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


SCRIPT_NAME = "37_fixed_zw_xy_completion"


def parse_tuple(text):
    parts = [int(x) for x in text.split(",")]
    if len(parts) != 4:
        raise ValueError("--tuple must be x,y,z,w")
    return tuple(parts)


def random_pm1_with_sum(length, target_sum):
    length = int(length)
    target_sum = int(target_sum)
    if (length + target_sum) % 2 != 0:
        raise ValueError("length and target sum have different parity")
    plus_count = (length + target_sum) // 2
    if plus_count < 0 or plus_count > length:
        raise ValueError("target sum {} impossible for length {}".format(target_sum, length))
    seq = [1] * plus_count + [-1] * (length - plus_count)
    random.shuffle(seq)
    return seq


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


def score_tuple(metrics, objective):
    if objective == "score":
        return (
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
    if objective == "nonzero":
        return (
            int(metrics["nonzero_defect_count"]),
            int(metrics["l1_error"]),
            int(metrics["max_abs_error"]),
            int(metrics["score"]),
        )
    raise ValueError("unknown objective {}".format(objective))


def random_balanced_flip(seq):
    plus = [i for i, x in enumerate(seq) if int(x) == 1]
    minus = [i for i, x in enumerate(seq) if int(x) == -1]
    if not plus or not minus:
        return None
    return int(random.choice(plus)), int(random.choice(minus))


def apply_flip(seq, i, j):
    if int(seq[i]) == int(seq[j]):
        raise ValueError("balanced flip needs opposite signs")
    seq[i] = -int(seq[i])
    seq[j] = -int(seq[j])


def random_move(X, Y):
    which = "X" if random.random() < 0.5 else "Y"
    flip = random_balanced_flip(X if which == "X" else Y)
    if flip is None:
        return None
    return which, flip[0], flip[1]


def affected_shift_pressure(seq, defects, pos):
    # Heuristic: positions participating in large-defect shifts get higher pressure.
    n = len(seq)
    total = 0
    for s, d in enumerate(defects, start=1):
        if d == 0:
            continue
        if pos + s < n:
            total += abs(int(d))
        if pos - s >= 0:
            total += abs(int(d))
    return int(total)


def targeted_move(X, Y, metrics, position_pool):
    defects = metrics["defects"]
    which = "X" if random.random() < 0.5 else "Y"
    seq = X if which == "X" else Y
    plus = []
    minus = []
    for pos, value in enumerate(seq):
        item = (affected_shift_pressure(seq, defects, pos), int(pos))
        if int(value) == 1:
            plus.append(item)
        else:
            minus.append(item)
    plus.sort(key=lambda x: x[0], reverse=True)
    minus.sort(key=lambda x: x[0], reverse=True)
    limit = max(1, int(position_pool))
    plus = plus[:limit]
    minus = minus[:limit]
    if not plus or not minus:
        return random_move(X, Y)
    window_p = max(1, min(len(plus), int(math.sqrt(len(plus))) + 2))
    window_m = max(1, min(len(minus), int(math.sqrt(len(minus))) + 2))
    return which, int(random.choice(plus[:window_p])[1]), int(random.choice(minus[:window_m])[1])


def propose_move(X, Y, metrics, args):
    if args.move_mode == "random":
        return random_move(X, Y), "random"
    if args.move_mode == "targeted":
        return targeted_move(X, Y, metrics, args.position_pool), "targeted"
    if args.move_mode == "mixed":
        if random.random() < float(args.targeted_prob):
            return targeted_move(X, Y, metrics, args.position_pool), "targeted"
        return random_move(X, Y), "random"
    raise ValueError("unknown move_mode {}".format(args.move_mode))


def apply_move(move, X, Y):
    which, i, j = move
    if which == "X":
        apply_flip(X, i, j)
    else:
        apply_flip(Y, i, j)


def undo_move(move, X, Y):
    apply_move(move, X, Y)


def choose_move(X, Y, fixed, metrics, args):
    best = None
    best_metrics = None
    best_key = None
    best_source = ""
    for _ in range(max(1, int(args.candidate_trials))):
        move, source = propose_move(X, Y, metrics, args)
        if move is None:
            continue
        apply_move(move, X, Y)
        cand_metrics = current_metrics(X, Y, fixed)
        key = score_tuple(cand_metrics, args.objective)
        undo_move(move, X, Y)
        if best is None or key < best_key:
            best = move
            best_metrics = cand_metrics
            best_key = key
            best_source = source
    return best, best_metrics, best_key, best_source


def temperature(step, steps, start, minimum):
    progress = float(step) / float(max(1, int(steps)))
    return max(float(minimum), float(start) * (1.0 - progress))


def accept(cur_key, new_key, step, args):
    if new_key <= cur_key:
        return True
    if args.strategy == "greedy":
        return False
    temp = temperature(step, args.steps, args.temperature, args.min_temperature)
    if temp <= 0:
        return False
    delta = float(new_key[0] - cur_key[0])
    return random.random() < math.exp(-max(0.0, delta) / temp)


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


def save_candidate(path, input_path, X, Y, Z, W, metrics, args, step, source):
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
        "classification": "fixed_zw_xy_completion_candidate",
        "input_zw_path": input_path,
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
        "turyn_ok": bool(turyn_ok),
        "turyn_bad_shifts": defects[:100],
        "t_sequences_ok": bool(t_ok),
        "hadamard_ok": bool(h_ok),
        "generated_order": generated_order,
        "step": int(step),
        "source": source,
        "objective": args.objective,
        "move_mode": args.move_mode,
        "targeted_prob": float(args.targeted_prob),
        "endpoint_width": int(args.endpoint_width),
        "x_signature": endpoint_signature(X, args.endpoint_width),
        "y_signature": endpoint_signature(Y, args.endpoint_width),
        "notes": [
            "This is an X/Y completion attempt for a fixed repaired Z/W pair.",
            "It is not a Hadamard construction unless turyn_ok, t_sequences_ok, and hadamard_ok are all true.",
        ],
    }
    write_json(path, payload)
    return payload


