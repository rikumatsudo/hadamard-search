from sage.all import *

import argparse
import collections
import json
import math
import os
import random
import time

from sds_repair_utils import setup_logging, write_json


SCRIPT_NAME = "32_turyn_endpoint_bucket_generator"


def turyn_rhs(n):
    return int(6 * int(n) - 2)


def hall_single_bound(n):
    return int(3 * int(n) - 1)


def sum_candidates(n):
    n = int(n)
    out = []
    x_values = range(-n, n + 1, 2)
    y_values = range(-n, n + 1, 2)
    z_values = range(-n, n + 1, 2)
    w_len = n - 1
    w_values = range(-w_len, w_len + 1, 2)
    target = turyn_rhs(n)
    for x in x_values:
        for y in y_values:
            for z in z_values:
                partial = x * x + y * y + 2 * z * z
                if partial > target:
                    continue
                for w in w_values:
                    if partial + 2 * w * w == target:
                        out.append((int(x), int(y), int(z), int(w)))
    return out


def tuple_priority(row):
    x, y, z, w = row
    return (abs(z) + abs(w), abs(x) + abs(y), abs(z), abs(w), row)


def random_pm1_with_sum(length, target_sum):
    length = int(length)
    target_sum = int(target_sum)
    if (length + target_sum) % 2 != 0:
        raise ValueError("length and sum parity mismatch")
    plus_count = (length + target_sum) // 2
    if plus_count < 0 or plus_count > length:
        raise ValueError("sum {} impossible for length {}".format(target_sum, length))
    values = [1] * plus_count + [-1] * (length - plus_count)
    random.shuffle(values)
    return values


def hall_values(seq, grid):
    values = []
    for j in range(1, int(grid) + 1):
        theta = math.pi * float(j) / float(grid)
        real = 0.0
        imag = 0.0
        for i, value in enumerate(seq):
            angle = float(i) * theta
            real += float(value) * math.cos(angle)
            imag += float(value) * math.sin(angle)
        values.append(float(real * real + imag * imag))
    return values


def endpoint_signature(seq, width):
    width = int(width)
    return tuple(int(x) for x in (list(seq[:width]) + list(seq[-width:])))


def compact_signature(sig):
    return "".join("+" if int(x) > 0 else "-" for x in sig)


def top_counter(counter, limit=10):
    rows = []
    for key, count in counter.most_common(int(limit)):
        rows.append({"signature": compact_signature(key), "count": int(count)})
    return rows


def sample_pass_sequences(length, target_sum, samples, grid, bound, endpoint_width, max_keep, label):
    bucket_counts = collections.Counter()
    kept = []
    pass_count = 0
    best_max = None
    best_seq = None
    for _ in range(int(samples)):
        seq = random_pm1_with_sum(length, target_sum)
        h = hall_values(seq, grid)
        h_max = max(h)
        if best_max is None or h_max < best_max:
            best_max = float(h_max)
            best_seq = list(seq)
        if h_max <= float(bound):
            pass_count += 1
            sig = endpoint_signature(seq, endpoint_width)
            bucket_counts[sig] += 1
            if len(kept) < int(max_keep):
                kept.append(
                    {
                        "sequence": [int(x) for x in seq],
                        "hall_values": h,
                        "hall_max": float(h_max),
                        "signature": sig,
                    }
                )
    return {
        "label": label,
        "length": int(length),
        "target_sum": int(target_sum),
        "samples": int(samples),
        "pass_count": int(pass_count),
        "pass_rate": float(pass_count) / float(max(1, int(samples))),
        "unique_buckets": int(len(bucket_counts)),
        "top_buckets": top_counter(bucket_counts),
        "best_hall_max": float(best_max) if best_max is not None else None,
        "best_sequence_prefix": [int(x) for x in best_seq[:20]] if best_seq is not None else [],
        "kept": kept,
    }


