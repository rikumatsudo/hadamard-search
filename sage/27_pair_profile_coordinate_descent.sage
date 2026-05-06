from sage.all import *

import argparse
import csv
import math
import os
import random
import sys
import time

from sds_repair_utils import (
    base_payload,
    delta_swap,
    load_candidate,
    metrics_from_counts,
    save_success,
    setup_logging,
    timestamp,
    total_diff_counts,
    write_json,
)


SCRIPT_NAME = "27_pair_profile_coordinate_descent"


def parse_split(text):
    try:
        left_text, right_text = text.split(":")
        left = tuple(int(x) for x in left_text.split(",") if x != "")
        right = tuple(int(x) for x in right_text.split(",") if x != "")
    except ValueError:
        raise argparse.ArgumentTypeError("split must look like 0,1:2,3")
    if sorted(list(left) + list(right)) != [0, 1, 2, 3]:
        raise argparse.ArgumentTypeError("split must partition 0,1,2,3")
    if len(left) != 2 or len(right) != 2:
        raise argparse.ArgumentTypeError("this prototype expects two blocks per side")
    return left, right


def block_to_bits(block):
    bits = 0
    for x in block:
        bits |= 1 << int(x)
    return int(bits)


def rotate_left(bits, shift, v, mask):
    bits = int(bits)
    mask = int(mask)
    v = int(v)
    shift %= v
    if shift == 0:
        return bits & mask
    return ((bits << shift) | (bits >> (v - shift))) & mask


def diff_counts_from_bits(v, bits):
    v = int(v)
    bits = int(bits)
    mask = (1 << v) - 1
    counts = [0] * v
    for d in range(1, v):
        counts[d] = int((bits & rotate_left(bits, d, v, mask)).bit_count())
    return counts


def pair_counts(v, blocks):
    counts = [0] * v
    for block in blocks:
        block_counts = diff_counts_from_bits(v, block_to_bits(block))
        for d in range(v):
            counts[d] += block_counts[d]
    return counts


def pair_metrics(v, generated_counts, target_counts):
    score = 0
    l1_error = 0
    max_abs_error = 0
    nonzero_defect_count = 0
    for d in range(1, v):
        err = int(generated_counts[d]) - int(target_counts[d])
        abs_err = abs(err)
        score += err * err
        l1_error += abs_err
        max_abs_error = max(max_abs_error, abs_err)
        if err != 0:
            nonzero_defect_count += 1
    return (
        int(score),
        int(l1_error),
        int(max_abs_error),
        int(nonzero_defect_count),
    )


def full_metrics(v, blocks, lam):
    return metrics_from_counts(total_diff_counts(v, blocks), lam)


def objective_tuple(metrics, objective):
    score, l1_error, max_abs_error, nonzero_defect_count = metrics
    if objective == "complement_l2":
        return (score, l1_error, max_abs_error, nonzero_defect_count)
    if objective == "complement_l1":
        return (l1_error, score, max_abs_error, nonzero_defect_count)
    if objective == "balanced":
        return (score, l1_error, nonzero_defect_count, max_abs_error)
    if objective == "maxabs":
        return (max_abs_error, l1_error, score, nonzero_defect_count)
    raise ValueError("unknown objective {}".format(objective))


def random_swap(v, blocks):
    block_pos = random.randrange(len(blocks))
    block = blocks[block_pos]
    removed = random.choice(tuple(block))
    added = random.randrange(v)
    while added in block:
        added = random.randrange(v)
    return block_pos, int(removed), int(added)


def evaluate_swap(v, side_blocks, side_counts, target_counts, block_pos, removed, added):
    block = side_blocks[block_pos]
    if removed not in block or added in block:
        return None
    delta = delta_swap(v, block, removed, added)
    new_counts = [int(side_counts[d]) + int(delta[d]) for d in range(v)]
    metrics = pair_metrics(v, new_counts, target_counts)
    return {
        "block_pos": int(block_pos),
        "removed": int(removed),
        "added": int(added),
        "counts": new_counts,
        "metrics": metrics,
    }


def choose_move(v, side_blocks, side_counts, target_counts, args):
    best = None
    for _ in range(max(1, int(args.candidate_trials))):
        block_pos, removed, added = random_swap(v, side_blocks)
        item = evaluate_swap(v, side_blocks, side_counts, target_counts, block_pos, removed, added)
        if item is None:
            continue
        if best is None or objective_tuple(item["metrics"], args.objective) < objective_tuple(best["metrics"], args.objective):
            best = item
    return best


def apply_move(side_blocks, move):
    block = side_blocks[int(move["block_pos"])]
    block.remove(int(move["removed"]))
    block.add(int(move["added"]))


def temperature(step, steps, args):
    if args.strategy == "greedy":
        return 0.0
    progress = float(step) / float(max(1, steps))
    return max(float(args.min_temperature), float(args.temperature) * (1.0 - progress))


