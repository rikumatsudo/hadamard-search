from sage.all import *

import argparse
import csv
import json
import os
import random
import time

from sds_repair_utils import setup_logging, write_json


SCRIPT_NAME = "40_pq_channel_routing_repair"


def parse_tuple(text):
    parts = [int(x) for x in text.split(",")]
    if len(parts) != 4:
        raise ValueError("--tuple must be x,y,z,w")
    return tuple(parts)


def parse_shift_list(text):
    if not text:
        return []
    return [int(x) for x in text.split(",") if str(x).strip()]


def autocorrelation(seq, shift):
    shift = int(shift)
    if shift <= 0:
        return int(sum(int(x) * int(x) for x in seq))
    if shift >= len(seq):
        return 0
    return int(sum(int(seq[i]) * int(seq[i + shift]) for i in range(len(seq) - shift)))


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


def current_metrics(X, Y, fixed):
    return defect_metrics(xy_defects(X, Y, fixed))


def pq_from_xy(X, Y):
    return [int(x) + int(y) for x, y in zip(X, Y)], [int(x) - int(y) for x, y in zip(X, Y)]


def channel_at(P, Q, pos):
    if int(P[pos]) != 0 and int(Q[pos]) == 0:
        return "P", 1 if int(P[pos]) > 0 else -1
    if int(Q[pos]) != 0 and int(P[pos]) == 0:
        return "Q", 1 if int(Q[pos]) > 0 else -1
    raise ValueError("invalid P/Q support at position {}".format(pos))


def target_shifts_from_metrics(metrics, explicit, target_count):
    if explicit:
        return [int(s) for s in explicit]
    rows = [(i + 1, int(d)) for i, d in enumerate(metrics["defects"]) if int(d) != 0]
    rows.sort(key=lambda row: (-abs(row[1]), row[0]))
    return [s for s, _ in rows[: max(1, int(target_count))]]


def target_l1(metrics, target_shifts):
    return int(sum(abs(int(metrics["defects"][int(s) - 1])) for s in target_shifts))


def pq_position_pressure(P, Q, defects, target_shifts, pos):
    channel, sign = channel_at(P, Q, pos)
    pressure = 0
    active = 0
    silent = 0
    bad_aligned = 0
    for s in target_shifts:
        d = int(defects[int(s) - 1])
        if d == 0:
            continue
        for other in (pos - int(s), pos + int(s)):
            if other < 0 or other >= len(P):
                continue
            other_channel, other_sign = channel_at(P, Q, other)
            weight = abs(d)
            pressure += weight
            if other_channel != channel:
                silent += weight
                pressure += weight // 2
                continue
            active += weight
            pair_sign = sign * other_sign
            # If the defect is positive, positive same-channel pairs are excess.
            # If the defect is negative, negative same-channel pairs are excess.
            if (d > 0 and pair_sign > 0) or (d < 0 and pair_sign < 0):
                bad_aligned += weight
                pressure += 4 * weight
            else:
                pressure += weight
    return {
        "position": int(pos),
        "channel": channel,
        "sign": int(sign),
        "pressure": int(pressure),
        "active_same_channel_pressure": int(active),
        "silent_cross_channel_pressure": int(silent),
        "bad_aligned_pressure": int(bad_aligned),
    }


def selected_positions(which, X, Y, P, Q, metrics, target_shifts, position_pool):
    seq = X if which == "X" else Y
    plus = []
    minus = []
    for pos, value in enumerate(seq):
        row = pq_position_pressure(P, Q, metrics["defects"], target_shifts, pos)
        item = (
            row["pressure"],
            row["bad_aligned_pressure"],
            row["active_same_channel_pressure"],
            row["silent_cross_channel_pressure"],
            int(pos),
        )
        if int(value) == 1:
            plus.append(item)
        else:
            minus.append(item)
    plus.sort(key=lambda x: (-x[0], -x[1], -x[2], -x[3], x[4]))
    minus.sort(key=lambda x: (-x[0], -x[1], -x[2], -x[3], x[4]))
    if int(position_pool) <= 0:
        return [p[-1] for p in plus], [p[-1] for p in minus]
    return [p[-1] for p in plus[: int(position_pool)]], [p[-1] for p in minus[: int(position_pool)]]


def apply_flip(seq, i, j):
    if int(seq[i]) == int(seq[j]):
        raise ValueError("balanced flip needs opposite signs")
    seq[i] = -int(seq[i])
    seq[j] = -int(seq[j])