def load_zw(path, args):
    with open(path) as f:
        data = json.load(f)
    Z = [int(x) for x in data["Z"]]
    W = [int(x) for x in data["W"]]
    tuple_value = tuple(int(x) for x in data.get("tuple", args.tuple_value))
    if tuple_value != args.tuple_value:
        raise ValueError("input tuple {} != requested tuple {}".format(tuple_value, args.tuple_value))
    if len(Z) != int(args.n) or len(W) != int(args.n) - 1:
        raise ValueError("input Z/W lengths incompatible with n={}".format(args.n))
    if sum(Z) != args.tuple_value[2] or sum(W) != args.tuple_value[3]:
        raise ValueError("input Z/W sums incompatible with tuple {}".format(args.tuple_value))
    return Z, W


def load_xy(path, args):
    with open(path) as f:
        data = json.load(f)
    if "X" not in data or "Y" not in data:
        raise ValueError("resume X/Y JSON must contain X and Y")
    X = [int(x) for x in data["X"]]
    Y = [int(x) for x in data["Y"]]
    if len(X) != int(args.n) or len(Y) != int(args.n):
        raise ValueError("resume X/Y lengths incompatible with n={}".format(args.n))
    if sum(X) != args.tuple_value[0] or sum(Y) != args.tuple_value[1]:
        raise ValueError("resume X/Y sums incompatible with tuple {}".format(args.tuple_value))
    return X, Y


