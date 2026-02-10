# NovaFlow Orchestration - Overview

## Introduction

NovaFlow Orchestration is a metadata-driven batch processing engine built on Azure Data Factory (ADF). It extracts data from source systems, ingests it into a data lake, and transforms it via Azure Databricks — all governed by configuration stored in an Azure SQL metadata database.

The system is composed of three pillars:

1. **Orchestration Metadata** — the configuration that defines *what* to process and in *what order*
2. **Metadata Management** — the pipeline that keeps that configuration current via CSV-driven CI/CD
3. **Batch Execution** — the ADF engine that reads the metadata and executes the work

```
┌────────────────────────────────────────────────────────────────────┐
│                     NovaFlow Orchestration                         │
│                                                                    │
│   ┌──────────────┐    ┌──────────────────┐    ┌────────────────┐  │
│   │  Orchestration│    │    Metadata      │    │    Batch       │  │
│   │   Metadata    │◄───│   Management    │    │   Execution    │  │
│   │              │    │                  │    │                │  │
│   │  Config DB   │    │  CSV → stg →     │    │  ADF Pipelines │  │
│   │  (what to    │    │  Config (CI/CD)  │    │  (how to       │  │
│   │   process)   │────┼──────────────────┼───►│   process)     │  │
│   └──────────────┘    └──────────────────┘    └────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

---

## 1. Orchestration Metadata

### Purpose

Orchestration metadata is the single source of truth that tells the engine *what* processes exist, *how* they relate to each other, and *where* they run. It is stored in the `Config` schema of the Azure SQL metadata database and is never edited directly — it is always rebuilt from staging data (see [Metadata Management](#2-metadata-management)).

### What It Defines

| Concept | Config Table | Description |
|---------|-------------|-------------|
| **Batches** | `Config.Batch` | Named groupings of work (e.g., `galahad_demo_batch`). A batch is the top-level unit that a user triggers. |
| **Process Groups** | `Config.ProcessGroup` | Logical groupings of processes within a batch. Maps to a Databricks cluster and controls parallel execution scope. |
| **Batch-to-Group Mapping** | `Config.BatchProcessGroup` | Links batches to their process groups with an `Active` flag, allowing groups to be toggled on/off without deletion. |
| **Processes** | `Config.Process` / `Config.vProcess` | Individual units of work: an extract, an ingest, or a transform. Each has a type, a data contract, and optionally a Databricks notebook name. |
| **Process DAG** | `Config.ProcessDAG` | The directed acyclic graph of dependencies between processes. Defines execution order by declaring which process must complete (and with what status) before another can start. |
| **Cluster Mapping** | `Config.ADBCluster` | Maps each process group to a Databricks cluster ID, enabling environment-specific compute routing. |

### Principles of Operation

1. **Declarative, not imperative.** The metadata describes *what* should happen, not *how*. The ADF engine interprets it at runtime. To change what runs, you change the metadata — not the pipelines.

2. **DAG-driven ordering.** Process execution order is entirely determined by `Config.ProcessDAG`. A process with no entry (or a NULL `DependentOnProcessID`) is a root node and runs immediately. A process that depends on another only runs after the dependency reaches the required status. This allows complex multi-stage workflows to be expressed as simple rows in a table.

3. **Configuration is normalised.** The `Config` schema uses surrogate keys (`ProcessID`, `BatchID`, `ProcessGroupID`) and referential relationships. This is deliberate — normalised config is efficient for the runtime engine to query, and the `stg` → `Config` rebuild process handles the ID resolution automatically.

4. **Active flags control scope without deletion.** Processes and process groups have `Active` flags. Setting `Active = 0` excludes them from execution without removing them from the configuration, making it safe to temporarily disable work.

5. **Environment-agnostic process definitions.** Processes are defined once. Environment-specific values (server names, cluster IDs, storage accounts) are resolved at runtime via `SetEnvironmentConfig` and `Config.ADBCluster`, allowing the same metadata to drive dev, pre-prod, and production.

### Entity Model

```
Config.Batch
    │
    1:N
    ▼
Config.BatchProcessGroup ──N:1──► Config.ProcessGroup ──1:N──► Config.ADBCluster
                                        │
                                        1:N
                                        ▼
                                  Config.Process  ──► Config.vProcess (view)
                                        │
                                        1:N
                                        ▼
                                  Config.ProcessDAG
```

---

## 2. Metadata Management

### Purpose

Metadata management is the CI/CD process that keeps the `Config` tables synchronised with a set of human-editable CSV files stored in the repository. It provides a controlled, auditable, and repeatable way to change what the orchestration engine does — without ever editing the database directly.

### How It Works

The metadata lifecycle follows a three-stage pattern: **author → validate → deploy**.

```
 CSV files in repo                Azure SQL Database
┌──────────────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│  process.csv     │     │          │     │          │     │          │
│  processDAG.csv  │────►│   stg    │────►│  Config  │────►│   run    │
│  ADBCluster.csv  │ bulk│  schema  │merge│  schema  │ read│  schema  │
│                  │ load│ (staging)│     │  (config)│     │(runtime) │
└──────────────────┘     └──────────┘     └──────────┘     └──────────┘
         │                                      │
    PR validation                          audit schema
    (pr-checks.yml)                    (change tracking)
