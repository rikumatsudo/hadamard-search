from sage.all import *

import argparse
import glob
import hashlib
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
    canonical_repr_summary,
    delta_swap,
    ensure_unique_path,
    error_histogram,
    json_blocks,
    metrics_from_counts,
    normalize_blocks,
    p_adic_moment_summary,
    setup_logging,
    total_diff_counts,
    validate_params,
    write_json,
)


SCRIPT_NAME = "53_small_p_escapability_validation"
POWERS = (2, 4, 6, 8, 10, 12)


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)


def json_safe(value):
    if isinstance(value, dict):
        return {str(k): json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(v) for v in value]
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


def parse_int_list(text, default=()):
    if text is None or str(text).strip() == "":
        return list(default)
    return [int(part.strip()) for part in str(text).split(",") if part.strip()]


def parse_float_list(text, default=()):
    if text is None or str(text).strip() == "":
        return list(default)
    return [float(part.strip()) for part in str(text).split(",") if part.strip()]


def parse_ks(text):
    values = tuple(int(part.strip()) for part in str(text).split(",") if part.strip())
    if len(values) != 4:
        raise argparse.ArgumentTypeError("--ks must contain exactly four integers")
    return values


def balanced_abs(residue, modulus):
    residue = int(residue) % int(modulus)
    return min(residue, int(modulus) - residue)


def falling(n, r):
    out = 1.0
    for i in range(int(r)):
        out *= float(int(n) - i)
    return out


def enumerate_tuples_for_p(p):
    p = int(p)
    out = []
    for k1 in range(p + 1):
        for k2 in range(k1, p + 1):
            for k3 in range(k2, p + 1):
                for k4 in range(k3, p + 1):
                    ks = (k1, k2, k3, k4)
                    row_sums = tuple(p - 2 * k for k in ks)
                    if sum(r * r for r in row_sums) != 4 * p:
                        continue
                    lam = sum(ks) - p
                    if lam < 0:
                        continue
                    if sum(k * (k - 1) for k in ks) != lam * (p - 1):
                        continue
                    out.append(
                        {
                            "p": int(p),
                            "n": int(4 * p),
                            "ks": [int(k) for k in ks],
                            "row_sums": [int(r) for r in row_sums],
                            "lambda": int(lam),
                            "valid": True,
                        }
                    )
    return out


def expected_n2(p, k):
    p = int(p)
    k = int(k)
    if p < 4:
        return 0.0
    return (
        p * falling(k, 2) / falling(p, 2)
        + 2 * p * falling(k, 3) / falling(p, 3)
        + p * (p - 3) * falling(k, 4) / falling(p, 4)
    )


def random_baseline_block(p, k):
    p = int(p)
    k = int(k)
    mean_nd = float(k * (k - 1)) / float(p - 1) if p > 1 else 0.0
    en2 = expected_n2(p, k)
    e_energy = float(k * k) + float(p - 1) * en2
    e_ap = float(k) + float(p * (p - 1)) * falling(k, 3) / falling(p, 3) if p >= 3 else float(k)
    e_q = (
        float(k * (p - k) * (4 * k - 6))
        - float(6 * k**3)
        + 8.0 * e_energy
        + 2.0 * float(p - 2 * k) * e_ap
    )
    var_nd = en2 - mean_nd * mean_nd
    return {
        "p": p,
        "k": k,
        "E_n_d": mean_nd,
        "E_n_d_square": en2,
        "E_energy": e_energy,
        "E_AP": e_ap,
        "E_Q": e_q,
        "Var_n_d": var_nd,
    }


def random_baseline_tuple(p, ks):
    blocks = [random_baseline_block(p, k) for k in ks]
    e_score = float(p - 1) * sum(block["Var_n_d"] for block in blocks)
    return {
        "p": int(p),
        "ks": [int(k) for k in ks],
        "E_score": e_score,
        "blocks": blocks,
        "E_Q_total": sum(block["E_Q"] for block in blocks),
        "E_energy_total": sum(block["E_energy"] for block in blocks),
        "E_AP_total": sum(block["E_AP"] for block in blocks),
    }


def block_diff_counts(p, block):
    counts = [0] * int(p)
    values = list(block)
    for x in values:
        for y in values:
            counts[(int(x) - int(y)) % int(p)] += 1
    return counts


def additive_energy(p, block):
    counts = block_diff_counts(p, block)
    return int(sum(c * c for c in counts))


def ap_count(p, block):
    p = int(p)
    values = list(block)
    pair_sums = [0] * p
    for x in values:
        for y in values:
            pair_sums[(int(x) + int(y)) % p] += 1
    total = 0
    for z in values:
        total += pair_sums[(2 * int(z)) % p]
    return int(total)


def q_formula_block(p, block):
    p = int(p)
    k = len(block)
    e = additive_energy(p, block)
    ap = ap_count(p, block)
    return int(k * (p - k) * (4 * k - 6) - 6 * k**3 + 8 * e + 2 * (p - 2 * k) * ap)


