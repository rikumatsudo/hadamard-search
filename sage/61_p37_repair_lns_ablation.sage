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
    verify_hadamard_exact,
    verify_sds,
    write_json,
)


SCRIPT_NAME = "61_p37_repair_lns_ablation"
POWERS = (2, 4, 6, 8, 10, 12)
LOW_SCORES = (4, 8, 12, 16)
MODES = (
    "baseline_no_repair",
    "threshold_accepting_repair",
    "negative_cross_pair_search",
    "sparse_vector_cancellation_beam",
    "exact_joint_rswap_lns",
    "pair_level_partial_defect_repair",
    "moment_late_repair",
    "hybrid_repair",
)


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


def parse_ints(text, default):
    if text is None or str(text).strip() == "":
        return tuple(int(x) for x in default)
    return tuple(int(part.strip()) for part in str(text).split(",") if part.strip())


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


def block_diff_counts_no_zero_pairs(p, block):
    counts = [0] * int(p)
    values = list(block)
    for x in values:
        for y in values:
            if int(x) != int(y):
                counts[(int(x) - int(y)) % int(p)] += 1
    return counts


def subset_total_counts(p, blocks, indices):
    total = [0] * int(p)
    for idx in indices:
        counts = block_diff_counts_no_zero_pairs(p, blocks[int(idx)])
        total = [int(a) + int(b) for a, b in zip(total, counts)]
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
    penalty = int(sum(balanced_abs(moments[key], p) ** 2 for key in ("T2", "T4", "T6", "T8", "T10", "T12")))
    return {
        "moment_zero_count_3": int(sum(1 for key in ("T2", "T4", "T6") if moments[key] == 0)),
        "moment_zero_count_6": int(summary["moment_zero_count"]),
        "higher_moment_norm": int(sum(balanced_abs(moments[key], p) ** 2 for key in ("T8", "T10", "T12"))),
        "moment_penalty": int(penalty),
        "padic_moments": moments,
    }


def score_counts(counts, lam):
    return int(metrics_from_counts(counts, lam)[0])


def rho_vector(counts, lam):
    rho = [0] * len(counts)
    for d in range(1, len(counts)):
        rho[d] = int(counts[d] - lam)
    return rho


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
        raise ValueError("remove_set and add_set size mismatch")
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
        "defect_target_score": int(move.get("defect_target_score", 0) or 0),
    }


def moves_compatible(moves, blocks):
    by_block = {}
    for move in moves:
        b = int(move["block"])
        r = int(move["remove"])
        a = int(move["add"])
        if r not in blocks[b] or a in blocks[b]:
            return False
        bucket = by_block.setdefault(b, {"remove": set(), "add": set()})
        if r in bucket["remove"] or a in bucket["add"]:
            return False
        bucket["remove"].add(r)
        bucket["add"].add(a)
    return True


def apply_moves_to_blocks(blocks, moves):
    out = clone_blocks(blocks)
    if not moves_compatible(moves, out):
        return None
    for move in moves:
        b = int(move["block"])
        out[b].remove(int(move["remove"]))
        out[b].add(int(move["add"]))
    return out


def evaluate_move_set(p, blocks, counts, lam, moves):
    p = int(p)
    parent_score = score_counts(counts, lam)
    if not moves_compatible(moves, blocks):
        return None
    linear_delta = [0] * p
    for move in moves:
        delta = move.get("_delta")
        if delta is None:
            delta = delta_swap_list(p, blocks[int(move["block"])], int(move["remove"]), int(move["add"]))
        if delta is None:
            return None
        add_delta_into(linear_delta, delta)
    linearized_score = score_counts(apply_delta(counts, linear_delta), lam)

    true_delta = [0] * p
    grouped = {}
    for move in moves:
        b = int(move["block"])
        grouped.setdefault(b, {"remove": set(), "add": set()})
        grouped[b]["remove"].add(int(move["remove"]))
        grouped[b]["add"].add(int(move["add"]))
    same_block_multi_swap = any(len(payload["remove"]) > 1 for payload in grouped.values())
    for b, payload in grouped.items():
        add_delta_into(true_delta, exact_joint_delta_counts(blocks[b], payload["remove"], payload["add"], p))
    true_blocks = apply_moves_to_blocks(blocks, moves)
    if true_blocks is None:
        return None
    true_counts = total_diff_counts(p, true_blocks)
    true_score = score_counts(true_counts, lam)
    interaction = [int(true_delta[d]) - int(linear_delta[d]) for d in range(p)]
    return {
        "parent_score": int(parent_score),
        "linearized_score": int(linearized_score),
        "true_score": int(true_score),
        "score_gap": int(true_score - linearized_score),
        "interaction_norm": int(norm_delta(interaction)),
        "interaction_nonzero": int(sum(1 for d in range(1, p) if int(interaction[d]) != 0)),
        "same_block_multi_swap": bool(same_block_multi_swap),
        "h_linear": int(linearized_score - parent_score),
        "h_true": int(true_score - parent_score),
        "_move_count": int(len(moves)),
        "_moves_compact": [compact_move(move) for move in moves],
        "_true_blocks": true_blocks,
        "_true_counts": true_counts,
        "_interaction": interaction,
    }


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
        "InitHardness": float(structure["InitHardness"]),
    }
    out.update(moment_payload(counts, lam, p))
    return out


def quantile(values, q):
    if not values:
        return None
    values = sorted(values)
    idx = int(math.floor(float(q) * (len(values) - 1)))
    return values[idx]


def one_swap_library(blocks, counts, lam, p, allowed_blocks=None):
    p = int(p)
    score = score_counts(counts, lam)
    rho = rho_vector(counts, lam)
    allowed = set(range(4)) if allowed_blocks is None else set(int(x) for x in allowed_blocks)
    moves = []
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
                kappa = None if q == 0 else float(-2 * g) / float(q)
                pos, neg, target = defect_mass_scores(rho, delta)
                moves.append(
                    {
                        "block": int(block_idx),
                        "remove": int(removed),
                        "add": int(added),
                        "g": int(g),
                        "q": int(q),
                        "h": int(h),
                        "score_after": int(score + h),
                        "kappa": kappa,
                        "positive_destroy": int(pos),
                        "negative_repair": int(neg),
                        "defect_target_score": int(target),
                        "_delta": delta,
                    }
                )
    moves.sort(key=lambda item: (int(item["h"]), -float(item["kappa"] if item["kappa"] is not None else -999.0), -int(item["defect_target_score"]), int(item["q"])))
    return moves


