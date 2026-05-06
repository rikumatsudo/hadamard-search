from sage.all import *
from sage.combinat.matrices.hadamard_matrix import is_hadamard_matrix

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


def normalize_blocks(v, blocks):
    normalized = []
    for idx, block in enumerate(blocks):
        values = [int(x) % v for x in block]
        if len(values) != len(set(values)):
            raise ValueError("block {} has duplicate elements modulo v".format(idx))
        normalized.append(set(values))
    return normalized


def diff_counts(v, block):
    block = list(block)
    counts = [0] * v
    for x in block:
        for y in block:
            if x != y:
                counts[(x - y) % v] += 1
    return counts


def total_diff_counts(v, blocks):
    total = [0] * v
    for block in blocks:
        counts = diff_counts(v, block)
        total = [a + b for a, b in zip(total, counts)]
    return total


def verify_sds(v, blocks, lam, verbose=True):
    total = total_diff_counts(v, blocks)
    bad = []
    for t in range(1, v):
        if total[t] != lam:
            bad.append((t, total[t]))

    ok = len(bad) == 0
    if verbose:
        print("SDS OK:", ok)
        if not ok:
            print("First bad shifts:", bad[:20])
    return ok


def sequence_from_block(v, block):
    block = set(block)
    return [-1 if i in block else 1 for i in range(v)]


def circulant_from_sequence(seq):
    v = len(seq)
    return matrix(ZZ, v, v, lambda i, j: seq[(j - i) % v])


def back_identity(v):
    return matrix(ZZ, v, v, lambda i, j: 1 if i + j == v - 1 else 0)


def goethals_seidel_matrix(v, blocks):
    circulants = [
        circulant_from_sequence(sequence_from_block(v, block))
        for block in blocks
    ]
    A, B, C, D = circulants
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


def verify_hadamard(v, blocks, verbose=True):
    H = goethals_seidel_matrix(v, blocks)
    n = 4 * v
    hh_t = H * H.transpose() == n * identity_matrix(ZZ, n)
    entries_ok = all(x in (-1, 1) for x in H.list())
    sage_ok = is_hadamard_matrix(H) if hh_t and entries_ok else False
    ok = hh_t and entries_ok and sage_ok
    if verbose:
        print("Generated order:", n)
        print("Entries are +/-1:", entries_ok)
        print("HH^T = {}I:".format(n), hh_t)
        print("is_hadamard_matrix:", sage_ok)
    return ok, hh_t


def load_candidate(path):
    with open(path) as f:
        payload = json.load(f)

    v = int(payload["v"])
    lam = int(payload["lambda"])
    blocks = normalize_blocks(v, payload["blocks"])

    if len(blocks) != 4:
        raise ValueError("expected exactly four blocks")

    if "ks" in payload:
        actual_ks = sorted(len(block) for block in blocks)
        expected_ks = sorted(int(k) for k in payload["ks"])
        if actual_ks != expected_ks:
            raise ValueError(
                "block sizes {} do not match ks {}".format(actual_ks, expected_ks)
            )

    return payload, v, blocks, lam


def parse_args():
    parser = argparse.ArgumentParser(
        description="Verify an SDS candidate JSON and optional Hadamard matrix."
    )
    parser.add_argument("candidate_json", help="Candidate JSON path.")
    parser.add_argument(
        "--skip-hadamard",
        action="store_true",
        help="Verify only the SDS condition.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    tee = setup_logging("02_verify_sds")
    try:
        payload, v, blocks, lam = load_candidate(args.candidate_json)
        print("Candidate:", args.candidate_json)
        print("v={}, n={}, lambda={}".format(v, 4 * v, lam))
        print("block sizes:", [len(block) for block in blocks])

        sds_ok = verify_sds(v, blocks, lam)
        if not sds_ok:
            raise SystemExit(1)

        if args.skip_hadamard:
            print("Skipped Hadamard construction.")
            return

        hadamard_ok, hh_t = verify_hadamard(v, blocks)
        if not hadamard_ok or not hh_t:
            raise SystemExit(1)
        print("OK: candidate verified")
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()

