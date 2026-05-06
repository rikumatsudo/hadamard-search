from sage.all import *

import argparse
import json
import math
import os
import signal
import sys
import time

from sds_repair_utils import (
    canonical_hash,
    load_candidate,
    metrics_from_counts,
    save_near_hit,
    save_success,
    setup_logging,
    timestamp,
    total_diff_counts,
    write_json,
)


SEARCH_METHOD = "partial_membership_lns_repair"


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


def defect_vector(counts, lam):
    return [0] + [int(counts[d] - lam) for d in range(1, len(counts))]


def choose_active_shifts(v, defects, top_k):
    shifts = [d for d in range(1, v) if defects[d] != 0]
    shifts.sort(key=lambda d: (-abs(defects[d]), d))
    return sorted(shifts[: int(top_k)])


def remove_delta(v, block, removed):
    delta = [0] * int(v)
    for y in block:
        if y == removed:
            continue
        delta[(removed - y) % v] -= 1
        delta[(y - removed) % v] -= 1
    return delta


def add_delta(v, block, added):
    delta = [0] * int(v)
    for y in block:
        if y == added:
            continue
        delta[(added - y) % v] += 1
        delta[(y - added) % v] += 1
    return delta


def apply_delta_to_defects(defects, delta):
    return [int(defects[d] + delta[d]) for d in range(len(defects))]


def active_l1(defects, active_shifts):
    return sum(abs(int(defects[d])) for d in active_shifts)


def active_nonzero(defects, active_shifts):
    return sum(1 for d in active_shifts if int(defects[d]) != 0)


def zero_shift_damage(defects_before, defects_after):
    damage = 0
    protected = 0
    for d in range(1, len(defects_before)):
        if int(defects_before[d]) == 0:
            protected += 1
            damage += abs(int(defects_after[d]))
    return int(damage), int(protected)


def score_single_delta(defects, delta, active_shifts):
    before_active = active_l1(defects, active_shifts)
    after = apply_delta_to_defects(defects, delta)
    after_active = active_l1(after, active_shifts)
    zero_damage, _ = zero_shift_damage(defects, after)
    total_l1_gain = sum(abs(defects[d]) for d in range(1, len(defects))) - sum(
        abs(after[d]) for d in range(1, len(defects))
    )
    return {
        "active_l1_gain": int(before_active - after_active),
        "total_l1_gain": int(total_l1_gain),
        "zero_damage": int(zero_damage),
        "after_active_l1": int(after_active),
    }


def choose_free_candidates(v, blocks, counts, lam, active_shifts, free_per_block):
    defects = defect_vector(counts, lam)
    remove_candidates = {}
    add_candidates = {}
    all_shifts = list(range(1, v))
    for block_idx, block in enumerate(blocks):
        removals = []
        for value in sorted(block):
            delta = remove_delta(v, block, value)
            stats = score_single_delta(defects, delta, active_shifts)
            removals.append(
                {
                    "block": int(block_idx),
                    "value": int(value),
                    "delta": delta,
                    "kind": "remove",
                    "rank": (
                        -stats["active_l1_gain"],
                        stats["zero_damage"],
                        -stats["total_l1_gain"],
                        value,
                    ),
                    "stats": stats,
                }
            )
        additions = []
        outside = [value for value in range(v) if value not in block]
        for value in outside:
            delta = add_delta(v, block, value)
            stats = score_single_delta(defects, delta, active_shifts)
            additions.append(
                {
                    "block": int(block_idx),
                    "value": int(value),
                    "delta": delta,
                    "kind": "add",
                    "rank": (
                        -stats["active_l1_gain"],
                        stats["zero_damage"],
                        -stats["total_l1_gain"],
                        value,
                    ),
                    "stats": stats,
                }
            )
        removals.sort(key=lambda item: item["rank"])
        additions.sort(key=lambda item: item["rank"])
        remove_candidates[block_idx] = removals[: int(free_per_block)]
        add_candidates[block_idx] = additions[: int(free_per_block)]
    return remove_candidates, add_candidates


