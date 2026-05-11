from sage.all import *

import argparse
import json
import math
import os
import shutil
import time


SCRIPT_NAME = "78_p167_stage5_candidate_deepening"
STAGE2_LIB_PATH = "sage/75_p167_stage2_survivor_deepening.sage"
DEFAULT_CONFIG = "configs/experiments/p167_stage5_candidate_deepening.yaml"
DEFAULT_TUPLE_REGISTRY = "configs/fixtures/p167_tuple_classes.json"
DEFAULT_STAGE4_ARTIFACT = "/tmp/hadamard-stage4-medium-40-aggregate"


def load_stage2_lib():
    namespace = {"__name__": "stage2_lib"}
    with open(STAGE2_LIB_PATH) as f:
        code = compile(f.read(), STAGE2_LIB_PATH, "exec")
    exec(code, namespace)
    return namespace


S2 = load_stage2_lib()
S2["SCRIPT_NAME"] = SCRIPT_NAME

ensure_dir = S2["ensure_dir"]
json_safe = S2["json_safe"]
write_json = S2["write_json"]
write_jsonl = S2["write_jsonl"]
write_csv = S2["write_csv"]
read_jsonl = S2["read_jsonl"]
parse_list = S2["parse_list"]
parse_int_list = S2["parse_int_list"]
deterministic_seed = S2["deterministic_seed"]
stable_hash = S2["stable_hash"]
load_tuple_registry = S2["load_tuple_registry"]
score_counts = S2["score_counts"]
total_diff_counts = S2["total_diff_counts"]
rho_vector = S2["rho_vector"]
apply_move = S2["apply_move"]
apply_sparse_delta = S2["apply_sparse_delta"]
state_hash = S2["state_hash"]
json_blocks = S2["json_blocks"]
rows_by_key = S2["rows_by_key"]
median = S2["median"]
summarize = S2["summarize"]
ORIGINAL_CHOOSE_STAGE2_MOVE = S2["choose_stage2_move"]
ORIGINAL_EMIT_STAGE2_SNAPSHOT = S2["emit_stage2_snapshot"]


STAGE5_OPERATORS = (
    "stage5_mixed_operator_adaptive",
    "stage5_exact_joint_local_repair",
    "stage5_pair_profile_movespace_filter",
    "stage5_baseline_score_only",
)

STAGE5_TO_STAGE2_OPERATOR = {
    "stage5_mixed_operator_adaptive": "survivor_mixed_operator_adaptive",
    "stage5_exact_joint_local_repair": "survivor_exact_joint_local_repair",
    "stage5_pair_profile_movespace_filter": "survivor_pair_profile_movespace_filter",
    "stage5_baseline_score_only": "survivor_baseline_score_only",
    # Accept Stage 4 names in optional budget plans and normalize at task build.
    "stage4_mixed_operator_adaptive": "survivor_mixed_operator_adaptive",
    "stage4_exact_joint_local_repair": "survivor_exact_joint_local_repair",
    "stage4_pair_profile_movespace_filter": "survivor_pair_profile_movespace_filter",
    "stage4_baseline_score_only": "survivor_baseline_score_only",
}

STAGE4_TO_STAGE5_OPERATOR = {
    "stage4_mixed_operator_adaptive": "stage5_mixed_operator_adaptive",
    "stage4_exact_joint_local_repair": "stage5_exact_joint_local_repair",
    "stage4_pair_profile_movespace_filter": "stage5_pair_profile_movespace_filter",
    "stage4_baseline_score_only": "stage5_baseline_score_only",
}


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def safe_float(value, default=None):
    try:
        if value is None or value == "":
            return default
        out = float(value)
        if math.isnan(out):
            return default
        return out
    except Exception:
        return default


def stage4_paths(stage4_artifact):
    root = stage4_artifact
    if not os.path.isdir(root):
        raise RuntimeError("Stage 4 artifact path does not exist: {}".format(root))
    paths = {
        "recommendations": os.path.join(root, "stage5_candidate_recommendations.jsonl"),
        "trajectory": os.path.join(root, "trajectory_level_records.jsonl"),
        "run": os.path.join(root, "run_level_records.jsonl"),
        "candidates": os.path.join(root, "input_stage4_candidates_deduped.jsonl"),
        "candidate_summary": os.path.join(root, "candidate_summary.json"),
    }
    for name, path in paths.items():
        if name == "candidate_summary":
            continue
        if not os.path.exists(path):
            raise RuntimeError("Stage 4 artifact missing {}: {}".format(name, path))
    return paths


def stage5_recommendation_score(row):
    rec_weight = {
        "production_deep_search": 20.0,
        "repair_target": 12.0,
        "operator_benchmark": 4.0,
        "needs_more_diagnostics": 2.0,
        "archive": 0.0,
    }
    value = rec_weight.get(row.get("recommendation"), 0.0)
    value += 3.0 * safe_float(row.get("stage4_best_exactlike_score"), 0.0)
    value += 1.0 * safe_float(row.get("stage4_best_closure_shell_score"), 0.0)
    value += 2.0 * safe_float(row.get("stage4_best_alignment"), 0.0)
    value -= 0.5 * safe_float(row.get("stage4_damage_score"), 0.0)
    if row.get("tuple_class_id") in ("p167_c01", "p167_c05"):
        value += 0.5
    return float(value)


def select_stage5_recommendations(rows, args):
    grouped = {}
    for row in rows:
        grouped.setdefault(row.get("candidate_hash"), []).append(row)
    selected = []
    for candidate_hash, group in grouped.items():
        group = sorted(group, key=stage5_recommendation_score, reverse=True)
        best = dict(group[0])
        best["all_stage5_recommendations"] = sorted(set(row.get("recommendation") for row in group if row.get("recommendation")))
        best["all_supporting_trajectories"] = [
            {
                "trajectory_id": row.get("trajectory_id"),
                "recommendation": row.get("recommendation"),
                "stage4_best_operator": row.get("stage4_best_operator"),
                "stage4_best_score": row.get("stage4_best_score"),
                "stage4_best_exactlike_score": row.get("stage4_best_exactlike_score"),
                "stage4_best_closure_shell_score": row.get("stage4_best_closure_shell_score"),
                "stage4_best_alignment": row.get("stage4_best_alignment"),
                "stage4_damage_score": row.get("stage4_damage_score"),
                "why_selected": row.get("why_selected"),
            }
            for row in group
        ]
        selected.append(best)
    selected.sort(key=stage5_recommendation_score, reverse=True)

    if int(args.production_candidate_limit) >= 0:
        production = [row for row in selected if recommended_stage5_role(row) == "production_deep_search"][: int(args.production_candidate_limit)]
    else:
        production = [row for row in selected if recommended_stage5_role(row) == "production_deep_search"]
    guarded = [row for row in selected if recommended_stage5_role(row) == "guarded_repair"][: int(args.guarded_repair_limit)]
    repair = [row for row in selected if recommended_stage5_role(row) == "repair_target"][: int(args.repair_target_limit)]
    benchmark = [row for row in selected if recommended_stage5_role(row) == "operator_benchmark"][: int(args.operator_benchmark_limit)]
    diagnostics = [row for row in selected if recommended_stage5_role(row) == "needs_more_diagnostics"][: int(args.needs_more_diagnostics_limit)]
    archive = [row for row in selected if recommended_stage5_role(row) == "archive"][: int(args.archive_limit)]

    out = []
    seen = set()
    for row in production + guarded + repair + benchmark + diagnostics + archive:
        h = row.get("candidate_hash")
        if h in seen:
            continue
        seen.add(h)
        out.append(row)
    if int(args.total_candidate_limit) > 0:
        out = out[: int(args.total_candidate_limit)]
    return out


def recommended_stage5_role(row):
    tuple_id = row.get("tuple_class_id")
    rec = row.get("recommendation")
    damage = safe_float(row.get("stage4_damage_score"), 0.0)
    exactlike = safe_float(row.get("stage4_best_exactlike_score"), 0.0)
    score = safe_float(row.get("stage4_best_score"), 10 ** 9)
    if tuple_id == "p167_c09" and score <= 200:
        return "operator_benchmark" if damage > 0.25 else "repair_target"
    if rec == "production_deep_search" and tuple_id in ("p167_c01", "p167_c05") and damage <= 0.40:
        return "production_deep_search"
    if tuple_id == "p167_c05" and exactlike >= 0.80:
        return "guarded_repair" if damage > 0.35 else "production_deep_search"
    if rec == "repair_target":
        return "repair_target"
    if rec == "operator_benchmark":
        return "operator_benchmark"
    if rec == "archive":
        return "archive"
    return "needs_more_diagnostics"


def normalize_stage5_operator(operator):
    return STAGE4_TO_STAGE5_OPERATOR.get(operator, operator)


def split_budget(total, primary, secondary, role, baseline_restarts):
    total = max(1, int(total))
    primary = normalize_stage5_operator(primary or "stage5_mixed_operator_adaptive")
    secondary = normalize_stage5_operator(secondary or "stage5_pair_profile_movespace_filter")
    budget = {}
    if role == "operator_benchmark":
        p_count = max(1, int(math.ceil(total * 0.6)))
    elif role == "repair_target":
        p_count = max(1, int(math.ceil(total * 0.6)))
    else:
        p_count = max(1, int(math.ceil(total * 0.7)))
    s_count = max(0, total - p_count)
    budget[primary] = budget.get(primary, 0) + p_count
    if secondary and secondary != primary and s_count > 0:
        budget[secondary] = budget.get(secondary, 0) + s_count
    if int(baseline_restarts) > 0:
        budget["stage5_baseline_score_only"] = int(baseline_restarts)
    return budget


