from sage.all import *
from sage.combinat.matrices.hadamard_matrix import is_hadamard_matrix

import argparse
import json
import math
import os
import random
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


def total_diff_counts(v, blocks):
    total = [0] * v
    for B in blocks:
        B = list(B)
        for x in B:
            for y in B:
                if x != y:
                    total[(x - y) % v] += 1
    return total


def score_counts(counts, lam):
    return sum((counts[t] - lam) ** 2 for t in range(1, len(counts)))


def verify_sds(v, blocks, lam, verbose=True):
    counts = total_diff_counts(v, blocks)
    bad = []
    for t in range(1, v):
        if counts[t] != lam:
            bad.append((t, counts[t]))
    ok = len(bad) == 0
    if verbose:
        print("SDS OK:", ok)
        if not ok:
            print("First bad shifts:", bad[:20])
    return ok


def delta_swap(v, B, a, b):
    delta = [0] * v
    others = set(B)
    others.remove(a)
    for y in others:
        delta[(a - y) % v] -= 1
        delta[(y - a) % v] -= 1
        delta[(b - y) % v] += 1
        delta[(y - b) % v] += 1
    return delta


def random_blocks(v, ks):
    universe = list(range(v))
    return [set(random.sample(universe, k)) for k in ks]


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


def write_candidate(outdir, v, ks, lam, blocks, seed, steps):
    sds_ok = verify_sds(v, blocks, lam)
    hadamard_ok, hh_t = verify_hadamard(v, blocks)
    if not (sds_ok and hadamard_ok and hh_t):
        raise RuntimeError("zero-score candidate failed final verification")

    result = {
        "v": int(v),
        "n": int(4 * v),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": [[int(x) for x in sorted(list(B))] for B in blocks],
        "verify_sds": bool(sds_ok),
        "generated_hadamard": bool(hadamard_ok),
        "hh_t": bool(hh_t),
        "construction": "Goethals-Seidel",
        "seed": None if seed is None else int(seed),
        "steps": int(steps),
    }

    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(
        outdir,
        "sds_v{}_n{}_verified_seed{}_step{}.json".format(
            v, 4 * v, seed, steps
        ),
    )
    with open(path, "w") as f:
        json.dump(result, f, indent=2)

    print("Wrote:", path)
    return result


def search(v, ks, lam, steps=200000, seed=None, outdir="outputs/candidates"):
    if len(ks) != 4:
        raise ValueError("ks must contain exactly four block sizes")
    if any(k < 0 or k > v for k in ks):
        raise ValueError("block sizes must lie between 0 and v")

    if seed is not None:
        random.seed(seed)

    blocks = random_blocks(v, ks)
    counts = total_diff_counts(v, blocks)
    cur_score = score_counts(counts, lam)
    best_score = cur_score
    best_blocks = [set(B) for B in blocks]
    start = time.time()

    print("Search target: v={}, n={}, ks={}, lambda={}".format(v, 4 * v, ks, lam))
    print("steps={}, seed={}".format(steps, seed))
    print("initial_score:", cur_score)

    if cur_score == 0:
        print("FOUND zero-score candidate at initialization")
        return write_candidate(outdir, v, ks, lam, blocks, seed, 0)

    movable_blocks = [idx for idx, B in enumerate(blocks) if 0 < len(B) < v]
    if not movable_blocks:
        raise ValueError("no block can be changed by a single swap")

    for step in range(1, steps + 1):
        i = random.choice(movable_blocks)
        B = blocks[i]
        a = random.choice(tuple(B))
        b = random.randrange(v)
        while b in B:
            b = random.randrange(v)

        delta = delta_swap(v, B, a, b)
        new_counts = [counts[t] + delta[t] for t in range(v)]
        new_score = score_counts(new_counts, lam)
        temp = max(0.01, 1.0 * (1 - float(step) / float(steps)))
        accept = (
            new_score <= cur_score
            or random.random() < math.exp((cur_score - new_score) / temp)
        )

        if accept:
            B.remove(a)
            B.add(b)
            counts = new_counts
            cur_score = new_score
            if cur_score < best_score:
                best_score = cur_score
                best_blocks = [set(X) for X in blocks]

        if step % 5000 == 0:
            elapsed = time.time() - start
            print(
                "step={} score={} best={} elapsed={:.1f}s".format(
                    step, cur_score, best_score, elapsed
                )
            )

        if cur_score == 0:
            print("FOUND zero-score candidate at step", step)
            return write_candidate(outdir, v, ks, lam, blocks, seed, step)

    print("NOT FOUND")
    print("best_score:", best_score)
    print("best_block_sizes:", [len(B) for B in best_blocks])
    return None


def parse_ks(value):
    ks = tuple(int(part.strip()) for part in value.split(",") if part.strip())
    if len(ks) != 4:
        raise argparse.ArgumentTypeError("--ks must contain four comma-separated ints")
    return ks


def parse_args():
    parser = argparse.ArgumentParser(
        description="Random local search for four SDS blocks over Z_v."
    )
    parser.add_argument("--v", type=int, default=167, help="Group order.")
    parser.add_argument(
        "--ks",
        type=parse_ks,
        default=(71, 81, 82, 82),
        help="Comma-separated block sizes.",
    )
    parser.add_argument("--lam", type=int, default=149, help="SDS lambda.")
    parser.add_argument("--steps", type=int, default=200000, help="Search steps.")
    parser.add_argument("--seed", type=int, default=1, help="Random seed.")
    parser.add_argument(
        "--outdir",
        default="outputs/candidates",
        help="Directory for verified candidate JSON files.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    tee = setup_logging("03_random_sds_search")
    try:
        search(args.v, args.ks, args.lam, args.steps, args.seed, args.outdir)
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
