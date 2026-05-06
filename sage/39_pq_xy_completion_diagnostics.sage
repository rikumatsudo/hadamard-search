from sage.all import *

import argparse
import json
import os
import time

from sds_repair_utils import setup_logging, write_json


SCRIPT_NAME = "39_pq_xy_completion_diagnostics"


def autocorrelation(seq, shift):
    shift = int(shift)
    if shift <= 0:
        return int(sum(int(x) * int(x) for x in seq))
    if shift >= len(seq):
        return 0
    return int(sum(int(seq[i]) * int(seq[i + shift]) for i in range(len(seq) - shift)))


def autocorrelation_vector(seq, n=None):
    limit = len(seq) if n is None else int(n)
    return [autocorrelation(seq, s) for s in range(limit)]


def fixed_zw_vector(Z, W, n):
    return [2 * autocorrelation(Z, s) + 2 * autocorrelation(W, s) for s in range(int(n))]


def xy_defects(X, Y, fixed):
    n = len(X)
    return [int(autocorrelation(X, s) + autocorrelation(Y, s) + fixed[s]) for s in range(1, n)]


def defect_metrics(defects):
    return {
        "score": int(sum(int(d) * int(d) for d in defects)),
        "l1_error": int(sum(abs(int(d)) for d in defects)),
        "max_abs_error": int(max(abs(int(d)) for d in defects)) if defects else 0,
        "nonzero_defect_count": int(sum(1 for d in defects if int(d) != 0)),
        "defects": [int(d) for d in defects],
    }


def parse_tuple(text):
    parts = [int(x) for x in text.split(",")]
    if len(parts) != 4:
        raise ValueError("--tuple must be x,y,z,w")
    return tuple(parts)


def sign_symbol(value):
    return "+" if int(value) > 0 else "-"


def pq_from_xy(X, Y):
    P = [int(x) + int(y) for x, y in zip(X, Y)]
    Q = [int(x) - int(y) for x, y in zip(X, Y)]
    return P, Q


def channel_at(P, Q, pos):
    if int(P[pos]) != 0 and int(Q[pos]) == 0:
        return "P", 1 if int(P[pos]) > 0 else -1
    if int(Q[pos]) != 0 and int(P[pos]) == 0:
        return "Q", 1 if int(Q[pos]) > 0 else -1
    raise ValueError("invalid P/Q disjoint support at position {}".format(pos))


def support_summary(seq):
    positive = [i for i, x in enumerate(seq) if int(x) > 0]
    negative = [i for i, x in enumerate(seq) if int(x) < 0]
    zero = [i for i, x in enumerate(seq) if int(x) == 0]
    return {
        "count": int(len(positive) + len(negative)),
        "positive_count": int(len(positive)),
        "negative_count": int(len(negative)),
        "zero_count": int(len(zero)),
        "sum": int(sum(seq)),
        "positive_positions": [int(x) for x in positive],
        "negative_positions": [int(x) for x in negative],
    }


def shift_pair_profile(P, Q, shift):
    n = len(P)
    row = {
        "shift": int(shift),
        "total_pairs": int(max(0, n - int(shift))),
        "p_positive_pairs": 0,
        "p_negative_pairs": 0,
        "q_positive_pairs": 0,
        "q_negative_pairs": 0,
        "same_channel_pairs": 0,
        "cross_channel_silent_pairs": 0,
        "pq_autocorrelation": 0,
    }
    for i in range(0, n - int(shift)):
        j = i + int(shift)
        ci, si = channel_at(P, Q, i)
        cj, sj = channel_at(P, Q, j)
        if ci != cj:
            row["cross_channel_silent_pairs"] += 1
            continue
        row["same_channel_pairs"] += 1
        if ci == "P":
            if si * sj > 0:
                row["p_positive_pairs"] += 1
            else:
                row["p_negative_pairs"] += 1
        else:
            if si * sj > 0:
                row["q_positive_pairs"] += 1
            else:
                row["q_negative_pairs"] += 1
    row["pq_autocorrelation"] = int(
        4
        * (
            row["p_positive_pairs"]
            - row["p_negative_pairs"]
            + row["q_positive_pairs"]
            - row["q_negative_pairs"]
        )
    )
    return row