def derived_budget_plan(row, role, args):
    tuple_id = row.get("tuple_class_id")
    if role == "production_deep_search" and tuple_id == "p167_c05":
        return {
            "primary_operator": "stage5_mixed_operator_adaptive",
            "secondary_operator": normalize_stage5_operator(row.get("stage4_best_operator") or "stage5_pair_profile_movespace_filter"),
            "restart_budget": int(args.production_c05_restarts),
            "step_budget": int(args.production_c05_steps),
            "sample_swaps": int(args.production_c05_sample_swaps),
        }
    if role == "production_deep_search" and tuple_id == "p167_c01":
        primary = "stage5_pair_profile_movespace_filter" if row.get("stage4_best_operator") == "stage4_pair_profile_movespace_filter" else "stage5_mixed_operator_adaptive"
        return {
            "primary_operator": primary,
            "secondary_operator": normalize_stage5_operator(row.get("stage4_best_operator") or "stage5_exact_joint_local_repair"),
            "restart_budget": int(args.production_c01_restarts),
            "step_budget": int(args.production_c01_steps),
            "sample_swaps": int(args.production_c01_sample_swaps),
        }
    if role == "repair_target":
        primary = "stage5_pair_profile_movespace_filter" if tuple_id == "p167_c05" else "stage5_mixed_operator_adaptive"
        secondary = "stage5_mixed_operator_adaptive" if primary == "stage5_pair_profile_movespace_filter" else "stage5_exact_joint_local_repair"
        return {
            "primary_operator": primary,
            "secondary_operator": secondary,
            "restart_budget": int(args.repair_restarts),
            "step_budget": int(args.repair_steps),
            "sample_swaps": int(args.repair_sample_swaps),
        }
    if role == "operator_benchmark":
        return {
            "primary_operator": "stage5_exact_joint_local_repair",
            "secondary_operator": "stage5_pair_profile_movespace_filter",
            "restart_budget": int(args.benchmark_restarts),
            "step_budget": int(args.benchmark_steps),
            "sample_swaps": int(args.benchmark_sample_swaps),
        }
    return {
        "primary_operator": "stage5_mixed_operator_adaptive",
        "secondary_operator": "stage5_pair_profile_movespace_filter",
        "restart_budget": int(args.diagnostic_restarts),
        "step_budget": int(args.repair_steps),
        "sample_swaps": int(args.repair_sample_swaps),
    }


def operator_budget_for_plan(plan, role, args):
    budget = split_budget(
        plan.get("restart_budget") or args.restarts,
        plan.get("primary_operator"),
        plan.get("secondary_operator"),
        role,
        args.baseline_restarts if role == "production_deep_search" else 0,
    )
    allowed = set(parse_list(args.operators, STAGE5_OPERATORS))
    return {op: max(0, int(n)) for op, n in budget.items() if op in allowed and int(n) > 0}


def choose_stage5_move(task_operator, blocks, counts, lam, p, rng, sample_swaps, uphill_threshold, operator_state):
    mapped = STAGE5_TO_STAGE2_OPERATOR.get(task_operator, task_operator)
    return ORIGINAL_CHOOSE_STAGE2_MOVE(mapped, blocks, counts, lam, p, rng, sample_swaps, uphill_threshold, operator_state)


def rho_hash_from_counts(counts, lam, p):
    rho = rho_vector(counts, lam)
    values = tuple(int(rho[d]) for d in range(1, int(p)))
    return stable_hash(json.dumps(values, separators=(",", ":")))


def support_signature_hash_from_counts(counts, lam, p):
    rho = rho_vector(counts, lam)
    values = tuple((int(d), int(rho[d])) for d in range(1, int(p)) if int(rho[d]) != 0)
    return stable_hash(json.dumps(values, separators=(",", ":")))


def emit_stage5_snapshot(row_base, snapshots, kind, attempted_steps, accepted_moves, blocks, counts, lam, p, rng, diagnostic_samples, initial_support, initial_metrics, best_score, diagnostic_type, current_operator, operator_reward, operator_state):
    row, metrics = ORIGINAL_EMIT_STAGE2_SNAPSHOT(row_base, snapshots, kind, attempted_steps, accepted_moves, blocks, counts, lam, p, rng, diagnostic_samples, initial_support, initial_metrics, best_score, diagnostic_type, current_operator, operator_reward, operator_state)
    score_value = int(metrics.get("S") or 0)
    row["state_hash"] = state_hash(blocks, p, row_base.get("ks") or [])
    row["rho_hash"] = rho_hash_from_counts(counts, lam, p)
    row["support_signature_hash"] = support_signature_hash_from_counts(counts, lam, p)
    row["score_band"] = int(math.floor(float(score_value) / 20.0) * 20) if score_value >= 0 else None
    return row, metrics


def replay_stage4_best_blocks(candidate, trajectory, args):
    p = int(candidate["p"])
    ks = [int(k) for k in candidate["ks"]]
    lam = int(candidate["lambda"])
    blocks = [set(int(x) for x in block) for block in candidate["blocks"]]
    counts = total_diff_counts(p, blocks)
    initial_score = score_counts(counts, lam)
    best_score = int(initial_score)
    best_blocks = [set(block) for block in blocks]
    stage_name = trajectory.get("stage_name") or "p167_stage4"
    candidate_id = trajectory.get("candidate_id") or candidate.get("candidate_id")
    operator = trajectory.get("operator")
    restart_id = int(trajectory.get("restart_id") or 0)
    raw = "{}:{}:{}:{}".format(candidate_id, operator, restart_id, stage_name)
    run_seed = int(args.stage4_seed_base) + int(deterministic_seed(raw) % 1000000007)
    row_cfg = trajectory.get("row_level_config") or {}
    steps = int(row_cfg.get("steps") or args.stage4_replay_steps)
    sample_swaps = int(row_cfg.get("sample_swaps") or args.stage4_replay_sample_swaps)
    uphill_threshold = int(row_cfg.get("uphill_threshold") or args.uphill_threshold)
    operator_state = {}
    accepted = 0
    for step in range(1, steps + 1):
        rng = S2["seeded_rng"](run_seed + step * 1009)
        move, _target_d, _selected_operator, _selected_reason = choose_stage5_move(
            operator,
            blocks,
            counts,
            lam,
            p,
            rng,
            sample_swaps,
            uphill_threshold,
            operator_state,
        )
        if move is None:
            continue
        next_blocks = apply_move(blocks, move)
        if next_blocks is None:
            continue
        blocks = next_blocks
        counts = apply_sparse_delta(counts, move["delta"])
        accepted += 1
        score = score_counts(counts, lam)
        if score < best_score:
            best_score = int(score)
            best_blocks = [set(block) for block in blocks]
    recovered_hash = state_hash(best_blocks, p, ks)
    return {
        "blocks": best_blocks,
        "best_score": int(best_score),
        "accepted_moves_replayed": int(accepted),
        "recovered_hash": recovered_hash,
        "expected_hash": trajectory.get("best_state_hash"),
        "hash_match": recovered_hash == trajectory.get("best_state_hash"),
    }


def load_stage5_budget_plan(args):
    if not args.stage5_budget_plan or not os.path.exists(args.stage5_budget_plan):
        return {}
    if args.stage5_budget_plan.endswith(".json"):
        with open(args.stage5_budget_plan) as f:
            rows = json.load(f)
    else:
        rows = []
        with open(args.stage5_budget_plan) as f:
            header = None
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split(",")
                if header is None:
                    header = parts
                    continue
                rows.append(dict(zip(header, parts)))
    out = {}
    for row in rows:
        if row.get("candidate_hash"):
            normalized = dict(row)
            normalized["primary_operator"] = normalize_stage5_operator(row.get("primary_operator"))
            normalized["secondary_operator"] = normalize_stage5_operator(row.get("secondary_operator"))
            out[row.get("candidate_hash")] = normalized
    return out


