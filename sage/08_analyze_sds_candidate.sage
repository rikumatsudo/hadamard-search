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


def timestamp_for_path():
    return time.strftime("%Y%m%d_%H%M%S")


def setup_logging(script_name):
    os.makedirs("outputs/logs", exist_ok=True)
    stamp = timestamp_for_path()
    path = os.path.join("outputs/logs", "{}_{}.log".format(script_name, stamp))
    tee = Tee(path)
    sys.stdout = tee
    print("Log:", path)
    return tee


def histogram(values):
    out = {}
    for value in values:
        key = int(value)
        out[key] = out.get(key, 0) + 1
    return {str(key): int(out[key]) for key in sorted(out)}


def duplicate_report(raw_blocks):
    reports = []
    ok = True
    for idx, block in enumerate(raw_blocks):
        seen = set()
        duplicates = []
        for value in block:
            if value in seen and value not in duplicates:
                duplicates.append(value)
            seen.add(value)
        if duplicates:
            ok = False
        reports.append(
            {
                "block": int(idx),
                "ok": len(duplicates) == 0,
                "duplicates": [int(x) for x in duplicates],
            }
        )
    return ok, reports


def range_report(v, raw_blocks):
    reports = []
    ok = True
    for idx, block in enumerate(raw_blocks):
        bad = [int(x) for x in block if int(x) < 0 or int(x) >= v]
        if bad:
            ok = False
        reports.append({"block": int(idx), "ok": len(bad) == 0, "bad": bad[:30]})
    return ok, reports


def normalize_blocks(raw_blocks):
    return [set(int(x) for x in block) for block in raw_blocks]


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
    per_block = []
    for block in blocks:
        counts = diff_counts(v, block)
        per_block.append(counts)
        total = [a + b for a, b in zip(total, counts)]
    return total, per_block


def metrics_from_counts(counts, lam):
    defects = []
    score = 0
    l1_error = 0
    max_abs_error = 0
    for d in range(1, len(counts)):
        defect = int(counts[d] - lam)
        defects.append((d, defect))
        abs_defect = abs(defect)
        score += defect * defect
        l1_error += abs_defect
        if abs_defect > max_abs_error:
            max_abs_error = abs_defect
    return int(score), int(l1_error), int(max_abs_error), defects


def worst_shifts(counts, lam, top):
    rows = []
    for d in range(1, len(counts)):
        count = int(counts[d])
        defect = int(count - lam)
        rows.append(
            {
                "shift": int(d),
                "count": count,
                "defect": defect,
                "abs_error": abs(defect),
            }
        )
    rows.sort(key=lambda item: (-item["abs_error"], item["shift"]))
    return rows[:top]


def top_over_under(counts, lam, top):
    over = []
    under = []
    for d in range(1, len(counts)):
        count = int(counts[d])
        defect = int(count - lam)
        row = {"shift": int(d), "count": count, "defect": defect}
        if defect > 0:
            over.append(row)
        elif defect < 0:
            under.append(row)
    over.sort(key=lambda item: (-item["defect"], item["shift"]))
    under.sort(key=lambda item: (item["defect"], item["shift"]))
    return over[:top], under[:top]


def per_block_summary(v, blocks, per_block_counts):
    out = []
    for idx, block in enumerate(blocks):
        counts = per_block_counts[idx]
        nonzero = [int(counts[d]) for d in range(1, v)]
        positive_shifts = sum(1 for value in nonzero if value > 0)
        out.append(
            {
                "block": int(idx),
                "size": int(len(block)),
                "density": float(len(block)) / float(v),
                "ordered_difference_total": int(sum(nonzero)),
                "expected_ordered_difference_total": int(len(block) * (len(block) - 1)),
                "nonzero_shifts_hit": int(positive_shifts),
                "min_nonzero_count": int(min(nonzero)) if nonzero else 0,
                "max_nonzero_count": int(max(nonzero)) if nonzero else 0,
                "count_histogram": histogram(nonzero),
            }
        )
    return out


def print_json(label, value):
    print("{}:".format(label))
    print(json.dumps(value, indent=2, sort_keys=True))


def parse_args():
    parser = argparse.ArgumentParser(
        description="Analyze a saved SDS candidate or near-hit JSON."
    )
    parser.add_argument("json_path", help="Candidate or near-hit JSON path.")
    parser.add_argument(
        "--top",
        type=int,
        default=12,
        help="Number of worst/over/under shifts to print.",
    )
    parser.add_argument(
        "--no-defect-vector",
        action="store_true",
        help="Do not print the full defect vector.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    tee = setup_logging("08_analyze_sds_candidate")
    try:
        with open(args.json_path) as f:
            data = json.load(f)

        v = int(data["v"])
        n = int(data.get("n", 4 * v))
        ks = [int(k) for k in data.get("ks", [])]
        lam = int(data["lambda"])
        raw_blocks = data["blocks"]

        duplicate_ok, duplicate_details = duplicate_report(raw_blocks)
        range_ok, range_details = range_report(v, raw_blocks)
        blocks = normalize_blocks(raw_blocks)
        counts, per_block_counts = total_diff_counts(v, blocks)
        score, l1_error, max_abs_error, defects = metrics_from_counts(counts, lam)

        print("Candidate:", args.json_path)
        print("v={}".format(v))
        print("n={}".format(n))
        print("ks={}".format(ks))
        print("lambda={}".format(lam))
        print("stored_score={}".format(data.get("score")))
        print("stored_l1_error={}".format(data.get("l1_error")))
        print("stored_max_abs_error={}".format(data.get("max_abs_error")))
        print("computed_score={}".format(score))
        print("computed_l1_error={}".format(l1_error))
        print("computed_max_abs_error={}".format(max_abs_error))
        print("verify_sds_flag={}".format(data.get("verify_sds")))
        print("generated_hadamard_flag={}".format(data.get("generated_hadamard")))
        print("hh_t_flag={}".format(data.get("hh_t")))
        print("duplicate_check={}".format(duplicate_ok))
        print("range_check={}".format(range_ok))
        print("block_density={}".format([float(len(block)) / float(v) for block in blocks]))

        expected_sizes_ok = (not ks) or [len(block) for block in blocks] == ks
        print("block_sizes={}".format([len(block) for block in blocks]))
        print("block_sizes_match_ks={}".format(expected_sizes_ok))

        print_json("duplicate_details", duplicate_details)
        print_json("range_details", range_details)
        print_json("worst_shifts", worst_shifts(counts, lam, args.top))
        print_json(
            "difference_count_histogram",
            histogram([counts[d] for d in range(1, v)]),
        )
        print_json(
            "per_block_difference_summary",
            per_block_summary(v, blocks, per_block_counts),
        )

        over, under = top_over_under(counts, lam, args.top)
        print_json("top_overrepresented_shifts", over)
        print_json("top_underrepresented_shifts", under)

        if not args.no_defect_vector:
            print_json(
                "defect_vector",
                [
                    {"shift": int(shift), "defect": int(defect)}
                    for shift, defect in defects
                ],
            )
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()

