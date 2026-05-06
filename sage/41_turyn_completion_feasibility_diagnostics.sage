from sage.all import *

import argparse
import cmath
import json
import math
import os
import statistics
import time

from sds_repair_utils import setup_logging, write_json


SCRIPT_NAME = "41_turyn_completion_feasibility_diagnostics"


def parse_tuple(text):
    parts = [int(x) for x in text.split(",")]
    if len(parts) != 4:
        raise ValueError("--tuple must be x,y,z,w")
    return tuple(parts)


def autocorrelation(seq, shift):
    shift = int(shift)
    if shift <= 0:
        return int(sum(int(x) * int(x) for x in seq))
    if shift >= len(seq):
        return 0
    return int(sum(int(seq[i]) * int(seq[i + shift]) for i in range(len(seq) - shift)))


def autocorrelation_vector(seq, limit):
    return [autocorrelation(seq, s) for s in range(int(limit))]


def fixed_zw_vector(Z, W, n):
    return [2 * autocorrelation(Z, s) + 2 * autocorrelation(W, s) for s in range(int(n))]


def xy_defects(X, Y, fixed):
    n = len(X)
    return [int(autocorrelation(X, s) + autocorrelation(Y, s) + fixed[s]) for s in range(1, n)]


def metrics_from_vector(values):
    values = [int(x) for x in values]
    return {
        "score": int(sum(x * x for x in values)),
        "l1_error": int(sum(abs(x) for x in values)),
        "max_abs_error": int(max(abs(x) for x in values)) if values else 0,
        "nonzero_count": int(sum(1 for x in values if x != 0)),
    }


def histogram(values):
    out = {}
    for value in values:
        key = str(int(value))
        out[key] = out.get(key, 0) + 1
    return dict(sorted(out.items(), key=lambda item: int(item[0])))


def poly_abs_sq(seq, theta):
    total = 0j
    z = complex(math.cos(theta), math.sin(theta))
    power = 1 + 0j
    for value in seq:
        total += int(value) * power
        power *= z
    magnitude = abs(total)
    return float(magnitude * magnitude)


def sampled_required_profile(Z, W, n, grid, epsilon):
    constant = float(6 * int(n) - 2)
    values = []
    argmin = None
    argmax = None
    for idx in range(int(grid)):
        theta = 2.0 * math.pi * float(idx) / float(grid)
        required = constant - 2.0 * (poly_abs_sq(Z, theta) + poly_abs_sq(W, theta))
        values.append(float(required))
        if argmin is None or required < values[argmin]:
            argmin = idx
        if argmax is None or required > values[argmax]:
            argmax = idx
    mean = sum(values) / float(len(values))
    variance = sum((x - mean) * (x - mean) for x in values) / float(len(values))
    return {
        "grid": int(grid),
        "constant": int(constant),
        "min_required": float(min(values)),
        "min_index": int(argmin),
        "min_theta": float(2.0 * math.pi * float(argmin) / float(grid)),
        "max_required": float(max(values)),
        "max_index": int(argmax),
        "max_theta": float(2.0 * math.pi * float(argmax) / float(grid)),
        "mean_required": float(mean),
        "std_required": float(math.sqrt(variance)),
        "negative_sample_count": int(sum(1 for x in values if x < -float(epsilon))),
        "near_zero_sample_count": int(sum(1 for x in values if abs(x) <= float(epsilon))),
        "small_required_count_1": int(sum(1 for x in values if 0 <= x <= 1.0)),
        "small_required_count_5": int(sum(1 for x in values if 0 <= x <= 5.0)),
        "small_required_count_10": int(sum(1 for x in values if 0 <= x <= 10.0)),
        "sample_values": [float(x) for x in values[: min(32, len(values))]],
    }