def block_structure_payload(p, blocks, baseline):
    rows = []
    total_e_excess = 0.0
    total_ap_excess = 0.0
    total_q = 0
    total_q_expected = 0.0
    for idx, block in enumerate(blocks):
        k = len(block)
        e = additive_energy(p, block)
        ap = ap_count(p, block)
        q = q_formula_block(p, block)
        b = baseline["blocks"][idx]
        e_excess = float(e) - float(b["E_energy"])
        ap_excess = float(ap) - float(b["E_AP"])
        q_excess = float(q) - float(b["E_Q"])
        rows.append(
            {
                "block": int(idx),
                "k": int(k),
                "E": int(e),
                "AP": int(ap),
                "Q_formula": int(q),
                "E_expected": float(b["E_energy"]),
                "AP_expected": float(b["E_AP"]),
                "Q_expected": float(b["E_Q"]),
                "E_excess": float(e_excess),
                "AP_excess": float(ap_excess),
                "Q_excess": float(q_excess),
            }
        )
        total_e_excess += e_excess
        total_ap_excess += ap_excess
        total_q += q
        total_q_expected += float(b["E_Q"])
    return {
        "blocks": rows,
        "E_excess_total": float(total_e_excess),
        "AP_excess_total": float(total_ap_excess),
        "Q_formula_total": int(total_q),
        "Q_expected_total": float(total_q_expected),
        "InitHardness": float(total_q - total_q_expected),
    }


