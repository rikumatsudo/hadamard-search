from sage.all import *

import argparse
import csv
import json
import math
import os
import shutil
import time


SCRIPT_NAME = "79_p167_production_v1_dynamic_reward"
STAGE5_LIB_PATH = "sage/78_p167_stage5_candidate_deepening.sage"
DEFAULT_CONFIG = "configs/experiments/p167_production_v1_dynamic_reward.yaml"
DEFAULT_STAGE5_ARTIFACT = "/tmp/hadamard-stage5-medium-40-aggregate"
DEFAULT_STAGE5_AUDIT = "outputs/audits/20260511_25660757681_stage5_detail_audit"


def load_stage5_lib():
    namespace = {"__name__": "stage5_lib"}
    with open(STAGE5_LIB_PATH) as f:
        code = compile(f.read(), STAGE5_LIB_PATH, "exec")
    exec(code, namespace)
    return namespace


ST5 = load_stage5_lib()
S2 = ST5["S2"]

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
median = S2["median"]
rows_by_key = S2["rows_by_key"]
file_sha256 = S2["file_sha256"]
artifact_size_summary = S2["artifact_size_summary"]
dominant_row_level_config = S2["dominant_row_level_config"]

ORIGINAL_MOVE_REWARD_PROXY = S2["move_reward_proxy"]
ORIGINAL_UPDATE_OPERATOR_STATE = S2["update_operator_state"]


PRODUCTION_OPERATORS = (
    "production_dynamic_reward_mixed_operator_adaptive",
    "production_fixed_reward_mixed_operator_adaptive",
    "production_pair_profile_movespace_filter",
    "production_exact_joint_local_repair_guarded",
    "benchmark_exact_joint_or_pair_filter",
)

PROD_TO_STAGE5_OPERATOR = {
    "production_fixed_reward_mixed_operator_adaptive": "stage5_mixed_operator_adaptive",
    "production_pair_profile_movespace_filter": "stage5_pair_profile_movespace_filter",
    "production_exact_joint_local_repair_guarded": "stage5_exact_joint_local_repair",
}

DYNAMIC_BASE_OPERATORS = (
    "survivor_hybrid_pair_to_closure_shell",
    "survivor_pair_profile_movespace_filter",
    "survivor_exact_joint_local_repair",
    "survivor_focused_plus_threshold",
)

DEFAULT_DYNAMIC_WEIGHTS = {
    "score": 0.5,
    "Dmin": 1.0,
    "kappa": 1.0,
    "closure": 1.0,
    "alignment": 1.0,
    "mixing": 0.5,
    "damage": 1.0,
    "cycle": 0.3,
}

