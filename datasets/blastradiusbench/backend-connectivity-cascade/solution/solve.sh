#!/bin/bash
# ORACLE solution for backend-connectivity-cascade. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "olapdb-server",
  "propagation_path": [
    {"from": "olapdb-server", "to": "metric-ingestor-large"},
    {"from": "metric-ingestor-large", "to": "http-receiver"}
  ],
  "root_cause": "olapdb-server lost backend connectivity on its write path (RPC timeouts and 'connection reset by peer' to 10-0-12-44.olapdb-server-headless after Karpenter removed shard capacity; commit 7b3d9e2f tightened the write RPC deadline), so writes fanned out as failures up to the ingestor and the http-receiver edge",
  "blast_radius": ["metric-ingestor-large", "http-receiver"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# backend-connectivity-cascade — failure chain

## Origin
`olapdb-server` failed FIRST. The earliest abnormal signal is at 22:41:10
("RPC to olapdb-server-headless timed out") and "connection reset by peer
(10-0-12-44.olapdb-server-headless.olapdb.svc.cluster.local)". olapdb-server's
backend_write_rpc_timeout_total climbs from 0 while everything else is at baseline.
Onset follows olapdb-server deploy at 22:36 (commit 7b3d9e2f, "tighten write RPC
deadline") and the Karpenter disruption that removed shard capacity.

## Propagation (causal direction = backend -> caller)
- olapdb-server write path unreachable -> metric-ingestor-large write txns
  fail with HTTP 500 / commitParts timeout (22:43) => olapdb-server -> metric-ingestor-large
- the ingestor rejects/queues writes -> http-receiver at the edge sees write rejections,
  rising p99 latency and 5xx (22:46) => metric-ingestor-large -> http-receiver

## Trap avoided
http-receiver carries the LOUDEST signal — it is the edge where latency and 5xx are
measured, and it pages. But it is the OUTERMOST victim: its errors start at 22:46, five
minutes after olapdb-server's connectivity loss at 22:41. The latency alarm at the edge
is a symptom of the backend write-path failure.

## Distractors ruled out
- transformer deployed at 22:44 near onset (decoy) and briefly flapped EOF warnings; it
  recovered and is not on the failing write path.
- flags (http_receiver.gzip_v2, ingest.large_batch) are decoys.

## Blast radius vs root cause
Root cause: olapdb-server backend connectivity loss on the write path.
Blast radius (victims): metric-ingestor-large, http-receiver.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
