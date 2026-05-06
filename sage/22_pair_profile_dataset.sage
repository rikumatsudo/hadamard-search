from sage.all import *

import argparse
import glob
import hashlib
import json
import os
import sys

from sds_repair_utils import (
    canonical_hash,
    error_histogram,
    load_candidate,
    metrics_from_counts,
    setup_logging,
    total_diff_counts,
    write_json,
)


SCRIPT_NAME = "22_pair_profile_dataset"


def parse_split(text):
    try:
        left_text, right_text = text.split(":")
        left = tuple(int(x) for x in left_text.split(",") if x != "")
        right = tuple(int(x) for x in right_text.split(",") if x != "")
    except ValueError:
        raise argparse.ArgumentTypeError("split must look like 0,1:2,3")
    indices = list(left) + list(right)
    if sorted(indices) != [0, 1, 2, 3]:
        raise argparse.ArgumentTypeError("split must partition block indices 0,1,2,3")
    if len(left) != 2 or len(right) != 2:
        raise argparse.ArgumentTypeError("this prototype expects two blocks per side")
    return left, right


def nonzero_profile(counts):
    return [int(counts[d]) for d in range(1, len(counts))]


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


def all_counts(v, blocks):
    total = [0] * v
    per_block = []
    for block in blocks:
        counts = diff_counts_from_bits(v, block_to_bits(block))
        per_block.append(counts)
        for d in range(v):
            total[d] += counts[d]
    return total, per_block


def pair_profile(v, per_block_counts, pair):
    profile = [0] * (v - 1)
    for idx in pair:
        counts = per_block_counts[int(idx)]
        for d in range(1, v):
            profile[d - 1] += int(counts[d])
    return profile


def profile_stats(profile):
    total = sum(profile)
    length = len(profile)
    numerator = total
    denominator = length
    balance_score_scaled = 0
    l1_scaled = 0
    max_scaled_deviation = 0
    for value in profile:
        scaled = int(value) * denominator - numerator
        balance_score_scaled += scaled * scaled
        abs_scaled = abs(scaled)
        l1_scaled += abs_scaled
        max_scaled_deviation = max(max_scaled_deviation, abs_scaled)
    return {
        "total_ordered_differences": int(total),
        "mean_numerator": int(numerator),
        "mean_denominator": int(denominator),
        "balance_score_scaled": int(balance_score_scaled),
        "l1_to_mean_scaled": int(l1_scaled),
        "max_scaled_deviation": int(max_scaled_deviation),
        "min_profile_value": int(min(profile)) if profile else 0,
        "max_profile_value": int(max(profile)) if profile else 0,
    }


def profile_hash(v, sizes, profile):
    payload = {
        "v": int(v),
        "sizes": [int(x) for x in sizes],
        "profile": [int(x) for x in profile],
    }
    text = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return str(hashlib.sha256(text.encode("utf-8")).hexdigest())


def defect_vector(counts, lam):
    return [int(counts[d] - lam) for d in range(1, len(counts))]


def classify_source(path, data):
    method = str(data.get("search_method", "")).lower()
    lowered = path.lower()
    if "guided" in method or "guided" in lowered:
        return "guided"
    if "ilp" in method or "ilp" in lowered:
        return "ilp"
    if "beam" in method or "beam" in lowered:
        return "beam"
    if "steepest" in method or "steepest" in lowered:
        return "steepest"
    if "pair" in method or "pair" in lowered:
        return "pair_profile"
    return "unknown"


def candidate_entry(path, data, v, ks, lam, blocks, split):
    counts, per_block_counts = all_counts(v, blocks)

    metrics = metrics_from_counts(counts, lam)
    left_pair, right_pair = split
    left_profile = pair_profile(v, per_block_counts, left_pair)
    right_profile = pair_profile(v, per_block_counts, right_pair)
    residual_left = [int(lam - value) for value in left_profile]
    match_error = [int(right_profile[i] - residual_left[i]) for i in range(v - 1)]
    pair_sum = [int(left_profile[i] + right_profile[i]) for i in range(v - 1)]

    source_metrics = (
        int(data.get("score", metrics[0])),
        int(data.get("l1_error", metrics[1])),
        int(data.get("max_abs_error", metrics[2])),
        int(data.get("nonzero_defect_count", metrics[3])),
    )

    return {
        "path": path,
        "source_type": classify_source(path, data),
        "canonical_hash": str(data.get("canonical_hash") or canonical_hash(blocks, ks, v)),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "metrics": {
            "score": int(metrics[0]),
            "l1_error": int(metrics[1]),
            "max_abs_error": int(metrics[2]),
            "nonzero_defect_count": int(metrics[3]),
        },
        "stored_metrics": {
            "score": int(source_metrics[0]),
            "l1_error": int(source_metrics[1]),
            "max_abs_error": int(source_metrics[2]),
            "nonzero_defect_count": int(source_metrics[3]),
        },
        "metrics_match": bool(metrics == source_metrics),
        "split": {
            "left": [int(i) for i in left_pair],
            "right": [int(i) for i in right_pair],
            "left_sizes": [int(ks[i]) for i in left_pair],
            "right_sizes": [int(ks[i]) for i in right_pair],
        },
        "profiles": {
            "left": left_profile,
            "right": right_profile,
            "left_residual_target": residual_left,
            "pair_sum": pair_sum,
            "match_error": match_error,
        },
        "profile_stats": {
            "left": profile_stats(left_profile),
            "right": profile_stats(right_profile),
        },
        "defect_vector": defect_vector(counts, lam),
        "error_histogram": error_histogram(counts, lam),
    }


