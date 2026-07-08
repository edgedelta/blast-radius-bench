"""Extract per-trial graded metrics from a Harbor trial directory.

The BlastRadiusBench grader emits a graded reward (0.0 for either cardinal sin
— naming a blast-radius victim as origin or inverting a causal edge; 0.5 +
0.5 x edge-recall when the origin is right; 0.25 x blast-radius Jaccard when
the origin is wrong but sane). Sources, in order:

  1. verifier/metrics.json              — written by graders from 2026-07 on
  2. BLASTRADIUSBENCH_METRICS line      — grader stdout
  3. legacy stdout                      — recomputed from the printed
                                          recall / reversed / jaccard lines and
                                          the failure messages
  4. verifier ran but nothing parses    — grader asserted before scoring
                                          (missing/malformed answer): 0.0
  5. no verifier output at all          — harness error; returns None
"""
from __future__ import annotations

import json
import re
from pathlib import Path

_RECALL = re.compile(r"directed-edge recall = ([\d.]+)")
_BR_JACC = re.compile(r"\[blast_radius\] jaccard vs truth = ([\d.]+)")
_REVERSED = re.compile(r"\[REVERSED-CAUSALITY\] model inverted (\d+)")
_ORIGIN_WRONG = re.compile(r"origin_service wrong")
_ORIGIN_VICTIM = re.compile(r"is a blast-radius VICTIM")


def _from_stdout(text: str) -> dict | None:
    for line in text.splitlines():
        if line.startswith("BLASTRADIUSBENCH_METRICS "):
            try:
                return json.loads(line.split(" ", 1)[1])
            except json.JSONDecodeError:
                continue
    recall_m = _RECALL.search(text)
    if not recall_m:
        return None
    recall = float(recall_m.group(1))
    rev_m = _REVERSED.search(text)
    rev = int(rev_m.group(1)) if rev_m else 0
    br_m = _BR_JACC.search(text)
    br = float(br_m.group(1)) if br_m else 0.0
    origin_is_victim = bool(_ORIGIN_VICTIM.search(text))
    origin_correct = not (_ORIGIN_WRONG.search(text) or origin_is_victim)

    if origin_is_victim or rev:
        graded = 0.0
    elif origin_correct:
        graded = round(0.5 + 0.5 * recall, 4)
    else:
        graded = round(0.25 * br, 4)
    return {
        "origin_correct": origin_correct,
        "origin_is_victim": origin_is_victim,
        "edge_recall": recall,
        "reversed_edges": rev,
        "blast_radius_jaccard": br,
        "graded_reward": graded,
    }


def graded_of(trial_dir: Path) -> dict | None:
    verifier = Path(trial_dir) / "verifier"
    mf = verifier / "metrics.json"
    if mf.exists():
        try:
            return json.loads(mf.read_text())
        except json.JSONDecodeError:
            pass
    for name in ("test-stdout.txt", "pytest.log"):
        f = verifier / name
        if f.exists():
            m = _from_stdout(f.read_text(errors="replace"))
            if m:
                return m
    if (verifier / "reward.txt").exists():
        return {"graded_reward": 0.0}
    return None
