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
    canonical_hash,
    canonical_repr_summary,
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


SCRIPT_NAME = "55_p37_score4_false_basin_anatomy"
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


def write_jsonl(path, rows):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(json_safe(public_row(row)), sort_keys=True) + "\n")


def public_row(row):
    if not isinstance(row, dict):
        return row
    return {k: v for k, v in row.items() if not str(k).startswith("_")}


def write_csv(path, rows, fields):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: json_safe(row.get(field)) for field in fields})


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
    return {"E_energy": e_energy, "E_AP": e_ap, "E_Q": e_q}


def random_baseline_tuple(p, ks):
    blocks = [random_baseline_block(p, k) for k in ks]
    return {
        "p": int(p),
        "ks": [int(k) for k in ks],
        "blocks": blocks,
        "E_Q_total": sum(block["E_Q"] for block in blocks),
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
        rows.append(
            {
                "block": int(idx),
                "E": int(e),
                "AP": int(ap),
                "Q_formula": int(q),
                "E_excess": float(e_excess),
                "AP_excess": float(ap_excess),
            }
        )
        total_e_excess += e_excess
        total_ap_excess += ap_excess
        total_q += int(q)
    return {
        "blocks": rows,
        "Q_formula_total": int(total_q),
        "E_excess_total": float(total_e_excess),
        "AP_excess_total": float(total_ap_excess),
        "InitHardness": float(max(0.0, total_e_excess) + max(0.0, total_ap_excess)),
    }


def score_counts(counts, lam):
    return int(metrics_from_counts(counts, lam)[0])


def rho_vector(counts, lam):
    rho = [0] * len(counts)
    for d in range(1, len(counts)):
        rho[d] = int(counts[d] - lam)
    return rho


def moment_payload(counts, lam, p):
    summary = p_adic_moment_summary(counts, lam, powers=POWERS, modulus=p)
    moments = {"T{}".format(item["power"]): int(item["residue"]) for item in summary["moments"]}
    return {
        "padic_moments": moments,
        "moment_zero_count_3": int(sum(1 for key in ("T2", "T4", "T6") if moments[key] == 0)),
        "moment_zero_count_6": int(summary["moment_zero_count"]),
        "higher_moment_norm": int(sum(balanced_abs(moments[key], p) ** 2 for key in ("T8", "T10", "T12"))),
    }


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


def full_diagnostic(blocks, counts, lam, p, baseline):
    p = int(p)
    score = score_counts(counts, lam)
    rho = rho_vector(counts, lam)
    h_min = None
    h_values = []
    improving = 0
    near = {0: 0, 4: 0, 8: 0, 16: 0}
    num_swaps = 0
    sum_q = 0
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
                sum_q += q
                h_values.append(h)
                if h < 0:
                    improving += 1
                for threshold in near:
                    if h <= threshold:
                        near[threshold] += 1
                if h_min is None or h < h_min:
                    h_min = h
                    min_move = {"block": int(block_idx), "remove": int(removed), "add": int(added), "g": int(g), "q": int(q), "h": int(h)}
    structure = block_structure_payload(p, blocks, baseline)
    threshold = int(4 * (p - 1) * score)
    d_min = None if h_min is None else int(score + h_min)
    return {
        "score": int(score),
        "h_min": int(h_min) if h_min is not None else None,
        "D_min_1": d_min,
        "D_min_ratio": float(d_min) / float(score) if score > 0 and d_min is not None else None,
        "improving_swap_count": int(improving),
        "P_0": float(near[0]) / float(num_swaps) if num_swaps else None,
        "P_4": float(near[4]) / float(num_swaps) if num_swaps else None,
        "P_8": float(near[8]) / float(num_swaps) if num_swaps else None,
        "P_16": float(near[16]) / float(num_swaps) if num_swaps else None,
        "Q_ratio": float(sum_q) / float(threshold) if threshold > 0 else None,
        "Q_tot": int(sum_q),
        "InitHardness": float(structure["InitHardness"]),
        "min_h_move": min_move,
    }


def defect_pattern(counts, lam, p):
    rho = rho_vector(counts, lam)
    nonzero = [{"shift": int(d), "defect": int(rho[d])} for d in range(1, p) if int(rho[d]) != 0]
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
    abstract = "+pairs{}_ -pairs{}_ other{}".format(len(positive_pairs), len(negative_pairs), len(other_pairs))
    if len(positive_pairs) == 1 and len(negative_pairs) == 1 and not other_pairs:
        pattern_type = "+1 on one +/- pair, -1 on one +/- pair"
    elif len(positive_pairs) == 1 and not negative_pairs and not other_pairs:
        pattern_type = "+1 on one +/- pair only"
    elif len(negative_pairs) == 1 and not positive_pairs and not other_pairs:
        pattern_type = "-1 on one +/- pair only"
    else:
        pattern_type = "other"
    coordinate_signature = ";".join(
        ["{}:{}|{}".format(pair["pair"][0], pair["defects"][0], pair["defects"][1]) for pair in pairs]
    )
    return {
        "score": score_counts(counts, lam),
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
    base = list(range(len(ks)))
    perms = [tuple(base)]
    by_size = {}
    for idx, size in enumerate(ks):
        by_size.setdefault(int(size), []).append(idx)
    if 18 in by_size and len(by_size[18]) == 2:
        swapped = list(base)
        i, j = by_size[18]
        swapped[i], swapped[j] = swapped[j], swapped[i]
        perms.append(tuple(swapped))
    return list(dict((perm, True) for perm in perms).keys())


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
            if best is None or (row["distance"], row["per_block"], row["shift"], row["perm"]) < (best["distance"], best["per_block"], best["shift"], best["perm"]):
                best = row
    return best


def blockwise_translation_lower_bound(blocks, exact_blocks, ks, p):
    best_total = None
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
        if best_total is None or int(total) < int(best_total):
            best_total = int(total)
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


def sample_perturbation_from_exact(rng, exact_blocks, p, r):
    blocks = [set(block) for block in exact_blocks]
    swaps = []
    for _ in range(int(r)):
        for _attempt in range(100):
            b = rng.randrange(4)
            block = blocks[b]
            removed = rng.choice(tuple(block))
            added = rng.randrange(int(p))
            if added in block:
                continue
            blocks[b].remove(removed)
            blocks[b].add(added)
            swaps.append({"block": int(b), "remove": int(removed), "add": int(added)})
            break
    return blocks, swaps


def row_for_candidate(path, blocks, counts, ks, lam, p, baseline, source_type):
    metrics = metrics_from_counts(counts, lam)
    pattern = defect_pattern(counts, lam, p)
    diag = full_diagnostic(blocks, counts, lam, p, baseline)
    moments = moment_payload(counts, lam, p)
    return {
        "path": path,
        "source_type": source_type,
        "score": int(metrics[0]),
        "l1_error": int(metrics[1]),
        "max_abs_error": int(metrics[2]),
        "nonzero_defect_count": int(metrics[3]),
        "canonical_hash": canonical_hash(blocks, ks, p),
        "pattern_type": pattern["pattern_type"],
        "pattern_signature": pattern["pattern_signature"],
        "coordinate_signature": pattern["coordinate_signature"],
        "h_min": diag["h_min"],
        "D_min_ratio": diag["D_min_ratio"],
        "improving_swap_count": diag["improving_swap_count"],
        "P_0": diag["P_0"],
        "P_4": diag["P_4"],
        "P_8": diag["P_8"],
        "P_16": diag["P_16"],
        "Q_ratio": diag["Q_ratio"],
        "InitHardness": diag["InitHardness"],
        "moment_zero_count_6": moments["moment_zero_count_6"],
        "higher_moment_norm": moments["higher_moment_norm"],
        "_blocks": blocks,
        "_counts": counts,
        "_pattern": pattern,
        "_diagnostic": diag,
    }


def find_exact_candidates(args, baseline):
    p = int(args.p)
    ks = tuple(int(k) for k in args.ks)
    lam = int(args.lam)
    paths = []
    if args.exact_json:
        paths.append(args.exact_json)
    else:
        roots = ["outputs", "outputs/candidates", "outputs/candidates/small_p", "outputs/explorations", "outputs/turyn"]
        seen = set()
        for root in roots:
            paths.extend(glob.glob(os.path.join(root, "**", "*.json"), recursive=True))
        paths = [path for path in paths if not (path in seen or seen.add(path))]
    rows = []
    for path in sorted(paths):
        try:
            if os.path.getsize(path) > 2 * 1024 * 1024:
                continue
            data, v, n, got_ks, got_lam, blocks = load_candidate(path)
            if int(v) != p or int(n) != 4 * p or tuple(got_ks) != ks or int(got_lam) != lam:
                continue
            counts = total_diff_counts(p, blocks)
            score = score_counts(counts, lam)
            if score != 0:
                continue
            rows.append(
                {
                    "path": path,
                    "v": int(v),
                    "n": int(n),
                    "ks": [int(k) for k in got_ks],
                    "lambda": int(got_lam),
                    "score": int(score),
                    "verify_sds_flag": bool(data.get("verify_sds", False)),
                    "generated_hadamard_flag": bool(data.get("generated_hadamard", False)),
                    "hh_t_flag": bool(data.get("hh_t", False)),
                    "canonical_hash": canonical_hash(blocks, ks, p),
                    "_blocks": blocks,
                    "_counts": counts,
                }
            )
        except Exception:
            continue
    if not rows:
        raise ValueError("no exact p={} candidate found; pass --exact-json".format(p))
    return rows


def discover_score4_candidates(args, baseline):
    p = int(args.p)
    ks = tuple(int(k) for k in args.ks)
    lam = int(args.lam)
    paths = []
    if args.score4_paths:
        paths = [part.strip() for part in args.score4_paths.split(",") if part.strip()]
    else:
        paths.extend(glob.glob(os.path.join("outputs", "candidates", "small_p", "candidate_v{}_score4_*.json".format(p))))
        paths.extend(glob.glob(os.path.join("outputs", "explorations", "**", "*.json"), recursive=True))
    rows = []
    seen = set()
    for path in sorted(paths):
        try:
            if os.path.getsize(path) > 2 * 1024 * 1024:
                continue
            data, v, _n, got_ks, got_lam, blocks = load_candidate(path)
            if int(v) != p or tuple(got_ks) != ks or int(got_lam) != lam:
                continue
            counts = total_diff_counts(p, blocks)
            metrics = metrics_from_counts(counts, lam)
            if int(metrics[0]) != 4:
                continue
            if data.get("score") is not None and int(data.get("score")) != int(metrics[0]):
                continue
            key = canonical_hash(blocks, ks, p)
            if key in seen:
                continue
            seen.add(key)
            row = row_for_candidate(path, blocks, counts, ks, lam, p, baseline, "search")
            row["stored_computed_match"] = bool(
                data.get("score") == metrics[0]
                and data.get("l1_error") == metrics[1]
                and data.get("max_abs_error") == metrics[2]
            )
            rows.append(row)
        except Exception:
            continue
    rows.sort(key=lambda row: (row["source_type"], row["path"]))
    return rows[: int(args.max_score4)]


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
        "_blocks_after": new_blocks,
        "_counts_after": new_counts,
    }


def sample_truncated_return(rng, blocks, counts, lam, p, direct_swaps, r, samples, baseline):
    parent_score = score_counts(counts, lam)
    if not direct_swaps:
        return {
            "r": int(r),
            "sample_count": 0,
            "best_score_after_truncated_return_r": int(parent_score),
            "best_h_after": 0,
            "best_D_min_ratio_after": None,
            "score0_seen": bool(parent_score == 0),
            "score_improvement_seen": False,
            "best_moves": [],
        }
    best = None
    seen = set()
    sample_count = 0
    k = min(int(r), len(direct_swaps))
    for _ in range(int(samples)):
        chosen = tuple(sorted(rng.sample(range(len(direct_swaps)), k)))
        if chosen in seen:
            continue
        seen.add(chosen)
        moves = [direct_swaps[i] for i in chosen]
        new_blocks = apply_swaps(blocks, moves)
        if new_blocks is None:
            continue
        new_counts = total_diff_counts(p, new_blocks)
        score = score_counts(new_counts, lam)
        sample_count += 1
        if best is None or score < best["score"]:
            best = {"score": int(score), "moves": moves, "_blocks": new_blocks, "_counts": new_counts}
            if score == 0:
                break
    if best is None:
        best = {"score": int(parent_score), "moves": [], "_blocks": blocks, "_counts": counts}
    diag = full_diagnostic(best["_blocks"], best["_counts"], lam, p, baseline) if best["score"] <= 8 and best["score"] > 0 else {}
    return {
        "r": int(r),
        "sample_count": int(sample_count),
        "best_score_after_truncated_return_r": int(best["score"]),
        "best_h_after": int(best["score"] - parent_score),
        "best_D_min_ratio_after": diag.get("D_min_ratio"),
        "score0_seen": bool(best["score"] == 0),
        "score_improvement_seen": bool(best["score"] < parent_score),
        "best_moves": best["moves"],
    }


def make_defect_target_moves(blocks, counts, lam, p):
    p = int(p)
    rho = rho_vector(counts, lam)
    score = score_counts(counts, lam)
    rows = []
    for block_idx, block in enumerate(blocks):
        outside = [x for x in range(p) if x not in block]
        for removed in sorted(block):
            for added in outside:
                delta = delta_swap_list(p, block, removed, added)
                g = dot_delta(rho, delta)
                q = norm_delta(delta)
                h = int(2 * g + q)
                kappa = None if q == 0 else float(-2.0 * g) / float(q)
                alpha = None if score <= 0 or q <= 0 else float(-g) / math.sqrt(float(score * q))
                pos, neg, target = defect_mass_scores(rho, delta)
                rows.append(
                    {
                        "block": int(block_idx),
                        "remove": int(removed),
                        "add": int(added),
                        "g": int(g),
                        "q": int(q),
                        "h": int(h),
                        "kappa": kappa,
                        "alpha": alpha,
                        "positive_destroy": int(pos),
                        "negative_repair": int(neg),
                        "defect_target_score": int(target),
                    }
                )
    rows.sort(key=lambda row: (-row["defect_target_score"], row["h"], -float(row["kappa"] or -999), row["q"]))
    return rows


def moves_compatible(moves, blocks):
    by_block = {}
    for move in moves:
        b = int(move["block"])
        r = int(move["remove"])
        a = int(move["add"])
        if r not in blocks[b] or a in blocks[b]:
            return False
        bucket = by_block.setdefault(b, {"r": set(), "a": set()})
        if r in bucket["r"] or a in bucket["a"]:
            return False
        bucket["r"].add(r)
        bucket["a"].add(a)
    return True


def sample_defect_targeted_return(rng, blocks, counts, lam, p, top_k, r, samples):
    parent_score = score_counts(counts, lam)
    library = make_defect_target_moves(blocks, counts, lam, p)[: int(top_k)]
    best = None
    sample_count = 0
    seen = set()
    if not library:
        return {"r": int(r), "top_k": int(top_k), "sample_count": 0, "best_score_after": int(parent_score), "score0_seen": False, "score_improvement_seen": False, "best_moves": []}
    for _ in range(int(samples)):
        k = min(int(r), len(library))
        indices = tuple(sorted(rng.sample(range(len(library)), k)))
        if indices in seen:
            continue
        seen.add(indices)
        moves = [library[i] for i in indices]
        if not moves_compatible(moves, blocks):
            continue
        new_blocks = apply_swaps(blocks, moves)
        if new_blocks is None:
            continue
        new_counts = total_diff_counts(p, new_blocks)
        score = score_counts(new_counts, lam)
        sample_count += 1
        if best is None or score < best["score"]:
            best = {"score": int(score), "moves": moves}
            if score == 0:
                break
    if best is None:
        best = {"score": int(parent_score), "moves": []}
    return {
        "r": int(r),
        "top_k": int(top_k),
        "sample_count": int(sample_count),
        "best_score_after": int(best["score"]),
        "score0_seen": bool(best["score"] == 0),
        "score_improvement_seen": bool(best["score"] < parent_score),
        "best_moves": best["moves"],
    }


def run_exact_perturbations(args, exact_blocks, ks, lam, p, baseline):
    rng = random.Random(int(int(args.seed) + 5501))
    low_rows = []
    summary_rows = []
    for r in range(1, int(args.max_r) + 1):
        scores = []
        best = []
        score4_count = 0
        low_count = 0
        for sample_idx in range(int(args.samples_per_r)):
            blocks, swaps = sample_perturbation_from_exact(rng, exact_blocks, p, r)
            counts = total_diff_counts(p, blocks)
            score = score_counts(counts, lam)
            scores.append(score)
            item = {"score": int(score), "r": int(r), "sample": int(sample_idx), "moves": swaps, "_blocks": blocks, "_counts": counts}
            best.append(item)
            best.sort(key=lambda row: row["score"])
            del best[20:]
            if score <= 8:
                low_count += 1
                pattern = defect_pattern(counts, lam, p)
                diag = full_diagnostic(blocks, counts, lam, p, baseline) if score > 0 else {}
                moments = moment_payload(counts, lam, p)
                row = {
                    "source_type": "exact_perturbation",
                    "distance_from_exact": int(r),
                    "sample": int(sample_idx),
                    "score": int(score),
                    "is_score4": bool(score == 4),
                    "moves": swaps,
                    "pattern_type": pattern["pattern_type"],
                    "pattern_signature": pattern["pattern_signature"],
                    "coordinate_signature": pattern["coordinate_signature"],
                    "h_min": diag.get("h_min"),
                    "D_min_ratio": diag.get("D_min_ratio"),
                    "improving_swap_count": diag.get("improving_swap_count"),
                    "P_0": diag.get("P_0"),
                    "P_4": diag.get("P_4"),
                    "P_8": diag.get("P_8"),
                    "P_16": diag.get("P_16"),
                    "Q_ratio": diag.get("Q_ratio"),
                    "InitHardness": diag.get("InitHardness"),
                    "moment_zero_count_6": moments["moment_zero_count_6"],
                    "higher_moment_norm": moments["higher_moment_norm"],
                    "canonical_hash": canonical_hash(blocks, ks, p),
                    "_blocks": blocks,
                    "_counts": counts,
                }
                low_rows.append(row)
                if score == 4:
                    score4_count += 1
        summary_rows.append(
            {
                "r": int(r),
                "samples": int(args.samples_per_r),
                "best_score": int(min(scores)) if scores else None,
                "median_score": statistics.median(scores) if scores else None,
                "score_le_8_count": int(low_count),
                "score4_count": int(score4_count),
                "best20_scores": ";".join(str(row["score"]) for row in best),
            }
        )
    return low_rows, summary_rows


def make_summary_md(out_dir, args, exact_rows, score4_rows, pattern_summary, distance_summary, perturb_rows, return_rows, defect_return_rows, comparison_json):
    lines = []
    lines.append("# p37 Score4 False Basin Anatomy Summary")
    lines.append("")
    lines.append("This is a lightweight anatomy run for p=37 score=4 near-hits. It is not a Hadamard 668 construction run.")
    lines.append("")
    lines.append("## Target")
    lines.append("")
    lines.append("- p: `{}`".format(args.p))
    lines.append("- ks: `{}`".format(list(args.ks)))
    lines.append("- lambda: `{}`".format(args.lam))
    lines.append("")
    lines.append("## Aggregate")
    lines.append("")
    aggregate = {
        "exact_candidate_count": len(exact_rows),
        "search_score4_candidate_count": len(score4_rows),
        "score4_pattern_type_count": pattern_summary["pattern_type_count"],
        "distance_proxy_note": distance_summary["note"],
        "exact_perturbation_score4_count": sum(1 for row in perturb_rows if row.get("is_score4")),
        "return_score0_seen": any(row.get("score0_seen") for row in return_rows),
        "return_improvement_seen": any(row.get("score_improvement_seen") for row in return_rows),
        "defect_targeted_return_improvement_seen": any(row.get("score_improvement_seen") for row in defect_return_rows),
    }
    lines.append("```json")
    lines.append(json.dumps(json_safe(aggregate), indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    exact_found = bool(exact_rows)
    exact_path = exact_rows[0]["path"] if exact_rows else None
    dist_values = [row["global_translation_plus_equal_size_permutation_best_distance"] for row in distance_summary["rows"]]
    direct_values = [row["direct_return_radius"] for row in comparison_json["search_rows"]]
    score4_pert = [row for row in perturb_rows if row.get("is_score4")]
    lines.append("1. p=37 exact candidate は見つかったか。SDS/GS/HH^T 検証は通ったか: `{}`。script 上の exact path は `{}`。外部検証ログで確認する。".format(exact_found, exact_path))
    lines.append("2. search-derived score=4 candidate は何個診断したか: `{}`.".format(len(score4_rows)))
    lines.append("3. score=4 defect pattern は何種類あったか: `{}`.".format(pattern_summary["pattern_type_count"]))
    lines.append("4. search-derived score=4 は exact から軽量距離でどのくらい離れていたか: global+18-swap proxy の min/median/max = `{}/{}/{}`.".format(min(dist_values) if dist_values else None, statistics.median(dist_values) if dist_values else None, max(dist_values) if dist_values else None))
    lines.append("5. exact から r<=4 perturbation で score=4 は出たか: `{}` 件。".format(len(score4_pert)))
    lines.append("6. exact-derived score=4 と search-derived score=4 は h_min / D_min / P_tau / Q_ratio で似ていたか: `{}`.".format(comparison_json["diagnosis"]["similarity_judgement"]))
    lines.append("7. direct return radius はどのくらいだったか: min/median/max = `{}/{}/{}`.".format(min(direct_values) if direct_values else None, statistics.median(direct_values) if direct_values else None, max(direct_values) if direct_values else None))
    lines.append("8. truncated return r<=6 で score 改善または score=0 は出たか: improvement `{}`, score0 `{}`.".format(any(row.get("score_improvement_seen") for row in return_rows), any(row.get("score0_seen") for row in return_rows)))
    lines.append("9. p=37 score=4 は true-neighborhood 型か、false-basin 型か: `{}`.".format(comparison_json["diagnosis"]["basin_type"]))
    lines.append("10. この知見を 668 の score164/176 にどう使うべきか: `{}`.".format(comparison_json["diagnosis"]["implication_for_668"]))
    lines.append("")
    lines.append("## Safety")
    lines.append("")
    lines.append("- score=4 is a near-hit, not a solution.")
    lines.append("- Distances are lightweight proxies; equivalence is not exhaustively minimized.")
    lines.append("- Block-wise translation is an independent lower bound, not an exact equivalence distance.")
    with open(os.path.join(out_dir, "p37_score4_false_basin_anatomy_summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Lightweight anatomy of p=37 score=4 false basins against a known exact SDS.")
    parser.add_argument("--p", type=int, default=37)
    parser.add_argument("--ks", type=parse_ks, default=(13, 16, 18, 18))
    parser.add_argument("--lam", type=int, default=28)
    parser.add_argument("--exact-json", default="")
    parser.add_argument("--score4-paths", default="")
    parser.add_argument("--max-score4", type=int, default=20)
    parser.add_argument("--samples-per-r", type=int, default=500)
    parser.add_argument("--max-r", type=int, default=4)
    parser.add_argument("--return-samples", type=int, default=1000)
    parser.add_argument("--defect-return-samples", type=int, default=500)
    parser.add_argument("--defect-top-k", type=int, default=100)
    parser.add_argument("--seed", type=int, default=55037)
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
        out_dir = args.out_dir or os.path.join("outputs", "explorations", "{}_p37_score4_false_basin_anatomy".format(now_stamp()))
        ensure_dir(out_dir)
        baseline = random_baseline_tuple(p, ks)
        run_config = {
            "script": SCRIPT_NAME,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "p": int(p),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "max_score4": int(args.max_score4),
            "samples_per_r": int(args.samples_per_r),
            "max_r": int(args.max_r),
            "return_samples": int(args.return_samples),
            "defect_return_samples": int(args.defect_return_samples),
            "defect_top_k": int(args.defect_top_k),
            "out_dir": out_dir,
        }
        write_json(os.path.join(out_dir, "run_config.json"), json_safe(run_config))
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# Run Log\n\n")
            f.write("- script: `{}`\n".format(SCRIPT_NAME))
            f.write("- p: `{}`\n".format(p))
            f.write("- ks: `{}`\n".format(ks))
            f.write("- lambda: `{}`\n".format(lam))
            f.write("- distance note: lightweight proxy, not exhaustive equivalence distance\n")

        exact_rows = find_exact_candidates(args, baseline)
        exact = exact_rows[0]
        exact_blocks = [set(block) for block in exact["_blocks"]]
        write_jsonl(os.path.join(out_dir, "exact_candidates.jsonl"), exact_rows)
        score4_rows = discover_score4_candidates(args, baseline)
        write_jsonl(os.path.join(out_dir, "input_score4_candidates.jsonl"), score4_rows)
        print("exact candidates:", len(exact_rows))
        print("score4 candidates:", len(score4_rows))
        sys.stdout.flush()

        pattern_rows = []
        pattern_counts = {}
        for row in score4_rows:
            pattern = row["_pattern"]
            pattern_counts[pattern["pattern_signature"]] = pattern_counts.get(pattern["pattern_signature"], 0) + 1
            pattern_rows.append(
                {
                    "path": row["path"],
                    "canonical_hash": row["canonical_hash"],
                    "score": int(row["score"]),
                    "pattern_type": pattern["pattern_type"],
                    "pattern_signature": pattern["pattern_signature"],
                    "coordinate_signature": pattern["coordinate_signature"],
                    "nonzero_defect_coordinates": pattern["nonzero_defect_coordinates"],
                    "positive_defect_pairs": pattern["positive_defect_pairs"],
                    "negative_defect_pairs": pattern["negative_defect_pairs"],
                    "rho_sum": pattern["rho_sum"],
                }
            )
        pattern_summary = {
            "pattern_type_count": int(len(pattern_counts)),
            "pattern_counts": pattern_counts,
            "rows": pattern_rows,
        }
        write_json(os.path.join(out_dir, "defect_pattern_summary.json"), json_safe(pattern_summary))
        write_csv(
            os.path.join(out_dir, "defect_pattern_table.csv"),
            pattern_rows,
            ["path", "canonical_hash", "score", "pattern_type", "pattern_signature", "coordinate_signature", "rho_sum"],
        )

        distance_rows = []
        return_rows = []
        defect_return_rows = []
        comparison_search_rows = []
        rng = random.Random(int(int(args.seed) + 5502))
        for row in score4_rows:
            dist = distance_summary_for_candidate(row["_blocks"], exact_blocks, ks, p)
            direct = direct_return_payload(row["_blocks"], dist["_aligned_exact_for_best"], row["_counts"], lam, p)
            distance_row = {
                "path": row["path"],
                "canonical_hash": row["canonical_hash"],
                "raw_distance": dist["raw_distance"],
                "raw_per_block": dist["raw_per_block"],
                "global_translation_best_distance": dist["global_translation_best_distance"],
                "global_translation_best_shift": dist["global_translation_best_shift"],
                "global_translation_plus_equal_size_permutation_best_distance": dist["global_translation_plus_equal_size_permutation_best_distance"],
                "global_translation_plus_equal_size_permutation_best_shift": dist["global_translation_plus_equal_size_permutation_best_shift"],
                "global_translation_plus_equal_size_permutation_best_perm": dist["global_translation_plus_equal_size_permutation_best_perm"],
                "global_translation_plus_equal_size_permutation_best_per_block": dist["global_translation_plus_equal_size_permutation_best_per_block"],
                "blockwise_translation_independent_lower_bound": dist["blockwise_translation_independent_lower_bound"],
                "direct_return_radius": direct["direct_return_radius"],
                "direct_return_score_after": direct["direct_return_score_after"],
                "direct_return_valid": direct["direct_return_valid"],
            }
            distance_rows.append(distance_row)

            best_truncated = None
            for r in range(1, 7):
                probe = sample_truncated_return(rng, row["_blocks"], row["_counts"], lam, p, direct["swaps"], r, int(args.return_samples), baseline)
                probe.update({"path": row["path"], "canonical_hash": row["canonical_hash"], "parent_score": int(row["score"]), "direct_return_radius": direct["direct_return_radius"]})
                return_rows.append(probe)
                if best_truncated is None or probe["best_score_after_truncated_return_r"] < best_truncated["best_score_after_truncated_return_r"]:
                    best_truncated = probe

            for r in range(1, 4):
                probe = sample_defect_targeted_return(rng, row["_blocks"], row["_counts"], lam, p, int(args.defect_top_k), r, int(args.defect_return_samples))
                probe.update({"path": row["path"], "canonical_hash": row["canonical_hash"], "parent_score": int(row["score"])})
                defect_return_rows.append(probe)

            comparison_search_rows.append(
                {
                    "source_type": "search",
                    "path": row["path"],
                    "canonical_hash": row["canonical_hash"],
                    "score": int(row["score"]),
                    "pattern_signature": row["pattern_signature"],
                    "h_min": row["h_min"],
                    "D_min_ratio": row["D_min_ratio"],
                    "improving_swap_count": row["improving_swap_count"],
                    "P_0": row["P_0"],
                    "P_4": row["P_4"],
                    "P_8": row["P_8"],
                    "P_16": row["P_16"],
                    "Q_ratio": row["Q_ratio"],
                    "InitHardness": row["InitHardness"],
                    "distance_to_exact": distance_row["global_translation_plus_equal_size_permutation_best_distance"],
                    "blockwise_lower_bound": distance_row["blockwise_translation_independent_lower_bound"],
                    "direct_return_radius": direct["direct_return_radius"],
                    "best_truncated_return_score": best_truncated["best_score_after_truncated_return_r"] if best_truncated else None,
                    "best_truncated_return_r": best_truncated["r"] if best_truncated else None,
                }
            )

        distance_summary = {
            "note": "Distances are lightweight proxies. Global translation and equal-size block swap are considered; block-wise translation is an independent lower bound, not exact equivalence distance.",
            "rows": distance_rows,
        }
        write_json(os.path.join(out_dir, "distance_to_exact_summary.json"), json_safe(distance_summary))
        write_csv(
            os.path.join(out_dir, "distance_to_exact_table.csv"),
            distance_rows,
            [
                "path",
                "canonical_hash",
                "raw_distance",
                "global_translation_best_distance",
                "global_translation_plus_equal_size_permutation_best_distance",
                "blockwise_translation_independent_lower_bound",
                "direct_return_radius",
                "direct_return_score_after",
                "direct_return_valid",
            ],
        )

        perturb_rows, perturb_summary = run_exact_perturbations(args, exact_blocks, ks, lam, p, baseline)
        write_jsonl(os.path.join(out_dir, "exact_perturbation_score4.jsonl"), perturb_rows)
        write_csv(
            os.path.join(out_dir, "exact_perturbation_summary.csv"),
            perturb_summary,
            ["r", "samples", "best_score", "median_score", "score_le_8_count", "score4_count", "best20_scores"],
        )
        write_jsonl(os.path.join(out_dir, "return_path_probe.jsonl"), return_rows)
        write_csv(
            os.path.join(out_dir, "return_path_summary.csv"),
            return_rows,
            ["path", "canonical_hash", "r", "parent_score", "direct_return_radius", "best_score_after_truncated_return_r", "best_h_after", "best_D_min_ratio_after", "score0_seen", "score_improvement_seen", "sample_count"],
        )
        write_jsonl(os.path.join(out_dir, "defect_targeted_return_probe.jsonl"), defect_return_rows)

        exact_score4_rows = [row for row in perturb_rows if row.get("is_score4")]
        comparison_exact_rows = []
        for row in exact_score4_rows:
            comparison_exact_rows.append(
                {
                    "source_type": "exact_perturbation",
                    "path": "",
                    "canonical_hash": row["canonical_hash"],
                    "score": int(row["score"]),
                    "pattern_signature": row["pattern_signature"],
                    "h_min": row.get("h_min"),
                    "D_min_ratio": row.get("D_min_ratio"),
                    "improving_swap_count": row.get("improving_swap_count"),
                    "P_0": row.get("P_0"),
                    "P_4": row.get("P_4"),
                    "P_8": row.get("P_8"),
                    "P_16": row.get("P_16"),
                    "Q_ratio": row.get("Q_ratio"),
                    "InitHardness": row.get("InitHardness"),
                    "distance_to_exact": row.get("distance_from_exact"),
                    "blockwise_lower_bound": row.get("distance_from_exact"),
                    "direct_return_radius": row.get("distance_from_exact"),
                    "best_truncated_return_score": None,
                    "best_truncated_return_r": None,
                }
            )
        search_distance_values = [row["distance_to_exact"] for row in comparison_search_rows]
        exact_h_values = [row["h_min"] for row in comparison_exact_rows if row.get("h_min") is not None]
        search_h_values = [row["h_min"] for row in comparison_search_rows if row.get("h_min") is not None]
        if not exact_score4_rows:
            similarity_judgement = "no exact-derived score4 was sampled for r<=max_r, so metric similarity could not be established"
        elif search_h_values and exact_h_values and abs(statistics.median(search_h_values) - statistics.median(exact_h_values)) <= 4:
            similarity_judgement = "partially similar in h_min, but distance proxy must still be checked"
        else:
            similarity_judgement = "not clearly similar under this lightweight sample"
        if search_distance_values and min(search_distance_values) <= int(args.max_r):
            basin_type = "possible true-neighborhood type under proxy"
        elif exact_score4_rows and search_distance_values and min(search_distance_values) <= 2 * int(args.max_r):
            basin_type = "borderline; near exact perturbation radius but not confirmed"
        else:
            basin_type = "false-basin type under lightweight exact-distance proxy"
        implication = "Use exact-neighborhood distance/proxy return diagnostics before spending heavy LNS on 668 score164/176; low score alone is not evidence of exact-basin proximity."
        comparison_json = {
            "search_rows": comparison_search_rows,
            "exact_perturbation_score4_rows": comparison_exact_rows,
            "diagnosis": {
                "similarity_judgement": similarity_judgement,
                "basin_type": basin_type,
                "implication_for_668": implication,
            },
        }
        comparison_rows = comparison_search_rows + comparison_exact_rows
        write_csv(
            os.path.join(out_dir, "score4_type_comparison.csv"),
            comparison_rows,
            [
                "source_type",
                "path",
                "canonical_hash",
                "score",
                "pattern_signature",
                "h_min",
                "D_min_ratio",
                "improving_swap_count",
                "P_0",
                "P_4",
                "P_8",
                "P_16",
                "Q_ratio",
                "InitHardness",
                "distance_to_exact",
                "blockwise_lower_bound",
                "direct_return_radius",
                "best_truncated_return_score",
                "best_truncated_return_r",
            ],
        )
        write_json(os.path.join(out_dir, "score4_type_comparison.json"), json_safe(comparison_json))
        make_summary_md(out_dir, args, exact_rows, score4_rows, pattern_summary, distance_summary, perturb_rows, return_rows, defect_return_rows, comparison_json)
        print("SUMMARY:", os.path.join(out_dir, "p37_score4_false_basin_anatomy_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
