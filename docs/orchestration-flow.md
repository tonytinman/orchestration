# Nova Framework - Orchestration Flow

## Recursive DAG Processing

The orchestration engine processes a directed acyclic graph (DAG) of data processes through a **recursive queue-drain pattern**. Rather than traversing the DAG in a single pass, it uses a polling loop that repeatedly discovers and executes newly-eligible work until the entire graph is complete.

### How It Works

1. **Seed** — Only root nodes (processes with no upstream dependencies) are placed into the queue at startup.
2. **Execute** — All currently-eligible PENDING items are fetched and run in parallel.
3. **Unlock** — When a process succeeds, its downstream dependents are added to the queue (if all their dependencies are now met).
4. **Repeat** — The loop re-checks for pending items. New items that were unlocked in step 3 are now eligible, so the next wave begins.
5. **Drain** — When no PENDING items remain, the loop exits and the batch is complete.

This means the DAG is not walked top-down in one shot. Instead, each iteration of the loop processes one "wave" of the graph — all items at the current frontier — and the frontier advances as dependencies are satisfied.

```
DAG Example:                          Execution Waves:

    A ──→ C ──→ E                     Wave 1: A, B    (root nodes, no dependencies)
    B ──→ D ──→ F                     Wave 2: C, D    (unlocked by A and B completing)
                                      Wave 3: E, F    (unlocked by C and D completing)
```

---

## Pipeline Interaction Diagram

```mermaid
flowchart TD
    subgraph BATCH["<b>BatchOrchestrator</b>"]
        INIT["Initiate Batch<br/><i>run.InitiateBatch</i>"]
        SEED["Seed Queue with Root Nodes<br/><i>run.InitialiseQueue</i>"]
        CHECK{"Pending<br/>items?"}
        DONE["Batch Complete"]
    end

    subgraph QUEUE["<b>QueueExecutor</b>"]
        FETCH["Fetch All Eligible Items<br/><i>run.GetPendingItems</i>"]
        PAR[/"Parallel ForEach<br/>(all items concurrently)"/]
    end

    subgraph PROC["<b>ProcessExecutor</b> <i>(one per queue item)</i>"]
        START["Mark IN PROGRESS<br/><i>run.StartProcess</i>"]
        META["Get Process Metadata<br/><i>run.GetProcessMetadata</i>"]
        SWITCH{"Process<br/>Type?"}
        UNLOCK["Enqueue Dependents<br/><i>run.AddDependenciesToQueue</i>"]
        FINAL["Finalise Process<br/><i>run.ProcessFinalise</i>"]
    end

    subgraph EXTRACT_PATH["<b>EXTRACT Path</b>"]
        CONTRACT["Load Data Contract<br/><i>from Blob Storage</i>"]
        PROVIDER{"Source<br/>Provider?"}
        ORACLE["ExtractOracleToNova<br/><i>Oracle → Blob</i>"]
        FUTURE_SRC["Future Providers<br/><i>(extensible switch)</i>"]
    end

    subgraph DATABRICKS_PATH["<b>DATABRICKS Path</b><br/><i>(INGEST + TRANSFORM)</i>"]
        DBCONFIG["Get Job Config<br/><i>run.GetIngestProcessConfig</i>"]
        DBJOBID["Resolve Job ID<br/><i>GetDatabricksJobID</i>"]
        DBJOB["Execute Databricks Job"]
    end

    %% Batch flow
    INIT --> SEED --> CHECK
    CHECK -- "Yes" --> FETCH
    CHECK -- "No" --> DONE

    %% Queue flow
    FETCH --> PAR
    PAR --> START

    %% Process flow
    START --> META --> SWITCH

    %% Conditional branches
    SWITCH -- "EXTRACT" --> CONTRACT
    SWITCH -- "INGEST / TRANSFORM" --> DBCONFIG

    %% Extract sub-flow
    CONTRACT --> PROVIDER
    PROVIDER -- "ORACLE" --> ORACLE
    PROVIDER -. "other" .-> FUTURE_SRC

    %% Databricks sub-flow
    DBCONFIG --> DBJOBID --> DBJOB

    %% Convergence: both paths feed into finalisation
    ORACLE --> UNLOCK
    DBJOB --> UNLOCK
    UNLOCK --> FINAL

    %% The recursive feedback loop
    FINAL -- "loop back" --> CHECK

    %% Styling
    classDef batchStyle fill:#2374ab,color:#fff,stroke:#1a5a8a
    classDef queueStyle fill:#4a90d9,color:#fff,stroke:#2374ab
    classDef procStyle fill:#f5a623,color:#fff,stroke:#c47d10
    classDef extractStyle fill:#7b68ee,color:#fff,stroke:#5a4fcf
    classDef dbricksStyle fill:#ff6b35,color:#fff,stroke:#cc5229
    classDef decisionStyle fill:#fff,color:#333,stroke:#333
    classDef doneStyle fill:#2ecc71,color:#fff,stroke:#27ae60

    class INIT,SEED batchStyle
    class FETCH,PAR queueStyle
    class START,META,UNLOCK,FINAL procStyle
    class CONTRACT,ORACLE,FUTURE_SRC extractStyle
    class DBCONFIG,DBJOBID,DBJOB dbricksStyle
    class CHECK,SWITCH,PROVIDER decisionStyle
    class DONE doneStyle
```

