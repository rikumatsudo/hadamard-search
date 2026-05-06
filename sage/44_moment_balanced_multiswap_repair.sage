from sage.all import *

import argparse
import csv
import os
import random
import time

from sds_repair_utils import (
    apply_delta,
    apply_swap_to_blocks,
    delta_swap,
    load_candidate,
    metrics_from_counts,
    p_adic_moment_summary,
    save_near_hit,
    save_success,
    setup_logging,
    timestamp,
    total_diff_counts,
)


SEARCH_METHOD = "moment_balanced_multiswap_repair"
MOMENT_POWERS = (2, 4, 6)


def parse_power_list(text):
    if text is None or str(text).strip() == "":
        return []
    out = []
    for part in str(text).split(","):
        part = part.strip()
        if part:
            out.append(int(part))
    return out


def balanced_abs(residue, modulus):
    residue = int(residue) % int(modulus)
    return min(residue, int(modulus) - residue)


def moment_residue_map(summary):
    return {
        int(item["power"]): int(item["residue"])
        for item in summary.get("moments", [])
    }


def moment_abs_sum(residue_map, powers, modulus):
    return sum(balanced_abs(residue_map.get(power, 0), modulus) for power in powers)


def moment_zero_count(residue_map, powers, modulus):
    return sum(1 for power in powers if int(residue_map.get(power, 0)) % modulus == 0)


def moment_delta_from_counts(v, delta, powers):
    out = {}
    for power in powers:
        total = 0
        for d in range(1, v):
            total += int(delta[d]) * pow(d % v, int(power), v)
        out[int(power)] = int(total % v)
    return out


def add_residue_maps(left, right, modulus):
    out = {}
    for power in MOMENT_POWERS:
        out[power] = int((left.get(power, 0) + right.get(power, 0)) % modulus)
    return out


def cap_violation(metrics, score_cap, maxabs_bound=None):
    violation = max(0, int(metrics[0]) - int(score_cap))
    if maxabs_bound is not None:
        violation += 100 * max(0, int(metrics[2]) - int(maxabs_bound))
    return int(violation)


def lock_target_stats(residue_map, lock_powers, target_powers, modulus):
    lock_abs = moment_abs_sum(residue_map, lock_powers, modulus)
    target_abs = moment_abs_sum(residue_map, target_powers, modulus)
    lock_zero = moment_zero_count(residue_map, lock_powers, modulus)
    target_zero = moment_zero_count(residue_map, target_powers, modulus)
    return {
        "lock_abs_sum": int(lock_abs),
        "target_abs_sum": int(target_abs),
        "lock_zero_count": int(lock_zero),
        "target_zero_count": int(target_zero),
        "lock_violation_count": int(len(lock_powers) - lock_zero),
        "target_violation_count": int(len(target_powers) - target_zero),
    }


def clone_blocks(blocks):
    return [set(block) for block in blocks]


def apply_sequence_true(v, blocks, counts, lam, moves):
    trial_blocks = clone_blocks(blocks)
    trial_counts = list(counts)
    applied = []
    for move in moves:
        block_idx = int(move["block"])
        removed = int(move["removed"])
        added = int(move["added"])
        if removed not in trial_blocks[block_idx]:
            return None
        if added in trial_blocks[block_idx]:
            return None
        delta = delta_swap(v, trial_blocks[block_idx], removed, added)
        trial_counts = apply_delta(trial_counts, delta)
        trial_blocks[block_idx].remove(removed)
        trial_blocks[block_idx].add(added)
        applied.append(
            {
                "block": int(block_idx),
                "removed": int(removed),
                "added": int(added),
                "block_index": int(block_idx),
                "remove": int(removed),
                "add": int(added),
            }
        )
    metrics = metrics_from_counts(trial_counts, lam)
    moment = p_adic_moment_summary(trial_counts, lam, powers=MOMENT_POWERS, modulus=v)
    return {
        "blocks": trial_blocks,
        "counts": trial_counts,
        "metrics": metrics,
        "moment": moment,
        "moves": applied,
    }


