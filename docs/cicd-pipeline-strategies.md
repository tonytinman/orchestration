# CI/CD Pipeline Strategies

## Overview

NovaFlow uses three Azure DevOps pipelines to manage the lifecycle of the orchestration platform. Each pipeline has a distinct responsibility:

| Pipeline | File | Trigger | Purpose |
|----------|------|---------|---------|
| **PR Checks** | `pr-checks.yml` | Pull request to `main` | Validates metadata CSVs before merge |
| **Metadata Deploy** | `orchestration-meta-deploy.yaml` | Push to `main` | Loads CSV metadata into the database and rebuilds config |
| **Schema Deploy** | `deployment.yml` | Manual | Deploys database schema changes via DACPAC |

These pipelines form a two-track deployment model: one track for **metadata** (what to process) and one track for **schema** (the database structure that holds it).

```
                         Pull Request
                              │
                    ┌─────────▼──────────┐
                    │   PR Checks        │
                    │   (pr-checks.yml)  │
                    │                    │
                    │  Validate CSVs     │
                    │  with Python       │
                    └─────────┬──────────┘
                              │ pass
                              ▼
                         Merge to main
                              │
              ┌───────────────┼────────────────┐
              ▼                                ▼
 ┌────────────────────────┐      ┌──────────────────────────┐
 │  Metadata Deploy       │      │  Schema Deploy           │
 │  (orchestration-meta-  │      │  (deployment.yml)        │
 │   deploy.yaml)         │      │                          │
 │                        │      │  Manual trigger only     │
 │  Auto-trigger on main  │      │                          │
 │                        │      │  DACPAC dryrun → publish │
 │  CSV → stg → Config    │      │  Tables, views, SPs     │
 └────────────────────────┘      └──────────────────────────┘
              │                                │
              ▼                                ▼
      Orchestration metadata            Database schema
      (what to process)                 (structure that holds it)
```

---

## 1. PR Checks Pipeline

> **File:** `azure-pipelines/pr-checks.yml`
> **Trigger:** Automatically on pull requests targeting `main`
> **Pool:** `ubuntu-latest` (Microsoft-hosted)

### Purpose

Validates orchestration metadata CSV files before they can be merged. This is the quality gate that prevents malformed or inconsistent configuration from reaching the database.

### Pipeline Flow

```
PR opened/updated against main
        │
        ▼
┌──────────────────────────────┐
│ 1. Install Python            │
│    pip install -r             │
│    tools/validator/           │
│    requirements.txt           │
├──────────────────────────────┤
│ 2. Run CSV validator         │
│    python3 validate_metadata │
│    --csv-dir orchestration-  │
│    metadata                  │
├──────────────────────────────┤
│ 3. Pass / Fail               │
│    Blocks merge on failure   │
└──────────────────────────────┘
```

### What It Validates

The `validate_metadata.py` script runs against the CSV files in `orchestration-metadata/`:
- `process.csv`
- `processDAG.csv`
- `ADBCluster.csv`

Validation catches issues such as missing required fields, invalid references between files, and structural errors — before they can propagate to the staging tables and onward to config.

### Principles

- **Shift left.** Errors are caught at PR time, not at deploy time. A broken CSV never reaches the database.
- **Lightweight and fast.** Runs on a Microsoft-hosted agent with no infrastructure dependencies — just Python and the CSV files.
- **Non-blocking for unrelated changes.** Only triggers on PRs to `main`, so feature branch work is unaffected.

---

## 2. Metadata Deploy Pipeline

> **File:** `azure-pipelines/orchestration-meta-deploy.yaml`
> **Trigger:** Automatically on push to `main`
> **Pool:** `vmss-dev-ado-uks-01` (self-hosted)

### Purpose

Loads orchestration metadata from CSV files into the Azure SQL staging tables, then executes the rebuild process that synchronises the `Config` schema. This is the pipeline that makes metadata changes live.

### Pipeline Flow

```
Push to main
    │
    ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. Authenticate                                              │
│    Azure CLI → AAD access token for Azure SQL                │
├──────────────────────────────────────────────────────────────┤
│ 2. For each CSV mapping:                                     │
│                                                              │
│    process.csv      → TRUNCATE stg.Process    → BULK LOAD   │
│    processDAG.csv   → TRUNCATE stg.ProcessDAG → BULK LOAD   │
│    ADBCluster.csv   → TRUNCATE stg.ADBCluster → BULK LOAD   │
│                                                              │
│    Uses SqlBulkCopy (batch size: 10,000)                     │
│    Continues to next table if one fails                      │
├──────────────────────────────────────────────────────────────┤
│ 3. If ALL loads succeeded:                                   │
│    EXEC stg.RebuildConfig @Environment = '<env>'             │
│                                                              │
│    Internally calls (in order):                              │
│      stg.RebuildBatch                                        │
│      stg.RebuildProcessGroup                                 │
│      stg.RebuildBatchProcessGroup                            │
│      stg.RebuildProcess                                      │
│      stg.RebuildProcessDAG                                   │
│      stg.RebuildADBCluster @Environment                      │
│                                                              │
│    Each MERGE writes changes to the audit schema             │
├──────────────────────────────────────────────────────────────┤
│ 4. If ANY load failed:                                       │
│    Skip rebuild, exit with error                             │
└──────────────────────────────────────────────────────────────┘
```