---

## The Recursive Feedback Loop

The diagram above shows a linear flow, but the critical insight is the **feedback loop** between `ProcessExecutor` and `BatchOrchestrator`. Here is that loop isolated:

```mermaid
flowchart LR
    A["<b>BatchOrchestrator</b><br/>Any PENDING items?"] -- "Yes" --> B["<b>QueueExecutor</b><br/>Fetch & fan out"]
    B --> C["<b>ProcessExecutor</b> ×N<br/>Execute in parallel"]
    C --> D["<b>AddDependenciesToQueue</b><br/>Unlock next wave"]
    D -- "new PENDING<br/>items added" --> A

    style A fill:#2374ab,color:#fff
    style B fill:#4a90d9,color:#fff
    style C fill:#f5a623,color:#fff
    style D fill:#e74c3c,color:#fff
```

Each cycle through this loop processes one **wave** of the DAG:

| Loop Iteration | What Happens |
|---------------|-------------|
| **Wave 1** | Root nodes (no dependencies) are executed. On success, their direct dependents are enqueued. |
| **Wave 2** | Newly-eligible processes (whose dependencies were satisfied in Wave 1) are executed. Their dependents are enqueued. |
| **Wave N** | Continues until the queue is fully drained — all leaf nodes have completed. |

The loop terminates when `run.IsQueuePending` returns `0`, meaning every reachable node in the DAG has been processed.

---

## Conditional Execution Paths

The `ProcessExecutor` routes each queue item to the appropriate execution path based on its `ProcessType`. The routing is a two-level conditional:

```mermaid
flowchart TD
    Q["Queue Item"] --> PT{"ProcessType?"}

    PT -- "EXTRACT" --> EC["<b>ExtractController</b>"]
    PT -- "INGEST" --> DB["<b>Databricks Job</b>"]
    PT -- "TRANSFORM" --> DB

    EC --> SP{"Source Provider?<br/><i>(from data contract)</i>"}
    SP -- "ORACLE" --> ORA["ExtractOracleToNova<br/><i>Oracle DB → Azure Blob</i>"]
    SP -. "future" .-> OTHER["Additional Providers<br/><i>(extensible)</i>"]

    DB --> RESOLVE["Resolve Databricks Job ID<br/><i>job name → job ID</i>"]
    RESOLVE --> EXEC["Execute Databricks Job"]

    ORA --> AUDIT_E["Capture audit data<br/><i>from extract pipeline</i>"]
    EXEC --> AUDIT_D["Capture audit data<br/><i>runPageUrl from Databricks</i>"]

    AUDIT_E --> FIN["<b>Finalise</b><br/>SUCCESS / FAILED"]
    AUDIT_D --> FIN

    style PT fill:#fff,stroke:#333,color:#333
    style SP fill:#fff,stroke:#333,color:#333
    style EC fill:#7b68ee,color:#fff
    style ORA fill:#7b68ee,color:#fff
    style OTHER fill:#7b68ee,color:#fff,stroke-dasharray: 5 5
    style DB fill:#ff6b35,color:#fff
    style RESOLVE fill:#ff6b35,color:#fff
    style EXEC fill:#ff6b35,color:#fff
    style AUDIT_E fill:#7b68ee,color:#fff
    style AUDIT_D fill:#ff6b35,color:#fff
    style FIN fill:#2ecc71,color:#fff
```

