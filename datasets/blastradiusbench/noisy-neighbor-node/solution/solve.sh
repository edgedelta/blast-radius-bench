#!/bin/bash
# ORACLE solution for noisy-neighbor-node. Writes the known-correct failure chain.
# Used to validate the grader (this answer must pass tests/test_outputs.py).
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "node-7",
  "propagation_path": [
    {"from": "node-7", "to": "auth"},
    {"from": "node-7", "to": "cart"},
    {"from": "node-7", "to": "image-resize"}
  ],
  "root_cause": "batch-importer (commit 7e0a4d2) loads the full catalog into memory with no chunking and no memory limit; its 02:00 cron run drove node-7 into MemoryPressure, and the kubelet OOMKilled/evicted the co-located pods of auth, cart and image-resize",
  "blast_radius": ["auth", "cart", "image-resize"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# noisy-neighbor-node — failure chain

## Origin
The origin is the **node-7** infrastructure fault, driven by the noisy-neighbor pod
`batch-importer`. Timeline:
- 02:00 batch-importer (importer-v55, commit 7e0a4d2) cron run starts.
- 02:01:30 "loading full catalog into memory (rows=4.2M)"; 02:03:20 rss=6100MB "no chunking".
- 02:04:05 kubelet: node-7 MemoryPressure=True (available 220Mi). 02:05:00 SystemOOM.
These are the EARLIEST abnormal signals — before any of the failing services error.

## Why it is NOT a service-call cascade
auth, cart, and image-resize fail within the same 2-minute window but sit in three
different branches of the call graph (auth & cart off api-gateway; image-resize off
catalog). There is no service-call edge connecting them. The only thing they share is
**node-7**: every OOMKill/Eviction event in events.json is on node-7, and every erroring
span carries `k8s.node: node-7`. catalog runs on node-3 and stays healthy throughout —
proving the fault is node-scoped, not global and not RPC-propagated.

## Propagation (shared-node coupling, fan-out)
- node-7 MemoryPressure -> auth pod OOMKilled (02:05:42)  => node-7 -> auth
- node-7 MemoryPressure -> cart pod evicted (02:06:25)     => node-7 -> cart
- node-7 MemoryPressure -> image-resize OOMKilled (02:07:05) => node-7 -> image-resize

## Traps avoided
- auth paged and is loudest (9100 errors) but is just one co-located victim.
- auth (1c4f8b0), cart (3aa2e91), image-resize (9b7c310) each have their OWN recent
  commit — a tempting "three independent code bugs" story. None of them is the cause.
- The true culprit, 7e0a4d2, is in batch-importer, which does not even appear in the
  service call graph. Onset tracks the 02:00 CRON RUN, not the importer deploy at 21:35.
- flags (image-resize.webp_enabled, auth.jwt_cache_v2) are decoys.

## Blast radius vs root cause
Root cause: node-7 memory saturation from batch-importer's unbounded in-memory load.
Blast radius (victims): auth, cart, image-resize. catalog (node-3) unaffected.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
