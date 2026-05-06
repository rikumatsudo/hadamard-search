from sage.all import *

import argparse
import json
import math
import os
import sys
import time

from sds_repair_utils import setup_logging, write_json


SCRIPT_NAME = "30_turyn_type_sequences"


def as_int_sequence(values, name):
    seq = [int(x) for x in values]
    bad = [x for x in seq if x not in (-1, 0, 1)]
    if bad:
        raise ValueError("{} contains entries outside -1,0,1".format(name))
    return seq


def require_pm1(seq, name):
    bad = [x for x in seq if int(x) not in (-1, 1)]
    if bad:
        raise ValueError("{} must be a +/-1 sequence".format(name))


def autocorrelation(seq, shift):
    shift = int(shift)
    if shift < 0:
        raise ValueError("shift must be nonnegative")
    if shift >= len(seq):
        return 0
    return int(sum(int(seq[i]) * int(seq[i + shift]) for i in range(len(seq) - shift)))


def autocorrelation_vector(seq):
    return [autocorrelation(seq, s) for s in range(len(seq))]


def hall_value(seq, theta):
    real = 0.0
    imag = 0.0
    for i, value in enumerate(seq):
        if value:
            angle = float(i) * float(theta)
            real += float(value) * math.cos(angle)
            imag += float(value) * math.sin(angle)
    return float(real * real + imag * imag)


def hall_grid_max(seq, grid):
    values = []
    for j in range(1, int(grid) + 1):
        theta = math.pi * float(j) / float(grid)
        values.append(hall_value(seq, theta))
    return float(max(values)) if values else 0.0


def turyn_rhs(n):
    return int(6 * int(n) - 2)


def hall_single_bound(n):
    # From fX + fY + 2 fZ + 2 fW = 6n - 2 and nonnegativity.
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


def verify_turyn_type(X, Y, Z, W, verbose=True):
    X = as_int_sequence(X, "X")
    Y = as_int_sequence(Y, "Y")
    Z = as_int_sequence(Z, "Z")
    W = as_int_sequence(W, "W")
    require_pm1(X, "X")
    require_pm1(Y, "Y")
    require_pm1(Z, "Z")
    require_pm1(W, "W")
    n = len(X)
    if len(Y) != n or len(Z) != n or len(W) != n - 1:
        raise ValueError("expected lengths n,n,n,n-1; got {},{},{},{}".format(len(X), len(Y), len(Z), len(W)))
    defects = []
    for s in range(1, n):
        value = autocorrelation(X, s) + autocorrelation(Y, s) + 2 * autocorrelation(Z, s) + 2 * autocorrelation(W, s)
        if value != 0:
            defects.append((int(s), int(value)))
    sums = {
        "x": int(sum(X)),
        "y": int(sum(Y)),
        "z": int(sum(Z)),
        "w": int(sum(W)),
        "sum_square_identity": int(sum(X) ** 2 + sum(Y) ** 2 + 2 * sum(Z) ** 2 + 2 * sum(W) ** 2),
        "expected_sum_square_identity": turyn_rhs(n),
    }
    ok = len(defects) == 0
    if verbose:
        print("Turyn type OK:", ok)
        print("lengths:", [len(X), len(Y), len(Z), len(W)])
        print("sums:", sums)
        if not ok:
            print("First bad shifts:", defects[:30])
    return ok, defects, sums


def turyn_to_base_sequences(X, Y, Z, W):
    X = list(X)
    Y = list(Y)
    Z = list(Z)
    W = list(W)
    n = len(X)
    if len(W) != n - 1:
        raise ValueError("W length must be n-1")
    A = list(Z) + list(W)
    B = list(Z) + [-int(w) for w in W]
    C = list(X)
    D = list(Y)
    return A, B, C, D


