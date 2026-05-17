#!/usr/bin/env python3
import argparse
import csv
import json
import os
import time
from pathlib import Path

import p167_frontier_repair_benchmark as base


P_DEFAULT = 167
TUPLE_CLASSES_DEFAULT = ("p167_c01", "p167_c05", "p167_c09")
FRONTIER_FIXTURE_DEFAULT = "configs/fixtures/p167_targeted_deep_frontier_repair_candidates.jsonl"
OUTPUT_ROOT_DEFAULT = "outputs/p167_targeted_deep_frontier_repair"
EXPERIMENT_DEFAULT = "p167_targeted_deep_frontier_repair"
OPERATORS_DEFAULT = (
    "score_only_1swap_greedy",
    "exact_joint_2swap_beam_deep",
    "exact_joint_3swap_beam",
    "defect_targeted_destroy_repair_deep",
    "pair_level_partial_defect_repair_deep",
    "restricted_exact_joint_lns_radius3_5",
)
THRESHOLDS = (1000, 800, 600, 500, 400, 300, 240, 200, 180, 160, 120, 100)
OPERATOR_ALIASES = {
    "exact_joint_2swap_beam_deep": "exact_joint_2swap_beam",
    "defect_targeted_destroy_repair_deep": "defect_targeted_destroy_repair",
    "pair_level_partial_defect_repair_deep": "pair_level_partial_defect_repair",
    "restricted_exact_joint_lns_radius3_5": "restricted_exact_joint_lns",
}


def canonical_operator(operator):
    return OPERATOR_ALIASES.get(operator, operator)


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def parse_csv(text):
    return [part.strip() for part in str(text).split(",") if part.strip()]


def build_repair_row(frontier, operator, args):
    p = int(args.p)
    blocks = [set(int(x) for x in block) for block in frontier["blocks"]]
    lam = int(frontier["lambda"])
    seed = (
        int(args.base_seed)
        + int(args.shard_id) * 10000000
        + base.stable_int(frontier["frontier_candidate_id"]) % 100000
        + base.stable_int(operator) % 10000
    )
    score_before = base.P37.score_blocks(p, blocks, lam)
    behavior = canonical_operator(operator)
    result = base.repair_candidate_with_operator(p, blocks, lam, behavior, seed, args)
    after = result["score_after"]
    improvement = int(score_before) - int(after)
    diagnostic_cap = int(args.dmin_sample_count)
    d1, d1_evals = base.restricted_dmin_score(p, result["blocks_after"], lam, [1], diagnostic_cap, seed + 101)
    d2, d2_evals = base.restricted_dmin_score(p, result["blocks_after"], lam, [1, 2], diagnostic_cap, seed + 202)
    d3, d3_evals = base.restricted_dmin_score(p, result["blocks_after"], lam, [1, 2, 3], diagnostic_cap, seed + 303)
    d5, d5_evals = base.restricted_dmin_score(p, result["blocks_after"], lam, [1, 2, 3, 4, 5], diagnostic_cap, seed + 505)
    row = {
        "run_id": args.run_id,
        "shard_id": int(args.shard_id),
        "frontier_candidate_id": frontier["frontier_candidate_id"],
        "source_file": frontier.get("source_file"),
        "tuple_class": frontier["tuple_class"],
        "frontier_bucket": frontier["frontier_bucket"],
        "initial_score": int(frontier["initial_score"]),
        "lambda": int(lam),
        "repair_operator": operator,
        "repair_seed": int(seed),
        "score_before": int(score_before),
        "score_after": int(after),
        "score_improvement": int(improvement),
        "improvement_rate": float(improvement) / float(max(1, score_before)),
        "best_intermediate_score": int(result["best_intermediate_score"]),
        "steps_used": int(result["steps_used"]),
        "beam_width": int(result["beam_width"]),
        "pool_size_remove": int(result["pool_size_remove"]),
        "pool_size_add": int(result["pool_size_add"]),
        "evaluated_moves_count": int(result["evaluated_moves_count"]),
        "exact_joint_evaluations_count": int(result["exact_joint_evaluations_count"]),
        "wall_time_ms": int(result["wall_time_ms"]),
        "timeout_flag": bool(result["timeout_flag"]),
        "D_min_1_full_score": None,
        "D_min_2_score": int(d2),
        "D_min_2_mode": "restricted_exact_joint_sampled",
        "D_min_3_score": int(d3),
        "D_min_3_mode": "restricted_exact_joint_sampled",
        "D_min_5_score": int(d5),
        "D_min_5_mode": "restricted_exact_joint_sampled",
        "D_min_1_restricted_score": int(d1),
        "D_min_1_restricted_evaluations": int(d1_evals),
        "D_min_2_evaluations": int(d2_evals),
        "D_min_3_evaluations": int(d3_evals),
        "D_min_5_evaluations": int(d5_evals),
        "canonical_hash_before": frontier["canonical_hash_before"],
        "canonical_hash_after": base.canonical_hash(result["blocks_after"]),
        "candidate_json_path_if_saved": "",
        "blocks_after": base.candidate_json(result["blocks_after"], p, [len(b) for b in result["blocks_after"]], lam)["blocks"],
    }
    for threshold in THRESHOLDS:
        row["score_after_le_{}".format(threshold)] = bool(int(after) <= threshold)
    return row


