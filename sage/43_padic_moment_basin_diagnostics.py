#!/usr/bin/env python3

import argparse
import glob
import json
import math
import os
import time
from collections import Counter, defaultdict


METRIC_KEYS = ("score", "l1_error", "max_abs_error", "nonzero_defect_count")
MOMENT_POWERS = (2, 4, 6)
MOMENT_POWERS_6 = (2, 4, 6, 8, 10, 12)


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)


def write_json(path, payload):
    ensure_dir(os.path.dirname(path) or ".")
    with open(path, "w") as f:
        json.dump(payload, f, indent=2, sort_keys=True)


def write_text(path, text):
    ensure_dir(os.path.dirname(path) or ".")
    with open(path, "w") as f:
        f.write(text)


def total_diff_counts(v, blocks):
    total = [0] * int(v)
    for block in blocks:
        values = list(block)
        for x in values:
            for y in values:
                if x != y:
                    total[(x - y) % int(v)] += 1
    return total


def metrics_from_counts(counts, lam):
    score = 0
    l1_error = 0
    max_abs_error = 0
    nonzero_defect_count = 0
    for d in range(1, len(counts)):
        err = int(counts[d] - lam)
        abs_err = abs(err)
        score += err * err
        l1_error += abs_err
        max_abs_error = max(max_abs_error, abs_err)
        if err:
            nonzero_defect_count += 1
    return (score, l1_error, max_abs_error, nonzero_defect_count)


def defect_vector(counts, lam):
    return [int(counts[d] - lam) for d in range(1, len(counts))]


def p_adic_moment_summary(counts, lam, powers=MOMENT_POWERS, modulus=None):
    if modulus is None:
        modulus = len(counts)
    modulus = int(modulus)
    moments = []
    zero_count = 0
    abs_sum = 0
    for power in powers:
        total = 0
        for d in range(1, len(counts)):
            total += int(counts[d] - lam) * pow(d % modulus, int(power), modulus)
        residue = int(total % modulus)
        balanced_abs = min(residue, modulus - residue)
        zero = residue == 0
        if zero:
            zero_count += 1
        abs_sum += balanced_abs
        moments.append(
            {
                "power": int(power),
                "residue": residue,
                "balanced_abs": int(balanced_abs),
                "zero": bool(zero),
            }
        )
    return {
        "modulus": modulus,
        "powers": [int(power) for power in powers],
        "moments": moments,
        "moment_signature": ",".join(str(item["residue"]) for item in moments),
        "moment_zero_count": int(zero_count),
        "moment_all_zero": bool(zero_count == len(moments)),
        "moment_abs_sum": int(abs_sum),
    }


def metric_tuple(record):
    return tuple(int(record[key]) for key in METRIC_KEYS)


def moment_rank_tuple(record):
    return (
        -int(record["moment_zero_count"]),
        int(record["moment_abs_sum"]),
        int(record["score"]),
        int(record["l1_error"]),
        int(record["max_abs_error"]),
        int(record["nonzero_defect_count"]),
        record["path"],
    )


def score_rank_tuple(record):
    return metric_tuple(record) + (record["path"],)


def parameter_key(record):
    return (tuple(int(k) for k in record["ks"]), int(record["lambda"]))


def dominates(left, right):
    lm = metric_tuple(left)
    rm = metric_tuple(right)
    return all(a <= b for a, b in zip(lm, rm)) and any(a < b for a, b in zip(lm, rm))


def compact(record, include_defect=False):
    keys = [
        "path",
        "canonical_hash",
        "ks",
        "lambda",
        "score",
        "l1_error",
        "max_abs_error",
        "nonzero_defect_count",
        "moment_signature",
        "moment_zero_count",
        "moment_abs_sum",
        "moment_all_zero",
        "source_type",
        "objective_schedule",
        "seed",
        "step",
    ]
    out = {key: record.get(key) for key in keys}
    out["p_adic_moments"] = record.get("p_adic_moments", {})
    if include_defect:
        out["defect_vector"] = record.get("defect_vector", [])
    return out


def infer_source_type(path, data):
    method = str(data.get("search_method") or "")
    name = os.path.basename(path)
    if "guided" in method or "07_guided" in name:
        return "guided"
    if "steepest" in method or "steepest" in name:
        return "steepest"
    if "beam" in method or "beam" in name:
        return "beam"
    if "ilp" in method or "ilp" in name:
        return "ilp"
    if "frontier" in path:
        return "frontier_copy"
    if "one_block" in method or "one_block" in name:
        return "one_block_completion"
    return "unknown"


