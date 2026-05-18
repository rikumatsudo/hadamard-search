#!/usr/bin/env python3
import argparse
import itertools
import json
import math
import os
import random
import statistics
import time
from pathlib import Path

import p167_frontier_repair_benchmark as base
import p167_local_branching_wall_check as lb


P_DEFAULT = 167
FRONTIER_FIXTURE_DEFAULT = "configs/fixtures/p167_local_branching_wall_candidates.jsonl"
OUTPUT_ROOT_DEFAULT = "outputs/p167_multiblock_coordination_repair"
EXPERIMENT_DEFAULT = "p167_multiblock_coordination_repair"
TUPLE_CLASSES_DEFAULT = "p167_c01,p167_c05"
THRESHOLDS = (160, 120, 100)


def parse_csv(text, cast=str):
    if isinstance(text, (list, tuple)):
        return [cast(x) for x in text]
    return [cast(part.strip()) for part in str(text).split(",") if part.strip()]


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def ensure_dir(path):
    if path:
        os.makedirs(path, exist_ok=True)


def median(values):
    vals = [float(v) for v in values if v is not None]
    return statistics.median(vals) if vals else None


def mean(values):
    vals = [float(v) for v in values if v is not None]
    return statistics.mean(vals) if vals else None


def rate(rows, pred):
    return sum(1 for row in rows if pred(row)) / float(len(rows)) if rows else 0.0


def stable_int(text):
    return base.stable_int(text)


def sparse_delta(delta):
    return {int(d): int(v) for d, v in enumerate(delta) if int(d) != 0 and int(v) != 0}


def sparse_dot(a, b):
    return lb.sparse_dot(a, b)


def sparse_add_inplace(total, delta):
    return lb.sparse_add_inplace(total, delta)


def score_effect_from_delta(rho, delta):
    effect = 0
    for d in range(1, len(rho)):
        dv = int(delta[d])
        if dv:
            effect += 2 * int(rho[d]) * dv + dv * dv
    return int(effect)


def move_signature(move):
    return (
        int(move["block"]),
        int(move["radius"]),
        tuple(int(x) for x in move["removes"]),
        tuple(int(x) for x in move["adds"]),
    )


def build_pools(p, blocks, rho, pool_size, rng, mode):
    if mode in {"defect", "hybrid", "random"}:
        return lb.build_restricted_pools(p, blocks, rho, int(pool_size), rng, mode)
    if mode != "broad_hybrid":
        raise ValueError("unknown pool mode {}".format(mode))
    pools = []
    for block in blocks:
        block = set(int(x) for x in block)
        outside = [x for x in range(p) if x not in block]
        remove_scores = base.element_remove_scores(p, block, rho)
        add_scores = base.element_add_scores(p, block, rho)
        ranked_removes = [x for x, _ in sorted(remove_scores.items(), key=lambda item: (-item[1], item[0]))]
        ranked_adds = [x for x, _ in sorted(add_scores.items(), key=lambda item: (-item[1], item[0]))]
        targeted = max(1, int(math.ceil(int(pool_size) * 0.60)))
        removes = ranked_removes[:targeted]
        adds = ranked_adds[:targeted]
        remove_remaining = [x for x in block if x not in set(removes)]
        add_remaining = [x for x in outside if x not in set(adds)]
        rng.shuffle(remove_remaining)
        rng.shuffle(add_remaining)
        removes.extend(remove_remaining[: max(0, int(pool_size) - len(removes))])
        adds.extend(add_remaining[: max(0, int(pool_size) - len(adds))])
        pools.append((sorted(int(x) for x in removes), sorted(int(x) for x in adds)))
    return pools


