#!/usr/bin/env python3
"""BlastRadiusBench oracle + data-integrity check (no Docker needed).

For every scenario under datasets/blastradiusbench/ this verifies:

  1. STRUCTURE   — ground_truth is internally consistent: origin is not a
                   blast-radius victim; no alias collides with a victim;
                   propagation_path edges are unique, non-reversed duplicates,
                   and every path victim appears in blast_radius; the loudest
                   ("loudest_but_innocent") service is a victim, not the
                   origin; edge_overlap_threshold is sane.
  2. SOLVE.SH    — replaying solution/solve.sh (with /workdir redirected to a
                   temp dir) emits a valid failure_chain.json.
  3. ORACLE      — the emitted answer matches ground truth exactly (origin,
                   full edge set, blast-radius set).
  4. GRADER      — the scenario's real grader (tests/test_outputs.py) passes
                   every check on the oracle.

Exit code 0 = every scenario clean. Run by CI on every push/PR.
"""

import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DATASET = REPO / "datasets" / "blastradiusbench"


def fail(scenario, msg):
    print(f"  FAIL [{scenario}] {msg}")
    return 1


def norm(s):
    return str(s).strip().lower()


def check_structure(name, d):
    errors = 0
    gt = json.loads((d / "tests" / "ground_truth.json").read_text())

    origin = norm(gt["origin_service"])
    victims = {norm(v) for v in gt["blast_radius"]}
    if origin in victims:
        errors += fail(name, f"origin {gt['origin_service']!r} is listed in blast_radius")
    for a in gt.get("accept_origin_aliases", []):
        if norm(a) in victims:
            errors += fail(name, f"origin alias {a!r} collides with a blast-radius victim")

    edges = [(norm(e["from"]), norm(e["to"])) for e in gt["propagation_path"]]
    if len(edges) != len(set(edges)):
        errors += fail(name, "duplicate edges in propagation_path")
    eset = set(edges)
    for a, b in eset:
        if (b, a) in eset:
            errors += fail(name, f"propagation_path contains both ({a}->{b}) and its reverse")
    path_victims = {b for _, b in eset}
    for v in path_victims - victims - {origin}:
        errors += fail(name, f"path victim {v!r} missing from blast_radius")
    if not eset:
        errors += fail(name, "empty propagation_path")

    # loudest_but_innocent is usually a blast-radius victim, but in
    # dual-incident scenarios it can belong to a parallel, unrelated incident —
    # the only invariant is that it is never the origin.
    loudest = norm(gt.get("loudest_but_innocent", ""))
    if loudest and loudest == origin:
        errors += fail(name, "loudest_but_innocent equals the origin")

    thresh = gt.get("edge_overlap_threshold", 1.0)
    if not (0 < float(thresh) <= 1.0):
        errors += fail(name, f"bad edge_overlap_threshold {thresh}")
    if not gt.get("root_cause_keywords"):
        errors += fail(name, "root_cause_keywords empty")
    return errors, gt


def replay_solve_sh(name, d):
    solve = d / "solution" / "solve.sh"
    with tempfile.TemporaryDirectory() as tmp:
        script = solve.read_text().replace("/workdir", tmp)
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        if r.returncode != 0:
            return fail(name, f"solve.sh failed: {r.stderr.strip()[:200]}"), None
        emitted = Path(tmp) / "failure_chain.json"
        if not emitted.exists():
            return fail(name, "solve.sh did not write failure_chain.json"), None
        return 0, json.loads(emitted.read_text())


def check_oracle_matches_truth(name, ans, gt):
    errors = 0
    accepted = {norm(gt["origin_service"])} | {norm(a) for a in gt.get("accept_origin_aliases", [])}
    if norm(ans["origin_service"]) not in accepted:
        errors += fail(name, f"oracle origin {ans['origin_service']!r} not accepted")
    truth_edges = {(norm(e["from"]), norm(e["to"])) for e in gt["propagation_path"]}
    ans_edges = {(norm(e["from"]), norm(e["to"])) for e in ans["propagation_path"]}
    if ans_edges != truth_edges:
        errors += fail(name, f"oracle edges != truth (missing {sorted(truth_edges - ans_edges)}, "
                             f"extra {sorted(ans_edges - truth_edges)})")
    if {norm(x) for x in ans["blast_radius"]} != {norm(x) for x in gt["blast_radius"]}:
        errors += fail(name, "oracle blast_radius set != truth")
    return errors


def check_grader_passes_oracle(name, d, ans):
    errors = 0
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "failure_chain.json").write_text(json.dumps(ans))
        spec = importlib.util.spec_from_file_location(
            f"grader_{name.replace('-', '_')}", d / "tests" / "test_outputs.py")
        grader = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(grader)
        grader.ANSWER_PATH = str(Path(tmp) / "failure_chain.json")
        for test in (grader.test_file_exists, grader.test_schema, grader.test_origin_service,
                     grader.test_origin_not_a_victim, grader.test_propagation_path_full_chain,
                     grader.test_secondary_metrics_report):
            buf = io.StringIO()
            try:
                with contextlib.redirect_stdout(buf):
                    test()
            except AssertionError as e:
                print(buf.getvalue(), end="")
                errors += fail(name, f"grader rejected the oracle: {e}")
    return errors


def main():
    scenarios = sorted(p for p in DATASET.iterdir()
                       if (p / "tests" / "ground_truth.json").exists())
    if not scenarios:
        print(f"no scenarios found under {DATASET}")
        sys.exit(1)

    total_errors = 0
    for d in scenarios:
        name = d.name
        errs, gt = check_structure(name, d)
        solve_errs, ans = replay_solve_sh(name, d)
        errs += solve_errs
        if ans is not None:
            errs += check_oracle_matches_truth(name, ans, gt)
            errs += check_grader_passes_oracle(name, d, ans)
        status = "OK  " if errs == 0 else "FAIL"
        print(f"{status} {name}  (origin={gt['origin_service']}, edges={len(gt['propagation_path'])}, "
              f"loudest={gt.get('loudest_but_innocent')})")
        total_errors += errs

    print(f"\n{len(scenarios)} scenarios checked, "
          f"{'all clean' if total_errors == 0 else f'{total_errors} error(s)'}")
    sys.exit(1 if total_errors else 0)


if __name__ == "__main__":
    main()
