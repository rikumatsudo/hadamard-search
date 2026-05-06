from sage.all import *

import argparse
import csv
import json
import math
import os
import random
import sys
import time

from sds_repair_utils import setup_logging, write_json


SCRIPT_NAME = "35_single_spike_hall_pair_repair"


def hall_bound(n):
    return int(3 * int(n) - 1)


def precompute_trig(max_len, grid):
    cos_table = []
    sin_table = []
    for j in range(1, int(grid) + 1):
        theta = math.pi * float(j) / float(grid)
        cos_table.append([math.cos(theta * i) for i in range(int(max_len))])
        sin_table.append([math.sin(theta * i) for i in range(int(max_len))])
    return cos_table, sin_table


def initial_transform(seq, cos_table, sin_table):
    real = []
    imag = []
    for row_c, row_s in zip(cos_table, sin_table):
        r = 0.0
        im = 0.0
        for i, value in enumerate(seq):
            r += float(value) * row_c[i]
            im += float(value) * row_s[i]
        real.append(r)
        imag.append(im)
    return real, imag


def hall_values_from_transform(real, imag):
    return [float(r * r + im * im) for r, im in zip(real, imag)]


def excess_over_bound(pair_values, bound):
    return float(sum(max(0.0, float(value) - float(bound)) for value in pair_values))


def violation_count(pair_values, bound):
    return int(sum(1 for value in pair_values if float(value) > float(bound)))


def pair_metrics(zr, zi, wr, wi, bound):
    z_hall = hall_values_from_transform(zr, zi)
    w_hall = hall_values_from_transform(wr, wi)
    pair = [float(a) + float(b) for a, b in zip(z_hall, w_hall)]
    pair_max = max(pair)
    pair_argmax = max(range(len(pair)), key=lambda i: pair[i])
    sorted_values = sorted(pair, reverse=True)
    mean = sum(pair) / float(len(pair))
    variance = sum((x - mean) ** 2 for x in pair) / float(len(pair))
    return {
        "pair_values": pair,
        "pair_max": float(pair_max),
        "pair_argmax": int(pair_argmax),
        "pair_top_indices": sorted(range(len(pair)), key=lambda i: pair[i], reverse=True)[:10],
        "pair_top_gap": float(sorted_values[0] - sorted_values[1]) if len(sorted_values) > 1 else 0.0,
        "pair_mean": float(mean),
        "pair_std": float(math.sqrt(max(0.0, variance))),
        "pair_excess_over_bound": excess_over_bound(pair, bound),
        "pair_violation_count": violation_count(pair, bound),
        "z_max": float(max(z_hall)),
        "w_max": float(max(w_hall)),
    }


def score_tuple(metrics, objective, target_indices):
    if objective == "pair_max":
        return (
            float(metrics["pair_max"]),
            float(metrics["pair_excess_over_bound"]),
            int(metrics["pair_violation_count"]),
            float(metrics["pair_std"]),
        )
    if objective == "excess_then_pair_max":
        return (
            float(metrics["pair_excess_over_bound"]),
            float(metrics["pair_max"]),
            int(metrics["pair_violation_count"]),
            float(metrics["pair_std"]),
        )
    if objective == "violations_then_pair_max":
        return (
            int(metrics["pair_violation_count"]),
            float(metrics["pair_excess_over_bound"]),
            float(metrics["pair_max"]),
            float(metrics["pair_std"]),
        )
    if objective == "target_then_pair_max":
        target_max = max(float(metrics["pair_values"][i]) for i in target_indices)
        return (
            target_max,
            float(metrics["pair_max"]),
            float(metrics["pair_excess_over_bound"]),
            int(metrics["pair_violation_count"]),
        )
    raise ValueError("unknown objective {}".format(objective))


def apply_flip(seq, real, imag, cos_table, sin_table, i, j):
    old_i = int(seq[i])
    old_j = int(seq[j])
    if old_i == old_j:
        raise ValueError("balanced flip needs opposite signs")
    seq[i] = -old_i
    seq[j] = -old_j
    delta_i = float(seq[i] - old_i)
    delta_j = float(seq[j] - old_j)
    for k in range(len(real)):
        real[k] += delta_i * cos_table[k][i] + delta_j * cos_table[k][j]
        imag[k] += delta_i * sin_table[k][i] + delta_j * sin_table[k][j]


def undo_flip(seq, real, imag, cos_table, sin_table, i, j):
    apply_flip(seq, real, imag, cos_table, sin_table, i, j)


