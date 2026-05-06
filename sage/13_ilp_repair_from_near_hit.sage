from sage.all import *

import argparse
import csv
import json
import math
import multiprocessing
import os
import random
import signal
import sys
import time

from sds_repair_utils import (
    apply_delta,
    delta_swap,
    load_candidate,
    metrics_from_counts,
    save_near_hit,
    save_success,
    setup_logging,
    timestamp,
    total_diff_counts,
    write_json,
)


SEARCH_METHOD = "ilp_repair_from_near_hit"


class HardTimeout(RuntimeError):
    pass


def _hard_timeout_handler(signum, frame):
    raise HardTimeout("hard time limit exceeded")


def start_hard_timeout(seconds):
    if seconds is None:
        return None
    seconds = int(math.ceil(float(seconds)))
    if seconds < 1:
        raise HardTimeout("hard time limit exceeded before operation started")
    old_handler = signal.getsignal(signal.SIGALRM)
    signal.signal(signal.SIGALRM, _hard_timeout_handler)
    signal.alarm(seconds)
    return old_handler


def stop_hard_timeout(old_handler):
    if old_handler is None:
        return
    signal.alarm(0)
    signal.signal(signal.SIGALRM, old_handler)


def hard_timeout_remaining(start, hard_time_limit):
    if hard_time_limit is None:
        return None
    remaining = float(hard_time_limit) - (time.time() - start)
    if remaining <= 0:
        raise HardTimeout("hard time limit already exhausted")
    return remaining


def defect_vector(counts, lam):
    return [0] + [int(counts[d] - lam) for d in range(1, len(counts))]