```

#### Stage 1 — Author

Engineers edit CSV files in the `orchestration-metadata/` directory:

| CSV File | Target Staging Table | Content |
|----------|---------------------|---------|
| `process.csv` | `stg.Process` | Flat, denormalised process definitions including batch name, process group, type, contract, notebook, and active flag |
| `processDAG.csv` | `stg.ProcessDAG` | Dependencies expressed as process name pairs (not IDs) with a dependency type |
| `ADBCluster.csv` | `stg.ADBCluster` | Process group to cluster ID mapping with per-environment columns (`dev_cluster_id`, `ccd_cluster_id`, `pre_cluster_id`, `prd_cluster_id`) |

The staging tables use **human-readable names** (not surrogate IDs), making the CSVs easy to author and review in pull requests.

#### Stage 2 — Validate

When a pull request is opened against `main`, the `pr-checks.yml` pipeline runs automatically:

1. Installs Python dependencies from `tools/validator/requirements.txt`
2. Executes `validate_metadata.py` against the CSV files
3. The PR is blocked if validation fails

This prevents malformed or inconsistent metadata from reaching the database.

#### Stage 3 — Deploy

When changes are merged to `main`, the `orchestration-meta-deploy.yaml` pipeline triggers:

1. **Truncate** — Each `stg` table is truncated to clear previous state
2. **Bulk Load** — CSV files are loaded into their corresponding `stg` tables via `SqlBulkCopy`
3. **Rebuild** — The `stg.RebuildConfig` stored procedure is executed, which orchestrates the merge in dependency order:

```
stg.RebuildConfig(@Environment)
    ├── stg.RebuildBatch              (stg.Process → Config.Batch)
    ├── stg.RebuildProcessGroup       (stg.Process → Config.ProcessGroup)
    ├── stg.RebuildBatchProcessGroup  (stg.Process → Config.BatchProcessGroup)
    ├── stg.RebuildProcess            (stg.Process → Config.Process)
    ├── stg.RebuildProcessDAG         (stg.ProcessDAG → Config.ProcessDAG)
    └── stg.RebuildADBCluster         (stg.ADBCluster → Config.ADBCluster)
```

Each rebuild procedure uses SQL `MERGE` statements to:
- **INSERT** new rows that exist in staging but not in config
- **UPDATE** existing rows where values have changed
- **DELETE** rows that exist in config but no longer appear in staging

Every MERGE operation writes its changes (inserted and deleted values, timestamp, action taken) to a corresponding `audit` schema table, providing a full change history.

### Principles of Operation

1. **CSV as the source of truth.** The CSV files in the repository are the canonical definition of orchestration metadata. The database is a derived artefact that is rebuilt from them. If the database and CSV files disagree, the CSVs win on the next deploy.

2. **Staging decouples format from schema.** The `stg` tables accept flat, denormalised, name-based data (matching the CSV structure). The `Rebuild` procedures handle normalisation, ID resolution, and referential integrity. This means engineers work with readable names while the runtime engine works with efficient surrogate keys.

3. **Ordered rebuild respects dependencies.** `RebuildConfig` calls the individual rebuild procedures in a specific order — batches and process groups first, then the mappings and processes that reference them, then the DAG that references processes. This ensures foreign keys are always resolvable.

4. **MERGE provides idempotent, audited sync.** Each rebuild is a full reconciliation: new items are added, changed items are updated, removed items are deleted. The `OUTPUT` clause captures every change into the `audit` schema. Running the same CSV data twice produces no changes.

5. **Environment-aware cluster resolution.** `stg.ADBCluster` contains cluster IDs for all environments in separate columns. `RebuildADBCluster` uses the `@Environment` parameter to select the correct column, so the same CSV drives dev, pre-prod, and production with different compute.

6. **Scoped deletes prevent accidental wipes.** `RebuildProcess` scopes its `DELETE` to only process groups present in the current staging load. This prevents a partial CSV (e.g., one that only defines processes for group A) from deleting all processes in group B.

7. **Validation before merge.** The PR checks pipeline validates CSVs before they reach `main`, catching issues like missing required fields, invalid references, or structural errors before they can affect the live database.

### Schema Overview

| Schema | Purpose | Populated By |
|--------|---------|-------------|
| `stg` | Staging tables — flat, name-based, truncated and reloaded each deploy | CI/CD pipeline (CSV bulk load) |
| `Config` | Configuration tables — normalised, ID-based, used by ADF at runtime | `stg.Rebuild*` MERGE procedures |
| `run` | Runtime tables — execution state, queue, load history | ADF pipelines at execution time |
| `audit` | Change tracking — captures every insert, update, delete from MERGE operations | `stg.Rebuild*` MERGE OUTPUT clauses |

---

## 3. Batch Execution

### Purpose

Batch execution is the runtime process where ADF reads the orchestration metadata and executes the configured work. It uses a recursive queue-drain pattern to walk the process DAG wave by wave, executing processes in parallel where dependencies allow.

### How It Works

A batch execution is initiated by triggering the **BatchOrchestrator** pipeline with a `BatchName` and `LoadName`. The engine then:

```
1. INITIALISE                    2. SEED                         3. EXECUTE
┌──────────────────┐            ┌──────────────────┐            ┌──────────────────┐
│ Create Load      │            │ Query the DAG    │            │ Fetch eligible   │
│ record           │───────────►│ for root nodes   │───────────►│ PENDING items    │
│ (run.InitiateBatch)│          │ (no dependencies)│            │ and fan out in   │
│                  │            │                  │            │ parallel         │
│ Copy process     │            │ Insert them into │            │                  │
│ groups to load   │            │ the queue as     │            │ Each item runs   │
│                  │            │ PENDING          │            │ its own          │
│ Register LoadID  │            │ (run.Initialise  │            │ ProcessExecutor  │
│                  │            │  Queue)          │            │                  │
└──────────────────┘            └──────────────────┘            └────────┬─────────┘
                                                                        │
