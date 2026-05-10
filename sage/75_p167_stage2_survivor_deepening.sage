from sage.all import *

import argparse
import glob
import gzip
import json
import math
import os
import random
import subprocess
import time


SCRIPT_NAME = "75_p167_stage2_survivor_deepening"
STAGE1_LIB_PATH = "sage/73_p167_broad_tuple_trajectory_dataset_calibration.sage"
DEFAULT_CONFIG = "configs/experiments/p167_stage2_survivor_deepening.yaml"
DEFAULT_TUPLE_REGISTRY = "configs/fixtures/p167_tuple_classes.json"
DEFAULT_BENCHMARK_TRAPS = "configs/fixtures/benchmark_traps/p167_score164_176.jsonl"
DEFAULT_NEARHIT_FIXTURE = "configs/fixtures/p167_focused_nearhit_candidates.jsonl"
DEFAULT_STAGE1_ARTIFACT = "/tmp/hadamard-stage1-lite-40-aggregate"

STAGE2_OPERATORS = (
    "survivor_baseline_score_only",
    "survivor_focused_plus_threshold",
    "survivor_hybrid_pair_to_closure_shell",
    "survivor_pair_profile_movespace_filter",
    "survivor_mixed_operator_adaptive",
    "survivor_exact_joint_local_repair",
)

ADAPTIVE_BASE_OPERATORS = (
    "survivor_focused_plus_threshold",
    "survivor_hybrid_pair_to_closure_shell",
    "survivor_pair_profile_movespace_filter",
    "survivor_exact_joint_local_repair",
)

ESSENTIAL_SNAPSHOT_KINDS = set(
    [
        "initial",
        "scheduled",
        "final",
        "best_score_state",
        "best_exactlike_state",
        "best_closure_shell_state",
        "best_alignment_state",
        "best_operator_reward_state",
    ]
)


def load_stage1_lib():
    namespace = {"__name__": "stage1_lib"}
    with open(STAGE1_LIB_PATH) as f:
        code = compile(f.read(), STAGE1_LIB_PATH, "exec")
    exec(code, namespace)
    return namespace


LIB = load_stage1_lib()

ensure_dir = LIB["ensure_dir"]
json_safe = LIB["json_safe"]
write_json = LIB["write_json"]
write_jsonl = LIB["write_jsonl"]
write_csv = LIB["write_csv"]
read_jsonl = LIB["read_jsonl"]
median = LIB["median"]
rate = LIB["rate"]
delta = LIB["delta"]
as_float = LIB["as_float"]
parse_list = LIB["parse_list"]
parse_int_list = LIB["parse_int_list"]
deterministic_seed = LIB["deterministic_seed"]
stable_hash = LIB["stable_hash"]
make_rng = LIB["make_rng"]
load_yaml = LIB["load_yaml"]
file_sha256 = LIB["file_sha256"]
git_commit = LIB["git_commit"]
load_tuple_registry = LIB["load_tuple_registry"]
total_diff_counts = LIB["total_diff_counts"]
rho_vector = LIB["rho_vector"]
score_counts = LIB["score_counts"]
support_from_rho = LIB["support_from_rho"]
apply_sparse_delta = LIB["apply_sparse_delta"]
apply_move = LIB["apply_move"]
json_blocks = LIB["json_blocks"]
state_hash = LIB["state_hash"]
high_abs_target = LIB["high_abs_target"]
sample_swap_moves = LIB["sample_swap_moves"]
state_metrics = LIB["state_metrics"]
random_blocks = LIB["random_blocks"]
init_blocks = LIB["init_blocks"]
stage1_choose_move = LIB["choose_move"]
task_row_stage1 = LIB["task_row"]
tuple_row_by_ks = LIB["tuple_row_by_ks"]
format_float = LIB["format_float"]
exactlike_score = LIB["exactlike_score"]
false_basin_score = LIB["false_basin_score"]
damage_components = LIB["damage_components"]
build_snapshot_row = LIB["build_snapshot_row"]
seeded_rng = LIB["seeded_rng"]
rows_by_key = LIB["rows_by_key"]
summarize = LIB["summarize"]
runtime_summary = LIB["runtime_summary"]
artifact_size_summary = LIB["artifact_size_summary"]
enrich_rank_percentiles = LIB["enrich_rank_percentiles"]
shard_distribution_summary = LIB["shard_distribution_summary"]
diagnostic_budget_summary = LIB["diagnostic_budget_summary"]
add_tuple_seed_operator_keys = LIB["add_tuple_seed_operator_keys"]


class ArgsView(object):
    pass


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def stage2_to_stage1_operator(operator):
    return {
        "survivor_baseline_score_only": "baseline_score_only",
        "survivor_focused_plus_threshold": "focused_plus_small_threshold",
        "survivor_hybrid_pair_to_closure_shell": "hybrid_pair_repair_to_closure_shell",
        "survivor_pair_profile_movespace_filter": "pair_profile_plus_movespace_filter",
        "survivor_exact_joint_local_repair": "pair_profile_plus_movespace_filter",
    }.get(operator, operator)


def stage1_args_from_run(run_row):
    cfg = run_row.get("row_level_config") or {}
    out = ArgsView()
    out.config = cfg.get("config") or "configs/experiments/p167_broad_tuple_stage1_scan.yaml"
    out.mixed_diversity_pool = 6
    init_method = str(run_row.get("init_method") or "")
    if "_pool" in init_method:
        try:
            out.mixed_diversity_pool = int(init_method.rsplit("_pool", 1)[1])
        except Exception:
            out.mixed_diversity_pool = 6
    out.diagnostic_sample_count = int(cfg.get("diagnostic_sample_count") or 200)
    out.steps = int(cfg.get("steps") or 300)
    out.sample_swaps = int(cfg.get("sample_swaps") or 200)
    out.snapshot_attempted_steps = cfg.get("snapshot_attempted_steps") or "0,25,50,100,200,300,500"
    out.snapshot_accepted_moves = cfg.get("snapshot_accepted_moves") or "0,25,50,100,200"
    out.diagnostic_type = "sampled"
    out.uphill_threshold = 16
    out.no_move_patience = 80
    out.high_resolution_logging = bool(cfg.get("high_resolution_logging"))
    out.highres_followup_accepted_moves = 50
    return out


def build_stage1_task(tuple_row, trajectory_row):
    lineage = trajectory_row.get("candidate_lineage") or {}
    seed_family = lineage.get("seed_family") or trajectory_row.get("seed_family")
    operator = lineage.get("operator") or trajectory_row.get("operator")
    restart_id = int(lineage.get("restart_id") if lineage.get("restart_id") is not None else trajectory_row.get("restart_id") or 0)
    run_seed = int(lineage.get("run_seed") or deterministic_seed(trajectory_row.get("trajectory_id") or trajectory_row.get("run_id")))
    raw = "stage1-replay:{}:{}:{}:{}".format(tuple_row["tuple_class_id"], seed_family, operator, restart_id)
    benchmark_meta = lineage.get("benchmark_meta")
    initial_blocks = None
    if benchmark_meta:
        initial_blocks = load_candidate_blocks_by_hash(benchmark_meta.get("candidate_hash"), DEFAULT_NEARHIT_FIXTURE)
    return task_row_stage1("p167_stage1_replay", tuple_row, seed_family, operator, restart_id, run_seed, raw, initial_blocks, benchmark_meta)


def replay_stage1_best_blocks(tuple_row, trajectory_row, run_row):
    args = stage1_args_from_run(run_row)
    task = build_stage1_task(tuple_row, trajectory_row)
    p = int(task["p"])
    ks = [int(x) for x in task["ks"]]
    lam = int(task["lambda"])
    blocks, init_method = init_blocks(task, task["seed_family"], task["run_seed"], args)
    counts = total_diff_counts(p, blocks)
    best_score = score_counts(counts, lam)
    best_blocks = [set(block) for block in blocks]
    accepted = 0
    no_move_streak = 0
    for step in range(1, int(args.steps) + 1):
        rng = seeded_rng(task["run_seed"] + step * 1009)
        move, _target = stage1_choose_move(task["operator"], blocks, counts, lam, p, rng, int(args.sample_swaps), int(args.uphill_threshold))
        if move is None:
            no_move_streak += 1
            if int(args.no_move_patience) > 0 and no_move_streak >= int(args.no_move_patience):
                break
            continue
        next_blocks = apply_move(blocks, move)
        if next_blocks is None:
            no_move_streak += 1
            continue
        blocks = next_blocks
        counts = apply_sparse_delta(counts, move["delta"])
        accepted += 1
        no_move_streak = 0
        score = score_counts(counts, lam)
        if score < best_score:
            best_score = int(score)
            best_blocks = [set(block) for block in blocks]
    recovered_hash = state_hash(best_blocks, p, ks)
    expected_hash = trajectory_row.get("best_state_hash")
    return {
        "blocks": best_blocks,
        "best_score": int(best_score),
        "recovered_hash": recovered_hash,
        "expected_hash": expected_hash,
        "hash_match": bool(expected_hash and recovered_hash == expected_hash),
        "accepted_moves_replayed": int(accepted),
        "init_method": init_method,
    }


def load_candidate_blocks_by_hash(candidate_hash, fixture_path):
    if not candidate_hash or not fixture_path or not os.path.exists(fixture_path):
        return None
    for row in read_jsonl(fixture_path):
        if row.get("candidate_hash") == candidate_hash and row.get("blocks"):
            return [[int(x) for x in block] for block in row.get("blocks")]
    return None


def candidate_hash_from_blocks(blocks, p, ks):
    return state_hash([set(block) for block in blocks], int(p), [int(k) for k in ks])


def save_stage2_score0_candidate(out_dir, task, blocks, run_id, operator, state_label):
    p = int(task["p"])
    ks = [int(k) for k in task["ks"]]
    h = state_hash([set(block) for block in blocks], p, ks)
    score0_dir = os.path.join(out_dir, "score0_candidates")
    ensure_dir(score0_dir)
    path = os.path.join(score0_dir, "{}_{}_{}.json".format(h[:12], operator, state_label))
    payload = {
        "p": p,
        "v": p,
        "n": int(4 * p),
        "ks": ks,
        "lambda": int(task["lambda"]),
        "score": 0,
        "blocks": json_blocks(blocks),
        "canonical_hash": h,
        "parent_hash": task.get("candidate_hash"),
        "candidate_id": task.get("candidate_id"),
        "source": task.get("source"),
        "source_script": SCRIPT_NAME,
        "run_id": run_id,
        "trajectory_id": run_id,
        "operator": operator,
        "state_label": state_label,
        "note": "score=0 is only a candidate until 08/05/04 validation passes",
    }
    write_json(path, payload)
    return path, h


def load_stage1_artifact(stage1_artifact):
    root = stage1_artifact
    if not os.path.isdir(root):
        raise RuntimeError("Stage 1 artifact path does not exist: {}".format(root))
    paths = {
        "survivors": os.path.join(root, "stage2_survivor_candidates.jsonl"),
        "trajectory": os.path.join(root, "trajectory_level_records.jsonl"),
        "run": os.path.join(root, "run_level_records.jsonl"),
        "snapshot": os.path.join(root, "snapshot_level_records.jsonl"),
    }
    for name, path in paths.items():
        if not os.path.exists(path):
            raise RuntimeError("Stage 1 artifact missing {}: {}".format(name, path))
    return paths