def base_to_t_sequences(A, B, C, D):
    A = list(A)
    B = list(B)
    C = list(C)
    D = list(D)
    if len(A) != len(B) or len(C) != len(D):
        raise ValueError("base lengths must be len(A)=len(B), len(C)=len(D)")
    left_len = len(A)
    right_len = len(C)
    T1 = [(int(a) + int(b)) // 2 for a, b in zip(A, B)] + [0] * right_len
    T2 = [(int(a) - int(b)) // 2 for a, b in zip(A, B)] + [0] * right_len
    T3 = [0] * left_len + [(int(c) + int(d)) // 2 for c, d in zip(C, D)]
    T4 = [0] * left_len + [(int(c) - int(d)) // 2 for c, d in zip(C, D)]
    return T1, T2, T3, T4


def verify_t_sequences(Ts, verbose=True):
    if len(Ts) != 4:
        raise ValueError("expected four T-sequences")
    v = len(Ts[0])
    if any(len(T) != v for T in Ts):
        raise ValueError("all T-sequences must have the same length")
    support_bad = []
    entry_bad = []
    for j in range(v):
        values = [int(T[j]) for T in Ts]
        if any(x not in (-1, 0, 1) for x in values):
            entry_bad.append((j, values))
        if sum(1 for x in values if x != 0) != 1:
            support_bad.append((j, values))
    corr_bad = []
    for s in range(1, v):
        value = sum(autocorrelation(T, s) for T in Ts)
        if value != 0:
            corr_bad.append((int(s), int(value)))
    ok = not support_bad and not entry_bad and not corr_bad
    if verbose:
        print("T-sequences OK:", ok)
        print("length:", v)
        if entry_bad:
            print("First bad entries:", entry_bad[:10])
        if support_bad:
            print("First bad support positions:", support_bad[:10])
        if corr_bad:
            print("First bad autocorrelation shifts:", corr_bad[:20])
    return ok, {"entry_bad": entry_bad, "support_bad": support_bad, "corr_bad": corr_bad}


def sequence_circulant(seq):
    seq = [int(x) for x in seq]
    v = len(seq)
    return matrix(ZZ, v, v, lambda i, j: seq[(j - i) % v])


def back_identity(v):
    return matrix(ZZ, v, v, lambda i, j: 1 if i + j == v - 1 else 0)


def goethals_seidel_from_t_sequences(T1, T2, T3, T4):
    mats = [sequence_circulant(T) for T in [T1, T2, T3, T4]]
    A1 = mats[0] + mats[1] + mats[2] + mats[3]
    A2 = -mats[0] + mats[1] + mats[2] - mats[3]
    A3 = -mats[0] - mats[1] + mats[2] + mats[3]
    A4 = -mats[0] + mats[1] - mats[2] + mats[3]
    v = A1.nrows()
    R = back_identity(v)
    H = block_matrix(
        ZZ,
        [
            [A1, A2 * R, A3 * R, A4 * R],
            [-A2 * R, A1, A4.transpose() * R, -A3.transpose() * R],
            [-A3 * R, -A4.transpose() * R, A1, A2.transpose() * R],
            [-A4 * R, A3.transpose() * R, -A2.transpose() * R, A1],
        ],
        subdivide=False,
    )
    return H


def first_bad_entries(M, limit=20):
    bad = []
    for i in range(M.nrows()):
        for j in range(M.ncols()):
            if M[i, j] != 0:
                bad.append((int(i), int(j), int(M[i, j])))
                if len(bad) >= limit:
                    return bad
    return bad


def is_pm1_matrix(H):
    for x in H.list():
        if int(x) not in (-1, 1):
            return False
    return True


def exact_hadamard_check(H):
    n = H.nrows()
    if H.ncols() != n:
        return False, "not square", []
    if not is_pm1_matrix(H):
        return False, "not +/-1", []
    defect = H * H.transpose() - n * identity_matrix(ZZ, n)
    bad = first_bad_entries(defect)
    if bad:
        return False, "HH^T differs from {}I".format(n), bad
    return True, "OK", []


def load_turyn_json(path):
    with open(path) as f:
        data = json.load(f)
    for key in ["X", "Y", "Z", "W"]:
        if key not in data:
            raise ValueError("{} missing from {}".format(key, path))
    return data, as_int_sequence(data["X"], "X"), as_int_sequence(data["Y"], "Y"), as_int_sequence(data["Z"], "Z"), as_int_sequence(data["W"], "W")


def parse_args():
    parser = argparse.ArgumentParser(description="Verify Turyn type sequences and convert them to a Hadamard candidate.")
    parser.add_argument("--n", type=int, default=56)
    parser.add_argument("--turyn-json", default="")
    parser.add_argument("--sum-candidates", action="store_true")
    parser.add_argument("--hall-grid", type=int, default=100)
    parser.add_argument("--out", default="")
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        payload = {
            "script": SCRIPT_NAME,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "n": int(args.n),
            "target_order": int(4 * (3 * int(args.n) - 1)),
            "notes": [
                "Turyn route is diagnostic unless a sequence passes exact Turyn, T-sequence, and HH^T checks.",
                "Fourier/Hall values are pruning diagnostics only.",
            ],
        }
        if args.sum_candidates:
            candidates = sum_candidates(args.n)
            payload["sum_candidates_count"] = len(candidates)
            payload["sum_candidates"] = [list(row) for row in candidates]
            print("n={} target_order={}".format(args.n, 4 * (3 * args.n - 1)))
            print("sum identity: x^2+y^2+2z^2+2w^2 = {}".format(turyn_rhs(args.n)))
            print("sum candidates:", len(candidates))
            print("first candidates:", candidates[:30])

        if args.turyn_json:
            data, X, Y, Z, W = load_turyn_json(args.turyn_json)
            ok_turyn, defects, sums = verify_turyn_type(X, Y, Z, W)
            payload["input"] = args.turyn_json
            payload["turyn_ok"] = bool(ok_turyn)
            payload["turyn_bad_shifts"] = defects[:100]
            payload["sums"] = sums
            payload["hall_grid"] = int(args.hall_grid)
            payload["hall"] = {
                "X_max": hall_grid_max(X, args.hall_grid),
                "Y_max": hall_grid_max(Y, args.hall_grid),
                "Z_max": hall_grid_max(Z, args.hall_grid),
                "W_max": hall_grid_max(W, args.hall_grid),
                "single_ZW_bound": hall_single_bound(len(X)),
            }
            if ok_turyn:
                A, B, C, D = turyn_to_base_sequences(X, Y, Z, W)
                Ts = base_to_t_sequences(A, B, C, D)
                ok_t, t_bad = verify_t_sequences(Ts)
                H = goethals_seidel_from_t_sequences(*Ts)
                ok_h, msg, bad = exact_hadamard_check(H)
                payload["t_sequences_ok"] = bool(ok_t)
                payload["t_sequence_bad"] = t_bad
                payload["hadamard_ok"] = bool(ok_h)
                payload["hadamard_message"] = msg
                payload["first_bad_hadamard_entries"] = bad
                payload["generated_order"] = int(H.nrows())
                print("Generated order:", H.nrows())
                print("HH^T check:", ok_h, msg)

        out = args.out or os.path.join("outputs/turyn", "{}_n{}.json".format(stamp, int(args.n)))
        write_json(out, payload)
        print("WROTE:", out)
    finally:
        tee.close()


if __name__ == "__main__":
    main()
