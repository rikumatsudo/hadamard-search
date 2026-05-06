from sage.all import *

import argparse
import csv
import json
import os
import random
import sys
import time

from sds_repair_utils import (
    apply_delta,
    delta_swap,
    load_candidate,
    metrics_from_counts,
    p_adic_moment_summary,
    save_near_hit,
    save_success,
    setup_logging,
    timestamp,
    total_diff_counts,
    write_json,
)


SEARCH_METHOD = "moment_preserving_score_repair"
LOW_POWERS = (2, 4, 6)
HIGH_POWERS = (2, 4, 6, 8, 10, 12)


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)


def parse_power_list(text):
    if text is None or str(text).strip() == "":
        return []
    return [int(part.strip()) for part in str(text).split(",") if part.strip()]


def balanced_abs(residue, modulus):
    residue = int(residue) % int(modulus)
    return min(residue, int(modulus) - residue)


def moment_residue_map(summary):
    return {int(item["power"]): int(item["residue"]) for item in summary["moments"]}


def add_residue_maps(left, right, powers, modulus):
    return {
        int(power): int((left.get(int(power), 0) + right.get(int(power), 0)) % modulus)
        for power in powers
    }


def moment_delta_from_counts(v, delta, powers):
    out = {}
    for power in powers:
        total = 0
        for d in range(1, v):
            total += int(delta[d]) * pow(d % v, int(power), v)
        out[int(power)] = int(total % v)
    return out


def moment_abs_sum(residue_map, powers, modulus):
    return sum(balanced_abs(residue_map.get(power, 0), modulus) for power in powers)


def moment_zero_count(residue_map, powers, modulus):
    return sum(1 for power in powers if int(residue_map.get(power, 0)) % modulus == 0)


def low_all_zero(residue_map, modulus):
    return moment_zero_count(residue_map, LOW_POWERS, modulus) == len(LOW_POWERS)


def cap_violation(metrics, score_cap, maxabs_cap=None):
    bad = max(0, int(metrics[0]) - int(score_cap))
    if maxabs_cap is not None:
        bad += 100 * max(0, int(metrics[2]) - int(maxabs_cap))
    return int(bad)


def signature_from_residues(residue_map, powers):
    return ",".join(str(int(residue_map.get(power, 0))) for power in powers)