def pareto_key(entry):
    metrics = entry["metrics"]
    return (
        int(metrics["score"]),
        int(metrics["l1_error"]),
        int(metrics["max_abs_error"]),
        int(metrics["nonzero_defect_count"]),
    )


def update_best(best, key, entry):
    current = best.get(key)
    if current is None or pareto_key(entry) < pareto_key(current):
        best[key] = entry


def parse_args():
    parser = argparse.ArgumentParser(
        description="Extract pair autocorrelation profiles from existing v=167 SDS near-hit JSON files."
    )
    parser.add_argument("--ks", required=True, help="Comma-separated block sizes, e.g. 73,78,79,81.")
    parser.add_argument("--lam", type=int, required=True, help="Target SDS lambda.")
    parser.add_argument("--split", type=parse_split, default=parse_split("0,1:2,3"))
    parser.add_argument(
        "--near-hit-glob",
        required=True,
        help="Glob for near-hit JSON files. Quote this argument in the shell.",
    )
    parser.add_argument("--out", required=True, help="Output JSON path.")
    parser.add_argument("--max-files", type=int, default=0, help="Optional file limit for smoke tests.")
    parser.add_argument("--top-k", type=int, default=200, help="Number of best entries to keep in summary.")
    return parser.parse_args()


def main():
    args = parse_args()
    tee, _stamp = setup_logging(SCRIPT_NAME)
    try:
        ks = tuple(int(x) for x in args.ks.split(",") if x != "")
        if len(ks) != 4:
            raise ValueError("--ks must contain four integers")

        paths = sorted(glob.glob(args.near_hit_glob, recursive=True))
        if args.max_files and args.max_files > 0:
            paths = paths[: args.max_files]

        entries = []
        skipped = []
        best_by_source = {}
        best_by_hash = {}
        for idx, path in enumerate(paths, 1):
            try:
                data, v, _n, file_ks, lam, blocks = load_candidate(path)
            except Exception as exc:
                skipped.append({"path": path, "reason": str(exc)[:200]})
                continue
            if tuple(file_ks) != ks or int(lam) != int(args.lam):
                continue
            entry = candidate_entry(path, data, v, file_ks, lam, blocks, args.split)
            entries.append(entry)
            update_best(best_by_source, entry["source_type"], entry)
            update_best(best_by_hash, entry["canonical_hash"], entry)
            if idx % 1000 == 0:
                print("processed={} valid={}".format(idx, len(entries)))
                sys.stdout.flush()

        entries.sort(key=pareto_key)
        summary_entries = entries[: int(args.top_k)]
        unique_hashes = len(set(entry["canonical_hash"] for entry in entries))
        source_counts = {}
        for entry in entries:
            source_counts[entry["source_type"]] = source_counts.get(entry["source_type"], 0) + 1

        payload = {
            "script": SCRIPT_NAME,
            "ks": [int(k) for k in ks],
            "lambda": int(args.lam),
            "split": {
                "left": [int(i) for i in args.split[0]],
                "right": [int(i) for i in args.split[1]],
            },
            "near_hit_glob": args.near_hit_glob,
            "total_paths": int(len(paths)),
            "valid_entries": int(len(entries)),
            "unique_canonical_hashes": int(unique_hashes),
            "skipped_count": int(len(skipped)),
            "skipped_examples": skipped[:30],
            "counts_by_source_type": source_counts,
            "best_by_source_type": {
                key: {
                    "path": value["path"],
                    "metrics": value["metrics"],
                    "canonical_hash": value["canonical_hash"],
                }
                for key, value in sorted(best_by_source.items())
            },
            "best_by_canonical_hash_count": int(len(best_by_hash)),
            "entries": summary_entries,
        }
        write_json(args.out, payload)
        print("WROTE:", args.out)
        print(
            "valid_entries={} unique_canonical_hashes={} skipped={}".format(
                len(entries), unique_hashes, len(skipped)
            )
        )
        if entries:
            print("best:", entries[0]["metrics"], entries[0]["path"])
    finally:
        tee.close()


if __name__ == "__main__":
    main()
