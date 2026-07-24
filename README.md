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

**Graded reward (reporting only, never gates pass/fail):** `0.0` for either cardinal
sin — naming a blast-radius victim as the origin, or inverting any causal edge;
`0.5 + 0.5 × edge-recall` when the origin is right (partial chains earn partial credit);
`0.25 × blast-radius Jaccard` when the origin is wrong but sane. The grader emits it per
trial (`BLASTRADIUSBENCH_METRICS` stdout line + `verifier/metrics.json`) and the
leaderboard ranks on **mean graded reward ± 95% CI** — on a benchmark this hard, the
difference between "right origin, half the chain" and "blamed the loudest victim" is
exactly what a binary verdict throws away.

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

Seventeen scenarios. Three are synthetic microservices-demo cascades; the remaining
fourteen are **reconstructions of representative production incidents** — realistic
service names, log signatures, k8s event types and node identifiers, all **fictional
stand-ins** (see the [dataset README](datasets/blastradiusbench/README.md)). In every
scenario the loudest, paging service is innocent — the origin hides upstream, on a
shared node, or in a shared backing resource.

| Scenario | Tier | Origin | Why it's hard |
|----------|------|--------|---------------|
| `cdn-origin-overload` | easy | `origin-web` CPU saturation | Sanity check: cdn-edge pages but simply relays its slow origin; one hop, clearly visible. |
| `shared-postgres-saturation` | hard | `pg:orders-db-shared` pool exhaustion | The edge gateway is loudest and pages, but is the last victim; the cascade fans out into a small tree, not a line. |
| `shared-kafka-saturation` | hard | `kafka:ingest-shared` slow consumer backpressure | The edge `http-receiver` shows the traffic+latency spike, but it is backpressure from a downstream slow queue consumer. Reversed-causality trap. |
| `shared-redis-eviction` | hard | `redis:session-cache-01` eviction storm | Dependents page loudest with 5xx; the shared cache quietly evicts under memory pressure. |
| `mid-chain-cache-origin` | medium | `price-cache` hit-ratio collapse | A cache-key format change mid-chain; both its caller and its backing DB look guilty, the cache itself looks like plumbing. |
| `grpc-deadline-chain` | medium | `pricing-svc` slow dependency | Deadline expirations surface at `mobile-bff`, four hops from the deepest service that actually slowed down. |
| `fan-in-quiet-downstream` | medium | `feature-flags-svc` lock contention | Dozens of callers fan into one quiet config service; every caller looks broken, the origin's own dashboards look calm. |
| `dual-independent-incidents` | medium | `payments-db` pool saturation | Two unrelated incidents in one window: the loud, just-deployed `analytics-worker` belongs to the other one. Conflate them and fail. |
| `retry-storm-amplification` | hard | `recommendation` GC pauses | Aggressive client retries put the *observed* load spike on the caller `product-page`; the true origin is the slow downstream. Classic reversed-causality trap. |
| `noisy-neighbor-node` | hard | `node-7` memory saturation | Three unrelated services fail simultaneously with no call edge between them; the only link is the shared node, visible only in infra events. |
| `fdb-tso-flink-cascade` | hard | `olapdb-tso` FoundationDB transaction timeouts | The loud `FlinkJobUnhealthy` page on `stream-taskmanager` is the last victim; the origin is the Timestamp Oracle's FDB leader-election/CAS timeouts four hops upstream. |
| `backend-connectivity-cascade` | hard | `olapdb-server` write-path connectivity loss | The loudest latency/5xx is at the `http-receiver` edge; the origin is the backend whose write shard lost capacity. |
| `disk-pressure-noisy-neighbor` | hard | `node:ip-10-0-37-88` DiskPressure | Three unrelated services in three namespaces evicted at once; the only link is the shared node, and each victim has its own red herring. |
| `memory-pressure-eviction-cascade` | hard | `node:ip-10-0-37-15` MemoryPressure | Query-failure 5xx loudest on `platform-api`; the chain starts with a node eviction of a `olapdb-vw-write` pod, then a service cascade. |
| `shared-dynamodb-throttle` | hard | `ddb:pipeline-states` DynamoDB throttling | Retry amplification makes the *caller* `ai-agent-svc` look like the epicenter; the origin is the throttled DynamoDB-backed memory store. |
| `shared-dns-resolver-degradation` | hard | `dns:coredns-cluster` resolver degradation | Every service's outbound calls degrade at once; the coupling is the cluster resolver, not any call edge. |
| `shared-nat-egress-saturation` | hard | `net:nat-gw-az1` SNAT port exhaustion | Only internet-bound calls fail, across unrelated services; the shared NAT gateway never appears in the service graph's call edges. |

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

Frozen run (v2): **17 scenarios x 23 models x 3 attempts = 1173 trials**, Harbor `terminus-2` over OpenRouter, 2026-07-08/10/23/24, all agents at an 1800s timeout. Models are ranked on **mean graded reward** (0.0 for either cardinal sin; 0.5 + 0.5 × edge-recall for a correct origin; 0.25 × blast-radius Jaccard otherwise; ± 95% CI over the 51 trials), with binary pass rates alongside. Four trials that died to infra errors (`AgentTimeoutError`, `BadRequestError`) were re-run per methodology — all four passed on retry. Full per-trial results (outcome, graded reward, cost, tokens, timing per model) + rollups are committed under [`benchmark-results/`](benchmark-results/).