def moment_payload(counts, lam, p):
    summary = p_adic_moment_summary(counts, lam, powers=POWERS, modulus=p)
    moments = {"T{}".format(item["power"]): int(item["residue"]) for item in summary["moments"]}
    return {
        "padic_moments": moments,
        "moment_zero_count_3": int(sum(1 for key in ("T2", "T4", "T6") if moments[key] == 0)),
        "moment_zero_count_6": int(summary["moment_zero_count"]),
        "higher_moment_norm": int(sum(balanced_abs(moments[key], p) ** 2 for key in ("T8", "T10", "T12"))),
        "low_moment_norm": int(sum(balanced_abs(moments[key], p) ** 2 for key in ("T2", "T4", "T6"))),
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


def fast_hash(blocks, p, ks):
    payload = {
        "v": int(p),
        "ks": [int(k) for k in ks],
        "blocks": [[int(x) for x in sorted(block)] for block in blocks],
    }
    text = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def clone_blocks(blocks):
    return [set(block) for block in blocks]


def random_blocks(rng, p, ks):
    universe = list(range(int(p)))
    return [set(rng.sample(universe, int(k))) for k in ks]


def delta_sparse(p, block, removed, added):
    p = int(p)
    out = {}
    others = set(block)
    others.remove(int(removed))
    for y in others:
        y = int(y)
        for d, coeff in (
            ((int(removed) - y) % p, -1),
            ((y - int(removed)) % p, -1),
            ((int(added) - y) % p, 1),
            ((y - int(added)) % p, 1),
        ):
            if d == 0:
                continue
            value = out.get(d, 0) + coeff
            if value:
                out[d] = value
            elif d in out:
                del out[d]
    return out


def full_diagnostic(blocks, counts, lam, p, baseline):
    p = int(p)
    score = int(metrics_from_counts(counts, lam)[0])
    rho = [0] * p
    for d in range(1, p):
        rho[d] = int(counts[d] - lam)
    num_swaps = 0
    sum_g = 0
    sum_q = 0
    sum_h = 0
    h_min = None
    h_values = []
    improving = 0
    near = {0: 0, 4: 0, 8: 0, 16: 0, 32: 0}
    theta = {0.01: 0, 0.05: 0, 0.10: 0}
    min_move = None
    for block_idx, block in enumerate(blocks):
        outside = [x for x in range(p) if x not in block]
        for removed in block:
            for added in outside:
                delta = delta_sparse(p, block, removed, added)
                g = int(sum(rho[d] * int(v) for d, v in delta.items()))
                q = int(sum(int(v) * int(v) for v in delta.values()))
                h = int(2 * g + q)
                num_swaps += 1
                sum_g += g
                sum_q += q
                sum_h += h
                h_values.append(h)
                if h < 0:
                    improving += 1
                for threshold in near:
                    if h <= threshold:
                        near[threshold] += 1
                for frac in theta:
                    if score > 0 and h <= frac * score:
                        theta[frac] += 1
                if h_min is None or h < h_min:
                    h_min = h
                    min_move = {
                        "block": int(block_idx),
                        "remove": int(removed),
                        "add": int(added),
                        "g": int(g),
                        "q": int(q),
                        "h": int(h),
                    }
    structure = block_structure_payload(p, blocks, baseline)
    expected_sum_g = int(-2 * (p - 1) * score)
    expected_sum_h = int(-4 * (p - 1) * score + structure["Q_formula_total"])
    d_min = None if h_min is None else int(score + h_min)
    threshold = int(4 * (p - 1) * score)
    h_sorted = sorted(h_values)
    def quantile(values, q):
        if not values:
            return None
        idx = int(math.floor(float(q) * (len(values) - 1)))
        return int(values[idx])
    return {
        "h_min": int(h_min) if h_min is not None else None,
        "D_min_1": d_min,
        "D_min_ratio": float(d_min) / float(score) if score > 0 and d_min is not None else None,
        "h_min_over_S": float(h_min) / float(score) if score > 0 and h_min is not None else None,
        "improving_swap_count": int(improving),
        "near_improving_count_h_le_0": int(near[0]),
        "near_improving_count_h_le_4": int(near[4]),
        "near_improving_count_h_le_8": int(near[8]),
        "near_improving_count_h_le_16": int(near[16]),
        "near_improving_count_h_le_32": int(near[32]),
        "P_0": float(near[0]) / float(num_swaps) if num_swaps else None,
        "P_4": float(near[4]) / float(num_swaps) if num_swaps else None,
        "P_8": float(near[8]) / float(num_swaps) if num_swaps else None,
        "P_16": float(near[16]) / float(num_swaps) if num_swaps else None,
        "P_thetaS_001": float(theta[0.01]) / float(num_swaps) if num_swaps else None,
        "P_thetaS_005": float(theta[0.05]) / float(num_swaps) if num_swaps else None,
        "P_thetaS_010": float(theta[0.10]) / float(num_swaps) if num_swaps else None,
        "num_swaps": int(num_swaps),
        "sum_g": int(sum_g),
        "expected_sum_g": int(expected_sum_g),
        "sum_g_match": bool(sum_g == expected_sum_g),
        "sum_q": int(sum_q),
        "Q_formula": int(structure["Q_formula_total"]),
        "sum_q_match": bool(sum_q == int(structure["Q_formula_total"])),
        "sum_h": int(sum_h),
        "expected_sum_h": int(expected_sum_h),
        "sum_h_match": bool(sum_h == expected_sum_h),
        "Q_tot": int(sum_q),
        "Q_ratio": float(sum_q) / float(threshold) if threshold > 0 else None,
        "h_p10": quantile(h_sorted, 0.10),
        "h_median": quantile(h_sorted, 0.50),
        "min_h_move": min_move,
        "InitHardness": structure["InitHardness"],
        "E_excess_total": structure["E_excess_total"],
        "AP_excess_total": structure["AP_excess_total"],
        "block_structure": structure["blocks"],
    }


def is_hard_basin(esc):
    if not esc:
        return False
    return bool(
        esc.get("h_min") is not None
        and int(esc.get("h_min")) > 0
        and int(esc.get("improving_swap_count", 0)) == 0
        and esc.get("D_min_ratio") is not None
        and float(esc.get("D_min_ratio")) > 1.0
    )


def should_diagnose(score, step, count, args, p):
    if count >= int(args.max_diagnostics_per_run):
        return False
    if int(args.diagnostic_interval) > 0 and step > 0 and step % int(args.diagnostic_interval) == 0:
        return True
    thresholds = [int(math.ceil(float(mult) * int(p))) for mult in parse_float_list(args.diagnostic_threshold_multipliers, (1, 2, 3, 4, 5, 8, 10, 15, 20))]
    return any(int(score) <= threshold for threshold in thresholds)


def random_swap(rng, blocks, p):
    block_idx = rng.randrange(4)
    block = blocks[block_idx]
    removed = rng.choice(tuple(block))
    added = rng.randrange(int(p))
    while added in block:
        added = rng.randrange(int(p))
    return block_idx, int(removed), int(added)


def targeted_swap(rng, blocks, counts, lam, p):
    defects = [(abs(int(counts[d] - lam)), d) for d in range(1, int(p))]
    defects.sort(reverse=True)
    _abs_defect, d = rng.choice(defects[: min(12, len(defects))])
    for _ in range(80):
        block_idx = rng.randrange(4)
        block = blocks[block_idx]
        if rng.random() < 0.5:
            removed = rng.choice(tuple(block))
            added = (int(removed) + int(d)) % int(p)
            if added not in block:
                return block_idx, int(removed), int(added)
        added = rng.randrange(int(p))
        if added in block:
            continue
        removed = (int(added) + int(d)) % int(p)
        if removed in block:
            return block_idx, int(removed), int(added)
    return random_swap(rng, blocks, p)


def sample_best_swap(rng, blocks, counts, lam, p, samples, targeted_prob):
    current = metrics_from_counts(counts, lam)
    best = None
    for _ in range(int(samples)):
        if rng.random() < float(targeted_prob):
            block_idx, removed, added = targeted_swap(rng, blocks, counts, lam, p)
        else:
            block_idx, removed, added = random_swap(rng, blocks, p)
        delta = delta_swap(p, blocks[block_idx], removed, added)
        new_counts = apply_delta(counts, delta)
        metrics = metrics_from_counts(new_counts, lam)
        item = (tuple(int(x) for x in metrics), int(block_idx), int(removed), int(added), new_counts)
        if best is None or item < best:
            best = item
    return tuple(int(x) for x in current), best


def init_candidate(rng, p, ks, lam, baseline, mode, args):
    if mode not in ("energy_regularized_init", "mixed_diversity"):
        blocks = random_blocks(rng, p, ks)
        return blocks, "pure_random"
    families = ["pure_random", "low_energy", "score_biased", "energy_regularized", "ap_regularized"]
    if mode == "mixed_diversity":
        chosen = rng.choice(families)
    else:
        chosen = "energy_regularized"
    candidates = []
    pool = max(1, int(args.init_pool))
    for _ in range(pool):
        blocks = random_blocks(rng, p, ks)
        counts = total_diff_counts(p, blocks)
        score = int(metrics_from_counts(counts, lam)[0])
        structure = block_structure_payload(p, blocks, baseline)
        e_score = max(1.0, float(baseline["E_score"]))
        e_q = max(1.0, float(abs(baseline["E_Q_total"])))
        rank = float(score) / e_score
        if chosen == "low_energy":
            rank += 0.5 * sum(max(0.0, row["E_excess"]) for row in structure["blocks"]) / e_q
        elif chosen == "ap_regularized":
            rank += 0.5 * sum(abs(row["AP_excess"]) for row in structure["blocks"]) / max(1.0, float(p))
        elif chosen == "score_biased":
            rank = float(score)
        else:
            rank += float(args.init_hardness_alpha) * max(0.0, structure["InitHardness"]) / e_q
        candidates.append((rank, score, blocks))
    candidates.sort(key=lambda x: (x[0], x[1]))
    return clone_blocks(candidates[0][2]), chosen


def make_row(mode, family, seed, step, blocks, counts, ks, lam, p, baseline, reason, diagnose, args):
    metrics = metric_record(counts, lam, p)
    esc = full_diagnostic(blocks, counts, lam, p, baseline) if diagnose else None
    structure = block_structure_payload(p, blocks, baseline)
    hard = is_hard_basin(esc)
    score_norm = float(metrics["score"]) / max(1.0, float(baseline["E_score"]))
    return {
        "mode": mode,
        "family": family,
        "seed": int(seed),
        "step": int(step),
        "v": int(p),
        "n": int(4 * int(p)),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "score": int(metrics["score"]),
        "score_randnorm": float(score_norm),
        "l1_error": int(metrics["l1_error"]),
        "max_abs_error": int(metrics["max_abs_error"]),
        "nonzero_defect_count": int(metrics["nonzero_defect_count"]),
        "padic_moments": metrics["padic_moments"],
        "moment_zero_count_3": int(metrics["moment_zero_count_3"]),
        "moment_zero_count_6": int(metrics["moment_zero_count_6"]),
        "higher_moment_norm": int(metrics["higher_moment_norm"]),
        "fast_hash": fast_hash(blocks, p, ks),
        "canonical_hash": canonical_hash(blocks, ks, p),
        "frontier_reason": reason,
        "escapability": esc,
        "is_hard_basin": bool(hard),
        "InitHardness": float(structure["InitHardness"]),
        "E_excess_total": float(structure["E_excess_total"]),
        "AP_excess_total": float(structure["AP_excess_total"]),
        "_blocks": clone_blocks(blocks),
        "_counts": list(counts),
    }


def row_rank(row, mode):
    score = int(row["score"])
    if score == 0:
        return (-1, 0, 0, 0)
    esc = row.get("escapability") or {}
    if mode == "score_only":
        return (score, row["l1_error"], row["max_abs_error"], row["nonzero_defect_count"])
    if mode == "escapability_aware":
        h_penalty = max(0, int(esc.get("h_min", 999999) or 999999))
        near = int(esc.get("near_improving_count_h_le_8", 0) or 0)
        ratio = esc.get("D_min_ratio")
        ratio_penalty = 0.0 if ratio is None else max(0.0, float(ratio) - 1.0) * score
        return (score + h_penalty + ratio_penalty - 3.0 * math.log(1 + near), score)
    if mode == "energy_regularized_init":
        return (score + max(0.0, row.get("InitHardness", 0.0)) * 0.002, score)
    return (score, row["InitHardness"])


def candidate_payload(row):
    blocks = row["_blocks"]
    p = int(row["v"])
    ks = tuple(int(k) for k in row["ks"])
    return {
        "v": p,
        "n": int(row["n"]),
        "ks": [int(k) for k in ks],
        "lambda": int(row["lambda"]),
        "blocks": json_blocks(blocks),
        "search_method": SCRIPT_NAME,
        "mode": row["mode"],
        "family": row.get("family", ""),
        "score": int(row["score"]),
        "score_randnorm": float(row["score_randnorm"]),
        "l1_error": int(row["l1_error"]),
        "max_abs_error": int(row["max_abs_error"]),
        "nonzero_defect_count": int(row["nonzero_defect_count"]),
        "verify_sds": bool(int(row["score"]) == 0),
        "generated_hadamard": False,
        "hh_t": False,
        "construction": "Goethals-Seidel",
        "escapability": row.get("escapability"),
        "padic_moments": row["padic_moments"],
        "moment_zero_count_3": int(row["moment_zero_count_3"]),
        "moment_zero_count_6": int(row["moment_zero_count_6"]),
        "higher_moment_norm": int(row["higher_moment_norm"]),
        "InitHardness": float(row["InitHardness"]),
        "E_excess_total": float(row["E_excess_total"]),
        "AP_excess_total": float(row["AP_excess_total"]),
        "frontier_reason": row.get("frontier_reason", ""),
        "is_hard_basin": bool(row.get("is_hard_basin", False)),
        "canonical_hash": row.get("canonical_hash") or canonical_hash(blocks, ks, p),
        "canonical_repr_summary": canonical_repr_summary(blocks, ks, p),
        "error_histogram": error_histogram(row["_counts"], int(row["lambda"])),
        "notes": [
            "Small-p algorithm validation candidate.",
            "score=0 requires SDS and Goethals-Seidel HH^T verification before success classification.",
        ],
    }


def save_candidate(row):
    ensure_dir(os.path.join("outputs", "candidates", "small_p"))
    name = "candidate_v{}_score{}_{}_{}_seed{}_step{}.json".format(
        row["v"], row["score"], SCRIPT_NAME, row["mode"], row["seed"], row["step"]
    )
    path = ensure_unique_path(os.path.join("outputs", "candidates", "small_p", name))
    write_json(path, json_safe(candidate_payload(row)))
    return path


def update_frontier(frontier, row, limit, mode):
    key = row["canonical_hash"]
    if any(item["canonical_hash"] == key for item in frontier):
        return
    frontier.append(row)
    frontier.sort(key=lambda item: row_rank(item, mode))
    del frontier[int(limit):]


def run_mode(mode, p, ks, lam, seed_values, args, baseline):
    frontier = []
    diagnostics = []
    false_basin_archive = []
    snapshots = []
    hardening_events = []
    run_results = []
    saved_paths = []
    diagnostic_count = 0
    false_threshold = int(math.ceil(float(args.false_basin_score_multiplier) * int(p)))
    for seed in seed_values:
        rng_seed = int(int(seed) + int(1000003 * (abs(hash(mode)) % 1000000)))
        rng = random.Random(rng_seed)
        blocks, family = init_candidate(rng, p, ks, lam, baseline, mode, args)
        counts = total_diff_counts(p, blocks)
        initial_structure = block_structure_payload(p, blocks, baseline)
        best_row = None
        success_step = None
        evaluated = 0
        last_score = int(metrics_from_counts(counts, lam)[0])
        last_q_ratio = None
        last_q_tot = int(initial_structure["Q_formula_total"])
        last_init_hardness = float(initial_structure["InitHardness"])
        for step in range(int(args.steps) + 1):
            record = metric_record(counts, lam, p)
            score = int(record["score"])
            diagnose = should_diagnose(score, step, diagnostic_count, args, p)
            if best_row is None or score < int(best_row["score"]) or diagnose:
                if diagnose:
                    diagnostic_count += 1
                row = make_row(mode, family, seed, step, blocks, counts, ks, lam, p, baseline, "snapshot", diagnose, args)
                snapshots.append({k: v for k, v in row.items() if not k.startswith("_")})
                if row.get("escapability"):
                    diagnostics.append(row)
                    if row["is_hard_basin"] and row["score"] <= false_threshold:
                        false_basin_archive.append(row)
                update_frontier(frontier, row, int(args.frontier_limit), mode)
                if best_row is None or row_rank(row, mode) < row_rank(best_row, mode):
                    best_row = row
                if score == 0 and success_step is None:
                    success_step = int(step)
                    saved_paths.append(save_candidate(row))
                    break
                if score <= int(args.save_score_threshold_multiplier) * int(p) or row.get("escapability"):
                    saved_paths.append(save_candidate(row))
            if step >= int(args.steps):
                break
            current, best = sample_best_swap(
                rng,
                blocks,
                counts,
                lam,
                p,
                int(args.candidate_samples),
                float(args.targeted_prob),
            )
            best_metrics, block_idx, removed, added, new_counts = best
            delta_s = int(best_metrics[0]) - int(current[0])
            accept = False
            if tuple(best_metrics) < tuple(current):
                accept = True
            elif mode in ("escapability_aware", "mixed_diversity") and delta_s <= int(args.allowed_worsen):
                temp = max(0.01, float(args.escape_temperature))
                if rng.random() < math.exp(-float(max(0, delta_s)) / temp):
                    accept = True
            elif rng.random() < float(args.random_walk_prob):
                accept = True
            if accept:
                counts[:] = list(new_counts)
                blocks[int(block_idx)].remove(int(removed))
                blocks[int(block_idx)].add(int(added))
                evaluated += int(args.candidate_samples)
                if step % max(1, int(args.hardening_interval)) == 0:
                    tmp_structure = block_structure_payload(p, blocks, baseline)
                    tmp_score = int(best_metrics[0])
                    tmp_diag = None
                    if tmp_score > 0:
                        tmp_diag = full_diagnostic(blocks, counts, lam, p, baseline)
                    q_ratio = tmp_diag.get("Q_ratio") if tmp_diag else None
                    hardening_events.append(
                        {
                            "mode": mode,
                            "seed": int(seed),
                            "step": int(step),
                            "DeltaS": int(tmp_score - last_score),
                            "DeltaQ_tot": int(tmp_structure["Q_formula_total"] - last_q_tot),
                            "DeltaInitHardness": float(tmp_structure["InitHardness"] - last_init_hardness),
                            "DeltaQ_ratio": None if q_ratio is None or last_q_ratio is None else float(q_ratio - last_q_ratio),
                            "is_hardening_move_score_qratio": bool(q_ratio is not None and last_q_ratio is not None and tmp_score < last_score and q_ratio > last_q_ratio),
                            "is_hardening_move_score_qtot": bool(tmp_score < last_score and int(tmp_structure["Q_formula_total"]) >= last_q_tot),
                        }
                    )
                    last_score = tmp_score
                    last_q_ratio = q_ratio
                    last_q_tot = int(tmp_structure["Q_formula_total"])
                    last_init_hardness = float(tmp_structure["InitHardness"])
            else:
                evaluated += int(args.candidate_samples)
        if best_row is None:
            best_row = make_row(mode, family, seed, int(args.steps), blocks, counts, ks, lam, p, baseline, "final", True, args)
        if not best_row.get("escapability"):
            best_row["escapability"] = full_diagnostic(best_row["_blocks"], best_row["_counts"], lam, p, baseline)
            best_row["is_hard_basin"] = bool(is_hard_basin(best_row["escapability"]))
            diagnostics.append(best_row)
            if best_row["is_hard_basin"] and best_row["score"] <= false_threshold:
                false_basin_archive.append(best_row)
            saved_paths.append(save_candidate(best_row))
        run_results.append(
            {
                "mode": mode,
                "family": family,
                "seed": int(seed),
                "best_score": int(best_row["score"]),
                "best_l1_error": int(best_row["l1_error"]),
                "best_max_abs_error": int(best_row["max_abs_error"]),
                "best_nonzero_defect_count": int(best_row["nonzero_defect_count"]),
                "success": bool(int(best_row["score"]) == 0 or success_step is not None),
                "success_step": success_step,
                "evaluated_candidates": int(evaluated),
                "is_hard_basin": bool(best_row.get("is_hard_basin")),
                "h_min": (best_row.get("escapability") or {}).get("h_min"),
                "D_min_ratio": (best_row.get("escapability") or {}).get("D_min_ratio"),
                "Q_ratio": (best_row.get("escapability") or {}).get("Q_ratio"),
                "InitHardness": float(best_row.get("InitHardness", 0.0)),
                "candidate_path": saved_paths[-1] if saved_paths else None,
            }
        )
        print("mode={} seed={} best_score={} success={}".format(mode, seed, best_row["score"], run_results[-1]["success"]))
        sys.stdout.flush()
    return {
        "mode": mode,
        "runs": run_results,
        "frontier": frontier,
        "diagnostics": diagnostics,
        "false_basin_archive": false_basin_archive,
        "trajectory_snapshots": snapshots,
        "hardening_events": hardening_events,
        "saved_paths": saved_paths,
    }


def public_row(row):
    return json_safe({k: v for k, v in row.items() if not k.startswith("_")})


def write_jsonl(path, rows):
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(public_row(row), sort_keys=True) + "\n")