def iter_joint_combos(removes, adds, radius, rng, cap):
    removes = list(removes)
    adds = list(adds)
    radius = int(radius)
    cap = int(cap)
    if radius <= 0 or len(removes) < radius or len(adds) < radius or cap <= 0:
        return
    total = math.comb(len(removes), radius) * math.comb(len(adds), radius)
    if total <= cap:
        for rcombo in itertools.combinations(removes, radius):
            for acombo in itertools.combinations(adds, radius):
                yield rcombo, acombo
        return
    seen = set()
    attempts = 0
    while len(seen) < cap and attempts < cap * 25:
        attempts += 1
        rcombo = tuple(sorted(rng.sample(removes, radius)))
        acombo = tuple(sorted(rng.sample(adds, radius)))
        key = (rcombo, acombo)
        if key in seen:
            continue
        seen.add(key)
        yield rcombo, acombo


def block_move_library(p, block, bidx, rho, current_score, removes, adds, block_radius, move_cap, combo_sample_cap, rng, started, max_wall_time_ms):
    zero = {
        "block": int(bidx),
        "radius": 0,
        "removes": [],
        "adds": [],
        "delta": {},
        "effect": 0,
        "score_if_alone": int(current_score),
    }
    moves = [zero]
    exact_evals = 0
    timed_out = False
    capped = False
    for radius in range(1, int(block_radius) + 1):
        radius_moves = []
        for rcombo, acombo in iter_joint_combos(removes, adds, radius, rng, int(combo_sample_cap)):
            if (time.time() - started) * 1000.0 >= float(max_wall_time_ms):
                timed_out = True
                break
            delta = base.exact_joint_delta_rho(p, block, rcombo, acombo)
            exact_evals += 1
            effect = score_effect_from_delta(rho, delta)
            radius_moves.append(
                {
                    "block": int(bidx),
                    "radius": int(radius),
                    "removes": [int(x) for x in rcombo],
                    "adds": [int(x) for x in acombo],
                    "delta": sparse_delta(delta),
                    "effect": int(effect),
                    "score_if_alone": int(current_score + effect),
                }
            )
            if len(radius_moves) > int(move_cap):
                capped = True
                radius_moves.sort(key=lambda row: (int(row["effect"]), int(row["radius"]), row["removes"], row["adds"]))
                radius_moves = radius_moves[: int(move_cap)]
        radius_moves.sort(key=lambda row: (int(row["effect"]), int(row["radius"]), row["removes"], row["adds"]))
        if len(radius_moves) > int(move_cap):
            capped = True
            radius_moves = radius_moves[: int(move_cap)]
        moves.extend(radius_moves)
        if timed_out:
            break
    nonzero = [move for move in moves if int(move["radius"]) > 0]
    nonzero.sort(key=lambda row: (int(row["effect"]), int(row["radius"]), row["removes"], row["adds"]))
    if len(nonzero) > int(move_cap):
        capped = True
        nonzero = nonzero[: int(move_cap)]
    return [zero] + nonzero, int(exact_evals), bool(capped), bool(timed_out)


def combine_moves(base_score, moves):
    total_effect = 0
    cross_term = 0
    individual_effect_sum = 0
    combined_delta = {}
    plan = []
    used_radius = 0
    blocks_used = []
    for move in moves:
        if int(move.get("radius", 0)) <= 0:
            continue
        cross = 2 * sparse_dot(combined_delta, move["delta"])
        cross_term += int(cross)
        individual_effect_sum += int(move["effect"])
        total_effect += int(move["effect"]) + int(cross)
        sparse_add_inplace(combined_delta, move["delta"])
        plan.append(move)
        used_radius += int(move["radius"])
        blocks_used.append(int(move["block"]))
    return {
        "score": int(base_score + total_effect),
        "effect": int(total_effect),
        "cross_term": int(cross_term),
        "individual_effect_sum": int(individual_effect_sum),
        "radius": int(used_radius),
        "blocks_used": sorted(blocks_used),
        "delta": combined_delta,
        "plan": [dict(move) for move in plan],
    }