def move_library(blocks, counts, lam, p, rng, per_category, random_count, allowed_blocks=None):
    all_moves = one_swap_library(blocks, counts, lam, p, allowed_blocks=allowed_blocks)
    selected = {}

    def add_many(rows):
        for move in rows:
            selected[move_key(move)] = move

    for threshold in (4, 8, 16, 32):
        add_many([m for m in all_moves if int(m["h"]) <= threshold][: int(per_category)])
    add_many(sorted(all_moves, key=lambda m: (-float(m["kappa"] if m["kappa"] is not None else -999), m["h"]))[: int(per_category)])
    add_many(sorted(all_moves, key=lambda m: (m["q"], m["h"]))[: int(per_category)])
    add_many(sorted(all_moves, key=lambda m: (m["g"], m["h"]))[: int(per_category)])
    add_many(sorted(all_moves, key=lambda m: (-m["defect_target_score"], m["h"]))[: int(per_category)])
    shuffled = list(all_moves)
    rng.shuffle(shuffled)
    add_many(shuffled[: int(random_count)])
    out = list(selected.values())
    out.sort(key=lambda item: (item["h"], -item["defect_target_score"], item["q"]))
    return out


def random_move(rng, blocks, counts, lam, p):
    for _ in range(100):
        b = rng.randrange(4)
        block = blocks[b]
        r = rng.choice(tuple(block))
        a = rng.randrange(int(p))
        if a not in block:
            move = one_move_from_indices(blocks, counts, lam, p, b, r, a)
            if move is not None:
                return move
    return None


def targeted_move(rng, blocks, counts, lam, p):
    rho = rho_vector(counts, lam)
    defects = sorted([(abs(rho[d]), d) for d in range(1, int(p))], reverse=True)
    for _ in range(100):
        _weight, d = rng.choice(defects[: min(12, len(defects))])
        b = rng.randrange(4)
        block = blocks[b]
        r = rng.choice(tuple(block))
        a = (int(r) + int(d)) % int(p)
        if a not in block:
            move = one_move_from_indices(blocks, counts, lam, p, b, r, a)
            if move is not None:
                return move
    return random_move(rng, blocks, counts, lam, p)


def one_move_from_indices(blocks, counts, lam, p, b, r, a):
    delta = delta_swap_list(p, blocks[int(b)], int(r), int(a))
    if delta is None:
        return None
    rho = rho_vector(counts, lam)
    score = score_counts(counts, lam)
    g = dot_delta(rho, delta)
    q = norm_delta(delta)
    h = int(2 * g + q)
    kappa = None if q == 0 else float(-2 * g) / float(q)
    pos, neg, target = defect_mass_scores(rho, delta)
    return {"block": int(b), "remove": int(r), "add": int(a), "g": int(g), "q": int(q), "h": int(h), "score_after": int(score + h), "kappa": kappa, "positive_destroy": int(pos), "negative_repair": int(neg), "defect_target_score": int(target), "_delta": delta}


def is_false_like(diag):
    return bool(
        diag.get("score") is not None
        and int(diag["score"]) > 0
        and diag.get("h_min") is not None
        and int(diag["h_min"]) >= 0
        and diag.get("D_min_ratio") is not None
        and float(diag["D_min_ratio"]) >= 1.0
        and float(diag.get("P_<0") or 0.0) == 0.0
    )


def escaped_false_basin(parent_diag, after_diag):
    if not is_false_like(parent_diag):
        return False
    p8_parent = float(parent_diag.get("P_8") or 0.0)
    p8_after = float(after_diag.get("P_8") or 0.0)
    return bool(
        (after_diag.get("D_min_ratio") is not None and float(after_diag["D_min_ratio"]) < 1.0)
        or (after_diag.get("h_min") is not None and int(after_diag["h_min"]) < 0)
        or (after_diag.get("kappa_max") is not None and float(after_diag["kappa_max"]) > 1.0)
        or (p8_after > p8_parent + 0.02 and p8_after > 1.25 * max(1e-9, p8_parent))
    )


def candidate_row_from_blocks(origin, label, source_path, blocks, p, ks, lam, baseline, extra=None):
    counts = total_diff_counts(p, blocks)
    diag = full_diagnostic(blocks, counts, lam, p, baseline)
    row = {
        "parent_origin": origin,
        "parent_label": label,
        "source_path": source_path,
        "parent_hash": canonical_hash(blocks, ks, p),
        "blocks": json_blocks(blocks),
    }
    row.update({k: diag.get(k) for k in ("score", "l1", "max_abs", "nonzero", "h_min", "D_min_ratio", "P_<0", "P_0", "P_4", "P_8", "P_16", "kappa_max", "Q_ratio", "InitHardness", "moment_zero_count_6")})
    if extra:
        row.update(extra)
    row["_blocks"] = clone_blocks(blocks)
    row["_counts"] = counts
    row["_diag"] = diag
    return row


def load_jsonl_rows(path):
    if not os.path.exists(path):
        return []
    rows = []
    with open(path) as f:
        for line in f:
            try:
                rows.append(json.loads(line))
            except Exception:
                continue
    return rows


