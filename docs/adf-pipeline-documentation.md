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
  - [4.1 Batch Lifecycle](#41-batch-lifecycle)
  - [4.2 Queue Management](#42-queue-management)
  - [4.3 Process Execution](#43-process-execution)
  - [4.4 Process Configuration](#44-process-configuration)
  - [4.5 Telemetry](#45-telemetry)
- [5. Database Schema](#5-database-schema)
- [6. Linked Services & Datasets](#6-linked-services--datasets)
- [7. External Pipeline Dependencies](#7-external-pipeline-dependencies)
- [8. Error Handling & Retry Policies](#8-error-handling--retry-policies)
- [9. Operational Runbook](#9-operational-runbook)

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

### Repository Structure

```
orchestration/
├── BatchOrchestrator.json               — Main orchestration pipeline
├── QueueExecutor                        — Parallel queue processor pipeline
├── ProcessExecutor.json                 — Process routing pipeline
├── ExtractController.json               — Extraction dispatcher pipeline
├── database/
│   └── run/
│       └── StoredProcedures/
│           ├── AddDependenciesToQueue.sql
│           ├── GetIngestProcessConfig.sql
│           ├── GetPendingItems.sql
│           ├── GetProcessConfig_ExtractADFAzureBlob.sql
│           ├── GetProcessConfig_Ingest.sql
│           ├── GetProcessFromQueue.sql
│           ├── GetProcessMetadata.sql
│           ├── InitialiseQueue.sql
│           ├── InitiateBatch.sql
│           ├── InitiateParentLoad.sql
│           ├── IsQueuePending.sql
│           ├── LogTelemetry.sql
│           ├── ProcessFinalise.sql
│           └── StartProcess.sql
└── docs/
    └── adf-pipeline-documentation.md    — This document
```

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
| 2 | Start Process | StoredProcedure | 1 | Calls `run.StartProcess` — marks queue item as `IN PROGRESS` |
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

All stored procedures reside in the `[run]` schema of the metadata Azure SQL Database. Source files are located in `database/run/StoredProcedures/`.

### Summary

| Stored Procedure | Called By | Category | Purpose |
|-----------------|-----------|----------|---------|
| `run.InitiateBatch` | BatchOrchestrator | Batch Lifecycle | Creates a new load and registers process groups |
| `run.InitiateParentLoad` | _(external)_ | Batch Lifecycle | Creates a parent queue record to group pending items |
| `run.InitialiseQueue` | BatchOrchestrator | Queue Management | Seeds the queue with root processes (no dependencies) |
| `run.IsQueuePending` | BatchOrchestrator | Queue Management | Checks if any PENDING items remain |
| `run.GetPendingItems` | QueueExecutor | Queue Management | Returns items ready for execution (dependencies satisfied) |
| `run.AddDependenciesToQueue` | ProcessExecutor | Queue Management | Enqueues downstream dependent processes |
| `run.StartProcess` | ProcessExecutor | Process Execution | Marks a queue item as IN PROGRESS |
| `run.GetProcessMetadata` | ProcessExecutor | Process Execution | Returns process routing metadata |
| `run.ProcessFinalise` | ProcessExecutor | Process Execution | Records final status and audit data |
| `run.GetProcessFromQueue` | _(utility)_ | Process Execution | Returns process details from the queue |
| `run.GetIngestProcessConfig` | ProcessExecutor | Configuration | Returns Databricks job config with cluster mapping |
| `run.GetProcessConfig_Ingest` | _(utility)_ | Configuration | Returns basic ingest config with extract path |
| `run.GetProcessConfig_ExtractADFAzureBlob` | _(utility)_ | Configuration | Parses JSON config for blob-to-blob extraction |
| `run.LogTelemetry` | _(utility)_ | Telemetry | Writes a message to the telemetry log |

---

### 4.1 Batch Lifecycle

#### `run.InitiateBatch`

> **File:** `database/run/StoredProcedures/InitiateBatch.sql`
> **Called by:** BatchOrchestrator (Lookup activity "Initiate Data Load")

Creates a new load record and copies the associated process groups from batch configuration.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `@LoadName` | varchar(100) | Descriptive name for this load run |
| `@BatchName` | varchar(200) | Batch identifier matching `Config.Batch.BatchName` |
| `@PartitionDate` | varchar(100) | Data partition date for this load |

**Behavior:**

1. Generates a new `@LoadID` (GUID via `NEWID()`)
2. Inserts a row into `run.Load` by looking up the `BatchID` from `Config.Batch` where `BatchName` matches
3. Copies all active process groups from `Config.BatchProcessGroup` into `run.LoadProcessGroup` for this load
4. Returns the `@LoadID` to the caller

**Returns:** Single row with column `LoadID` (uniqueidentifier)

---

#### `run.InitiateParentLoad`

> **File:** `database/run/StoredProcedures/InitiateParentLoad.sql`
> **Called by:** Not directly called by the pipelines in this repository (available for external use)

Creates a parent queue record and groups orphaned pending items under it. Used to logically group a batch of queue items under a single parent for tracking.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `@LoadID` | uniqueidentifier | Load GUID |
| `@ADFExecution` | varchar(500) | ADF execution/run identifier |
| `@ProcessGroup` | varchar(100) | _(optional, currently unused in logic)_ Process group filter |

**Behavior:**

1. Counts pending queue items that have no `ParentQueueID` for the given LoadID
2. If count > 0:
   - Inserts a new "Parent" queue record with `ProcessType = 'Parent'` and status `IN PROGRESS`
   - Captures the new `ParentQueueID` via `@@IDENTITY`
   - Updates all orphaned PENDING items to point to this parent
3. Returns `ParentQueueID` and `EntitiesToProcess` count

**Returns:** Single row with columns `ParentQueueID` (int) and `EntitiesToProcess` (int)

---

### 4.2 Queue Management

#### `run.InitialiseQueue`

> **File:** `database/run/StoredProcedures/InitialiseQueue.sql`
> **Called by:** BatchOrchestrator (StoredProcedure activity "Initialise Process Queue")

Seeds the process queue with **root processes** — those that have no upstream dependencies. This is the starting point for the DAG execution.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `@LoadID` | uniqueidentifier | Load GUID |

**Behavior:**

1. Joins `run.Load` → `run.LoadProcessGroup` → `Config.vProcess` → `Config.ProcessDAG`
2. Filters for processes where:
   - `Config.ProcessDAG.DependentOnProcessID IS NULL` (no upstream dependency — root nodes)
   - `Process.Active = 1` and `ProcessGroup.Active = 1`
3. Inserts matching processes into `run.ProcessQueue` with:
   - `ProcessStatus = 'PENDING'`
   - `ProcessPartition` = the load's `PartitionDate`
   - `ProcessCreateDate` = current timestamp
   - `ParentQueueID`, `ADFExecutionID`, start/end dates = NULL

**Key tables involved:** `run.Load`, `run.LoadProcessGroup`, `Config.vProcess` (view), `Config.ProcessDAG`

---

#### `run.IsQueuePending`

> **File:** `database/run/StoredProcedures/IsQueuePending.sql`
> **Called by:** BatchOrchestrator (Lookup activities for Until loop control)

Simple check whether any PENDING items remain in the queue for a load.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `@LoadID` | uniqueidentifier | Load GUID |

**Returns:** Single row with column `IsPending` — `1` if PENDING items exist, `0` otherwise.

**SQL logic:** `SELECT CASE WHEN COUNT(QueueID) > 0 THEN 1 ELSE 0 END FROM run.ProcessQueue WHERE LoadID = @LoadID AND ProcessStatus = 'PENDING'`

---

#### `run.GetPendingItems`

> **File:** `database/run/StoredProcedures/GetPendingItems.sql`
> **Called by:** QueueExecutor (Lookup activity "Get Pending Items")

Returns all queue items that are ready for execution — either because their dependencies have been satisfied or because they have no dependencies.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `@LoadID` | uniqueidentifier | Load GUID |

**Behavior:**

The query uses a `UNION ALL` of two datasets:

1. **Dependent items with satisfied dependencies:**
   - Joins `run.ProcessQueue` (base) → `config.ProcessDAG` (map) → `run.ProcessQueue` (dpn)
   - Matches where the dependency process's `ProcessStatus` equals the required `DependencyType` in the DAG
   - Only returns items where `base.ProcessStatus = 'PENDING'`

2. **Root items with no dependencies:**
   - Left joins `run.ProcessQueue` → `config.ProcessDAG`
   - Matches where `DependentOnProcessID IS NULL`
   - Only returns items where `ProcessStatus = 'PENDING'`

Results are ordered by `QueueID`.

**Returns:** Multiple rows with columns: `LoadID`, `ProcessID`, `QueueID`, `ParentQueueID`, `ADFExecutionID`, `ProcessType`, `ProcessSubType`, `ProcessTarget`, `Contract`, `Config`, `NotebookName`, `NotebookRunURL`, `ProcessPartition`, `ProcessStatus`, `ExtractPath`, `TriggerQueueID`

**Important:** The `DependencyType` in `config.ProcessDAG` allows flexible dependency conditions (e.g., a process can depend on another being `SUCCESS`, or even `FAILED`), not just simple completion.

---

#### `run.AddDependenciesToQueue`

> **File:** `database/run/StoredProcedures/AddDependenciesToQueue.sql`
> **Called by:** ProcessExecutor (StoredProcedure activity "Add Dependencies", fires on Succeeded)

After a process completes successfully, this procedure enqueues any downstream processes that depend on it.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `@QueueID` | int | The completed queue item's ID |

**Behavior:**

1. Looks up the completed process via `run.ProcessQueue`
2. Joins through `Config.ProcessDAG` to find processes that list this process as `DependentOnProcessID`
3. Joins `Config.vProcess` to get process definitions and `run.LoadProcessGroup` / `run.Load` for load context
4. Filters for active processes and process groups
5. **Deduplication guard:** Uses `NOT EXISTS` to skip processes already in the queue for this LoadID
6. Inserts new queue items with:
   - `ProcessStatus = 'PENDING'`
   - `TriggerQueueID = @QueueID` (links back to the triggering process)
   - `ProcessPartition` = the load's `PartitionDate`

**Key detail:** The `TriggerQueueID` column creates a parent-child linkage between the triggering process and its dependents. This is used later by `run.GetIngestProcessConfig` to retrieve audit data (e.g., extract path) from the upstream process.

---

### 4.3 Process Execution

#### `run.StartProcess`

> **File:** `database/run/StoredProcedures/StartProcess.sql`
> **Called by:** ProcessExecutor (StoredProcedure activity "Start Process")

Marks a queue item as actively running.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `@QueueID` | int | Queue item ID |

**Behavior:**
- Sets `ProcessStartDate = GETDATE()`
- Sets `ProcessStatus = 'IN PROGRESS'`

---

#### `run.GetProcessMetadata`

> **File:** `database/run/StoredProcedures/GetProcessMetadata.sql`
> **Called by:** ProcessExecutor (Lookup activity "Get Process Metadata")

Returns the metadata needed to route and execute a process.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `@LoadID` | nvarchar(MAX) | Load GUID (as string) |
| `@QueueID` | int | Queue item ID |

**Returns:** Single row with columns:

| Column | Source Column | Description |
|--------|--------------|-------------|
| `ProcessID` | ProcessID | Process identifier |
| `ProcessName` | ProcessName | Process name (e.g., `SCHEMA.TABLE` for extracts) |
| `ProcessType` | ProcessType | Routing key: `EXTRACT`, `INGEST`, or `TRANSFORM` |
| `ProcessSubType` | ProcessSubType | Sub-classification |
| `ProcessContract` | Contract | Data contract filename |
| `ProcessConfig` | Config | JSON configuration blob |
| `ScriptName` | NotebookName | Databricks notebook/job name |
| `TriggerQueueID` | TriggerQueueID | ID of the upstream process that triggered this one |

---

#### `run.ProcessFinalise`

> **File:** `database/run/StoredProcedures/ProcessFinalise.sql`
> **Called by:** ProcessExecutor (StoredProcedure activity "Finalise Process", fires on Completed)

Records the final outcome of a process execution.

**Parameters:**

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `@QueueID` | int | _(required)_ | Queue item ID |
| `@status` | varchar(50) | _(required)_ | Final status: `SUCCESS` or `FAILED` |
| `@ProcessAuditData` | nvarchar(2000) | `'{}'` | JSON audit payload (e.g., Databricks runPageUrl, extract metadata) |

**Behavior:**
- Sets `ProcessStatus = @status`
- Sets `ProcessEndDate = GETDATE()`
- Sets `ProcessAuditData = @ProcessAuditData`

---

#### `run.GetProcessFromQueue`

> **File:** `database/run/StoredProcedures/GetProcessFromQueue.sql`
> **Called by:** Not directly called by the pipelines in this repository (utility procedure)

Returns process details from the queue. Note: the current implementation does not filter by `@QueueID` in the WHERE clause — it returns all rows from `run.ProcessQueue`.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `@QueueID` | int | Queue item ID (declared but not used in WHERE clause) |

**Returns:** Columns: `ProcessID`, `ProcessName`, `ProcessType`, `ProcessSubType`, `Contract`, `Config`, `NotebookName`

---

### 4.4 Process Configuration

#### `run.GetIngestProcessConfig`

> **File:** `database/run/StoredProcedures/GetIngestProcessConfig.sql`
> **Called by:** ProcessExecutor (Lookup activity in DATABRICKS switch case)

Returns the configuration needed to execute a Databricks ingest or transform job, including the cluster mapping and upstream process audit data.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `@QueueID` | int | Queue item ID |

**Behavior:**

1. Queries `run.ProcessQueue` (q1) for the current process
2. Left joins `run.ProcessQueue` (q2) via `TriggerQueueID` to retrieve the **upstream process's audit data** (e.g., extract path from a prior EXTRACT step)
3. Joins `config.Process` → `config.ProcessGroup` for the process group name
4. Joins `config.ADBCluster` to resolve the `cluster_id` based on `ProcessGroupName`
5. For `TRANSFORM` type processes, overrides `ProcessAuditData` with `'{"source_ref":" "}'` (empty source ref)

**Returns:** Single row with columns:

| Column | Description |
|--------|-------------|
| `QueueID` | Current queue item ID |
| `ProcessGroupName` | Process group name (used as Databricks job parameter) |
| `NotebookName` | Databricks job name to execute |
| `Contract` | Data contract name |
| `LoadDate` | Process start date (from `ProcessStartDate`) |
| `ProcessAuditData` | Upstream audit data (or empty JSON for transforms) |
| `cluster_id` | Databricks cluster ID from `config.ADBCluster` |

---

#### `run.GetProcessConfig_Ingest`

> **File:** `database/run/StoredProcedures/GetProcessConfig_Ingest.sql`
> **Called by:** Not directly called by the pipelines in this repository (utility procedure)

Simplified ingest configuration that returns the extract path from the triggering process.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `@QueueID` | int | Queue item ID |

**Returns:** Single row with columns: `QueueID`, `NotebookName`, `Contract`, `ExtractPath` (from the trigger queue item)

---

#### `run.GetProcessConfig_ExtractADFAzureBlob`

> **File:** `database/run/StoredProcedures/GetProcessConfig_ExtractADFAzureBlob.sql`
> **Called by:** Not directly called by the pipelines in this repository (utility procedure)

Parses the JSON `Config` column from `config.Process` to extract source and destination blob storage connection details. Used for Azure Blob-to-Blob extraction scenarios.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `@LoadID` | uniqueidentifier | Load GUID |
| `@QueueID` | int | Queue item ID |

**Returns:** Single row (TOP 1) with parsed JSON fields:

| Column | JSON Path | Description |
|--------|-----------|-------------|
| `ProcessID` | — | Process identifier |
| `Classification` | — | Process classification |
| `ConfigType` | `$.TYPE` | Configuration type |
| `ConfigSource` | `$.SOURCE` | Source system identifier |
| `ConfigSource_ConnectionType` | `$.SOURCE_CONNECTION.TYPE` | Source connection type |
| `ConfigSource_SorageContainer` | `$.SOURCE_CONNECTION.CONNECTIONSTRING.CONTAINER` | Source blob container |
| `ConfigSource_StorageName` | `$.SOURCE_CONNECTION.CONNECTIONSTRING.STORAGEACCOUNTNAME` | Source storage account |
| `ConfigSource_Directory` | `$.SOURCE_CONNECTION.CONNECTIONSTRING.DIRECTORY` | Source directory |
| `ConfigDest_Con_Type` | `$.DEST_CONNECTION.TYPE` | Destination connection type |
| `ConfigDest_SorageContainer` | `$.DEST_CONNECTION.CONNECTIONSTRING.CONTAINER` | Destination blob container |
| `ConfigDest_StorageName` | `$.DEST_CONNECTION.CONNECTIONSTRING.STORAGEACCOUNTNAME` | Destination storage account |
| `ConfigDest_Directory` | `$.DEST_CONNECTION.CONNECTIONSTRING.DIRECTORY` | Destination directory |
| `ConfigObject_Name` | `$.OBJECT.NAME` | Object/file name |
| `ConfigObject_Path` | `$.OBJECT.PATH` | Object/file path |

**Note:** Only processes with valid JSON in the `Config` column are returned (`ISJSON(cp.Config) = 1`).

---

### 4.5 Telemetry

#### `run.LogTelemetry`

> **File:** `database/run/StoredProcedures/LogTelemetry.sql`
> **Called by:** Not directly called by the pipelines in this repository (available for diagnostics)

Writes a telemetry message to the `run.Telemetry` table.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `@LoadID` | varchar(100) | Load identifier |
| `@Message` | varchar(400) | Telemetry message |

---

## 5. Database Schema

The metadata database uses two schemas: `run` (runtime state) and `Config` (configuration). The following tables and views are referenced by the stored procedures.

### Runtime Tables (`run` schema)

#### `run.Load`

Stores load execution records — one row per batch invocation.

| Column | Type | Description |
|--------|------|-------------|
| `LoadID` | uniqueidentifier | Primary key (generated GUID) |
| `BatchID` | int | Foreign key to `Config.Batch` |
| `LoadName` | varchar | Descriptive name for this load run |
| `PartitionDate` | varchar | Data partition date |
| `LoadStart` | datetime | Timestamp when the load was initiated |

#### `run.LoadProcessGroup`

Links a load to its active process groups — copied from `Config.BatchProcessGroup` at batch initiation.

| Column | Type | Description |
|--------|------|-------------|
| `LoadID` | uniqueidentifier | Foreign key to `run.Load` |
| `BatchID` | int | Foreign key to `Config.Batch` |
| `ProcessGroupID` | int | Foreign key to `Config.ProcessGroup` |
| `Active` | bit | Whether this process group is active for the load |

#### `run.ProcessQueue`

Central queue table that tracks every process execution within a load.

| Column | Type | Description |
|--------|------|-------------|
| `QueueID` | int | Primary key (identity) |
| `LoadID` | uniqueidentifier | Foreign key to `run.Load` |
| `ParentQueueID` | int | Optional parent queue item (for grouping) |
| `ADFExecutionID` | varchar | ADF pipeline run ID |
| `ProcessID` | int | Foreign key to `Config.Process` |
| `ProcessName` | varchar | Process name (e.g., `SCHEMA.TABLE`) |
| `ProcessType` | varchar | `EXTRACT`, `INGEST`, or `TRANSFORM` |
| `ProcessSubType` | varchar | Sub-classification |
| `ProcessTarget` | varchar | Target system/location |
| `Contract` | varchar | Data contract filename |
| `Config` | nvarchar | JSON configuration blob |
| `NotebookName` | varchar | Databricks notebook/job name |
| `ProcessCreateDate` | datetime | When the queue item was created |
| `ProcessStartDate` | datetime | When execution started |
| `ProcessEndDate` | datetime | When execution completed |
| `ProcessPartition` | varchar | Partition date for this process |
| `ProcessStatus` | varchar | `PENDING`, `IN PROGRESS`, `SUCCESS`, or `FAILED` |
| `ExtractPath` | varchar | Output path for extracted data |
| `InitiatingProcessID` | int | Process that initiated this one |
| `NotebookRunURL` | varchar | Databricks run page URL |
| `TriggerQueueID` | int | QueueID of the upstream process that triggered this item |
| `ProcessAuditData` | nvarchar(2000) | JSON audit payload |

#### `run.Telemetry`

Simple telemetry/logging table.

| Column | Type | Description |
|--------|------|-------------|
| `LoadID` | varchar(100) | Load identifier |
| `Message` | varchar(400) | Log message |

### Configuration Tables (`Config` schema)

#### `Config.Batch`

Defines available batches.

| Column | Type | Description |
|--------|------|-------------|
| `BatchID` | int | Primary key |
| `BatchName` | varchar | Unique batch name (e.g., `galahad_demo_batch`) |

#### `Config.BatchProcessGroup`

Maps batches to their process groups.

| Column | Type | Description |
|--------|------|-------------|
| `BatchID` | int | Foreign key to `Config.Batch` |
| `ProcessGroupID` | int | Foreign key to `Config.ProcessGroup` |
| `Active` | bit | Whether this mapping is active |

#### `Config.ProcessGroup`

Defines process groups (logical groupings of processes).

| Column | Type | Description |
|--------|------|-------------|
| `ProcessGroupID` | int | Primary key |
| `ProcessGroupName` | varchar | Group name (also used for Databricks cluster mapping) |

#### `Config.Process`

Defines individual processes.

| Column | Type | Description |
|--------|------|-------------|
| `ProcessID` | int | Primary key |
| `ProcessGroupID` | int | Foreign key to `Config.ProcessGroup` |
| `Classification` | varchar | Process classification |
| `Config` | nvarchar | JSON configuration for blob-to-blob extracts |
| _(other columns)_ | | Inherited by `Config.vProcess` |

#### `Config.vProcess` (View)

View over process definitions that includes process group context. Used by `InitialiseQueue` and `AddDependenciesToQueue`.

| Column | Description |
|--------|-------------|
| `ProcessID` | Process identifier |
| `ProcessGroupID` | Process group this process belongs to |
| `ProcessName` | Process name |
| `ProcessType` | `EXTRACT`, `INGEST`, or `TRANSFORM` |
| `ProcessSubType` | Sub-type |
| `ProcessTarget` | Target system |
| `Contract` | Data contract filename |
| `Config` | JSON configuration |
| `NotebookName` | Databricks notebook/job name |
| `Active` | Whether the process is active |

#### `Config.ProcessDAG`

Defines the directed acyclic graph (DAG) of process dependencies.

| Column | Type | Description |
|--------|------|-------------|
| `ProcessID` | int | The process that has a dependency |
| `DependentOnProcessID` | int | The process it depends on (NULL = root node) |
| `DependencyType` | varchar | Required status of the dependency (e.g., `SUCCESS`) |

**DAG interpretation:**
- A row with `DependentOnProcessID = NULL` means the process is a **root node** with no upstream dependencies — it is eligible for immediate execution.
- A row with `DependentOnProcessID = X` and `DependencyType = 'SUCCESS'` means this process can only run after process X reaches `SUCCESS` status.
- The `DependencyType` field enables advanced patterns like triggering on failure.

#### `Config.ADBCluster`

Maps process groups to Databricks cluster IDs.

| Column | Type | Description |
|--------|------|-------------|
| `ProcessGroupName` | varchar | Matches `Config.ProcessGroup.ProcessGroupName` |
| `cluster_id` | varchar | Databricks cluster ID to use for this group |

### Entity Relationship Overview

```
Config.Batch ──1:N──> Config.BatchProcessGroup ──N:1──> Config.ProcessGroup
                                                              │
                                                              1:N
                                                              ▼
                                                        Config.Process ──> Config.vProcess (view)
                                                              │
                                                              1:N
                                                              ▼
                                                        Config.ProcessDAG
                                                              │
Config.ADBCluster ── (joined on ProcessGroupName) ───────────┘

run.Load ──1:N──> run.LoadProcessGroup
    │
    1:N
    ▼
run.ProcessQueue ── (self-referencing via TriggerQueueID, ParentQueueID)

run.Telemetry (standalone)
```

---

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

## 7. External Pipeline Dependencies

These pipelines are referenced but **not defined in this repository**:

| Pipeline | Called By | Purpose |
|----------|-----------|---------|
| `SetEnvironmentConfig` | All pipelines | Returns environment-specific configuration values (server names, storage accounts, Databricks workspace URLs, etc.) via `pipelineReturnValue`. |
| `GetExtractContractConfig` | ExtractController | Reads a data contract JSON file from Blob Storage and returns parsed connection/sink configuration. |
| `ExtractOracleToNova` | ExtractController | Performs the actual data extraction from Oracle to Azure Blob Storage. Returns `ProcessAuditData`. |
| `GetDatabricksJobID` | ProcessExecutor | Resolves a Databricks job name to its numeric job ID. Accepts `p_job_name`, `p_creator_user_name`, `p_ADB_WorkspaceURL`. Returns `actualJobID`. |

---

## 8. Error Handling & Retry Policies

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
PENDING → IN PROGRESS → SUCCESS / FAILED
```

- `run.StartProcess` transitions the item to **IN PROGRESS** (sets `ProcessStartDate`)
- On child pipeline success: status is set to **SUCCESS**
- On child pipeline failure: status is set to **FAILED**
- `run.ProcessFinalise` persists the final status and sets `ProcessEndDate` regardless of outcome (fires on **Completed** dependency condition)

### Failure Behavior

- If a process **fails**, the `Finalise Process` activity still runs (dependency condition: `Completed`, not `Succeeded`), ensuring the failure is recorded.
- The `Add Dependencies` activity only runs on **Succeeded**, so downstream processes are not unblocked when a process fails.
- The Until loop continues processing remaining pending items even if individual processes fail — the queue drains until no more items are eligible.
- If status variables are never set (e.g., unrecognized ProcessType), the default value `UNKNOWN/EMPTY` is recorded.

---

## 9. Operational Runbook

### Triggering a Batch

Trigger the **BatchOrchestrator** pipeline with:

| Parameter | Example Value | Notes |
|-----------|---------------|-------|
| `BatchName` | `galahad_demo_batch` | Must match a configured batch in the metadata database |
| `LoadName` | `DailyLoad` | Descriptive name for this execution |

The pipeline will automatically calculate the partition date (yesterday by default), create the load, populate the queue, and process all items.

### Monitoring

1. **ADF Monitor** — Track the BatchOrchestrator run; drill into QueueExecutor and ProcessExecutor child runs for per-item status.
2. **Metadata Database** — Query queue tables to see item statuses, timestamps, and audit data (see queries below).
3. **Databricks** — For INGEST/TRANSFORM processes, the `runPageUrl` in the audit data links directly to the Databricks job run.
4. **Telemetry** — Check `run.Telemetry` for diagnostic messages logged during execution.

#### Useful Monitoring Queries

```sql
-- Check overall load progress
SELECT ProcessStatus, COUNT(*) AS Count
FROM run.ProcessQueue
WHERE LoadID = '<LoadID>'
GROUP BY ProcessStatus;

-- Find stuck or failed processes
SELECT QueueID, ProcessName, ProcessType, ProcessStatus,
       ProcessStartDate, ProcessEndDate, ProcessAuditData
FROM run.ProcessQueue
WHERE LoadID = '<LoadID>'
  AND ProcessStatus IN ('IN PROGRESS', 'FAILED');

-- View the dependency chain for a process
SELECT dag.ProcessID, p.ProcessName, dag.DependentOnProcessID,
       dep.ProcessName AS DependsOnName, dag.DependencyType
FROM Config.ProcessDAG dag
JOIN Config.vProcess p ON p.ProcessID = dag.ProcessID
LEFT JOIN Config.vProcess dep ON dep.ProcessID = dag.DependentOnProcessID
ORDER BY dag.ProcessID;

-- Check telemetry logs for a load
SELECT * FROM run.Telemetry WHERE LoadID = '<LoadID>';
```

### Common Failure Scenarios

| Scenario | Symptoms | Resolution |
|----------|----------|------------|
| Source system unavailable | ExtractController child pipeline fails; process marked FAILED | Check source connectivity (Oracle/SQL). Re-trigger the batch after resolving — `run.InitialiseQueue` should re-queue failed items. |
| Databricks cluster not running | Execute Databricks Job fails | Verify the `cluster_id` in process config is valid and the cluster is available. |
| Unknown ProcessType | Process finalized with `UNKNOWN/EMPTY` status | Check `run.GetProcessMetadata` output for the QueueID — the ProcessType may be misconfigured in the metadata database. |
| Queue never drains | Until loop runs to 12-hour timeout | Check for circular dependencies or processes stuck in `IN PROGRESS` state in the queue table. |
| Environment config failure | All downstream activities fail | Verify the `SetEnvironmentConfig` pipeline is deployed and returns expected output values. |

### Adding a New Source Provider

To add support for a new source system (e.g., SQL Server, PostgreSQL):

1. Create a new extraction pipeline (e.g., `ExtractSQLServerToNova`)
2. Add a new case to the `Extract Type` Switch activity in **ExtractController**
3. Map the contract fields to the new pipeline's parameters
4. Ensure data contracts for the new provider include the correct `system_provider` value