def generate_swap_candidates(v, blocks, counts, lam, args, before_residues):
    universe = list(range(v))
    candidates = []
    powers = list(MOMENT_POWERS)
    for block_idx, block in enumerate(blocks):
        outside = [x for x in universe if x not in block]
        for removed in sorted(block):
            for added in outside:
                delta = delta_swap(v, block, removed, added)
                new_counts = apply_delta(counts, delta)
                metrics = metrics_from_counts(new_counts, lam)
                moment_delta = moment_delta_from_counts(v, delta, powers)
                after_residues = add_residue_maps(before_residues, moment_delta, v)
                stats = lock_target_stats(
                    after_residues, args.lock_powers, args.target_powers, v
                )
                candidate = {
                    "block": int(block_idx),
                    "removed": int(removed),
                    "added": int(added),
                    "delta": delta,
                    "metrics": metrics,
                    "moment_delta": moment_delta,
                    "after_residues": after_residues,
                    "single_lock_abs_sum": int(stats["lock_abs_sum"]),
                    "single_target_abs_sum": int(stats["target_abs_sum"]),
                    "single_target_zero_count": int(stats["target_zero_count"]),
                    "single_lock_violation_count": int(stats["lock_violation_count"]),
                    "single_cap_violation": cap_violation(
                        metrics, args.score_cap, args.maxabs_bound
                    ),
                }
                candidates.append(candidate)

    random.Random(int(args.seed)).shuffle(candidates)
    candidates.sort(
        key=lambda item: (
            item["single_lock_violation_count"],
            item["single_target_abs_sum"],
            -item["single_target_zero_count"],
            item["single_cap_violation"],
            item["metrics"][0],
            item["metrics"][1],
            item["metrics"][2],
            item["metrics"][3],
            item["block"],
            item["removed"],
            item["added"],
        )
    )
    pool = []
    seen = set()

    def add_items(items):
        for item in items:
            key = (item["block"], item["removed"], item["added"])
            if key in seen:
                continue
            seen.add(key)
            pool.append(item)

    prefilter = int(args.prefilter)
    add_items(candidates[:prefilter])

    # Add score-preserving moves as a second view; moment-useful moves can be
    # score-expensive, but the final stage rechecks caps exactly.
    score_sorted = sorted(
        candidates,
        key=lambda item: (
            item["single_cap_violation"],
            item["metrics"][0],
            item["metrics"][1],
            item["single_target_abs_sum"],
        ),
    )
    add_items(score_sorted[: max(10, prefilter // 3)])

    # Add moves that strongly affect each target moment, so the beam has
    # enough directions to cancel locks and hit targets in combination.
    for power in args.target_powers:
        target_sorted = sorted(
            candidates,
            key=lambda item, power=power: (
                balanced_abs(before_residues[power] + item["moment_delta"][power], v),
                item["single_lock_violation_count"],
                item["single_cap_violation"],
                item["metrics"][0],
            ),
        )
        add_items(target_sorted[: max(10, prefilter // 4)])

    return pool[: int(args.candidate_pool)], len(candidates)


def compatible_with_state(state, move):
    block = int(move["block"])
    removed = int(move["removed"])
    added = int(move["added"])
    block_state = state["block_state"].setdefault(block, {"removed": set(), "added": set()})
    if removed in block_state["removed"]:
        return False
    if added in block_state["added"]:
        return False
    return True


def extend_state(state, idx, move, before_residues, args, v, counts, lam):
    if not compatible_with_state(state, move):
        return None
    new_state = {
        "indices": state["indices"] + [idx],
        "moves": state["moves"] + [move],
        "counts": apply_delta(state["counts"], move["delta"]),
        "residues": add_residue_maps(state["residues"], move["moment_delta"], v),
        "block_state": {
            block: {
                "removed": set(values["removed"]),
                "added": set(values["added"]),
            }
            for block, values in state["block_state"].items()
        },
    }
    block = int(move["block"])
    new_state["block_state"].setdefault(block, {"removed": set(), "added": set()})
    new_state["block_state"][block]["removed"].add(int(move["removed"]))
    new_state["block_state"][block]["added"].add(int(move["added"]))
    new_state["metrics"] = metrics_from_counts(new_state["counts"], lam)
    return new_state


def state_rank(state, args, v):
    metrics = state["metrics"]
    stats = lock_target_stats(state["residues"], args.lock_powers, args.target_powers, v)
    violation = cap_violation(metrics, args.score_cap, args.maxabs_bound)
    if args.rank_mode == "cap_first":
        return (
            stats["lock_violation_count"],
            violation,
            stats["target_abs_sum"],
            -stats["target_zero_count"],
            metrics[0],
            metrics[1],
            metrics[2],
            metrics[3],
            len(state["moves"]),
        )
    return (
        stats["lock_violation_count"],
        stats["target_abs_sum"],
        -stats["target_zero_count"],
        violation,
        metrics[0],
        metrics[1],
        metrics[2],
        metrics[3],
        len(state["moves"]),
    )


def result_rank(result, args, v):
    metrics = result["metrics"]
    stats = result["lock_target_stats"]
    violation = cap_violation(metrics, args.score_cap, args.maxabs_bound)
    if args.rank_mode == "cap_first":
        return (
            stats["lock_violation_count"],
            violation,
            stats["target_abs_sum"],
            -stats["target_zero_count"],
            metrics[0],
            metrics[1],
            metrics[2],
            metrics[3],
            len(result["moves"]),
        )
    return (
        stats["lock_violation_count"],
        stats["target_abs_sum"],
        -stats["target_zero_count"],
        violation,
        metrics[0],
        metrics[1],
        metrics[2],
        metrics[3],
        len(result["moves"]),
    )


def beam_search(v, blocks, counts, lam, before_residues, candidates, args):
    initial = {
        "indices": [],
        "moves": [],
        "counts": list(counts),
        "residues": dict(before_residues),
        "block_state": {},
        "metrics": metrics_from_counts(counts, lam),
    }
    beam = [initial]
    all_states = []
    per_depth = []
    for depth in range(1, int(args.max_moves) + 1):
        next_states = []
        for state in beam:
            start_idx = state["indices"][-1] + 1 if state["indices"] else 0
            for idx in range(start_idx, len(candidates)):
                child = extend_state(
                    state,
                    idx,
                    candidates[idx],
                    before_residues,
                    args,
                    v,
                    counts,
                    lam,
                )
                if child is None:
                    continue
                next_states.append(child)
        next_states.sort(key=lambda state: state_rank(state, args, v))
        beam = next_states[: int(args.beam_width)]
        all_states.extend(beam)
        per_depth.append({"depth": int(depth), "states": int(len(next_states)), "kept": int(len(beam))})
        if not beam:
            break
    return all_states, per_depth


def move_text(moves):
    return ",".join(
        "B{}:{}->{}".format(move["block"], move["removed"], move["added"])
        for move in moves
    )


def parse_args():
    parser = argparse.ArgumentParser(
        description="Moment-balanced multi-swap repair for p-adic moment diagnostics."
    )
    parser.add_argument("json_path", help="Input candidate or near-hit JSON path.")
    parser.add_argument("--lock-powers", default="2", help="Comma-separated moment powers that should remain zero.")
    parser.add_argument("--target-powers", default="4,6", help="Comma-separated moment powers to improve.")
    parser.add_argument("--score-cap", type=int, default=260, help="Preferred maximum score for accepted diagnostic candidates.")
    parser.add_argument("--maxabs-bound", type=int, default=None, help="Optional max_abs bound used in ranking.")
    parser.add_argument("--candidate-pool", type=int, default=600, help="Maximum one-swap candidates kept after diverse prefiltering.")
    parser.add_argument("--prefilter", type=int, default=300, help="Primary one-swap prefilter width.")
    parser.add_argument("--beam-width", type=int, default=500, help="Beam width for approximate multi-swap states.")
    parser.add_argument("--max-moves", type=int, default=4, help="Maximum number of swaps in one multi-swap candidate.")
    parser.add_argument("--evaluate-top", type=int, default=100, help="Number of approximate beam states to exactly re-evaluate.")
    parser.add_argument(
        "--rank-mode",
        choices=["moment_first", "cap_first"],
        default="moment_first",
        help="Rank beam states by moment first or by score/max_abs cap first.",
    )
    parser.add_argument("--round", type=int, default=1, help="Round label for output filenames.")
    parser.add_argument("--seed", type=int, default=1, help="Deterministic tie-shuffle seed.")
    parser.add_argument("--dry-run-pool-stats", action="store_true", help="Only build pool and print model/beam scale estimates.")
    parser.add_argument("--near-hit-dir", default="outputs/candidates/near_hits")
    parser.add_argument("--candidate-dir", default="outputs/candidates")
    return parser.parse_args()


def main():
    args = parse_args()
    args.lock_powers = parse_power_list(args.lock_powers)
    args.target_powers = parse_power_list(args.target_powers)
    if not args.lock_powers:
        raise ValueError("--lock-powers must contain at least one power")
    if not args.target_powers:
        raise ValueError("--target-powers must contain at least one power")

    tee, stamp = setup_logging("44_moment_balanced_multiswap_repair")
    csv_path = os.path.join(
        "outputs/logs", "44_moment_balanced_multiswap_repair_{}.csv".format(stamp)
    )
    csv_file = None
    try:
        data, v, n, ks, lam, blocks = load_candidate(args.json_path)
        counts = total_diff_counts(v, blocks)
        metrics = metrics_from_counts(counts, lam)
        before_moment = p_adic_moment_summary(counts, lam, powers=MOMENT_POWERS, modulus=v)
        before_residues = moment_residue_map(before_moment)
        before_stats = lock_target_stats(before_residues, args.lock_powers, args.target_powers, v)

        print("CSV log:", csv_path)
        print("Input:", args.json_path)
        print("v={} n={} ks={} lambda={}".format(v, n, ks, lam))
        print(
            "initial score={} l1_error={} max_abs_error={} nonzero_defect_count={}".format(
                metrics[0], metrics[1], metrics[2], metrics[3]
            )
        )
        print(
            "initial moment_signature={} moment_zero_count={} lock_powers={} target_powers={} "
            "lock_abs_sum={} target_abs_sum={}".format(
                before_moment["moment_signature"],
                before_moment["moment_zero_count"],
                args.lock_powers,
                args.target_powers,
                before_stats["lock_abs_sum"],
                before_stats["target_abs_sum"],
            )
        )
        print(
            "candidate_pool={} prefilter={} beam_width={} max_moves={} evaluate_top={} "
            "score_cap={} maxabs_bound={} rank_mode={}".format(
                args.candidate_pool,
                args.prefilter,
                args.beam_width,
                args.max_moves,
                args.evaluate_top,
                args.score_cap,
                args.maxabs_bound,
                args.rank_mode,
            )
        )

        start = time.time()
        candidates, raw_candidate_count = generate_swap_candidates(
            v, blocks, counts, lam, args, before_residues
        )
        print(
            "pool raw_candidate_count={} kept_candidate_count={}".format(
                raw_candidate_count, len(candidates)
            )
        )
        if args.dry_run_pool_stats:
            print("DRY RUN: pool stats only")
            return

        approx_states, per_depth = beam_search(
            v, blocks, counts, lam, before_residues, candidates, args
        )
        approx_states.sort(key=lambda state: state_rank(state, args, v))
        print("beam_depth_stats:", per_depth)
        print("approx_states_kept_total={}".format(len(approx_states)))

        exact_results = []
        for state in approx_states[: int(args.evaluate_top)]:
            exact = apply_sequence_true(v, blocks, counts, lam, state["moves"])
            if exact is None:
                continue
            residues = moment_residue_map(exact["moment"])
            stats = lock_target_stats(residues, args.lock_powers, args.target_powers, v)
            exact["residues"] = residues
            exact["lock_target_stats"] = stats
            exact["rank"] = result_rank(exact, args, v)
            exact_results.append(exact)
        exact_results.sort(key=lambda item: item["rank"])

        os.makedirs("outputs/logs", exist_ok=True)
        csv_file = open(csv_path, "w")
        fieldnames = [
            "timestamp",
            "rank",
            "score",
            "l1_error",
            "max_abs_error",
            "nonzero_defect_count",
            "moment_signature",
            "moment_zero_count",
            "lock_violation_count",
            "lock_abs_sum",
            "target_zero_count",
            "target_abs_sum",
            "cap_violation",
            "move_count",
            "moves",
        ]
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        for idx, item in enumerate(exact_results[:50], start=1):
            stats = item["lock_target_stats"]
            row = {
                "timestamp": timestamp(),
                "rank": int(idx),
                "score": int(item["metrics"][0]),
                "l1_error": int(item["metrics"][1]),
                "max_abs_error": int(item["metrics"][2]),
                "nonzero_defect_count": int(item["metrics"][3]),
                "moment_signature": item["moment"]["moment_signature"],
                "moment_zero_count": int(item["moment"]["moment_zero_count"]),
                "lock_violation_count": int(stats["lock_violation_count"]),
                "lock_abs_sum": int(stats["lock_abs_sum"]),
                "target_zero_count": int(stats["target_zero_count"]),
                "target_abs_sum": int(stats["target_abs_sum"]),
                "cap_violation": cap_violation(item["metrics"], args.score_cap, args.maxabs_bound),
                "move_count": int(len(item["moves"])),
                "moves": move_text(item["moves"]),
            }
            writer.writerow(row)
            print(
                "rank={rank} score={score} l1={l1_error} max={max_abs_error} "
                "nonzero={nonzero_defect_count} moment={moment_signature} "
                "zeros={moment_zero_count} lock_bad={lock_violation_count} "
                "target_zero={target_zero_count} target_abs={target_abs_sum} "
                "cap_bad={cap_violation} moves={moves}".format(**row)
            )

        if not exact_results:
            print("NO EXACT RESULTS")
            return

        best = exact_results[0]
        best_metrics = best["metrics"]
        best_stats = best["lock_target_stats"]
        extra = {
            "selected_moves": best["moves"],
            "selected_moves_count": int(len(best["moves"])),
            "input_json": args.json_path,
            "input_metrics": {
                "score": int(metrics[0]),
                "l1_error": int(metrics[1]),
                "max_abs_error": int(metrics[2]),
                "nonzero_defect_count": int(metrics[3]),
            },
            "input_moment_signature": before_moment["moment_signature"],
            "input_moment_zero_count": int(before_moment["moment_zero_count"]),
            "p_adic_moments": best["moment"],
            "moment_signature": best["moment"]["moment_signature"],
            "moment_zero_count": int(best["moment"]["moment_zero_count"]),
            "moment_abs_sum": int(best["moment"]["moment_abs_sum"]),
            "moment_lock_powers": [int(x) for x in args.lock_powers],
            "moment_target_powers": [int(x) for x in args.target_powers],
            "moment_lock_violation_count": int(best_stats["lock_violation_count"]),
            "moment_lock_abs_sum": int(best_stats["lock_abs_sum"]),
            "moment_target_zero_count": int(best_stats["target_zero_count"]),
            "moment_target_abs_sum": int(best_stats["target_abs_sum"]),
            "score_cap": int(args.score_cap),
            "maxabs_bound": None if args.maxabs_bound is None else int(args.maxabs_bound),
            "rank_mode": args.rank_mode,
            "score_cap_satisfied": bool(best_metrics[0] <= int(args.score_cap)),
            "cap_violation": int(cap_violation(best_metrics, args.score_cap, args.maxabs_bound)),
            "raw_candidate_count": int(raw_candidate_count),
            "kept_candidate_count": int(len(candidates)),
            "beam_depth_stats": per_depth,
            "exact_evaluated_count": int(len(exact_results)),
            "elapsed_sec": float(time.time() - start),
        }
        if best_metrics[0] == 0:
            path = save_success(
                args.candidate_dir,
                args.near_hit_dir,
                v,
                ks,
                lam,
                best["blocks"],
                best_metrics,
                args.json_path,
                SEARCH_METHOD,
                args.round,
                len(best["moves"]),
                best["counts"],
                extra,
            )
        else:
            path = save_near_hit(
                args.near_hit_dir,
                v,
                ks,
                lam,
                best["blocks"],
                best_metrics,
                args.json_path,
                SEARCH_METHOD,
                args.round,
                len(best["moves"]),
                best["counts"],
                extra,
            )
        print("BEST saved:", path)
    finally:
        if csv_file is not None:
            csv_file.close()
        tee.flush()
        tee.close()
        sys.stdout = tee.terminal


if __name__ == "__main__":
    main()
