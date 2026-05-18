#!/usr/bin/env python3
import argparse
import collections
import csv
import hashlib
import itertools
import json
import math
import os
import random
import statistics
import time
from pathlib import Path

import p167_frontier_repair_benchmark as base
import p167_low_score_wall_diagnostics as wall


P_DEFAULT = 167
EXPERIMENT_DEFAULT = "p167_fixed0123_nonmonotone_pair_lns"
OUTPUT_ROOT_DEFAULT = "outputs/p167_fixed0123_nonmonotone_pair_lns"
FRONTIER_FILES_DEFAULT = wall.FRONTIER_FILES_DEFAULT
TUPLE_CLASSES_DEFAULT = "p167_c01,p167_c05,p167_c09"
FIXED_SPLIT = "fixed_01_23"
THRESHOLDS = (200, 180, 160, 120, 100)
OPERATORS_DEFAULT = (
    "O0",
    "O1",
    "O2",
    "O3",
    "O4",
    "O5",
)
OPERATOR_NAMES = {
    "O0": "score_only_baseline",
    "O1": "fixed0123_threshold_beam_r3",
    "O2": "fixed0123_threshold_beam_r5",
    "O3": "fixed0123_threshold_beam_r7",
    "O4": "fixed0123_pair_balanced_lns",
    "O5": "fixed0123_uphill_then_repair",
    "O6": "optional_cp_sat_local_branching",
}


def parse_csv(text, cast=str):
    if isinstance(text, (list, tuple)):
        return [cast(x) for x in text]
    return [cast(part.strip()) for part in str(text).split(",") if part.strip()]


def ensure_dir(path):
    if path:
        os.makedirs(path, exist_ok=True)


def stable_int(text):
    return int(hashlib.sha256(str(text).encode("utf-8")).hexdigest()[:12], 16)


def median(values):
    vals = [float(v) for v in values if v is not None and v != ""]
    return statistics.median(vals) if vals else None


def quantile(values, q):
    vals = sorted(float(v) for v in values if v is not None and v != "")
    if not vals:
        return None
    idx = int(round((len(vals) - 1) * float(q)))
    return vals[max(0, min(len(vals) - 1, idx))]


def rate(rows, pred):
    return sum(1 for row in rows if pred(row)) / float(len(rows)) if rows else 0.0


def write_json(path, payload):
    base.write_json(path, payload)


def write_jsonl(path, rows):
    base.write_jsonl(path, rows)


def write_csv(path, rows, fields):
    base.write_csv(path, rows, fields)


def read_jsonl(path):
    return base.read_jsonl(path)


def progress(args, message):
    if getattr(args, "progress_logging", True):
        print("[progress] {}".format(message), flush=True)


def now_stamp():
    return time.strftime("%Y%m%d_%H%M%S")


def operator_name(op):
    return OPERATOR_NAMES.get(op, op)


def op_radius(op, args):
    if op == "O1":
        return 3
    if op == "O2":
        return 5
    if op == "O3":
        return 7
    if op == "O4":
        return int(args.pair_balanced_radius)
    if op == "O5":
        return int(args.uphill_then_repair_radius)
    if op == "O6":
        return min(5, int(args.pair_balanced_radius))
    return 1


def pair_loss0123(p, blocks, lam):
    return base.pair_loss(p, blocks, lam, FIXED_SPLIT)


def objective(p, blocks, lam, score, alpha):
    return float(score) + float(alpha) * float(pair_loss0123(p, blocks, lam))


def candidate_hash(blocks):
    return base.canonical_hash(blocks)


def load_candidates(args):
    # Reuse the wall-diagnostics selection logic so c01 172, c05 164,
    # and c09 160/164/176 are always prioritized.
    candidates = wall.load_all_candidates(args)
    for idx, row in enumerate(candidates):
        row["lns_candidate_id"] = "lns_{:04d}".format(idx)
    return candidates


def shard_tasks(candidates, args):
    operators = parse_csv(args.operators)
    alphas = parse_csv(args.alpha_values, float)
    uphills = parse_csv(args.max_uphill_values, int)
    tasks = []
    for cand in candidates:
        for op in operators:
            if op == "O0":
                params = [(0.0, 0, 1, 0)]
            else:
                params = []
                radius = op_radius(op, args)
                for alpha in alphas:
                    for uphill in uphills:
                        for restart in range(int(args.restarts_per_candidate_operator)):
                            params.append((alpha, uphill, radius, restart))
            for alpha, uphill, radius, restart in params:
                key = "{}::{}::{:.4g}::{}::{}::{}".format(
                    cand["candidate_hash"], op, float(alpha), int(uphill), int(radius), int(restart)
                )
                if stable_int(key) % int(args.shard_count) == int(args.shard_id):
                    tasks.append((cand, op, float(alpha), int(uphill), int(radius), int(restart)))
    return tasks


def candidate_keys(candidate):
    return {
        "lns_candidate_id": candidate["lns_candidate_id"],
        "candidate_hash_before": candidate["candidate_hash"],
        "tuple_class": candidate["tuple_class"],
        "wall_role": candidate.get("wall_role", ""),
        "frontier_bucket": candidate.get("frontier_bucket", ""),
        "source_file": candidate.get("source_file", ""),
        "source_fixture": candidate.get("source_fixture", ""),
        "source_run": candidate.get("source_run", ""),
        "ks": candidate["ks"],
        "lambda": int(candidate["lambda"]),
        "score_before": int(candidate["score"]),
    }


