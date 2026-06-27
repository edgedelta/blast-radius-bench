#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# ///
"""
generate_scenario.py — scaffold a new BlastRadiusBench scenario.

============================================================================
HOW REAL SCENARIOS ARE PRODUCED (the fault-injection methodology)
============================================================================

BlastRadiusBench scenarios are NOT hand-authored fiction; the shipped ones are
hand-curated, but the intended pipeline is fault injection on a real app:

  1. Stand up a real microservices demo (e.g. GoogleCloudPlatform/microservices-demo
     or the OpenTelemetry Astronomy Shop) under steady synthetic load.
  2. Pin every service to a known git commit. Pick ONE commit to be the culprit and
     inject a realistic fault tied to that code change, e.g.:
        - shrink a DB connection pool / hold a connection across an RPC  (shared-postgres-saturation)
        - add an unbounded in-memory batch that triggers GC pauses       (retry-storm)
        - drop a memory limit on a co-located batch job                  (noisy-neighbor)
  3. Let the cascade develop. Record the telemetry window (traces, metrics, logs,
     k8s events) for ~10-15 minutes spanning baseline -> onset -> escalation.
  4. Freeze that window into the scenario's /workdir files, DOWNSAMPLED to a few KB
     so the agent can read everything. Strip noise but keep the buried first signal.
  5. Build the context/ files: the real commit list in the window (the culprit PLUS
     many plausible distractor commits), the deploy events (with an INNOCENT deploy
     placed near onset to punish "blame the latest change"), and feature-flag changes
     (decoys only — v1 root causes are always code changes).
  6. Hand-label the ground truth: origin_service, the directed propagation edges
     (callee -> caller for RPC cascades; node -> pod for shared-infra cascades),
     the root_cause text + culprit sha, and the blast_radius victim set. Write it to
     tests/ground_truth.json (NEVER copied into the agent image).

The realism rules (small files, internally-consistent timestamps with onset AFTER the
culprit deploy, a loud-but-innocent edge service, exactly one true origin) are what make
the task discriminating. See datasets/blastradiusbench/README.md for the schema.

============================================================================
WHAT THIS SCRIPT DOES
============================================================================

It emits a fully-wired scenario SKELETON (all 6 task files + placeholder /workdir data
+ ground_truth.json) that you then fill in with a frozen telemetry window. The synthetic
data it generates is a minimal, internally-consistent linear cascade with injectable
distractor commits, enough to smoke-test the harness end-to-end.

Usage:
    uv run tools/generate_scenario.py NAME --services api,web,svc,db \\
        --origin svc --difficulty hard --distractors 4

    # then run the oracle to confirm the grader is consistent:
    bash datasets/blastradiusbench/NAME/solution/solve.sh   # (after pointing /workdir)
"""

from __future__ import annotations

import argparse
import json
import random
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BENCH_DIR = ROOT / "datasets" / "blastradiusbench"

DISTRACTOR_MSGS = [
    "add request-id propagation header",
    "bump analytics event, minor css",
    "upgrade query parser to v2",
    "add idempotency-key logging",
    "enable gzip for responses",
    "precompute facet counts nightly",
    "rotate signing-key cache TTL",
    "index product tags",
]


