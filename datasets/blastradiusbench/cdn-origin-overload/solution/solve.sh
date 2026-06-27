#!/bin/bash
# ORACLE solution for cdn-origin-overload. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "origin-web",
  "propagation_path": [
    {"from": "origin-web", "to": "cdn-edge"}
  ],
  "root_cause": "origin-web CPU saturated after a traffic shift moved a region's requests onto it (cpu_util_pct pegged ~99%, render_latency_ms_p99 climbing from 13:12), so page renders went slow; cdn-edge origin fetches for uncached pages then exceeded their deadline and cdn-edge served 502/504 to customers",
  "blast_radius": ["cdn-edge"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# cdn-origin-overload — failure chain

## Origin
`origin-web` failed FIRST. After a traffic shift at 13:10 moved a region's requests
onto origin-web, its cpu_util_pct pegs near 99% and render_latency_ms_p99 climbs from
~620ms baseline to multiple seconds starting 13:12 — strictly before any cdn-edge 5xx.
origin-web's own logs are slow-render / high-CPU signals (WARN), not errors.

## Propagation (causal direction = origin -> edge)
- cdn-edge fetches uncached pages from origin-web. With origin-web rendering slowly,
  cdn-edge's origin-fetch hits its deadline and returns 502/504 to customers starting
  ~13:18 => origin-web -> cdn-edge.

## Trap avoided
cdn-edge carries the LOUDEST signal — it is the customer edge where 5xx is measured and
it pages at 13:20. But it is the outer victim: its 5xx begins ~6 minutes after origin-web
CPU saturation at 13:12. Its own errors name the origin ("origin fetch deadline exceeded
to origin-web").

## Distractors ruled out
- image-resizer deployed at 13:14 near onset and emits a flat trickle of benign HTTP 415
  "unsupported media type" rejects; its error rate is flat (~1%) and it is not on the
  page-render fetch path (decoy).
- static-assets serves cached assets off-origin and stays healthy throughout (control),
  showing the fault is specific to the origin-render path, not "everything is down".
- flags (cdn.brotli_v2, edge.shield_tier) are decoys.

## Blast radius vs root cause
Root cause: origin-web CPU saturation / slow renders after the traffic shift.
Blast radius (victims): cdn-edge.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