def estimate_model_size(v, active_shifts, remove_candidates, add_candidates):
    remove_count = sum(len(items) for items in remove_candidates.values())
    add_count = sum(len(items) for items in add_candidates.values())
    var_count = remove_count + add_count
    # Active pos/neg, all-shift max_abs pos/neg, zero-damage pos/neg, max_abs var.
    var_count += 2 * len(active_shifts)
    var_count += 2 * (v - 1) + 1
    zero_shift_count = (v - 1) - len(set(active_shifts))
    var_count += 2 * zero_shift_count
    constraint_count = 4  # rough global move constraints
    constraint_count += 4 * 3  # per-block balance and caps
    constraint_count += len(active_shifts)
    constraint_count += 3 * (v - 1)
    constraint_count += zero_shift_count
    return {
        "remove_var_count": int(remove_count),
        "add_var_count": int(add_count),
        "model_var_count_estimate": int(var_count),
        "model_constraint_count_estimate": int(constraint_count),
        "zero_shift_count": int(zero_shift_count),
    }


def serialize_candidate_map(candidate_map):
    out = {}
    for block_idx, items in candidate_map.items():
        out[str(block_idx)] = [
            {
                "value": int(item["value"]),
                "stats": item["stats"],
            }
            for item in items
        ]
    return out


def build_and_solve_lns(
    args,
    v,
    blocks,
    counts,
    lam,
    active_shifts,
    remove_candidates,
    add_candidates,
):
    defects = defect_vector(counts, lam)
    p = MixedIntegerLinearProgram(maximization=False)
    rvar = p.new_variable(binary=True, name="remove")
    avar = p.new_variable(binary=True, name="add")
    active_pos = p.new_variable(nonnegative=True, name="active_pos")
    active_neg = p.new_variable(nonnegative=True, name="active_neg")
    all_pos = p.new_variable(nonnegative=True, name="all_pos")
    all_neg = p.new_variable(nonnegative=True, name="all_neg")
    zero_pos = p.new_variable(nonnegative=True, name="zero_pos")
    zero_neg = p.new_variable(nonnegative=True, name="zero_neg")
    max_abs = p.new_variable(nonnegative=True, name="max_abs")

    remove_keys = []
    add_keys = []
    for block_idx, items in remove_candidates.items():
        for local_idx, item in enumerate(items):
            remove_keys.append((int(block_idx), int(local_idx)))
    for block_idx, items in add_candidates.items():
        for local_idx, item in enumerate(items):
            add_keys.append((int(block_idx), int(local_idx)))

    selected_remove = sum(rvar[key] for key in remove_keys)
    selected_add = sum(avar[key] for key in add_keys)
    p.add_constraint(selected_remove >= int(args.min_moves))
    p.add_constraint(selected_add >= int(args.min_moves))
    p.add_constraint(selected_remove <= int(args.max_remove_per_block) * 4)
    p.add_constraint(selected_add <= int(args.max_add_per_block) * 4)

    for block_idx in range(4):
        r_keys = [(block_idx, idx) for idx in range(len(remove_candidates[block_idx]))]
        a_keys = [(block_idx, idx) for idx in range(len(add_candidates[block_idx]))]
        r_sum = sum(rvar[key] for key in r_keys)
        a_sum = sum(avar[key] for key in a_keys)
        p.add_constraint(r_sum == a_sum)
        p.add_constraint(r_sum <= int(args.max_remove_per_block))
        p.add_constraint(a_sum <= int(args.max_add_per_block))

    active_l1_terms = []
    all_l1_terms = []
    zero_terms = []
    active_set = set(active_shifts)
    for d in range(1, v):
        delta_expr = 0
        for block_idx, items in remove_candidates.items():
            for local_idx, item in enumerate(items):
                delta_expr += int(item["delta"][d]) * rvar[(block_idx, local_idx)]
        for block_idx, items in add_candidates.items():
            for local_idx, item in enumerate(items):
                delta_expr += int(item["delta"][d]) * avar[(block_idx, local_idx)]
        expr = int(defects[d]) + delta_expr
        p.add_constraint(expr == all_pos[d] - all_neg[d])
        p.add_constraint(expr <= max_abs[0])
        p.add_constraint(-expr <= max_abs[0])
        all_l1_terms.append(all_pos[d] + all_neg[d])
        if d in active_set:
            p.add_constraint(expr == active_pos[d] - active_neg[d])
            active_l1_terms.append(active_pos[d] + active_neg[d])
        elif int(defects[d]) == 0:
            p.add_constraint(expr == zero_pos[d] - zero_neg[d])
            zero_terms.append(zero_pos[d] + zero_neg[d])

    if args.maxabs_bound is not None:
        p.add_constraint(max_abs[0] <= int(args.maxabs_bound))
    if args.zero_damage_bound is not None and zero_terms:
        p.add_constraint(sum(zero_terms) <= int(args.zero_damage_bound))
    if args.time_limit is not None:
        try:
            p.solver_parameter("timelimit", int(args.time_limit))
        except Exception as exc:
            print("WARNING: solver time limit was not applied: {}".format(exc))

    selected_count = selected_remove + selected_add
    if args.objective == "active_l1":
        p.set_objective(1000000 * sum(active_l1_terms) + 1000 * sum(all_l1_terms) + selected_count)
    elif args.objective == "active_l1_zero":
        p.set_objective(
            1000000 * sum(active_l1_terms)
            + 10000 * sum(zero_terms)
            + 1000 * sum(all_l1_terms)
            + selected_count
        )
    elif args.objective == "active_balanced":
        p.set_objective(
            1000000 * sum(active_l1_terms)
            + 10000 * max_abs[0]
            + 5000 * sum(zero_terms)
            + 1000 * sum(all_l1_terms)
            + selected_count
        )
    else:
        raise ValueError("unknown objective: {}".format(args.objective))

    objective_value = p.solve(log=bool(args.solver_log))
    r_values = p.get_values(rvar)
    a_values = p.get_values(avar)

    selected_removes = []
    selected_adds = []
    for block_idx, items in remove_candidates.items():
        for local_idx, item in enumerate(items):
            if r_values.get((block_idx, local_idx), 0) > 0.5:
                selected_removes.append(
                    {
                        "block_index": int(block_idx),
                        "value": int(item["value"]),
                        "stats": item["stats"],
                    }
                )
    for block_idx, items in add_candidates.items():
        for local_idx, item in enumerate(items):
            if a_values.get((block_idx, local_idx), 0) > 0.5:
                selected_adds.append(
                    {
                        "block_index": int(block_idx),
                        "value": int(item["value"]),
                        "stats": item["stats"],
                    }
                )
    return float(objective_value), selected_removes, selected_adds