### Configuration

| Variable | Value | Description |
|----------|-------|-------------|
| `SqlServer` | `sql-edp-dev-nova-uks-01.database.windows.net` | Target Azure SQL server |
| `SqlDatabase` | `CLUKNova_Meta_Dev` | Target metadata database |
| `environmentName` | `dev` | Environment name (drives cluster ID selection) |
| `serviceConnection` | `cluk-az-dev-azdo-databricks` | Azure DevOps service connection for AAD auth |
| `PostLoadStoredProc` | `stg.RebuildConfig` | Stored procedure to execute after CSV load |

### CSV-to-Table Mapping

| CSV File | Staging Table |
|----------|---------------|
| `orchestration-metadata/process.csv` | `stg.Process` |
| `orchestration-metadata/processDAG.csv` | `stg.ProcessDAG` |
| `orchestration-metadata/ADBCluster.csv` | `stg.ADBCluster` |

### Authentication

The pipeline uses AAD token-based authentication:
1. The `AzureCLI@2` task authenticates using the Azure DevOps service connection
2. An access token is acquired via `az account get-access-token --resource https://database.windows.net`
3. The token is attached to every `SqlConnection` via the `AccessToken` property

No SQL credentials are stored in the pipeline or variables.

### Error Handling

| Scenario | Behaviour |
|----------|-----------|
| CSV file not found | Error logged, continues to next table |
| CSV has zero rows | Warning logged, table skipped |
| Bulk load fails | Error logged, continues to next table |
| Any table load fails | `stg.RebuildConfig` is **skipped** entirely, pipeline exits with error |
| Rebuild stored proc fails | Error logged, pipeline exits with error |

The rebuild is only executed when **all** staging loads succeed. This prevents a partial load from producing an inconsistent config state.

### Principles

- **Truncate-and-reload.** Staging tables are truncated before each load. The CSVs represent the complete desired state, not incremental changes. This makes the pipeline idempotent — running it twice with the same CSVs produces the same result.
- **All-or-nothing rebuild.** The rebuild only fires if every CSV loaded successfully. A failure in any one table skips the entire config synchronisation, leaving the existing config intact.
- **Self-hosted agent.** Runs on `vmss-dev-ado-uks-01` which has network access to the Azure SQL server. This is required for the bulk copy operation.
- **Environment-parameterised.** The `environmentName` variable drives cluster ID resolution during `RebuildADBCluster`. To deploy to a different environment, only the variables need to change.

---

## 3. Schema Deploy Pipeline

> **File:** `azure-pipelines/deployment.yml`
> **Trigger:** Manual only (`trigger: none`)
> **Pool:** `vmss-dev-ado-uks-01` (self-hosted)

### Purpose

Deploys database schema changes (tables, views, stored procedures, constraints) to the metadata database using a DACPAC. This pipeline manages the structure of the database, while the metadata deploy pipeline manages the data within it.

### Pipeline Flow

The pipeline has two stages with a deployment gate between them:

