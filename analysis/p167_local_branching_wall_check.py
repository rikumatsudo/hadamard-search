#!/usr/bin/env python3
import argparse
import itertools
import json
import math
import os
import random
import statistics
import sys
import time
from pathlib import Path

import p167_frontier_repair_benchmark as base


P_DEFAULT = 167
FRONTIER_FIXTURE_DEFAULT = "configs/fixtures/p167_local_branching_wall_candidates.jsonl"
OUTPUT_ROOT_DEFAULT = "outputs/p167_local_branching_wall_check"
EXPERIMENT_DEFAULT = "p167_local_branching_wall_check"
TUPLE_CLASSES_DEFAULT = "p167_c01,p167_c05"
THRESHOLDS = (160, 120, 100)


def parse_csv(text, cast=str):
    if isinstance(text, (list, tuple)):
        return [cast(x) for x in text]
    return [cast(part.strip()) for part in str(text).split(",") if part.strip()]


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def stable_int(text):
    return base.stable_int(text)


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


def sparse_delta(delta):
    return {int(d): int(v) for d, v in enumerate(delta) if int(d) != 0 and int(v) != 0}


def sparse_dot(a, b):
    if len(a) > len(b):
        a, b = b, a
    total = 0
    for key, value in a.items():
        total += int(value) * int(b.get(key, 0))
    return int(total)


def sparse_add_inplace(total, delta):
    changed = []
    for key, value in delta.items():
        old = int(total.get(key, 0))
        new = old + int(value)
        if new:
            total[key] = new
        elif key in total:
            del total[key]
        changed.append((key, old))
    return changed


def sparse_rollback(total, changed):
    for key, old in reversed(changed):
        if old:
            total[key] = old
        elif key in total:
            del total[key]


def apply_plan(blocks, plan):
    out = [set(int(x) for x in block) for block in blocks]
    for move in plan:
        bidx = int(move["block"])
        for x in move.get("removes", []):
            out[bidx].remove(int(x))
        for x in move.get("adds", []):
            out[bidx].add(int(x))
    return out


def build_restricted_pools(p, blocks, rho, pool_size, rng, mode):
    pools = []
    pool_size = int(pool_size)
    for block in blocks:
        block = set(int(x) for x in block)
        outside = [x for x in range(p) if x not in block]
        remove_scores = base.element_remove_scores(p, block, rho)
        add_scores = base.element_add_scores(p, block, rho)
        ranked_removes = [x for x, _ in sorted(remove_scores.items(), key=lambda item: (-item[1], item[0]))]
        ranked_adds = [x for x, _ in sorted(add_scores.items(), key=lambda item: (-item[1], item[0]))]
        if mode == "random":
            removes = rng.sample(list(block), min(pool_size, len(block)))
            adds = rng.sample(outside, min(pool_size, len(outside)))
        elif mode == "hybrid":
            targeted = max(1, int(math.ceil(pool_size * 0.75)))
            removes = ranked_removes[:targeted]
            adds = ranked_adds[:targeted]
            remove_remaining = [x for x in block if x not in set(removes)]
            add_remaining = [x for x in outside if x not in set(adds)]
            rng.shuffle(remove_remaining)
            rng.shuffle(add_remaining)
            removes.extend(remove_remaining[: max(0, pool_size - len(removes))])
            adds.extend(add_remaining[: max(0, pool_size - len(adds))])
        else:
            removes = ranked_removes[:pool_size]
            adds = ranked_adds[:pool_size]
        pools.append((sorted(int(x) for x in removes), sorted(int(x) for x in adds)))
    return pools


def iter_joint_combos(removes, adds, radius):
    for rcombo in itertools.combinations(removes, radius):
        for acombo in itertools.combinations(adds, radius):
            yield rcombo, acombo