> v1 → v2: raises the agent timeout 600s → 1800s (v1 cost glm-5.2 and kimi-k2.5 one
> trial each and gpt-oss-20b nine as `AgentTimeoutError`), adds sakana/fugu-ultra and
> anthropic/claude-fable-5, and captures per-trial graded rewards. On this, the hardest
> of the three benches, the top five are a statistical tie — their graded-reward CIs
> overlap almost entirely — and single-scenario flips move a 51-trial pass rate by
> ±4–6 points, which is exactly why the leaderboard now ranks on the graded mean.

| Model | Mean graded reward (95% CI) | Pass rate | easy | medium | hard |
|---|---|---|---|---|---|
| glm-5.2 | **0.679 ± 0.116** | 59% | 100% | 83% | 47% |
| fugu-ultra | **0.675 ± 0.116** | 61% | 100% | 100% | 44% |
| gpt-5.5 | **0.672 ± 0.117** | 61% | 100% | 100% | 44% |
| gpt-5.6-sol | **0.655 ± 0.118** | 57% | 100% | 75% | 47% |
| gemini-3.1-pro-preview | **0.653 ± 0.123** | 59% | 100% | 58% | 56% |
| claude-fable-5 | **0.637 ± 0.120** | 57% | 100% | 83% | 44% |
| gpt-5.4 | **0.632 ± 0.123** | 57% | 100% | 75% | 47% |
| gpt-5.4-mini | **0.626 ± 0.120** | 53% | 67% | 75% | 44% |
| claude-opus-5 | **0.603 ± 0.121** | 53% | 100% | 75% | 39% |
| grok-4.5 | **0.602 ± 0.122** | 53% | 100% | 75% | 42% |
| claude-sonnet-4.6 | **0.587 ± 0.125** | 53% | 100% | 58% | 47% |
| claude-opus-4.8 | **0.562 ± 0.120** | 47% | 100% | 75% | 33% |
| kimi-k3 | **0.556 ± 0.119** | 45% | 100% | 67% | 33% |
| gemini-3.5-flash | **0.554 ± 0.123** | 47% | 100% | 58% | 39% |
| deepseek-v4-flash | **0.548 ± 0.116** | 41% | 100% | 67% | 28% |
| gemini-3.1-flash-lite | **0.542 ± 0.116** | 37% | 100% | 67% | 22% |
| qwen3-235b-a22b-2507 | **0.496 ± 0.126** | 41% | 67% | 58% | 33% |
| kimi-k2-thinking | **0.494 ± 0.121** | 39% | 33% | 50% | 36% |
| kimi-k2.5 | **0.464 ± 0.123** | 39% | 33% | 50% | 36% |
| gpt-oss-120b | **0.339 ± 0.125** | 29% | 67% | 42% | 22% |
| qwen3-32b | **0.301 ± 0.113** | 20% | 0% | 25% | 19% |
| claude-haiku-4.5 | **0.262 ± 0.111** | 22% | 0% | 42% | 17% |
| gpt-oss-20b | **0.049 ± 0.057** | 4% | 33% | 0% | 3% |

## Baselines: can a script reconstruct the chain?

A benchmark whose chain falls out of the service graph measures nothing. Five
deterministic, non-LLM baselines answer every scenario from the data the agent sees
(alert + service map) and are scored with the grader's exact rules
([`scripts/run_baselines.py`](scripts/run_baselines.py); per-scenario results in
[`benchmark-results/blastradiusbench/baselines.json`](benchmark-results/blastradiusbench/baselines.json)):

| Baseline | Policy | Pass rate | Blamed a victim | Reversed edges |
|---|---|---|---|---|
| `loudest-service` | origin = the paging service | 0/17 | **17/17** | — |
| `first-service` | alphabetically first service | 0/17 | 8/17 | — |
| `blame-datastore` | the pager's backing datastore | 1/17 | 10/17 | — |
| `deep-walk` | walk call edges to the deepest dependency, path in causal direction | 3/17 | 5/17 | 1 |
| `request-flow-path` | same walk, path in request direction | 0/17 | 5/17 | **10/17** |

Three takeaways:

- **The loudest service is never the origin.** Blaming the paging service commits the
  victim-as-origin cardinal sin in **17 of 17 scenarios** — the benchmark's central
  claim, verified mechanically.
- **Arrow direction is the discriminator.** The identical dependency walk passes 3
  scenarios with causal arrows and zero with request-flow arrows, inverting edges in 10
  — the reversed-causality trap catches any policy that confuses "A calls B" with
  "A broke B".
- **Known soft spots.** `deep-walk` recovers the full chain in 3 scenarios and
  `blame-datastore` solves the easy one — there the topology alone gives the answer.
  CI warns on each; candidates for added graph branches in a future data revision.

CI ([`oracle-check`](.github/workflows/oracle-check.yml)) enforces on every push: every
scenario's oracle matches ground truth exactly and passes its own grader, ground-truth
structure is internally consistent (origin never a victim, no reversed or duplicate
truth edges), and no degenerate baseline passes any scenario.

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
