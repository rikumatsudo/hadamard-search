from sage.all import *

import argparse
import csv
import glob
import itertools
import json
import math
import os
import random
import re
import statistics
import sys
import time

from sds_repair_utils import (
    apply_delta,
    apply_swap_to_blocks,
    canonical_hash,
    canonical_repr_summary,
    delta_swap,
    error_histogram,
    json_blocks,
    load_candidate,
    metrics_from_counts,
    normalize_blocks,
    p_adic_moment_summary,
    setup_logging,
    total_diff_counts,
    validate_params,
    verify_hadamard_exact,
    verify_sds,
    write_json,
)


SCRIPT_NAME = "60_p37_exact_vs_search_low_score_comparison"
POWERS = (2, 4, 6, 8, 10, 12)
DEFAULT_R_VALUES = (1, 2, 3, 4, 5, 6, 8, 10)
LOW_SCORE_SET = set([4, 8, 12, 16])
FEATURE_DIRECTIONS = {
    "D_min_ratio": "low",
    "P_4": "high",
    "P_8": "high",
    "P_16": "high",
    "kappa_max": "high",
    "kappa_q90": "high",
    "kappa_q99": "high",
    "Q_ratio": "low",
    "InitHardness": "low",
    "return_radius_proxy": "low",
}


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def ensure_dir(path):
    if path:
        os.makedirs(path, exist_ok=True)


def json_safe(value):
    if isinstance(value, dict):
        return {str(k): json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(v) for v in value]
    if isinstance(value, set):
        return [json_safe(v) for v in sorted(value)]
    if isinstance(value, bool):
        return bool(value)
    if isinstance(value, int):
        return int(value)
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    try:
        if isinstance(value, Integer):
            return int(value)
    except NameError:
        pass
    try:
        if str(type(value)).startswith("<class 'sage."):
            as_float = float(value)
            return as_float if math.isfinite(as_float) else None
    except Exception:
        pass
    try:
        json.dumps(value)
        return value
    except TypeError:
        pass
    try:
        return float(value)
    except Exception:
        return str(value)


def public_row(row):
    if not isinstance(row, dict):
        return row
    return {key: value for key, value in row.items() if not str(key).startswith("_")}


def write_json_safe(path, payload):
    write_json(path, json_safe(payload))


def write_jsonl(path, rows):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(json_safe(public_row(row)), sort_keys=True) + "\n")


def csv_value(value):
    value = json_safe(value)
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True)
    if value is None:
        return ""
    return value


def write_csv(path, rows, fields):
    ensure_dir(os.path.dirname(path))
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: csv_value(row.get(field)) for field in fields})


def parse_ks(text):
    values = tuple(int(part.strip()) for part in str(text).split(",") if part.strip())
    if len(values) != 4:
        raise argparse.ArgumentTypeError("--ks must contain exactly four integers")
    return values


def parse_r_values(text, max_r):
    if text:
        values = tuple(int(part.strip()) for part in str(text).split(",") if part.strip())
    else:
        values = tuple(r for r in DEFAULT_R_VALUES if int(r) <= int(max_r))
        if int(max_r) not in values:
            values = tuple(sorted(set(values + (int(max_r),))))
    return tuple(int(r) for r in values if int(r) > 0 and int(r) <= int(max_r))


def clone_blocks(blocks):
    return [set(block) for block in blocks]


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
        "E_energy": float(e_energy),
        "E_AP": float(e_ap),
        "E_Q": float(e_q),
        "Var_n_d": float(en2 - mean_nd * mean_nd),
    }


