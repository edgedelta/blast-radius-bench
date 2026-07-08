#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# ///
"""Summarise Harbor result.json files into markdown tables.

Harbor writes one `result.json` per trial under `jobs/<run>/<trial>/result.json`,
with a top-level `task_name`, the agent at `config.agent.model_name`, and the
reward at `verifier_result.rewards.reward` (1.0 = passed, 0.0 = failed).

Scenarios and their difficulty are discovered dynamically — scenarios from the
trials actually present, difficulty from each scenario's `datasets/*/<scenario>/
task.toml`. Nothing is hardcoded, so every scenario in a run is always counted.

Usage:
    uv run scripts/process_results.py jobs/<run> [more_job_dirs ...]

Prints: per-model overall pass rate, a scenario x model matrix, a per-difficulty
breakdown, and an explicit list of every failing (model, scenario) trial.
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from blastradius_metrics import graded_of

try:
    import tomllib  # py3.11+
except ModuleNotFoundError:  # pragma: no cover
    tomllib = None


def reward_of(result: dict, trial_dir: Path) -> float:
    vr = result.get("verifier_result") or {}
    rewards = vr.get("rewards") or {}
    if "reward" in rewards:
        return float(rewards["reward"])
    # fallback: the raw reward.txt the verifier writes
    rt = trial_dir / "verifier" / "reward.txt"
    if rt.exists():
        try:
            return float(rt.read_text().strip() or 0.0)
        except ValueError:
            return 0.0
    return 0.0


def model_of(result: dict) -> str:
    name = (result.get("config", {}).get("agent", {}) or {}).get("model_name") or "unknown"
    return name.split("/")[-1]


def difficulty_of(scenario: str, cache: dict[str, str]) -> str:
    if scenario in cache:
        return cache[scenario]
    diff = "unknown"
    matches = list(Path("datasets").glob(f"*/{scenario}/task.toml"))
    if matches:
        text = matches[0].read_text()
        if tomllib:
            try:
                diff = (tomllib.loads(text).get("metadata", {}) or {}).get("difficulty", "unknown")
            except Exception:
                pass
        if diff == "unknown":  # tomllib-free fallback
            for line in text.splitlines():
                s = line.strip()
                if s.startswith("difficulty"):
                    diff = s.split("=", 1)[1].strip().strip('"').strip("'")
                    break
    cache[scenario] = diff
    return diff


def collect(job_dirs: list[Path]):
    cells: dict[tuple[str, str], list[float]] = defaultdict(list)
    graded_cells: dict[tuple[str, str], list[float]] = defaultdict(list)
    files: list[Path] = []
    for d in job_dirs:
        files.extend(sorted(d.glob("*/result.json")))
    if not files:
        print("No result.json files found under the given job dir(s).", file=sys.stderr)
        sys.exit(1)
    for f in files:
        try:
            r = json.loads(f.read_text())
        except Exception as e:
            print(f"  skip {f}: {e}", file=sys.stderr)
            continue
        scenario = r.get("task_name") or f.parent.name.split("__")[0]
        key = (model_of(r), scenario)
        cells[key].append(reward_of(r, f.parent))
        graded = graded_of(f.parent)
        if graded and graded.get("graded_reward") is not None:
            graded_cells[key].append(float(graded["graded_reward"]))
    return cells, graded_cells, len(files)


def pct(rewards: list[float]) -> str:
    if not rewards:
        return "—"
    passed = sum(1 for x in rewards if x >= 1.0)
    return f"{100 * passed / len(rewards):.0f}% ({passed}/{len(rewards)})"


def graded_str(vals: list[float]) -> str:
    """Mean graded reward (0 for cardinal sins, else origin+chain credit) ± 95% CI."""
    if not vals:
        return "—"
    mean = sum(vals) / len(vals)
    if len(vals) < 2:
        return f"{mean:.3f}"
    var = sum((x - mean) ** 2 for x in vals) / (len(vals) - 1)
    ci = 1.96 * (var ** 0.5) / (len(vals) ** 0.5)
    return f"{mean:.3f} ± {ci:.3f}"


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    job_dirs = [Path(p) for p in sys.argv[1:]]
    cells, graded_cells, n = collect(job_dirs)

    models = sorted({m for (m, _) in cells})
    scenarios = sorted({s for (_, s) in cells})
    diff_cache: dict[str, str] = {}
    difficulties = sorted({difficulty_of(s, diff_cache) for s in scenarios})

    print(f"\n# Benchmark results — {n} trials, {len(models)} models, {len(scenarios)} scenarios\n")

    # Per-model overall — ranked on mean graded reward (finer than pass rate),
    # pass rate shown alongside as the headline binary.
    print("## Overall\n")
    print("| Model | Mean graded reward (95% CI) | Pass rate |")
    print("|---|---|---|")
    overall = []
    for m in models:
        rw = [x for (mm, _), xs in cells.items() if mm == m for x in xs]
        gr = [x for (mm, _), xs in graded_cells.items() if mm == m for x in xs]
        overall.append((m, rw, gr))
    for m, rw, gr in sorted(overall,
                            key=lambda kv: -(sum(kv[2]) / len(kv[2]) if kv[2] else 0)):
        print(f"| {m} | {graded_str(gr)} | {pct(rw)} |")

    # Scenario x model matrix (scenarios as rows — readable for many scenarios)
    print("\n## By scenario\n")
    print("| Scenario | difficulty | " + " | ".join(models) + " |")
    print("|---|---|" + "---|" * len(models))
    for s in scenarios:
        cellvals = [pct(cells.get((m, s), [])) for m in models]
        print(f"| {s} | {difficulty_of(s, diff_cache)} | " + " | ".join(cellvals) + " |")

    # Per-difficulty breakdown (pass rate + mean graded reward per tier)
    print("\n## By difficulty\n")
    print("| Model | " + " | ".join(f"{d} | {d} graded" for d in difficulties) + " |")
    print("|---|" + "---|" * (2 * len(difficulties)))
    for m in models:
        row = [m]
        for d in difficulties:
            rw = [x for (mm, s), xs in cells.items()
                  if mm == m and difficulty_of(s, diff_cache) == d for x in xs]
            gr = [x for (mm, s), xs in graded_cells.items()
                  if mm == m and difficulty_of(s, diff_cache) == d for x in xs]
            row.append(pct(rw))
            row.append(graded_str(gr))
        print("| " + " | ".join(row) + " |")

    # Explicit failures (what the old script masked)
    fails = sorted((m, s) for (m, s), xs in cells.items() for x in xs if x < 1.0)
    print(f"\n## Failures ({len(fails)})\n")
    if fails:
        for m, s in fails:
            print(f"- {m} — {s}")
    else:
        print("None — every trial passed.")
    print()


if __name__ == "__main__":
    main()
