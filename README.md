# BlastRadiusBench

### Can AI reconstruct the failure chain?

When five services are on fire at once, the junior on-call lists what is burning. The
senior asks one question: **what lit it, and in what order?** BlastRadiusBench measures
whether a frontier LLM can do the senior's job — separate the **root cause** from the
**blast radius**, recover the *directed* path the failure took service-to-service, and
resist the gravitational pull of the loudest alarm.

It is a neutral, fully-open benchmark of **the models**, not of any vendor's product.
Every model gets identical data and identical tools. We measure the reasoning.

---

## The question

A cascading incident hands you traces, metrics, logs, k8s events, and a service
dependency graph. Somewhere in there:

- one service failed **first** (the origin),
- its failure **propagated** along call edges — but in causal terms a slow *callee* backs
  up its *caller*, so the propagation runs **opposite** to the request flow,
- the service that **pages** is usually the **last** victim at the edge, not the source,
- and sometimes the coupling is not a call at all but a **shared node** that took down
  unrelated neighbors.

Can the model reconstruct the chain — or does it blame the loudest box and invert the
arrows?

## What the benchmark measures

The model writes `/workdir/failure_chain.json`:

```json
{
  "origin_service": "<failed first>",
  "propagation_path": [{"from": "<svc>", "to": "<svc>"}],
  "root_cause": "<the originating fault>",
  "blast_radius": ["<downstream victim>", "..."]
}
```

**Primary reward (binary):** `origin_service` is correct **AND** the `propagation_path`
recovers enough of the true *directed* causal edges (edge-recall ≥ a per-scenario
threshold, default 0.6).

**Secondary (printed, never gates the score):**

- **blast-radius overlap** vs truth,
- a **root-cause keyword** check (did it name the fault, or just a symptom?),
- the **reversed-causality count** — how many edges the model *inverted* (claimed a
  downstream victim caused an upstream service). This inversion is the single most
  diagnostic error in incident reasoning, so we surface it explicitly.

## How it works