def random_baseline_tuple(p, ks):
    blocks = [random_baseline_block(p, k) for k in ks]
    return {
        "p": int(p),
        "ks": [int(k) for k in ks],
        "E_score": float(p - 1) * sum(block["Var_n_d"] for block in blocks),
        "blocks": blocks,
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
    total_e = 0
    total_ap = 0
    total_q = 0
    total_e_excess = 0.0
    total_ap_excess = 0.0
    total_q_expected = 0.0
    for idx, block in enumerate(blocks):
        base = baseline["blocks"][idx]
        e = additive_energy(p, block)
        ap = ap_count(p, block)
        q = q_formula_block(p, block)
        e_excess = float(e) - float(base["E_energy"])
        ap_excess = float(ap) - float(base["E_AP"])
        rows.append({"block": int(idx), "E": int(e), "AP": int(ap), "Q_formula": int(q)})
        total_e += int(e)
        total_ap += int(ap)
        total_q += int(q)
        total_e_excess += e_excess
        total_ap_excess += ap_excess
        total_q_expected += float(base["E_Q"])
    return {
        "blocks": rows,
        "E_total": int(total_e),
        "AP_total": int(total_ap),
        "Q_formula_total": int(total_q),
        "Q_expected_total": float(total_q_expected),
        "E_excess_total": float(total_e_excess),
        "AP_excess_total": float(total_ap_excess),
        "InitHardness": float(total_q - total_q_expected),
    }


def balanced_abs(residue, modulus):
    residue = int(residue) % int(modulus)
    return min(residue, int(modulus) - residue)


def moment_payload(counts, lam, p):
    summary = p_adic_moment_summary(counts, lam, powers=POWERS, modulus=p)
    moments = {"T{}".format(item["power"]): int(item["residue"]) for item in summary["moments"]}
    return {
        "moment_zero_count_3": int(sum(1 for key in ("T2", "T4", "T6") if moments[key] == 0)),
        "moment_zero_count_6": int(summary["moment_zero_count"]),
        "higher_moment_norm": int(sum(balanced_abs(moments[key], p) ** 2 for key in ("T8", "T10", "T12"))),
        "padic_moments": moments,
    }


def score_counts(counts, lam):
    return int(metrics_from_counts(counts, lam)[0])


def rho_vector(counts, lam):
    rho = [0] * len(counts)
    for d in range(1, len(counts)):
        rho[d] = int(counts[d] - lam)
    return rho


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


def quantile(values, q):
    if not values:
        return None
    values = sorted(values)
    idx = int(math.floor(float(q) * (len(values) - 1)))
    return values[idx]


def one_swap_library(blocks, counts, lam, p):
    p = int(p)
    score = score_counts(counts, lam)
    rho = rho_vector(counts, lam)
    moves = []
    for block_idx, block in enumerate(blocks):
        if len(block) == 0 or len(block) == p:
            continue
        outside = [x for x in range(p) if x not in block]
        for removed in sorted(block):
            for added in outside:
                delta = delta_sparse(p, block, removed, added)
                g = int(sum(rho[d] * int(v) for d, v in delta.items()))
                q = int(sum(int(v) * int(v) for v in delta.values()))
                h = int(2 * g + q)
                kappa = None if q == 0 else float(-2 * g) / float(q)
                moves.append(
                    {
                        "block": int(block_idx),
                        "removed": int(removed),
                        "added": int(added),
                        "delta": delta,
                        "g": int(g),
                        "q": int(q),
                        "h": int(h),
                        "score_after": int(score + h),
                        "kappa": kappa,
                    }
                )
    moves.sort(key=lambda item: (int(item["h"]), -float(item["kappa"] if item["kappa"] is not None else -999.0), int(item["q"])))
    return moves


def full_diagnostic(blocks, counts, lam, p, baseline):
    score, l1_error, max_abs_error, nonzero_defect_count = [int(x) for x in metrics_from_counts(counts, lam)]
    moves = one_swap_library(blocks, counts, lam, p)
    h_values = [int(move["h"]) for move in moves]
    q_values = [int(move["q"]) for move in moves]
    kappas = [float(move["kappa"]) for move in moves if move["kappa"] is not None]
    improving = [move for move in moves if int(move["h"]) < 0]
    near = {threshold: sum(1 for move in moves if int(move["h"]) <= threshold) for threshold in (0, 4, 8, 16)}
    h_min = min(h_values) if h_values else None
    d_min = None if h_min is None else int(score + h_min)
    structure = block_structure_payload(p, blocks, baseline)
    q_threshold = int(4 * (int(p) - 1) * score)
    out = {
        "score": int(score),
        "l1": int(l1_error),
        "max_abs": int(max_abs_error),
        "nonzero": int(nonzero_defect_count),
        "h_min": int(h_min) if h_min is not None else None,
        "D_min_1": int(d_min) if d_min is not None else None,
        "D_min_ratio": float(d_min) / float(score) if score > 0 and d_min is not None else None,
        "improving_swap_count": int(len(improving)),
        "P_<0": float(len(improving)) / float(len(moves)) if moves else None,
        "P_0": float(near[0]) / float(len(moves)) if moves else None,
        "P_4": float(near[4]) / float(len(moves)) if moves else None,
        "P_8": float(near[8]) / float(len(moves)) if moves else None,
        "P_16": float(near[16]) / float(len(moves)) if moves else None,
        "kappa_max": max(kappas) if kappas else None,
        "kappa_q90": quantile(kappas, 0.90),
        "kappa_q99": quantile(kappas, 0.99),
        "Q_ratio": float(sum(q_values)) / float(q_threshold) if q_threshold > 0 else None,
        "Q_tot": int(sum(q_values)),
        "E_total": int(structure["E_total"]),
        "AP_total": int(structure["AP_total"]),
        "E_excess_total": float(structure["E_excess_total"]),
        "AP_excess_total": float(structure["AP_excess_total"]),
        "InitHardness": float(structure["InitHardness"]),
    }
    out.update(moment_payload(counts, lam, p))
    return out


def defect_pattern(counts, lam, p):
    rho = rho_vector(counts, lam)
    nonzero = [{"shift": int(d), "defect": int(rho[d])} for d in range(1, int(p)) if int(rho[d]) != 0]
    pairs = []
    positive_pairs = []
    negative_pairs = []
    other_pairs = []
    for d in range(1, (int(p) + 1) // 2):
        e = (-d) % int(p)
        rd = int(rho[d])
        re = int(rho[e])
        if rd == 0 and re == 0:
            continue
        pair = {"pair": [int(d), int(e)], "defects": [rd, re]}
        pairs.append(pair)
        if rd == re and rd > 0:
            positive_pairs.append(pair)
        elif rd == re and rd < 0:
            negative_pairs.append(pair)
        else:
            other_pairs.append(pair)
    if len(positive_pairs) == 1 and len(negative_pairs) == 1 and not other_pairs:
        pattern_type = "+1 on +/-a, -1 on +/-b"
    elif len(positive_pairs) == 1 and not negative_pairs and not other_pairs:
        pattern_type = "+1 on one +/- pair only"
    elif len(negative_pairs) == 1 and not positive_pairs and not other_pairs:
        pattern_type = "-1 on one +/- pair only"
    else:
        pattern_type = "other"
    abstract = "+pairs{}_ -pairs{}_ other{}".format(len(positive_pairs), len(negative_pairs), len(other_pairs))
    coordinate_signature = ";".join(
        ["{}:{}|{}".format(pair["pair"][0], pair["defects"][0], pair["defects"][1]) for pair in pairs]
    )
    return {
        "rho_sum": int(sum(rho[1:])),
        "nonzero_defect_coordinates": nonzero,
        "paired_coordinates": pairs,
        "positive_defect_pairs": positive_pairs,
        "negative_defect_pairs": negative_pairs,
        "other_pairs": other_pairs,
        "pattern_type": pattern_type,
        "pattern_signature": abstract,
        "coordinate_signature": coordinate_signature,
    }


def translate_block(block, shift, p):
    return set((int(x) + int(shift)) % int(p) for x in block)


def half_symdiff_distance(a, b):
    return int(len(set(a).symmetric_difference(set(b))) // 2)


def equal_size_permutations(ks):
    choices = [tuple(range(len(ks)))]
    groups = {}
    for idx, size in enumerate(ks):
        groups.setdefault(int(size), []).append(idx)
    per_group = []
    for indices in groups.values():
        if len(indices) <= 1:
            per_group.append([tuple(indices)])
        else:
            per_group.append(list(itertools.permutations(indices)))
    out = []
    for combo in itertools.product(*per_group):
        perm = list(range(len(ks)))
        for indices, mapped in zip(groups.values(), combo):
            for target_idx, source_idx in zip(indices, mapped):
                perm[target_idx] = source_idx
        out.append(tuple(perm))
    out.extend(choices)
    return sorted(set(out))


def aligned_exact_blocks(exact_blocks, perm, shift, p):
    return [translate_block(exact_blocks[int(perm[i])], shift, p) for i in range(4)]


def distance_for_alignment(blocks, exact_blocks, perm, shift, p):
    aligned = aligned_exact_blocks(exact_blocks, perm, shift, p)
    per_block = [half_symdiff_distance(blocks[i], aligned[i]) for i in range(4)]
    return int(sum(per_block)), per_block, aligned


def best_global_distance(blocks, exact_blocks, ks, p, use_perms):
    perms = equal_size_permutations(ks) if use_perms else [tuple(range(4))]
    best = None
    for perm in perms:
        for shift in range(int(p)):
            total, per_block, aligned = distance_for_alignment(blocks, exact_blocks, perm, shift, p)
            row = {"distance": int(total), "per_block": per_block, "perm": [int(x) for x in perm], "shift": int(shift), "_aligned": aligned}
            key = (row["distance"], row["per_block"], row["shift"], row["perm"])
            if best is None or key < (best["distance"], best["per_block"], best["shift"], best["perm"]):
                best = row
    return best


def blockwise_translation_lower_bound(blocks, exact_blocks, ks, p):
    best_payload = None
    for perm in equal_size_permutations(ks):
        per = []
        total = 0
        for i in range(4):
            block_best = None
            for shift in range(int(p)):
                dist = half_symdiff_distance(blocks[i], translate_block(exact_blocks[int(perm[i])], shift, p))
                if block_best is None or (dist, shift) < (block_best["distance"], block_best["shift"]):
                    block_best = {"distance": int(dist), "shift": int(shift)}
            per.append(block_best)
            total += int(block_best["distance"])
        payload = {"distance": int(total), "perm": [int(x) for x in perm], "per_block": per}
        if best_payload is None or int(total) < int(best_payload["distance"]):
            best_payload = payload
    return best_payload


def distance_summary_for_candidate(blocks, exact_blocks, ks, p):
    raw_total, raw_per, _aligned = distance_for_alignment(blocks, exact_blocks, tuple(range(4)), 0, p)
    global_best = best_global_distance(blocks, exact_blocks, ks, p, False)
    global_perm_best = best_global_distance(blocks, exact_blocks, ks, p, True)
    lower = blockwise_translation_lower_bound(blocks, exact_blocks, ks, p)
    return {
        "raw_distance": int(raw_total),
        "raw_per_block": raw_per,
        "global_translation_best_distance": int(global_best["distance"]),
        "global_translation_best_shift": int(global_best["shift"]),
        "global_translation_best_per_block": global_best["per_block"],
        "global_translation_plus_equal_size_permutation_best_distance": int(global_perm_best["distance"]),
        "global_translation_plus_equal_size_permutation_best_shift": int(global_perm_best["shift"]),
        "global_translation_plus_equal_size_permutation_best_perm": global_perm_best["perm"],
        "global_translation_plus_equal_size_permutation_best_per_block": global_perm_best["per_block"],
        "blockwise_translation_independent_lower_bound": int(lower["distance"]),
        "blockwise_translation_lower_bound_payload": lower,
        "_aligned_exact_for_best": global_perm_best["_aligned"],
    }


def direct_return_payload(blocks, aligned_exact, counts, lam, p):
    remove_sets = []
    add_sets = []
    swaps = []
    for i in range(4):
        remove = sorted(set(blocks[i]).difference(aligned_exact[i]))
        add = sorted(set(aligned_exact[i]).difference(blocks[i]))
        remove_sets.append(remove)
        add_sets.append(add)
        for r, a in zip(remove, add):
            swaps.append({"block": int(i), "remove": int(r), "add": int(a)})
    new_blocks = [set(blocks[i]).difference(remove_sets[i]).union(add_sets[i]) for i in range(4)]
    new_counts = total_diff_counts(p, new_blocks)
    return {
        "direct_return_radius": int(sum(len(x) for x in remove_sets)),
        "direct_return_score_after": int(score_counts(new_counts, lam)),
        "direct_return_valid": bool(score_counts(new_counts, lam) == 0),
        "remove_sets": remove_sets,
        "add_sets": add_sets,
        "swaps": swaps,
    }


def apply_swaps(blocks, swaps):
    out = [set(block) for block in blocks]
    for swap in swaps:
        b = int(swap["block"])
        r = int(swap["remove"])
        a = int(swap["add"])
        if r not in out[b] or a in out[b]:
            return None
        out[b].remove(r)
        out[b].add(a)
    return out


def sample_truncated_return(rng, blocks, counts, lam, p, direct_swaps, r, samples):
    parent_score = score_counts(counts, lam)
    if not direct_swaps:
        return {"r": int(r), "sample_count": 0, "best_score": int(parent_score), "score0_seen": parent_score == 0, "improvement_seen": False}
    k = min(int(r), len(direct_swaps))
    best_score = int(parent_score)
    sample_count = 0
    seen = set()
    max_unique = math.comb(len(direct_swaps), k) if hasattr(math, "comb") else int(samples)
    max_attempts = min(int(samples) * 4, max(int(samples), int(max_unique) * 2))
    for _ in range(max_attempts):
        if sample_count >= int(samples):
            break
        chosen = tuple(sorted(rng.sample(range(len(direct_swaps)), k)))
        if chosen in seen:
            continue
        seen.add(chosen)
        moves = [direct_swaps[i] for i in chosen]
        new_blocks = apply_swaps(blocks, moves)
        if new_blocks is None:
            continue
        score = score_counts(total_diff_counts(p, new_blocks), lam)
        sample_count += 1
        if score < best_score:
            best_score = int(score)
        if score == 0:
            break
    return {
        "r": int(r),
        "sample_count": int(sample_count),
        "best_score": int(best_score),
        "best_delta": int(best_score - parent_score),
        "score0_seen": bool(best_score == 0),
        "improvement_seen": bool(best_score < parent_score),
    }


def random_swap(rng, blocks, p):
    block_idx = rng.randrange(4)
    block = blocks[block_idx]
    removed = rng.choice(tuple(block))
    added = rng.randrange(int(p))
    while added in block:
        added = rng.randrange(int(p))
    return {"block": int(block_idx), "remove": int(removed), "add": int(added)}


def perturb_exact(rng, exact_blocks, p, radius):
    blocks = clone_blocks(exact_blocks)
    moves = []
    for _ in range(int(radius)):
        move = random_swap(rng, blocks, p)
        if apply_swap_to_blocks(blocks, {"block": move["block"], "removed": move["remove"], "added": move["add"]}):
            moves.append(move)
    return blocks, moves


def save_candidate_json(path, blocks, p, ks, lam, method, metadata):
    counts = total_diff_counts(p, blocks)
    score, l1_error, max_abs_error, nonzero = metrics_from_counts(counts, lam)
    ok, _bad = verify_sds(p, blocks, lam)
    entries_ok, hh_t_ok = verify_hadamard_exact(p, blocks)
    payload = {
        "v": int(p),
        "n": int(4 * int(p)),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": json_blocks(blocks),
        "score": int(score),
        "l1_error": int(l1_error),
        "max_abs_error": int(max_abs_error),
        "nonzero_defect_count": int(nonzero),
        "verify_sds": bool(ok),
        "generated_hadamard": bool(hh_t_ok),
        "hh_t": bool(hh_t_ok),
        "entries_pm1_ok": bool(entries_ok),
        "construction": "Goethals-Seidel",
        "search_method": method,
        "canonical_hash": canonical_hash(blocks, ks, p),
        "canonical_repr_summary": canonical_repr_summary(blocks, ks, p),
        "error_histogram": error_histogram(counts, lam),
    }
    payload.update(metadata or {})
    write_json_safe(path, payload)
    return path


def candidate_from_blocks(blocks, p, ks, lam, baseline, origin_type, source_path, metadata):
    blocks = clone_blocks(blocks)
    counts = total_diff_counts(p, blocks)
    score, l1, max_abs, nonzero = [int(x) for x in metrics_from_counts(counts, lam)]
    pattern = defect_pattern(counts, lam, p)
    diag = full_diagnostic(blocks, counts, lam, p, baseline)
    row = {
        "origin_type": origin_type,
        "source_path": source_path,
        "score": int(score),
        "l1": int(l1),
        "max_abs": int(max_abs),
        "nonzero": int(nonzero),
        "canonical_hash": canonical_hash(blocks, ks, p),
        "blocks": json_blocks(blocks),
        "nonzero_defect_coordinates": pattern["nonzero_defect_coordinates"],
        "defect_values": pattern["nonzero_defect_coordinates"],
        "paired_coordinates": pattern["paired_coordinates"],
        "positive_defect_pairs": pattern["positive_defect_pairs"],
        "negative_defect_pairs": pattern["negative_defect_pairs"],
        "pattern_type": pattern["pattern_type"],
        "pattern_signature": pattern["pattern_signature"],
        "coordinate_signature": pattern["coordinate_signature"],
        "rho_sum": pattern["rho_sum"],
    }
    row.update(diag)
    row.update(metadata or {})
    row["_blocks"] = blocks
    row["_counts"] = counts
    return row


def stored_metrics_match(data, metrics):
    keys = [("score", 0), ("l1_error", 1), ("max_abs_error", 2), ("nonzero_defect_count", 3)]
    for key, idx in keys:
        if key in data and data[key] is not None and int(data[key]) != int(metrics[idx]):
            return False
    return True


def candidate_from_json_path(path, p, ks, lam, baseline, origin_type):
    data, v, _n, got_ks, got_lam, blocks = load_candidate(path)
    if int(v) != int(p) or tuple(got_ks) != tuple(ks) or int(got_lam) != int(lam):
        return None
    counts = total_diff_counts(p, blocks)
    metrics = metrics_from_counts(counts, lam)
    if not stored_metrics_match(data, metrics):
        return None
    score = int(metrics[0])
    if score not in LOW_SCORE_SET:
        return None
    return candidate_from_blocks(
        blocks,
        p,
        ks,
        lam,
        baseline,
        origin_type,
        path,
        {"stored_computed_match": True, "candidate_file_score": int(score)},
    )


def candidate_from_jsonl_payload(payload, source_path, line_no, p, ks, lam, baseline):
    if not isinstance(payload, dict) or "blocks" not in payload:
        return None
    try:
        blocks = normalize_blocks(int(p), payload["blocks"])
    except Exception:
        return None
    if tuple(len(block) for block in blocks) != tuple(ks):
        return None
    counts = total_diff_counts(p, blocks)
    metrics = metrics_from_counts(counts, lam)
    if not stored_metrics_match(payload, metrics):
        return None
    score = int(metrics[0])
    if score not in LOW_SCORE_SET:
        return None
    origin_hint = str(payload.get("origin") or payload.get("family") or payload.get("source_type") or payload.get("origin_detail") or "")
    if "exact" in origin_hint:
        return None
    return candidate_from_blocks(
        blocks,
        p,
        ks,
        lam,
        baseline,
        "search_derived",
        "{}:{}".format(source_path, line_no),
        {"stored_computed_match": True, "source_format": "jsonl"},
    )


def score_hint_from_path(path):
    match = re.search(r"score(\d+)", os.path.basename(path))
    if not match:
        return 10**9
    return int(match.group(1))


def balanced_append(rows_by_score, row, per_score_limit, seen):
    score = int(row["score"])
    if score not in LOW_SCORE_SET:
        return False
    if len(rows_by_score.setdefault(score, [])) >= int(per_score_limit):
        return False
    key = row["canonical_hash"]
    if key in seen:
        return False
    seen.add(key)
    rows_by_score[score].append(row)
    return True


def balanced_done(rows_by_score, per_score_limit):
    return all(len(rows_by_score.get(score, [])) >= int(per_score_limit) for score in sorted(LOW_SCORE_SET))


def flatten_balanced(rows_by_score, max_rows):
    out = []
    for score in sorted(LOW_SCORE_SET):
        out.extend(rows_by_score.get(score, []))
    return out[: int(max_rows)]


def discover_search_low_score_candidates(args, baseline):
    p = int(args.p)
    ks = tuple(int(k) for k in args.ks)
    lam = int(args.lam)
    roots = [
        os.path.join("outputs", "candidates", "small_p"),
        os.path.join("outputs", "explorations", "20260506_0915_small_p_escapability_validation"),
        os.path.join("outputs", "explorations", "20260506_0925_small_p_escapability_validation_all_modes_smoke"),
        os.path.join("outputs", "explorations", "20260506_1125_small_p_defect_targeted_lns_validation"),
        os.path.join("outputs", "explorations", "20260506_1200_p37_score4_false_basin_anatomy"),
        os.path.join("outputs", "explorations", "20260506_1557_p37_pipeline_framework"),
        os.path.join("outputs", "explorations", "20260506_1638_p37_trajectory_signature_tracking"),
        os.path.join("outputs", "explorations", "20260506_1657_p37_initialization_family_comparison"),
    ]
    rows_by_score = {}
    seen = set()
    per_score_limit = max(1, int(math.ceil(float(args.max_search_candidates) / float(len(LOW_SCORE_SET)))))
    json_paths = []
    jsonl_paths = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        json_paths.extend(glob.glob(os.path.join(root, "**", "*.json"), recursive=True))
        jsonl_paths.extend(glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True))
    for path in sorted(set(json_paths), key=lambda item: (score_hint_from_path(item), item)):
        if balanced_done(rows_by_score, per_score_limit):
            break
        if score_hint_from_path(path) not in LOW_SCORE_SET and score_hint_from_path(path) != 10**9:
            continue
        if os.path.basename(path).startswith("exact_v37") or "score0_candidate_exact_derived" in path:
            continue
        try:
            if os.path.getsize(path) > 2_000_000:
                continue
            row = candidate_from_json_path(path, p, ks, lam, baseline, "search_derived")
        except Exception:
            row = None
        if row is None:
            continue
        balanced_append(rows_by_score, row, per_score_limit, seen)
    for path in sorted(set(jsonl_paths)):
        if balanced_done(rows_by_score, per_score_limit):
            break
        try:
            if os.path.getsize(path) > 10_000_000:
                continue
            with open(path) as f:
                for line_no, line in enumerate(f, start=1):
                    if balanced_done(rows_by_score, per_score_limit):
                        break
                    try:
                        payload = json.loads(line)
                    except Exception:
                        continue
                    row = candidate_from_jsonl_payload(payload, path, line_no, p, ks, lam, baseline)
                    if row is None:
                        continue
                    balanced_append(rows_by_score, row, per_score_limit, seen)
        except Exception:
            continue
    return flatten_balanced(rows_by_score, int(args.max_search_candidates))


def generate_exact_derived_low_score(args, exact_blocks, baseline, out_dir):
    p = int(args.p)
    ks = tuple(int(k) for k in args.ks)
    lam = int(args.lam)
    rng = random.Random(int(int(args.seed) + 6001))
    rows = []
    seen = set()
    score0_paths = []
    score0_hashes = set()
    r_values = parse_r_values(args.r_values, args.max_r)
    for r in r_values:
        kept = 0
        best_score = None
        for sample_idx in range(int(args.samples_per_r)):
            blocks, moves = perturb_exact(rng, exact_blocks, p, r)
            counts = total_diff_counts(p, blocks)
            score = score_counts(counts, lam)
            if best_score is None or score < best_score:
                best_score = int(score)
            if score == 0:
                key = canonical_hash(blocks, ks, p)
                if key not in score0_hashes:
                    score0_hashes.add(key)
                    path = os.path.join(out_dir, "score0_candidate_exact_perturb_r{}_sample{}.json".format(r, sample_idx))
                    score0_paths.append(
                        save_candidate_json(
                            path,
                            blocks,
                            p,
                            ks,
                            lam,
                            SCRIPT_NAME,
                            {"origin_type": "exact_derived", "perturb_radius": int(r), "applied_moves": moves},
                        )
                    )
                continue
            if score not in LOW_SCORE_SET:
                continue
            key = canonical_hash(blocks, ks, p)
            if key in seen:
                continue
            seen.add(key)
            row = candidate_from_blocks(
                blocks,
                p,
                ks,
                lam,
                baseline,
                "exact_derived",
                "exact_perturbation",
                {
                    "perturb_radius": int(r),
                    "direct_return_radius_from_generation": int(r),
                    "sample": int(sample_idx),
                    "applied_moves": moves,
                },
            )
            rows.append(row)
            kept += 1
        print("exact perturb r={} best_score={} kept_low_score={}".format(r, best_score, kept))
        sys.stdout.flush()
    return rows, {"r_values": list(r_values), "score0_candidate_paths": score0_paths, "unique_score0_hashes": int(len(score0_hashes))}


def add_distance_and_return(rows, exact_blocks, p, ks, lam, baseline, args, do_truncated):
    rng = random.Random(int(int(args.seed) + 6002))
    out = []
    for idx, row in enumerate(rows, start=1):
        dist = distance_summary_for_candidate(row["_blocks"], exact_blocks, ks, p)
        direct = direct_return_payload(row["_blocks"], dist["_aligned_exact_for_best"], row["_counts"], lam, p)
        row["raw_distance"] = dist["raw_distance"]
        row["global_translation_best_distance"] = dist["global_translation_best_distance"]
        row["global_translation_plus_equal_size_permutation_best_distance"] = dist["global_translation_plus_equal_size_permutation_best_distance"]
        row["blockwise_translation_independent_lower_bound"] = dist["blockwise_translation_independent_lower_bound"]
        row["direct_return_radius"] = direct["direct_return_radius"]
        row["direct_return_score_after"] = direct["direct_return_score_after"]
        row["direct_return_valid"] = direct["direct_return_valid"]
        row["return_radius_proxy"] = int(direct["direct_return_radius"])
        if row["origin_type"] == "exact_derived":
            row["return_radius_proxy"] = int(row.get("direct_return_radius_from_generation") or direct["direct_return_radius"])
        if do_truncated:
            best_by_r = {}
            improvement = False
            score0 = False
            for r in range(1, 7):
                probe = sample_truncated_return(rng, row["_blocks"], row["_counts"], lam, p, direct["swaps"], r, int(args.return_samples_per_r))
                best_by_r[str(r)] = probe["best_score"]
                improvement = improvement or bool(probe["improvement_seen"])
                score0 = score0 or bool(probe["score0_seen"])
            row["best_truncated_return_score_by_r"] = best_by_r
            row["truncated_return_improvement_seen"] = bool(improvement)
            row["truncated_return_score0_seen"] = bool(score0)
        else:
            row["best_truncated_return_score_by_r"] = {}
            row["truncated_return_improvement_seen"] = None
            row["truncated_return_score0_seen"] = None
        out.append(row)
        if idx % 25 == 0:
            print("distance diagnostics {}/{} origin={}".format(idx, len(rows), row["origin_type"]))
            sys.stdout.flush()
    return out


def median(values):
    values = sorted([float(v) for v in values if v is not None])
    if not values:
        return None
    n = len(values)
    if n % 2:
        return values[n // 2]
    return (values[n // 2 - 1] + values[n // 2]) / 2.0


def mean(values):
    values = [float(v) for v in values if v is not None]
    if not values:
        return None
    return sum(values) / float(len(values))


def pstdev(values):
    values = [float(v) for v in values if v is not None]
    if len(values) <= 1:
        return None
    return statistics.pstdev(values)


def score_band_origin_summary(rows):
    groups = {}
    for row in rows:
        if int(row["score"]) not in LOW_SCORE_SET:
            continue
        key = (int(row["score"]), row["origin_type"])
        groups.setdefault(key, []).append(row)
    out = []
    fields = ["D_min_ratio", "P_4", "P_8", "P_16", "kappa_max", "Q_ratio", "return_radius_proxy", "InitHardness"]
    for key, group in sorted(groups.items()):
        score, origin = key
        item = {"score": int(score), "origin_type": origin, "count": int(len(group))}
        for field in fields:
            item["median_{}".format(field)] = median([row.get(field) for row in group])
        out.append(item)
    return out


def effect_size(a, b):
    a = [float(x) for x in a if x is not None]
    b = [float(x) for x in b if x is not None]
    if not a or not b:
        return None
    ma = sum(a) / float(len(a))
    mb = sum(b) / float(len(b))
    va = statistics.pvariance(a) if len(a) > 1 else 0.0
    vb = statistics.pvariance(b) if len(b) > 1 else 0.0
    pooled = math.sqrt((va + vb) / 2.0)
    if pooled == 0:
        return None
    return float(ma - mb) / pooled


def auc_like(a, b, direction):
    a = [float(x) for x in a if x is not None]
    b = [float(x) for x in b if x is not None]
    if not a or not b:
        return None
    wins = 0.0
    total = 0
    for x in a:
        for y in b:
            total += 1
            if direction == "low":
                if x < y:
                    wins += 1.0
                elif x == y:
                    wins += 0.5
            else:
                if x > y:
                    wins += 1.0
                elif x == y:
                    wins += 0.5
    return wins / float(total) if total else None


def feature_separation(rows):
    exact = [row for row in rows if row["origin_type"] == "exact_derived"]
    search = [row for row in rows if row["origin_type"] == "search_derived"]
    out = []
    for feature, direction in FEATURE_DIRECTIONS.items():
        a = [row.get(feature) for row in exact]
        b = [row.get(feature) for row in search]
        out.append(
            {
                "feature": feature,
                "direction_exact_like": direction,
                "exact_derived_count": int(sum(1 for x in a if x is not None)),
                "search_derived_count": int(sum(1 for x in b if x is not None)),
                "exact_derived_median": median(a),
                "search_derived_median": median(b),
                "median_difference_exact_minus_search": None if median(a) is None or median(b) is None else float(median(a) - median(b)),
                "effect_size_exact_minus_search": effect_size(a, b),
                "auc_like_exact_better_than_search": auc_like(a, b, direction),
            }
        )
    return out


def z_stats(rows, fields):
    stats = {}
    for field in fields:
        values = [float(row[field]) for row in rows if row.get(field) is not None]
        if values:
            stats[field] = {"mean": sum(values) / float(len(values)), "std": statistics.pstdev(values) if len(values) > 1 else 0.0}
        else:
            stats[field] = {"mean": 0.0, "std": 0.0}
    return stats


def zscore(value, stat):
    if value is None:
        return 0.0
    try:
        value = float(value)
    except Exception:
        return 0.0
    if not math.isfinite(value) or not stat["std"]:
        return 0.0
    return (value - stat["mean"]) / stat["std"]


def exact_like_scores(rows):
    fields = ("D_min_ratio", "P_4", "P_8", "kappa_max", "Q_ratio")
    stats = z_stats(rows, fields)
    score_rows = []
    for row in rows:
        score = (
            -zscore(row.get("D_min_ratio"), stats["D_min_ratio"])
            + zscore(row.get("P_4"), stats["P_4"])
            + zscore(row.get("P_8"), stats["P_8"])
            + zscore(row.get("kappa_max"), stats["kappa_max"])
            - 0.25 * zscore(row.get("Q_ratio"), stats["Q_ratio"])
        )
        score_rows.append(
            {
                "canonical_hash": row["canonical_hash"],
                "origin_type": row["origin_type"],
                "score": int(row["score"]),
                "ExactLikeScore": float(score),
                "D_min_ratio": row.get("D_min_ratio"),
                "P_4": row.get("P_4"),
                "P_8": row.get("P_8"),
                "kappa_max": row.get("kappa_max"),
                "Q_ratio": row.get("Q_ratio"),
                "return_radius_proxy": row.get("return_radius_proxy"),
            }
        )
    summary = []
    groups = {}
    for row in score_rows:
        groups.setdefault(row["origin_type"], []).append(row)
    for origin, group in sorted(groups.items()):
        summary.append(
            {
                "origin_type": origin,
                "count": int(len(group)),
                "median_ExactLikeScore": median([row["ExactLikeScore"] for row in group]),
                "median_D_min_ratio": median([row.get("D_min_ratio") for row in group]),
                "median_P_8": median([row.get("P_8") for row in group]),
                "median_kappa_max": median([row.get("kappa_max") for row in group]),
                "median_Q_ratio": median([row.get("Q_ratio") for row in group]),
            }
        )
    return score_rows, summary


def score4_special(rows):
    score4 = [row for row in rows if int(row["score"]) == 4]
    table = []
    for row in score4:
        table.append(
            {
                "origin_type": row["origin_type"],
                "canonical_hash": row["canonical_hash"],
                "source_path": row.get("source_path"),
                "pattern_signature": row.get("pattern_signature"),
                "pattern_type": row.get("pattern_type"),
                "D_min_ratio": row.get("D_min_ratio"),
                "P_4": row.get("P_4"),
                "P_8": row.get("P_8"),
                "P_16": row.get("P_16"),
                "kappa_max": row.get("kappa_max"),
                "return_radius_proxy": row.get("return_radius_proxy"),
                "direct_return_radius": row.get("direct_return_radius"),
                "truncated_return_improvement_seen": row.get("truncated_return_improvement_seen"),
                "truncated_return_score0_seen": row.get("truncated_return_score0_seen"),
            }
        )
    patterns = sorted(set(row.get("pattern_signature") for row in table))
    origin_counts = {}
    for row in table:
        origin_counts[row["origin_type"]] = origin_counts.get(row["origin_type"], 0) + 1
    return table, {
        "score4_count": int(len(table)),
        "origin_counts": origin_counts,
        "pattern_signatures": patterns,
        "exact_derived_score4_count": int(origin_counts.get("exact_derived", 0)),
        "search_derived_score4_count": int(origin_counts.get("search_derived", 0)),
    }


def exact_validation_payload(exact_path, exact_blocks, p, ks, lam, baseline):
    counts = total_diff_counts(p, exact_blocks)
    score, l1, max_abs, nonzero = [int(x) for x in metrics_from_counts(counts, lam)]
    sds_ok, bad = verify_sds(p, exact_blocks, lam)
    entries_ok, hh_t_ok = verify_hadamard_exact(p, exact_blocks)
    row = candidate_from_blocks(exact_blocks, p, ks, lam, baseline, "exact", exact_path, {})
    return {
        "exact_json": exact_path,
        "score": int(score),
        "l1": int(l1),
        "max_abs": int(max_abs),
        "nonzero": int(nonzero),
        "SDS_OK": bool(sds_ok),
        "bad_differences": bad[:10],
        "entries_pm1_ok": bool(entries_ok),
        "HHt_148I": bool(hh_t_ok),
        "canonical_hash": row["canonical_hash"],
    }, row


def verdict(value):
    if value is None:
        return "inconclusive"
    return "supported" if value else "not_supported"


def evaluate_hypotheses(rows, sep_rows, score4_json):
    exact = [row for row in rows if row["origin_type"] == "exact_derived"]
    search = [row for row in rows if row["origin_type"] == "search_derived"]
    med_exact_radius = median([row.get("return_radius_proxy") for row in exact])
    med_search_radius = median([row.get("return_radius_proxy") for row in search])
    h1 = None
    if search and med_search_radius is not None:
        h1 = med_search_radius >= 10
    strong_features = []
    for row in sep_rows:
        auc = row.get("auc_like_exact_better_than_search")
        if auc is not None and auc >= 0.75:
            strong_features.append(row["feature"])
    h2 = len([f for f in strong_features if f in ("D_min_ratio", "P_4", "P_8", "kappa_max", "return_radius_proxy")]) >= 2
    score4_patterns_one = len(score4_json.get("pattern_signatures") or []) == 1
    exact_score4 = score4_json.get("exact_derived_score4_count", 0) > 0
    search_score4 = score4_json.get("search_derived_score4_count", 0) > 0
    h3 = None
    if score4_patterns_one and exact_score4 and search_score4:
        h3 = True
    elif score4_patterns_one and search_score4 and not exact_score4:
        h3 = None
    return {
        "H1_low_score_does_not_imply_exact_proximity": {
            "verdict": verdict(h1),
            "search_median_return_radius_proxy": med_search_radius,
            "exact_derived_median_return_radius_proxy": med_exact_radius,
        },
        "H2_exact_vs_search_low_score_feature_separation": {
            "verdict": verdict(h2),
            "strong_auc_features": strong_features,
        },
        "H3_score4_pattern_one_basin_type_not_one": {
            "verdict": verdict(h3),
            "score4_patterns_one": bool(score4_patterns_one),
            "exact_derived_score4_present": bool(exact_score4),
            "search_derived_score4_present": bool(search_score4),
            "note": "If exact-derived score=4 is not sampled, basin-type multiplicity at score=4 remains inconclusive in this run.",
        },
    }


def make_summary(path, context):
    hyp = context["hypotheses"]
    sep = {row["feature"]: row for row in context["feature_separation"]}
    score4 = context["score4_special_json"]
    exact_count = context["exact_derived_count"]
    search_count = context["search_derived_count"]
    search_score4 = score4.get("search_derived_score4_count", 0)
    exact_score4 = score4.get("exact_derived_score4_count", 0)
    d_auc = sep.get("D_min_ratio", {}).get("auc_like_exact_better_than_search")
    p8_auc = sep.get("P_8", {}).get("auc_like_exact_better_than_search")
    k_auc = sep.get("kappa_max", {}).get("auc_like_exact_better_than_search")
    r_auc = sep.get("return_radius_proxy", {}).get("auc_like_exact_better_than_search")
    lines = [
        "# p37 Exact-Derived vs Search-Derived Low-Score Comparison",
        "",
        "This run compares controlled exact perturbations against existing search-derived low-score candidates. It is not a heavy search and not a Hadamard 668 construction run.",
        "",
        "## Run",
        "",
        "- p: `{}`".format(context["p"]),
        "- ks: `{}`".format(context["ks"]),
        "- lambda: `{}`".format(context["lambda"]),
        "- exact_json: `{}`".format(context["exact_json"]),
        "- search-derived low-score count: `{}`".format(search_count),
        "- exact-derived low-score count: `{}`".format(exact_count),
        "- score=0 only is success.",
        "",
        "## Hypotheses",
        "",
        "```json",
        json.dumps(json_safe(hyp), indent=2, sort_keys=True),
        "```",
        "",
        "## Required Answers",
        "",
        "1. exact-derived low-score candidates は何件得られたか: `{}`.".format(exact_count),
        "2. search-derived low-score candidates は何件得られたか: `{}`.".format(search_count),
        "3. exact-derived score=4 は出たか: `{}` 件。".format(exact_score4),
        "4. search-derived score=4 と exact-derived score=4 は比較できたか: `{}`。".format("yes" if search_score4 and exact_score4 else "no"),
        "5. score=4 defect pattern は理論通り +1 on +/-a, -1 on +/-b だったか: `{}`; signatures `{}`.".format(score4.get("all_score4_theory_pattern"), score4.get("pattern_signatures")),
        "6. exact-derived と search-derived は D_min_ratio / P_tau / kappa で分離できたか: D_min AUC `{}`, P8 AUC `{}`, kappa AUC `{}`.".format(d_auc, p8_auc, k_auc),
        "7. return radius proxy は origin_type を分けたか: AUC `{}`.".format(r_auc),
        "8. search-derived score=4 は exact から遠い false-basin type という見方を支持したか: `{}`.".format(context["search_score4_false_basin_supported"]),
        "9. H1, H2, H3 は supported / not_supported / inconclusive のどれか: H1 `{}`, H2 `{}`, H3 `{}`.".format(
            hyp["H1_low_score_does_not_imply_exact_proximity"]["verdict"],
            hyp["H2_exact_vs_search_low_score_feature_separation"]["verdict"],
            hyp["H3_score4_pattern_one_basin_type_not_one"]["verdict"],
        ),
        "10. 668 に戻すとき、score164/176 をどう読むべきか: low score should be treated as defect-space proximity only; keep candidates whose D_min/S, P_tau, kappa, and return-like probes look exact-basin-like, and de-prioritize low-score points with collapsed local mobility.",
        "",
        "## Notes",
        "",
        "- Exact distance is a lightweight proxy, not a complete equivalence search.",
        "- Exact-derived candidates are controlled perturbations, not unguided search successes.",
        "- p=37 behavior should not be over-generalized to 668 without repeating the diagnostics.",
    ]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Compare exact-derived and search-derived p37 low-score candidates.")
    parser.add_argument("--p", type=int, default=37)
    parser.add_argument("--ks", type=parse_ks, default=(13, 16, 18, 18))
    parser.add_argument("--lambda", dest="lam", type=int, default=28)
    parser.add_argument("--exact-json", default="outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json")
    parser.add_argument("--max-search-candidates", type=int, default=100)
    parser.add_argument("--max-r", type=int, default=10)
    parser.add_argument("--r-values", default="")
    parser.add_argument("--samples-per-r", type=int, default=1000)
    parser.add_argument("--return-samples-per-r", type=int, default=500)
    parser.add_argument("--seed", type=int, default=60037)
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
        out_dir = args.out_dir or os.path.join("outputs", "explorations", "{}_p37_exact_vs_search_low_score_comparison".format(now_stamp()))
        ensure_dir(out_dir)
        baseline = random_baseline_tuple(p, ks)
        run_config = {
            "script": SCRIPT_NAME,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "p": int(p),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "exact_json": args.exact_json,
            "max_search_candidates": int(args.max_search_candidates),
            "r_values": list(parse_r_values(args.r_values, args.max_r)),
            "samples_per_r": int(args.samples_per_r),
            "return_samples_per_r": int(args.return_samples_per_r),
            "out_dir": out_dir,
            "note": "score=0 only is success; exact perturbation is controlled sampling.",
        }
        write_json_safe(os.path.join(out_dir, "run_config.json"), run_config)
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# Run Log\n\n")
            f.write("- script: `{}`\n".format(SCRIPT_NAME))
            f.write("- score=0 only is success\n")
            f.write("- distance proxies are not exhaustive equivalence distances\n")

        _data, v, _n, got_ks, got_lam, exact_blocks = load_candidate(args.exact_json)
        if int(v) != p or tuple(got_ks) != tuple(ks) or int(got_lam) != lam:
            raise ValueError("exact-json parameters do not match target")
        exact_validation, exact_diag_row = exact_validation_payload(args.exact_json, exact_blocks, p, ks, lam, baseline)
        write_json_safe(os.path.join(out_dir, "exact_validation.json"), exact_validation)
        print("exact validation:", exact_validation)
        sys.stdout.flush()

        search_rows = discover_search_low_score_candidates(args, baseline)
        print("search low-score candidates:", len(search_rows))
        sys.stdout.flush()
        search_rows = add_distance_and_return(search_rows, exact_blocks, p, ks, lam, baseline, args, do_truncated=True)
        write_jsonl(os.path.join(out_dir, "search_low_score_candidates.jsonl"), search_rows)

        exact_rows, exact_generation = generate_exact_derived_low_score(args, exact_blocks, baseline, out_dir)
        exact_rows = add_distance_and_return(exact_rows, exact_blocks, p, ks, lam, baseline, args, do_truncated=False)
        write_jsonl(os.path.join(out_dir, "exact_perturbation_low_score_candidates.jsonl"), exact_rows)

        all_rows = [exact_diag_row] + exact_rows + search_rows
        write_jsonl(os.path.join(out_dir, "candidate_diagnostics.jsonl"), all_rows)

        band_summary = score_band_origin_summary(exact_rows + search_rows)
        band_fields = [
            "score",
            "origin_type",
            "count",
            "median_D_min_ratio",
            "median_P_4",
            "median_P_8",
            "median_P_16",
            "median_kappa_max",
            "median_Q_ratio",
            "median_return_radius_proxy",
            "median_InitHardness",
        ]
        write_csv(os.path.join(out_dir, "score_band_origin_summary.csv"), band_summary, band_fields)
        write_json_safe(os.path.join(out_dir, "score_band_origin_summary.json"), {"rows": band_summary})

        sep_rows = feature_separation(exact_rows + search_rows)
        write_csv(
            os.path.join(out_dir, "exact_vs_search_feature_separation.csv"),
            sep_rows,
            [
                "feature",
                "direction_exact_like",
                "exact_derived_count",
                "search_derived_count",
                "exact_derived_median",
                "search_derived_median",
                "median_difference_exact_minus_search",
                "effect_size_exact_minus_search",
                "auc_like_exact_better_than_search",
            ],
        )

        score4_rows, score4_json = score4_special(exact_rows + search_rows)
        score4_json["all_score4_theory_pattern"] = bool(score4_rows) and all(row["pattern_type"] == "+1 on +/-a, -1 on +/-b" for row in score4_rows)
        if not score4_json["exact_derived_score4_count"]:
            score4_json["exact_derived_score4_note"] = "exact-derived score4 not sampled up to max-r / samples"
        write_csv(
            os.path.join(out_dir, "score4_special_comparison.csv"),
            score4_rows,
            [
                "origin_type",
                "canonical_hash",
                "source_path",
                "pattern_signature",
                "pattern_type",
                "D_min_ratio",
                "P_4",
                "P_8",
                "P_16",
                "kappa_max",
                "return_radius_proxy",
                "direct_return_radius",
                "truncated_return_improvement_seen",
                "truncated_return_score0_seen",
            ],
        )
        write_json_safe(os.path.join(out_dir, "score4_special_comparison.json"), score4_json)

        score_rows, score_summary = exact_like_scores(exact_rows + search_rows)
        write_jsonl(os.path.join(out_dir, "exact_like_scores.jsonl"), score_rows)
        write_csv(
            os.path.join(out_dir, "exact_like_score_by_origin.csv"),
            score_summary,
            ["origin_type", "count", "median_ExactLikeScore", "median_D_min_ratio", "median_P_8", "median_kappa_max", "median_Q_ratio"],
        )

        hyp = evaluate_hypotheses(exact_rows + search_rows, sep_rows, score4_json)
        score4_search = [row for row in search_rows if int(row["score"]) == 4]
        search_score4_false_basin_supported = bool(score4_search) and median([row.get("return_radius_proxy") for row in score4_search]) is not None and median([row.get("return_radius_proxy") for row in score4_search]) >= 10
        write_json_safe(
            os.path.join(out_dir, "low_score_comparison_diagnostics.json"),
            {
                "hypotheses": hyp,
                "exact_generation": exact_generation,
                "search_score4_false_basin_supported": bool(search_score4_false_basin_supported),
                "search_score4_return_radius_median": median([row.get("return_radius_proxy") for row in score4_search]),
            },
        )
        make_summary(
            os.path.join(out_dir, "p37_exact_vs_search_low_score_comparison_summary.md"),
            {
                "p": p,
                "ks": [int(k) for k in ks],
                "lambda": lam,
                "exact_json": args.exact_json,
                "exact_derived_count": len(exact_rows),
                "search_derived_count": len(search_rows),
                "feature_separation": sep_rows,
                "score4_special_json": score4_json,
                "hypotheses": hyp,
                "search_score4_false_basin_supported": bool(search_score4_false_basin_supported),
            },
        )
        print("SUMMARY:", os.path.join(out_dir, "p37_exact_vs_search_low_score_comparison_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
