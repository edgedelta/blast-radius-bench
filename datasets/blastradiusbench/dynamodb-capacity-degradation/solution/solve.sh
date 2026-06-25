#!/bin/bash
# ORACLE solution for dynamodb-capacity-degradation. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "ai-memory-svc",
  "propagation_path": [
    {"from": "ai-memory-svc", "to": "ai-agent-svc"},
    {"from": "ai-agent-svc", "to": "platform-api"}
  ],
  "root_cause": "ai-memory-svc writes agent state to DynamoDB table pipeline-states, which breached its provisioned write capacity after commit 6f8a0c2e doubled per-step checkpoint writes; DynamoDB returned ProvisionedThroughputExceeded/throttling, ai-agent-svc retried aggressively (retry amplification), and platform-api surfaced AI runtime 500s",
  "blast_radius": ["ai-agent-svc", "platform-api"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# dynamodb-capacity-degradation — failure chain

## Origin
`ai-memory-svc` failed FIRST. The earliest abnormal signal is at 07:31:10
("DynamoDB PutItem ProvisionedThroughputExceededException on table pipeline-states") and
dynamodb_write_throttle_total climbs from 0. Onset follows the ai-memory-svc deploy
at 07:26 (commit 6f8a0c2e, "double per-step checkpoint writes"), which doubled the write
rate against a fixed provisioned WCU on pipeline-states.

## The retry-amplification trap
ai-agent-svc calls ai-memory-svc to persist agent state and RETRIES on
throttle errors. The retries multiply its outbound call volume, CPU and error counts, so
ai-agent-svc looks like the BIGGEST, LOUDEST problem and is what PAGES. But that
volume spike is amplification of a downstream throttle, not the source. The throttling
metric is on ai-memory-svc/DynamoDB, which fires FIRST.

## Propagation (causal direction = throttled callee -> caller)
- DynamoDB throttles ai-memory-svc writes -> ai-agent-svc state writes fail
  and it retries (retry storm) at 07:33 => ai-memory-svc -> ai-agent-svc
- ai-agent-svc failures surface as AI runtime 500s on platform-api at
  07:36 => ai-agent-svc -> platform-api

## Distractors ruled out
- ai-agent-svc's CPU/call-volume spike is the retry amplification SYMPTOM, not a
  load surge it originated.
- ai-agent-svc deployed at 07:34 near onset (decoy); flags are decoys.

## Blast radius vs root cause
Root cause: ai-memory-svc DynamoDB write-capacity throttling (table pipeline-states).
Blast radius (victims): ai-agent-svc, platform-api.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