def build_block_moves(p, block, bidx, rho, current_score, removes, adds, max_radius, cap_per_radius, started, max_wall_time_ms):
    by_radius = {0: [{"block": int(bidx), "radius": 0, "removes": [], "adds": [], "delta": {}, "effect": 0, "score_if_alone": int(current_score)}]}
    exact_evals = 0
    capped = False
    timed_out = False
    for radius in range(1, int(max_radius) + 1):
        moves = []
        combo_count = 0
        for rcombo, acombo in iter_joint_combos(removes, adds, radius):
            if (time.time() - started) * 1000.0 >= float(max_wall_time_ms):
                timed_out = True
                break
            combo_count += 1
            delta = base.exact_joint_delta_rho(p, block, rcombo, acombo)
            exact_evals += 1
            effect = 0
            for d in range(1, p):
                dv = int(delta[d])
                if dv:
                    effect += 2 * int(rho[d]) * dv + dv * dv
            move = {
                "block": int(bidx),
                "radius": int(radius),
                "removes": [int(x) for x in rcombo],
                "adds": [int(x) for x in acombo],
                "delta": sparse_delta(delta),
                "effect": int(effect),
                "score_if_alone": int(current_score + effect),
            }
            moves.append(move)
            if len(moves) > int(cap_per_radius):
                capped = True
                # Keep the best individually promising moves. This makes the
                # branch search restricted-but-auditable rather than sampled.
                moves.sort(key=lambda row: (int(row["effect"]), row["block"], row["radius"], row["removes"], row["adds"]))
                moves = moves[: int(cap_per_radius)]
        if timed_out:
            break
        moves.sort(key=lambda row: (int(row["effect"]), row["block"], row["radius"], row["removes"], row["adds"]))
        by_radius[radius] = moves
    return by_radius, exact_evals, capped, timed_out


def flatten_block_moves(by_radius, max_radius):
    out = []
    for radius in range(0, int(max_radius) + 1):
        out.extend(by_radius.get(radius, []))
    out.sort(key=lambda row: (int(row["effect"]), row["block"], row["radius"], row["removes"], row["adds"]))
    return out


def search_local_branch(block_moves_by_block, base_score, radius, global_eval_cap, started, max_wall_time_ms):
    best = {
        "score": int(base_score),
        "effect": 0,
        "plan": [],
        "radius": 0,
        "delta": {},
    }
    evaluations = 0
    timed_out = False
    capped = False
    current_delta = {}
    current_plan = []

    def dfs(bidx, used_radius, current_effect):
        nonlocal evaluations, timed_out, capped, best
        if timed_out or capped:
            return
        if (time.time() - started) * 1000.0 >= float(max_wall_time_ms):
            timed_out = True
            return
        if bidx >= len(block_moves_by_block):
            evaluations += 1
            score = int(base_score + current_effect)
            if score < int(best["score"]):
                best = {
                    "score": int(score),
                    "effect": int(current_effect),
                    "plan": [dict(move) for move in current_plan if int(move.get("radius", 0)) > 0],
                    "radius": int(used_radius),
                    "delta": dict(current_delta),
                }
            if evaluations >= int(global_eval_cap):
                capped = True
            return
        remaining_blocks = len(block_moves_by_block) - bidx - 1
        for move in block_moves_by_block[bidx]:
            move_radius = int(move["radius"])
            if used_radius + move_radius > int(radius):
                continue
            # Keep at least zero moves available for remaining blocks; no
            # additional lower-bound pruning is applied, so a completed uncapped
            # run is exact within the selected move lists.
            if remaining_blocks < 0:
                continue
            cross = 2 * sparse_dot(current_delta, move["delta"])
            next_effect = int(current_effect) + int(move["effect"]) + int(cross)
            changed = sparse_add_inplace(current_delta, move["delta"])
            current_plan.append(move)
            dfs(bidx + 1, used_radius + move_radius, next_effect)
            current_plan.pop()
            sparse_rollback(current_delta, changed)
            if timed_out or capped:
                return

    dfs(0, 0, 0)
    return best, int(evaluations), bool(capped), bool(timed_out)


