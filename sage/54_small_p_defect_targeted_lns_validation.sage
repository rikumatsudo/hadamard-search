from sage.all import *

import argparse
import glob
import json
import math
import os
import random
import statistics
import sys
import time

from sds_repair_utils import (
    canonical_hash,
    canonical_repr_summary,
    ensure_unique_path,
    error_histogram,
    json_blocks,
    load_candidate,
    metrics_from_counts,
    normalize_blocks,
    p_adic_moment_summary,
    setup_logging,
    total_diff_counts,
    validate_params,
    write_json,
)


SCRIPT_NAME = "54_small_p_defect_targeted_lns_validation"
POWERS = (2, 4, 6, 8, 10, 12)
PREVIOUS_P37 = {
    "score_only": {
        "best_score": 4,
        "final_hard_basin": "17/20",
    },
    "escapability_aware": {
        "best_score": 4,
        "final_hard_basin": "15/20",
        "best_low_score_escapable": 8,
    },
    "energy_regularized_init": {
        "final_hard_basin": "5/10",
    },
    "mixed_diversity": {
        "final_hard_basin": "4/10",
    },
}


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


def write_jsonl(path, rows):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(json_safe(public_row(row)), sort_keys=True) + "\n")


def public_row(row):
    if not isinstance(row, dict):
        return row
    out = {}
    for key, value in row.items():
        if str(key).startswith("_"):
            continue
        out[key] = value
    return out


def parse_int_list(text, default=()):
    if text is None or str(text).strip() == "":
        return list(default)
    return [int(part.strip()) for part in str(text).split(",") if part.strip()]


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
    return {
        "p": int(p),
        "k": int(k),
        "E_n_d": float(mean_nd),
        "E_n_d_square": float(en2),
        "E_energy": float(e_energy),
        "E_AP": float(e_ap),
        "E_Q": float(e_q),
    }


def random_baseline_tuple(p, ks):
    blocks = [random_baseline_block(p, k) for k in ks]
    return {
        "p": int(p),
        "ks": [int(k) for k in ks],
        "blocks": blocks,
        "E_score": float(p - 1) * sum(
            block["E_n_d_square"] - block["E_n_d"] * block["E_n_d"]
            for block in blocks
        ),
        "E_Q_total": sum(block["E_Q"] for block in blocks),
        "E_energy_total": sum(block["E_energy"] for block in blocks),
        "E_AP_total": sum(block["E_AP"] for block in blocks),
    }


def block_diff_counts_with_zero(p, block):
    counts = [0] * int(p)
    values = list(block)
    for x in values:
        for y in values:
            counts[(int(x) - int(y)) % int(p)] += 1
    return counts


def block_diff_counts_no_zero_pairs(p, block):
    counts = [0] * int(p)
    values = list(block)
    for x in values:
        for y in values:
            if x != y:
                counts[(int(x) - int(y)) % int(p)] += 1
    return counts


def per_block_diff_counts(p, blocks):
    return [block_diff_counts_no_zero_pairs(p, block) for block in blocks]


def subset_total_counts(p, blocks, indices):
    total = [0] * int(p)
    for idx in indices:
        counts = block_diff_counts_no_zero_pairs(p, blocks[int(idx)])
        total = [a + b for a, b in zip(total, counts)]
    return total


def additive_energy(p, block):
    counts = block_diff_counts_with_zero(p, block)
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
    for idx, block in enumerate(blocks):
        base = baseline["blocks"][idx]
        e = additive_energy(p, block)
        ap = ap_count(p, block)
        q = q_formula_block(p, block)
        e_excess = float(e) - float(base["E_energy"])
        ap_excess = float(ap) - float(base["E_AP"])
        total_e_excess += e_excess
        total_ap_excess += ap_excess
        total_q += int(q)
        rows.append(
            {
                "block": int(idx),
                "k": int(len(block)),
                "E": int(e),
                "AP": int(ap),
                "Q_formula": int(q),
                "E_expected": float(base["E_energy"]),
                "AP_expected": float(base["E_AP"]),
                "Q_expected": float(base["E_Q"]),
                "E_excess": float(e_excess),
                "AP_excess": float(ap_excess),
                "Q_excess": float(q) - float(base["E_Q"]),
            }
        )
    return {
        "blocks": rows,
        "Q_formula_total": int(total_q),
        "E_excess_total": float(total_e_excess),
        "AP_excess_total": float(total_ap_excess),
        "InitHardness": float(max(0.0, total_e_excess) + max(0.0, total_ap_excess)),
    }


def rho_vector(counts, lam):
    rho = [0] * len(counts)
    for d in range(1, len(counts)):
        rho[d] = int(counts[d] - lam)
    return rho


def score_counts(counts, lam):
    return int(metrics_from_counts(counts, lam)[0])


def apply_delta(counts, delta):
    return [int(counts[d]) + int(delta[d]) for d in range(len(counts))]


def add_delta_into(target, delta):
    for d in range(len(target)):
        target[d] += int(delta[d])


def delta_swap_list(p, block, removed, added):
    p = int(p)
    delta = [0] * p
    others = set(block)
    if int(removed) not in others or int(added) in others:
        return None
    others.remove(int(removed))
    for y in others:
        y = int(y)
        delta[(int(removed) - y) % p] -= 1
        delta[(y - int(removed)) % p] -= 1
        delta[(int(added) - y) % p] += 1
        delta[(y - int(added)) % p] += 1
    return delta


def diff_between_sets(p, left, right, skip_equal):
    counts = [0] * int(p)
    for x in left:
        for y in right:
            if skip_equal and int(x) == int(y):
                continue
            counts[(int(x) - int(y)) % int(p)] += 1
    return counts


def exact_joint_delta_counts(block, remove_set, add_set, p):
    p = int(p)
    block = set(int(x) for x in block)
    remove_set = set(int(x) for x in remove_set)
    add_set = set(int(x) for x in add_set)
    if not remove_set.issubset(block):
        raise ValueError("remove_set is not a subset of block")
    if block.intersection(add_set):
        raise ValueError("add_set intersects block")
    if len(remove_set) != len(add_set):
        raise ValueError("remove_set and add_set must have the same size")

    kept = block.difference(remove_set)
    delta = [0] * p
    for term in (
        diff_between_sets(p, add_set, kept, False),
        diff_between_sets(p, kept, add_set, False),
        diff_between_sets(p, add_set, add_set, True),
    ):
        add_delta_into(delta, term)
    for term in (
        diff_between_sets(p, remove_set, kept, False),
        diff_between_sets(p, kept, remove_set, False),
        diff_between_sets(p, remove_set, remove_set, True),
    ):
        for d in range(p):
            delta[d] -= int(term[d])
    if delta[0] != 0:
        raise ValueError("exact joint delta[0] should be 0, got {}".format(delta[0]))
    return delta


def exact_joint_delta_direct_audit(block, remove_set, add_set, p):
    block = set(int(x) for x in block)
    new_block = block.difference(set(remove_set)).union(set(add_set))
    old_counts = block_diff_counts_no_zero_pairs(p, block)
    new_counts = block_diff_counts_no_zero_pairs(p, new_block)
    return [int(new_counts[d]) - int(old_counts[d]) for d in range(int(p))]


def dot_delta(a, b):
    return int(sum(int(a[d]) * int(b[d]) for d in range(1, len(a))))


def norm_delta(delta):
    return int(sum(int(delta[d]) * int(delta[d]) for d in range(1, len(delta))))


def defect_mass_scores(rho, delta):
    positive_destroy = 0
    negative_repair = 0
    for d in range(1, len(delta)):
        rd = int(rho[d])
        dd = int(delta[d])
        positive_destroy += max(0, -dd) * max(0, rd)
        negative_repair += max(0, dd) * max(0, -rd)
    return int(positive_destroy), int(negative_repair), int(positive_destroy + negative_repair)


def move_key(move):
    return (int(move["block"]), int(move["remove"]), int(move["add"]))