def load_survivor_candidates(args, tuple_rows):
    paths = load_stage1_artifact(args.stage1_artifact)
    survivors = read_jsonl(paths["survivors"])[: int(args.survivor_limit)]
    trajectory_by_id = {row.get("trajectory_id"): row for row in read_jsonl(paths["trajectory"])}
    run_by_id = {row.get("run_id"): row for row in read_jsonl(paths["run"])}
    tuple_by_id = {row["tuple_class_id"]: row for row in tuple_rows}
    out = []
    for idx, survivor in enumerate(survivors, 1):
        trajectory = trajectory_by_id.get(survivor.get("trajectory_id")) or trajectory_by_id.get(survivor.get("run_id"))
        run_row = run_by_id.get(survivor.get("run_id"))
        tuple_row = tuple_by_id.get(survivor.get("tuple_class_id"))
        if not trajectory or not run_row or not tuple_row:
            continue
        replay = replay_stage1_best_blocks(tuple_row, trajectory, run_row)
        blocks = replay["blocks"]
        candidate_hash = replay["recovered_hash"]
        out.append(
            {
                "candidate_id": "survivor_{:03d}_{}".format(idx, candidate_hash[:12]),
                "candidate_hash": candidate_hash,
                "source": "survivor",
                "blocks": json_blocks(blocks),
                "tuple_class_id": tuple_row["tuple_class_id"],
                "abs_row_sums": tuple_row["abs_row_sums"],
                "ks": tuple_row["ks"],
                "representative_tuple": tuple_row.get("representative_tuple", tuple_row["ks"]),
                "lambda": tuple_row["lambda"],
                "p": tuple_row["p"],
                "n": tuple_row["n"],
                "equivalence_definition": tuple_row.get("equivalence_definition"),
                "seed_family": survivor.get("seed_family"),
                "operator_from_stage1": survivor.get("operator"),
                "stage1_run_id": survivor.get("run_id"),
                "stage1_trajectory_id": survivor.get("trajectory_id"),
                "stage1_selection_reason": survivor.get("why_selected"),
                "stage1_best_score": survivor.get("best_score"),
                "stage1_best_exactlike_score": survivor.get("best_exactlike_score"),
                "stage1_best_closure_shell_score": survivor.get("best_closure_shell_score"),
                "stage1_best_alignment_to_minus_rho": survivor.get("best_alignment_to_minus_rho"),
                "stage1_best_state_hash": survivor.get("best_state_hash"),
                "stage1_replay_hash": replay["recovered_hash"],
                "stage1_replay_hash_match": replay["hash_match"],
                "stage1_replay_best_score": replay["best_score"],
                "stage1_replay_accepted_moves": replay["accepted_moves_replayed"],
                "candidate_lineage": {
                    "source": "stage1_survivor_replay",
                    "stage1_survivor": survivor,
                    "stage1_trajectory": {
                        "run_id": trajectory.get("run_id"),
                        "candidate_lineage": trajectory.get("candidate_lineage"),
                    },
                    "stage1_replay": {key: value for key, value in replay.items() if key != "blocks"},
                },
            }
        )
    return out


def load_benchmark_controls(args, tuple_rows):
    limit = int(args.benchmark_trap_limit)
    if limit <= 0:
        return []
    manifest_rows = read_jsonl(args.benchmark_trap_manifest)[:limit]
    fixture = None
    if manifest_rows:
        fixture = manifest_rows[0].get("source_fixture") or args.nearhit_fixture
    tuple_by_id = {row["tuple_class_id"]: row for row in tuple_rows}
    out = []
    for idx, manifest in enumerate(manifest_rows, 1):
        blocks = load_candidate_blocks_by_hash(manifest.get("candidate_hash"), fixture)
        tuple_row = tuple_by_id.get(manifest.get("tuple_class_id"))
        if not blocks or not tuple_row:
            continue
        out.append(
            {
                "candidate_id": "benchmark_{:03d}_{}".format(idx, manifest.get("candidate_hash", "")[:12]),
                "candidate_hash": manifest.get("candidate_hash"),
                "source": "benchmark_trap",
                "blocks": blocks,
                "tuple_class_id": tuple_row["tuple_class_id"],
                "abs_row_sums": tuple_row["abs_row_sums"],
                "ks": tuple_row["ks"],
                "representative_tuple": tuple_row.get("representative_tuple", tuple_row["ks"]),
                "lambda": tuple_row["lambda"],
                "p": tuple_row["p"],
                "n": tuple_row["n"],
                "equivalence_definition": tuple_row.get("equivalence_definition"),
                "seed_family": "benchmark_trap",
                "operator_from_stage1": None,
                "stage1_run_id": None,
                "stage1_trajectory_id": None,
                "stage1_selection_reason": ["benchmark_trap_control"],
                "stage1_best_score": manifest.get("score"),
                "stage1_best_exactlike_score": None,
                "stage1_best_closure_shell_score": None,
                "stage1_best_alignment_to_minus_rho": None,
                "candidate_lineage": {"source": "benchmark_trap_fixture", "benchmark_meta": manifest},
            }
        )
    return out


def load_nearhit_controls(args, tuple_rows):
    limit = int(args.nearhit_control_limit)
    if limit <= 0 or not os.path.exists(args.nearhit_fixture):
        return []
    tuple_by_id = {row["tuple_class_id"]: row for row in tuple_rows}
    out = []
    seen = set()
    for row in read_jsonl(args.nearhit_fixture):
        score = as_float(row.get("score"))
        if score is None or score < 180 or score > 232 or not row.get("blocks"):
            continue
        ks = row.get("tuple")
        tuple_row = tuple_row_by_ks(tuple_rows, ks)
        if not tuple_row:
            continue
        candidate_hash = row.get("candidate_hash") or candidate_hash_from_blocks(row.get("blocks"), tuple_row["p"], tuple_row["ks"])
        if candidate_hash in seen:
            continue
        seen.add(candidate_hash)
        out.append(
            {
                "candidate_id": "nearhit_{:03d}_{}".format(len(out) + 1, candidate_hash[:12]),
                "candidate_hash": candidate_hash,
                "source": "nearhit_control",
                "blocks": row.get("blocks"),
                "tuple_class_id": tuple_row["tuple_class_id"],
                "abs_row_sums": tuple_row["abs_row_sums"],
                "ks": tuple_row["ks"],
                "representative_tuple": tuple_row.get("representative_tuple", tuple_row["ks"]),
                "lambda": tuple_row["lambda"],
                "p": tuple_row["p"],
                "n": tuple_row["n"],
                "equivalence_definition": tuple_row.get("equivalence_definition"),
                "seed_family": "nearhit_control",
                "operator_from_stage1": None,
                "stage1_run_id": None,
                "stage1_trajectory_id": None,
                "stage1_selection_reason": ["nearhit_control_score_{}_{}".format(180, 232)],
                "stage1_best_score": row.get("score"),
                "stage1_best_exactlike_score": None,
                "stage1_best_closure_shell_score": None,
                "stage1_best_alignment_to_minus_rho": None,
                "candidate_lineage": {"source": "nearhit_fixture", "nearhit_meta": {k: row.get(k) for k in ("candidate_hash", "score", "source_method", "source_file", "label")}},
            }
        )
        if len(out) >= limit:
            break
    return out


def load_random_controls(args, tuple_rows):
    limit = int(args.random_control_limit)
    if limit <= 0:
        return []
    out = []
    tuple_rows = list(tuple_rows)
    for idx in range(limit):
        tuple_row = tuple_rows[idx % len(tuple_rows)]
        seed = int(args.seed_base) + 550000000 + idx * 104729
        rng = make_rng(seed)
        blocks = random_blocks(int(tuple_row["p"]), [int(k) for k in tuple_row["ks"]], rng)
        candidate_hash = candidate_hash_from_blocks(blocks, tuple_row["p"], tuple_row["ks"])
        out.append(
            {
                "candidate_id": "random_{:03d}_{}".format(idx + 1, candidate_hash[:12]),
                "candidate_hash": candidate_hash,
                "source": "random_control",
                "blocks": json_blocks(blocks),
                "tuple_class_id": tuple_row["tuple_class_id"],
                "abs_row_sums": tuple_row["abs_row_sums"],
                "ks": tuple_row["ks"],
                "representative_tuple": tuple_row.get("representative_tuple", tuple_row["ks"]),
                "lambda": tuple_row["lambda"],
                "p": tuple_row["p"],
                "n": tuple_row["n"],
                "equivalence_definition": tuple_row.get("equivalence_definition"),
                "seed_family": "random_control",
                "operator_from_stage1": None,
                "stage1_run_id": None,
                "stage1_trajectory_id": None,
                "stage1_selection_reason": ["random_control"],
                "stage1_best_score": None,
                "stage1_best_exactlike_score": None,
                "stage1_best_closure_shell_score": None,
                "stage1_best_alignment_to_minus_rho": None,
                "candidate_lineage": {"source": "random_control", "seed": seed},
            }
        )
    return out


def load_stage2_candidates(args, tuple_rows):
    survivors = load_survivor_candidates(args, tuple_rows)
    controls = []
    controls.extend(load_benchmark_controls(args, tuple_rows))
    controls.extend(load_random_controls(args, tuple_rows))
    controls.extend(load_nearhit_controls(args, tuple_rows))
    total_limit = int(args.total_candidate_limit)
    if total_limit > 0:
        remaining = max(0, total_limit - len(survivors))
        controls = controls[:remaining]
    return survivors, controls


def task_grid(candidates, operators, restarts, seed_base, stage_name):
    tasks = []
    for candidate in candidates:
        for operator in operators:
            for restart_id in range(int(restarts)):
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


def shard_tasks(tasks, shard_index, shard_count):
    shard_index = int(shard_index)
    shard_count = int(shard_count)
    if shard_count <= 1:
        return tasks
    return [task for idx, task in enumerate(tasks) if idx % shard_count == shard_index]


def choose_weighted(rng, items, weights):
    total = sum(max(0.0, float(w)) for w in weights)
    if total <= 0.0:
        return rng.choice(items)
    needle = rng.random() * total
    acc = 0.0
    for item, weight in zip(items, weights):
        acc += max(0.0, float(weight))
        if acc >= needle:
            return item
    return items[-1]


def adaptive_operator(operator_state, rng):
    weights = []
    for operator in ADAPTIVE_BASE_OPERATORS:
        state = operator_state.setdefault(operator, {"success": 0, "failure": 0, "recent_reward": 0.0, "uses": 0})
        weights.append(1.0 + state["success"] + max(0.0, state["recent_reward"]) - 0.25 * state["failure"])
    return choose_weighted(rng, list(ADAPTIVE_BASE_OPERATORS), weights)


def exact_joint_local_move(blocks, counts, lam, p, rng, sample_swaps, uphill_threshold):
    rho = rho_vector(counts, lam)
    target_d = high_abs_target(rho, rng)
    moves = sample_swap_moves(blocks, counts, rho, lam, p, rng, int(sample_swaps), target_d)
    allowed = [move for move in moves if int(move["h"]) <= int(uphill_threshold) * 2 and float(move["new_support_fraction"]) <= 0.70]
    if not allowed:
        allowed = [move for move in moves if int(move["h"]) <= int(uphill_threshold)]
    if not allowed:
        return None, target_d
    allowed.sort(key=lambda move: (-float(move["kappa"]), int(move["h"]), int(move["added_support_count"]), -int(move["removed_support_count"])))
    return allowed[0], target_d


