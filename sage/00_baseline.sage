from sage.all import *
from sage.combinat.matrices.hadamard_matrix import (
    hadamard_matrix,
    is_hadamard_matrix,
)

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


def main():
    tee = setup_logging("00_baseline")
    try:
        known_orders = [4, 8, 12, 20, 92, 148, 428]
        unknown_orders = [668, 716, 892, 1132]

        print("Known construction checks")
        for n in known_orders:
            print(n, hadamard_matrix(n, existence=True))

        print("\nUnknown construction checks")
        for n in unknown_orders:
            print(n, hadamard_matrix(n, existence=True))

        print("\nBuild and verify small known matrix")
        H = hadamard_matrix(92, check=True)
        assert is_hadamard_matrix(H)
        assert H * H.transpose() == 92 * identity_matrix(ZZ, 92)
        print("OK: H_92 verified")
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()