def load_records(pattern, target_v=167, target_n=668):
    paths = sorted(set(glob.glob(pattern, recursive=True)))
    records = []
    invalid = []
    mismatches = []
    for path in paths:
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception as exc:
            invalid.append({"path": path, "reason": "json_error:{}".format(exc)})
            continue
        if not isinstance(data, dict):
            invalid.append({"path": path, "reason": "not_object"})
            continue
        required = ["v", "n", "ks", "lambda", "blocks"]
        missing = [key for key in required if key not in data]
        if missing:
            invalid.append({"path": path, "reason": "missing:{}".format(missing)})
            continue
        try:
            v = int(data["v"])
            n = int(data["n"])
            if v != int(target_v) or n != int(target_n):
                continue
            lam = int(data["lambda"])
            blocks = [set(int(x) for x in block) for block in data["blocks"]]
            counts = total_diff_counts(v, blocks)
            recomputed = metrics_from_counts(counts, lam)
            moment = p_adic_moment_summary(counts, lam, powers=MOMENT_POWERS, modulus=v)
            moment6 = p_adic_moment_summary(counts, lam, powers=MOMENT_POWERS_6, modulus=v)
            saved = tuple(int(data.get(key, recomputed[idx])) for idx, key in enumerate(METRIC_KEYS))
            vec = defect_vector(counts, lam)
        except Exception as exc:
            invalid.append({"path": path, "reason": "parse_error:{}".format(exc)})
            continue
        if saved != recomputed:
            mismatches.append(
                {"path": path, "saved": list(saved), "recomputed": list(recomputed)}
            )
        record = {
            "path": path,
            "v": v,
            "n": n,
            "ks": [int(k) for k in data["ks"]],
            "lambda": lam,
            "score": int(recomputed[0]),
            "l1_error": int(recomputed[1]),
            "max_abs_error": int(recomputed[2]),
            "nonzero_defect_count": int(recomputed[3]),
            "saved_metrics": list(saved),
            "metrics_match": bool(saved == recomputed),
            "canonical_hash": data.get("canonical_hash", ""),
            "source_type": infer_source_type(path, data),
            "search_method": data.get("search_method", ""),
            "objective_schedule": data.get("objective_schedule")
            or data.get("objective")
            or data.get("diagnostic_objective")
            or "",
            "seed": data.get("seed"),
            "step": data.get("step"),
            "defect_vector": vec,
            "p_adic_moments": moment,
            "moment_signature": moment["moment_signature"],
            "moment_zero_count": int(moment["moment_zero_count"]),
            "moment_abs_sum": int(moment["moment_abs_sum"]),
            "moment_all_zero": bool(moment["moment_all_zero"]),
            "p_adic_moments_6": moment6,
            "moment_signature_6": moment6["moment_signature"],
            "moment_zero_count_6": int(moment6["moment_zero_count"]),
            "moment_abs_sum_6": int(moment6["moment_abs_sum"]),
            "moment_all_zero_6": bool(moment6["moment_all_zero"]),
        }
        records.append(record)
    return paths, records, invalid, mismatches


def pearson(xs, ys):
    if len(xs) < 2:
        return None
    mx = sum(xs) / len(xs)
    my = sum(ys) / len(ys)
    vx = sum((x - mx) ** 2 for x in xs)
    vy = sum((y - my) ** 2 for y in ys)
    if vx == 0 or vy == 0:
        return None
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / math.sqrt(vx * vy)