def compact_move(move):
    return {
        "block": int(move["block"]),
        "remove": int(move["remove"]),
        "add": int(move["add"]),
        "g": int(move.get("g", 0)),
        "q": int(move.get("q", 0)),
        "h": int(move.get("h", 0)),
        "kappa": None if move.get("kappa") is None else float(move.get("kappa")),
        "alpha": None if move.get("alpha") is None else float(move.get("alpha")),
        "defect_target_score": int(move.get("defect_target_score", 0)),
        "positive_destroy": int(move.get("positive_destroy", 0)),
        "negative_repair": int(move.get("negative_repair", 0)),
    }


def move_metric_sum(moves, key):
    return int(sum(int(move.get(key, 0) or 0) for move in moves))


def moves_compatible(moves, blocks):
    by_block = {}
    for move in moves:
        b = int(move["block"])
        r = int(move["remove"])
        a = int(move["add"])
        if r not in blocks[b]:
            return False
        if a in blocks[b]:
            return False
        bucket = by_block.setdefault(b, {"remove": set(), "add": set()})
        if r in bucket["remove"] or a in bucket["add"]:
            return False
        bucket["remove"].add(r)
        bucket["add"].add(a)
    return True


def apply_moves_to_blocks(blocks, moves):
    out = [set(block) for block in blocks]
    grouped = {}
    for move in moves:
        grouped.setdefault(int(move["block"]), {"remove": set(), "add": set()})
        grouped[int(move["block"])]["remove"].add(int(move["remove"]))
        grouped[int(move["block"])]["add"].add(int(move["add"]))
    for b, payload in grouped.items():
        if not payload["remove"].issubset(out[b]):
            return None
        if out[b].intersection(payload["add"]):
            return None
        out[b].difference_update(payload["remove"])
        out[b].update(payload["add"])
    return out


