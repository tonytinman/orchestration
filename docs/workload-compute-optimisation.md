# Workload Compute Optimisation

## Overview

NovaFlow allows each process group to be aligned to a specific Databricks cluster. At runtime, every INGEST and TRANSFORM process executes on the cluster assigned to its process group. This enables workloads to be matched to compute configurations that are optimised for their specific characteristics — whether that is high-volume data movement, parallel transformation, or cost-efficient lightweight processing.

The mapping is defined once in a CSV file, resolved per environment at deploy time, and consumed transparently at runtime. No pipeline changes are required to reassign a workload to different compute.

---

## How It Works

### The Mapping Chain

A process group's cluster assignment flows through four layers, from authored configuration to runtime execution:

```
 ADBCluster.csv                stg.ADBCluster              Config.ADBCluster
┌─────────────────────┐      ┌──────────────────┐       ┌───────────────────┐
│ ProcessGroupName    │      │ ProcessGroupName │       │ ProcessGroupName  │
│ dev_cluster_id      │─CSV──│ dev_cluster_id   │─MERGE─│ cluster_id        │
│ ccd_cluster_id      │ load │ ccd_cluster_id   │       │ (env-specific)    │
│ pre_cluster_id      │      │ pre_cluster_id   │       └─────────┬─────────┘
│ prd_cluster_id      │      │ prd_cluster_id   │                 │
└─────────────────────┘      └──────────────────┘                 │
                                                                  │ joined at runtime
                                                                  ▼
                                                     run.GetIngestProcessConfig
                                                     ┌───────────────────────┐
                                                     │ ProcessQueue          │
                                                     │   → config.Process    │
                                                     │   → config.ProcessGroup│
                                                     │   → config.ADBCluster │
                                                     │                       │
                                                     │ Returns: cluster_id   │
                                                     └───────────┬───────────┘
                                                                 │
                                                                 ▼
                                                     ProcessExecutor (ADF)
                                                     ┌───────────────────────┐
                                                     │ Databricks Activity   │
                                                     │  LinkedService param: │
                                                     │   ExistingClusterID   │
                                                     │  Job param:           │
                                                     │   cluster_id          │
                                                     └───────────────────────┘
```

### Step by Step

**1. Define cluster mappings (author time)**

Engineers maintain `ADBCluster.csv` in the repository. Each row maps a process group to a cluster ID in every environment:

```
ProcessGroupName,dev_cluster_id,ccd_cluster_id,pre_cluster_id,prd_cluster_id
sales_extract,0101-abc123,0201-def456,0301-ghi789,0401-jkl012
finance_transform,0102-mno345,0202-pqr678,0302-stu901,0402-vwx234
lightweight_ingest,0101-abc123,0201-def456,0301-ghi789,0401-jkl012
```

Different process groups can share the same cluster, or each can have its own.

**2. Deploy with environment selection (deploy time)**

When the CI/CD pipeline runs `stg.RebuildADBCluster(@Environment)`, it selects the correct cluster ID column for the target environment using dynamic SQL:

| @Environment | Column Selected |
|-------------|----------------|
| `dev` | `dev_cluster_id` |
| `ccd` | `ccd_cluster_id` |
| `pre` | `pre_cluster_id` |
| `prd` | `prd_cluster_id` |

The MERGE writes only the resolved `(ProcessGroupName, cluster_id)` pair into `Config.ADBCluster`. The runtime engine never sees the other environments' cluster IDs.

**3. Resolve cluster at runtime (execution time)**

When a DATABRICKS process executes, the `run.GetIngestProcessConfig` stored procedure resolves the cluster:

```
run.ProcessQueue (current item)
    → config.Process (get ProcessID)
    → config.ProcessGroup (get ProcessGroupName)
    → config.ADBCluster (get cluster_id by ProcessGroupName)
```

The resolved `cluster_id` is returned alongside the job configuration.

**4. Execute on the target cluster (ADF activity)**

The ProcessExecutor passes the `cluster_id` to the Databricks activity in two places:

- **Linked service parameter** `ExistingClusterID` — tells the Databricks linked service which cluster to connect to
- **Job parameter** `cluster_id` — passed to the Databricks job itself, allowing the notebook to reference its own compute context

---

## Principles of Operation

### 1. Process group is the unit of compute alignment

The mapping is between a **process group** and a cluster — not between individual processes and clusters. All processes within a process group run on the same cluster. This is deliberate: a process group represents a cohesive workload (e.g., "all finance ingests"), and aligning it to a single cluster simplifies resource planning and avoids fragmentation.

### 2. Cluster configuration is externalised from pipeline logic

