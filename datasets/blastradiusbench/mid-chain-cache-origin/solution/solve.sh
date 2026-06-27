#!/bin/bash
# ORACLE solution for mid-chain-cache-origin. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "price-cache",
  "propagation_path": [
    {"from": "price-cache", "to": "catalog-svc"},
    {"from": "catalog-svc", "to": "api-edge"},
    {"from": "price-cache", "to": "pricing-db"}
  ],
  "root_cause": "price-cache deploy v9f1c5a7 changed the cache key format (added a tenant/currency segment), so warm entries stopped matching and the cache hit ratio collapsed from ~94% to ~6%; every read now misses and falls through to a slow pricing-db lookup, which both backs up catalog-svc and api-edge waiting on cache fills and stampedes pricing-db with miss traffic",
  "blast_radius": ["catalog-svc", "api-edge", "pricing-db"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# mid-chain-cache-origin — failure chain

## Origin
`price-cache` failed FIRST. It is a read-through cache sitting between `catalog-svc`
and `pricing-db` (service_map: catalog-svc -> price-cache -> pricing-db). The earliest
abnormal signal is the cache hit ratio: at 14:22:00 `cache_hit_ratio_pct` falls from a
baseline ~94 to ~38, and to ~6 by 14:24 — strictly BEFORE any victim error rate rises.
This follows the price-cache deploy v9f1c5a7 at 14:20 (commit 9f1c5a7 "rework cache key
to include tenant+currency segment"), which invalidated every warm entry by changing the
key format. price-cache spans stay status OK but its `fill_latency_ms` jumps 6-8x because
every lookup is now a miss that falls through to pricing-db.

## Propagation (causal direction = callee backs up its caller)
- price-cache fills are now slow (every read misses) -> `catalog-svc`, its direct caller,
  blocks waiting on price reads: catalog 5xx/timeouts begin 14:24:40 ("deadline exceeded
  waiting on price-cache read fill") => price-cache -> catalog-svc
- catalog-svc backs up -> `api-edge` at the storefront edge times out fetching product
  pricing and pages at 14:28 (loudest: p99 8.7s, 41% 5xx) => catalog-svc -> api-edge
- price-cache misses stampede the backing store -> `pricing-db` query QPS and active
  connections spike from the miss flood beginning ~14:23 => price-cache -> pricing-db

## Traps avoided
- `api-edge` carries the LOUDEST signal and is where the page fired (it is the customer
  edge where latency is measured), but it is the OUTERMOST victim: its errors start at
  14:27, five minutes after the cache hit-ratio collapse at 14:22.
- `pricing-db` is the DEEPEST component and looks saturated (query_qps and
  active_connections climb sharply), which tempts "deepest + busiest = origin". But
  pricing-db stays status OK with only elevated load and emits no errors — it is being
  stampeded BY the cache misses, it did not initiate the incident. Its load rises AFTER
  the hit-ratio collapse, not before.

## Distractors ruled out
- `inventory-svc` deployed v4d2 at 14:25 (near onset) and threw its own ERROR logs
  (expired upstream TLS cert to a supplier feed). It is on the inventory path, not the
  price read path (no edge to price-cache / pricing-db), and its error trend is flat —
  not part of this cascade.
- `search-svc` reads pricing-db directly (NOT through price-cache) and stayed healthy —
  confirming the fault is the cache layer, not pricing-db itself.
- flags (api_edge.new_pricing_ui, catalog.batch_reads) are decoys; the change is a
  code/deploy to price-cache.

## Blast radius vs root cause
Root cause: price-cache hit-ratio collapse from the key-format change (cache misses
falling through to pricing-db).
Blast radius (victims): catalog-svc, api-edge, pricing-db.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