def exact_local_branching_check(candidate, args, pool_mode, pool_size, radius, restart_id):
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
        + int(pool_size) * 100
        + int(radius) * 10
        + int(restart_id)
    )
    rng = random.Random(seed)
    started = time.time()
    pools = build_restricted_pools(p, blocks, rho, int(pool_size), rng, pool_mode)
    block_moves = []
    block_counts = {}
    exact_evals = 0
    block_capped = False
    timed_out = False
    for bidx, (removes, adds) in enumerate(pools):
        by_radius, evals, capped, block_timeout = build_block_moves(
            p,
            blocks[bidx],
            bidx,
            rho,
            score_before,
            removes,
            adds,
            int(radius),
            int(args.block_candidate_cap_per_radius),
            started,
            float(args.max_wall_time_ms),
        )
        block_moves.append(flatten_block_moves(by_radius, int(radius)))
        for r, moves in by_radius.items():
            block_counts["b{}_r{}".format(bidx, r)] = len(moves)
        exact_evals += int(evals)
        block_capped = block_capped or bool(capped)
        timed_out = timed_out or bool(block_timeout)
        if timed_out:
            break
    if timed_out:
        best = {"score": int(score_before), "effect": 0, "plan": [], "radius": 0, "delta": {}}
        combination_evals = 0
        combo_capped = False
        combo_timeout = True
    else:
        best, combination_evals, combo_capped, combo_timeout = search_local_branch(
            block_moves,
            score_before,
            int(radius),
            int(args.global_eval_cap),
            started,
            float(args.max_wall_time_ms),
        )
    elapsed_ms = int(round((time.time() - started) * 1000.0))
    timed_out = bool(timed_out or combo_timeout)
    capped = bool(block_capped or combo_capped)
    cap_reason = []
    if block_capped:
        cap_reason.append("block_candidate_cap")
    if combo_capped:
        cap_reason.append("global_eval_cap")
    if timed_out:
        cap_reason.append("wall_time_cap")
    search_complete = not cap_reason
    if best["plan"]:
        after_blocks = apply_plan(blocks, best["plan"])
    else:
        after_blocks = [set(block) for block in blocks]
    score_after = base.P37.score_blocks(p, after_blocks, lam)
    candidate_after = base.candidate_json(after_blocks, p, [len(block) for block in after_blocks], lam)
    row = {
        "run_id": args.run_id,
        "shard_id": int(args.shard_id),
        "candidate_id": candidate["frontier_candidate_id"],
        "tuple_class": candidate["tuple_class"],
        "source_run": candidate.get("source_run", ""),
        "source_file": candidate.get("source_file", ""),
        "frontier_bucket": candidate.get("frontier_bucket", ""),
        "lambda": int(lam),
        "ks": [len(block) for block in blocks],
        "initial_score": int(candidate["initial_score"]),
        "candidate_hash_before": candidate["canonical_hash_before"],
        "pool_mode": pool_mode,
        "pool_size": int(pool_size),
        "radius": int(radius),
        "restart_id": int(restart_id),
        "seed": int(seed),
        "block_candidate_cap_per_radius": int(args.block_candidate_cap_per_radius),
        "global_eval_cap": int(args.global_eval_cap),
        "score_before": int(score_before),
        "best_score": int(best["score"]),
        "score_after": int(score_after),
        "score_improvement": int(score_before) - int(best["score"]),
        "improved": bool(int(best["score"]) < int(score_before)),
        "score0": bool(int(best["score"]) == 0),
        "search_complete": bool(search_complete),
        "cap_reason": ",".join(cap_reason),
        "block_candidate_count": sum(len(moves) for moves in block_moves),
        "block_candidate_counts": block_counts,
        "combination_evaluations": int(combination_evals),
        "exact_joint_evaluations": int(exact_evals),
        "wall_time_ms": int(elapsed_ms),
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
        "best_plan_radius": int(best["radius"]),
        "candidate_hash_after": base.canonical_hash(after_blocks),
        "blocks_after": candidate_after["blocks"],
    }
    for threshold in THRESHOLDS:
        row["score_after_le_{}".format(threshold)] = bool(int(best["score"]) <= int(threshold))
    return row


def task_key(candidate, pool_mode, pool_size, radius, restart_id):
    return "{}::{}::{}::{}::{}".format(candidate["frontier_candidate_id"], pool_mode, pool_size, radius, restart_id)


def shard_tasks(candidates, pool_modes, pool_sizes, radii, restarts, shard_id, shard_count):
    tasks = []
    for candidate in candidates:
        for pool_mode in pool_modes:
            for pool_size in pool_sizes:
                for radius in radii:
                    for restart_id in range(int(restarts)):
                        key = task_key(candidate, pool_mode, pool_size, radius, restart_id)
                        if stable_int(key) % int(shard_count) == int(shard_id):
                            tasks.append((candidate, pool_mode, pool_size, radius, restart_id))
    return tasks