def support_possibilities(n, x_sum, y_sum):
    p_sum = int(x_sum) + int(y_sum)
    q_sum = int(x_sum) - int(y_sum)
    out = []
    for p_support in range(int(n) + 1):
        q_support = int(n) - p_support
        if (p_support + p_sum // 2) % 2 != 0:
            continue
        if (q_support + q_sum // 2) % 2 != 0:
            continue
        if p_sum % 2 != 0 or q_sum % 2 != 0:
            continue
        p_plus = (p_support + p_sum // 2) // 2
        p_minus = p_support - p_plus
        q_plus = (q_support + q_sum // 2) // 2
        q_minus = q_support - q_plus
        if min(p_plus, p_minus, q_plus, q_minus) < 0:
            continue
        out.append(
            {
                "P_support": int(p_support),
                "P_positive": int(p_plus),
                "P_negative": int(p_minus),
                "Q_support": int(q_support),
                "Q_positive": int(q_plus),
                "Q_negative": int(q_minus),
            }
        )
    return out


def pq_from_xy(X, Y):
    return [int(x) + int(y) for x, y in zip(X, Y)], [int(x) - int(y) for x, y in zip(X, Y)]


def pq_support_summary(X, Y):
    P, Q = pq_from_xy(X, Y)
    return {
        "P_support": int(sum(1 for x in P if int(x) != 0)),
        "P_positive": int(sum(1 for x in P if int(x) > 0)),
        "P_negative": int(sum(1 for x in P if int(x) < 0)),
        "P_sum": int(sum(P)),
        "Q_support": int(sum(1 for x in Q if int(x) != 0)),
        "Q_positive": int(sum(1 for x in Q if int(x) > 0)),
        "Q_negative": int(sum(1 for x in Q if int(x) < 0)),
        "Q_sum": int(sum(Q)),
    }


def channel_at(P, Q, pos):
    if int(P[pos]) != 0 and int(Q[pos]) == 0:
        return "P", 1 if int(P[pos]) > 0 else -1
    if int(Q[pos]) != 0 and int(P[pos]) == 0:
        return "Q", 1 if int(Q[pos]) > 0 else -1
    raise ValueError("invalid P/Q support at position {}".format(pos))


def shift_pair_profile(P, Q, shift):
    n = len(P)
    row = {
        "shift": int(shift),
        "total_pairs": int(max(0, n - int(shift))),
        "same_channel_pairs": 0,
        "cross_channel_silent_pairs": 0,
        "same_positive_pairs": 0,
        "same_negative_pairs": 0,
    }
    for i in range(0, n - int(shift)):
        j = i + int(shift)
        ci, si = channel_at(P, Q, i)
        cj, sj = channel_at(P, Q, j)
        if ci != cj:
            row["cross_channel_silent_pairs"] += 1
            continue
        row["same_channel_pairs"] += 1
        if si * sj > 0:
            row["same_positive_pairs"] += 1
        else:
            row["same_negative_pairs"] += 1
    return row


def target_profile(Z, W, n):
    nz = autocorrelation_vector(Z, n)
    nw = autocorrelation_vector(W, n)
    xy_target = [int(-2 * (nz[s] + nw[s])) for s in range(1, int(n))]
    pq_target = [int(2 * x) for x in xy_target]
    return xy_target, pq_target


def target_roughness(values):
    return int(sum((int(values[i + 1]) - int(values[i])) ** 2 for i in range(len(values) - 1)))


def target_feasibility_checks(xy_target, pq_target, n):
    rows = []
    for s, value in enumerate(xy_target, start=1):
        bound = 2 * (int(n) - int(s))
        rows.append(
            {
                "shift": int(s),
                "target": int(value),
                "absolute_bound": int(bound),
                "within_absolute_bound": bool(abs(int(value)) <= int(bound)),
                "xy_target_even": bool(int(value) % 2 == 0),
                "pq_target_multiple_of_4": bool(int(pq_target[s - 1]) % 4 == 0),
            }
        )
    return {
        "all_within_absolute_bounds": bool(all(row["within_absolute_bound"] for row in rows)),
        "all_xy_targets_even": bool(all(row["xy_target_even"] for row in rows)),
        "all_pq_targets_multiple_of_4": bool(all(row["pq_target_multiple_of_4"] for row in rows)),
        "rows": rows,
    }


def load_json(path):
    with open(path) as f:
        return json.load(f)


def load_zw(path, args):
    data = load_json(path)
    if "Z" not in data or "W" not in data:
        raise ValueError("{} must contain Z and W".format(path))
    Z = [int(x) for x in data["Z"]]
    W = [int(x) for x in data["W"]]
    if len(Z) != int(args.n) or len(W) != int(args.n) - 1:
        raise ValueError("Z/W lengths incompatible with n={}".format(args.n))
    z_sum = sum(Z)
    w_sum = sum(W)
    if (z_sum, w_sum) != (args.tuple_value[2], args.tuple_value[3]):
        raise ValueError("Z/W sums {} != tuple Z/W {}".format((z_sum, w_sum), args.tuple_value[2:]))
    return data, Z, W


def load_xy_from_data(data, args):
    if "X" not in data or "Y" not in data:
        return None, None
    X = [int(x) for x in data["X"]]
    Y = [int(x) for x in data["Y"]]
    if len(X) != int(args.n) or len(Y) != int(args.n):
        raise ValueError("X/Y lengths incompatible with n={}".format(args.n))
    if (sum(X), sum(Y)) != (args.tuple_value[0], args.tuple_value[1]):
        raise ValueError("X/Y sums {} != tuple X/Y {}".format((sum(X), sum(Y)), args.tuple_value[:2]))
    return X, Y


def xy_diagnostics(X, Y, Z, W, n):
    fixed = fixed_zw_vector(Z, W, n)
    defects = xy_defects(X, Y, fixed)
    metrics = metrics_from_vector(defects)
    P, Q = pq_from_xy(X, Y)
    pq_profiles = []
    for s, defect in enumerate(defects, start=1):
        if int(defect) == 0:
            continue
        row = shift_pair_profile(P, Q, s)
        row["xy_defect"] = int(defect)
        pq_profiles.append(row)
    pq_profiles.sort(key=lambda row: (-abs(row["xy_defect"]), row["shift"]))
    return {
        "metrics": metrics,
        "defect_histogram": histogram(defects),
        "bad_shifts": [[int(s), int(d)] for s, d in enumerate(defects, start=1) if int(d) != 0],
        "pq_support": pq_support_summary(X, Y),
        "worst_pq_shift_profiles": pq_profiles[:20],
    }


def write_markdown(path, payload):
    lines = []
    lines.append("# Turyn Completion Feasibility Diagnostics")
    lines.append("")
    lines.append("This is a reverse/necessary-condition diagnostic. It is not a proof of existence and not a Hadamard 668 construction.")
    lines.append("")
    lines.append("## Input")
    lines.append("")
    lines.append("- Z/W input: `{}`".format(payload["input"]["zw_path"]))
    if payload["input"].get("xy_path"):
        lines.append("- X/Y input: `{}`".format(payload["input"]["xy_path"]))
    lines.append("- n: `{}`".format(payload["n"]))
    lines.append("- tuple: `{}`".format(payload["tuple"]))
    lines.append("")
    lines.append("## Target Profile")
    lines.append("")
    t = payload["target_profile"]
    lines.append("- score: `{}`".format(t["metrics"]["score"]))
    lines.append("- l1: `{}`".format(t["metrics"]["l1_error"]))
    lines.append("- max_abs: `{}`".format(t["metrics"]["max_abs_error"]))
    lines.append("- roughness: `{}`".format(t["roughness"]))
    lines.append("- histogram: `{}`".format(t["histogram"]))
    lines.append("")
    lines.append("## Fourier Required Profile")
    lines.append("")
    f = payload["fourier_required"]
    lines.append("- grid: `{}`".format(f["grid"]))
    lines.append("- min_required: `{:.12f}` at index `{}`".format(f["min_required"], f["min_index"]))
    lines.append("- max_required: `{:.12f}` at index `{}`".format(f["max_required"], f["max_index"]))
    lines.append("- mean_required: `{:.12f}`".format(f["mean_required"]))
    lines.append("- std_required: `{:.12f}`".format(f["std_required"]))
    lines.append("- negative_sample_count: `{}`".format(f["negative_sample_count"]))
    lines.append("- small_required_count_10: `{}`".format(f["small_required_count_10"]))
    lines.append("")
    lines.append("## Basic Necessary Checks")
    lines.append("")
    c = payload["basic_checks"]
    lines.append("- absolute target bounds: `{}`".format(c["all_within_absolute_bounds"]))
    lines.append("- target parity even: `{}`".format(c["all_xy_targets_even"]))
    lines.append("- P/Q target multiple of 4: `{}`".format(c["all_pq_targets_multiple_of_4"]))
    lines.append("- Fourier sampled nonnegative: `{}`".format(payload["fourier_sampled_nonnegative"]))
    lines.append("")
    lines.append("## P/Q Support Possibilities")
    lines.append("")
    pqs = payload["pq_support_possibilities"]
    lines.append("- possible support splits: `{}`".format(len(pqs)))
    if pqs:
        lines.append("- P_support range: `{}`..`{}`".format(pqs[0]["P_support"], pqs[-1]["P_support"]))
    if payload.get("xy_diagnostics"):
        lines.append("")
        lines.append("## Supplied X/Y Near-Hit")
        lines.append("")
        x = payload["xy_diagnostics"]
        lines.append("- score: `{}`".format(x["metrics"]["score"]))
        lines.append("- l1: `{}`".format(x["metrics"]["l1_error"]))
        lines.append("- max_abs: `{}`".format(x["metrics"]["max_abs_error"]))
        lines.append("- nonzero: `{}`".format(x["metrics"]["nonzero_count"]))
        lines.append("- P/Q support: `{}`".format(x["pq_support"]))
        lines.append("")
        lines.append("Worst supplied near-hit shifts:")
        lines.append("")
        lines.append("| shift | defect | same-channel | silent-cross | same + | same - |")
        lines.append("|---:|---:|---:|---:|---:|---:|")
        for row in x["worst_pq_shift_profiles"][:12]:
            lines.append(
                "| {shift} | {xy_defect} | {same_channel_pairs} | {cross_channel_silent_pairs} | {same_positive_pairs} | {same_negative_pairs} |".format(
                    **row
                )
            )
    lines.append("")
    lines.append("## Interpretation")
    lines.append("")
    for item in payload["interpretation"]:
        lines.append("- {}".format(item))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Reverse feasibility diagnostics for fixed Z/W Turyn X/Y completion.")
    parser.add_argument("zw_json")
    parser.add_argument("--xy-json", default="")
    parser.add_argument("--n", type=int, default=56)
    parser.add_argument("--tuple", default="0,-18,-2,1")
    parser.add_argument("--fourier-grid", type=int, default=5000)
    parser.add_argument("--epsilon", type=float, default=1e-6)
    parser.add_argument("--out-prefix", default="outputs/turyn/turyn_completion_feasibility")
    args = parser.parse_args()
    args.tuple_value = parse_tuple(args.tuple)
    return args


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        zw_data, Z, W = load_zw(args.zw_json, args)
        xy_path = args.xy_json or ""
        X = Y = None
        if xy_path:
            xy_data = load_json(xy_path)
            X, Y = load_xy_from_data(xy_data, args)
            if "Z" in xy_data and "W" in xy_data:
                if [int(x) for x in xy_data["Z"]] != Z or [int(x) for x in xy_data["W"]] != W:
                    raise ValueError("--xy-json Z/W does not match positional Z/W input")
        else:
            X, Y = load_xy_from_data(zw_data, args)

        xy_target, pq_target = target_profile(Z, W, args.n)
        target_metrics = metrics_from_vector(xy_target)
        fourier = sampled_required_profile(Z, W, args.n, args.fourier_grid, args.epsilon)
        support_options = support_possibilities(args.n, args.tuple_value[0], args.tuple_value[1])
        basic = target_feasibility_checks(xy_target, pq_target, args.n)

        interpretation = []
        if fourier["negative_sample_count"] == 0:
            interpretation.append("The fixed Z/W passes the sampled Fourier nonnegativity diagnostic on this grid.")
        else:
            interpretation.append("The fixed Z/W has sampled Fourier required-profile negatives; it is not suitable on this diagnostic grid.")
        if fourier["small_required_count_10"] > 0:
            interpretation.append("The required X/Y Fourier energy has near-zero samples, so X/Y completion may be phase-sensitive at those modes.")
        interpretation.append("P/Q support is not fixed by the tuple alone; the support split is an additional hidden basin parameter.")
        interpretation.append("These are necessary-condition and hardness diagnostics only. Exact success still requires Turyn/T-sequence/HH^T verification.")

        payload = {
            "script": SCRIPT_NAME,
            "classification": "turyn_completion_feasibility_diagnostic",
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "input": {
                "zw_path": args.zw_json,
                "xy_path": xy_path or None,
                "zw_classification": zw_data.get("classification"),
                "pair_max": zw_data.get("pair_max"),
                "pair_hall_pass": zw_data.get("pair_hall_pass"),
            },
            "n": int(args.n),
            "target_order": int(4 * (3 * int(args.n) - 1)),
            "tuple": [int(x) for x in args.tuple_value],
            "z_sum": int(sum(Z)),
            "w_sum": int(sum(W)),
            "target_profile": {
                "xy_target": [int(x) for x in xy_target],
                "pq_target": [int(x) for x in pq_target],
                "metrics": target_metrics,
                "histogram": histogram(xy_target),
                "roughness": target_roughness(xy_target),
            },
            "fourier_required": fourier,
            "fourier_sampled_nonnegative": bool(fourier["negative_sample_count"] == 0),
            "basic_checks": basic,
            "pq_support_possibilities": support_options,
            "xy_diagnostics": xy_diagnostics(X, Y, Z, W, args.n) if X is not None and Y is not None else None,
            "interpretation": interpretation,
            "notes": [
                "This diagnostic reasons backward from necessary properties of an exact Turyn completion.",
                "Floating-point Fourier samples are not used as proof or final verification.",
                "No artifact produced here is a success candidate unless exact Turyn, T-sequence, and HH^T checks pass separately.",
            ],
        }

        out_json = "{}_n{}_grid{}.json".format(args.out_prefix, int(args.n), int(args.fourier_grid))
        out_md = "{}_n{}_grid{}.md".format(args.out_prefix, int(args.n), int(args.fourier_grid))
        os.makedirs(os.path.dirname(out_json) or ".", exist_ok=True)
        write_json(out_json, payload)
        write_markdown(out_md, payload)

        print("Z/W input:", args.zw_json)
        if xy_path:
            print("X/Y input:", xy_path)
        print("target metrics:", target_metrics)
        print(
            "fourier required min={:.12f} max={:.12f} negative_samples={}".format(
                fourier["min_required"], fourier["max_required"], fourier["negative_sample_count"]
            )
        )
        print("support split count:", len(support_options))
        if payload["xy_diagnostics"]:
            print("XY metrics:", payload["xy_diagnostics"]["metrics"])
            print("XY P/Q support:", payload["xy_diagnostics"]["pq_support"])
        print("WROTE:", out_json)
        print("WROTE:", out_md)
    finally:
        tee.close()


if __name__ == "__main__":
    main()