def discover_input_candidates(args, baseline):
    p = int(args.p)
    ks = tuple(int(k) for k in args.ks)
    lam = int(args.lam)
    source_dir = os.path.join("outputs", "explorations", "20260506_1950_p37_exact_vs_search_low_score_comparison")
    search_rows = load_jsonl_rows(os.path.join(source_dir, "search_low_score_candidates.jsonl"))
    exact_rows = load_jsonl_rows(os.path.join(source_dir, "exact_perturbation_low_score_candidates.jsonl"))
    selected = []
    seen = set()

    def add_payload(payload, origin, label):
        if len(selected) >= int(args.max_parent_candidates):
            return False
        try:
            blocks = normalize_blocks(p, payload["blocks"])
        except Exception:
            return False
        if tuple(len(block) for block in blocks) != ks:
            return False
        counts = total_diff_counts(p, blocks)
        score = score_counts(counts, lam)
        if score not in LOW_SCORES:
            return False
        key = canonical_hash(blocks, ks, p)
        if key in seen:
            return False
        seen.add(key)
        row = candidate_row_from_blocks(
            origin,
            label,
            payload.get("source_path", payload.get("source_json", "")),
            blocks,
            p,
            ks,
            lam,
            baseline,
            {"source_payload_hash": payload.get("canonical_hash"), "return_radius_proxy": payload.get("return_radius_proxy")},
        )
        selected.append(row)
        return True

    by_score = {score: [] for score in LOW_SCORES}
    for payload in search_rows:
        score = int(payload.get("score", -1))
        if score in by_score:
            by_score[score].append(payload)
    for payload in by_score[4][:10]:
        add_payload(payload, "search_derived", "search_score4_false_like")
    remaining_search_slots = max(0, int(args.max_parent_candidates) - min(20, len(exact_rows)) - len(selected))
    per_score = max(1, int(math.ceil(float(remaining_search_slots) / 3.0)))
    for score in (8, 12, 16):
        for payload in by_score[score][:per_score]:
            add_payload(payload, "search_derived", "search_low_score")

    exact_added = 0
    for payload in exact_rows:
        if exact_added >= 20 or len(selected) >= int(args.max_parent_candidates):
            break
        before = len(selected)
        add_payload(payload, "exact_derived", "exact_derived_positive_control")
        if len(selected) > before:
            exact_added += 1

    if len(selected) < int(args.max_parent_candidates):
        paths = sorted(glob.glob(os.path.join("outputs", "candidates", "small_p", "candidate_v{}_score*.json".format(p))))
        for path in paths:
            if len(selected) >= int(args.max_parent_candidates):
                break
            try:
                data, v, _n, got_ks, got_lam, blocks = load_candidate(path)
            except Exception:
                continue
            if int(v) != p or tuple(got_ks) != ks or int(got_lam) != lam:
                continue
            counts = total_diff_counts(p, blocks)
            score = score_counts(counts, lam)
            if score not in LOW_SCORES:
                continue
            key = canonical_hash(blocks, ks, p)
            if key in seen:
                continue
            seen.add(key)
            label = "candidate_json_score{}".format(score)
            selected.append(candidate_row_from_blocks("search_derived", label, path, blocks, p, ks, lam, baseline, {}))

    selected.sort(key=lambda row: (0 if row["parent_origin"] == "search_derived" and int(row["score"]) == 4 else 1, row["parent_origin"], int(row["score"]), row["parent_hash"]))
    return selected[: int(args.max_parent_candidates)]


def save_score0_candidate(out_dir, parent, attempt, blocks, p, ks, lam):
    counts = total_diff_counts(p, blocks)
    score = score_counts(counts, lam)
    if score != 0:
        return None
    ok, _bad = verify_sds(p, blocks, lam)
    entries_ok, hh_t_ok = verify_hadamard_exact(p, blocks)
    payload = {
        "v": int(p),
        "n": int(4 * int(p)),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": json_blocks(blocks),
        "score": 0,
        "l1_error": 0,
        "max_abs_error": 0,
        "nonzero_defect_count": 0,
        "verify_sds": bool(ok),
        "generated_hadamard": bool(hh_t_ok),
        "hh_t": bool(hh_t_ok),
        "entries_pm1_ok": bool(entries_ok),
        "construction": "Goethals-Seidel",
        "search_method": SCRIPT_NAME,
        "mode": attempt["mode"],
        "parent_hash": parent["parent_hash"],
        "canonical_hash": canonical_hash(blocks, ks, p),
        "canonical_repr_summary": canonical_repr_summary(blocks, ks, p),
        "error_histogram": error_histogram(counts, lam),
    }
    path = os.path.join(out_dir, "score0_candidate_{}_{}.json".format(attempt["mode"], canonical_hash(blocks, ks, p)[:12]))
    write_json_safe(path, payload)
    return path


def make_attempt(parent, mode, after_blocks, p, ks, lam, baseline, details=None, audit=None):
    after_counts = total_diff_counts(p, after_blocks)
    after_diag = full_diagnostic(after_blocks, after_counts, lam, p, baseline)
    parent_diag = parent["_diag"]
    row = {
        "parent_hash": parent["parent_hash"],
        "parent_origin": parent["parent_origin"],
        "parent_score": int(parent_diag["score"]),
        "parent_label": parent["parent_label"],
        "parent_D_min_ratio": parent_diag.get("D_min_ratio"),
        "parent_P_4": parent_diag.get("P_4"),
        "parent_P_8": parent_diag.get("P_8"),
        "parent_P_16": parent_diag.get("P_16"),
        "parent_kappa_max": parent_diag.get("kappa_max"),
        "parent_Q_ratio": parent_diag.get("Q_ratio"),
        "parent_InitHardness": parent_diag.get("InitHardness"),
        "parent_moment_zero_count_6": parent_diag.get("moment_zero_count_6"),
        "mode": mode,
        "score_after": int(after_diag["score"]),
        "score_delta": int(after_diag["score"] - parent_diag["score"]),
        "D_min_ratio_after": after_diag.get("D_min_ratio"),
        "P_4_after": after_diag.get("P_4"),
        "P_8_after": after_diag.get("P_8"),
        "P_16_after": after_diag.get("P_16"),
        "kappa_max_after": after_diag.get("kappa_max"),
        "Q_ratio_after": after_diag.get("Q_ratio"),
        "InitHardness_after": after_diag.get("InitHardness"),
        "moment_zero_count_6_after": after_diag.get("moment_zero_count_6"),
        "score_improvement_seen": bool(after_diag["score"] < parent_diag["score"]),
        "score0_seen": bool(after_diag["score"] == 0),
        "escaped_false_basin": escaped_false_basin(parent_diag, after_diag),
        "after_hash": canonical_hash(after_blocks, ks, p),
        "linearized_score": None,
        "true_score": int(after_diag["score"]),
        "score_gap": None,
        "interaction_norm": None,
        "interaction_nonzero": None,
        "same_block_multi_swap": False,
    }
    if audit:
        row.update({key: audit.get(key) for key in ("linearized_score", "true_score", "score_gap", "interaction_norm", "interaction_nonzero", "same_block_multi_swap")})
    if details:
        row.update(details)
    row["_blocks"] = clone_blocks(after_blocks)
    return row


def baseline_no_repair(parent, p, ks, lam, baseline):
    return make_attempt(parent, "baseline_no_repair", parent["_blocks"], p, ks, lam, baseline, {"note": "diagnostic only"})


