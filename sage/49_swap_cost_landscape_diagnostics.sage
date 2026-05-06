from sage.all import *

import argparse
import csv
import glob
import json
import math
import os
import random
import statistics
import sys
import time

from sds_repair_utils import (
    apply_delta,
    canonical_hash,
    delta_swap,
    load_candidate,
    metrics_from_counts,
    p_adic_moment_summary,
    setup_logging,
    total_diff_counts,
    write_json,
)


SCRIPT_NAME = "49_swap_cost_landscape_diagnostics"
POWERS = (2, 4, 6, 8, 10, 12)
LOW_POWERS = (2, 4, 6)


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


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
    try:
        json.dumps(value)
        return value
    except TypeError:
        pass
    try:
        int_value = int(value)
        if value == int_value:
            return int_value
    except Exception:
        pass
    try:
        return float(value)
    except Exception:
        return str(value)
    return value


def balanced_abs(residue, modulus):
    residue = int(residue) % int(modulus)
    return min(residue, int(modulus) - residue)


def moment_payload(counts, lam, p):
    high = p_adic_moment_summary(counts, lam, powers=POWERS, modulus=p)
    by_power = {"T{}".format(item["power"]): int(item["residue"]) for item in high["moments"]}
    low_norm = sum(balanced_abs(by_power[key], p) ** 2 for key in ("T2", "T4", "T6"))
    high_tail_norm = sum(balanced_abs(by_power[key], p) ** 2 for key in ("T8", "T10", "T12"))
    return {
        "padic_moments": by_power,
        "moment_zero_count_3": int(sum(1 for key in ("T2", "T4", "T6") if by_power[key] == 0)),
        "moment_zero_count_6": int(high["moment_zero_count"]),
        "moment_abs_sum_6": int(high["moment_abs_sum"]),
        "low_moment_norm": int(low_norm),
        "higher_moment_norm": int(high_tail_norm),
        "moment_signature_6": high["moment_signature"],
    }


def candidate_id_from_path(path, fallback):
    name = os.path.basename(path)
    if "score164" in name:
        return "score164"
    if "score176_seed101_step8576" in name:
        return "score176"
    if "score424_moment_preserving" in name:
        return "score424_moment000"
    if "score284_moment_balanced" in name:
        return "score284_moment006"
    if "distance1_rank1_score48" in name:
        return "428_distance1_best_score48"
    if "distance2_rank2_score80" in name:
        return "428_distance2_best_nonzero_score80"
    if "exact_428" in name:
        return "428_exact"
    return fallback


def find_candidate_by_score(score, preferred_names):
    candidates = []
    for name in preferred_names:
        path = os.path.join("outputs", "candidates", "near_hits", name)
        if os.path.exists(path):
            candidates.append(path)
    pattern = os.path.join("outputs", "candidates", "near_hits", "**", "*score{}*.json".format(score))
    candidates.extend(sorted(glob.glob(pattern, recursive=True)))
    seen = set()
    for path in candidates:
        if path in seen:
            continue
        seen.add(path)
        try:
            data, p, _n, _ks, lam, blocks = load_candidate(path)
            if int(p) != 167:
                continue
            counts = total_diff_counts(p, blocks)
            metrics = metrics_from_counts(counts, lam)
            if int(metrics[0]) == int(score) and int(data.get("score", -1)) == int(score):
                return path
        except Exception:
            continue
    raise RuntimeError("could not find valid score={} candidate".format(score))


def optional_existing(path):
    return path if path and os.path.exists(path) else None


def diff_distribution_block(block, p):
    values = list(block)
    counts = [0] * int(p)
    for x in values:
        for y in values:
            counts[(int(x) - int(y)) % int(p)] += 1
    return counts


def additive_energy(block, p):
    counts = diff_distribution_block(block, p)
    return int(sum(int(x) * int(x) for x in counts))