def search_coordinated_moves(block_moves, base_score, coordination_order, max_total_radius, eval_cap, started, max_wall_time_ms):
    best = {
        "score": int(base_score),
        "effect": 0,
        "cross_term": 0,
        "individual_effect_sum": 0,
        "radius": 0,
        "blocks_used": [],
        "delta": {},
        "plan": [],
    }
    best_cross = dict(best)
    evaluations = 0
    capped = False
    timed_out = False
    order = int(coordination_order)
    for block_subset in itertools.combinations(range(len(block_moves)), order):
        move_lists = []
        for bidx in block_subset:
            nonzero = [move for move in block_moves[bidx] if int(move.get("radius", 0)) > 0]
            if not nonzero:
                move_lists = []
                break
            move_lists.append(nonzero)
        if not move_lists:
            continue
        for combo in itertools.product(*move_lists):
            if (time.time() - started) * 1000.0 >= float(max_wall_time_ms):
                timed_out = True
                break
            radius = sum(int(move["radius"]) for move in combo)
            if radius > int(max_total_radius):
                continue
            evaluations += 1
            state = combine_moves(base_score, combo)
            if int(state["score"]) < int(best["score"]):
                best = state
            if int(state["cross_term"]) < int(best_cross["cross_term"]):
                best_cross = state
            if evaluations >= int(eval_cap):
                capped = True
                break
        if timed_out or capped:
            break
    return best, best_cross, int(evaluations), bool(capped), bool(timed_out)


def apply_plan(blocks, plan):
    return lb.apply_plan(blocks, plan)


def task_key(candidate, pool_mode, pool_size, block_radius, coordination_order, restart_id):
    return "{}::{}::{}::{}::{}::{}".format(
        candidate["frontier_candidate_id"],
        pool_mode,
        pool_size,
        block_radius,
        coordination_order,
        restart_id,
    )


def shard_tasks(candidates, pool_modes, pool_sizes, block_radii, coordination_orders, restarts, shard_id, shard_count):
    tasks = []
    for candidate in candidates:
        for pool_mode in pool_modes:
            for pool_size in pool_sizes:
                for block_radius in block_radii:
                    for order in coordination_orders:
                        for restart_id in range(int(restarts)):
                            key = task_key(candidate, pool_mode, pool_size, block_radius, order, restart_id)
                            if stable_int(key) % int(shard_count) == int(shard_id):
                                tasks.append((candidate, pool_mode, pool_size, block_radius, order, restart_id))
    return tasks