def threshold_walk(parent, p, ks, lam, baseline, rng, allow_delta, walk_length, sample_moves):
    blocks = clone_blocks(parent["_blocks"])
    counts = list(parent["_counts"])
    best_blocks = clone_blocks(blocks)
    best_score = score_counts(counts, lam)
    parent_score = int(best_score)
    visited = set([canonical_hash(blocks, ks, p)])
    accepted = 0
    for _step in range(int(walk_length)):
        candidates = []
        for _ in range(int(sample_moves)):
            move = targeted_move(rng, blocks, counts, lam, p) if rng.random() < 0.65 else random_move(rng, blocks, counts, lam, p)
            if move is None:
                continue
            ev = evaluate_move_set(p, blocks, counts, lam, [move])
            if ev is None:
                continue
            if int(ev["h_true"]) <= int(allow_delta):
                candidates.append((ev["true_score"], int(move["h"]), -int(move["defect_target_score"]), move, ev))
        if not candidates:
            continue
        candidates.sort(key=lambda item: item[:3])
        _score, _h, _target, _move, ev = candidates[0]
        new_hash = canonical_hash(ev["_true_blocks"], ks, p)
        if new_hash in visited:
            continue
        visited.add(new_hash)
        blocks = clone_blocks(ev["_true_blocks"])
        counts = list(ev["_true_counts"])
        accepted += 1
        score = score_counts(counts, lam)
        if score < best_score:
            best_score = score
            best_blocks = clone_blocks(blocks)
        if score == 0:
            break
    final_score = score_counts(counts, lam)
    returned_blocks = best_blocks if int(best_score) < parent_score else blocks
    returned_kind = "best_score_state" if int(best_score) < parent_score else "final_threshold_state"
    return returned_blocks, {
        "accepted_moves": int(accepted),
        "visited_states": int(len(visited)),
        "best_score": int(best_score),
        "final_score": int(final_score),
        "returned_state": returned_kind,
    }


def threshold_accepting_repair(parent, p, ks, lam, baseline, rng, args):
    best = None
    best_details = None
    for allow in (4, 8, 16):
        for walk_length in (200, 500):
            for restart in range(int(args.restarts_per_candidate)):
                blocks, details = threshold_walk(parent, p, ks, lam, baseline, rng, allow, walk_length, int(args.threshold_sample_moves))
                score = score_counts(total_diff_counts(p, blocks), lam)
                if best is None or score < score_counts(total_diff_counts(p, best), lam):
                    best = blocks
                    best_details = {"allow_deltaS": int(allow), "walk_length": int(walk_length), "restart": int(restart + 1)}
                    best_details.update(details)
    return make_attempt(parent, "threshold_accepting_repair", best, p, ks, lam, baseline, best_details)


def negative_cross_pair_search(parent, p, ks, lam, baseline, rng, args):
    blocks = clone_blocks(parent["_blocks"])
    counts = list(parent["_counts"])
    parent_score = score_counts(counts, lam)
    lib = move_library(blocks, counts, lam, p, rng, int(args.library_k), int(args.random_library_moves))[: int(args.pair_library_limit)]
    best = None
    best_audit = None
    negative_cross = 0
    linearized_improve = 0
    true_improve = 0
    mismatch = 0
    for i in range(len(lib)):
        for j in range(i + 1, len(lib)):
            moves = [lib[i], lib[j]]
            if not moves_compatible(moves, blocks):
                continue
            cross = 2 * dot_delta(lib[i]["_delta"], lib[j]["_delta"])
            if cross < 0:
                negative_cross += 1
            ev = evaluate_move_set(p, blocks, counts, lam, moves)
            if ev is None:
                continue
            if ev["linearized_score"] < parent_score:
                linearized_improve += 1
            if ev["true_score"] < parent_score:
                true_improve += 1
            if ev["true_score"] != ev["linearized_score"]:
                mismatch += 1
            if best is None or (ev["true_score"], ev["linearized_score"], ev["score_gap"]) < (best["true_score"], best["linearized_score"], best["score_gap"]):
                best = ev
                best_audit = ev
    if best is None:
        best_blocks = blocks
    else:
        best_blocks = best["_true_blocks"]
    details = {
        "best_linearized_pair_score": None if best is None else int(best["linearized_score"]),
        "best_true_pair_score": None if best is None else int(best["true_score"]),
        "linearized_improvement_seen": bool(linearized_improve > 0),
        "true_improvement_seen": bool(true_improve > 0),
        "linearized_true_mismatch": int(mismatch),
        "negative_cross_pair_count": int(negative_cross),
    }
    return make_attempt(parent, "negative_cross_pair_search", best_blocks, p, ks, lam, baseline, details, best_audit)


def sparse_vector_cancellation_beam(parent, p, ks, lam, baseline, rng, args):
    blocks = clone_blocks(parent["_blocks"])
    counts = list(parent["_counts"])
    parent_score = score_counts(counts, lam)
    lib = move_library(blocks, counts, lam, p, rng, int(args.library_k), int(args.random_library_moves))[: int(args.beam_library_limit)]
    beam = [{"moves": [], "delta": [0] * int(p), "linearized_score": parent_score}]
    best = None
    for depth in range(1, int(args.max_depth) + 1):
        expanded = {}
        for state in beam:
            for move in lib:
                moves = state["moves"] + [move]
                if not moves_compatible(moves, blocks):
                    continue
                key = tuple(sorted(move_key(m) for m in moves))
                if key in expanded:
                    continue
                delta = list(state["delta"])
                add_delta_into(delta, move["_delta"])
                lin_score = score_counts(apply_delta(counts, delta), lam)
                expanded[key] = {"moves": moves, "delta": delta, "linearized_score": int(lin_score)}
        states = sorted(expanded.values(), key=lambda row: (row["linearized_score"], len(row["moves"])))[: int(args.beam_width)]
        beam = states
        for state in states[: int(args.beam_true_eval_limit)]:
            ev = evaluate_move_set(p, blocks, counts, lam, state["moves"])
            if ev is None:
                continue
            if best is None or (ev["true_score"], ev["linearized_score"]) < (best["true_score"], best["linearized_score"]):
                best = ev
    if best is None:
        best_blocks = blocks
        details = {"best_linearized_score": None, "best_true_score": parent_score, "selected_move_count": 0}
    else:
        best_blocks = best["_true_blocks"]
        details = {
            "best_linearized_score": int(best["linearized_score"]),
            "best_true_score": int(best["true_score"]),
            "interaction_gap": int(best["score_gap"]),
            "selected_move_count": int(best.get("_move_count", 0)),
            "selected_moves": best.get("_moves_compact", []),
        }
    return make_attempt(parent, "sparse_vector_cancellation_beam", best_blocks, p, ks, lam, baseline, details, best)


