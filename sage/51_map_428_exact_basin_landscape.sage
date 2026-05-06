from sage.all import *

import argparse
import csv
import hashlib
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
    json_blocks,
    load_candidate,
    metrics_from_counts,
    p_adic_moment_summary,
    setup_logging,
    total_diff_counts,
    write_json,
)


SCRIPT_NAME = "51_map_428_exact_basin_landscape"
POWERS = (2, 4, 6, 8, 10, 12)


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
        return int(value)
    except Exception:
        pass
    try:
        return float(value)
    except Exception:
        return str(value)


def balanced_abs(residue, modulus):
    residue = int(residue) % int(modulus)
    return min(residue, int(modulus) - residue)


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


def fast_block_hash(blocks, p, ks):
    payload = {
        "v": int(p),
        "ks": [int(k) for k in ks],
        "blocks": [[int(x) for x in sorted(block)] for block in blocks],
    }
    text = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def diff_distribution_block(block, p):
    counts = [0] * int(p)
    values = [int(x) for x in block]
    for x in values:
        for y in values:
            counts[(x - y) % int(p)] += 1
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


def delta_swap_sparse(p, block, removed, added):
    p = int(p)
    removed = int(removed)
    added = int(added)
    out = {}
    for y in block:
        y = int(y)
        if y == removed:
            continue
        for d, coeff in (
            ((removed - y) % p, -1),
            ((y - removed) % p, -1),
            ((added - y) % p, 1),
            ((y - added) % p, 1),
        ):
            if d == 0:
                continue
            value = out.get(d, 0) + coeff
            if value:
                out[d] = value
            elif d in out:
                del out[d]
    return out


def moment_payload(counts, lam, p):
    high = p_adic_moment_summary(counts, lam, powers=POWERS, modulus=p)
    by_power = {"T{}".format(item["power"]): int(item["residue"]) for item in high["moments"]}
    higher_norm = sum(balanced_abs(by_power[key], p) ** 2 for key in ("T8", "T10", "T12"))
    low_norm = sum(balanced_abs(by_power[key], p) ** 2 for key in ("T2", "T4", "T6"))
    return {
        "padic_moments": by_power,
        "moment_zero_count_3": int(sum(1 for key in ("T2", "T4", "T6") if by_power[key] == 0)),
        "moment_zero_count_6": int(high["moment_zero_count"]),
        "moment_abs_sum_6": int(high["moment_abs_sum"]),
        "low_moment_norm": int(low_norm),
        "higher_moment_norm": int(higher_norm),
        "moment_signature_6": high["moment_signature"],
    }


def metric_record(counts, lam, p):
    score, l1_error, max_abs_error, nonzero_defect_count = metrics_from_counts(counts, lam)
    return {
        "score": int(score),
        "l1_error": int(l1_error),
        "max_abs_error": int(max_abs_error),
        "nonzero_defect_count": int(nonzero_defect_count),
        **moment_payload(counts, lam, p),
    }


def apply_swap_in_place(blocks, counts, p, move):
    block_idx = int(move["block"])
    removed = int(move["remove"])
    added = int(move["add"])
    block = blocks[block_idx]
    if removed not in block or added in block:
        return False
    delta = delta_swap(p, block, removed, added)
    new_counts = apply_delta(counts, delta)
    block.remove(removed)
    block.add(added)
    counts[:] = new_counts
    return True


def random_move(rng, blocks, p):
    block_idx = rng.randrange(len(blocks))
    block = blocks[block_idx]
    removed = rng.choice(tuple(block))
    added = rng.randrange(int(p))
    while added in block:
        added = rng.randrange(int(p))
    return {"block": int(block_idx), "remove": int(removed), "add": int(added)}


def random_perturbation(rng, base_blocks, base_counts, distance, p):
    blocks = [set(block) for block in base_blocks]
    counts = list(base_counts)
    moves = []
    for _ in range(int(distance)):
        move = random_move(rng, blocks, p)
        ok = apply_swap_in_place(blocks, counts, p, move)
        if not ok:
            continue
        moves.append(move)
    return blocks, counts, moves


def block_decomposition(blocks, p):
    rows = []
    q_total = 0
    for block_idx, block in enumerate(blocks):
        q_value, energy, ap = q_formula_block(block, p)
        q_total += int(q_value)
        rows.append({
            "block_index": int(block_idx),
            "k": int(len(block)),
            "E": int(energy),
            "AP": int(ap),
            "Q_X": int(q_value),
        })
    for row in rows:
        row["Q_contribution_ratio"] = safe_ratio(row["Q_X"], q_total)
    return rows, int(q_total)


