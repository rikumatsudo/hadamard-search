from sage.all import *

import argparse
import json
import os
import sys
import time


class Tee(object):
    def __init__(self, path):
        self.terminal = sys.stdout
        self.log = open(path, "w")

    def write(self, data):
        self.terminal.write(data)
        self.log.write(data)

    def flush(self):
        self.terminal.flush()
        self.log.flush()

    def close(self):
        self.log.close()


def setup_logging(script_name):
    os.makedirs("outputs/logs", exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    path = os.path.join("outputs/logs", "{}_{}.log".format(script_name, stamp))
    tee = Tee(path)
    sys.stdout = tee
    print("Log:", path)
    return tee


def require_keys(data, keys):
    missing = [key for key in keys if key not in data]
    if missing:
        raise ValueError("candidate JSON is missing keys: {}".format(missing))


def normalize_blocks(v, raw_blocks):
    if len(raw_blocks) != 4:
        raise ValueError("expected exactly four blocks, got {}".format(len(raw_blocks)))

    blocks = []
    for idx, raw_block in enumerate(raw_blocks):
        values = [int(x) for x in raw_block]
        out_of_range = [x for x in values if x < 0 or x >= v]
        if out_of_range:
            raise ValueError(
                "block {} has elements outside Z_{}: {}".format(
                    idx, v, out_of_range[:20]
                )
            )
        if len(values) != len(set(values)):
            raise ValueError("block {} has duplicate elements".format(idx))
        blocks.append(set(values))
    return blocks


def load_candidate(path):
    with open(path) as f:
        data = json.load(f)

    require_keys(data, ["v", "n", "ks", "lambda", "blocks"])

    v = int(data["v"])
    n = int(data["n"])
    ks = [int(k) for k in data["ks"]]
    lam = int(data["lambda"])

    if v <= 0:
        raise ValueError("v must be positive")
    if n != 4 * v:
        raise ValueError("n={} does not equal 4*v={}".format(n, 4 * v))
    if len(ks) != 4:
        raise ValueError("ks must contain exactly four sizes")

    blocks = normalize_blocks(v, data["blocks"])
    actual_sizes = [len(block) for block in blocks]
    if actual_sizes != ks:
        raise ValueError(
            "block sizes {} do not match ks {}".format(actual_sizes, ks)
        )

    if lam != sum(ks) - v:
        raise ValueError(
            "lambda={} does not equal sum(ks)-v={}".format(lam, sum(ks) - v)
        )

    lhs = sum(k * (k - 1) for k in ks)
    rhs = lam * (v - 1)
    if lhs != rhs:
        raise ValueError(
            "SDS parameter equation failed: sum k(k-1)={} but lambda*(v-1)={}".format(
                lhs, rhs
            )
        )

    return data, v, n, ks, lam, blocks


def diff_counts(v, block):
    block = list(block)
    counts = [0] * v
    for x in block:
        for y in block:
            if x != y:
                counts[(x - y) % v] += 1
    return counts


def verify_sds(v, blocks, lam):
    total = [0] * v
    for block in blocks:
        counts = diff_counts(v, block)
        total = [a + b for a, b in zip(total, counts)]

    bad = []
    for t in range(1, v):
        if total[t] != lam:
            bad.append((t, total[t]))
    return len(bad) == 0, bad


def block_to_pm1_circulant(v, block):
    first_row = [-1 if i in block else 1 for i in range(v)]
    return matrix(ZZ, v, v, lambda i, j: first_row[(j - i) % v])


def back_identity(v):
    return matrix(ZZ, v, v, lambda i, j: 1 if i + j == v - 1 else 0)


def goethals_seidel(A, B, C, D):
    v = A.nrows()
    R = back_identity(v)
    return block_matrix(
        ZZ,
        [
            [A, B * R, C * R, D * R],
            [-B * R, A, -D.transpose() * R, C.transpose() * R],
            [-C * R, D.transpose() * R, A, -B.transpose() * R],
            [-D * R, -C.transpose() * R, B.transpose() * R, A],
        ],
        subdivide=False,
    )


def first_bad_entries(M, limit=20):
    bad = []
    for i in range(M.nrows()):
        for j in range(M.ncols()):
            if M[i, j] != 0:
                bad.append((int(i), int(j), int(M[i, j])))
                if len(bad) >= limit:
                    return bad
    return bad


def first_bad_pm1_entries(H, limit=20):
    bad = []
    for i in range(H.nrows()):
        for j in range(H.ncols()):
            if H[i, j] not in (-1, 1):
                bad.append((int(i), int(j), int(H[i, j])))
                if len(bad) >= limit:
                    return bad
    return bad


def is_hadamard_exact(H):
    n = H.nrows()
    if H.ncols() != n:
        return False, "matrix is not square", []

    bad_entries = first_bad_pm1_entries(H)
    if bad_entries:
        return False, "matrix contains entries outside +/-1", bad_entries

    defect = H * H.transpose() - n * identity_matrix(ZZ, n)
    bad_defect = first_bad_entries(defect)
    if bad_defect:
        return False, "HH^T differs from {}I".format(n), bad_defect

    return True, "OK", []


def parse_args():
    parser = argparse.ArgumentParser(
        description="Build a Goethals-Seidel Hadamard matrix from an SDS JSON."
    )
    parser.add_argument("json_path", help="Candidate JSON path.")
    return parser.parse_args()


def main():
    args = parse_args()
    tee = setup_logging("04_build_gs_from_sds")
    try:
        data, v, n, ks, lam, blocks = load_candidate(args.json_path)

        print("Candidate:", args.json_path)
        print("v={}".format(v))
        print("n={}".format(n))
        print("lambda={}".format(lam))
        print("ks={}".format(ks))
        print("block sizes={}".format([len(block) for block in blocks]))

        sds_ok, bad = verify_sds(v, blocks, lam)
        print("SDS OK:", sds_ok)
        if not sds_ok:
            print("First bad shifts:", bad[:30])
            raise SystemExit(1)

        A, B, C, D = [block_to_pm1_circulant(v, block) for block in blocks]
        H = goethals_seidel(A, B, C, D)

        print("H shape={} x {}".format(H.nrows(), H.ncols()))
        entries_ok = not first_bad_pm1_entries(H)
        print("entries +/-1:", entries_ok)

        ok, reason, detail = is_hadamard_exact(H)
        print("HH^T = {}I:".format(n), ok)
        if not ok:
            print("Failure:", reason)
            print("First bad entries:", detail[:20])
            raise SystemExit(1)

        print("OK: Goethals-Seidel Hadamard verified")
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()

