#!/bin/bash
# ORACLE solution for grpc-deadline-chain. Writes the known-correct failure chain.
set -euo pipefail

cat > /workdir/failure_chain.json <<'JSON'
{
  "origin_service": "pricing-svc",
  "propagation_path": [
    {"from": "pricing-svc", "to": "quote-svc"},
    {"from": "quote-svc", "to": "orders-api"},
    {"from": "orders-api", "to": "mobile-bff"}
  ],
  "root_cause": "pricing-svc GetPrice developed a slow dependency after commit c41a77e0 made it synchronously reload the pricing-rules-store cache on a miss, so its p99 climbed past the 2s gRPC deadline; quote-svc's calls to pricing-svc then returned DeadlineExceeded, which propagated up as deadline-exceeded errors through orders-api to the mobile-bff edge",
  "blast_radius": ["quote-svc", "orders-api", "mobile-bff"]
}
JSON

cat > /workdir/reasoning.md <<'MD'
# grpc-deadline-chain — failure chain

## Origin
`pricing-svc` failed FIRST, but quietly. Its GetPrice spans stay `status: OK`
while their duration balloons from ~45ms baseline to >2s. The earliest abnormal
signal is pricing-svc's GetPrice p99 climbing at 14:33 ("rules cache miss, reload
from pricing-rules-store 1.8s") — strictly before any victim error. Onset follows
pricing-svc deploy v_c41a77e at 14:31 (commit c41a77e0: "load pricing rules
synchronously on cache miss").

## Propagation (causal direction = callee -> caller)
The gRPC call graph is mobile-bff -> orders-api -> quote-svc -> pricing-svc.
Failure propagates back UP the chain as deadline-exceeded:
- pricing-svc GetPrice exceeds quote-svc's 2s deadline -> quote-svc returns
  DeadlineExceeded "calling pricing-svc.GetPrice" (14:35) => pricing-svc -> quote-svc
- quote-svc slow/erroring -> orders-api deadlines "calling quote-svc.GetQuote"
  (14:37) => quote-svc -> orders-api
- orders-api 5xx -> mobile-bff edge returns 503 to clients, paged (14:39)
  => orders-api -> mobile-bff

Each victim's timeout names the NEXT HOP toward pricing-svc, so the chain is
traceable down to the silent origin.

## Trap avoided: quote-svc
quote-svc is the tempting wrong answer: it deployed v488 right at onset (14:32)
AND emits its own real ERROR logs — HTTP 422 config-validation rejecting a
malformed promo rule. But those 422s are flat (~a handful, not escalating) and
unrelated to the deadline chain; quote-svc's deadline errors all name
pricing-svc.GetPrice as the target. quote-svc is mid-chain, not the source.

## Trap avoided: mobile-bff
mobile-bff carries the LOUDEST signal (it pages, 5xx 41%, p99 12s) but is the
outermost victim; its errors start at 14:39, six minutes after pricing-svc's
latency onset at 14:33.

## Distractors ruled out
- search-svc also calls quote-svc but stays healthy (control) — quote-svc itself
  is not broadly broken; only the pricing-dependent path is.
- flags (mobile_bff.new_checkout, orders.async_capture) are decoys.

## Blast radius vs root cause
Root cause: pricing-svc slow dependency (synchronous pricing-rules-store cache
reload) blowing the gRPC deadline.
Blast radius (victims): quote-svc, orders-api, mobile-bff.
MD

echo "wrote /workdir/failure_chain.json and /workdir/reasoning.md"