def score_move(v, counts, defects, lam, block_idx, block, removed, added):
    delta = delta_swap(v, block, removed, added)
    new_counts = apply_delta(counts, delta)
    new_metrics = metrics_from_counts(new_counts, lam)
    cur_metrics = metrics_from_counts(counts, lam)
    cur_abs = 0
    new_abs = 0
    fix_abs = 0
    damage_abs = 0
    alignment = 0
    zero_damage = 0
    worst_fix = 0
    worst_over_fix = 0
    worst_under_fix = 0
    worst_abs = max(abs(defects[d]) for d in range(1, v))
    for d in range(1, v):
        before = defects[d]
        after = before + delta[d]
        before_abs = abs(before)
        after_abs = abs(after)
        cur_abs += before_abs
        new_abs += after_abs
        alignment -= before * delta[d]
        if after_abs < before_abs:
            fix_abs += before_abs - after_abs
            if before_abs >= 2:
                worst_fix += before_abs - after_abs
            if before == worst_abs:
                worst_over_fix += before_abs - after_abs
            elif before == -worst_abs:
                worst_under_fix += before_abs - after_abs
        elif after_abs > before_abs:
            damage_abs += after_abs - before_abs
            if before == 0:
                zero_damage += after_abs

    pair_fix = 0
    pair_damage = 0
    for d in range(1, (v - 1) // 2 + 1):
        e = (-d) % v
        before_pair = abs(defects[d]) + abs(defects[e])
        after_pair = abs(defects[d] + delta[d]) + abs(defects[e] + delta[e])
        if after_pair < before_pair:
            pair_fix += before_pair - after_pair
        elif after_pair > before_pair:
            pair_damage += after_pair - before_pair

    return {
        "block": int(block_idx),
        "removed": int(removed),
        "added": int(added),
        "delta": delta,
        "metrics": new_metrics,
        "score_change": int(new_metrics[0] - cur_metrics[0]),
        "l1_change": int(new_metrics[1] - cur_metrics[1]),
        "max_abs_change": int(new_metrics[2] - cur_metrics[2]),
        "nonzero_change": int(new_metrics[3] - cur_metrics[3]),
        "alignment": int(alignment),
        "fix_abs": int(fix_abs),
        "damage_abs": int(damage_abs),
        "zero_damage": int(zero_damage),
        "worst_fix": int(worst_fix),
        "worst_over_fix": int(worst_over_fix),
        "worst_under_fix": int(worst_under_fix),
        "pair_fix": int(pair_fix),
        "pair_damage": int(pair_damage),
        "pool_categories": [],
    }


def unique_moves(moves):
    seen = set()
    out = []
    for move in moves:
        key = (move["block"], move["removed"], move["added"])
        if key in seen:
            continue
        seen.add(key)
        out.append(move)
    return out


def tag_move(move, category):
    categories = move.setdefault("pool_categories", [])
    if category not in categories:
        categories.append(category)
    return move


def take_category(moves, category, key_fn, bucket):
    selected = []
    for move in sorted(moves, key=key_fn)[: max(0, int(bucket))]:
        selected.append(tag_move(move, category))
    return selected


def final_pool_sort_key(item):
    return (
        item["score_change"],
        item["l1_change"],
        item["max_abs_change"],
        item["nonzero_change"],
        -item["alignment"],
        item["damage_abs"],
        -item["fix_abs"],
        -item["pair_fix"],
        item["block"],
        item["removed"],
        item["added"],
    )


def zero_protection_stats(v, old_counts, new_counts, lam):
    protected = 0
    damage = 0
    for d in range(1, v):
        if int(old_counts[d] - lam) == 0:
            protected += 1
            damage += abs(int(new_counts[d] - lam))
    return int(damage), int(protected)


def choose_active_shifts(v, defects, active_defects, active_top_k_shifts):
    if active_defects != "nonzero":
        raise ValueError("unknown active defect policy: {}".format(active_defects))
    shifts = [d for d in range(1, v) if defects[d] != 0]
    shifts.sort(key=lambda d: (-abs(defects[d]), d))
    if active_top_k_shifts is not None:
        shifts = shifts[: int(active_top_k_shifts)]
    return sorted(int(d) for d in shifts)


def annotate_active_repair_scores(moves, defects, active_shifts):
    active_set = set(int(d) for d in active_shifts)
    zero_shifts = [
        d for d in range(1, len(defects)) if defects[d] == 0 and d not in active_set
    ]
    for move in moves:
        active_l1_before = 0
        active_l1_after = 0
        active_nonzero_before = 0
        active_nonzero_after = 0
        active_fix_abs = 0
        active_damage_abs = 0
        active_zeroed = 0
        for d in active_shifts:
            before = int(defects[d])
            after = int(before + move["delta"][d])
            before_abs = abs(before)
            after_abs = abs(after)
            active_l1_before += before_abs
            active_l1_after += after_abs
            if before != 0:
                active_nonzero_before += 1
            if after != 0:
                active_nonzero_after += 1
            if after_abs < before_abs:
                active_fix_abs += before_abs - after_abs
                if after == 0:
                    active_zeroed += 1
            elif after_abs > before_abs:
                active_damage_abs += after_abs - before_abs

        zero_damage = sum(abs(int(move["delta"][d])) for d in zero_shifts)
        l1_gain = active_l1_before - active_l1_after
        nonzero_gain = active_nonzero_before - active_nonzero_after
        repair_score = (
            1000 * l1_gain
            + 250 * nonzero_gain
            + 25 * active_zeroed
            - 200 * active_damage_abs
            - 5 * zero_damage
            - max(0, int(move["score_change"]))
        )
        move["active_l1_before"] = int(active_l1_before)
        move["active_l1_after"] = int(active_l1_after)
        move["active_l1_gain"] = int(l1_gain)
        move["active_nonzero_before"] = int(active_nonzero_before)
        move["active_nonzero_after"] = int(active_nonzero_after)
        move["active_nonzero_gain"] = int(nonzero_gain)
        move["active_fix_abs"] = int(active_fix_abs)
        move["active_damage_abs"] = int(active_damage_abs)
        move["active_zeroed"] = int(active_zeroed)
        move["active_zero_shift_damage"] = int(zero_damage)
        move["active_repair_score"] = int(repair_score)
    return moves


def greedy_prefilter_moves(moves, defects, active_shifts, greedy_prefilter):
    annotate_active_repair_scores(moves, defects, active_shifts)
    if greedy_prefilter is None or int(greedy_prefilter) >= len(moves):
        return moves
    limit = max(1, int(greedy_prefilter))
    ranked = sorted(
        moves,
        key=lambda item: (
            -item["active_repair_score"],
            item["active_l1_after"],
            item["active_nonzero_after"],
            item["active_zero_shift_damage"],
            item["metrics"][0],
            item["metrics"][1],
            item["block"],
            item["removed"],
            item["added"],
        ),
    )
    return ranked[:limit]


def estimate_model_size(v, blocks, moves, objective, residual_bound):
    move_count = len(moves)
    var_count = move_count + 2 * (v - 1) + 1
    constraint_count = 1
    removed_keys = set()
    added_keys = set()
    for move in moves:
        removed_keys.add((int(move["block"]), int(move["removed"])))
        added_keys.add((int(move["block"]), int(move["added"])))
    conflict_constraints = len(removed_keys) + len(added_keys)
    constraint_count += conflict_constraints

    score_objectives = (
        "score",
        "score_then_l1",
        "score_zero_protect",
        "zero_protect_score",
    )
    if objective in ("l1_then_nonzero", "nonzero_then_l1"):
        var_count += v - 1
    if objective in score_objectives:
        var_count += (v - 1) * (2 * int(residual_bound) + 1)

    # expr == pos-neg, expr <= max_abs, -expr <= max_abs
    constraint_count += 3 * (v - 1)
    if objective in ("l1_then_nonzero", "nonzero_then_l1"):
        constraint_count += v - 1
    if objective in score_objectives:
        # one-hot residual value and encoded residual equality
        constraint_count += 2 * (v - 1)

    return {
        "model_var_count_estimate": int(var_count),
        "model_constraint_count_estimate": int(constraint_count),
        "conflict_constraint_count_estimate": int(conflict_constraints),
    }


def move_linear_expr(moves, x, key):
    return sum(int(moves[j].get(key, 0)) * x[j] for j in range(len(moves)))


def diagnostic_objective_expr(moves, x, selected_count, diagnostic_objective):
    active_l1_gain = move_linear_expr(moves, x, "active_l1_gain")
    active_nonzero_gain = move_linear_expr(moves, x, "active_nonzero_gain")
    active_zeroed = move_linear_expr(moves, x, "active_zeroed")
    active_damage = move_linear_expr(moves, x, "active_damage_abs")
    zero_damage = move_linear_expr(moves, x, "active_zero_shift_damage")
    score_worsen = sum(
        max(0, int(moves[j].get("score_change", 0))) * x[j]
        for j in range(len(moves))
    )
    score_improve = sum(
        max(0, -int(moves[j].get("score_change", 0))) * x[j]
        for j in range(len(moves))
    )
    active_touch = sum(
        (1 if int(moves[j].get("active_l1_before", 0)) != int(moves[j].get("active_l1_after", 0)) else 0)
        * x[j]
        for j in range(len(moves))
    )

    if diagnostic_objective == "move_l1_repair":
        return (
            -10000 * active_l1_gain
            - 250 * active_zeroed
            + 500 * active_damage
            + 10 * zero_damage
            + score_worsen
            + selected_count
        )
    if diagnostic_objective == "move_nonzero_repair":
        return (
            -10000 * active_nonzero_gain
            - 500 * active_l1_gain
            - 100 * active_zeroed
            + 500 * active_damage
            + 10 * zero_damage
            + score_worsen
            + selected_count
        )
    if diagnostic_objective == "move_balanced":
        return (
            -1000 * active_l1_gain
            - 250 * active_nonzero_gain
            - 25 * active_zeroed
            + 200 * active_damage
            + 5 * zero_damage
            + score_worsen
            - score_improve
            + selected_count
        )
    if diagnostic_objective == "move_escape":
        return (
            -1000 * selected_count
            - 100 * active_touch
            - 50 * active_l1_gain
            + 20 * active_damage
            + 5 * zero_damage
            + score_worsen
        )
    raise ValueError("unknown diagnostic objective: {}".format(diagnostic_objective))


def build_pool_diagnostics(
    args,
    v,
    counts,
    lam,
    moves,
    total_swaps,
    pool_count_before_filter,
    active_shifts,
):
    defects = defect_vector(counts, lam)
    estimate = estimate_model_size(v, [], moves, args.objective, args.residual_bound)
    diagnostics = {
        "active_top_k_shifts": (
            None
            if args.active_top_k_shifts is None
            else int(args.active_top_k_shifts)
        ),
        "active_defect_count": int(sum(1 for d in range(1, v) if defects[d] != 0)),
        "active_shifts_used": [int(d) for d in active_shifts],
        "greedy_prefilter": (
            None if args.greedy_prefilter is None else int(args.greedy_prefilter)
        ),
        "pool_count_before_filter": int(pool_count_before_filter),
        "pool_count_after_filter": int(len(moves)),
        "candidate_swap_count_before_filtering": int(total_swaps),
        "candidate_swap_count_after_filtering": int(len(moves)),
        "model_var_count_estimate": int(estimate["model_var_count_estimate"]),
        "model_constraint_count_estimate": int(
            estimate["model_constraint_count_estimate"]
        ),
        "conflict_constraint_count_estimate": int(
            estimate["conflict_constraint_count_estimate"]
        ),
        "hard_time_limit": (
            None if args.hard_time_limit is None else int(args.hard_time_limit)
        ),
        "time_limit": None if args.time_limit is None else int(args.time_limit),
        "max_swaps": int(args.max_moves),
        "max_moves": int(args.max_moves),
        "objective": args.objective,
        "diagnostic_objective": args.diagnostic_objective,
        "force_moves": bool(args.force_moves),
        "min_moves": int(args.min_moves),
        "score_worsen_limit": args.score_worsen_limit,
        "l1_worsen_limit": args.l1_worsen_limit,
        "maxabs_limit": args.maxabs_limit,
        "pool_mode": args.pool_mode,
    }
    return diagnostics


def print_solver_preamble(args, input_path, metrics, diagnostics):
    print("ILP pre-solve diagnostics")
    print("  input path:", input_path)
    print(
        "  metrics: score={} l1_error={} max_abs_error={} nonzero_defect_count={}".format(
            metrics[0], metrics[1], metrics[2], metrics[3]
        )
    )
    print("  objective:", args.objective)
    print("  diagnostic_objective:", args.diagnostic_objective)
    print("  force_moves:", bool(args.force_moves))
    print("  min_moves:", int(args.min_moves))
    print("  score_worsen_limit:", args.score_worsen_limit)
    print("  l1_worsen_limit:", args.l1_worsen_limit)
    print("  maxabs_limit:", args.maxabs_limit)
    print("  pool_mode:", args.pool_mode)
    print("  active defect count:", diagnostics["active_defect_count"])
    print("  active shifts used:", diagnostics["active_shifts_used"])
    print(
        "  candidate swap count before filtering:",
        diagnostics["candidate_swap_count_before_filtering"],
    )
    print(
        "  candidate swap count after filtering:",
        diagnostics["candidate_swap_count_after_filtering"],
    )
    print(
        "  estimated variable count:",
        diagnostics["model_var_count_estimate"],
    )
    print(
        "  estimated constraint count:",
        diagnostics["model_constraint_count_estimate"],
    )
    print("  max_swaps:", diagnostics["max_swaps"])
    print("  time_limit:", diagnostics["time_limit"])
    print("  hard_time_limit:", diagnostics["hard_time_limit"])
    sys.stdout.flush()


def write_pool_stats_files(stamp, round_index, stats):
    base = os.path.join(
        "outputs/logs",
        "13_ilp_repair_from_near_hit_{}_pool_stats_round{}".format(
            stamp, round_index
        ),
    )
    json_path = base + ".json"
    md_path = base + ".md"
    write_json(json_path, stats)
    with open(md_path, "w") as f:
        f.write("# ILP Pool Stats\n\n")
        for key in sorted(stats):
            value = stats[key]
            if isinstance(value, (list, dict)):
                value = json.dumps(value, sort_keys=True)
            f.write("- `{}`: {}\n".format(key, value))
    print("POOL_STATS json={} md={}".format(json_path, md_path))
    sys.stdout.flush()
    return {"pool_stats_json": json_path, "pool_stats_md": md_path}


def build_defect_driven_pool(v, blocks, counts, lam, pool_size, pool_mode, rng):
    defects = defect_vector(counts, lam)
    moves = []
    universe = list(range(v))
    cur_metrics = metrics_from_counts(counts, lam)
    for block_idx, block in enumerate(blocks):
        if len(block) == 0 or len(block) == v:
            continue
        outside = [x for x in universe if x not in block]
        for removed in sorted(block):
            for added in outside:
                item = score_move(
                    v, counts, defects, lam, block_idx, block, removed, added
                )
                item["cur_metrics"] = cur_metrics
                moves.append(item)

    pool_size = int(pool_size)
    if pool_mode == "score":
        selected = take_category(
            moves,
            "score",
            lambda item: (item["metrics"], item["damage_abs"], item["block"], item["removed"], item["added"]),
            pool_size,
        )
        return unique_moves(selected)[:pool_size], len(moves)

    if pool_mode == "l1":
        selected = take_category(
            moves,
            "l1",
            lambda item: (
                item["metrics"][1],
                item["metrics"][0],
                item["metrics"][2],
                item["damage_abs"],
                item["block"],
                item["removed"],
                item["added"],
            ),
            pool_size,
        )
        return unique_moves(selected)[:pool_size], len(moves)

    if pool_mode == "max_abs":
        selected = take_category(
            moves,
            "max_abs",
            lambda item: (
                item["metrics"][2],
                item["metrics"][0],
                item["metrics"][1],
                -item["worst_fix"],
                item["damage_abs"],
                item["block"],
                item["removed"],
                item["added"],
            ),
            pool_size,
        )
        return unique_moves(selected)[:pool_size], len(moves)

    if pool_mode == "worst_shift":
        selected = []
        bucket = max(1, pool_size // 3)
        selected.extend(
            take_category(
                moves,
                "worst_over",
                lambda item: (
                    -item["worst_over_fix"],
                    item["damage_abs"],
                    item["score_change"],
                    item["block"],
                    item["removed"],
                    item["added"],
                ),
                bucket,
            )
        )
        selected.extend(
            take_category(
                moves,
                "worst_under",
                lambda item: (
                    -item["worst_under_fix"],
                    item["damage_abs"],
                    item["score_change"],
                    item["block"],
                    item["removed"],
                    item["added"],
                ),
                bucket,
            )
        )
        selected.extend(
            take_category(
                moves,
                "worst_shift",
                lambda item: (
                    -item["worst_fix"],
                    item["damage_abs"],
                    item["score_change"],
                    item["block"],
                    item["removed"],
                    item["added"],
                ),
                pool_size,
            )
        )
        selected = unique_moves(selected)
        selected.sort(key=final_pool_sort_key)
        return selected[:pool_size], len(moves)

    if pool_mode == "zero_protect":
        selected = take_category(
            moves,
            "zero_protect",
            lambda item: (
                item["zero_damage"],
                item["nonzero_change"],
                item["score_change"],
                item["l1_change"],
                -item["fix_abs"],
                item["damage_abs"],
                item["block"],
                item["removed"],
                item["added"],
            ),
            pool_size,
        )
        return unique_moves(selected)[:pool_size], len(moves)

    if pool_mode == "low_nonzero":
        selected = take_category(
            moves,
            "low_nonzero",
            lambda item: (
                item["metrics"][3],
                item["zero_damage"],
                item["metrics"][1],
                item["metrics"][0],
                item["metrics"][2],
                item["block"],
                item["removed"],
                item["added"],
            ),
            pool_size,
        )
        return unique_moves(selected)[:pool_size], len(moves)

    if pool_mode == "active_defect_lns":
        selected = []
        bucket = max(1, pool_size // 5)
        selected.extend(
            take_category(
                moves,
                "active_fix",
                lambda item: (
                    -item["fix_abs"],
                    item["zero_damage"],
                    item["metrics"][1],
                    item["metrics"][3],
                    item["metrics"][0],
                    item["block"],
                    item["removed"],
                    item["added"],
                ),
                bucket,
            )
        )
        selected.extend(
            take_category(
                moves,
                "active_l1",
                lambda item: (
                    item["metrics"][1],
                    item["zero_damage"],
                    item["metrics"][3],
                    item["metrics"][0],
                    item["block"],
                    item["removed"],
                    item["added"],
                ),
                bucket,
            )
        )
        selected.extend(
            take_category(
                moves,
                "active_nonzero",
                lambda item: (
                    item["metrics"][3],
                    item["zero_damage"],
                    item["metrics"][1],
                    item["metrics"][0],
                    item["block"],
                    item["removed"],
                    item["added"],
                ),
                bucket,
            )
        )
        selected.extend(
            take_category(
                moves,
                "active_pair",
                lambda item: (
                    -item["pair_fix"],
                    item["pair_damage"],
                    item["zero_damage"],
                    item["metrics"][1],
                    item["metrics"][3],
                    item["block"],
                    item["removed"],
                    item["added"],
                ),
                bucket,
            )
        )
        selected.extend(
            take_category(
                moves,
                "active_score",
                lambda item: (
                    item["metrics"][0],
                    item["zero_damage"],
                    item["metrics"][1],
                    item["metrics"][3],
                    item["block"],
                    item["removed"],
                    item["added"],
                ),
                pool_size,
            )
        )
        selected = unique_moves(selected)
        selected.sort(
            key=lambda item: (
                item["metrics"][1],
                item["metrics"][3],
                item["zero_damage"],
                item["metrics"][0],
                -item["fix_abs"],
                item["block"],
                item["removed"],
                item["added"],
            )
        )
        return selected[:pool_size], len(moves)

    if pool_mode not in ("mixed", "diverse"):
        raise ValueError("unknown pool mode: {}".format(pool_mode))

    categories = [
        (
            "score",
            lambda item: (item["metrics"], item["damage_abs"], item["block"], item["removed"], item["added"]),
        ),
        (
            "l1",
            lambda item: (
                item["metrics"][1],
                item["metrics"][0],
                item["metrics"][2],
                item["damage_abs"],
                item["block"],
                item["removed"],
                item["added"],
            ),
        ),
        (
            "max_abs",
            lambda item: (
                item["metrics"][2],
                item["metrics"][0],
                item["metrics"][1],
                -item["worst_fix"],
                item["damage_abs"],
                item["block"],
                item["removed"],
                item["added"],
            ),
        ),
        (
            "worst_over",
            lambda item: (
                -item["worst_over_fix"],
                item["damage_abs"],
                item["score_change"],
                item["block"],
                item["removed"],
                item["added"],
            ),
        ),
        (
            "worst_under",
            lambda item: (
                -item["worst_under_fix"],
                item["damage_abs"],
                item["score_change"],
                item["block"],
                item["removed"],
                item["added"],
            ),
        ),
        (
            "pair",
            lambda item: (
                -item["pair_fix"],
                item["pair_damage"],
                item["score_change"],
                item["block"],
                item["removed"],
                item["added"],
            ),
        ),
        (
            "alignment",
            lambda item: (
                -item["alignment"],
                item["damage_abs"],
                item["score_change"],
                item["block"],
                item["removed"],
                item["added"],
            ),
        ),
        (
            "zero_protect",
            lambda item: (
                item["zero_damage"],
                item["nonzero_change"],
                item["score_change"],
                item["l1_change"],
                item["block"],
                item["removed"],
                item["added"],
            ),
        ),
        (
            "low_nonzero",
            lambda item: (
                item["metrics"][3],
                item["zero_damage"],
                item["metrics"][1],
                item["metrics"][0],
                item["block"],
                item["removed"],
                item["added"],
            ),
        ),
    ]

    bucket = max(1, int(math.ceil(float(pool_size) / float(len(categories)))))
    selected = []
    for category, key_fn in categories:
        selected.extend(take_category(moves, category, key_fn, bucket))

    selected = unique_moves(selected)

    if pool_mode == "diverse" and len(selected) < pool_size:
        selected_keys = {
            (move["block"], move["removed"], move["added"]) for move in selected
        }
        remaining = [
            move
            for move in moves
            if (move["block"], move["removed"], move["added"]) not in selected_keys
        ]
        rng.shuffle(remaining)
        for move in remaining[: max(0, pool_size - len(selected))]:
            selected.append(tag_move(move, "random_diverse"))

    if pool_mode == "diverse":
        by_block = []
        block_quota = max(1, pool_size // 4)
        for block_idx in range(4):
            block_moves = [move for move in moves if move["block"] == block_idx]
            by_block.extend(
                take_category(
                    block_moves,
                    "block_diverse",
                    final_pool_sort_key,
                    block_quota,
                )
            )
        selected.extend(by_block)

    selected = unique_moves(selected)
    selected.sort(key=final_pool_sort_key)
    return selected[:pool_size], len(moves)


def solve_ilp(
    v,
    blocks,
    counts,
    lam,
    moves,
    max_moves,
    objective,
    residual_bound,
    zero_protect_weight,
    time_limit,
    solver_log,
    min_moves,
    force_moves,
    score_worsen_limit,
    l1_worsen_limit,
    maxabs_limit,
    diagnostic_objective,
    limit_base_metrics,
):
    defects = defect_vector(counts, lam)
    p = MixedIntegerLinearProgram(maximization=False)
    x = p.new_variable(binary=True, name="x")
    pos = p.new_variable(nonnegative=True, name="pos")
    neg = p.new_variable(nonnegative=True, name="neg")
    max_abs = p.new_variable(nonnegative=True, name="max_abs")
    residual_value = None
    nonzero_residual = None
    score_objectives = (
        "score",
        "score_then_l1",
        "score_zero_protect",
        "zero_protect_score",
    )
    if objective in score_objectives:
        residual_value = p.new_variable(binary=True, name="residual_value")
    if objective in ("l1_then_nonzero", "nonzero_then_l1"):
        nonzero_residual = p.new_variable(binary=True, name="nonzero_residual")

    selected_count = sum(x[j] for j in range(len(moves)))
    p.add_constraint(selected_count <= int(max_moves))
    if force_moves:
        p.add_constraint(selected_count >= int(min_moves))
    if time_limit is not None:
        try:
            p.solver_parameter("timelimit", int(time_limit))
        except Exception as exc:
            print("WARNING: solver time limit was not applied: {}".format(exc))

    for block_idx, block in enumerate(blocks):
        for value in block:
            js = [j for j, move in enumerate(moves) if move["block"] == block_idx and move["removed"] == value]
            if js:
                p.add_constraint(sum(x[j] for j in js) <= 1)
        outside = [value for value in range(v) if value not in block]
        for value in outside:
            js = [j for j, move in enumerate(moves) if move["block"] == block_idx and move["added"] == value]
            if js:
                p.add_constraint(sum(x[j] for j in js) <= 1)

    l1_terms = []
    score_terms = []
    encoded_l1_terms = []
    zero_terms = []
    residual_values = list(range(-int(residual_bound), int(residual_bound) + 1))
    for d in range(1, v):
        expr = defects[d] + sum(int(moves[j]["delta"][d]) * x[j] for j in range(len(moves)))
        p.add_constraint(expr == pos[d] - neg[d])
        p.add_constraint(expr <= max_abs[0])
        p.add_constraint(-expr <= max_abs[0])
        l1_terms.append(pos[d] + neg[d])
        if defects[d] == 0:
            zero_terms.append(pos[d] + neg[d])
        if nonzero_residual is not None:
            p.add_constraint(pos[d] + neg[d] <= int(residual_bound) * nonzero_residual[d])
        if residual_value is not None:
            p.add_constraint(sum(residual_value[(d, r)] for r in residual_values) == 1)
            p.add_constraint(
                expr
                == sum(r * residual_value[(d, r)] for r in residual_values)
            )
            score_terms.append(
                sum((r * r) * residual_value[(d, r)] for r in residual_values)
            )
            encoded_l1_terms.append(
                sum(abs(r) * residual_value[(d, r)] for r in residual_values)
            )

    l1_obj = sum(l1_terms)

    if l1_worsen_limit is not None:
        current_l1 = int(limit_base_metrics[1])
        p.add_constraint(l1_obj <= int(current_l1) + int(l1_worsen_limit))
    if maxabs_limit is not None:
        p.add_constraint(max_abs[0] <= int(maxabs_limit))

    if force_moves and diagnostic_objective is not None:
        p.set_objective(
            diagnostic_objective_expr(moves, x, selected_count, diagnostic_objective)
        )
    elif objective == "l1":
        p.set_objective(1000 * l1_obj + selected_count)
    elif objective == "max_then_l1":
        p.set_objective(100000 * max_abs[0] + 1000 * l1_obj + selected_count)
    elif objective == "score":
        p.set_objective(1000000 * sum(score_terms) + selected_count)
    elif objective == "score_then_l1":
        p.set_objective(
            1000000 * sum(score_terms)
            + 1000 * sum(encoded_l1_terms)
            + selected_count
        )
    elif objective in ("score_zero_protect", "zero_protect_score"):
        p.set_objective(
            1000000 * sum(score_terms)
            + int(zero_protect_weight) * sum(zero_terms)
            + 1000 * sum(encoded_l1_terms)
            + selected_count
        )
    elif objective == "l1_then_nonzero":
        p.set_objective(
            1000000 * l1_obj
            + 1000 * sum(nonzero_residual[d] for d in range(1, v))
            + selected_count
        )
    elif objective == "nonzero_then_l1":
        p.set_objective(
            1000000 * sum(nonzero_residual[d] for d in range(1, v))
            + 1000 * l1_obj
            + selected_count
        )
    else:
        raise ValueError("unknown objective: {}".format(objective))

    try:
        value = p.solve(log=bool(solver_log))
        solver_status = "solved"
        x_values = p.get_values(x)
    except HardTimeout:
        raise
    except Exception as exc:
        print("WARNING: ILP solver failed: {}".format(exc))
        sys.stdout.flush()
        return None, [], "solver_error:{}".format(exc)
    selected = []
    for j in range(len(moves)):
        if x_values.get(j, 0) > 0.5:
            selected.append(j)
    return float(value), selected, solver_status


def _solve_ilp_worker(queue, payload):
    try:
        objective_value, selected, solver_status = solve_ilp(*payload)
        queue.put(
            {
                "ok": True,
                "objective_value": objective_value,
                "selected": selected,
                "solver_status": solver_status,
            }
        )
    except BaseException as exc:
        queue.put(
            {
                "ok": False,
                "objective_value": None,
                "selected": [],
                "solver_status": "solver_error:{}".format(exc),
            }
        )


def solve_ilp_guarded(
    v,
    blocks,
    counts,
    lam,
    moves,
    max_moves,
    objective,
    residual_bound,
    zero_protect_weight,
    time_limit,
    solver_log,
    hard_time_remaining,
    min_moves,
    force_moves,
    score_worsen_limit,
    l1_worsen_limit,
    maxabs_limit,
    diagnostic_objective,
    limit_base_metrics,
):
    payload = (
        v,
        blocks,
        counts,
        lam,
        moves,
        max_moves,
        objective,
        residual_bound,
        zero_protect_weight,
        time_limit,
        solver_log,
        min_moves,
        force_moves,
        score_worsen_limit,
        l1_worsen_limit,
        maxabs_limit,
        diagnostic_objective,
        limit_base_metrics,
    )
    if hard_time_remaining is None:
        objective_value, selected, solver_status = solve_ilp(*payload)
        return objective_value, selected, solver_status, False

    timeout_seconds = max(1, int(math.floor(float(hard_time_remaining))))
    try:
        ctx = multiprocessing.get_context("fork")
    except ValueError:
        ctx = multiprocessing.get_context()
    queue = ctx.Queue()
    process = ctx.Process(target=_solve_ilp_worker, args=(queue, payload))
    process.start()
    process.join(timeout_seconds)
    if process.is_alive():
        process.terminate()
        process.join(5)
        if process.is_alive():
            try:
                process.kill()
            except AttributeError:
                pass
            process.join(5)
        return None, [], "hard_timeout", True
    if queue.empty():
        return None, [], "solver_error:no_result_from_child_process", False
    result = queue.get()
    return (
        result.get("objective_value"),
        result.get("selected", []),
        result.get("solver_status", "solved"),
        False,
    )


def apply_selected_swaps(v, blocks, moves, selected):
    new_blocks = [set(block) for block in blocks]
    for j in selected:
        move = moves[j]
        block_idx = move["block"]
        removed = move["removed"]
        added = move["added"]
        if removed not in new_blocks[block_idx]:
            raise RuntimeError(
                "selected swap removes missing element: block={} removed={}".format(
                    block_idx, removed
                )
            )
        if added in new_blocks[block_idx]:
            raise RuntimeError(
                "selected swap adds existing element: block={} added={}".format(
                    block_idx, added
                )
            )
        new_blocks[block_idx].remove(removed)
        new_blocks[block_idx].add(added)
    return new_blocks


def selected_swap_payload(moves, selected):
    return [
        {
            "block_index": int(moves[j]["block"]),
            "remove": int(moves[j]["removed"]),
            "add": int(moves[j]["added"]),
            "block": int(moves[j]["block"]),
            "removed": int(moves[j]["removed"]),
            "added": int(moves[j]["added"]),
            "score_change": int(moves[j]["score_change"]),
            "l1_change": int(moves[j]["l1_change"]),
            "max_abs_change": int(moves[j]["max_abs_change"]),
            "nonzero_change": int(moves[j]["nonzero_change"]),
            "alignment": int(moves[j]["alignment"]),
            "fix_abs": int(moves[j]["fix_abs"]),
            "damage_abs": int(moves[j]["damage_abs"]),
            "zero_damage": int(moves[j]["zero_damage"]),
            "worst_fix": int(moves[j]["worst_fix"]),
            "worst_over_fix": int(moves[j]["worst_over_fix"]),
            "worst_under_fix": int(moves[j]["worst_under_fix"]),
            "pair_fix": int(moves[j]["pair_fix"]),
            "pair_damage": int(moves[j]["pair_damage"]),
            "active_repair_score": int(moves[j].get("active_repair_score", 0)),
            "active_l1_gain": int(moves[j].get("active_l1_gain", 0)),
            "active_nonzero_gain": int(moves[j].get("active_nonzero_gain", 0)),
            "active_zero_shift_damage": int(
                moves[j].get("active_zero_shift_damage", 0)
            ),
            "pool_categories": sorted(moves[j].get("pool_categories", [])),
        }
        for j in selected
    ]


def metric_tuple_from_record(record):
    return (
        int(record["score"]),
        int(record["l1_error"]),
        int(record["max_abs_error"]),
        int(record["nonzero_defect_count"]),
    )


def parameter_key_from_record(record):
    return (
        int(record["v"]),
        int(record["n"]),
        tuple(int(k) for k in record["ks"]),
        int(record["lambda"]),
    )


def dominates(left, right):
    if parameter_key_from_record(left) != parameter_key_from_record(right):
        return False
    left_metrics = metric_tuple_from_record(left)
    right_metrics = metric_tuple_from_record(right)
    if left_metrics == right_metrics:
        return (
            str(left.get("timestamp", "")),
            str(left.get("source_path", "")),
        ) < (
            str(right.get("timestamp", "")),
            str(right.get("source_path", "")),
        )
    return all(a <= b for a, b in zip(left_metrics, right_metrics)) and any(
        a < b for a, b in zip(left_metrics, right_metrics)
    )


def load_frontier_records(frontier_dir):
    index_path = os.path.join(frontier_dir, "frontier_index.json")
    if not os.path.exists(index_path):
        return []
    with open(index_path) as f:
        data = json.load(f)
    return data.get("records", [])


def write_frontier_records(frontier_dir, records):
    os.makedirs(frontier_dir, exist_ok=True)
    payload = {
        "timestamp": timestamp(),
        "metric_order": ["score", "l1_error", "max_abs_error", "nonzero_defect_count"],
        "records": records,
    }
    write_json(os.path.join(frontier_dir, "frontier_index.json"), payload)


def candidate_record(path, frontier_path, v, n, ks, lam, metrics, label):
    return {
        "path": frontier_path,
        "source_path": path,
        "label": label,
        "v": int(v),
        "n": int(n),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "score": int(metrics[0]),
        "l1_error": int(metrics[1]),
        "max_abs_error": int(metrics[2]),
        "nonzero_defect_count": int(metrics[3]),
        "timestamp": timestamp(),
    }


def copy_candidate_to_frontier(path, frontier_dir):
    os.makedirs(frontier_dir, exist_ok=True)
    with open(path) as f:
        data = json.load(f)
    base = os.path.basename(path)
    out_path = os.path.join(frontier_dir, base)
    if os.path.exists(out_path):
        root, ext = os.path.splitext(out_path)
        idx = 1
        while os.path.exists("{}_{}{}".format(root, idx, ext)):
            idx += 1
        out_path = "{}_{}{}".format(root, idx, ext)
    write_json(out_path, data)
    return out_path


def update_frontier(frontier_dir, candidate_path, v, n, ks, lam, metrics, label):
    records = load_frontier_records(frontier_dir)
    source_key = os.path.normpath(candidate_path)
    existing = None
    for record in records:
        if os.path.normpath(record.get("source_path", "")) == source_key:
            existing = record
            break

    if existing is None:
        frontier_path = copy_candidate_to_frontier(candidate_path, frontier_dir)
        new_record = candidate_record(
            candidate_path, frontier_path, v, n, ks, lam, metrics, label
        )
        records.append(new_record)
    else:
        new_record = existing

    active = []
    dominated = []
    for idx, record in enumerate(records):
        is_dominated = False
        for jdx, other in enumerate(records):
            if idx == jdx:
                continue
            if dominates(other, record):
                is_dominated = True
                break
        if is_dominated:
            dominated.append(record)
        else:
            active.append(record)

    active.sort(
        key=lambda record: (
            parameter_key_from_record(record),
            metric_tuple_from_record(record),
            record.get("path", ""),
        )
    )
    write_frontier_records(frontier_dir, active)
    is_active = any(
        os.path.normpath(record.get("source_path", "")) == source_key
        for record in active
    )
    return {
        "pareto_active": bool(is_active),
        "frontier_active_count": int(len(active)),
        "dominated_removed_count": int(len(dominated)),
        "frontier_path": new_record.get("path", ""),
    }


def make_row(
    round_index,
    pool_size,
    total_swaps,
    selected_count,
    old_metrics,
    new_metrics,
    objective_value,
    accepted,
    elapsed,
    path,
    pool_mode,
    pareto_info,
    zero_shift_damage,
    protected_zero_shifts,
    diagnostics=None,
    solver_status="not_run",
    hard_timeout_triggered=False,
    accepted_by_worsen_limits=True,
    rejected_reason="",
    metric_improved=False,
):
    pareto_info = pareto_info or {}
    diagnostics = diagnostics or {}
    active_shifts_used = diagnostics.get("active_shifts_used", [])
    return {
        "timestamp": timestamp(),
        "round": int(round_index),
        "pool_mode": pool_mode,
        "pool_size": int(pool_size),
        "total_swaps": int(total_swaps),
        "selected_count": int(selected_count),
        "selected_moves_count": int(selected_count),
        "old_score": int(old_metrics[0]),
        "old_l1_error": int(old_metrics[1]),
        "old_max_abs_error": int(old_metrics[2]),
        "old_nonzero_defect_count": int(old_metrics[3]),
        "score": int(new_metrics[0]),
        "l1_error": int(new_metrics[1]),
        "max_abs_error": int(new_metrics[2]),
        "nonzero_defect_count": int(new_metrics[3]),
        "zero_shift_damage": int(zero_shift_damage),
        "protected_zero_shifts": int(protected_zero_shifts),
        "objective_value": "" if objective_value is None else float(objective_value),
        "active_top_k_shifts": (
            ""
            if diagnostics.get("active_top_k_shifts") is None
            else int(diagnostics.get("active_top_k_shifts"))
        ),
        "active_shifts_used": json.dumps(active_shifts_used),
        "active_defect_count": int(diagnostics.get("active_defect_count", 0)),
        "greedy_prefilter": (
            ""
            if diagnostics.get("greedy_prefilter") is None
            else int(diagnostics.get("greedy_prefilter"))
        ),
        "pool_count_before_filter": int(
            diagnostics.get("pool_count_before_filter", pool_size)
        ),
        "pool_count_after_filter": int(
            diagnostics.get("pool_count_after_filter", pool_size)
        ),
        "model_var_count_estimate": int(
            diagnostics.get("model_var_count_estimate", 0)
        ),
        "model_constraint_count_estimate": int(
            diagnostics.get("model_constraint_count_estimate", 0)
        ),
        "hard_timeout_triggered": bool(hard_timeout_triggered),
        "solver_status": solver_status,
        "force_moves": bool(diagnostics.get("force_moves", False)),
        "min_moves": int(diagnostics.get("min_moves", 0)),
        "diagnostic_objective": diagnostics.get("diagnostic_objective", ""),
        "score_worsen_limit": (
            ""
            if diagnostics.get("score_worsen_limit") is None
            else int(diagnostics.get("score_worsen_limit"))
        ),
        "l1_worsen_limit": (
            ""
            if diagnostics.get("l1_worsen_limit") is None
            else int(diagnostics.get("l1_worsen_limit"))
        ),
        "maxabs_limit": (
            ""
            if diagnostics.get("maxabs_limit") is None
            else int(diagnostics.get("maxabs_limit"))
        ),
        "accepted_by_worsen_limits": bool(accepted_by_worsen_limits),
        "rejected_reason": rejected_reason,
        "metric_improved": bool(metric_improved),
        "accepted": bool(accepted),
        "pareto_improving": bool(accepted and pareto_info.get("pareto_active", False)),
        "pareto_active": bool(pareto_info.get("pareto_active", False)),
        "frontier_active_count": int(pareto_info.get("frontier_active_count", 0)),
        "dominated_removed_count": int(pareto_info.get("dominated_removed_count", 0)),
        "frontier_path": pareto_info.get("frontier_path", ""),
        "elapsed_sec": float(elapsed),
        "path": path,
    }


def print_row(row):
    objective_text = row["objective_value"]
    if objective_text == "":
        objective_text = "NA"
    else:
        objective_text = "{:.3f}".format(float(objective_text))
    print(
        "round={round} pool_size={pool_size} selected={selected_count} "
        "pool_mode={pool_mode} "
        "solver_status={solver_status} hard_timeout={hard_timeout_triggered} "
        "force_moves={force_moves} min_moves={min_moves} "
        "diagnostic_objective={diagnostic_objective} "
        "pool_after_filter={pool_count_after_filter} "
        "old=({old_score},{old_l1_error},{old_max_abs_error},{old_nonzero_defect_count}) "
        "new=({score},{l1_error},{max_abs_error},{nonzero_defect_count}) "
        "zero_shift_damage={zero_shift_damage} "
        "protected_zero_shifts={protected_zero_shifts} "
        "limits_ok={accepted_by_worsen_limits} rejected_reason={rejected_reason} "
        "accepted={accepted} pareto_improving={pareto_improving} "
        "pareto_active={pareto_active} "
        "frontier_active_count={frontier_active_count} objective={objective_text} "
        "elapsed_sec={elapsed_sec:.2f} path={path}".format(
            objective_text=objective_text, **row
        )
    )


def acceptance_tuple(metrics, mode):
    score, l1_error, max_abs_error, nonzero_defect_count = metrics
    if mode == "lex":
        return (score, l1_error, max_abs_error, nonzero_defect_count)
    if mode == "max_then_score":
        return (max_abs_error, score, l1_error, nonzero_defect_count)
    if mode == "l1_then_score":
        return (l1_error, score, max_abs_error, nonzero_defect_count)
    if mode == "l1_then_nonzero":
        return (l1_error, nonzero_defect_count, score, max_abs_error)
    if mode == "nonzero_then_l1":
        return (nonzero_defect_count, l1_error, score, max_abs_error)
    raise ValueError("unknown acceptance mode: {}".format(mode))


def check_worsen_limits(before_metrics, after_metrics, args):
    reasons = []
    if args.score_worsen_limit is not None:
        limit = int(before_metrics[0]) + int(args.score_worsen_limit)
        if int(after_metrics[0]) > limit:
            reasons.append(
                "score {} exceeds {}".format(int(after_metrics[0]), int(limit))
            )
    if args.l1_worsen_limit is not None:
        limit = int(before_metrics[1]) + int(args.l1_worsen_limit)
        if int(after_metrics[1]) > limit:
            reasons.append("l1 {} exceeds {}".format(int(after_metrics[1]), int(limit)))
    if args.maxabs_limit is not None:
        if int(after_metrics[2]) > int(args.maxabs_limit):
            reasons.append(
                "max_abs {} exceeds {}".format(
                    int(after_metrics[2]), int(args.maxabs_limit)
                )
            )
    return len(reasons) == 0, "; ".join(reasons)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Repair an SDS near-hit by selecting defect-driven swaps with a small ILP."
    )
    parser.add_argument("json_path", help="Candidate or near-hit JSON path.")
    parser.add_argument("--pool-size", type=int, default=400)
    parser.add_argument(
        "--pool-mode",
        choices=[
            "score",
            "l1",
            "max_abs",
            "worst_shift",
            "zero_protect",
            "low_nonzero",
            "active_defect_lns",
            "mixed",
            "diverse",
        ],
        default="mixed",
        help="How to build the defect-driven swap pool.",
    )
    parser.add_argument(
        "--pool-random-seed",
        type=int,
        default=1,
        help="Seed used only by --pool-mode diverse.",
    )
    parser.add_argument("--max-moves", type=int, default=6)
    parser.add_argument(
        "--max-swaps",
        type=int,
        default=None,
        help="Alias for --max-moves used by active-defect LNS experiments.",
    )
    parser.add_argument(
        "--swap-pool",
        type=int,
        default=None,
        help="Alias for --pool-size used by active-defect LNS experiments.",
    )
    parser.add_argument(
        "--active-defects",
        choices=["nonzero"],
        default="nonzero",
        help="Active defect selection policy for --pool-mode active_defect_lns.",
    )
    parser.add_argument(
        "--active-top-k-shifts",
        type=int,
        default=None,
        help="Use only the top K active shifts by absolute defect for active-defect LNS.",
    )
    parser.add_argument(
        "--greedy-prefilter",
        type=int,
        default=None,
        help="Keep only the top N active-repair scored swaps before building the ILP.",
    )
    parser.add_argument(
        "--min-moves",
        type=int,
        default=None,
        help="Minimum selected swaps when --force-moves is enabled. Defaults to 1.",
    )
    parser.add_argument(
        "--force-moves",
        action="store_true",
        help="Forbid the zero-move ILP solution by adding selected_moves >= min_moves.",
    )
    parser.add_argument(
        "--score-worsen-limit",
        type=int,
        default=None,
        help="Reject forced moves with score above input score plus this limit.",
    )
    parser.add_argument(
        "--l1-worsen-limit",
        type=int,
        default=None,
        help="Constrain/reject forced moves with l1 above input l1 plus this limit.",
    )
    parser.add_argument(
        "--maxabs-limit",
        type=int,
        default=None,
        help="Constrain/reject forced moves with max_abs above this value.",
    )
    parser.add_argument(
        "--diagnostic-objective",
        choices=[
            "move_l1_repair",
            "move_nonzero_repair",
            "move_balanced",
            "move_escape",
        ],
        default=None,
        help="Move-level diagnostic objective used with --force-moves.",
    )
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument(
        "--objective",
        choices=[
            "l1",
            "max_then_l1",
            "score",
            "score_then_l1",
            "score_zero_protect",
            "zero_protect_score",
            "l1_then_nonzero",
            "nonzero_then_l1",
        ],
        default="max_then_l1",
    )
    parser.add_argument(
        "--zero-protect-weight",
        type=int,
        default=100000,
        help="Penalty weight for damaging currently zero-defect shifts.",
    )
    parser.add_argument(
        "--residual-bound",
        type=int,
        default=12,
        help="Residual value bound used by score/score_then_l1 objectives.",
    )
    parser.add_argument(
        "--acceptance",
        choices=[
            "lex",
            "max_then_score",
            "l1_then_score",
            "l1_then_nonzero",
            "nonzero_then_l1",
        ],
        default="lex",
        help="Metric tuple used to accept the ILP result.",
    )
    parser.add_argument("--solver-log", action="store_true")
    parser.add_argument(
        "--time-limit",
        type=int,
        default=None,
        help="Optional solver time limit in seconds, if supported by the backend.",
    )
    parser.add_argument(
        "--hard-time-limit",
        type=int,
        default=None,
        help="Python-side hard stop in seconds for pool generation and solving.",
    )
    parser.add_argument(
        "--dry-run-pool-stats",
        action="store_true",
        help="Build and log the active pool/model size estimate without solving the ILP.",
    )
    parser.add_argument(
        "--near-hit-dir",
        default="outputs/candidates/near_hits",
        help="Directory for repaired near-hit JSON files.",
    )
    parser.add_argument(
        "--candidate-dir",
        default="outputs/candidates",
        help="Directory for fully verified success candidates.",
    )
    parser.add_argument(
        "--frontier-dir",
        default="outputs/candidates/near_hits/frontier",
        help="Directory for Pareto frontier index and copied frontier JSON files.",
    )
    parser.add_argument(
        "--canonical-dedup",
        action="store_true",
        help="Accepted for repair workflow compatibility; saved payloads already carry canonical hashes.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging("13_ilp_repair_from_near_hit")
    csv_path = os.path.join(
        "outputs/logs", "13_ilp_repair_from_near_hit_{}.csv".format(stamp)
    )
    csv_file = None
    try:
        if args.pool_size < 1:
            raise ValueError("--pool-size must be positive")
        if args.swap_pool is not None:
            args.pool_size = int(args.swap_pool)
        if args.max_swaps is not None:
            args.max_moves = int(args.max_swaps)
        if args.min_moves is None:
            args.min_moves = 1 if args.force_moves else 0
        if args.max_moves < 1:
            raise ValueError("--max-moves must be positive")
        if args.min_moves < 0:
            raise ValueError("--min-moves must be nonnegative")
        if args.force_moves and args.min_moves < 1:
            raise ValueError("--force-moves requires --min-moves >= 1")
        if args.force_moves and args.min_moves > args.max_moves:
            raise ValueError("--min-moves cannot exceed --max-moves")
        if args.rounds < 1:
            raise ValueError("--rounds must be positive")
        if args.residual_bound < 1:
            raise ValueError("--residual-bound must be positive")
        if args.active_top_k_shifts is not None and args.active_top_k_shifts < 1:
            raise ValueError("--active-top-k-shifts must be positive")
        if args.greedy_prefilter is not None and args.greedy_prefilter < 1:
            raise ValueError("--greedy-prefilter must be positive")
        if args.hard_time_limit is not None and args.hard_time_limit < 1:
            raise ValueError("--hard-time-limit must be positive")
        if args.score_worsen_limit is not None and args.score_worsen_limit < 0:
            raise ValueError("--score-worsen-limit must be nonnegative")
        if args.l1_worsen_limit is not None and args.l1_worsen_limit < 0:
            raise ValueError("--l1-worsen-limit must be nonnegative")
        if args.maxabs_limit is not None and args.maxabs_limit < 0:
            raise ValueError("--maxabs-limit must be nonnegative")
        if args.force_moves and args.diagnostic_objective is None:
            args.diagnostic_objective = "move_balanced"

        data, v, n, ks, lam, blocks = load_candidate(args.json_path)
        counts = total_diff_counts(v, blocks)
        metrics = metrics_from_counts(counts, lam)
        input_metrics = metrics
        rng = random.Random(int(args.pool_random_seed))
        start = time.time()

        os.makedirs("outputs/logs", exist_ok=True)
        csv_file = open(csv_path, "w")
        fieldnames = [
            "timestamp",
            "round",
            "pool_mode",
            "pool_size",
            "total_swaps",
            "pool_count_before_filter",
            "pool_count_after_filter",
            "selected_count",
            "selected_moves_count",
            "solver_status",
            "hard_timeout_triggered",
            "force_moves",
            "min_moves",
            "diagnostic_objective",
            "score_worsen_limit",
            "l1_worsen_limit",
            "maxabs_limit",
            "accepted_by_worsen_limits",
            "rejected_reason",
            "metric_improved",
            "old_score",
            "old_l1_error",
            "old_max_abs_error",
            "old_nonzero_defect_count",
            "score",
            "l1_error",
            "max_abs_error",
            "nonzero_defect_count",
            "zero_shift_damage",
            "protected_zero_shifts",
            "objective_value",
            "active_top_k_shifts",
            "active_shifts_used",
            "active_defect_count",
            "greedy_prefilter",
            "model_var_count_estimate",
            "model_constraint_count_estimate",
            "accepted",
            "pareto_improving",
            "pareto_active",
            "frontier_active_count",
            "dominated_removed_count",
            "frontier_path",
            "elapsed_sec",
            "path",
        ]
        csv_writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        csv_writer.writeheader()

        print("CSV log:", csv_path)
        print("Input:", args.json_path)
        print("v={} n={} ks={} lambda={}".format(v, n, ks, lam))
        print(
            "pool_size={} pool_mode={} max_moves={} rounds={} objective={} "
            "acceptance={} residual_bound={} zero_protect_weight={} "
            "pool_random_seed={} active_top_k_shifts={} greedy_prefilter={} "
            "force_moves={} min_moves={} diagnostic_objective={} "
            "score_worsen_limit={} l1_worsen_limit={} maxabs_limit={} "
            "time_limit={} hard_time_limit={} dry_run_pool_stats={}".format(
                args.pool_size,
                args.pool_mode,
                args.max_moves,
                args.rounds,
                args.objective,
                args.acceptance,
                args.residual_bound,
                args.zero_protect_weight,
                args.pool_random_seed,
                args.active_top_k_shifts,
                args.greedy_prefilter,
                args.force_moves,
                args.min_moves,
                args.diagnostic_objective,
                args.score_worsen_limit,
                args.l1_worsen_limit,
                args.maxabs_limit,
                args.time_limit,
                args.hard_time_limit,
                args.dry_run_pool_stats,
            )
        )
        if args.objective == "nonzero_then_l1":
            print(
                "WARNING: nonzero_then_l1 is experimental/heavy; prefer "
                "l1_then_nonzero for bounded active-defect diagnostics."
            )
        print(
            "initial score={} l1_error={} max_abs_error={} "
            "nonzero_defect_count={}".format(
                metrics[0], metrics[1], metrics[2], metrics[3]
            )
        )

        path = args.json_path
        pareto_info = update_frontier(
            args.frontier_dir,
            path,
            v,
            n,
            ks,
            lam,
            metrics,
            "input",
        )
        print("Input frontier status:", pareto_info)
        if metrics[0] == 0:
            print("FOUND score 0 at input; running exact verification")
            path = save_success(
                args.candidate_dir,
                args.near_hit_dir,
                v,
                ks,
                lam,
                blocks,
                metrics,
                args.json_path,
                SEARCH_METHOD,
                0,
                0,
                counts,
                {"input_score": data.get("score")},
            )
            return

        for round_index in range(1, args.rounds + 1):
            old_metrics = metrics
            diagnostics = {}
            objective_value = None
            selected = []
            solver_status = "not_run"
            hard_timeout_triggered = False
            alarm_handler = None
            try:
                alarm_handler = start_hard_timeout(
                    hard_timeout_remaining(start, args.hard_time_limit)
                )
                defects = defect_vector(counts, lam)
                active_shifts = choose_active_shifts(
                    v, defects, args.active_defects, args.active_top_k_shifts
                )
                moves, total_swaps = build_defect_driven_pool(
                    v, blocks, counts, lam, args.pool_size, args.pool_mode, rng
                )
                pool_count_before_filter = len(moves)
                moves = greedy_prefilter_moves(
                    moves, defects, active_shifts, args.greedy_prefilter
                )
                diagnostics = build_pool_diagnostics(
                    args,
                    v,
                    counts,
                    lam,
                    moves,
                    total_swaps,
                    pool_count_before_filter,
                    active_shifts,
                )
                print_solver_preamble(args, args.json_path, metrics, diagnostics)
                if csv_file is not None:
                    csv_file.flush()
                pool_stats = dict(diagnostics)
                pool_stats.update(
                    {
                        "timestamp": timestamp(),
                        "round": int(round_index),
                        "input_path": args.json_path,
                        "metrics": {
                            "score": int(metrics[0]),
                            "l1_error": int(metrics[1]),
                            "max_abs_error": int(metrics[2]),
                            "nonzero_defect_count": int(metrics[3]),
                        },
                    }
                )
                stats_paths = write_pool_stats_files(stamp, round_index, pool_stats)
                diagnostics.update(stats_paths)
                if args.dry_run_pool_stats:
                    solver_status = "dry_run"
                    zero_shift_damage, protected_zero_shifts = zero_protection_stats(
                        v, counts, counts, lam
                    )
                    row = make_row(
                        round_index,
                        len(moves),
                        total_swaps,
                        0,
                        old_metrics,
                        old_metrics,
                        objective_value,
                        False,
                        time.time() - start,
                        path,
                        args.pool_mode,
                        pareto_info,
                        zero_shift_damage,
                        protected_zero_shifts,
                        diagnostics,
                        solver_status,
                        hard_timeout_triggered,
                    )
                    csv_writer.writerow(row)
                    csv_file.flush()
                    print_row(row)
                    print("STOP: dry-run pool stats requested; ILP was not solved")
                    break
                stop_hard_timeout(alarm_handler)
                alarm_handler = None
                (
                    objective_value,
                    selected,
                    solver_status,
                    hard_timeout_triggered,
                ) = solve_ilp_guarded(
                    v,
                    blocks,
                    counts,
                    lam,
                    moves,
                    args.max_moves,
                    args.objective,
                    args.residual_bound,
                    args.zero_protect_weight,
                    args.time_limit,
                    args.solver_log,
                    hard_timeout_remaining(start, args.hard_time_limit),
                    args.min_moves,
                    args.force_moves,
                    args.score_worsen_limit,
                    args.l1_worsen_limit,
                    args.maxabs_limit,
                    args.diagnostic_objective,
                    input_metrics,
                )
            except HardTimeout as exc:
                hard_timeout_triggered = True
                solver_status = "hard_timeout"
                print("STOP: hard time limit triggered: {}".format(exc))
                sys.stdout.flush()
                if diagnostics:
                    timeout_stats = dict(diagnostics)
                    timeout_stats.update(
                        {
                            "timestamp": timestamp(),
                            "round": int(round_index),
                            "input_path": args.json_path,
                            "hard_timeout_triggered": True,
                            "solver_status": solver_status,
                        }
                    )
                    write_pool_stats_files(stamp, round_index, timeout_stats)
                zero_shift_damage, protected_zero_shifts = zero_protection_stats(
                    v, counts, counts, lam
                )
                row = make_row(
                    round_index,
                    int(diagnostics.get("pool_count_after_filter", 0)),
                    int(diagnostics.get("candidate_swap_count_before_filtering", 0)),
                    0,
                    old_metrics,
                    old_metrics,
                    objective_value,
                    False,
                    time.time() - start,
                    path,
                    args.pool_mode,
                    pareto_info,
                    zero_shift_damage,
                    protected_zero_shifts,
                    diagnostics,
                    solver_status,
                    hard_timeout_triggered,
                )
                csv_writer.writerow(row)
                csv_file.flush()
                print_row(row)
                break
            finally:
                stop_hard_timeout(alarm_handler)

            if not moves:
                print("STOP: move pool is empty")
                break

            if hard_timeout_triggered:
                zero_shift_damage, protected_zero_shifts = zero_protection_stats(
                    v, counts, counts, lam
                )
                row = make_row(
                    round_index,
                    len(moves),
                    total_swaps,
                    0,
                    old_metrics,
                    old_metrics,
                    objective_value,
                    False,
                    time.time() - start,
                    path,
                    args.pool_mode,
                    pareto_info,
                    zero_shift_damage,
                    protected_zero_shifts,
                    diagnostics,
                    solver_status,
                    hard_timeout_triggered,
                )
                csv_writer.writerow(row)
                csv_file.flush()
                print_row(row)
                print("STOP: hard time limit terminated ILP child process")
                break

            if not selected:
                zero_shift_damage, protected_zero_shifts = zero_protection_stats(
                    v, counts, counts, lam
                )
                row = make_row(
                    round_index,
                    len(moves),
                    total_swaps,
                    0,
                    old_metrics,
                    old_metrics,
                    objective_value,
                    False,
                    time.time() - start,
                    path,
                    args.pool_mode,
                    pareto_info,
                    zero_shift_damage,
                    protected_zero_shifts,
                    diagnostics,
                    solver_status,
                    hard_timeout_triggered,
                )
                csv_writer.writerow(row)
                csv_file.flush()
                print_row(row)
                print("STOP: ILP selected no swaps")
                break

            trial_blocks = apply_selected_swaps(v, blocks, moves, selected)
            trial_counts = total_diff_counts(v, trial_blocks)
            trial_metrics = metrics_from_counts(trial_counts, lam)
            zero_shift_damage, protected_zero_shifts = zero_protection_stats(
                v, counts, trial_counts, lam
            )
            metric_improved = acceptance_tuple(trial_metrics, args.acceptance) < acceptance_tuple(
                metrics, args.acceptance
            )
            accepted_by_worsen_limits, rejected_reason = check_worsen_limits(
                input_metrics, trial_metrics, args
            )
            accepted = bool(metric_improved or (args.force_moves and accepted_by_worsen_limits))
            selected_payload = selected_swap_payload(moves, selected)

            if accepted:
                blocks = trial_blocks
                counts = trial_counts
                metrics = trial_metrics
                path = save_near_hit(
                    args.near_hit_dir,
                    v,
                    ks,
                    lam,
                    blocks,
                    metrics,
                    args.json_path,
                    SEARCH_METHOD,
                    round_index,
                    round_index,
                    counts,
                    {
                        "objective": args.objective,
                        "acceptance": args.acceptance,
                        "force_moves": bool(args.force_moves),
                        "min_moves": int(args.min_moves),
                        "diagnostic_objective": args.diagnostic_objective,
                        "score_worsen_limit": args.score_worsen_limit,
                        "l1_worsen_limit": args.l1_worsen_limit,
                        "maxabs_limit": args.maxabs_limit,
                        "accepted_by_worsen_limits": bool(
                            accepted_by_worsen_limits
                        ),
                        "rejected_reason": rejected_reason,
                        "metric_improved": bool(metric_improved),
                        "pool_mode": args.pool_mode,
                        "pool_random_seed": int(args.pool_random_seed),
                        "residual_bound": int(args.residual_bound),
                        "zero_protect_weight": int(args.zero_protect_weight),
                        "zero_shift_damage": int(zero_shift_damage),
                        "protected_zero_shifts": int(protected_zero_shifts),
                        "objective_value": float(objective_value),
                        "pool_size": int(len(moves)),
                        "total_swaps": int(total_swaps),
                        "active_top_k_shifts": diagnostics.get(
                            "active_top_k_shifts"
                        ),
                        "active_shifts_used": diagnostics.get(
                            "active_shifts_used", []
                        ),
                        "active_defect_count": int(
                            diagnostics.get("active_defect_count", 0)
                        ),
                        "greedy_prefilter": diagnostics.get("greedy_prefilter"),
                        "pool_count_before_filter": int(
                            diagnostics.get("pool_count_before_filter", len(moves))
                        ),
                        "pool_count_after_filter": int(
                            diagnostics.get("pool_count_after_filter", len(moves))
                        ),
                        "model_var_count_estimate": int(
                            diagnostics.get("model_var_count_estimate", 0)
                        ),
                        "model_constraint_count_estimate": int(
                            diagnostics.get("model_constraint_count_estimate", 0)
                        ),
                        "hard_timeout_triggered": bool(hard_timeout_triggered),
                        "solver_status": solver_status,
                        "max_moves": int(args.max_moves),
                        "selected_moves_count": int(len(selected)),
                        "selected_moves": selected_payload,
                        "selected_swaps": selected_payload,
                        "before_metrics": {
                            "score": int(old_metrics[0]),
                            "l1_error": int(old_metrics[1]),
                            "max_abs_error": int(old_metrics[2]),
                            "nonzero_defect_count": int(old_metrics[3]),
                        },
                        "after_metrics": {
                            "score": int(trial_metrics[0]),
                            "l1_error": int(trial_metrics[1]),
                            "max_abs_error": int(trial_metrics[2]),
                            "nonzero_defect_count": int(trial_metrics[3]),
                        },
                    },
                )
                pareto_info = update_frontier(
                    args.frontier_dir,
                    path,
                    v,
                    n,
                    ks,
                    lam,
                    metrics,
                    "accepted_round_{}".format(round_index),
                )
            else:
                pareto_info = update_frontier(
                    args.frontier_dir,
                    path,
                    v,
                    n,
                    ks,
                    lam,
                    metrics,
                    "unchanged_round_{}".format(round_index),
                )
            row = make_row(
                round_index,
                len(moves),
                total_swaps,
                len(selected),
                old_metrics,
                trial_metrics,
                objective_value,
                accepted,
                time.time() - start,
                path,
                args.pool_mode,
                pareto_info,
                zero_shift_damage,
                protected_zero_shifts,
                diagnostics,
                solver_status,
                hard_timeout_triggered,
                accepted_by_worsen_limits,
                rejected_reason,
                metric_improved,
            )
            csv_writer.writerow(row)
            csv_file.flush()
            print_row(row)
            print("selected_swaps={}".format(selected_payload))

            if not accepted:
                if rejected_reason:
                    print("STOP: forced ILP result rejected: {}".format(rejected_reason))
                else:
                    print("STOP: ILP result did not improve exact metric tuple")
                break

            if metrics[0] == 0:
                print(
                    "FOUND score 0 after round {}; running exact verification".format(
                        round_index
                    )
                )
                path = save_success(
                    args.candidate_dir,
                    args.near_hit_dir,
                    v,
                    ks,
                    lam,
                    blocks,
                    metrics,
                    args.json_path,
                    SEARCH_METHOD,
                    round_index,
                    round_index,
                    counts,
                    {
                        "objective": args.objective,
                        "acceptance": args.acceptance,
                        "force_moves": bool(args.force_moves),
                        "min_moves": int(args.min_moves),
                        "diagnostic_objective": args.diagnostic_objective,
                        "score_worsen_limit": args.score_worsen_limit,
                        "l1_worsen_limit": args.l1_worsen_limit,
                        "maxabs_limit": args.maxabs_limit,
                        "accepted_by_worsen_limits": bool(
                            accepted_by_worsen_limits
                        ),
                        "rejected_reason": rejected_reason,
                        "metric_improved": bool(metric_improved),
                        "pool_mode": args.pool_mode,
                        "pool_random_seed": int(args.pool_random_seed),
                        "residual_bound": int(args.residual_bound),
                        "zero_protect_weight": int(args.zero_protect_weight),
                        "zero_shift_damage": int(zero_shift_damage),
                        "protected_zero_shifts": int(protected_zero_shifts),
                        "objective_value": float(objective_value),
                        "pool_size": int(len(moves)),
                        "total_swaps": int(total_swaps),
                        "active_top_k_shifts": diagnostics.get(
                            "active_top_k_shifts"
                        ),
                        "active_shifts_used": diagnostics.get(
                            "active_shifts_used", []
                        ),
                        "active_defect_count": int(
                            diagnostics.get("active_defect_count", 0)
                        ),
                        "greedy_prefilter": diagnostics.get("greedy_prefilter"),
                        "pool_count_before_filter": int(
                            diagnostics.get("pool_count_before_filter", len(moves))
                        ),
                        "pool_count_after_filter": int(
                            diagnostics.get("pool_count_after_filter", len(moves))
                        ),
                        "model_var_count_estimate": int(
                            diagnostics.get("model_var_count_estimate", 0)
                        ),
                        "model_constraint_count_estimate": int(
                            diagnostics.get("model_constraint_count_estimate", 0)
                        ),
                        "hard_timeout_triggered": bool(hard_timeout_triggered),
                        "solver_status": solver_status,
                        "max_moves": int(args.max_moves),
                        "selected_moves_count": int(len(selected)),
                        "selected_moves": selected_payload,
                        "selected_swaps": selected_payload,
                        "before_metrics": {
                            "score": int(old_metrics[0]),
                            "l1_error": int(old_metrics[1]),
                            "max_abs_error": int(old_metrics[2]),
                            "nonzero_defect_count": int(old_metrics[3]),
                        },
                        "after_metrics": {
                            "score": int(metrics[0]),
                            "l1_error": int(metrics[1]),
                            "max_abs_error": int(metrics[2]),
                            "nonzero_defect_count": int(metrics[3]),
                        },
                    },
                )
                break

        print(
            "DONE: final score={} l1_error={} max_abs_error={} "
            "nonzero_defect_count={} path={}".format(
                metrics[0], metrics[1], metrics[2], metrics[3], path
            )
        )
    finally:
        if csv_file is not None:
            csv_file.close()
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