def shard_tasks(frontier, operators, shard_id, shard_count):
    tasks = []
    for cand in frontier:
        for operator in operators:
            key = "{}::{}".format(cand["frontier_candidate_id"], operator)
            if base.stable_int(key) % int(shard_count) == int(shard_id):
                tasks.append((cand, operator))
    return tasks


def run_mode(args):
    base.ensure_dir(args.out_dir)
    frontier = base.load_frontier_candidates(args)
    operators = parse_csv(args.operators)
    tasks = shard_tasks(frontier, operators, int(args.shard_id), int(args.shard_count))
    if args.smoke:
        tasks = tasks[: max(1, int(args.smoke_task_limit))]
    rows = [build_repair_row(cand, operator, args) for cand, operator in tasks]
    write_outputs(args, rows, frontier, args.out_dir)
    print("wrote {} targeted deep repair rows to {}".format(len(rows), args.out_dir))


def aggregate_mode(args):
    rows = []
    frontier_by_hash = {}
    for path in Path(args.aggregate_input_dir).rglob("repair_rows.jsonl"):
        rows.extend(base.read_jsonl(str(path)))
    for path in Path(args.aggregate_input_dir).rglob("frontier_candidates.jsonl"):
        for row in base.read_jsonl(str(path)):
            frontier_by_hash[row["canonical_hash_before"]] = row
    frontier = list(frontier_by_hash.values())
    write_outputs(args, rows, frontier, args.out_dir)
    print("aggregated {} targeted deep repair rows to {}".format(len(rows), args.out_dir))


def threshold_rows(rows, threshold):
    return [row for row in rows if int(row["score_after"]) <= int(threshold)]


def closure_shell_audit_rows(rows):
    selected = []
    for row in rows:
        if int(row["score_after"]) <= 500 or int(row["initial_score"]) <= 200:
            selected.append(row)
    return sorted(selected, key=lambda row: (int(row["score_after"]), row["tuple_class"], row["repair_operator"]))


def best_by_tuple(rows, tuple_class):
    group = [row for row in rows if row.get("tuple_class") == tuple_class]
    if not group:
        return None
    return min(group, key=lambda row: int(row["score_after"]))


def decision(rows, operator_summary):
    c01 = best_by_tuple(rows, "p167_c01")
    c05 = best_by_tuple(rows, "p167_c05")
    any_300 = any(int(row["score_after"]) <= 300 for row in rows)
    any_240 = any(int(row["score_after"]) <= 240 for row in rows)
    any_200 = any(int(row["score_after"]) <= 200 for row in rows)
    c09_improved_160 = any(row["tuple_class"] == "p167_c09" and int(row["initial_score"]) <= 164 and int(row["score_after"]) < int(row["initial_score"]) for row in rows)
    if (c01 and int(c01["score_after"]) < 348) or (c05 and int(c05["score_after"]) < 340):
        return "Strong GO"
    if any_300 or any_240 or any_200 or c09_improved_160:
        return "Strong GO"
    baseline = next((row for row in operator_summary if row.get("repair_operator") == "score_only_1swap_greedy"), None)
    if baseline:
        baseline_median = float(baseline.get("median_score_improvement") or 0.0)
        if any(float(row.get("median_score_improvement") or 0.0) > baseline_median * 1.10 for row in operator_summary):
            return "Weak GO"
    return "No GO"


def c09_score160_included(frontier):
    return any(row.get("tuple_class") == "p167_c09" and int(row.get("initial_score") or 0) == 160 for row in frontier)


