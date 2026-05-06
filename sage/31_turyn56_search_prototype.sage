from sage.all import *

import argparse
import json
import math
import os
import random
import time

from sds_repair_utils import setup_logging, write_json


SCRIPT_NAME = "31_turyn56_search_prototype"


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


def hall_value(seq, theta):
    real = 0.0
    imag = 0.0
    for i, value in enumerate(seq):
        angle = float(i) * float(theta)
        real += float(value) * math.cos(angle)
        imag += float(value) * math.sin(angle)
    return float(real * real + imag * imag)


def hall_grid_values(seq, grid):
    values = []
    for j in range(1, int(grid) + 1):
        theta = math.pi * float(j) / float(grid)
        values.append(hall_value(seq, theta))
    return values


def endpoint_signature(seq, width):
    width = int(width)
    return tuple(int(x) for x in (list(seq[:width]) + list(seq[-width:])))


def sample_for_sum_tuple(n, tuple_value, samples, grid, endpoint_width):
    x, y, z, w = [int(v) for v in tuple_value]
    bound = float(hall_single_bound(n))
    stats = {
        "tuple": [x, y, z, w],
        "samples": int(samples),
        "z_pass": 0,
        "w_pass": 0,
        "zw_pair_pass": 0,
        "best_zw_max": None,
        "best_z_max": None,
        "best_w_max": None,
        "endpoint_signature_count": 0,
        "examples": [],
    }
    signatures = set()
    for _ in range(int(samples)):
        Z = random_pm1_with_sum(n, z)
        W = random_pm1_with_sum(n - 1, w)
        z_values = hall_grid_values(Z, grid)
        w_values = hall_grid_values(W, grid)
        z_max = max(z_values)
        w_max = max(w_values)
        zw_max = max(float(a) + float(b) for a, b in zip(z_values, w_values))
        if z_max <= bound:
            stats["z_pass"] += 1
        if w_max <= bound:
            stats["w_pass"] += 1
        if zw_max <= bound:
            stats["zw_pair_pass"] += 1
            signatures.add((endpoint_signature(Z, endpoint_width), endpoint_signature(W, endpoint_width)))
            if len(stats["examples"]) < 5:
                stats["examples"].append(
                    {
                        "Z": [int(v) for v in Z],
                        "W": [int(v) for v in W],
                        "z_max": float(z_max),
                        "w_max": float(w_max),
                        "zw_max": float(zw_max),
                    }
                )
        if stats["best_zw_max"] is None or zw_max < stats["best_zw_max"]:
            stats["best_zw_max"] = float(zw_max)
            stats["best_z_max"] = float(z_max)
            stats["best_w_max"] = float(w_max)
    stats["endpoint_signature_count"] = int(len(signatures))
    for key in ["z_pass", "w_pass", "zw_pair_pass"]:
        stats[key + "_rate"] = float(stats[key]) / float(max(1, int(samples)))
    return stats


def tuple_priority(row):
    x, y, z, w = row
    # Prefer small absolute sums first; they usually have more entropy.
    return (abs(z) + abs(w), abs(x) + abs(y), abs(z), abs(w), row)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Prototype diagnostics for extending the 428 Turyn search route to n=56."
    )
    parser.add_argument("--n", type=int, default=56)
    parser.add_argument("--samples", type=int, default=1000)
    parser.add_argument("--grid", type=int, default=100)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--max-tuples", type=int, default=12)
    parser.add_argument("--endpoint-width", type=int, default=6)
    parser.add_argument("--include-n36-comparison", action="store_true")
    parser.add_argument("--out", default="")
    return parser.parse_args()


def analyze_n(n, args):
    candidates = sum_candidates(n)
    selected = sorted(candidates, key=tuple_priority)[: int(args.max_tuples)]
    rows = []
    for row in selected:
        print("Sampling n={} tuple={} samples={}".format(n, row, args.samples))
        rows.append(sample_for_sum_tuple(n, row, args.samples, args.grid, args.endpoint_width))
    return {
        "n": int(n),
        "target_order": int(4 * (3 * int(n) - 1)),
        "sum_identity_rhs": turyn_rhs(n),
        "hall_single_bound": hall_single_bound(n),
        "sum_candidates_count": len(candidates),
        "selected_sum_tuples": [list(row) for row in selected],
        "sample_rows": rows,
    }


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        random.seed(int(args.seed))
        payload = {
            "script": SCRIPT_NAME,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "seed": int(args.seed),
            "samples_per_tuple": int(args.samples),
            "grid": int(args.grid),
            "endpoint_width": int(args.endpoint_width),
            "classification": "diagnostic",
            "notes": [
                "This is not a proof of nonexistence and not a Hadamard construction.",
                "It estimates where the 428 Turyn search pipeline begins to become hard for n=56.",
            ],
        }
        payload["primary"] = analyze_n(args.n, args)
        if args.include_n36_comparison and int(args.n) != 36:
            payload["comparison_n36"] = analyze_n(36, args)

        out = args.out or os.path.join(
            "outputs/turyn",
            "{}_n{}_samples{}.json".format(stamp, int(args.n), int(args.samples)),
        )
        write_json(out, payload)
        print("WROTE:", out)
        print("Summary:")
        for label in ["primary", "comparison_n36"]:
            if label not in payload:
                continue
            item = payload[label]
            best = sorted(item["sample_rows"], key=lambda r: (r["best_zw_max"], -r["zw_pair_pass"]))[:3]
            print(
                "{} n={} order={} sum_tuples={} bound={}".format(
                    label,
                    item["n"],
                    item["target_order"],
                    item["sum_candidates_count"],
                    item["hall_single_bound"],
                )
            )
            for row in best:
                print(
                    "  tuple={} zw_pass={}/{} rate={:.4f} best_zw_max={:.3f}".format(
                        row["tuple"],
                        row["zw_pair_pass"],
                        row["samples"],
                        row["zw_pair_pass_rate"],
                        row["best_zw_max"],
                    )
                )
    finally:
        tee.close()


if __name__ == "__main__":
    main()