The ADF pipelines contain no hardcoded cluster IDs. The cluster is resolved dynamically at runtime from metadata. To move a workload to a different cluster, you update the CSV and redeploy — the pipelines remain unchanged. This separation means compute decisions are made by operations teams, not embedded in pipeline code.

### 3. Environment-specific resolution enables right-sizing per tier

Each environment can use a different cluster for the same process group. A workload might use a small, cost-efficient cluster in dev, a moderately sized cluster in pre-prod, and a large, high-throughput cluster in production. The CSV captures all four mappings in a single row; the deploy process selects the right one.

### 4. Shared clusters enable cost consolidation

Multiple process groups can map to the same cluster ID. Lightweight workloads that don't need dedicated compute can share a common cluster, reducing idle capacity and cost. The mapping is flexible — groups can be split onto separate clusters or consolidated onto shared ones as needs change.

### 5. Cluster changes are audited

Every change to `Config.ADBCluster` — whether a new mapping, an updated cluster ID, or a removed group — is recorded in `audit.ADBCluster` with the before/after values and a timestamp. This provides a full history of when compute assignments changed and what they changed from.

---

## Optimisation Strategies

The process group to cluster mapping enables several optimisation patterns:

### Optimise for Volume

Process groups that handle large data volumes (e.g., full table extracts from high-row-count sources) can be assigned to clusters with:
- More worker nodes for higher parallelism
- Larger instance types for more memory per node
- Autoscaling enabled with a high maximum worker count

```
ProcessGroupName          cluster (prd)
─────────────────         ──────────────────────
high_volume_extract  →    Large cluster (8-32 workers, memory-optimised)
```

### Optimise for Parallelism

Process groups containing many independent processes that run concurrently within a wave can be assigned to clusters sized for parallel throughput:
- More worker nodes to handle concurrent tasks
- Spark configurations tuned for task-level parallelism

```
ProcessGroupName          cluster (prd)
─────────────────         ──────────────────────
parallel_transforms  →    Wide cluster (16+ workers, compute-optimised)
```

### Optimise for Cost

Process groups with lightweight or infrequent workloads can share a small, always-on cluster or use a cluster with aggressive autoscaling down to zero:

```
ProcessGroupName          cluster (prd)
─────────────────         ──────────────────────
reference_data_ingest →   Shared small cluster (2-4 workers)
lookup_transforms    →    Shared small cluster (same cluster ID)
```

### Isolate for SLA

Process groups with strict SLA requirements can be assigned dedicated clusters to avoid resource contention with other workloads:

```
ProcessGroupName          cluster (prd)
─────────────────         ──────────────────────
regulatory_reporting →    Dedicated cluster (guaranteed resources)
```

### Tier by Environment

The same workload can use progressively larger clusters as it moves through environments:

```
ProcessGroupName: sales_daily_ingest
    dev →  Small cluster  (2 workers, minimal cost)
    ccd →  Medium cluster (4 workers, integration testing)
    pre →  Large cluster  (8 workers, performance validation)
    prd →  Large cluster  (16 workers, production throughput)
```

---

## Configuration Reference

### CSV Format (`ADBCluster.csv`)

| Column | Type | Description |
|--------|------|-------------|
| `ProcessGroupName` | string | Must match a process group name defined in `process.csv` |
| `dev_cluster_id` | string | Databricks cluster ID for the dev environment |
| `ccd_cluster_id` | string | Databricks cluster ID for the CCD environment |
| `pre_cluster_id` | string | Databricks cluster ID for the pre-production environment |
| `prd_cluster_id` | string | Databricks cluster ID for the production environment |

### Runtime Resolution (`run.GetIngestProcessConfig`)

The stored procedure joins through the following path to resolve `cluster_id`:

```sql
FROM run.ProcessQueue AS q1                    -- current queue item
LEFT JOIN config.Process AS p                  -- process definition
    ON p.ProcessID = q1.ProcessID
LEFT JOIN config.ProcessGroup AS pg            -- process group
    ON pg.ProcessGroupID = p.ProcessGroupID
LEFT JOIN config.ADBCluster AS ac              -- cluster mapping
    ON ac.ProcessGroupName = pg.ProcessGroupName
```

### ADF Consumption (`ProcessExecutor`)

The resolved `cluster_id` is used in the Databricks activity:

| Usage | Parameter | Value Source |
|-------|-----------|-------------|
| Linked service connection | `ExistingClusterID` | `activity('Get IngestProcessConfig').output.firstRow.cluster_id` |
| Job parameter | `cluster_id` | `activity('Get IngestProcessConfig').output.firstRow.cluster_id` |