def position_pressures(P, Q, defects, top_shift_count):
    n = len(P)
    rows = [(s, int(d)) for s, d in enumerate(defects, start=1) if int(d) != 0]
    rows.sort(key=lambda item: (-abs(item[1]), item[0]))
    selected = rows[: max(1, int(top_shift_count))]
    pressures = []
    for pos in range(n):
        channel, sign = channel_at(P, Q, pos)
        item = {
            "position": int(pos),
            "channel": channel,
            "sign": int(sign),
            "touch_pressure": 0,
            "active_same_channel_pressure": 0,
            "silent_cross_channel_pressure": 0,
            "shifts_touched": [],
        }
        for s, d in selected:
            for other in (pos - s, pos + s):
                if other < 0 or other >= n:
                    continue
                other_channel, _ = channel_at(P, Q, other)
                weight = abs(int(d))
                item["touch_pressure"] += weight
                if other_channel == channel:
                    item["active_same_channel_pressure"] += weight
                else:
                    item["silent_cross_channel_pressure"] += weight
                item["shifts_touched"].append(int(s))
        item["shifts_touched"] = sorted(set(item["shifts_touched"]))
        pressures.append(item)
    pressures.sort(
        key=lambda row: (
            -row["touch_pressure"],
            -row["active_same_channel_pressure"],
            -row["silent_cross_channel_pressure"],
            row["position"],
        )
    )
    return pressures


def load_completion(path, args):
    with open(path) as f:
        data = json.load(f)
    for key in ["X", "Y", "Z", "W"]:
        if key not in data:
            raise ValueError("{} is missing {}".format(path, key))
    X = [int(x) for x in data["X"]]
    Y = [int(x) for x in data["Y"]]
    Z = [int(x) for x in data["Z"]]
    W = [int(x) for x in data["W"]]
    if len(X) != int(args.n) or len(Y) != int(args.n) or len(Z) != int(args.n) or len(W) != int(args.n) - 1:
        raise ValueError("input lengths incompatible with n={}".format(args.n))
    sums = (sum(X), sum(Y), sum(Z), sum(W))
    if tuple(int(x) for x in sums) != args.tuple_value:
        raise ValueError("input sums {} != tuple {}".format(sums, args.tuple_value))
    return data, X, Y, Z, W


