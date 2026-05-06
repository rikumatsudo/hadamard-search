from sage.all import *

import argparse
import json
import os
import sys

from sds_repair_utils import (
    base_payload,
    error_histogram,
    metrics_from_counts,
    save_success,
    setup_logging,
    total_diff_counts,
    validate_params,
    write_json,
)


SCRIPT_NAME = "24_pair_profile_match"


def load_pair_file(path):
    with open(path) as f:
        data = json.load(f)
    missing = [key for key in ["v", "sizes", "entries"] if key not in data]
    if missing:
        raise ValueError("{} missing keys {}".format(path, missing))
    entries = data["entries"]
    for entry in entries:
        if "profile" not in entry or "blocks" not in entry:
            raise ValueError("{} contains an entry without profile/blocks".format(path))
    return data


def pair_flatness(entry):
    stats = entry.get("profile_stats", {})
    return (
        int(stats.get("fourier_flatness_proxy", stats.get("profile_balance_score", 10**30))),
        int(stats.get("profile_balance_score", 10**30)),
        int(stats.get("profile_l1_to_mean", 10**30)),
        int(stats.get("max_profile_spike_scaled", 10**30)),
        int(entry.get("sample_index", 10**30)),
    )


def prune_entries(entries, max_count):
    if max_count is None or int(max_count) <= 0 or len(entries) <= int(max_count):
        return list(entries)
    return sorted(entries, key=pair_flatness)[: int(max_count)]


def pair_match_metrics(left_profile, right_profile, lam):
    score = 0
    l1_error = 0
    max_abs_error = 0
    nonzero_defect_count = 0
    defects = []
    for idx in range(len(left_profile)):
        err = int(left_profile[idx]) + int(right_profile[idx]) - int(lam)
        defects.append(err)
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
    ), defects


def match_rank(match):
    return (
        int(match["metrics"]["score"]),
        int(match["metrics"]["l1_error"]),
        int(match["metrics"]["max_abs_error"]),
        int(match["metrics"]["nonzero_defect_count"]),
        int(match["left_sample_index"]),
        int(match["right_sample_index"]),
    )


def candidate_blocks(left_entry, right_entry):
    blocks = []
    for block in left_entry["blocks"]:
        blocks.append(set(int(x) for x in block))
    for block in right_entry["blocks"]:
        blocks.append(set(int(x) for x in block))
    return blocks


def make_match(v, lam, left_sizes, right_sizes, left_entry, right_entry):
    metrics, defects = pair_match_metrics(
        left_entry["profile"], right_entry["profile"], lam
    )
    return {
        "metrics": {
            "score": int(metrics[0]),
            "l1_error": int(metrics[1]),
            "max_abs_error": int(metrics[2]),
            "nonzero_defect_count": int(metrics[3]),
        },
        "left_sample_index": int(left_entry.get("sample_index", -1)),
        "right_sample_index": int(right_entry.get("sample_index", -1)),
        "left_profile_hash": left_entry.get("profile_hash", ""),
        "right_profile_hash": right_entry.get("profile_hash", ""),
        "left_pair_canonical_hash": left_entry.get("pair_canonical_hash", ""),
        "right_pair_canonical_hash": right_entry.get("pair_canonical_hash", ""),
        "defect_histogram": error_histogram([0] + [int(lam + d) for d in defects], lam),
        "defect_vector": [int(x) for x in defects],
        "left_blocks": left_entry["blocks"],
        "right_blocks": right_entry["blocks"],
        "ks": [int(x) for x in list(left_sizes) + list(right_sizes)],
    }


def insert_top(top, match, top_k):
    top.append(match)
    top.sort(key=match_rank)
    if len(top) > int(top_k):
        del top[int(top_k) :]


def write_candidate_payloads(matches, args, v, ks, lam):
    near_hit_dir = "outputs/candidates/near_hits"
    success_dir = "outputs/candidates"
    saved = []
    for idx, match in enumerate(matches, 1):
        blocks = []
        for block in match["left_blocks"]:
            blocks.append(set(int(x) for x in block))
        for block in match["right_blocks"]:
            blocks.append(set(int(x) for x in block))
        counts = total_diff_counts(v, blocks)
        metrics = metrics_from_counts(counts, lam)
        extra = {
            "left_profile_hash": match.get("left_profile_hash", ""),
            "right_profile_hash": match.get("right_profile_hash", ""),
            "left_sample_index": int(match.get("left_sample_index", -1)),
            "right_sample_index": int(match.get("right_sample_index", -1)),
            "pair_profile_match_rank": int(idx),
            "pair_profile_match_metrics": match["metrics"],
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
                "pair_profile_match",
                idx,
                idx,
                counts,
                extra=extra,
            )
            saved.append({"rank": int(idx), "path": path, "success_candidate": True})
        else:
            payload = base_payload(
                v,
                ks,
                lam,
                blocks,
                metrics,
                args.out,
                "pair_profile_match",
                idx,
                idx,
                counts,
                extra=extra,
            )
            name = "near_hit_v{}_score{}_pair_profile_match_rank{}.json".format(
                v, metrics[0], idx
            )
            path = os.path.join(near_hit_dir, name)
            root, ext = os.path.splitext(path)
            counter = 1
            while os.path.exists(path):
                path = "{}_{}{}".format(root, counter, ext)
                counter += 1
            write_json(path, payload)
            saved.append({"rank": int(idx), "path": path, "success_candidate": False})
    return saved


