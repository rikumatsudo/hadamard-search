from itertools import combinations_with_replacement

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


def sds_parameter_sets(v):
    out = []
    for ks in combinations_with_replacement(range(0, v // 2 + 1), 4):
        lam = sum(ks) - v
        if lam < 0:
            continue
        lhs = sum(k * (k - 1) for k in ks)
        rhs = lam * (v - 1)
        if lhs == rhs:
            out.append((ks, lam))
    return out


def write_params(v, params, outdir):
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, "sds_params_v{}_n{}.json".format(v, 4 * v))
    payload = {
        "v": int(v),
        "n": int(4 * v),
        "parameter_sets": [
            {"ks": [int(k) for k in ks], "lambda": int(lam)}
            for (ks, lam) in params
        ],
    }
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)
    return path


def parse_args():
    parser = argparse.ArgumentParser(
        description="Enumerate SDS parameter candidates."
    )
    parser.add_argument(
        "--v",
        dest="vs",
        type=int,
        action="append",
        default=None,
        help="Group order v. May be passed more than once.",
    )
    parser.add_argument(
        "--outdir",
        default="outputs/params",
        help="Output directory for parameter JSON files.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    tee = setup_logging("01_sds_params")
    try:
        vs = args.vs or [167, 179, 223]
        for v in vs:
            print("\nv={}, n={}".format(v, 4 * v))
            params = sds_parameter_sets(v)
            for ks, lam in params:
                print("  k={}, lambda={}".format(ks, lam))
            path = write_params(v, params, args.outdir)
            print("Wrote:", path)
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