def pool_scores_from_defect(p, block, rho):
    return base.element_remove_scores(p, block, rho), base.element_add_scores(p, block, rho)


def mixed_pool_for_block(p, block, rho, pool_size, rng):
    remove_scores, add_scores = pool_scores_from_defect(p, block, rho)
    target_n = max(1, int(round(float(pool_size) * 0.75)))
    random_n = max(1, int(pool_size) - target_n)
    removes = [x for x, _ in sorted(remove_scores.items(), key=lambda item: (-item[1], item[0]))[:target_n]]
    adds = [x for x, _ in sorted(add_scores.items(), key=lambda item: (-item[1], item[0]))[:target_n]]
    block_values = sorted(int(x) for x in block)
    outside = [x for x in range(p) if x not in block]
    if block_values:
        removes.extend(rng.sample(block_values, min(random_n, len(block_values))))
    if outside:
        adds.extend(rng.sample(outside, min(random_n, len(outside))))
    removes = sorted(dict.fromkeys(int(x) for x in removes))[: int(pool_size)]
    adds = sorted(dict.fromkeys(int(x) for x in adds))[: int(pool_size)]
    return removes, adds


def build_fixed0123_pools(p, blocks, rho, pool_size, rng):
    return [mixed_pool_for_block(p, block, rho, pool_size, rng) for block in blocks]


def random_allocation(total_radius, block_count, rng, balanced=False):
    total_radius = int(total_radius)
    if total_radius <= 0 or block_count <= 0:
        return None
    max_blocks = min(block_count, total_radius)
    if balanced:
        if total_radius <= 1:
            return [(rng.randrange(block_count), total_radius)]
        # One left-pair and one right-pair block when possible.
        blocks = [rng.choice([0, 1]), rng.choice([2, 3])]
        if total_radius >= 3 and rng.random() < 0.35:
            extra = rng.choice([b for b in range(block_count) if b not in blocks])
            blocks.append(extra)
    else:
        count = rng.randint(1, max_blocks)
        blocks = rng.sample(range(block_count), count)
    remaining = int(total_radius)
    allocation = []
    for idx, bidx in enumerate(blocks):
        slots_left = len(blocks) - idx - 1
        if slots_left == 0:
            r = remaining
        else:
            max_r = remaining - slots_left
            if max_r < 1:
                return None
            r = rng.randint(1, max_r)
        remaining -= r
        allocation.append((bidx, r))
    return allocation


def sample_plan(p, pools, radius, rng, balanced=False):
    allocation = random_allocation(int(radius), len(pools), rng, balanced=balanced)
    if not allocation:
        return None
    plan = []
    for bidx, r in allocation:
        removes, adds = pools[bidx]
        if len(removes) < r or len(adds) < r:
            return None
        plan.append(
            {
                "block": int(bidx),
                "removes": sorted(rng.sample(removes, int(r))),
                "adds": sorted(rng.sample(adds, int(r))),
            }
        )
    return plan


def plan_key(plan):
    return tuple((item["block"], tuple(item["removes"]), tuple(item["adds"])) for item in plan)


def evaluate_plan(p, rho, current_score, blocks, plan):
    total_delta = [0] * p
    for item in plan:
        delta = base.exact_joint_delta_rho(p, blocks[item["block"]], item["removes"], item["adds"])
        for d in range(p):
            total_delta[d] += int(delta[d])
    score = 0
    for d in range(1, p):
        v = int(rho[d]) + int(total_delta[d])
        score += v * v
    return int(score), total_delta


def apply_plan(blocks, plan):
    out = [set(block) for block in blocks]
    for item in plan:
        bidx = item["block"]
        for x in item["removes"]:
            out[bidx].remove(int(x))
        for x in item["adds"]:
            out[bidx].add(int(x))
    return out


def strip_plan(plan):
    return [
        {"block": int(item["block"]), "removes": [int(x) for x in item["removes"]], "adds": [int(x) for x in item["adds"]]}
        for item in plan
    ]


def generate_candidate_moves(p, blocks, lam, score, radius, rng, args, balanced):
    rho = base.rho_vector(p, blocks, lam)
    pools = build_fixed0123_pools(p, blocks, rho, int(args.pool_size), rng)
    seen = set()
    moves = []
    attempts = 0
    cap = int(args.eval_cap_per_attempt)
    while len(moves) < cap and attempts < cap * 20:
        attempts += 1
        plan_radius = rng.randint(1, max(1, int(radius)))
        plan = sample_plan(p, pools, plan_radius, rng, balanced=balanced)
        if not plan:
            continue
        key = plan_key(plan)
        if key in seen:
            continue
        seen.add(key)
        new_score, delta = evaluate_plan(p, rho, score, blocks, plan)
        new_blocks = apply_plan(blocks, plan)
        moves.append(
            {
                "score": int(new_score),
                "deltaS": int(new_score) - int(score),
                "plan": strip_plan(plan),
                "blocks": new_blocks,
                "delta": delta,
                "radius": int(plan_radius),
            }
        )
    return moves, len(moves)