def choose_stage2_move(task_operator, blocks, counts, lam, p, rng, sample_swaps, uphill_threshold, operator_state):
    selected = task_operator
    reason = "fixed_operator"
    if task_operator == "survivor_mixed_operator_adaptive":
        selected = adaptive_operator(operator_state, rng)
        reason = "adaptive_reward_weighted"
    if selected == "survivor_exact_joint_local_repair":
        move, target_d = exact_joint_local_move(blocks, counts, lam, p, rng, sample_swaps, uphill_threshold)
    else:
        base = stage2_to_stage1_operator(selected)
        move, target_d = stage1_choose_move(base, blocks, counts, lam, p, rng, sample_swaps, uphill_threshold)
    return move, target_d, selected, reason


def move_reward_proxy(move, score):
    if move is None:
        return -0.05
    score_gain = max(0.0, -float(move.get("h") or 0.0)) / float(max(1.0, score))
    kappa_proxy = max(0.0, min(2.0, float(move.get("kappa") or 0.0))) / 2.0
    support_proxy = 0.05 * float(move.get("removed_support_count") or 0) - 0.05 * float(move.get("added_support_count") or 0)
    damage_proxy = max(0.0, float(move.get("h") or 0.0)) / float(max(1.0, score))
    return float(score_gain + 0.25 * kappa_proxy + support_proxy - damage_proxy)


def update_operator_state(operator_state, operator, reward):
    state = operator_state.setdefault(operator, {"success": 0, "failure": 0, "recent_reward": 0.0, "uses": 0})
    state["uses"] += 1
    state["recent_reward"] = 0.8 * float(state.get("recent_reward") or 0.0) + 0.2 * float(reward)
    if reward > 0:
        state["success"] += 1
    else:
        state["failure"] += 1


def operator_state_counts(operator_state):
    return {
        "operator_success_count": sum(int(v.get("success") or 0) for v in operator_state.values()),
        "operator_failure_count": sum(int(v.get("failure") or 0) for v in operator_state.values()),
        "operator_recent_reward": sum(float(v.get("recent_reward") or 0.0) for v in operator_state.values()),
        "operator_switch_count": sum(1 for v in operator_state.values() if int(v.get("uses") or 0) > 0),
    }


def emit_stage2_snapshot(row_base, snapshots, kind, attempted_steps, accepted_moves, blocks, counts, lam, p, rng, diagnostic_samples, initial_support, initial_metrics, best_score, diagnostic_type, current_operator, operator_reward, operator_state):
    metrics = state_metrics(blocks, counts, lam, p, rng, diagnostic_samples, initial_support, diagnostic_type)
    row = build_snapshot_row(row_base, kind, attempted_steps, accepted_moves, metrics, initial_metrics, best_score, getattr(rng, "_stage_seed", 0))
    row["current_operator"] = current_operator
    row["operator_reward"] = float(operator_reward or 0.0)
    row["operator_selected_reason"] = "snapshot"
    row.update(operator_state_counts(operator_state))
    snapshots.append(row)
    return row, metrics


def trajectory_recommendation(initial_metrics, best_exact_metrics, best_shell_metrics, best_align_metrics, final_metrics, best_score, final_score):
    closure_delta = delta(initial_metrics.get("closure_shell_score"), best_shell_metrics.get("closure_shell_score")) or 0.0
    align_delta = delta(initial_metrics.get("best_alignment_to_minus_rho"), best_align_metrics.get("best_alignment_to_minus_rho")) or 0.0
    dmin_delta = delta(initial_metrics.get("D_min_ratio"), best_exact_metrics.get("D_min_ratio")) or 0.0
    kappa_delta = delta(initial_metrics.get("kappa_q99"), best_exact_metrics.get("kappa_q99")) or 0.0
    components = damage_components(initial_metrics, final_metrics)
    damage_score = float(components.get("damage_score") or 0.0)
    hardening_score = max(
        0.0,
        -float(dmin_delta or 0.0),
        -float(delta(initial_metrics.get("P_16"), final_metrics.get("P_16")) or 0.0),
        -float(delta(initial_metrics.get("kappa_q99"), final_metrics.get("kappa_q99")) or 0.0),
    )
    support_mixing_score = 1.0 - float(final_metrics.get("persistent_defect_fraction") or 1.0)
    score_delta = int(best_score) - int(initial_metrics["S"])
    if damage_score <= 0.35 and closure_delta > 0.15 and align_delta > 0.05 and dmin_delta < 0:
        recommendation = "deep_search"
        final_label = "stage3_candidate"
    elif damage_score <= 0.50 and (closure_delta > 0 or align_delta > 0 or dmin_delta < 0):
        recommendation = "repair_target"
        final_label = "promising_repair_target"
    elif damage_score > 0.75 or hardening_score > 0.75:
        recommendation = "archive"
        final_label = "hardening_or_damage"
    else:
        recommendation = "needs_more_diagnostics"
        final_label = "ambiguous"
    if score_delta < 0 and recommendation == "needs_more_diagnostics":
        recommendation = "operator_benchmark"
    return {
        "closure_shell_delta": float(closure_delta),
        "alignment_delta": float(align_delta),
        "D_min_ratio_delta": float(dmin_delta),
        "kappa_q99_delta": float(kappa_delta),
        "damage_score": damage_score,
        "hardening_score": float(hardening_score),
        "support_mixing_score": float(support_mixing_score),
        "recommendation": recommendation,
        "final_label": final_label,
    }


