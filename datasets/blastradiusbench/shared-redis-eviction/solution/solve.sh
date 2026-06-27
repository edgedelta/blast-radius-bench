#!/bin/bash
# ORACLE solution for shared-redis-eviction. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "redis:session-cache-01",
  "propagation_path": [
    {"from": "redis:session-cache-01", "to": "auth"},
    {"from": "redis:session-cache-01", "to": "cart"},
    {"from": "redis:session-cache-01", "to": "rate-limiter"}
  ],
  "root_cause": "The nightly cache-audit cron ran 'KEYS *' followed by a bulk DEL against the shared Redis primary session-cache-01; KEYS * blocked the single-threaded event loop and the bulk DEL triggered a maxmemory eviction storm, so blocked_clients and evicted_keys spiked and every client's commands timed out. The three unrelated services that share session-cache-01 (auth, cart, rate-limiter) had their reads/writes time out simultaneously. The coupling is the shared Redis primary, not any service call.",
  "blast_radius": ["auth", "cart", "rate-limiter"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# shared-redis-eviction — failure chain

## Origin (shared infrastructure, not a service)
The origin is the shared **Redis primary session-cache-01**, saturated by the nightly
`cache-audit` cron. Timeline:
- 19:02:00 cache-audit cron fires; runs `KEYS *` against session-cache-01.
- 19:02:30 redis:session-cache-01 blocked_clients jumps 1 -> 180; the single-threaded
  event loop is blocked scanning the full keyspace.
- 19:03:00 cache-audit issues a bulk DEL of the scanned keys; redis:session-cache-01
  evicted_keys surges and instantaneous_ops latency on the primary spikes (maxmemory).
These are the EARLIEST abnormal signals, and they are on the Redis resource, not a service.

## Why it is NOT three independent incidents and NOT a service cascade
auth, cart and rate-limiter fail within the same ~1-minute window but share NO
service-call edge in service_map.json: they live in different call graphs and only
co-depend on the Redis primary `session-cache-01` (each lists it under `datastores`).
A model chasing per-service logs would try to explain three separate outages and miss
the common cause. The ONLY thing the three share is session-cache-01: every victim's
error names "session-cache-01" / "redis" timeout or eviction.

## Propagation (shared-Redis coupling, fan-out)
- session-cache-01 blocked/evicting -> auth GET session token timeout (19:03:10)
  => redis:session-cache-01 -> auth
- session-cache-01 blocked/evicting -> cart HGETALL cart state timeout (19:03:20)
  => redis:session-cache-01 -> cart
- session-cache-01 blocked/evicting -> rate-limiter INCR counter timeout (19:03:30)
  => redis:session-cache-01 -> rate-limiter

## Traps avoided
- auth paged and is loudest (most errors, login failures) but is just one co-tenant
  victim of the shared Redis, not the cause.
- notification-svc errored (smtp relay cert expired) AND just deployed near onset, but
  it does NOT use session-cache-01 and its error trend is flat/pre-existing -- a decoy.
- Control services catalog (own Postgres datastore) and api-gateway do NOT touch
  session-cache-01 and stay healthy, proving the fault is the shared Redis, not a global
  outage.
- flags are decoys; the heavy tenant is the cache-audit cron's access pattern.

## Blast radius vs root cause
Root cause: shared Redis primary session-cache-01 saturated (blocked_clients spike +
eviction storm) by the cache-audit cron's KEYS * / bulk DEL.
Blast radius (victims): auth, cart, rate-limiter.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