def load_stage5_candidates(args, tuple_rows):
    paths = stage4_paths(args.stage4_artifact)
    recommendations = select_stage5_recommendations(read_jsonl(paths["recommendations"]), args)
    budget_plan_by_hash = load_stage5_budget_plan(args)
    trajectory_by_id = {row.get("trajectory_id"): row for row in read_jsonl(paths["trajectory"])}
    input_candidates = read_jsonl(paths["candidates"])
    input_by_id = {row.get("candidate_id"): row for row in input_candidates}
    input_by_hash = {row.get("candidate_hash"): row for row in input_candidates}
    tuple_by_id = {row["tuple_class_id"]: row for row in tuple_rows}
    out = []
    for idx, rec in enumerate(recommendations, 1):
        trajectory = trajectory_by_id.get(rec.get("trajectory_id")) or trajectory_by_id.get(rec.get("run_id"))
        if not trajectory:
            continue
        candidate = input_by_id.get(trajectory.get("candidate_id")) or input_by_hash.get(trajectory.get("candidate_hash"))
        tuple_row = tuple_by_id.get(trajectory.get("tuple_class_id") or rec.get("tuple_class_id"))
        if not candidate or not tuple_row or not candidate.get("blocks"):
            continue
        replay = replay_stage4_best_blocks(candidate, trajectory, args)
        h = replay["recovered_hash"]
        role = recommended_stage5_role(rec)
        plan = budget_plan_by_hash.get(rec.get("candidate_hash")) or budget_plan_by_hash.get(h) or derived_budget_plan(rec, role, args)
        plan["primary_operator"] = normalize_stage5_operator(plan.get("primary_operator"))
        plan["secondary_operator"] = normalize_stage5_operator(plan.get("secondary_operator"))
        budget = operator_budget_for_plan(plan, role, args)
        out.append(
            {
                "candidate_id": "stage5_{:03d}_{}".format(idx, h[:12]),
                "candidate_hash": h,
                "source": role,
                "blocks": json_blocks(replay["blocks"]),
                "tuple_class_id": tuple_row["tuple_class_id"],
                "abs_row_sums": tuple_row["abs_row_sums"],
                "ks": tuple_row["ks"],
                "representative_tuple": tuple_row.get("representative_tuple", tuple_row["ks"]),
                "lambda": tuple_row["lambda"],
                "p": tuple_row["p"],
                "n": tuple_row["n"],
                "equivalence_definition": tuple_row.get("equivalence_definition"),
                "seed_family": trajectory.get("seed_family"),
                "operator_from_stage1": trajectory.get("operator_from_stage1"),
                "stage1_run_id": trajectory.get("stage1_run_id"),
                "stage1_trajectory_id": trajectory.get("stage1_trajectory_id"),
                "stage1_selection_reason": trajectory.get("stage1_selection_reason"),
                "stage1_best_score": trajectory.get("stage1_best_score"),
                "stage1_best_exactlike_score": trajectory.get("stage1_best_exactlike_score"),
                "stage1_best_closure_shell_score": trajectory.get("stage1_best_closure_shell_score"),
                "stage1_best_alignment_to_minus_rho": trajectory.get("stage1_best_alignment_to_minus_rho"),
                "stage2_recommendation": trajectory.get("source"),
                "stage2_trajectory_id": trajectory.get("stage2_trajectory_id"),
                "stage3_run_id": trajectory.get("stage3_run_id"),
                "stage3_trajectory_id": trajectory.get("stage3_trajectory_id"),
                "stage4_run_id": trajectory.get("run_id"),
                "stage4_trajectory_id": trajectory.get("trajectory_id"),
                "stage4_recommendation": rec.get("recommendation"),
                "stage4_selection_reason": rec.get("why_selected"),
                "stage4_best_operator": rec.get("stage4_best_operator") or trajectory.get("operator"),
                "stage4_best_score": rec.get("stage4_best_score") or trajectory.get("best_score"),
                "stage4_best_exactlike_score": rec.get("stage4_best_exactlike_score") or trajectory.get("best_exactlike_score"),
                "stage4_best_closure_shell_score": rec.get("stage4_best_closure_shell_score") or trajectory.get("best_closure_shell_score"),
                "stage4_best_alignment": rec.get("stage4_best_alignment") or trajectory.get("best_alignment_to_minus_rho"),
                "stage4_D_min_ratio": rec.get("stage4_D_min_ratio") or trajectory.get("D_min_ratio"),
                "stage4_kappa_q99": rec.get("stage4_kappa_q99") or trajectory.get("kappa_q99"),
                "stage4_damage_score": rec.get("stage4_damage_score") or trajectory.get("damage_score"),
                "stage4_hardening_score": rec.get("stage4_hardening_score") or trajectory.get("hardening_score"),
                "all_stage5_recommendations": rec.get("all_stage5_recommendations"),
                "all_supporting_trajectories": rec.get("all_supporting_trajectories"),
                "recommended_stage5_role": role,
                "recommended_operator_budget": budget,
                "primary_operator": plan.get("primary_operator"),
                "secondary_operator": plan.get("secondary_operator"),
                "restart_budget": int(plan.get("restart_budget") or 0),
                "step_budget": int(plan.get("step_budget") or args.steps),
                "sample_swaps_budget": int(plan.get("sample_swaps") or args.sample_swaps),
                "why_selected": rec.get("why_selected"),
                "stage4_replay_hash": h,
                "stage4_replay_hash_match": replay["hash_match"],
                "stage4_replay_best_score": replay["best_score"],
                "stage4_replay_accepted_moves": replay["accepted_moves_replayed"],
                "candidate_lineage": {
                    "source": "stage4_recommendation_replay",
                    "stage5_recommendation": rec,
                    "stage4_trajectory": {
                        "run_id": trajectory.get("run_id"),
                        "trajectory_id": trajectory.get("trajectory_id"),
                        "candidate_lineage": trajectory.get("candidate_lineage"),
                    },
                    "stage4_replay": {key: value for key, value in replay.items() if key != "blocks"},
                    "stage5_budget_plan": plan,
                },
            }
        )
    return out, []


def stage5_task_grid(candidates, operators, restarts, seed_base, stage_name):
    tasks = []
    allowed = set(parse_list(",".join(operators) if isinstance(operators, (list, tuple)) else operators, STAGE5_OPERATORS))
    for candidate in candidates:
        budget = candidate.get("recommended_operator_budget") or {}
        if not budget:
            budget = {operator: int(restarts) for operator in allowed}
        for operator, op_restarts in sorted(budget.items()):
            if operator not in allowed:
                continue
            for restart_id in range(int(op_restarts)):
                raw = "{}:{}:{}:{}".format(candidate["candidate_id"], operator, restart_id, stage_name)
                run_seed = int(seed_base) + int(deterministic_seed(raw) % 1000000007)
                task = dict(candidate)
                task.update(
                    {
                        "task_id": "{}_".format(stage_name) + stable_hash(raw)[:16],
                        "operator": operator,
                        "restart_id": int(restart_id),
                        "run_seed": int(run_seed),
                        "step_budget": int(candidate.get("step_budget") or 0),
                        "sample_swaps_budget": int(candidate.get("sample_swaps_budget") or 0),
                        "primary_operator": candidate.get("primary_operator"),
                        "secondary_operator": candidate.get("secondary_operator"),
                        "restart_budget": int(candidate.get("restart_budget") or 0),
                    }
                )
                tasks.append(task)
    tasks.sort(key=lambda row: stable_hash("{}:{}:{}".format(row["candidate_id"], row["operator"], row["restart_id"])))
    return tasks


ORIGINAL_RUN_TASK = S2["run_task"]


def run_stage5_task(task, args, config_hash, input_manifest_hash, code_commit, github_run_id):
    old_steps = args.steps
    old_sample_swaps = args.sample_swaps
    if int(task.get("step_budget") or 0) > 0:
        args.steps = int(task.get("step_budget"))
    if int(task.get("sample_swaps_budget") or 0) > 0:
        args.sample_swaps = int(task.get("sample_swaps_budget"))
    try:
        run_row, trajectory, snapshots, reward_log = ORIGINAL_RUN_TASK(task, args, config_hash, input_manifest_hash, code_commit, github_run_id)
    finally:
        args.steps = old_steps
        args.sample_swaps = old_sample_swaps
    extras = {
        "stage5_primary_operator": task.get("primary_operator"),
        "stage5_secondary_operator": task.get("secondary_operator"),
        "stage5_restart_budget": int(task.get("restart_budget") or 0),
        "stage5_step_budget": int(task.get("step_budget") or 0),
        "stage5_sample_swaps_budget": int(task.get("sample_swaps_budget") or 0),
        "stage4_best_operator": task.get("stage4_best_operator"),
        "stage4_best_score": task.get("stage4_best_score"),
        "stage4_best_exactlike_score": task.get("stage4_best_exactlike_score"),
        "stage4_best_closure_shell_score": task.get("stage4_best_closure_shell_score"),
        "stage4_best_alignment": task.get("stage4_best_alignment"),
        "stage4_D_min_ratio": task.get("stage4_D_min_ratio"),
        "stage4_kappa_q99": task.get("stage4_kappa_q99"),
        "stage4_damage_score": task.get("stage4_damage_score"),
        "stage4_hardening_score": task.get("stage4_hardening_score"),
    }
    run_row.update(extras)
    trajectory.update(extras)
    row_cfg = run_row.get("row_level_config") or {}
    row_cfg["steps"] = int(task.get("step_budget") or old_steps)
    row_cfg["sample_swaps"] = int(task.get("sample_swaps_budget") or old_sample_swaps)
    row_cfg["stage5_primary_operator"] = task.get("primary_operator")
    row_cfg["stage5_secondary_operator"] = task.get("secondary_operator")
    run_row["row_level_config"] = row_cfg
    return run_row, trajectory, snapshots, reward_log


def recommendation_from_trajectory(row):
    damage = safe_float(row.get("damage_score"), 0.0)
    hardening = safe_float(row.get("hardening_score"), 0.0)
    exactlike = safe_float(row.get("best_exactlike_score"), 0.0)
    closure = safe_float(row.get("best_closure_shell_score"), 0.0)
    alignment = safe_float(row.get("best_alignment_to_minus_rho"), 0.0)
    dmin_delta = safe_float(row.get("D_min_ratio_delta"), 0.0)
    tuple_id = row.get("tuple_class_id")
    score = safe_float(row.get("best_score"), 10 ** 9)
    if tuple_id == "p167_c09" and score <= 200 and exactlike < 0.35:
        return "operator_benchmark"
    if damage <= 0.35 and hardening <= 0.35 and exactlike >= 0.80 and closure >= 2.15 and alignment >= 0.55 and dmin_delta < 0:
        return "production_deep_search"
    if damage <= 0.55 and (closure >= 2.10 or alignment >= 0.50) and dmin_delta < 0:
        return "repair_target"
    if damage > 0.90 or hardening > 0.90:
        return "archive"
    return "needs_more_diagnostics"


def stage6_candidates(trajectory_rows, limit):
    grouped = rows_by_key(trajectory_rows, "candidate_hash")
    out = []
    for candidate_hash, group in grouped.items():
        best = sorted(
            group,
            key=lambda row: (
                {"production_deep_search": 4, "repair_target": 3, "needs_more_diagnostics": 2, "operator_benchmark": 1, "archive": 0}.get(recommendation_from_trajectory(row), 0),
                safe_float(row.get("best_exactlike_score"), 0.0),
                safe_float(row.get("best_closure_shell_score"), 0.0),
                safe_float(row.get("best_alignment_to_minus_rho"), 0.0),
                -safe_float(row.get("damage_score"), 0.0),
            ),
            reverse=True,
        )[0]
        reasons = []
        if safe_float(best.get("closure_shell_delta"), 0.0) > 0.0:
            reasons.append("closure_shell_improved")
        if safe_float(best.get("alignment_delta"), 0.0) > 0.0:
            reasons.append("alignment_improved")
        if safe_float(best.get("D_min_ratio_delta"), 0.0) < 0.0:
            reasons.append("D_min_ratio_decreased")
        if safe_float(best.get("kappa_q99_delta"), 0.0) > 0.0:
            reasons.append("kappa_q99_improved")
        if safe_float(best.get("damage_score"), 1.0) <= 0.35:
            reasons.append("low_damage")
        if safe_float(best.get("hardening_score"), 1.0) <= 0.35:
            reasons.append("low_hardening")
        if safe_float(best.get("support_mixing_score"), 0.0) > 0.10:
            reasons.append("support_mixing_positive")
        out.append(
            {
                "candidate_hash": candidate_hash,
                "tuple_class_id": best.get("tuple_class_id"),
                "ks": best.get("ks"),
                "lambda": best.get("lambda"),
                "source": best.get("source"),
                "stage5_role": best.get("source"),
                "stage5_best_operator": best.get("operator"),
                "stage5_best_score": best.get("best_score"),
                "stage5_best_exactlike_score": best.get("best_exactlike_score"),
                "stage5_best_closure_shell_score": best.get("best_closure_shell_score"),
                "stage5_best_alignment": best.get("best_alignment_to_minus_rho"),
                "stage5_D_min_ratio": best.get("D_min_ratio"),
                "stage5_kappa_q99": best.get("kappa_q99"),
                "stage5_damage_score": best.get("damage_score"),
                "stage5_hardening_score": best.get("hardening_score"),
                "stage5_basin_revisit_score": best.get("basin_revisit_score"),
                "run_id": best.get("run_id"),
                "trajectory_id": best.get("trajectory_id"),
                "best_state_hash": best.get("best_state_hash"),
                "recommendation": recommendation_from_trajectory(best),
                "why_selected": reasons,
            }
        )
    out.sort(
        key=lambda row: (
            {"production_deep_search": 4, "repair_target": 3, "needs_more_diagnostics": 2, "operator_benchmark": 1, "archive": 0}.get(row.get("recommendation"), 0),
            safe_float(row.get("stage5_best_exactlike_score"), 0.0),
            safe_float(row.get("stage5_best_closure_shell_score"), 0.0),
            -safe_float(row.get("stage5_damage_score"), 0.0),
        ),
        reverse=True,
    )
    return out[: int(limit)] if int(limit) > 0 else out