def one_swap_diagnostic(blocks, counts, lam, p):
    score, l1_error, max_abs_error, nonzero_defect_count = metrics_from_counts(counts, lam)
    score = int(score)
    rho = [0] * int(p)
    for d in range(1, int(p)):
        rho[d] = int(counts[d] - lam)

    q_formula_total = int(sum(row["Q_X"] for row in block_decomposition(blocks, p)[0]))
    num_swaps = 0
    sum_g = 0
    sum_q = 0
    sum_h = 0
    min_h = None
    min_h_move = None
    h_values = []
    improving_count = 0

    for block_idx, block in enumerate(blocks):
        outside = [x for x in range(int(p)) if x not in block]
        for removed in sorted(block):
            for added in outside:
                delta = delta_swap_sparse(p, block, int(removed), int(added))
                g = int(sum(int(rho[d]) * int(value) for d, value in delta.items()))
                q = int(sum(int(value) * int(value) for value in delta.values()))
                h = int(2 * g + q)
                num_swaps += 1
                sum_g += g
                sum_q += q
                sum_h += h
                h_values.append(h)
                if h < 0:
                    improving_count += 1
                if min_h is None or h < min_h:
                    min_h = h
                    min_h_move = {
                        "block": int(block_idx),
                        "remove": int(removed),
                        "add": int(added),
                        "g": int(g),
                        "q": int(q),
                        "h": int(h),
                    }

    expected_sum_g = int(-2 * (int(p) - 1) * score)
    expected_sum_h = int(-4 * (int(p) - 1) * score + q_formula_total)
    d_min_1 = int(score + (min_h if min_h is not None else 0))
    threshold = int(4 * (int(p) - 1) * score)
    return {
        "score": int(score),
        "l1_error": int(l1_error),
        "max_abs_error": int(max_abs_error),
        "nonzero_defect_count": int(nonzero_defect_count),
        "num_swaps": int(num_swaps),
        "min_h": int(min_h) if min_h is not None else None,
        "min_h_move": min_h_move,
        "h_min_new_score": int(d_min_1),
        "improving_swap_count": int(improving_count),
        "D_min_1": int(d_min_1),
        "D_min_ratio": safe_ratio(d_min_1, score),
        "Q_tot": int(q_formula_total),
        "Q_ratio": safe_ratio(q_formula_total, threshold),
        "sum_g": int(sum_g),
        "expected_sum_g": int(expected_sum_g),
        "sum_g_match": bool(sum_g == expected_sum_g),
        "sum_q_direct": int(sum_q),
        "sum_q_formula": int(q_formula_total),
        "sum_q_match": bool(sum_q == q_formula_total),
        "sum_h": int(sum_h),
        "expected_sum_h": int(expected_sum_h),
        "sum_h_match": bool(sum_h == expected_sum_h),
        "h_median": float(median(h_values)) if h_values else None,
        "h_p1": int(quantile(h_values, 0.01)) if h_values else None,
        "h_p5": int(quantile(h_values, 0.05)) if h_values else None,
        "h_p10": int(quantile(h_values, 0.10)) if h_values else None,
        "h_values_count": int(len(h_values)),
    }


def candidate_payload(blocks, p, ks, lam, metrics, source, origin, moves, extra=None):
    payload = {
        "v": int(p),
        "n": int(4 * int(p)),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": json_blocks(blocks),
        "score": int(metrics["score"]),
        "l1_error": int(metrics["l1_error"]),
        "max_abs_error": int(metrics["max_abs_error"]),
        "nonzero_defect_count": int(metrics["nonzero_defect_count"]),
        "verify_sds": bool(metrics["score"] == 0),
        "generated_hadamard": False,
        "hh_t": False,
        "construction": "Goethals-Seidel",
        "search_method": SCRIPT_NAME,
        "source_json": source,
        "origin": origin,
        "moves": moves,
        "canonical_hash": fast_block_hash(blocks, p, ks),
        "hash_type": "fast_exact_representative_hash",
        "padic_moments": metrics["padic_moments"],
        "moment_zero_count_3": int(metrics["moment_zero_count_3"]),
        "moment_zero_count_6": int(metrics["moment_zero_count_6"]),
        "higher_moment_norm": int(metrics["higher_moment_norm"]),
        "notes": [
            "428 exact-basin landscape artifact.",
            "Perturbed candidates are calibration diagnostics, not new Hadamard 668 results.",
        ],
    }
    if extra:
        payload.update(extra)
    return payload


def save_candidate(path, blocks, p, ks, lam, metrics, source, origin, moves, extra=None):
    write_json(path, candidate_payload(blocks, p, ks, lam, metrics, source, origin, moves, extra=extra))
    return path