def compare_pair_buckets(z_data, w_data, bound, max_pair_checks):
    z_rows = z_data["kept"]
    w_rows = w_data["kept"]
    if not z_rows or not w_rows:
        return {
            "pair_checks": 0,
            "pair_pass_count": 0,
            "pair_pass_rate": 0.0,
            "unique_pair_buckets": 0,
            "best_pair_max": None,
            "best_pair": None,
            "top_pair_buckets": [],
        }
    pair_bucket_counts = collections.Counter()
    checks = 0
    pass_count = 0
    best_pair_max = None
    best_pair = None
    for z in z_rows:
        for w in w_rows:
            if checks >= int(max_pair_checks):
                break
            checks += 1
            pair_max = max(float(a) + float(b) for a, b in zip(z["hall_values"], w["hall_values"]))
            if best_pair_max is None or pair_max < best_pair_max:
                best_pair_max = float(pair_max)
                best_pair = {
                    "z_signature": compact_signature(z["signature"]),
                    "w_signature": compact_signature(w["signature"]),
                    "z_hall_max": float(z["hall_max"]),
                    "w_hall_max": float(w["hall_max"]),
                    "pair_max": float(pair_max),
                }
            if pair_max <= float(bound):
                pass_count += 1
                pair_bucket_counts[(z["signature"], w["signature"])] += 1
        if checks >= int(max_pair_checks):
            break
    top_pairs = []
    for (z_sig, w_sig), count in pair_bucket_counts.most_common(10):
        top_pairs.append(
            {
                "z_signature": compact_signature(z_sig),
                "w_signature": compact_signature(w_sig),
                "count": int(count),
            }
        )
    return {
        "pair_checks": int(checks),
        "pair_pass_count": int(pass_count),
        "pair_pass_rate": float(pass_count) / float(max(1, checks)),
        "unique_pair_buckets": int(len(pair_bucket_counts)),
        "best_pair_max": float(best_pair_max) if best_pair_max is not None else None,
        "best_pair": best_pair,
        "top_pair_buckets": top_pairs,
    }


def analyze_tuple(n, tuple_value, args):
    _x, _y, z_sum, w_sum = [int(v) for v in tuple_value]
    bound = hall_single_bound(n)
    z_data = sample_pass_sequences(
        n,
        z_sum,
        args.samples,
        args.grid,
        bound,
        args.endpoint_width,
        args.max_keep,
        "Z",
    )
    w_data = sample_pass_sequences(
        n - 1,
        w_sum,
        args.samples,
        args.grid,
        bound,
        args.endpoint_width,
        args.max_keep,
        "W",
    )
    pair_data = compare_pair_buckets(z_data, w_data, bound, args.max_pair_checks)
    # Strip kept full sequences from public JSON summary unless requested.
    z_public = dict(z_data)
    w_public = dict(w_data)
    if not args.keep_sequences:
        z_public.pop("kept", None)
        w_public.pop("kept", None)
    else:
        for item in z_public["kept"]:
            item["signature"] = compact_signature(item["signature"])
            item.pop("hall_values", None)
        for item in w_public["kept"]:
            item["signature"] = compact_signature(item["signature"])
            item.pop("hall_values", None)
    return {
        "tuple": [int(v) for v in tuple_value],
        "bound": int(bound),
        "Z": z_public,
        "W": w_public,
        "pair": pair_data,
    }


def analyze_n(n, args):
    candidates = sum_candidates(n)
    if args.tuple:
        selected = []
        for text in args.tuple.split(";"):
            if not text.strip():
                continue
            row = tuple(int(x) for x in text.split(","))
            if len(row) != 4:
                raise ValueError("--tuple entries must have four comma-separated integers")
            selected.append(row)
    else:
        selected = sorted(candidates, key=tuple_priority)[: int(args.max_tuples)]
    rows = []
    for row in selected:
        print("Endpoint bucket sampling n={} tuple={} samples={}".format(n, row, args.samples))
        rows.append(analyze_tuple(n, row, args))
    return {
        "n": int(n),
        "target_order": int(4 * (3 * int(n) - 1)),
        "sum_identity_rhs": int(turyn_rhs(n)),
        "hall_bound": int(hall_single_bound(n)),
        "sum_candidates_count": int(len(candidates)),
        "selected_tuples": [list(row) for row in selected],
        "rows": rows,
    }


