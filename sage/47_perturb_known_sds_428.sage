from sage.all import *

import argparse
import csv
import json
import os
import random
import statistics
import time

from sds_repair_utils import (
    apply_delta,
    canonical_hash,
    delta_swap,
    json_blocks,
    metrics_from_counts,
    p_adic_moment_summary,
    setup_logging,
    total_diff_counts,
    write_json,
)


SCRIPT_NAME = "47_perturb_known_sds_428"
POWERS = (2, 4, 6, 8, 10, 12)


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)


def json_safe(value):
    if isinstance(value, dict):
        return {str(key): json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    try:
        if isinstance(value, Integer):
            return int(value)
    except NameError:
        pass
    return value


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def as_int_sequence(values, name):
    seq = [int(x) for x in values]
    bad = [x for x in seq if x not in (-1, 0, 1)]
    if bad:
        raise ValueError("{} contains entries outside -1,0,1".format(name))
    return seq


def autocorrelation(seq, shift):
    shift = int(shift)
    if shift < 0:
        raise ValueError("shift must be nonnegative")
    if shift >= len(seq):
        return 0
    return int(sum(int(seq[i]) * int(seq[i + shift]) for i in range(len(seq) - shift)))


def verify_turyn_type(X, Y, Z, W):
    n = len(X)
    if len(Y) != n or len(Z) != n or len(W) != n - 1:
        raise ValueError("expected Turyn lengths n,n,n,n-1")
    defects = []
    for shift in range(1, n):
        value = (
            autocorrelation(X, shift)
            + autocorrelation(Y, shift)
            + 2 * autocorrelation(Z, shift)
            + 2 * autocorrelation(W, shift)
        )
        if value != 0:
            defects.append((int(shift), int(value)))
    return len(defects) == 0, defects


def turyn_to_t_sequences(X, Y, Z, W):
    A = list(Z) + list(W)
    B = list(Z) + [-int(w) for w in W]
    C = list(X)
    D = list(Y)
    left_len = len(A)
    right_len = len(C)
    T1 = [(int(a) + int(b)) // 2 for a, b in zip(A, B)] + [0] * right_len
    T2 = [(int(a) - int(b)) // 2 for a, b in zip(A, B)] + [0] * right_len
    T3 = [0] * left_len + [(int(c) + int(d)) // 2 for c, d in zip(C, D)]
    T4 = [0] * left_len + [(int(c) - int(d)) // 2 for c, d in zip(C, D)]
    return T1, T2, T3, T4


def verify_t_sequences(Ts):
    v = len(Ts[0])
    support_bad = []
    corr_bad = []
    for idx in range(v):
        values = [int(T[idx]) for T in Ts]
        if sum(1 for x in values if x != 0) != 1:
            support_bad.append((int(idx), values))
    for shift in range(1, v):
        value = sum(autocorrelation(T, shift) for T in Ts)
        if value != 0:
            corr_bad.append((int(shift), int(value)))
    return not support_bad and not corr_bad, {
        "support_bad": support_bad[:20],
        "corr_bad": corr_bad[:20],
    }


def t_sequences_to_pm1_sequences(Ts):
    T1, T2, T3, T4 = [[int(x) for x in T] for T in Ts]
    seqs = []
    for signs in ((1, 1, 1, 1), (-1, 1, 1, -1), (-1, -1, 1, 1), (-1, 1, -1, 1)):
        seq = []
        for values in zip(T1, T2, T3, T4):
            value = sum(int(s) * int(x) for s, x in zip(signs, values))
            if value not in (-1, 1):
                raise ValueError("Walsh-mixed T-sequence entry is not +/-1")
            seq.append(int(value))
        seqs.append(seq)
    return seqs


def load_exact_428_blocks(path):
    with open(path) as f:
        data = json.load(f)
    X = as_int_sequence(data["X"], "X")
    Y = as_int_sequence(data["Y"], "Y")
    Z = as_int_sequence(data["Z"], "Z")
    W = as_int_sequence(data["W"], "W")
    turyn_ok, turyn_bad = verify_turyn_type(X, Y, Z, W)
    Ts = turyn_to_t_sequences(X, Y, Z, W)
    t_ok, t_bad = verify_t_sequences(Ts)
    seqs = t_sequences_to_pm1_sequences(Ts)
    blocks = [set(i for i, value in enumerate(seq) if int(value) == -1) for seq in seqs]
    v = len(seqs[0])
    ks = tuple(len(block) for block in blocks)
    lam = int(sum(ks) - v)
    return {
        "source": path,
        "turyn_ok": bool(turyn_ok),
        "turyn_bad": turyn_bad[:20],
        "t_sequences_ok": bool(t_ok),
        "t_sequence_bad": t_bad,
        "v": int(v),
        "n": int(4 * v),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": blocks,
        "row_sums": [int(sum(seq)) for seq in seqs],
    }


def verify_sds_from_counts(counts, lam):
    bad = []
    for shift in range(1, len(counts)):
        if int(counts[shift]) != int(lam):
            bad.append((int(shift), int(counts[shift])))
    return len(bad) == 0, bad


def moment_payload(counts, lam, v):
    summary = p_adic_moment_summary(counts, lam, powers=POWERS, modulus=v)
    moments = {"T{}".format(item["power"]): int(item["residue"]) for item in summary["moments"]}
    return {
        "padic_moments": moments,
        "moment_zero_count_3": int(sum(1 for key in ("T2", "T4", "T6") if moments[key] == 0)),
        "moment_zero_count_6": int(summary["moment_zero_count"]),
        "moment_abs_sum_6": int(summary["moment_abs_sum"]),
        "moment_signature_6": summary["moment_signature"],
    }


def evaluate_blocks(blocks, v, lam, ks, include_canonical=False):
    counts = total_diff_counts(v, blocks)
    return evaluate_counts(blocks, counts, v, lam, ks, include_canonical=include_canonical)


def evaluate_counts(blocks, counts, v, lam, ks, include_canonical=False):
    metrics = metrics_from_counts(counts, lam)
    ok, bad = verify_sds_from_counts(counts, lam)
    return {
        "score": int(metrics[0]),
        "l1_error": int(metrics[1]),
        "max_abs_error": int(metrics[2]),
        "nonzero_defect_count": int(metrics[3]),
        "sds_ok": bool(ok),
        "sds_bad_first": bad[:20],
        "canonical_hash": canonical_hash(blocks, ks, v) if include_canonical else "",
        **moment_payload(counts, lam, v),
    }


def row_from_eval(distance, sample_id, metrics, moves, origin):
    out = {
        "distance": int(distance),
        "sample_id": int(sample_id),
        "origin": origin,
        "score": int(metrics["score"]),
        "l1_error": int(metrics["l1_error"]),
        "max_abs_error": int(metrics["max_abs_error"]),
        "nonzero_defect_count": int(metrics["nonzero_defect_count"]),
        "moment_zero_count_3": int(metrics["moment_zero_count_3"]),
        "moment_zero_count_6": int(metrics["moment_zero_count_6"]),
        "moment_abs_sum_6": int(metrics["moment_abs_sum_6"]),
        "canonical_hash": metrics["canonical_hash"],
        "moves": json.dumps(moves, sort_keys=True),
    }
    for key, value in metrics["padic_moments"].items():
        out[key] = int(value)
    return out


def apply_swap(blocks, block_idx, removed, added):
    out = [set(block) for block in blocks]
    out[block_idx].remove(removed)
    out[block_idx].add(added)
    return out


def random_perturbation(rng, base_blocks, base_counts, distance, v):
    blocks = [set(block) for block in base_blocks]
    counts = list(base_counts)
    moves = []
    for _ in range(int(distance)):
        block_idx = rng.randrange(4)
        removed = rng.choice(tuple(blocks[block_idx]))
        added = rng.randrange(v)
        while added in blocks[block_idx]:
            added = rng.randrange(v)
        delta = delta_swap(v, blocks[block_idx], removed, added)
        counts = apply_delta(counts, delta)
        blocks[block_idx].remove(removed)
        blocks[block_idx].add(added)
        moves.append({"block": int(block_idx), "remove": int(removed), "add": int(added)})
    return blocks, counts, moves


def candidate_payload(blocks, v, ks, lam, metrics, source, origin, moves):
    return {
        "v": int(v),
        "n": int(4 * v),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": json_blocks(blocks),
        "score": int(metrics["score"]),
        "l1_error": int(metrics["l1_error"]),
        "max_abs_error": int(metrics["max_abs_error"]),
        "nonzero_defect_count": int(metrics["nonzero_defect_count"]),
        "verify_sds": bool(metrics["sds_ok"]),
        "generated_hadamard": False,
        "hh_t": False,
        "construction": "Goethals-Seidel",
        "search_method": SCRIPT_NAME,
        "source_json": source,
        "origin": origin,
        "moves": moves,
        "canonical_hash": metrics["canonical_hash"],
        "padic_moments": metrics["padic_moments"],
        "moment_zero_count_3": int(metrics["moment_zero_count_3"]),
        "moment_zero_count_6": int(metrics["moment_zero_count_6"]),
        "moment_signature_6": metrics["moment_signature_6"],
        "notes": [
            "428 positive-control perturbation artifact.",
            "Perturbed candidates are diagnostics, not Hadamard constructions unless exact SDS and GS checks are run and pass.",
        ],
    }


def save_candidate(path, blocks, v, ks, lam, metrics, source, origin, moves):
    if not metrics.get("canonical_hash"):
        metrics = dict(metrics)
        metrics["canonical_hash"] = canonical_hash(blocks, ks, v)
    write_json(path, candidate_payload(blocks, v, ks, lam, metrics, source, origin, moves))
    return path


def summarize_rows(rows):
    if not rows:
        return {}
    scores = sorted(row["score"] for row in rows)
    l1s = sorted(row["l1_error"] for row in rows)
    zero3 = {}
    for row in rows:
        key = str(row["moment_zero_count_3"])
        zero3[key] = zero3.get(key, 0) + 1
    def q(values, frac):
        idx = int(frac * (len(values) - 1))
        return int(values[idx])
    return {
        "count": int(len(rows)),
        "score_min": int(scores[0]),
        "score_p1": q(scores, 0.01),
        "score_p5": q(scores, 0.05),
        "score_p10": q(scores, 0.10),
        "score_median": q(scores, 0.50),
        "l1_min": int(l1s[0]),
        "moment_zero_count_3_hist": zero3,
    }


def write_summary(out_dir, exact_metrics, distance_summaries, best_records, exact_path):
    lines = []
    lines.append("# 428 Positive-control Perturbation Summary")
    lines.append("")
    lines.append("This is a calibration experiment using the known order-428 construction. It does not claim anything about order 668 directly.")
    lines.append("")
    lines.append("## Exact 428 Baseline")
    lines.append("")
    lines.append("- source: `{}`".format(exact_path))
    lines.append("- score: `{}`".format(exact_metrics["score"]))
    lines.append("- l1_error: `{}`".format(exact_metrics["l1_error"]))
    lines.append("- max_abs_error: `{}`".format(exact_metrics["max_abs_error"]))
    lines.append("- nonzero_defect_count: `{}`".format(exact_metrics["nonzero_defect_count"]))
    lines.append("- SDS OK: `{}`".format(exact_metrics["sds_ok"]))
    lines.append("- moments: `{}`".format(exact_metrics["padic_moments"]))
    lines.append("")
    lines.append("## Perturbation Distribution")
    lines.append("")
    for distance in sorted(distance_summaries):
        lines.append("### distance {}".format(distance))
        lines.append("")
        lines.append("```json")
        lines.append(json.dumps(json_safe(distance_summaries[distance]), indent=2, sort_keys=True))
        lines.append("```")
        lines.append("")
    lines.append("## Best Records")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(json_safe(best_records), indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("## Interpretation")
    lines.append("")
    lines.append("- Exact 428 has score 0 and all tested p-adic moments zero, as expected.")
    lines.append("- The useful calibration question is whether small swap distance preserves moment compatibility together with low score, or whether moments randomize faster than score.")
    lines.append("- Perturbed rows are diagnostics only; only the exact baseline is a verified construction.")
    with open(os.path.join(out_dir, "perturbation_summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Perturb the known order-428 SDS/Turyn construction and measure score/moment indicators.")
    parser.add_argument("--turyn-json", default="outputs/turyn/exact_428_kharaghani_tayfeh_rezaie.json")
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--max-distance", type=int, default=4)
    parser.add_argument("--samples-per-distance", type=int, default=5000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--full-one-swap", action="store_true")
    parser.add_argument("--save-best-per-distance", type=int, default=5)
    return parser.parse_args()


def main():
    args = parse_args()
    out_dir = args.out_dir or os.path.join("outputs", "explorations", "{}_hadamard428_positive_control_perturbation".format(now_stamp()))
    ensure_dir(out_dir)
    ensure_dir(os.path.join(out_dir, "candidates"))
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        exact = load_exact_428_blocks(args.turyn_json)
        v = int(exact["v"])
        ks = tuple(int(k) for k in exact["ks"])
        lam = int(exact["lambda"])
        blocks = exact["blocks"]
        exact_metrics = evaluate_blocks(blocks, v, lam, ks, include_canonical=True)
        exact_counts = total_diff_counts(v, blocks)
        exact_payload = candidate_payload(blocks, v, ks, lam, exact_metrics, args.turyn_json, "exact_428_baseline", [])
        exact_payload.update({
            "turyn_ok": exact["turyn_ok"],
            "t_sequences_ok": exact["t_sequences_ok"],
            "row_sums": exact["row_sums"],
        })
        exact_path = os.path.join(out_dir, "exact_428_sds_candidate.json")
        write_json(exact_path, exact_payload)
        print("Output dir:", out_dir)
        print("Exact path:", exact_path)
        print("v={} ks={} lambda={}".format(v, ks, lam))
        print("Exact metrics:", exact_metrics)

        csv_path = os.path.join(out_dir, "perturbations.csv")
        jsonl_path = os.path.join(out_dir, "perturbations.jsonl")
        fieldnames = [
            "distance", "sample_id", "origin", "score", "l1_error", "max_abs_error",
            "nonzero_defect_count", "moment_zero_count_3", "moment_zero_count_6",
            "moment_abs_sum_6", "T2", "T4", "T6", "T8", "T10", "T12",
            "canonical_hash", "moves",
        ]
        rows_by_distance = {}
        best_by_distance = {}
        rng = random.Random(int(args.seed))
        with open(csv_path, "w", newline="") as f_csv, open(jsonl_path, "w") as f_jsonl:
            writer = csv.DictWriter(f_csv, fieldnames=fieldnames)
            writer.writeheader()

            def record(distance, sample_id, perturbed_blocks, moves, origin, counts=None):
                if counts is None:
                    metrics = evaluate_blocks(perturbed_blocks, v, lam, ks, include_canonical=False)
                else:
                    metrics = evaluate_counts(perturbed_blocks, counts, v, lam, ks, include_canonical=False)
                row = row_from_eval(distance, sample_id, metrics, moves, origin)
                writer.writerow(row)
                f_jsonl.write(json.dumps(json_safe(row), sort_keys=True) + "\n")
                rows_by_distance.setdefault(int(distance), []).append(row)
                best = best_by_distance.setdefault(int(distance), [])
                best.append((metrics["score"], metrics["l1_error"], metrics, [set(b) for b in perturbed_blocks], moves, origin))
                best.sort(key=lambda item: (item[0], item[1], item[2]["max_abs_error"], item[2]["nonzero_defect_count"]))
                del best[int(args.save_best_per_distance):]

            sample_id = 0
            if args.full_one_swap:
                for block_idx, block in enumerate(blocks):
                    outside = [x for x in range(v) if x not in block]
                    for removed in sorted(block):
                        for added in outside:
                            sample_id += 1
                            record(
                                1,
                                sample_id,
                                apply_swap(blocks, block_idx, int(removed), int(added)),
                                [{"block": int(block_idx), "remove": int(removed), "add": int(added)}],
                                "full_one_swap",
                                apply_delta(exact_counts, delta_swap(v, blocks[block_idx], int(removed), int(added))),
                            )
                print("Full one-swap rows:", sample_id)

            for distance in range(1, int(args.max_distance) + 1):
                for local_id in range(int(args.samples_per_distance)):
                    sample_id += 1
                    perturbed, counts, moves = random_perturbation(rng, blocks, exact_counts, distance, v)
                    record(distance, sample_id, perturbed, moves, "sampled_random_swaps", counts)
                print("Sampled distance {} rows: {}".format(distance, int(args.samples_per_distance)))

        saved_best = {}
        for distance, items in best_by_distance.items():
            saved_best[str(distance)] = []
            for rank, (_score, _l1, metrics, candidate_blocks, moves, origin) in enumerate(items, start=1):
                path = os.path.join(out_dir, "candidates", "distance{}_rank{}_score{}.json".format(distance, rank, metrics["score"]))
                save_candidate(path, candidate_blocks, v, ks, lam, metrics, args.turyn_json, origin, moves)
                saved_best[str(distance)].append({
                    "path": path,
                    "score": int(metrics["score"]),
                    "l1_error": int(metrics["l1_error"]),
                    "max_abs_error": int(metrics["max_abs_error"]),
                    "nonzero_defect_count": int(metrics["nonzero_defect_count"]),
                    "padic_moments": metrics["padic_moments"],
                    "moment_zero_count_3": int(metrics["moment_zero_count_3"]),
                    "moment_zero_count_6": int(metrics["moment_zero_count_6"]),
                })

        distance_summaries = {int(distance): summarize_rows(rows) for distance, rows in rows_by_distance.items()}
        run_config = {
            "script": SCRIPT_NAME,
            "turyn_json": args.turyn_json,
            "exact_candidate": exact_path,
            "v": v,
            "n": 4 * v,
            "ks": list(ks),
            "lambda": lam,
            "max_distance": int(args.max_distance),
            "samples_per_distance": int(args.samples_per_distance),
            "full_one_swap": bool(args.full_one_swap),
            "seed": int(args.seed),
        }
        write_json(os.path.join(out_dir, "run_config.json"), run_config)
        write_json(os.path.join(out_dir, "distance_summaries.json"), distance_summaries)
        write_json(os.path.join(out_dir, "best_records.json"), saved_best)
        write_summary(out_dir, exact_metrics, distance_summaries, saved_best, exact_path)
        print("CSV:", csv_path)
        print("SUMMARY:", os.path.join(out_dir, "perturbation_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
