#!/usr/bin/env python3
"""Non-LLM baselines for BlastRadiusBench: can a script reconstruct the chain?

Five deterministic policies answer every scenario using only the data the
agent sees (alert.json + service_map.json) and are scored with the grader's
exact primary rules (origin accepted, origin not a victim, zero reversed
edges, directed-edge recall >= threshold):

  loudest-service     origin = the paging service, no path — the junior move
  first-service       origin = alphabetically first service (degenerate)
  blame-datastore     origin = the paging service's backing datastore (or its
                      first callee), single edge to the pager
  deep-walk           follow call edges from the pager to the deepest
                      dependency (or its datastore); path in CAUSAL direction
  request-flow-path   same walk, but path emitted in REQUEST direction
                      (caller->callee) — quantifies the reversed-causality trap

Writes benchmark-results/blastradiusbench/baselines.json. With --check (CI
mode) it fails if a degenerate baseline (loudest-service / first-service)
passes any scenario and warns when a cheap walk heuristic passes.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DATASET = REPO / "datasets" / "blastradiusbench"
OUT_PATH = REPO / "benchmark-results" / "blastradiusbench" / "baselines.json"

DEGENERATE = ("loudest-service", "first-service")
CHEAP = ("blame-datastore", "deep-walk", "request-flow-path")


def norm(s):
    return str(s).strip().lower()


# --- graph helpers -----------------------------------------------------------

def call_edges(smap):
    return [(e["from"], e["to"]) for e in smap.get("edges", [])]


def service_names(smap):
    """services is either a list of dicts ({name, datastores, ...}) or plain strings."""
    return [s["name"] if isinstance(s, dict) else s for s in smap.get("services", [])]


def datastores_of(smap, svc):
    for s in smap.get("services", []):
        if isinstance(s, dict) and s.get("name") == svc:
            return s.get("datastores", [])
    top = smap.get("datastores")
    if isinstance(top, dict):
        return top.get(svc, [])
    return []


def walk_deepest(smap, start):
    """BFS along call edges from `start`; return the path (list of services)
    to the deepest reachable node."""
    adj = {}
    for f, t in call_edges(smap):
        adj.setdefault(f, []).append(t)
    best = [start]
    queue = [[start]]
    seen = {start}
    while queue:
        path = queue.pop(0)
        if len(path) > len(best):
            best = path
        for nxt in sorted(adj.get(path[-1], [])):
            if nxt not in seen:
                seen.add(nxt)
                queue.append(path + [nxt])
    return best


# --- policies ----------------------------------------------------------------
# Each returns an answer dict shaped like failure_chain.json.

def loudest_service(alert, smap):
    return {"origin_service": alert["service"], "propagation_path": [],
            "root_cause": "overload", "blast_radius": []}


def first_service(alert, smap):
    names = sorted(service_names(smap))
    return {"origin_service": names[0] if names else "unknown",
            "propagation_path": [], "root_cause": "unknown", "blast_radius": []}


def blame_datastore(alert, smap):
    svc = alert["service"]
    ds = datastores_of(smap, svc)
    if ds:
        origin = ds[0]
    else:
        callees = sorted(t for f, t in call_edges(smap) if f == svc)
        origin = callees[0] if callees else svc
    return {"origin_service": origin,
            "propagation_path": [{"from": origin, "to": svc}],
            "root_cause": "saturation", "blast_radius": [svc]}


def _walk_answer(alert, smap, causal):
    svc = alert["service"]
    walk = walk_deepest(smap, svc)          # pager -> ... -> deepest callee
    deepest = walk[-1]
    ds = datastores_of(smap, deepest)
    chain = walk + [ds[0]] if ds else walk  # extend to the datastore if any
    origin = chain[-1]
    pairs = list(zip(chain, chain[1:]))     # (caller, callee) request direction
    if causal:
        path = [{"from": b, "to": a} for a, b in reversed(pairs)]
    else:
        path = [{"from": a, "to": b} for a, b in pairs]
    return {"origin_service": origin, "propagation_path": path,
            "root_cause": "saturation", "blast_radius": [s for s in chain if s != origin]}


def deep_walk(alert, smap):
    return _walk_answer(alert, smap, causal=True)


def request_flow_path(alert, smap):
    return _walk_answer(alert, smap, causal=False)


BASELINES = {
    "loudest-service": loudest_service,
    "first-service": first_service,
    "blame-datastore": blame_datastore,
    "deep-walk": deep_walk,
    "request-flow-path": request_flow_path,
}


# --- scoring (mirrors the grader) ---------------------------------------------

def score(ans, gt):
    got = norm(ans["origin_service"])
    accepted = {norm(gt["origin_service"])} | {norm(a) for a in gt.get("accept_origin_aliases", [])}
    victims = {norm(v) for v in gt.get("blast_radius", [])}
    true_edges = {(norm(e["from"]), norm(e["to"])) for e in gt["propagation_path"]}
    model_edges = {(norm(e["from"]), norm(e["to"])) for e in ans["propagation_path"]}
    recall = (len(model_edges & true_edges) / len(true_edges)) if true_edges else 1.0
    rev = {(a, b) for (a, b) in model_edges if (b, a) in true_edges and (a, b) not in true_edges}
    threshold = float(gt.get("edge_overlap_threshold", 1.0))
    origin_correct = got in accepted
    origin_is_victim = got in victims
    return {
        "passed": bool(origin_correct and not origin_is_victim and not rev and recall >= threshold),
        "origin_correct": origin_correct,
        "origin_is_victim": origin_is_victim,
        "edge_recall": round(recall, 3),
        "reversed_edges": len(rev),
    }


def load_scenario(d):
    wd = d / "environment" / "workdir"
    difficulty = "?"
    for line in (d / "task.toml").read_text().splitlines():
        if line.strip().startswith("difficulty"):
            difficulty = line.split("=")[1].strip().strip('"')
    return {
        "alert": json.loads((wd / "alert.json").read_text()),
        "smap": json.loads((wd / "service_map.json").read_text()),
        "gt": json.loads((d / "tests" / "ground_truth.json").read_text()),
        "difficulty": difficulty,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    scenarios = sorted(p for p in DATASET.iterdir()
                       if (p / "tests" / "ground_truth.json").exists())
    results = {name: {} for name in BASELINES}
    tiers = {}
    for d in scenarios:
        data = load_scenario(d)
        tiers[d.name] = data["difficulty"]
        for name, policy in BASELINES.items():
            r = score(policy(data["alert"], data["smap"]), data["gt"])
            r["difficulty"] = data["difficulty"]
            results[name][d.name] = r

    width = max(len(d.name) for d in scenarios)
    header = f"{'scenario':<{width}}  {'tier':<6}  " + "  ".join(f"{n:>18}" for n in BASELINES)
    print(header)
    print("-" * len(header))
    for d in scenarios:
        cells = []
        for name in BASELINES:
            r = results[name][d.name]
            mark = ("PASS" if r["passed"]
                    else "victim" if r["origin_is_victim"]
                    else "revrsd" if r["reversed_edges"] else "fail")
            cells.append(mark.rjust(18))
        print(f"{d.name:<{width}}  {tiers[d.name]:<6}  " + "  ".join(cells))

    print()
    summary = {}
    tier_names = sorted(set(tiers.values()))
    for name in BASELINES:
        rs = results[name]
        passed = sum(r["passed"] for r in rs.values())
        victims = sum(r["origin_is_victim"] for r in rs.values())
        revd = sum(1 for r in rs.values() if r["reversed_edges"])
        by_tier = {t: f"{sum(r['passed'] for s, r in rs.items() if tiers[s] == t)}"
                      f"/{sum(1 for s in rs if tiers[s] == t)}" for t in tier_names}
        summary[name] = {"passed": passed, "total": len(scenarios),
                         "pass_rate_pct": round(100 * passed / len(scenarios), 1),
                         "blamed_a_victim": victims, "scenarios_with_reversed_edges": revd,
                         "by_tier": by_tier}
        tier_str = "  ".join(f"{t} {by_tier[t]}" for t in tier_names)
        print(f"{name:>18}: {passed}/{len(scenarios)} passed, blamed-a-victim {victims}, "
              f"reversed {revd}  ({tier_str})")

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps({"summary": summary, "by_scenario": results}, indent=2) + "\n")
    print(f"\nwrote {OUT_PATH.relative_to(REPO)}")

    if args.check:
        for n in CHEAP:
            for s, r in results[n].items():
                if r["passed"]:
                    print(f"WARNING: cheap heuristic '{n}' passes {s} — the chain is "
                          f"recoverable from the service graph alone.")
        hard = [(n, s) for n in DEGENERATE for s, r in results[n].items() if r["passed"]]
        if hard:
            print(f"CI FAIL: degenerate baseline passes: {hard}")
            sys.exit(1)
        print("CI OK: no degenerate baseline passes any scenario.")


if __name__ == "__main__":
    main()