def parse_args():
    parser = argparse.ArgumentParser(
        description="Match two generated pair profile datasets and emit four-block SDS near-hits."
    )
    parser.add_argument("--left", required=True, help="Left pair profile JSON.")
    parser.add_argument("--right", required=True, help="Right pair profile JSON.")
    parser.add_argument("--lam", type=int, required=True)
    parser.add_argument("--top-k", type=int, default=100)
    parser.add_argument("--out", required=True)
    parser.add_argument(
        "--max-left",
        type=int,
        default=2000,
        help="Use at most this many left entries, chosen by pair flatness. 0 means no pruning.",
    )
    parser.add_argument(
        "--max-right",
        type=int,
        default=2000,
        help="Use at most this many right entries, chosen by pair flatness. 0 means no pruning.",
    )
    parser.add_argument(
        "--save-candidates",
        type=int,
        default=20,
        help="Save this many top matches as candidate/near-hit JSON files.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    tee, _stamp = setup_logging(SCRIPT_NAME)
    try:
        left_data = load_pair_file(args.left)
        right_data = load_pair_file(args.right)
        v = int(left_data["v"])
        if int(right_data["v"]) != v:
            raise ValueError("left and right v differ")
        left_sizes = tuple(int(x) for x in left_data["sizes"])
        right_sizes = tuple(int(x) for x in right_data["sizes"])
        ks = tuple(list(left_sizes) + list(right_sizes))
        validate_params(v, ks, int(args.lam))

        left_entries = prune_entries(left_data["entries"], args.max_left)
        right_entries = prune_entries(right_data["entries"], args.max_right)
        total_comparisons = len(left_entries) * len(right_entries)
        print(
            "left_entries={} right_entries={} comparisons={} top_k={}".format(
                len(left_entries), len(right_entries), total_comparisons, args.top_k
            )
        )
        sys.stdout.flush()

        top = []
        for i, left_entry in enumerate(left_entries, 1):
            left_profile = left_entry["profile"]
            for right_entry in right_entries:
                metrics, defects = pair_match_metrics(
                    left_profile, right_entry["profile"], args.lam
                )
                match = {
                    "metrics": {
                        "score": int(metrics[0]),
                        "l1_error": int(metrics[1]),
                        "max_abs_error": int(metrics[2]),
                        "nonzero_defect_count": int(metrics[3]),
                    },
                    "left_sample_index": int(left_entry.get("sample_index", -1)),
                    "right_sample_index": int(right_entry.get("sample_index", -1)),
                    "left_profile_hash": left_entry.get("profile_hash", ""),
                    "right_profile_hash": right_entry.get("profile_hash", ""),
                    "left_pair_canonical_hash": left_entry.get("pair_canonical_hash", ""),
                    "right_pair_canonical_hash": right_entry.get("pair_canonical_hash", ""),
                    "defect_histogram": error_histogram(
                        [0] + [int(args.lam + d) for d in defects], args.lam
                    ),
                    "defect_vector": [int(x) for x in defects],
                    "left_blocks": left_entry["blocks"],
                    "right_blocks": right_entry["blocks"],
                    "ks": [int(x) for x in ks],
                }
                if len(top) < int(args.top_k) or match_rank(match) < match_rank(top[-1]):
                    insert_top(top, match, args.top_k)
            if i % 100 == 0:
                print(
                    "matched_left={} best={}".format(
                        i, top[0]["metrics"] if top else None
                    )
                )
                sys.stdout.flush()

        saved_candidates = []
        if args.save_candidates and int(args.save_candidates) > 0:
            saved_candidates = write_candidate_payloads(
                top[: int(args.save_candidates)], args, v, ks, int(args.lam)
            )

        payload = {
            "script": SCRIPT_NAME,
            "left": args.left,
            "right": args.right,
            "v": int(v),
            "ks": [int(x) for x in ks],
            "lambda": int(args.lam),
            "left_entries_used": int(len(left_entries)),
            "right_entries_used": int(len(right_entries)),
            "comparisons": int(total_comparisons),
            "top_k": int(args.top_k),
            "matches": top,
            "saved_candidates": saved_candidates,
        }
        write_json(args.out, payload)
        print("WROTE:", args.out)
        if top:
            print("best_match:", top[0]["metrics"])
            print("best_left_sample:", top[0]["left_sample_index"])
            print("best_right_sample:", top[0]["right_sample_index"])
        if any(item.get("success_candidate") for item in saved_candidates):
            print("SUCCESS CANDIDATE GENERATED AND VERIFIED")
        else:
            print("DONE: no verified success candidate from pair matching.")
    finally:
        tee.close()


if __name__ == "__main__":
    main()