def parse_args():
    parser = argparse.ArgumentParser(description="Search X/Y completion for a fixed repaired Z/W Turyn pair.")
    parser.add_argument("zw_json")
    parser.add_argument("--resume-xy-json", default="")
    parser.add_argument("--n", type=int, default=56)
    parser.add_argument("--tuple", default="0,-18,-2,1")
    parser.add_argument("--steps", type=int, default=20000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--candidate-trials", type=int, default=64)
    parser.add_argument("--objective", choices=["score", "l1", "max_abs", "nonzero"], default="score")
    parser.add_argument("--strategy", choices=["greedy", "anneal"], default="anneal")
    parser.add_argument("--temperature", type=float, default=5.0)
    parser.add_argument("--min-temperature", type=float, default=0.01)
    parser.add_argument("--restart-patience", type=int, default=5000)
    parser.add_argument("--shake-rate", type=float, default=0.05)
    parser.add_argument("--move-mode", choices=["random", "targeted", "mixed"], default="mixed")
    parser.add_argument("--targeted-prob", type=float, default=0.7)
    parser.add_argument("--position-pool", type=int, default=24)
    parser.add_argument("--endpoint-width", type=int, default=6)
    parser.add_argument("--save-improvements", action="store_true")
    parser.add_argument("--verify-hadamard-on-success", action="store_true")
    parser.add_argument("--out-prefix", default="outputs/turyn/fixed_zw_xy_completion")
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
        Z, W = load_zw(args.zw_json, args)
        x_sum, y_sum, z_sum, w_sum = args.tuple_value
        fixed = fixed_zw_vector(Z, W, args.n)
        if args.resume_xy_json:
            X, Y = load_xy(args.resume_xy_json, args)
        else:
            X = random_pm1_with_sum(args.n, x_sum)
            Y = random_pm1_with_sum(args.n, y_sum)
        metrics = current_metrics(X, Y, fixed)
        cur_key = score_tuple(metrics, args.objective)
        best_X = list(X)
        best_Y = list(Y)
        best_metrics = dict(metrics)
        best_key = cur_key
        best_step = 0
        last_improvement = 0
        plateau_count = 0
        start = time.time()
        csv_path = args.csv or os.path.join("outputs/logs", "{}_{}.csv".format(SCRIPT_NAME, stamp))
        os.makedirs(os.path.dirname(csv_path) or ".", exist_ok=True)
        csv_file = open(csv_path, "w", newline="")
        writer = csv.DictWriter(
            csv_file,
            fieldnames=[
                "step",
                "score",
                "l1_error",
                "max_abs_error",
                "nonzero_defect_count",
                "best_score",
                "best_l1_error",
                "best_max_abs_error",
                "best_nonzero_defect_count",
                "accepted",
                "improved",
                "move_source",
                "plateau_count",
                "elapsed_sec",
            ],
        )
        writer.writeheader()
        print("fixed Z/W:", args.zw_json)
        if args.resume_xy_json:
            print("resume X/Y:", args.resume_xy_json)
        print("tuple={} x_sum={} y_sum={} z_sum={} w_sum={}".format(args.tuple_value, x_sum, y_sum, z_sum, w_sum))
        print(
            "initial score={} l1={} max_abs={} nonzero={}".format(
                metrics["score"], metrics["l1_error"], metrics["max_abs_error"], metrics["nonzero_defect_count"]
            )
        )
        for step in range(1, int(args.steps) + 1):
            move, new_metrics, new_key, source = choose_move(X, Y, fixed, metrics, args)
            accepted = False
            improved = False
            if move is not None and accept(cur_key, new_key, step, args):
                apply_move(move, X, Y)
                metrics = new_metrics
                cur_key = new_key
                accepted = True
            if cur_key < best_key:
                best_X = list(X)
                best_Y = list(Y)
                best_metrics = dict(metrics)
                best_key = cur_key
                best_step = step
                last_improvement = step
                improved = True
                print(
                    "BEST step={} score={} l1={} max_abs={} nonzero={}".format(
                        step,
                        best_metrics["score"],
                        best_metrics["l1_error"],
                        best_metrics["max_abs_error"],
                        best_metrics["nonzero_defect_count"],
                    )
                )
                if args.save_improvements:
                    path = "{}_seed{}_step{}_score{}.json".format(
                        args.out_prefix, int(args.seed), int(best_step), int(best_metrics["score"])
                    )
                    save_candidate(path, args.zw_json, best_X, best_Y, Z, W, best_metrics, args, best_step, "improvement")
                    print("saved:", path)
                sys.stdout.flush()
            if args.restart_patience > 0 and step - last_improvement >= int(args.restart_patience):
                flips = max(1, int((len(X) + len(Y)) * float(args.shake_rate)))
                for _ in range(flips):
                    move = random_move(X, Y)
                    if move is not None:
                        apply_move(move, X, Y)
                metrics = current_metrics(X, Y, fixed)
                cur_key = score_tuple(metrics, args.objective)
                plateau_count += 1
                last_improvement = step
                print(
                    "PLATEAU_SHAKE step={} count={} flips={} score={} l1={}".format(
                        step, plateau_count, flips, metrics["score"], metrics["l1_error"]
                    )
                )
                sys.stdout.flush()
            if improved or step % 1000 == 0 or step == int(args.steps):
                writer.writerow(
                    {
                        "step": int(step),
                        "score": int(metrics["score"]),
                        "l1_error": int(metrics["l1_error"]),
                        "max_abs_error": int(metrics["max_abs_error"]),
                        "nonzero_defect_count": int(metrics["nonzero_defect_count"]),
                        "best_score": int(best_metrics["score"]),
                        "best_l1_error": int(best_metrics["l1_error"]),
                        "best_max_abs_error": int(best_metrics["max_abs_error"]),
                        "best_nonzero_defect_count": int(best_metrics["nonzero_defect_count"]),
                        "accepted": bool(accepted),
                        "improved": bool(improved),
                        "move_source": source,
                        "plateau_count": int(plateau_count),
                        "elapsed_sec": round(time.time() - start, 3),
                    }
                )
                csv_file.flush()
                if step % 1000 == 0 or step == int(args.steps):
                    print(
                        "step={} cur_score={} best_score={} best_l1={} best_max={} elapsed={:.1f}s".format(
                            step,
                            metrics["score"],
                            best_metrics["score"],
                            best_metrics["l1_error"],
                            best_metrics["max_abs_error"],
                            time.time() - start,
                        )
                    )
                    sys.stdout.flush()
            if best_metrics["score"] == 0:
                print("TURYN_AUTOCORRELATION_PASSED step={}".format(best_step))
                break
        final_path = "{}_seed{}_step{}_score{}.json".format(
            args.out_prefix, int(args.seed), int(best_step), int(best_metrics["score"])
        )
        payload = save_candidate(final_path, args.zw_json, best_X, best_Y, Z, W, best_metrics, args, best_step, "final_best")
        print("FINAL_BEST:", final_path)
        print(
            "best score={} l1={} max_abs={} nonzero={} turyn_ok={} hadamard_ok={}".format(
                best_metrics["score"],
                best_metrics["l1_error"],
                best_metrics["max_abs_error"],
                best_metrics["nonzero_defect_count"],
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