def run_coordination_row(candidate, args, pool_mode, pool_size, block_radius, coordination_order, restart_id):
    p = int(args.p)
    blocks = [set(int(x) for x in block) for block in candidate["blocks"]]
    lam = int(candidate["lambda"])
    score_before = base.P37.score_blocks(p, blocks, lam)
    rho = base.rho_vector(p, blocks, lam)
    seed = (
        int(args.base_seed)
        + int(args.shard_id) * 10000000
        + stable_int(candidate["frontier_candidate_id"]) % 100000
        + stable_int(pool_mode) % 10000
        + int(pool_size) * 1000
        + int(block_radius) * 100
        + int(coordination_order) * 10
        + int(restart_id)
    )
    rng = random.Random(seed)
    started = time.time()
    pools = build_pools(p, blocks, rho, int(pool_size), rng, pool_mode)
    block_moves = []
    block_counts = {}
    exact_evals = 0
    block_capped = False
    timed_out = False
    for bidx, (removes, adds) in enumerate(pools):
        moves, evals, capped, timeout = block_move_library(
            p,
            blocks[bidx],
            bidx,
            rho,
            score_before,
            removes,
            adds,
            int(block_radius),
            int(args.move_cap_per_block),
            int(args.combo_sample_cap_per_block_radius),
            rng,
            started,
            int(args.max_wall_time_ms),
        )
        block_moves.append(moves)
        block_counts["b{}".format(bidx)] = len(moves)
        exact_evals += evals
        block_capped = block_capped or capped
        timed_out = timed_out or timeout
        if timed_out:
            break
    best_single = {"score": int(score_before), "effect": 0, "plan": [], "radius": 0}
    for moves in block_moves:
        for move in moves:
            if int(move["radius"]) > 0 and int(score_before + move["effect"]) < int(best_single["score"]):
                best_single = {
                    "score": int(score_before + move["effect"]),
                    "effect": int(move["effect"]),
                    "plan": [move],
                    "radius": int(move["radius"]),
                }
    if timed_out:
        best = combine_moves(score_before, [])
        best_cross = dict(best)
        combo_evals = 0
        combo_capped = False
        combo_timeout = True
    else:
        best, best_cross, combo_evals, combo_capped, combo_timeout = search_coordinated_moves(
            block_moves,
            score_before,
            int(coordination_order),
            int(args.max_total_radius),
            int(args.combination_eval_cap),
            started,
            int(args.max_wall_time_ms),
        )
    timed_out = bool(timed_out or combo_timeout)
    capped = bool(block_capped or combo_capped)
    cap_reason = []
    if block_capped:
        cap_reason.append("block_move_cap")
    if combo_capped:
        cap_reason.append("combination_eval_cap")
    if timed_out:
        cap_reason.append("wall_time_cap")
    after_blocks = apply_plan(blocks, best["plan"]) if best["plan"] else [set(block) for block in blocks]
    score_after = base.P37.score_blocks(p, after_blocks, lam)
    candidate_after = base.candidate_json(after_blocks, p, [len(block) for block in after_blocks], lam)
    elapsed_ms = int(round((time.time() - started) * 1000.0))
    individual_sum = int(best.get("individual_effect_sum", 0))
    cross_term = int(best.get("cross_term", 0))
    row = {
        "run_id": args.run_id,
        "shard_id": int(args.shard_id),
        "candidate_id": candidate["frontier_candidate_id"],
        "tuple_class": candidate["tuple_class"],
        "frontier_bucket": candidate.get("frontier_bucket", ""),
        "source_run": candidate.get("source_run", ""),
        "source_file": candidate.get("source_file", ""),
        "lambda": int(lam),
        "ks": [len(block) for block in blocks],
        "initial_score": int(candidate["initial_score"]),
        "candidate_hash_before": candidate["canonical_hash_before"],
        "pool_mode": pool_mode,
        "pool_size": int(pool_size),
        "block_radius": int(block_radius),
        "coordination_order": int(coordination_order),
        "max_total_radius": int(args.max_total_radius),
        "restart_id": int(restart_id),
        "seed": int(seed),
        "score_before": int(score_before),
        "best_single_block_score": int(best_single["score"]),
        "best_single_block_delta": int(best_single["effect"]),
        "best_multi_block_score": int(best["score"]),
        "best_multi_block_delta": int(best["effect"]),
        "score_after": int(score_after),
        "score_improvement": int(score_before) - int(best["score"]),
        "single_block_improved": bool(int(best_single["score"]) < int(score_before)),
        "multi_block_improved": bool(int(best["score"]) < int(score_before)),
        "coordination_gain": int(best_single["effect"]) - int(best["effect"]),
        "individual_effect_sum": int(individual_sum),
        "cross_term": int(cross_term),
        "negative_cross_gain": int(-cross_term),
        "best_cross_term": int(best_cross.get("cross_term", 0)),
        "best_cross_term_score": int(best_cross.get("score", score_before)),
        "best_cross_term_effect": int(best_cross.get("effect", 0)),
        "blocks_used": best.get("blocks_used", []),
        "best_plan_radius": int(best.get("radius", 0)),
        "best_plan_json": [
            {
                "block": int(move["block"]),
                "radius": int(move["radius"]),
                "removes": [int(x) for x in move["removes"]],
                "adds": [int(x) for x in move["adds"]],
                "effect_if_alone": int(move["effect"]),
            }
            for move in best["plan"]
        ],
        "block_move_counts": block_counts,
        "block_move_count": sum(int(v) for v in block_counts.values()),
        "combination_evaluations": int(combo_evals),
        "exact_joint_evaluations": int(exact_evals),
        "search_complete": not bool(cap_reason),
        "cap_reason": ",".join(cap_reason),
        "wall_time_ms": int(elapsed_ms),
        "candidate_hash_after": base.canonical_hash(after_blocks),
        "blocks_after": candidate_after["blocks"],
    }
    for threshold in THRESHOLDS:
        row["score_after_le_{}".format(threshold)] = bool(int(best["score"]) <= int(threshold))
    return row


