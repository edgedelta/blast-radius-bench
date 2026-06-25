#!/bin/bash
# ORACLE solution for db-pool-cascade. Writes the known-correct failure chain.
# Used to validate the grader (this answer must pass tests/test_outputs.py).
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "orders",
  "propagation_path": [
    {"from": "orders", "to": "checkout"},
    {"from": "checkout", "to": "frontend"},
    {"from": "frontend", "to": "api-gateway"},
    {"from": "checkout", "to": "payments"}
  ],
  "root_cause": "orders (commit a1b9f02) holds a postgres connection across the enrichment call, exhausting its DB connection pool (50/50 in use); requests time out waiting for a connection and the timeouts back up the call chain",
  "blast_radius": ["checkout", "frontend", "api-gateway", "payments"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# db-pool-cascade — failure chain

## Origin
`orders` failed first. The earliest abnormal signal is at 13:57:50 ("db pool acquire
slow: waited 410ms") and a hard error at 13:59:30 ("timeout acquiring db connection
from pool, in_use=50 max=50"). At 13:58 orders db_pool_in_use already = 44/50 and p99
= 310ms while every other service is still at baseline. orders was deployed at 13:43
(commit a1b9f02, "hold conn across enrichment call") — onset follows that deploy.

## Propagation (causal direction = callee → caller)
- orders saturates its pool -> checkout's calls to orders time out (checkout ERROR at
  14:01:55) => orders -> checkout
- checkout returns 504 to frontend (14:03:03) => checkout -> frontend
- frontend returns 504 to api-gateway (14:03:03) => frontend -> api-gateway
- checkout also fans out to payments; payments requests are cancelled by checkout's
  deadline (14:02:05) => checkout -> payments (parallel sibling of orders)

## Traps avoided
- api-gateway has the HIGHEST error count (8200/5m) and is what paged, but it is the
  LAST victim — its errors start at 14:03, minutes after orders.
- frontend deployed at 14:00:30 right at onset (decoy); search deployed v77 and flipped
  parser_v2 flag (decoy) — search stayed healthy throughout.
- checkout's timeout bump (b7710e3, 800ms->3s) amplifies the backup but is not the
  origin.

## Blast radius vs root cause
Root cause: orders DB connection-pool exhaustion. Blast radius (victims): checkout,
frontend, api-gateway, payments. search is unaffected.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