def accept_move(cur_metrics, new_metrics, local_step, args):
    if objective_tuple(new_metrics, args.objective) <= objective_tuple(cur_metrics, args.objective):
        return True
    if args.strategy == "greedy":
        return False
    if args.strategy == "mixed" and (local_step // max(1, int(args.mixed_period))) % 2 == 0:
        return False
    temp = temperature(local_step, args.steps_per_phase, args)
    if temp <= 0:
        return False
    score_delta = float(new_metrics[0] - cur_metrics[0])
    return random.random() < math.exp(-max(0.0, score_delta) / temp)


def shake(v, side_blocks, moves):
    for _ in range(max(1, int(moves))):
        block_pos, removed, added = random_swap(v, side_blocks)
        side_blocks[block_pos].remove(removed)
        side_blocks[block_pos].add(added)


def replace_side(blocks, side_indices, side_blocks):
    out = [set(block) for block in blocks]
    for pos, idx in enumerate(side_indices):
        out[int(idx)] = set(side_blocks[pos])
    return out


def optimize_side(v, blocks, fixed_indices, side_indices, lam, args, phase_label):
    fixed_blocks = [set(blocks[int(i)]) for i in fixed_indices]
    side_blocks = [set(blocks[int(i)]) for i in side_indices]
    fixed_counts = pair_counts(v, fixed_blocks)
    target_counts = [0] * v
    for d in range(1, v):
        target_counts[d] = int(lam) - int(fixed_counts[d])
    side_counts = pair_counts(v, side_blocks)
    cur_metrics = pair_metrics(v, side_counts, target_counts)
    initial_metrics = cur_metrics
    best_metrics = cur_metrics
    best_counts = list(side_counts)
    best_blocks = [set(block) for block in side_blocks]
    best_step = 0
    last_improvement_step = 0
    plateau_escape_count = 0

    for local_step in range(1, int(args.steps_per_phase) + 1):
        move = choose_move(v, side_blocks, side_counts, target_counts, args)
        if move is not None and accept_move(cur_metrics, move["metrics"], local_step, args):
            apply_move(side_blocks, move)
            side_counts = move["counts"]
            cur_metrics = move["metrics"]

        if objective_tuple(cur_metrics, args.objective) < objective_tuple(best_metrics, args.objective):
            best_metrics = cur_metrics
            best_counts = list(side_counts)
            best_blocks = [set(block) for block in side_blocks]
            best_step = local_step
            last_improvement_step = local_step

        if args.plateau_escape and local_step - last_improvement_step >= int(args.restart_patience):
            shake_moves = max(1, int(sum(len(block) for block in side_blocks) * float(args.shake_rate)))
            shake(v, side_blocks, shake_moves)
            side_counts = pair_counts(v, side_blocks)
            cur_metrics = pair_metrics(v, side_counts, target_counts)
            plateau_escape_count += 1
            last_improvement_step = local_step

    print(
        "phase={} side={} initial={} best={} best_step={} plateau={}".format(
            phase_label, side_indices, initial_metrics, best_metrics, best_step, plateau_escape_count
        )
    )
    return best_blocks, best_metrics, best_counts, best_step, plateau_escape_count


def save_current(path_base, v, ks, lam, blocks, metrics, source_json, round_index, phase, args):
    counts = total_diff_counts(v, blocks)
    exact_metrics = metrics_from_counts(counts, lam)
    if exact_metrics != metrics:
        raise RuntimeError("metrics mismatch {} != {}".format(metrics, exact_metrics))
    extra = {
        "coordinate_descent_round": int(round_index),
        "coordinate_descent_phase": phase,
        "objective": args.objective,
        "strategy": args.strategy,
        "candidate_trials": int(args.candidate_trials),
        "steps_per_phase": int(args.steps_per_phase),
        "source_json": source_json,
    }
    if metrics[0] == 0:
        return save_success(
            "outputs/candidates",
            "outputs/candidates/near_hits",
            v,
            ks,
            lam,
            blocks,
            metrics,
            source_json,
            "pair_profile_coordinate_descent",
            round_index,
            round_index,
            counts,
            extra=extra,
        )
    payload = base_payload(
        v,
        ks,
        lam,
        blocks,
        metrics,
        source_json,
        "pair_profile_coordinate_descent",
        round_index,
        round_index,
        counts,
        extra=extra,
    )
    path = "{}_round{}_{}_score{}.json".format(path_base, int(round_index), phase, int(metrics[0]))
    root, ext = os.path.splitext(path)
    if not ext:
        ext = ".json"
        path = root + ext
    counter = 1
    while os.path.exists(path):
        path = "{}_{}{}".format(root, counter, ext)
        counter += 1
    write_json(path, payload)
    return path


def parse_args():
    parser = argparse.ArgumentParser(
        description="Coordinate-descent alternation of left/right two-block pair-profile target searches."
    )
    parser.add_argument("candidate_json")
    parser.add_argument("--split", type=parse_split, default=parse_split("0,1:2,3"))
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--steps-per-phase", type=int, default=5000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--candidate-trials", type=int, default=64)
    parser.add_argument("--objective", choices=["complement_l2", "complement_l1", "balanced", "maxabs"], default="balanced")
    parser.add_argument("--strategy", choices=["greedy", "anneal", "mixed"], default="mixed")
    parser.add_argument("--temperature", type=float, default=20.0)
    parser.add_argument("--min-temperature", type=float, default=0.01)
    parser.add_argument("--mixed-period", type=int, default=1000)
    parser.add_argument("--plateau-escape", action="store_true")
    parser.add_argument("--restart-patience", type=int, default=2000)
    parser.add_argument("--shake-rate", type=float, default=0.04)
    parser.add_argument("--save-each-round", action="store_true")
    parser.add_argument("--out-prefix", default="outputs/candidates/near_hits/pair_coordinate_descent")
    parser.add_argument("--csv", default="")
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    csv_path = args.csv or os.path.join("outputs/logs", "{}_{}.csv".format(SCRIPT_NAME, stamp))
    try:
        _data, v, _n, ks, lam, blocks = load_candidate(args.candidate_json)
        blocks = [set(block) for block in blocks]
        left, right = args.split
        random.seed(int(args.seed))
        start = time.time()
        initial_metrics = full_metrics(v, blocks, lam)
        best_metrics = initial_metrics
        best_blocks = [set(block) for block in blocks]
        best_round = 0
        print(
            "target={} split={} rounds={} steps_per_phase={} initial_metrics={}".format(
                args.candidate_json, args.split, args.rounds, args.steps_per_phase, initial_metrics
            )
        )

        os.makedirs(os.path.dirname(csv_path) or ".", exist_ok=True)
        csv_file = open(csv_path, "w", newline="")
        fieldnames = [
            "timestamp",
            "round",
            "phase",
            "score",
            "l1_error",
            "max_abs_error",
            "nonzero_defect_count",
            "best_score",
            "best_l1_error",
            "best_max_abs_error",
            "best_nonzero_defect_count",
            "phase_pair_score",
            "phase_pair_l1_error",
            "phase_pair_max_abs_error",
            "phase_pair_nonzero_defect_count",
            "plateau_escape_count",
            "elapsed_sec",
            "path",
        ]
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()

        for round_index in range(1, int(args.rounds) + 1):
            for phase, fixed_indices, side_indices in [
                ("right", left, right),
                ("left", right, left),
            ]:
                side_blocks, phase_metrics, _phase_counts, _best_step, plateau_count = optimize_side(
                    v, blocks, fixed_indices, side_indices, lam, args, "round{}_{}".format(round_index, phase)
                )
                blocks = replace_side(blocks, side_indices, side_blocks)
                cur_metrics = full_metrics(v, blocks, lam)
                path = ""
                if objective_tuple(cur_metrics, args.objective) < objective_tuple(best_metrics, args.objective):
                    best_metrics = cur_metrics
                    best_blocks = [set(block) for block in blocks]
                    best_round = round_index
                    path = save_current(
                        args.out_prefix,
                        v,
                        ks,
                        lam,
                        best_blocks,
                        best_metrics,
                        args.candidate_json,
                        round_index,
                        phase,
                        args,
                    )
                    print("NEW_BEST round={} phase={} metrics={} path={}".format(round_index, phase, best_metrics, path))
                elif args.save_each_round:
                    path = save_current(
                        args.out_prefix,
                        v,
                        ks,
                        lam,
                        blocks,
                        cur_metrics,
                        args.candidate_json,
                        round_index,
                        phase,
                        args,
                    )

                row = {
                    "timestamp": timestamp(),
                    "round": int(round_index),
                    "phase": phase,
                    "score": int(cur_metrics[0]),
                    "l1_error": int(cur_metrics[1]),
                    "max_abs_error": int(cur_metrics[2]),
                    "nonzero_defect_count": int(cur_metrics[3]),
                    "best_score": int(best_metrics[0]),
                    "best_l1_error": int(best_metrics[1]),
                    "best_max_abs_error": int(best_metrics[2]),
                    "best_nonzero_defect_count": int(best_metrics[3]),
                    "phase_pair_score": int(phase_metrics[0]),
                    "phase_pair_l1_error": int(phase_metrics[1]),
                    "phase_pair_max_abs_error": int(phase_metrics[2]),
                    "phase_pair_nonzero_defect_count": int(phase_metrics[3]),
                    "plateau_escape_count": int(plateau_count),
                    "elapsed_sec": round(time.time() - start, 3),
                    "path": path,
                }
                writer.writerow(row)
                csv_file.flush()
                print(
                    "round={} phase={} cur={} best={} plateau={} elapsed={:.1f}s".format(
                        round_index, phase, cur_metrics, best_metrics, plateau_count, time.time() - start
                    )
                )
                sys.stdout.flush()
                if best_metrics[0] == 0:
                    break
            if best_metrics[0] == 0:
                break

        final_path = save_current(
            args.out_prefix,
            v,
            ks,
            lam,
            best_blocks,
            best_metrics,
            args.candidate_json,
            best_round,
            "final",
            args,
        )
        print("FINAL_BEST path={} metrics={} round={}".format(final_path, best_metrics, best_round))
        if best_metrics[0] == 0:
            print("SUCCESS CANDIDATE GENERATED AND VERIFIED")
        else:
            print("DONE: no verified success candidate from pair coordinate descent.")
        csv_file.close()
    finally:
        tee.close()


if __name__ == "__main__":
    main()