def sample_same_block_moves(rng, lib, block_idx, r):
    moves = [move for move in lib if int(move["block"]) == int(block_idx)]
    rng.shuffle(moves)
    selected = []
    used_remove = set()
    used_add = set()
    for move in sorted(moves[:160], key=lambda m: (-m["defect_target_score"], m["h"])):
        if int(move["remove"]) in used_remove or int(move["add"]) in used_add:
            continue
        selected.append(move)
        used_remove.add(int(move["remove"]))
        used_add.add(int(move["add"]))
        if len(selected) == int(r):
            return selected
    return None


def exact_joint_rswap_lns(parent, p, ks, lam, baseline, rng, args):
    blocks = clone_blocks(parent["_blocks"])
    counts = list(parent["_counts"])
    parent_structure = block_structure_payload(p, blocks, baseline)
    lib = move_library(blocks, counts, lam, p, rng, int(args.library_k), int(args.random_library_moves))
    best = None
    for r in range(2, 7):
        for _ in range(int(args.samples_per_r)):
            block_order = sorted(range(4), key=lambda b: -parent_structure["blocks"][b]["Q_formula"])
            block_idx = rng.choice(block_order[:2]) if rng.random() < 0.7 else rng.randrange(4)
            moves = sample_same_block_moves(rng, lib, block_idx, r)
            if not moves:
                continue
            ev = evaluate_move_set(p, blocks, counts, lam, moves)
            if ev is None:
                continue
            if best is None or (ev["true_score"], ev["linearized_score"]) < (best["true_score"], best["linearized_score"]):
                best = ev
    if best is None:
        return make_attempt(parent, "exact_joint_rswap_lns", blocks, p, ks, lam, baseline, {"best_R_set": {}, "best_B_set": {}})
    new_structure = block_structure_payload(p, best["_true_blocks"], baseline)
    grouped_r = {}
    grouped_b = {}
    for move in best.get("_moves_compact", []):
        key = str(int(move["block"]))
        grouped_r.setdefault(key, []).append(int(move["remove"]))
        grouped_b.setdefault(key, []).append(int(move["add"]))
    details = {
        "best_score_after": int(best["true_score"]),
        "best_R_set": grouped_r,
        "best_B_set": grouped_b,
        "selected_move_count": int(best.get("_move_count", 0)),
        "selected_moves": best.get("_moves_compact", []),
        "delta_E": float(new_structure["E_total"] - parent_structure["E_total"]),
        "delta_AP": float(new_structure["AP_total"] - parent_structure["AP_total"]),
        "delta_Q": float(new_structure["Q_formula_total"] - parent_structure["Q_formula_total"]),
    }
    return make_attempt(parent, "exact_joint_rswap_lns", best["_true_blocks"], p, ks, lam, baseline, details, best)


def partial_score(p, lam, blocks, repair_side, fixed_side):
    repair_counts = subset_total_counts(p, blocks, repair_side)
    fixed_counts = subset_total_counts(p, blocks, fixed_side)
    total = 0
    for d in range(1, int(p)):
        defect = int(repair_counts[d]) - (int(lam) - int(fixed_counts[d]))
        total += defect * defect
    return int(total)


def pair_level_partial_defect_repair(parent, p, ks, lam, baseline, rng, args):
    blocks = clone_blocks(parent["_blocks"])
    counts = list(parent["_counts"])
    splits = [((0, 1), (2, 3)), ((0, 2), (1, 3)), ((0, 3), (1, 2))]
    best = None
    best_details = None
    for left, right in splits:
        for side_name, repair_side, fixed_side in (("A", left, right), ("B", right, left)):
            before = partial_score(p, lam, blocks, repair_side, fixed_side)
            lib = move_library(blocks, counts, lam, p, rng, int(args.library_k), int(args.random_library_moves), allowed_blocks=repair_side)[: int(args.pair_repair_library_limit)]
            for i in range(len(lib)):
                candidates = [[lib[i]]]
                for j in range(i + 1, min(len(lib), i + 50)):
                    candidates.append([lib[i], lib[j]])
                for moves in candidates:
                    if not moves_compatible(moves, blocks):
                        continue
                    ev = evaluate_move_set(p, blocks, counts, lam, moves)
                    if ev is None:
                        continue
                    after = partial_score(p, lam, ev["_true_blocks"], repair_side, fixed_side)
                    key = (ev["true_score"], after, ev["linearized_score"])
                    if best is None or key < (best["true_score"], best_details["partial_score_after"], best["linearized_score"]):
                        best = ev
                        best_details = {
                            "split": "{}|{}".format(list(left), list(right)),
                            "repair_side": side_name,
                            "partial_score_before": int(before),
                            "partial_score_after": int(after),
                            "global_score_before": int(score_counts(counts, lam)),
                            "global_score_after": int(ev["true_score"]),
                            "selected_move_count": int(ev.get("_move_count", 0)),
                            "selected_moves": ev.get("_moves_compact", []),
                        }
    if best is None:
        return make_attempt(parent, "pair_level_partial_defect_repair", blocks, p, ks, lam, baseline, {})
    return make_attempt(parent, "pair_level_partial_defect_repair", best["_true_blocks"], p, ks, lam, baseline, best_details, best)


def moment_late_repair(parent, p, ks, lam, baseline, rng, args):
    blocks = clone_blocks(parent["_blocks"])
    counts = list(parent["_counts"])
    lib = move_library(blocks, counts, lam, p, rng, int(args.library_k), int(args.random_library_moves))[: int(args.moment_library_limit)]
    best = None
    best_details = None
    for eta in (0.01, 0.05, 0.1, 0.5):
        for move in lib:
            ev = evaluate_move_set(p, blocks, counts, lam, [move])
            if ev is None:
                continue
            moment = moment_payload(ev["_true_counts"], lam, p)
            objective = float(ev["true_score"]) + float(eta) * float(moment["moment_penalty"])
            if best is None or (objective, ev["true_score"]) < (best_details["objective"], best["true_score"]):
                best = ev
                best_details = {
                    "eta": float(eta),
                    "objective": float(objective),
                    "moment_penalty_after": int(moment["moment_penalty"]),
                    "moment_zero_count_after": int(moment["moment_zero_count_6"]),
                    "score_damage": int(ev["true_score"] - score_counts(counts, lam)),
                }
    if best is None:
        return make_attempt(parent, "moment_late_repair", blocks, p, ks, lam, baseline, {})
    return make_attempt(parent, "moment_late_repair", best["_true_blocks"], p, ks, lam, baseline, best_details, best)