BlastRadiusBench ships **tasks + datasets + scoring only**. It runs on the external
[Harbor](https://harborframework.com) harness using the
[Terminal-Bench](https://www.tbench.ai/) task format with the default `terminus-2` agent.
Each scenario is a sandboxed Docker container with the telemetry mounted at `/workdir`
and standard CLI tools (`jq`, `grep`, `awk`, `python3`). The agent investigates, writes
its answer, and a pytest grader scores it. Models are swapped via
[OpenRouter](https://openrouter.ai/), so the comparison is apples-to-apples.

> If you query telemetry like this in Edge Delta you would use **CQL** — field equality
> (`severity_text:"ERROR"`), boolean AND/OR, numeric comparisons (`@latency_ms > 1000`).
> In the sandbox you grep/jq the raw files; the reasoning is identical.

## Task format

Each task under [`datasets/blastradiusbench/<scenario>/`](datasets/blastradiusbench)
contains `task.toml`, `instruction.md`, `environment/` (Dockerfile + `workdir/` data),
`solution/solve.sh` (the oracle), and `tests/` (the grader + hidden ground truth). See
[the dataset README](datasets/blastradiusbench/README.md) for the full schema.

## Difficulty tiers

10 scenarios. The first three are synthetic microservices-demo cascades; the remaining
seven are **reconstructions of representative production incidents** — realistic service
names, log signatures, k8s event types and node identifiers, all **fictional stand-ins**
(see the [dataset README](datasets/blastradiusbench/README.md)).

| Scenario | Tier | Origin | Why it's hard |
|----------|------|--------|---------------|
| `db-pool-cascade` | medium | `orders` DB connection-pool exhaustion | The edge gateway is loudest and pages, but is the last victim; the cascade fans out into a small tree, not a line. |
| `retry-storm-amplification` | hard | `recommendation` GC pauses | Aggressive client retries put the *observed* load spike on the caller `product-page`; the true origin is the slow downstream. Classic reversed-causality trap. |
| `noisy-neighbor-node` | hard | `node-7` memory saturation | Three unrelated services fail simultaneously with no call edge between them; the only link is the shared node, visible only in infra events. |
| `fdb-tso-flink-cascade` | hard | `olapdb-tso` FoundationDB transaction timeouts | The loud `FlinkJobUnhealthy` page on `stream-taskmanager` is the last victim; the origin is the Timestamp Oracle's FDB leader-election/CAS timeouts four hops upstream. |
| `backend-connectivity-cascade` | hard | `olapdb-server` write-path connectivity loss | The loudest latency/5xx is at the `http-receiver` edge; the origin is the backend whose write shard lost capacity. |
| `queue-backlog-ingestion-cascade` | medium | `metric-ingestor-1` slow consumer | The edge `http-receiver` shows the traffic+latency spike, but it is backpressure from a downstream slow queue consumer. Reversed-causality trap. |
| `disk-pressure-noisy-neighbor` | hard | `node:ip-10-0-37-88` DiskPressure | Three unrelated services in three namespaces evicted at once; the only link is the shared node, and each victim has its own red herring. |
| `probe-crashloop-cascade` | medium | `workflow-engine` probe misconfig (CrashLoopBackOff) | Dependents page loudest with 5xx; the origin's app logs are clean — the kubelet is killing it on a misconfigured probe. |
| `memory-pressure-eviction-cascade` | hard | `node:ip-10-0-37-15` MemoryPressure | Query-failure 5xx loudest on `platform-api`; the chain starts with a node eviction of a `olapdb-vw-write` pod, then a service cascade. |
| `dynamodb-capacity-degradation` | medium | `ai-memory-svc` DynamoDB throttling | Retry amplification makes the *caller* `ai-agent-svc` look like the epicenter; the origin is the throttled DynamoDB-backed memory store. |

## Running it

```bash
# 1. Build/clone, then set keys.
git clone https://github.com/edgedelta/blast-radius-bench.git && cd blast-radius-bench
cp .env.example .env   # add OPENROUTER_API_KEY=...

# 2. Smoke test: one model, one scenario.
source .env && uv run harbor run -c configs/smoke-docker.yaml

# 3. Full run: all scenarios × several models × 3 attempts.
source .env && uv run harbor run -c configs/all-models-docker.yaml

# 4. Summarize into a markdown leaderboard.
uv run scripts/process_results.py jobs/<timestamp>
```

You can also point any agentic CLI (Claude Code, Codex, Cursor) at a scenario's `/workdir`
and have it write `failure_chain.json`, then run the scenario's `tests/test_outputs.py`.

## Leaderboard

> ⚠️ **Illustrative placeholder numbers — run it yourself.** The table below is synthetic
> and exists to show the shape of the result, not to rank anyone. We have not frozen an
> official run. Honesty is the product: if your model does badly here, that is a finding,
> not a bug.

| Model | Origin accuracy | Path edge-overlap | Reversed-edge rate \* |
|-------|----------------:|------------------:|----------------------:|
| claude-opus-4.6        | 0.78 | 0.71 | 0.14 |
| gpt-5.2-codex          | 0.72 | 0.66 | 0.19 |
| gemini-3-pro-preview   | 0.69 | 0.61 | 0.22 |
| kimi-k2.5              | 0.56 | 0.48 | 0.31 |

\* *Illustrative.* Origin accuracy = fraction of scenarios with the right `origin_service`.
Path edge-overlap = mean directed-edge recall vs truth. Reversed-edge rate = fraction of
emitted edges that invert a true causal edge (lower is better). All numbers synthetic —
clone the repo and generate your own.

## How scenarios are generated

Scenarios come from two sources. The original three are **fault injection on a real
microservices app**. The other seven are **reconstructions of representative production
incidents** — the service names, log/event signatures, queue names, node identifiers and
commit SHAs are **fictional stand-ins**, but the failure classes are realistic
(FoundationDB/TSO transaction timeouts, OLAP-store backend connectivity loss, SQS queue
backlog, node DiskPressure/MemoryPressure evictions, probe-misconfig CrashLoopBackOff,
DynamoDB write-capacity throttling) so the telemetry reads as authentic. Both follow the
same methodology:

1. Run a microservices demo (e.g. the OpenTelemetry Astronomy Shop) under steady load.
2. Pin every service to a git commit; pick one commit as the **culprit** and inject a
   realistic fault tied to that code change (shrink a DB pool, add an unbounded in-memory
   batch, drop a memory limit on a co-located job).
3. Let the cascade develop; record a ~10-15 minute telemetry window spanning
   baseline → onset → escalation.
4. Downsample to a few KB so the agent can read everything, keeping the buried first
   signal among innocent noise.
5. Assemble the context: the real commit list (culprit **plus distractors**), deploy
   events (with an **innocent deploy placed at onset** to punish "blame the latest
   change"), and feature-flag changes (decoys — v1 root causes are always code changes).
6. Hand-label `ground_truth.json` (origin, directed edges, root cause + culprit sha,
   blast radius) and keep it out of the agent's container.

## Building your own scenarios

```bash
uv run tools/generate_scenario.py my-scenario \
  --services api,web,svc,db --origin svc --difficulty hard --distractors 4
```

This scaffolds a fully-wired scenario (all six task files + placeholder telemetry +
ground truth) that already passes its own oracle, so you can validate the harness, then
replace `environment/workdir/` with a real frozen telemetry window. The generator
documents the full fault-injection methodology in its header.

## Why we built this

Edge Delta builds AI for on-call engineers, so we care a lot about whether models can
actually reason about *causality* in distributed systems rather than pattern-matching the
loudest alert. BlastRadiusBench is our attempt to measure that honestly, in the open, on
neutral ground. More at [edgedelta.com](https://edgedelta.com).

## License

Apache-2.0. See [LICENSE](LICENSE). Copyright Edge Delta, Inc.