def apply_seq_move(which, move, X, Y):
    if move is None:
        return
    i, j = move
    if which == "X":
        apply_flip(X, i, j)
    else:
        apply_flip(Y, i, j)


def clone_xy(X, Y):
    return list(X), list(Y)


def evaluate_moves(base_X, base_Y, x_moves, y_moves, fixed):
    X, Y = clone_xy(base_X, base_Y)
    for move in x_moves:
        apply_seq_move("X", move, X, Y)
    for move in y_moves:
        apply_seq_move("Y", move, X, Y)
    return X, Y, current_metrics(X, Y, fixed)


def routing_gain(before_metrics, after_metrics, target_shifts):
    return int(target_l1(before_metrics, target_shifts) - target_l1(after_metrics, target_shifts))


def routing_damage(before_metrics, after_metrics, target_shifts, args):
    targets = set(int(s) for s in target_shifts)
    before_defects = [int(d) for d in before_metrics["defects"]]
    after_defects = [int(d) for d in after_metrics["defects"]]
    target_before = target_l1(before_metrics, target_shifts)
    target_after = target_l1(after_metrics, target_shifts)
    non_target_before = 0
    non_target_after = 0
    zero_damage = 0
    zero_damage_count = 0
    for idx, (before, after) in enumerate(zip(before_defects, after_defects), start=1):
        if idx not in targets:
            non_target_before += abs(before)
            non_target_after += abs(after)
        if before == 0 and after != 0:
            zero_damage += abs(after)
            zero_damage_count += 1
    non_target_increase = max(0, int(non_target_after) - int(non_target_before))
    maxabs_increase = max(0, int(after_metrics["max_abs_error"]) - int(before_metrics["max_abs_error"]))
    score_increase = max(0, int(after_metrics["score"]) - int(before_metrics["score"]))
    l1_increase = max(0, int(after_metrics["l1_error"]) - int(before_metrics["l1_error"]))
    target_gain = int(target_before) - int(target_after)
    net_gain = (
        int(target_gain)
        - int(args.non_target_damage_weight) * int(non_target_increase)
        - int(args.zero_damage_weight) * int(zero_damage)
        - int(args.maxabs_damage_weight) * int(maxabs_increase)
        - int(args.score_damage_weight) * int(score_increase)
        - int(args.l1_damage_weight) * int(l1_increase)
    )
    return {
        "target_l1_before": int(target_before),
        "target_l1_after": int(target_after),
        "target_gain": int(target_gain),
        "non_target_l1_before": int(non_target_before),
        "non_target_l1_after": int(non_target_after),
        "non_target_l1_increase": int(non_target_increase),
        "zero_shift_damage": int(zero_damage),
        "zero_shift_damage_count": int(zero_damage_count),
        "maxabs_increase": int(maxabs_increase),
        "score_increase": int(score_increase),
        "l1_increase": int(l1_increase),
        "net_routing_gain": int(net_gain),
    }


def cap_tuple(metrics, args, before_metrics):
    before_score = int(before_metrics["score"]) if before_metrics is not None else int(metrics["score"])
    before_l1 = int(before_metrics["l1_error"]) if before_metrics is not None else int(metrics["l1_error"])
    score_cap = before_score + int(args.score_slack)
    l1_cap = before_l1 + int(args.l1_slack)
    maxabs_cap = int(args.maxabs_bound)
    violation = (
        max(0, int(metrics["score"]) - score_cap)
        + max(0, int(metrics["l1_error"]) - l1_cap)
        + 100 * max(0, int(metrics["max_abs_error"]) - maxabs_cap)
    )
    return int(violation), int(score_cap), int(l1_cap), int(maxabs_cap)