def apply_remove_adds(blocks, selected_removes, selected_adds):
    new_blocks = [set(block) for block in blocks]
    for item in selected_removes:
        block_idx = int(item["block_index"])
        value = int(item["value"])
        if value not in new_blocks[block_idx]:
            raise RuntimeError("selected remove missing value block={} value={}".format(block_idx, value))
        new_blocks[block_idx].remove(value)
    for item in selected_adds:
        block_idx = int(item["block_index"])
        value = int(item["value"])
        if value in new_blocks[block_idx]:
            raise RuntimeError("selected add existing value block={} value={}".format(block_idx, value))
        new_blocks[block_idx].add(value)
    return new_blocks


def exact_post_validation(v, lam, before_counts, after_counts, args):
    before_metrics = metrics_from_counts(before_counts, lam)
    after_metrics = metrics_from_counts(after_counts, lam)
    before_defects = defect_vector(before_counts, lam)
    after_defects = defect_vector(after_counts, lam)
    zero_damage, protected = zero_shift_damage(before_defects, after_defects)
    reasons = []
    if int(after_metrics[0]) > int(before_metrics[0]) + int(args.score_slack):
        reasons.append(
            "score {} exceeds before+slack {}".format(
                int(after_metrics[0]), int(before_metrics[0]) + int(args.score_slack)
            )
        )
    if args.maxabs_bound is not None and int(after_metrics[2]) > int(args.maxabs_bound):
        reasons.append("max_abs {} exceeds {}".format(int(after_metrics[2]), int(args.maxabs_bound)))
    if args.zero_damage_bound is not None and int(zero_damage) > int(args.zero_damage_bound):
        reasons.append("zero_damage {} exceeds {}".format(int(zero_damage), int(args.zero_damage_bound)))
    return {
        "before_metrics": [int(x) for x in before_metrics],
        "after_metrics": [int(x) for x in after_metrics],
        "zero_shift_damage": int(zero_damage),
        "protected_zero_shifts": int(protected),
        "accepted_by_bounds": not reasons,
        "rejected_reason": "; ".join(reasons),
    }