def summarize_group(rows, keys):
    buckets = {}
    for row in rows:
        key = tuple(row.get(k) for k in keys)
        buckets.setdefault(key, []).append(row)
    out = []
    for key, group in sorted(buckets.items(), key=lambda item: item[0]):
        summary = {keys[i]: key[i] for i in range(len(keys))}
        scores = [int(row["best_score"]) for row in group]
        improvements = [int(row["score_improvement"]) for row in group]
        summary["row_count"] = len(group)
        summary["best_score"] = min(scores) if scores else None
        summary["median_best_score"] = median(scores)
        summary["best_improvement"] = max(improvements) if improvements else None
        summary["median_improvement"] = median(improvements)
        summary["improvement_rate"] = rate(group, lambda row: bool(row.get("improved")))
        summary["score0_count"] = sum(1 for row in group if int(row["best_score"]) == 0)
        summary["search_complete_rate"] = rate(group, lambda row: bool(row.get("search_complete")))
        summary["timeout_or_cap_rate"] = rate(group, lambda row: not bool(row.get("search_complete")))
        summary["wall_time_ms_median"] = median(row.get("wall_time_ms") for row in group)
        summary["combination_evaluations_median"] = median(row.get("combination_evaluations") for row in group)
        summary["exact_joint_evaluations_median"] = median(row.get("exact_joint_evaluations") for row in group)
        for threshold in THRESHOLDS:
            summary["score_after_le_{}_count".format(threshold)] = sum(1 for row in group if int(row["best_score"]) <= threshold)
            summary["score_after_le_{}_rate".format(threshold)] = rate(group, lambda row, t=threshold: int(row["best_score"]) <= t)
        out.append(summary)
    return out


def best_rows(rows, limit=100):
    return sorted(rows, key=lambda row: (int(row["best_score"]), -int(row["score_improvement"]), int(row["wall_time_ms"])))[:limit]


def threshold_rows(rows, threshold):
    return [row for row in rows if int(row["best_score"]) <= int(threshold)]


def write_readme(out_dir, config, rows, candidate_summary, parameter_summary):
    best = best_rows(rows, 5)
    c01 = [row for row in rows if row.get("tuple_class") == "p167_c01"]
    c05 = [row for row in rows if row.get("tuple_class") == "p167_c05"]
    lines = [
        "# p167 local branching wall check",
        "",
        "This is a restricted local-branching repair diagnostic on existing p167 wall candidates. It is not a generator, filter, classifier, or reranker experiment.",
        "",
        "Multi-swap scoring uses exact joint updates. For block indicator `f` and `h = 1_B - 1_R`, `Delta n = h*f_tilde + f*h_tilde + h*h_tilde`.",
        "",
        "The local-branching radius is `sum_i |X_i triangle X_i0| / 2 <= r`. A completed row is exact within the selected restricted pool and retained block move lists; capped rows are partial restricted checks.",
        "",
        "## Run",
        "",
        "- run_id: `{}`".format(config["run_id"]),
        "- candidate_count: `{}`".format(config["candidate_count"]),
        "- row_count: `{}`".format(len(rows)),
        "- pool_modes: `{}`".format(config["pool_modes"]),
        "- pool_size_list: `{}`".format(config["pool_size_list"]),
        "- radius_list: `{}`".format(config["radius_list"]),
        "- restarts_per_cell: `{}`".format(config["restarts_per_cell"]),
        "",
        "## Direct Answers",
        "",
        "1. c01 168 improved: `{}`".format(any(int(row["best_score"]) < int(row["score_before"]) for row in c01)),
        "2. c05 164 improved: `{}`".format(any(int(row["best_score"]) < int(row["score_before"]) for row in c05)),
        "3. score160 or below found: `{}`".format(any(int(row["best_score"]) <= 160 for row in rows)),
        "4. score120 or below found: `{}`".format(any(int(row["best_score"]) <= 120 for row in rows)),
        "5. score100 or below found: `{}`".format(any(int(row["best_score"]) <= 100 for row in rows)),
        "6. any completed restricted proof of no improvement: `{}`".format(any(row.get("search_complete") and not row.get("improved") for row in rows)),
        "7. any capped/partial checks: `{}`".format(any(not row.get("search_complete") for row in rows)),
        "",
        "## Best Rows",
        "",
        base.markdown_table(
            best,
            ["tuple_class", "candidate_id", "score_before", "best_score", "score_improvement", "pool_mode", "pool_size", "radius", "search_complete", "cap_reason", "combination_evaluations", "wall_time_ms"],
            limit=10,
        ),
        "",
        "## Candidate Summary",
        "",
        base.markdown_table(candidate_summary, ["tuple_class", "candidate_id", "row_count", "best_score", "median_best_score", "best_improvement", "improvement_rate", "search_complete_rate"], limit=20),
        "",
        "## Parameter Summary",
        "",
        base.markdown_table(parameter_summary, ["pool_mode", "pool_size", "radius", "row_count", "best_score", "median_best_score", "best_improvement", "improvement_rate", "search_complete_rate"], limit=40),
        "",
        "## Next Actions",
        "",
        "- If complete restricted rows find no improvement, enlarge or redesign the pool rather than just increasing beam depth.",
        "- If capped rows find improvement, rerun the winning pool/radius with higher caps to verify whether the improvement survives a more complete local-branching check.",
        "- If no restricted improvement appears for c01/c05, move toward a stronger exact local-branching/CP-SAT model with selected residual coordinates and multi-block variables.",
        "",
    ]
    with open(os.path.join(out_dir, "README.md"), "w") as f:
        f.write("\n".join(lines))