def run_task(task, args, config_hash, input_manifest_hash, code_commit, github_run_id):
    started = time.time()
    p = int(task["p"])
    ks = [int(x) for x in task["ks"]]
    lam = int(task["lambda"])
    run_id = task["task_id"] + "_r{}".format(task["restart_id"])
    blocks = [set(int(x) for x in block) for block in task["blocks"]]
    counts = total_diff_counts(p, blocks)
    initial_rho = rho_vector(counts, lam)
    initial_support = support_from_rho(initial_rho)
    diagnostic_type = str(args.diagnostic_type)
    initial_diagnostic_seed = int(task["run_seed"] + 101)
    initial_metrics = state_metrics(blocks, counts, lam, p, seeded_rng(initial_diagnostic_seed), int(args.diagnostic_sample_count), initial_support, diagnostic_type)
    best_score = int(initial_metrics["S"])
    best_score_metrics = dict(initial_metrics)
    best_exact_metrics = dict(initial_metrics)
    best_shell_metrics = dict(initial_metrics)
    best_align_metrics = dict(initial_metrics)
    best_reward_metrics = dict(initial_metrics)
    best_score_blocks = [set(block) for block in blocks]
    final_blocks = [set(block) for block in blocks]
    attempted_schedule = set(parse_int_list(args.snapshot_attempted_steps, [0, 50, 100, 200, 500, 1000]))
    accepted_schedule = set(parse_int_list(args.snapshot_accepted_moves, [0, 25, 50, 100, 200, 500]))
    emitted_attempted_steps = set([0])
    emitted_accepted_moves = set([0])
    emitted_highres_accepted_moves = set()
    snapshots = []
    reward_log = []
    operator_state = {}
    row_base = {
        "run_id": run_id,
        "trajectory_id": run_id,
        "run_label": args.run_label,
        "task_id": task["task_id"],
        "candidate_id": task["candidate_id"],
        "candidate_hash": task["candidate_hash"],
        "source": task["source"],
        "tuple_class_id": task["tuple_class_id"],
        "abs_row_sums": task["abs_row_sums"],
        "ks": ks,
        "representative_tuple": task.get("representative_tuple", ks),
        "lambda": lam,
        "equivalence_definition": task.get("equivalence_definition"),
        "seed_family": task.get("seed_family"),
        "operator_from_stage1": task.get("operator_from_stage1"),
        "operator": task["operator"],
        "restart_id": int(task["restart_id"]),
        "shard_id": int(args.shard_index),
        "github_run_id": github_run_id,
        "code_commit": code_commit,
        "config_hash": config_hash,
        "input_manifest_hash": input_manifest_hash,
        "artifact_path": args.out_dir,
        "operator_version": "{}_operator_v1".format(args.stage_name or "p167_stage2"),
        "stage1_run_id": task.get("stage1_run_id"),
        "stage1_trajectory_id": task.get("stage1_trajectory_id"),
    }
    initial_row = build_snapshot_row(row_base, "initial", 0, 0, initial_metrics, initial_metrics, best_score, initial_diagnostic_seed)
    initial_row["current_operator"] = task["operator"]
    initial_row["operator_reward"] = 0.0
    initial_row["operator_selected_reason"] = "initial"
    initial_row.update(operator_state_counts(operator_state))
    snapshots.append(initial_row)
    best_score_snapshot = dict(initial_row, snapshot_kind="best_score_state")
    best_exact_snapshot = dict(initial_row, snapshot_kind="best_exactlike_state")
    best_shell_snapshot = dict(initial_row, snapshot_kind="best_closure_shell_state")
    best_align_snapshot = dict(initial_row, snapshot_kind="best_alignment_state")
    best_reward_snapshot = dict(initial_row, snapshot_kind="best_operator_reward_state")
    best_operator_reward = -10 ** 9
    accepted = 0
    highres_until = -1
    highres_trigger_count = 0
    highres_windows_opened = 0
    no_move_streak = 0
    previous_selected = None
    operator_switch_count = 0
    for step in range(1, int(args.steps) + 1):
        rng = seeded_rng(task["run_seed"] + step * 1009)
        move, target_d, selected_operator, selected_reason = choose_stage2_move(task["operator"], blocks, counts, lam, p, rng, int(args.sample_swaps), int(args.uphill_threshold), operator_state)
        if previous_selected is not None and selected_operator != previous_selected:
            operator_switch_count += 1
        previous_selected = selected_operator
        score_before = score_counts(counts, lam)
        reward = move_reward_proxy(move, score_before)
        if move is None:
            update_operator_state(operator_state, selected_operator, reward)
            no_move_streak += 1
            if int(args.no_move_patience) > 0 and no_move_streak >= int(args.no_move_patience):
                break
        else:
            next_blocks = apply_move(blocks, move)
            if next_blocks is not None:
                blocks = next_blocks
                counts = apply_sparse_delta(counts, move["delta"])
                accepted += 1
                no_move_streak = 0
                score = score_counts(counts, lam)
                update_operator_state(operator_state, selected_operator, reward)
                reward_log.append(
                    {
                        "run_id": run_id,
                        "trajectory_id": run_id,
                        "candidate_id": task["candidate_id"],
                        "source": task["source"],
                        "tuple_class_id": task["tuple_class_id"],
                        "operator": task["operator"],
                        "current_operator": selected_operator,
                        "operator_selected_reason": selected_reason,
                        "step": int(step),
                        "accepted_moves": int(accepted),
                        "operator_reward": float(reward),
                        "DeltaS": int(move.get("h") or 0),
                        "kappa": float(move.get("kappa") or 0.0),
                        "target_d": target_d,
                        "removed_support_count": int(move.get("removed_support_count") or 0),
                        "added_support_count": int(move.get("added_support_count") or 0),
                    }
                )
                if reward > best_operator_reward:
                    best_operator_reward = float(reward)
                    reward_seed = task["run_seed"] + 500000 + accepted
                    best_reward_metrics = state_metrics(blocks, counts, lam, p, seeded_rng(reward_seed), int(args.diagnostic_sample_count), initial_support, diagnostic_type)
                    best_reward_snapshot = build_snapshot_row(row_base, "best_operator_reward_state", step, accepted, best_reward_metrics, initial_metrics, best_score, reward_seed)
                    best_reward_snapshot["current_operator"] = selected_operator
                    best_reward_snapshot["operator_reward"] = float(reward)
                    best_reward_snapshot["operator_selected_reason"] = selected_reason
                    best_reward_snapshot.update(operator_state_counts(operator_state))
                if score < best_score:
                    best_score = int(score)
                    best_score_blocks = [set(block) for block in blocks]
                    best_seed = task["run_seed"] + 400000 + accepted
                    best_score_metrics = state_metrics(blocks, counts, lam, p, seeded_rng(best_seed), int(args.diagnostic_sample_count), initial_support, diagnostic_type)
                    best_score_snapshot = build_snapshot_row(row_base, "best_score_state", step, accepted, best_score_metrics, initial_metrics, best_score, best_seed)
                    best_score_snapshot["current_operator"] = selected_operator
                    best_score_snapshot["operator_reward"] = float(reward)
                    best_score_snapshot["operator_selected_reason"] = selected_reason
                    best_score_snapshot.update(operator_state_counts(operator_state))
        attempted_due = step in attempted_schedule and step not in emitted_attempted_steps
        accepted_due = accepted in accepted_schedule and accepted not in emitted_accepted_moves
        highres_due = (
            str(args.high_resolution_mode) == "all"
            and accepted > 0
            and accepted not in emitted_highres_accepted_moves
        ) or (
            str(args.high_resolution_mode) == "triggered"
            and accepted > 0
            and accepted <= highres_until
            and accepted not in emitted_highres_accepted_moves
        )
        need_snapshot = attempted_due or accepted_due or highres_due
        if need_snapshot:
            kind = "high_resolution" if highres_due else "scheduled"
            row, metrics = emit_stage2_snapshot(
                row_base,
                snapshots,
                kind,
                step,
                accepted,
                blocks,
                counts,
                lam,
                p,
                seeded_rng(task["run_seed"] + 200000 + step + accepted),
                int(args.diagnostic_sample_count),
                initial_support,
                initial_metrics,
                best_score,
                diagnostic_type,
                selected_operator,
                reward,
                operator_state,
            )
            row["operator_switch_count"] = int(operator_switch_count)
            if attempted_due:
                emitted_attempted_steps.add(step)
            if accepted_due:
                emitted_accepted_moves.add(accepted)
            if highres_due:
                emitted_highres_accepted_moves.add(accepted)
            if exactlike_score(metrics) > exactlike_score(best_exact_metrics):
                best_exact_metrics = dict(metrics)
                best_exact_snapshot = dict(row, snapshot_kind="best_exactlike_state")
            if float(metrics.get("closure_shell_score") or -999.0) > float(best_shell_metrics.get("closure_shell_score") or -999.0):
                best_shell_metrics = dict(metrics)
                best_shell_snapshot = dict(row, snapshot_kind="best_closure_shell_state")
            if float(metrics.get("best_alignment_to_minus_rho") or -999.0) > float(best_align_metrics.get("best_alignment_to_minus_rho") or -999.0):
                best_align_metrics = dict(metrics)
                best_align_snapshot = dict(row, snapshot_kind="best_alignment_state")
            if bool(args.high_resolution_logging) and str(args.high_resolution_mode) == "triggered":
                dmin0 = initial_metrics.get("D_min_ratio")
                dmin = metrics.get("D_min_ratio")
                align_delta = row.get("alignment_delta")
                kappa_delta = row.get("kappa_q99_delta")
                shell_delta = row.get("closure_shell_delta")
                trigger = False
                if dmin0 is not None and dmin is not None and float(dmin) <= 0.8 * float(dmin0):
                    trigger = True
                if align_delta is not None and float(align_delta) >= 0.15:
                    trigger = True
                if kappa_delta is not None and float(kappa_delta) >= 0.10:
                    trigger = True
                if shell_delta is not None and float(shell_delta) >= 0.50:
                    trigger = True
                if reward > best_operator_reward + 0.25:
                    trigger = True
                if (
                    trigger
                    and highres_windows_opened < int(args.high_resolution_max_windows_per_trajectory)
                    and accepted + int(args.high_resolution_window_accepted_moves) > highres_until
                ):
                    highres_until = accepted + int(args.high_resolution_window_accepted_moves)
                    highres_trigger_count += 1
                    highres_windows_opened += 1
    final_blocks = [set(block) for block in blocks]
    final_counts = counts
    final_score = score_counts(final_counts, lam)
    final_row, final_metrics = emit_stage2_snapshot(
        row_base,
        snapshots,
        "final",
        min(int(args.steps), step if "step" in locals() else 0),
        accepted,
        final_blocks,
        final_counts,
        lam,
        p,
        seeded_rng(task["run_seed"] + 999999),
        int(args.diagnostic_sample_count),
        initial_support,
        initial_metrics,
        best_score,
        diagnostic_type,
        previous_selected or task["operator"],
        best_operator_reward if best_operator_reward > -10 ** 8 else 0.0,
        operator_state,
    )
    final_row["operator_switch_count"] = int(operator_switch_count)
    if exactlike_score(final_metrics) > exactlike_score(best_exact_metrics):
        best_exact_metrics = dict(final_metrics)
        best_exact_snapshot = dict(final_row, snapshot_kind="best_exactlike_state")
    if float(final_metrics.get("closure_shell_score") or -999.0) > float(best_shell_metrics.get("closure_shell_score") or -999.0):
        best_shell_metrics = dict(final_metrics)
        best_shell_snapshot = dict(final_row, snapshot_kind="best_closure_shell_state")
    if float(final_metrics.get("best_alignment_to_minus_rho") or -999.0) > float(best_align_metrics.get("best_alignment_to_minus_rho") or -999.0):
        best_align_metrics = dict(final_metrics)
        best_align_snapshot = dict(final_row, snapshot_kind="best_alignment_state")
    snapshots.extend([best_score_snapshot, best_exact_snapshot, best_shell_snapshot, best_align_snapshot, best_reward_snapshot])
    completed = time.time()
    verdict = trajectory_recommendation(initial_metrics, best_exact_metrics, best_shell_metrics, best_align_metrics, final_metrics, best_score, final_score)
    support_mixing_score = verdict["support_mixing_score"]
    run_row = dict(row_base)
    run_row.update(
        {
            "diagnostic_type": diagnostic_type,
            "diagnostic_sample_count": int(args.diagnostic_sample_count),
            "diagnostic_seed": int(task["run_seed"] + 101),
            "diagnostic_budget": int(args.diagnostic_sample_count),
            "started_at": int(started),
            "completed_at": int(completed),
            "wall_time_seconds": float(completed - started),
            "status": "completed",
            "row_level_config": {
                "config": args.config,
                "stage1_artifact": args.stage1_artifact,
                "steps": int(args.steps),
                "sample_swaps": int(args.sample_swaps),
                "diagnostic_sample_count": int(args.diagnostic_sample_count),
                "snapshot_attempted_steps": args.snapshot_attempted_steps,
                "snapshot_accepted_moves": args.snapshot_accepted_moves,
                "high_resolution_logging": bool(args.high_resolution_logging),
                "high_resolution_mode": args.high_resolution_mode,
                "high_resolution_max_windows_per_trajectory": int(args.high_resolution_max_windows_per_trajectory),
                "high_resolution_window_accepted_moves": int(args.high_resolution_window_accepted_moves),
                "artifact_mode": args.artifact_mode,
                "snapshot_log_mode": args.snapshot_log_mode,
                "operator_reward_log_mode": args.operator_reward_log_mode,
                "operator_reward_topk": int(args.operator_reward_topk),
                "operator_reward_sample_rate": float(args.operator_reward_sample_rate),
            },
            "config_inline_or_ref": args.config,
            "candidate_lineage_policy": "stage1_survivor_replay_or_control_fixture",
        }
    )
    score0_candidate_path = None
    score0_candidate_hash = None
    if int(best_score) == 0:
        score0_candidate_path, score0_candidate_hash = save_stage2_score0_candidate(
            args.out_dir,
            task,
            best_score_blocks,
            run_id,
            task["operator"],
            "best_score",
        )
    trajectory = dict(row_base)
    trajectory.update(
        {
            "initial_score": int(initial_metrics["S"]),
            "best_score": int(best_score),
            "final_score": int(final_score),
            "score_delta_from_start": int(best_score - int(initial_metrics["S"])),
            "best_exactlike_score": exactlike_score(best_exact_metrics),
            "best_false_basin_score": false_basin_score(best_exact_metrics),
            "best_closure_shell_score": best_shell_metrics.get("closure_shell_score"),
            "best_alignment_to_minus_rho": best_align_metrics.get("best_alignment_to_minus_rho"),
            "best_operator_reward": float(best_operator_reward if best_operator_reward > -10 ** 8 else 0.0),
            "damage_score": float(verdict["damage_score"]),
            "hardening_score": float(verdict["hardening_score"]),
            "support_mixing_score": float(support_mixing_score),
            "damage_seen": bool(float(verdict["damage_score"]) > 0.50),
            "acceptance_rate": float(accepted) / float(max(1, step if "step" in locals() else 0)),
            "attempted_steps": int(step if "step" in locals() else 0),
            "accepted_moves": int(accepted),
            "best_state_hash": state_hash(best_score_blocks, p, ks),
            "final_state_hash": state_hash(final_blocks, p, ks),
            "final_label": verdict["final_label"],
            "recommendation": verdict["recommendation"],
            "runtime_seconds": float(completed - started),
            "artifact_bytes": None,
            "artifact_path": args.out_dir,
            "operator_version": "{}_operator_v1".format(args.stage_name or "p167_stage2"),
            "parent_hash": task.get("candidate_hash"),
            "candidate_lineage": task.get("candidate_lineage"),
            "score0_candidate_path": score0_candidate_path,
            "score0_candidate_hash": score0_candidate_hash,
            "highres_trigger_count": int(highres_trigger_count),
            "operator_switch_count": int(operator_switch_count),
            "D_min_ratio_delta": verdict["D_min_ratio_delta"],
            "P_16_delta": delta(initial_metrics.get("P_16"), best_exact_metrics.get("P_16")),
            "P_32_delta": delta(initial_metrics.get("P_32"), best_exact_metrics.get("P_32")),
            "kappa_q99_delta": verdict["kappa_q99_delta"],
            "alignment_delta": verdict["alignment_delta"],
            "closure_shell_delta": verdict["closure_shell_delta"],
            "S_delta_from_start": int(best_score - int(initial_metrics["S"])),
            "D_min_ratio_delta_from_start": verdict["D_min_ratio_delta"],
            "P_16_delta_from_start": delta(initial_metrics.get("P_16"), best_exact_metrics.get("P_16")),
            "P_32_delta_from_start": delta(initial_metrics.get("P_32"), best_exact_metrics.get("P_32")),
            "kappa_q99_delta_from_start": verdict["kappa_q99_delta"],
            "kappa_max_delta_from_start": delta(initial_metrics.get("kappa_max"), best_exact_metrics.get("kappa_max")),
            "alignment_delta_from_start": verdict["alignment_delta"],
            "closure_shell_delta_from_start": verdict["closure_shell_delta"],
            "damage_score_delta_from_start": float(verdict["damage_score"]),
            "score_band": int(math.floor(float(best_score) / 50.0) * 50),
            "stage1_selection_reason": task.get("stage1_selection_reason"),
            "stage1_best_score": task.get("stage1_best_score"),
            "stage1_best_exactlike_score": task.get("stage1_best_exactlike_score"),
            "stage1_best_closure_shell_score": task.get("stage1_best_closure_shell_score"),
            "stage1_best_alignment_to_minus_rho": task.get("stage1_best_alignment_to_minus_rho"),
        }
    )
    return run_row, trajectory, snapshots, reward_log