def score_tuple(metrics, objective, target_shifts, before_metrics=None, args=None):
    gain = routing_gain(before_metrics, metrics, target_shifts) if before_metrics is not None else 0
    damage = routing_damage(before_metrics, metrics, target_shifts, args) if before_metrics is not None and args is not None else None
    if objective == "score":
        return (
            int(metrics["score"]),
            int(metrics["l1_error"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_defect_count"]),
            int(target_l1(metrics, target_shifts)),
        )
    if objective == "pq_target_then_score":
        return (
            int(target_l1(metrics, target_shifts)),
            int(metrics["score"]),
            int(metrics["l1_error"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_defect_count"]),
        )
    if objective == "pq_routing_then_score":
        return (
            -int(gain),
            int(target_l1(metrics, target_shifts)),
            int(metrics["score"]),
            int(metrics["l1_error"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_defect_count"]),
        )
    if objective == "net_pq_routing_then_score":
        return (
            -int(damage["net_routing_gain"]),
            int(damage["non_target_l1_increase"]),
            int(damage["zero_shift_damage"]),
            int(damage["maxabs_increase"]),
            int(metrics["score"]),
            int(metrics["l1_error"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_defect_count"]),
            int(target_l1(metrics, target_shifts)),
        )
    if objective == "capped_pq_target_then_score":
        violation, _, _, _ = cap_tuple(metrics, args, before_metrics)
        if violation <= 0:
            return (
                0,
                int(target_l1(metrics, target_shifts)),
                int(metrics["score"]),
                int(metrics["l1_error"]),
                int(metrics["max_abs_error"]),
                int(metrics["nonzero_defect_count"]),
            )
        return (
            1,
            int(args.cap_penalty) + int(violation),
            int(metrics["score"]),
            int(metrics["l1_error"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_defect_count"]),
            int(target_l1(metrics, target_shifts)),
        )
    if objective == "capped_pq_routing_then_score":
        violation, _, _, _ = cap_tuple(metrics, args, before_metrics)
        if violation <= 0:
            return (
                0,
                -int(gain),
                int(target_l1(metrics, target_shifts)),
                int(metrics["score"]),
                int(metrics["l1_error"]),
                int(metrics["max_abs_error"]),
                int(metrics["nonzero_defect_count"]),
            )
        return (
            1,
            int(args.cap_penalty) + int(violation),
            int(metrics["score"]),
            int(metrics["l1_error"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_defect_count"]),
            int(target_l1(metrics, target_shifts)),
        )
    if objective == "capped_net_pq_routing_then_score":
        violation, _, _, _ = cap_tuple(metrics, args, before_metrics)
        if violation <= 0:
            return (
                0,
                -int(damage["net_routing_gain"]),
                int(damage["non_target_l1_increase"]),
                int(damage["zero_shift_damage"]),
                int(damage["maxabs_increase"]),
                int(metrics["score"]),
                int(metrics["l1_error"]),
                int(metrics["max_abs_error"]),
                int(metrics["nonzero_defect_count"]),
                int(target_l1(metrics, target_shifts)),
            )
        return (
            1,
            int(args.cap_penalty) + int(violation),
            -int(damage["net_routing_gain"]),
            int(metrics["score"]),
            int(metrics["l1_error"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_defect_count"]),
            int(target_l1(metrics, target_shifts)),
        )
    if objective == "l1":
        return (
            int(metrics["l1_error"]),
            int(metrics["score"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_defect_count"]),
            int(target_l1(metrics, target_shifts)),
        )
    if objective == "max_abs":
        return (
            int(metrics["max_abs_error"]),
            int(metrics["l1_error"]),
            int(metrics["score"]),
            int(metrics["nonzero_defect_count"]),
            int(target_l1(metrics, target_shifts)),
        )
    raise ValueError("unknown objective {}".format(objective))


def compatible(existing_moves, move):
    used = set()
    for m in existing_moves:
        used.add(int(m[0]))
        used.add(int(m[1]))
    return int(move[0]) not in used and int(move[1]) not in used


def generate_atomic_flips(which, X, Y, fixed, base_metrics, target_shifts, args):
    P, Q = pq_from_xy(X, Y)
    plus, minus = selected_positions(which, X, Y, P, Q, base_metrics, target_shifts, args.position_pool)
    scored = []
    seen = set()
    for i in plus:
        for j in minus:
            move = (int(i), int(j))
            if move in seen:
                continue
            seen.add(move)
            if which == "X":
                _, _, metrics = evaluate_moves(X, Y, [move], [], fixed)
            else:
                _, _, metrics = evaluate_moves(X, Y, [], [move], fixed)
            key = score_tuple(metrics, args.atomic_objective, target_shifts, base_metrics, args)
            scored.append((key, move, metrics))
    if int(args.random_flips) > 0:
        seq = X if which == "X" else Y
        plus_all = [i for i, x in enumerate(seq) if int(x) == 1]
        minus_all = [i for i, x in enumerate(seq) if int(x) == -1]
        for _ in range(int(args.random_flips)):
            move = (int(random.choice(plus_all)), int(random.choice(minus_all)))
            if move in seen:
                continue
            seen.add(move)
            if which == "X":
                _, _, metrics = evaluate_moves(X, Y, [move], [], fixed)
            else:
                _, _, metrics = evaluate_moves(X, Y, [], [move], fixed)
            key = score_tuple(metrics, args.atomic_objective, target_shifts, base_metrics, args)
            scored.append((key, move, metrics))
    scored.sort(key=lambda row: row[0])
    return [move for _, move, _ in scored[: max(1, int(args.atomic_pool))]], scored[: min(10, len(scored))]


def run_pattern(pattern, X, Y, fixed, x_atoms, y_atoms, target_shifts, args, initial_metrics):
    beam = [{"x_moves": [], "y_moves": [], "metrics": initial_metrics, "key": None}]
    checked = 0
    for letter in pattern:
        next_beam = []
        atoms = x_atoms if letter == "X" else y_atoms
        for state in beam:
            existing = state["x_moves"] if letter == "X" else state["y_moves"]
            for move in atoms:
                if not compatible(existing, move):
                    continue
                x_moves = list(state["x_moves"])
                y_moves = list(state["y_moves"])
                if letter == "X":
                    x_moves.append(move)
                else:
                    y_moves.append(move)
                _, _, metrics = evaluate_moves(X, Y, x_moves, y_moves, fixed)
                key = score_tuple(metrics, args.objective, target_shifts, initial_metrics, args)
                checked += 1
                next_beam.append({"x_moves": x_moves, "y_moves": y_moves, "metrics": metrics, "key": key})
        next_beam.sort(key=lambda row: row["key"])
        beam = next_beam[: max(1, int(args.beam_width))]
        if not beam:
            break
    if not beam:
        return None, checked
    return beam[0], checked


def verify_turyn_type(X, Y, Z, W):
    n = len(X)
    defects = []
    for s in range(1, n):
        value = autocorrelation(X, s) + autocorrelation(Y, s) + 2 * autocorrelation(Z, s) + 2 * autocorrelation(W, s)
        if value != 0:
            defects.append((int(s), int(value)))
    return len(defects) == 0, defects


def endpoint_signature(seq, width):
    width = int(width)
    return "".join("+" if int(x) > 0 else "-" for x in (list(seq[:width]) + list(seq[-width:])))


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


def save_result(path, input_path, X, Y, Z, W, before_metrics, metrics, args, target_shifts, pattern_results, atomic_preview):
    turyn_ok, defects = verify_turyn_type(X, Y, Z, W)
    payload = {
        "script": SCRIPT_NAME,
        "classification": "pq_channel_routing_repair",
        "input_completion_path": input_path,
        "n": int(args.n),
        "target_order": int(4 * (3 * int(args.n) - 1)),
        "tuple": [int(x) for x in args.tuple_value],
        "X": [int(x) for x in X],
        "Y": [int(x) for x in Y],
        "Z": [int(x) for x in Z],
        "W": [int(x) for x in W],
        "x_sum": int(sum(X)),
        "y_sum": int(sum(Y)),
        "z_sum": int(sum(Z)),
        "w_sum": int(sum(W)),
        "score": int(metrics["score"]),
        "l1_error": int(metrics["l1_error"]),
        "max_abs_error": int(metrics["max_abs_error"]),
        "nonzero_defect_count": int(metrics["nonzero_defect_count"]),
        "defects": [int(d) for d in metrics["defects"]],
        "target_shifts": [int(s) for s in target_shifts],
        "target_l1": int(target_l1(metrics, target_shifts)),
        "patterns": args.patterns,
        "pattern_results": pattern_results,
        "objective": args.objective,
        "atomic_objective": args.atomic_objective,
        "position_pool": int(args.position_pool),
        "atomic_pool": int(args.atomic_pool),
        "beam_width": int(args.beam_width),
        "score_slack": int(args.score_slack),
        "l1_slack": int(args.l1_slack),
        "maxabs_bound": int(args.maxabs_bound),
        "cap_penalty": int(args.cap_penalty),
        "damage_weights": {
            "non_target_damage_weight": int(args.non_target_damage_weight),
            "zero_damage_weight": int(args.zero_damage_weight),
            "maxabs_damage_weight": int(args.maxabs_damage_weight),
            "score_damage_weight": int(args.score_damage_weight),
            "l1_damage_weight": int(args.l1_damage_weight),
        },
        "routing_damage": routing_damage(before_metrics, metrics, target_shifts, args),
        "pq_support": pq_support_summary(X, Y),
        "atomic_preview": atomic_preview,
        "turyn_ok": bool(turyn_ok),
        "turyn_bad_shifts": defects[:100],
        "t_sequences_ok": False,
        "hadamard_ok": False,
        "generated_order": None,
        "endpoint_width": int(args.endpoint_width),
        "x_signature": endpoint_signature(X, args.endpoint_width),
        "y_signature": endpoint_signature(Y, args.endpoint_width),
        "notes": [
            "This is a P/Q channel-routing repair attempt for fixed Z/W X/Y completion.",
            "It is not a Hadamard construction unless exact Turyn, T-sequence, and HH^T checks pass.",
        ],
    }
    write_json(path, payload)
    return payload


def load_completion(path, args):
    with open(path) as f:
        data = json.load(f)
    for key in ["X", "Y", "Z", "W"]:
        if key not in data:
            raise ValueError("{} missing from {}".format(key, path))
    X = [int(x) for x in data["X"]]
    Y = [int(x) for x in data["Y"]]
    Z = [int(x) for x in data["Z"]]
    W = [int(x) for x in data["W"]]
    tuple_value = tuple(int(x) for x in data.get("tuple", args.tuple_value))
    if tuple_value != args.tuple_value:
        raise ValueError("input tuple {} != requested tuple {}".format(tuple_value, args.tuple_value))
    if len(X) != int(args.n) or len(Y) != int(args.n) or len(Z) != int(args.n) or len(W) != int(args.n) - 1:
        raise ValueError("input lengths incompatible with n={}".format(args.n))
    sums = (sum(X), sum(Y), sum(Z), sum(W))
    if tuple(int(x) for x in sums) != args.tuple_value:
        raise ValueError("input sums {} != tuple {}".format(sums, args.tuple_value))
    return X, Y, Z, W


def parse_args():
    parser = argparse.ArgumentParser(description="P/Q channel-routing beam repair for fixed-Z/W X/Y completion.")
    parser.add_argument("completion_json")
    parser.add_argument("--n", type=int, default=56)
    parser.add_argument("--tuple", default="0,-18,-2,1")
    parser.add_argument(
        "--objective",
        choices=[
            "score",
            "pq_target_then_score",
            "pq_routing_then_score",
            "net_pq_routing_then_score",
            "capped_pq_target_then_score",
            "capped_pq_routing_then_score",
            "capped_net_pq_routing_then_score",
            "l1",
            "max_abs",
        ],
        default="pq_target_then_score",
    )
    parser.add_argument(
        "--atomic-objective",
        choices=[
            "score",
            "pq_target_then_score",
            "pq_routing_then_score",
            "net_pq_routing_then_score",
            "capped_pq_target_then_score",
            "capped_pq_routing_then_score",
            "capped_net_pq_routing_then_score",
            "l1",
            "max_abs",
        ],
        default="pq_routing_then_score",
    )
    parser.add_argument("--target-shifts", default="")
    parser.add_argument("--target-count", type=int, default=9)
    parser.add_argument("--patterns", default="XXY,XYY,XXYY,XYXY")
    parser.add_argument("--position-pool", type=int, default=0)
    parser.add_argument("--atomic-pool", type=int, default=200)
    parser.add_argument("--beam-width", type=int, default=200)
    parser.add_argument("--score-slack", type=int, default=80)
    parser.add_argument("--l1-slack", type=int, default=30)
    parser.add_argument("--maxabs-bound", type=int, default=8)
    parser.add_argument("--cap-penalty", type=int, default=10000)
    parser.add_argument("--non-target-damage-weight", type=int, default=2)
    parser.add_argument("--zero-damage-weight", type=int, default=4)
    parser.add_argument("--maxabs-damage-weight", type=int, default=20)
    parser.add_argument("--score-damage-weight", type=int, default=0)
    parser.add_argument("--l1-damage-weight", type=int, default=0)
    parser.add_argument("--random-flips", type=int, default=0)
    parser.add_argument("--endpoint-width", type=int, default=6)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--out-prefix", default="outputs/turyn/pq_channel_routing_repair")
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
        X, Y, Z, W = load_completion(args.completion_json, args)
        fixed = fixed_zw_vector(Z, W, args.n)
        initial_metrics = current_metrics(X, Y, fixed)
        explicit_shifts = parse_shift_list(args.target_shifts)
        target_shifts = target_shifts_from_metrics(initial_metrics, explicit_shifts, args.target_count)
        initial_key = score_tuple(initial_metrics, args.objective, target_shifts, initial_metrics, args)
        print("input:", args.completion_json)
        print(
            "initial score={} l1={} max_abs={} nonzero={} target_l1={} targets={}".format(
                initial_metrics["score"],
                initial_metrics["l1_error"],
                initial_metrics["max_abs_error"],
                initial_metrics["nonzero_defect_count"],
                target_l1(initial_metrics, target_shifts),
                target_shifts,
            )
        )
        print("pq support:", pq_support_summary(X, Y))
        x_atoms, x_preview = generate_atomic_flips("X", X, Y, fixed, initial_metrics, target_shifts, args)
        y_atoms, y_preview = generate_atomic_flips("Y", X, Y, fixed, initial_metrics, target_shifts, args)
        atomic_preview = {
            "X": [{"key": list(row[0]), "move": list(row[1])} for row in x_preview],
            "Y": [{"key": list(row[0]), "move": list(row[1])} for row in y_preview],
        }
        print("atomic flips: X={} Y={}".format(len(x_atoms), len(y_atoms)))
        csv_path = args.csv or os.path.join("outputs/logs", "{}_{}.csv".format(SCRIPT_NAME, stamp))
        os.makedirs(os.path.dirname(csv_path) or ".", exist_ok=True)
        csv_file = open(csv_path, "w", newline="")
        writer = csv.DictWriter(
            csv_file,
            fieldnames=[
                "pattern",
                "checked",
                "score",
                "l1_error",
                "max_abs_error",
                "nonzero_defect_count",
                "target_l1",
                "x_moves",
                "y_moves",
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
            result, checked = run_pattern(pattern, X, Y, fixed, x_atoms, y_atoms, target_shifts, args, initial_metrics)
            if result is None:
                continue
            metrics = result["metrics"]
            key = result["key"]
            improved = key < initial_key
            item = {
                "pattern": pattern,
                "checked": int(checked),
                "score": int(metrics["score"]),
                "l1_error": int(metrics["l1_error"]),
                "max_abs_error": int(metrics["max_abs_error"]),
                "nonzero_defect_count": int(metrics["nonzero_defect_count"]),
                "target_l1": int(target_l1(metrics, target_shifts)),
                "routing_damage": routing_damage(initial_metrics, metrics, target_shifts, args),
                "x_moves": [list(m) for m in result["x_moves"]],
                "y_moves": [list(m) for m in result["y_moves"]],
                "improved": bool(improved),
            }
            pattern_results.append(item)
            writer.writerow(
                {
                    "pattern": pattern,
                    "checked": int(checked),
                    "score": int(metrics["score"]),
                    "l1_error": int(metrics["l1_error"]),
                    "max_abs_error": int(metrics["max_abs_error"]),
                    "nonzero_defect_count": int(metrics["nonzero_defect_count"]),
                    "target_l1": int(target_l1(metrics, target_shifts)),
                    "x_moves": item["x_moves"],
                    "y_moves": item["y_moves"],
                    "improved": bool(improved),
                    "elapsed_sec": round(time.time() - start, 3),
                }
            )
            csv_file.flush()
            print(
                "pattern={} checked={} score={} l1={} max_abs={} nonzero={} target_l1={} improved={}".format(
                    pattern,
                    checked,
                    metrics["score"],
                    metrics["l1_error"],
                    metrics["max_abs_error"],
                    metrics["nonzero_defect_count"],
                    target_l1(metrics, target_shifts),
                    improved,
                )
            )
            if best_state is None or key < best_key:
                best_state = result
                best_key = key
        if best_state is None or best_key >= initial_key:
            best_X = list(X)
            best_Y = list(Y)
            best_metrics = initial_metrics
        else:
            best_X, best_Y, best_metrics = evaluate_moves(
                X,
                Y,
                best_state["x_moves"],
                best_state["y_moves"],
                fixed,
            )
        out_path = "{}_score{}.json".format(args.out_prefix, int(best_metrics["score"]))
        payload = save_result(
            out_path,
            args.completion_json,
            best_X,
            best_Y,
            Z,
            W,
            initial_metrics,
            best_metrics,
            args,
            target_shifts,
            pattern_results,
            atomic_preview,
        )
        print("FINAL_BEST:", out_path)
        print(
            "best score={} l1={} max_abs={} nonzero={} target_l1={} turyn_ok={} hadamard_ok={}".format(
                payload["score"],
                payload["l1_error"],
                payload["max_abs_error"],
                payload["nonzero_defect_count"],
                payload["target_l1"],
                payload["turyn_ok"],
                payload["hadamard_ok"],
            )
        )
    finally:
        if csv_file is not None:
            csv_file.close()
        tee.close()


if __name__ == "__main__":
    main()