def local_descent(start_blocks, start_counts, lam, p, max_steps=20, mode="steepest"):
    blocks = [set(block) for block in start_blocks]
    counts = list(start_counts)
    history = []
    visited = set()
    rng = random.Random(int(123))
    for step in range(int(max_steps) + 1):
        metrics = metric_record(counts, lam, p)
        state_hash = canonical_hash(blocks, tuple(len(block) for block in blocks), p)
        history.append({
            "step": int(step),
            "score": int(metrics["score"]),
            "l1_error": int(metrics["l1_error"]),
            "max_abs_error": int(metrics["max_abs_error"]),
            "nonzero_defect_count": int(metrics["nonzero_defect_count"]),
            "canonical_hash": state_hash,
        })
        if int(metrics["score"]) == 0:
            return blocks, counts, history, "returned_to_score0"
        if state_hash in visited:
            return blocks, counts, history, "visited_loop"
        visited.add(state_hash)

        best = None
        improving = []
        for block_idx, block in enumerate(blocks):
            outside = [x for x in range(int(p)) if x not in block]
            for removed in sorted(block):
                for added in outside:
                    delta = delta_swap(p, block, int(removed), int(added))
                    new_counts = apply_delta(counts, delta)
                    new_score = int(metrics_from_counts(new_counts, lam)[0])
                    old_score = int(metrics["score"])
                    if new_score < old_score:
                        item = (new_score, block_idx, int(removed), int(added), delta, new_counts)
                        improving.append(item)
                        if best is None or item < best:
                            best = item
        if not improving:
            return blocks, counts, history, "stuck_nonexact_local_minimum"
        if mode == "random_improving":
            best = rng.choice(improving)
        _new_score, block_idx, removed, added, _delta, new_counts = best
        blocks[block_idx].remove(removed)
        blocks[block_idx].add(added)
        counts = list(new_counts)
    return blocks, counts, history, "max_steps_no_return"


def find_candidate_by_score(score):
    preferred = {
        164: ["outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json"],
        176: ["outputs/candidates/near_hits/near_hit_v167_score176_seed101_step8576.json"],
        284: ["outputs/candidates/near_hits/near_hit_v167_score284_moment_balanced_multiswap_repair_round2.json"],
        424: ["outputs/candidates/near_hits/near_hit_v167_score424_moment_preserving_score_repair_round1.json"],
    }
    for path in preferred.get(int(score), []):
        if os.path.exists(path):
            return path
    pattern = os.path.join("outputs", "candidates", "near_hits", "**", "*score{}*.json".format(int(score)))
    for path in sorted(glob.glob(pattern, recursive=True)):
        try:
            _data, p, _n, _ks, lam, blocks = load_candidate(path)
            if int(p) != 167:
                continue
            counts = total_diff_counts(p, blocks)
            if int(metrics_from_counts(counts, lam)[0]) == int(score):
                return path
        except Exception:
            continue
    return None


def find_exact_428(path_arg=""):
    candidates = []
    if path_arg:
        candidates.append(path_arg)
    candidates.extend([
        "outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/exact_428_sds_candidate.json",
    ])
    candidates.extend(sorted(glob.glob("outputs/**/exact_428_sds_candidate.json", recursive=True)))
    for path in candidates:
        if not path or not os.path.exists(path):
            continue
        try:
            _data, p, _n, _ks, lam, blocks = load_candidate(path)
            if int(p) != 107:
                continue
            counts = total_diff_counts(p, blocks)
            if int(metrics_from_counts(counts, lam)[0]) == 0:
                return path
        except Exception:
            continue
    raise RuntimeError("could not find exact 428 SDS candidate JSON")


def make_record(distance, sample_id, blocks, counts, moves, p, ks, lam, origin):
    metrics = metric_record(counts, lam, p)
    return {
        "distance": int(distance),
        "sample_id": int(sample_id),
        "origin": origin,
        "score": int(metrics["score"]),
        "l1_error": int(metrics["l1_error"]),
        "max_abs_error": int(metrics["max_abs_error"]),
        "nonzero_defect_count": int(metrics["nonzero_defect_count"]),
        "T2": int(metrics["padic_moments"]["T2"]),
        "T4": int(metrics["padic_moments"]["T4"]),
        "T6": int(metrics["padic_moments"]["T6"]),
        "T8": int(metrics["padic_moments"]["T8"]),
        "T10": int(metrics["padic_moments"]["T10"]),
        "T12": int(metrics["padic_moments"]["T12"]),
        "moment_zero_count_3": int(metrics["moment_zero_count_3"]),
        "moment_zero_count_6": int(metrics["moment_zero_count_6"]),
        "higher_moment_norm": int(metrics["higher_moment_norm"]),
        "canonical_hash": canonical_hash(blocks, ks, p),
        "moves": json.dumps(moves, sort_keys=True),
        "_blocks": [set(block) for block in blocks],
        "_counts": list(counts),
        "_metrics": metrics,
        "_moves": moves,
    }