def aggregate_roots(args):
    names = {
        "run": "run_level.jsonl",
        "trajectory": "trajectory_level.jsonl",
        "snapshot": "snapshot_level.jsonl",
        "attempts": "survivor_deepening_attempts.jsonl",
        "reward": "operator_reward_log.jsonl",
        "survivors": "input_stage2_survivors.jsonl",
        "controls": "input_stage2_controls.jsonl",
    }
    out = {key: [] for key in names}
    for root in parse_list(args.aggregate_roots):
        for key, filename in names.items():
            for path in glob.glob(os.path.join(root, "**", filename), recursive=True):
                out[key].extend(read_jsonl(path))
    return out


def dedupe_rows(rows, key):
    out = []
    seen = set()
    for row in rows:
        value = row.get(key)
        if value is None:
            value = stable_hash(json.dumps(json_safe(row), sort_keys=True))
        if value in seen:
            continue
        seen.add(value)
        out.append(row)
    return out


def summarize_controls(trajectory_rows):
    return summarize(trajectory_rows, "source")


def build_hypotheses(trajectory_rows):
    source_groups = rows_by_key(trajectory_rows, "source")
    survivor_rows = source_groups.get("survivor", [])
    control_rows = [row for row in trajectory_rows if row.get("source") != "survivor"]
    benchmark_rows = source_groups.get("benchmark_trap", [])
    baseline_rows = [row for row in trajectory_rows if row.get("operator") == "survivor_baseline_score_only"]
    routed_rows = [row for row in trajectory_rows if row.get("operator") != "survivor_baseline_score_only"]
    best_score_row = min(trajectory_rows, key=lambda row: float(row.get("best_score") or 10 ** 12)) if trajectory_rows else None
    best_exactlike_row = max(trajectory_rows, key=lambda row: float(row.get("best_exactlike_score") or -1.0)) if trajectory_rows else None
    stage3_rows = [row for row in trajectory_rows if row.get("recommendation") in ("deep_search", "repair_target")]
    return {
        "H_STAGE2_1_survivors_beat_controls": {
            "status": "supported"
            if survivor_rows
            and control_rows
            and (median(row.get("best_closure_shell_score") for row in survivor_rows) or 0.0) >= (median(row.get("best_closure_shell_score") for row in control_rows) or 0.0)
            else "inconclusive",
            "survivor_closure_median": median(row.get("best_closure_shell_score") for row in survivor_rows),
            "control_closure_median": median(row.get("best_closure_shell_score") for row in control_rows),
        },
        "H_STAGE2_2_routing_beats_baseline": {
            "status": "supported"
            if baseline_rows
            and routed_rows
            and (median(row.get("closure_shell_delta") for row in routed_rows) or 0.0) >= (median(row.get("closure_shell_delta") for row in baseline_rows) or 0.0)
            else "inconclusive",
            "baseline_closure_delta_median": median(row.get("closure_shell_delta") for row in baseline_rows),
            "routed_closure_delta_median": median(row.get("closure_shell_delta") for row in routed_rows),
        },
        "H_STAGE2_3_stage1_selection_effective": {
            "status": "supported"
            if survivor_rows and control_rows and rate(survivor_rows, "damage_seen") <= rate(control_rows, "damage_seen")
            else "inconclusive",
            "survivor_damage_rate": rate(survivor_rows, "damage_seen"),
            "control_damage_rate": rate(control_rows, "damage_seen"),
        },
        "H_STAGE2_4_best_score_not_exactlike": {
            "status": "supported"
            if best_score_row and best_exactlike_row and best_score_row.get("trajectory_id") != best_exactlike_row.get("trajectory_id")
            else "inconclusive",
            "best_score_trajectory_id": best_score_row.get("trajectory_id") if best_score_row else None,
            "best_exactlike_trajectory_id": best_exactlike_row.get("trajectory_id") if best_exactlike_row else None,
        },
        "H_STAGE2_5_benchmark_traps_remain_hard": {
            "status": "supported"
            if benchmark_rows
            and survivor_rows
            and (median(row.get("damage_score") for row in benchmark_rows) or 0.0) >= (median(row.get("damage_score") for row in survivor_rows) or 0.0)
            else "inconclusive",
            "benchmark_damage_median": median(row.get("damage_score") for row in benchmark_rows),
            "survivor_damage_median": median(row.get("damage_score") for row in survivor_rows),
        },
        "H_STAGE2_6_stage3_candidates_available": {
            "status": "supported" if stage3_rows else "inconclusive",
            "stage3_candidate_count": len(stage3_rows),
        },
    }


def stage3_candidates(trajectory_rows, limit):
    rows = []
    for row in trajectory_rows:
        reasons = []
        if float(row.get("closure_shell_delta") or 0.0) > 0.0:
            reasons.append("closure_shell_improved")
        if float(row.get("alignment_delta") or 0.0) > 0.0:
            reasons.append("alignment_improved")
        if float(row.get("D_min_ratio_delta") or 0.0) < 0.0:
            reasons.append("D_min_ratio_decreased")
        if float(row.get("kappa_q99_delta") or 0.0) > 0.0:
            reasons.append("kappa_q99_improved")
        if float(row.get("damage_score") or 0.0) <= 0.35:
            reasons.append("low_damage")
        if float(row.get("hardening_score") or 0.0) <= 0.35:
            reasons.append("low_hardening")
        if float(row.get("support_mixing_score") or 0.0) > 0.10:
            reasons.append("support_mixing_positive")
        if float(row.get("score_delta_from_start") or 0.0) > 0.25 * float(row.get("initial_score") or 1):
            continue
        if len(reasons) < 4:
            continue
        recommendation = row.get("recommendation")
        rows.append(
            {
                "candidate_hash": row.get("candidate_hash"),
                "tuple_class_id": row.get("tuple_class_id"),
                "ks": row.get("ks"),
                "lambda": row.get("lambda"),
                "source": row.get("source"),
                "stage1_selection_reason": row.get("stage1_selection_reason"),
                "stage2_best_operator": row.get("operator"),
                "stage2_best_score": row.get("best_score"),
                "stage2_best_exactlike_score": row.get("best_exactlike_score"),
                "stage2_best_closure_shell_score": row.get("best_closure_shell_score"),
                "stage2_best_alignment": row.get("best_alignment_to_minus_rho"),
                "stage2_damage_score": row.get("damage_score"),
                "run_id": row.get("run_id"),
                "trajectory_id": row.get("trajectory_id"),
                "best_state_hash": row.get("best_state_hash"),
                "recommendation": recommendation,
                "why_selected": reasons,
            }
        )
    rows.sort(
        key=lambda row: (
            -float(row.get("stage2_best_closure_shell_score") or 0.0),
            -float(row.get("stage2_best_exactlike_score") or 0.0),
            float(row.get("stage2_damage_score") or 0.0),
            float(row.get("stage2_best_score") or 10 ** 9),
        )
    )
    return rows[: int(limit)]


def write_stage2_summary(path, run_config, run_rows, trajectory_rows, snapshot_rows, tuple_summary, operator_summary, survivor_summary, control_summary, benchmark_summary, stage3_rows, hypotheses, artifact_summary):
    source_counts = rows_by_key(trajectory_rows, "source")
    tuple_sorted = sorted(tuple_summary, key=lambda row: float(row.get("closure_shell_score_median") or 0.0), reverse=True)
    operator_sorted = sorted(operator_summary, key=lambda row: (float(row.get("closure_shell_improvement_rate") or 0.0), -float(row.get("damage_rate") or 0.0)), reverse=True)
    seed_summary = summarize(trajectory_rows, "seed_family")
    seed_sorted = sorted(seed_summary, key=lambda row: float(row.get("closure_shell_score_median") or 0.0), reverse=True)
    stage1_operator_summary = summarize(trajectory_rows, "operator_from_stage1")
    stage1_operator_sorted = sorted(stage1_operator_summary, key=lambda row: float(row.get("closure_shell_score_median") or 0.0), reverse=True)
    best_score_row = min(trajectory_rows, key=lambda row: float(row.get("best_score") or 10 ** 12)) if trajectory_rows else None
    best_exactlike_row = max(trajectory_rows, key=lambda row: float(row.get("best_exactlike_score") or -1.0)) if trajectory_rows else None
    lines = []
    lines.append("# p167 Stage 2 survivor deepening")
    lines.append("")
    lines.append("This is a Stage 2 survivor deepening diagnostic, not a Hadamard 668 construction run.")
    lines.append("")
    lines.append("Sampled diagnostics are not full certificates.")
    lines.append("")
    lines.append("## Scope")
    lines.append("")
    lines.append("- run rows: `{}`".format(len(run_rows)))
    lines.append("- trajectory rows: `{}`".format(len(trajectory_rows)))
    lines.append("- snapshot rows: `{}`".format(len(snapshot_rows)))
    lines.append("- sources: `{}`".format({key: len(value) for key, value in source_counts.items()}))
    lines.append("- stage3 recommendations: `{}`".format(len(stage3_rows)))
    lines.append("- artifact bytes: `{}`".format(artifact_summary.get("artifact_total_bytes")))
    lines.append("- score0 candidate files: `{}`".format(sum(1 for row in trajectory_rows if row.get("score0_candidate_path"))))
    lines.append("- snapshot log mode: `{}`".format(run_config.get("snapshot_log_mode")))
    lines.append("- operator reward log mode: `{}`".format(run_config.get("operator_reward_log_mode")))
    lines.append("- raw logs uploaded: `{}`".format(run_config.get("upload_raw_logs")))
    lines.append("")
    lines.append("## Operator Summary")
    lines.append("")
    lines.append("| operator | runs | best score | closure improve | alignment improve | D_min improve | damage rate |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")
    for row in operator_summary:
        lines.append("| `{}` | {} | {} | {} | {} | {} | {} |".format(row.get("operator"), row.get("run_count"), row.get("best_score"), format_float(row.get("closure_shell_improvement_rate")), format_float(row.get("alignment_improvement_rate")), format_float(row.get("D_min_improvement_rate")), format_float(row.get("damage_rate"))))
    lines.append("")
    lines.append("## Hypotheses")
    lines.append("")
    for key in sorted(hypotheses):
        lines.append("- `{}`: `{}`".format(key, hypotheses[key].get("status")))
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    lines.append("1. Stage 2 対象: survivor `{}`, controls `{}`.".format(len(source_counts.get("survivor", [])), len(trajectory_rows) - len(source_counts.get("survivor", []))))
    lines.append("2. Stage 1 survivors は controls より良かったか: `{}`.".format(hypotheses["H_STAGE2_1_survivors_beat_controls"]["status"]))
    lines.append("3. benchmark traps は引き続き hard trap だったか: `{}`.".format(hypotheses["H_STAGE2_5_benchmark_traps_remain_hard"]["status"]))
    lines.append("4. 良かった tuple class: `{}` by closure_shell_score_median.".format(tuple_sorted[0].get("tuple_class_id") if tuple_sorted else "NA"))
    lines.append("5. 良かった Stage 1 seed family: `{}` by closure_shell_score_median.".format(seed_sorted[0].get("seed_family") if seed_sorted else "NA"))
    lines.append("6. 良かった Stage 1 operator 由来: `{}` by closure_shell_score_median.".format(stage1_operator_sorted[0].get("operator_from_stage1") if stage1_operator_sorted else "NA"))
    lines.append("7. Stage 2 で良かった operator: `{}` by closure improvement / damage tradeoff.".format(operator_sorted[0].get("operator") if operator_sorted else "NA"))
    lines.append("8. mixed/adaptive operator は baseline より良かったか: `{}`.".format(hypotheses["H_STAGE2_2_routing_beats_baseline"]["status"]))
    lines.append("9. best score と exact-like metrics は一致したか: `{}`.".format("no" if best_score_row and best_exactlike_row and best_score_row.get("trajectory_id") != best_exactlike_row.get("trajectory_id") else "inconclusive"))
    lines.append("10. Stage 3 candidate は `{}` 件.".format(len(stage3_rows)))
    lines.append("11. Stage 3 は `deep_search` / `repair_target` recommendations を深掘りする。")
    lines.append("12. score0 candidate は出たか: `{}`.".format("yes" if any(int(row.get("best_score") or 1) == 0 for row in trajectory_rows) else "no"))
    lines.append("13. sampled diagnostic の限界: full certificate ではない。")
    lines.append("14. artifact size / runtime は runtime_summary と artifact_size_summary を参照。")
    lines.append("")
    lines.append("## Formula Notes")
    lines.append("")
    lines.append("- `S = sum_{d != 0} rho(d)^2`")
    lines.append("- `D_min_ratio = D_min_1 / S`")
    lines.append("- `kappa = -2g / q`")
    lines.append("- `alignment = <Delta rho, -rho> / (||Delta rho|| * ||rho||)`")
    lines.append("- `reward = closure improvement + alignment improvement + kappa improvement + D_min improvement + support mixing - damage`")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def write_jsonl_gzip(path, rows):
    ensure_dir(os.path.dirname(path))
    with gzip.open(path, "wt") as f:
        for row in rows:
            f.write(json.dumps(json_safe(row), sort_keys=True) + "\n")


