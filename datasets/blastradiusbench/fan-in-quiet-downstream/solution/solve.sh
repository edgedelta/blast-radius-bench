#!/bin/bash
# ORACLE solution for fan-in-quiet-downstream. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "feature-flags-svc",
  "propagation_path": [
    {"from": "feature-flags-svc", "to": "checkout"},
    {"from": "feature-flags-svc", "to": "search"},
    {"from": "feature-flags-svc", "to": "profile"}
  ],
  "root_cause": "feature-flags-svc shipped c4f1a9b which reloads a larger ruleset in-process under a global evaluation mutex, causing long stop-the-world gc pauses and lock contention; its Evaluate/GetFlags p99 climbed from ~8ms to >1.4s while still returning status OK, so the three independent callers (checkout, search, profile) that each block on a synchronous flag call at request start blew their client deadlines and returned timeouts/5xx",
  "blast_radius": ["checkout", "search", "profile"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# fan-in-quiet-downstream — failure chain

## Origin
`feature-flags-svc` degraded FIRST. Its leading indicators rise before any caller errors:
gc_pause_ms_max and evaluate_rpc_p99_ms jump at 14:24 (p99 8ms -> 420ms, gc 12ms -> 610ms)
and keep climbing (980ms/1450ms at 14:28, 1430ms/2050ms at 14:32). The service never errors:
error_rate_pct stays 0.0 throughout and every feature-flags-svc span is status OK — only the
duration is elevated. Onset follows its deploy at 14:20 (commit c4f1a9b: reload a 41k-rule set
in-process under a global eval mutex), which produces the stop-the-world gc pauses and lock waits
seen in its WARN logs.

## Propagation (causal direction = slow callee -> blocked caller)
checkout, search, and profile each issue a SYNCHRONOUS GetFlags/Evaluate to feature-flags-svc at
request start (service_map edges). When that call slows past each caller's client deadline they
return timeouts/5xx, all naming feature-flags-svc:
- feature-flags-svc slow -> checkout 504 "deadline exceeded calling feature-flags-svc GetFlags" (errors begin 14:31)
- feature-flags-svc slow -> search 503 "timeout calling feature-flags-svc Evaluate" (14:31:50)
- feature-flags-svc slow -> profile 503 "deadline exceeded calling feature-flags-svc GetFlags" (14:32:20)

The three callers have NO call edges among one another (independent request paths). They share
exactly ONE downstream that degraded first: feature-flags-svc. That co-degradation + single shared
slow dependency is the tell.

## Trap avoided
checkout carries the LOUDEST signal and pages (PD-4488, p99 6.3s / 22% 5xx) because it is the
customer-facing purchase path with the highest RPS. But its errors start at 14:31, seven minutes
after feature-flags-svc's latency began rising at 14:24 — checkout is the outermost/loudest victim,
not the cause. feature-flags-svc is easy to overlook precisely because it never errors and is not
loud; only its latency moved.

## Controls / distractors ruled out
- inventory-svc is ALSO a shared dependency (checkout and recommendations-svc both call it) but it
  stays flat: error_rate ~0.1%, p99 ~96ms throughout. So "everything downstream is down" is wrong;
  the slow shared dependency is specifically feature-flags-svc.
- recommendations-svc errored (HTTP 422 'holiday_v2' weights) and just deployed at 14:31 (v91) —
  a tempting "errored + just shipped" wrong answer — but it is off the flag-eval fan-in, its error
  trend is flat/benign (~1.5%), and no caller errors reference it.
- flags (checkout.express_pay, search.ranking_variant_c) are distractors; the fault is the
  feature-flags-svc code change.

## Blast radius vs root cause
Root cause: feature-flags-svc gc pause / eval-lock contention from the ruleset-reload change.
Blast radius (victims): checkout, search, profile.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