def summarize_distance(rows):
    scores = [int(row["score"]) for row in rows]
    hmins = [int(row["h_min"]) for row in rows if row.get("h_min") is not None]
    ratios = [float(row["D_min_ratio"]) for row in rows if row.get("D_min_ratio") is not None]
    qratios = [float(row["Q_ratio"]) for row in rows if row.get("Q_ratio") is not None]
    improving = [int(row["improving_swap_count"]) for row in rows if row.get("improving_swap_count") is not None]
    zero3 = {}
    zero6 = {}
    for row in rows:
        zero3[str(row["moment_zero_count_3"])] = zero3.get(str(row["moment_zero_count_3"]), 0) + 1
        zero6[str(row["moment_zero_count_6"])] = zero6.get(str(row["moment_zero_count_6"]), 0) + 1
    diagnosed = [row for row in rows if row.get("h_min") is not None]
    local_minimum_count = sum(1 for row in diagnosed if row.get("h_min") is not None and int(row["h_min"]) >= 0)
    returned = [row for row in rows if row.get("descent_status")]
    returned_to_exact = sum(1 for row in returned if row.get("descent_status") == "returned_to_score0")
    stuck = sum(1 for row in returned if row.get("descent_status") == "stuck_nonexact_local_minimum")
    return {
        "distance": int(rows[0]["distance"]) if rows else None,
        "sample_count": int(len(rows)),
        "diagnosed_count": int(len(diagnosed)),
        "score_min": int(min(scores)) if scores else None,
        "score_p1": int(quantile(scores, 0.01)) if scores else None,
        "score_p5": int(quantile(scores, 0.05)) if scores else None,
        "score_p10": int(quantile(scores, 0.10)) if scores else None,
        "score_median": float(median(scores)) if scores else None,
        "score_mean": float(sum(scores) / len(scores)) if scores else None,
        "h_min_min": int(min(hmins)) if hmins else None,
        "h_min_p1": int(quantile(hmins, 0.01)) if hmins else None,
        "h_min_p5": int(quantile(hmins, 0.05)) if hmins else None,
        "h_min_median": float(median(hmins)) if hmins else None,
        "h_min_mean": float(sum(hmins) / len(hmins)) if hmins else None,
        "improving_swap_count_median": float(median(improving)) if improving else None,
        "improving_swap_count_zero_count": int(sum(1 for x in improving if x == 0)),
        "local_minimum_rate_among_diagnosed": safe_ratio(local_minimum_count, len(diagnosed)),
        "local_minimum_count": int(local_minimum_count),
        "D_min_ratio_min": float(min(ratios)) if ratios else None,
        "D_min_ratio_p5": float(quantile(ratios, 0.05)) if ratios else None,
        "D_min_ratio_median": float(median(ratios)) if ratios else None,
        "D_min_ratio_gt_1_count": int(sum(1 for x in ratios if x > 1.0)),
        "Q_ratio_median": float(median(qratios)) if qratios else None,
        "Q_ratio_p10": float(quantile(qratios, 0.10)) if qratios else None,
        "Q_ratio_p90": float(quantile(qratios, 0.90)) if qratios else None,
        "moment_zero_count_3_hist": zero3,
        "moment_zero_count_6_hist": zero6,
        "descent_test_count": int(len(returned)),
        "returned_to_exact_rate": safe_ratio(returned_to_exact, len(returned)),
        "stuck_nonexact_local_minimum_count": int(stuck),
    }


def public_row(row):
    return {key: value for key, value in row.items() if not key.startswith("_")}