def summarize(records, paths, invalid, mismatches):
    by_param = defaultdict(list)
    for record in records:
        by_param[parameter_key(record)].append(record)

    param_summary = []
    for key, group in sorted(by_param.items()):
        moment_all_zero = [record for record in group if record["moment_all_zero"]]
        param_summary.append(
            {
                "ks": list(key[0]),
                "lambda": key[1],
                "count": len(group),
                "moment_zero_count_histogram": dict(
                    sorted(Counter(record["moment_zero_count"] for record in group).items())
                ),
                "moment_all_zero_count": len(moment_all_zero),
                "best_by_score": compact(min(group, key=score_rank_tuple)),
                "best_by_moment_then_score": compact(min(group, key=moment_rank_tuple)),
                "best_moment_all_zero_by_score": (
                    compact(min(moment_all_zero, key=score_rank_tuple)) if moment_all_zero else None
                ),
            }
        )

    branches = {
        "score164": ((73, 78, 79, 81), 144, (164, 116, 3, 96)),
        "score176": ((73, 78, 79, 81), 144, (176, 112, 3, 86)),
        "low_nonzero184": ((73, 76, 83, 83), 148, (184, 112, 3, 80)),
        "maxabs2_172": ((73, 76, 83, 83), 148, (172, 128, 2, 106)),
        "maxabs2_184": ((73, 78, 79, 81), 144, (184, 124, 2, 94)),
        "maxabs2_nonzero86": ((73, 78, 79, 81), 144, (200, 124, 2, 86)),
    }
    branch_summary = {}
    for name, (ks, lam, metrics) in branches.items():
        matches = [
            record
            for record in records
            if tuple(record["ks"]) == tuple(ks)
            and int(record["lambda"]) == int(lam)
            and metric_tuple(record) == tuple(metrics)
        ]
        branch_summary[name] = {
            "expected": {"ks": list(ks), "lambda": lam, "metrics": list(metrics)},
            "count": len(matches),
            "representative": compact(matches[0], include_defect=True) if matches else None,
        }

    moment_all_zero = [record for record in records if record["moment_all_zero"]]
    moment_all_zero_6 = [record for record in records if record["moment_all_zero_6"]]
    moment_two_or_more = [record for record in records if record["moment_zero_count"] >= 2]
    metric_correlations = []
    for key in METRIC_KEYS:
        metric_correlations.append(
            {
                "metric": key,
                "pearson_with_moment_zero_count": pearson(
                    [record[key] for record in records],
                    [record["moment_zero_count"] for record in records],
                ),
                "pearson_with_moment_abs_sum": pearson(
                    [record[key] for record in records],
                    [record["moment_abs_sum"] for record in records],
                ),
            }
        )

    return {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "total_json_files": len(paths),
        "valid_near_hits": len(records),
        "invalid_or_skipped_json": len(invalid),
        "metrics_mismatch_count": len(mismatches),
        "unique_canonical_hashes": len(
            set(record["canonical_hash"] for record in records if record["canonical_hash"])
        ),
        "moment_powers": list(MOMENT_POWERS),
        "moment_powers_6": list(MOMENT_POWERS_6),
        "moment_zero_count_histogram": dict(
            sorted(Counter(record["moment_zero_count"] for record in records).items())
        ),
        "moment_zero_count_histogram_6": dict(
            sorted(Counter(record["moment_zero_count_6"] for record in records).items())
        ),
        "moment_signature_top20": [
            {"signature": key, "count": count}
            for key, count in Counter(record["moment_signature"] for record in records).most_common(20)
        ],
        "moment_all_zero_count": len(moment_all_zero),
        "moment_all_zero_count_6": len(moment_all_zero_6),
        "moment_two_or_more_count": len(moment_two_or_more),
        "best_overall_by_score": compact(min(records, key=score_rank_tuple)) if records else None,
        "best_overall_by_moment_then_score": (
            compact(min(records, key=moment_rank_tuple)) if records else None
        ),
        "best_moment_all_zero_by_score": (
            compact(min(moment_all_zero, key=score_rank_tuple)) if moment_all_zero else None
        ),
        "best_moment_all_zero_6_by_score": (
            compact(min(moment_all_zero_6, key=score_rank_tuple)) if moment_all_zero_6 else None
        ),
        "best_moment_two_or_more_by_score": (
            compact(min(moment_two_or_more, key=score_rank_tuple)) if moment_two_or_more else None
        ),
        "top_moment_then_score": [compact(record) for record in sorted(records, key=moment_rank_tuple)[:50]],
        "top_moment_all_zero_by_score": [
            compact(record) for record in sorted(moment_all_zero, key=score_rank_tuple)[:50]
        ],
        "frontier_branch_moments": branch_summary,
        "counts_by_ks_lambda": param_summary,
        "metric_correlations": metric_correlations,
        "metric_mismatches_first": mismatches[:20],
        "invalid_first": invalid[:20],
    }


