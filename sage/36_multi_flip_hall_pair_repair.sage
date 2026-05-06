from sage.all import *

import argparse
import csv
import json
import math
import os
import random
import time

from sds_repair_utils import setup_logging, write_json


SCRIPT_NAME = "36_multi_flip_hall_pair_repair"


def ensure_unique_path(path):
    if not os.path.exists(path):
        return path
    root, ext = os.path.splitext(path)
    idx = 1
    while True:
        candidate = "{}_{}{}".format(root, idx, ext)
        if not os.path.exists(candidate):
            return candidate
        idx += 1


def hall_bound(n):
    return int(3 * int(n) - 1)


def parse_tuple(text):
    parts = [int(x) for x in text.split(",")]
    if len(parts) != 4:
        raise ValueError("--tuple must be x,y,z,w")
    return tuple(parts)


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


def excess_over_limit(pair_values, limit):
    return float(sum(max(0.0, float(value) - float(limit)) for value in pair_values))


def violation_count(pair_values, bound):
    return int(sum(1 for value in pair_values if float(value) > float(bound)))


def violation_count_over_limit(pair_values, limit):
    return int(sum(1 for value in pair_values if float(value) > float(limit)))


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


def autocorrelation(seq, shift):
    shift = int(shift)
    if shift <= 0:
        return int(sum(int(x) * int(x) for x in seq))
    if shift >= len(seq):
        return 0
    return int(sum(int(seq[i]) * int(seq[i + shift]) for i in range(len(seq) - shift)))


def target_roughness(values):
    return int(sum((int(values[i + 1]) - int(values[i])) ** 2 for i in range(len(values) - 1)))


def target_profile_metrics(Z, W, n):
    values = []
    for s in range(1, int(n)):
        values.append(int(-2 * (autocorrelation(Z, s) + autocorrelation(W, s))))
    return {
        "score": int(sum(x * x for x in values)),
        "l1_error": int(sum(abs(x) for x in values)),
        "max_abs_error": int(max(abs(x) for x in values)) if values else 0,
        "nonzero_count": int(sum(1 for x in values if int(x) != 0)),
        "roughness": target_roughness(values),
        "xy_target": [int(x) for x in values],
    }


def completion_proxy_metrics(metrics, bound, Z, W, n, args):
    pair_values = metrics["pair_values"]
    constant = float(6 * int(n) - 2)
    required = [constant - 2.0 * float(value) for value in pair_values]
    small_margin = float(args.proxy_small_margin)
    epsilon = 1e-6
    near_zero_penalty = 0.0
    reciprocal_penalty = 0.0
    for value in required:
        if value < -epsilon:
            near_zero_penalty += (abs(value) + small_margin) ** 2
            reciprocal_penalty += 1.0 / epsilon
        elif value < small_margin:
            near_zero_penalty += (small_margin - value) ** 2
            reciprocal_penalty += 1.0 / max(epsilon, value)
    target = target_profile_metrics(Z, W, n)
    pair_excess = excess_over_bound(pair_values, bound)
    pair_violations = violation_count(pair_values, bound)
    hall_component = 10.0 * float(pair_excess) + 1000.0 * float(pair_violations)
    fourier_component = (
        10000.0 * float(sum(1 for x in required if x < -epsilon))
        + float(args.proxy_margin_weight) * (near_zero_penalty / float(max(1, len(required))))
        + float(args.proxy_reciprocal_weight) * (reciprocal_penalty / float(max(1, len(required))))
    )
    target_component = (
        float(args.proxy_target_score_weight) * float(target["score"])
        + float(args.proxy_target_l1_weight) * float(target["l1_error"])
        + float(args.proxy_target_maxabs_weight) * float(target["max_abs_error"])
        + float(args.proxy_target_roughness_weight) * float(target["roughness"])
    )
    return {
        "completion_proxy": float(hall_component + fourier_component + target_component),
        "hall_component": float(hall_component),
        "fourier_component": float(fourier_component),
        "target_component": float(target_component),
        "min_required": float(min(required)) if required else 0.0,
        "negative_required_count": int(sum(1 for x in required if x < -epsilon)),
        "near_zero_penalty": float(near_zero_penalty / float(max(1, len(required)))),
        "reciprocal_margin_penalty": float(reciprocal_penalty / float(max(1, len(required)))),
        "target_profile": target,
    }


def target_indices_from_metrics(metrics, bound, target_theta, target_count):
    if int(target_theta) > 0:
        return [int(target_theta) - 1]
    violating = [i for i, value in enumerate(metrics["pair_values"]) if float(value) > float(bound)]
    if violating:
        violating.sort(key=lambda i: metrics["pair_values"][i], reverse=True)
        return violating[: max(1, int(target_count))]
    return [int(metrics["pair_argmax"])]


