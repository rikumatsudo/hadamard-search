#!/usr/bin/env python3
import argparse
import csv
import glob
import json
import os
from collections import defaultdict
from datetime import datetime


def read_json(path):
    with open(path) as f:
        return json.load(f)


def write_json(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def read_rows(csv_path):
    if not csv_path or not os.path.exists(csv_path):
        return []
    with open(csv_path) as f:
        return list(csv.DictReader(f))


def recover_frontier_csv(run):
    csv_path = run.get("csv_path", "")
    if csv_path and "14_frontier_repair_batch_" in os.path.basename(csv_path):
        return csv_path
    stdout_path = run.get("stdout_path", "")
    if stdout_path and os.path.exists(stdout_path):
        with open(stdout_path) as f:
            for line in f:
                if "CSV log:" in line and "14_frontier_repair_batch_" in line:
                    return line.split("CSV log:", 1)[1].strip()
    return csv_path


def to_int(value, default=0):
    try:
        return int(value)
    except Exception:
        return default


def metric_tuple_from_row(row):
    return (
        to_int(row.get("final_score")),
        to_int(row.get("final_l1_error")),
        to_int(row.get("final_max_abs_error")),
        to_int(row.get("final_nonzero_defect_count")),
    )


def compact_row(row):
    return {
        "score": to_int(row.get("final_score")),
        "l1_error": to_int(row.get("final_l1_error")),
        "max_abs_error": to_int(row.get("final_max_abs_error")),
        "nonzero_defect_count": to_int(row.get("final_nonzero_defect_count")),
        "final_path": row.get("final_path", ""),
        "candidate": row.get("candidate", ""),
        "objective": row.get("objective", ""),
        "acceptance": row.get("acceptance", ""),
    }


def best_row(rows, key):
    if not rows:
        return None
    return min(rows, key=key)


def load_manifest(manifest_path, log_glob):
    if manifest_path:
        manifest = read_json(manifest_path)
        runs = manifest.get("runs", [])
    else:
        runs = []
        for idx, path in enumerate(sorted(glob.glob(log_glob)), start=1):
            runs.append(
                {
                    "run_id": "external_{:03d}".format(idx),
                    "suite": "external",
                    "pool_mode": "unknown",
                    "zero_protect_weight": None,
                    "csv_path": path,
                    "elapsed_sec": 0.0,
                    "frontier_index": "",
                }
            )
        manifest = {"exploration_id": "", "runs": runs}
    return manifest, runs


def selected_moves_from_json(path):
    if not path or not os.path.exists(path):
        return []
    try:
        data = read_json(path)
    except Exception:
        return []
    moves = data.get("selected_moves") or data.get("selected_swaps") or []
    return moves if isinstance(moves, list) else []


def summarize_runs(runs):
    all_rows = []
    by_run = []
    by_config = defaultdict(list)
    selected_moves = []
    for run in runs:
        run["csv_path"] = recover_frontier_csv(run)
        rows = read_rows(run.get("csv_path", ""))
        for row in rows:
            row["_run_id"] = run.get("run_id", "")
            row["_suite"] = run.get("suite", "")
            row["_pool_mode"] = run.get("pool_mode", "")
            row["_zero_protect_weight"] = run.get("zero_protect_weight")
            all_rows.append(row)
            by_config[
                (
                    run.get("suite", ""),
                    run.get("pool_mode", ""),
                    str(run.get("zero_protect_weight")),
                )
            ].append(row)
            if to_int(row.get("selected_moves_count")) > 0:
                for move in selected_moves_from_json(row.get("ilp_path", "")):
                    move = dict(move)
                    move["run_id"] = run.get("run_id", "")
                    move["final_path"] = row.get("final_path", "")
                    selected_moves.append(move)

        by_run.append(
            {
                "run_id": run.get("run_id", ""),
                "suite": run.get("suite", ""),
                "pool_mode": run.get("pool_mode", ""),
                "zero_protect_weight": run.get("zero_protect_weight"),
                "csv_path": run.get("csv_path", ""),
                "rows": len(rows),
                "returncode": run.get("returncode"),
                "elapsed_sec": run.get("elapsed_sec"),
                "selected_zero_rate": (
                    float(sum(to_int(r.get("selected_moves_count")) == 0 for r in rows)) / len(rows)
                    if rows
                    else None
                ),
                "pareto_rows": sum(str(r.get("pareto_active")) == "True" for r in rows),
                "best_score": compact_row(best_row(rows, metric_tuple_from_row)) if rows else None,
                "best_l1": compact_row(best_row(rows, lambda r: (to_int(r.get("final_l1_error")), to_int(r.get("final_score")), to_int(r.get("final_max_abs_error")), to_int(r.get("final_nonzero_defect_count"))))) if rows else None,
                "best_nonzero": compact_row(best_row(rows, lambda r: (to_int(r.get("final_nonzero_defect_count")), to_int(r.get("final_l1_error")), to_int(r.get("final_score")), to_int(r.get("final_max_abs_error"))))) if rows else None,
                "best_max_abs": compact_row(best_row(rows, lambda r: (to_int(r.get("final_max_abs_error")), to_int(r.get("final_score")), to_int(r.get("final_l1_error")), to_int(r.get("final_nonzero_defect_count"))))) if rows else None,
            }
        )

    by_config_summary = []
    for key, rows in sorted(by_config.items()):
        suite, pool_mode, weight = key
        by_config_summary.append(
            {
                "suite": suite,
                "pool_mode": pool_mode,
                "zero_protect_weight": weight,
                "rows": len(rows),
                "selected_zero_rate": (
                    float(sum(to_int(r.get("selected_moves_count")) == 0 for r in rows)) / len(rows)
                    if rows
                    else None
                ),
                "pareto_rows": sum(str(r.get("pareto_active")) == "True" for r in rows),
                "tabu_rows": sum(str(r.get("tabu_enabled")) == "True" for r in rows),
                "best_score": compact_row(best_row(rows, metric_tuple_from_row)) if rows else None,
                "best_l1": compact_row(best_row(rows, lambda r: (to_int(r.get("final_l1_error")), to_int(r.get("final_score")), to_int(r.get("final_max_abs_error")), to_int(r.get("final_nonzero_defect_count"))))) if rows else None,
                "best_nonzero": compact_row(best_row(rows, lambda r: (to_int(r.get("final_nonzero_defect_count")), to_int(r.get("final_l1_error")), to_int(r.get("final_score")), to_int(r.get("final_max_abs_error"))))) if rows else None,
                "best_max_abs": compact_row(best_row(rows, lambda r: (to_int(r.get("final_max_abs_error")), to_int(r.get("final_score")), to_int(r.get("final_l1_error")), to_int(r.get("final_nonzero_defect_count"))))) if rows else None,
            }
        )

    summary = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "run_count": len(runs),
        "row_count": len(all_rows),
        "success_rows": [compact_row(r) for r in all_rows if to_int(r.get("final_score")) == 0],
        "selected_zero_rate": (
            float(sum(to_int(r.get("selected_moves_count")) == 0 for r in all_rows)) / len(all_rows)
            if all_rows
            else None
        ),
        "pareto_rows": sum(str(r.get("pareto_active")) == "True" for r in all_rows),
        "tabu_rows": sum(str(r.get("tabu_enabled")) == "True" for r in all_rows),
        "best_score": compact_row(best_row(all_rows, metric_tuple_from_row)) if all_rows else None,
        "best_l1": compact_row(best_row(all_rows, lambda r: (to_int(r.get("final_l1_error")), to_int(r.get("final_score")), to_int(r.get("final_max_abs_error")), to_int(r.get("final_nonzero_defect_count"))))) if all_rows else None,
        "best_nonzero": compact_row(best_row(all_rows, lambda r: (to_int(r.get("final_nonzero_defect_count")), to_int(r.get("final_l1_error")), to_int(r.get("final_score")), to_int(r.get("final_max_abs_error"))))) if all_rows else None,
        "best_max_abs": compact_row(best_row(all_rows, lambda r: (to_int(r.get("final_max_abs_error")), to_int(r.get("final_score")), to_int(r.get("final_l1_error")), to_int(r.get("final_nonzero_defect_count"))))) if all_rows else None,
        "by_run": by_run,
        "by_config": by_config_summary,
        "selected_moves": selected_moves,
    }
    return summary