def ap_count(block, p):
    p = int(p)
    values = [int(x) for x in block]
    pair_sums = [0] * p
    for x in values:
        for y in values:
            pair_sums[(x + y) % p] += 1
    return int(sum(pair_sums[(2 * z) % p] for z in values))


def q_formula_block(block, p):
    p = int(p)
    k = len(block)
    energy = additive_energy(block, p)
    ap = ap_count(block, p)
    value = k * (p - k) * (4 * k - 6) - 6 * (k ** 3) + 8 * energy + 2 * (p - 2 * k) * ap
    return int(value), int(energy), int(ap)


def direct_q_block(block, p):
    p = int(p)
    outside = [x for x in range(p) if x not in block]
    total_q = 0
    count = 0
    for removed in sorted(block):
        for added in outside:
            delta = delta_swap(p, block, int(removed), int(added))
            total_q += sum(int(delta[d]) * int(delta[d]) for d in range(1, p))
            count += 1
    return int(total_q), int(count)


def random_block_stats(k, p, samples, rng):
    if samples <= 0:
        return None
    energies = []
    aps = []
    universe = list(range(int(p)))
    for _ in range(int(samples)):
        block = set(rng.sample(universe, int(k)))
        energies.append(additive_energy(block, p))
        aps.append(ap_count(block, p))
    return {
        "samples": int(samples),
        "energy_mean": float(sum(energies) / len(energies)),
        "energy_min": int(min(energies)),
        "energy_max": int(max(energies)),
        "ap_mean": float(sum(aps) / len(aps)),
        "ap_min": int(min(aps)),
        "ap_max": int(max(aps)),
    }


def quantile(values, frac):
    if not values:
        return None
    values = sorted(values)
    idx = int(float(frac) * (len(values) - 1))
    return values[idx]


def median(values):
    if not values:
        return None
    return statistics.median(values)


def safe_ratio(num, den):
    if den == 0:
        return None
    return float(num) / float(den)


def metric_record(counts, lam, p):
    metrics = metrics_from_counts(counts, lam)
    return {
        "score": int(metrics[0]),
        "l1_error": int(metrics[1]),
        "max_abs_error": int(metrics[2]),
        "nonzero_defect_count": int(metrics[3]),
        **moment_payload(counts, lam, p),
    }


def moment_distance(record, keys):
    p = None
    # caller passes balanced residues only through record values, so no modulus needed here.
    return sum(int(record[key]) * int(record[key]) for key in keys)