def write_next_actions(out_dir, rows):
    best = best_rows(rows, 3)
    lines = [
        "# Next actions",
        "",
        "1. Inspect `local_branch_rows.csv` for complete rows on c01/c05 with no improvement; these are the strongest restricted negative evidence.",
        "2. If a best row is capped, rerun that parameter cell with higher `global_eval_cap` and `block_candidate_cap_per_radius`.",
        "3. If all useful rows are capped and unimproved, implement a CP-SAT/local branching prototype over the same pool with selected defect-coordinate objective.",
        "",
        "Best observed rows:",
        "",
        base.markdown_table(best, ["tuple_class", "candidate_id", "score_before", "best_score", "score_improvement", "pool_mode", "pool_size", "radius", "cap_reason"], limit=3),
        "",
    ]
    with open(os.path.join(out_dir, "next_actions.md"), "w") as f:
        f.write("\n".join(lines))


ROW_FIELDS = [
    "run_id",
    "shard_id",
    "candidate_id",
    "tuple_class",
    "source_run",
    "source_file",
    "frontier_bucket",
    "lambda",
    "ks",
    "initial_score",
    "candidate_hash_before",
    "pool_mode",
    "pool_size",
    "radius",
    "restart_id",
    "seed",
    "block_candidate_cap_per_radius",
    "global_eval_cap",
    "score_before",
    "best_score",
    "score_after",
    "score_improvement",
    "improved",
    "score0",
    "search_complete",
    "cap_reason",
    "block_candidate_count",
    "block_candidate_counts",
    "combination_evaluations",
    "exact_joint_evaluations",
    "wall_time_ms",
    "best_plan_json",
    "best_plan_radius",
    "candidate_hash_after",
] + ["score_after_le_{}".format(t) for t in THRESHOLDS]


def write_outputs(args, rows, candidates, out_dir):
    ensure_dir(out_dir)
    candidate_summary = summarize_group(rows, ["tuple_class", "candidate_id"])
    parameter_summary = summarize_group(rows, ["pool_mode", "pool_size", "radius"])
    config = {
        "experiment_name": args.experiment_name,
        "run_id": args.run_id,
        "candidate_count": len(candidates),
        "row_count": len(rows),
        "frontier_files": args.frontier_files,
        "pool_modes": args.pool_modes,
        "pool_size_list": args.pool_size_list,
        "radius_list": args.radius_list,
        "restarts_per_cell": int(args.restarts_per_cell),
        "block_candidate_cap_per_radius": int(args.block_candidate_cap_per_radius),
        "global_eval_cap": int(args.global_eval_cap),
        "max_wall_time_ms": int(args.max_wall_time_ms),
        "shard_id": int(args.shard_id),
        "shard_count": int(args.shard_count),
    }
    base.write_json(os.path.join(out_dir, "run_config.json"), config)
    base.write_jsonl(os.path.join(out_dir, "candidate_list.jsonl"), candidates)
    base.write_jsonl(os.path.join(out_dir, "local_branch_rows.jsonl"), rows)
    base.write_csv(os.path.join(out_dir, "local_branch_rows.csv"), rows, ROW_FIELDS)
    base.write_csv(os.path.join(out_dir, "candidate_summary.csv"), candidate_summary, sorted({k for row in candidate_summary for k in row}))
    base.write_csv(os.path.join(out_dir, "parameter_summary.csv"), parameter_summary, sorted({k for row in parameter_summary for k in row}))
    base.write_jsonl(os.path.join(out_dir, "best_moves.jsonl"), best_rows(rows, 100))
    for threshold in THRESHOLDS:
        base.write_jsonl(os.path.join(out_dir, "score_under_{}_candidates.jsonl".format(threshold)), threshold_rows(rows, threshold))
    score0_rows = [row for row in rows if int(row["best_score"]) == 0]
    base.write_jsonl(os.path.join(out_dir, "score0_candidates.jsonl"), score0_rows)
    base.write_json(os.path.join(out_dir, "validation_report.json"), {"score0_count": len(score0_rows), "validated_score0_count": 0, "note": "No Sage validation was required unless score0_count is nonzero."})
    write_readme(out_dir, config, rows, candidate_summary, parameter_summary)
    write_next_actions(out_dir, rows)


