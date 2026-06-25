#!/bin/bash
# ORACLE solution for queue-backlog-ingestion-cascade. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "metric-ingestor-1",
  "propagation_path": [
    {"from": "metric-ingestor-1", "to": "kafka-metric-ingestor"},
    {"from": "kafka-metric-ingestor", "to": "http-receiver"}
  ],
  "root_cause": "metric-ingestor-1 became a slow consumer of queue ed-olapdb-mt-1-metric-iq after commit 0f60a4b2 added a synchronous fsync per commit batch; consumption lag drove ApproximateAgeOfOldestMessage from 810s to 1048s, and the queue backlog backpressured up to kafka-metric-ingestor and the http-receiver edge",
  "blast_radius": ["kafka-metric-ingestor", "http-receiver"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# queue-backlog-ingestion-cascade — failure chain

## Origin (NOT the loudest)
`metric-ingestor-1` failed FIRST as a SLOW CONSUMER. Earliest abnormal signal
is at 03:14:00 ("commit batch took 5200ms (fsync per batch)") and consumer_lag begins
climbing. ApproximateAgeOfOldestMessage on ed-olapdb-mt-1-metric-iq rises 810s -> 1048s.
Onset follows the ingestor deploy at 03:08 (commit 0f60a4b2, "fsync per commit batch").

## The reversed-causality trap
Request flow is http-receiver -> kafka-metric-ingestor -> metric-ingestor-1.
http-receiver shows the visible p99/traffic spike and PAGES — so the naive reading blames
http-receiver and draws the edge http-receiver -> ingestor (request-flow direction). That
is INVERTED. The ingestor is the slow consumer; its backlog backpressures its callers.
Causal direction = callee backpressures caller.

## Propagation (causal direction)
- ingestor slow-consumes ed-olapdb-mt-1-metric-iq -> kafka-metric-ingestor producer
  blocks on full queue / SQS ChangeMessageVisibility errors (03:17) =>
  metric-ingestor-1 -> kafka-metric-ingestor
- kafka-metric-ingestor backpressure -> http-receiver ingest p99 spikes, 429/timeouts
  at the edge (03:20) => kafka-metric-ingestor -> http-receiver

## Distractors ruled out
- http-receiver deployed at 03:18 near onset (decoy); its traffic spike is the SYMPTOM of
  backpressure, not a load surge it caused.
- flags (ingest.kafka_v2, http_receiver.keepalive) are decoys.

## Blast radius vs root cause
Root cause: metric-ingestor-1 slow consumption -> queue backlog.
Blast radius (victims): kafka-metric-ingestor, http-receiver.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
