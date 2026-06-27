# BlastRadiusBench scenarios

Each subdirectory is one Terminal-Bench task: a frozen telemetry window from a cascading
multi-service failure. The model gets the telemetry in `/workdir`; it must write
`/workdir/failure_chain.json` reconstructing the causal chain.

## Scenario layout

```
<scenario>/
  task.toml                     # Terminal-Bench metadata + resource limits
  instruction.md                # the prompt the model sees
  environment/
    Dockerfile                  # python:3.12-slim + jq/grep/awk; COPYs workdir/ into /workdir
    workdir/                    # the telemetry the agent reads
      traces.json               # OTel-ish spans; parent_id links; status OK|ERROR
      metrics.csv               # timestamp,service,metric,value
      logs.ndjson               # {timestamp,service,severity_text,msg,trace_id,...}
      events.json               # k8s-ish events: deploys, OOMKill, eviction, scaling
      service_map.json          # directed dep graph; {from:A,to:B} == A calls B
      patterns.json             # clustered log signatures w/ count + delta + first_seen
      alert.json                # the page that fired (note WHERE it was measured)
      context/
        commits.json            # commits in window: culprit + many distractors
        deploys.json            # deploy events; innocent deploy near onset (decoy)
        flags.json              # feature-flag changes (decoys only in v1)
  solution/
    solve.sh                    # ORACLE: writes the known-correct failure_chain.json
  tests/
    test.sh                     # installs uv+pytest, runs test_outputs.py, writes reward.txt
    test_outputs.py             # the grader (scenario-agnostic; reads ground_truth.json)
    ground_truth.json           # truth — injected ONLY at verification; agent never sees it
```

## The answer the model writes — `/workdir/failure_chain.json`

```json
{
  "origin_service": "orders",
  "propagation_path": [
    {"from": "orders", "to": "checkout"},
    {"from": "checkout", "to": "frontend"}
  ],
  "root_cause": "orders exhausted its DB connection pool ...",
  "blast_radius": ["checkout", "frontend", "api-gateway"]
}
```

- **origin_service** — what failed FIRST. May be a service, or an infrastructure entity
  (a k8s node) when the coupling is shared infra rather than an RPC call.
- **propagation_path** — directed edges of how the fault SPREAD. For an RPC cascade the
  causal direction is **callee → caller** (the slow callee makes the caller back up),
  which is the *reverse* of the request-flow direction. For a shared-infra cascade it is
  **node → co-located pod**.
- **root_cause** — short description of the originating fault.
- **blast_radius** — the downstream victims (degraded only because a dependency failed).

## Ground-truth schema — `tests/ground_truth.json`

| Field | Meaning |
|-------|---------|
| `origin_service` | the one true origin (exact-match scored) |
| `accept_origin_aliases` | optional list of equivalent origin spellings (infra scenarios) |
| `propagation_path` | the true directed causal edges |
| `edge_overlap_threshold` | min directed-edge recall to pass (default 0.6) |
| `root_cause_culprit_sha` / `root_cause_keywords` | the culprit commit + words a correct `root_cause` should mention |
| `blast_radius` | the true victim set |
| `loudest_but_innocent` | the service that pages / is loudest but is NOT the origin |
| `reversed_trap_edge` | (where applicable) the edge a naive reading inverts |

## Scoring

Primary reward is **binary** (pytest pass/fail):

1. `origin_service` correct, AND
2. `propagation_path` directed-edge recall vs the true causal edges ≥ `edge_overlap_threshold`.

The grader also **prints** secondary metrics (never failing the test): blast-radius
Jaccard, a root-cause keyword check, and the **reversed-causality count** — how many of
the model's edges are the inverse of a true causal edge. Inverting an edge (claiming a
downstream victim caused an upstream service) is the failure mode this benchmark exists
to surface.

## The shipped scenarios

10 scenarios total. The first three are the original synthetic microservices-demo
cascades; the remaining seven are **reconstructions of representative production
incidents** — all service, host, queue and commit identifiers are **fictional stand-ins**.
Service names (`olapdb-tso`, `olapdb-server`, `metric-ingestor-1`,
`stream-taskmanager` Flink taskmanager, `workflow-engine`, `ai-agent-svc`, `ai-memory-svc`,
`platform-api`, `http-receiver`, `dashboard-svc`, `log-agent-v1`, `sbom-scanner`), log
signatures (`CnchLock`/`TransactionCoordinator`/FoundationDB timeouts,
`ProvisionedThroughputExceeded`, `ApproximateAgeOfOldestMessage`), k8s event types
(`DiskPressure`, `MemoryPressure`, `PodEviction`, `Unconsolidatable`, `NodeNotReady`,
`DisruptionBlocked`) and nodes (`ip-10-0-x-x.us-east-1`) / NodePools
(`nodepool-olapdb`, `spot`) are realistic but invented.

| Scenario | Difficulty | Origin | The trap |
|----------|-----------|--------|----------|
| `shared-postgres-saturation` | medium | `orders` (DB connection-pool exhaustion) | api-gateway is loudest (8200 errors, the page) but is the LAST victim. Fan-out: `payments` degrades in parallel under `checkout`. |
| `retry-storm-amplification` | hard | `recommendation` (GC stop-the-world pauses) | The observed traffic/CPU spike is on the CALLER `product-page` (retry amplification). Naive reading inverts the edge and blames `product-page`. |
| `noisy-neighbor-node` | hard | `node-7` (memory saturation from a noisy batch job) | Three unrelated services fail at once with NO service-call edge between them. The only link is the shared node — visible in `events.json`, not the call graph. Each victim even has its own decoy commit. |
| `fdb-tso-flink-cascade` | hard | `olapdb-tso` (FoundationDB transaction timeouts in TSO leader-election/CAS) | The PagerDuty page is `FlinkJobUnhealthy` on `stream-taskmanager` — the LAST victim. The Flink alert is a downstream symptom of olapdb/FDB degradation. |
| `backend-connectivity-cascade` | hard | `olapdb-server` (backend write-path connectivity loss) | Latency/5xx alarms are loudest on the `http-receiver` edge; the origin is the backend write path (`olapdb-server-headless` shard capacity removed by Karpenter). |
| `shared-kafka-saturation` | medium | `metric-ingestor-1` (slow consumer) | Reversed-causality trap: `http-receiver` (the caller/edge) shows the traffic+latency spike, but it is backpressure from the downstream slow consumer of `ed-olapdb-mt-1-metric-iq`. |
| `disk-pressure-noisy-neighbor` | hard | `node:ip-10-0-37-88` (node DiskPressure from `log-agent-v1` log-rotation disabled) | Looks like 3 independent incidents — `dashboard-svc`, `log-agent-v1`, `sbom-scanner` (3 namespaces, no call edge). The only link is the shared node in `events.json`. Each victim has its own red herring. |
| `shared-redis-eviction` | medium | `workflow-engine` (readiness/liveness probe misconfig → CrashLoopBackOff) | Dependents alarm loudest with 5xx (`platform-api`); the origin is the restarting service whose app logs are clean (the probe is the fault). |
| `memory-pressure-eviction-cascade` | hard | `node:ip-10-0-37-15` (node MemoryPressure evicts a `olapdb-vw-write` pod) | Query-failure 5xx are loudest on `platform-api`; the chain is node → evicted write VW → `olapdb-server` → platform-api. First edge is shared-infra, then a service cascade. |
| `shared-dynamodb-throttle` | medium | `ai-memory-svc` (DynamoDB `pipeline-states` write-capacity throttling) | Retry amplification makes the caller `ai-agent-svc` loudest (9× call volume, high CPU); the origin is the throttled memory store. |
