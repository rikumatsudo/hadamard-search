from sage.all import *

import argparse
import json
import os
import random
import sys

from sds_repair_utils import (
    base_payload,
    error_histogram,
    json_blocks,
    load_candidate,
    metrics_from_counts,
    save_success,
    setup_logging,
    total_diff_counts,
    write_json,
)


SCRIPT_NAME = "25_pair_profile_target_completion"


def parse_split(text):
    try:
        left_text, right_text = text.split(":")
        left = tuple(int(x) for x in left_text.split(",") if x != "")
        right = tuple(int(x) for x in right_text.split(",") if x != "")
    except ValueError:
        raise argparse.ArgumentTypeError("split must look like 0,1:2,3")
    if sorted(list(left) + list(right)) != [0, 1, 2, 3]:
        raise argparse.ArgumentTypeError("split must partition 0,1,2,3")
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


def pair_profile(v, blocks):
    counts = [0] * v
    for block in blocks:
        block_counts = diff_counts_from_bits(v, block_to_bits(block))
        for d in range(v):
            counts[d] += block_counts[d]
    return [int(counts[d]) for d in range(1, v)]


def random_pair(v, sizes):
    universe = list(range(v))
    return [set(random.sample(universe, int(size))) for size in sizes]


def target_metrics(profile, target):
    score = 0
    l1_error = 0
    max_abs_error = 0
    nonzero_defect_count = 0
    for idx, value in enumerate(profile):
        err = int(value) - int(target[idx])
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


def full_metrics_from_pair_profiles(fixed_profile, generated_profile, lam):
    score = 0
    l1_error = 0
    max_abs_error = 0
    nonzero_defect_count = 0
    for idx, value in enumerate(generated_profile):
        err = int(fixed_profile[idx]) + int(value) - int(lam)
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


def rank_entry(entry, objective):
    tm = entry["target_metrics"]
    fm = entry["full_metrics"]
    if objective == "complement_l2":
        return tm + fm + (int(entry["sample_index"]),)
    if objective == "complement_l1":
        return (tm[1], tm[0], tm[2], tm[3]) + fm + (int(entry["sample_index"]),)
    if objective == "full_score":
        return fm + tm + (int(entry["sample_index"]),)
    if objective == "balanced":
        return (
            fm[0],
            fm[1],
            tm[0],
            tm[1],
            fm[2],
            fm[3],
            tm[2],
            tm[3],
            int(entry["sample_index"]),
        )
    raise ValueError("unknown objective {}".format(objective))


def insert_top(top, entry, keep_top, objective):
    top.append(entry)
    top.sort(key=lambda item: rank_entry(item, objective))
    if len(top) > int(keep_top):
        del top[int(keep_top) :]


def combined_blocks(blocks, fixed_indices, generated_indices, generated_pair):
    out = [set() for _ in range(4)]
    for idx in fixed_indices:
        out[int(idx)] = set(blocks[int(idx)])
    for pos, idx in enumerate(generated_indices):
        out[int(idx)] = set(generated_pair[pos])
    return out


def make_entry(
    v,
    ks,
    lam,
    blocks,
    fixed_indices,
    generated_indices,
    fixed_profile,
    target,
    generated_pair,
    sample_index,
    objective,
):
    generated_profile = pair_profile(v, generated_pair)
    tm = target_metrics(generated_profile, target)
    fm = full_metrics_from_pair_profiles(fixed_profile, generated_profile, lam)
    full_blocks = combined_blocks(blocks, fixed_indices, generated_indices, generated_pair)
    return {
        "sample_index": int(sample_index),
        "target_metrics": tm,
        "full_metrics": fm,
        "generated_blocks": json_blocks(generated_pair),
        "blocks": json_blocks(full_blocks),
        "rank": None,
        "objective": objective,
    }


