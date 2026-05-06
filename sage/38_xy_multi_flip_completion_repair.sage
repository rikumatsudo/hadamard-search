from sage.all import *

import argparse
import csv
import json
import math
import os
import random
import time

from sds_repair_utils import setup_logging, write_json


SCRIPT_NAME = "38_xy_multi_flip_completion_repair"


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
    score = int(sum(int(d) * int(d) for d in defects))
    l1 = int(sum(abs(int(d)) for d in defects))
    max_abs = int(max(abs(int(d)) for d in defects)) if defects else 0
    nonzero = int(sum(1 for d in defects if int(d) != 0))
    return {
        "score": score,
        "l1_error": l1,
        "max_abs_error": max_abs,
        "nonzero_defect_count": nonzero,
        "defects": [int(d) for d in defects],
    }


def current_metrics(X, Y, fixed):
    return defect_metrics(xy_defects(X, Y, fixed))


def target_shifts_from_metrics(metrics, explicit, target_count):
    if explicit:
        return [int(s) for s in explicit]
    rows = [(i + 1, int(d)) for i, d in enumerate(metrics["defects"]) if int(d) != 0]
    rows.sort(key=lambda row: (-abs(row[1]), row[0]))
    return [s for s, _ in rows[: max(1, int(target_count))]]


def target_l1(metrics, target_shifts):
    return int(sum(abs(int(metrics["defects"][s - 1])) for s in target_shifts))