def nonmonotone_pair_lns(p, blocks, lam, op, alpha, max_uphill, radius, seed, args):
    rng = random.Random(int(seed))
    initial_blocks = [set(block) for block in blocks]
    initial_score = base.P37.score_blocks(p, initial_blocks, lam)
    initial_pair = pair_loss0123(p, initial_blocks, lam)
    initial_obj = objective(p, initial_blocks, lam, initial_score, alpha)
    started = time.time()
    beam = [
        {
            "blocks": initial_blocks,
            "score": int(initial_score),
            "objective": float(initial_obj),
            "path": [],
            "worst_intermediate_score": int(initial_score),
            "accepted_uphill_steps": 0,
            "max_uphill_used": 0,
            "used_radius": 0,
        }
    ]
    best = dict(beam[0])
    total_eval = 0
    exact_eval = 0
    timeout = False
    any_uphill = False
    accepted_count = 0
    failure_mode = "unknown"
    balanced = op == "O4"
    max_depth = int(radius)
    progress(args, "lns-start op={} score={} alpha={} uphill={} radius={} seed={}".format(op, initial_score, alpha, max_uphill, radius, seed))
    for depth in range(1, max_depth + 1):
        next_states = []
        for state in beam:
            if (time.time() - started) * 1000.0 >= float(args.max_wall_time_ms):
                timeout = True
                break
            remaining_radius = int(radius) - int(state.get("used_radius", 0))
            if remaining_radius <= 0:
                continue
            moves, evaluated = generate_candidate_moves(
                p, state["blocks"], lam, int(state["score"]), remaining_radius, rng, args, balanced=balanced
            )
            total_eval += evaluated
            exact_eval += evaluated
            for move in moves:
                new_score = int(move["score"])
                if new_score > int(initial_score) + int(max_uphill):
                    continue
                new_blocks = move["blocks"]
                new_pair = pair_loss0123(p, new_blocks, lam)
                new_obj = float(new_score) + float(alpha) * float(new_pair)
                uphill_step = int(new_score) > int(state["score"])
                any_uphill = any_uphill or uphill_step
                accepted_count += 1
                new_state = {
                    "blocks": new_blocks,
                    "score": int(new_score),
                    "objective": float(new_obj),
                    "path": list(state["path"]) + [{"depth": depth, "score": int(new_score), "pair_loss": int(new_pair), "plan": move["plan"]}],
                    "worst_intermediate_score": max(int(state["worst_intermediate_score"]), int(new_score)),
                    "accepted_uphill_steps": int(state["accepted_uphill_steps"]) + (1 if uphill_step else 0),
                    "max_uphill_used": max(int(state["max_uphill_used"]), int(new_score) - int(initial_score)),
                    "used_radius": int(state.get("used_radius", 0)) + int(move["radius"]),
                }
                next_states.append(new_state)
                if int(new_score) < int(best["score"]):
                    best = dict(new_state)
        if timeout:
            failure_mode = "timeout"
            break
        if not next_states:
            failure_mode = "no_candidate_in_pool" if total_eval == 0 else "only_uphill_paths_found"
            break
        next_states.sort(key=lambda r: (float(r["objective"]), int(r["score"]), int(r["accepted_uphill_steps"])))
        beam = next_states[: int(args.beam_width)]
        progress(
            args,
            "lns-depth op={} depth={} beam={} accepted={} best={} elapsed_ms={}".format(
                op,
                depth,
                len(beam),
                accepted_count,
                int(best["score"]),
                int(round((time.time() - started) * 1000.0)),
            ),
        )
    if best["score"] < initial_score:
        failure_mode = "score_improved_pair_not" if pair_loss0123(p, best["blocks"], lam) >= initial_pair else "improved"
    elif pair_loss0123(p, best["blocks"], lam) < initial_pair:
        failure_mode = "pair_residual_improved_score_not"
    elif failure_mode == "unknown":
        failure_mode = "uphill_found_but_no_final_improvement" if any_uphill else "exact_joint_damage"
    elapsed_ms = int(round((time.time() - started) * 1000.0))
    return {
        "blocks_after": [set(block) for block in best["blocks"]],
        "score_after": int(best["score"]),
        "best_intermediate_score": int(best["score"]),
        "worst_intermediate_score": int(best["worst_intermediate_score"]),
        "steps_used": len(best["path"]),
        "evaluated_moves_count": int(total_eval),
        "exact_joint_evaluations_count": int(exact_eval),
        "wall_time_ms": int(elapsed_ms),
        "timeout": bool(timeout),
        "accepted_uphill_steps": int(best["accepted_uphill_steps"]),
        "max_uphill_used": int(best["max_uphill_used"]),
        "path": best["path"],
        "failure_mode": failure_mode,
        "L_pair0123_before": int(initial_pair),
        "L_pair0123_after": int(pair_loss0123(p, best["blocks"], lam)),
    }


def score_only_baseline(p, blocks, lam, seed, args):
    repair_args = argparse.Namespace(
        max_repair_steps=int(args.baseline_repair_steps),
        pool_size=int(args.pool_size),
        lns_pool_size=int(args.pool_size),
        lns_radius=1,
        beam_width=1,
        eval_cap_per_step=int(args.eval_cap_per_attempt),
        max_wall_time_ms=int(args.max_wall_time_ms),
    )
    result = base.repair_candidate_with_operator(p, blocks, lam, "score_only_1swap_greedy", seed, repair_args)
    before = base.P37.score_blocks(p, blocks, lam)
    return {
        "blocks_after": result["blocks_after"],
        "score_after": int(result["score_after"]),
        "best_intermediate_score": int(result["best_intermediate_score"]),
        "worst_intermediate_score": int(before),
        "steps_used": int(result["steps_used"]),
        "evaluated_moves_count": int(result["evaluated_moves_count"]),
        "exact_joint_evaluations_count": int(result["exact_joint_evaluations_count"]),
        "wall_time_ms": int(result["wall_time_ms"]),
        "timeout": bool(result["timeout_flag"]),
        "accepted_uphill_steps": 0,
        "max_uphill_used": 0,
        "path": [],
        "failure_mode": "improved" if int(result["score_after"]) < int(before) else "no_candidate_in_pool",
        "L_pair0123_before": int(pair_loss0123(p, blocks, lam)),
        "L_pair0123_after": int(pair_loss0123(p, result["blocks_after"], lam)),
    }


