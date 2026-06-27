#!/bin/bash
# ORACLE solution for dual-independent-incidents. Writes the known-correct failure chain
# for the PAGED incident (the customer-facing checkout 5xx cascade).
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "payments-db",
  "propagation_path": [
    {"from": "payments-db", "to": "payments-svc"},
    {"from": "payments-svc", "to": "checkout"}
  ],
  "root_cause": "payments-db connection pool saturated (active connections reached max_connections after commit c41d9f02 added a synchronous fraud-check query that holds a connection for the full request), so payments-svc could not acquire connections and returned 503, and checkout at the edge returned customer-facing 5xx",
  "blast_radius": ["payments-svc", "checkout"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# dual-independent-incidents — failure chain (paged incident)

## Origin
`payments-db` saturated FIRST on the paged path. Its leading indicator
`pg_active_connections` climbs from baseline ~20 at 14:36, hits the 100
`max_connections` ceiling by 14:40 — strictly BEFORE any victim error.
payments-db spans stay status=OK but slow (acquire/query wait rising); it
emits only WARN saturation lines, no 5xx. Onset follows payments-svc deploy
of commit c41d9f02 (synchronous fraud-check query holding a connection per
request) at 14:34.

## Propagation (causal direction = backend pool -> caller -> edge)
- payments-db pool exhausted -> payments-svc cannot acquire a connection,
  "acquire timeout" / "remaining connection slots reserved", returns 503
  (14:41) => payments-db -> payments-svc
- payments-svc 503s -> checkout edge returns customer-facing 5xx on
  POST /api/checkout (14:44, page fires 14:46) => payments-svc -> checkout

## The parallel (unrelated) incident — NOT in the chain
`analytics-worker` crashloops after deploy v412 at 14:33 and is the LOUDEST
by error count (CrashLoopBackOff, panic on every batch). `analytics-api`
(its only caller) logs 502s. But analytics-* is an internal batch pipeline
with NO service-call edge to payments-svc or checkout and no customer path.
It started loud and just deployed, but it is a separate, self-contained
incident — not the cause of the checkout 5xx. It is neither the origin nor
in the blast radius of the paged incident.

## Distractors ruled out
- analytics-worker deploy v412 / its panics: loud + freshly shipped, but
  off the payments call graph.
- search-svc and notifications-svc stay healthy (controls).

## Blast radius vs root cause
Root cause: payments-db connection pool exhaustion.
Blast radius (victims): payments-svc, checkout.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
