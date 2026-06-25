#!/bin/bash
# ORACLE solution for retry-storm-amplification. Writes the known-correct failure chain.
# Used to validate the grader (this answer must pass tests/test_outputs.py).
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "recommendation",
  "propagation_path": [
    {"from": "recommendation", "to": "product-page"},
    {"from": "product-page", "to": "api-edge"}
  ],
  "root_cause": "recommendation (commit 9f3c1aa) batch-loads the full candidate slice per request, blowing up the heap and triggering multi-second stop-the-world GC pauses; product-page's calls to recommendation time out and its aggressive retries amplify outbound load",
  "blast_radius": ["product-page", "api-edge"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# retry-storm-amplification — failure chain

## Origin
`recommendation` failed first. Earliest abnormal signal: 09:05:40 WARN "GC pause 480ms
(heap_used_mb=1510 batch_size=18400)", escalating to stop-the-world stalls at 09:07:10
(920ms) and 09:09–09:14 (2.1–3.4s). recommendation gc_pause_ms and heap_used_mb climb
first while catalog stays flat. recommendation deployed 08:37 (commit 9f3c1aa, "batch-load
all candidate items into one slice") — onset follows that deploy. redis-cache, its
dependency, stays fast (6ms MGET): the fault is internal GC, not a downstream of reco.

## The trap (reversed causality)
The page fired on `product-page`: outbound request rate to recommendation spiked 4x
(290 -> 1180 rps) and CPU hit 95%. Naive reading: "product-page is hammering
recommendation, product-page is the problem." WRONG. product-page's spike is its retry
budget (3 retries, 200ms deadline) firing against a slow callee — retry_count goes
3 -> 9800. The amplified traffic lives on product-page but is a SYMPTOM. The causal edge
is recommendation -> product-page, NOT product-page -> recommendation.

## Propagation (callee -> caller)
- recommendation GC stalls -> product-page reco calls time out and exhaust retries
  (09:07:30 onward) => recommendation -> product-page
- product-page returns 503 to api-edge (09:11:03) => product-page -> api-edge

## Distractors avoided
- 2bb90c4 (product-page retry budget 1 -> 3) AMPLIFIES the storm but is not the origin;
  it only converts a slow dependency into a load multiplier.
- flags product-page.aggressive_retry and reco.personalized_ranking are decoys (v1: code
  changes only).
- catalog (a07fe22, nightly facets) stays healthy throughout.

## Blast radius vs root cause
Root cause: recommendation GC pauses from unbounded per-request batch load. Blast radius
(victims): product-page, api-edge. catalog and redis-cache unaffected.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
