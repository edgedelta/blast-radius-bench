#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# ///
"""
Summarize Harbor results for BlastRadiusBench into a markdown leaderboard.

Reads the per-trial result.json files Harbor writes under a jobs directory and prints:
  - a per-model accuracy table (origin+path pass rate = the primary binary reward)
  - a per-difficulty breakdown

Usage:
    uv run scripts/process_results.py jobs/2026-06-25__10-00-00 [more_job_dirs ...]

Notes:
  - Primary reward is binary (pytest pass/fail) and lives in each trial's
    verifier reward. We read it from result.json (verifier_result.rewards.reward)
    and fall back to the reward.txt the test.sh writes.
  - Secondary metrics (edge-overlap, reversed-edge-rate) are PRINTED by the grader
    into the pytest log; this script reports the headline pass rate. Parse the
    pytest logs if you want to aggregate the secondary numbers.
"""

from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

# scenario -> difficulty (keep in sync with each task.toml)
DIFFICULTY = {
    "db-pool-cascade": "medium",
    "retry-storm-amplification": "hard",
    "noisy-neighbor-node": "hard",
}


def scenario_of(task_name: str) -> str:
    return task_name.split("/")[-1]


def read_reward(result_file: Path, raw: dict) -> float:
    rewards = (raw.get("verifier_result") or {}).get("rewards") or {}
    if "reward" in rewards:
        try:
            return float(rewards["reward"])
        except (TypeError, ValueError):
            pass
    # fallback: reward.txt next to the trial's verifier logs
    for cand in (result_file.parent / "verifier" / "reward.txt",
                 result_file.parent / "logs" / "verifier" / "reward.txt"):
        if cand.exists():
            try:
                return float(cand.read_text().strip())
            except ValueError:
                return 0.0
    return 0.0


def model_display(raw: dict) -> str:
    name = ((raw.get("config") or {}).get("agent") or {}).get("model_name", "unknown")
    return name.split("/")[-1]


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    result_files: list[Path] = []
    for d in sys.argv[1:]:
        p = Path(d)
        if not p.is_dir():
            print(f"warning: {p} is not a directory, skipping", file=sys.stderr)
            continue
        result_files.extend(sorted(p.glob("*/result.json")))

    if not result_files:
        print("No result.json files found.", file=sys.stderr)
        sys.exit(1)

    # (model, scenario) -> [passed_bool, ...]
    by_model_scenario: dict[tuple[str, str], list[bool]] = defaultdict(list)

    for rf in result_files:
        try:
            raw = json.loads(rf.read_text())
        except Exception as e:  # noqa: BLE001
            print(f"  parse error {rf}: {e}", file=sys.stderr)
            continue
        model = model_display(raw)
        scen = scenario_of(raw.get("task_name", "unknown"))
        passed = read_reward(rf, raw) > 0
        by_model_scenario[(model, scen)].append(passed)

    models = sorted({m for (m, _) in by_model_scenario})
    scenarios = sorted({s for (_, s) in by_model_scenario},
                       key=lambda s: (DIFFICULTY.get(s, "z"), s))

    # ── per-model overall accuracy ──────────────────────────────────────────
    print("## BlastRadiusBench — origin+path pass rate\n")
    print("| Model | " + " | ".join(scenarios) + " | Overall |")
    print("|" + "---|" * (len(scenarios) + 2))
    for m in models:
        cells = []
        tot_pass = tot = 0
        for s in scenarios:
            runs = by_model_scenario.get((m, s), [])
            if runs:
                p = sum(runs)
                cells.append(f"{p}/{len(runs)}")
                tot_pass += p
                tot += len(runs)
            else:
                cells.append("-")
        overall = f"{100*tot_pass/tot:.0f}%" if tot else "-"
        print(f"| {m} | " + " | ".join(cells) + f" | {overall} |")

    # ── per-difficulty breakdown ────────────────────────────────────────────
    print("\n## Per-difficulty pass rate\n")
    diffs = sorted({DIFFICULTY.get(s, "unknown") for s in scenarios})
    print("| Model | " + " | ".join(diffs) + " |")
    print("|" + "---|" * (len(diffs) + 1))
    for m in models:
        cells = []
        for d in diffs:
            p = t = 0
            for s in scenarios:
                if DIFFICULTY.get(s) == d:
                    runs = by_model_scenario.get((m, s), [])
                    p += sum(runs)
                    t += len(runs)
            cells.append(f"{100*p/t:.0f}%" if t else "-")
        print(f"| {m} | " + " | ".join(cells) + " |")

    print("\n(Pass = origin_service correct AND propagation-path directed-edge recall >= threshold.)")


if __name__ == "__main__":
    main()