def summarize_group(rows, keys):
    buckets = {}
    for row in rows:
        key = tuple(row.get(k) for k in keys)
        buckets.setdefault(key, []).append(row)
    out = []
    for key, group in sorted(buckets.items(), key=lambda item: item[0]):
        summary = {keys[i]: key[i] for i in range(len(keys))}
        best_scores = [int(row["best_multi_block_score"]) for row in group]
        improvements = [int(row["score_improvement"]) for row in group]
        cross_gains = [int(row["negative_cross_gain"]) for row in group]
        summary["row_count"] = len(group)
        summary["best_score"] = min(best_scores) if best_scores else None
        summary["median_best_score"] = median(best_scores)
        summary["best_improvement"] = max(improvements) if improvements else None
        summary["median_improvement"] = median(improvements)
        summary["multi_block_improvement_rate"] = rate(group, lambda row: bool(row.get("multi_block_improved")))
        summary["single_block_improvement_rate"] = rate(group, lambda row: bool(row.get("single_block_improved")))
        summary["coordination_only_improvement_count"] = sum(
            1 for row in group if bool(row.get("multi_block_improved")) and not bool(row.get("single_block_improved"))
        )
        summary["best_negative_cross_gain"] = max(cross_gains) if cross_gains else None
        summary["median_negative_cross_gain"] = median(cross_gains)
        summary["search_complete_rate"] = rate(group, lambda row: bool(row.get("search_complete")))
        summary["wall_time_ms_median"] = median(row.get("wall_time_ms") for row in group)
        summary["combination_evaluations_median"] = median(row.get("combination_evaluations") for row in group)
        summary["exact_joint_evaluations_median"] = median(row.get("exact_joint_evaluations") for row in group)
        for threshold in THRESHOLDS:
            summary["score_after_le_{}_count".format(threshold)] = sum(1 for row in group if int(row["best_multi_block_score"]) <= threshold)
            summary["score_after_le_{}_rate".format(threshold)] = rate(group, lambda row, t=threshold: int(row["best_multi_block_score"]) <= t)
        out.append(summary)
    return out


def best_rows(rows, limit=100):
    return sorted(
        rows,
        key=lambda row: (
            int(row["best_multi_block_score"]),
            -int(row["score_improvement"]),
            -int(row["negative_cross_gain"]),
            int(row["wall_time_ms"]),
        ),
    )[:limit]


def threshold_rows(rows, threshold):
    return [row for row in rows if int(row["best_multi_block_score"]) <= int(threshold)]


ROW_FIELDS = [
    "run_id",
    "shard_id",
    "candidate_id",
    "tuple_class",
    "frontier_bucket",
    "source_run",
    "source_file",
    "lambda",
    "ks",
    "initial_score",
    "candidate_hash_before",
    "pool_mode",
    "pool_size",
    "block_radius",
    "coordination_order",
    "max_total_radius",
    "restart_id",
    "seed",
    "score_before",
    "best_single_block_score",
    "best_single_block_delta",
    "best_multi_block_score",
    "best_multi_block_delta",
    "score_after",
    "score_improvement",
    "single_block_improved",
    "multi_block_improved",
    "coordination_gain",
    "individual_effect_sum",
    "cross_term",
    "negative_cross_gain",
    "best_cross_term",
    "best_cross_term_score",
    "best_cross_term_effect",
    "blocks_used",
    "best_plan_radius",
    "best_plan_json",
    "block_move_counts",
    "block_move_count",
    "combination_evaluations",
    "exact_joint_evaluations",
    "search_complete",
    "cap_reason",
    "wall_time_ms",
    "candidate_hash_after",
] + ["score_after_le_{}".format(t) for t in THRESHOLDS]