def filtered_snapshot_rows(snapshot_rows, mode):
    mode = str(mode or "summary_only")
    if mode == "full":
        return list(snapshot_rows)
    if mode == "triggered":
        return list(snapshot_rows)
    if mode == "scheduled":
        return [row for row in snapshot_rows if row.get("snapshot_kind") != "high_resolution"]
    return [row for row in snapshot_rows if row.get("snapshot_kind") in ESSENTIAL_SNAPSHOT_KINDS]


def best_numeric(rows, key, higher_is_better=True):
    usable = [row for row in rows if row.get(key) is not None]
    if not usable:
        return None
    return max(usable, key=lambda row: float(row.get(key))) if higher_is_better else min(usable, key=lambda row: float(row.get(key)))


def snapshot_summary_by_trajectory(snapshot_rows):
    groups = rows_by_key(snapshot_rows, "trajectory_id")
    out = []
    for trajectory_id in sorted(groups):
        rows = groups[trajectory_id]
        initial = next((row for row in rows if row.get("snapshot_kind") == "initial"), rows[0])
        final = next((row for row in reversed(rows) if row.get("snapshot_kind") == "final"), rows[-1])
        best_s = best_numeric(rows, "S", higher_is_better=False)
        best_closure = best_numeric(rows, "closure_shell_score", higher_is_better=True)
        best_dmin = best_numeric(rows, "D_min_ratio", higher_is_better=False)
        best_kappa = best_numeric(rows, "kappa_q99", higher_is_better=True)
        best_alignment = best_numeric(rows, "best_alignment_to_minus_rho", higher_is_better=True)
        max_damage = best_numeric(rows, "damage_score", higher_is_better=True)
        row = {
            "trajectory_id": trajectory_id,
            "run_id": initial.get("run_id"),
            "tuple_class_id": initial.get("tuple_class_id"),
            "operator": initial.get("operator"),
            "source": initial.get("source"),
            "recommendation": initial.get("recommendation"),
            "initial_S": initial.get("S"),
            "best_S": best_s.get("S") if best_s else None,
            "final_S": final.get("S"),
            "initial_closure_shell_score": initial.get("closure_shell_score"),
            "best_closure_shell_score": best_closure.get("closure_shell_score") if best_closure else None,
            "final_closure_shell_score": final.get("closure_shell_score"),
            "closure_shell_delta_best": delta(initial.get("closure_shell_score"), best_closure.get("closure_shell_score") if best_closure else None),
            "initial_D_min_ratio": initial.get("D_min_ratio"),
            "best_D_min_ratio": best_dmin.get("D_min_ratio") if best_dmin else None,
            "final_D_min_ratio": final.get("D_min_ratio"),
            "D_min_ratio_delta_best": delta(initial.get("D_min_ratio"), best_dmin.get("D_min_ratio") if best_dmin else None),
            "initial_kappa_q99": initial.get("kappa_q99"),
            "best_kappa_q99": best_kappa.get("kappa_q99") if best_kappa else None,
            "final_kappa_q99": final.get("kappa_q99"),
            "kappa_q99_delta_best": delta(initial.get("kappa_q99"), best_kappa.get("kappa_q99") if best_kappa else None),
            "initial_alignment": initial.get("best_alignment_to_minus_rho"),
            "best_alignment": best_alignment.get("best_alignment_to_minus_rho") if best_alignment else None,
            "final_alignment": final.get("best_alignment_to_minus_rho"),
            "alignment_delta_best": delta(initial.get("best_alignment_to_minus_rho"), best_alignment.get("best_alignment_to_minus_rho") if best_alignment else None),
            "initial_damage_score": initial.get("damage_score"),
            "max_damage_score": max_damage.get("damage_score") if max_damage else None,
            "final_damage_score": final.get("damage_score"),
            "best_snapshot_kind": best_closure.get("snapshot_kind") if best_closure else None,
            "best_snapshot_step": best_closure.get("attempted_steps") if best_closure else None,
            "best_snapshot_accepted_moves": best_closure.get("accepted_moves") if best_closure else None,
        }
        out.append(row)
    return out


def simple_group_summary(rows, key):
    out = []
    for value, group in sorted(rows_by_key(rows, key).items()):
        out.append(
            {
                key: value,
                "trajectory_count": len(group),
                "median_best_S": median(row.get("best_S") for row in group),
                "median_best_closure_shell_score": median(row.get("best_closure_shell_score") for row in group),
                "median_D_min_ratio_delta_best": median(row.get("D_min_ratio_delta_best") for row in group),
                "median_kappa_q99_delta_best": median(row.get("kappa_q99_delta_best") for row in group),
                "median_alignment_delta_best": median(row.get("alignment_delta_best") for row in group),
                "median_max_damage_score": median(row.get("max_damage_score") for row in group),
            }
        )
    return out


def reward_topk_rows(reward_rows, trajectory_lookup, k):
    k = int(k)
    grouped = rows_by_key(reward_rows, "trajectory_id")
    out = []
    for trajectory_id, group in grouped.items():
        group = sorted(group, key=lambda row: float(row.get("operator_reward") or 0.0), reverse=True)[:k]
        for row in group:
            base = dict(row)
            trajectory = trajectory_lookup.get(trajectory_id, {})
            base["recommendation"] = trajectory.get("recommendation")
            base["reward"] = base.get("operator_reward")
            base["reward_components"] = {
                "DeltaS": base.get("DeltaS"),
                "kappa": base.get("kappa"),
                "removed_support_count": base.get("removed_support_count"),
                "added_support_count": base.get("added_support_count"),
            }
            base.setdefault("S", None)
            base.setdefault("D_min_ratio", None)
            base.setdefault("kappa_q99", None)
            base.setdefault("closure_shell_score", None)
            base.setdefault("alignment", None)
            base.setdefault("damage_score", None)
            out.append(base)
    return out


def reward_sampled_rows(reward_rows, sample_rate, seed_base):
    sample_rate = float(sample_rate)
    if sample_rate <= 0:
        return []
    if sample_rate >= 1:
        return list(reward_rows)
    out = []
    for row in reward_rows:
        seed = deterministic_seed((seed_base, row.get("trajectory_id"), row.get("step"), row.get("current_operator")))
        if random.Random(seed).random() <= sample_rate:
            out.append(row)
    return out


def operator_reward_summary_rows(reward_rows, trajectory_lookup):
    enriched = []
    for row in reward_rows:
        trajectory = trajectory_lookup.get(row.get("trajectory_id"), {})
        enriched.append(
            dict(
                row,
                source=row.get("source") or trajectory.get("source"),
                recommendation=trajectory.get("recommendation"),
                damage_seen=trajectory.get("damage_seen"),
                closure_improved=float(trajectory.get("closure_shell_delta") or 0.0) > 0.0,
                alignment_improved=float(trajectory.get("alignment_delta") or 0.0) > 0.0,
                D_min_improved=float(trajectory.get("D_min_ratio_delta") or 0.0) < 0.0,
            )
        )
    grouped = {}
    for row in enriched:
        key = (row.get("current_operator"), row.get("tuple_class_id"), row.get("source"), row.get("recommendation"))
        grouped.setdefault(key, []).append(row)
    out = []
    for key, group in sorted(grouped.items(), key=lambda item: str(item[0])):
        rewards = [float(row.get("operator_reward") or 0.0) for row in group]
        operator, tuple_class_id, source, recommendation = key
        out.append(
            {
                "operator": operator,
                "tuple_class_id": tuple_class_id,
                "source": source,
                "recommendation": recommendation,
                "attempt_count": len(group),
                "median_reward": median(rewards),
                "mean_reward": sum(rewards) / float(len(rewards)) if rewards else None,
                "max_reward": max(rewards) if rewards else None,
                "min_reward": min(rewards) if rewards else None,
                "positive_reward_rate": sum(1 for value in rewards if value > 0.0) / float(len(rewards)) if rewards else 0.0,
                "damage_rate": rate(group, "damage_seen"),
                "closure_improvement_rate": rate(group, "closure_improved"),
                "alignment_improvement_rate": rate(group, "alignment_improved"),
                "D_min_improvement_rate": rate(group, "D_min_improved"),
            }
        )
    return out


def dominant_row_level_config(run_rows):
    counts = {}
    for row in run_rows:
        cfg = row.get("row_level_config") or {}
        key = json.dumps(json_safe(cfg), sort_keys=True)
        counts[key] = counts.get(key, 0) + 1
    if not counts:
        return {}
    key = max(counts, key=lambda item: counts[item])
    try:
        return json.loads(key)
    except Exception:
        return {}


