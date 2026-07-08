#!/usr/bin/env python3
"""
BlastRadiusBench grader (Tier-0 hardened).

PRIMARY reward (binary pass/fail) — ALL must hold:
  1. origin_service is correct (exact, or an accepted non-victim alias), AND
  2. origin_service is NOT a member of the true blast_radius (naming a victim
     as the cause is an automatic fail), AND
  3. propagation_path directed-edge recall vs the true causal edges >= threshold
     (default 1.0 — the FULL chain), AND
  4. zero reversed-causality edges (claiming a downstream victim caused an
     upstream service is an automatic fail).

SECONDARY (printed, never fails — for the writeup):
  - blast_radius set overlap (Jaccard) vs truth
  - root_cause keyword check (did the model name the originating fault).

GRADED reward (reporting only, never gates pass/fail): 0.0 for either cardinal
sin (naming a blast-radius victim as origin, or inverting any causal edge);
0.5 + 0.5 x edge-recall when the origin is right; 0.25 x blast-radius Jaccard
when the origin is wrong but sane. Emitted as a `BLASTRADIUSBENCH_METRICS
{json}` stdout line and, under Harbor, /logs/verifier/metrics.json —
leaderboards rank on mean graded reward instead of coarse pass counts.

The tests/ directory is injected only at verification time, so the agent never
sees ground_truth.json.
"""

import json
import os
import sys

ANSWER_PATH = "/workdir/failure_chain.json"
GROUND_TRUTH_PATH = os.path.join(os.path.dirname(__file__), "ground_truth.json")
METRICS_PATH = os.environ.get("BLASTRADIUSBENCH_METRICS_PATH", "/logs/verifier/metrics.json")

# Default edge-overlap bar. 1.0 = the model must recover the FULL causal chain.
DEFAULT_EDGE_THRESHOLD = 1.0


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
    if not true_edges:
        return 1.0
    return len(model_edges & true_edges) / len(true_edges)


def directed_edge_jaccard(model_edges, true_edges):
    union = model_edges | true_edges
    return 1.0 if not union else len(model_edges & true_edges) / len(union)


def reversed_edges(model_edges, true_edges):
    """Model edges (a,b) where (b,a) is a true edge but (a,b) is NOT — inverted causality."""
    return {(a, b) for (a, b) in model_edges
            if (b, a) in true_edges and (a, b) not in true_edges}


def set_jaccard(a, b):
    a, b = set(a), set(b)
    return 1.0 if not (a | b) else len(a & b) / len(a | b)


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
    accepted = {norm(truth["origin_service"])}
    for a in truth.get("accept_origin_aliases", []):
        accepted.add(norm(a))
    assert got in accepted, (
        f"origin_service wrong: got '{ans['origin_service']}', expected one of {sorted(accepted)}. "
        f"(The loudest service is usually NOT the origin.)"
    )


def test_origin_not_a_victim():
    """Naming a downstream victim (a blast_radius member) as the cause is an automatic fail."""
    ans = load_answer()
    truth = load_truth()
    got = norm(ans["origin_service"])
    victims = {norm(v) for v in truth.get("blast_radius", [])}
    assert got not in victims, (
        f"origin_service '{ans['origin_service']}' is a blast-radius VICTIM, not the cause. "
        f"victims = {sorted(victims)}"
    )


def test_propagation_path_full_chain():
    ans = load_answer()
    truth = load_truth()
    model_edges = edge_set(ans["propagation_path"])
    true_edges = edge_set(truth["propagation_path"])
    threshold = float(truth.get("edge_overlap_threshold", DEFAULT_EDGE_THRESHOLD))

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
        print(f"[REVERSED-CAUSALITY] model inverted {len(rev)} edge(s): {sorted(rev)}  <-- automatic fail")
    else:
        print(f"[REVERSED-CAUSALITY] none detected")

    assert not rev, (
        f"reversed-causality: model inverted {len(rev)} edge(s) {sorted(rev)} "
        f"(claimed a downstream victim caused an upstream service)"
    )
    assert recall >= threshold, (
        f"propagation_path directed-edge recall {recall:.3f} < threshold {threshold} "
        f"(must recover the full causal chain)"
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
        print(f"[root_cause] keyword match: {matched}")
    else:
        print(f"[root_cause] NO keyword match against {kws} -- model may have described a symptom")

    _emit_metrics(ans, truth, br_overlap, bool(matched))
    assert True


def _emit_metrics(ans, truth, br_overlap, keyword_match):
    """Graded reward: reporting only, never gates pass/fail."""
    got = norm(ans["origin_service"])
    accepted = {norm(truth["origin_service"])} | {norm(a) for a in truth.get("accept_origin_aliases", [])}
    origin_correct = got in accepted
    origin_is_victim = got in {norm(v) for v in truth.get("blast_radius", [])}
    model_edges = edge_set(ans["propagation_path"])
    true_edges = edge_set(truth["propagation_path"])
    recall = directed_edge_recall(model_edges, true_edges)
    rev = len(reversed_edges(model_edges, true_edges))
    threshold = float(truth.get("edge_overlap_threshold", DEFAULT_EDGE_THRESHOLD))

    if origin_is_victim or rev:
        graded = 0.0
    elif origin_correct:
        graded = round(0.5 + 0.5 * recall, 4)
    else:
        graded = round(0.25 * br_overlap, 4)
    metrics = {
        "scenario": truth.get("scenario"),
        "origin_correct": origin_correct,
        "origin_is_victim": origin_is_victim,
        "edge_recall": round(recall, 4),
        "reversed_edges": rev,
        "blast_radius_jaccard": round(br_overlap, 4),
        "root_cause_keyword_match": keyword_match,
        "passed": bool(origin_correct and not origin_is_victim and not rev and recall >= threshold),
        "graded_reward": graded,
    }
    print(f"BLASTRADIUSBENCH_METRICS {json.dumps(metrics, sort_keys=True)}")
    try:
        if os.path.isdir(os.path.dirname(METRICS_PATH)):
            with open(METRICS_PATH, "w") as f:
                json.dump(metrics, f, indent=1)
    except OSError:
        pass  # metrics file is best-effort; never fail grading over it


if __name__ == "__main__":
    tests = [
        test_file_exists,
        test_schema,
        test_origin_service,
        test_origin_not_a_victim,
        test_propagation_path_full_chain,
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