def high_moment_payload(counts, lam, v):
    low = p_adic_moment_summary(counts, lam, powers=LOW_POWERS, modulus=v)
    high = p_adic_moment_summary(counts, lam, powers=HIGH_POWERS, modulus=v)
    by_power = {
        "T{}".format(item["power"]): int(item["residue"])
        for item in high["moments"]
    }
    return {
        "padic_moments": by_power,
        "p_adic_moments": high,
        "p_adic_moments_3": low,
        "moment_zero_count_3": int(low["moment_zero_count"]),
        "moment_zero_count_6": int(high["moment_zero_count"]),
        "moment_signature_3": low["moment_signature"],
        "moment_signature_6": high["moment_signature"],
        "moment_abs_sum_3": int(low["moment_abs_sum"]),
        "moment_abs_sum_6": int(high["moment_abs_sum"]),
        "moment_low_all_zero": bool(low["moment_all_zero"]),
        "moment_high_all_zero": bool(high["moment_all_zero"]),
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
        if removed not in trial_blocks[block_idx] or added in trial_blocks[block_idx]:
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
    return {
        "blocks": trial_blocks,
        "counts": trial_counts,
        "metrics": metrics_from_counts(trial_counts, lam),
        "moves": applied,
        "moment": high_moment_payload(trial_counts, lam, v),
    }


def compatible_with_state(state, move):
    block = int(move["block"])
    removed = int(move["removed"])
    added = int(move["added"])
    block_state = state["block_state"].setdefault(block, {"removed": set(), "added": set()})
    if removed in block_state["removed"] or added in block_state["added"]:
        return False
    return True


def state_rank(state, args, v):
    metrics = state["metrics"]
    residues = state["residues"]
    low_zero = moment_zero_count(residues, LOW_POWERS, v)
    high_abs = moment_abs_sum(residues, HIGH_POWERS, v)
    low_abs = moment_abs_sum(residues, LOW_POWERS, v)
    cap_bad = cap_violation(metrics, args.score_cap, args.maxabs_cap)
    if args.mode == "score_repair":
        return (
            len(LOW_POWERS) - low_zero,
            cap_bad,
            metrics[0],
            metrics[1],
            metrics[2],
            metrics[3],
            high_abs,
            len(state["moves"]),
        )
    return (
        len(LOW_POWERS) - low_zero,
        low_abs,
        cap_bad,
        metrics[0],
        metrics[1],
        metrics[2],
        metrics[3],
        high_abs,
        len(state["moves"]),
    )


def result_rank(result, args, v):
    metrics = result["metrics"]
    low_zero = int(result["moment"]["moment_zero_count_3"])
    low_abs = int(result["moment"]["moment_abs_sum_3"])
    high_abs = int(result["moment"]["moment_abs_sum_6"])
    cap_bad = cap_violation(metrics, args.score_cap, args.maxabs_cap)
    if args.mode == "score_repair":
        return (
            len(LOW_POWERS) - low_zero,
            cap_bad,
            metrics[0],
            metrics[1],
            metrics[2],
            metrics[3],
            high_abs,
            len(result["moves"]),
        )
    return (
        len(LOW_POWERS) - low_zero,
        low_abs,
        cap_bad,
        metrics[0],
        metrics[1],
        metrics[2],
        metrics[3],
        high_abs,
        len(result["moves"]),
    )


def extend_state(state, idx, move, v, lam):
    if not compatible_with_state(state, move):
        return None
    new_state = {
        "indices": state["indices"] + [idx],
        "moves": state["moves"] + [move],
        "counts": apply_delta(state["counts"], move["delta"]),
        "residues": add_residue_maps(state["residues"], move["moment_delta"], HIGH_POWERS, v),
        "block_state": {
            block: {"removed": set(value["removed"]), "added": set(value["added"])}
            for block, value in state["block_state"].items()
        },
    }
    block = int(move["block"])
    new_state["block_state"].setdefault(block, {"removed": set(), "added": set()})
    new_state["block_state"][block]["removed"].add(int(move["removed"]))
    new_state["block_state"][block]["added"].add(int(move["added"]))
    new_state["metrics"] = metrics_from_counts(new_state["counts"], lam)
    return new_state


def generate_swap_candidates(v, blocks, counts, lam, args, before_residues):
    universe = list(range(v))
    candidates = []
    before_metrics = metrics_from_counts(counts, lam)
    for block_idx, block in enumerate(blocks):
        outside = [x for x in universe if x not in block]
        for removed in sorted(block):
            for added in outside:
                delta = delta_swap(v, block, removed, added)
                new_counts = apply_delta(counts, delta)
                metrics = metrics_from_counts(new_counts, lam)
                moment_delta = moment_delta_from_counts(v, delta, HIGH_POWERS)
                after_residues = add_residue_maps(before_residues, moment_delta, HIGH_POWERS, v)
                low_zero = moment_zero_count(after_residues, LOW_POWERS, v)
                low_abs = moment_abs_sum(after_residues, LOW_POWERS, v)
                high_abs = moment_abs_sum(after_residues, HIGH_POWERS, v)
                candidates.append(
                    {
                        "block": int(block_idx),
                        "removed": int(removed),
                        "added": int(added),
                        "delta": delta,
                        "metrics": metrics,
                        "moment_delta": moment_delta,
                        "after_residues": after_residues,
                        "single_low_zero_count": int(low_zero),
                        "single_low_abs_sum": int(low_abs),
                        "single_high_abs_sum": int(high_abs),
                        "score_delta": int(metrics[0] - before_metrics[0]),
                        "l1_delta": int(metrics[1] - before_metrics[1]),
                        "cap_violation": cap_violation(metrics, args.score_cap, args.maxabs_cap),
                    }
                )

    random.Random(int(args.seed)).shuffle(candidates)
    pool = []
    seen = set()

    def add_items(items):
        for item in items:
            key = (item["block"], item["removed"], item["added"])
            if key in seen:
                continue
            seen.add(key)
            pool.append(item)

    by_score = sorted(
        candidates,
        key=lambda item: (
            item["cap_violation"],
            item["score_delta"],
            item["l1_delta"],
            item["metrics"][2],
            item["single_low_abs_sum"],
            item["single_high_abs_sum"],
        ),
    )
    add_items(by_score[: int(args.prefilter)])

    by_moment = sorted(
        candidates,
        key=lambda item: (
            len(LOW_POWERS) - item["single_low_zero_count"],
            item["single_low_abs_sum"],
            item["cap_violation"],
            item["metrics"][0],
            item["metrics"][1],
        ),
    )
    add_items(by_moment[: max(20, int(args.prefilter) // 2)])

    # Include moment-delta directional moves. They are often score-expensive but
    # supply the modular degrees of freedom needed to close T2/T4/T6.
    for power in LOW_POWERS:
        directional = sorted(
            candidates,
            key=lambda item, power=power: (
                balanced_abs(before_residues[power] + item["moment_delta"][power], v),
                item["cap_violation"],
                item["metrics"][0],
            ),
        )
        add_items(directional[: max(20, int(args.prefilter) // 3)])

    return pool[: int(args.candidate_pool)], len(candidates)


def beam_search(v, counts, lam, before_residues, candidates, args):
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
    depth_stats = []
    for depth in range(1, int(args.max_moves) + 1):
        next_states = []
        for state in beam:
            start_idx = state["indices"][-1] + 1 if state["indices"] else 0
            for idx in range(start_idx, len(candidates)):
                child = extend_state(state, idx, candidates[idx], v, lam)
                if child is not None:
                    next_states.append(child)
        next_states.sort(key=lambda state: state_rank(state, args, v))
        beam = next_states[: int(args.beam_width)]
        all_states.extend(beam)
        depth_stats.append({"depth": int(depth), "states": int(len(next_states)), "kept": int(len(beam))})
        if not beam:
            break
    all_states.sort(key=lambda state: state_rank(state, args, v))
    return all_states, depth_stats


def move_text(moves):
    return ",".join("B{}:{}->{}".format(m["block"], m["removed"], m["added"]) for m in moves)


def append_jsonl(path, payload):
    ensure_dir(os.path.dirname(path) or ".")
    with open(path, "a") as f:
        f.write(json.dumps(payload, sort_keys=True) + "\n")


def write_summary(path, lines):
    ensure_dir(os.path.dirname(path) or ".")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Repair moment-compatible Hadamard 668 near-hits while preserving T2/T4/T6 final zero."
    )
    parser.add_argument("json_path")
    parser.add_argument("--mode", choices=["closure", "score_repair", "pool"], default="closure")
    parser.add_argument("--score-cap", type=int, default=340)
    parser.add_argument("--maxabs-cap", type=int, default=None)
    parser.add_argument("--candidate-pool", type=int, default=700)
    parser.add_argument("--prefilter", type=int, default=300)
    parser.add_argument("--beam-width", type=int, default=500)
    parser.add_argument("--max-moves", type=int, default=4)
    parser.add_argument("--evaluate-top", type=int, default=200)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--save-top", type=int, default=10)
    parser.add_argument("--exploration-id", default=None)
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--near-hit-dir", default="outputs/candidates/near_hits")
    parser.add_argument("--candidate-dir", default="outputs/candidates")
    return parser.parse_args()


def main():
    args = parse_args()
    if args.exploration_id is None:
        args.exploration_id = "{}_hadamard668_moment_preserving_score_repair".format(now_stamp())
    if args.out_dir is None:
        args.out_dir = os.path.join("outputs", "explorations", args.exploration_id)
    ensure_dir(args.out_dir)
    ensure_dir(os.path.join(args.out_dir, "raw"))

    tee, stamp = setup_logging("45_moment_preserving_score_repair")
    csv_path = os.path.join("outputs/logs", "45_moment_preserving_score_repair_{}.csv".format(stamp))
    csv_file = None
    saved_paths = []
    best_seen = None
    try:
        data, v, n, ks, lam, blocks = load_candidate(args.json_path)
        counts = total_diff_counts(v, blocks)
        metrics = metrics_from_counts(counts, lam)
        moment = high_moment_payload(counts, lam, v)
        config = {
            "input": args.json_path,
            "mode": args.mode,
            "score_cap": int(args.score_cap),
            "maxabs_cap": args.maxabs_cap,
            "candidate_pool": int(args.candidate_pool),
            "prefilter": int(args.prefilter),
            "beam_width": int(args.beam_width),
            "max_moves": int(args.max_moves),
            "evaluate_top": int(args.evaluate_top),
            "rounds": int(args.rounds),
            "seed": int(args.seed),
            "exploration_id": args.exploration_id,
        }
        write_json(os.path.join(args.out_dir, "run_config.json"), config)
        write_json(os.path.join(args.out_dir, "raw", "run_config.json"), config)

        print("CSV log:", csv_path)
        print("Exploration:", args.out_dir)
        print("Input:", args.json_path)
        print("v={} n={} ks={} lambda={}".format(v, n, ks, lam))
        print(
            "initial score={} l1={} max={} nonzero={} moment3={} zeros3={} moment6={} zeros6={}".format(
                metrics[0],
                metrics[1],
                metrics[2],
                metrics[3],
                moment["moment_signature_3"],
                moment["moment_zero_count_3"],
                moment["moment_signature_6"],
                moment["moment_zero_count_6"],
            )
        )

        csv_file = open(csv_path, "w")
        fields = [
            "timestamp",
            "round",
            "rank",
            "accepted",
            "score",
            "l1_error",
            "max_abs_error",
            "nonzero_defect_count",
            "moment_signature_3",
            "moment_zero_count_3",
            "moment_signature_6",
            "moment_zero_count_6",
            "moment_abs_sum_6",
            "cap_violation",
            "move_count",
            "moves",
            "path",
        ]
        writer = csv.DictWriter(csv_file, fieldnames=fields)
        writer.writeheader()

        for round_idx in range(1, int(args.rounds) + 1):
            round_start = time.time()
            before_counts = list(counts)
            before_metrics = metrics_from_counts(counts, lam)
            before_moment = high_moment_payload(counts, lam, v)
            before_residues = moment_residue_map(before_moment["p_adic_moments"])
            candidates, raw_count = generate_swap_candidates(v, blocks, counts, lam, args, before_residues)
            states, depth_stats = beam_search(v, counts, lam, before_residues, candidates, args)
            exact_results = []
            for state in states[: int(args.evaluate_top)]:
                exact = apply_sequence_true(v, blocks, counts, lam, state["moves"])
                if exact is None:
                    continue
                exact["rank"] = result_rank(exact, args, v)
                exact_results.append(exact)
            exact_results.sort(key=lambda item: item["rank"])

            low_all_zero_results = [
                item for item in exact_results if item["moment"]["moment_zero_count_3"] == len(LOW_POWERS)
            ]
            low_all_zero_results.sort(
                key=lambda item: (
                    cap_violation(item["metrics"], args.score_cap, args.maxabs_cap),
                    item["metrics"][0],
                    item["metrics"][1],
                    item["metrics"][2],
                    item["metrics"][3],
                    item["moment"]["moment_abs_sum_6"],
                )
            )
            ranked_for_log = low_all_zero_results[: int(args.save_top)]
            if not ranked_for_log:
                ranked_for_log = exact_results[: int(args.save_top)]

            accepted = None
            if args.mode == "score_repair":
                for item in low_all_zero_results:
                    if item["metrics"][0] < before_metrics[0]:
                        accepted = item
                        break
            elif args.mode == "closure":
                for item in low_all_zero_results:
                    if item["metrics"][0] <= int(args.score_cap):
                        accepted = item
                        break
                if accepted is None and low_all_zero_results:
                    accepted = low_all_zero_results[0]
            else:
                accepted = low_all_zero_results[0] if low_all_zero_results else (exact_results[0] if exact_results else None)

            print(
                "round={} raw_swaps={} pool={} depth_stats={} exact={} low_all_zero={} elapsed={:.2f}s".format(
                    round_idx,
                    raw_count,
                    len(candidates),
                    depth_stats,
                    len(exact_results),
                    len(low_all_zero_results),
                    time.time() - round_start,
                )
            )

            for idx, item in enumerate(ranked_for_log, start=1):
                item_metrics = item["metrics"]
                item_moment = item["moment"]
                is_accepted = bool(item is accepted)
                row = {
                    "timestamp": timestamp(),
                    "round": int(round_idx),
                    "rank": int(idx),
                    "accepted": bool(is_accepted),
                    "score": int(item_metrics[0]),
                    "l1_error": int(item_metrics[1]),
                    "max_abs_error": int(item_metrics[2]),
                    "nonzero_defect_count": int(item_metrics[3]),
                    "moment_signature_3": item_moment["moment_signature_3"],
                    "moment_zero_count_3": int(item_moment["moment_zero_count_3"]),
                    "moment_signature_6": item_moment["moment_signature_6"],
                    "moment_zero_count_6": int(item_moment["moment_zero_count_6"]),
                    "moment_abs_sum_6": int(item_moment["moment_abs_sum_6"]),
                    "cap_violation": int(cap_violation(item_metrics, args.score_cap, args.maxabs_cap)),
                    "move_count": int(len(item["moves"])),
                    "moves": move_text(item["moves"]),
                    "path": "",
                }
                writer.writerow(row)
                print(
                    "round={round} rank={rank} accepted={accepted} score={score} l1={l1_error} "
                    "max={max_abs_error} nonzero={nonzero_defect_count} m3={moment_signature_3} "
                    "z3={moment_zero_count_3} m6={moment_signature_6} z6={moment_zero_count_6} moves={moves}".format(
                        **row
                    )
                )

            if accepted is None:
                print("round={} no accepted candidate".format(round_idx))
                break

            extra = dict(accepted["moment"])
            extra.update(
                {
                    "origin_candidate": args.json_path,
                    "parent_hash": data.get("canonical_hash", ""),
                    "move_path": accepted["moves"],
                    "selected_moves": accepted["moves"],
                    "selected_moves_count": int(len(accepted["moves"])),
                    "verification_status": "near_hit_not_verified_success",
                    "score_cap": int(args.score_cap),
                    "maxabs_cap": args.maxabs_cap,
                    "mode": args.mode,
                    "search_method_detail": "final_low_moment_zero_beam_lns",
                    "round_input_metrics": {
                        "score": int(before_metrics[0]),
                        "l1_error": int(before_metrics[1]),
                        "max_abs_error": int(before_metrics[2]),
                        "nonzero_defect_count": int(before_metrics[3]),
                    },
                    "round_input_moment_signature_3": before_moment["moment_signature_3"],
                    "raw_swap_count": int(raw_count),
                    "candidate_pool_count": int(len(candidates)),
                    "beam_depth_stats": depth_stats,
                    "exact_evaluated_count": int(len(exact_results)),
                }
            )
            if accepted["metrics"][0] == 0:
                out_path = save_success(
                    args.candidate_dir,
                    args.near_hit_dir,
                    v,
                    ks,
                    lam,
                    accepted["blocks"],
                    accepted["metrics"],
                    args.json_path,
                    SEARCH_METHOD,
                    round_idx,
                    len(accepted["moves"]),
                    accepted["counts"],
                    extra,
                )
            else:
                out_path = save_near_hit(
                    args.near_hit_dir,
                    v,
                    ks,
                    lam,
                    accepted["blocks"],
                    accepted["metrics"],
                    args.json_path,
                    SEARCH_METHOD,
                    round_idx,
                    len(accepted["moves"]),
                    accepted["counts"],
                    extra,
                )
            saved_paths.append(out_path)
            append_jsonl(
                os.path.join(args.out_dir, "best_candidates.jsonl"),
                {
                    "round": int(round_idx),
                    "path": out_path,
                    "metrics": {
                        "score": int(accepted["metrics"][0]),
                        "l1_error": int(accepted["metrics"][1]),
                        "max_abs_error": int(accepted["metrics"][2]),
                        "nonzero_defect_count": int(accepted["metrics"][3]),
                    },
                    "moment_signature_3": accepted["moment"]["moment_signature_3"],
                    "moment_signature_6": accepted["moment"]["moment_signature_6"],
                    "moment_zero_count_3": int(accepted["moment"]["moment_zero_count_3"]),
                    "moment_zero_count_6": int(accepted["moment"]["moment_zero_count_6"]),
                    "move_path": accepted["moves"],
                },
            )

            if best_seen is None or accepted["metrics"][0] < best_seen["metrics"][0]:
                best_seen = {"path": out_path, "metrics": accepted["metrics"], "moment": accepted["moment"]}

            blocks = accepted["blocks"]
            counts = accepted["counts"]
            data = {"canonical_hash": extra.get("canonical_hash", data.get("canonical_hash", ""))}

            if args.mode == "score_repair" and accepted["metrics"][0] >= before_metrics[0]:
                break

        summary_lines = [
            "# Moment-preserving Score Repair Summary",
            "",
            "This is diagnostic output. Low p-adic moment compatibility is not an SDS success certificate.",
            "",
            "- input: `{}`".format(args.json_path),
            "- mode: `{}`".format(args.mode),
            "- saved candidates: {}".format(len(saved_paths)),
            "- saved paths:",
        ]
        for path in saved_paths:
            summary_lines.append("  - `{}`".format(path))
        if best_seen:
            summary_lines.extend(
                [
                    "",
                    "Best saved by score:",
                    "- path: `{}`".format(best_seen["path"]),
                    "- score/l1/max/nonzero: `{}`".format(tuple(int(x) for x in best_seen["metrics"])),
                    "- low moment signature: `{}`".format(best_seen["moment"]["moment_signature_3"]),
                    "- extended moment signature: `{}`".format(best_seen["moment"]["moment_signature_6"]),
                ]
            )
        write_summary(os.path.join(args.out_dir, "moment_preserving_score_summary.md"), summary_lines)
        print("SUMMARY:", os.path.join(args.out_dir, "moment_preserving_score_summary.md"))
    finally:
        if csv_file is not None:
            csv_file.close()
        tee.flush()
        tee.close()
        sys.stdout = tee.terminal


if __name__ == "__main__":
    main()