def candidate_summary_rows(trajectory_rows):
    out = []
    for h, group in sorted(rows_by_key(trajectory_rows, "candidate_hash").items()):
        best_score_row = min(group, key=lambda row: safe_float(row.get("best_score"), 10 ** 12))
        best_shell_row = max(group, key=lambda row: safe_float(row.get("best_closure_shell_score"), -10 ** 12))
        best_exact_row = max(group, key=lambda row: safe_float(row.get("best_exactlike_score"), -10 ** 12))
        out.append(
            {
                "candidate_hash": h,
                "tuple_class_id": best_exact_row.get("tuple_class_id"),
                "role": best_exact_row.get("source"),
                "attempt_count": len(group),
                "best_score": best_score_row.get("best_score"),
                "best_score_operator": best_score_row.get("operator"),
                "best_exactlike_score": best_exact_row.get("best_exactlike_score"),
                "best_exactlike_operator": best_exact_row.get("operator"),
                "best_closure_shell_score": best_shell_row.get("best_closure_shell_score"),
                "best_closure_operator": best_shell_row.get("operator"),
                "median_damage_score": median(row.get("damage_score") for row in group),
                "median_hardening_score": median(row.get("hardening_score") for row in group),
            }
        )
    return out


def event_rows(snapshot_rows, reward_rows, before_window, after_window):
    rows = []
    for trajectory_id, group in rows_by_key(snapshot_rows, "trajectory_id").items():
        group = sorted(group, key=lambda row: (int(row.get("accepted_moves") or 0), int(row.get("attempted_steps") or 0), row.get("snapshot_kind") or ""))
        event_sources = []
        for kind in ("best_score_state", "best_exactlike_state", "best_closure_shell_state", "best_alignment_state", "best_operator_reward_state"):
            event_sources.extend([row for row in group if row.get("snapshot_kind") == kind])
        seen = set()
        for event in event_sources:
            key = (event.get("snapshot_kind"), event.get("accepted_moves"), event.get("attempted_steps"))
            if key in seen:
                continue
            seen.add(key)
            accepted = int(event.get("accepted_moves") or 0)
            window = [
                row for row in group
                if accepted - int(before_window) <= int(row.get("accepted_moves") or 0) <= accepted + int(after_window)
            ]
            rows.append(
                {
                    "trajectory_id": trajectory_id,
                    "run_id": event.get("run_id"),
                    "tuple_class_id": event.get("tuple_class_id"),
                    "operator": event.get("operator"),
                    "source": event.get("source"),
                    "event_kind": event.get("snapshot_kind"),
                    "event_step": event.get("attempted_steps"),
                    "event_accepted_moves": event.get("accepted_moves"),
                    "event_S": event.get("S"),
                    "event_closure_shell_score": event.get("closure_shell_score"),
                    "event_alignment": event.get("best_alignment_to_minus_rho"),
                    "event_D_min_ratio": event.get("D_min_ratio"),
                    "event_kappa_q99": event.get("kappa_q99"),
                    "event_damage_score": event.get("damage_score"),
                    "window_snapshot_count": len(window),
                    "window_snapshots": [
                        {
                            "snapshot_kind": row.get("snapshot_kind"),
                            "attempted_steps": row.get("attempted_steps"),
                            "accepted_moves": row.get("accepted_moves"),
                            "S": row.get("S"),
                            "closure_shell_score": row.get("closure_shell_score"),
                            "best_alignment_to_minus_rho": row.get("best_alignment_to_minus_rho"),
                            "D_min_ratio": row.get("D_min_ratio"),
                            "kappa_q99": row.get("kappa_q99"),
                            "damage_score": row.get("damage_score"),
                        }
                        for row in window
                    ],
                }
            )
    return rows


def simple_event_summary(events):
    out = []
    for key, group in sorted(rows_by_key(events, "event_kind").items()):
        out.append(
            {
                "event_kind": key,
                "event_count": len(group),
                "median_event_S": median(row.get("event_S") for row in group),
                "median_event_closure_shell_score": median(row.get("event_closure_shell_score") for row in group),
                "median_event_alignment": median(row.get("event_alignment") for row in group),
                "median_event_D_min_ratio": median(row.get("event_D_min_ratio") for row in group),
                "median_event_damage_score": median(row.get("event_damage_score") for row in group),
            }
        )
    return out


def add_cycle_columns(snapshot_rows):
    enriched = []
    for trajectory_id, group in rows_by_key(snapshot_rows, "trajectory_id").items():
        group = sorted(group, key=lambda row: (int(row.get("accepted_moves") or 0), int(row.get("attempted_steps") or 0), row.get("snapshot_kind") or ""))
        seen_state = {}
        seen_rho = {}
        seen_support = {}
        last_score = None
        last_rho = None
        last_support = None
        score_plateau = 0
        rho_plateau = 0
        support_plateau = 0
        for row in group:
            row = dict(row)
            sh = row.get("state_hash")
            rh = row.get("rho_hash")
            suh = row.get("support_signature_hash")
            score_value = row.get("S")
            row["seen_state_before"] = bool(sh in seen_state) if sh is not None else None
            row["seen_rho_before"] = bool(rh in seen_rho) if rh is not None else None
            row["seen_support_before"] = bool(suh in seen_support) if suh is not None else None
            row["state_visit_count_so_far"] = int(seen_state.get(sh, 0) + 1) if sh is not None else None
            row["rho_visit_count_so_far"] = int(seen_rho.get(rh, 0) + 1) if rh is not None else None
            row["support_visit_count_so_far"] = int(seen_support.get(suh, 0) + 1) if suh is not None else None
            score_plateau = score_plateau + 1 if score_value == last_score else 1
            rho_plateau = rho_plateau + 1 if rh == last_rho else 1
            support_plateau = support_plateau + 1 if suh == last_support else 1
            row["current_score_plateau_length"] = int(score_plateau)
            row["current_rho_plateau_length"] = int(rho_plateau)
            row["current_support_plateau_length"] = int(support_plateau)
            if sh is not None:
                seen_state[sh] = seen_state.get(sh, 0) + 1
            if rh is not None:
                seen_rho[rh] = seen_rho.get(rh, 0) + 1
            if suh is not None:
                seen_support[suh] = seen_support.get(suh, 0) + 1
            last_score = score_value
            last_rho = rh
            last_support = suh
            enriched.append(row)
    return enriched


def cycle_diagnostics_by_trajectory(snapshot_rows, trajectory_rows):
    traj_by_id = {row.get("trajectory_id"): row for row in trajectory_rows}
    out = []
    for trajectory_id, group in rows_by_key(snapshot_rows, "trajectory_id").items():
        states = [row.get("state_hash") for row in group if row.get("state_hash")]
        rhos = [row.get("rho_hash") for row in group if row.get("rho_hash")]
        supports = [row.get("support_signature_hash") for row in group if row.get("support_signature_hash")]
        score_plateaus = [int(row.get("current_score_plateau_length") or 0) for row in group]
        rho_plateaus = [int(row.get("current_rho_plateau_length") or 0) for row in group]
        support_plateaus = [int(row.get("current_support_plateau_length") or 0) for row in group]
        visited_state = len(states)
        visited_rho = len(rhos)
        visited_support = len(supports)
        state_repeat_rate = 1.0 - float(len(set(states))) / float(max(1, visited_state))
        rho_repeat_rate = 1.0 - float(len(set(rhos))) / float(max(1, visited_rho))
        support_repeat_rate = 1.0 - float(len(set(supports))) / float(max(1, visited_support))
        max_plateau = max(score_plateaus or [0])
        normalized_plateau = float(max_plateau) / float(max(1, len(group)))
        immediate_reverse_rate = 0.0
        basin_revisit_score = 0.4 * rho_repeat_rate + 0.3 * support_repeat_rate + 0.2 * normalized_plateau + 0.1 * immediate_reverse_rate
        traj = traj_by_id.get(trajectory_id, {})
        out.append(
            {
                "trajectory_id": trajectory_id,
                "run_id": traj.get("run_id") or (group[0].get("run_id") if group else None),
                "candidate_hash": traj.get("candidate_hash") or (group[0].get("candidate_hash") if group else None),
                "tuple_class_id": traj.get("tuple_class_id") or (group[0].get("tuple_class_id") if group else None),
                "operator": traj.get("operator") or (group[0].get("operator") if group else None),
                "source": traj.get("source") or (group[0].get("source") if group else None),
                "visited_state_count": int(visited_state),
                "unique_state_count": int(len(set(states))),
                "state_repeat_count": int(visited_state - len(set(states))),
                "state_repeat_rate": float(state_repeat_rate),
                "visited_rho_count": int(visited_rho),
                "unique_rho_count": int(len(set(rhos))),
                "rho_repeat_count": int(visited_rho - len(set(rhos))),
                "rho_repeat_rate": float(rho_repeat_rate),
                "visited_support_signature_count": int(visited_support),
                "unique_support_signature_count": int(len(set(supports))),
                "support_repeat_count": int(visited_support - len(set(supports))),
                "support_repeat_rate": float(support_repeat_rate),
                "max_score_plateau_length": int(max(score_plateaus or [0])),
                "max_rho_plateau_length": int(max(rho_plateaus or [0])),
                "max_support_plateau_length": int(max(support_plateaus or [0])),
                "immediate_reverse_move_count": 0,
                "immediate_reverse_move_rate": 0.0,
                "recent_rho_repeat_count": int(sum(1 for row in group[-10:] if row.get("seen_rho_before"))),
                "recent_support_repeat_count": int(sum(1 for row in group[-10:] if row.get("seen_support_before"))),
                "basin_revisit_score": float(basin_revisit_score),
            }
        )
    return out


