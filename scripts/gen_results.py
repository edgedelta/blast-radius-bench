#!/usr/bin/env python3
"""Emit benchmark-results/<bench>/{results.json, summary.json} from a Harbor job dir.

results.json : one record per (task x model x attempt) — outcome + cost/token/timing
               metadata (no trajectories; structured fields only, no local paths).
summary.json : TotalRuns/Passed/Failed/Cost + ByModel and ByTask rollups.

Usage: gen_results.py <job_dir> <out_dir>
"""
import json, glob, os, sys
from collections import defaultdict
from datetime import datetime

job_dir, out_dir = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)

def parse(t):
    try:
        return datetime.fromisoformat((t or "").replace("Z", "+00:00"))
    except Exception:
        return None

rows = []
for f in sorted(glob.glob(job_dir + "/*__*/result.json")):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    ar = d.get("agent_result") or {}
    reward = ((d.get("verifier_result") or {}).get("rewards") or {}).get("reward")
    s, e = parse(d.get("started_at")), parse(d.get("finished_at"))
    dur = round((e - s).total_seconds(), 1) if s and e else None
    model = ((d.get("config", {}) or {}).get("agent", {}) or {}).get("model_name", "") or ""
    ei = d.get("exception_info") or {}
    rows.append({
        "TaskName": d.get("task_name"),
        "ModelName": model,
        "ModelDisplay": model.split("openrouter/")[-1],
        "Passed": reward is not None and float(reward) >= 1.0,
        "Reward": reward,
        "CostUSD": ar.get("cost_usd"),
        "InputTokens": ar.get("n_input_tokens"),
        "OutputTokens": ar.get("n_output_tokens"),
        "CacheTokens": ar.get("n_cache_tokens"),
        "DurationSec": dur,
        "StartedAt": d.get("started_at"),
        "FinishedAt": d.get("finished_at"),
        "Error": ei.get("exception_type", "") if ei else "",
        "TrialDir": os.path.basename(os.path.dirname(f)),
    })

cnt = defaultdict(int)
for r in rows:
    k = (r["TaskName"], r["ModelName"]); cnt[k] += 1; r["Attempt"] = cnt[k]

def agg(items):
    runs = len(items); passed = sum(1 for r in items if r["Passed"])
    cost = sum(r["CostUSD"] or 0 for r in items)
    durs = [r["DurationSec"] for r in items if r["DurationSec"] is not None]
    return {
        "Runs": runs, "Passed": passed, "Failed": runs - passed,
        "PassRate": round(100 * passed / runs, 1) if runs else 0,
        "TotalCostUSD": round(cost, 4), "AvgCostUSD": round(cost / runs, 4) if runs else 0,
        "AvgDurationSec": round(sum(durs) / len(durs), 1) if durs else None,
    }

mg, tg = defaultdict(list), defaultdict(list)
for r in rows:
    mg[r["ModelName"]].append(r); tg[r["TaskName"]].append(r)
summary = {
    "TotalRuns": len(rows),
    "TotalPassed": sum(1 for r in rows if r["Passed"]),
    "TotalFailed": sum(1 for r in rows if not r["Passed"]),
    "TotalCostUSD": round(sum(r["CostUSD"] or 0 for r in rows), 2),
    "ByModel": dict(sorted({m: agg(it) for m, it in mg.items()}.items(),
                           key=lambda kv: -kv[1]["PassRate"])),
    "ByTask": {t: agg(it) for t, it in sorted(tg.items())},
}

json.dump(rows, open(out_dir + "/results.json", "w"), indent=1)
json.dump(summary, open(out_dir + "/summary.json", "w"), indent=1)
print(f"wrote {len(rows)} trials -> {out_dir}  (models={len(mg)} tasks={len(tg)})")