def hybrid_repair(parent, p, ks, lam, baseline, rng, args):
    stage_rows = []
    blocks, details = threshold_walk(parent, p, ks, lam, baseline, rng, 8, 200, int(args.threshold_sample_moves))
    counts = total_diff_counts(p, blocks)
    stage_rows.append({"stage": "threshold", "score": int(score_counts(counts, lam)), "D_min_ratio": full_diagnostic(blocks, counts, lam, p, baseline).get("D_min_ratio")})
    temp_parent = dict(parent)
    temp_parent["_blocks"] = clone_blocks(blocks)
    temp_parent["_counts"] = counts
    temp_parent["_diag"] = full_diagnostic(blocks, counts, lam, p, baseline)
    beam = sparse_vector_cancellation_beam(temp_parent, p, ks, lam, baseline, rng, args)
    blocks = beam["_blocks"]
    counts = total_diff_counts(p, blocks)
    stage_rows.append({"stage": "beam", "score": int(score_counts(counts, lam)), "D_min_ratio": full_diagnostic(blocks, counts, lam, p, baseline).get("D_min_ratio")})
    temp_parent["_blocks"] = clone_blocks(blocks)
    temp_parent["_counts"] = counts
    temp_parent["_diag"] = full_diagnostic(blocks, counts, lam, p, baseline)
    rswap = exact_joint_rswap_lns(temp_parent, p, ks, lam, baseline, rng, args)
    blocks = rswap["_blocks"]
    counts = total_diff_counts(p, blocks)
    stage_rows.append({"stage": "rswap", "score": int(score_counts(counts, lam)), "D_min_ratio": full_diagnostic(blocks, counts, lam, p, baseline).get("D_min_ratio")})
    attempt = make_attempt(parent, "hybrid_repair", blocks, p, ks, lam, baseline, {"stage_scores": stage_rows, "stage_D_min_ratio": [row.get("D_min_ratio") for row in stage_rows]})
    return attempt


def run_all_modes(parent, p, ks, lam, baseline, rng, args):
    attempts = []
    attempts.append(baseline_no_repair(parent, p, ks, lam, baseline))
    attempts.append(threshold_accepting_repair(parent, p, ks, lam, baseline, rng, args))
    attempts.append(negative_cross_pair_search(parent, p, ks, lam, baseline, rng, args))
    attempts.append(sparse_vector_cancellation_beam(parent, p, ks, lam, baseline, rng, args))
    attempts.append(exact_joint_rswap_lns(parent, p, ks, lam, baseline, rng, args))
    attempts.append(pair_level_partial_defect_repair(parent, p, ks, lam, baseline, rng, args))
    attempts.append(moment_late_repair(parent, p, ks, lam, baseline, rng, args))
    attempts.append(hybrid_repair(parent, p, ks, lam, baseline, rng, args))
    return attempts