def discover_known_exact(p_list):
    wanted = set(int(p) for p in p_list)
    roots = ["outputs", "sage", "README.md"]
    paths = []
    for root in roots:
        if os.path.isdir(root):
            paths.extend(glob.glob(os.path.join(root, "**", "*.json"), recursive=True))
        elif os.path.exists(root) and root.endswith(".json"):
            paths.append(root)
    found = []
    seen = set()
    for path in paths:
        if path in seen:
            continue
        seen.add(path)
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception:
            continue
        if not isinstance(data, dict):
            continue
        if not all(key in data for key in ("v", "n", "ks", "lambda", "blocks")):
            continue
        try:
            v = int(data["v"])
            if v not in wanted:
                continue
            ks = tuple(int(k) for k in data["ks"])
            lam = int(data["lambda"])
            validate_params(v, ks, lam)
            blocks = normalize_blocks(v, data["blocks"])
            if tuple(len(block) for block in blocks) != ks:
                continue
            counts = total_diff_counts(v, blocks)
            score = int(metrics_from_counts(counts, lam)[0])
        except Exception:
            continue
        if score == 0 or data.get("verify_sds") is True:
            found.append(
                {
                    "path": path,
                    "p": int(v),
                    "n": int(4 * v),
                    "ks": [int(k) for k in ks],
                    "lambda": int(lam),
                    "score": int(score),
                    "verify_sds_flag": bool(data.get("verify_sds", False)),
                    "generated_hadamard_flag": bool(data.get("generated_hadamard", False)),
                    "hh_t_flag": bool(data.get("hh_t", False)),
                }
            )
    return found