def uphill_then_repair(p, blocks, lam, alpha, max_uphill, radius, seed, args):
    first_args = argparse.Namespace(**vars(args))
    first_args.beam_width = max(1, min(int(args.beam_width), int(args.uphill_stage_beam_width)))
    first_args.eval_cap_per_attempt = max(1, int(args.eval_cap_per_attempt) // 2)
    first_args.max_wall_time_ms = max(1, int(args.max_wall_time_ms) // 2)
    first = nonmonotone_pair_lns(p, blocks, lam, "O5", alpha, max_uphill, radius, seed, first_args)
    repair_args = argparse.Namespace(
        max_repair_steps=int(args.post_uphill_repair_steps),
        pool_size=int(args.pool_size),
        lns_pool_size=int(args.pool_size),
        lns_radius=1,
        beam_width=1,
        eval_cap_per_step=int(args.eval_cap_per_attempt),
        max_wall_time_ms=max(1, int(args.max_wall_time_ms) - int(first["wall_time_ms"])),
    )
    second = base.repair_candidate_with_operator(p, first["blocks_after"], lam, "score_only_1swap_greedy", seed + 17, repair_args)
    after_blocks = second["blocks_after"]
    after_score = int(second["score_after"])
    before = base.P37.score_blocks(p, blocks, lam)
    failure = "improved" if after_score < before else first["failure_mode"]
    return {
        **first,
        "blocks_after": after_blocks,
        "score_after": after_score,
        "best_intermediate_score": min(int(first["best_intermediate_score"]), int(second["best_intermediate_score"])),
        "worst_intermediate_score": max(int(first["worst_intermediate_score"]), int(before)),
        "steps_used": int(first["steps_used"]) + int(second["steps_used"]),
        "evaluated_moves_count": int(first["evaluated_moves_count"]) + int(second["evaluated_moves_count"]),
        "exact_joint_evaluations_count": int(first["exact_joint_evaluations_count"]) + int(second["exact_joint_evaluations_count"]),
        "wall_time_ms": int(first["wall_time_ms"]) + int(second["wall_time_ms"]),
        "timeout": bool(first["timeout"] or second["timeout_flag"]),
        "failure_mode": failure,
        "L_pair0123_after": int(pair_loss0123(p, after_blocks, lam)),
    }


def restricted_dmin(p, blocks, lam, radii, args, seed):
    if int(args.dmin_sample_count) <= 0:
        return None, 0
    return base.restricted_dmin_score(p, blocks, lam, radii, int(args.dmin_sample_count), int(seed))


def build_repair_row(candidate, op, alpha, max_uphill, radius, restart, args):
    p = int(args.p)
    blocks = [set(block) for block in candidate["blocks"]]
    lam = int(candidate["lambda"])
    seed = (
        int(args.base_seed)
        + int(args.shard_id) * 10000000
        + stable_int(candidate["candidate_hash"]) % 1000000
        + stable_int(op) % 100000
        + int(restart) * 1009
        + int(max_uphill) * 17
        + int(round(float(alpha) * 1000.0))
    )
    before = base.P37.score_blocks(p, blocks, lam)
    if op == "O0":
        result = score_only_baseline(p, blocks, lam, seed, args)
    elif op == "O5":
        result = uphill_then_repair(p, blocks, lam, alpha, max_uphill, radius, seed, args)
    else:
        result = nonmonotone_pair_lns(p, blocks, lam, op, alpha, max_uphill, radius, seed, args)
    after = int(result["score_after"])
    d2, _ = restricted_dmin(p, result["blocks_after"], lam, [1, 2], args, seed + 202)
    d3, _ = restricted_dmin(p, result["blocks_after"], lam, [1, 2, 3], args, seed + 303)
    d5, _ = restricted_dmin(p, result["blocks_after"], lam, [1, 2, 3, 4, 5], args, seed + 505)
    d7, _ = restricted_dmin(p, result["blocks_after"], lam, [1, 2, 3, 4, 5, 6, 7], args, seed + 707)
    row = {
        "run_id": args.run_id,
        "shard_id": int(args.shard_id),
        "lns_candidate_id": candidate["lns_candidate_id"],
        "source_file": candidate.get("source_file", ""),
        "source_fixture": candidate.get("source_fixture", ""),
        "source_run": candidate.get("source_run", ""),
        "tuple_class": candidate["tuple_class"],
        "wall_role": candidate.get("wall_role", ""),
        "frontier_bucket": candidate.get("frontier_bucket", ""),
        "initial_score": int(candidate["score"]),
        "lambda": int(lam),
        "ks": candidate["ks"],
        "operator": op,
        "operator_name": operator_name(op),
        "alpha": float(alpha),
        "max_uphill": int(max_uphill),
        "radius": int(radius),
        "restart_id": int(restart),
        "repair_seed": int(seed),
        "score_before": int(before),
        "score_after": int(after),
        "score_improvement": int(before) - int(after),
        "improvement_rate": float(int(before) - int(after)) / float(max(1, int(before))),
        "best_intermediate_score": int(result["best_intermediate_score"]),
        "worst_intermediate_score": int(result["worst_intermediate_score"]),
        "max_uphill_used": int(result["max_uphill_used"]),
        "accepted_uphill_steps": int(result["accepted_uphill_steps"]),
        "final_improved": bool(after < int(before)),
        "score0": bool(after == 0),
        "exact_joint_evaluations": int(result["exact_joint_evaluations_count"]),
        "evaluated_moves_count": int(result["evaluated_moves_count"]),
        "wall_time_ms": int(result["wall_time_ms"]),
        "timeout": bool(result["timeout"]),
        "L_pair0123_before": int(result["L_pair0123_before"]),
        "L_pair0123_after": int(result["L_pair0123_after"]),
        "L_pair0123_improvement": int(result["L_pair0123_before"]) - int(result["L_pair0123_after"]),
        "score_improved_while_L_pair_worsened": bool(after < int(before) and int(result["L_pair0123_after"]) > int(result["L_pair0123_before"])),
        "L_pair_improved_while_score_worsened": bool(after > int(before) and int(result["L_pair0123_after"]) < int(result["L_pair0123_before"])),
        "D_min_1_full_score": None,
        "D_min_2_restricted_score": d2,
        "D_min_3_restricted_score": d3,
        "D_min_5_restricted_score": d5,
        "D_min_7_restricted_score": d7,
        "failure_mode": result["failure_mode"],
        "candidate_hash_before": candidate["candidate_hash"],
        "candidate_hash_after": candidate_hash(result["blocks_after"]),
        "candidate_json_path_if_saved": "",
        "blocks_after": [[int(x) for x in sorted(block)] for block in result["blocks_after"]],
        "path": result.get("path", []),
    }
    for threshold in THRESHOLDS:
        row["score_after_le_{}".format(threshold)] = bool(after <= threshold)
    return row


def task_label(task):
    cand, op, alpha, max_uphill, radius, restart = task
    return "{} {} {} alpha={} uphill={} r={} restart={}".format(
        cand["lns_candidate_id"], cand["tuple_class"], op, alpha, max_uphill, radius, restart
    )


def run_mode(args):
    ensure_dir(args.out_dir)
    candidates = load_candidates(args)
    tasks = shard_tasks(candidates, args)
    if args.smoke:
        tasks = tasks[: max(1, int(args.smoke_task_limit))]
    progress(
        args,
        "shard-start shard={}/{} selected_candidates={} task_count={} out_dir={}".format(
            args.shard_id, args.shard_count, len(candidates), len(tasks), args.out_dir
        ),
    )
    rows = []
    for idx, task in enumerate(tasks, 1):
        pct = 100.0 * float(idx - 1) / float(max(1, len(tasks)))
        progress(args, "task-start {}/{} {:.1f}% {}".format(idx, len(tasks), pct, task_label(task)))
        rows.append(build_repair_row(*task, args))
        progress(args, "task-done {}/{} score_after={}".format(idx, len(tasks), rows[-1]["score_after"]))
    write_outputs(args, rows, candidates, args.out_dir)
    print("wrote {} repair rows to {}".format(len(rows), args.out_dir))


def summarize_group(rows, keys):
    buckets = {}
    for row in rows:
        key = tuple(row.get(k) for k in keys)
        buckets.setdefault(key, []).append(row)
    out = []
    for key, group in sorted(buckets.items(), key=lambda item: item[0]):
        summary = {keys[idx]: key[idx] for idx in range(len(keys))}
        before = [int(row["score_before"]) for row in group]
        after = [int(row["score_after"]) for row in group]
        improvements = [int(row["score_improvement"]) for row in group]
        summary["candidate_count"] = len(group)
        summary["best_score_before"] = min(before) if before else None
        summary["best_score_after"] = min(after) if after else None
        summary["median_score_before"] = median(before)
        summary["median_score_after"] = median(after)
        summary["median_score_improvement"] = median(improvements)
        summary["q75_score_improvement"] = quantile(improvements, 0.75)
        summary["q90_score_improvement"] = quantile(improvements, 0.90)
        summary["improvement_rate"] = rate(group, lambda row: int(row["score_after"]) < int(row["score_before"]))
        summary["accepted_uphill_rate"] = rate(group, lambda row: int(row.get("accepted_uphill_steps") or 0) > 0)
        summary["median_max_uphill_used"] = median(row.get("max_uphill_used") for row in group)
        for threshold in THRESHOLDS:
            summary["score_after_le_{}_count".format(threshold)] = sum(1 for row in group if int(row["score_after"]) <= threshold)
            summary["score_after_le_{}_rate".format(threshold)] = rate(group, lambda row, t=threshold: int(row["score_after"]) <= t)
        summary["score0_count"] = sum(1 for row in group if int(row["score_after"]) == 0)
        summary["validated_score0_count"] = 0
        summary["wall_time_per_row_ms"] = median(row.get("wall_time_ms") for row in group)
        summary["timeout_rate"] = rate(group, lambda row: bool(row.get("timeout")))
        summary["same_compute_yield"] = (statistics.mean(improvements) if improvements else 0.0) / max(
            1.0, (summary["wall_time_per_row_ms"] or 0.0) / 1000.0
        )
        summary["failure_modes"] = dict(collections.Counter(row.get("failure_mode") for row in group))
        out.append(summary)
    return out


def candidate_selection_summary(candidates):
    rows = []
    for keys in (["tuple_class"], ["wall_role"], ["tuple_class", "wall_role"]):
        buckets = {}
        for row in candidates:
            buckets.setdefault(tuple(row.get(k) for k in keys), []).append(row)
        for key, group in sorted(buckets.items()):
            out = {"summary_scope": "+".join(keys)}
            for idx, name in enumerate(keys):
                out[name] = key[idx]
            out["candidate_count"] = len(group)
            out["best_score"] = min(int(row["score"]) for row in group)
            out["median_score"] = median(row["score"] for row in group)
            rows.append(out)
    return rows


def threshold_rows(rows, threshold):
    return [row for row in rows if int(row["score_after"]) <= int(threshold)]


def write_score0_candidates(out_dir, rows):
    score0_rows = [row for row in rows if int(row["score_after"]) == 0]
    for idx, row in enumerate(score0_rows):
        candidate = {
            "v": P_DEFAULT,
            "n": 4 * P_DEFAULT,
            "ks": [len(block) for block in row["blocks_after"]],
            "lambda": int(row["lambda"]),
            "blocks": row["blocks_after"],
        }
        path = os.path.join(out_dir, "score0_candidate_{:04d}.json".format(idx))
        write_json(path, candidate)
        row["candidate_json_path_if_saved"] = path
    write_jsonl(os.path.join(out_dir, "score0_candidates.jsonl"), score0_rows)
    return score0_rows


def best_candidate_rows(rows, limit=100):
    selected = {}
    for row in sorted(rows, key=lambda r: int(r["score_after"]))[:limit]:
        selected[(row["lns_candidate_id"], row["operator"], row["restart_id"], row["alpha"], row["max_uphill"])] = row
    for threshold in THRESHOLDS:
        for row in threshold_rows(rows, threshold):
            selected[(row["lns_candidate_id"], row["operator"], row["restart_id"], row["alpha"], row["max_uphill"])] = row
    return list(selected.values())


def decision(rows):
    core_improved = any(
        row["wall_role"] in {"core_c01_172", "core_c05_164", "core_c09_160", "core_c09_164", "core_c09_176"}
        and int(row["score_after"]) < int(row["score_before"])
        for row in rows
    )
    score160_under = any(int(row["score_after"]) < 160 for row in rows)
    score120_under = any(int(row["score_after"]) <= 120 for row in rows)
    nonmono_beats_baseline = False
    baseline_best = min([int(row["score_after"]) for row in rows if row["operator"] == "O0"] or [10**9])
    nonmono_best = min([int(row["score_after"]) for row in rows if row["operator"] != "O0"] or [10**9])
    if nonmono_best < baseline_best:
        nonmono_beats_baseline = True
    if core_improved or score160_under or score120_under or nonmono_beats_baseline:
        return "Strong GO"
    if any(int(row.get("accepted_uphill_steps") or 0) > 0 for row in rows):
        return "Weak GO"
    return "No GO"


def best_for(rows, tuple_class=None, wall_role=None):
    group = rows
    if tuple_class:
        group = [row for row in group if row["tuple_class"] == tuple_class]
    if wall_role:
        group = [row for row in group if row["wall_role"] == wall_role]
    if not group:
        return None
    return min(group, key=lambda row: int(row["score_after"]))


def markdown_table(rows, keys, limit=20):
    return base.markdown_table(rows, keys, limit=limit)


def write_case_studies(out_dir, rows):
    lines = [
        "# p167 fixed_01_23 non-monotone pair LNS case studies",
        "",
        "This is repair execution evidence, not a filter/classifier/reranker report.",
        "",
    ]
    interesting_roles = ["core_c01_172", "core_c05_164", "core_c09_160", "core_c09_164", "core_c09_176"]
    for role in interesting_roles:
        row = best_for(rows, wall_role=role)
        if not row:
            continue
        lines.extend(
            [
                "## {} {} {}".format(row["tuple_class"], role, row["lns_candidate_id"]),
                "",
                "- score_before: `{}`".format(row["score_before"]),
                "- score_after: `{}`".format(row["score_after"]),
                "- operator: `{}`".format(row["operator_name"]),
                "- alpha: `{}`".format(row["alpha"]),
                "- max_uphill: `{}`".format(row["max_uphill"]),
                "- radius: `{}`".format(row["radius"]),
                "- accepted_uphill_steps: `{}`".format(row["accepted_uphill_steps"]),
                "- failure_mode: `{}`".format(row["failure_mode"]),
                "- L_pair0123_before/after: `{}` / `{}`".format(row["L_pair0123_before"], row["L_pair0123_after"]),
                "",
            ]
        )
    with open(os.path.join(out_dir, "wall_candidate_case_studies.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def write_readme(out_dir, config, selection_summary, operator_summary, parameter_summary, rows):
    verdict = decision(rows)
    best = min(rows, key=lambda row: int(row["score_after"])) if rows else None
    c01 = best_for(rows, wall_role="core_c01_172")
    c05 = best_for(rows, wall_role="core_c05_164")
    c09_160 = best_for(rows, wall_role="core_c09_160")
    c09_164 = best_for(rows, wall_role="core_c09_164")
    c09_176 = best_for(rows, wall_role="core_c09_176")
    best_ops = sorted(operator_summary, key=lambda row: (int(row.get("best_score_after") or 10**9), -float(row.get("median_score_improvement") or 0.0)))
    best_params = sorted(parameter_summary, key=lambda row: (int(row.get("best_score_after") or 10**9), -float(row.get("median_score_improvement") or 0.0)))
    lines = [
        "# p167 fixed_01_23 non-monotone pair LNS",
        "",
        "This is a non-monotone repair execution run on existing p167 wall candidates. It is not a generator, filter, classifier, or reranker experiment.",
        "",
        "Fixed split:",
        "",
        "A(d) = n_X0(d) + n_X1(d)",
        "B(d) = lambda - n_X2(d) - n_X3(d)",
        "L_pair0123 = sum_{d != 0} (A(d)-B(d))^2",
        "",
        "Search objective:",
        "",
        "Obj = S + alpha L_pair0123",
        "",
        "Exact joint multi-swap update used for scoring:",
        "",
        "Delta n = h*f_tilde + f*h_tilde + h*h_tilde",
        "",
        "where h = 1_B - 1_R.",
        "",
        "## Run",
        "",
        "- run_id: `{}`".format(config["run_id"]),
        "- candidate_count: `{}`".format(config["candidate_count"]),
        "- repair_rows: `{}`".format(config["repair_rows"]),
        "- shard_count: `{}`".format(config["shard_count"]),
        "- best_score_after: `{}`".format(best["score_after"] if best else "none"),
        "- score0_count: `{}`".format(sum(1 for row in rows if int(row["score_after"]) == 0)),
        "- decision: `{}`".format(verdict),
        "",
        "## Candidate selection",
        "",
        markdown_table(selection_summary, ["summary_scope", "tuple_class", "wall_role", "candidate_count", "best_score", "median_score"], limit=40),
        "## Operator summary",
        "",
        markdown_table(best_ops, ["operator_name", "candidate_count", "best_score_after", "median_score_improvement", "improvement_rate", "accepted_uphill_rate", "timeout_rate"], limit=20),
        "## Best parameter rows",
        "",
        markdown_table(best_params, ["operator_name", "alpha", "max_uphill", "radius", "candidate_count", "best_score_after", "median_score_improvement", "accepted_uphill_rate"], limit=20),
        "## Required answers",
        "",
        "1. c01 172 improved: `{}` (best `{}`).".format(bool(c01 and int(c01["score_after"]) < int(c01["score_before"])), c01["score_after"] if c01 else "none"),
        "2. c05 164 improved: `{}` (best `{}`).".format(bool(c05 and int(c05["score_after"]) < int(c05["score_before"])), c05["score_after"] if c05 else "none"),
        "3. c09 160/164/176 improved: `{}` / `{}` / `{}`.".format(
            bool(c09_160 and int(c09_160["score_after"]) < int(c09_160["score_before"])),
            bool(c09_164 and int(c09_164["score_after"]) < int(c09_164["score_before"])),
            bool(c09_176 and int(c09_176["score_after"]) < int(c09_176["score_before"])),
        ),
        "4. fixed_01_23 non-monotone LNS vs baseline is summarized in `operator_summary.csv`.",
        "5. max_uphill comparison is in `parameter_summary.csv`.",
        "6. radius comparison is in `parameter_summary.csv`.",
        "7. pair-balanced LNS is operator `O4`.",
        "8. score/L_pair tradeoff columns are in `repair_rows.csv`.",
        "9. uphill intermediate evidence is `accepted_uphill_steps` and `max_uphill_used`.",
        "10. failure modes are in `repair_rows.csv` and summaries.",
        "11. score thresholds <=200/180/160/120/100 counts are in threshold artifacts.",
        "12. CP-SAT local branching remains optional; use it only if this run shows uphill-local evidence.",
        "13. fixed_01_23 continuation verdict: `{}`.".format(verdict),
        "",
        "## Notes",
        "",
        "- score0, if present, is only a candidate until Sage verifies SDS and HH^T = 668I.",
        "- This run does not claim a Hadamard 668 construction.",
        "- D_min r>=2 columns are restricted sampled proxies unless explicitly marked full.",
    ]
    with open(os.path.join(out_dir, "README.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(out_dir, "next_actions.md"), "w") as f:
        f.write(
            "# next actions\n\n"
            "- If any core wall improves, expand that operator/alpha/uphill neighborhood first.\n"
            "- If uphill states are accepted but no final improvement appears, move to explicit local branching/CP-SAT with bounded uphill.\n"
            "- If all rows stay unchanged, fixed_01_23 guidance alone is not enough; redesign pools or allow coordinated multi-block constraints.\n"
        )


REPAIR_FIELDS = [
    "run_id",
    "shard_id",
    "lns_candidate_id",
    "source_file",
    "source_fixture",
    "source_run",
    "tuple_class",
    "wall_role",
    "frontier_bucket",
    "initial_score",
    "lambda",
    "ks",
    "operator",
    "operator_name",
    "alpha",
    "max_uphill",
    "radius",
    "restart_id",
    "repair_seed",
    "score_before",
    "score_after",
    "score_improvement",
    "improvement_rate",
    "best_intermediate_score",
    "worst_intermediate_score",
    "max_uphill_used",
    "accepted_uphill_steps",
    "final_improved",
] + ["score_after_le_{}".format(t) for t in THRESHOLDS] + [
    "score0",
    "exact_joint_evaluations",
    "evaluated_moves_count",
    "wall_time_ms",
    "timeout",
    "L_pair0123_before",
    "L_pair0123_after",
    "L_pair0123_improvement",
    "score_improved_while_L_pair_worsened",
    "L_pair_improved_while_score_worsened",
    "D_min_1_full_score",
    "D_min_2_restricted_score",
    "D_min_3_restricted_score",
    "D_min_5_restricted_score",
    "D_min_7_restricted_score",
    "failure_mode",
    "candidate_hash_before",
    "candidate_hash_after",
    "candidate_json_path_if_saved",
]


def write_outputs(args, rows, candidates, out_dir):
    ensure_dir(out_dir)
    selection_summary = candidate_selection_summary(candidates)
    operator_summary = summarize_group(rows, ["operator_name"])
    parameter_summary = summarize_group(rows, ["operator_name", "alpha", "max_uphill", "radius"])
    candidate_operator_summary = summarize_group(rows, ["lns_candidate_id", "tuple_class", "wall_role", "operator_name"])
    score0_rows = write_score0_candidates(out_dir, rows)
    config = {
        "run_id": args.run_id,
        "experiment_name": args.experiment_name,
        "p": int(args.p),
        "candidate_count": len(candidates),
        "repair_rows": len(rows),
        "operators": parse_csv(args.operators),
        "alpha_values": parse_csv(args.alpha_values, float),
        "max_uphill_values": parse_csv(args.max_uphill_values, int),
        "pool_size": int(args.pool_size),
        "beam_width": int(args.beam_width),
        "eval_cap_per_attempt": int(args.eval_cap_per_attempt),
        "max_wall_time_ms": int(args.max_wall_time_ms),
        "shard_id": int(args.shard_id),
        "shard_count": int(args.shard_count),
    }
    write_json(os.path.join(out_dir, "run_config.json"), config)
    write_json(os.path.join(out_dir, "validation_report.json"), {"score0_candidates": len(score0_rows), "validated_score0_count": 0})
    write_jsonl(os.path.join(out_dir, "candidate_list.jsonl"), candidates)
    write_csv(os.path.join(out_dir, "candidate_selection_summary.csv"), selection_summary, sorted({k for row in selection_summary for k in row}))
    write_jsonl(os.path.join(out_dir, "repair_rows.jsonl"), rows)
    write_csv(os.path.join(out_dir, "repair_rows.csv"), rows, REPAIR_FIELDS)
    write_csv(os.path.join(out_dir, "operator_summary.csv"), operator_summary, sorted({k for row in operator_summary for k in row}))
    write_csv(os.path.join(out_dir, "parameter_summary.csv"), parameter_summary, sorted({k for row in parameter_summary for k in row}))
    write_csv(os.path.join(out_dir, "candidate_operator_summary.csv"), candidate_operator_summary, sorted({k for row in candidate_operator_summary for k in row}))
    write_case_studies(out_dir, rows)
    for threshold in THRESHOLDS:
        write_jsonl(os.path.join(out_dir, "score_under_{}_candidates.jsonl".format(threshold)), threshold_rows(rows, threshold))
    write_readme(out_dir, config, selection_summary, operator_summary, parameter_summary, rows)


def aggregate_mode(args):
    rows = []
    by_hash = {}
    for path in Path(args.aggregate_input_dir).rglob("repair_rows.jsonl"):
        rows.extend(read_jsonl(str(path)))
    for path in Path(args.aggregate_input_dir).rglob("candidate_list.jsonl"):
        for row in read_jsonl(str(path)):
            by_hash[row["candidate_hash"]] = row
    candidates = list(by_hash.values())
    write_outputs(args, rows, candidates, args.out_dir)
    print("aggregated {} rows to {}".format(len(rows), args.out_dir))


def parse_args():
    parser = argparse.ArgumentParser(description="p167 fixed_01_23 non-monotone pair-level LNS repair.")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--frontier-files", default=FRONTIER_FILES_DEFAULT)
    parser.add_argument("--tuple-registry", default=base.TUPLE_REGISTRY_DEFAULT)
    parser.add_argument("--tuple-classes", default=TUPLE_CLASSES_DEFAULT)
    parser.add_argument("--candidate-count", type=int, default=40)
    parser.add_argument("--operators", default=",".join(OPERATORS_DEFAULT))
    parser.add_argument("--alpha-values", default="0.0,0.1,0.25")
    parser.add_argument("--max-uphill-values", default="32,64,128")
    parser.add_argument("--restarts-per-candidate-operator", type=int, default=2)
    parser.add_argument("--pool-size", type=int, default=48)
    parser.add_argument("--beam-width", type=int, default=24)
    parser.add_argument("--eval-cap-per-attempt", type=int, default=3000)
    parser.add_argument("--max-wall-time-ms", type=int, default=90000)
    parser.add_argument("--dmin-sample-count", type=int, default=0)
    parser.add_argument("--baseline-repair-steps", type=int, default=16)
    parser.add_argument("--pair-balanced-radius", type=int, default=7)
    parser.add_argument("--uphill-then-repair-radius", type=int, default=5)
    parser.add_argument("--uphill-stage-beam-width", type=int, default=12)
    parser.add_argument("--post-uphill-repair-steps", type=int, default=8)
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--output-root", default=OUTPUT_ROOT_DEFAULT)
    parser.add_argument("--experiment-name", default=EXPERIMENT_DEFAULT)
    parser.add_argument("--run-id", default="")
    parser.add_argument("--base-seed", type=int, default=172123)
    parser.add_argument("--shard-id", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--smoke-task-limit", type=int, default=2)
    parser.add_argument("--progress-logging", dest="progress_logging", action="store_true", default=True)
    parser.add_argument("--no-progress-logging", dest="progress_logging", action="store_false")
    parser.add_argument("--aggregate", action="store_true")
    parser.add_argument("--aggregate-input-dir", default="")
    args = parser.parse_args()
    if not args.run_id:
        args.run_id = "{}-{}".format(args.experiment_name, now_stamp())
    if not args.out_dir:
        args.out_dir = os.path.join(args.output_root, args.run_id)
    return args


def main():
    args = parse_args()
    if args.aggregate:
        aggregate_mode(args)
    else:
        run_mode(args)


if __name__ == "__main__":
    main()