def median(values):
    values = sorted([float(v) for v in values if v is not None])
    if not values:
        return None
    n = len(values)
    if n % 2:
        return values[n // 2]
    return (values[n // 2 - 1] + values[n // 2]) / 2.0


def repair_by_mode_summary(attempts):
    groups = {}
    for row in attempts:
        groups.setdefault(row["mode"], []).append(row)
    out = []
    for mode, rows in sorted(groups.items()):
        out.append(
            {
                "mode": mode,
                "attempt_count": int(len(rows)),
                "score_improvement_count": int(sum(1 for row in rows if row.get("score_improvement_seen"))),
                "score_improvement_rate": float(sum(1 for row in rows if row.get("score_improvement_seen"))) / float(len(rows)) if rows else None,
                "escaped_false_basin_count": int(sum(1 for row in rows if row.get("escaped_false_basin"))),
                "escaped_false_basin_rate": float(sum(1 for row in rows if row.get("escaped_false_basin"))) / float(len(rows)) if rows else None,
                "score0_count": int(sum(1 for row in rows if row.get("score0_seen"))),
                "best_score_after": min(int(row.get("score_after", 10**9)) for row in rows),
                "median_score_after": median([row.get("score_after") for row in rows]),
                "median_score_delta": median([row.get("score_delta") for row in rows]),
                "median_D_min_ratio_after": median([row.get("D_min_ratio_after") for row in rows]),
                "median_P_8_after": median([row.get("P_8_after") for row in rows]),
                "median_kappa_max_after": median([row.get("kappa_max_after") for row in rows]),
            }
        )
    return out


def mismatch_summary(attempts):
    groups = {}
    for row in attempts:
        if row.get("linearized_score") is None:
            continue
        groups.setdefault(row["mode"], []).append(row)
    out = []
    for mode, rows in sorted(groups.items()):
        gaps = [abs(int(row.get("score_gap") or 0)) for row in rows]
        out.append(
            {
                "mode": mode,
                "audited_count": int(len(rows)),
                "mismatch_count": int(sum(1 for row in rows if int(row.get("score_gap") or 0) != 0 or int(row.get("interaction_norm") or 0) > 0)),
                "max_abs_score_gap": max(gaps) if gaps else 0,
                "median_abs_score_gap": median(gaps),
                "linearized_improvement_but_true_not_count": int(sum(1 for row in rows if row.get("linearized_score") is not None and int(row["linearized_score"]) < int(row["parent_score"]) and int(row["score_after"]) >= int(row["parent_score"]))),
                "same_block_multi_swap_count": int(sum(1 for row in rows if row.get("same_block_multi_swap"))),
            }
        )
    return out


def parent_outcome_summary(parents, attempts):
    by_parent = {}
    for row in attempts:
        by_parent.setdefault(row["parent_hash"], []).append(row)
    out = []
    for parent in parents:
        rows = by_parent.get(parent["parent_hash"], [])
        best = min(rows, key=lambda row: int(row.get("score_after", 10**9))) if rows else None
        out.append(
            {
                "parent_hash": parent["parent_hash"],
                "parent_origin": parent["parent_origin"],
                "parent_label": parent["parent_label"],
                "parent_score": int(parent["score"]),
                "best_score_after": None if best is None else int(best["score_after"]),
                "best_mode": None if best is None else best["mode"],
                "score0_seen": any(row.get("score0_seen") for row in rows),
                "score_improvement_seen": any(row.get("score_improvement_seen") for row in rows),
                "escaped_false_basin_seen": any(row.get("escaped_false_basin") for row in rows),
            }
        )
    return out


def hypothesis_evaluation(attempts, mode_summary, mismatch_rows):
    mode_map = {row["mode"]: row for row in mode_summary}
    mismatch_total = sum(row["mismatch_count"] for row in mismatch_rows)
    lin_bad = sum(row["linearized_improvement_but_true_not_count"] for row in mismatch_rows)
    h18 = mismatch_total > 0 or lin_bad > 0
    low_parent_improved = any(row["parent_score"] in (8, 12, 16) and row.get("score_improvement_seen") for row in attempts)
    score4_to_zero = any(row["parent_score"] == 4 and row.get("score0_seen") for row in attempts)
    h19 = low_parent_improved and not score4_to_zero
    neg = mode_map.get("negative_cross_pair_search", {})
    h20 = bool(neg) and float(neg.get("score_improvement_rate") or 0.0) <= 0.25
    pair = mode_map.get("pair_level_partial_defect_repair", {})
    block = mode_map.get("exact_joint_rswap_lns", {})
    h21 = None
    if pair and block:
        h21 = (
            float(pair.get("score_improvement_rate") or 0.0) > float(block.get("score_improvement_rate") or 0.0)
            or int(pair.get("best_score_after") or 999) < int(block.get("best_score_after") or 999)
        )
    return {
        "H18_exact_joint_more_reliable_than_linearized": {
            "verdict": "supported" if h18 else "not_supported",
            "mismatch_count": int(mismatch_total),
            "linearized_improvement_but_true_not_count": int(lin_bad),
        },
        "H19_defect_targeted_mid_score_but_weak_final_closure": {
            "verdict": "supported" if h19 else "not_supported",
            "score_8_12_16_improvement_seen": bool(low_parent_improved),
            "score4_to_score0_seen": bool(score4_to_zero),
        },
        "H20_negative_cross_pair_search_weak_alone": {
            "verdict": "supported" if h20 else "not_supported",
            "negative_cross_summary": neg,
        },
        "H21_pair_level_better_than_block_level": {
            "verdict": "supported" if h21 is True else ("not_supported" if h21 is False else "inconclusive"),
            "pair_level_summary": pair,
            "block_level_summary": block,
        },
    }


def make_summary(path, context):
    hyp = context["hypotheses"]
    mode_summary = context["mode_summary"]
    by_mode = {row["mode"]: row for row in mode_summary}
    score4_attempts = [row for row in context["attempts"] if int(row["parent_score"]) == 4]
    score4_to_zero = any(row.get("score0_seen") for row in score4_attempts)
    score4_lt4 = any(int(row.get("score_after") or 999) < 4 for row in score4_attempts)
    mid_improved = any(int(row["parent_score"]) in (8, 12, 16) and row.get("score_improvement_seen") for row in context["attempts"])
    best_improve = max(mode_summary, key=lambda row: float(row.get("score_improvement_rate") or 0.0))
    best_escape = max(mode_summary, key=lambda row: float(row.get("escaped_false_basin_rate") or 0.0))
    lines = [
        "# p37 Repair/LNS Ablation Summary",
        "",
        "This run compares p=37 repair/LNS modes on low-score candidates. It is not a Hadamard 668 construction run.",
        "",
        "## Run",
        "",
        "- p: `{}`".format(context["p"]),
        "- ks: `{}`".format(context["ks"]),
        "- lambda: `{}`".format(context["lambda"]),
        "- parent candidates: `{}`".format(context["parent_count"]),
        "- score=0 only is success.",
        "",
        "## Mode Summary",
        "",
        "```json",
        json.dumps(json_safe(mode_summary), indent=2, sort_keys=True),
        "```",
        "",
        "## Hypotheses",
        "",
        "```json",
        json.dumps(json_safe(hyp), indent=2, sort_keys=True),
        "```",
        "",
        "## Required Answers",
        "",
        "1. score=4 parent から score=0 は出たか: `{}`.".format(score4_to_zero),
        "2. score=4 parent から score<4 は出たか: `{}`.".format(score4_lt4),
        "3. score=8/12/16 parent から score 改善は出たか: `{}`.".format(mid_improved),
        "4. どの repair mode が最も score improvement rate が高かったか: `{}` rate `{}`.".format(best_improve["mode"], best_improve["score_improvement_rate"]),
        "5. どの repair mode が最も escaped_false_basin rate が高かったか: `{}` rate `{}`.".format(best_escape["mode"], best_escape["escaped_false_basin_rate"]),
        "6. negative_cross_pair_search は true improvement に繋がったか: `{}`.".format(bool(by_mode.get("negative_cross_pair_search", {}).get("score_improvement_count", 0))),
        "7. sparse_vector_cancellation_beam は true recomputation でも有効だったか: `{}`.".format(bool(by_mode.get("sparse_vector_cancellation_beam", {}).get("score_improvement_count", 0))),
        "8. exact_joint_rswap_lns は block-level repair として有効だったか: `{}`.".format(bool(by_mode.get("exact_joint_rswap_lns", {}).get("score_improvement_count", 0))),
        "9. pair_level_partial_defect_repair は H21 を支持したか: `{}`.".format(hyp["H21_pair_level_better_than_block_level"]["verdict"]),
        "10. moment_late_repair は score と揃ったか、それとも conflict したか: score_improvement_rate `{}`; moment objective is late-stage only.".format(by_mode.get("moment_late_repair", {}).get("score_improvement_rate")),
        "11. exact joint vs linearized mismatch はどの程度あったか: mismatch_count `{}`, linearized improvement but true not `{}`.".format(hyp["H18_exact_joint_more_reliable_than_linearized"]["mismatch_count"], hyp["H18_exact_joint_more_reliable_than_linearized"]["linearized_improvement_but_true_not_count"]),
        "12. H18, H19, H20, H21 の判定: H18 `{}`, H19 `{}`, H20 `{}`, H21 `{}`.".format(
            hyp["H18_exact_joint_more_reliable_than_linearized"]["verdict"],
            hyp["H19_defect_targeted_mid_score_but_weak_final_closure"]["verdict"],
            hyp["H20_negative_cross_pair_search_weak_alone"]["verdict"],
            hyp["H21_pair_level_better_than_block_level"]["verdict"],
        ),
        "13. 668 に戻す場合、repair/LNS を主探索に使うべきか、late-stage audit に使うべきか: use as late-stage audit/repair, not primary search, unless exact-like trajectory signatures are present.",
    ]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="p37 repair/LNS ablation for cyclic SDS low-score candidates.")
    parser.add_argument("--p", type=int, default=37)
    parser.add_argument("--ks", type=parse_ks, default=(13, 16, 18, 18))
    parser.add_argument("--lambda", dest="lam", type=int, default=28)
    parser.add_argument("--exact-json", default="outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json")
    parser.add_argument("--max-parent-candidates", type=int, default=50)
    parser.add_argument("--samples-per-r", type=int, default=500)
    parser.add_argument("--beam-width", type=int, default=300)
    parser.add_argument("--max-depth", type=int, default=5)
    parser.add_argument("--restarts-per-candidate", type=int, default=5)
    parser.add_argument("--threshold-sample-moves", type=int, default=12)
    parser.add_argument("--library-k", type=int, default=50)
    parser.add_argument("--random-library-moves", type=int, default=50)
    parser.add_argument("--pair-library-limit", type=int, default=120)
    parser.add_argument("--beam-library-limit", type=int, default=90)
    parser.add_argument("--beam-true-eval-limit", type=int, default=45)
    parser.add_argument("--pair-repair-library-limit", type=int, default=70)
    parser.add_argument("--moment-library-limit", type=int, default=120)
    parser.add_argument("--seed", type=int, default=61037)
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
        out_dir = args.out_dir or os.path.join("outputs", "explorations", "{}_p37_repair_lns_ablation".format(now_stamp()))
        ensure_dir(out_dir)
        baseline = random_baseline_tuple(p, ks)
        run_config = {
            "script": SCRIPT_NAME,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "p": int(p),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "exact_json": args.exact_json,
            "max_parent_candidates": int(args.max_parent_candidates),
            "samples_per_r": int(args.samples_per_r),
            "beam_width": int(args.beam_width),
            "max_depth": int(args.max_depth),
            "modes": list(MODES),
            "out_dir": out_dir,
            "note": "score=0 only is success; p=37 repair/LNS ablation only.",
        }
        write_json_safe(os.path.join(out_dir, "run_config.json"), run_config)
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# Run Log\n\n")
            f.write("- script: `{}`\n".format(SCRIPT_NAME))
            f.write("- score=0 only is success\n")
            f.write("- exact-derived controlled candidates are positive controls\n")

        parents = discover_input_candidates(args, baseline)
        write_jsonl(os.path.join(out_dir, "input_repair_candidates.jsonl"), parents)
        print("Selected parents:", len(parents))
        sys.stdout.flush()

        rng = random.Random(int(args.seed))
        attempts = []
        score0_paths = []
        score0_path_set = set()
        for idx, parent in enumerate(parents):
            print("parent {}/{} origin={} score={} label={}".format(idx + 1, len(parents), parent["parent_origin"], parent["score"], parent["parent_label"]))
            sys.stdout.flush()
            parent_attempts = run_all_modes(parent, p, ks, lam, baseline, rng, args)
            for attempt in parent_attempts:
                attempt["parent_index"] = int(idx)
                if attempt.get("score0_seen"):
                    path = save_score0_candidate(out_dir, parent, attempt, attempt["_blocks"], p, ks, lam)
                    if path:
                        attempt["score0_candidate_path"] = path
                        if path not in score0_path_set:
                            score0_path_set.add(path)
                            score0_paths.append(path)
            attempts.extend(parent_attempts)

        write_jsonl(os.path.join(out_dir, "repair_attempts.jsonl"), attempts)
        mode_summary = repair_by_mode_summary(attempts)
        write_csv(
            os.path.join(out_dir, "repair_by_mode_summary.csv"),
            mode_summary,
            [
                "mode",
                "attempt_count",
                "score_improvement_count",
                "score_improvement_rate",
                "escaped_false_basin_count",
                "escaped_false_basin_rate",
                "score0_count",
                "best_score_after",
                "median_score_after",
                "median_score_delta",
                "median_D_min_ratio_after",
                "median_P_8_after",
                "median_kappa_max_after",
            ],
        )
        write_json_safe(os.path.join(out_dir, "repair_by_mode_summary.json"), {"rows": mode_summary})
        mismatch_rows = mismatch_summary(attempts)
        write_csv(
            os.path.join(out_dir, "exact_joint_mismatch_summary.csv"),
            mismatch_rows,
            ["mode", "audited_count", "mismatch_count", "max_abs_score_gap", "median_abs_score_gap", "linearized_improvement_but_true_not_count", "same_block_multi_swap_count"],
        )
        write_json_safe(os.path.join(out_dir, "exact_joint_mismatch_summary.json"), {"rows": mismatch_rows})
        parent_summary = parent_outcome_summary(parents, attempts)
        write_csv(
            os.path.join(out_dir, "parent_outcome_summary.csv"),
            parent_summary,
            ["parent_hash", "parent_origin", "parent_label", "parent_score", "best_score_after", "best_mode", "score0_seen", "score_improvement_seen", "escaped_false_basin_seen"],
        )
        hyp = hypothesis_evaluation(attempts, mode_summary, mismatch_rows)
        hyp["score0_candidate_paths"] = score0_paths
        write_json_safe(os.path.join(out_dir, "hypothesis_evaluation.json"), hyp)
        make_summary(
            os.path.join(out_dir, "p37_repair_lns_ablation_summary.md"),
            {
                "p": p,
                "ks": [int(k) for k in ks],
                "lambda": lam,
                "parent_count": len(parents),
                "attempts": attempts,
                "mode_summary": mode_summary,
                "hypotheses": hyp,
            },
        )
        print("SUMMARY:", os.path.join(out_dir, "p37_repair_lns_ablation_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