def summarize_result(result):
    runs = result["runs"]
    successes = [row for row in runs if row["success"]]
    hard = [row for row in runs if row["is_hard_basin"]]
    success_steps = [row["success_step"] for row in successes if row["success_step"] is not None]
    best_score = min([row["best_score"] for row in runs], default=None)
    low_esc = [
        row for row in runs
        if row.get("h_min") is not None and row["h_min"] < 0
    ]
    q_ratios = [row["Q_ratio"] for row in runs if row.get("Q_ratio") is not None]
    init_vals = [row["InitHardness"] for row in runs]
    return {
        "mode": result["mode"],
        "run_count": int(len(runs)),
        "success_count": int(len(successes)),
        "success_rate": float(len(successes)) / float(len(runs)) if runs else 0.0,
        "median_success_step": statistics.median(success_steps) if success_steps else None,
        "best_score": int(best_score) if best_score is not None else None,
        "false_basin_event_count": int(len(result["false_basin_archive"])),
        "final_hard_basin_count": int(len(hard)),
        "best_low_score_escapable": min([row["best_score"] for row in low_esc], default=None),
        "median_Q_ratio": statistics.median(q_ratios) if q_ratios else None,
        "median_InitHardness": statistics.median(init_vals) if init_vals else None,
    }


def make_summary_md(out_dir, p, selected_tuple, known_exact, summaries, comparison):
    lines = []
    lines.append("# Small-p Escapability Validation Summary")
    lines.append("")
    lines.append("This is algorithm validation on small cyclic SDS cases, not a Hadamard 668 construction claim.")
    lines.append("")
    lines.append("## Target")
    lines.append("")
    lines.append("- p: `{}`".format(p))
    lines.append("- ks: `{}`".format(selected_tuple["ks"]))
    lines.append("- lambda: `{}`".format(selected_tuple["lambda"]))
    lines.append("- repo known exact for p: `{}`".format(bool(known_exact)))
    lines.append("")
    lines.append("## Mode Summaries")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(json_safe(summaries), indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("## Comparison")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(json_safe(comparison), indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    lines.append("1. p=37 usable tuple was enumerated and selected as `{}`; repo-known exact target found: `{}`.".format(selected_tuple["ks"], bool(known_exact)))
    lines.append("2. If all modes reach score=0 quickly, p=37 is too easy for discrimination; otherwise the run is landscape/false-basin validation only.")
    lines.append("3. Success rate and median steps are in `comparison_summary.json`; score=0 only is counted as success.")
    lines.append("4. False basin hit rate is reported through `false_basin_event_count` and `final_hard_basin_count`.")
    lines.append("5. Hardening diagnostics are saved in `hardening_events.jsonl`; this prototype samples those events sparsely.")
    lines.append("6. Moment diagnostics are saved, but moments are not used as early-stage objective.")
    lines.append("7. Any score=0 small-p candidate must still be checked with SDS and Goethals-Seidel HH^T verification.")
    lines.append("")
    lines.append("## Safety")
    lines.append("")
    lines.append("- This run does not solve Hadamard 668.")
    lines.append("- score>0 candidates are diagnostic near-hits, not solutions.")
    lines.append("- score=0 is not a Hadamard 668 claim; for small p it is only a small-case validation candidate until SDS/GS verification passes.")
    with open(os.path.join(out_dir, "small_p_escapability_validation_summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Validate escapability/hardness-aware SDS search on small p.")
    parser.add_argument("--p", type=int, default=37)
    parser.add_argument("--p-list", default="37,31,43,47,67")
    parser.add_argument("--ks", type=parse_ks, default=None)
    parser.add_argument("--tuple-index", type=int, default=0)
    parser.add_argument("--seeds", type=int, default=20)
    parser.add_argument("--steps", type=int, default=5000)
    parser.add_argument("--modes", default="score_only,escapability_aware")
    parser.add_argument("--candidate-samples", type=int, default=32)
    parser.add_argument("--targeted-prob", type=float, default=0.3)
    parser.add_argument("--diagnostic-interval", type=int, default=500)
    parser.add_argument("--diagnostic-threshold-multipliers", default="1,2,3,4,5,8,10,15,20")
    parser.add_argument("--max-diagnostics-per-run", type=int, default=80)
    parser.add_argument("--false-basin-score-multiplier", type=float, default=5.0)
    parser.add_argument("--save-score-threshold-multiplier", type=int, default=5)
    parser.add_argument("--frontier-limit", type=int, default=50)
    parser.add_argument("--init-pool", type=int, default=50)
    parser.add_argument("--init-hardness-alpha", type=float, default=0.3)
    parser.add_argument("--allowed-worsen", type=int, default=12)
    parser.add_argument("--escape-temperature", type=float, default=8.0)
    parser.add_argument("--random-walk-prob", type=float, default=0.005)
    parser.add_argument("--hardening-interval", type=int, default=250)
    parser.add_argument("--out-dir", default=None)
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        out_dir = args.out_dir or os.path.join("outputs", "explorations", "{}_small_p_escapability_validation".format(now_stamp()))
        ensure_dir(out_dir)
        p_list = parse_int_list(args.p_list, [args.p])
        tuple_payload = {}
        for p in p_list:
            tuple_payload[str(p)] = {
                "p": int(p),
                "n": int(4 * int(p)),
                "tuples": enumerate_tuples_for_p(p),
            }
        write_json(os.path.join(out_dir, "tuple_enumeration.json"), json_safe(tuple_payload))

        known = discover_known_exact(p_list)
        write_json(os.path.join(out_dir, "known_exact_candidates.json"), json_safe({"candidates": known}))

        p = int(args.p)
        tuples = tuple_payload[str(p)]["tuples"]
        if not tuples:
            raise ValueError("no valid tuples enumerated for p={}".format(p))
        if args.ks is not None:
            selected = None
            for item in tuples:
                if tuple(item["ks"]) == tuple(args.ks):
                    selected = item
                    break
            if selected is None:
                raise ValueError("--ks={} was not a valid enumerated tuple for p={}".format(args.ks, p))
        else:
            exact_for_p = [item for item in known if int(item["p"]) == p]
            if exact_for_p:
                exact_ks = tuple(exact_for_p[0]["ks"])
                selected = next((item for item in tuples if tuple(item["ks"]) == exact_ks), tuples[int(args.tuple_index)])
            else:
                selected = tuples[int(args.tuple_index)]
        ks = tuple(int(k) for k in selected["ks"])
        lam = int(selected["lambda"])
        validate_params(p, ks, lam)
        baseline = random_baseline_tuple(p, ks)
        write_json(os.path.join(out_dir, "random_baseline.json"), json_safe(baseline))

        run_config = {
            "script": SCRIPT_NAME,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "p": int(p),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "seeds": int(args.seeds),
            "steps": int(args.steps),
            "modes": [part.strip() for part in args.modes.split(",") if part.strip()],
            "candidate_samples": int(args.candidate_samples),
            "out_dir": out_dir,
        }
        write_json(os.path.join(out_dir, "run_config.json"), json_safe(run_config))
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# Run Log\n\n")
            f.write("- script: `{}`\n".format(SCRIPT_NAME))
            f.write("- p: `{}`\n".format(p))
            f.write("- ks: `{}`\n".format(ks))
            f.write("- lambda: `{}`\n".format(lam))

        seed_values = list(range(1, int(args.seeds) + 1))
        results = {}
        summaries = {}
        all_false = []
        all_diag = []
        all_snapshots = []
        all_hardening = []
        for mode in [part.strip() for part in args.modes.split(",") if part.strip()]:
            print("Running mode:", mode)
            result = run_mode(mode, p, ks, lam, seed_values, args, baseline)
            results[mode] = result
            summaries[mode] = summarize_result(result)
            write_jsonl(os.path.join(out_dir, "{}_results.jsonl".format(mode)), result["runs"])
            write_jsonl(os.path.join(out_dir, "frontier_{}.jsonl".format(mode)), result["frontier"])
            all_false.extend(result["false_basin_archive"])
            all_diag.extend(result["diagnostics"])
            all_snapshots.extend(result["trajectory_snapshots"])
            all_hardening.extend(result["hardening_events"])

        comparison_rows = []
        for mode, summary in summaries.items():
            comparison_rows.append(dict(summary))
        write_json(os.path.join(out_dir, "comparison_summary.json"), json_safe(summaries))
        with open(os.path.join(out_dir, "comparison_summary.csv"), "w") as f:
            fields = ["mode", "run_count", "success_count", "success_rate", "median_success_step", "best_score", "false_basin_event_count", "final_hard_basin_count", "best_low_score_escapable", "median_Q_ratio", "median_InitHardness"]
            f.write(",".join(fields) + "\n")
            for row in comparison_rows:
                f.write(",".join("" if row.get(field) is None else str(row.get(field)) for field in fields) + "\n")
        write_jsonl(os.path.join(out_dir, "false_basin_archive.jsonl"), all_false)
        write_jsonl(os.path.join(out_dir, "diagnostic_candidates.jsonl"), all_diag)
        write_jsonl(os.path.join(out_dir, "trajectory_snapshots.jsonl"), all_snapshots)
        write_jsonl(os.path.join(out_dir, "hardening_events.jsonl"), all_hardening)
        # Compatibility filenames requested in the prompt.
        for name in ("score_only", "escapability_aware", "energy_regularized", "mixed_diversity"):
            path = os.path.join(out_dir, "{}_results.jsonl".format(name))
            if not os.path.exists(path):
                open(path, "w").close()
        make_summary_md(out_dir, p, selected, [item for item in known if int(item["p"]) == p], summaries, summaries)
        print("SUMMARY:", os.path.join(out_dir, "small_p_escapability_validation_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
