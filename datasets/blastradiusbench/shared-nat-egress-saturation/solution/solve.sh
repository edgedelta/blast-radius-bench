#!/bin/bash
# ORACLE solution for shared-nat-egress-saturation. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "net:nat-gw-az1",
  "propagation_path": [
    {"from": "net:nat-gw-az1", "to": "payment-gateway-client"},
    {"from": "net:nat-gw-az1", "to": "maps-svc"},
    {"from": "net:nat-gw-az1", "to": "push-notifier"}
  ],
  "root_cause": "The data-export batch job (after its deploy) began a large continuous outbound sync to an object store through the shared NAT gateway net:nat-gw-az1, holding thousands of long-lived outbound connections and saturating both the SNAT source-port pool (ErrorPortAllocation) and the egress bandwidth on nat-gw-az1. With no free SNAT ports, every NEW outbound connection from the az1 subnet failed, so the three unrelated services that make third-party calls through the same NAT (payment-gateway-client -> Stripe, maps-svc -> geocoder, push-notifier -> APNs) had their outbound calls time out simultaneously. The coupling is the shared NAT egress path, not any service call.",
  "blast_radius": ["payment-gateway-client", "maps-svc", "push-notifier"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# shared-nat-egress-saturation — failure chain

## Origin (shared infrastructure, not a service)
The origin is the shared **NAT gateway net:nat-gw-az1**, the single egress path all
internet-bound traffic from the az1 subnet leaves through. It was saturated by the
`data-export` batch job's outbound sync. Timeline (2026-06-23):
- 14:00:10 data-export v1.7.0 deploys and starts a continuous outbound object-store sync
  through nat-gw-az1, opening thousands of long-lived outbound connections.
- 14:01:30 net:nat-gw-az1 snat_port_allocation_errors_per_sec begins climbing from 0;
  egress_bandwidth_mbps approaches the gateway cap; allocated_snat_ports nears the pool max.
- 14:02:30 nat-gw-az1 ErrorPortAllocation is sustained (no free source ports) and egress
  bandwidth is pinned at the cap.
These are the EARLIEST abnormal signals, and they are on the NAT resource, not a service.

## Why it is NOT three independent incidents and NOT a service cascade
payment-gateway-client, maps-svc and push-notifier fail within the same ~1-minute window
but share NO service-call edge in service_map.json: they live in different call graphs and
only co-depend on the NAT egress (each lists `egress_via: net:nat-gw-az1` and a DIFFERENT
external dependency -- Stripe, a geocoder, APNs respectively). A model chasing per-service
logs would try to explain three separate third-party outages and miss the common cause.
The ONLY thing the three share is net:nat-gw-az1: every victim's error is an OUTBOUND
connection timeout to a distinct external host, all leaving through the same NAT.

## Propagation (shared-NAT coupling, fan-out)
- nat-gw-az1 SNAT ports exhausted -> payment-gateway-client POST api.stripe.com dial timeout
  (14:02:50)  => net:nat-gw-az1 -> payment-gateway-client
- nat-gw-az1 SNAT ports exhausted -> maps-svc GET geocoder dial timeout (14:03:05)
  => net:nat-gw-az1 -> maps-svc
- nat-gw-az1 SNAT ports exhausted -> push-notifier connect api.push.apple.com timeout
  (14:03:20)  => net:nat-gw-az1 -> push-notifier

## Traps avoided
- payment-gateway-client paged and is loudest (most errors, checkout failures) but is just
  one co-tenant victim of the shared NAT, not the cause.
- image-resizer errored (a local thumbnail decode panic) AND just deployed near onset, but
  it makes NO outbound third-party calls and does not egress via nat-gw-az1; its error
  trend is its own local fault -- a tempting "errored + shipped" wrong answer.
- Control services catalog-svc (internal-only, own Postgres, no external egress) and
  internal-api (no egress) do NOT use the NAT and stay healthy, proving the fault is the
  shared NAT egress, not a global outage.
- flags are decoys; the heavy tenant is the data-export batch job's outbound flood.

## Blast radius vs root cause
Root cause: shared NAT gateway net:nat-gw-az1 egress saturated (SNAT port allocation
errors + egress bandwidth at cap) by the data-export batch job's outbound sync.
Blast radius (victims): payment-gateway-client, maps-svc, push-notifier.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