def analyze_candidate(path, candidate_id, out_dir, write_swap_csv=False, random_baseline_samples=50, seed=1):
    data, p, n, ks, lam, blocks = load_candidate(path)
    counts = total_diff_counts(p, blocks)
    metrics = metrics_from_counts(counts, lam)
    record = metric_record(counts, lam, p)
    rho = [0] * p
    for d in range(1, p):
        rho[d] = int(counts[d] - lam)
    score = int(metrics[0])
    candidate_hash = data.get("canonical_hash") or canonical_hash(blocks, ks, p)
    rng = random.Random(int(seed) + int(score) + int(p))

    block_rows = []
    q_formula_total = 0
    q_direct_total_by_block = 0
    for block_idx, block in enumerate(blocks):
        q_formula, energy, ap = q_formula_block(block, p)
        q_direct, swap_count = direct_q_block(block, p)
        q_formula_total += int(q_formula)
        q_direct_total_by_block += int(q_direct)
        baseline = random_block_stats(len(block), p, random_baseline_samples, rng)
        block_rows.append({
            "candidate_id": candidate_id,
            "path": path,
            "p": int(p),
            "block_index": int(block_idx),
            "k": int(len(block)),
            "E": int(energy),
            "AP": int(ap),
            "Q_formula": int(q_formula),
            "Q_direct_contribution": int(q_direct),
            "Q_formula_matches_direct": bool(int(q_formula) == int(q_direct)),
            "swap_count": int(swap_count),
            "Q_contribution_ratio": None,
            "random_baseline": baseline,
        })
    if q_direct_total_by_block:
        for row in block_rows:
            row["Q_contribution_ratio"] = float(row["Q_direct_contribution"]) / float(q_direct_total_by_block)

    swap_csv_path = None
    if write_swap_csv:
        swap_csv_path = os.path.join(out_dir, "swap_table_{}.csv".format(candidate_id))
    csv_file = None
    writer = None
    if swap_csv_path:
        csv_file = open(swap_csv_path, "w", newline="")
        fieldnames = [
            "candidate_id", "block_index", "remove", "add",
            "g", "q", "h", "new_score", "new_l1", "new_max_abs", "new_nonzero",
            "score_delta_verified", "T2", "T4", "T6", "T8", "T10", "T12",
            "low_moment_norm_after", "higher_moment_norm_after",
            "low_moment_improved", "higher_moment_improved",
            "alpha", "alpha_threshold", "alpha_minus_threshold",
        ]
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()

    num_swaps = 0
    sum_g = 0
    sum_q = 0
    sum_h = 0
    h_values = []
    g_values = []
    q_values = []
    alpha_values = []
    alpha_minus_values = []
    improving_count = 0
    h_le_counts = {0: 0, 4: 0, 8: 0, 16: 0}
    score_delta_mismatch_count = 0
    min_h_row = None
    max_alpha_row = None
    low_moment_improving = []
    high_moment_improving = []
    low_before = int(record["low_moment_norm"])
    high_before = int(record["higher_moment_norm"])

    for block_idx, block in enumerate(blocks):
        outside = [x for x in range(p) if x not in block]
        for removed in sorted(block):
            for added in outside:
                delta = delta_swap(p, block, int(removed), int(added))
                g = int(sum(int(rho[d]) * int(delta[d]) for d in range(1, p)))
                q = int(sum(int(delta[d]) * int(delta[d]) for d in range(1, p)))
                h = int(2 * g + q)
                new_counts = apply_delta(counts, delta)
                new_metrics = metrics_from_counts(new_counts, lam)
                score_delta_verified = int(new_metrics[0]) - int(score)
                if score_delta_verified != h:
                    score_delta_mismatch_count += 1
                moment_after = moment_payload(new_counts, lam, p)
                low_after = int(moment_after["low_moment_norm"])
                high_after = int(moment_after["higher_moment_norm"])
                alpha = None
                alpha_threshold = None
                alpha_minus_threshold = None
                if score > 0 and q > 0:
                    alpha = float(-g) / math.sqrt(float(score) * float(q))
                    alpha_threshold = 0.5 * math.sqrt(float(q) / float(score))
                    alpha_minus_threshold = alpha - alpha_threshold
                    alpha_values.append(alpha)
                    alpha_minus_values.append(alpha_minus_threshold)

                row = {
                    "candidate_id": candidate_id,
                    "block_index": int(block_idx),
                    "remove": int(removed),
                    "add": int(added),
                    "g": int(g),
                    "q": int(q),
                    "h": int(h),
                    "new_score": int(new_metrics[0]),
                    "new_l1": int(new_metrics[1]),
                    "new_max_abs": int(new_metrics[2]),
                    "new_nonzero": int(new_metrics[3]),
                    "score_delta_verified": int(score_delta_verified),
                    "low_moment_norm_after": int(low_after),
                    "higher_moment_norm_after": int(high_after),
                    "low_moment_improved": bool(low_after < low_before),
                    "higher_moment_improved": bool(high_after < high_before),
                    "alpha": alpha,
                    "alpha_threshold": alpha_threshold,
                    "alpha_minus_threshold": alpha_minus_threshold,
                }
                for key, value in moment_after["padic_moments"].items():
                    row[key] = int(value)
                if writer:
                    writer.writerow(row)
                num_swaps += 1
                sum_g += g
                sum_q += q
                sum_h += h
                h_values.append(h)
                g_values.append(g)
                q_values.append(q)
                if h < 0:
                    improving_count += 1
                for threshold in h_le_counts:
                    if h <= threshold:
                        h_le_counts[threshold] += 1
                if min_h_row is None or h < min_h_row["h"]:
                    min_h_row = dict(row)
                if alpha is not None and (max_alpha_row is None or alpha > max_alpha_row["alpha"]):
                    max_alpha_row = dict(row)
                if row["low_moment_improved"]:
                    low_moment_improving.append(row)
                if row["higher_moment_improved"]:
                    high_moment_improving.append(row)

    if csv_file:
        csv_file.close()

    expected_sum_g = int(-2 * (p - 1) * score)
    expected_sum_h = int(-4 * (p - 1) * score + q_formula_total)
    threshold = int(4 * (p - 1) * score)
    alpha_at_min_h = min_h_row.get("alpha") if min_h_row else None
    q_at_min_h = min_h_row.get("q") if min_h_row else None
    g_at_min_h = min_h_row.get("g") if min_h_row else None
    improvement_threshold_at_min_h = min_h_row.get("alpha_threshold") if min_h_row else None
    max_alpha_minus_threshold = max(alpha_minus_values) if alpha_minus_values else None
    d_min_1 = int(score + (min(h_values) if h_values else 0))

    low_moment_h = [row["h"] for row in low_moment_improving]
    high_moment_h = [row["h"] for row in high_moment_improving]
    low_moment_q = [row["q"] for row in low_moment_improving]
    high_moment_q = [row["q"] for row in high_moment_improving]

    summary = {
        "candidate_id": candidate_id,
        "path": path,
        "p": int(p),
        "n": int(n),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "canonical_hash": candidate_hash,
        "stored_score": int(data.get("score", -1)),
        "score": int(score),
        "l1_error": int(metrics[1]),
        "max_abs_error": int(metrics[2]),
        "nonzero_defect_count": int(metrics[3]),
        "metrics_match": bool(int(data.get("score", score)) == int(score)),
        "padic_moments": record["padic_moments"],
        "moment_zero_count_3": int(record["moment_zero_count_3"]),
        "moment_zero_count_6": int(record["moment_zero_count_6"]),
        "low_moment_norm": int(record["low_moment_norm"]),
        "higher_moment_norm": int(record["higher_moment_norm"]),
        "num_swaps": int(num_swaps),
        "sum_g": int(sum_g),
        "expected_sum_g": int(expected_sum_g),
        "sum_g_match": bool(sum_g == expected_sum_g),
        "sum_q_direct": int(sum_q),
        "sum_q_direct_by_block": int(q_direct_total_by_block),
        "sum_q_formula": int(q_formula_total),
        "sum_q_match": bool(sum_q == q_formula_total == q_direct_total_by_block),
        "sum_h": int(sum_h),
        "expected_sum_h": int(expected_sum_h),
        "sum_h_match": bool(sum_h == expected_sum_h),
        "score_delta_mismatch_count": int(score_delta_mismatch_count),
        "avg_g": float(sum_g) / float(num_swaps) if num_swaps else None,
        "avg_q": float(sum_q) / float(num_swaps) if num_swaps else None,
        "avg_h": float(sum_h) / float(num_swaps) if num_swaps else None,
        "min_g": int(min(g_values)) if g_values else None,
        "min_q": int(min(q_values)) if q_values else None,
        "min_h": int(min(h_values)) if h_values else None,
        "max_h": int(max(h_values)) if h_values else None,
        "median_h": float(median(h_values)) if h_values else None,
        "p1_h": int(quantile(h_values, 0.01)) if h_values else None,
        "p5_h": int(quantile(h_values, 0.05)) if h_values else None,
        "p10_h": int(quantile(h_values, 0.10)) if h_values else None,
        "improving_swap_count": int(improving_count),
        "near_improving_count_h_le_0": int(h_le_counts[0]),
        "near_improving_count_h_le_4": int(h_le_counts[4]),
        "near_improving_count_h_le_8": int(h_le_counts[8]),
        "near_improving_count_h_le_16": int(h_le_counts[16]),
        "threshold_4_p_minus_1_score": int(threshold),
        "Q_ratio": safe_ratio(q_formula_total, threshold),
        "avg_delta_score": safe_ratio(q_formula_total - threshold, num_swaps),
        "D_min_1": int(d_min_1),
        "D_min_ratio": safe_ratio(d_min_1, score),
        "min_h_over_score": safe_ratio(min(h_values), score) if h_values else None,
        "max_alpha": max(alpha_values) if alpha_values else None,
        "alpha_at_min_h": alpha_at_min_h,
        "q_at_min_h": q_at_min_h,
        "g_at_min_h": g_at_min_h,
        "improvement_threshold_at_min_h": improvement_threshold_at_min_h,
        "max_alpha_minus_threshold": max_alpha_minus_threshold,
        "min_h_row": min_h_row,
        "max_alpha_row": max_alpha_row,
        "moment_change_relation": {
            "low_moment_norm_before": int(low_before),
            "higher_moment_norm_before": int(high_before),
            "low_moment_improving_swap_count": int(len(low_moment_improving)),
            "higher_moment_improving_swap_count": int(len(high_moment_improving)),
            "low_moment_improving_h_min": int(min(low_moment_h)) if low_moment_h else None,
            "low_moment_improving_h_median": float(median(low_moment_h)) if low_moment_h else None,
            "low_moment_improving_q_median": float(median(low_moment_q)) if low_moment_q else None,
            "higher_moment_improving_h_min": int(min(high_moment_h)) if high_moment_h else None,
            "higher_moment_improving_h_median": float(median(high_moment_h)) if high_moment_h else None,
            "higher_moment_improving_q_median": float(median(high_moment_q)) if high_moment_q else None,
            "score_improving_and_low_moment_improving_count": int(sum(1 for row in low_moment_improving if row["h"] < 0)),
            "score_improving_and_higher_moment_improving_count": int(sum(1 for row in high_moment_improving if row["h"] < 0)),
        },
        "swap_csv": swap_csv_path,
    }
    return summary, block_rows