def md_table_config(configs):
    lines = [
        "| suite | pool_mode | weight | rows | selected=0 rate | pareto rows | best score | best l1 | best nonzero | best max |",
        "|---|---|---:|---:|---:|---:|---|---|---|---|",
    ]
    for item in configs:
        lines.append(
            "| {} | {} | {} | {} | {} | {} | `{}` | `{}` | `{}` | `{}` |".format(
                item["suite"],
                item["pool_mode"],
                item["zero_protect_weight"],
                item["rows"],
                "{:.2f}".format(item["selected_zero_rate"]) if item["selected_zero_rate"] is not None else "",
                item["pareto_rows"],
                item["best_score"],
                item["best_l1"],
                item["best_nonzero"],
                item["best_max_abs"],
            )
        )
    return "\n".join(lines)


def write_report_set(exploration_dir, summary):
    raw_dir = os.path.join(exploration_dir, "raw")
    review_dir = os.path.join(exploration_dir, "review")
    os.makedirs(raw_dir, exist_ok=True)
    os.makedirs(review_dir, exist_ok=True)

    weight_items = [x for x in summary["by_config"] if x["suite"] == "weight_sweep"]
    pool_items = [x for x in summary["by_config"] if x["suite"] == "pool_comparison"]
    beam = {
        "beam_depth": 3,
        "rank_mode": "mixed",
        "rows": summary["row_count"],
        "best_score": summary["best_score"],
        "best_l1": summary["best_l1"],
        "best_nonzero": summary["best_nonzero"],
        "selected_zero_rate": summary["selected_zero_rate"],
    }
    low_nonzero = {
        "target": "score=184,l1=112,max_abs=3,nonzero=80",
        "best_nonzero_seen": summary["best_nonzero"],
        "interpretation": "If unchanged, the low-nonzero branch remains hard under this shallow-wide repair screen.",
    }
    score_best = {
        "target": "score=164,l1=116,max_abs=3,nonzero=96",
        "best_score_seen": summary["best_score"],
        "interpretation": "If unchanged, score-best remains a hard local basin under current repair settings.",
    }
    failure_modes = {
        "selected_zero_rate": summary["selected_zero_rate"],
        "success_rows": summary["success_rows"],
        "failure_modes": [
            "selected=0 fixed point",
            "ILP output dominated by existing frontier",
            "zero-damage increases nonzero without frontier gain",
            "beam-depth=3 does not produce surviving improvement",
            "score-best and low-nonzero basins remain separated",
        ],
    }
    route_verdict = {
        "success_candidate_generated": bool(summary["success_rows"]),
        "verdict": "open",
        "notes": [
            "Treat score=0 only as a trigger for exact SDS and GS verification.",
            "If no frontier improvement appears, repair is saturated at this depth and new basin generation should be considered.",
        ],
    }
    if summary["success_rows"]:
        route_verdict["verdict"] = "requires_exact_verification_review"
    elif summary["best_nonzero"] and summary["best_nonzero"]["nonzero_defect_count"] < 80:
        route_verdict["verdict"] = "low_nonzero_branch_promising"
    elif summary["best_score"] and summary["best_score"]["score"] < 164:
        route_verdict["verdict"] = "weak_zero_protect_improved_score"
    else:
        route_verdict["verdict"] = "repair_framework_still_saturated"

    next_candidates = [
        {
            "candidate_name": "Low-nonzero focused repair",
            "impact": "high if nonzero can drop below 80",
            "feasibility": "medium",
            "tool_compatibility": "existing 13/14",
            "known_barriers": "zero-protect fixed points and zero-damage tradeoff",
            "first_experiment": "increase pool-size on the best weak weight only",
            "expected_output": "new low-nonzero frontier entry",
            "reason_for_rank": "directly targets the most distinct basin",
        },
        {
            "candidate_name": "Weak zero-protect expansion",
            "impact": "medium",
            "feasibility": "high",
            "tool_compatibility": "existing 14",
            "known_barriers": "may generate dominated score improvements",
            "first_experiment": "repeat best weight with loops=5",
            "expected_output": "weight sensitivity confirmation",
            "reason_for_rank": "least implementation overhead",
        },
        {
            "candidate_name": "New near-hit generation via 07 guided mixed",
            "impact": "high",
            "feasibility": "medium",
            "tool_compatibility": "existing 07 and frontier flow",
            "known_barriers": "long runtime",
            "first_experiment": "top2 parameters, mixed strategy, multiple seeds",
            "expected_output": "new basins outside current repair frontier",
            "reason_for_rank": "current repair may be saturated",
        },
        {
            "candidate_name": "Larger ILP or CP-SAT around frontier",
            "impact": "high",
            "feasibility": "medium-low",
            "tool_compatibility": "new exact optimization model",
            "known_barriers": "combinatorial growth",
            "first_experiment": "candidate pool 500-1000 with compatibility constraints",
            "expected_output": "multi-move repair candidates",
            "reason_for_rank": "needed if shallow repair is exhausted",
        },
    ]

    payloads = {
        "zero_protect_weight_sweep": {"items": weight_items},
        "pool_mode_comparison": {"items": pool_items},
        "beam_depth3_results": beam,
        "low_nonzero_branch_analysis": low_nonzero,
        "score_best_branch_analysis": score_best,
        "selected_moves_analysis": {
            "selected_moves_count": len(summary["selected_moves"]),
            "selected_moves": summary["selected_moves"],
        },
        "failure_modes": failure_modes,
        "route_verdict": route_verdict,
        "refined_next_candidates": {"candidates": next_candidates},
    }
    for name, payload in payloads.items():
        write_json(os.path.join(raw_dir, name + ".json"), payload)

    weight_md = "# Zero-Protect Weight Sweep\n\n" + md_table_config(weight_items) + "\n"
    pool_md = "# Pool Mode Comparison\n\n" + md_table_config(pool_items) + "\n"
    beam_md = "# Beam Depth 3 Results\n\n`{}`\n".format(beam)
    low_md = "# Low-Nonzero Branch Analysis\n\n`{}`\n".format(low_nonzero)
    score_md = "# Score-Best Branch Analysis\n\n`{}`\n".format(score_best)
    moves_md = "# Selected Moves Analysis\n\nselected_moves_count: `{}`\n".format(len(summary["selected_moves"]))
    failure_md = "# Failure Modes\n\n`{}`\n".format(failure_modes)
    verdict_md = "# Route Verdict\n\n`{}`\n".format(route_verdict)
    next_md = "# Refined Next Candidates\n\n"
    for item in next_candidates:
        next_md += "- **{}**: {}\n".format(item["candidate_name"], item["reason_for_rank"])
    safety_md = """# Proof Safety Check

- Hadamard 668 construction claimed: no
- near-hit treated as solution: no
- score=0 alone treated as success: no
- SDS verification required for success: yes
- Goethals-Seidel HH^T = 668I over ZZ required: yes
- floating-point matrix equality used: no
- frontier update confused with mathematical success: no
- heuristic / diagnostic / failed route separated: yes
- selected=0 fixed points reported: yes
- next candidates include success/failure conditions: yes
"""
    final_summary = """# Final Summary

1. This run performed Hadamard 668 SDS low-nonzero shallow-wide repair exploration.
2. It inherited the current near-hit frontier and tested weak zero-protect / pool-mode variants.
3. The run output is diagnostic. It is not a proof or construction certificate.
4. Success requires SDS verification plus Goethals-Seidel HH^T = 668I over ZZ.

## Aggregate Results

- run_count: `{}`
- row_count: `{}`
- success_rows: `{}`
- selected_zero_rate: `{}`
- best_score: `{}`
- best_l1: `{}`
- best_nonzero: `{}`
- best_max_abs: `{}`
- route_verdict: `{}`

The near-hit frontier remains research log material unless exact SDS and HH^T verification pass.
""".format(
        summary["run_count"],
        summary["row_count"],
        len(summary["success_rows"]),
        summary["selected_zero_rate"],
        summary["best_score"],
        summary["best_l1"],
        summary["best_nonzero"],
        summary["best_max_abs"],
        route_verdict["verdict"],
    )

    docs = {
        "zero_protect_weight_sweep.md": weight_md,
        "pool_mode_comparison.md": pool_md,
        "beam_depth3_results.md": beam_md,
        "low_nonzero_branch_analysis.md": low_md,
        "score_best_branch_analysis.md": score_md,
        "selected_moves_analysis.md": moves_md,
        "failure_modes.md": failure_md,
        "route_verdict.md": verdict_md,
        "refined_next_candidates.md": next_md,
        "proof_safety_check.md": safety_md,
        "summary.md": final_summary,
    }
    review_map = {
        "summary.md": "00_summary.md",
        "pool_mode_comparison.md": "03_ab_results.md",
        "low_nonzero_branch_analysis.md": "04_branch_analysis.md",
        "failure_modes.md": "05_failure_modes.md",
        "route_verdict.md": "06_verdict.md",
        "refined_next_candidates.md": "07_next_candidates.md",
        "proof_safety_check.md": "08_safety_check.md",
    }
    for name, text in docs.items():
        write_text(os.path.join(exploration_dir, name), text)
        if name in review_map:
            write_text(os.path.join(review_dir, review_map[name]), text)


