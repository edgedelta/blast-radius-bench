#!/bin/bash
# ORACLE solution for shared-dynamodb-throttle. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "ddb:pipeline-states",
  "propagation_path": [
    {"from": "ddb:pipeline-states", "to": "ai-memory-svc"},
    {"from": "ddb:pipeline-states", "to": "ai-scheduler"},
    {"from": "ddb:pipeline-states", "to": "notification-worker"}
  ],
  "root_cause": "The shared DynamoDB table pipeline-states breached its provisioned write capacity (2000 WCU) after ai-scheduler deployed commit 6f8a0c2e at 07:26, which checkpoints plan state on every step and doubled its write rate; ConsumedWriteCapacityUnits crossed 2000 at 07:31 and the table returned ProvisionedThroughputExceededException to all three writers, so ai-memory-svc, ai-scheduler and notification-worker all degraded together. The coupling is the shared table, not a service call.",
  "blast_radius": ["ai-memory-svc", "ai-scheduler", "notification-worker"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# shared-dynamodb-throttle — failure chain

## Origin (a shared resource, not a service)
The origin is the **DynamoDB table pipeline-states**, which ran out of provisioned
write capacity. Timeline:
- 07:26:30 ai-scheduler rolls v6f8a0c2e ("per-step checkpoint writes"); its
  ddb_write_rps to pipeline-states climbs 210 -> 430 -> 480.
- 07:31 metrics.csv: ConsumedWriteCapacityUnits 2480 vs ProvisionedWriteCapacityUnits
  2000; throttled_write_requests jumps 4 -> 310. events.json logs WriteThrottleEvents
  on table pipeline-states at 07:31:10. This is the EARLIEST abnormal signal.
- 07:34 every victim's error_rate spikes together (ai-memory-svc 38%, ai-scheduler 21%,
  notification-worker 17%) — AFTER the table started throttling.

## Why it is NOT three independent incidents and NOT a service cascade
ai-memory-svc, ai-scheduler and notification-worker fail within the same ~3-minute
window but share NO service-call edge — service_map.json lists no edges between them.
The only thing they have in common is the `datastores: ["dynamodb:pipeline-states"]`
field: all three write the same table. Each victim's error names the table directly:
"ProvisionedThroughputExceededException on table pipeline-states".

## Propagation (shared-resource coupling, fan-out)
- table throttles -> ai-memory-svc PutItem fails (07:31:15)      => ddb:pipeline-states -> ai-memory-svc
- table throttles -> ai-scheduler BatchWriteItem fails (07:33:20) => ddb:pipeline-states -> ai-scheduler
- table throttles -> notification-worker UpdateItem fails (07:33:50) => ddb:pipeline-states -> notification-worker

## Traps avoided
- ai-memory-svc is paged and has the highest error rate, but it is just the loudest
  co-tenant of the table, not the cause.
- notification-svc deployed v44 near onset and emits HTTP 422 template errors, but it
  writes postgres:templates-db (not pipeline-states), its error trend is flat, and it is
  not in the throttle window — an errored-and-shipped distractor.
- ai-inference-runner and platform-api do not write the table and stay healthy,
  proving the fault is table-scoped, not cluster-wide.
- flags are decoys.

## Blast radius vs root cause
Root cause: shared DynamoDB table pipeline-states write-capacity saturation, driven by
ai-scheduler's per-step checkpoint deploy.
Blast radius (victims): ai-memory-svc, ai-scheduler, notification-worker.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