def apply_seq_move(which, move, Z, W, zr, zi, wr, wi, cos_table, sin_table):
    if move is None:
        return
    i, j = move
    if which == "Z":
        apply_flip(Z, zr, zi, cos_table, sin_table, i, j)
    else:
        apply_flip(W, wr, wi, cos_table, sin_table, i, j)


def undo_seq_move(which, move, Z, W, zr, zi, wr, wi, cos_table, sin_table):
    apply_seq_move(which, move, Z, W, zr, zi, wr, wi, cos_table, sin_table)


def target_indices_from_metrics(metrics, bound, target_theta, target_count):
    if int(target_theta) > 0:
        return [int(target_theta) - 1]
    violating = [i for i, value in enumerate(metrics["pair_values"]) if float(value) > float(bound)]
    if violating:
        violating.sort(key=lambda i: metrics["pair_values"][i], reverse=True)
        return violating[: max(1, int(target_count))]
    return [int(metrics["pair_argmax"])]


def position_delta_for_targets(seq, real, imag, cos_table, sin_table, target_indices, pos):
    old_value = int(seq[pos])
    delta = float(-2 * old_value)
    out = 0.0
    for theta_idx in target_indices:
        dc = delta * cos_table[theta_idx][pos]
        ds = delta * sin_table[theta_idx][pos]
        before = real[theta_idx] * real[theta_idx] + imag[theta_idx] * imag[theta_idx]
        after = (real[theta_idx] + dc) ** 2 + (imag[theta_idx] + ds) ** 2
        out += after - before
    return float(out)


def selected_positions(seq, real, imag, cos_table, sin_table, target_indices, position_pool):
    plus = []
    minus = []
    for pos, value in enumerate(seq):
        item = (
            position_delta_for_targets(seq, real, imag, cos_table, sin_table, target_indices, pos),
            int(pos),
        )
        if int(value) == 1:
            plus.append(item)
        else:
            minus.append(item)
    plus.sort(key=lambda x: x[0])
    minus.sort(key=lambda x: x[0])
    if int(position_pool) <= 0:
        return [p for _, p in plus], [p for _, p in minus]
    return [p for _, p in plus[: int(position_pool)]], [p for _, p in minus[: int(position_pool)]]