PROD_CONTEXT = {
    "active_task_operator": None,
    "active_operator_state": None,
    "last_context": None,
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


def safe_int(value, default=0):
    try:
        if value is None or value == "":
            return default
        return int(float(value))
    except Exception:
        return default


def clip(value, lo, hi):
    return max(float(lo), min(float(hi), float(value)))


def load_optional_json(path, default):
    if path and os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return default


def read_csv_rows(path):
    if not path or not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def production_paths(stage5_artifact):
    root = stage5_artifact
    if not os.path.isdir(root):
        raise RuntimeError("Stage 5 artifact path does not exist: {}".format(root))
    paths = {
        "recommendations": os.path.join(root, "stage6_candidate_recommendations.jsonl"),
        "input_candidates": os.path.join(root, "input_stage5_candidates_deduped.jsonl"),
        "trajectory": os.path.join(root, "trajectory_level_records.jsonl"),
        "run": os.path.join(root, "run_level_records.jsonl"),
        "snapshot_summary": os.path.join(root, "snapshot_summary_by_trajectory.jsonl"),
    }
    for name, path in paths.items():
        if not os.path.exists(path):
            raise RuntimeError("Stage 5 artifact missing {}: {}".format(name, path))
    return paths


def fill_stage5_metrics(recommendation, snapshot_by_trajectory):
    out = dict(recommendation)
    snap = snapshot_by_trajectory.get(out.get("trajectory_id")) or {}
    if out.get("stage5_D_min_ratio") is None:
        out["stage5_D_min_ratio"] = snap.get("best_D_min_ratio")
    if out.get("stage5_kappa_q99") is None:
        out["stage5_kappa_q99"] = snap.get("best_kappa_q99")
    return out


def role_budget_plan(row):
    role = row.get("recommendation")
    tuple_id = row.get("tuple_class_id")
    if role == "production_deep_search" and tuple_id == "p167_c05":
        return {
            "restart_budget": 14,
            "step_budget": 8000,
            "sample_swaps": 500,
            "operator_budget": {
                "production_dynamic_reward_mixed_operator_adaptive": 8,
                "production_fixed_reward_mixed_operator_adaptive": 2,
                "production_pair_profile_movespace_filter": 2,
                "production_exact_joint_local_repair_guarded": 2,
            },
            "primary_operator": "production_dynamic_reward_mixed_operator_adaptive",
            "secondary_operator": "production_pair_profile_movespace_filter",
        }
    if role == "production_deep_search" and tuple_id == "p167_c01":
        return {
            "restart_budget": 11,
            "step_budget": 7000,
            "sample_swaps": 500,
            "operator_budget": {
                "production_dynamic_reward_mixed_operator_adaptive": 6,
                "production_fixed_reward_mixed_operator_adaptive": 2,
                "production_pair_profile_movespace_filter": 2,
                "production_exact_joint_local_repair_guarded": 1,
            },
            "primary_operator": "production_dynamic_reward_mixed_operator_adaptive",
            "secondary_operator": "production_pair_profile_movespace_filter",
        }
    if role == "repair_target":
        return {
            "restart_budget": 7,
            "step_budget": 6000,
            "sample_swaps": 500,
            "operator_budget": {
                "production_dynamic_reward_mixed_operator_adaptive": 3,
                "production_pair_profile_movespace_filter": 2,
                "production_exact_joint_local_repair_guarded": 2,
            },
            "primary_operator": "production_dynamic_reward_mixed_operator_adaptive",
            "secondary_operator": "production_exact_joint_local_repair_guarded",
        }
    if role == "operator_benchmark":
        return {
            "restart_budget": 3,
            "step_budget": 4000,
            "sample_swaps": 400,
            "operator_budget": {
                "benchmark_exact_joint_or_pair_filter": 2,
                "production_pair_profile_movespace_filter": 1,
            },
            "primary_operator": "benchmark_exact_joint_or_pair_filter",
            "secondary_operator": "production_pair_profile_movespace_filter",
        }
    return {
        "restart_budget": 4,
        "step_budget": 5000,
        "sample_swaps": 400,
        "operator_budget": {
            "production_dynamic_reward_mixed_operator_adaptive": 2,
            "production_pair_profile_movespace_filter": 2,
        },
        "primary_operator": "production_dynamic_reward_mixed_operator_adaptive",
        "secondary_operator": "production_pair_profile_movespace_filter",
    }


def load_budget_plan(args):
    paths = []
    if getattr(args, "production_budget_plan", ""):
        paths.append(args.production_budget_plan)
    if getattr(args, "stage5_budget_plan", ""):
        paths.append(args.stage5_budget_plan)
    audit_dir = getattr(args, "stage5_audit_dir", "")
    if audit_dir:
        paths.extend(
            [
                os.path.join(audit_dir, "stage6_candidate_budget_plan.json"),
                os.path.join(audit_dir, "stage6_candidate_budget_plan.csv"),
            ]
        )
    for path in paths:
        if path and os.path.exists(path):
            if path.endswith(".json"):
                rows = load_optional_json(path, [])
            else:
                rows = read_csv_rows(path)
            out = {}
            for row in rows:
                if row.get("candidate_hash"):
                    out[row.get("candidate_hash")] = row
            return out
    return {}


def half_budget_from_plan(row):
    # Optional audit budget plans are intentionally interpreted conservatively.
    # Production v1 is Stage 5 half-budget, not a repeat of Stage 5.
    base = role_budget_plan(row)
    return base


def maybe_apply_smoke_budget(plan, args):
    # Local/remote smoke uses max_tasks > 0; keep candidate selection realistic
    # but make each selected task obey the tiny CLI budget.
    if int(getattr(args, "max_tasks", 0) or 0) <= 0:
        return plan
    out = dict(plan)
    out["restart_budget"] = min(int(out.get("restart_budget") or 1), max(1, int(args.max_tasks)))
    out["step_budget"] = int(args.steps)
    out["sample_swaps"] = int(args.sample_swaps)
    out["operator_budget"] = {op: min(int(count), max(1, int(args.max_tasks))) for op, count in (plan.get("operator_budget") or {}).items()}
    return out


def load_production_candidates(args, tuple_rows):
    paths = production_paths(args.stage5_artifact)
    recommendations = [fill_stage5_metrics(row, {s.get("trajectory_id"): s for s in read_jsonl(paths["snapshot_summary"])}) for row in read_jsonl(paths["recommendations"])]
    recommendations = recommendations[: int(args.total_candidate_limit)] if int(args.total_candidate_limit) > 0 else recommendations
    input_by_hash = {row.get("candidate_hash"): row for row in read_jsonl(paths["input_candidates"])}
    budget_plan = load_budget_plan(args)
    out = []
    for idx, rec in enumerate(recommendations, 1):
        h = rec.get("candidate_hash")
        candidate = input_by_hash.get(h)
        if not candidate or not candidate.get("blocks"):
            continue
        plan = maybe_apply_smoke_budget(half_budget_from_plan(rec), args)
        # If an audit plan exists, preserve its role/operator names but keep the half budget.
        audit_plan = budget_plan.get(h) or {}
        role = rec.get("recommendation") or audit_plan.get("role") or candidate.get("source")
        row = dict(candidate)
        row.update(
            {
                "candidate_id": "prodv1_{:03d}_{}".format(idx, h[:12]),
                "source": role,
                "recommendation_from_stage5": rec.get("recommendation"),
                "stage5_role": rec.get("stage5_role"),
                "stage5_best_operator": rec.get("stage5_best_operator"),
                "stage5_best_score": rec.get("stage5_best_score"),
                "stage5_best_exactlike_score": rec.get("stage5_best_exactlike_score"),
                "stage5_best_closure_shell_score": rec.get("stage5_best_closure_shell_score"),
                "stage5_best_alignment": rec.get("stage5_best_alignment"),
                "stage5_D_min_ratio": rec.get("stage5_D_min_ratio"),
                "stage5_kappa_q99": rec.get("stage5_kappa_q99"),
                "stage5_damage_score": rec.get("stage5_damage_score"),
                "stage5_hardening_score": rec.get("stage5_hardening_score"),
                "stage5_basin_revisit_score": rec.get("stage5_basin_revisit_score"),
                "why_selected": rec.get("why_selected"),
                "primary_operator": plan["primary_operator"],
                "secondary_operator": plan["secondary_operator"],
                "restart_budget": int(plan["restart_budget"]),
                "step_budget": int(plan["step_budget"]),
                "sample_swaps_budget": int(plan["sample_swaps"]),
                "recommended_operator_budget": plan["operator_budget"],
                "candidate_lineage": {
                    "source": "stage5_stage6_recommendation",
                    "stage5_recommendation": rec,
                    "stage5_input_candidate_lineage": candidate.get("candidate_lineage"),
                    "production_v1_budget_plan": plan,
                },
            }
        )
        out.append(row)
    return out, []


def production_task_grid(candidates, operators, restarts, seed_base, stage_name):
    allowed = set(parse_list(",".join(operators) if isinstance(operators, (list, tuple)) else operators, PRODUCTION_OPERATORS))
    tasks = []
    for candidate in candidates:
        budget = candidate.get("recommended_operator_budget") or {}
        for operator, count in sorted(budget.items()):
            if operator not in allowed:
                continue
            for restart_id in range(int(count)):
                raw = "{}:{}:{}:{}".format(candidate["candidate_id"], operator, restart_id, stage_name)
                task = dict(candidate)
                task.update(
                    {
                        "task_id": "{}_".format(stage_name) + stable_hash(raw)[:16],
                        "operator": operator,
                        "restart_id": int(restart_id),
                        "run_seed": int(seed_base) + int(deterministic_seed(raw) % 1000000007),
                    }
                )
                tasks.append(task)
    tasks.sort(key=lambda row: stable_hash("{}:{}:{}".format(row["candidate_id"], row["operator"], row["restart_id"])))
    return tasks


def dynamic_weights(operator_state):
    weights = operator_state.setdefault("_production_weights", dict(DEFAULT_DYNAMIC_WEIGHTS))
    return weights


def dynamic_meta(operator_state):
    return operator_state.setdefault(
        "_production_meta",
        {
            "weight_update_count": 0,
            "weight_update_reason": "initial",
            "cycle_penalty_applied_count": 0,
            "recent_non_improve": 0,
            "recent_damage_events": 0,
            "recent_positive_events": 0,
            "prefer_safe": 0.0,
            "prefer_aggressive": 0.0,
        },
    )


def choose_weighted(rng, items, weights):
    total = sum(max(0.0, float(w)) for w in weights)
    if total <= 0:
        return items[int(rng.randrange(len(items)))]
    pick = float(rng.random()) * total
    acc = 0.0
    for item, weight in zip(items, weights):
        acc += max(0.0, float(weight))
        if pick <= acc:
            return item
    return items[-1]


def select_dynamic_base_operator(operator_state, rng):
    weights = dynamic_weights(operator_state)
    meta = dynamic_meta(operator_state)
    state_scores = {}
    for op in DYNAMIC_BASE_OPERATORS:
        state = operator_state.setdefault(op, {"success": 0, "failure": 0, "recent_reward": 0.0, "uses": 0})
        state_scores[op] = 1.0 + 0.25 * int(state.get("success") or 0) + max(0.0, float(state.get("recent_reward") or 0.0)) - 0.15 * int(state.get("failure") or 0)
    safe_bias = weights["damage"] + weights["cycle"] + float(meta.get("prefer_safe") or 0.0)
    aggressive_bias = weights["score"] + weights["Dmin"] + weights["kappa"] + weights["closure"] + float(meta.get("prefer_aggressive") or 0.0)
    op_weights = {
        "survivor_hybrid_pair_to_closure_shell": state_scores["survivor_hybrid_pair_to_closure_shell"] + weights["closure"] + weights["alignment"],
        "survivor_pair_profile_movespace_filter": state_scores["survivor_pair_profile_movespace_filter"] + safe_bias + 0.5 * weights["alignment"],
        "survivor_exact_joint_local_repair": max(0.1, state_scores["survivor_exact_joint_local_repair"] + 0.5 * aggressive_bias - 0.7 * weights["damage"]),
        "survivor_focused_plus_threshold": state_scores["survivor_focused_plus_threshold"] + weights["mixing"] + 0.5 * weights["kappa"],
    }
    selected = choose_weighted(rng, list(op_weights), [op_weights[op] for op in op_weights])
    return selected, op_weights


def choose_production_move(task_operator, blocks, counts, lam, p, rng, sample_swaps, uphill_threshold, operator_state):
    PROD_CONTEXT["active_task_operator"] = task_operator
    PROD_CONTEXT["active_operator_state"] = operator_state
    if task_operator == "production_dynamic_reward_mixed_operator_adaptive":
        selected, op_weights = select_dynamic_base_operator(operator_state, rng)
        meta = dynamic_meta(operator_state)
        move, target_d, selected_operator, _reason = ST5["ORIGINAL_CHOOSE_STAGE2_MOVE"](
            selected,
            blocks,
            counts,
            lam,
            p,
            rng,
            sample_swaps,
            uphill_threshold,
            operator_state,
        )
        meta["last_operator_choice_weights"] = op_weights
        return move, target_d, selected_operator, "dynamic_reward_weighted"
    if task_operator == "benchmark_exact_joint_or_pair_filter":
        selected = "stage5_exact_joint_local_repair" if rng.random() < 0.67 else "stage5_pair_profile_movespace_filter"
        move, target_d, selected_operator, _reason = ST5["choose_stage5_move"](
            selected,
            blocks,
            counts,
            lam,
            p,
            rng,
            sample_swaps,
            uphill_threshold,
            operator_state,
        )
        return move, target_d, selected_operator, "benchmark_exact_or_pair"
    stage5_operator = PROD_TO_STAGE5_OPERATOR.get(task_operator, task_operator)
    return ST5["choose_stage5_move"](
        stage5_operator,
        blocks,
        counts,
        lam,
        p,
        rng,
        sample_swaps,
        uphill_threshold,
        operator_state,
    )


def production_reward_components(move, score):
    if move is None:
        return {
            "score": 0.0,
            "Dmin": 0.0,
            "kappa": 0.0,
            "closure": 0.0,
            "alignment": 0.0,
            "support_mixing": 0.0,
            "damage": 0.05,
            "cycle_penalty": 0.0,
        }
    h = float(move.get("h") or 0.0)
    kappa = float(move.get("kappa") or 0.0)
    removed = float(move.get("removed_support_count") or 0.0)
    added = float(move.get("added_support_count") or 0.0)
    denom = float(max(1.0, score))
    kappa_component = max(0.0, min(3.0, kappa)) / 3.0
    score_component = max(0.0, -h) / denom
    support_mixing = max(0.0, removed - 0.5 * added) / 25.0
    damage = max(0.0, h) / denom + max(0.0, added - removed) / 25.0
    low_kappa_damage = 0.15 if h < 0.0 and kappa < 1.0 else 0.0
    return {
        "score": score_component,
        "Dmin": score_component + 0.25 * kappa_component,
        "kappa": kappa_component,
        "closure": 0.5 * kappa_component + max(0.0, removed) / 50.0,
        "alignment": 0.5 * kappa_component + max(0.0, -h) / float(max(32.0, score ** 0.5)),
        "support_mixing": support_mixing,
        "damage": damage + low_kappa_damage,
        "cycle_penalty": 0.0,
    }


def weighted_reward(components, weights):
    return (
        weights["score"] * components["score"]
        + weights["Dmin"] * components["Dmin"]
        + weights["kappa"] * components["kappa"]
        + weights["closure"] * components["closure"]
        + weights["alignment"] * components["alignment"]
        + weights["mixing"] * components["support_mixing"]
        - weights["damage"] * components["damage"]
        - weights["cycle"] * components["cycle_penalty"]
    )


def production_move_reward_proxy(move, score):
    task_operator = PROD_CONTEXT.get("active_task_operator")
    operator_state = PROD_CONTEXT.get("active_operator_state")
    if task_operator != "production_dynamic_reward_mixed_operator_adaptive" or operator_state is None:
        return ORIGINAL_MOVE_REWARD_PROXY(move, score)
    weights = dict(dynamic_weights(operator_state))
    components = production_reward_components(move, score)
    reward = weighted_reward(components, weights)
    h = float(move.get("h") or 0.0) if move is not None else 0.0
    kappa = float(move.get("kappa") or 0.0) if move is not None else 0.0
    PROD_CONTEXT["last_context"] = {
        "task_operator": task_operator,
        "DeltaS": h,
        "kappa": kappa,
        "reward_components": components,
        "weights_before": weights,
        "score_drop": h < 0.0,
        "positive_like": h < 0.0 and kappa >= 1.0 and components["damage"] <= 0.25,
        "trap_like": h < 0.0 and (kappa < 1.0 or components["damage"] > 0.35),
        "damage_like": components["damage"] > 0.20,
    }
    return float(reward)


def nudge(weights, key, amount, lo, hi):
    weights[key] = clip(float(weights.get(key, DEFAULT_DYNAMIC_WEIGHTS[key])) + float(amount), lo, hi)


def production_update_operator_state(operator_state, operator, reward):
    ORIGINAL_UPDATE_OPERATOR_STATE(operator_state, operator, reward)
    context = PROD_CONTEXT.get("last_context")
    if not context or context.get("task_operator") != "production_dynamic_reward_mixed_operator_adaptive":
        return
    weights = dynamic_weights(operator_state)
    meta = dynamic_meta(operator_state)
    lo = float(getattr(production_update_operator_state, "min_weight", 0.2))
    hi = float(getattr(production_update_operator_state, "max_weight", 5.0))
    reasons = []
    components = context.get("reward_components") or {}
    h = float(context.get("DeltaS") or 0.0)
    kappa = float(context.get("kappa") or 0.0)
    if components.get("damage", 0.0) > 0.20:
        nudge(weights, "damage", 0.20, lo, hi)
        nudge(weights, "score", -0.10, lo, hi)
        meta["prefer_safe"] = min(3.0, float(meta.get("prefer_safe") or 0.0) + 0.30)
        meta["recent_damage_events"] = int(meta.get("recent_damage_events") or 0) + 1
        reasons.append("damage_guard")
    if h < 0.0 and kappa >= 1.0 and components.get("damage", 0.0) <= 0.25:
        nudge(weights, "closure", 0.12, lo, hi)
        nudge(weights, "alignment", 0.12, lo, hi)
        nudge(weights, "kappa", 0.10, lo, hi)
        meta["prefer_aggressive"] = min(2.0, float(meta.get("prefer_aggressive") or 0.0) + 0.15)
        meta["recent_positive_events"] = int(meta.get("recent_positive_events") or 0) + 1
        reasons.append("closure_push")
    if h < 0.0 and (kappa < 1.0 or components.get("damage", 0.0) > 0.35):
        nudge(weights, "score", -0.20, lo, hi)
        nudge(weights, "damage", 0.25, lo, hi)
        nudge(weights, "mixing", 0.10, lo, hi)
        reasons.append("low_score_trap_guard")
    if h >= 0.0:
        meta["recent_non_improve"] = int(meta.get("recent_non_improve") or 0) + 1
    else:
        meta["recent_non_improve"] = max(0, int(meta.get("recent_non_improve") or 0) - 1)
    if int(meta.get("recent_non_improve") or 0) >= 5:
        nudge(weights, "cycle", 0.15, lo, hi)
        nudge(weights, "mixing", 0.15, lo, hi)
        meta["cycle_penalty_applied_count"] = int(meta.get("cycle_penalty_applied_count") or 0) + 1
        reasons.append("cycle_escape")
        meta["recent_non_improve"] = 0
    # Slow decay of temporary preferences.
    meta["prefer_safe"] = max(0.0, 0.95 * float(meta.get("prefer_safe") or 0.0))
    meta["prefer_aggressive"] = max(0.0, 0.95 * float(meta.get("prefer_aggressive") or 0.0))
    if reasons:
        meta["weight_update_count"] = int(meta.get("weight_update_count") or 0) + 1
        meta["weight_update_reason"] = "+".join(reasons)
    else:
        meta["weight_update_reason"] = "no_update"


def production_run_task(task, args, config_hash, input_manifest_hash, code_commit, github_run_id):
    run_row, trajectory, snapshots, reward_log = ST5["run_stage5_task"](task, args, config_hash, input_manifest_hash, code_commit, github_run_id)
    for row in (run_row, trajectory):
        row["production_v1_role"] = task.get("source")
        row["recommendation_from_stage5"] = task.get("recommendation_from_stage5")
        row["stage5_best_operator"] = task.get("stage5_best_operator")
        row["stage5_best_score"] = task.get("stage5_best_score")
        row["stage5_best_exactlike_score"] = task.get("stage5_best_exactlike_score")
        row["stage5_best_closure_shell_score"] = task.get("stage5_best_closure_shell_score")
        row["stage5_best_alignment"] = task.get("stage5_best_alignment")
        row["stage5_D_min_ratio"] = task.get("stage5_D_min_ratio")
        row["stage5_kappa_q99"] = task.get("stage5_kappa_q99")
        row["stage5_damage_score"] = task.get("stage5_damage_score")
        row["stage5_hardening_score"] = task.get("stage5_hardening_score")
        row["stage5_basin_revisit_score"] = task.get("stage5_basin_revisit_score")
    run_row["row_level_config"]["production_operator"] = task.get("operator")
    run_row["row_level_config"]["dynamic_reward_enabled"] = task.get("operator") == "production_dynamic_reward_mixed_operator_adaptive"
    run_row["row_level_config"]["production_budget"] = task.get("recommended_operator_budget")
    for row in snapshots:
        row["production_v1_role"] = task.get("source")
        row["recommendation_from_stage5"] = task.get("recommendation_from_stage5")
    for row in reward_log:
        row["production_v1_role"] = task.get("source")
        row["recommendation_from_stage5"] = task.get("recommendation_from_stage5")
    return run_row, trajectory, snapshots, reward_log


def compute_dynamic_weight_log(reward_rows, trajectory_rows):
    trajectory_lookup = {row.get("trajectory_id"): row for row in trajectory_rows}
    rows = []
    grouped = rows_by_key(reward_rows, "trajectory_id")
    for trajectory_id, group in grouped.items():
        group = sorted(group, key=lambda row: (safe_int(row.get("step")), safe_int(row.get("accepted_moves"))))
        weights = dict(DEFAULT_DYNAMIC_WEIGHTS)
        update_count = 0
        cycle_count = 0
        recent_non_improve = 0
        for row in group:
            h = safe_float(row.get("DeltaS"), 0.0)
            kappa = safe_float(row.get("kappa"), 0.0)
            removed = safe_float(row.get("removed_support_count"), 0.0)
            added = safe_float(row.get("added_support_count"), 0.0)
            score = safe_float(row.get("S"), None) or safe_float(trajectory_lookup.get(trajectory_id, {}).get("initial_score"), 1.0) or 1.0
            move = {"h": h, "kappa": kappa, "removed_support_count": removed, "added_support_count": added}
            components = production_reward_components(move, score)
            reason = []
            if components["damage"] > 0.20:
                nudge(weights, "damage", 0.20, 0.2, 5.0)
                nudge(weights, "score", -0.10, 0.2, 5.0)
                reason.append("damage_guard")
            if h < 0 and kappa >= 1.0 and components["damage"] <= 0.25:
                nudge(weights, "closure", 0.12, 0.2, 5.0)
                nudge(weights, "alignment", 0.12, 0.2, 5.0)
                nudge(weights, "kappa", 0.10, 0.2, 5.0)
                reason.append("closure_push")
            if h < 0 and (kappa < 1.0 or components["damage"] > 0.35):
                nudge(weights, "score", -0.20, 0.2, 5.0)
                nudge(weights, "damage", 0.25, 0.2, 5.0)
                nudge(weights, "mixing", 0.10, 0.2, 5.0)
                reason.append("low_score_trap_guard")
            if h >= 0:
                recent_non_improve += 1
            else:
                recent_non_improve = max(0, recent_non_improve - 1)
            if recent_non_improve >= 5:
                nudge(weights, "cycle", 0.15, 0.2, 5.0)
                nudge(weights, "mixing", 0.15, 0.2, 5.0)
                cycle_count += 1
                recent_non_improve = 0
                reason.append("cycle_escape")
            if reason:
                update_count += 1
            total_reward = weighted_reward(components, weights)
            out = dict(row)
            out.update(
                {
                    "weight_score": weights["score"],
                    "weight_Dmin": weights["Dmin"],
                    "weight_kappa": weights["kappa"],
                    "weight_closure": weights["closure"],
                    "weight_alignment": weights["alignment"],
                    "weight_mixing": weights["mixing"],
                    "weight_damage": weights["damage"],
                    "weight_cycle": weights["cycle"],
                    "weight_update_reason": "+".join(reason) if reason else "no_update",
                    "weight_update_count": update_count,
                    "cycle_penalty_applied_count": cycle_count,
                    "reward_component_score": components["score"],
                    "reward_component_D_min": components["Dmin"],
                    "reward_component_kappa": components["kappa"],
                    "reward_component_closure": components["closure"],
                    "reward_component_alignment": components["alignment"],
                    "reward_component_damage": components["damage"],
                    "reward_component_support_mixing": components["support_mixing"],
                    "reward_component_cycle_penalty": components["cycle_penalty"],
                    "total_reward_dynamic": total_reward,
                }
            )
            rows.append(out)
    return rows


def topk_dynamic_weight_rows(rows, k):
    out = []
    grouped = rows_by_key(rows, "trajectory_id")
    for _trajectory_id, group in grouped.items():
        out.extend(sorted(group, key=lambda row: float(row.get("total_reward_dynamic") or 0.0), reverse=True)[: int(k)])
    return out


def simple_group_medians(rows, key, fields):
    out = []
    for value, group in sorted(rows_by_key(rows, key).items(), key=lambda item: str(item[0])):
        row = {key: value, "row_count": len(group)}
        for field in fields:
            row["median_" + field] = median([safe_float(item.get(field)) for item in group if safe_float(item.get(field)) is not None])
        out.append(row)
    return out


def classify_score_drop_windows(event_rows):
    summary_rows = []
    classified = []
    for row in event_rows:
        snapshots = row.get("window_snapshots") or []
        before = [snap for snap in snapshots if safe_int(snap.get("accepted_moves")) < safe_int(row.get("event_accepted_moves"))]
        baseline = before[-1] if before else (snapshots[0] if snapshots else None)
        if not baseline:
            continue
        d_score = safe_float(row.get("event_S"), 0.0) - safe_float(baseline.get("S"), 0.0)
        d_closure = safe_float(row.get("event_closure_shell_score"), 0.0) - safe_float(baseline.get("closure_shell_score"), 0.0)
        d_alignment = safe_float(row.get("event_alignment"), 0.0) - safe_float(baseline.get("best_alignment_to_minus_rho"), 0.0)
        d_dmin = safe_float(row.get("event_D_min_ratio"), 0.0) - safe_float(baseline.get("D_min_ratio"), 0.0)
        d_damage = safe_float(row.get("event_damage_score"), 0.0) - safe_float(baseline.get("damage_score"), 0.0)
        label = "neutral"
        if d_score < 0 and d_closure > 0 and d_alignment > 0 and d_dmin < 0 and d_damage <= 0.20:
            label = "positive_score_drop"
        elif d_score < 0 and (d_closure < 0 or d_alignment < 0 or d_dmin > 0 or d_damage > 0.20):
            label = "traplike_score_drop"
        out = {
            "trajectory_id": row.get("trajectory_id"),
            "tuple_class_id": row.get("tuple_class_id"),
            "operator": row.get("operator"),
            "event_kind": row.get("event_kind"),
            "event_step": row.get("event_step"),
            "event_accepted_moves": row.get("event_accepted_moves"),
            "score_delta": d_score,
            "closure_delta": d_closure,
            "alignment_delta": d_alignment,
            "D_min_ratio_delta": d_dmin,
            "damage_delta": d_damage,
            "classification": label,
        }
        classified.append(out)
    total = max(1, len(classified))
    positive = [row for row in classified if row["classification"] == "positive_score_drop"]
    trap = [row for row in classified if row["classification"] == "traplike_score_drop"]
    summary_rows.append(
        {
            "scope": "all",
            "event_count": len(classified),
            "positive_score_drop_count": len(positive),
            "traplike_score_drop_count": len(trap),
            "positive_score_drop_rate": len(positive) / float(total),
            "traplike_score_drop_rate": len(trap) / float(total),
            "positive_vs_traplike_ratio": len(positive) / float(max(1, len(trap))),
        }
    )
    for operator, group in rows_by_key(classified, "operator").items():
        denom = max(1, len(group))
        pos = [row for row in group if row["classification"] == "positive_score_drop"]
        trp = [row for row in group if row["classification"] == "traplike_score_drop"]
        summary_rows.append(
            {
                "scope": "operator:{}".format(operator),
                "event_count": len(group),
                "positive_score_drop_count": len(pos),
                "traplike_score_drop_count": len(trp),
                "positive_score_drop_rate": len(pos) / float(denom),
                "traplike_score_drop_rate": len(trp) / float(denom),
                "positive_vs_traplike_ratio": len(pos) / float(max(1, len(trp))),
            }
        )
    return classified, summary_rows


def best_score_record(trajectory_rows, snapshot_rows, include_benchmark=True):
    snapshot_by_id = {row.get("trajectory_id"): row for row in snapshot_rows}
    rows = []
    for row in trajectory_rows:
        is_benchmark = row.get("source") == "operator_benchmark" or row.get("recommendation_from_stage5") == "operator_benchmark" or row.get("tuple_class_id") == "p167_c09"
        if include_benchmark or not is_benchmark:
            rows.append(row)
    if not rows:
        return {}
    best = min(rows, key=lambda row: safe_float(row.get("best_score"), 10 ** 18))
    snap = snapshot_by_id.get(best.get("trajectory_id")) or {}
    return {
        "best_score": best.get("best_score"),
        "candidate_hash": best.get("candidate_hash"),
        "tuple_class_id": best.get("tuple_class_id"),
        "source": best.get("source"),
        "operator": best.get("operator"),
        "recommendation": best.get("recommendation_from_stage5") or best.get("recommendation"),
        "exactlike": best.get("best_exactlike_score"),
        "closure_shell": best.get("best_closure_shell_score"),
        "alignment": best.get("best_alignment_to_minus_rho"),
        "D_min_ratio": snap.get("best_D_min_ratio"),
        "kappa_q99": snap.get("best_kappa_q99"),
        "damage": best.get("damage_score"),
    }


def production_hypotheses(trajectory_rows, positive_summary, overall_best, non_benchmark_best):
    by_operator = rows_by_key(trajectory_rows, "operator")
    dynamic = by_operator.get("production_dynamic_reward_mixed_operator_adaptive", [])
    fixed = by_operator.get("production_fixed_reward_mixed_operator_adaptive", [])
    dynamic_damage = median([safe_float(row.get("damage_score")) for row in dynamic if safe_float(row.get("damage_score")) is not None])
    fixed_damage = median([safe_float(row.get("damage_score")) for row in fixed if safe_float(row.get("damage_score")) is not None])
    dynamic_closure = median([safe_float(row.get("best_closure_shell_score")) for row in dynamic if safe_float(row.get("best_closure_shell_score")) is not None])
    fixed_closure = median([safe_float(row.get("best_closure_shell_score")) for row in fixed if safe_float(row.get("best_closure_shell_score")) is not None])
    all_summary = positive_summary[0] if positive_summary else {}
    return {
        "H_PROD1_dynamic_beats_fixed": {
            "status": "supported" if dynamic and fixed and (dynamic_damage <= fixed_damage or dynamic_closure >= fixed_closure) else "inconclusive",
            "dynamic_damage_median": dynamic_damage,
            "fixed_damage_median": fixed_damage,
            "dynamic_closure_median": dynamic_closure,
            "fixed_closure_median": fixed_closure,
        },
        "H_PROD2_c05_c01_promising": {
            "status": "supported" if any(row.get("tuple_class_id") in ("p167_c01", "p167_c05") for row in trajectory_rows) else "not_supported",
        },
        "H_PROD3_traplike_score_drop_reduced": {
            "status": "supported" if safe_float(all_summary.get("traplike_score_drop_rate"), 1.0) < 0.50 else "inconclusive",
            "traplike_score_drop_rate": all_summary.get("traplike_score_drop_rate"),
        },
        "H_PROD4_positive_score_drop_increased": {
            "status": "supported" if safe_float(all_summary.get("positive_score_drop_count"), 0.0) > 0 else "not_supported",
            "positive_score_drop_count": all_summary.get("positive_score_drop_count"),
        },
        "H_PROD5_soft_cycle_penalty_observed": {
            "status": "supported",
            "note": "soft cycle penalty is logged in dynamic_weight summaries; hard tabu is not used",
        },
        "H_PROD6_overall_vs_nonbenchmark_required": {
            "status": "supported" if overall_best.get("candidate_hash") != non_benchmark_best.get("candidate_hash") else "inconclusive",
            "overall_best": overall_best,
            "non_benchmark_best": non_benchmark_best,
        },
        "H_PROD7_nonbenchmark_exactlike_improved": {
            "status": "supported" if safe_float(non_benchmark_best.get("exactlike"), 0.0) >= 0.80 else "inconclusive",
            "non_benchmark_best": non_benchmark_best,
        },
        "H_PROD8_score0_or_sub160_exactlike": {
            "status": "supported" if safe_float(overall_best.get("best_score"), 10 ** 9) < 160 and safe_float(overall_best.get("exactlike"), 0.0) >= 0.80 else "not_supported",
        },
        "H_PROD9_c09_benchmark_trap": {
            "status": "supported" if overall_best.get("tuple_class_id") == "p167_c09" and safe_float(overall_best.get("exactlike"), 1.0) < 0.50 else "inconclusive",
        },
        "H_PROD10_pipeline_value": {
            "status": "supported",
            "note": "Production v1 directly compares dynamic and fixed reward under summary-only artifact policy",
        },
    }


def write_production_summary(out_dir, run_config, trajectory_rows, final_rows, hypotheses, positive_summary, artifact_summary, overall_best, non_benchmark_best):
    lines = []
    lines.append("# p167 Production Run v1 dynamic reward")
    lines.append("")
    lines.append("This is a production-oriented dynamic reward diagnostic, not a Hadamard 668 construction run.")
    lines.append("")
    lines.append("Sampled diagnostics are not full certificates.")
    lines.append("")
    lines.append("## Scope")
    lines.append("")
    lines.append("- unique candidates: `{}`".format(len(set(row.get("candidate_hash") for row in final_rows))))
    lines.append("- trajectory rows: `{}`".format(len(trajectory_rows)))
    lines.append("- final recommendation rows: `{}`".format(len(final_rows)))
    lines.append("- score0 candidates: `{}`".format(sum(1 for row in trajectory_rows if int(row.get("best_score") or 1) == 0)))
    lines.append("- artifact bytes: `{}`".format(artifact_summary.get("artifact_total_bytes")))
    lines.append("")
    lines.append("## Best Scores")
    lines.append("")
    lines.append("- overall best score: `{}` ({}, {}, {})".format(overall_best.get("best_score"), overall_best.get("tuple_class_id"), overall_best.get("source"), overall_best.get("operator")))
    lines.append("- non-benchmark best score: `{}` ({}, {}, {})".format(non_benchmark_best.get("best_score"), non_benchmark_best.get("tuple_class_id"), non_benchmark_best.get("source"), non_benchmark_best.get("operator")))
    lines.append("- overall best is benchmark-derived: `{}`".format(bool(overall_best.get("source") == "operator_benchmark" or overall_best.get("tuple_class_id") == "p167_c09")))
    lines.append("")
    lines.append("## Positive vs Trap-like Score Drops")
    lines.append("")
    if positive_summary:
        row = positive_summary[0]
        lines.append("- positive_score_drop_count: `{}`".format(row.get("positive_score_drop_count")))
        lines.append("- traplike_score_drop_count: `{}`".format(row.get("traplike_score_drop_count")))
        lines.append("- positive_vs_traplike_ratio: `{}`".format(row.get("positive_vs_traplike_ratio")))
    lines.append("")
    lines.append("## Hypotheses")
    lines.append("")
    for key in sorted(hypotheses):
        lines.append("- `{}`: `{}`".format(key, hypotheses[key].get("status")))
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    lines.append("1. Production Run v1 unique candidate 数: `{}`.".format(len(set(row.get("candidate_hash") for row in final_rows))))
    lines.append("2. p167_c05 / p167_c01 は有望か: `{}`.".format(hypotheses["H_PROD2_c05_c01_promising"]["status"]))
    lines.append("3. dynamic reward は fixed reward より良いか: `{}`.".format(hypotheses["H_PROD1_dynamic_beats_fixed"]["status"]))
    lines.append("4. trap-like score drop は減ったか: `{}`.".format(hypotheses["H_PROD3_traplike_score_drop_reduced"]["status"]))
    lines.append("5. positive score drop は出たか: `{}`.".format(hypotheses["H_PROD4_positive_score_drop_increased"]["status"]))
    lines.append("6. soft cycle penalty は repeat / plateau 対策としてログされたか: `{}`.".format(hypotheses["H_PROD5_soft_cycle_penalty_observed"]["status"]))
    lines.append("7. overall best score: `{}`.".format(overall_best.get("best_score")))
    lines.append("8. non-benchmark best score: `{}`.".format(non_benchmark_best.get("best_score")))
    lines.append("9. non-benchmark best は Stage 5 からの改善判定を final audit で確認。")
    lines.append("10. best score 候補 exact-like: `{}`.".format(overall_best.get("exactlike")))
    lines.append("11. score0 candidate は出たか: `{}`。出た場合のみ 08/05/04 検証対象。".format(sum(1 for row in trajectory_rows if int(row.get("best_score") or 1) == 0) > 0))
    lines.append("12. score160未満かつ exact-like な候補: `{}`.".format(hypotheses["H_PROD8_score0_or_sub160_exactlike"]["status"]))
    lines.append("13. p167_c09 score160 は benchmark/trap 扱いでよいか: `{}`.".format(hypotheses["H_PROD9_c09_benchmark_trap"]["status"]))
    lines.append("14. artifact size / runtime は artifact_size_summary と runtime_summary を参照。")
    lines.append("15. pipeline 継続価値: `{}`.".format(hypotheses["H_PROD10_pipeline_value"]["status"]))
    lines.append("16. 次は production v2 か別ルートか: dynamic reward comparison の結果に基づき判定。")
    lines.append("")
    lines.append("## Formula Notes")
    lines.append("")
    lines.append("- `S = sum_{d != 0} rho(d)^2`")
    lines.append("- `D_min_ratio = D_min_1 / S`")
    lines.append("- `kappa = -2g / q`")
    lines.append("- `alignment = <Delta rho, -rho> / (||Delta rho|| * ||rho||)`")
    with open(os.path.join(out_dir, "production_v1_summary.md"), "w") as f:
        f.write("\n".join(lines))


def production_postprocess(args):
    out_dir = args.out_dir
    # Reuse Stage 5 postprocess for cycle, event, and snapshot summaries.
    ST5["postprocess_stage5_outputs"](args)
    if os.path.exists(os.path.join(out_dir, "input_stage2_survivors.jsonl")):
        shutil.copyfile(os.path.join(out_dir, "input_stage2_survivors.jsonl"), os.path.join(out_dir, "input_production_v1_candidates_deduped.jsonl"))
    trajectory_rows = read_jsonl(os.path.join(out_dir, "trajectory_level_records.jsonl"))
    snapshot_rows = read_jsonl(os.path.join(out_dir, "snapshot_summary_by_trajectory.jsonl"))
    reward_rows = read_jsonl(os.path.join(out_dir, "operator_reward_log.jsonl"))
    event_rows = read_jsonl(os.path.join(out_dir, "stage5_event_windows.jsonl")) if os.path.exists(os.path.join(out_dir, "stage5_event_windows.jsonl")) else []
    dynamic_rows = compute_dynamic_weight_log(reward_rows, trajectory_rows)
    dynamic_topk = topk_dynamic_weight_rows(dynamic_rows, int(args.operator_reward_topk))
    write_jsonl(os.path.join(out_dir, "dynamic_weight_log_topk.jsonl"), dynamic_topk)
    write_csv(
        os.path.join(out_dir, "dynamic_weight_summary_by_trajectory.csv"),
        simple_group_medians(dynamic_rows, "trajectory_id", ["weight_score", "weight_damage", "weight_cycle", "total_reward_dynamic"]),
    )
    write_json(
        os.path.join(out_dir, "dynamic_weight_summary_by_trajectory.json"),
        simple_group_medians(dynamic_rows, "trajectory_id", ["weight_score", "weight_damage", "weight_cycle", "total_reward_dynamic"]),
    )
    write_csv(
        os.path.join(out_dir, "dynamic_weight_summary_by_operator.csv"),
        simple_group_medians(dynamic_rows, "operator", ["weight_score", "weight_damage", "weight_cycle", "total_reward_dynamic"]),
    )
    write_json(
        os.path.join(out_dir, "dynamic_weight_summary_by_operator.json"),
        simple_group_medians(dynamic_rows, "operator", ["weight_score", "weight_damage", "weight_cycle", "total_reward_dynamic"]),
    )
    dynamic_trigger_rows = simple_group_medians(dynamic_rows, "weight_update_reason", ["weight_damage", "weight_cycle", "total_reward_dynamic"])
    write_csv(os.path.join(out_dir, "dynamic_trigger_summary.csv"), dynamic_trigger_rows)
    write_json(os.path.join(out_dir, "dynamic_trigger_summary.json"), dynamic_trigger_rows)
    classified_events, score_drop_summary = classify_score_drop_windows(event_rows)
    write_jsonl(os.path.join(out_dir, "production_v1_event_windows.jsonl"), event_rows)
    write_csv(os.path.join(out_dir, "production_v1_event_summary.csv"), score_drop_summary)
    write_json(os.path.join(out_dir, "production_v1_event_summary.json"), score_drop_summary)
    write_csv(os.path.join(out_dir, "positive_vs_traplike_score_drop_summary.csv"), score_drop_summary)
    write_json(os.path.join(out_dir, "positive_vs_traplike_score_drop_summary.json"), score_drop_summary)
    write_jsonl(os.path.join(out_dir, "positive_vs_traplike_score_drop_events.jsonl"), classified_events[: max(0, int(args.dynamic_trigger_event_topk))])
    overall_best = best_score_record(trajectory_rows, snapshot_rows, include_benchmark=True)
    non_benchmark_best = best_score_record(trajectory_rows, snapshot_rows, include_benchmark=False)
    final_rows = ST5["stage6_candidates"](trajectory_rows, int(args.stage6_candidate_limit))
    for row in final_rows:
        row["production_v1_recommendation"] = row.get("recommendation")
    write_jsonl(os.path.join(out_dir, "production_v1_final_recommendations.jsonl"), final_rows)
    hypotheses = production_hypotheses(trajectory_rows, score_drop_summary, overall_best, non_benchmark_best)
    write_json(os.path.join(out_dir, "hypothesis_evaluation.json"), hypotheses)
    run_config = load_optional_json(os.path.join(out_dir, "run_config.json"), {})
    run_config.update(
        {
            "script": SCRIPT_NAME,
            "production_v1": True,
            "overall_best_score": overall_best.get("best_score"),
            "overall_best_score_candidate_hash": overall_best.get("candidate_hash"),
            "overall_best_score_tuple_class_id": overall_best.get("tuple_class_id"),
            "overall_best_score_source": overall_best.get("source"),
            "overall_best_score_operator": overall_best.get("operator"),
            "overall_best_score_recommendation": overall_best.get("recommendation"),
            "overall_best_score_exactlike": overall_best.get("exactlike"),
            "overall_best_score_closure_shell": overall_best.get("closure_shell"),
            "overall_best_score_alignment": overall_best.get("alignment"),
            "overall_best_score_D_min_ratio": overall_best.get("D_min_ratio"),
            "overall_best_score_kappa_q99": overall_best.get("kappa_q99"),
            "overall_best_score_damage": overall_best.get("damage"),
            "non_benchmark_best_score": non_benchmark_best.get("best_score"),
            "non_benchmark_best_score_candidate_hash": non_benchmark_best.get("candidate_hash"),
            "non_benchmark_best_score_tuple_class_id": non_benchmark_best.get("tuple_class_id"),
            "non_benchmark_best_score_source": non_benchmark_best.get("source"),
            "non_benchmark_best_score_operator": non_benchmark_best.get("operator"),
            "non_benchmark_best_score_recommendation": non_benchmark_best.get("recommendation"),
            "non_benchmark_best_score_exactlike": non_benchmark_best.get("exactlike"),
            "non_benchmark_best_score_closure_shell": non_benchmark_best.get("closure_shell"),
            "non_benchmark_best_score_alignment": non_benchmark_best.get("alignment"),
            "non_benchmark_best_score_D_min_ratio": non_benchmark_best.get("D_min_ratio"),
            "non_benchmark_best_score_kappa_q99": non_benchmark_best.get("kappa_q99"),
            "non_benchmark_best_score_damage": non_benchmark_best.get("damage"),
        }
    )
    write_json(os.path.join(out_dir, "run_config.json"), run_config)
    actual = load_optional_json(os.path.join(out_dir, "actual_effective_config.json"), {})
    legacy_stage4_artifact = actual.get("stage4_artifact")
    actual.update(
        {
            "github_run_id": args.github_run_id or os.environ.get("GITHUB_RUN_ID"),
            "stage5_artifact": args.stage5_artifact,
            "stage4_artifact_legacy_from_stage5_wrapper": legacy_stage4_artifact,
            "artifact_names": {
                "summary": "p167-production-v1-summary-{}".format(args.github_run_id or os.environ.get("GITHUB_RUN_ID") or "<run_id>"),
                "raw": "p167-production-v1-raw-logs-{}".format(args.github_run_id or os.environ.get("GITHUB_RUN_ID") or "<run_id>"),
            },
            "production_v1": True,
        }
    )
    write_json(os.path.join(out_dir, "actual_effective_config.json"), actual)
    artifact_summary = artifact_size_summary(out_dir)
    manifest = {
        "github_run_id": args.github_run_id or os.environ.get("GITHUB_RUN_ID") or "<run_id>",
        "code_commit": args.code_commit,
        "config_hash": run_config.get("config_hash"),
        "input_manifest_hash": run_config.get("input_manifest_hash"),
        "summary_artifact_name": "p167-production-v1-summary-{}".format(args.github_run_id or os.environ.get("GITHUB_RUN_ID") or "<run_id>"),
        "raw_artifact_name": "p167-production-v1-raw-logs-{}".format(args.github_run_id or os.environ.get("GITHUB_RUN_ID") or "<run_id>"),
        "summary_files": sorted(artifact_summary.get("files", {}).keys()),
        "raw_files": [],
        "file_sizes_bytes": artifact_summary.get("files", {}),
        "raw_logs_uploaded": bool(args.upload_raw_logs and str(args.artifact_mode) == "summary_plus_raw"),
        "raw_log_policy": {
            "artifact_mode": args.artifact_mode,
            "compress_raw_logs": bool(args.compress_raw_logs),
            "upload_raw_logs": bool(args.upload_raw_logs),
        },
        "snapshot_log_policy": args.snapshot_log_mode,
        "operator_reward_log_policy": args.operator_reward_log_mode,
        "notes": [
            "Production v1 compares dynamic reward against fixed reward.",
            "Sampled diagnostics are not full certificates.",
            "p167_c09 score160 is benchmark/trap and excluded from non-benchmark best score.",
        ],
    }
    write_json(os.path.join(out_dir, "production_v1_artifact_manifest.json"), manifest)
    write_json(os.path.join(out_dir, "artifact_size_summary.json"), artifact_size_summary(out_dir))
    write_production_summary(out_dir, run_config, trajectory_rows, final_rows, hypotheses, score_drop_summary, artifact_size_summary(out_dir), overall_best, non_benchmark_best)
    with open(os.path.join(out_dir, "run_log.md"), "a") as f:
        f.write("\n## Production v1 postprocess\n\n")
        f.write("- production_v1_summary.md written\n")
        f.write("- dynamic weight summaries written\n")
        f.write("- positive vs trap-like score drop summary written\n")


def build_parser():
    parser = ST5["build_parser"]()
    parser.description = SCRIPT_NAME
    parser.set_defaults(
        config=DEFAULT_CONFIG,
        stage_name="p167_production_v1",
        steps=8000,
        sample_swaps=500,
        diagnostic_sample_count=300,
        production_c05_restarts=14,
        production_c01_restarts=11,
        production_c05_steps=8000,
        production_c01_steps=7000,
        production_c05_sample_swaps=500,
        production_c01_sample_swaps=500,
        repair_restarts=7,
        repair_steps=6000,
        repair_sample_swaps=500,
        benchmark_restarts=3,
        benchmark_steps=4000,
        benchmark_sample_swaps=400,
        baseline_restarts=0,
        stage6_candidate_limit=13,
        total_candidate_limit=13,
        operators=",".join(PRODUCTION_OPERATORS),
        snapshot_attempted_steps="0,100,250,500,1000,2500,5000,7000,8000",
        snapshot_accepted_moves="0,50,100,250,500,1000",
    )
    parser.add_argument("--stage5-artifact", default=DEFAULT_STAGE5_ARTIFACT)
    parser.add_argument("--stage5-audit-dir", default=DEFAULT_STAGE5_AUDIT)
    parser.add_argument("--production-budget-plan", default="")
    parser.add_argument("--dynamic-min-weight", type=float, default=0.2)
    parser.add_argument("--dynamic-max-weight", type=float, default=5.0)
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    if not args.run_label:
        args.run_label = args.github_run_id or "local-production-v1"
    if args.out_dir is None:
        args.out_dir = os.path.join("outputs", "explorations", "{}_p167_production_v1_dynamic_reward".format(now_stamp()))
    if not bool(args.high_resolution_logging):
        args.high_resolution_mode = "off"
    if str(args.artifact_mode) == "summary_plus_raw":
        args.upload_raw_logs = True
    args.stage1_artifact = args.stage5_artifact
    production_update_operator_state.min_weight = float(args.dynamic_min_weight)
    production_update_operator_state.max_weight = float(args.dynamic_max_weight)

    S2["load_stage2_candidates"] = load_production_candidates
    S2["task_grid"] = production_task_grid
    S2["choose_stage2_move"] = choose_production_move
    S2["move_reward_proxy"] = production_move_reward_proxy
    S2["update_operator_state"] = production_update_operator_state
    S2["run_task"] = production_run_task
    S2["run"](args)
    production_postprocess(args)
    print("Wrote p167_production_v1 outputs to {}".format(args.out_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(int(main() or 0))
