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
    json_blocks,
    load_candidate,
    metrics_from_counts,
    save_success,
    setup_logging,
    timestamp,
    total_diff_counts,
    write_json,
)


SCRIPT_NAME = "26_pair_profile_target_search"


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


def random_blocks(v, sizes):
    universe = list(range(v))
    return [set(random.sample(universe, int(size))) for size in sizes]


def metrics_from_pair_counts(v, generated_counts, target_counts):
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


def error_histogram_from_pair(v, generated_counts, target_counts):
    hist = {}
    for d in range(1, v):
        err = int(generated_counts[d]) - int(target_counts[d])
        hist[err] = hist.get(err, 0) + 1
    return {str(key): int(hist[key]) for key in sorted(hist)}


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


def evaluate_swap(v, blocks, generated_counts, target_counts, block_pos, removed, added):
    block = blocks[block_pos]
    if removed not in block or added in block:
        return None
    delta = delta_swap(v, block, removed, added)
    new_counts = [int(generated_counts[d]) + int(delta[d]) for d in range(v)]
    metrics = metrics_from_pair_counts(v, new_counts, target_counts)
    return {
        "block_pos": int(block_pos),
        "removed": int(removed),
        "added": int(added),
        "delta": delta,
        "counts": new_counts,
        "metrics": metrics,
    }


def choose_move(v, blocks, generated_counts, target_counts, args):
    trials = max(1, int(args.candidate_trials))
    best = None
    for _ in range(trials):
        block_pos, removed, added = random_swap(v, blocks)
        item = evaluate_swap(v, blocks, generated_counts, target_counts, block_pos, removed, added)
        if item is None:
            continue
        if best is None or objective_tuple(item["metrics"], args.objective) < objective_tuple(best["metrics"], args.objective):
            best = item
    return best


def apply_move(blocks, move):
    block = blocks[int(move["block_pos"])]
    block.remove(int(move["removed"]))
    block.add(int(move["added"]))


def temperature(step, steps, args):
    if args.strategy == "greedy":
        return 0.0
    progress = float(step) / float(max(1, steps))
    return max(float(args.min_temperature), float(args.temperature) * (1.0 - progress))


