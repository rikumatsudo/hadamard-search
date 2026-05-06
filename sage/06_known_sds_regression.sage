from sage.all import *
from sage.rings.integer import Integer as SageInteger

import argparse
import json
import os
import shutil
import sys
import tempfile
import time


KNOWN_CANDIDATES = [
    {
        "name": "known_sds_v3_n12",
        "v": 3,
        "n": 12,
        "ks": [0, 1, 1, 1],
        "lambda": 0,
        "blocks": [[], [0], [0], [0]],
    },
    {
        "name": "known_sds_v5_n20",
        "v": 5,
        "n": 20,
        "ks": [1, 1, 2, 2],
        "lambda": 1,
        "blocks": [[0], [0], [0, 1], [0, 2]],
    },
    {
        "name": "known_sds_v7_n28",
        "v": 7,
        "n": 28,
        "ks": [1, 3, 3, 3],
        "lambda": 3,
        "blocks": [[0], [0, 2, 4], [0, 1, 2], [0, 1, 4]],
    },
]


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

    v = int(data["v"])
    n = int(data["n"])
    ks = [int(k) for k in data["ks"]]
    lam = int(data["lambda"])
    blocks = normalize_blocks(v, data["blocks"])

    if n != 4 * v:
        raise ValueError("n={} does not equal 4*v={}".format(n, 4 * v))
    if [len(block) for block in blocks] != ks:
        raise ValueError("block sizes do not match ks")
    if lam != sum(ks) - v:
        raise ValueError("lambda does not equal sum(ks)-v")
    if sum(k * (k - 1) for k in ks) != lam * (v - 1):
        raise ValueError("SDS parameter equation failed")

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


def verify_hadamard(v, blocks):
    matrices = [block_to_pm1_circulant(v, block) for block in blocks]
    H = goethals_seidel(*matrices)
    n = 4 * v

    bad_entries = first_bad_pm1_entries(H)
    if bad_entries:
        return False, "entries outside +/-1", bad_entries

    defect = H * H.transpose() - n * identity_matrix(ZZ, n)
    bad_defect = first_bad_entries(defect)
    if bad_defect:
        return False, "HH^T differs from {}I".format(n), bad_defect

    return True, "OK", []


def write_candidate(path, candidate):
    payload = json_safe(dict(candidate))
    payload.pop("name", None)
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)


def json_safe(value):
    if isinstance(value, dict):
        return {str(k): json_safe(v) for k, v in value.items()}
    if isinstance(value, list):
        return [json_safe(v) for v in value]
    if isinstance(value, tuple):
        return [json_safe(v) for v in value]
    if isinstance(value, SageInteger):
        return int(value)
    return value


def mark_verified(path):
    with open(path) as f:
        payload = json.load(f)
    payload["verify_sds"] = True
    payload["generated_hadamard"] = True
    payload["hh_t"] = True
    payload["construction"] = "Goethals-Seidel"
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)


def run_one(candidate, fixture_dir):
    path = os.path.join(fixture_dir, "{}.json".format(candidate["name"]))
    write_candidate(path, candidate)

    data, v, n, ks, lam, blocks = load_candidate(path)
    print("\nRegression:", candidate["name"])
    print("fixture:", path)
    print("v={}, n={}, ks={}, lambda={}".format(v, n, ks, lam))
    print("block sizes={}".format([len(block) for block in blocks]))

    sds_ok, bad = verify_sds(v, blocks, lam)
    print("SDS OK:", sds_ok)
    if not sds_ok:
        print("First bad shifts:", bad[:30])
        raise SystemExit(1)

    hadamard_ok, reason, detail = verify_hadamard(v, blocks)
    print("HH^T = {}I:".format(n), hadamard_ok)
    if not hadamard_ok:
        print("Failure:", reason)
        print("First bad entries:", detail[:20])
        raise SystemExit(1)

    mark_verified(path)
    print("OK: known SDS regression passed")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run known small SDS -> Goethals-Seidel regressions."
    )
    parser.add_argument(
        "--fixture-dir",
        default=None,
        help="Directory for generated known-SDS JSON fixtures.",
    )
    parser.add_argument(
        "--keep-fixtures",
        action="store_true",
        help="Keep temporary fixtures when --fixture-dir is not passed.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    tee = setup_logging("06_known_sds_regression")
    fixture_dir = args.fixture_dir
    cleanup = False

    try:
        if fixture_dir is None:
            fixture_dir = tempfile.mkdtemp(prefix="hadamard_known_sds_")
            cleanup = not args.keep_fixtures
        else:
            os.makedirs(fixture_dir, exist_ok=True)

        print("Fixture dir:", fixture_dir)
        for candidate in KNOWN_CANDIDATES:
            run_one(candidate, fixture_dir)
        print("\nOK: all known SDS regressions passed")
    finally:
        if cleanup and fixture_dir and os.path.isdir(fixture_dir):
            shutil.rmtree(fixture_dir)
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
