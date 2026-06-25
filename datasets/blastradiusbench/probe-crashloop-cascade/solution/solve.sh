#!/bin/bash
# ORACLE solution for probe-crashloop-cascade. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "workflow-engine",
  "propagation_path": [
    {"from": "workflow-engine", "to": "ai-agent-svc"},
    {"from": "ai-agent-svc", "to": "platform-api"}
  ],
  "root_cause": "workflow-engine liveness/readiness probe misconfiguration (commit 8a0c2e4d pointed the liveness probe at port 9090 /health, which serves /metrics and returns 404), so the kubelet repeatedly Killed the container and workflow-engine entered CrashLoopBackOff; dependents got connection-refused and surfaced 5xx",
  "blast_radius": ["ai-agent-svc", "platform-api"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# probe-crashloop-cascade — failure chain

## Origin
`workflow-engine` failed FIRST. The earliest abnormal signal is at 19:02:10
("Liveness probe failed: HTTP 404 from :9090/health") followed by kubelet "Killing
container workflow-engine" and BackOff. workflow-engine's restart_count climbs from 0 while ai-agent and
platform-api are still at baseline. Onset follows the workflow-engine deploy at 18:58 (commit
8a0c2e4d, "point liveness probe at metrics port"). CRUCIALLY workflow-engine's APPLICATION logs
show clean startup ("workflow-engine server listening on :8080") — the app is fine; the PROBE is
misconfigured (it targets :9090/health, which only serves /metrics and 404s).

## Propagation (causal direction = callee restarting -> callers fail)
- workflow-engine keeps restarting / is unavailable -> ai-agent-svc calls to workflow-engine get
  "connection refused" (19:05) => workflow-engine -> ai-agent-svc
- ai-agent-svc then returns errors to platform-api, which surfaces AI
  Teammates 5xx (19:08) => ai-agent-svc -> platform-api

## Trap avoided
platform-api is LOUDEST and PAGES (Admin API HTTP 5xx monitor, most errors). But
it is the LAST victim — its errors start at 19:08, six minutes after workflow-engine's probe
failures at 19:02. Reading platform-api's 5xx as the cause inverts the chain.

## Distractors ruled out
- ai-agent-svc also had a prior CrashLoopBackOff history (red herring) but in THIS
  window its only failures are connection-refused to workflow-engine (a symptom).
- platform-api deployed at 19:06 near onset (decoy); flags are decoys.

## Blast radius vs root cause
Root cause: workflow-engine liveness/readiness probe misconfiguration -> CrashLoopBackOff.
Blast radius (victims): ai-agent-svc, platform-api.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