```
Manual trigger
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│ Stage 1: DACPAC Dryrun                                          │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ 1. Build DACPAC                                         │    │
│  │    dotnet build sql/nova_metadata -c Release             │    │
│  ├─────────────────────────────────────────────────────────┤    │
│  │ 2. Install sqlpackage                                    │    │
│  ├─────────────────────────────────────────────────────────┤    │
│  │ 3. Assert DACPAC exists                                  │    │
│  ├─────────────────────────────────────────────────────────┤    │
│  │ 4. Generate DeployReport (XML)                           │    │
│  │    sqlpackage /Action:DeployReport                       │    │
│  │      /p:DropObjectsNotInSource=true                      │    │
│  │      /p:BlockOnPossibleDataLoss=true                     │    │
│  ├─────────────────────────────────────────────────────────┤    │
│  │ 5. Generate deploy script (SQL)                          │    │
│  │    sqlpackage /Action:Script                             │    │
│  │      /p:DropObjectsNotInSource=true                      │    │
│  │      /p:BlockOnPossibleDataLoss=true                     │    │
│  ├─────────────────────────────────────────────────────────┤    │
│  │ 6. Preview summary                                       │    │
│  │    Count CREATE / ALTER / DROP statements                │    │
│  │    Show first 150 lines of deploy.sql                    │    │
│  ├─────────────────────────────────────────────────────────┤    │
│  │ 7. Publish DACPAC artifact                               │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
└─────────────────────────────┬───────────────────────────────────┘
                              │
                    Environment gate
                    (dev_framework)
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Stage 2: Publish DACPAC                                         │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ 1. Install sqlpackage                                    │    │
│  ├─────────────────────────────────────────────────────────┤    │
│  │ 2. Download DACPAC artifact from Stage 1                 │    │
│  ├─────────────────────────────────────────────────────────┤    │
│  │ 3. Assert DACPAC exists                                  │    │
│  ├─────────────────────────────────────────────────────────┤    │
│  │ 4. Publish to database                                   │    │
│  │    sqlpackage /Action:Publish                            │    │
│  │      /p:DropObjectsNotInSource=false                     │    │
│  │      /p:BlockOnPossibleDataLoss=true                     │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Configuration

| Variable | Value | Description |
|----------|-------|-------------|
| `PROJECT_DIR` | `sql/nova_metadata` | Path to the SQL project |
| `DACPAC_PATH` | `sql/nova_metadata/bin/Release/nova_metadata.dacpac` | Build output path |
| `server` | `sql-edp-dev-nova-uks-01.database.windows.net` | Target Azure SQL server |
| `database` | `CLUKNova_Meta_Dev` | Target metadata database |
| `serviceConnection` | `cluk-az-dev-azdo-databricks` | Azure DevOps service connection |

### Dryrun vs Publish Behaviour

The two stages use different sqlpackage settings to provide a safety net:

| Setting | Dryrun (Stage 1) | Publish (Stage 2) |
|---------|------------------|-------------------|
| Action | `DeployReport` + `Script` | `Publish` |
| `DropObjectsNotInSource` | `true` | `false` |
| `BlockOnPossibleDataLoss` | `true` | `true` |
| Output | XML report + SQL script + summary | Applied to database |

The dryrun uses `DropObjectsNotInSource=true` to show the **full picture** of what would change, including objects that would be dropped. The publish uses `DropObjectsNotInSource=false` as a safety measure — it will not drop objects that exist in the database but not in the DACPAC. This prevents accidental removal of objects managed outside the SQL project.

### Dryrun Preview

The dryrun stage generates a human-readable summary:

```
## DACPAC preview for CLUKNova_Meta_Dev @ sql-edp-dev-nova-uks-01.database.windows.net

- **Creates:** 3   **Alters:** 12   **Drops:** 0

### First 150 lines of deploy.sql
```sql
...
```

This gives reviewers a clear view of the impact before approving the publish stage.

### Environment Gate

The publish stage uses an Azure DevOps **environment** (`dev_framework`) with a `deployment` job and `runOnce` strategy. This provides:

- **Approval gates** — the environment can be configured with manual approvals before the publish proceeds
- **Deployment history** — Azure DevOps tracks every deployment to the environment
- **Rollback visibility** — if a publish causes issues, the history shows exactly what was deployed and when

### Artifact Flow

The DACPAC is built once and reused across stages:

1. Stage 1 builds the DACPAC and publishes it as a pipeline artifact (`dacpac_preview`)
2. Stage 2 downloads the same artifact — it does not rebuild

This ensures the exact same binary that was previewed is what gets published.

### Principles

- **Preview before apply.** The dryrun stage generates a full deployment report and SQL script before any changes are made. Teams can review the exact CREATE/ALTER/DROP statements that will execute.
- **Manual trigger only.** Schema changes are deliberate, not automatic. Unlike metadata deploys (which trigger on every push to main), schema deploys require an explicit decision.
- **Build once, deploy the same artifact.** The DACPAC is built in the dryrun stage and passed to the publish stage as an artifact. There is no second build, eliminating the risk of a different binary being published than what was previewed.
- **Conservative publish settings.** The publish stage uses `DropObjectsNotInSource=false`, meaning it will add and modify objects but never drop existing ones. Combined with `BlockOnPossibleDataLoss=true`, this prevents both accidental object removal and data-destructive changes.
- **Gated deployment.** The `dev_framework` environment gate between stages provides an approval checkpoint and deployment audit trail.

---

## Pipeline Interaction Model

The three pipelines operate independently but form a coherent deployment workflow:

```
Developer workflow:

  1. Edit CSV files and/or SQL project
  2. Open pull request
         │
         ├── pr-checks.yml validates CSVs automatically
         │
  3. Merge to main
         │
         ├── orchestration-meta-deploy.yaml fires automatically
         │   (loads CSVs → rebuilds config)
         │
  4. If schema changes needed:
         │
         └── deployment.yml triggered manually
             (dryrun → approve → publish DACPAC)
```

### Ordering Considerations

| Change Type | Pipeline(s) Involved | Ordering |
|------------|---------------------|----------|
| New processes or DAG changes | PR Checks → Metadata Deploy | Automatic. Merge triggers deploy. |
| New cluster mappings | PR Checks → Metadata Deploy | Automatic. Same as above. |
| New table or column | Schema Deploy → Metadata Deploy | Schema first. The new column must exist before metadata can populate it. |
| New stored procedure | Schema Deploy | Schema only. No metadata change needed. |
| Rename a column | Schema Deploy → Metadata Deploy | Schema first. Deploy the renamed column, then update the CSVs to reference it. |

When both schema and metadata changes are needed, deploy the schema first, then trigger the metadata deploy (or let it run on the next push to main).