def write_artifact_policy_summary(path, args):
    lines = []
    lines.append("# Stage 2 artifact policy")
    lines.append("")
    lines.append("This run separates audit-friendly summary outputs from optional heavy raw logs.")
    lines.append("")
    lines.append("## Summary artifact contents")
    lines.append("")
    lines.append("- run and trajectory records")
    lines.append("- compact snapshot records")
    lines.append("- snapshot summaries by trajectory / tuple / operator / recommendation")
    lines.append("- operator reward summary and top-k/sample logs")
    lines.append("- Stage 3 recommendations and hypothesis summary")
    lines.append("- `actual_effective_config.json` and `stage2_artifact_manifest.json`")
    lines.append("")
    lines.append("## Raw artifact contents")
    lines.append("")
    lines.append("- `raw_logs/snapshot_level_records.jsonl.gz` when raw logs are enabled")
    lines.append("- `raw_logs/operator_reward_log.jsonl.gz` when raw logs are enabled")
    lines.append("")
    lines.append("## Default policy")
    lines.append("")
    lines.append("- artifact_mode: `{}`".format(args.artifact_mode))
    lines.append("- snapshot_log_mode: `{}`".format(args.snapshot_log_mode))
    lines.append("- operator_reward_log_mode: `{}`".format(args.operator_reward_log_mode))
    lines.append("- upload_raw_logs: `{}`".format(args.upload_raw_logs))
    lines.append("- compress_raw_logs: `{}`".format(args.compress_raw_logs))
    lines.append("")
    lines.append("Full raw logs are for debugging only. Summary outputs remain the primary audit interface.")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def build_artifact_manifest(args, artifact_summary, raw_files, summary_files):
    run_id = args.github_run_id or os.environ.get("GITHUB_RUN_ID") or "<run_id>"
    return {
        "github_run_id": run_id,
        "code_commit": args.code_commit,
        "config_hash": None,
        "input_manifest_hash": None,
        "summary_artifact_name": "p167-stage2-summary-{}".format(run_id),
        "raw_artifact_name": "p167-stage2-raw-logs-{}".format(run_id),
        "summary_files": summary_files,
        "raw_files": raw_files,
        "file_sizes_bytes": artifact_summary.get("files", {}),
        "compressed_file_sizes_bytes": {},
        "raw_logs_uploaded": bool(args.upload_raw_logs),
        "raw_log_policy": args.operator_reward_log_mode,
        "snapshot_log_policy": args.snapshot_log_mode,
        "operator_reward_log_policy": args.operator_reward_log_mode,
        "full_snapshot_available": bool(args.upload_raw_logs),
        "full_snapshot_path": "raw_logs/snapshot_level_records.jsonl.gz" if args.upload_raw_logs else None,
        "operator_reward_full_available": bool(args.upload_raw_logs),
        "operator_reward_full_path": "raw_logs/operator_reward_log.jsonl.gz" if args.upload_raw_logs else None,
        "notes": [
            "summary artifact is the primary audit interface",
            "sampled diagnostics are not full certificates",
            "GitHub artifact compressed sizes are not available before upload",
        ],
    }


def write_outputs(args, run_rows, trajectory_rows, snapshot_rows, attempts_rows, reward_rows, input_survivors, input_controls, config_hash, input_manifest_hash, code_commit, tuple_registry_payload):
    input_survivors = dedupe_rows(input_survivors, "candidate_id")
    input_controls = dedupe_rows(input_controls, "candidate_id")
    trajectory_rows = add_tuple_seed_operator_keys(trajectory_rows)
    snapshot_rows = enrich_rank_percentiles(snapshot_rows)
    tuple_summary = summarize(trajectory_rows, "tuple_class_id")
    operator_summary = summarize(trajectory_rows, "operator")
    survivor_summary = summarize([row for row in trajectory_rows if row.get("source") == "survivor"], "candidate_id")
    control_summary = summarize_controls(trajectory_rows)
    benchmark_summary = summarize([row for row in trajectory_rows if row.get("source") == "benchmark_trap"], "candidate_id")
    runtime_rows = runtime_summary(run_rows, args.shard_index, args.shard_count)
    diagnostic_summary = diagnostic_budget_summary(snapshot_rows)
    stage3_rows = stage3_candidates(trajectory_rows, int(args.stage3_candidate_limit))
    stage3_summary = summarize(stage3_rows, "tuple_class_id")
    hypotheses = build_hypotheses(trajectory_rows)
    trajectory_lookup = dict((row.get("trajectory_id"), row) for row in trajectory_rows)
    snapshot_summary = snapshot_summary_by_trajectory(snapshot_rows)
    for row in snapshot_summary:
        trajectory = trajectory_lookup.get(row.get("trajectory_id"), {})
        if trajectory:
            row["recommendation"] = trajectory.get("recommendation")
            row["source"] = trajectory.get("source")
            row["operator"] = trajectory.get("operator")
            row["tuple_class_id"] = trajectory.get("tuple_class_id")
    snapshot_summary_by_tuple = simple_group_summary(snapshot_summary, "tuple_class_id")
    snapshot_summary_by_operator = simple_group_summary(snapshot_summary, "operator")
    snapshot_summary_by_recommendation = simple_group_summary(snapshot_summary, "recommendation")
    compact_snapshot_rows = filtered_snapshot_rows(snapshot_rows, args.snapshot_log_mode)
    reward_summary = operator_reward_summary_rows(reward_rows, trajectory_lookup)
    reward_topk = reward_topk_rows(reward_rows, trajectory_lookup, int(args.operator_reward_topk))
    reward_sampled = reward_sampled_rows(reward_rows, float(args.operator_reward_sample_rate), int(args.seed_base))
    if args.operator_reward_log_mode == "full_compressed":
        summary_reward_rows = reward_topk
    elif args.operator_reward_log_mode == "sampled":
        summary_reward_rows = reward_sampled
    else:
        summary_reward_rows = reward_topk

    write_jsonl(os.path.join(args.out_dir, "input_stage2_survivors.jsonl"), input_survivors)
    write_jsonl(os.path.join(args.out_dir, "input_stage2_controls.jsonl"), input_controls)
    write_jsonl(os.path.join(args.out_dir, "run_level.jsonl"), run_rows)
    write_jsonl(os.path.join(args.out_dir, "trajectory_level.jsonl"), trajectory_rows)
    write_jsonl(os.path.join(args.out_dir, "snapshot_level.jsonl"), compact_snapshot_rows)
    write_jsonl(os.path.join(args.out_dir, "run_level_records.jsonl"), run_rows)
    write_jsonl(os.path.join(args.out_dir, "trajectory_level_records.jsonl"), trajectory_rows)
    write_jsonl(os.path.join(args.out_dir, "snapshot_level_records.jsonl"), compact_snapshot_rows)
    write_jsonl(os.path.join(args.out_dir, "survivor_deepening_attempts.jsonl"), attempts_rows or trajectory_rows)
    write_jsonl(os.path.join(args.out_dir, "operator_reward_log.jsonl"), summary_reward_rows)
    write_jsonl(os.path.join(args.out_dir, "operator_reward_topk.jsonl"), reward_topk)
    write_jsonl(os.path.join(args.out_dir, "operator_reward_sampled.jsonl"), reward_sampled)
    write_csv(os.path.join(args.out_dir, "operator_reward_summary.csv"), reward_summary)
    write_json(os.path.join(args.out_dir, "operator_reward_summary.json"), reward_summary)
    write_jsonl(os.path.join(args.out_dir, "snapshot_summary_by_trajectory.jsonl"), snapshot_summary)
    write_csv(os.path.join(args.out_dir, "snapshot_summary_by_tuple.csv"), snapshot_summary_by_tuple)
    write_json(os.path.join(args.out_dir, "snapshot_summary_by_tuple.json"), snapshot_summary_by_tuple)
    write_csv(os.path.join(args.out_dir, "snapshot_summary_by_operator.csv"), snapshot_summary_by_operator)
    write_json(os.path.join(args.out_dir, "snapshot_summary_by_operator.json"), snapshot_summary_by_operator)
    write_csv(os.path.join(args.out_dir, "snapshot_summary_by_recommendation.csv"), snapshot_summary_by_recommendation)
    write_json(os.path.join(args.out_dir, "snapshot_summary_by_recommendation.json"), snapshot_summary_by_recommendation)
    raw_files = []
    if bool(args.upload_raw_logs):
        raw_dir = os.path.join(args.out_dir, "raw_logs")
        ensure_dir(raw_dir)
        snapshot_raw = os.path.join(raw_dir, "snapshot_level_records.jsonl.gz")
        reward_raw = os.path.join(raw_dir, "operator_reward_log.jsonl.gz")
        if bool(args.compress_raw_logs):
            write_jsonl_gzip(snapshot_raw, snapshot_rows)
            write_jsonl_gzip(reward_raw, reward_rows)
            raw_files.extend(["raw_logs/snapshot_level_records.jsonl.gz", "raw_logs/operator_reward_log.jsonl.gz"])
        else:
            snapshot_raw = os.path.join(raw_dir, "snapshot_level_records.jsonl")
            reward_raw = os.path.join(raw_dir, "operator_reward_log.jsonl")
            write_jsonl(snapshot_raw, snapshot_rows)
            write_jsonl(reward_raw, reward_rows)
            raw_files.extend(["raw_logs/snapshot_level_records.jsonl", "raw_logs/operator_reward_log.jsonl"])
    write_csv(os.path.join(args.out_dir, "tuple_summary.csv"), tuple_summary)
    write_json(os.path.join(args.out_dir, "tuple_summary.json"), tuple_summary)
    write_csv(os.path.join(args.out_dir, "operator_summary.csv"), operator_summary)
    write_json(os.path.join(args.out_dir, "operator_summary.json"), operator_summary)
    write_csv(os.path.join(args.out_dir, "survivor_summary.csv"), survivor_summary)
    write_json(os.path.join(args.out_dir, "survivor_summary.json"), survivor_summary)
    write_csv(os.path.join(args.out_dir, "control_comparison_summary.csv"), control_summary)
    write_json(os.path.join(args.out_dir, "control_comparison_summary.json"), control_summary)
    write_csv(os.path.join(args.out_dir, "benchmark_trap_comparison_summary.csv"), benchmark_summary)
    write_json(os.path.join(args.out_dir, "benchmark_trap_comparison_summary.json"), benchmark_summary)
    write_jsonl(os.path.join(args.out_dir, "stage3_candidate_recommendations.jsonl"), stage3_rows)
    write_csv(os.path.join(args.out_dir, "stage3_candidate_summary.csv"), stage3_summary)
    write_json(os.path.join(args.out_dir, "stage3_candidate_summary.json"), stage3_summary)
    write_csv(os.path.join(args.out_dir, "diagnostic_budget_summary.csv"), diagnostic_summary)
    write_json(os.path.join(args.out_dir, "diagnostic_budget_summary.json"), diagnostic_summary)
    write_csv(os.path.join(args.out_dir, "runtime_summary.csv"), runtime_rows)
    write_json(os.path.join(args.out_dir, "runtime_summary.json"), runtime_rows)
    write_json(os.path.join(args.out_dir, "hypothesis_evaluation.json"), hypotheses)

    input_manifest = {
        "config": args.config,
        "config_hash": config_hash,
        "tuple_registry": args.tuple_registry,
        "tuple_registry_hash": file_sha256(args.tuple_registry),
        "stage1_artifact": args.stage1_artifact,
        "benchmark_trap_manifest": args.benchmark_trap_manifest,
        "benchmark_trap_manifest_hash": file_sha256(args.benchmark_trap_manifest),
        "nearhit_fixture": args.nearhit_fixture,
        "nearhit_fixture_hash": file_sha256(args.nearhit_fixture),
        "input_manifest_hash": input_manifest_hash,
    }
    write_json(os.path.join(args.out_dir, "input_manifest.json"), input_manifest)
    with open(os.path.join(args.out_dir, "input_manifest_hash.txt"), "w") as f:
        f.write(str(input_manifest_hash) + "\n")
    write_json(os.path.join(args.out_dir, "tuple_class_registry.json"), tuple_registry_payload)

    run_config = vars(args).copy()
    dominant_config = dominant_row_level_config(run_rows)
    if dominant_config:
        for key in (
            "high_resolution_logging",
            "high_resolution_mode",
            "high_resolution_max_windows_per_trajectory",
            "high_resolution_window_accepted_moves",
            "artifact_mode",
            "snapshot_log_mode",
            "operator_reward_log_mode",
            "operator_reward_topk",
            "operator_reward_sample_rate",
        ):
            if key in dominant_config:
                run_config[key] = dominant_config.get(key)
    run_config.update(
        {
            "script": SCRIPT_NAME,
            "config_hash": config_hash,
            "input_manifest_hash": input_manifest_hash,
            "code_commit": code_commit,
            "tuple_registry_schema": tuple_registry_payload.get("schema_version"),
            "run_rows": len(run_rows),
            "trajectory_rows": len(trajectory_rows),
            "snapshot_rows": len(snapshot_rows),
            "snapshot_rows_written": len(compact_snapshot_rows),
            "operator_reward_rows": len(reward_rows),
            "operator_reward_rows_written": len(summary_reward_rows),
            "stage3_candidate_rows": len(stage3_rows),
            "timestamp": now_stamp(),
        }
    )
    write_json(os.path.join(args.out_dir, "run_config.json"), run_config)
    actual_effective_config = {
        "workflow_inputs": vars(args).copy(),
        "dominant_row_level_config": dominant_config,
        "config_hash": config_hash,
        "code_commit": code_commit,
        "github_run_id": args.github_run_id or os.environ.get("GITHUB_RUN_ID"),
        "artifact_names": {
            "summary": "p167-stage2-summary-<run_id>",
            "raw": "p167-stage2-raw-logs-<run_id>",
        },
        "raw_log_policy": {
            "artifact_mode": args.artifact_mode,
            "upload_raw_logs": bool(args.upload_raw_logs),
            "compress_raw_logs": bool(args.compress_raw_logs),
        },
        "summary_artifact_policy": {
            "snapshot_log_mode": args.snapshot_log_mode,
            "operator_reward_log_mode": args.operator_reward_log_mode,
            "operator_reward_topk": int(args.operator_reward_topk),
            "operator_reward_sample_rate": float(args.operator_reward_sample_rate),
        },
    }
    write_json(os.path.join(args.out_dir, "actual_effective_config.json"), actual_effective_config)
    write_artifact_policy_summary(os.path.join(args.out_dir, "stage2_artifact_policy_summary.md"), args)
    artifact_summary = artifact_size_summary(args.out_dir)
    summary_files = sorted(
        [
            path
            for path in artifact_summary.get("files", {})
            if not path.startswith("raw_logs/")
        ]
    )
    manifest = build_artifact_manifest(args, artifact_summary, raw_files, summary_files)
    manifest["config_hash"] = config_hash
    manifest["input_manifest_hash"] = input_manifest_hash
    write_json(os.path.join(args.out_dir, "stage2_artifact_manifest.json"), manifest)
    artifact_summary = artifact_size_summary(args.out_dir)
    write_json(os.path.join(args.out_dir, "artifact_size_summary.json"), artifact_summary)
    write_stage2_summary(
        os.path.join(args.out_dir, "p167_stage2_survivor_deepening_summary.md"),
        run_config,
        run_rows,
        trajectory_rows,
        snapshot_rows,
        tuple_summary,
        operator_summary,
        survivor_summary,
        control_summary,
        benchmark_summary,
        stage3_rows,
        hypotheses,
        artifact_summary,
    )
    with open(os.path.join(args.out_dir, "run_log.md"), "w") as f:
        f.write("# p167 Stage 2 survivor deepening log\n\n")
        f.write("- run rows: `{}`\n".format(len(run_rows)))
        f.write("- trajectory rows: `{}`\n".format(len(trajectory_rows)))
        f.write("- snapshot rows: `{}`\n".format(len(snapshot_rows)))
        f.write("- sampled diagnostics: `{}`\n".format(args.diagnostic_type == "sampled"))


