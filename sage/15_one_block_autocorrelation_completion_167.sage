from sage.all import *

import argparse
import csv
import json
import math
import os
import random
import sys
import time

from sds_repair_utils import (
    apply_delta,
    delta_swap,
    error_histogram,
    json_blocks,
    load_candidate,
    metrics_from_counts,
    save_near_hit,
    save_success,
    setup_logging,
    timestamp,
    total_diff_counts,
    validate_params,
)


SEARCH_METHOD = "one_block_autocorrelation_completion_167"
DEFAULT_V = 167
DEFAULT_KS = (76, 76, 77, 80)
DEFAULT_LAM = 142


def parse_ks(value):
    try:
        ks = tuple(int(part.strip()) for part in value.split(",") if part.strip())
    except ValueError:
        raise argparse.ArgumentTypeError("--ks must contain comma-separated integers")
    if len(ks) != 4:
        raise argparse.ArgumentTypeError("--ks must contain exactly four integers")
    return ks


def block_diff_counts(v, block):
    return total_diff_counts(v, [block])


def translate_block_to_zero(v, block):
    values = set(int(x) % int(v) for x in block)
    if not values or 0 in values:
        return values
    shift = -min(values)
    return set((x + shift) % int(v) for x in values)


def random_block(v, k, include_zero=True):
    v = int(v)
    k = int(k)
    if include_zero:
        if k < 1:
            return set()
        return set([0] + random.sample(list(range(1, v)), k - 1))
    return set(random.sample(list(range(v)), k))


def random_blocks_for_params(v, ks, include_zero=True):
    return [random_block(v, k, include_zero=include_zero) for k in ks]


def load_or_create_blocks(args, ks, lam):
    source_data = None
    if args.from_json:
        source_data, v, n, source_ks, source_lam, blocks = load_candidate(args.from_json)
        if v != args.v:
            raise ValueError("source v={} does not match --v={}".format(v, args.v))
        if source_ks != ks:
            raise ValueError(
                "source ks={} does not match --ks={}".format(source_ks, ks)
            )
        if source_lam != lam:
            raise ValueError(
                "source lambda={} does not match --lam={}".format(source_lam, lam)
            )
        if args.zero_normalize:
            blocks = [translate_block_to_zero(args.v, block) for block in blocks]
        if not args.use_json_completion:
            blocks[args.complete_index] = random_block(
                args.v, ks[args.complete_index], include_zero=args.zero_normalize
            )
        return blocks, source_data

    blocks = random_blocks_for_params(args.v, ks, include_zero=args.zero_normalize)
    return blocks, source_data


def residual_stats(v, lam, fixed_counts):
    residual = [0] * v
    for d in range(1, v):
        residual[d] = int(lam - fixed_counts[d])
    nonzero_values = [residual[d] for d in range(1, v)]
    negative = [d for d in range(1, v) if residual[d] < 0]
    return residual, {
        "min_residual": int(min(nonzero_values)),
        "max_residual": int(max(nonzero_values)),
        "negative_residual_count": int(len(negative)),
        "negative_residual_shifts_first": [int(d) for d in negative[:30]],
        "residual_sum": int(sum(nonzero_values)),
    }


def objective_tuple(metrics):
    score, l1_error, max_abs_error, nonzero_defect_count = metrics
    return (
        int(score),
        int(l1_error),
        int(max_abs_error),
        int(nonzero_defect_count),
    )


def objective_scalar(metrics):
    score, l1_error, max_abs_error, nonzero_defect_count = metrics
    return (
        float(score)
        + 0.1 * float(l1_error)
        + 2.0 * float(max_abs_error * max_abs_error)
        + 0.5 * float(nonzero_defect_count)
    )


def anneal_accept(old_scalar, new_scalar, temp):
    exponent = (float(old_scalar) - float(new_scalar)) / float(temp)
    if exponent >= 0:
        return True
    if exponent < -745:
        return False
    return random.random() < math.exp(exponent)


def allowed_removed_values(block, keep_zero):
    values = sorted(int(x) for x in block)
    if keep_zero:
        values = [x for x in values if x != 0]
    return values


def sample_best_swap(v, block, counts, lam, samples, keep_zero):
    removed_values = allowed_removed_values(block, keep_zero)
    if not removed_values:
        return None
    outside = [x for x in range(v) if x not in block]
    if not outside:
        return None

    best = None
    seen = set()
    attempts = max(int(samples) * 3, int(samples) + 10)
    for _ in range(attempts):
        if len(seen) >= int(samples):
            break
        removed = random.choice(removed_values)
        added = random.choice(outside)
        key = (removed, added)
        if key in seen:
            continue
        seen.add(key)
        delta = delta_swap(v, block, removed, added)
        new_counts = apply_delta(counts, delta)
        new_metrics = metrics_from_counts(new_counts, lam)
        item = {
            "removed": int(removed),
            "added": int(added),
            "delta": delta,
            "counts": new_counts,
            "metrics": new_metrics,
        }
        if best is None or objective_tuple(new_metrics) < objective_tuple(best["metrics"]):
            best = item
    return best