def write_readme(out_dir, config, rows, candidate_summary, parameter_summary):
    best = best_rows(rows, 10)
    c01 = [row for row in rows if row.get("tuple_class") == "p167_c01"]
    c05 = [row for row in rows if row.get("tuple_class") == "p167_c05"]
    coord_only = [row for row in rows if row.get("multi_block_improved") and not row.get("single_block_improved")]
    lines = [
        "# p167 multiblock coordination repair",
        "",
        "This is a repair/diagnostic experiment on existing p167 wall candidates. It is not a generator, filter, classifier, or reranker experiment.",
        "",
        "The score model explicitly includes cross-block coordination. For per-block exact-joint deltas `delta_i`,",
        "",
        "`Delta S_total = sum_i Delta S_i + 2 * sum_{i<j} <delta_i, delta_j>`",
        "",
        "where each block move uses the exact joint update `Delta n = h*f_tilde + f*h_tilde + h*h_tilde`.",
        "",
        "## Run",
        "",
        "- run_id: `{}`".format(config["run_id"]),
        "- candidate_count: `{}`".format(config["candidate_count"]),
        "- row_count: `{}`".format(len(rows)),
        "- pool_modes: `{}`".format(config["pool_modes"]),
        "- pool_size_list: `{}`".format(config["pool_size_list"]),
        "- block_radius_list: `{}`".format(config["block_radius_list"]),
        "- coordination_orders: `{}`".format(config["coordination_orders"]),
        "- restarts_per_cell: `{}`".format(config["restarts_per_cell"]),
        "",
        "## Direct Answers",
        "",
        "1. c01 wall improved: `{}`".format(any(int(row["best_multi_block_score"]) < int(row["score_before"]) for row in c01)),
        "2. c05 wall improved: `{}`".format(any(int(row["best_multi_block_score"]) < int(row["score_before"]) for row in c05)),
        "3. coordination-only improvement found: `{}`".format(bool(coord_only)),
        "4. score160 or below found: `{}`".format(any(int(row["best_multi_block_score"]) <= 160 for row in rows)),
        "5. score120 or below found: `{}`".format(any(int(row["best_multi_block_score"]) <= 120 for row in rows)),
        "6. score100 or below found: `{}`".format(any(int(row["best_multi_block_score"]) <= 100 for row in rows)),
        "7. any capped/partial rows: `{}`".format(any(not bool(row.get("search_complete")) for row in rows)),
        "",
        "## Best Rows",
        "",
        base.markdown_table(
            best,
            [
                "tuple_class",
                "candidate_id",
                "score_before",
                "best_multi_block_score",
                "score_improvement",
                "best_single_block_delta",
                "best_multi_block_delta",
                "coordination_gain",
                "negative_cross_gain",
                "pool_mode",
                "pool_size",
                "block_radius",
                "coordination_order",
                "search_complete",
                "cap_reason",
            ],
            limit=10,
        ),
        "",
        "## Candidate Summary",
        "",
        base.markdown_table(candidate_summary, ["tuple_class", "candidate_id", "row_count", "best_score", "median_best_score", "best_improvement", "multi_block_improvement_rate", "coordination_only_improvement_count", "best_negative_cross_gain"], limit=20),
        "",
        "## Parameter Summary",
        "",
        base.markdown_table(parameter_summary, ["pool_mode", "pool_size", "block_radius", "coordination_order", "row_count", "best_score", "median_best_score", "best_improvement", "multi_block_improvement_rate", "coordination_only_improvement_count", "best_negative_cross_gain"], limit=80),
        "",
        "## Interpretation Guide",
        "",
        "- `coordination_gain > 0` means the best multi-block plan beats the best single-block move in the same restricted pool.",
        "- `negative_cross_gain > 0` means cross-block terms helped the combined move.",
        "- `coordination_only_improvement_count > 0` is the strongest signal that explicit multi-block coordination is needed.",
        "",
    ]
    with open(os.path.join(out_dir, "README.md"), "w") as f:
        f.write("\n".join(lines))


