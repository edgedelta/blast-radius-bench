# Reconstruct the failure chain

A cascading, multi-service incident is in progress. You are the on-call SRE. A page
fired and several services are throwing errors at once. Your job is **not** to list
what is on fire — it is to reconstruct *what lit it, and in what order*.

You must determine:
1. **origin_service** — the service that failed FIRST (the true source of the cascade).
2. **propagation_path** — the ordered, directed edges describing how the failure
   spread service-to-service (e.g. `{"from": "A", "to": "B"}` meaning A's failure
   caused/propagated into B). This may be a small tree, not a single line, if the
   failure fanned out.
3. **root_cause** — a short description of the originating fault.
4. **blast_radius** — the set of downstream services that became victims (degraded
   only because something they depend on failed), as distinct from the origin.

## Data available in `/workdir`

| File | What it is |
|------|------------|
| `traces.json` | Sampled OTel spans across services. `parent_id` links spans; `status` is OK/ERROR. Span start times and the depth of the erroring span tell you where a request *first* failed. |
| `metrics.csv` | `timestamp,service,metric,value`. Per-service latency, error rate, and resource gauges across a baseline + incident window. |
| `logs.ndjson` | Structured log records (`timestamp`, `service`, `severity_text`, `msg`, `trace_id`). The first error signal is buried among healthy noise. |
| `events.json` | Cluster/infra events (deploys, probe failures, scaling, evictions, OOMKills). |
| `service_map.json` | The directed dependency graph. An edge `{from: A, to: B}` means **A calls B**. |
| `alert.json` | The page that fired. Note *where* it was measured. |
| `context/commits.json` | Code commits in the window (sha, author, message, files_changed). Contains the culprit plus many plausible distractors. |
| `context/deploys.json` | Deploy events. An innocent deploy may sit right at incident onset. |
| `context/flags.json` | Feature-flag changes near the window. In this benchmark, **flags are distractors** — the root cause is always a code change. |

## Tools

Standard CLI is available: `jq`, `grep`, `awk`, `sort`, `python3`. The data is small
enough to read directly. If you were querying this in Edge Delta you would use **CQL**
(field equality like `severity_text:"ERROR"`, boolean AND/OR, numeric comparisons like
`@latency_ms > 1000`); here you can grep/jq the raw files.

## Rules

- Do NOT blame the loudest service. The service with the highest error count or the one
  that paged is frequently the *last* victim at the edge, not the origin.
- Causality flows along call edges, but **only in the direction a caller waits on a
  callee**. If A calls B and B is slow, A backs up — the failure propagates B→A in
  causal terms even though the request flowed A→B. Get this direction right.
- Use earliest-error timing (logs, span timestamps, metric onset) to find the origin,
  not peak magnitude.
- Beware retry amplification: a caller that retries a slow dependency will show a large
  *outbound request-rate spike* and high CPU. That observed load lives on the CALLER, but
  it is a SYMPTOM of a slow CALLEE. The caller is not the origin just because it is where
  the traffic spike is measured. Look for `retry_count` and per-attempt spans.
- Distinguish the ROOT CAUSE (one originating fault) from the BLAST RADIUS (downstream
  victims). A victim is not a cause.
- Do not speculate. If a service is degraded but you cannot tie it to the cascade via a
  call edge or a shared dependency, leave it out rather than inventing an edge.

## Output

Write your machine-checkable answer to **`/workdir/failure_chain.json`**:

```json
{
  "origin_service": "<service that failed first>",
  "propagation_path": [
    {"from": "<svc>", "to": "<svc>"}
  ],
  "root_cause": "<short description of the originating fault>",
  "blast_radius": ["<downstream victim svc>", "..."]
}
```

Also write your free-form analysis (timeline, evidence, why you ruled out the
distractors) to **`/workdir/reasoning.md`**.

You will be scored primarily on getting `origin_service` right AND recovering enough of
the true directed propagation edges. Inverting an edge (claiming a downstream victim
caused an upstream service) is the failure mode we most want to catch.
