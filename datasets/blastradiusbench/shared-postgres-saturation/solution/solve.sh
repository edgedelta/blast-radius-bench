#!/bin/bash
# ORACLE solution for shared-postgres-saturation. Writes the known-correct failure chain.
# Used to validate the grader (this answer must pass tests/test_outputs.py).
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "pg:orders-db-shared",
  "propagation_path": [
    {"from": "pg:orders-db-shared", "to": "orders"},
    {"from": "pg:orders-db-shared", "to": "billing"},
    {"from": "pg:orders-db-shared", "to": "fulfillment"}
  ],
  "root_cause": "The reporting job (commit 9c2e71a) ran an un-indexed full-table-scan rollup against the shared Postgres instance orders-db-shared, each session holding a connection until active_connections hit max_connections (200/200); Postgres then returned 'FATAL: too many connections / remaining connection slots are reserved', so the three co-tenant services orders, billing and fulfillment could not acquire a connection. The coupling is the shared database, not any service call.",
  "blast_radius": ["orders", "billing", "fulfillment"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# shared-postgres-saturation — failure chain

## Origin (shared resource, not a service)
The origin is the **shared Postgres instance `orders-db-shared`** reaching its
`max_connections` limit. Timeline (earliest signals first):
- 13:43 reporting deployed (commit 9c2e71a) with a rewritten rollup query.
- 13:52-13:56 reporting logs show a `SELECT * ... JOIN line_items` seq scan on
  orders-db-shared holding connections; reporting.db_conns_held climbs 38 -> 93 -> 121.
- 13:58:10 `orders-db-shared active_connections=200 of max_connections=200`
  (DatabaseAlert event) — this is the FIRST hard fault and it is resource-level.
- 14:00:05 / 14:00:33 / 14:00:58 orders, billing, fulfillment each begin emitting
  `FATAL: too many connections to orders-db-shared`.

## Why it is NOT three independent incidents and NOT a service cascade
orders (ns commerce), billing (ns finance) and fulfillment (ns logistics) fail within
the same ~1-minute window but share NO service-call edge: service_map.json has no edge
among them — the only thing the three have in common is `orders-db-shared` in their
`datastores`. Each victim has its own tempting recent commit, but those touch logging /
rounding / unrelated paths. A reader chasing per-service logs would "explain" each
separately and miss the common resource.

## Propagation (shared-resource coupling, fan-out)
- orders-db-shared at max_connections -> orders cannot get a session (14:00:05)
  => pg:orders-db-shared -> orders
- orders-db-shared at max_connections -> billing cannot get a session (14:00:33)
  => pg:orders-db-shared -> billing
- orders-db-shared at max_connections -> fulfillment cannot get a session (14:00:58)
  => pg:orders-db-shared -> fulfillment

## Traps avoided
- orders paged and is loudest (6100 errors/5m) but is just one co-tenant victim.
- frontend deployed at 14:01:30 (commit 7af31c2) right after onset and emits 404s from
  the express_banner flag rollout — benign, flat trend, and frontend is NOT on
  orders-db-shared.
- search (own Elasticsearch search-es) and api-gateway (no datastore) stay healthy,
  proving the fault is scoped to the shared Postgres, not global.
- flags are decoys.

## Blast radius vs root cause
Root cause: shared Postgres `orders-db-shared` connection exhaustion driven by the
reporting full-table-scan job. Blast radius (victims): orders, billing, fulfillment.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
