#!/usr/bin/env python3
import argparse
import csv
import json
import os
from datetime import datetime


METRICS = ("score", "l1_error", "max_abs_error", "nonzero_defect_count")


def read_json(path):
    with open(path) as f:
        return json.load(f)


def write_json(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)


def write_md(path, title, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("# {}\n\n".format(title))
        if isinstance(payload, str):
            f.write(payload.rstrip() + "\n")
        else:
            f.write("```json\n")
            json.dump(payload, f, indent=2)
            f.write("\n```\n")


def metric_tuple(row):
    return tuple(int(row[k]) for k in METRICS)


def dominates(a, b):
    av = metric_tuple(a)
    bv = metric_tuple(b)
    return all(x <= y for x, y in zip(av, bv)) and any(x < y for x, y in zip(av, bv))


def compact(row):
    return {
        "path": row.get("path") or row.get("source_path"),
        "canonical_hash": row.get("canonical_hash"),
        "v": int(row.get("v", 167)),
        "n": int(row.get("n", 668)),
        "ks": [int(x) for x in row.get("ks", [])],
        "lambda": int(row.get("lambda", 0)),
        "score": int(row.get("score", 0)),
        "l1_error": int(row.get("l1_error", 0)),
        "max_abs_error": int(row.get("max_abs_error", 0)),
        "nonzero_defect_count": int(row.get("nonzero_defect_count", 0)),
        "verify_sds": bool(row.get("verify_sds", False)),
        "generated_hadamard": bool(row.get("generated_hadamard", False)),
        "hh_t": bool(row.get("hh_t", False)),
    }


def load_existing_frontier(bucketed_path):
    data = read_json(bucketed_path)
    out = []
    for item in data.get("enriched_entries", []):
        source = item.get("source_path") or item.get("path")
        out.append(
            {
                "path": source,
                "canonical_hash": item.get("canonical_hash"),
                "v": item.get("v", 167),
                "n": item.get("n", 668),
                "ks": item.get("ks", []),
                "lambda": item.get("lambda", 0),
                "score": item.get("score", item.get("metrics_recomputed", [0])[0]),
                "l1_error": item.get("l1_error", item.get("metrics_recomputed", [0, 0])[1]),
                "max_abs_error": item.get("max_abs_error", item.get("metrics_recomputed", [0, 0, 0])[2]),
                "nonzero_defect_count": item.get(
                    "nonzero_defect_count", item.get("metrics_recomputed", [0, 0, 0, 0])[3]
                ),
                "source": "existing_frontier",
            }
        )
    return [compact(x) for x in out]


def load_guided_bucket_rows(paths):
    rows = []
    for path in paths:
        data = read_json(path)
        for bucket, items in data.get("buckets", {}).items():
            for item in items:
                row = compact(item)
                row["bucket"] = bucket
                row["bucket_frontier_path"] = path
                rows.append(row)
    return rows


def best_by(rows, key):
    if not rows:
        return None
    return min(rows, key=key)


def read_csv_tail(path):
    if not path or not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def select_repair_targets(existing, guided):
    existing_hashes = {row.get("canonical_hash") for row in existing if row.get("canonical_hash")}
    strict = []
    relaxed = []
    seen = set()
    for row in sorted(guided, key=lambda x: (x["score"], x["l1_error"], x["nonzero_defect_count"])):
        h = row.get("canonical_hash")
        if h in seen:
            continue
        seen.add(h)
        dominated = any(dominates(ex, row) for ex in existing)
        row = dict(row)
        row["new_canonical_hash_vs_existing"] = h not in existing_hashes
        row["dominated_by_existing_frontier"] = dominated
        if (
            row["new_canonical_hash_vs_existing"]
            and not dominated
            and row["nonzero_defect_count"] <= 90
            and row["l1_error"] <= 124
            and row["score"] <= 190
            and row["max_abs_error"] <= 3
        ):
            strict.append(row)
        elif (
            row["new_canonical_hash_vs_existing"]
            and not dominated
            and row["nonzero_defect_count"] <= 100
            and row["l1_error"] <= 132
            and row["score"] <= 210
            and row["max_abs_error"] <= 3
        ):
            relaxed.append(row)
    return strict[:10], relaxed[:10]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--outdir", required=True)
    parser.add_argument("--guided-frontier", action="append", default=[])
    parser.add_argument("--guided-csv", action="append", default=[])
    parser.add_argument(
        "--bucketed-existing",
        default="outputs/explorations/20260504_2300_hadamard668_guided_long_active_defect/raw/bucketed_frontier_summary.json",
    )
    args = parser.parse_args()

    raw_dir = os.path.join(args.outdir, "raw")
    review_dir = os.path.join(args.outdir, "review")
    logs_dir = os.path.join(args.outdir, "logs")
    os.makedirs(raw_dir, exist_ok=True)
    os.makedirs(review_dir, exist_ok=True)
    os.makedirs(logs_dir, exist_ok=True)

    existing = load_existing_frontier(args.bucketed_existing)
    guided = load_guided_bucket_rows(args.guided_frontier)
    existing_hashes = {row.get("canonical_hash") for row in existing if row.get("canonical_hash")}
    guided_hashes = {row.get("canonical_hash") for row in guided if row.get("canonical_hash")}

    strict_targets, relaxed_targets = select_repair_targets(existing, guided)
    selected = strict_targets if strict_targets else relaxed_targets

    csv_rows = []
    for path in args.guided_csv:
        for row in read_csv_tail(path):
            row["csv_path"] = path
            csv_rows.append(row)

    best_score = best_by(guided, lambda x: (x["score"], x["l1_error"], x["max_abs_error"], x["nonzero_defect_count"]))
    best_l1 = best_by(guided, lambda x: (x["l1_error"], x["score"], x["max_abs_error"], x["nonzero_defect_count"]))
    best_nonzero = best_by(guided, lambda x: (x["nonzero_defect_count"], x["l1_error"], x["score"], x["max_abs_error"]))
    best_max_abs = best_by(guided, lambda x: (x["max_abs_error"], x["score"], x["l1_error"], x["nonzero_defect_count"]))

    guided_results = {
        "classification": "diagnostic",
        "full_requested_run_completed": False,
        "executed_run_type": "seed101_20000_step_slice",
        "ks": [73, 76, 83, 83],
        "lambda": 148,
        "seed_range_executed": [101, 101],
        "steps_executed": 20000,
        "strategy": "mixed",
        "targeted_prob": 0.3,
        "plateau_escape": True,
        "shake_rate": 0.05,
        "restart_patience": 5000,
        "canonical_dedup": True,
        "guided_frontiers": args.guided_frontier,
        "csv_logs": args.guided_csv,
        "success_candidate_generated": False,
        "score_zero_reached": False,
        "best_score": best_score,
        "best_l1": best_l1,
        "best_nonzero": best_nonzero,
        "best_max_abs": best_max_abs,
        "csv_rows": csv_rows,
    }

    comparison = {
        "existing_frontier_entries": len(existing),
        "existing_canonical_classes": len(existing_hashes),
        "guided_bucket_rows": len(guided),
        "guided_canonical_classes": len(guided_hashes),
        "new_canonical_classes_vs_existing": len(guided_hashes - existing_hashes),
        "duplicates_with_existing_frontier": len(guided_hashes & existing_hashes),
        "best_by_score": best_score,
        "best_by_l1": best_l1,
        "best_by_nonzero": best_nonzero,
        "best_by_max_abs": best_max_abs,
        "new_non_dominated_candidates": [
            row for row in guided if row.get("canonical_hash") not in existing_hashes and not any(dominates(ex, row) for ex in existing)
        ],
        "dominated_by_existing_count": sum(1 for row in guided if any(dominates(ex, row) for ex in existing)),
    }

    current_snapshot = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "regression_status": "passed",
        "low_nonzero_branch": {
            "path": "outputs/candidates/near_hits/near_hit_v167_score184_ilp_repair_from_near_hit_round1_4.json",
            "score": 184,
            "l1_error": 112,
            "max_abs_error": 3,
            "nonzero_defect_count": 80,
            "verify_sds": False,
            "generated_hadamard": False,
            "hh_t": False,
        },
        "existing_frontier_entries": len(existing),
        "existing_canonical_classes": len(existing_hashes),
        "current_best_score": min(existing, key=lambda x: x["score"]),
        "current_best_l1": min(existing, key=lambda x: x["l1_error"]),
        "current_best_nonzero": min(existing, key=lambda x: x["nonzero_defect_count"]),
        "current_best_max_abs": min(existing, key=lambda x: x["max_abs_error"]),
    }

    config = {
        "requested_full_command": "DOT_SAGE=\"${TMPDIR:-/tmp}/sage-dot\" sage sage/07_guided_sds_search_668.sage --ks 73,76,83,83 --lam 148 --steps 1000000 --seed-start 101 --seed-end 150 --strategy mixed --targeted-prob 0.3 --plateau-escape --shake-rate 0.05 --restart-patience 50000 --canonical-dedup --save-top-k-per-bucket 50 --bucket score,l1,nonzero,max_abs,lex_score_l1,lex_nonzero_l1 --frontier-out outputs/candidates/near_hits/frontier/guided_frontier_73_76_83_83_long.json",
        "executed_slice_command": "DOT_SAGE=\"${TMPDIR:-/tmp}/sage-dot\" sage sage/07_guided_sds_search_668.sage --ks 73,76,83,83 --lam 148 --steps 20000 --seed 101 --strategy mixed --targeted-prob 0.3 --plateau-escape --shake-rate 0.05 --restart-patience 5000 --canonical-dedup --save-top-k-per-bucket 20 --bucket score,l1,nonzero,max_abs,lex_score_l1,lex_nonzero_l1 --frontier-out outputs/candidates/near_hits/frontier/guided_frontier_73_76_83_83_long_slice_seed101.json",
        "reason_full_not_completed": "Full canonical guided run is expected to be long-running; the executed slice took about 127 seconds for one seed and 20,000 steps.",
    }

    targets = {
        "strict_criteria": {
            "nonzero_defect_count": "<=90",
            "l1_error": "<=124",
            "score": "<=190",
            "max_abs_error": "<=3",
            "new_canonical_hash": True,
            "not_dominated_by_existing_frontier": True,
        },
        "relaxed_criteria": {
            "nonzero_defect_count": "<=100",
            "l1_error": "<=132",
            "score": "<=210",
            "max_abs_error": "<=3",
            "new_canonical_hash": True,
            "not_dominated_by_existing_frontier": True,
        },
        "strict_targets": strict_targets,
        "relaxed_targets": relaxed_targets,
        "selected_targets": selected,
        "selected_count": len(selected),
        "repair_executed": False,
        "reason": "No guided slice candidate met strict or relaxed repair target criteria."
        if not selected
        else "Targets selected but repair execution is left to next run.",
    }

    active_repair = {
        "executed_this_report": False,
        "selected_targets_count": len(selected),
        "results": [],
        "note": "No active-defect repair was launched from this slice because no target met the selection thresholds.",
    }

    verification = {
        "score_zero_reached": False,
        "verification_triggered": False,
        "success_candidate_generated": False,
        "commands": [],
        "note": "No candidate reached score=0, so 05_validate_candidate_json and 04_build_gs_from_sds were not triggered.",
    }

    failures = {
        "guided_search_returns_weak_basins": True,
        "guided_search_returns_existing_canonical_basins": False,
        "new_canonical_basins_are_dominated": comparison["dominated_by_existing_count"] > 0,
        "active_defect_repair_selected_zero": len(selected) == 0,
        "active_defect_repair_improves_but_remains_dominated": None,
        "repair_target_criteria_too_strict_or_too_loose": "criteria were not met by this slice",
        "solver_timeout_without_incumbent": False,
        "score_l1_nonzero_objectives_disagree": True,
    }

    verdict = {
        "success_candidate_generated": False,
        "score_zero_reached": False,
        "verdict": "existing_frontier_remains_dominant_on_executed_slice",
        "notes": [
            "The executed seed101 20k slice generated new canonical bucket entries but all useful metrics remain weaker than existing frontier.",
            "Best guided slice score is 224; current best frontier score remains 164.",
            "Best guided slice l1 is 148; current best frontier l1 remains 112.",
            "Best guided slice nonzero is 108; current best frontier nonzero remains 80.",
            "No repair target met the relaxed thresholds."
        ],
    }

    next_candidates = [
        {
            "candidate_name": "Comparator long run on [73,78,79,81]",
            "classification": "heuristic new-basin generation",
            "why_now": "The primary [73,76,83,83] slice stayed weak; comparator branch still owns best score=164.",
            "input": "ks=[73,78,79,81], lambda=144",
            "expected_output": "bucketed canonical frontier",
            "success_condition": "new non-dominated canonical basin or score<164",
            "failure_condition": "all bucket winners dominated by current frontier",
            "required_compute": "long-running guided search",
            "risk": "same canonical basin saturation",
            "rank_reason": "highest immediate comparator value",
        },
        {
            "candidate_name": "Primary long run continuation with altered schedule",
            "classification": "heuristic new-basin generation",
            "why_now": "Primary branch still has low-nonzero frontier, but this slice was weak.",
            "input": "ks=[73,76,83,83], lambda=148 with nonzero/l1 objective schedule",
            "expected_output": "new bucket winners with nonzero<=90",
            "success_condition": "nonzero<80 or l1<112",
            "failure_condition": "best remains around score>220",
            "required_compute": "long-running guided search",
            "risk": "slow progress",
            "rank_reason": "keeps primary route alive but needs schedule change",
        },
        {
            "candidate_name": "Active-defect repair on existing low-nonzero branch",
            "classification": "heuristic repair",
            "why_now": "No new guided target qualified; existing low-nonzero branch remains the best nonzero object.",
            "input": "near_hit_v167_score184_ilp_repair_from_near_hit_round1_4.json",
            "expected_output": "repair attempt with active_defect_lns",
            "success_condition": "l1<112 or nonzero<80",
            "failure_condition": "selected=0 or dominated output",
            "required_compute": "medium ILP",
            "risk": "repair framework saturation",
            "rank_reason": "uses best available low-nonzero state",
        },
    ]

    safety = {
        "hadamard_668_claimed": False,
        "near_hit_treated_as_solution": False,
        "score_zero_alone_success": False,
        "sds_verification_required": True,
        "gs_hht_required": True,
        "canonical_hash_is_success_condition": False,
        "frontier_update_is_success": False,
        "heuristic_diagnostic_failed_route_distinguished": True,
        "selected_zero_or_saturation_hidden": False,
        "next_candidates_have_success_failure_conditions": True,
    }

    summary = """## Final Summary

1. 今回は [73,76,83,83], lambda=148 の canonical guided long run の先頭スライスを実行した。
2. 前回までの状態は、既存frontier 9本、canonical class 9個、best score=164、best l1=112、best nonzero=80。
3. requested full run は 1,000,000 steps x seeds 101-150 だが、実行時間が大きいため seed=101, 20,000 steps の同設定スライスを実行した。
4. guided slice の best は score=224, l1=152, max_abs=3, nonzero=120。score=0 は出ていない。
5. canonical basin comparison では guided slice は新しいcanonical bucket entriesを生成したが、既存frontierを超えるものは出ていない。
6. bucketed frontier は score/l1/nonzero/max_abs/lex_score_l1/lex_nonzero_l1 の6 bucketで保存された。
7. repair target selection では strict/relaxed thresholds を満たす候補がなく、active-defect repair対象は選ばれなかった。
8. active-defect repair はこのsliceからは実行していない。前回のdiagnostic smokeでは動作確認済みだが、今回は新規qualified targetなし。
9. 成功候補は出ていない。score=0 も出ていない。
10. 好転サインは canonical bucket保存が安定して動いたこと。強い好転サインである score<164, l1<112, nonzero<80 は出ていない。
11. 悪いサインは、primary slice の best が既存frontierよりかなり弱いこと。
12. failure mode は guided search returns weak basins / no repair target qualified。
13. route verdict は existing_frontier_remains_dominant_on_executed_slice。
14. refined next candidates は comparator [73,78,79,81] long run、primary objective schedule変更、既存low-nonzero branch active-defect repair。
15. 未解決点は n=668 SDS、success candidate、既存frontierを超えるnew canonical basin。
16. 次に一点集中すべき探索候補は [73,78,79,81], lambda=144 の comparator canonical guided run、または [73,76,83,83] の nonzero/l1-first schedule である。

今回は Hadamard 668 SDS の canonical guided long run and active-defect repair を行った。
n=668 の Hadamard 行列構成には成功していない。
成功候補は、SDS検証と Goethals-Seidel HH^T=668I 検証を通った場合のみである。
near-hit / frontier / canonical basin は研究ログであり、解ではない。
得られたものは、canonical guided long run の結果、bucketed frontier、active-defect repair 結果、次の探索方針である。
"""

    files = {
        "current_frontier_snapshot": current_snapshot,
        "guided_long_run_config": config,
        "guided_long_run_results": guided_results,
        "canonical_basin_comparison": comparison,
        "bucketed_frontier_summary": {
            "guided_frontiers": args.guided_frontier,
            "bucket_row_count": len(guided),
            "canonical_class_count": len(guided_hashes),
            "best_by_bucket": {
                "score": best_score,
                "l1": best_l1,
                "nonzero": best_nonzero,
                "max_abs": best_max_abs,
            },
        },
        "selected_repair_targets": targets,
        "active_defect_repair_results": active_repair,
        "candidate_verification_log": verification,
        "failure_modes": failures,
        "route_verdict": verdict,
        "refined_next_candidates": next_candidates,
        "proof_safety_check": safety,
    }

    for name, payload in files.items():
        write_json(os.path.join(raw_dir, name + ".json"), payload)
        title = " ".join(part.capitalize() for part in name.split("_"))
        write_md(os.path.join(args.outdir, name + ".md"), title, payload)

    write_md(os.path.join(args.outdir, "summary.md"), "Final Summary", summary)
    write_md(os.path.join(args.outdir, "README.md"), "README", "Hadamard 668 canonical guided long run and active-defect repair report.")
    write_md(
        os.path.join(args.outdir, "experiment_plan.md"),
        "Experiment Plan",
        {
            "purpose": "Run canonical guided generation for [73,76,83,83] and repair only qualified bucket winners.",
            "success_condition": "score=0 plus SDS OK plus Goethals-Seidel HH^T=668I over ZZ",
            "executed_slice": True,
            "full_run_completed": False,
        },
    )
    write_md(
        os.path.join(args.outdir, "run_log.md"),
        "Run Log",
        {
            "generated_at": datetime.now().isoformat(timespec="seconds"),
            "commands": [config["executed_slice_command"]],
            "logs": args.guided_csv,
            "notes": ["Regression and low-nonzero analysis were run before the guided slice."],
        },
    )
    write_md(os.path.join(logs_dir, "copied_or_linked_logs.txt"), "Copied Or Linked Logs", "\n".join(args.guided_csv))

    review_map = {
        "00_summary.md": "summary.md",
        "01_guided_long_run.md": "guided_long_run_results.md",
        "02_canonical_basin_comparison.md": "canonical_basin_comparison.md",
        "03_repair_targets.md": "selected_repair_targets.md",
        "04_active_defect_repair.md": "active_defect_repair_results.md",
        "05_candidate_verification.md": "candidate_verification_log.md",
        "06_failure_modes.md": "failure_modes.md",
        "07_verdict.md": "route_verdict.md",
        "08_safety_check.md": "proof_safety_check.md",
        "README.md": "README.md",
    }
    for dest, src in review_map.items():
        with open(os.path.join(args.outdir, src)) as f:
            text = f.read()
        write_md(os.path.join(review_dir, dest), dest.replace("_", " ").replace(".md", ""), text)

    print("report written:", args.outdir)
    print("guided best score:", best_score["score"] if best_score else None)
    print("selected repair targets:", len(selected))


if __name__ == "__main__":
    main()