def write_markdown(path, payload, top_shifts, top_positions):
    lines = []
    lines.append("# P/Q X/Y Completion Diagnostics")
    lines.append("")
    lines.append("This is a diagnostic artifact. It is not a Turyn type sequence proof and not a Hadamard 668 construction.")
    lines.append("")
    lines.append("## Input")
    lines.append("")
    lines.append("- input: `{}`".format(payload["input_path"]))
    lines.append("- n: `{}`".format(payload["n"]))
    lines.append("- tuple: `{}`".format(payload["tuple"]))
    lines.append("")
    lines.append("## X/Y Defect Metrics")
    lines.append("")
    m = payload["xy_metrics"]
    lines.append("- score: `{}`".format(m["score"]))
    lines.append("- l1_error: `{}`".format(m["l1_error"]))
    lines.append("- max_abs_error: `{}`".format(m["max_abs_error"]))
    lines.append("- nonzero_defect_count: `{}`".format(m["nonzero_defect_count"]))
    lines.append("- pq_identity_ok: `{}`".format(payload["identity_checks"]["pq_identity_ok"]))
    lines.append("- pq_defect_double_xy_ok: `{}`".format(payload["identity_checks"]["pq_defect_double_xy_ok"]))
    lines.append("")
    lines.append("## P/Q Support")
    lines.append("")
    for name in ["P", "Q"]:
        s = payload["support"][name]
        lines.append(
            "- {}: support `{}`, positive `{}`, negative `{}`, sum `{}`".format(
                name, s["count"], s["positive_count"], s["negative_count"], s["sum"]
            )
        )
    lines.append("")
    lines.append("## Worst Shifts")
    lines.append("")
    lines.append("| shift | xy_defect | pq_defect | same pairs | silent cross | P + | P - | Q + | Q - |")
    lines.append("|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for row in payload["bad_shift_profiles"][: int(top_shifts)]:
        lines.append(
            "| {shift} | {xy_defect} | {pq_defect} | {same_channel_pairs} | {cross_channel_silent_pairs} | {p_positive_pairs} | {p_negative_pairs} | {q_positive_pairs} | {q_negative_pairs} |".format(
                **row
            )
        )
    lines.append("")
    lines.append("## High-Pressure Positions")
    lines.append("")
    lines.append("| pos | channel | sign | touch | active same-channel | silent cross-channel | shifts |")
    lines.append("|---:|:---:|---:|---:|---:|---:|:---|")
    for row in payload["position_pressures"][: int(top_positions)]:
        lines.append(
            "| {position} | {channel} | {sign} | {touch_pressure} | {active_same_channel_pressure} | {silent_cross_channel_pressure} | {shifts_touched} |".format(
                **row
            )
        )
    lines.append("")
    lines.append("## Move Semantics")
    lines.append("")
    lines.append("- Flipping one `X` entry maps `(P,Q)` at that position to `(-Q,-P)`.")
    lines.append("- Flipping one `Y` entry maps `(P,Q)` at that position to `(Q,P)`.")
    lines.append("- A balanced `X` or `Y` move therefore swaps two positions between the P-channel and Q-channel while preserving the requested X/Y sums.")
    lines.append("- P/Q autocorrelation receives contributions only from same-channel pairs; cross-channel pairs are silent.")
    lines.append("")
    lines.append("## Safety")
    lines.append("")
    lines.append("This report only rewrites and diagnoses the current X/Y near-hit. A success candidate still requires exact Turyn verification, T-sequence verification, and exact integer `HH^T = 668I`.")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Diagnose fixed-Z/W X/Y completion in P=X+Y, Q=X-Y coordinates.")
    parser.add_argument("completion_json")
    parser.add_argument("--n", type=int, default=56)
    parser.add_argument("--tuple", default="0,-18,-2,1")
    parser.add_argument("--top-shifts", type=int, default=20)
    parser.add_argument("--pressure-shifts", type=int, default=12)
    parser.add_argument("--top-positions", type=int, default=20)
    parser.add_argument("--out-prefix", default="outputs/turyn/pq_xy_diagnostics")
    args = parser.parse_args()
    args.tuple_value = parse_tuple(args.tuple)
    return args


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        data, X, Y, Z, W = load_completion(args.completion_json, args)
        P, Q = pq_from_xy(X, Y)
        fixed = fixed_zw_vector(Z, W, args.n)
        xy_metrics = defect_metrics(xy_defects(X, Y, fixed))
        nx = autocorrelation_vector(X, args.n)
        ny = autocorrelation_vector(Y, args.n)
        nz = autocorrelation_vector(Z, args.n)
        nw = autocorrelation_vector(W, args.n)
        npv = autocorrelation_vector(P, args.n)
        nqv = autocorrelation_vector(Q, args.n)
        pq_auto = [int(npv[s] + nqv[s]) for s in range(args.n)]
        pq_target = [int(-4 * (nz[s] + nw[s])) for s in range(args.n)]
        pq_defects = [int(pq_auto[s] - pq_target[s]) for s in range(1, args.n)]

        pq_identity_ok = all(int(pq_auto[s]) == int(2 * (nx[s] + ny[s])) for s in range(args.n))
        pq_defect_double_xy_ok = all(
            int(pq_defects[s - 1]) == int(2 * xy_metrics["defects"][s - 1]) for s in range(1, args.n)
        )
        disjoint_support_ok = all((int(P[i]) == 0) != (int(Q[i]) == 0) for i in range(args.n))
        value_set_ok = all(int(x) in (-2, 0, 2) for x in P + Q)

        bad_rows = []
        for s, d in enumerate(xy_metrics["defects"], start=1):
            if int(d) == 0:
                continue
            row = shift_pair_profile(P, Q, s)
            row["xy_defect"] = int(d)
            row["pq_defect"] = int(2 * d)
            row["pq_target"] = int(pq_target[s])
            row["pq_actual"] = int(pq_auto[s])
            bad_rows.append(row)
        bad_rows.sort(key=lambda row: (-abs(row["xy_defect"]), row["shift"]))

        pressures = position_pressures(P, Q, xy_metrics["defects"], args.pressure_shifts)

        payload = {
            "script": SCRIPT_NAME,
            "classification": "pq_xy_completion_diagnostic",
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "input_path": args.completion_json,
            "n": int(args.n),
            "target_order": int(4 * (3 * int(args.n) - 1)),
            "tuple": [int(x) for x in args.tuple_value],
            "xy_metrics": xy_metrics,
            "input_recorded_metrics": {
                "score": data.get("score"),
                "l1_error": data.get("l1_error"),
                "max_abs_error": data.get("max_abs_error"),
                "nonzero_defect_count": data.get("nonzero_defect_count"),
                "turyn_ok": data.get("turyn_ok"),
                "hadamard_ok": data.get("hadamard_ok"),
            },
            "P": [int(x) for x in P],
            "Q": [int(x) for x in Q],
            "support": {
                "P": support_summary(P),
                "Q": support_summary(Q),
            },
            "identity_checks": {
                "value_set_ok": bool(value_set_ok),
                "disjoint_support_ok": bool(disjoint_support_ok),
                "pq_identity_ok": bool(pq_identity_ok),
                "pq_defect_double_xy_ok": bool(pq_defect_double_xy_ok),
            },
            "pq_target": [int(x) for x in pq_target[1:]],
            "pq_actual": [int(x) for x in pq_auto[1:]],
            "pq_defects": [int(x) for x in pq_defects],
            "bad_shift_profiles": bad_rows,
            "position_pressures": pressures,
            "notes": [
                "P=X+Y and Q=X-Y convert X/Y completion into a disjoint-support ternary autocorrelation split.",
                "P/Q autocorrelation contributes only on same-channel pairs; cross-channel pairs are silent.",
                "This is a diagnostic artifact, not a Turyn type sequence or Hadamard construction.",
            ],
        }

        out_json = "{}_score{}.json".format(args.out_prefix, xy_metrics["score"])
        out_md = "{}_score{}.md".format(args.out_prefix, xy_metrics["score"])
        os.makedirs(os.path.dirname(out_json) or ".", exist_ok=True)
        write_json(out_json, payload)
        write_markdown(out_md, payload, args.top_shifts, args.top_positions)

        print("input:", args.completion_json)
        print(
            "metrics score={} l1={} max_abs={} nonzero={}".format(
                xy_metrics["score"],
                xy_metrics["l1_error"],
                xy_metrics["max_abs_error"],
                xy_metrics["nonzero_defect_count"],
            )
        )
        print(
            "P support={} sum={} Q support={} sum={}".format(
                payload["support"]["P"]["count"],
                payload["support"]["P"]["sum"],
                payload["support"]["Q"]["count"],
                payload["support"]["Q"]["sum"],
            )
        )
        print("identity checks:", payload["identity_checks"])
        print("top bad shifts:", [(r["shift"], r["xy_defect"]) for r in bad_rows[: args.top_shifts]])
        print("WROTE:", out_json)
        print("WROTE:", out_md)
    finally:
        tee.close()


if __name__ == "__main__":
    main()