def write_next_actions(out_dir, rows):
    best = best_rows(rows, 5)
    lines = [
        "# Next actions",
        "",
        "1. If a row improves c01/c05, rerun that exact pool/radius/order with higher move and combination caps.",
        "2. If no row improves but negative cross gains are large, redesign the pool to keep anti-aligned block moves rather than individually promising moves only.",
        "3. If coordination-only improvements appear, promote multi-block coordinated repair into the main frontier repair benchmark.",
        "4. If neither improvements nor cross gains appear, multi-block coordination is not enough in the current restricted pool.",
        "",
        "Best observed rows:",
        "",
        base.markdown_table(best, ["tuple_class", "candidate_id", "score_before", "best_multi_block_score", "score_improvement", "coordination_gain", "negative_cross_gain", "pool_mode", "pool_size", "block_radius", "coordination_order"], limit=5),
        "",
    ]
    with open(os.path.join(out_dir, "next_actions.md"), "w") as f:
        f.write("\n".join(lines))


def write_outputs(args, rows, candidates, out_dir):
    ensure_dir(out_dir)
    candidate_summary = summarize_group(rows, ["tuple_class", "candidate_id"])
    parameter_summary = summarize_group(rows, ["pool_mode", "pool_size", "block_radius", "coordination_order"])
    config = {
        "experiment_name": args.experiment_name,
        "run_id": args.run_id,
        "candidate_count": len(candidates),
        "row_count": len(rows),
        "frontier_files": args.frontier_files,
        "pool_modes": args.pool_modes,
        "pool_size_list": args.pool_size_list,
        "block_radius_list": args.block_radius_list,
        "coordination_orders": args.coordination_orders,
        "max_total_radius": int(args.max_total_radius),
        "restarts_per_cell": int(args.restarts_per_cell),
        "move_cap_per_block": int(args.move_cap_per_block),
        "combo_sample_cap_per_block_radius": int(args.combo_sample_cap_per_block_radius),
        "combination_eval_cap": int(args.combination_eval_cap),
        "max_wall_time_ms": int(args.max_wall_time_ms),
        "shard_id": int(args.shard_id),
        "shard_count": int(args.shard_count),
    }
    base.write_json(os.path.join(out_dir, "run_config.json"), config)
    base.write_jsonl(os.path.join(out_dir, "candidate_list.jsonl"), candidates)
    base.write_jsonl(os.path.join(out_dir, "coordination_rows.jsonl"), rows)
    base.write_csv(os.path.join(out_dir, "coordination_rows.csv"), rows, ROW_FIELDS)
    base.write_csv(os.path.join(out_dir, "candidate_summary.csv"), candidate_summary, sorted({k for row in candidate_summary for k in row}))
    base.write_csv(os.path.join(out_dir, "parameter_summary.csv"), parameter_summary, sorted({k for row in parameter_summary for k in row}))
    base.write_jsonl(os.path.join(out_dir, "best_coordinated_moves.jsonl"), best_rows(rows, 100))
    for threshold in THRESHOLDS:
        base.write_jsonl(os.path.join(out_dir, "score_under_{}_candidates.jsonl".format(threshold)), threshold_rows(rows, threshold))
    score0_rows = [row for row in rows if int(row["best_multi_block_score"]) == 0]
    score0_dir = os.path.join(out_dir, "score0_candidate_jsons")
    for idx, row in enumerate(score0_rows):
        ensure_dir(score0_dir)
        candidate = {
            "v": int(args.p),
            "n": int(4 * int(args.p)),
            "ks": row["ks"],
            "lambda": int(row["lambda"]),
            "blocks": row["blocks_after"],
        }
        base.write_json(os.path.join(score0_dir, "score0_{:04d}.json".format(idx)), candidate)
    base.write_jsonl(os.path.join(out_dir, "score0_candidates.jsonl"), score0_rows)
    base.write_json(
        os.path.join(out_dir, "validation_report.json"),
        {
            "score0_count": len(score0_rows),
            "validated_score0_count": 0,
            "note": "No Sage validation is required unless score0_count is nonzero. Workflow logs validate saved score0_candidate_jsons when present.",
        },
    )
    write_readme(out_dir, config, rows, candidate_summary, parameter_summary)
    write_next_actions(out_dir, rows)