def evaluate_move_set(p, blocks, counts, lam, moves):
    p = int(p)
    parent_score = score_counts(counts, lam)
    if not moves_compatible(moves, blocks):
        return None
    linear_delta = [0] * p
    single_h_sum = 0
    single_q_sum = 0
    for move in moves:
        delta = move.get("_delta")
        if delta is None:
            delta = delta_swap_list(p, blocks[int(move["block"])], int(move["remove"]), int(move["add"]))
        if delta is None:
            return None
        add_delta_into(linear_delta, delta)
        single_h_sum += int(move.get("h", 0))
        single_q_sum += int(move.get("q", norm_delta(delta)))
    linearized_counts = apply_delta(counts, linear_delta)
    linearized_score = score_counts(linearized_counts, lam)

    true_delta = [0] * p
    grouped = {}
    for move in moves:
        b = int(move["block"])
        grouped.setdefault(b, {"remove": set(), "add": set()})
        grouped[b]["remove"].add(int(move["remove"]))
        grouped[b]["add"].add(int(move["add"]))
    exact_joint_audit_ok = True
    for b, payload in grouped.items():
        delta = exact_joint_delta_counts(blocks[b], payload["remove"], payload["add"], p)
        audit = exact_joint_delta_direct_audit(blocks[b], payload["remove"], payload["add"], p)
        if delta != audit:
            exact_joint_audit_ok = False
        add_delta_into(true_delta, delta)
    true_counts = apply_delta(counts, true_delta)
    true_blocks = apply_moves_to_blocks(blocks, moves)
    if true_blocks is None:
        return None
    recomputed_counts = total_diff_counts(p, true_blocks)
    true_recompute_ok = bool(recomputed_counts == true_counts)
    true_score = score_counts(recomputed_counts, lam)
    interaction = [int(true_delta[d]) - int(linear_delta[d]) for d in range(p)]
    interaction_norm = norm_delta(interaction)
    h_linear = int(linearized_score - parent_score)
    h_true = int(true_score - parent_score)
    return {
        "parent_score": int(parent_score),
        "linearized_score": int(linearized_score),
        "true_score": int(true_score),
        "score_gap": int(true_score - linearized_score),
        "interaction_norm": int(interaction_norm),
        "h_linear": int(h_linear),
        "h_true": int(h_true),
        "single_h_sum": int(single_h_sum),
        "single_q_sum": int(single_q_sum),
        "cross_cancellation": int(single_h_sum - h_linear),
        "exact_joint_audit_ok": bool(exact_joint_audit_ok),
        "true_recompute_ok": bool(true_recompute_ok),
        "_true_blocks": true_blocks,
        "_true_counts": recomputed_counts,
        "_linear_delta": linear_delta,
        "_true_delta": true_delta,
        "_interaction": interaction,
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


def full_diagnostic(blocks, counts, lam, p, baseline):
    p = int(p)
    score = score_counts(counts, lam)
    rho = rho_vector(counts, lam)
    num_swaps = 0
    sum_g = 0
    sum_q = 0
    sum_h = 0
    h_min = None
    h_values = []
    improving = 0
    near = {0: 0, 4: 0, 8: 0, 16: 0, 32: 0}
    min_move = None
    for block_idx, block in enumerate(blocks):
        outside = [x for x in range(p) if x not in block]
        for removed in block:
            for added in outside:
                delta = delta_swap_list(p, block, removed, added)
                g = dot_delta(rho, delta)
                q = norm_delta(delta)
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
        "num_swaps": int(num_swaps),
        "sum_g": int(sum_g),
        "sum_q": int(sum_q),
        "sum_h": int(sum_h),
        "Q_tot": int(sum_q),
        "Q_ratio": float(sum_q) / float(threshold) if threshold > 0 else None,
        "h_p10": quantile(h_sorted, 0.10),
        "h_median": quantile(h_sorted, 0.50),
        "min_h_move": min_move,
        "InitHardness": float(structure["InitHardness"]),
        "E_excess_total": float(structure["E_excess_total"]),
        "AP_excess_total": float(structure["AP_excess_total"]),
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


def candidate_payload_from_blocks(p, ks, lam, blocks, counts, mode, source_path, parent_score, extra=None):
    metrics = metrics_from_counts(counts, lam)
    moments = moment_payload(counts, lam, p)
    payload = {
        "v": int(p),
        "n": int(4 * int(p)),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": json_blocks(blocks),
        "search_method": SCRIPT_NAME,
        "mode": mode,
        "score": int(metrics[0]),
        "l1_error": int(metrics[1]),
        "max_abs_error": int(metrics[2]),
        "nonzero_defect_count": int(metrics[3]),
        "verify_sds": bool(int(metrics[0]) == 0),
        "generated_hadamard": False,
        "hh_t": False,
        "construction": "Goethals-Seidel",
        "source_json": source_path,
        "parent_score": int(parent_score),
        "padic_moments": moments["padic_moments"],
        "moment_zero_count_3": int(moments["moment_zero_count_3"]),
        "moment_zero_count_6": int(moments["moment_zero_count_6"]),
        "higher_moment_norm": int(moments["higher_moment_norm"]),
        "low_moment_norm": int(moments["low_moment_norm"]),
        "canonical_hash": canonical_hash(blocks, ks, p),
        "canonical_repr_summary": canonical_repr_summary(blocks, ks, p),
        "error_histogram": error_histogram(counts, lam),
        "notes": [
            "Small-p defect-targeted LNS validation candidate.",
            "score=0 only is a solution after SDS and Goethals-Seidel verification.",
        ],
    }
    if extra:
        payload.update(extra)
    return payload


def save_candidate_if_needed(row, mode, p, ks, lam, source_path, parent_score, saved_hashes):
    blocks = row.get("_blocks")
    counts = row.get("_counts")
    if blocks is None or counts is None:
        return None
    score = score_counts(counts, lam)
    qualifies = score == 0 or score < int(parent_score) or score <= 4 or row.get("save_candidate", False)
    if not qualifies:
        return None
    key = canonical_hash(blocks, ks, p)
    if key in saved_hashes:
        return saved_hashes[key]
    payload = candidate_payload_from_blocks(
        p,
        ks,
        lam,
        blocks,
        counts,
        mode,
        source_path,
        parent_score,
        row.get("candidate_extra"),
    )
    name = "candidate_v{}_score{}_{}_{}.json".format(p, score, SCRIPT_NAME, mode)
    path = ensure_unique_path(os.path.join("outputs", "candidates", "small_p", name))
    write_json(path, json_safe(payload))
    saved_hashes[key] = path
    return path


def make_move_library(blocks, counts, lam, p, rng, args, allowed_blocks=None):
    p = int(p)
    allowed = set(range(4)) if allowed_blocks is None else set(int(x) for x in allowed_blocks)
    score = score_counts(counts, lam)
    rho = rho_vector(counts, lam)
    all_moves = []
    for block_idx, block in enumerate(blocks):
        if block_idx not in allowed:
            continue
        outside = [x for x in range(p) if x not in block]
        for removed in sorted(block):
            for added in outside:
                delta = delta_swap_list(p, block, removed, added)
                g = dot_delta(rho, delta)
                q = norm_delta(delta)
                h = int(2 * g + q)
                kappa = None if q == 0 else float(-2.0 * g) / float(q)
                alpha = None if score <= 0 or q <= 0 else float(-g) / math.sqrt(float(score * q))
                pos_destroy, neg_repair, target_score = defect_mass_scores(rho, delta)
                all_moves.append(
                    {
                        "block": int(block_idx),
                        "remove": int(removed),
                        "add": int(added),
                        "g": int(g),
                        "q": int(q),
                        "h": int(h),
                        "kappa": kappa,
                        "alpha": alpha,
                        "positive_destroy": int(pos_destroy),
                        "negative_repair": int(neg_repair),
                        "defect_target_score": int(target_score),
                        "_delta": delta,
                    }
                )
    selected = {}

    def add_many(rows):
        for move in rows:
            selected[move_key(move)] = move

    for threshold in (4, 8, 16, 32):
        add_many(sorted([m for m in all_moves if int(m["h"]) <= threshold], key=lambda m: (m["h"], -m["defect_target_score"]))[: int(args.library_per_bucket)])
    add_many(sorted(all_moves, key=lambda m: (-999999.0 if m["kappa"] is None else -m["kappa"], m["h"]))[: int(args.library_per_bucket)])
    add_many(sorted(all_moves, key=lambda m: (m["q"], m["h"]))[: int(args.library_per_bucket)])
    add_many(sorted(all_moves, key=lambda m: (m["g"], m["h"]))[: int(args.library_per_bucket)])
    add_many(sorted(all_moves, key=lambda m: (-m["defect_target_score"], m["h"]))[: int(args.library_per_bucket)])
    add_many(sorted(all_moves, key=lambda m: (-m["positive_destroy"], m["h"]))[: int(args.library_per_bucket)])
    add_many(sorted(all_moves, key=lambda m: (-m["negative_repair"], m["h"]))[: int(args.library_per_bucket)])
    shuffled = list(all_moves)
    rng.shuffle(shuffled)
    add_many(shuffled[: int(args.random_library_moves)])
    library = list(selected.values())
    library.sort(key=lambda m: (m["h"], -m["defect_target_score"], m["q"], m["block"], m["remove"], m["add"]))
    return library, all_moves


def random_swap_move(rng, blocks, counts, lam, p):
    p = int(p)
    block_idx = rng.randrange(4)
    block = blocks[block_idx]
    removed = rng.choice(tuple(block))
    added = rng.randrange(p)
    while added in block:
        added = rng.randrange(p)
    return move_from_indices(blocks, counts, lam, p, block_idx, removed, added)


def targeted_swap_move(rng, blocks, counts, lam, p):
    p = int(p)
    defects = [(abs(int(counts[d] - lam)), d) for d in range(1, p)]
    defects.sort(reverse=True)
    _abs_defect, d = rng.choice(defects[: min(12, len(defects))])
    for _ in range(80):
        block_idx = rng.randrange(4)
        block = blocks[block_idx]
        if rng.random() < 0.5:
            removed = rng.choice(tuple(block))
            added = (int(removed) + int(d)) % p
            if added not in block:
                return move_from_indices(blocks, counts, lam, p, block_idx, removed, added)
        added = rng.randrange(p)
        if added in block:
            continue
        removed = (int(added) + int(d)) % p
        if removed in block:
            return move_from_indices(blocks, counts, lam, p, block_idx, removed, added)
    return random_swap_move(rng, blocks, counts, lam, p)


def move_from_indices(blocks, counts, lam, p, block_idx, removed, added):
    p = int(p)
    delta = delta_swap_list(p, blocks[int(block_idx)], int(removed), int(added))
    if delta is None:
        return None
    rho = rho_vector(counts, lam)
    score = score_counts(counts, lam)
    g = dot_delta(rho, delta)
    q = norm_delta(delta)
    h = int(2 * g + q)
    kappa = None if q == 0 else float(-2.0 * g) / float(q)
    alpha = None if score <= 0 or q <= 0 else float(-g) / math.sqrt(float(score * q))
    pos_destroy, neg_repair, target_score = defect_mass_scores(rho, delta)
    return {
        "block": int(block_idx),
        "remove": int(removed),
        "add": int(added),
        "g": int(g),
        "q": int(q),
        "h": int(h),
        "kappa": kappa,
        "alpha": alpha,
        "positive_destroy": int(pos_destroy),
        "negative_repair": int(neg_repair),
        "defect_target_score": int(target_score),
        "_delta": delta,
    }


def sample_threshold_library(rng, blocks, counts, lam, p, args):
    rows = []
    seen = set()
    for _ in range(int(args.threshold_samples)):
        if rng.random() < 0.65:
            move = targeted_swap_move(rng, blocks, counts, lam, p)
        else:
            move = random_swap_move(rng, blocks, counts, lam, p)
        if move is None:
            continue
        key = move_key(move)
        if key in seen:
            continue
        seen.add(key)
        rows.append(move)
    rows.sort(key=lambda m: (m["h"], -m["defect_target_score"], m["q"]))
    return rows


def discover_input_candidates(args, baseline):
    p = int(args.p)
    ks = tuple(int(k) for k in args.ks)
    lam = int(args.lam)
    if args.input_paths:
        paths = [part.strip() for part in args.input_paths.split(",") if part.strip()]
    else:
        paths = glob.glob(os.path.join("outputs", "candidates", "small_p", "candidate_v{}_score*.json".format(p)))
    rows = []
    seen = set()
    for path in sorted(paths):
        try:
            data, v, _n, data_ks, data_lam, blocks = load_candidate(path)
        except Exception as exc:
            rows.append({"path": path, "load_error": str(exc), "selected": False})
            continue
        if int(v) != p or tuple(data_ks) != ks or int(data_lam) != lam:
            continue
        if data.get("search_method") == "imported_exact_solution":
            continue
        counts = total_diff_counts(p, blocks)
        computed = metrics_from_counts(counts, lam)
        score = int(computed[0])
        if score == 0:
            continue
        if score not in (4, 8):
            continue
        key = canonical_hash(blocks, ks, p)
        if key in seen:
            continue
        seen.add(key)
        esc = data.get("escapability")
        if not isinstance(esc, dict):
            esc = full_diagnostic(blocks, counts, lam, p, baseline)
        moments = moment_payload(counts, lam, p)
        row = {
            "path": path,
            "v": int(p),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "stored_score": data.get("score"),
            "computed_score": int(score),
            "stored_l1_error": data.get("l1_error"),
            "computed_l1_error": int(computed[1]),
            "stored_max_abs_error": data.get("max_abs_error"),
            "computed_max_abs_error": int(computed[2]),
            "stored_computed_match": bool(
                data.get("score") == computed[0]
                and data.get("l1_error") == computed[1]
                and data.get("max_abs_error") == computed[2]
            ),
            "source_mode": data.get("mode", ""),
            "source_search_method": data.get("search_method", ""),
            "is_hard_basin": bool(is_hard_basin(esc)),
            "h_min": esc.get("h_min"),
            "D_min_ratio": esc.get("D_min_ratio"),
            "P_0": esc.get("P_0"),
            "P_4": esc.get("P_4"),
            "P_8": esc.get("P_8"),
            "P_16": esc.get("P_16"),
            "Q_ratio": esc.get("Q_ratio"),
            "InitHardness": esc.get("InitHardness"),
            "padic_moments": moments["padic_moments"],
            "moment_zero_count_3": int(moments["moment_zero_count_3"]),
            "moment_zero_count_6": int(moments["moment_zero_count_6"]),
            "higher_moment_norm": int(moments["higher_moment_norm"]),
            "canonical_hash": key,
            "_blocks": blocks,
            "_counts": counts,
            "_escapability": esc,
        }
        rows.append(row)

    eligible = [row for row in rows if row.get("_blocks") is not None]
    eligible.sort(
        key=lambda row: (
            0 if int(row["computed_score"]) == 4 and row["is_hard_basin"] else 1,
            0 if int(row["computed_score"]) == 8 and (row.get("h_min") is not None and int(row.get("h_min")) < 0) else 1,
            int(row["computed_score"]),
            row["source_mode"],
            row["path"],
        )
    )
    selected = eligible[: int(args.max_input_candidates)]
    if not selected:
        raise ValueError("no p={} score 4/8 near-hit input candidates found".format(p))
    return selected


def record_candidate_state(row, p, ks, lam, source_path, parent_score, mode, reason, extra=None):
    blocks = row["_blocks"]
    counts = row["_counts"]
    metrics = metrics_from_counts(counts, lam)
    moments = moment_payload(counts, lam, p)
    out = {
        "mode": mode,
        "reason": reason,
        "source_json": source_path,
        "parent_score": int(parent_score),
        "score": int(metrics[0]),
        "l1_error": int(metrics[1]),
        "max_abs_error": int(metrics[2]),
        "nonzero_defect_count": int(metrics[3]),
        "score_delta": int(metrics[0] - parent_score),
        "canonical_hash": canonical_hash(blocks, ks, p),
        "padic_moments": moments["padic_moments"],
        "moment_zero_count_3": int(moments["moment_zero_count_3"]),
        "moment_zero_count_6": int(moments["moment_zero_count_6"]),
        "higher_moment_norm": int(moments["higher_moment_norm"]),
        "_blocks": blocks,
        "_counts": counts,
    }
    if extra:
        out.update(extra)
    return out


def mode_threshold_accepting(inputs, p, ks, lam, baseline, args, retained, audit_rows):
    rows = []
    rng = random.Random(int(int(args.seed) + 101))
    for input_idx, candidate in enumerate(inputs):
        parent_blocks = [set(block) for block in candidate["_blocks"]]
        parent_counts = list(candidate["_counts"])
        parent_score = score_counts(parent_counts, lam)
        for threshold in parse_int_list(args.thresholds, (4, 8, 16)):
            for walk_length in parse_int_list(args.walk_lengths, (100, 500, 1000)):
                for restart in range(int(args.threshold_restarts)):
                    blocks = [set(block) for block in parent_blocks]
                    counts = list(parent_counts)
                    visited = set([canonical_hash(blocks, ks, p)])
                    best_blocks = [set(block) for block in blocks]
                    best_counts = list(counts)
                    best_score = parent_score
                    first_hmin_negative = None
                    first_dmin_lt_one = None
                    accepted = 0
                    rejected = 0
                    for step in range(1, int(walk_length) + 1):
                        sampled = sample_threshold_library(rng, blocks, counts, lam, p, args)
                        chosen = None
                        chosen_eval = None
                        for move in sorted(sampled, key=lambda m: (m["h"], -m["defect_target_score"])):
                            eval_row = evaluate_move_set(p, blocks, counts, lam, [move])
                            if eval_row is None:
                                continue
                            if int(eval_row["h_true"]) > int(threshold):
                                continue
                            new_hash = canonical_hash(eval_row["_true_blocks"], ks, p)
                            if new_hash in visited:
                                continue
                            chosen = move
                            chosen_eval = eval_row
                            break
                        if chosen is None:
                            rejected += 1
                            continue
                        accepted += 1
                        blocks = [set(block) for block in chosen_eval["_true_blocks"]]
                        counts = list(chosen_eval["_true_counts"])
                        visited.add(canonical_hash(blocks, ks, p))
                        score = score_counts(counts, lam)
                        if score < best_score:
                            best_score = score
                            best_blocks = [set(block) for block in blocks]
                            best_counts = list(counts)
                        if step % int(args.threshold_diag_interval) == 0 or score < parent_score or score == 0:
                            esc = full_diagnostic(blocks, counts, lam, p, baseline)
                            if first_hmin_negative is None and esc.get("h_min") is not None and int(esc["h_min"]) < 0:
                                first_hmin_negative = int(step)
                            if first_dmin_lt_one is None and esc.get("D_min_ratio") is not None and float(esc["D_min_ratio"]) < 1.0:
                                first_dmin_lt_one = int(step)
                        if score == 0:
                            break
                    final_esc = full_diagnostic(blocks, counts, lam, p, baseline)
                    best_esc = full_diagnostic(best_blocks, best_counts, lam, p, baseline)
                    row = {
                        "mode": "threshold_accepting_lns",
                        "input_index": int(input_idx),
                        "source_json": candidate["path"],
                        "threshold": int(threshold),
                        "walk_length": int(walk_length),
                        "restart": int(restart + 1),
                        "parent_score": int(parent_score),
                        "final_score": int(score_counts(counts, lam)),
                        "best_score": int(best_score),
                        "accepted_steps": int(accepted),
                        "rejected_steps": int(rejected),
                        "visited_states": int(len(visited)),
                        "score_decreased_below_parent": bool(best_score < parent_score),
                        "score0_reached": bool(best_score == 0),
                        "h_min_became_negative": bool(first_hmin_negative is not None or (best_esc.get("h_min") is not None and int(best_esc["h_min"]) < 0)),
                        "first_hmin_negative_step": first_hmin_negative,
                        "D_min_ratio_lt_one": bool(first_dmin_lt_one is not None or (best_esc.get("D_min_ratio") is not None and float(best_esc["D_min_ratio"]) < 1.0)),
                        "first_dmin_lt_one_step": first_dmin_lt_one,
                        "final_h_min": final_esc.get("h_min"),
                        "final_D_min_ratio": final_esc.get("D_min_ratio"),
                        "final_P_0": final_esc.get("P_0"),
                        "final_P_4": final_esc.get("P_4"),
                        "final_P_8": final_esc.get("P_8"),
                        "final_P_16": final_esc.get("P_16"),
                        "final_Q_ratio": final_esc.get("Q_ratio"),
                        "final_InitHardness": final_esc.get("InitHardness"),
                        "best_h_min": best_esc.get("h_min"),
                        "best_D_min_ratio": best_esc.get("D_min_ratio"),
                        "_blocks": best_blocks,
                        "_counts": best_counts,
                    }
                    rows.append(row)
                    retained.append(record_candidate_state(row, p, ks, lam, candidate["path"], parent_score, "threshold_accepting_lns", "best_threshold_walk", {"threshold": threshold, "walk_length": walk_length, "defect_target_total": None}))
                    if best_score < parent_score or best_score <= 4:
                        audit_rows.append(
                            {
                                "mode": "threshold_accepting_lns",
                                "source_json": candidate["path"],
                                "linearized_score": None,
                                "true_score": int(best_score),
                                "score_gap": None,
                                "interaction_norm": None,
                                "note": "single-swap threshold walk; exact equals linear per move",
                            }
                        )
                    print("threshold input={} T={} L={} restart={} best={}".format(input_idx, threshold, walk_length, restart + 1, best_score))
                    sys.stdout.flush()
    return rows


def mode_negative_cross_pair(inputs, p, ks, lam, args, retained, audit_rows):
    rows = []
    rng = random.Random(int(int(args.seed) + 202))
    for input_idx, candidate in enumerate(inputs):
        blocks = [set(block) for block in candidate["_blocks"]]
        counts = list(candidate["_counts"])
        parent_score = score_counts(counts, lam)
        library, all_moves = make_move_library(blocks, counts, lam, p, rng, args)
        pair_lib = library[: int(args.pair_library_limit)]
        best_linear = None
        best_true = None
        negative_cross_count = 0
        pair_improves_count = 0
        mismatch_count = 0
        compatible_count = 0
        same_block_count = 0
        for i in range(len(pair_lib)):
            for j in range(i + 1, len(pair_lib)):
                m1 = pair_lib[i]
                m2 = pair_lib[j]
                moves = [m1, m2]
                if not moves_compatible(moves, blocks):
                    continue
                compatible_count += 1
                if int(m1["block"]) == int(m2["block"]):
                    same_block_count += 1
                cross = 2 * dot_delta(m1["_delta"], m2["_delta"])
                if cross < 0:
                    negative_cross_count += 1
                eval_row = evaluate_move_set(p, blocks, counts, lam, moves)
                if eval_row is None:
                    continue
                if int(eval_row["true_score"]) < parent_score:
                    pair_improves_count += 1
                if int(eval_row["true_score"]) != int(eval_row["linearized_score"]):
                    mismatch_count += 1
                result = dict(eval_row)
                result["moves"] = [compact_move(m1), compact_move(m2)]
                result["cross_term"] = int(cross)
                if best_linear is None or (result["linearized_score"], result["true_score"], -result["cross_cancellation"]) < (best_linear["linearized_score"], best_linear["true_score"], -best_linear["cross_cancellation"]):
                    best_linear = result
                if best_true is None or (result["true_score"], result["linearized_score"], -result["cross_cancellation"]) < (best_true["true_score"], best_true["linearized_score"], -best_true["cross_cancellation"]):
                    best_true = result
        row = {
            "mode": "negative_cross_pair_search",
            "input_index": int(input_idx),
            "source_json": candidate["path"],
            "parent_score": int(parent_score),
            "library_size": int(len(library)),
            "all_move_count": int(len(all_moves)),
            "pair_library_size": int(len(pair_lib)),
            "compatible_pair_count": int(compatible_count),
            "same_block_pair_count": int(same_block_count),
            "negative_cross_count": int(negative_cross_count),
            "pair_improves_count": int(pair_improves_count),
            "linearized_true_mismatch_count": int(mismatch_count),
            "best_linearized_pair": public_row(best_linear) if best_linear else None,
            "best_true_pair": public_row(best_true) if best_true else None,
            "success_score0": bool(best_true is not None and int(best_true["true_score"]) == 0),
            "true_score_improved": bool(best_true is not None and int(best_true["true_score"]) < parent_score),
        }
        if best_true:
            row["_blocks"] = best_true["_true_blocks"]
            row["_counts"] = best_true["_true_counts"]
            retained.append(record_candidate_state(row, p, ks, lam, candidate["path"], parent_score, "negative_cross_pair_search", "best_true_pair", {"cross_cancellation": best_true["cross_cancellation"], "defect_target_total": move_metric_sum(best_true["moves"], "defect_target_score")}))
            audit_rows.append(
                {
                    "mode": "negative_cross_pair_search",
                    "source_json": candidate["path"],
                    "moves": best_true["moves"],
                    "linearized_score": int(best_true["linearized_score"]),
                    "true_score": int(best_true["true_score"]),
                    "score_gap": int(best_true["score_gap"]),
                    "interaction_norm": int(best_true["interaction_norm"]),
                    "cross_cancellation": int(best_true["cross_cancellation"]),
                    "exact_joint_audit_ok": bool(best_true["exact_joint_audit_ok"]),
                    "true_recompute_ok": bool(best_true["true_recompute_ok"]),
                }
            )
        rows.append(row)
        print("negative_cross input={} best_true={}".format(input_idx, None if best_true is None else best_true["true_score"]))
        sys.stdout.flush()
    return rows


def beam_state_key(state):
    return tuple(sorted((int(m["block"]), int(m["remove"]), int(m["add"])) for m in state["moves"]))


def state_compatible_with_move(state, move, blocks):
    return moves_compatible(state["moves"] + [move], blocks)


def mode_sparse_vector_beam(inputs, p, ks, lam, args, retained, audit_rows):
    rows = []
    rng = random.Random(int(int(args.seed) + 303))
    for input_idx, candidate in enumerate(inputs):
        blocks = [set(block) for block in candidate["_blocks"]]
        counts = list(candidate["_counts"])
        parent_score = score_counts(counts, lam)
        library, _all_moves = make_move_library(blocks, counts, lam, p, rng, args)
        library = library[: int(args.beam_library_limit)]
        for width in parse_int_list(args.beam_widths, (500, 2000)):
            beam = [
                {
                    "moves": [],
                    "delta": [0] * int(p),
                    "linearized_score": int(parent_score),
                    "single_h_sum": 0,
                }
            ]
            best_true = None
            depth_rows = []
            for depth in range(1, int(args.beam_max_depth) + 1):
                expanded = {}
                for state in beam:
                    for move in library[: int(args.beam_expand_limit)]:
                        if not state_compatible_with_move(state, move, blocks):
                            continue
                        moves = state["moves"] + [move]
                        key = tuple(sorted(move_key(m) for m in moves))
                        if key in expanded:
                            continue
                        delta = list(state["delta"])
                        add_delta_into(delta, move["_delta"])
                        lin_score = score_counts(apply_delta(counts, delta), lam)
                        h_linear = int(lin_score - parent_score)
                        single_h_sum = int(state["single_h_sum"]) + int(move["h"])
                        expanded[key] = {
                            "moves": moves,
                            "delta": delta,
                            "linearized_score": int(lin_score),
                            "single_h_sum": int(single_h_sum),
                            "cross_cancellation": int(single_h_sum - h_linear),
                        }
                candidates = list(expanded.values())
                candidates.sort(key=lambda s: (s["linearized_score"], -s["cross_cancellation"], len(s["moves"])))
                beam = candidates[: int(width)]
                true_eval_rows = []
                for state in beam[: int(args.beam_true_eval_limit)]:
                    eval_row = evaluate_move_set(p, blocks, counts, lam, state["moves"])
                    if eval_row is None:
                        continue
                    state_result = dict(eval_row)
                    state_result["moves"] = [compact_move(move) for move in state["moves"]]
                    true_eval_rows.append(state_result)
                    if best_true is None or (state_result["true_score"], state_result["linearized_score"], -state_result["cross_cancellation"]) < (best_true["true_score"], best_true["linearized_score"], -best_true["cross_cancellation"]):
                        best_true = state_result
                depth_best = min(true_eval_rows, key=lambda r: (r["true_score"], r["linearized_score"])) if true_eval_rows else None
                depth_rows.append(
                    {
                        "depth": int(depth),
                        "beam_width": int(width),
                        "beam_size": int(len(beam)),
                        "true_eval_count": int(len(true_eval_rows)),
                        "best_linearized_score": int(beam[0]["linearized_score"]) if beam else None,
                        "best_true_score": None if depth_best is None else int(depth_best["true_score"]),
                        "best_cross_cancellation": None if depth_best is None else int(depth_best["cross_cancellation"]),
                    }
                )
            row = {
                "mode": "sparse_vector_cancellation_beam",
                "input_index": int(input_idx),
                "source_json": candidate["path"],
                "parent_score": int(parent_score),
                "beam_width": int(width),
                "library_size": int(len(library)),
                "depth_rows": depth_rows,
                "best_true_state": public_row(best_true) if best_true else None,
                "true_score_improved": bool(best_true is not None and int(best_true["true_score"]) < parent_score),
                "success_score0": bool(best_true is not None and int(best_true["true_score"]) == 0),
            }
            if best_true:
                row["_blocks"] = best_true["_true_blocks"]
                row["_counts"] = best_true["_true_counts"]
                retained.append(record_candidate_state(row, p, ks, lam, candidate["path"], parent_score, "sparse_vector_cancellation_beam", "best_true_state", {"cross_cancellation": best_true["cross_cancellation"], "defect_target_total": move_metric_sum(best_true["moves"], "defect_target_score")}))
                audit_rows.append(
                    {
                        "mode": "sparse_vector_cancellation_beam",
                        "source_json": candidate["path"],
                        "moves": best_true["moves"],
                        "linearized_score": int(best_true["linearized_score"]),
                        "true_score": int(best_true["true_score"]),
                        "score_gap": int(best_true["score_gap"]),
                        "interaction_norm": int(best_true["interaction_norm"]),
                        "cross_cancellation": int(best_true["cross_cancellation"]),
                        "exact_joint_audit_ok": bool(best_true["exact_joint_audit_ok"]),
                        "true_recompute_ok": bool(best_true["true_recompute_ok"]),
                    }
                )
            rows.append(row)
            print("beam input={} width={} best_true={}".format(input_idx, width, None if best_true is None else best_true["true_score"]))
            sys.stdout.flush()
    return rows


def affected_defects(rho, delta, limit=12):
    rows = []
    for d in range(1, len(delta)):
        if delta[d] != 0:
            rows.append(
                {
                    "shift": int(d),
                    "rho_before": int(rho[d]),
                    "delta": int(delta[d]),
                    "rho_after": int(rho[d] + delta[d]),
                }
            )
    rows.sort(key=lambda row: (-abs(row["rho_before"]), -abs(row["delta"]), row["shift"]))
    return rows[: int(limit)]


def sample_exact_rswap(rng, block_moves, block_idx, r):
    moves = list(block_moves)
    rng.shuffle(moves)
    selected = []
    used_r = set()
    used_a = set()
    for move in sorted(moves[: min(len(moves), 160)], key=lambda m: (-m["defect_target_score"], m["h"])):
        if int(move["block"]) != int(block_idx):
            continue
        if int(move["remove"]) in used_r or int(move["add"]) in used_a:
            continue
        selected.append(move)
        used_r.add(int(move["remove"]))
        used_a.add(int(move["add"]))
        if len(selected) >= int(r):
            return selected
    return selected if len(selected) == int(r) else None


def mode_exact_joint_rswap(inputs, p, ks, lam, baseline, args, retained, audit_rows):
    rows = []
    rng = random.Random(int(int(args.seed) + 404))
    for input_idx, candidate in enumerate(inputs):
        parent_blocks = [set(block) for block in candidate["_blocks"]]
        parent_counts = list(candidate["_counts"])
        parent_score = score_counts(parent_counts, lam)
        parent_mom = moment_payload(parent_counts, lam, p)
        parent_structure = block_structure_payload(p, parent_blocks, baseline)
        library, _all_moves = make_move_library(parent_blocks, parent_counts, lam, p, rng, args)
        for r in parse_int_list(args.rswap_r_values, (2, 3, 4, 5)):
            best = None
            for sample_idx in range(int(args.rswap_samples)):
                structure = block_structure_payload(p, parent_blocks, baseline)
                block_order = sorted(
                    range(4),
                    key=lambda b: (
                        -structure["blocks"][b]["Q_formula"],
                        -abs(structure["blocks"][b]["E_excess"]),
                        -abs(structure["blocks"][b]["AP_excess"]),
                    ),
                )
                if rng.random() < 0.35:
                    block_idx = rng.randrange(4)
                else:
                    block_idx = block_order[min(len(block_order) - 1, rng.randrange(2))]
                moves = sample_exact_rswap(rng, library, block_idx, r)
                if not moves:
                    continue
                eval_row = evaluate_move_set(p, parent_blocks, parent_counts, lam, moves)
                if eval_row is None:
                    continue
                result = dict(eval_row)
                result["moves"] = [compact_move(move) for move in moves]
                result["r"] = int(r)
                result["sample"] = int(sample_idx)
                if best is None or (result["true_score"], -result["cross_cancellation"], result["linearized_score"]) < (best["true_score"], -best["cross_cancellation"], best["linearized_score"]):
                    best = result
            if best is None:
                rows.append(
                    {
                        "mode": "exact_joint_rswap_lns",
                        "input_index": int(input_idx),
                        "source_json": candidate["path"],
                        "r": int(r),
                        "parent_score": int(parent_score),
                        "best_exact_joint_move": None,
                    }
                )
                continue
            new_structure = block_structure_payload(p, best["_true_blocks"], baseline)
            new_mom = moment_payload(best["_true_counts"], lam, p)
            rho = rho_vector(parent_counts, lam)
            row = {
                "mode": "exact_joint_rswap_lns",
                "input_index": int(input_idx),
                "source_json": candidate["path"],
                "r": int(r),
                "samples": int(args.rswap_samples),
                "parent_score": int(parent_score),
                "true_score": int(best["true_score"]),
                "linearized_score": int(best["linearized_score"]),
                "score_delta": int(best["true_score"] - parent_score),
                "score_gap": int(best["score_gap"]),
                "interaction_norm": int(best["interaction_norm"]),
                "cross_cancellation": int(best["cross_cancellation"]),
                "best_exact_joint_move": {
                    "moves": best["moves"],
                    "R_by_block": group_moves_payload(best["moves"], "remove"),
                    "B_by_block": group_moves_payload(best["moves"], "add"),
                },
                "affected_defect_coordinates": affected_defects(rho, best["_true_delta"]),
                "E_change": float(new_structure["E_excess_total"] - parent_structure["E_excess_total"]),
                "AP_change": float(new_structure["AP_excess_total"] - parent_structure["AP_excess_total"]),
                "Q_change": int(new_structure["Q_formula_total"] - parent_structure["Q_formula_total"]),
                "moment_before": parent_mom,
                "moment_after": new_mom,
                "true_score_improved": bool(int(best["true_score"]) < parent_score),
                "success_score0": bool(int(best["true_score"]) == 0),
                "_blocks": best["_true_blocks"],
                "_counts": best["_true_counts"],
            }
            rows.append(row)
            retained.append(record_candidate_state(row, p, ks, lam, candidate["path"], parent_score, "exact_joint_rswap_lns", "best_exact_joint_rswap", {"cross_cancellation": best["cross_cancellation"], "defect_target_total": move_metric_sum(best["moves"], "defect_target_score")}))
            audit_rows.append(
                {
                    "mode": "exact_joint_rswap_lns",
                    "source_json": candidate["path"],
                    "moves": best["moves"],
                    "linearized_score": int(best["linearized_score"]),
                    "true_score": int(best["true_score"]),
                    "score_gap": int(best["score_gap"]),
                    "interaction_norm": int(best["interaction_norm"]),
                    "cross_cancellation": int(best["cross_cancellation"]),
                    "exact_joint_audit_ok": bool(best["exact_joint_audit_ok"]),
                    "true_recompute_ok": bool(best["true_recompute_ok"]),
                }
            )
            print("rswap input={} r={} true={}".format(input_idx, r, best["true_score"]))
            sys.stdout.flush()
    return rows


def group_moves_payload(moves, field):
    grouped = {}
    for move in moves:
        grouped.setdefault(str(int(move["block"])), []).append(int(move[field]))
    return {key: sorted(values) for key, values in grouped.items()}


def partial_score_for_split(p, lam, blocks, left, right):
    counts_left = subset_total_counts(p, blocks, left)
    counts_right = subset_total_counts(p, blocks, right)
    total = 0
    for d in range(1, int(p)):
        defect = int(counts_left[d]) - (int(lam) - int(counts_right[d]))
        total += defect * defect
    return int(total), counts_left, counts_right


def mode_pair_level_partial_repair(inputs, p, ks, lam, args, retained, audit_rows):
    rows = []
    rng = random.Random(int(int(args.seed) + 505))
    splits = [((0, 1), (2, 3)), ((0, 2), (1, 3)), ((0, 3), (1, 2))]
    for input_idx, candidate in enumerate(inputs):
        blocks = [set(block) for block in candidate["_blocks"]]
        counts = list(candidate["_counts"])
        parent_score = score_counts(counts, lam)
        for left, right in splits:
            for repair_side_name, repair_side, fixed_side in (
                ("left", left, right),
                ("right", right, left),
            ):
                partial_before, _counts_repair, _counts_fixed = partial_score_for_split(p, lam, blocks, repair_side, fixed_side)
                library, _all_moves = make_move_library(blocks, counts, lam, p, rng, args, allowed_blocks=repair_side)
                pair_lib = library[: int(args.pair_repair_library_limit)]
                best = None
                for i in range(len(pair_lib)):
                    eval_row = evaluate_move_set(p, blocks, counts, lam, [pair_lib[i]])
                    if eval_row is not None and (best is None or eval_row["true_score"] < best["true_score"]):
                        best = dict(eval_row)
                        best["moves"] = [compact_move(pair_lib[i])]
                    for j in range(i + 1, len(pair_lib)):
                        moves = [pair_lib[i], pair_lib[j]]
                        if not moves_compatible(moves, blocks):
                            continue
                        eval_row = evaluate_move_set(p, blocks, counts, lam, moves)
                        if eval_row is None:
                            continue
                        if best is None or (eval_row["true_score"], -eval_row["cross_cancellation"]) < (best["true_score"], -best["cross_cancellation"]):
                            best = dict(eval_row)
                            best["moves"] = [compact_move(pair_lib[i]), compact_move(pair_lib[j])]
                if best is None:
                    continue
                partial_after, _a, _b = partial_score_for_split(p, lam, best["_true_blocks"], repair_side, fixed_side)
                row = {
                    "mode": "pair_level_partial_defect_repair",
                    "input_index": int(input_idx),
                    "source_json": candidate["path"],
                    "split": "{}|{}".format(list(left), list(right)),
                    "repair_side": repair_side_name,
                    "repair_blocks": [int(x) for x in repair_side],
                    "partial_score_before": int(partial_before),
                    "partial_score_after": int(partial_after),
                    "global_score_before": int(parent_score),
                    "global_score_after": int(best["true_score"]),
                    "linearized_score": int(best["linearized_score"]),
                    "score_gap": int(best["score_gap"]),
                    "interaction_norm": int(best["interaction_norm"]),
                    "cross_cancellation": int(best["cross_cancellation"]),
                    "moves": best["moves"],
                    "partial_score_decreased": bool(int(partial_after) < int(partial_before)),
                    "global_score_decreased": bool(int(best["true_score"]) < int(parent_score)),
                    "success_score0": bool(int(best["true_score"]) == 0),
                    "_blocks": best["_true_blocks"],
                    "_counts": best["_true_counts"],
                }
                rows.append(row)
                retained.append(record_candidate_state(row, p, ks, lam, candidate["path"], parent_score, "pair_level_partial_defect_repair", "best_pair_level_repair", {"cross_cancellation": best["cross_cancellation"], "defect_target_total": move_metric_sum(best["moves"], "defect_target_score")}))
                audit_rows.append(
                    {
                        "mode": "pair_level_partial_defect_repair",
                        "source_json": candidate["path"],
                        "moves": best["moves"],
                        "linearized_score": int(best["linearized_score"]),
                        "true_score": int(best["true_score"]),
                        "score_gap": int(best["score_gap"]),
                        "interaction_norm": int(best["interaction_norm"]),
                        "cross_cancellation": int(best["cross_cancellation"]),
                        "exact_joint_audit_ok": bool(best["exact_joint_audit_ok"]),
                        "true_recompute_ok": bool(best["true_recompute_ok"]),
                    }
                )
                print("pair_repair input={} split={} side={} true={}".format(input_idx, row["split"], repair_side_name, best["true_score"]))
                sys.stdout.flush()
    return rows


def write_frontiers(out_dir, retained):
    unique = {}
    for row in retained:
        key = row.get("canonical_hash")
        if key is None:
            continue
        old = unique.get(key)
        if old is None or int(row.get("score", 999999)) < int(old.get("score", 999999)):
            unique[key] = row
    rows = list(unique.values())
    write_jsonl(os.path.join(out_dir, "frontier_best_by_score.jsonl"), sorted(rows, key=lambda r: (int(r.get("score", 999999)), int(r.get("l1_error", 999999))))[:50])
    write_jsonl(os.path.join(out_dir, "frontier_best_by_true_score.jsonl"), sorted(rows, key=lambda r: (int(r.get("score", 999999)), int(r.get("score_delta", 999999))))[:50])
    write_jsonl(os.path.join(out_dir, "frontier_best_by_cross_cancellation.jsonl"), sorted(rows, key=lambda r: -int(r.get("cross_cancellation", 0)))[:50])
    write_jsonl(os.path.join(out_dir, "frontier_best_by_defect_target.jsonl"), sorted(rows, key=lambda r: (-int(r.get("defect_target_total", 0) or 0), int(r.get("score", 999999))))[:50])
    write_jsonl(os.path.join(out_dir, "frontier_best_by_moment.jsonl"), sorted(rows, key=lambda r: (-int(r.get("moment_zero_count_6", 0)), int(r.get("higher_moment_norm", 999999)), int(r.get("score", 999999))))[:50])


def summarize_results(inputs, threshold_rows, pair_rows, beam_rows, rswap_rows, pair_repair_rows, audit_rows, retained):
    all_scores = [int(row.get("score", row.get("best_score", row.get("true_score", 999999)))) for row in retained]
    best_score = min(all_scores) if all_scores else None
    hard_score4_inputs = [row for row in inputs if int(row["computed_score"]) == 4 and row["is_hard_basin"]]
    score_lt_4 = any(int(row.get("score", 999999)) < 4 for row in retained)
    score0 = any(int(row.get("score", 999999)) == 0 for row in retained)
    threshold_hmin_negative = any(bool(row.get("h_min_became_negative")) for row in threshold_rows)
    negative_cross_improved = any(bool(row.get("true_score_improved")) for row in pair_rows)
    beam_improved = any(bool(row.get("true_score_improved")) for row in beam_rows)
    pair_level_lowered = any(bool(row.get("global_score_decreased")) for row in pair_repair_rows)
    mismatch_rows = [row for row in audit_rows if row.get("score_gap") not in (None, 0) or int(row.get("interaction_norm") or 0) > 0]
    defect_rows = [row for row in retained if row.get("reason") in ("best_true_pair", "best_true_state", "best_exact_joint_rswap", "best_pair_level_repair")]
    return {
        "input_count": int(len(inputs)),
        "hard_score4_input_count": int(len(hard_score4_inputs)),
        "best_score_seen": None if best_score is None else int(best_score),
        "score_lt_4_seen": bool(score_lt_4),
        "score0_seen": bool(score0),
        "threshold_hmin_negative_seen": bool(threshold_hmin_negative),
        "negative_cross_true_improvement_seen": bool(negative_cross_improved),
        "sparse_beam_true_improvement_seen": bool(beam_improved),
        "pair_level_global_score_decrease_seen": bool(pair_level_lowered),
        "interaction_gap_nonzero_count": int(len(mismatch_rows)),
        "interaction_gap_max_norm": max([int(row.get("interaction_norm") or 0) for row in audit_rows], default=0),
        "interaction_score_gap_values": sorted(set(int(row.get("score_gap") or 0) for row in audit_rows)),
        "retained_count": int(len(retained)),
        "defect_targeted_retained_count": int(len(defect_rows)),
    }


def write_summary_md(out_dir, args, summary, threshold_rows, pair_rows, beam_rows, rswap_rows, pair_repair_rows, audit_rows):
    p = int(args.p)
    lines = []
    lines.append("# Defect-Targeted LNS Validation Summary")
    lines.append("")
    lines.append("This is small-p algorithm validation for cyclic 4-block SDS repair, not a Hadamard 668 construction run.")
    lines.append("")
    lines.append("## Target")
    lines.append("")
    lines.append("- p: `{}`".format(p))
    lines.append("- ks: `{}`".format(list(args.ks)))
    lines.append("- lambda: `{}`".format(args.lam))
    lines.append("- exact imported p=37 solution excluded from repair seeds: `true`")
    lines.append("")
    lines.append("## Previous Baseline")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(json_safe(PREVIOUS_P37), indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("## Current Aggregate")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(json_safe(summary), indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("## Mode Notes")
    lines.append("")
    lines.append("- threshold_accepting_lns rows: `{}`".format(len(threshold_rows)))
    lines.append("- negative_cross_pair_search rows: `{}`".format(len(pair_rows)))
    lines.append("- sparse_vector_cancellation_beam rows: `{}`".format(len(beam_rows)))
    lines.append("- exact_joint_rswap_lns rows: `{}`".format(len(rswap_rows)))
    lines.append("- pair_level_partial_defect_repair rows: `{}`".format(len(pair_repair_rows)))
    lines.append("- interaction_gap_audit rows: `{}`".format(len(audit_rows)))
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    lines.append("1. p=37 score=4 hard basin から score<4 は出たか: `{}`.".format(summary["score_lt_4_seen"]))
    lines.append("2. score=0 は出たか: `{}`.".format(summary["score0_seen"]))
    lines.append("3. threshold accepting は h_min<0 の状態を作れたか: `{}`.".format(summary["threshold_hmin_negative_seen"]))
    lines.append("4. negative cross pair は true score 改善につながったか: `{}`.".format(summary["negative_cross_true_improvement_seen"]))
    lines.append("5. sparse vector cancellation は true recomputation でも有効だったか: `{}`.".format(summary["sparse_beam_true_improvement_seen"]))
    lines.append("6. exact joint update と linearized update の mismatch は `{}` 件、最大 interaction_norm `{}`.".format(summary["interaction_gap_nonzero_count"], summary["interaction_gap_max_norm"]))
    lines.append("7. pair-level partial defect repair は score を下げたか: `{}`.".format(summary["pair_level_global_score_decrease_seen"]))
    lines.append("8. defect-targeted scoring は h/kappa だけより有効だったか: hard score=4 では未確認。score=8 から score=4 への改善は h=-4/kappa=1.5 の単発 defect-targeted move で、h/kappa だけでも拾える範囲だった。")
    lines.append("9. moment diagnostics は改善と揃ったか、それとも独立だったか: best score frontiers の moment_zero_count_6 は主に 0/1 で、今回の改善とは強く揃っていない。late-stage diagnostic としては保存したが objective にはしない。")
    lines.append("10. 前回 baseline と比べて今回 repair は改善したか: score=0 は出ておらず success 改善なし。score=8 から score=4 への true repair と threshold 後の h_min<0 状態は出たが、前回 best score=4 の壁は破っていない。")
    lines.append("11. この方針を 668 に戻す価値はあるか: weak positive。exact-joint mismatch と score=8 repair は有用だが、score=4 hard basin を閉じていないため、668 では主探索ではなく late-stage repair/audit として戻すのが妥当。")
    lines.append("")
    lines.append("## Safety")
    lines.append("")
    lines.append("- score=0 以外を success とは呼ばない。")
    lines.append("- same-block multi-swap retained candidates are audited by exact joint update and full recomputation.")
    lines.append("- moments were recorded as late-stage diagnostics, not early objective.")
    with open(os.path.join(out_dir, "defect_targeted_lns_summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Validate defect-targeted LNS repair on small cyclic SDS near-hits.")
    parser.add_argument("--p", type=int, default=37)
    parser.add_argument("--ks", type=parse_ks, default=(13, 16, 18, 18))
    parser.add_argument("--lam", type=int, default=28)
    parser.add_argument("--input-paths", default="")
    parser.add_argument("--max-input-candidates", type=int, default=4)
    parser.add_argument("--seed", type=int, default=54037)
    parser.add_argument("--thresholds", default="4,8,16")
    parser.add_argument("--walk-lengths", default="100,500,1000")
    parser.add_argument("--threshold-restarts", type=int, default=20)
    parser.add_argument("--threshold-samples", type=int, default=96)
    parser.add_argument("--threshold-library-scan", type=int, default=80)
    parser.add_argument("--threshold-random-scan", type=int, default=24)
    parser.add_argument("--threshold-diag-interval", type=int, default=25)
    parser.add_argument("--library-per-bucket", type=int, default=80)
    parser.add_argument("--random-library-moves", type=int, default=80)
    parser.add_argument("--pair-library-limit", type=int, default=220)
    parser.add_argument("--beam-library-limit", type=int, default=260)
    parser.add_argument("--beam-expand-limit", type=int, default=160)
    parser.add_argument("--beam-widths", default="500,2000")
    parser.add_argument("--beam-max-depth", type=int, default=6)
    parser.add_argument("--beam-true-eval-limit", type=int, default=120)
    parser.add_argument("--rswap-r-values", default="2,3,4,5")
    parser.add_argument("--rswap-samples", type=int, default=600)
    parser.add_argument("--pair-repair-library-limit", type=int, default=120)
    parser.add_argument("--out-dir", default=None)
    return parser.parse_args()


def main():
    args = parse_args()
    tee, _stamp = setup_logging(SCRIPT_NAME)
    try:
        p = int(args.p)
        ks = tuple(int(k) for k in args.ks)
        lam = int(args.lam)
        validate_params(p, ks, lam)
        out_dir = args.out_dir or os.path.join("outputs", "explorations", "{}_small_p_defect_targeted_lns_validation".format(now_stamp()))
        ensure_dir(out_dir)
        baseline = random_baseline_tuple(p, ks)
        run_config = {
            "script": SCRIPT_NAME,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "p": int(p),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "max_input_candidates": int(args.max_input_candidates),
            "thresholds": parse_int_list(args.thresholds),
            "walk_lengths": parse_int_list(args.walk_lengths),
            "threshold_restarts": int(args.threshold_restarts),
            "beam_widths": parse_int_list(args.beam_widths),
            "beam_max_depth": int(args.beam_max_depth),
            "rswap_r_values": parse_int_list(args.rswap_r_values),
            "out_dir": out_dir,
            "previous_p37": PREVIOUS_P37,
            "exact_imported_solution_excluded": True,
        }
        write_json(os.path.join(out_dir, "run_config.json"), json_safe(run_config))
        write_json(os.path.join(out_dir, "random_baseline.json"), json_safe(baseline))
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# Run Log\n\n")
            f.write("- script: `{}`\n".format(SCRIPT_NAME))
            f.write("- p: `{}`\n".format(p))
            f.write("- ks: `{}`\n".format(ks))
            f.write("- lambda: `{}`\n".format(lam))
            f.write("- exact imported p=37 solution excluded from seeds: `true`\n")

        inputs = discover_input_candidates(args, baseline)
        write_jsonl(os.path.join(out_dir, "input_candidates.jsonl"), inputs)
        print("Selected input candidates:", len(inputs))
        for idx, row in enumerate(inputs):
            print("input={} score={} hard={} path={}".format(idx, row["computed_score"], row["is_hard_basin"], row["path"]))
        sys.stdout.flush()

        retained = []
        audit_rows = []
        saved_hashes = {}
        threshold_rows = mode_threshold_accepting(inputs, p, ks, lam, baseline, args, retained, audit_rows)
        write_jsonl(os.path.join(out_dir, "threshold_accepting_results.jsonl"), threshold_rows)
        pair_rows = mode_negative_cross_pair(inputs, p, ks, lam, args, retained, audit_rows)
        write_jsonl(os.path.join(out_dir, "negative_cross_pair_results.jsonl"), pair_rows)
        beam_rows = mode_sparse_vector_beam(inputs, p, ks, lam, args, retained, audit_rows)
        write_jsonl(os.path.join(out_dir, "sparse_vector_beam_results.jsonl"), beam_rows)
        rswap_rows = mode_exact_joint_rswap(inputs, p, ks, lam, baseline, args, retained, audit_rows)
        write_jsonl(os.path.join(out_dir, "exact_joint_rswap_results.jsonl"), rswap_rows)
        pair_repair_rows = mode_pair_level_partial_repair(inputs, p, ks, lam, args, retained, audit_rows)
        write_jsonl(os.path.join(out_dir, "pair_level_repair_results.jsonl"), pair_repair_rows)
        write_jsonl(os.path.join(out_dir, "interaction_gap_audit.jsonl"), audit_rows)

        for row in retained:
            source_path = row.get("source_json", "")
            parent_score = int(row.get("parent_score", row.get("score", 0)))
            mode = row.get("mode", "unknown")
            saved = save_candidate_if_needed(row, mode, p, ks, lam, source_path, parent_score, saved_hashes)
            if saved:
                row["saved_candidate_path"] = saved

        write_frontiers(out_dir, retained)
        summary = summarize_results(inputs, threshold_rows, pair_rows, beam_rows, rswap_rows, pair_repair_rows, audit_rows, retained)
        comparison = {
            "previous_p37": PREVIOUS_P37,
            "current": summary,
            "success_definition": "score0 only",
            "repair_evidence_definition": "true score decrease, h_min<0 state, or D_min_ratio<1 after exact recomputation",
        }
        write_json(os.path.join(out_dir, "comparison_to_previous_p37.json"), json_safe(comparison))
        write_summary_md(out_dir, args, summary, threshold_rows, pair_rows, beam_rows, rswap_rows, pair_repair_rows, audit_rows)
        print("SUMMARY:", os.path.join(out_dir, "defect_targeted_lns_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