def group_cycle_rows(cycle_rows, key):
    out = []
    for value, group in sorted(rows_by_key(cycle_rows, key).items()):
        out.append(
            {
                key: value,
                "trajectory_count": len(group),
                "median_rho_repeat_rate": median(row.get("rho_repeat_rate") for row in group),
                "median_support_repeat_rate": median(row.get("support_repeat_rate") for row in group),
                "median_basin_revisit_score": median(row.get("basin_revisit_score") for row in group),
                "median_max_score_plateau_length": median(row.get("max_score_plateau_length") for row in group),
                "median_immediate_reverse_move_rate": median(row.get("immediate_reverse_move_rate") for row in group),
            }
        )
    return out


def dynamic_reward_prep_rows(trajectory_rows, cycle_rows):
    cycle_by_traj = {row.get("trajectory_id"): row for row in cycle_rows}
    out = []
    for row in trajectory_rows:
        cycle = cycle_by_traj.get(row.get("trajectory_id"), {})
        damage = safe_float(row.get("damage_score"), 0.0)
        hardening = safe_float(row.get("hardening_score"), 0.0)
        closure = safe_float(row.get("best_closure_shell_score"), 0.0)
        alignment = safe_float(row.get("best_alignment_to_minus_rho"), 0.0)
        dmin = safe_float(row.get("D_min_ratio_delta"), 0.0)
        kappa = safe_float(row.get("kappa_q99_delta"), 0.0)
        revisit = safe_float(cycle.get("basin_revisit_score"), 0.0)
        prep = {
            "trajectory_id": row.get("trajectory_id"),
            "candidate_hash": row.get("candidate_hash"),
            "tuple_class_id": row.get("tuple_class_id"),
            "operator": row.get("operator"),
            "source": row.get("source"),
            "recent_score_delta_50": row.get("score_delta_from_start"),
            "recent_score_delta_100": row.get("score_delta_from_start"),
            "recent_score_delta_200": row.get("score_delta_from_start"),
            "recent_D_min_ratio_delta_50": row.get("D_min_ratio_delta"),
            "recent_D_min_ratio_delta_100": row.get("D_min_ratio_delta"),
            "recent_D_min_ratio_delta_200": row.get("D_min_ratio_delta"),
            "recent_P_16_delta_50": row.get("P_16_delta"),
            "recent_P_16_delta_100": row.get("P_16_delta"),
            "recent_P_16_delta_200": row.get("P_16_delta"),
            "recent_P_32_delta_50": row.get("P_32_delta"),
            "recent_P_32_delta_100": row.get("P_32_delta"),
            "recent_P_32_delta_200": row.get("P_32_delta"),
            "recent_kappa_q99_delta_50": row.get("kappa_q99_delta"),
            "recent_kappa_q99_delta_100": row.get("kappa_q99_delta"),
            "recent_kappa_q99_delta_200": row.get("kappa_q99_delta"),
            "recent_kappa_max_delta_50": row.get("kappa_max_delta_from_start"),
            "recent_kappa_max_delta_100": row.get("kappa_max_delta_from_start"),
            "recent_kappa_max_delta_200": row.get("kappa_max_delta_from_start"),
            "recent_closure_shell_delta_50": row.get("closure_shell_delta"),
            "recent_closure_shell_delta_100": row.get("closure_shell_delta"),
            "recent_closure_shell_delta_200": row.get("closure_shell_delta"),
            "recent_alignment_delta_50": row.get("alignment_delta"),
            "recent_alignment_delta_100": row.get("alignment_delta"),
            "recent_alignment_delta_200": row.get("alignment_delta"),
            "recent_damage_delta_50": row.get("damage_score_delta_from_start"),
            "recent_damage_delta_100": row.get("damage_score_delta_from_start"),
            "recent_damage_delta_200": row.get("damage_score_delta_from_start"),
            "recent_hardening_delta_50": row.get("hardening_score"),
            "recent_hardening_delta_100": row.get("hardening_score"),
            "recent_hardening_delta_200": row.get("hardening_score"),
            "recent_support_turnover_50": row.get("support_mixing_score"),
            "recent_support_turnover_100": row.get("support_mixing_score"),
            "recent_support_turnover_200": row.get("support_mixing_score"),
            "recent_persistent_defect_fraction_50": None,
            "recent_persistent_defect_fraction_100": None,
            "recent_persistent_defect_fraction_200": None,
            "recent_rho_repeat_rate_50": cycle.get("rho_repeat_rate"),
            "recent_rho_repeat_rate_100": cycle.get("rho_repeat_rate"),
            "recent_rho_repeat_rate_200": cycle.get("rho_repeat_rate"),
            "recent_support_repeat_rate_50": cycle.get("support_repeat_rate"),
            "recent_support_repeat_rate_100": cycle.get("support_repeat_rate"),
            "recent_support_repeat_rate_200": cycle.get("support_repeat_rate"),
            "recent_plateau_length_50": cycle.get("max_score_plateau_length"),
            "recent_plateau_length_100": cycle.get("max_score_plateau_length"),
            "recent_plateau_length_200": cycle.get("max_score_plateau_length"),
            "phase_proxy_exploration": max(0.0, safe_float(row.get("support_mixing_score"), 0.0) - 0.5 * revisit),
            "phase_proxy_exactlike": max(0.0, safe_float(row.get("best_exactlike_score"), 0.0) - damage),
            "phase_proxy_closure": max(0.0, closure + alignment - safe_float(row.get("D_min_ratio_delta"), 0.0)),
            "phase_proxy_damage_recovery": max(0.0, damage + hardening),
            "phase_proxy_stuck_or_cycle": max(0.0, revisit),
            "would_increase_damage_weight": bool(damage > 0.35 or hardening > 0.35),
            "would_decrease_score_weight": bool(damage > 0.35 and safe_float(row.get("score_delta_from_start"), 0.0) < 0),
            "would_increase_closure_weight": bool(closure < 2.2 or safe_float(row.get("closure_shell_delta"), 0.0) <= 0),
            "would_increase_alignment_weight": bool(alignment < 0.60 or safe_float(row.get("alignment_delta"), 0.0) <= 0),
            "would_increase_mixing_weight": bool(revisit > 0.25 or safe_float(row.get("support_mixing_score"), 0.0) < 0.10),
            "would_switch_to_safe_operator": bool(damage > 0.35 or hardening > 0.35 or revisit > 0.35),
            "would_switch_to_aggressive_operator": bool(damage <= 0.20 and closure >= 2.2 and dmin < 0 and kappa > 0),
        }
        out.append(prep)
    return out


def group_dynamic_rows(rows, key):
    out = []
    for value, group in sorted(rows_by_key(rows, key).items()):
        out.append(
            {
                key: value,
                "trajectory_count": len(group),
                "median_phase_proxy_exploration": median(row.get("phase_proxy_exploration") for row in group),
                "median_phase_proxy_exactlike": median(row.get("phase_proxy_exactlike") for row in group),
                "median_phase_proxy_closure": median(row.get("phase_proxy_closure") for row in group),
                "median_phase_proxy_damage_recovery": median(row.get("phase_proxy_damage_recovery") for row in group),
                "median_phase_proxy_stuck_or_cycle": median(row.get("phase_proxy_stuck_or_cycle") for row in group),
                "switch_to_safe_rate": float(sum(1 for row in group if row.get("would_switch_to_safe_operator"))) / float(max(1, len(group))),
                "switch_to_aggressive_rate": float(sum(1 for row in group if row.get("would_switch_to_aggressive_operator"))) / float(max(1, len(group))),
            }
        )
    return out


def reward_component_rows(reward_rows):
    out = []
    for row in reward_rows:
        reward = safe_float(row.get("operator_reward"), 0.0)
        delta_s = safe_float(row.get("DeltaS"), 0.0)
        kappa = safe_float(row.get("kappa"), 0.0)
        removed = safe_float(row.get("removed_support_count"), 0.0)
        added = safe_float(row.get("added_support_count"), 0.0)
        out.append(
            {
                "trajectory_id": row.get("trajectory_id"),
                "operator": row.get("operator"),
                "current_operator": row.get("current_operator"),
                "tuple_class_id": row.get("tuple_class_id"),
                "reward_component_score": max(0.0, -delta_s),
                "reward_component_D_min": max(0.0, -delta_s),
                "reward_component_kappa": max(0.0, kappa),
                "reward_component_closure": max(0.0, removed - added),
                "reward_component_alignment": max(0.0, kappa),
                "reward_component_damage": max(0.0, delta_s),
                "reward_component_support_mixing": max(0.0, removed),
                "reward_component_cycle_penalty": 0.0,
                "total_reward_fixed_weights": reward,
            }
        )
    return out


def reward_component_summary(rows):
    out = []
    for op, group in sorted(rows_by_key(rows, "operator").items()):
        out.append(
            {
                "operator": op,
                "record_count": len(group),
                "median_reward_component_score": median(row.get("reward_component_score") for row in group),
                "median_reward_component_D_min": median(row.get("reward_component_D_min") for row in group),
                "median_reward_component_kappa": median(row.get("reward_component_kappa") for row in group),
                "median_reward_component_closure": median(row.get("reward_component_closure") for row in group),
                "median_reward_component_alignment": median(row.get("reward_component_alignment") for row in group),
                "median_reward_component_damage": median(row.get("reward_component_damage") for row in group),
                "median_reward_component_support_mixing": median(row.get("reward_component_support_mixing") for row in group),
                "median_total_reward_fixed_weights": median(row.get("total_reward_fixed_weights") for row in group),
            }
        )
    return out