def write_markdown(path, payload):
    lines = []
    lines.append("# Turyn Endpoint Bucket Diagnostic")
    lines.append("")
    lines.append("This is a diagnostic only. It is not a Hadamard construction.")
    lines.append("")
    for section in ["primary", "comparison_n36"]:
        if section not in payload:
            continue
        data = payload[section]
        lines.append("## {} n={}".format(section, data["n"]))
        lines.append("")
        lines.append("- target order: {}".format(data["target_order"]))
        lines.append("- sum candidates: {}".format(data["sum_candidates_count"]))
        lines.append("- Hall bound: {}".format(data["hall_bound"]))
        lines.append("")
        lines.append("| tuple | Z pass | W pass | pair pass | Z buckets | W buckets | pair buckets | best pair max |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
        for row in data["rows"]:
            pair = row["pair"]
            lines.append(
                "| {} | {}/{} | {}/{} | {}/{} | {} | {} | {} | {} |".format(
                    row["tuple"],
                    row["Z"]["pass_count"],
                    row["Z"]["samples"],
                    row["W"]["pass_count"],
                    row["W"]["samples"],
                    pair["pair_pass_count"],
                    pair["pair_checks"],
                    row["Z"]["unique_buckets"],
                    row["W"]["unique_buckets"],
                    pair["unique_pair_buckets"],
                    "{:.3f}".format(pair["best_pair_max"]) if pair["best_pair_max"] is not None else "NA",
                )
            )
        lines.append("")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate Z/W Hall-pruned endpoint buckets for the Turyn 428-to-668 route."
    )
    parser.add_argument("--n", type=int, default=56)
    parser.add_argument("--samples", type=int, default=2000)
    parser.add_argument("--grid", type=int, default=100)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--max-tuples", type=int, default=8)
    parser.add_argument("--tuple", default="", help="Optional semicolon-separated x,y,z,w tuples.")
    parser.add_argument("--endpoint-width", type=int, default=6)
    parser.add_argument("--max-keep", type=int, default=1000)
    parser.add_argument("--max-pair-checks", type=int, default=200000)
    parser.add_argument("--include-n36-comparison", action="store_true")
    parser.add_argument("--keep-sequences", action="store_true")
    parser.add_argument("--out", default="")
    parser.add_argument("--summary-md", default="")
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        random.seed(int(args.seed))
        payload = {
            "script": SCRIPT_NAME,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "seed": int(args.seed),
            "samples": int(args.samples),
            "grid": int(args.grid),
            "endpoint_width": int(args.endpoint_width),
            "max_keep": int(args.max_keep),
            "max_pair_checks": int(args.max_pair_checks),
            "classification": "diagnostic",
            "notes": [
                "Z/W endpoint buckets are a pruning diagnostic for the Turyn route.",
                "A bucket or pair pass is not a Hadamard construction.",
            ],
        }
        payload["primary"] = analyze_n(args.n, args)
        if args.include_n36_comparison and int(args.n) != 36:
            payload["comparison_n36"] = analyze_n(36, args)
        out = args.out or os.path.join(
            "outputs/turyn",
            "{}_endpoint_buckets_n{}_samples{}.json".format(stamp, int(args.n), int(args.samples)),
        )
        write_json(out, payload)
        md = args.summary_md or os.path.splitext(out)[0] + ".md"
        write_markdown(md, payload)
        print("WROTE:", out)
        print("WROTE:", md)
        for section in ["primary", "comparison_n36"]:
            if section not in payload:
                continue
            data = payload[section]
            best = sorted(data["rows"], key=lambda r: (r["pair"]["best_pair_max"] if r["pair"]["best_pair_max"] is not None else 10**9, -r["pair"]["pair_pass_count"]))[:3]
            print("{} n={} order={} sum_candidates={} bound={}".format(section, data["n"], data["target_order"], data["sum_candidates_count"], data["hall_bound"]))
            for row in best:
                print(
                    "  tuple={} Zpass={}/{} Wpass={}/{} pair={}/{} best_pair={}".format(
                        row["tuple"],
                        row["Z"]["pass_count"],
                        row["Z"]["samples"],
                        row["W"]["pass_count"],
                        row["W"]["samples"],
                        row["pair"]["pair_pass_count"],
                        row["pair"]["pair_checks"],
                        "{:.3f}".format(row["pair"]["best_pair_max"]) if row["pair"]["best_pair_max"] is not None else "NA",
                    )
                )
    finally:
        tee.close()


if __name__ == "__main__":
    main()