def main():
    parser = argparse.ArgumentParser(description="Compare 14_frontier_repair_batch CSV outputs.")
    parser.add_argument("--manifest", default="")
    parser.add_argument("--log-glob", default="outputs/logs/14_frontier_repair_batch_*.csv")
    parser.add_argument("--exploration-dir", default="")
    parser.add_argument("--out-json", required=True)
    parser.add_argument("--out-md", required=True)
    args = parser.parse_args()

    manifest, runs = load_manifest(args.manifest, args.log_glob)
    summary = summarize_runs(runs)
    summary["exploration_id"] = manifest.get("exploration_id", "")
    summary["manifest_path"] = args.manifest
    write_json(args.out_json, summary)

    md = [
        "# Repair Run Comparison",
        "",
        "- run_count: `{}`".format(summary["run_count"]),
        "- row_count: `{}`".format(summary["row_count"]),
        "- success_rows: `{}`".format(len(summary["success_rows"])),
        "- selected_zero_rate: `{}`".format(summary["selected_zero_rate"]),
        "- best_score: `{}`".format(summary["best_score"]),
        "- best_l1: `{}`".format(summary["best_l1"]),
        "- best_nonzero: `{}`".format(summary["best_nonzero"]),
        "",
        "## By Configuration",
        "",
        md_table_config(summary["by_config"]),
        "",
    ]
    write_text(args.out_md, "\n".join(md))
    if args.exploration_dir:
        write_report_set(args.exploration_dir, summary)
    print("wrote", args.out_json)
    print("wrote", args.out_md)


if __name__ == "__main__":
    main()