def run_mode(args):
    candidates = base.load_frontier_candidates(args)
    pool_modes = parse_csv(args.pool_modes)
    pool_sizes = parse_csv(args.pool_size_list, int)
    block_radii = parse_csv(args.block_radius_list, int)
    coordination_orders = parse_csv(args.coordination_orders, int)
    tasks = shard_tasks(
        candidates,
        pool_modes,
        pool_sizes,
        block_radii,
        coordination_orders,
        int(args.restarts_per_cell),
        int(args.shard_id),
        int(args.shard_count),
    )
    if args.smoke:
        tasks = tasks[: max(1, int(args.smoke_task_limit))]
    print(
        "multiblock-coordination-start shard={}/{} candidates={} tasks={} pool_modes={} pool_sizes={} block_radii={} orders={}".format(
            args.shard_id,
            args.shard_count,
            len(candidates),
            len(tasks),
            pool_modes,
            pool_sizes,
            block_radii,
            coordination_orders,
        ),
        flush=True,
    )
    rows = []
    for idx, (candidate, pool_mode, pool_size, block_radius, order, restart_id) in enumerate(tasks, start=1):
        print(
            "task {}/{} candidate={} tuple={} score={} pool_mode={} pool_size={} block_radius={} order={} restart={}".format(
                idx,
                len(tasks),
                candidate["frontier_candidate_id"],
                candidate["tuple_class"],
                candidate["initial_score"],
                pool_mode,
                pool_size,
                block_radius,
                order,
                restart_id,
            ),
            flush=True,
        )
        rows.append(run_coordination_row(candidate, args, pool_mode, pool_size, block_radius, order, restart_id))
    write_outputs(args, rows, candidates, args.out_dir)
    print("wrote {} coordination rows to {}".format(len(rows), args.out_dir), flush=True)


def aggregate_mode(args):
    rows = []
    by_hash = {}
    for path in Path(args.aggregate_input_dir).rglob("coordination_rows.jsonl"):
        rows.extend(base.read_jsonl(str(path)))
    for path in Path(args.aggregate_input_dir).rglob("candidate_list.jsonl"):
        for row in base.read_jsonl(str(path)):
            by_hash[row["canonical_hash_before"]] = row
    candidates = list(by_hash.values())
    write_outputs(args, rows, candidates, args.out_dir)
    print("aggregated {} coordination rows to {}".format(len(rows), args.out_dir), flush=True)


def parse_args():
    parser = argparse.ArgumentParser(description="p167 multi-block coordination repair diagnostic.")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--frontier-files", default=FRONTIER_FIXTURE_DEFAULT)
    parser.add_argument("--tuple-registry", default=base.TUPLE_REGISTRY_DEFAULT)
    parser.add_argument("--tuple-classes", default=TUPLE_CLASSES_DEFAULT)
    parser.add_argument("--frontier-count", "--candidate-count", dest="frontier_count", type=int, default=2)
    parser.add_argument("--pool-modes", default="defect,hybrid")
    parser.add_argument("--pool-size-list", default="6,8,10")
    parser.add_argument("--block-radius-list", default="1,2")
    parser.add_argument("--coordination-orders", default="2,3,4")
    parser.add_argument("--max-total-radius", type=int, default=6)
    parser.add_argument("--restarts-per-cell", type=int, default=4)
    parser.add_argument("--move-cap-per-block", type=int, default=4000)
    parser.add_argument("--combo-sample-cap-per-block-radius", type=int, default=50000)
    parser.add_argument("--combination-eval-cap", type=int, default=2000000)
    parser.add_argument("--max-wall-time-ms", type=int, default=120000)
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--output-root", default=OUTPUT_ROOT_DEFAULT)
    parser.add_argument("--experiment-name", default=EXPERIMENT_DEFAULT)
    parser.add_argument("--run-id", default="")
    parser.add_argument("--base-seed", type=int, default=167431)
    parser.add_argument("--shard-id", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--smoke-task-limit", type=int, default=2)
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