4. UNLOCK                        5. REPEAT                              │
┌──────────────────┐            ┌──────────────────┐                    │
│ On SUCCESS:      │            │ Re-check for     │◄───────────────────┘
│ find downstream  │───────────►│ PENDING items    │
│ dependents in    │            │                  │
│ ProcessDAG       │            │ If found: go to  │──── loop back to step 3
│                  │            │ step 3           │
│ Enqueue them as  │            │                  │
│ new PENDING      │            │ If none: batch   │──── done
│ items            │            │ complete         │
│ (run.AddDepend   │            │                  │
│  enciesToQueue)  │            └──────────────────┘
└──────────────────┘
```

### Process Type Routing

Each process in the queue is routed based on its `ProcessType`:

| ProcessType | Execution Path | Description |
|-------------|---------------|-------------|
| `EXTRACT` | **ExtractController** → source-specific pipeline (e.g., `ExtractOracleToNova`) | Pulls data from a source system into Azure Blob Storage. The source provider (Oracle, etc.) is determined by the data contract. |
| `INGEST` | **Databricks Job** | Runs a Databricks job that ingests extracted data from blob storage into the lakehouse. Receives upstream extract audit data (via `TriggerQueueID`) to locate the source files. |
| `TRANSFORM` | **Databricks Job** | Runs a Databricks job that transforms ingested data. Receives an empty `source_ref` since it operates on already-ingested data. |

### Wave-Based DAG Traversal

The engine does not traverse the DAG in a single pass. Instead, each iteration of the polling loop processes one **wave** — all currently-eligible items at the frontier of the graph:

```
Example DAG:                          Execution:

  Extract_A ──► Ingest_A ──► Transform_A    Wave 1: Extract_A, Extract_B  (roots)
  Extract_B ──► Ingest_B ──► Transform_B    Wave 2: Ingest_A, Ingest_B   (unlocked)
                                             Wave 3: Transform_A, Transform_B (unlocked)
```

Within each wave, all eligible items execute **in parallel** (via the QueueExecutor's ForEach with `isSequential: false`). This maximises throughput while respecting dependency ordering.

### Principles of Operation

1. **Queue as the execution contract.** The `run.ProcessQueue` table is the single runtime record of what has been done, what is in progress, and what remains. Every state transition (PENDING → IN PROGRESS → SUCCESS/FAILED) is recorded with timestamps.

2. **Recursive discovery, not static planning.** The engine does not pre-compute the full execution plan. It discovers work dynamically: after each process succeeds, `AddDependenciesToQueue` checks for newly-eligible dependents and enqueues them. This means the queue grows as the DAG is traversed — processes that are deep in the graph don't appear in the queue until their dependencies are met.

3. **Parallel by default, sequential by dependency.** The ForEach activity runs all eligible items concurrently (up to ADF's limit of 20). Sequential ordering is only enforced where the DAG declares a dependency. If two processes have no dependency relationship, they run in parallel even if they belong to the same batch.

4. **Completion-based finalisation.** The `Finalise Process` activity fires on the ADF **Completed** dependency condition, meaning it runs whether the process succeeded or failed. This guarantees that every process has a recorded outcome. The `Add Dependencies` activity, by contrast, only fires on **Succeeded**, ensuring failed processes do not unlock downstream work.

5. **Audit data flows through the chain.** Each process captures audit data (e.g., extract row counts, Databricks run URLs) and stores it in `ProcessAuditData`. Downstream processes can access their upstream's audit data via the `TriggerQueueID` linkage, enabling ingests to locate the exact files produced by their corresponding extract.

6. **Environment isolation via configuration.** The same pipeline code runs in every environment. All environment-specific values (database servers, storage accounts, Databricks workspace URLs, cluster IDs) are resolved at runtime from `SetEnvironmentConfig` and `Config.ADBCluster`. Promoting a batch from dev to production requires no pipeline changes — only the environment configuration differs.

7. **Idempotent re-execution.** If a batch fails partway through, it can be re-triggered. `InitialiseQueue` seeds only root processes; the Until loop then discovers and executes whatever work remains. Processes that already succeeded are not re-queued (the deduplication guard in `AddDependenciesToQueue` prevents this).
