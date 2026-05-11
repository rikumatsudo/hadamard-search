from sage.all import *

import argparse
import json
import math
import os
import shutil
import time


SCRIPT_NAME = "77_p167_stage4_candidate_deepening"
STAGE2_LIB_PATH = "sage/75_p167_stage2_survivor_deepening.sage"
DEFAULT_CONFIG = "configs/experiments/p167_stage4_candidate_deepening.yaml"
DEFAULT_TUPLE_REGISTRY = "configs/fixtures/p167_tuple_classes.json"
DEFAULT_STAGE3_ARTIFACT = "/tmp/hadamard-stage3-medium-40-aggregate"


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
apply_move = S2["apply_move"]
apply_sparse_delta = S2["apply_sparse_delta"]
state_hash = S2["state_hash"]
json_blocks = S2["json_blocks"]
rows_by_key = S2["rows_by_key"]
median = S2["median"]
summarize = S2["summarize"]
ORIGINAL_CHOOSE_STAGE2_MOVE = S2["choose_stage2_move"]


STAGE4_OPERATORS = (
    "stage4_mixed_operator_adaptive",
    "stage4_exact_joint_local_repair",
    "stage4_pair_profile_movespace_filter",
    "stage4_baseline_score_only",
)

STAGE4_TO_STAGE2_OPERATOR = {
    "stage4_mixed_operator_adaptive": "survivor_mixed_operator_adaptive",
    "stage4_exact_joint_local_repair": "survivor_exact_joint_local_repair",
    "stage4_pair_profile_movespace_filter": "survivor_pair_profile_movespace_filter",
    "stage4_baseline_score_only": "survivor_baseline_score_only",
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


def stage3_paths(stage3_artifact):
    root = stage3_artifact
    if not os.path.isdir(root):
        raise RuntimeError("Stage 3 artifact path does not exist: {}".format(root))
    paths = {
        "recommendations": os.path.join(root, "stage4_candidate_recommendations.jsonl"),
        "trajectory": os.path.join(root, "trajectory_level_records.jsonl"),
        "run": os.path.join(root, "run_level_records.jsonl"),
        "candidates": os.path.join(root, "input_stage3_candidates.jsonl"),
    }
    for name, path in paths.items():
        if not os.path.exists(path):
            raise RuntimeError("Stage 3 artifact missing {}: {}".format(name, path))
    return paths


def stage4_recommendation_score(row):
    rec_weight = {
        "production_deep_search": 20.0,
        "repair_target": 12.0,
        "operator_benchmark": 4.0,
        "needs_more_diagnostics": 2.0,
        "archive": 0.0,
    }
    value = rec_weight.get(row.get("recommendation"), 0.0)
    value += 3.0 * safe_float(row.get("stage3_best_exactlike_score"), 0.0)
    value += 1.0 * safe_float(row.get("stage3_best_closure_shell_score"), 0.0)
    value += 2.0 * safe_float(row.get("stage3_best_alignment"), 0.0)
    value -= 0.5 * safe_float(row.get("stage3_damage_score"), 0.0)
    if row.get("tuple_class_id") in ("p167_c01", "p167_c05"):
        value += 0.5
    return float(value)


def select_stage4_recommendations(rows, args):
    grouped = {}
    for row in rows:
        grouped.setdefault(row.get("candidate_hash"), []).append(row)
    selected = []
    for candidate_hash, group in grouped.items():
        group = sorted(group, key=stage4_recommendation_score, reverse=True)
        best = dict(group[0])
        best["all_stage4_recommendations"] = sorted(set(row.get("recommendation") for row in group if row.get("recommendation")))
        best["all_supporting_trajectories"] = [
            {
                "trajectory_id": row.get("trajectory_id"),
                "recommendation": row.get("recommendation"),
                "stage3_best_operator": row.get("stage3_best_operator"),
                "stage3_best_score": row.get("stage3_best_score"),
                "stage3_best_exactlike_score": row.get("stage3_best_exactlike_score"),
                "stage3_best_closure_shell_score": row.get("stage3_best_closure_shell_score"),
                "stage3_best_alignment": row.get("stage3_best_alignment"),
                "stage3_damage_score": row.get("stage3_damage_score"),
                "why_selected": row.get("why_selected"),
            }
            for row in group
        ]
        selected.append(best)
    selected.sort(key=stage4_recommendation_score, reverse=True)

    if int(args.production_candidate_limit) >= 0:
        production = [row for row in selected if recommended_stage4_role(row) == "production_deep_search"][: int(args.production_candidate_limit)]
    else:
        production = [row for row in selected if recommended_stage4_role(row) == "production_deep_search"]
    guarded = [row for row in selected if recommended_stage4_role(row) == "guarded_repair"][: int(args.guarded_repair_limit)]
    repair = [row for row in selected if recommended_stage4_role(row) == "repair_target"][: int(args.repair_target_limit)]
    benchmark = [row for row in selected if recommended_stage4_role(row) == "operator_benchmark"][: int(args.operator_benchmark_limit)]
    diagnostics = [row for row in selected if recommended_stage4_role(row) == "needs_more_diagnostics"][: int(args.needs_more_diagnostics_limit)]
    archive = [row for row in selected if recommended_stage4_role(row) == "archive"][: int(args.archive_limit)]

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


def recommended_stage4_role(row):
    tuple_id = row.get("tuple_class_id")
    rec = row.get("recommendation")
    damage = safe_float(row.get("stage3_damage_score"), 0.0)
    exactlike = safe_float(row.get("stage3_best_exactlike_score"), 0.0)
    score = safe_float(row.get("stage3_best_score"), 10 ** 9)
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


def operator_budget_for_role(role, args):
    main = [
        "stage4_mixed_operator_adaptive",
        "stage4_exact_joint_local_repair",
        "stage4_pair_profile_movespace_filter",
    ]
    budget = {}
    if role == "production_deep_search":
        for op in main:
            budget[op] = int(args.production_restarts)
        budget["stage4_baseline_score_only"] = int(args.baseline_restarts)
    elif role == "guarded_repair":
        budget["stage4_pair_profile_movespace_filter"] = int(args.repair_restarts)
        budget["stage4_mixed_operator_adaptive"] = int(args.repair_restarts)
        budget["stage4_exact_joint_local_repair"] = max(1, int(args.repair_restarts) // 2)
        budget["stage4_baseline_score_only"] = int(args.baseline_restarts)
    elif role == "repair_target":
        budget["stage4_pair_profile_movespace_filter"] = int(args.repair_restarts)
        budget["stage4_exact_joint_local_repair"] = int(args.repair_restarts)
        budget["stage4_mixed_operator_adaptive"] = max(1, int(args.repair_restarts) // 2)
    elif role == "operator_benchmark":
        for op in main:
            budget[op] = int(args.benchmark_restarts)
        if int(args.baseline_restarts) > 0:
            budget["stage4_baseline_score_only"] = int(args.baseline_restarts)
    elif role == "needs_more_diagnostics":
        budget["stage4_mixed_operator_adaptive"] = int(args.diagnostic_restarts)
        budget["stage4_pair_profile_movespace_filter"] = int(args.diagnostic_restarts)
    else:
        budget["stage4_baseline_score_only"] = max(1, int(args.baseline_restarts))
    allowed = set(parse_list(args.operators, STAGE4_OPERATORS))
    return {op: max(0, int(n)) for op, n in budget.items() if op in allowed and int(n) > 0}


def choose_stage4_move(task_operator, blocks, counts, lam, p, rng, sample_swaps, uphill_threshold, operator_state):
    mapped = STAGE4_TO_STAGE2_OPERATOR.get(task_operator, task_operator)
    return ORIGINAL_CHOOSE_STAGE2_MOVE(mapped, blocks, counts, lam, p, rng, sample_swaps, uphill_threshold, operator_state)


def replay_stage3_best_blocks(candidate, trajectory, args):
    p = int(candidate["p"])
    ks = [int(k) for k in candidate["ks"]]
    lam = int(candidate["lambda"])
    blocks = [set(int(x) for x in block) for block in candidate["blocks"]]
    counts = total_diff_counts(p, blocks)
    initial_score = score_counts(counts, lam)
    best_score = int(initial_score)
    best_blocks = [set(block) for block in blocks]
    stage_name = trajectory.get("stage_name") or "p167_stage3"
    candidate_id = trajectory.get("candidate_id") or candidate.get("candidate_id")
    operator = trajectory.get("operator")
    restart_id = int(trajectory.get("restart_id") or 0)
    raw = "{}:{}:{}:{}".format(candidate_id, operator, restart_id, stage_name)
    run_seed = int(args.stage3_seed_base) + int(deterministic_seed(raw) % 1000000007)
    row_cfg = trajectory.get("row_level_config") or {}
    steps = int(row_cfg.get("steps") or args.stage3_replay_steps)
    sample_swaps = int(row_cfg.get("sample_swaps") or args.stage3_replay_sample_swaps)
    uphill_threshold = int(row_cfg.get("uphill_threshold") or args.uphill_threshold)
    operator_state = {}
    accepted = 0
    for step in range(1, steps + 1):
        rng = S2["seeded_rng"](run_seed + step * 1009)
        move, _target_d, _selected_operator, _selected_reason = choose_stage4_move(
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


def load_stage4_candidates(args, tuple_rows):
    paths = stage3_paths(args.stage3_artifact)
    recommendations = select_stage4_recommendations(read_jsonl(paths["recommendations"]), args)
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
        replay = replay_stage3_best_blocks(candidate, trajectory, args)
        h = replay["recovered_hash"]
        role = recommended_stage4_role(rec)
        budget = operator_budget_for_role(role, args)
        out.append(
            {
                "candidate_id": "stage4_{:03d}_{}".format(idx, h[:12]),
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
                "stage3_run_id": trajectory.get("run_id"),
                "stage3_trajectory_id": trajectory.get("trajectory_id"),
                "stage3_recommendation": rec.get("recommendation"),
                "stage3_selection_reason": rec.get("why_selected"),
                "stage3_best_operator": rec.get("stage3_best_operator") or trajectory.get("operator"),
                "stage3_best_score": rec.get("stage3_best_score") or trajectory.get("best_score"),
                "stage3_best_exactlike_score": rec.get("stage3_best_exactlike_score") or trajectory.get("best_exactlike_score"),
                "stage3_best_closure_shell_score": rec.get("stage3_best_closure_shell_score") or trajectory.get("best_closure_shell_score"),
                "stage3_best_alignment": rec.get("stage3_best_alignment") or trajectory.get("best_alignment_to_minus_rho"),
                "stage3_damage_score": rec.get("stage3_damage_score") or trajectory.get("damage_score"),
                "all_stage4_recommendations": rec.get("all_stage4_recommendations"),
                "all_supporting_trajectories": rec.get("all_supporting_trajectories"),
                "recommended_stage4_role": role,
                "recommended_operator_budget": budget,
                "why_selected": rec.get("why_selected"),
                "stage3_replay_hash": h,
                "stage3_replay_hash_match": replay["hash_match"],
                "stage3_replay_best_score": replay["best_score"],
                "stage3_replay_accepted_moves": replay["accepted_moves_replayed"],
                "candidate_lineage": {
                    "source": "stage3_recommendation_replay",
                    "stage4_recommendation": rec,
                    "stage3_trajectory": {
                        "run_id": trajectory.get("run_id"),
                        "trajectory_id": trajectory.get("trajectory_id"),
                        "candidate_lineage": trajectory.get("candidate_lineage"),
                    },
                    "stage3_replay": {key: value for key, value in replay.items() if key != "blocks"},
                },
            }
        )
    return out, []


def stage4_task_grid(candidates, operators, restarts, seed_base, stage_name):
    tasks = []
    allowed = set(parse_list(",".join(operators) if isinstance(operators, (list, tuple)) else operators, STAGE4_OPERATORS))
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
                    }
                )
                tasks.append(task)
    tasks.sort(key=lambda row: stable_hash("{}:{}:{}".format(row["candidate_id"], row["operator"], row["restart_id"])))
    return tasks


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


def stage5_candidates(trajectory_rows, limit):
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
                "stage4_role": best.get("source"),
                "stage4_best_operator": best.get("operator"),
                "stage4_best_score": best.get("best_score"),
                "stage4_best_exactlike_score": best.get("best_exactlike_score"),
                "stage4_best_closure_shell_score": best.get("best_closure_shell_score"),
                "stage4_best_alignment": best.get("best_alignment_to_minus_rho"),
                "stage4_damage_score": best.get("damage_score"),
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
            safe_float(row.get("stage4_best_exactlike_score"), 0.0),
            safe_float(row.get("stage4_best_closure_shell_score"), 0.0),
            -safe_float(row.get("stage4_damage_score"), 0.0),
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


def stage4_hypotheses(trajectory_rows, stage5_rows):
    by_tuple = rows_by_key(trajectory_rows, "tuple_class_id")
    by_operator = rows_by_key(trajectory_rows, "operator")
    c01_c05 = by_tuple.get("p167_c01", []) + by_tuple.get("p167_c05", [])
    c09 = by_tuple.get("p167_c09", [])
    baseline = by_operator.get("stage4_baseline_score_only", [])
    routed = [row for row in trajectory_rows if row.get("operator") != "stage4_baseline_score_only"]
    mixed = by_operator.get("stage4_mixed_operator_adaptive", [])
    exact_joint = by_operator.get("stage4_exact_joint_local_repair", [])
    pair_filter = by_operator.get("stage4_pair_profile_movespace_filter", [])
    best_score_row = min(trajectory_rows, key=lambda row: safe_float(row.get("best_score"), 10 ** 12)) if trajectory_rows else None
    best_exact_row = max(trajectory_rows, key=lambda row: safe_float(row.get("best_exactlike_score"), -1.0)) if trajectory_rows else None

    def med(rows, key):
        return median(row.get(key) for row in rows)

    return {
        "H_STAGE4_1_short_indicator_persistence": {
            "status": "supported" if trajectory_rows and (med(trajectory_rows, "best_closure_shell_score") or 0.0) >= 2.0 else "inconclusive",
            "evidence": {"median_closure": med(trajectory_rows, "best_closure_shell_score"), "median_damage": med(trajectory_rows, "damage_score")},
        },
        "H_STAGE4_2_sudden_improvement_exists": {
            "status": "supported" if any(safe_float(row.get("score_delta_from_start"), 0.0) < -500 for row in trajectory_rows) else "inconclusive",
            "evidence": {"large_score_drop_count": sum(1 for row in trajectory_rows if safe_float(row.get("score_delta_from_start"), 0.0) < -500)},
        },
        "H_STAGE4_3_c01_c05_remain_promising": {
            "status": "supported" if c01_c05 and (not c09 or (med(c01_c05, "best_exactlike_score") or 0.0) > (med(c09, "best_exactlike_score") or 0.0)) else "inconclusive",
            "evidence": {"c01_c05_count": len(c01_c05), "c09_count": len(c09), "c01_c05_exactlike_median": med(c01_c05, "best_exactlike_score"), "c09_exactlike_median": med(c09, "best_exactlike_score")},
        },
        "H_STAGE4_4_routing_beats_baseline": {
            "status": "supported" if routed and baseline and (med(routed, "best_exactlike_score") or 0.0) > (med(baseline, "best_exactlike_score") or 0.0) else ("inconclusive" if not baseline else "not_supported"),
            "evidence": {"routed_count": len(routed), "baseline_count": len(baseline), "routed_exactlike_median": med(routed, "best_exactlike_score"), "baseline_exactlike_median": med(baseline, "best_exactlike_score")},
        },
        "H_STAGE4_5_score_exactlike_differ": {
            "status": "supported" if best_score_row and best_exact_row and best_score_row.get("trajectory_id") != best_exact_row.get("trajectory_id") else "inconclusive",
            "evidence": {"best_score_trajectory": best_score_row.get("trajectory_id") if best_score_row else None, "best_exactlike_trajectory": best_exact_row.get("trajectory_id") if best_exact_row else None},
        },
        "H_STAGE4_6_stage5_candidates_available": {
            "status": "supported" if stage5_rows else "not_supported",
            "evidence": {"stage5_candidate_count": len(stage5_rows)},
        },
        "H_STAGE4_exact_joint_tradeoff": {
            "status": "supported" if exact_joint and (med(exact_joint, "score_delta_from_start") or 0.0) < 0.0 and (med(exact_joint, "damage_score") or 0.0) >= 0.35 else "inconclusive",
            "evidence": {"exact_joint_count": len(exact_joint), "median_score_delta": med(exact_joint, "score_delta_from_start"), "median_damage": med(exact_joint, "damage_score")},
        },
        "H_STAGE4_pair_filter_safe": {
            "status": "supported" if pair_filter and (med(pair_filter, "damage_score") or 1.0) <= 0.35 else "inconclusive",
            "evidence": {"pair_filter_count": len(pair_filter), "median_damage": med(pair_filter, "damage_score")},
        },
        "H_STAGE4_c09_benchmark": {
            "status": "supported" if c09 and (med(c09, "best_exactlike_score") or 1.0) < 0.50 else "inconclusive",
            "evidence": {"c09_count": len(c09), "c09_exactlike_median": med(c09, "best_exactlike_score"), "c09_best_score_median": med(c09, "best_score")},
        },
    }


def write_stage4_summary(out_dir, trajectory_rows, stage5_rows, hypotheses, artifact_summary):
    tuple_summary = summarize(trajectory_rows, "tuple_class_id")
    operator_summary = summarize(trajectory_rows, "operator")
    tuple_sorted = sorted(tuple_summary, key=lambda row: safe_float(row.get("exactlike_score_median"), 0.0), reverse=True)
    operator_sorted = sorted(operator_summary, key=lambda row: (safe_float(row.get("exactlike_score_median"), 0.0), -safe_float(row.get("damage_score_median"), 1.0)), reverse=True)
    best_score_row = min(trajectory_rows, key=lambda row: safe_float(row.get("best_score"), 10 ** 12)) if trajectory_rows else None
    best_exact_row = max(trajectory_rows, key=lambda row: safe_float(row.get("best_exactlike_score"), -1.0)) if trajectory_rows else None
    score0_count = sum(1 for row in trajectory_rows if int(row.get("best_score") or 1) == 0)
    lines = []
    lines.append("# p167 Stage 4 candidate deepening")
    lines.append("")
    lines.append("This is a Stage 4 candidate deepening diagnostic, not a Hadamard 668 construction run.")
    lines.append("")
    lines.append("Sampled diagnostics are not full certificates.")
    lines.append("")
    lines.append("## Scope")
    lines.append("")
    lines.append("- trajectory rows: `{}`".format(len(trajectory_rows)))
    lines.append("- unique candidates: `{}`".format(len(set(row.get("candidate_hash") for row in trajectory_rows))))
    lines.append("- Stage 5 recommendations: `{}`".format(len(stage5_rows)))
    lines.append("- score0 candidates: `{}`".format(score0_count))
    lines.append("- artifact bytes: `{}`".format(artifact_summary.get("artifact_total_bytes")))
    lines.append("")
    lines.append("## Hypotheses")
    lines.append("")
    for key in sorted(hypotheses):
        lines.append("- `{}`: `{}`".format(key, hypotheses[key].get("status")))
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    lines.append("1. Stage 4 unique candidate 数: `{}`.".format(len(set(row.get("candidate_hash") for row in trajectory_rows))))
    lines.append("2. p167_c01 / p167_c05 は Stage 4 でも有望か: `{}`.".format(hypotheses["H_STAGE4_3_c01_c05_remain_promising"]["status"]))
    lines.append("3. p167_c09 score160 系は benchmark / trap 寄りか: `{}`.".format(hypotheses["H_STAGE4_c09_benchmark"]["status"]))
    lines.append("4. 短期指標は長時間でも持続したか: `{}`.".format(hypotheses["H_STAGE4_1_short_indicator_persistence"]["status"]))
    lines.append("5. 突然改善型 trajectory は出たか: `{}`.".format(hypotheses["H_STAGE4_2_sudden_improvement_exists"]["status"]))
    lines.append("6. 最良 operator: `{}`.".format(operator_sorted[0].get("operator") if operator_sorted else "NA"))
    lines.append("7. mixed_operator_adaptive は baseline より良かったか: `{}`.".format(hypotheses["H_STAGE4_4_routing_beats_baseline"]["status"]))
    lines.append("8. exact_joint_local_repair の score/damage tradeoff: `{}`.".format(hypotheses["H_STAGE4_exact_joint_tradeoff"]["status"]))
    lines.append("9. pair_profile_movespace_filter は安全 operator か: `{}`.".format(hypotheses["H_STAGE4_pair_filter_safe"]["status"]))
    lines.append("10. best score は `{}`.".format(best_score_row.get("best_score") if best_score_row else "NA"))
    lines.append("11. best score と exact-like metrics は一致したか: `{}`.".format("no" if best_score_row and best_exact_row and best_score_row.get("trajectory_id") != best_exact_row.get("trajectory_id") else "inconclusive"))
    lines.append("12. score0 candidate は出たか: `{}`。出た場合のみ 08/05/04 検証対象。".format("yes" if score0_count else "no"))
    lines.append("13. Stage 5 candidate は `{}` 件。".format(len(stage5_rows)))
    lines.append("14. Stage 5 は `{}` / `{}` を中心に深掘り。".format(tuple_sorted[0].get("tuple_class_id") if tuple_sorted else "NA", operator_sorted[0].get("operator") if operator_sorted else "NA"))
    lines.append("15. artifact size / runtime は artifact_size_summary と runtime_summary を参照。")
    lines.append("16. sampled diagnostic の限界: full certificate ではない。")
    lines.append("")
    lines.append("## Formula Notes")
    lines.append("")
    lines.append("- `S = sum_{d != 0} rho(d)^2`")
    lines.append("- `D_min_ratio = D_min_1 / S`")
    lines.append("- `kappa = -2g / q`")
    lines.append("- `alignment = <Delta rho, -rho> / (||Delta rho|| * ||rho||)`")
    with open(os.path.join(out_dir, "p167_stage4_candidate_deepening_summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def copy_if_exists(src, dst):
    if os.path.exists(src):
        shutil.copyfile(src, dst)


def postprocess_stage4_outputs(args):
    out_dir = args.out_dir
    copy_if_exists(os.path.join(out_dir, "input_stage2_survivors.jsonl"), os.path.join(out_dir, "input_stage4_candidates_deduped.jsonl"))
    copy_if_exists(os.path.join(out_dir, "stage3_candidate_recommendations.jsonl"), os.path.join(out_dir, "stage5_candidate_recommendations.jsonl"))
    copy_if_exists(os.path.join(out_dir, "stage3_candidate_summary.csv"), os.path.join(out_dir, "stage5_candidate_summary.csv"))
    copy_if_exists(os.path.join(out_dir, "stage3_candidate_summary.json"), os.path.join(out_dir, "stage5_candidate_summary.json"))
    copy_if_exists(os.path.join(out_dir, "stage2_artifact_policy_summary.md"), os.path.join(out_dir, "stage4_artifact_policy_summary.md"))

    trajectory_rows = read_jsonl(os.path.join(out_dir, "trajectory_level_records.jsonl")) if os.path.exists(os.path.join(out_dir, "trajectory_level_records.jsonl")) else []
    snapshot_rows = read_jsonl(os.path.join(out_dir, "snapshot_level_records.jsonl")) if os.path.exists(os.path.join(out_dir, "snapshot_level_records.jsonl")) else []
    reward_rows = read_jsonl(os.path.join(out_dir, "operator_reward_log.jsonl")) if os.path.exists(os.path.join(out_dir, "operator_reward_log.jsonl")) else []
    stage5_rows = read_jsonl(os.path.join(out_dir, "stage5_candidate_recommendations.jsonl")) if os.path.exists(os.path.join(out_dir, "stage5_candidate_recommendations.jsonl")) else []

    candidate_summary = candidate_summary_rows(trajectory_rows)
    write_csv(os.path.join(out_dir, "candidate_summary.csv"), candidate_summary)
    write_json(os.path.join(out_dir, "candidate_summary.json"), candidate_summary)

    events = event_rows(snapshot_rows, reward_rows, int(args.event_window_before_accepted_moves), int(args.event_window_after_accepted_moves))
    event_summary = simple_event_summary(events)
    write_jsonl(os.path.join(out_dir, "stage4_event_windows.jsonl"), events)
    write_csv(os.path.join(out_dir, "stage4_event_summary.csv"), event_summary)
    write_json(os.path.join(out_dir, "stage4_event_summary.json"), event_summary)
    write_csv(os.path.join(out_dir, "score_event_summary.csv"), [row for row in event_summary if row.get("event_kind") == "best_score_state"])
    write_json(os.path.join(out_dir, "score_event_summary.json"), [row for row in event_summary if row.get("event_kind") == "best_score_state"])
    sudden = [row for row in events if row.get("event_kind") in ("best_score_state", "best_closure_shell_state", "best_alignment_state")]
    write_csv(os.path.join(out_dir, "sudden_improvement_summary.csv"), simple_event_summary(sudden))
    write_json(os.path.join(out_dir, "sudden_improvement_summary.json"), simple_event_summary(sudden))

    hypotheses = stage4_hypotheses(trajectory_rows, stage5_rows)
    write_json(os.path.join(out_dir, "hypothesis_evaluation.json"), hypotheses)

    effective_path = os.path.join(out_dir, "actual_effective_config.json")
    if os.path.exists(effective_path):
        with open(effective_path) as f:
            effective = json.load(f)
        effective["stage3_artifact"] = args.stage3_artifact
        effective["artifact_names"] = {"summary": "p167-stage4-summary-<run_id>", "raw": "p167-stage4-raw-logs-<run_id>"}
        write_json(effective_path, effective)

    artifact_summary = S2["artifact_size_summary"](out_dir)
    write_stage4_summary(out_dir, trajectory_rows, stage5_rows, hypotheses, artifact_summary)
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
            "stage5_candidate_rows": len(stage5_rows),
            "score0_candidate_count": int(score0_count),
            "best_score": int(best_score) if best_score is not None and best_score < 10 ** 12 else None,
            "artifact_total_bytes": artifact_summary.get("artifact_total_bytes"),
        }
    )
    write_json(run_config_path, run_config)

    run_id = args.github_run_id or os.environ.get("GITHUB_RUN_ID") or "<run_id>"
    file_sizes = artifact_summary.get("files", {})
    stage4_manifest = {
        "github_run_id": run_id,
        "code_commit": args.code_commit,
        "config_hash": run_config.get("config_hash"),
        "input_manifest_hash": run_config.get("input_manifest_hash"),
        "summary_artifact_name": "p167-stage4-summary-{}".format(run_id),
        "raw_artifact_name": "p167-stage4-raw-logs-{}".format(run_id),
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
            "Stage 4 uses deduped unique candidate hashes from Stage 3 recommendations.",
            "Summary artifact is authoritative for normal audit.",
            "Sampled diagnostics are not full certificates.",
        ],
    }
    write_json(os.path.join(out_dir, "stage4_artifact_manifest.json"), stage4_manifest)
    with open(os.path.join(out_dir, "run_log.md"), "a") as f:
        f.write("\n## Stage 4 postprocess\n\n")
        f.write("- input_stage4_candidates_deduped.jsonl alias written\n")
        f.write("- stage5_candidate_recommendations.jsonl alias written\n")
        f.write("- p167_stage4_candidate_deepening_summary.md written\n")


def build_parser():
    parser = argparse.ArgumentParser(description=SCRIPT_NAME)
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--tuple-registry", default=DEFAULT_TUPLE_REGISTRY)
    parser.add_argument("--stage3-artifact", default=DEFAULT_STAGE3_ARTIFACT)
    parser.add_argument("--stage3-seed-base", type=int, default=760167)
    parser.add_argument("--stage3-replay-steps", type=int, default=1500)
    parser.add_argument("--stage3-replay-sample-swaps", type=int, default=400)
    parser.add_argument("--aggregate-roots", default="")
    parser.add_argument("--benchmark-trap-manifest", default=S2["DEFAULT_BENCHMARK_TRAPS"])
    parser.add_argument("--nearhit-fixture", default=S2["DEFAULT_NEARHIT_FIXTURE"])
    parser.add_argument("--operators", default=",".join(STAGE4_OPERATORS))
    parser.add_argument("--production-candidate-limit", type=int, default=8)
    parser.add_argument("--guarded-repair-limit", type=int, default=4)
    parser.add_argument("--repair-target-limit", type=int, default=4)
    parser.add_argument("--operator-benchmark-limit", type=int, default=2)
    parser.add_argument("--needs-more-diagnostics-limit", type=int, default=1)
    parser.add_argument("--archive-limit", type=int, default=0)
    parser.add_argument("--total-candidate-limit", type=int, default=13)
    parser.add_argument("--production-restarts", type=int, default=12)
    parser.add_argument("--repair-restarts", type=int, default=8)
    parser.add_argument("--benchmark-restarts", type=int, default=4)
    parser.add_argument("--diagnostic-restarts", type=int, default=4)
    parser.add_argument("--baseline-restarts", type=int, default=2)
    parser.add_argument("--survivor-limit", type=int, default=13)
    parser.add_argument("--benchmark-trap-limit", type=int, default=0)
    parser.add_argument("--random-control-limit", type=int, default=0)
    parser.add_argument("--nearhit-control-limit", type=int, default=0)
    parser.add_argument("--restarts", type=int, default=1)
    parser.add_argument("--steps", type=int, default=5000)
    parser.add_argument("--sample-swaps", type=int, default=500)
    parser.add_argument("--diagnostic-sample-count", type=int, default=500)
    parser.add_argument("--diagnostic-type", default="sampled")
    parser.add_argument("--snapshot-attempted-steps", default="0,100,250,500,1000,2500,5000")
    parser.add_argument("--snapshot-accepted-moves", default="0,50,100,250,500,1000")
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
    parser.add_argument("--seed-base", type=int, default=770167)
    parser.add_argument("--stage3-candidate-limit", type=int, default=50)
    parser.add_argument("--stage5-candidate-limit", type=int, default=20)
    parser.add_argument("--github-run-id", default="")
    parser.add_argument("--code-commit", default="")
    parser.add_argument("--run-label", default="")
    parser.add_argument("--stage-name", default="p167_stage4")
    parser.add_argument("--out-dir", default=None)
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    if not args.run_label:
        args.run_label = args.github_run_id or "local-stage4"
    if args.out_dir is None:
        args.out_dir = os.path.join("outputs", "explorations", "{}_p167_stage4_candidate_deepening".format(now_stamp()))
    if not bool(args.high_resolution_logging):
        args.high_resolution_mode = "off"
    if str(args.artifact_mode) == "summary_plus_raw":
        args.upload_raw_logs = True
    args.stage1_artifact = args.stage3_artifact

    S2["load_stage2_candidates"] = load_stage4_candidates
    S2["task_grid"] = stage4_task_grid
    S2["choose_stage2_move"] = choose_stage4_move
    S2["stage3_candidates"] = stage5_candidates
    S2["run"](args)
    postprocess_stage4_outputs(args)
    print("Wrote p167_stage4 postprocessed outputs to {}".format(args.out_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(int(main() or 0))