def stage5_hypotheses(trajectory_rows, stage6_rows, cycle_rows, dynamic_rows):
    by_tuple = rows_by_key(trajectory_rows, "tuple_class_id")
    by_operator = rows_by_key(trajectory_rows, "operator")
    c01_c05 = by_tuple.get("p167_c01", []) + by_tuple.get("p167_c05", [])
    c09 = by_tuple.get("p167_c09", [])
    baseline = by_operator.get("stage5_baseline_score_only", [])
    routed = [row for row in trajectory_rows if row.get("operator") != "stage5_baseline_score_only"]
    mixed = by_operator.get("stage5_mixed_operator_adaptive", [])
    exact_joint = by_operator.get("stage5_exact_joint_local_repair", [])
    pair_filter = by_operator.get("stage5_pair_profile_movespace_filter", [])
    best_score_row = min(trajectory_rows, key=lambda row: safe_float(row.get("best_score"), 10 ** 12)) if trajectory_rows else None
    best_exact_row = max(trajectory_rows, key=lambda row: safe_float(row.get("best_exactlike_score"), -1.0)) if trajectory_rows else None

    def med(rows, key):
        return median(row.get(key) for row in rows)

    return {
        "H_STAGE5_1_c05_c01_persist": {
            "status": "supported" if trajectory_rows and (med(trajectory_rows, "best_closure_shell_score") or 0.0) >= 2.0 else "inconclusive",
            "evidence": {"median_closure": med(trajectory_rows, "best_closure_shell_score"), "median_damage": med(trajectory_rows, "damage_score")},
        },
        "H_STAGE5_2_sudden_improvement": {
            "status": "supported" if any(safe_float(row.get("score_delta_from_start"), 0.0) < -500 for row in trajectory_rows) else "inconclusive",
            "evidence": {"large_score_drop_count": sum(1 for row in trajectory_rows if safe_float(row.get("score_delta_from_start"), 0.0) < -500)},
        },
        "H_STAGE5_3_mixed_main_operator": {
            "status": "supported" if mixed and baseline and (med(mixed, "best_exactlike_score") or 0.0) > (med(baseline, "best_exactlike_score") or 0.0) else ("inconclusive" if not baseline else "not_supported"),
            "evidence": {"mixed_count": len(mixed), "baseline_count": len(baseline), "mixed_exactlike_median": med(mixed, "best_exactlike_score"), "baseline_exactlike_median": med(baseline, "best_exactlike_score")},
        },
        "H_STAGE5_4_pair_filter_safe": {
            "status": "supported" if pair_filter and (med(pair_filter, "damage_score") or 1.0) <= 0.35 else "inconclusive",
            "evidence": {"pair_filter_count": len(pair_filter), "median_damage": med(pair_filter, "damage_score")},
        },
        "H_STAGE5_5_exact_joint_needs_guard": {
            "status": "supported" if exact_joint and (med(exact_joint, "score_delta_from_start") or 0.0) < 0.0 and (med(exact_joint, "damage_score") or 0.0) >= (med(pair_filter, "damage_score") or 0.0) else "inconclusive",
            "evidence": {"exact_joint_count": len(exact_joint), "median_score_delta": med(exact_joint, "score_delta_from_start"), "median_damage": med(exact_joint, "damage_score"), "pair_filter_median_damage": med(pair_filter, "damage_score")},
        },
        "H_STAGE5_6_c09_benchmark_trap": {
            "status": "supported" if c09 and (med(c09, "best_exactlike_score") or 1.0) < 0.50 else "inconclusive",
            "evidence": {"c09_count": len(c09), "c09_exactlike_median": med(c09, "best_exactlike_score"), "c09_best_score_median": med(c09, "best_score")},
        },
        "H_STAGE5_7_score_exactlike_differ": {
            "status": "supported" if best_score_row and best_exact_row and best_score_row.get("trajectory_id") != best_exact_row.get("trajectory_id") else "inconclusive",
            "evidence": {"best_score_trajectory": best_score_row.get("trajectory_id") if best_score_row else None, "best_exactlike_trajectory": best_exact_row.get("trajectory_id") if best_exact_row else None},
        },
        "H_STAGE5_8_cycle_diagnostics_available": {
            "status": "supported" if cycle_rows else "not_supported",
            "evidence": {"cycle_trajectory_count": len(cycle_rows), "median_basin_revisit_score": median(row.get("basin_revisit_score") for row in cycle_rows)},
        },
        "H_STAGE5_9_stage6_candidates_available": {
            "status": "supported" if stage6_rows else "not_supported",
            "evidence": {"stage6_candidate_count": len(stage6_rows)},
        },
        "H_STAGE5_10_dynamic_reward_prep_available": {
            "status": "supported" if dynamic_rows else "not_supported",
            "evidence": {"dynamic_reward_prep_rows": len(dynamic_rows), "safe_switch_rate": float(sum(1 for row in dynamic_rows if row.get("would_switch_to_safe_operator"))) / float(max(1, len(dynamic_rows)))},
        },
        "H_STAGE5_c01_c05_remain_promising": {
            "status": "supported" if c01_c05 and (not c09 or (med(c01_c05, "best_exactlike_score") or 0.0) > (med(c09, "best_exactlike_score") or 0.0)) else "inconclusive",
            "evidence": {"c01_c05_count": len(c01_c05), "c09_count": len(c09), "c01_c05_exactlike_median": med(c01_c05, "best_exactlike_score"), "c09_exactlike_median": med(c09, "best_exactlike_score")},
        },
        "H_STAGE5_routing_beats_baseline": {
            "status": "supported" if routed and baseline and (med(routed, "best_exactlike_score") or 0.0) > (med(baseline, "best_exactlike_score") or 0.0) else ("inconclusive" if not baseline else "not_supported"),
            "evidence": {"routed_count": len(routed), "baseline_count": len(baseline), "routed_exactlike_median": med(routed, "best_exactlike_score"), "baseline_exactlike_median": med(baseline, "best_exactlike_score")},
        },
    }


