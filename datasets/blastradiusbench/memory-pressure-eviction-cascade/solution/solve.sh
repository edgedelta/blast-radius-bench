#!/bin/bash
# ORACLE solution for memory-pressure-eviction-cascade. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "node:ip-10-0-37-15",
  "propagation_path": [
    {"from": "node:ip-10-0-37-15", "to": "olapdb-vw-write"},
    {"from": "olapdb-vw-write", "to": "olapdb-server"},
    {"from": "olapdb-server", "to": "platform-api"}
  ],
  "root_cause": "node ip-10-0-37-15.us-east-1 hit MemoryPressure because a olapdb-vw-write pod ran with memory request 0 / no limit (commit 0e2b4d6f removed the resource limit) and grew unbounded; the kubelet evicted the write virtual-warehouse pod, so olapdb-server write/commit queries failed and platform-api surfaced query-failure 5xx",
  "blast_radius": ["olapdb-vw-write", "olapdb-server", "platform-api"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# memory-pressure-eviction-cascade — failure chain

## Origin (infrastructure)
The origin is the **node ip-10-0-37-15.us-east-1** memory-pressure fault. Timeline:
- 11:48:20 "olapdb-vw-write rss 14.2Gi, memory request 0 (no limit set)".
- 11:50:00 kubelet: node ip-10-0-37-15 MemoryPressure=True (available 180Mi).
- 11:50:40 SystemOOM / Evicted olapdb-vw-write pod. These are the EARLIEST signals,
  before any olapdb-server or platform-api error. Onset follows the olapdb-vw-write
  deploy at 11:42 (commit 0e2b4d6f, "remove memory limit on write VW").

## Propagation (node eviction, then service-call cascade)
- node MemoryPressure -> olapdb-vw-write pod evicted (11:50:40) =>
  node:ip-10-0-37-15 -> olapdb-vw-write (shared-infra / eviction edge)
- with the write virtual-warehouse pod gone, olapdb-server write/commit queries fail
  ("no available write worker", commitParts errors) at 11:52 =>
  olapdb-vw-write -> olapdb-server (service-call edge)
- platform-api depends on olapdb-server for query results and surfaces
  query-failure 5xx at 11:55 => olapdb-server -> platform-api

## Trap avoided
platform-api is LOUDEST and PAGES (query-failure 5xx monitor). But it is the LAST
victim — its errors start at 11:55, minutes after the node MemoryPressure at 11:50. The
node memory-pressure event is the origin, not the platform-api query failures.

## Distractors ruled out
- platform-api deployed at 11:53 near onset (decoy).
- prometheus-prom-kube-stack on a DIFFERENT node had its own brief probe 503s (red
  herring) but recovered and is not on this path.
- flags are decoys.

## Blast radius vs root cause
Root cause: node ip-10-0-37-15 memory pressure -> olapdb-vw-write eviction.
Blast radius (victims): olapdb-vw-write, olapdb-server, platform-api.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
