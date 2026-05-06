from sage.all import *

import argparse
import hashlib
import json
import os
import random
import sys

from sds_repair_utils import canonical_hash, json_blocks, setup_logging, write_json


SCRIPT_NAME = "23_pair_profile_generator"


def block_to_bits(block):
    bits = 0
    for x in block:
        bits |= 1 << int(x)
    return bits


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
    per_block = []
    for block in blocks:
        block_counts = diff_counts_from_bits(v, block_to_bits(block))
        per_block.append(block_counts)
        for d in range(v):
            counts[d] += block_counts[d]
    return [int(counts[d]) for d in range(1, v)], per_block


def profile_hash(v, sizes, profile):
    payload = {
        "v": int(v),
        "sizes": [int(x) for x in sizes],
        "profile": [int(x) for x in profile],
    }
    text = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def profile_stats(profile):
    length = len(profile)
    total = int(sum(profile))
    balance_score_scaled = 0
    l1_scaled = 0
    max_scaled_deviation = 0
    for value in profile:
        scaled = int(value) * length - total
        balance_score_scaled += scaled * scaled
        l1_scaled += abs(scaled)
        max_scaled_deviation = max(max_scaled_deviation, abs(scaled))
    adjacent_roughness = 0
    for idx in range(length):
        adjacent_roughness += abs(int(profile[idx]) - int(profile[(idx + 1) % length]))
    return {
        "total_ordered_differences": total,
        "mean_numerator": total,
        "mean_denominator": int(length),
        "profile_balance_score": int(balance_score_scaled),
        "profile_l1_to_mean": int(l1_scaled),
        "max_profile_spike_scaled": int(max_scaled_deviation),
        "min_profile_value": int(min(profile)) if profile else 0,
        "max_profile_value": int(max(profile)) if profile else 0,
        "adjacent_roughness": int(adjacent_roughness),
        "fourier_flatness_proxy": int(balance_score_scaled + adjacent_roughness * length),
    }


def random_pair(v, sizes):
    universe = list(range(v))
    return [set(random.sample(universe, int(size))) for size in sizes]


def pair_canonical_hash(v, sizes, blocks):
    padded_ks = tuple(int(x) for x in list(sizes) + [0, 0])
    padded_blocks = [set(blocks[0]), set(blocks[1]), set(), set()]
    return canonical_hash(padded_blocks, padded_ks, v)


def target_profile_metrics(profile, target_profile):
    if target_profile is None:
        return None
    if len(profile) != len(target_profile):
        raise ValueError("profile length {} != target length {}".format(len(profile), len(target_profile)))
    score = 0
    l1_error = 0
    max_abs_error = 0
    nonzero_defect_count = 0
    for idx, value in enumerate(profile):
        err = int(value) - int(target_profile[idx])
        abs_err = abs(err)
        score += err * err
        l1_error += abs_err
        max_abs_error = max(max_abs_error, abs_err)
        if err != 0:
            nonzero_defect_count += 1
    return {
        "score": int(score),
        "l1_error": int(l1_error),
        "max_abs_error": int(max_abs_error),
        "nonzero_defect_count": int(nonzero_defect_count),
    }


def make_entry(
    v,
    sizes,
    blocks,
    sample_index,
    seed,
    include_pair_canonical_hash=False,
    target_profile=None,
):
    profile, _per_block = pair_profile(v, blocks)
    stats = profile_stats(profile)
    entry = {
        "sample_index": int(sample_index),
        "seed": int(seed),
        "v": int(v),
        "sizes": [int(x) for x in sizes],
        "blocks": json_blocks(blocks),
        "profile": profile,
        "profile_hash": profile_hash(v, sizes, profile),
        "pair_canonical_hash": "",
        "profile_stats": stats,
    }
    metrics = target_profile_metrics(profile, target_profile)
    if metrics is not None:
        entry["target_profile_metrics"] = metrics
    if include_pair_canonical_hash:
        entry["pair_canonical_hash"] = pair_canonical_hash(v, sizes, blocks)
    return entry


def cap_stats(metrics, args):
    if metrics is None:
        return {"within_target_cap": False, "target_cap_violation": 0}
    violation = 0
    if args.target_score_cap and args.target_score_cap > 0:
        violation += max(0, int(metrics["score"]) - int(args.target_score_cap))
    if args.target_l1_cap and args.target_l1_cap > 0:
        violation += max(0, int(metrics["l1_error"]) - int(args.target_l1_cap))
    if args.target_maxabs_cap and args.target_maxabs_cap > 0:
        violation += 100 * max(0, int(metrics["max_abs_error"]) - int(args.target_maxabs_cap))
    return {
        "within_target_cap": bool(violation == 0),
        "target_cap_violation": int(violation),
    }