def markdown_report(summary):
    lines = []
    lines.append("# p-adic Moment Basin Diagnostics")
    lines.append("")
    lines.append("Diagnostic only. These moment conditions are necessary conditions for SDS, not success certificates.")
    lines.append("")
    lines.append("## Dataset")
    lines.append("")
    lines.append("- valid near-hits: {}".format(summary["valid_near_hits"]))
    lines.append("- unique canonical hashes: {}".format(summary["unique_canonical_hashes"]))
    lines.append("- metrics mismatch count: {}".format(summary["metrics_mismatch_count"]))
    lines.append("- moment powers: {}".format(summary["moment_powers"]))
    lines.append("- extended moment powers: {}".format(summary["moment_powers_6"]))
    lines.append("- moment zero-count histogram: {}".format(summary["moment_zero_count_histogram"]))
    lines.append("- extended moment zero-count histogram: {}".format(summary["moment_zero_count_histogram_6"]))
    lines.append("- all three moments zero: {}".format(summary["moment_all_zero_count"]))
    lines.append("- all six moments zero: {}".format(summary["moment_all_zero_count_6"]))
    lines.append("")
    lines.append("## Best Records")
    lines.append("")
    lines.append("Best by score:")
    lines.append("```json")
    lines.append(json.dumps(summary["best_overall_by_score"], indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("Best by moment then score:")
    lines.append("```json")
    lines.append(json.dumps(summary["best_overall_by_moment_then_score"], indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("Best all-moment-zero by score:")
    lines.append("```json")
    lines.append(json.dumps(summary["best_moment_all_zero_by_score"], indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("Best six-moment-zero by score:")
    lines.append("```json")
    lines.append(json.dumps(summary["best_moment_all_zero_6_by_score"], indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("## Known Branch Moment Signatures")
    lines.append("")
    for name, item in summary["frontier_branch_moments"].items():
        rep = item["representative"]
        if rep is None:
            lines.append("- {}: not found".format(name))
        else:
            lines.append(
                "- {}: metrics=({}, {}, {}, {}), signature={}, zero_count={}, abs_sum={}, path={}".format(
                    name,
                    rep["score"],
                    rep["l1_error"],
                    rep["max_abs_error"],
                    rep["nonzero_defect_count"],
                    rep["moment_signature"],
                    rep["moment_zero_count"],
                    rep["moment_abs_sum"],
                    rep["path"],
                )
            )
    lines.append("")
    lines.append("## Interpretation")
    lines.append("")
    lines.append(
        "Use `moment_zero_count` as a basin classification filter. A near-hit with low score but nonzero low-degree p-adic moments is still outside the exact SDS p-adic shadow."
    )
    lines.append(
        "If all known frontier branches fail `T2=T4=T6=0`, the current frontier should not be treated as privileged solely because of score."
    )
    return "\n".join(lines) + "\n"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Analyze p-adic moment signatures for Hadamard 668 near-hit JSON files."
    )
    parser.add_argument(
        "--near-hit-glob",
        default="outputs/candidates/near_hits/**/*.json",
        help="Recursive glob for candidate/near-hit JSON files.",
    )
    parser.add_argument("--v", type=int, default=167)
    parser.add_argument("--n", type=int, default=668)
    parser.add_argument(
        "--out-dir",
        default=None,
        help="Output directory. Defaults to outputs/explorations/<stamp>_hadamard668_padic_moment_basin.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    out_dir = args.out_dir or os.path.join(
        "outputs",
        "explorations",
        "{}_hadamard668_padic_moment_basin".format(now_stamp()),
    )
    paths, records, invalid, mismatches = load_records(args.near_hit_glob, args.v, args.n)
    summary = summarize(records, paths, invalid, mismatches)
    raw_dir = os.path.join(out_dir, "raw")
    write_json(os.path.join(raw_dir, "padic_moment_basin_summary.json"), summary)
    write_text(os.path.join(out_dir, "padic_moment_basin_summary.md"), markdown_report(summary))
    print("Output dir:", out_dir)
    print("Valid near-hits:", summary["valid_near_hits"])
    print("Moment zero-count histogram:", summary["moment_zero_count_histogram"])
    print("All T2/T4/T6 zero:", summary["moment_all_zero_count"])
    if summary["best_moment_all_zero_by_score"]:
        print("Best all-zero:", summary["best_moment_all_zero_by_score"]["path"])
    else:
        print("Best all-zero: none")


if __name__ == "__main__":
    main()
