#!/bin/bash
# ORACLE solution for shared-kafka-saturation. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "kafka:ingest-shared",
  "propagation_path": [
    {"from": "kafka:ingest-shared", "to": "metric-ingestor"},
    {"from": "kafka:ingest-shared", "to": "log-ingestor"},
    {"from": "kafka:ingest-shared", "to": "trace-ingestor"}
  ],
  "root_cause": "A retention.ms config change (commit f60a4b2) on cluster ingest-shared filled broker-2's log dir to 95%, dropping partitions out of the in-sync replica set cluster-wide (UnderReplicatedPartitions 0->71); with isr < min.insync.replicas=2 the cluster returned NotEnoughReplicas / produce timeouts on every topic, so the three unrelated consumers metric-ingestor, log-ingestor and trace-ingestor failed together. The coupling is the shared Kafka cluster, not any service call.",
  "blast_radius": ["metric-ingestor", "log-ingestor", "trace-ingestor"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# shared-kafka-saturation — failure chain

## Origin (infrastructure, not a service)
The origin is the **shared Kafka cluster ingest-shared**. A retention.ms change applied
at 14:38 (commit f60a4b2) caused broker-2's log dir to fill to 95%, shrinking the in-sync
replica set. Earliest signals are on the cluster, before any victim errors:
- 14:46:30 broker-2 log dir 89% used (retention.ms lowered, segment deletion lagging).
- 14:48:00 UnderReplicatedPartitions=18, ISR shrinking on broker-2.
- 14:49:30 broker-2 log dir 95%, UnderReplicatedPartitions=64 across metrics.raw/logs.raw/traces.raw.

## Why it is NOT three independent incidents and NOT a service cascade
metric-ingestor, log-ingestor and trace-ingestor fail within the same ~2-minute window but
share NO service-call edge: service_map.json shows no path between them — they only sit on
the same cluster ingest-shared, each on its own topic. With isr=1 < min.insync.replicas=2 the
cluster rejects produce/commit on ALL topics (NotEnoughReplicas), hitting all three at once:
- 14:50:05 metric-ingestor: produce metrics.raw NotEnoughReplicasException.
- 14:50:40 log-ingestor: offset commit / produce stalled, NotEnoughReplicas.
- 14:51:10 trace-ingestor: produce timeout to traces.raw, UnderReplicatedPartitions.

## Propagation (shared-cluster coupling, fan-out)
- cluster ISR shrink -> metric-ingestor produce fails => kafka:ingest-shared -> metric-ingestor
- cluster ISR shrink -> log-ingestor commit/produce fails => kafka:ingest-shared -> log-ingestor
- cluster ISR shrink -> trace-ingestor produce fails => kafka:ingest-shared -> trace-ingestor

## Controls and distractors ruled out
- billing (cluster billing-events + rds:billing-pg) and api-gateway are NOT on ingest-shared
  and stay at ~0.1% error throughout — proving the fault is cluster-scoped, not "everything down".
- auth-service deployed at 14:50 (jwks rotation) with its own flat ~21/5m 401s, off-cluster —
  an "errored + just shipped" red herring, unrelated to the ISR shrink.
- flags (ingest.batch_v2, auth.new_jwks) are decoys.

## Blast radius vs root cause
Root cause: cluster ingest-shared ISR shrink from broker-2 log dir saturation (retention change).
Blast radius (victims): metric-ingestor, log-ingestor, trace-ingestor.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
