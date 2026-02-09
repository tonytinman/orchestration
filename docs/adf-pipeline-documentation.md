# Nova Framework - ADF Orchestration Engine

## Table of Contents

- [1. Overview](#1-overview)
- [2. Architecture](#2-architecture)
- [3. Pipeline Reference](#3-pipeline-reference)
  - [3.1 BatchOrchestrator](#31-batchorchestrator)
  - [3.2 QueueExecutor](#32-queueexecutor)
  - [3.3 ProcessExecutor](#33-processexecutor)
  - [3.4 ExtractController](#34-extractcontroller)
- [4. Stored Procedures](#4-stored-procedures)
- [5. Linked Services & Datasets](#5-linked-services--datasets)
- [6. External Pipeline Dependencies](#6-external-pipeline-dependencies)
- [7. Error Handling & Retry Policies](#7-error-handling--retry-policies)
- [8. Operational Runbook](#8-operational-runbook)

---

## 1. Overview

The **Nova Framework Orchestration Engine** is a set of Azure Data Factory (ADF) pipelines that manage end-to-end batch data processing. It coordinates extraction from source systems (Oracle, Azure SQL), ingestion into a data lake, and transformation via Azure Databricks — all driven by a metadata-managed queue in Azure SQL Database.

### Key Capabilities

- **Batch-driven scheduling** with partition-date-based data loads
- **Queue-based execution** with automatic dependency resolution
- **Parallel processing** of independent queue items
- **Multi-source extraction** routed by data contract configuration
- **Databricks integration** for ingest and transform workloads
- **Audit trail** with per-process status tracking and metadata capture

### ADF Folder Structure

| Folder | Pipelines |
|--------|-----------|
| `Nova Framework/Orchestration Engine` | BatchOrchestrator, QueueExecutor, ProcessExecutor |
| `Nova Framework/Process Library/Extraction` | ExtractController |

---

## 2. Architecture

### Execution Flow

```
BatchOrchestrator
│
├── 1. SetEnvironmentConfig          (load environment-specific settings)
├── 2. Set Partition Date Variable   (calculate load date from offset)
├── 3. Initiate Data Load            (run.InitiateBatch → returns LoadID)
├── 4. Set Load ID
├── 5. Initialise Process Queue      (run.InitialiseQueue)
├── 6. Check Pending Items           (run.IsQueuePending)
│
└── 7. UNTIL no pending items ──────────────────────────────────┐
        │                                                       │
        ├── QueueExecutor                                       │
        │   ├── SetEnvironmentConfig                            │
        │   ├── Get Pending Items    (run.GetPendingItems)      │
        │   └── ForEach item (PARALLEL)                         │
        │       └── ProcessExecutor                             │
        │           ├── SetEnvironmentConfig                    │
        │           ├── Start Process    (run.StartProcess)     │
        │           ├── Get Process Metadata                    │
        │           ├── SWITCH on ProcessType:                  │
        │           │   ├── EXTRACT → ExtractController         │
        │           │   │   ├── SetEnvironmentConfig            │
        │           │   │   ├── GetExtractContractConfig        │
        │           │   │   └── SWITCH on provider:             │
        │           │   │       └── ORACLE → ExtractOracleToNova│
        │           │   └── DATABRICKS (INGEST / TRANSFORM)     │
        │           │       ├── GetIngestProcessConfig           │
        │           │       ├── GetDatabricksJobID               │
        │           │       └── Execute Databricks Job           │
        │           ├── Add Dependencies (run.AddDependenciesToQueue)│
        │           └── Finalise Process (run.ProcessFinalise)  │
        │                                                       │
        └── Re-check pending items → loop ──────────────────────┘
```

### Design Patterns

| Pattern | Description |
|---------|-------------|
| **Polling loop** | BatchOrchestrator uses an `Until` activity that repeatedly checks `run.IsQueuePending` until the queue is drained. |
| **Fan-out / fan-in** | QueueExecutor's `ForEach` runs items in parallel (`isSequential: false`), with each item invoking its own ProcessExecutor instance. |
| **Switch routing** | ProcessExecutor routes by `ProcessType` (EXTRACT vs DATABRICKS). ExtractController routes by `system_provider` (ORACLE, etc.). |
| **Dynamic dependencies** | After each process completes, `run.AddDependenciesToQueue` enqueues newly-unblocked downstream processes, enabling the polling loop to pick them up on the next iteration. |
| **Environment abstraction** | Every pipeline calls `SetEnvironmentConfig` first, returning server names, workspace URLs, storage accounts, etc. — enabling promotion across environments without pipeline changes. |

---

## 3. Pipeline Reference

### 3.1 BatchOrchestrator

> **Folder:** `Nova Framework/Orchestration Engine`
> **Purpose:** Top-level entry point. Initiates a batch load and drives the queue processing loop until all work is complete.

#### Parameters

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `BatchName` | string | `galahad_demo_batch` | Logical name of the batch to execute |
| `LoadName` | string | `TestLoad1` | Name for this specific load run |

#### Variables

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `PartitionDate` | String | `2025/07/30` | Calculated load date (overwritten at runtime) |
| `PartitionDateOffset` | Integer | `1` | Number of days in the past for partition date calculation |
| `LoadID` | String | _(empty)_ | GUID returned by `run.InitiateBatch` |
| `PendingItems` | Boolean | _(empty)_ | Flag controlling the Until loop |

#### Activity Sequence

| # | Activity | Type | Depends On | Description |
|---|----------|------|------------|-------------|
| 1 | Environment Config | ExecutePipeline | _(none)_ | Calls `SetEnvironmentConfig` to load environment settings |
| 2 | Set Partition Date Variable | SetVariable | 1 | Computes partition date: `formatDateTime(getPastTime(PartitionDateOffset, 'Day'), 'yyyy-MM-dd')` |
| 3 | Initiate Data Load | Lookup | 2 | Calls `run.InitiateBatch` with BatchName, LoadName, PartitionDate. Returns `LoadID`. |
| 4 | Set Load ID | SetVariable | 3 | Stores the LoadID from step 3 into a pipeline variable |
| 5 | Initialise Process Queue | StoredProcedure | 4 | Calls `run.InitialiseQueue` with LoadID to populate the process queue |
| 6 | Get Pending Items Flag | Lookup | 5 | Calls `run.IsQueuePending` to check if there are items to process |
| 7 | Set Pending Items Variable | SetVariable | 6 | Sets `PendingItems = IsPending > 0` |
| 8 | **Until No More Pending Items** | Until | 7 | Loops while `PendingItems == true`: |
| 8a | &nbsp;&nbsp;Process Pending Queue Items | ExecutePipeline | _(loop start)_ | Calls **QueueExecutor** with LoadID, PartitionDate, BatchName |
| 8b | &nbsp;&nbsp;Check Pending Items | Lookup | 8a | Re-checks `run.IsQueuePending` |
| 8c | &nbsp;&nbsp;Set Pending Items Variable | SetVariable | 8b | Updates loop control variable |

#### Timeout

- Until loop: **12 hours**
- Individual activities: **12 hours** (query timeout: 2 hours)

---

### 3.2 QueueExecutor

> **Folder:** `Nova Framework/Orchestration Engine`
> **Purpose:** Fetches all currently pending queue items and executes them in parallel.

#### Parameters

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `p_load_id` | string | `A9530B90-4BEA-4CCC-A0A0-6D1E192C1100` | GUID of the current load |
| `p_load_date` | string | _(empty)_ | Partition date for the load |
| `p_BatchName` | string | _(empty)_ | Batch name passed through from orchestrator |

#### Activity Sequence

| # | Activity | Type | Depends On | Description |
|---|----------|------|------------|-------------|
| 1 | Environment Config | ExecutePipeline | _(none)_ | Calls `SetEnvironmentConfig` |
| 2 | Get Pending Items | Lookup | 1 | Calls `run.GetPendingItems` with LoadID. Returns **all rows** (`firstRowOnly: false`). |
| 3 | ForEachItem | ForEach | 2 | Iterates over pending items **in parallel** (`isSequential: false`) |
| 3a | &nbsp;&nbsp;Execute Process | ExecutePipeline | _(each item)_ | Calls **ProcessExecutor** with `QueueID`, `LoadID`, `LoadDate`, `BatchName` |

#### Key Behavior

- The `ForEach` operates in **parallel mode**, meaning all pending items are processed concurrently (subject to ADF's default concurrency limit of 20 per ForEach).
- Each iteration waits for its ProcessExecutor child pipeline to complete (`waitOnCompletion: true`).

---

### 3.3 ProcessExecutor

> **Folder:** `Nova Framework/Orchestration Engine`
> **Purpose:** Executes a single queued process — routes to the appropriate handler based on process type, manages status lifecycle, and records audit data.

#### Parameters

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `p_queue_id` | int | `37` | Queue item identifier |
| `p_load_id` | string | `D5E30220-B86E-4E23-8C43-31FDA8051ABC` | Load GUID |
| `p_load_date` | string | `2026-02-06` | Partition date |
| `p_switch_log` | bool | `false` | Logging toggle (reserved) |
| `p_BatchName` | string | `galahad_demo_batch` | Batch name |

#### Variables

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `_ProcessAuditData` | String | `UNKNOWN/EMPTY` | Audit payload captured from child pipeline output |
| `_FinaliseProcessStatus` | String | `UNKNOWN/EMPTY` | Final status: `SUCCESS` or `FAILED` |

#### Activity Sequence

| # | Activity | Type | Depends On | Description |
|---|----------|------|------------|-------------|
| 1 | Environment Config | ExecutePipeline | _(none)_ | Calls `SetEnvironmentConfig` |
| 2 | Start Process | StoredProcedure | 1 | Calls `run.StartProcess` — marks queue item as running |
| 3 | Get Process Metadata | Lookup | 2 | Calls `run.GetProcessMetadata` — returns `ProcessType`, `ProcessName`, `ProcessContract` |
| 4 | **Process Type (Switch)** | Switch | 3 | Routes based on ProcessType (see routing logic below) |
| 5 | Add Dependencies | StoredProcedure | 4 (Succeeded) | Calls `run.AddDependenciesToQueue` — enqueues downstream processes |
| 6 | Finalise Process | StoredProcedure | 4 (Completed) | Calls `run.ProcessFinalise` with status and audit data |

#### Process Type Routing Logic

The Switch expression normalizes the `ProcessType` value:

```
EXTRACT        → routes to "EXTRACT" case
INGEST         → routes to "DATABRICKS" case
TRANSFORM      → routes to "DATABRICKS" case
(anything else)→ passes through as-is (no matching case — falls to default/no-op)
```

#### EXTRACT Case Activities

| Activity | Description |
|----------|-------------|
| Extract Controller | Calls **ExtractController** pipeline with contract storage info and source table schema/name (split from `ProcessName` on `.`) |
| Set ProcessAuditData | Captures `ProcessAuditData` from ExtractController output |
| Set EXTRACT-ADF SUCCESS | Sets status to `SUCCESS` on Extract Controller success |
| Set EXTRACT-ADF FAILED | Sets status to `FAILED` on Extract Controller failure |

#### DATABRICKS Case Activities

| Activity | Description |
|----------|-------------|
| Get IngestProcessConfig | Calls `run.GetIngestProcessConfig` — returns `NotebookName`, `Contract`, `QueueID`, `LoadDate`, `ProcessGroupName`, `cluster_id`, `ProcessAuditData` |
| Execute GetDatabricksJobID | Calls **GetDatabricksJobID** pipeline to resolve the Databricks job ID from the job name |
| Execute Databricks Job | Runs the Databricks job with parameters: `data_contract_name`, `env`, `process_queue_id`, `source_ref`, `batch_name`, `load_date`, `process_group_name`, `cluster_id` |
| Set DATABRICKS SUCCESS | Sets status to `SUCCESS` on job success |
| Set DATABRICKS FAILED | Sets status to `FAILED` on job failure |
| Set ProcessAuditData | Captures `runPageUrl` from Databricks job output as JSON audit data |

#### Finalise Process

The `Finalise Process` activity fires on the **Completed** dependency condition (runs regardless of success or failure). It calls `run.ProcessFinalise` with:
- `QueueID` — the queue item
- `status` — `SUCCESS`, `FAILED`, or `UNKNOWN/EMPTY` (if switch case didn't match)
- `ProcessAuditData` — audit payload from the child pipeline

---

### 3.4 ExtractController

> **Folder:** `Nova Framework/Process Library/Extraction`
> **Purpose:** Loads a data contract configuration from Blob Storage and routes to the appropriate source-specific extraction pipeline.

#### Parameters

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `p_contract_storageaccountname` | string | `stnovadevadbuks01` | Storage account holding data contracts |
| `p_contract_container` | string | `data-contracts` | Blob container for contracts |
| `p_contract_directory` | string | `test` | Directory within the container |
| `p_contract_filename` | string | `extract.galahad` | Contract filename |
| `p_src_tbl_schema` | string | `QUOLIVE_MANAGER` | Source table schema |
| `p_src_tbl_name` | string | `INDUSTRY_TYPE` | Source table name |

#### Variables

| Name | Type | Description |
|------|------|-------------|
| `_audit_json` | String | Intermediate audit data |
| `_infer_contract_type` | String | Reserved for contract type inference |
| `_ProcessAuditData` | String | Audit data returned to caller |

#### Activity Sequence

| # | Activity | Type | Depends On | Description |
|---|----------|------|------------|-------------|
| 1 | Environment Config | ExecutePipeline | _(none)_ | Calls `SetEnvironmentConfig` |
| 2 | Get Data Contract Config | ExecutePipeline | 1 | Calls **GetExtractContractConfig** with storage account, container, directory, filename. Returns connection details and sink configuration. |
| 3 | **Extract Type (Switch)** | Switch | 2 | Routes based on `system_provider` (uppercased) from contract config |
| 4 | Set Return Variable | SetVariable | 3 | Sets `pipelineReturnValue.ProcessAuditData` for the parent pipeline |

#### Extract Type Routing

| Provider | Pipeline Called | Parameters Passed |
|----------|---------------|-------------------|
| `ORACLE` | **ExtractOracleToNova** | `vault_uri`, `client_secret`, `server`, `user`, `database`, `port`, `serviceName`, `src_schema`, `src_table`, `sink_container`, `sink_source_ref`, `sink_storageAccountName`, `sink_partition_type`, `sink_partition_column` |

#### Data Contract Fields

The data contract (loaded from Blob Storage via `GetExtractContractConfig`) provides:

| Field | Description |
|-------|-------------|
| `vault_uri` | Key Vault URI for secrets |
| `client_secret` | Key Vault secret name for source credentials |
| `server` | Source database server |
| `user` | Source database user |
| `database` | Source database name |
| `port` | Source database port |
| `serviceName` | Oracle service name |
| `container` | Sink blob container |
| `source_ref` | Source reference identifier |
| `storage_account_name` | Sink storage account |
| `partition_type` | Partitioning strategy for sink |
| `partition_column` | Column used for partitioning |
| `system_provider` | Source system type (e.g., ORACLE) |

---

## 4. Stored Procedures

All stored procedures reside in the `run` schema of the metadata Azure SQL Database.

| Stored Procedure | Called By | Purpose |
|-----------------|-----------|---------|
| `run.InitiateBatch` | BatchOrchestrator | Creates a new batch load record. Accepts BatchName, LoadName, PartitionDate. Returns `LoadID` (GUID). |
| `run.InitialiseQueue` | BatchOrchestrator | Populates the process queue for a given LoadID based on configured batch processes and their dependencies. |
| `run.IsQueuePending` | BatchOrchestrator | Returns an `IsPending` flag (int) indicating whether unprocessed items remain in the queue. Used as the loop control. |
| `run.GetPendingItems` | QueueExecutor | Returns all queue items currently in a pending/ready state for the given LoadID. |
| `run.StartProcess` | ProcessExecutor | Marks a queue item as running (updates status, sets start timestamp). |
| `run.GetProcessMetadata` | ProcessExecutor | Returns process metadata: `ProcessType`, `ProcessName`, `ProcessContract`, etc. |
| `run.AddDependenciesToQueue` | ProcessExecutor | After a process succeeds, checks if downstream dependent processes are now unblocked and adds them to the queue. |
| `run.ProcessFinalise` | ProcessExecutor | Updates the queue item with final status (`SUCCESS`/`FAILED`), audit data, and end timestamp. |
| `run.GetIngestProcessConfig` | ProcessExecutor | Returns Databricks job configuration: `NotebookName`, `Contract`, `QueueID`, `LoadDate`, `ProcessGroupName`, `cluster_id`, `ProcessAuditData`. |

---

## 5. Linked Services & Datasets

### Linked Services

| Name | Type | Purpose |
|------|------|---------|
| `ls_AzureSqlDatabase` | Azure SQL Database | Metadata database. Parameterized with `p_sqlserver` and `p_databasename` (resolved from environment config). |
| `ls_NovaFlow_AzureDatabricks` | Azure Databricks | Databricks workspace. Parameterized with `DatabricksWorkspaceURL`, `DatabricksWorkspaceResourceID`, and `ExistingClusterID`. |

### Datasets

| Name | Type | Purpose |
|------|------|---------|
| `ds_azuresql_generic` | Azure SQL | Generic SQL dataset parameterized with `p_sqlservername` and `p_databasename`. Used by all Lookup activities. |

---

## 6. External Pipeline Dependencies

These pipelines are referenced but **not defined in this repository**:

| Pipeline | Called By | Purpose |
|----------|-----------|---------|
| `SetEnvironmentConfig` | All pipelines | Returns environment-specific configuration values (server names, storage accounts, Databricks workspace URLs, etc.) via `pipelineReturnValue`. |
| `GetExtractContractConfig` | ExtractController | Reads a data contract JSON file from Blob Storage and returns parsed connection/sink configuration. |
| `ExtractOracleToNova` | ExtractController | Performs the actual data extraction from Oracle to Azure Blob Storage. Returns `ProcessAuditData`. |
| `GetDatabricksJobID` | ProcessExecutor | Resolves a Databricks job name to its numeric job ID. Accepts `p_job_name`, `p_creator_user_name`, `p_ADB_WorkspaceURL`. Returns `actualJobID`. |

---

## 7. Error Handling & Retry Policies

### Retry Configuration

| Setting | Value |
|---------|-------|
| Retry count | `0` (no automatic retries) |
| Retry interval | 30 seconds (if retries were enabled) |
| Activity timeout | 12 hours |
| Query timeout | 2 hours |

### Status Lifecycle

Each queue item follows this status progression:

```
PENDING → RUNNING → SUCCESS / FAILED
```

- `run.StartProcess` transitions the item to **RUNNING**
- On child pipeline success: status is set to **SUCCESS**
- On child pipeline failure: status is set to **FAILED**
- `run.ProcessFinalise` persists the final status regardless of outcome (fires on **Completed** dependency condition)

### Failure Behavior

- If a process **fails**, the `Finalise Process` activity still runs (dependency condition: `Completed`, not `Succeeded`), ensuring the failure is recorded.
- The `Add Dependencies` activity only runs on **Succeeded**, so downstream processes are not unblocked when a process fails.
- The Until loop continues processing remaining pending items even if individual processes fail — the queue drains until no more items are eligible.
- If status variables are never set (e.g., unrecognized ProcessType), the default value `UNKNOWN/EMPTY` is recorded.

---

## 8. Operational Runbook

### Triggering a Batch

Trigger the **BatchOrchestrator** pipeline with:

| Parameter | Example Value | Notes |
|-----------|---------------|-------|
| `BatchName` | `galahad_demo_batch` | Must match a configured batch in the metadata database |
| `LoadName` | `DailyLoad` | Descriptive name for this execution |

The pipeline will automatically calculate the partition date (yesterday by default), create the load, populate the queue, and process all items.

### Monitoring

1. **ADF Monitor** — Track the BatchOrchestrator run; drill into QueueExecutor and ProcessExecutor child runs for per-item status.
2. **Metadata Database** — Query queue tables to see item statuses, timestamps, and audit data.
3. **Databricks** — For INGEST/TRANSFORM processes, the `runPageUrl` in the audit data links directly to the Databricks job run.

### Common Failure Scenarios

| Scenario | Symptoms | Resolution |
|----------|----------|------------|
| Source system unavailable | ExtractController child pipeline fails; process marked FAILED | Check source connectivity (Oracle/SQL). Re-trigger the batch after resolving — `run.InitialiseQueue` should re-queue failed items. |
| Databricks cluster not running | Execute Databricks Job fails | Verify the `cluster_id` in process config is valid and the cluster is available. |
| Unknown ProcessType | Process finalized with `UNKNOWN/EMPTY` status | Check `run.GetProcessMetadata` output for the QueueID — the ProcessType may be misconfigured in the metadata database. |
| Queue never drains | Until loop runs to 12-hour timeout | Check for circular dependencies or processes stuck in RUNNING state in the queue table. |
| Environment config failure | All downstream activities fail | Verify the `SetEnvironmentConfig` pipeline is deployed and returns expected output values. |

### Adding a New Source Provider

To add support for a new source system (e.g., SQL Server, PostgreSQL):

1. Create a new extraction pipeline (e.g., `ExtractSQLServerToNova`)
2. Add a new case to the `Extract Type` Switch activity in **ExtractController**
3. Map the contract fields to the new pipeline's parameters
4. Ensure data contracts for the new provider include the correct `system_provider` value