def run(args):
    ensure_dir(args.out_dir)
    config_payload = load_yaml(args.config)
    if not args.stage_name:
        args.stage_name = "p167_stage2"
    tuple_registry, tuple_registry_payload = load_tuple_registry(args.tuple_registry)
    config_hash = file_sha256(args.config)
    input_manifest_hash = stable_hash(
        (
            file_sha256(args.tuple_registry),
            file_sha256(args.benchmark_trap_manifest),
            file_sha256(args.nearhit_fixture),
            config_hash,
            str(args.stage1_artifact),
        )
    )
    code_commit = args.code_commit or git_commit()
    github_run_id = args.github_run_id or os.environ.get("GITHUB_RUN_ID")

    if args.aggregate_roots:
        aggregate = aggregate_roots(args)
        run_rows = aggregate["run"]
        trajectory_rows = aggregate["trajectory"]
        snapshot_rows = aggregate["snapshot"]
        attempts_rows = aggregate["attempts"] or trajectory_rows
        reward_rows = aggregate["reward"]
        input_survivors = aggregate["survivors"]
        input_controls = aggregate["controls"]
        if not run_rows and not trajectory_rows and not snapshot_rows:
            raise RuntimeError("No Stage 2 shard artifacts found in aggregate roots")
    else:
        operators = parse_list(args.operators, config_payload.get("operators", STAGE2_OPERATORS))
        input_survivors, input_controls = load_stage2_candidates(args, tuple_registry)
        candidates = input_survivors + input_controls
        if int(args.total_candidate_limit) > 0:
            candidates = candidates[: int(args.total_candidate_limit)]
        tasks_all = task_grid(candidates, operators, int(args.restarts), int(args.seed_base), args.stage_name)
        if int(args.max_tasks) > 0:
            tasks_all = tasks_all[: int(args.max_tasks)]
        tasks = shard_tasks(tasks_all, int(args.shard_index), int(args.shard_count))
        if not tasks:
            raise RuntimeError("No Stage 2 tasks selected for this shard")
        used_candidate_ids = set(task.get("candidate_id") for task in tasks)
        input_survivors = [row for row in input_survivors if row.get("candidate_id") in used_candidate_ids]
        input_controls = [row for row in input_controls if row.get("candidate_id") in used_candidate_ids]
        run_rows = []
        trajectory_rows = []
        snapshot_rows = []
        attempts_rows = []
        reward_rows = []
        for idx, task in enumerate(tasks, 1):
            run_row, trajectory, snapshots, reward_log = run_task(task, args, config_hash, input_manifest_hash, code_commit, github_run_id)
            run_rows.append(run_row)
            trajectory_rows.append(trajectory)
            attempts_rows.append(trajectory)
            snapshot_rows.extend(snapshots)
            reward_rows.extend(reward_log)
            print(args.stage_name, "task", idx, "/", len(tasks), task["source"], task["tuple_class_id"], task["operator"])

    write_outputs(args, run_rows, trajectory_rows, snapshot_rows, attempts_rows, reward_rows, input_survivors, input_controls, config_hash, input_manifest_hash, code_commit, tuple_registry_payload)
    print("Wrote {} outputs to {}".format(args.stage_name, args.out_dir))
    print("Run rows:", len(run_rows), "Trajectory rows:", len(trajectory_rows), "Snapshot rows:", len(snapshot_rows))


def build_parser():
    parser = argparse.ArgumentParser(description=SCRIPT_NAME)
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--tuple-registry", default=DEFAULT_TUPLE_REGISTRY)
    parser.add_argument("--stage1-artifact", default=DEFAULT_STAGE1_ARTIFACT)
    parser.add_argument("--benchmark-trap-manifest", default=DEFAULT_BENCHMARK_TRAPS)
    parser.add_argument("--nearhit-fixture", default=DEFAULT_NEARHIT_FIXTURE)
    parser.add_argument("--aggregate-roots", default="")
    parser.add_argument("--operators", default="")
    parser.add_argument("--survivor-limit", type=int, default=50)
    parser.add_argument("--benchmark-trap-limit", type=int, default=7)
    parser.add_argument("--random-control-limit", type=int, default=20)
    parser.add_argument("--nearhit-control-limit", type=int, default=20)
    parser.add_argument("--total-candidate-limit", type=int, default=100)
    parser.add_argument("--restarts", type=int, default=3)
    parser.add_argument("--steps", type=int, default=1000)
    parser.add_argument("--sample-swaps", type=int, default=300)
    parser.add_argument("--diagnostic-sample-count", type=int, default=300)
    parser.add_argument("--diagnostic-type", default="sampled")
    parser.add_argument("--snapshot-attempted-steps", default="0,50,100,200,500,1000")
    parser.add_argument("--snapshot-accepted-moves", default="0,25,50,100,200,500")
    parser.add_argument("--uphill-threshold", type=int, default=16)
    parser.add_argument("--no-move-patience", type=int, default=160)
    parser.add_argument("--high-resolution-logging", action="store_true", default=False)
    parser.add_argument("--disable-high-resolution-logging", action="store_false", dest="high_resolution_logging")
    parser.add_argument("--highres-followup-accepted-moves", type=int, default=50)
    parser.add_argument("--high-resolution-mode", choices=["off", "triggered", "all"], default="triggered")
    parser.add_argument("--high-resolution-max-windows-per-trajectory", type=int, default=2)
    parser.add_argument("--high-resolution-window-accepted-moves", type=int, default=50)
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
    parser.add_argument("--seed-base", type=int, default=750167)
    parser.add_argument("--stage3-candidate-limit", type=int, default=50)
    parser.add_argument("--github-run-id", default="")
    parser.add_argument("--code-commit", default="")
    parser.add_argument("--run-label", default="")
    parser.add_argument("--stage-name", default="p167_stage2")
    parser.add_argument("--out-dir", default=None)
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    if not args.run_label:
        args.run_label = args.github_run_id or "local-stage2"
    if args.out_dir is None:
        args.out_dir = os.path.join("outputs", "explorations", "{}_p167_stage2_survivor_deepening".format(now_stamp()))
    if int(args.shard_index) < 0 or int(args.shard_count) < 1 or int(args.shard_index) >= int(args.shard_count):
        raise RuntimeError("shard_index must satisfy 0 <= shard_index < shard_count")
    if not bool(args.high_resolution_logging):
        args.high_resolution_mode = "off"
    if str(args.artifact_mode) == "summary_plus_raw":
        args.upload_raw_logs = True
    if int(args.high_resolution_max_windows_per_trajectory) < 0:
        raise RuntimeError("high_resolution_max_windows_per_trajectory must be non-negative")
    if int(args.high_resolution_window_accepted_moves) < 1:
        raise RuntimeError("high_resolution_window_accepted_moves must be positive")
    if int(args.operator_reward_topk) < 1:
        raise RuntimeError("operator_reward_topk must be positive")
    if float(args.operator_reward_sample_rate) < 0.0 or float(args.operator_reward_sample_rate) > 1.0:
        raise RuntimeError("operator_reward_sample_rate must be in [0, 1]")
    run(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(int(main() or 0))
