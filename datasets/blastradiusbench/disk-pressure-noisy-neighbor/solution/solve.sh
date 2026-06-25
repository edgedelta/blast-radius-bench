#!/bin/bash
# ORACLE solution for disk-pressure-noisy-neighbor. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "node:ip-10-0-37-88",
  "propagation_path": [
    {"from": "node:ip-10-0-37-88", "to": "dashboard-svc"},
    {"from": "node:ip-10-0-37-88", "to": "log-agent-v1"},
    {"from": "node:ip-10-0-37-88", "to": "sbom-scanner"}
  ],
  "root_cause": "log-agent-v1 (commit 2d4f6a8c disabled log rotation) filled the ephemeral disk of node ip-10-0-37-88.us-east-1, driving the kubelet to DiskPressure=True; the kubelet then evicted the co-located pods of the unrelated services dashboard-svc, log-agent-v1 and sbom-scanner. The coupling is the shared node, not any service call.",
  "blast_radius": ["dashboard-svc", "log-agent-v1", "sbom-scanner"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# disk-pressure-noisy-neighbor — failure chain

## Origin (infrastructure, not a service)
The origin is the **node ip-10-0-37-88.us-east-1** disk-pressure fault, driven by the
noisy-neighbor pod `log-agent-v1`. Timeline:
- 14:46:30 log-agent-v1 "log rotation disabled, /var/log/flog growing" (commit 2d4f6a8c).
- 14:49:10 node disk_used_pct 96% (ephemeral-storage).
- 14:50:00 kubelet: node ip-10-0-37-88 DiskPressure=True. These are the EARLIEST signals.

## Why it is NOT three independent incidents and NOT a service cascade
dashboard-svc (ns dashboard-svc), log-agent-v1 (ns default) and sbom-scanner (ns rad) fail within the
same 3-minute window but share NO service-call edge: they live in different namespaces and
different call graphs (service_map.json shows no path between them). Each even has its own
tempting red herring:
- dashboard-svc: a "module 'lib' has no attribute 'GEN_EMAIL'" import WARNING + its own commit.
- sbom-scanner: an ECR "401 Unauthorized" digest-lookup error + its own commit.
- log-agent-v1: a noisy log-spam pattern.
A model chasing per-service logs will "explain" each separately and miss the common cause.
The ONLY thing the three share is **node ip-10-0-37-88**: every Evicted/DiskPressure
event in events.json is on that node, and every erroring pod carries node=ip-10-0-37-88.

## Propagation (shared-node coupling, fan-out)
- DiskPressure -> dashboard-svc-... pod evicted (14:51:20)      => node:ip-10-0-37-88 -> dashboard-svc
- DiskPressure -> log-agent-v1 pod evicted (14:52:05)     => node:ip-10-0-37-88 -> log-agent-v1
- DiskPressure -> sbom-scanner pod evicted (14:52:50)          => node:ip-10-0-37-88 -> sbom-scanner

## Traps avoided
- dashboard-svc paged and is loudest (most errors) but is just one co-located victim.
- dashboard-svc's GEN_EMAIL import warning and sbom-scanner's ECR 401 are pre-existing red herrings,
  not the cause of the simultaneous evictions.
- Pods on OTHER nodes (e.g. platform-api on ip-10-0-12-31) stay healthy —
  proving the fault is node-scoped.
- flags are decoys.

## Blast radius vs root cause
Root cause: node ip-10-0-37-88 disk saturation from log-agent-v1's disabled log rotation.
Blast radius (victims): dashboard-svc, log-agent-v1, sbom-scanner.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
