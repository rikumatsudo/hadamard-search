from sage.all import *
from sage.rings.integer import Integer as SageInteger

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


def load_json(path):
    with open(path) as f:
        return json.load(f)


def write_json(path, payload):
    with open(path, "w") as f:
        json.dump(json_safe(payload), f, indent=2, sort_keys=True)
        f.write("\n")


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
    data = load_json(path)
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
        raise ValueError("block sizes {} do not match ks {}".format(actual_sizes, ks))

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


def verify_hadamard_exact(v, blocks):
    matrices = [block_to_pm1_circulant(v, block) for block in blocks]
    H = goethals_seidel(*matrices)
    n = 4 * v

    bad_entries = first_bad_pm1_entries(H)
    if bad_entries:
        return False, False, "matrix contains entries outside +/-1", bad_entries

    defect = H * H.transpose() - n * identity_matrix(ZZ, n)
    bad_defect = first_bad_entries(defect)
    if bad_defect:
        return True, False, "HH^T differs from {}I".format(n), bad_defect

    return True, True, "OK", []


def resolve_path(path, base_dir):
    if os.path.isabs(path) or os.path.exists(path):
        return path
    candidate = os.path.join(base_dir, path)
    if os.path.exists(candidate):
        return candidate
    return path


def verify_candidate(path, out_dir):
    row = {
        "source_path": path,
        "verified_path": None,
        "verify_sds": False,
        "generated_hadamard": False,
        "hh_t": False,
        "error": None,
    }
    try:
        data, v, n, ks, lam, blocks = load_candidate(path)
        sds_ok, bad = verify_sds(v, blocks, lam)
        row["verify_sds"] = bool(sds_ok)
        if not sds_ok:
            row["error"] = "SDS failed: {}".format(bad[:20])
        else:
            entries_ok, hh_t_ok, reason, detail = verify_hadamard_exact(v, blocks)
            row["generated_hadamard"] = bool(entries_ok)
            row["hh_t"] = bool(hh_t_ok)
            if not hh_t_ok:
                row["error"] = "{}: {}".format(reason, detail[:20])

        data["verify_sds"] = bool(row["verify_sds"])
        data["generated_hadamard"] = bool(row["generated_hadamard"])
        data["hh_t"] = bool(row["hh_t"])
        data["construction"] = "Goethals-Seidel"
        if row["error"]:
            data["verification_error"] = row["error"]

        verified_dir = os.path.join(out_dir, "verified_score0_candidates")
        os.makedirs(verified_dir, exist_ok=True)
        verified_path = os.path.join(verified_dir, os.path.basename(path))
        write_json(verified_path, data)
        row["verified_path"] = verified_path
    except Exception as exc:
        row["error"] = str(exc)
    return row


def build_mode_summary(engine_summary, score0_count, verified_count):
    engine = engine_summary.get("engine", "unknown")
    return [
        {
            "mode": engine,
            "run_count": engine_summary.get("run_count"),
            "best_score_overall": engine_summary.get("best_score"),
            "score0_count": score0_count,
            "verified_score0_count": verified_count,
            "frontier_count": 0,
            "repair_attempt_count": 0,
        }
    ]


def write_markdown(path, summary):
    lines = [
        "# Score0 Candidate Verification",
        "",
        "- engine: `{}`".format(summary["engine"]),
        "- source candidates: `{}`".format(summary["candidate_count"]),
        "- score0 candidates: `{}`".format(summary["score0_count"]),
        "- SDS verified: `{}`".format(summary["sds_ok_count"]),
        "- Hadamard verified: `{}`".format(summary["hadamard_ok_count"]),
        "",
        "| candidate | SDS | HH^T | verified JSON | error |",
        "| --- | ---: | ---: | --- | --- |",
    ]
    for row in summary["rows"]:
        lines.append(
            "| `{}` | `{}` | `{}` | `{}` | `{}` |".format(
                row["source_path"],
                row["verify_sds"],
                row["hh_t"],
                row["verified_path"] or "",
                row["error"] or "",
            )
        )
    if not summary["rows"]:
        lines.append("| `none` | `False` | `False` | `` | `` |")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Verify score=0 candidate JSON files with SageMath."
    )
    parser.add_argument("--score0-summary", required=True)
    parser.add_argument("--engine-summary", default=None)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--comparison-summary", default=None)
    parser.add_argument("--summary-md", default=None)
    parser.add_argument("--require-success", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    tee = setup_logging("64_verify_score0_candidates")
    try:
        os.makedirs(args.out_dir, exist_ok=True)
        score0_summary = load_json(args.score0_summary)
        engine_summary = load_json(args.engine_summary) if args.engine_summary else {}
        engine = engine_summary.get("engine") or score0_summary.get("engine") or "unknown"
        base_dir = os.path.dirname(args.score0_summary)

        candidate_paths = [
            resolve_path(path, base_dir)
            for path in score0_summary.get("score0_candidate_paths", [])
        ]
        rows = []
        for path in candidate_paths:
            print("Verify:", path)
            row = verify_candidate(path, args.out_dir)
            print("  SDS={} HHt={} error={}".format(row["verify_sds"], row["hh_t"], row["error"]))
            rows.append(row)

        sds_ok_count = sum(1 for row in rows if row["verify_sds"])
        hadamard_ok_count = sum(1 for row in rows if row["verify_sds"] and row["hh_t"])
        verified_paths = [
            row["verified_path"]
            for row in rows
            if row["verified_path"] and row["verify_sds"] and row["hh_t"]
        ]

        summary = {
            "engine": engine,
            "source": args.score0_summary,
            "candidate_count": int(score0_summary.get("candidate_count", 0)),
            "score0_count": len(candidate_paths),
            "sds_ok_count": sds_ok_count,
            "hadamard_ok_count": hadamard_ok_count,
            "verified_candidate_paths": verified_paths,
            "rows": rows,
        }

        verification_summary = os.path.join(args.out_dir, "verification_summary.json")
        summary_md = args.summary_md or os.path.join(args.out_dir, "verification_summary.md")
        write_json(verification_summary, summary)
        write_markdown(summary_md, summary)

        comparison = {
            "engine": engine,
            "source": "score0_candidate_verifier",
            "score0_candidate_paths": candidate_paths,
            "verified_score0_candidate_paths": verified_paths,
            "mode_summary": build_mode_summary(engine_summary, len(candidate_paths), hadamard_ok_count),
            "trajectory_run_count": engine_summary.get("run_count"),
            "frontier_count": 0,
            "repair_attempt_count": 0,
            "verification": {
                "summary_path": verification_summary,
                "candidate_count": int(score0_summary.get("candidate_count", 0)),
                "score0_count": len(candidate_paths),
                "sds_ok_count": sds_ok_count,
                "hadamard_ok_count": hadamard_ok_count,
            },
        }
        comparison_summary = args.comparison_summary or os.path.join(args.out_dir, "comparison_summary.json")
        write_json(comparison_summary, comparison)

        print("SUMMARY:", summary_md)
        print("COMPARISON:", comparison_summary)
        if args.require_success and candidate_paths and hadamard_ok_count != len(candidate_paths):
            raise SystemExit(1)
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