def apply_completion_swap(blocks, complete_index, swap):
    block = blocks[complete_index]
    removed = int(swap["removed"])
    added = int(swap["added"])
    block.remove(removed)
    block.add(added)


def shake_completion_block(v, blocks, complete_index, shake_rate, keep_zero):
    block = blocks[complete_index]
    shake_moves = max(1, int(math.ceil(float(len(block)) * float(shake_rate))))
    applied = 0
    for _ in range(shake_moves):
        removed_values = allowed_removed_values(block, keep_zero)
        outside = [x for x in range(v) if x not in block]
        if not removed_values or not outside:
            break
        removed = random.choice(removed_values)
        added = random.choice(outside)
        block.remove(removed)
        block.add(added)
        applied += 1
    return applied


def format_metrics(metrics):
    return "score={} l1_error={} max_abs_error={} nonzero_defect_count={}".format(
        metrics[0], metrics[1], metrics[2], metrics[3]
    )


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Experimental one-block autocorrelation completion for v=167 SDS "
            "parameters, especially ks=(76,76,77,80), lambda=142."
        )
    )
    parser.add_argument("--v", type=int, default=DEFAULT_V)
    parser.add_argument("--ks", type=parse_ks, default=DEFAULT_KS)
    parser.add_argument("--lam", type=int, default=DEFAULT_LAM)
    parser.add_argument(
        "--complete-index",
        type=int,
        default=3,
        help="Block index to search/complete. Default 3, the size-80 block.",
    )
    parser.add_argument(
        "--from-json",
        help="Optional candidate/near-hit JSON with matching v, ks, lambda. "
        "Blocks other than --complete-index are fixed.",
    )
    parser.add_argument(
        "--use-json-completion",
        action="store_true",
        help="When --from-json is used, start from the JSON completion block instead "
        "of replacing it by a random block.",
    )
    parser.add_argument(
        "--no-zero-normalization",
        dest="zero_normalize",
        action="store_false",
        help="Do not translate each block to contain 0 and do not keep 0 fixed in "
        "the completion block.",
    )
    parser.set_defaults(zero_normalize=True)
    parser.add_argument("--steps", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument(
        "--strategy",
        choices=["greedy", "anneal", "mixed"],
        default="mixed",
        help="Acceptance policy. mixed alternates greedy and anneal windows.",
    )
    parser.add_argument("--candidate-samples", type=int, default=256)
    parser.add_argument("--temperature", type=float, default=1.0)
    parser.add_argument("--restart-patience", type=int, default=5000)
    parser.add_argument("--plateau-escape", action="store_true")
    parser.add_argument("--shake-rate", type=float, default=0.05)
    parser.add_argument("--log-interval", type=int, default=5000)
    parser.add_argument("--near-hit-dir", default="outputs/candidates/near_hits")
    parser.add_argument("--candidate-dir", default="outputs/candidates")
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging("15_one_block_autocorrelation_completion_167")
    csv_path = os.path.join(
        "outputs/logs",
        "15_one_block_autocorrelation_completion_167_{}.csv".format(stamp),
    )

    try:
        random.seed(int(args.seed))
        ks = tuple(int(k) for k in args.ks)
        lam = int(args.lam)
        validate_params(int(args.v), ks, lam)
        if args.complete_index < 0 or args.complete_index >= len(ks):
            raise ValueError("--complete-index must be between 0 and 3")

        blocks, source_data = load_or_create_blocks(args, ks, lam)
        source_json = args.from_json
        fixed_indices = [idx for idx in range(4) if idx != args.complete_index]
        fixed_blocks = [blocks[idx] for idx in fixed_indices]
        fixed_counts = total_diff_counts(args.v, fixed_blocks)
        residual, residual_summary = residual_stats(args.v, lam, fixed_counts)
        completion_counts = block_diff_counts(args.v, blocks[args.complete_index])
        counts = [fixed_counts[d] + completion_counts[d] for d in range(args.v)]
        cur_metrics = metrics_from_counts(counts, lam)
        best_metrics = cur_metrics
        best_blocks = [set(block) for block in blocks]
        best_counts = list(counts)

        print("CSV log:", csv_path)
        print(
            "v={} n={} ks={} lambda={} complete_index={} fixed_indices={}".format(
                args.v, 4 * args.v, ks, lam, args.complete_index, fixed_indices
            )
        )
        print(
            "mode={} source_json={} use_json_completion={} zero_normalize={}".format(
                "from_json" if args.from_json else "random_fixed_blocks",
                args.from_json,
                bool(args.use_json_completion),
                bool(args.zero_normalize),
            )
        )
        print("residual_summary={}".format(json.dumps(residual_summary, sort_keys=True)))
        print("initial {}".format(format_metrics(cur_metrics)))

        csv_file = open(csv_path, "w", newline="")
        writer = csv.DictWriter(
            csv_file,
            fieldnames=[
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
                "strategy",
                "temperature",
                "plateau_escape_count",
                "last_improvement_step",
                "elapsed_sec",
            ],
        )
        writer.writeheader()

        start = time.time()
        plateau_escape_count = 0
        last_improvement_step = 0
        success_path = None

        for step in range(1, int(args.steps) + 1):
            active_strategy = args.strategy
            if args.strategy == "mixed":
                active_strategy = "greedy" if (step // 5000) % 2 == 0 else "anneal"

            proposal = sample_best_swap(
                args.v,
                blocks[args.complete_index],
                counts,
                lam,
                args.candidate_samples,
                keep_zero=args.zero_normalize,
            )
            if proposal is None:
                break

            new_metrics = proposal["metrics"]
            accepted = False
            if objective_tuple(new_metrics) <= objective_tuple(cur_metrics):
                accepted = True
            elif active_strategy == "anneal":
                temp = max(
                    0.01,
                    float(args.temperature) * (1.0 - float(step) / float(args.steps)),
                )
                old_scalar = objective_scalar(cur_metrics)
                new_scalar = objective_scalar(new_metrics)
                if anneal_accept(old_scalar, new_scalar, temp):
                    accepted = True

            if accepted:
                apply_completion_swap(blocks, args.complete_index, proposal)
                counts = proposal["counts"]
                cur_metrics = new_metrics

            if objective_tuple(cur_metrics) < objective_tuple(best_metrics):
                best_metrics = cur_metrics
                best_blocks = [set(block) for block in blocks]
                best_counts = list(counts)
                last_improvement_step = step
                print(
                    "BEST step={} {}".format(step, format_metrics(best_metrics))
                )
                print("BEST error_histogram={}".format(error_histogram(best_counts, lam)))
                sys.stdout.flush()

                if best_metrics[0] == 0:
                    success_path = save_success(
                        args.candidate_dir,
                        args.near_hit_dir,
                        args.v,
                        ks,
                        lam,
                        best_blocks,
                        best_metrics,
                        source_json,
                        SEARCH_METHOD,
                        1,
                        step,
                        best_counts,
                        extra={
                            "seed": int(args.seed),
                            "steps": int(args.steps),
                            "complete_index": int(args.complete_index),
                            "fixed_indices": [int(x) for x in fixed_indices],
                            "residual_summary": residual_summary,
                            "completion_contains_zero": bool(args.zero_normalize),
                        },
                    )
                    break

            stagnant = step - last_improvement_step
            if (
                args.plateau_escape
                and args.restart_patience > 0
                and stagnant >= int(args.restart_patience)
            ):
                applied = shake_completion_block(
                    args.v,
                    blocks,
                    args.complete_index,
                    args.shake_rate,
                    keep_zero=args.zero_normalize,
                )
                completion_counts = block_diff_counts(args.v, blocks[args.complete_index])
                counts = [fixed_counts[d] + completion_counts[d] for d in range(args.v)]
                cur_metrics = metrics_from_counts(counts, lam)
                plateau_escape_count += 1
                last_improvement_step = step
                print(
                    "PLATEAU_ESCAPE step={} shake_moves={} {}".format(
                        step, applied, format_metrics(cur_metrics)
                    )
                )

            if step == 1 or step % int(args.log_interval) == 0:
                elapsed = time.time() - start
                temp = max(
                    0.01,
                    float(args.temperature) * (1.0 - float(step) / float(args.steps)),
                )
                row = {
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
                    "strategy": active_strategy,
                    "temperature": float(temp),
                    "plateau_escape_count": int(plateau_escape_count),
                    "last_improvement_step": int(last_improvement_step),
                    "elapsed_sec": float(elapsed),
                }
                writer.writerow(row)
                csv_file.flush()
                print(
                    "step={step} score={score} l1_error={l1_error} "
                    "max_abs_error={max_abs_error} nonzero_defect_count={nonzero_defect_count} "
                    "best_score={best_score} best_l1_error={best_l1_error} "
                    "best_max_abs_error={best_max_abs_error} "
                    "best_nonzero_defect_count={best_nonzero_defect_count} "
                    "strategy={strategy} plateau_escape_count={plateau_escape_count} "
                    "elapsed_sec={elapsed_sec:.2f}".format(**row)
                )
                sys.stdout.flush()

        csv_file.close()

        if success_path is None:
            near_hit_path = save_near_hit(
                args.near_hit_dir,
                args.v,
                ks,
                lam,
                best_blocks,
                best_metrics,
                source_json,
                SEARCH_METHOD,
                1,
                int(args.steps),
                best_counts,
                extra={
                    "seed": int(args.seed),
                    "steps": int(args.steps),
                    "complete_index": int(args.complete_index),
                    "fixed_indices": [int(x) for x in fixed_indices],
                    "residual_summary": residual_summary,
                    "completion_contains_zero": bool(args.zero_normalize),
                    "fixed_block_generation": "from_json"
                    if args.from_json
                    else "random",
                    "use_json_completion": bool(args.use_json_completion),
                },
            )
            print(
                "DONE: no verified success candidate. final_near_hit={}".format(
                    near_hit_path
                )
            )
            print("final {}".format(format_metrics(best_metrics)))
        else:
            print("DONE: verified success candidate={}".format(success_path))

    finally:
        sys.stdout.flush()
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