def run_mode(args):
    candidates = base.load_frontier_candidates(args)
    pool_modes = parse_csv(args.pool_modes)
    pool_sizes = parse_csv(args.pool_size_list, int)
    radii = parse_csv(args.radius_list, int)
    tasks = shard_tasks(candidates, pool_modes, pool_sizes, radii, int(args.restarts_per_cell), int(args.shard_id), int(args.shard_count))
    if args.smoke:
        tasks = tasks[: max(1, int(args.smoke_task_limit))]
    print(
        "local-branching-start shard={}/{} candidates={} tasks={} pool_modes={} pool_sizes={} radii={}".format(
            args.shard_id, args.shard_count, len(candidates), len(tasks), pool_modes, pool_sizes, radii
        ),
        flush=True,
    )
    rows = []
    for idx, (candidate, pool_mode, pool_size, radius, restart_id) in enumerate(tasks, start=1):
        print(
            "task {}/{} candidate={} tuple={} score={} pool_mode={} pool_size={} radius={} restart={}".format(
                idx,
                len(tasks),
                candidate["frontier_candidate_id"],
                candidate["tuple_class"],
                candidate["initial_score"],
                pool_mode,
                pool_size,
                radius,
                restart_id,
            ),
            flush=True,
        )
        rows.append(exact_local_branching_check(candidate, args, pool_mode, pool_size, radius, restart_id))
    write_outputs(args, rows, candidates, args.out_dir)
    print("wrote {} local branch rows to {}".format(len(rows), args.out_dir), flush=True)


def aggregate_mode(args):
    rows = []
    by_hash = {}
    for path in Path(args.aggregate_input_dir).rglob("local_branch_rows.jsonl"):
        rows.extend(base.read_jsonl(str(path)))
    for path in Path(args.aggregate_input_dir).rglob("candidate_list.jsonl"):
        for row in base.read_jsonl(str(path)):
            by_hash[row["canonical_hash_before"]] = row
    candidates = list(by_hash.values())
    write_outputs(args, rows, candidates, args.out_dir)
    print("aggregated {} local branch rows to {}".format(len(rows), args.out_dir), flush=True)


def parse_args():
    parser = argparse.ArgumentParser(description="p167 restricted local-branching wall check.")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--frontier-files", default=FRONTIER_FIXTURE_DEFAULT)
    parser.add_argument("--tuple-registry", default=base.TUPLE_REGISTRY_DEFAULT)
    parser.add_argument("--tuple-classes", default=TUPLE_CLASSES_DEFAULT)
    parser.add_argument("--frontier-count", "--candidate-count", dest="frontier_count", type=int, default=2)
    parser.add_argument("--pool-modes", default="defect,hybrid")
    parser.add_argument("--pool-size-list", default="6,8,10")
    parser.add_argument("--radius-list", default="2,3,4")
    parser.add_argument("--restarts-per-cell", type=int, default=4)
    parser.add_argument("--block-candidate-cap-per-radius", type=int, default=50000)
    parser.add_argument("--global-eval-cap", type=int, default=4000000)
    parser.add_argument("--max-wall-time-ms", type=int, default=120000)
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--output-root", default=OUTPUT_ROOT_DEFAULT)
    parser.add_argument("--experiment-name", default=EXPERIMENT_DEFAULT)
    parser.add_argument("--run-id", default="")
    parser.add_argument("--base-seed", type=int, default=164168)
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
