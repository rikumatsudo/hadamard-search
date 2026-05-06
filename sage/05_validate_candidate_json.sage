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


def parse_args():
    parser = argparse.ArgumentParser(
        description="Validate an SDS candidate JSON."
    )
    parser.add_argument("json_path", help="Candidate JSON path.")
    return parser.parse_args()


def main():
    args = parse_args()
    tee = setup_logging("05_validate_candidate_json")
    try:
        data, v, n, ks, lam, blocks = load_candidate(args.json_path)

        print("Candidate:", args.json_path)
        print("v={}".format(v))
        print("n={}".format(n))
        print("lambda={}".format(lam))
        print("ks={}".format(ks))
        print("block sizes={}".format([len(block) for block in blocks]))
        print("schema OK: True")
        print("parameter equation OK: True")

        ok, bad = verify_sds(v, blocks, lam)
        print("SDS OK:", ok)
        if not ok:
            print("First bad shifts:")
            print(bad[:30])
            raise SystemExit(1)

        print("OK: candidate JSON validates as SDS")
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()