def score_tuple(metrics, objective, target_indices, Z=None, W=None, args=None):
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
    if objective in ("hall_slack_completion_proxy", "hall_pass_completion_proxy", "pair_max_then_completion_proxy"):
        if Z is None or W is None or args is None:
            raise ValueError("{} requires Z/W state".format(objective))
        bound = hall_bound(args.n)
        proxy = completion_proxy_metrics(metrics, bound, Z, W, args.n, args)
        pair_values = metrics["pair_values"]
        if objective == "hall_slack_completion_proxy":
            limit = float(bound) + float(args.hall_slack)
            slack_excess = excess_over_limit(pair_values, limit)
            slack_violations = violation_count_over_limit(pair_values, limit)
            return (
                int(slack_violations),
                float(slack_excess),
                float(proxy["completion_proxy"]),
                float(metrics["pair_max"]),
                float(metrics["pair_excess_over_bound"]),
            )
        if objective == "hall_pass_completion_proxy":
            return (
                int(metrics["pair_violation_count"]),
                float(metrics["pair_excess_over_bound"]),
                float(proxy["completion_proxy"]),
                float(metrics["pair_max"]),
            )
        return (
            float(metrics["pair_max"]),
            float(proxy["completion_proxy"]),
            float(metrics["pair_excess_over_bound"]),
            int(proxy["negative_required_count"]),
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


def apply_seq_move(which, move, Z, W, zr, zi, wr, wi, cos_table, sin_table):
    if move is None:
        return
    i, j = move
    if which == "Z":
        apply_flip(Z, zr, zi, cos_table, sin_table, i, j)
    else:
        apply_flip(W, wr, wi, cos_table, sin_table, i, j)


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


def clone_state(Z, W, zr, zi, wr, wi):
    return list(Z), list(W), list(zr), list(zi), list(wr), list(wi)


def evaluate_moves(base_state, z_moves, w_moves, cos_table, sin_table, bound):
    Z, W, zr, zi, wr, wi = clone_state(*base_state)
    for move in z_moves:
        apply_seq_move("Z", move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
    for move in w_moves:
        apply_seq_move("W", move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
    return Z, W, pair_metrics(zr, zi, wr, wi, bound)


def generate_atomic_flips(which, base_state, cos_table, sin_table, bound, target_indices, args):
    Z, W, zr, zi, wr, wi = clone_state(*base_state)
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
            if which == "Z":
                cand_Z, cand_W, metrics = evaluate_moves(base_state, [move], [], cos_table, sin_table, bound)
            else:
                cand_Z, cand_W, metrics = evaluate_moves(base_state, [], [move], cos_table, sin_table, bound)
            key = score_tuple(metrics, args.atomic_objective, target_indices, Z=cand_Z, W=cand_W, args=args)
            scored.append((key, move))
    if int(args.random_flips) > 0:
        plus_all = [i for i, x in enumerate(seq) if int(x) == 1]
        minus_all = [i for i, x in enumerate(seq) if int(x) == -1]
        for _ in range(int(args.random_flips)):
            move = (int(random.choice(plus_all)), int(random.choice(minus_all)))
            if move in seen:
                continue
            seen.add(move)
            if which == "Z":
                cand_Z, cand_W, metrics = evaluate_moves(base_state, [move], [], cos_table, sin_table, bound)
            else:
                cand_Z, cand_W, metrics = evaluate_moves(base_state, [], [move], cos_table, sin_table, bound)
            key = score_tuple(metrics, args.atomic_objective, target_indices, Z=cand_Z, W=cand_W, args=args)
            scored.append((key, move))
    scored.sort(key=lambda x: x[0])
    return [move for _, move in scored[: max(1, int(args.atomic_pool))]]


def compatible(existing_moves, move):
    used = set()
    for m in existing_moves:
        used.add(int(m[0]))
        used.add(int(m[1]))
    return int(move[0]) not in used and int(move[1]) not in used


def run_pattern(pattern, base_state, z_atoms, w_atoms, cos_table, sin_table, bound, target_indices, args):
    beam = [
        {
            "z_moves": [],
            "w_moves": [],
            "key": None,
            "metrics": None,
        }
    ]
    checked = 0
    for letter in pattern:
        next_beam = []
        atoms = z_atoms if letter == "Z" else w_atoms
        for state in beam:
            existing = state["z_moves"] if letter == "Z" else state["w_moves"]
            for move in atoms:
                if not compatible(existing, move):
                    continue
                z_moves = list(state["z_moves"])
                w_moves = list(state["w_moves"])
                if letter == "Z":
                    z_moves.append(move)
                else:
                    w_moves.append(move)
                cand_Z, cand_W, metrics = evaluate_moves(base_state, z_moves, w_moves, cos_table, sin_table, bound)
                key = score_tuple(metrics, args.objective, target_indices, Z=cand_Z, W=cand_W, args=args)
                checked += 1
                next_beam.append(
                    {
                        "z_moves": z_moves,
                        "w_moves": w_moves,
                        "key": key,
                        "metrics": metrics,
                        "Z": cand_Z,
                        "W": cand_W,
                    }
                )
        next_beam.sort(key=lambda x: x["key"])
        beam = next_beam[: max(1, int(args.beam_width))]
        if not beam:
            break
    if not beam:
        return None, checked
    return beam[0], checked


def compact_signature(seq, width):
    width = int(width)
    sig = list(seq[:width]) + list(seq[-width:])
    return "".join("+" if int(x) > 0 else "-" for x in sig)


def save_result(path, input_path, Z, W, metrics, args, target_indices, pattern_results):
    payload = {
        "script": SCRIPT_NAME,
        "classification": "multi_flip_hall_pair_repair",
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
        "atomic_objective": args.atomic_objective,
        "target_indices": [int(i) + 1 for i in target_indices],
        "pair_max": float(metrics["pair_max"]),
        "pair_argmax": int(metrics["pair_argmax"]),
        "pair_top_indices": [int(x) for x in metrics["pair_top_indices"]],
        "pair_excess_over_bound": float(metrics["pair_excess_over_bound"]),
        "pair_violation_count": int(metrics["pair_violation_count"]),
        "pair_hall_pass": bool(metrics["pair_max"] <= hall_bound(args.n)),
        "hall_slack": float(args.hall_slack),
        "pair_within_hall_slack": bool(metrics["pair_max"] <= hall_bound(args.n) + float(args.hall_slack)),
        "z_max": float(metrics["z_max"]),
        "w_max": float(metrics["w_max"]),
        "position_pool": int(args.position_pool),
        "atomic_pool": int(args.atomic_pool),
        "beam_width": int(args.beam_width),
        "patterns": args.patterns,
        "pattern_results": pattern_results,
        "z_signature": compact_signature(Z, args.endpoint_width),
        "w_signature": compact_signature(W, args.endpoint_width),
        "notes": [
            "This is a Z/W Hall-pair multi-flip repair artifact, not a Hadamard construction.",
            "A Hall-pair pass only permits a later X/Y completion attempt.",
        ],
    }
    if args.objective in ("hall_slack_completion_proxy", "hall_pass_completion_proxy", "pair_max_then_completion_proxy") or args.save_proxy_metrics:
        payload["completion_proxy_metrics"] = completion_proxy_metrics(metrics, hall_bound(args.n), Z, W, args.n, args)
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


def parse_args():
    parser = argparse.ArgumentParser(description="Beam multi-flip Hall-pair repair.")
    parser.add_argument("input_json")
    parser.add_argument("--n", type=int, default=56)
    parser.add_argument("--tuple", default="0,-18,-2,1")
    parser.add_argument("--grid", type=int, default=100)
    parser.add_argument(
        "--objective",
        choices=[
            "pair_max",
            "excess_then_pair_max",
            "violations_then_pair_max",
            "target_then_pair_max",
            "hall_slack_completion_proxy",
            "hall_pass_completion_proxy",
            "pair_max_then_completion_proxy",
        ],
        default="pair_max",
    )
    parser.add_argument(
        "--atomic-objective",
        choices=[
            "pair_max",
            "excess_then_pair_max",
            "violations_then_pair_max",
            "target_then_pair_max",
            "hall_slack_completion_proxy",
            "hall_pass_completion_proxy",
            "pair_max_then_completion_proxy",
        ],
        default="target_then_pair_max",
    )
    parser.add_argument("--patterns", default="ZZW,ZWW,ZZWW")
    parser.add_argument("--target-theta", type=int, default=0)
    parser.add_argument("--target-count", type=int, default=1)
    parser.add_argument("--position-pool", type=int, default=0)
    parser.add_argument("--atomic-pool", type=int, default=200)
    parser.add_argument("--beam-width", type=int, default=300)
    parser.add_argument("--random-flips", type=int, default=0)
    parser.add_argument("--endpoint-width", type=int, default=6)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--hall-slack", type=float, default=1.0)
    parser.add_argument("--proxy-small-margin", type=float, default=10.0)
    parser.add_argument("--proxy-margin-weight", type=float, default=50.0)
    parser.add_argument("--proxy-reciprocal-weight", type=float, default=10.0)
    parser.add_argument("--proxy-target-score-weight", type=float, default=0.10)
    parser.add_argument("--proxy-target-l1-weight", type=float, default=1.0)
    parser.add_argument("--proxy-target-maxabs-weight", type=float, default=5.0)
    parser.add_argument("--proxy-target-roughness-weight", type=float, default=0.01)
    parser.add_argument("--save-proxy-metrics", action="store_true")
    parser.add_argument("--out-prefix", default="outputs/turyn/multi_flip_repair")
    parser.add_argument("--csv", default="")
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
        base_state = (Z, W, zr, zi, wr, wi)
        initial_metrics = pair_metrics(zr, zi, wr, wi, bound)
        target_indices = target_indices_from_metrics(initial_metrics, bound, args.target_theta, args.target_count)
        initial_key = score_tuple(initial_metrics, args.objective, target_indices, Z=Z, W=W, args=args)
        print("input:", args.input_json)
        print(
            "initial pair_max={:.6f} excess={:.6f} violations={} theta={} targets={}".format(
                initial_metrics["pair_max"],
                initial_metrics["pair_excess_over_bound"],
                initial_metrics["pair_violation_count"],
                initial_metrics["pair_argmax"] + 1,
                [i + 1 for i in target_indices],
            )
        )
        z_atoms = generate_atomic_flips("Z", base_state, cos_table, sin_table, bound, target_indices, args)
        w_atoms = generate_atomic_flips("W", base_state, cos_table, sin_table, bound, target_indices, args)
        print("atomic flips: Z={} W={}".format(len(z_atoms), len(w_atoms)))
        csv_path = args.csv or os.path.join("outputs/logs", "{}_{}.csv".format(SCRIPT_NAME, stamp))
        os.makedirs(os.path.dirname(csv_path) or ".", exist_ok=True)
        csv_file = open(csv_path, "w", newline="")
        writer = csv.DictWriter(
            csv_file,
            fieldnames=[
                "pattern",
                "checked",
                "pair_max",
                "pair_excess",
                "violations",
                "theta",
                "z_moves",
                "w_moves",
                "improved",
                "elapsed_sec",
            ],
        )
        writer.writeheader()
        best_state = None
        best_key = None
        pattern_results = []
        start = time.time()
        for raw_pattern in args.patterns.split(","):
            pattern = raw_pattern.strip().upper()
            if not pattern:
                continue
            result, checked = run_pattern(pattern, base_state, z_atoms, w_atoms, cos_table, sin_table, bound, target_indices, args)
            if result is None:
                continue
            metrics = result["metrics"]
            key = result["key"]
            improved = key < initial_key
            item = {
                "pattern": pattern,
                "checked": int(checked),
                "pair_max": float(metrics["pair_max"]),
                "pair_excess_over_bound": float(metrics["pair_excess_over_bound"]),
                "pair_violation_count": int(metrics["pair_violation_count"]),
                "pair_argmax": int(metrics["pair_argmax"]) + 1,
                "z_moves": [list(m) for m in result["z_moves"]],
                "w_moves": [list(m) for m in result["w_moves"]],
                "improved": bool(improved),
            }
            if args.objective in ("hall_slack_completion_proxy", "hall_pass_completion_proxy", "pair_max_then_completion_proxy"):
                item["completion_proxy_metrics"] = completion_proxy_metrics(
                    metrics, bound, result["Z"], result["W"], args.n, args
                )
            pattern_results.append(item)
            writer.writerow(
                {
                    "pattern": pattern,
                    "checked": int(checked),
                    "pair_max": float(metrics["pair_max"]),
                    "pair_excess": float(metrics["pair_excess_over_bound"]),
                    "violations": int(metrics["pair_violation_count"]),
                    "theta": int(metrics["pair_argmax"]) + 1,
                    "z_moves": item["z_moves"],
                    "w_moves": item["w_moves"],
                    "improved": bool(improved),
                    "elapsed_sec": round(time.time() - start, 3),
                }
            )
            csv_file.flush()
            print(
                "pattern={} checked={} pair_max={:.6f} excess={:.6f} violations={} improved={}".format(
                    pattern,
                    checked,
                    metrics["pair_max"],
                    metrics["pair_excess_over_bound"],
                    metrics["pair_violation_count"],
                    improved,
                )
            )
            if best_state is None or key < best_key:
                best_state = result
                best_key = key
        if best_state is None or best_key >= initial_key:
            best_Z = list(Z)
            best_W = list(W)
            best_metrics = initial_metrics
        else:
            best_Z, best_W, best_metrics = evaluate_moves(
                base_state, best_state["z_moves"], best_state["w_moves"], cos_table, sin_table, bound
            )
        final_path = ensure_unique_path("{}_pairmax{:.3f}.json".format(args.out_prefix, best_metrics["pair_max"]))
        save_result(final_path, args.input_json, best_Z, best_W, best_metrics, args, target_indices, pattern_results)
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
