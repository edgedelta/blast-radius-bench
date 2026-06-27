#!/bin/bash
# ORACLE solution for shared-dns-resolver-degradation. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "dns:coredns-cluster",
  "propagation_path": [
    {"from": "dns:coredns-cluster", "to": "web-checkout"},
    {"from": "dns:coredns-cluster", "to": "email-worker"},
    {"from": "dns:coredns-cluster", "to": "sync-agent"}
  ],
  "root_cause": "A Corefile change shrank the CoreDNS cluster resolver's in-memory cache to 1000 entries and pointed its forward plugin at a slow internet upstream with max_concurrent 100. On reload, dns:coredns-cluster began evicting cache entries constantly and queuing forwarded lookups behind the saturated upstream, so its SERVFAIL rate, cache_evictions, and forward p99 latency spiked first. The three unrelated services that resolve external hostnames per request through cluster DNS (web-checkout -> payment gateway host, email-worker -> SMTP relay host, sync-agent -> object-store host) all began returning getaddrinfo ENOTFOUND / resolution timeouts simultaneously. The coupling is the shared cluster DNS resolver, not any service-to-service call.",
  "blast_radius": ["web-checkout", "email-worker", "sync-agent"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# shared-dns-resolver-degradation — failure chain

## Origin (shared infrastructure, not a service)
The origin is the shared cluster DNS resolver **dns:coredns-cluster**, degraded by a
Corefile change. Timeline:
- 09:00:00 Corefile change deployed (cache size 100000 -> 1000, forward to a slow
  internet upstream, max_concurrent 100); CoreDNS reloads.
- 09:01:30 dns:coredns-cluster cache_evictions_per_sec jumps 0 -> 9200 and
  forward_p99_latency_ms 4 -> 5200 and servfail_rate_pct 0.1 -> 31; the resolver is
  thrashing its tiny cache and queuing forwarded lookups behind the saturated upstream.
These are the EARLIEST abnormal signals, and they are on the DNS resolver, not a service.

## Why it is NOT three independent incidents and NOT a service cascade
web-checkout, email-worker and sync-agent fail within the same ~30s window but share NO
service-call edge in service_map.json: they live in different call graphs and only
co-depend on dns:coredns-cluster (each lists it under `resolver`). A model chasing
per-service logs would try to explain three separate outages and miss the common cause.
The ONLY thing the three share is cluster DNS: every victim's error names a DNS failure
(getaddrinfo ENOTFOUND / resolution timeout via coredns-cluster) on an EXTERNAL hostname
it must resolve per request.

## Propagation (shared-resolver coupling, fan-out)
- coredns-cluster SERVFAIL/evicting -> web-checkout getaddrinfo ENOTFOUND for the
  payment gateway host (09:02:10)  => dns:coredns-cluster -> web-checkout
- coredns-cluster SERVFAIL/evicting -> email-worker resolution timeout for the SMTP
  relay host (09:02:25)             => dns:coredns-cluster -> email-worker
- coredns-cluster SERVFAIL/evicting -> sync-agent getaddrinfo ENOTFOUND for the
  object-store host (09:02:40)      => dns:coredns-cluster -> sync-agent

## Traps avoided
- web-checkout paged and is loudest (most errors, checkout failures) but is just one
  co-tenant victim of the shared resolver, not the cause.
- pdf-renderer errored (font-cache mmap failure) AND just deployed near onset, but it
  does NOT depend on cluster DNS at request time and its error trend is flat/pre-existing
  -- an off-resolver decoy.
- Control services metrics-relay (static hostAliases IP, no DNS lookups) and image-proxy
  (NodeLocal DNS cache + long-lived cached connection) do NOT depend on cluster DNS at
  request time and stay healthy, proving the fault is the shared resolver, not a global
  network outage.
- flags are decoys; the trigger is the Corefile change to coredns-cluster.

## Blast radius vs root cause
Root cause: shared cluster DNS resolver dns:coredns-cluster degraded (SERVFAIL spike +
cache eviction storm + forward latency) after a Corefile change.
Blast radius (victims): web-checkout, email-worker, sync-agent.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