def write_stage5_summary(out_dir, trajectory_rows, stage6_rows, hypotheses, artifact_summary, cycle_rows, dynamic_rows):
    tuple_summary = summarize(trajectory_rows, "tuple_class_id")
    operator_summary = summarize(trajectory_rows, "operator")
    tuple_sorted = sorted(tuple_summary, key=lambda row: safe_float(row.get("exactlike_score_median"), 0.0), reverse=True)
    operator_sorted = sorted(operator_summary, key=lambda row: (safe_float(row.get("exactlike_score_median"), 0.0), -safe_float(row.get("damage_score_median"), 1.0)), reverse=True)
    best_score_row = min(trajectory_rows, key=lambda row: safe_float(row.get("best_score"), 10 ** 12)) if trajectory_rows else None
    best_exact_row = max(trajectory_rows, key=lambda row: safe_float(row.get("best_exactlike_score"), -1.0)) if trajectory_rows else None
    score0_count = sum(1 for row in trajectory_rows if int(row.get("best_score") or 1) == 0)
    lines = []
    lines.append("# p167 Stage 5 candidate deepening")
    lines.append("")
    lines.append("This is a Stage 5 production-candidate deepening diagnostic, not a Hadamard 668 construction run.")
    lines.append("")
    lines.append("Sampled diagnostics are not full certificates.")
    lines.append("")
    lines.append("## Scope")
    lines.append("")
    lines.append("- trajectory rows: `{}`".format(len(trajectory_rows)))
    lines.append("- unique candidates: `{}`".format(len(set(row.get("candidate_hash") for row in trajectory_rows))))
    lines.append("- Stage 6 recommendations: `{}`".format(len(stage6_rows)))
    lines.append("- score0 candidates: `{}`".format(score0_count))
    lines.append("- artifact bytes: `{}`".format(artifact_summary.get("artifact_total_bytes")))
    lines.append("- cycle diagnostic rows: `{}`".format(len(cycle_rows)))
    lines.append("- dynamic reward prep rows: `{}`".format(len(dynamic_rows)))
    lines.append("")
    lines.append("## Hypotheses")
    lines.append("")
    for key in sorted(hypotheses):
        lines.append("- `{}`: `{}`".format(key, hypotheses[key].get("status")))
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    lines.append("1. Stage 5 unique candidate 数: `{}`.".format(len(set(row.get("candidate_hash") for row in trajectory_rows))))
    lines.append("2. p167_c05 / p167_c01 は長時間でも有望か: `{}`.".format(hypotheses["H_STAGE5_c01_c05_remain_promising"]["status"]))
    lines.append("3. p167_c09 score160 系は benchmark / trap 寄りか: `{}`.".format(hypotheses["H_STAGE5_6_c09_benchmark_trap"]["status"]))
    lines.append("4. 短期指標は長時間でも持続したか: `{}`.".format(hypotheses["H_STAGE5_1_c05_c01_persist"]["status"]))
    lines.append("5. sudden improvement は出たか: `{}`.".format(hypotheses["H_STAGE5_2_sudden_improvement"]["status"]))
    lines.append("6. 最良 operator: `{}`.".format(operator_sorted[0].get("operator") if operator_sorted else "NA"))
    lines.append("7. mixed_operator_adaptive は主operatorとして有効か: `{}`.".format(hypotheses["H_STAGE5_3_mixed_main_operator"]["status"]))
    lines.append("8. pair_profile_movespace_filter は safety operator か: `{}`.".format(hypotheses["H_STAGE5_4_pair_filter_safe"]["status"]))
    lines.append("9. exact_joint_local_repair は damage guard が必要か: `{}`.".format(hypotheses["H_STAGE5_5_exact_joint_needs_guard"]["status"]))
    lines.append("10. best score は `{}`.".format(best_score_row.get("best_score") if best_score_row else "NA"))
    lines.append("11. best score と exact-like metrics は一致したか: `{}`.".format("no" if best_score_row and best_exact_row and best_score_row.get("trajectory_id") != best_exact_row.get("trajectory_id") else "inconclusive"))
    lines.append("12. score0 candidate は出たか: `{}`。出た場合のみ 08/05/04 検証対象。".format("yes" if score0_count else "no"))
    lines.append("13. 千日手的 repeat / plateau は cycle diagnostics を参照。median basin revisit score: `{}`.".format(median(row.get("basin_revisit_score") for row in cycle_rows)))
    lines.append("14. production candidates と benchmark trap の多様性比較は cycle_diagnostics_by_candidate を参照。")
    lines.append("15. Stage 6 candidate は `{}` 件。".format(len(stage6_rows)))
    lines.append("16. Stage 6 は `{}` / `{}` を中心に深掘り。".format(tuple_sorted[0].get("tuple_class_id") if tuple_sorted else "NA", operator_sorted[0].get("operator") if operator_sorted else "NA"))
    lines.append("17. dynamic reward 設計ログは `{}` 行。".format(len(dynamic_rows)))
    lines.append("18. window 指標は current artifact では snapshot/event-level proxy として保存。")
    lines.append("19. damage 予兆は dynamic_reward_trigger_events と phase_proxy_summary を参照。")
    lines.append("20. score改善時の closure/alignment/D_min 併発は stage5_event_summary を参照。")
    lines.append("21. phase_proxy 別 operator 傾向は dynamic_reward_prep_by_operator を参照。")
    lines.append("22. stuck_or_cycle 状態は cycle_diagnostics_by_operator を参照。")
    lines.append("23. dynamic reward で最初に動かす重み: damage / closure / alignment / mixing を候補。")
    lines.append("24. Stage 6 dynamic rule: high damageなら safe operator、high closureかつlow damageなら aggressive operator、cycle高なら mixing weight増。")
    lines.append("25. artifact size / runtime は artifact_size_summary と runtime_summary を参照。")
    lines.append("26. sampled diagnostic の限界: full certificate ではない。")
    lines.append("")
    lines.append("## Formula Notes")
    lines.append("")
    lines.append("- `S = sum_{d != 0} rho(d)^2`")
    lines.append("- `D_min_ratio = D_min_1 / S`")
    lines.append("- `kappa = -2g / q`")
    lines.append("- `alignment = <Delta rho, -rho> / (||Delta rho|| * ||rho||)`")
    with open(os.path.join(out_dir, "p167_stage5_candidate_deepening_summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def copy_if_exists(src, dst):
    if os.path.exists(src):
        shutil.copyfile(src, dst)


def postprocess_stage5_outputs(args):
    out_dir = args.out_dir
    copy_if_exists(os.path.join(out_dir, "input_stage2_survivors.jsonl"), os.path.join(out_dir, "input_stage5_candidates_deduped.jsonl"))

    trajectory_rows = read_jsonl(os.path.join(out_dir, "trajectory_level_records.jsonl")) if os.path.exists(os.path.join(out_dir, "trajectory_level_records.jsonl")) else []
    snapshot_rows = read_jsonl(os.path.join(out_dir, "snapshot_level_records.jsonl")) if os.path.exists(os.path.join(out_dir, "snapshot_level_records.jsonl")) else []
    reward_rows = read_jsonl(os.path.join(out_dir, "operator_reward_log.jsonl")) if os.path.exists(os.path.join(out_dir, "operator_reward_log.jsonl")) else []

    snapshot_rows = add_cycle_columns(snapshot_rows)
    write_jsonl(os.path.join(out_dir, "snapshot_level_records.jsonl"), snapshot_rows)

    candidate_summary = candidate_summary_rows(trajectory_rows)
    write_csv(os.path.join(out_dir, "candidate_summary.csv"), candidate_summary)
    write_json(os.path.join(out_dir, "candidate_summary.json"), candidate_summary)

    events = event_rows(snapshot_rows, reward_rows, int(args.event_window_before_accepted_moves), int(args.event_window_after_accepted_moves))
    event_summary = simple_event_summary(events)
    write_jsonl(os.path.join(out_dir, "stage5_event_windows.jsonl"), events)
    write_csv(os.path.join(out_dir, "stage5_event_summary.csv"), event_summary)
    write_json(os.path.join(out_dir, "stage5_event_summary.json"), event_summary)
    write_csv(os.path.join(out_dir, "score_event_summary.csv"), [row for row in event_summary if row.get("event_kind") == "best_score_state"])
    write_json(os.path.join(out_dir, "score_event_summary.json"), [row for row in event_summary if row.get("event_kind") == "best_score_state"])
    sudden = [row for row in events if row.get("event_kind") in ("best_score_state", "best_closure_shell_state", "best_alignment_state")]
    write_csv(os.path.join(out_dir, "sudden_improvement_summary.csv"), simple_event_summary(sudden))
    write_json(os.path.join(out_dir, "sudden_improvement_summary.json"), simple_event_summary(sudden))

    cycle_rows = cycle_diagnostics_by_trajectory(snapshot_rows, trajectory_rows)
    for row in trajectory_rows:
        cyc = next((c for c in cycle_rows if c.get("trajectory_id") == row.get("trajectory_id")), None)
        if cyc:
            row.update(
                {
                    "rho_repeat_rate": cyc.get("rho_repeat_rate"),
                    "support_repeat_rate": cyc.get("support_repeat_rate"),
                    "basin_revisit_score": cyc.get("basin_revisit_score"),
                    "max_score_plateau_length": cyc.get("max_score_plateau_length"),
                }
            )
    write_jsonl(os.path.join(out_dir, "trajectory_level_records.jsonl"), trajectory_rows)
    write_csv(os.path.join(out_dir, "cycle_diagnostics_by_trajectory.csv"), cycle_rows)
    write_json(os.path.join(out_dir, "cycle_diagnostics_by_trajectory.json"), cycle_rows)
    write_csv(os.path.join(out_dir, "cycle_diagnostics_by_operator.csv"), group_cycle_rows(cycle_rows, "operator"))
    write_json(os.path.join(out_dir, "cycle_diagnostics_by_operator.json"), group_cycle_rows(cycle_rows, "operator"))
    write_csv(os.path.join(out_dir, "cycle_diagnostics_by_candidate.csv"), group_cycle_rows(cycle_rows, "candidate_hash"))
    write_json(os.path.join(out_dir, "cycle_diagnostics_by_candidate.json"), group_cycle_rows(cycle_rows, "candidate_hash"))
    cycle_events = sorted([row for row in cycle_rows if safe_float(row.get("basin_revisit_score"), 0.0) > 0.25], key=lambda row: safe_float(row.get("basin_revisit_score"), 0.0), reverse=True)[: int(args.cycle_event_topk)]
    write_jsonl(os.path.join(out_dir, "cycle_revisit_events.jsonl"), cycle_events)

    dynamic_rows = dynamic_reward_prep_rows(trajectory_rows, cycle_rows)
    write_csv(os.path.join(out_dir, "dynamic_reward_prep_by_trajectory.csv"), dynamic_rows)
    write_json(os.path.join(out_dir, "dynamic_reward_prep_by_trajectory.json"), dynamic_rows)
    write_csv(os.path.join(out_dir, "dynamic_reward_prep_by_operator.csv"), group_dynamic_rows(dynamic_rows, "operator"))
    write_json(os.path.join(out_dir, "dynamic_reward_prep_by_operator.json"), group_dynamic_rows(dynamic_rows, "operator"))
    trigger_events = [row for row in dynamic_rows if row.get("would_switch_to_safe_operator") or row.get("would_switch_to_aggressive_operator")]
    trigger_events = sorted(trigger_events, key=lambda row: (row.get("would_switch_to_safe_operator") is True, safe_float(row.get("phase_proxy_stuck_or_cycle"), 0.0)), reverse=True)[: int(args.dynamic_trigger_event_topk)]
    write_jsonl(os.path.join(out_dir, "dynamic_reward_trigger_events.jsonl"), trigger_events)
    reward_components = reward_component_rows(reward_rows)
    reward_summary = reward_component_summary(reward_components)
    write_csv(os.path.join(out_dir, "reward_component_summary.csv"), reward_summary)
    write_json(os.path.join(out_dir, "reward_component_summary.json"), reward_summary)
    phase_summary = group_dynamic_rows(dynamic_rows, "operator")
    write_csv(os.path.join(out_dir, "phase_proxy_summary.csv"), phase_summary)
    write_json(os.path.join(out_dir, "phase_proxy_summary.json"), phase_summary)

    stage6_rows = stage6_candidates(trajectory_rows, int(args.stage6_candidate_limit))
    write_jsonl(os.path.join(out_dir, "stage6_candidate_recommendations.jsonl"), stage6_rows)
    write_csv(os.path.join(out_dir, "stage6_candidate_summary.csv"), stage6_rows)
    write_json(os.path.join(out_dir, "stage6_candidate_summary.json"), stage6_rows)

    hypotheses = stage5_hypotheses(trajectory_rows, stage6_rows, cycle_rows, dynamic_rows)
    write_json(os.path.join(out_dir, "hypothesis_evaluation.json"), hypotheses)

    effective_path = os.path.join(out_dir, "actual_effective_config.json")
    if os.path.exists(effective_path):
        with open(effective_path) as f:
            effective = json.load(f)
        effective["stage4_artifact"] = args.stage4_artifact
        effective["github_run_id"] = args.github_run_id or os.environ.get("GITHUB_RUN_ID")
        effective["artifact_names"] = {"summary": "p167-stage5-summary-{}".format(args.github_run_id or os.environ.get("GITHUB_RUN_ID") or "<run_id>"), "raw": "p167-stage5-raw-logs-{}".format(args.github_run_id or os.environ.get("GITHUB_RUN_ID") or "<run_id>")}
        write_json(effective_path, effective)

    artifact_summary = S2["artifact_size_summary"](out_dir)
    write_stage5_summary(out_dir, trajectory_rows, stage6_rows, hypotheses, artifact_summary, cycle_rows, dynamic_rows)
    artifact_summary = S2["artifact_size_summary"](out_dir)
    write_json(os.path.join(out_dir, "artifact_size_summary.json"), artifact_summary)

    run_config_path = os.path.join(out_dir, "run_config.json")
    run_config = {}
    if os.path.exists(run_config_path):
        with open(run_config_path) as f:
            run_config = json.load(f)
    score0_count = sum(1 for row in trajectory_rows if int(row.get("best_score") or 1) == 0)
    best_score = min([safe_float(row.get("best_score"), 10 ** 12) for row in trajectory_rows] or [None])
    run_config.update(
        {
            "stage4_unique_candidate_rows": len(set(row.get("candidate_hash") for row in trajectory_rows)),
            "stage5_unique_candidate_rows": len(set(row.get("candidate_hash") for row in trajectory_rows)),
            "stage6_candidate_rows": len(stage6_rows),
            "score0_candidate_count": int(score0_count),
            "best_score": int(best_score) if best_score is not None and best_score < 10 ** 12 else None,
            "artifact_total_bytes": artifact_summary.get("artifact_total_bytes"),
        }
    )
    write_json(run_config_path, run_config)

    run_id = args.github_run_id or os.environ.get("GITHUB_RUN_ID") or "<run_id>"
    file_sizes = artifact_summary.get("files", {})
    stage5_manifest = {
        "github_run_id": run_id,
        "code_commit": args.code_commit,
        "config_hash": run_config.get("config_hash"),
        "input_manifest_hash": run_config.get("input_manifest_hash"),
        "summary_artifact_name": "p167-stage5-summary-{}".format(run_id),
        "raw_artifact_name": "p167-stage5-raw-logs-{}".format(run_id),
        "summary_files": sorted(path for path in file_sizes if not path.startswith("raw_logs/")),
        "raw_files": sorted(path for path in file_sizes if path.startswith("raw_logs/")),
        "file_sizes_bytes": file_sizes,
        "compressed_file_sizes_bytes": {},
        "raw_logs_uploaded": bool(args.upload_raw_logs and str(args.artifact_mode) == "summary_plus_raw"),
        "raw_log_policy": {
            "artifact_mode": args.artifact_mode,
            "compress_raw_logs": bool(args.compress_raw_logs),
            "upload_raw_logs": bool(args.upload_raw_logs),
        },
        "snapshot_log_policy": args.snapshot_log_mode,
        "operator_reward_log_policy": args.operator_reward_log_mode,
        "full_snapshot_available": bool(args.artifact_mode == "summary_plus_raw"),
        "full_snapshot_path": "raw_logs/snapshot_level_records.jsonl.gz" if bool(args.artifact_mode == "summary_plus_raw") else None,
        "operator_reward_full_available": bool(args.artifact_mode == "summary_plus_raw" or args.operator_reward_log_mode == "full_compressed"),
        "operator_reward_full_path": "raw_logs/operator_reward_log.jsonl.gz" if bool(args.artifact_mode == "summary_plus_raw") else None,
        "notes": [
            "Stage 5 uses deduped unique candidate hashes from Stage 4 recommendations.",
            "Summary artifact is authoritative for normal audit.",
            "Sampled diagnostics are not full certificates.",
            "Cycle and dynamic reward diagnostics are observational only and do not affect move acceptance.",
        ],
    }
    write_json(os.path.join(out_dir, "stage5_artifact_manifest.json"), stage5_manifest)
    with open(os.path.join(out_dir, "run_log.md"), "a") as f:
        f.write("\n## Stage 5 postprocess\n\n")
        f.write("- input_stage5_candidates_deduped.jsonl alias written\n")
        f.write("- stage6_candidate_recommendations.jsonl written\n")
        f.write("- cycle and dynamic reward prep summaries written\n")
        f.write("- p167_stage5_candidate_deepening_summary.md written\n")


def build_parser():
    parser = argparse.ArgumentParser(description=SCRIPT_NAME)
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--tuple-registry", default=DEFAULT_TUPLE_REGISTRY)
    parser.add_argument("--stage4-artifact", default=DEFAULT_STAGE4_ARTIFACT)
    parser.add_argument("--stage5-budget-plan", default="")
    parser.add_argument("--stage4-seed-base", type=int, default=770167)
    parser.add_argument("--stage4-replay-steps", type=int, default=5000)
    parser.add_argument("--stage4-replay-sample-swaps", type=int, default=500)
    parser.add_argument("--aggregate-roots", default="")
    parser.add_argument("--benchmark-trap-manifest", default=S2["DEFAULT_BENCHMARK_TRAPS"])
    parser.add_argument("--nearhit-fixture", default=S2["DEFAULT_NEARHIT_FIXTURE"])
    parser.add_argument("--operators", default=",".join(STAGE5_OPERATORS))
    parser.add_argument("--production-candidate-limit", type=int, default=10)
    parser.add_argument("--guarded-repair-limit", type=int, default=4)
    parser.add_argument("--repair-target-limit", type=int, default=2)
    parser.add_argument("--operator-benchmark-limit", type=int, default=1)
    parser.add_argument("--needs-more-diagnostics-limit", type=int, default=1)
    parser.add_argument("--archive-limit", type=int, default=0)
    parser.add_argument("--total-candidate-limit", type=int, default=13)
    parser.add_argument("--production-c05-restarts", type=int, default=28)
    parser.add_argument("--production-c01-restarts", type=int, default=22)
    parser.add_argument("--production-c05-steps", type=int, default=12000)
    parser.add_argument("--production-c01-steps", type=int, default=10000)
    parser.add_argument("--production-c05-sample-swaps", type=int, default=700)
    parser.add_argument("--production-c01-sample-swaps", type=int, default=700)
    parser.add_argument("--repair-restarts", type=int, default=14)
    parser.add_argument("--repair-steps", type=int, default=9000)
    parser.add_argument("--repair-sample-swaps", type=int, default=700)
    parser.add_argument("--benchmark-restarts", type=int, default=6)
    parser.add_argument("--benchmark-steps", type=int, default=5000)
    parser.add_argument("--benchmark-sample-swaps", type=int, default=500)
    parser.add_argument("--diagnostic-restarts", type=int, default=4)
    parser.add_argument("--baseline-restarts", type=int, default=1)
    parser.add_argument("--survivor-limit", type=int, default=13)
    parser.add_argument("--benchmark-trap-limit", type=int, default=0)
    parser.add_argument("--random-control-limit", type=int, default=0)
    parser.add_argument("--nearhit-control-limit", type=int, default=0)
    parser.add_argument("--restarts", type=int, default=1)
    parser.add_argument("--steps", type=int, default=12000)
    parser.add_argument("--sample-swaps", type=int, default=700)
    parser.add_argument("--diagnostic-sample-count", type=int, default=500)
    parser.add_argument("--diagnostic-type", default="sampled")
    parser.add_argument("--snapshot-attempted-steps", default="0,100,250,500,1000,2500,5000,10000,12000")
    parser.add_argument("--snapshot-accepted-moves", default="0,50,100,250,500,1000,2000")
    parser.add_argument("--uphill-threshold", type=int, default=16)
    parser.add_argument("--no-move-patience", type=int, default=320)
    parser.add_argument("--high-resolution-logging", action="store_true", default=False)
    parser.add_argument("--disable-high-resolution-logging", action="store_false", dest="high_resolution_logging")
    parser.add_argument("--highres-followup-accepted-moves", type=int, default=50)
    parser.add_argument("--high-resolution-mode", choices=["off", "triggered", "all"], default="triggered")
    parser.add_argument("--high-resolution-max-windows-per-trajectory", type=int, default=2)
    parser.add_argument("--high-resolution-window-accepted-moves", type=int, default=50)
    parser.add_argument("--event-window-before-accepted-moves", type=int, default=20)
    parser.add_argument("--event-window-after-accepted-moves", type=int, default=20)
    parser.add_argument("--artifact-mode", choices=["summary_only", "summary_plus_raw"], default="summary_only")
    parser.add_argument("--compress-raw-logs", action="store_true", default=True)
    parser.add_argument("--no-compress-raw-logs", action="store_false", dest="compress_raw_logs")
    parser.add_argument("--upload-raw-logs", action="store_true", default=False)
    parser.add_argument("--disable-raw-log-upload", action="store_false", dest="upload_raw_logs")
    parser.add_argument("--snapshot-log-mode", choices=["summary_only", "scheduled", "triggered", "full"], default="summary_only")
    parser.add_argument("--operator-reward-log-mode", choices=["summary_only", "topk", "sampled", "full_compressed"], default="topk")
    parser.add_argument("--operator-reward-topk", type=int, default=50)
    parser.add_argument("--operator-reward-sample-rate", type=float, default=0.01)
    parser.add_argument("--shard-index", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--max-tasks", type=int, default=0)
    parser.add_argument("--seed-base", type=int, default=780167)
    parser.add_argument("--stage6-candidate-limit", type=int, default=13)
    parser.add_argument("--stage3-candidate-limit", type=int, default=13)
    parser.add_argument("--cycle-event-topk", type=int, default=200)
    parser.add_argument("--dynamic-trigger-event-topk", type=int, default=200)
    parser.add_argument("--github-run-id", default="")
    parser.add_argument("--code-commit", default="")
    parser.add_argument("--run-label", default="")
    parser.add_argument("--stage-name", default="p167_stage5")
    parser.add_argument("--out-dir", default=None)
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    if not args.run_label:
        args.run_label = args.github_run_id or "local-stage5"
    if args.out_dir is None:
        args.out_dir = os.path.join("outputs", "explorations", "{}_p167_stage5_candidate_deepening".format(now_stamp()))
    if not bool(args.high_resolution_logging):
        args.high_resolution_mode = "off"
    if str(args.artifact_mode) == "summary_plus_raw":
        args.upload_raw_logs = True
    args.stage1_artifact = args.stage4_artifact

    S2["load_stage2_candidates"] = load_stage5_candidates
    S2["task_grid"] = stage5_task_grid
    S2["choose_stage2_move"] = choose_stage5_move
    S2["emit_stage2_snapshot"] = emit_stage5_snapshot
    S2["run_task"] = run_stage5_task
    S2["stage3_candidates"] = stage6_candidates
    S2["run"](args)
    postprocess_stage5_outputs(args)
    print("Wrote p167_stage5 postprocessed outputs to {}".format(args.out_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(int(main() or 0))