def write_summary(out_dir, diagnostics, block_rows):
    by_id = {item["candidate_id"]: item for item in diagnostics}
    lines = []
    lines.append("# Swap-cost Landscape Diagnostics")
    lines.append("")
    lines.append("This is a hardness diagnostic for low-score near-hits. It is not a Hadamard 668 construction claim.")
    lines.append("")
    lines.append("## Identity Checks")
    lines.append("")
    lines.append("| candidate | score | sum_g ok | Q formula ok | sum_h ok | score delta mismatches |")
    lines.append("|---|---:|---:|---:|---:|---:|")
    for item in diagnostics:
        lines.append("| `{}` | {} | {} | {} | {} | {} |".format(
            item["candidate_id"],
            item["score"],
            item["sum_g_match"],
            item["sum_q_match"],
            item["sum_h_match"],
            item["score_delta_mismatch_count"],
        ))
    lines.append("")
    lines.append("## 668 Hardness")
    lines.append("")
    lines.append("| candidate | score | min_h | improving swaps | Q_ratio | D_min_ratio | max_alpha | max_alpha_minus_threshold |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
    for cid in ("score164", "score176", "score284_moment006", "score424_moment000"):
        item = by_id.get(cid)
        if not item:
            continue
        lines.append("| `{}` | {} | {} | {} | {} | {} | {} | {} |".format(
            cid,
            item["score"],
            item["min_h"],
            item["improving_swap_count"],
            "{:.6f}".format(item["Q_ratio"]) if item["Q_ratio"] is not None else "NA",
            "{:.6f}".format(item["D_min_ratio"]) if item["D_min_ratio"] is not None else "NA",
            "{:.6f}".format(item["max_alpha"]) if item["max_alpha"] is not None else "NA",
            "{:.6f}".format(item["max_alpha_minus_threshold"]) if item["max_alpha_minus_threshold"] is not None else "NA",
        ))
    lines.append("")
    lines.append("## 428 Comparison")
    lines.append("")
    lines.append("| candidate | p | score | min_h | improving swaps | Q_ratio | D_min_ratio | interpretation |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---|")
    for cid in ("428_exact", "428_distance1_best_score48", "428_distance2_best_nonzero_score80"):
        item = by_id.get(cid)
        if not item:
            continue
        if item["score"] == 0:
            interp = "exact SDS; ratios with score denominator are not defined"
        elif item["D_min_1"] == 0:
            interp = "has a one-swap return/improvement to exact or lower score"
        elif item["improving_swap_count"] > 0:
            interp = "has downhill one-swap directions"
        else:
            interp = "no downhill one-swap direction"
        lines.append("| `{}` | {} | {} | {} | {} | {} | {} | {} |".format(
            cid,
            item["p"],
            item["score"],
            item["min_h"],
            item["improving_swap_count"],
            "{:.6f}".format(item["Q_ratio"]) if item["Q_ratio"] is not None else "NA",
            "{:.6f}".format(item["D_min_ratio"]) if item["D_min_ratio"] is not None else "NA",
            interp,
        ))
    lines.append("")
    lines.append("## Block-level Notes")
    lines.append("")
    grouped = {}
    for row in block_rows:
        grouped.setdefault(row["candidate_id"], []).append(row)
    for cid in ("score164", "score176"):
        rows = grouped.get(cid, [])
        if not rows:
            continue
        worst = max(rows, key=lambda row: row["Q_direct_contribution"])
        lines.append("- `{}` largest Q contribution: block `{}` k `{}` Q `{}` ratio `{:.4f}` E `{}` AP `{}`.".format(
            cid,
            worst["block_index"],
            worst["k"],
            worst["Q_direct_contribution"],
            worst["Q_contribution_ratio"],
            worst["E"],
            worst["AP"],
        ))
    lines.append("")
    lines.append("## Moment-change Relation")
    lines.append("")
    for cid in ("score164", "score176"):
        item = by_id.get(cid)
        if not item:
            continue
        rel = item["moment_change_relation"]
        lines.append("- `{}`: low-moment improving swaps `{}`; best h among them `{}`; median h `{}`. Higher-moment improving swaps `{}`; best h `{}`; median h `{}`.".format(
            cid,
            rel["low_moment_improving_swap_count"],
            rel["low_moment_improving_h_min"],
            rel["low_moment_improving_h_median"],
            rel["higher_moment_improving_swap_count"],
            rel["higher_moment_improving_h_min"],
            rel["higher_moment_improving_h_median"],
        ))
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    lines.append("1. `Q_tot` formula versus direct `sum_q`: see Identity Checks; mismatches are explicit if any.")
    lines.append("2. `sum_g = -2(p-1)S`: see Identity Checks.")
    for cid in ("score164", "score176"):
        item = by_id.get(cid)
        if item:
            lines.append("3. `{}` Q_ratio: `{}`.".format(cid, item["Q_ratio"]))
    lines.append("4. `score164` and `score176` have positive `min_h` and zero improving 1-swaps if the table above reports that, meaning they are true 1-swap local minima.")
    lines.append("5. The block-level section identifies which block contributes most to movement cost.")
    lines.append("6. 428 perturbations differ if they have `D_min_1=0` or negative `min_h`; that means a one-swap return direction exists, unlike a false basin with positive `min_h`.")
    lines.append("7. Moment-improving swaps are reported separately; if their median h is positive, moment improvement is not aligned with score descent.")
    lines.append("8. If 668 minima have no downhill one-swap but 428 perturbations do, the next mechanism should be coherent multi-swap / pair-level repair rather than more score-only 1-swap repair.")
    lines.append("")
    lines.append("## Safety")
    lines.append("")
    lines.append("- No score-nonzero candidate is a solution.")
    lines.append("- `T2/T4/T6=0` remains a necessary diagnostic, not a success condition.")
    lines.append("- This is not a nonexistence proof; filtered 2/3-swap results remain separate from this full 1-swap certificate.")
    with open(os.path.join(out_dir, "swap_cost_summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Diagnose full 1-swap g/q/h cost landscape for Hadamard SDS near-hits.")
    parser.add_argument("--score164-path", default="")
    parser.add_argument("--score176-path", default="")
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--random-baseline-samples", type=int, default=50)
    parser.add_argument("--include-optional-668", action="store_true")
    parser.add_argument("--seed", type=int, default=49)
    return parser.parse_args()


def main():
    args = parse_args()
    out_dir = args.out_dir or os.path.join(
        "outputs",
        "explorations",
        "{}_hadamard_swap_cost_landscape_diagnostics".format(now_stamp()),
    )
    ensure_dir(out_dir)
    ensure_dir(os.path.join(out_dir, "raw"))
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        score164 = args.score164_path or find_candidate_by_score(164, ["near_hit_v167_score164_steepest_swap_descent_round1.json"])
        score176 = args.score176_path or find_candidate_by_score(176, ["near_hit_v167_score176_seed101_step8576.json"])
        targets = [
            ("score164", score164, True),
            ("score176", score176, True),
        ]
        if args.include_optional_668:
            optional = [
                ("score284_moment006", optional_existing("outputs/candidates/near_hits/near_hit_v167_score284_moment_balanced_multiswap_repair_round2.json"), False),
                ("score424_moment000", optional_existing("outputs/candidates/near_hits/near_hit_v167_score424_moment_preserving_score_repair_round1.json"), False),
            ]
            targets.extend([item for item in optional if item[1]])
        targets.extend([
            ("428_exact", optional_existing("outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/exact_428_sds_candidate.json"), False),
            ("428_distance1_best_score48", optional_existing("outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance1_rank1_score48.json"), True),
            ("428_distance2_best_nonzero_score80", optional_existing("outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/candidates/distance2_rank2_score80.json"), False),
        ])
        targets = [(cid, path, csv_flag) for cid, path, csv_flag in targets if path]
        run_config = {
            "script": SCRIPT_NAME,
            "out_dir": out_dir,
            "targets": [{"candidate_id": cid, "path": path, "write_swap_csv": csv_flag} for cid, path, csv_flag in targets],
            "random_baseline_samples": int(args.random_baseline_samples),
            "seed": int(args.seed),
        }
        write_json(os.path.join(out_dir, "run_config.json"), run_config)
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# Run Log\n\n")
            f.write("- timestamp: `{}`\n".format(time.strftime("%Y-%m-%dT%H:%M:%S")))
            f.write("- script: `{}`\n".format(SCRIPT_NAME))
            f.write("- output dir: `{}`\n".format(out_dir))
            f.write("- targets: `{}`\n".format([cid for cid, _path, _csv in targets]))
        diagnostics = []
        block_rows = []
        candidate_jsonl = os.path.join(out_dir, "candidate_diagnostics.jsonl")
        block_jsonl = os.path.join(out_dir, "block_decomposition.jsonl")
        with open(candidate_jsonl, "w") as f_diag, open(block_jsonl, "w") as f_block:
            for cid, path, write_csv in targets:
                print("Analyzing {} path={} write_csv={}".format(cid, path, write_csv))
                summary, blocks = analyze_candidate(
                    path,
                    cid,
                    out_dir,
                    write_swap_csv=write_csv,
                    random_baseline_samples=int(args.random_baseline_samples),
                    seed=int(args.seed),
                )
                diagnostics.append(summary)
                block_rows.extend(blocks)
                f_diag.write(json.dumps(json_safe(summary), sort_keys=True) + "\n")
                for row in blocks:
                    f_block.write(json.dumps(json_safe(row), sort_keys=True) + "\n")
                write_json(os.path.join(out_dir, "raw", "{}_diagnostics.json".format(cid)), json_safe(summary))
        write_summary(out_dir, diagnostics, block_rows)
        print("OUT_DIR:", out_dir)
        print("SUMMARY:", os.path.join(out_dir, "swap_cost_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