**Key points:**

- **INGEST and TRANSFORM both route to Databricks** — the switch expression normalises both to the `DATABRICKS` case. The difference is in the job parameters: TRANSFORM processes receive an empty `source_ref` since they don't depend on a specific extract output.
- **EXTRACT routes through a second switch** on the data contract's `system_provider` field, making source systems pluggable. Currently only `ORACLE` is implemented.
- **Both paths converge** on the same finalisation logic — status is set to `SUCCESS` or `FAILED`, audit data is captured, and `run.ProcessFinalise` records the outcome.
- **Both paths feed into dependency resolution** — on success, `run.AddDependenciesToQueue` enqueues the next wave regardless of which execution path was taken.

---

## DAG Dependency Resolution

The dependency system uses `Config.ProcessDAG` to define a directed acyclic graph. Here is how it resolves across the execution lifecycle:

```mermaid
flowchart TD
    subgraph CONFIG["Configuration Time"]
        DAG["Config.ProcessDAG<br/><i>defines the full DAG</i>"]
    end

    subgraph WAVE1["Wave 1 — Initialisation"]
        IQ["run.InitialiseQueue"]
        ROOT["Root nodes → PENDING<br/><i>(DependentOnProcessID IS NULL)</i>"]
        IQ --> ROOT
    end

    subgraph WAVE2["Wave 2..N — Runtime"]
        EXEC2["Process completes<br/>with SUCCESS"]
        ADD["run.AddDependenciesToQueue<br/><i>finds children in ProcessDAG</i>"]
        DEDUP{"Already<br/>in queue?"}
        ENQ["Enqueue dependent → PENDING<br/><i>TriggerQueueID = parent QueueID</i>"]
        SKIP["Skip<br/><i>(deduplication guard)</i>"]
    end

    subgraph RESOLVE["Eligibility Check"]
        GP["run.GetPendingItems"]
        DEP_CHECK{"All dependencies<br/>satisfied?"}
        READY["Return as eligible"]
        WAIT["Remains PENDING<br/><i>(checked again next wave)</i>"]
    end

    DAG --> IQ
    DAG --> ADD

    ROOT --> GP
    EXEC2 --> ADD
    ADD --> DEDUP
    DEDUP -- "No" --> ENQ
    DEDUP -- "Yes" --> SKIP
    ENQ --> GP

    GP --> DEP_CHECK
    DEP_CHECK -- "Yes" --> READY
    DEP_CHECK -- "No" --> WAIT

    style CONFIG fill:#f0f0f0,stroke:#999
    style WAVE1 fill:#e8f4fd,stroke:#2374ab
    style WAVE2 fill:#fef3e0,stroke:#f5a623
    style RESOLVE fill:#e8f8e8,stroke:#2ecc71
```

**Multi-dependency handling:** A process can depend on multiple upstream processes. `GetPendingItems` only returns it when **all** dependencies are satisfied (each upstream process has reached the required `DependencyType` status). If only some are met, the item stays PENDING and is re-evaluated on the next loop iteration.
