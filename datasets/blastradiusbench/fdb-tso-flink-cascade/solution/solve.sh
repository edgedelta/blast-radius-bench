#!/bin/bash
# ORACLE solution for fdb-tso-flink-cascade. Writes the known-correct failure chain.
# Used to validate the grader (this answer must pass tests/test_outputs.py).
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "olapdb-tso",
  "propagation_path": [
    {"from": "olapdb-tso", "to": "metric-ingestor-1"},
    {"from": "metric-ingestor-1", "to": "stream-taskmanager"},
    {"from": "stream-taskmanager", "to": "platform-api"}
  ],
  "root_cause": "olapdb-tso (Timestamp Oracle) hit FoundationDB transaction timeouts during TSO leader-election and CAS operations after commit 3d8221b4 lowered the TSO CAS retry budget; without commit timestamps the olapdb write path could not commit txns, starving the downstream ingestor, Flink job and platform-api",
  "blast_radius": ["metric-ingestor-1", "stream-taskmanager", "platform-api"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# fdb-tso-flink-cascade — failure chain

## Origin
`olapdb-tso` failed FIRST. The earliest abnormal signal is at 09:12:40
("FoundationDB transaction timeout during TSO leader-election") followed by
"CAS operation failed: commit_ts unavailable". olapdb-tso is the olapdb Timestamp
Oracle: every write txn needs a commit timestamp from it. Its tso_cas_timeout_total
metric climbs from baseline 0 to 140 while every downstream service is still at baseline.
Onset follows the olapdb-tso deploy at 09:05 (commit 3d8221b4, "Lower TSO CAS retry budget").

## Propagation (causal direction)
- TSO cannot serve commit timestamps -> metric-ingestor-1 cannot acquire
  CnchLocks / commit write txns ("CnchLock acquire timed out", "TransactionCoordinator
  commit failed") at 09:14 => olapdb-tso -> metric-ingestor-1
- the ingestor stalls the olapdb write path the Flink job consumes, so the
  stream-taskmanager Flink taskmanager goes unhealthy (checkpoint expired, restart loop)
  at 09:17 => metric-ingestor-1 -> stream-taskmanager
- platform-api depends on the stream-taskmanager job output and starts returning
  errors at 09:20 => stream-taskmanager -> platform-api

## Trap avoided
The PagerDuty page is **FlinkJobUnhealthy** on `stream-taskmanager` (loudest, most alarming,
fired_at 09:18). But stream-taskmanager is the LAST victim before platform-api — its errors
start at 09:17, five minutes after olapdb-tso's FDB timeouts at 09:12. The Flink alert
is a downstream symptom of the OLAP store/FoundationDB degradation, not a Flink pod failure.

## Distractors ruled out
- kafka-metric-ingestor deployed at 09:16 right at onset (decoy) and flapped briefly;
  it is not on the failing path and recovered.
- flags (stream_taskmanager.parallelism_v2, ingest.batch_v3) are decoys.
- olapdb-server is healthy throughout (read path unaffected).

## Blast radius vs root cause
Root cause: olapdb-tso FoundationDB transaction timeouts (TSO leader-election/CAS).
Blast radius (victims): metric-ingestor-1, stream-taskmanager, platform-api.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