def score_tuple(metrics, objective, target_shifts):
    if objective == "score":
        return (
            int(metrics["score"]),
            int(metrics["l1_error"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_defect_count"]),
        )
    if objective == "target_then_score":
        return (
            target_l1(metrics, target_shifts),
            int(metrics["score"]),
            int(metrics["l1_error"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_defect_count"]),
        )
    if objective == "l1":
        return (
            int(metrics["l1_error"]),
            int(metrics["score"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_defect_count"]),
        )
    if objective == "max_abs":
        return (
            int(metrics["max_abs_error"]),
            int(metrics["l1_error"]),
            int(metrics["score"]),
            int(metrics["nonzero_defect_count"]),
        )
    raise ValueError("unknown objective {}".format(objective))


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


def position_pressure(seq, defects, target_shifts, pos):
    n = len(seq)
    total = 0
    shifts = target_shifts if target_shifts else range(1, n)
    for s in shifts:
        d = int(defects[int(s) - 1])
        if d == 0:
            continue
        if pos + s < n:
            total += abs(d)
        if pos - s >= 0:
            total += abs(d)
    return int(total)


def selected_positions(seq, metrics, target_shifts, position_pool):
    defects = metrics["defects"]
    plus = []
    minus = []
    for pos, value in enumerate(seq):
        item = (position_pressure(seq, defects, target_shifts, pos), int(pos))
        if int(value) == 1:
            plus.append(item)
        else:
            minus.append(item)
    plus.sort(key=lambda x: x[0], reverse=True)
    minus.sort(key=lambda x: x[0], reverse=True)
    if int(position_pool) <= 0:
        return [p for _, p in plus], [p for _, p in minus]
    return [p for _, p in plus[: int(position_pool)]], [p for _, p in minus[: int(position_pool)]]


def compatible(existing_moves, move):
    used = set()
    for m in existing_moves:
        used.add(int(m[0]))
        used.add(int(m[1]))
    return int(move[0]) not in used and int(move[1]) not in used


def generate_atomic_flips(which, X, Y, fixed, base_metrics, target_shifts, args):
    seq = X if which == "X" else Y
    plus, minus = selected_positions(seq, base_metrics, target_shifts, args.position_pool)
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
            key = score_tuple(metrics, args.atomic_objective, target_shifts)
            scored.append((key, move))
    if int(args.random_flips) > 0:
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
            key = score_tuple(metrics, args.atomic_objective, target_shifts)
            scored.append((key, move))
    scored.sort(key=lambda x: x[0])
    return [move for _, move in scored[: max(1, int(args.atomic_pool))]]


def run_pattern(pattern, X, Y, fixed, x_atoms, y_atoms, target_shifts, args):
    beam = [{"x_moves": [], "y_moves": [], "metrics": None, "key": None}]
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
                key = score_tuple(metrics, args.objective, target_shifts)
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


def sequence_circulant(seq):
    seq = [int(x) for x in seq]
    v = len(seq)
    return matrix(ZZ, v, v, lambda i, j: seq[(j - i) % v])


def back_identity(v):
    return matrix(ZZ, v, v, lambda i, j: 1 if i + j == v - 1 else 0)


def turyn_to_base_sequences(X, Y, Z, W):
    return list(Z) + list(W), list(Z) + [-int(w) for w in W], list(X), list(Y)


def base_to_t_sequences(A, B, C, D):
    left_len = len(A)
    right_len = len(C)
    T1 = [(int(a) + int(b)) // 2 for a, b in zip(A, B)] + [0] * right_len
    T2 = [(int(a) - int(b)) // 2 for a, b in zip(A, B)] + [0] * right_len
    T3 = [0] * left_len + [(int(c) + int(d)) // 2 for c, d in zip(C, D)]
    T4 = [0] * left_len + [(int(c) - int(d)) // 2 for c, d in zip(C, D)]
    return T1, T2, T3, T4


def verify_t_sequences(Ts):
    v = len(Ts[0])
    for T in Ts:
        if len(T) != v:
            return False
    for j in range(v):
        if sum(1 for T in Ts if int(T[j]) != 0) != 1:
            return False
    for s in range(1, v):
        if sum(autocorrelation(T, s) for T in Ts) != 0:
            return False
    return True


def goethals_seidel_from_t_sequences(T1, T2, T3, T4):
    mats = [sequence_circulant(T) for T in [T1, T2, T3, T4]]
    A1 = mats[0] + mats[1] + mats[2] + mats[3]
    A2 = -mats[0] + mats[1] + mats[2] - mats[3]
    A3 = -mats[0] - mats[1] + mats[2] + mats[3]
    A4 = -mats[0] + mats[1] - mats[2] + mats[3]
    v = A1.nrows()
    R = back_identity(v)
    return block_matrix(
        ZZ,
        [
            [A1, A2 * R, A3 * R, A4 * R],
            [-A2 * R, A1, A4.transpose() * R, -A3.transpose() * R],
            [-A3 * R, -A4.transpose() * R, A1, A2.transpose() * R],
            [-A4 * R, A3.transpose() * R, -A2.transpose() * R, A1],
        ],
        subdivide=False,
    )


def exact_hadamard_check(H):
    n = H.nrows()
    if H.ncols() != n:
        return False
    for x in H.list():
        if int(x) not in (-1, 1):
            return False
    return H * H.transpose() == n * identity_matrix(ZZ, n)


def endpoint_signature(seq, width):
    width = int(width)
    return "".join("+" if int(x) > 0 else "-" for x in (list(seq[:width]) + list(seq[-width:])))


def save_result(path, input_path, X, Y, Z, W, metrics, args, target_shifts, pattern_results):
    turyn_ok, defects = verify_turyn_type(X, Y, Z, W)
    t_ok = False
    h_ok = False
    generated_order = None
    if turyn_ok and args.verify_hadamard_on_success:
        A, B, C, D = turyn_to_base_sequences(X, Y, Z, W)
        Ts = base_to_t_sequences(A, B, C, D)
        t_ok = verify_t_sequences(Ts)
        if t_ok:
            H = goethals_seidel_from_t_sequences(*Ts)
            generated_order = int(H.nrows())
            h_ok = exact_hadamard_check(H)
    payload = {
        "script": SCRIPT_NAME,
        "classification": "xy_multi_flip_completion_repair",
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
        "patterns": args.patterns,
        "pattern_results": pattern_results,
        "objective": args.objective,
        "atomic_objective": args.atomic_objective,
        "position_pool": int(args.position_pool),
        "atomic_pool": int(args.atomic_pool),
        "beam_width": int(args.beam_width),
        "turyn_ok": bool(turyn_ok),
        "turyn_bad_shifts": defects[:100],
        "t_sequences_ok": bool(t_ok),
        "hadamard_ok": bool(h_ok),
        "generated_order": generated_order,
        "endpoint_width": int(args.endpoint_width),
        "x_signature": endpoint_signature(X, args.endpoint_width),
        "y_signature": endpoint_signature(Y, args.endpoint_width),
        "notes": [
            "This is an X/Y multi-flip repair attempt for a fixed repaired Z/W pair.",
            "It is not a Hadamard construction unless turyn_ok, t_sequences_ok, and hadamard_ok are all true.",
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
    parser = argparse.ArgumentParser(description="Beam multi-flip X/Y completion repair for fixed Z/W.")
    parser.add_argument("completion_json")
    parser.add_argument("--n", type=int, default=56)
    parser.add_argument("--tuple", default="0,-18,-2,1")
    parser.add_argument("--objective", choices=["score", "target_then_score", "l1", "max_abs"], default="score")
    parser.add_argument("--atomic-objective", choices=["score", "target_then_score", "l1", "max_abs"], default="target_then_score")
    parser.add_argument("--target-shifts", default="")
    parser.add_argument("--target-count", type=int, default=3)
    parser.add_argument("--patterns", default="XXY,XYY,XXYY")
    parser.add_argument("--position-pool", type=int, default=24)
    parser.add_argument("--atomic-pool", type=int, default=150)
    parser.add_argument("--beam-width", type=int, default=150)
    parser.add_argument("--random-flips", type=int, default=0)
    parser.add_argument("--endpoint-width", type=int, default=6)
    parser.add_argument("--verify-hadamard-on-success", action="store_true")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--out-prefix", default="outputs/turyn/xy_multi_flip_repair")
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
        initial_key = score_tuple(initial_metrics, args.objective, target_shifts)
        print("input:", args.completion_json)
        print(
            "initial score={} l1={} max_abs={} nonzero={} targets={}".format(
                initial_metrics["score"],
                initial_metrics["l1_error"],
                initial_metrics["max_abs_error"],
                initial_metrics["nonzero_defect_count"],
                target_shifts,
            )
        )
        x_atoms = generate_atomic_flips("X", X, Y, fixed, initial_metrics, target_shifts, args)
        y_atoms = generate_atomic_flips("Y", X, Y, fixed, initial_metrics, target_shifts, args)
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
            result, checked = run_pattern(pattern, X, Y, fixed, x_atoms, y_atoms, target_shifts, args)
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
                X, Y, best_state["x_moves"], best_state["y_moves"], fixed
            )
        final_path = "{}_score{}.json".format(args.out_prefix, int(best_metrics["score"]))
        payload = save_result(final_path, args.completion_json, best_X, best_Y, Z, W, best_metrics, args, target_shifts, pattern_results)
        print("FINAL_BEST:", final_path)
        print(
            "best score={} l1={} max_abs={} nonzero={} turyn_ok={} hadamard_ok={}".format(
                payload["score"],
                payload["l1_error"],
                payload["max_abs_error"],
                payload["nonzero_defect_count"],
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