def accept_move(cur_metrics, new_metrics, step, args):
    cur_tuple = objective_tuple(cur_metrics, args.objective)
    new_tuple = objective_tuple(new_metrics, args.objective)
    if new_tuple <= cur_tuple:
        return True
    if args.strategy == "greedy":
        return False
    if args.strategy == "mixed" and (step // max(1, int(args.mixed_period))) % 2 == 0:
        return False
    temp = temperature(step, args.steps, args)
    if temp <= 0:
        return False
    score_delta = float(new_metrics[0] - cur_metrics[0])
    return random.random() < math.exp(-max(0.0, score_delta) / temp)


def combined_blocks(original_blocks, fixed_indices, generated_indices, generated_blocks):
    out = [set() for _ in range(4)]
    for idx in fixed_indices:
        out[int(idx)] = set(original_blocks[int(idx)])
    for pos, idx in enumerate(generated_indices):
        out[int(idx)] = set(generated_blocks[pos])
    return out


def save_candidate(path_base, v, ks, lam, original_blocks, fixed_indices, generated_indices, generated_blocks, metrics, source_json, step, args, generated_counts, target_counts):
    blocks = combined_blocks(original_blocks, fixed_indices, generated_indices, generated_blocks)
    counts = total_diff_counts(v, blocks)
    exact_metrics = metrics_from_counts(counts, lam)
    if exact_metrics != metrics:
        raise RuntimeError("pair metrics {} != exact full metrics {}".format(metrics, exact_metrics))
    extra = {
        "fixed_source_json": source_json,
        "fixed_side": args.fixed_side,
        "fixed_indices": [int(i) for i in fixed_indices],
        "generated_indices": [int(i) for i in generated_indices],
        "pair_target_search_step": int(step),
        "objective": args.objective,
        "strategy": args.strategy,
        "candidate_trials": int(args.candidate_trials),
        "target_error_histogram": error_histogram_from_pair(v, generated_counts, target_counts),
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
            "pair_profile_target_search",
            step,
            step,
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
        "pair_profile_target_search",
        step,
        step,
        counts,
        extra=extra,
    )
    path = "{}_step{}_score{}.json".format(path_base, int(step), int(metrics[0]))
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


def shake(v, blocks, moves):
    for _ in range(max(1, int(moves))):
        block_pos, removed, added = random_swap(v, blocks)
        block = blocks[block_pos]
        block.remove(removed)
        block.add(added)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Local-search a two-block pair profile toward the residual target from a fixed pair."
    )
    parser.add_argument("candidate_json")
    parser.add_argument("--split", type=parse_split, default=parse_split("0,1:2,3"))
    parser.add_argument("--fixed-side", choices=["left", "right"], default="left")
    parser.add_argument("--init", choices=["input", "random"], default="input")
    parser.add_argument("--steps", type=int, default=100000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--candidate-trials", type=int, default=32)
    parser.add_argument("--objective", choices=["complement_l2", "complement_l1", "balanced", "maxabs"], default="balanced")
    parser.add_argument("--strategy", choices=["greedy", "anneal", "mixed"], default="mixed")
    parser.add_argument("--temperature", type=float, default=10.0)
    parser.add_argument("--min-temperature", type=float, default=0.01)
    parser.add_argument("--mixed-period", type=int, default=1000)
    parser.add_argument("--plateau-escape", action="store_true")
    parser.add_argument("--restart-patience", type=int, default=10000)
    parser.add_argument("--shake-rate", type=float, default=0.05)
    parser.add_argument("--save-improvements", action="store_true")
    parser.add_argument("--out-prefix", default="outputs/candidates/near_hits/pair_target_search")
    parser.add_argument("--csv", default="")
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    csv_path = args.csv or os.path.join("outputs/logs", "{}_{}.csv".format(SCRIPT_NAME, stamp))
    try:
        data, v, _n, ks, lam, original_blocks = load_candidate(args.candidate_json)
        left, right = args.split
        if args.fixed_side == "left":
            fixed_indices = left
            generated_indices = right
        else:
            fixed_indices = right
            generated_indices = left
        fixed_blocks = [original_blocks[int(i)] for i in fixed_indices]
        fixed_counts = pair_counts(v, fixed_blocks)
        target_counts = [0] * v
        for d in range(1, v):
            target_counts[d] = int(lam) - int(fixed_counts[d])

        random.seed(int(args.seed))
        generated_sizes = [int(ks[int(i)]) for i in generated_indices]
        if args.init == "input":
            generated_blocks = [set(original_blocks[int(i)]) for i in generated_indices]
        else:
            generated_blocks = random_blocks(v, generated_sizes)
        generated_counts = pair_counts(v, generated_blocks)
        cur_metrics = metrics_from_pair_counts(v, generated_counts, target_counts)
        best_metrics = cur_metrics
        best_counts = list(generated_counts)
        best_blocks = [set(block) for block in generated_blocks]
        best_step = 0
        last_improvement_step = 0
        plateau_escape_count = 0
        start = time.time()

        os.makedirs(os.path.dirname(csv_path) or ".", exist_ok=True)
        csv_file = open(csv_path, "w", newline="")
        fieldnames = [
            "timestamp",
            "step",
            "score",
            "l1_error",
            "max_abs_error",
            "nonzero_defect_count",
            "best_score",
            "best_l1_error",
            "best_max_abs_error",
            "best_nonzero_defect_count",
            "accepted",
            "improved_best",
            "plateau_escape_count",
            "last_improvement_step",
            "elapsed_sec",
        ]
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        print("CSV log:", csv_path)
        print(
            "target={} fixed_side={} fixed_indices={} generated_indices={} init={} "
            "initial_metrics={}".format(
                args.candidate_json,
                args.fixed_side,
                fixed_indices,
                generated_indices,
                args.init,
                cur_metrics,
            )
        )

        for step in range(1, int(args.steps) + 1):
            move = choose_move(v, generated_blocks, generated_counts, target_counts, args)
            accepted = False
            improved_best = False
            if move is not None and accept_move(cur_metrics, move["metrics"], step, args):
                apply_move(generated_blocks, move)
                generated_counts = move["counts"]
                cur_metrics = move["metrics"]
                accepted = True

            if objective_tuple(cur_metrics, args.objective) < objective_tuple(best_metrics, args.objective):
                best_metrics = cur_metrics
                best_counts = list(generated_counts)
                best_blocks = [set(block) for block in generated_blocks]
                best_step = step
                last_improvement_step = step
                improved_best = True
                print(
                    "BEST step={} metrics={} objective_tuple={}".format(
                        step, best_metrics, objective_tuple(best_metrics, args.objective)
                    )
                )
                if args.save_improvements:
                    path = save_candidate(
                        args.out_prefix,
                        v,
                        ks,
                        lam,
                        original_blocks,
                        fixed_indices,
                        generated_indices,
                        best_blocks,
                        best_metrics,
                        args.candidate_json,
                        step,
                        args,
                        best_counts,
                        target_counts,
                    )
                    print("saved_best:", path)
                sys.stdout.flush()

            if args.plateau_escape and step - last_improvement_step >= int(args.restart_patience):
                shake_moves = max(1, int(sum(generated_sizes) * float(args.shake_rate)))
                shake(v, generated_blocks, shake_moves)
                generated_counts = pair_counts(v, generated_blocks)
                cur_metrics = metrics_from_pair_counts(v, generated_counts, target_counts)
                plateau_escape_count += 1
                last_improvement_step = step
                print(
                    "PLATEAU_ESCAPE step={} count={} shake_moves={} cur_metrics={}".format(
                        step, plateau_escape_count, shake_moves, cur_metrics
                    )
                )
                sys.stdout.flush()

            if step % 5000 == 0 or step == int(args.steps) or improved_best:
                row = {
                    "timestamp": timestamp(),
                    "step": int(step),
                    "score": int(cur_metrics[0]),
                    "l1_error": int(cur_metrics[1]),
                    "max_abs_error": int(cur_metrics[2]),
                    "nonzero_defect_count": int(cur_metrics[3]),
                    "best_score": int(best_metrics[0]),
                    "best_l1_error": int(best_metrics[1]),
                    "best_max_abs_error": int(best_metrics[2]),
                    "best_nonzero_defect_count": int(best_metrics[3]),
                    "accepted": bool(accepted),
                    "improved_best": bool(improved_best),
                    "plateau_escape_count": int(plateau_escape_count),
                    "last_improvement_step": int(last_improvement_step),
                    "elapsed_sec": round(time.time() - start, 3),
                }
                writer.writerow(row)
                csv_file.flush()
                if step % 5000 == 0 or step == int(args.steps):
                    print(
                        "step={} cur={} best={} best_step={} plateau={} elapsed={:.1f}s".format(
                            step, cur_metrics, best_metrics, best_step, plateau_escape_count, time.time() - start
                        )
                    )
                    sys.stdout.flush()

            if best_metrics[0] == 0:
                break

        final_path = save_candidate(
            args.out_prefix,
            v,
            ks,
            lam,
            original_blocks,
            fixed_indices,
            generated_indices,
            best_blocks,
            best_metrics,
            args.candidate_json,
            best_step,
            args,
            best_counts,
            target_counts,
        )
        print("FINAL_BEST path={} metrics={} step={}".format(final_path, best_metrics, best_step))
        if best_metrics[0] == 0:
            print("SUCCESS CANDIDATE GENERATED AND VERIFIED")
        else:
            print("DONE: no verified success candidate from pair target search.")
        csv_file.close()
    finally:
        tee.close()


if __name__ == "__main__":
    main()