def save_outputs(top, args, v, ks, lam, fixed_source, fixed_indices, generated_indices):
    saved = []
    near_hit_dir = "outputs/candidates/near_hits"
    success_dir = "outputs/candidates"
    for rank, entry in enumerate(top[: int(args.save_candidates)], 1):
        blocks = [set(int(x) for x in block) for block in entry["blocks"]]
        counts = total_diff_counts(v, blocks)
        metrics = metrics_from_counts(counts, lam)
        extra = {
            "pair_profile_target_completion_rank": int(rank),
            "fixed_source_json": fixed_source,
            "fixed_indices": [int(i) for i in fixed_indices],
            "generated_indices": [int(i) for i in generated_indices],
            "target_metrics": {
                "score": int(entry["target_metrics"][0]),
                "l1_error": int(entry["target_metrics"][1]),
                "max_abs_error": int(entry["target_metrics"][2]),
                "nonzero_defect_count": int(entry["target_metrics"][3]),
            },
        }
        if metrics[0] == 0:
            path = save_success(
                success_dir,
                near_hit_dir,
                v,
                ks,
                lam,
                blocks,
                metrics,
                args.out,
                "pair_profile_target_completion",
                rank,
                rank,
                counts,
                extra=extra,
            )
            saved.append({"rank": int(rank), "path": path, "success_candidate": True})
        else:
            payload = base_payload(
                v,
                ks,
                lam,
                blocks,
                metrics,
                args.out,
                "pair_profile_target_completion",
                rank,
                rank,
                counts,
                extra=extra,
            )
            path = os.path.join(
                near_hit_dir,
                "near_hit_v{}_score{}_pair_profile_target_completion_rank{}.json".format(
                    v, metrics[0], rank
                ),
            )
            root, ext = os.path.splitext(path)
            counter = 1
            while os.path.exists(path):
                path = "{}_{}{}".format(root, counter, ext)
                counter += 1
            write_json(path, payload)
            saved.append({"rank": int(rank), "path": path, "success_candidate": False})
    return saved


def parse_args():
    parser = argparse.ArgumentParser(
        description="Fix one pair from an existing near-hit and randomly complete the opposite pair by target-complement profile."
    )
    parser.add_argument("candidate_json")
    parser.add_argument("--split", type=parse_split, default=parse_split("0,1:2,3"))
    parser.add_argument(
        "--fixed-side",
        choices=["left", "right"],
        default="left",
        help="Which side of the split is fixed from the input candidate.",
    )
    parser.add_argument("--samples", type=int, default=10000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--keep-top", type=int, default=100)
    parser.add_argument("--save-candidates", type=int, default=20)
    parser.add_argument(
        "--objective",
        choices=["complement_l2", "complement_l1", "full_score", "balanced"],
        default="balanced",
    )
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    tee, _stamp = setup_logging(SCRIPT_NAME)
    try:
        data, v, _n, ks, lam, blocks = load_candidate(args.candidate_json)
        left, right = args.split
        if args.fixed_side == "left":
            fixed_indices = left
            generated_indices = right
        else:
            fixed_indices = right
            generated_indices = left
        fixed_blocks = [blocks[int(i)] for i in fixed_indices]
        fixed_profile = pair_profile(v, fixed_blocks)
        target = [int(lam) - int(value) for value in fixed_profile]
        generated_sizes = [int(ks[int(i)]) for i in generated_indices]
        random.seed(int(args.seed))

        top = []
        for sample_index in range(1, int(args.samples) + 1):
            generated_pair = random_pair(v, generated_sizes)
            entry = make_entry(
                v,
                ks,
                lam,
                blocks,
                fixed_indices,
                generated_indices,
                fixed_profile,
                target,
                generated_pair,
                sample_index,
                args.objective,
            )
            if len(top) < int(args.keep_top) or rank_entry(entry, args.objective) < rank_entry(top[-1], args.objective):
                insert_top(top, entry, args.keep_top, args.objective)
            if sample_index % 5000 == 0:
                best = top[0]
                print(
                    "sample={} best_full_metrics={} best_target_metrics={}".format(
                        sample_index, best["full_metrics"], best["target_metrics"]
                    )
                )
                sys.stdout.flush()

        for rank, entry in enumerate(top, 1):
            entry["rank"] = int(rank)
        saved = save_outputs(top, args, v, ks, lam, args.candidate_json, fixed_indices, generated_indices)
        payload = {
            "script": SCRIPT_NAME,
            "candidate_json": args.candidate_json,
            "v": int(v),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "split": {
                "left": [int(i) for i in left],
                "right": [int(i) for i in right],
            },
            "fixed_side": args.fixed_side,
            "fixed_indices": [int(i) for i in fixed_indices],
            "generated_indices": [int(i) for i in generated_indices],
            "generated_sizes": generated_sizes,
            "samples": int(args.samples),
            "seed": int(args.seed),
            "objective": args.objective,
            "keep_top": int(args.keep_top),
            "top": top,
            "saved_candidates": saved,
        }
        write_json(args.out, payload)
        print("WROTE:", args.out)
        if top:
            print("best_full_metrics:", top[0]["full_metrics"])
            print("best_target_metrics:", top[0]["target_metrics"])
        if any(item.get("success_candidate") for item in saved):
            print("SUCCESS CANDIDATE GENERATED AND VERIFIED")
        else:
            print("DONE: no verified success candidate from target completion.")
    finally:
        tee.close()


if __name__ == "__main__":
    main()