def write_summary(out_dir, exact_path, exact_metrics, distance_summaries, false_valleys, comparison, args):
    lines = []
    lines.append("# 428 Exact Basin Landscape Summary")
    lines.append("")
    lines.append("This is a positive-control calibration around the known order-428 construction. It is not a Hadamard 668 construction claim.")
    lines.append("")
    lines.append("## Exact Baseline")
    lines.append("")
    lines.append("- exact candidate: `{}`".format(exact_path))
    lines.append("- score: `{}`".format(exact_metrics["score"]))
    lines.append("- l1_error: `{}`".format(exact_metrics["l1_error"]))
    lines.append("- max_abs_error: `{}`".format(exact_metrics["max_abs_error"]))
    lines.append("- nonzero_defect_count: `{}`".format(exact_metrics["nonzero_defect_count"]))
    lines.append("- moments: `{}`".format(exact_metrics["padic_moments"]))
    lines.append("")
    lines.append("## Run Scope")
    lines.append("")
    lines.append("- distances: `{}`".format(args.distances))
    lines.append("- samples_per_distance: `{}`".format(args.samples_per_distance))
    lines.append("- diagnostic_limit_per_distance: `{}`".format(args.diagnostic_limit_per_distance))
    lines.append("- descent_limit_per_distance: `{}`".format(args.descent_limit_per_distance))
    lines.append("")
    lines.append("## Distance Summary")
    lines.append("")
    lines.append("| distance | samples | diagnosed | score min | score median | h_min min | local min rate diagnosed | returned-to-score0 rate | false valleys |")
    lines.append("|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    false_by_dist = {}
    for row in false_valleys:
        false_by_dist[str(row["distance"])] = false_by_dist.get(str(row["distance"]), 0) + 1
    for item in distance_summaries:
        lines.append("| {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
            item["distance"],
            item["sample_count"],
            item["diagnosed_count"],
            item["score_min"],
            item["score_median"],
            item["h_min_min"],
            "{:.4f}".format(item["local_minimum_rate_among_diagnosed"]) if item["local_minimum_rate_among_diagnosed"] is not None else "NA",
            "{:.4f}".format(item["returned_to_exact_rate"]) if item["returned_to_exact_rate"] is not None else "NA",
            false_by_dist.get(str(item["distance"]), 0),
        ))
    lines.append("")
    lines.append("## False Valleys")
    lines.append("")
    if false_valleys:
        nearest = sorted(false_valleys, key=lambda row: (row["distance"], row["score"], row["h_min"]))[0]
        lines.append("- nearest diagnosed nonexact 1-swap local minimum: distance `{}`, score `{}`, h_min `{}`, D_min_ratio `{}`, Q_ratio `{}`.".format(
            nearest["distance"],
            nearest["score"],
            nearest["h_min"],
            nearest.get("D_min_ratio"),
            nearest.get("Q_ratio"),
        ))
    else:
        lines.append("- No nonexact 1-swap local minimum was found among the diagnosed perturbations.")
    lines.append("")
    lines.append("## 428 vs 668 Comparison")
    lines.append("")
    lines.append("| candidate | p | score | l1 | max | nonzero | h_min | improving swaps | D_min_ratio | Q_ratio | interpretation |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|")
    for item in comparison:
        lines.append("| `{}` | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
            item["candidate"],
            item["p"],
            item["score"],
            item["l1_error"],
            item["max_abs_error"],
            item["nonzero_defect_count"],
            item.get("h_min"),
            item.get("improving_swap_count"),
            "{:.6f}".format(item["D_min_ratio"]) if item.get("D_min_ratio") is not None else "NA",
            "{:.6f}".format(item["Q_ratio"]) if item.get("Q_ratio") is not None else "NA",
            item["interpretation"],
        ))
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    if false_valleys:
        nearest = sorted(false_valleys, key=lambda row: (row["distance"], row["score"], row["h_min"]))[0]
        lines.append("1. Nearest diagnosed nonexact 1-swap local minimum appeared at swap distance `{}`.".format(nearest["distance"]))
        lines.append("2. Its score / h_min / D_min_ratio / Q_ratio are `{}` / `{}` / `{}` / `{}`.".format(nearest["score"], nearest["h_min"], nearest.get("D_min_ratio"), nearest.get("Q_ratio")))
    else:
        lines.append("1. No diagnosed false valley was found in this run.")
        lines.append("2. Nearest false-valley metrics are therefore unavailable for this run.")
    lines.append("3. Distance-wise local-minimum rates are in the Distance Summary table; rates are among exactly diagnosed rows, not all random rows when diagnostic sampling is limited.")
    lines.append("4. Returned-to-score0 rates from local descent are also in the Distance Summary table.")
    lines.append("5. Compare 668 score164/score176 against the nearest 428 false valley above: positive h_min and D_min_ratio>1 indicate false-valley behavior, while D_min_ratio=0 indicates a direct return path.")
    lines.append("6. Moment signatures remain diagnostics only; 428 perturbations can have low score while low-degree moments are nonzero.")
    lines.append("7. `h_min` and `D_min_ratio` are the clearest local false-valley indicators; `Q_ratio` is a cost-background diagnostic.")
    lines.append("8. If 428 false valleys resembling score164/176 occur only at larger distances, 668 score164/176 should be treated as false-basin candidates rather than immediate true-neighborhood candidates.")
    lines.append("")
    lines.append("## Safety")
    lines.append("")
    lines.append("- 428 exact is a known positive control, not a new result.")
    lines.append("- No Hadamard 668 construction is claimed.")
    lines.append("- Perturbed 428 candidates are calibration artifacts unless score=0 and validation passes.")
    with open(os.path.join(out_dir, "exact_basin_landscape_summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Map score/cost landscape around known exact order-428 SDS.")
    parser.add_argument("--exact-428-path", default="")
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--distances", default="1,2,3,4,5,6,8,10")
    parser.add_argument("--samples-per-distance", type=int, default=2000)
    parser.add_argument("--diagnostic-limit-per-distance", type=int, default=120)
    parser.add_argument("--extra-random-diagnostics-per-distance", type=int, default=20)
    parser.add_argument("--low-score-frontier-size", type=int, default=100)
    parser.add_argument("--descent-limit-per-distance", type=int, default=20)
    parser.add_argument("--descent-max-steps", type=int, default=20)
    parser.add_argument("--seed", type=int, default=51)
    parser.add_argument("--save-candidate-threshold", type=int, default=200)
    return parser.parse_args()


def main():
    args = parse_args()
    out_dir = args.out_dir or os.path.join(
        "outputs",
        "explorations",
        "{}_hadamard428_exact_basin_landscape".format(now_stamp()),
    )
    ensure_dir(out_dir)
    ensure_dir(os.path.join(out_dir, "raw"))
    ensure_dir(os.path.join(out_dir, "candidates"))
    tee, _stamp = setup_logging(SCRIPT_NAME)
    try:
        exact_path = find_exact_428(args.exact_428_path)
        exact_data, p, n, ks, lam, exact_blocks = load_candidate(exact_path)
        exact_counts = total_diff_counts(p, exact_blocks)
        exact_metrics = metric_record(exact_counts, lam, p)
        exact_hash = canonical_hash(exact_blocks, ks, p)
        distances = [int(x) for x in str(args.distances).split(",") if str(x).strip()]
        rng = random.Random(int(args.seed))

        run_config = {
            "script": SCRIPT_NAME,
            "out_dir": out_dir,
            "exact_428_path": exact_path,
            "v": int(p),
            "n": int(n),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "distances": distances,
            "samples_per_distance": int(args.samples_per_distance),
            "diagnostic_limit_per_distance": int(args.diagnostic_limit_per_distance),
            "extra_random_diagnostics_per_distance": int(args.extra_random_diagnostics_per_distance),
            "low_score_frontier_size": int(args.low_score_frontier_size),
            "descent_limit_per_distance": int(args.descent_limit_per_distance),
            "descent_max_steps": int(args.descent_max_steps),
            "seed": int(args.seed),
        }
        write_json(os.path.join(out_dir, "run_config.json"), run_config)
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# Run Log\n\n")
            f.write("- timestamp: `{}`\n".format(time.strftime("%Y-%m-%dT%H:%M:%S")))
            f.write("- script: `{}`\n".format(SCRIPT_NAME))
            f.write("- output dir: `{}`\n".format(out_dir))
            f.write("- exact candidate: `{}`\n".format(exact_path))

        print("Output dir:", out_dir)
        print("Exact 428:", exact_path)
        print("Exact metrics:", exact_metrics)

        all_rows = []
        false_valleys = []
        low_score_frontier = []
        local_descent_results = []
        random_csv_path = os.path.join(out_dir, "random_perturbations.csv")
        csv_fields = [
            "distance", "sample_id", "origin", "score", "l1_error", "max_abs_error",
            "nonzero_defect_count", "T2", "T4", "T6", "T8", "T10", "T12",
            "moment_zero_count_3", "moment_zero_count_6", "higher_moment_norm",
            "h_min", "improving_swap_count", "D_min_ratio", "Q_ratio",
            "descent_status", "canonical_hash",
        ]

        with open(random_csv_path, "w", newline="") as f_csv:
            writer = csv.DictWriter(f_csv, fieldnames=csv_fields)
            writer.writeheader()
            sample_id = 0
            for distance in distances:
                rows = []
                for local_id in range(int(args.samples_per_distance)):
                    sample_id += 1
                    blocks, counts, moves = random_perturbation(rng, exact_blocks, exact_counts, distance, p)
                    row = make_record(distance, sample_id, blocks, counts, moves, p, ks, lam, "random_perturbation")
                    rows.append(row)
                rows.sort(key=lambda row: (row["score"], row["l1_error"], row["max_abs_error"], row["nonzero_defect_count"]))

                diagnose_indices = set(range(min(int(args.diagnostic_limit_per_distance), len(rows))))
                if len(rows) > int(args.diagnostic_limit_per_distance):
                    tail = list(range(int(args.diagnostic_limit_per_distance), len(rows)))
                    rng.shuffle(tail)
                    diagnose_indices.update(tail[: min(int(args.extra_random_diagnostics_per_distance), len(tail))])

                for idx, row in enumerate(rows):
                    if idx in diagnose_indices:
                        diag = one_swap_diagnostic(row["_blocks"], row["_counts"], lam, p)
                        row.update({
                            "h_min": diag["min_h"],
                            "improving_swap_count": diag["improving_swap_count"],
                            "D_min_1": diag["D_min_1"],
                            "D_min_ratio": diag["D_min_ratio"],
                            "Q_tot": diag["Q_tot"],
                            "Q_ratio": diag["Q_ratio"],
                            "sum_g_match": diag["sum_g_match"],
                            "sum_q_match": diag["sum_q_match"],
                            "sum_h_match": diag["sum_h_match"],
                            "block_decomposition": block_decomposition(row["_blocks"], p)[0],
                        })
                        if row["score"] > 0 and row["h_min"] is not None and int(row["h_min"]) >= 0 and int(row["improving_swap_count"]) == 0:
                            false_valleys.append(public_row(row))
                    else:
                        row.update({
                            "h_min": None,
                            "improving_swap_count": None,
                            "D_min_1": None,
                            "D_min_ratio": None,
                            "Q_tot": None,
                            "Q_ratio": None,
                        })

                for idx, row in enumerate(rows[: int(args.descent_limit_per_distance)]):
                    final_blocks, final_counts, history, status = local_descent(
                        row["_blocks"],
                        row["_counts"],
                        lam,
                        p,
                        max_steps=int(args.descent_max_steps),
                        mode="steepest",
                    )
                    row["descent_status"] = status
                    row["descent_steps"] = int(len(history) - 1)
                    descent_payload = {
                        **public_row(row),
                        "history": history,
                        "final_metrics": metric_record(final_counts, lam, p),
                        "returned_to_exact_hash": bool(metric_record(final_counts, lam, p)["score"] == 0 and canonical_hash(final_blocks, ks, p) == exact_hash),
                    }
                    local_descent_results.append(descent_payload)

                for row in rows:
                    if "descent_status" not in row:
                        row["descent_status"] = None
                    writer.writerow({key: public_row(row).get(key) for key in csv_fields})
                    all_rows.append(row)
                low_score_frontier.extend(rows[: int(args.low_score_frontier_size)])
                low_score_frontier.sort(key=lambda row: (row["score"], row["distance"], row["l1_error"], row["max_abs_error"], row["nonzero_defect_count"]))
                del low_score_frontier[int(args.low_score_frontier_size) * len(distances):]
                print("distance {} sampled {} best_score {} diagnosed {}".format(
                    distance,
                    len(rows),
                    rows[0]["score"] if rows else None,
                    len(diagnose_indices),
                ))

        distance_summaries = [summarize_distance([row for row in all_rows if int(row["distance"]) == int(distance)]) for distance in distances]

        with open(os.path.join(out_dir, "low_score_frontier.jsonl"), "w") as f:
            for row in low_score_frontier:
                f.write(json.dumps(json_safe(public_row(row)), sort_keys=True) + "\n")
        with open(os.path.join(out_dir, "false_valley_candidates.jsonl"), "w") as f:
            for row in sorted(false_valleys, key=lambda x: (x["distance"], x["score"], x["h_min"])):
                f.write(json.dumps(json_safe(row), sort_keys=True) + "\n")
        with open(os.path.join(out_dir, "local_descent_results.jsonl"), "w") as f:
            for row in local_descent_results:
                f.write(json.dumps(json_safe(row), sort_keys=True) + "\n")

        write_json(os.path.join(out_dir, "random_perturbation_summary.json"), json_safe({"distance_summary": distance_summaries}))
        write_json(os.path.join(out_dir, "distance_summary.json"), json_safe(distance_summaries))
        distance_csv = os.path.join(out_dir, "distance_summary.csv")
        if distance_summaries:
            with open(distance_csv, "w", newline="") as f:
                fieldnames = list(distance_summaries[0].keys())
                writer = csv.DictWriter(f, fieldnames=fieldnames)
                writer.writeheader()
                for row in distance_summaries:
                    writer.writerow(row)

        saved = []
        save_rows = []
        save_rows.extend([row for row in false_valleys])
        save_rows.extend([public_row(row) for row in low_score_frontier if int(row["score"]) <= int(args.save_candidate_threshold)])
        seen_hashes = set()
        for rank, pub in enumerate(save_rows[:200], start=1):
            source = next((row for row in all_rows if row["sample_id"] == pub["sample_id"]), None)
            if source is None:
                continue
            key = source["canonical_hash"]
            if key in seen_hashes:
                continue
            seen_hashes.add(key)
            path = os.path.join(
                "outputs",
                "candidates",
                "near_hits",
                "near_hit_v{}_score{}_428_basin_landscape_distance{}_rank{}.json".format(p, source["score"], source["distance"], rank),
            )
            extra = {
                "distance_from_exact": int(source["distance"]),
                "applied_moves_from_exact": source["_moves"],
                "h_min": source.get("h_min"),
                "improving_swap_count": source.get("improving_swap_count"),
                "D_min_ratio": source.get("D_min_ratio"),
                "Q_ratio": source.get("Q_ratio"),
                "block_decomposition": source.get("block_decomposition"),
            }
            saved_path = save_candidate(path, source["_blocks"], p, ks, lam, source["_metrics"], exact_path, "428_exact_basin_landscape", source["_moves"], extra=extra)
            saved.append({"path": saved_path, "score": int(source["score"]), "distance": int(source["distance"])})

        comparison = []
        nearest_false = sorted(false_valleys, key=lambda row: (row["distance"], row["score"], row["h_min"]))[:1]
        for label, source in [("428_exact", {"blocks": exact_blocks, "counts": exact_counts, "p": p, "ks": ks, "lam": lam})]:
            metrics = metric_record(source["counts"], source["lam"], source["p"])
            diag = one_swap_diagnostic(source["blocks"], source["counts"], source["lam"], source["p"])
            comparison.append({
                "candidate": label,
                "p": int(source["p"]),
                **{key: metrics[key] for key in ("score", "l1_error", "max_abs_error", "nonzero_defect_count")},
                "padic_moments": metrics["padic_moments"],
                "h_min": diag["min_h"],
                "improving_swap_count": diag["improving_swap_count"],
                "D_min_ratio": diag["D_min_ratio"],
                "Q_ratio": diag["Q_ratio"],
                "interpretation": "known exact positive control",
            })
        if nearest_false:
            row = nearest_false[0]
            comparison.append({
                "candidate": "428_nearest_false_valley",
                "p": int(p),
                "score": int(row["score"]),
                "l1_error": int(row["l1_error"]),
                "max_abs_error": int(row["max_abs_error"]),
                "nonzero_defect_count": int(row["nonzero_defect_count"]),
                "padic_moments": {key: row[key] for key in ("T2", "T4", "T6", "T8", "T10", "T12")},
                "h_min": row.get("h_min"),
                "improving_swap_count": row.get("improving_swap_count"),
                "D_min_ratio": row.get("D_min_ratio"),
                "Q_ratio": row.get("Q_ratio"),
                "interpretation": "diagnosed nonexact 1-swap local minimum around 428 exact",
            })
        for score in (164, 176, 284, 424):
            path = find_candidate_by_score(score)
            if not path:
                continue
            data, p668, n668, ks668, lam668, blocks668 = load_candidate(path)
            counts668 = total_diff_counts(p668, blocks668)
            metrics668 = metric_record(counts668, lam668, p668)
            diag668 = one_swap_diagnostic(blocks668, counts668, lam668, p668)
            if score in (164, 176):
                interp = "668 low-score 1-swap local minimum" if diag668["improving_swap_count"] == 0 else "668 low-score candidate with downhill 1-swap"
            else:
                interp = "668 auxiliary comparison candidate"
            comparison.append({
                "candidate": "668_score{}".format(score),
                "path": path,
                "p": int(p668),
                **{key: metrics668[key] for key in ("score", "l1_error", "max_abs_error", "nonzero_defect_count")},
                "padic_moments": metrics668["padic_moments"],
                "h_min": diag668["min_h"],
                "improving_swap_count": diag668["improving_swap_count"],
                "D_min_ratio": diag668["D_min_ratio"],
                "Q_ratio": diag668["Q_ratio"],
                "interpretation": interp,
            })
        write_json(os.path.join(out_dir, "comparison_428_668.json"), json_safe(comparison))
        write_json(os.path.join(out_dir, "saved_candidates.json"), json_safe(saved))

        write_summary(out_dir, exact_path, exact_metrics, distance_summaries, false_valleys, comparison, args)
        print("SUMMARY:", os.path.join(out_dir, "exact_basin_landscape_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