def write_stats_files(stamp, stats):
    base = os.path.join("outputs/logs", "21_partial_membership_lns_repair_{}_model_stats".format(stamp))
    json_path = base + ".json"
    md_path = base + ".md"
    write_json(json_path, stats)
    with open(md_path, "w") as f:
        f.write("# Partial Membership LNS Model Stats\n\n")
        for key in sorted(stats):
            value = stats[key]
            if isinstance(value, (list, dict)):
                value = json.dumps(value, sort_keys=True)
            f.write("- `{}`: {}\n".format(key, value))
    print("MODEL_STATS json={} md={}".format(json_path, md_path))
    return json_path, md_path


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("candidate_json")
    parser.add_argument("--active-top-k-shifts", type=int, default=20)
    parser.add_argument("--free-per-block", type=int, default=8)
    parser.add_argument("--max-remove-per-block", type=int, default=3)
    parser.add_argument("--max-add-per-block", type=int, default=3)
    parser.add_argument("--min-moves", type=int, default=1)
    parser.add_argument("--score-slack", type=int, default=40)
    parser.add_argument("--maxabs-bound", type=int, default=4)
    parser.add_argument("--zero-damage-bound", type=int, default=40)
    parser.add_argument(
        "--objective",
        choices=["active_l1", "active_l1_zero", "active_balanced"],
        default="active_l1",
    )
    parser.add_argument("--time-limit", type=int, default=120)
    parser.add_argument("--hard-time-limit", type=int, default=180)
    parser.add_argument("--dry-run-model-stats", action="store_true")
    parser.add_argument("--canonical-dedup", action="store_true")
    parser.add_argument("--solver-log", action="store_true")
    parser.add_argument("--near-hit-dir", default="outputs/candidates/near_hits")
    parser.add_argument("--candidate-dir", default="outputs/candidates")
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging("21_partial_membership_lns_repair")
    old_handler = None
    try:
        data, v, n, ks, lam, blocks = load_candidate(args.candidate_json)
        counts = total_diff_counts(v, blocks)
        metrics = metrics_from_counts(counts, lam)
        defects = defect_vector(counts, lam)
        active_shifts = choose_active_shifts(v, defects, args.active_top_k_shifts)
        remove_candidates, add_candidates = choose_free_candidates(
            v, blocks, counts, lam, active_shifts, args.free_per_block
        )
        estimate = estimate_model_size(v, active_shifts, remove_candidates, add_candidates)
        stats = {
            "input_path": args.candidate_json,
            "v": int(v),
            "n": int(n),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "before_metrics": [int(x) for x in metrics],
            "canonical_hash": canonical_hash(blocks, ks, v),
            "active_top_k_shifts": int(args.active_top_k_shifts),
            "active_shifts_used": [int(d) for d in active_shifts],
            "active_l1_before": int(active_l1(defects, active_shifts)),
            "active_nonzero_before": int(active_nonzero(defects, active_shifts)),
            "free_per_block": int(args.free_per_block),
            "max_remove_per_block": int(args.max_remove_per_block),
            "max_add_per_block": int(args.max_add_per_block),
            "score_slack": int(args.score_slack),
            "maxabs_bound": int(args.maxabs_bound),
            "zero_damage_bound": int(args.zero_damage_bound),
            "objective": args.objective,
            "time_limit": int(args.time_limit),
            "hard_time_limit": int(args.hard_time_limit),
            "remove_candidates": serialize_candidate_map(remove_candidates),
            "add_candidates": serialize_candidate_map(add_candidates),
        }
        stats.update(estimate)
        print("Partial membership LNS pre-solve diagnostics")
        print("  input path:", args.candidate_json)
        print(
            "  before metrics: score={} l1_error={} max_abs_error={} nonzero_defect_count={}".format(
                metrics[0], metrics[1], metrics[2], metrics[3]
            )
        )
        print("  active shifts:", active_shifts)
        print("  model vars estimate:", estimate["model_var_count_estimate"])
        print("  model constraints estimate:", estimate["model_constraint_count_estimate"])
        print("  objective:", args.objective)
        print("  dry_run:", bool(args.dry_run_model_stats))
        sys.stdout.flush()
        stats_json, stats_md = write_stats_files(stamp, stats)
        if args.dry_run_model_stats:
            print("DONE: dry-run model stats only")
            return

        old_handler = start_hard_timeout(args.hard_time_limit)
        start = time.time()
        try:
            objective_value, selected_removes, selected_adds = build_and_solve_lns(
                args,
                v,
                blocks,
                counts,
                lam,
                active_shifts,
                remove_candidates,
                add_candidates,
            )
            solver_status = "solved"
            hard_timeout_triggered = False
        except HardTimeout:
            objective_value = None
            selected_removes = []
            selected_adds = []
            solver_status = "hard_timeout"
            hard_timeout_triggered = True
        except Exception as exc:
            objective_value = None
            selected_removes = []
            selected_adds = []
            solver_status = "solver_error:{}".format(exc)
            hard_timeout_triggered = False
        finally:
            stop_hard_timeout(old_handler)
            old_handler = None

        selected_count = len(selected_removes) + len(selected_adds)
        result = dict(stats)
        result.update(
            {
                "solver_status": solver_status,
                "hard_timeout_triggered": bool(hard_timeout_triggered),
                "objective_value": objective_value,
                "selected_remove_count": len(selected_removes),
                "selected_add_count": len(selected_adds),
                "selected_count": selected_count,
                "selected_removes": selected_removes,
                "selected_adds": selected_adds,
                "elapsed_sec": time.time() - start,
                "stats_json": stats_json,
                "stats_md": stats_md,
            }
        )

        if selected_count == 0:
            result.update(
                {
                    "accepted_by_bounds": False,
                    "rejected_reason": "selected_count=0 or solver did not return a candidate",
                }
            )
            out_path = os.path.join(
                "outputs/logs",
                "21_partial_membership_lns_repair_{}_result.json".format(stamp),
            )
            write_json(out_path, result)
            print("DONE: no selected remove/add set. result={}".format(out_path))
            return

        new_blocks = apply_remove_adds(blocks, selected_removes, selected_adds)
        new_counts = total_diff_counts(v, new_blocks)
        validation = exact_post_validation(v, lam, counts, new_counts, args)
        new_metrics = tuple(int(x) for x in validation["after_metrics"])
        result.update(validation)
        out_path = os.path.join(
            "outputs/logs",
            "21_partial_membership_lns_repair_{}_result.json".format(stamp),
        )
        write_json(out_path, result)
        print(
            "LNS exact result old=({},{},{},{}) new=({},{},{},{}) "
            "selected={} bounds_ok={} reason={}".format(
                metrics[0],
                metrics[1],
                metrics[2],
                metrics[3],
                new_metrics[0],
                new_metrics[1],
                new_metrics[2],
                new_metrics[3],
                selected_count,
                validation["accepted_by_bounds"],
                validation["rejected_reason"],
            )
        )
        if new_metrics[0] == 0:
            success_path = save_success(
                args.candidate_dir,
                args.near_hit_dir,
                v,
                ks,
                lam,
                new_blocks,
                new_metrics,
                args.candidate_json,
                SEARCH_METHOD,
                1,
                selected_count,
                new_counts,
                extra=result,
            )
            print("DONE: verified success candidate={}".format(success_path))
            return
        if validation["accepted_by_bounds"]:
            near_hit_path = save_near_hit(
                args.near_hit_dir,
                v,
                ks,
                lam,
                new_blocks,
                new_metrics,
                args.candidate_json,
                SEARCH_METHOD,
                1,
                selected_count,
                new_counts,
                extra=result,
            )
            print("DONE: near-hit saved path={}".format(near_hit_path))
        else:
            print("DONE: exact candidate rejected by bounds. result={}".format(out_path))
    finally:
        if old_handler is not None:
            stop_hard_timeout(old_handler)
        sys.stdout.flush()
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