def entry_rank(entry, args):
    stats = entry["profile_stats"]
    flatness_rank = (
        int(stats["fourier_flatness_proxy"]),
        int(stats["profile_balance_score"]),
        int(stats["profile_l1_to_mean"]),
        int(stats["max_profile_spike_scaled"]),
        int(entry["sample_index"]),
    )
    metrics = entry.get("target_profile_metrics")
    if args.rank_mode == "flatness" or metrics is None:
        return flatness_rank
    complement_rank = (
        int(metrics["score"]),
        int(metrics["l1_error"]),
        int(metrics["max_abs_error"]),
        int(metrics["nonzero_defect_count"]),
    )
    if args.rank_mode == "complement_l2":
        return complement_rank + flatness_rank
    if args.rank_mode == "complement_l1":
        return (
            int(metrics["l1_error"]),
            int(metrics["score"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_defect_count"]),
        ) + flatness_rank
    if args.rank_mode == "complement_balanced":
        return (
            int(metrics["score"]),
            int(metrics["l1_error"]),
            int(metrics["nonzero_defect_count"]),
            int(metrics["max_abs_error"]),
            int(stats["fourier_flatness_proxy"]),
        )
    if args.rank_mode == "capped_complement":
        caps = cap_stats(metrics, args)
        return (
            0 if caps["within_target_cap"] else 1,
            int(caps["target_cap_violation"]),
            int(metrics["score"]),
            int(metrics["l1_error"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_defect_count"]),
        ) + flatness_rank
    raise ValueError("unknown rank mode {}".format(args.rank_mode))


def _entry_at(data, index):
    if "entries" in data:
        return data["entries"][int(index)]
    if "matches" in data:
        return data["matches"][int(index)]
    raise ValueError("target JSON must contain entries or matches")


def _profile_from_entry(entry, key, lam):
    if key == "profile":
        return [int(x) for x in entry["profile"]]
    if key in ("left", "right", "left_residual_target"):
        return [int(x) for x in entry["profiles"][key]]
    if key == "right_residual_target":
        if lam is None:
            raise ValueError("--target-lam is required for right_residual_target")
        right = [int(x) for x in entry["profiles"]["right"]]
        return [int(lam) - x for x in right]
    raise ValueError("unsupported target key {}".format(key))


def load_target_profile(args, v):
    if not args.target_profile:
        return None, None
    with open(args.target_profile) as f:
        data = json.load(f)
    entry = _entry_at(data, args.target_entry_index)
    key = args.target_key
    if key == "auto":
        if "profile" in entry:
            key = "profile"
        elif "profiles" in entry and "left_residual_target" in entry["profiles"]:
            key = "left_residual_target"
        else:
            raise ValueError("could not infer target profile key")
    profile = _profile_from_entry(entry, key, args.target_lam)
    if len(profile) != int(v) - 1:
        raise ValueError("target profile has length {}, expected {}".format(len(profile), int(v) - 1))
    info = {
        "path": args.target_profile,
        "entry_index": int(args.target_entry_index),
        "key": key,
        "lambda": None if args.target_lam is None else int(args.target_lam),
    }
    if "path" in entry:
        info["source_path"] = entry["path"]
    if "metrics" in entry:
        info["source_metrics"] = entry["metrics"]
    return profile, info


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate random two-block pair autocorrelation profiles over Z_v."
    )
    parser.add_argument("--v", type=int, default=167)
    parser.add_argument("--sizes", required=True, help="Two comma-separated block sizes, e.g. 73,78.")
    parser.add_argument("--samples", type=int, default=10000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--out", required=True)
    parser.add_argument(
        "--keep-top",
        type=int,
        default=0,
        help="Keep only the best N profiles by flatness. Default 0 keeps all samples.",
    )
    parser.add_argument(
        "--dedup-profile",
        action="store_true",
        help="Keep only the first occurrence of each exact profile hash.",
    )
    parser.add_argument(
        "--pair-canonical-hash",
        action="store_true",
        help="Compute canonical hashes for generated two-block pairs. This is much slower.",
    )
    parser.add_argument(
        "--rank-mode",
        choices=[
            "flatness",
            "complement_l2",
            "complement_l1",
            "complement_balanced",
            "capped_complement",
        ],
        default="flatness",
        help="How generated pair profiles are ranked and kept.",
    )
    parser.add_argument(
        "--target-profile",
        help="Optional JSON containing a target profile. Supports 22 dataset entries and 23 generator entries.",
    )
    parser.add_argument("--target-entry-index", type=int, default=0)
    parser.add_argument(
        "--target-key",
        choices=["auto", "profile", "left", "right", "left_residual_target", "right_residual_target"],
        default="auto",
    )
    parser.add_argument(
        "--target-lam",
        type=int,
        default=None,
        help="Lambda used when deriving a residual target, e.g. right_residual_target.",
    )
    parser.add_argument("--target-score-cap", type=int, default=0)
    parser.add_argument("--target-l1-cap", type=int, default=0)
    parser.add_argument("--target-maxabs-cap", type=int, default=0)
    return parser.parse_args()


def main():
    args = parse_args()
    tee, _stamp = setup_logging(SCRIPT_NAME)
    try:
        sizes = tuple(int(x) for x in args.sizes.split(",") if x != "")
        if len(sizes) != 2:
            raise ValueError("--sizes must contain exactly two integers")
        if any(size < 0 or size > args.v for size in sizes):
            raise ValueError("sizes must lie between 0 and v")
        target_profile, target_info = load_target_profile(args, args.v)
        if target_profile is None and args.rank_mode != "flatness":
            raise ValueError("--target-profile is required when --rank-mode is not flatness")
        random.seed(int(args.seed))

        entries = []
        seen_profiles = set()
        for sample_index in range(1, int(args.samples) + 1):
            blocks = random_pair(args.v, sizes)
            entry = make_entry(
                args.v,
                sizes,
                blocks,
                sample_index,
                args.seed,
                include_pair_canonical_hash=args.pair_canonical_hash,
                target_profile=target_profile,
            )
            if "target_profile_metrics" in entry:
                entry.update(cap_stats(entry["target_profile_metrics"], args))
            if args.dedup_profile:
                if entry["profile_hash"] in seen_profiles:
                    continue
                seen_profiles.add(entry["profile_hash"])
            entries.append(entry)
            if args.keep_top and len(entries) > int(args.keep_top) * 2:
                entries.sort(key=lambda item: entry_rank(item, args))
                entries = entries[: int(args.keep_top)]
            if sample_index % 5000 == 0:
                best = min(entries, key=lambda item: entry_rank(item, args))
                target_text = ""
                if "target_profile_metrics" in best:
                    target_text = " target_metrics={}".format(best["target_profile_metrics"])
                print(
                    "sample={} stored={} best_flatness={} best_l1_to_mean={}{}".format(
                        sample_index,
                        len(entries),
                        best["profile_stats"]["fourier_flatness_proxy"],
                        best["profile_stats"]["profile_l1_to_mean"],
                        target_text,
                    )
                )
                sys.stdout.flush()

        entries.sort(key=lambda item: entry_rank(item, args))
        if args.keep_top:
            entries = entries[: int(args.keep_top)]
        payload = {
            "script": SCRIPT_NAME,
            "v": int(args.v),
            "sizes": [int(x) for x in sizes],
            "samples_requested": int(args.samples),
            "seed": int(args.seed),
            "dedup_profile": bool(args.dedup_profile),
            "pair_canonical_hash": bool(args.pair_canonical_hash),
            "rank_mode": args.rank_mode,
            "target_profile_info": target_info,
            "target_caps": {
                "target_score_cap": int(args.target_score_cap),
                "target_l1_cap": int(args.target_l1_cap),
                "target_maxabs_cap": int(args.target_maxabs_cap),
            },
            "keep_top": int(args.keep_top),
            "stored_entries": int(len(entries)),
            "rank_description": args.rank_mode,
            "entries": entries,
        }
        write_json(args.out, payload)
        print("WROTE:", args.out)
        print("stored_entries={}".format(len(entries)))
        if entries:
            print("best_profile_stats:", entries[0]["profile_stats"])
            if "target_profile_metrics" in entries[0]:
                print("best_target_profile_metrics:", entries[0]["target_profile_metrics"])
    finally:
        tee.close()


if __name__ == "__main__":
    main()