def iso(t: datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


def gen(name: str, services: list[str], origin: str, difficulty: str, n_distractors: int) -> None:
    if origin not in services:
        raise SystemExit(f"--origin {origin!r} must be one of --services {services}")

    rng = random.Random(name)  # deterministic per name
    base = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
    culprit_deploy = base + timedelta(minutes=2)
    onset = base + timedelta(minutes=4)  # AFTER culprit deploy
    culprit_sha = f"{rng.randrange(16**7):07x}"

    sdir = BENCH_DIR / name
    wd = sdir / "environment" / "workdir"
    ctx = wd / "context"

    # Linear causal chain origin -> ... -> edge (callee -> caller direction).
    # services list is treated as [edge, ..., origin] deepest-last for the call graph,
    # but causal propagation runs origin outward.
    chain = list(services)
    if chain[-1] != origin:
        chain.remove(origin)
        chain.append(origin)
    # call edges: caller -> callee = reverse adjacency of chain
    call_edges = [{"from": chain[i], "to": chain[i + 1]} for i in range(len(chain) - 1)]
    # causal propagation edges: callee -> caller
    prop_edges = [{"from": e["to"], "to": e["from"]} for e in reversed(call_edges)]
    blast = [e["to"] for e in prop_edges]  # everyone downstream of origin

    # ── service_map.json ──
    write(wd / "service_map.json", json.dumps({
        "description": "Directed dependency graph. {from: A, to: B} means A calls B.",
        "generated_at": iso(onset),
        "services": services,
        "edges": [dict(e, call_rate_rps=100) for e in call_edges],
    }, indent=2) + "\n")

    # ── alert.json (loud edge service, not origin) ──
    loud = chain[0]
    write(wd / "alert.json", json.dumps({
        "alert_id": "PD-00000",
        "service": loud,
        "metric": "http_5xx_rate",
        "threshold": "> 5%",
        "observed_value": "40%",
        "fired_at": iso(onset + timedelta(minutes=3)),
        "severity": "critical",
        "summary": f"{loud} loudest 5xx — but it is the edge, not necessarily the source",
    }, indent=2) + "\n")

    # ── metrics.csv (origin degrades first) ──
    rows = ["timestamp,service,metric,value"]
    for k, t in enumerate((base, onset, onset + timedelta(minutes=4))):
        for s in services:
            lead = 1 if s == origin else 0
            err = [0.1, 9.0 * (1 + lead), 35.0][k]
            lat = [50, 1800 if s == origin else 200, 6000][k]
            rows.append(f"{iso(t)},{s},error_rate_pct,{err}")
            rows.append(f"{iso(t)},{s},p99_latency_ms,{lat}")
    write(wd / "metrics.csv", "\n".join(rows) + "\n")

    # ── logs / traces / events / patterns (minimal) ──
    write(wd / "logs.ndjson",
          json.dumps({"timestamp": iso(onset), "service": origin, "severity_text": "ERROR",
                      "msg": "originating fault began here", "trace_id": "tr-1"}) + "\n" +
          json.dumps({"timestamp": iso(onset + timedelta(minutes=3)), "service": loud,
                      "severity_text": "ERROR", "msg": "edge 5xx (last victim)", "trace_id": "tr-1"}) + "\n")
    write(wd / "traces.json", json.dumps({
        "description": "Deepest erroring span is the origin.",
        "traces": [{"trace_id": "tr-1", "spans": [
            {"span_id": "s1", "parent_id": None, "service": loud, "name": "GET /",
             "start": iso(onset + timedelta(minutes=3)), "duration_ms": 6000, "status": "ERROR"},
            {"span_id": "s2", "parent_id": "s1", "service": origin, "name": "work",
             "start": iso(onset), "duration_ms": 5900, "status": "ERROR",
             "attributes": {"error.msg": "originating fault"}},
        ]}],
    }, indent=2) + "\n")
    write(wd / "events.json", json.dumps({
        "window": f"{iso(base)}..{iso(onset + timedelta(minutes=8))}",
        "events": [{"timestamp": iso(culprit_deploy), "type": "Deployment",
                    "object": f"deploy/{origin}", "reason": "ScalingReplicaSet",
                    "message": f"rolled out culprit {culprit_sha}"}],
    }, indent=2) + "\n")
    write(wd / "patterns.json", json.dumps({
        "window": f"{iso(base)}..{iso(onset + timedelta(minutes=8))}",
        "patterns": [
            {"signature": "originating fault", "service": origin, "count": 1000,
             "delta_vs_baseline": "+1000", "first_seen": iso(onset), "sentiment": "negative"},
            {"signature": "edge 5xx", "service": loud, "count": 8000,
             "delta_vs_baseline": "+8000", "first_seen": iso(onset + timedelta(minutes=3)),
             "sentiment": "negative"},
        ],
    }, indent=2) + "\n")

    # ── context: culprit + distractors, innocent deploy near onset ──
    commits = [{"sha": culprit_sha, "author": "dev0", "timestamp": iso(culprit_deploy - timedelta(minutes=1)),
                "service": origin, "message": f"{origin}: INJECTED culprit fault",
                "files_changed": [f"{origin}/main.go"]}]
    others = [s for s in services if s != origin] or services
    for i in range(n_distractors):
        svc = others[i % len(others)]
        commits.append({"sha": f"{rng.randrange(16**7):07x}", "author": f"dev{i+1}",
                        "timestamp": iso(base + timedelta(minutes=rng.randint(-30, 3))),
                        "service": svc, "message": f"{svc}: {DISTRACTOR_MSGS[i % len(DISTRACTOR_MSGS)]}",
                        "files_changed": [f"{svc}/x.go"]})
    write(ctx / "commits.json", json.dumps({"repo": "github.com/acme/demo",
        "window": f"{iso(base)}..{iso(onset + timedelta(minutes=8))}", "commits": commits}, indent=2) + "\n")
    write(ctx / "deploys.json", json.dumps({"deploys": [
        {"timestamp": iso(culprit_deploy), "service": origin, "commit_sha": culprit_sha, "version": f"{origin}-v1"},
        {"timestamp": iso(onset), "service": loud, "commit_sha": "innocent", "version": f"{loud}-v1",
         "note": "innocent deploy at onset — decoy"},
    ]}, indent=2) + "\n")
    write(ctx / "flags.json", json.dumps({
        "note": "Flags are distractors; v1 root causes are code changes.",
        "changes": [{"timestamp": iso(onset), "flag": f"{loud}.some_flag", "service": loud,
                     "from": False, "to": True, "actor": "dev0"}],
    }, indent=2) + "\n")

    # ── task.toml / instruction.md / Dockerfile ──
    write(sdir / "task.toml", f'''version = "1.0"

[metadata]
author_name = "Edge Delta"
author_email = "oss@edgedelta.com"
difficulty = "{difficulty}"
category = "observability"
tags = ["sre", "root-cause", "cascading-failure", "blast-radius", "generated"]

[verifier]
timeout_sec = 120.0

[agent]
timeout_sec = 3600.0

[environment]
build_timeout_sec = 600.0
cpus = 2
memory_mb = 4096
storage_mb = 8192
''')
    write(sdir / "environment" / "Dockerfile", '''FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends jq grep gawk coreutils ca-certificates \\
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workdir
COPY workdir/ /workdir/
CMD ["/bin/bash"]
''')
    write(sdir / "instruction.md", f'''# Reconstruct the failure chain

A cascading multi-service incident is in progress. Reconstruct what failed first and how
it spread. Data is in `/workdir` (traces.json, metrics.csv, logs.ndjson, events.json,
service_map.json, alert.json, context/). Flags are distractors; the root cause is a code
change.

Write `/workdir/failure_chain.json`:
```json
{{
  "origin_service": "<svc>",
  "propagation_path": [{{"from": "<svc>", "to": "<svc>"}}],
  "root_cause": "<short>",
  "blast_radius": ["<svc>"]
}}
```
and your analysis to `/workdir/reasoning.md`. Do not blame the loudest service; use
earliest-error timing and the call-direction (callee -> caller) of the cascade.
''')

    # ── solution oracle + tests ──
    answer = {"origin_service": origin, "propagation_path": prop_edges,
              "root_cause": f"{origin} (commit {culprit_sha}) originating fault", "blast_radius": blast}
    write(sdir / "solution" / "solve.sh",
          "#!/bin/bash\nset -euo pipefail\ncat > /workdir/failure_chain.json <<'JSON'\n"
          + json.dumps(answer, indent=2) + "\nJSON\n"
          + "echo 'INJECTED culprit fault' > /workdir/reasoning.md\n")
    write(sdir / "tests" / "ground_truth.json", json.dumps({
        "scenario": name, "origin_service": origin, "root_cause_culprit_sha": culprit_sha,
        "root_cause_keywords": ["fault", culprit_sha], "propagation_path": prop_edges,
        "blast_radius": blast, "edge_overlap_threshold": 0.6, "loudest_but_innocent": loud,
    }, indent=2) + "\n")

    # reuse the shared grader + test.sh from an existing scenario
    src = BENCH_DIR / "shared-postgres-saturation" / "tests"
    write(sdir / "tests" / "test_outputs.py", (src / "test_outputs.py").read_text())
    write(sdir / "tests" / "test.sh", (src / "test.sh").read_text())

    print(f"Scaffolded scenario at {sdir}")
    print(f"  origin={origin}  culprit_sha={culprit_sha}  edges={prop_edges}")
    print("  Fill /workdir with a real frozen telemetry window, then validate the oracle.")


def main() -> None:
    ap = argparse.ArgumentParser(description="Scaffold a BlastRadiusBench scenario")
    ap.add_argument("name")
    ap.add_argument("--services", required=True, help="comma-separated, edge-first (e.g. api,web,svc,db)")
    ap.add_argument("--origin", required=True, help="service that failed first")
    ap.add_argument("--difficulty", default="medium", choices=["easy", "medium", "hard"])
    ap.add_argument("--distractors", type=int, default=4)
    a = ap.parse_args()
    gen(a.name, [s.strip() for s in a.services.split(",") if s.strip()], a.origin, a.difficulty, a.distractors)


if __name__ == "__main__":
    main()
