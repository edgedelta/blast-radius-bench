#!/usr/bin/env python3
"""
BlastRadiusBench grader.

PRIMARY reward (binary pass/fail):
  1. origin_service is correct, AND
  2. propagation_path directed-edge recall vs the true causal edges >= threshold.

SECONDARY (printed, never fails the test — for the writeup):
  - blast_radius set overlap (Jaccard) vs truth
  - reversed-causality check: how many of the model's edges are the REVERSE of a
    true causal edge (claiming a downstream victim caused an upstream service).
    This inverted-causality error is the key failure mode we want to surface.
  - root_cause keyword check (did the model name the originating fault, not a symptom).

The tests/ directory is injected only at verification time, so the agent never
sees ground_truth.json.
"""

import json
import os
import sys

ANSWER_PATH = "/workdir/failure_chain.json"
GROUND_TRUTH_PATH = os.path.join(os.path.dirname(__file__), "ground_truth.json")


# ── loaders ────────────────────────────────────────────────────────────────

def load_answer():
    with open(ANSWER_PATH, "r") as f:
        return json.load(f)


def load_truth():
    with open(GROUND_TRUTH_PATH, "r") as f:
        return json.load(f)


def norm(s):
    return str(s).strip().lower()


def edge_set(path):
    """Normalize a propagation_path list-of-{from,to} into a set of (from,to) tuples."""
    out = set()
    for e in path or []:
        if not isinstance(e, dict):
            continue
        f = e.get("from")
        t = e.get("to")
        if f is None or t is None:
            continue
        out.add((norm(f), norm(t)))
    return out


# ── metrics ────────────────────────────────────────────────────────────────

def directed_edge_recall(model_edges, true_edges):
    """Fraction of TRUE causal edges the model recovered (directed)."""
    if not true_edges:
        return 1.0
    hit = len(model_edges & true_edges)
    return hit / len(true_edges)


def directed_edge_jaccard(model_edges, true_edges):
    union = model_edges | true_edges
    if not union:
        return 1.0
    return len(model_edges & true_edges) / len(union)


def reversed_edges(model_edges, true_edges):
    """Model edges (a,b) where (b,a) is a true edge but (a,b) is NOT — inverted causality."""
    rev = set()
    for (a, b) in model_edges:
        if (b, a) in true_edges and (a, b) not in true_edges:
            rev.add((a, b))
    return rev


def set_jaccard(a, b):
    a, b = set(a), set(b)
    if not (a | b):
        return 1.0
    return len(a & b) / len(a | b)


# ── tests ────────────────────────────────────────────────────────────────

def test_file_exists():
    assert os.path.exists(ANSWER_PATH), f"{ANSWER_PATH} does not exist"


def test_schema():
    ans = load_answer()
    for key in ("origin_service", "propagation_path", "root_cause", "blast_radius"):
        assert key in ans, f"answer missing required key: {key}"
    assert isinstance(ans["propagation_path"], list), "propagation_path must be a list"
    assert isinstance(ans["blast_radius"], list), "blast_radius must be a list"


def test_origin_service():
    ans = load_answer()
    truth = load_truth()
    got = norm(ans["origin_service"])
    # Some scenarios (e.g. infra/node faults) accept a small set of equivalent origin
    # spellings; default is exact match on origin_service.
    accepted = {norm(truth["origin_service"])}
    for a in truth.get("accept_origin_aliases", []):
        accepted.add(norm(a))
    assert got in accepted, (
        f"origin_service wrong: got '{ans['origin_service']}', expected one of {sorted(accepted)}. "
        f"(The loudest service is usually NOT the origin.)"
    )


def test_propagation_path_overlap():
    ans = load_answer()
    truth = load_truth()
    model_edges = edge_set(ans["propagation_path"])
    true_edges = edge_set(truth["propagation_path"])
    threshold = float(truth.get("edge_overlap_threshold", 0.6))

    recall = directed_edge_recall(model_edges, true_edges)
    jacc = directed_edge_jaccard(model_edges, true_edges)
    rev = reversed_edges(model_edges, true_edges)

    print(f"\n[propagation_path] directed-edge recall = {recall:.3f} (threshold {threshold})")
    print(f"[propagation_path] directed-edge jaccard = {jacc:.3f}")
    print(f"[propagation_path] true edges     = {sorted(true_edges)}")
    print(f"[propagation_path] model edges    = {sorted(model_edges)}")
    print(f"[propagation_path] recovered      = {sorted(model_edges & true_edges)}")
    print(f"[propagation_path] missed         = {sorted(true_edges - model_edges)}")
    if rev:
        print(f"[REVERSED-CAUSALITY] model inverted {len(rev)} edge(s): {sorted(rev)}  <-- key failure mode")
    else:
        print(f"[REVERSED-CAUSALITY] none detected")

    assert recall >= threshold, (
        f"propagation_path directed-edge recall {recall:.3f} < threshold {threshold}"
    )


def test_secondary_metrics_report():
    """Always passes. Prints blast-radius overlap and root-cause keyword match."""
    ans = load_answer()
    truth = load_truth()

    br_overlap = set_jaccard([norm(x) for x in ans["blast_radius"]],
                             [norm(x) for x in truth["blast_radius"]])
    print(f"\n[blast_radius] jaccard vs truth = {br_overlap:.3f}")
    print(f"[blast_radius] truth = {sorted(norm(x) for x in truth['blast_radius'])}")
    print(f"[blast_radius] model = {sorted(norm(x) for x in ans['blast_radius'])}")

    rc = norm(ans.get("root_cause", ""))
    kws = [norm(k) for k in truth.get("root_cause_keywords", [])]
    matched = [k for k in kws if k in rc]
    if matched:
        print(f"[root_cause] keyword match: {matched}  (model named the originating fault)")
    else:
        print(f"[root_cause] NO keyword match against {kws} -- model may have described a symptom, not the cause")

    loud = truth.get("loudest_but_innocent")
    if loud:
        print(f"[trap] loudest-but-innocent service = '{loud}'. "
              f"Model origin = '{norm(ans['origin_service'])}' "
              f"({'FELL FOR TRAP' if norm(ans['origin_service']) == norm(loud) else 'avoided trap'})")

    assert True


if __name__ == "__main__":
    tests = [
        test_file_exists,
        test_schema,
        test_origin_service,
        test_propagation_path_overlap,
        test_secondary_metrics_report,
    ]
    try:
        for t in tests:
            t()
        print("\nAll BlastRadiusBench primary checks passed!")
        sys.exit(0)
    except AssertionError as e:
        print(f"\nTest failed: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\nUnexpected error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