def write_readme(out_dir, config, frontier, frontier_summary, operator_summary, tuple_operator_summary, bucket_operator_summary, rows):
    best_ops = sorted(operator_summary, key=lambda row: int(row.get("best_score_after") or 10**9))
    best_median = sorted(operator_summary, key=lambda row: -(float(row.get("median_score_improvement") or 0.0)))
    c01 = best_by_tuple(rows, "p167_c01")
    c05 = best_by_tuple(rows, "p167_c05")
    c09 = best_by_tuple(rows, "p167_c09")
    verdict = decision(rows, operator_summary)
    score160_moved = any(row["tuple_class"] == "p167_c09" and int(row["initial_score"]) == 160 and int(row["score_after"]) < 160 for row in rows)
    lines = [
        "# p167 targeted deep frontier repair",
        "",
        "This is a targeted deep repair benchmark on existing p167 frontier candidates. It is not a generator, filter, classifier, or reranker experiment.",
        "",
        "Exact joint multi-swap update used for multi-swap scoring:",
        "",
        "Delta n = h*f_tilde + f*h_tilde + h*h_tilde",
        "",
        "where h = 1_B - 1_R for remove set R and add set B.",
        "",
        "## Run",
        "",
        "- run_id: `{}`".format(config["run_id"]),
        "- frontier candidates: `{}`".format(config["frontier_candidate_count"]),
        "- repair rows: `{}`".format(config["total_repair_rows"]),
        "- operators: `{}`".format(config["operators"]),
        "- shard_count: `{}`".format(config["shard_count"]),
        "- c09 score160 fixture included: `{}`".format(c09_score160_included(frontier)),
        "",
        "## Frontier selection",
        "",
        base.markdown_table(frontier_summary, ["summary_scope", "tuple_class", "frontier_bucket", "candidate_count", "best_initial_score", "median_initial_score"], limit=40),
        "## Operator summary",
        "",
        base.markdown_table(best_ops, ["repair_operator", "candidate_count", "best_score_after", "median_score_improvement", "improvement_rate", "same_compute_yield", "timeout_rate"], limit=20),
        "## Required answers",
        "",
        "1. c01 best 348 improved: `{}` (best now `{}`).".format(bool(c01 and int(c01["score_after"]) < 348), c01["score_after"] if c01 else "none"),
        "2. c05 best 340 improved: `{}` (best now `{}`).".format(bool(c05 and int(c05["score_after"]) < 340), c05["score_after"] if c05 else "none"),
        "3. c09 score160/164/176 fixture moved: `{}` (score160 moved: `{}`, best c09 `{}`).".format(any(row["tuple_class"] == "p167_c09" and int(row["score_after"]) < int(row["initial_score"]) for row in rows), score160_moved, c09["score_after"] if c09 else "none"),
        "4. score300 or below count: `{}`.".format(sum(1 for row in rows if int(row["score_after"]) <= 300)),
        "5. score240 or below count: `{}`.".format(sum(1 for row in rows if int(row["score_after"]) <= 240)),
        "6. score200 or below count: `{}`.".format(sum(1 for row in rows if int(row["score_after"]) <= 200)),
        "7. score180 or below count: `{}`.".format(sum(1 for row in rows if int(row["score_after"]) <= 180)),
        "8. score160 or below count: `{}`.".format(sum(1 for row in rows if int(row["score_after"]) <= 160)),
        "9. score120/100 or below counts: `{}` / `{}`.".format(sum(1 for row in rows if int(row["score_after"]) <= 120), sum(1 for row in rows if int(row["score_after"]) <= 100)),
        "10. Best score operator: `{}`.".format(best_ops[0]["repair_operator"] if best_ops else "none"),
        "11. Best median improvement operator: `{}`.".format(best_median[0]["repair_operator"] if best_median else "none"),
        "12. exact_joint_2swap_deep comparison is in `operator_summary.csv` and `tuple_operator_summary.csv`.",
        "13. exact_joint_3swap added value is visible by comparing against exact_joint_2swap_deep.",
        "14. defect_targeted repair tuple behavior is in `tuple_operator_summary.csv`.",
        "15. pair_level repair reproducibility is in the `pair_level_partial_defect_repair_deep` rows.",
        "16. restricted LNS radius3/5 is in the `restricted_exact_joint_lns_radius3_5` rows.",
        "17. CP-SAT local branching is optional and not in the default operator list.",
        "18. Repair-first verdict: `{}`.".format(verdict),
        "19. Next action: inspect best candidates, then either deepen the winning operator family or redesign c09 trap escape pools.",
        "",
        "## Notes",
        "",
        "- score0, if present, is only a candidate until Sage verifies SDS and HH^T = 668I.",
        "- This run does not claim a Hadamard 668 construction.",
        "- D_min r>=2 diagnostics are restricted sampled/beam proxies unless explicitly marked full.",
    ]
    with open(os.path.join(out_dir, "README.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(out_dir, "next_actions.md"), "w") as f:
        f.write(
            "# next actions\n\n"
            "- If c01/c05 improve below 300, expand the winning operator on those candidates first.\n"
            "- If c09 score160 does not move, treat it as a hard benchmark/trap and redesign c09-specific pools before spending more budget.\n"
            "- If pair-level remains slow but strong, split it into c01/c05-only production runs.\n"
        )


def write_outputs(args, rows, frontier, out_dir):
    base.ensure_dir(out_dir)
    frontier_summary = base.frontier_selection_summary(frontier)
    operator_summary = base.summarize_group(rows, ["repair_operator"])
    tuple_operator_summary = base.summarize_group(rows, ["tuple_class", "repair_operator"])
    bucket_operator_summary = base.summarize_group(rows, ["frontier_bucket", "repair_operator"])
    score0_rows = base.write_score0_candidates(out_dir, rows)
    config = {
        "run_id": args.run_id,
        "p": int(args.p),
        "frontier_candidate_count": len(frontier),
        "total_repair_rows": len(rows),
        "operators": parse_csv(args.operators),
        "max_repair_steps": int(args.max_repair_steps),
        "pool_size": int(args.pool_size),
        "lns_pool_size": int(args.lns_pool_size),
        "lns_radius": int(args.lns_radius),
        "beam_width": int(args.beam_width),
        "eval_cap_per_step": int(args.eval_cap_per_step),
        "max_wall_time_ms": int(args.max_wall_time_ms),
        "shard_id": int(args.shard_id),
        "shard_count": int(args.shard_count),
    }
    base.write_json(os.path.join(out_dir, "run_config.json"), config)
    base.write_json(os.path.join(out_dir, "validation_report.json"), {"score0_candidates": len(score0_rows), "validated_score0_count": 0})
    base.write_jsonl(os.path.join(out_dir, "frontier_candidates.jsonl"), frontier)
    base.write_csv(os.path.join(out_dir, "frontier_selection_summary.csv"), frontier_summary, sorted({k for row in frontier_summary for k in row}))
    base.write_jsonl(os.path.join(out_dir, "repair_rows.jsonl"), rows)
    base.write_csv(os.path.join(out_dir, "repair_rows.csv"), rows, base.REPAIR_FIELDS)
    base.write_csv(os.path.join(out_dir, "operator_summary.csv"), operator_summary, sorted({k for row in operator_summary for k in row}))
    base.write_csv(os.path.join(out_dir, "tuple_operator_summary.csv"), tuple_operator_summary, sorted({k for row in tuple_operator_summary for k in row}))
    base.write_csv(os.path.join(out_dir, "bucket_operator_summary.csv"), bucket_operator_summary, sorted({k for row in bucket_operator_summary for k in row}))
    base.write_jsonl(os.path.join(out_dir, "best_candidates_after_repair.jsonl"), base.best_rows(rows))
    for threshold in (1000, 500, 300, 240, 200, 180, 160, 120, 100):
        base.write_jsonl(os.path.join(out_dir, "score_under_{}_candidates.jsonl".format(threshold)), threshold_rows(rows, threshold))
    audit = closure_shell_audit_rows(rows)
    base.write_csv(os.path.join(out_dir, "closure_shell_audit.csv"), audit, base.REPAIR_FIELDS)
    write_readme(out_dir, config, frontier, frontier_summary, operator_summary, tuple_operator_summary, bucket_operator_summary, rows)


def parse_args():
    parser = argparse.ArgumentParser(description="p167 targeted deep frontier repair benchmark.")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--tuple-classes", default=",".join(TUPLE_CLASSES_DEFAULT))
    parser.add_argument("--tuple-registry", default=base.TUPLE_REGISTRY_DEFAULT)
    parser.add_argument("--frontier-files", default=FRONTIER_FIXTURE_DEFAULT)
    parser.add_argument("--operators", default=",".join(OPERATORS_DEFAULT))
    parser.add_argument("--frontier-count", type=int, default=90)
    parser.add_argument("--max-repair-steps", type=int, default=16)
    parser.add_argument("--pool-size", type=int, default=40)
    parser.add_argument("--lns-pool-size", type=int, default=48)
    parser.add_argument("--lns-radius", type=int, default=5)
    parser.add_argument("--beam-width", type=int, default=16)
    parser.add_argument("--eval-cap-per-step", type=int, default=3000)
    parser.add_argument("--max-wall-time-ms", type=int, default=60000)
    parser.add_argument("--dmin-sample-count", type=int, default=320)
    parser.add_argument("--base-seed", type=int, default=168337)
    parser.add_argument("--shard-id", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--run-id", default="local")
    parser.add_argument("--output-root", default=OUTPUT_ROOT_DEFAULT)
    parser.add_argument("--experiment-name", default=EXPERIMENT_DEFAULT)
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--smoke-task-limit", type=int, default=2)
    parser.add_argument("--aggregate", action="store_true")
    parser.add_argument("--aggregate-input-dir", default="")
    return parser.parse_args()


def main():
    args = parse_args()
    if not args.out_dir:
        safe = args.run_id.replace("/", "-")
        args.out_dir = os.path.join(args.output_root, "{}_{}".format(now_stamp(), safe))
    if args.aggregate:
        aggregate_mode(args)
    else:
        run_mode(args)


if __name__ == "__main__":
    main()