def generate_seq_flips(which, Z, W, zr, zi, wr, wi, cos_table, sin_table, bound, target_indices, args):
    if which == "Z":
        seq, real, imag = Z, zr, zi
    else:
        seq, real, imag = W, wr, wi
    plus, minus = selected_positions(seq, real, imag, cos_table, sin_table, target_indices, args.position_pool)
    scored = []
    seen = set()
    for i in plus:
        for j in minus:
            move = (int(i), int(j))
            if move in seen:
                continue
            seen.add(move)
            apply_seq_move(which, move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
            metrics = pair_metrics(zr, zi, wr, wi, bound)
            key = score_tuple(metrics, args.objective, target_indices)
            undo_seq_move(which, move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
            scored.append((key, move, metrics))
    scored.sort(key=lambda x: x[0])
    if int(args.random_flips) > 0:
        plus_all = [i for i, x in enumerate(seq) if int(x) == 1]
        minus_all = [i for i, x in enumerate(seq) if int(x) == -1]
        for _ in range(int(args.random_flips)):
            move = (int(random.choice(plus_all)), int(random.choice(minus_all)))
            if move in seen:
                continue
            seen.add(move)
            apply_seq_move(which, move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
            metrics = pair_metrics(zr, zi, wr, wi, bound)
            key = score_tuple(metrics, args.objective, target_indices)
            undo_seq_move(which, move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
            scored.append((key, move, metrics))
        scored.sort(key=lambda x: x[0])
    return [move for _, move, _ in scored[: max(1, int(args.flip_pool))]]


def find_best_coordinated_move(Z, W, zr, zi, wr, wi, cos_table, sin_table, bound, args, metrics, cur_key):
    target_indices = target_indices_from_metrics(metrics, bound, args.target_theta, args.target_count)
    z_moves = [None] + generate_seq_flips("Z", Z, W, zr, zi, wr, wi, cos_table, sin_table, bound, target_indices, args)
    w_moves = [None] + generate_seq_flips("W", Z, W, zr, zi, wr, wi, cos_table, sin_table, bound, target_indices, args)
    best = None
    best_metrics = None
    best_key = None
    checked = 0
    for z_move in z_moves:
        apply_seq_move("Z", z_move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
        for w_move in w_moves:
            if z_move is None and w_move is None:
                continue
            apply_seq_move("W", w_move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
            cand_metrics = pair_metrics(zr, zi, wr, wi, bound)
            key = score_tuple(cand_metrics, args.objective, target_indices)
            checked += 1
            undo_seq_move("W", w_move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
            if best is None or key < best_key:
                best = (z_move, w_move, target_indices)
                best_metrics = cand_metrics
                best_key = key
        undo_seq_move("Z", z_move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
    improved = best_key is not None and best_key < cur_key
    return best, best_metrics, best_key, checked, improved


def compact_signature(seq, width):
    width = int(width)
    sig = list(seq[:width]) + list(seq[-width:])
    return "".join("+" if int(x) > 0 else "-" for x in sig)


def save_result(path, input_path, Z, W, metrics, args, step, history):
    payload = {
        "script": SCRIPT_NAME,
        "classification": "single_spike_hall_pair_repair",
        "input_path": input_path,
        "n": int(args.n),
        "target_order": int(4 * hall_bound(args.n)),
        "tuple": [int(x) for x in args.tuple_value],
        "Z": [int(x) for x in Z],
        "W": [int(x) for x in W],
        "z_sum": int(sum(Z)),
        "w_sum": int(sum(W)),
        "bound": int(hall_bound(args.n)),
        "grid": int(args.grid),
        "objective": args.objective,
        "pair_max": float(metrics["pair_max"]),
        "pair_argmax": int(metrics["pair_argmax"]),
        "pair_top_indices": [int(x) for x in metrics["pair_top_indices"]],
        "pair_excess_over_bound": float(metrics["pair_excess_over_bound"]),
        "pair_violation_count": int(metrics["pair_violation_count"]),
        "pair_hall_pass": bool(metrics["pair_max"] <= hall_bound(args.n)),
        "z_max": float(metrics["z_max"]),
        "w_max": float(metrics["w_max"]),
        "step": int(step),
        "position_pool": int(args.position_pool),
        "flip_pool": int(args.flip_pool),
        "random_flips": int(args.random_flips),
        "history": history,
        "z_signature": compact_signature(Z, args.endpoint_width),
        "w_signature": compact_signature(W, args.endpoint_width),
        "notes": [
            "This is a Z/W Hall-pair repair artifact, not a Hadamard construction.",
            "A Hall-pair pass only permits a later X/Y completion attempt.",
        ],
    }
    write_json(path, payload)


def load_pair(path, args):
    with open(path) as f:
        data = json.load(f)
    Z = [int(x) for x in data["Z"]]
    W = [int(x) for x in data["W"]]
    tuple_value = tuple(int(x) for x in data.get("tuple", args.tuple_value))
    if tuple_value != args.tuple_value:
        raise ValueError("input tuple {} != requested tuple {}".format(tuple_value, args.tuple_value))
    if len(Z) != int(args.n) or len(W) != int(args.n) - 1:
        raise ValueError("input lengths are incompatible with n={}".format(args.n))
    if sum(Z) != args.tuple_value[2] or sum(W) != args.tuple_value[3]:
        raise ValueError("input sums do not match requested tuple")
    return Z, W


def parse_tuple(text):
    parts = [int(x) for x in text.split(",")]
    if len(parts) != 4:
        raise ValueError("--tuple must be x,y,z,w")
    return tuple(parts)


def parse_args():
    parser = argparse.ArgumentParser(description="Coordinated Z/W single-spike Hall-pair repair.")
    parser.add_argument("input_json")
    parser.add_argument("--n", type=int, default=56)
    parser.add_argument("--tuple", default="0,-18,-2,1")
    parser.add_argument("--grid", type=int, default=100)
    parser.add_argument(
        "--objective",
        choices=["pair_max", "excess_then_pair_max", "violations_then_pair_max", "target_then_pair_max"],
        default="pair_max",
    )
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--target-theta", type=int, default=0, help="1-based theta index. 0 means current worst violation.")
    parser.add_argument("--target-count", type=int, default=1)
    parser.add_argument("--position-pool", type=int, default=0, help="0 uses all plus/minus positions.")
    parser.add_argument("--flip-pool", type=int, default=120)
    parser.add_argument("--random-flips", type=int, default=0)
    parser.add_argument("--endpoint-width", type=int, default=6)
    parser.add_argument("--save-improvements", action="store_true")
    parser.add_argument("--out-prefix", default="outputs/turyn/single_spike_repair")
    parser.add_argument("--csv", default="")
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    args.tuple_value = parse_tuple(args.tuple)
    return args


def main():
    args = parse_args()
    random.seed(int(args.seed))
    tee, stamp = setup_logging(SCRIPT_NAME)
    csv_file = None
    try:
        bound = hall_bound(args.n)
        Z, W = load_pair(args.input_json, args)
        cos_table, sin_table = precompute_trig(args.n, args.grid)
        zr, zi = initial_transform(Z, cos_table, sin_table)
        wr, wi = initial_transform(W, cos_table, sin_table)
        metrics = pair_metrics(zr, zi, wr, wi, bound)
        cur_key = score_tuple(
            metrics,
            args.objective,
            target_indices_from_metrics(metrics, bound, args.target_theta, args.target_count),
        )
        best_metrics = dict(metrics)
        best_Z = list(Z)
        best_W = list(W)
        best_key = cur_key
        best_step = 0
        history = []
        start = time.time()
        csv_path = args.csv or os.path.join("outputs/logs", "{}_{}.csv".format(SCRIPT_NAME, stamp))
        os.makedirs(os.path.dirname(csv_path) or ".", exist_ok=True)
        csv_file = open(csv_path, "w", newline="")
        writer = csv.DictWriter(
            csv_file,
            fieldnames=[
                "step",
                "pair_max",
                "pair_excess",
                "violations",
                "theta",
                "z_move",
                "w_move",
                "checked",
                "improved",
                "elapsed_sec",
            ],
        )
        writer.writeheader()
        print("input:", args.input_json)
        print(
            "initial pair_max={:.6f} excess={:.6f} violations={} theta={}".format(
                metrics["pair_max"],
                metrics["pair_excess_over_bound"],
                metrics["pair_violation_count"],
                metrics["pair_argmax"] + 1,
            )
        )
        for step in range(1, int(args.rounds) + 1):
            move, cand_metrics, cand_key, checked, improved = find_best_coordinated_move(
                Z, W, zr, zi, wr, wi, cos_table, sin_table, bound, args, metrics, cur_key
            )
            if not improved:
                print("NO_IMPROVING_COORDINATED_MOVE step={} checked={}".format(step, checked))
                break
            z_move, w_move, target_indices = move
            apply_seq_move("Z", z_move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
            apply_seq_move("W", w_move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
            metrics = cand_metrics
            cur_key = cand_key
            best_metrics = dict(metrics)
            best_Z = list(Z)
            best_W = list(W)
            best_key = cur_key
            best_step = step
            item = {
                "step": int(step),
                "z_move": list(z_move) if z_move is not None else None,
                "w_move": list(w_move) if w_move is not None else None,
                "target_indices": [int(i) + 1 for i in target_indices],
                "checked": int(checked),
                "pair_max": float(metrics["pair_max"]),
                "pair_excess_over_bound": float(metrics["pair_excess_over_bound"]),
                "pair_violation_count": int(metrics["pair_violation_count"]),
                "pair_argmax": int(metrics["pair_argmax"]) + 1,
            }
            history.append(item)
            print(
                "BEST step={} pair_max={:.6f} excess={:.6f} violations={} theta={} z_move={} w_move={} checked={}".format(
                    step,
                    metrics["pair_max"],
                    metrics["pair_excess_over_bound"],
                    metrics["pair_violation_count"],
                    metrics["pair_argmax"] + 1,
                    z_move,
                    w_move,
                    checked,
                )
            )
            writer.writerow(
                {
                    "step": int(step),
                    "pair_max": float(metrics["pair_max"]),
                    "pair_excess": float(metrics["pair_excess_over_bound"]),
                    "violations": int(metrics["pair_violation_count"]),
                    "theta": int(metrics["pair_argmax"]) + 1,
                    "z_move": z_move,
                    "w_move": w_move,
                    "checked": int(checked),
                    "improved": True,
                    "elapsed_sec": round(time.time() - start, 3),
                }
            )
            csv_file.flush()
            if args.save_improvements:
                path = "{}_step{}_pairmax{:.3f}.json".format(args.out_prefix, step, metrics["pair_max"])
                save_result(path, args.input_json, best_Z, best_W, best_metrics, args, best_step, history)
                print("saved:", path)
            if metrics["pair_max"] <= bound:
                print("PAIR_HALL_BOUND_PASSED step={} pair_max={:.6f}".format(step, metrics["pair_max"]))
                break
            sys.stdout.flush()
        final_path = "{}_step{}_pairmax{:.3f}.json".format(args.out_prefix, best_step, best_metrics["pair_max"])
        save_result(final_path, args.input_json, best_Z, best_W, best_metrics, args, best_step, history)
        print("FINAL_BEST:", final_path)
        print(
            "best pair_max={:.6f} excess={:.6f} violations={} pass={}".format(
                best_metrics["pair_max"],
                best_metrics["pair_excess_over_bound"],
                best_metrics["pair_violation_count"],
                best_metrics["pair_max"] <= bound,
            )
        )
    finally:
        if csv_file is not None:
            csv_file.close()
        tee.close()


if __name__ == "__main__":
    main()
