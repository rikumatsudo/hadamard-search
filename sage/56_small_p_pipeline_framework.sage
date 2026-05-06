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


SCRIPT_NAME = "56_small_p_pipeline_framework"
POWERS = (2, 4, 6, 8, 10, 12)
PIPELINE_MODES = (
    "design_only",
    "diagnose_exact",
    "init_smoke",
    "trajectory_smoke",
    "classifier_smoke",
    "repair_smoke",
    "pipeline_smoke",
)
TRAJECTORY_MODES = (
    "score_only",
    "escapability_aware",
    "energy_regularized_init",
    "mixed_diversity",
    "threshold_accepting",
)
INIT_FAMILIES = (
    "pure_random",
    "low_energy_random",
    "score_biased_random",
    "energy_regularized",
    "mixed_diversity",
    "near_hit_perturbation",
    "exact_perturbation",
)
REPAIR_MODES = (
    "exact_joint_rswap_lns",
    "negative_cross_pair_search",
    "sparse_vector_cancellation_beam",
    "pair_level_partial_defect_repair",
    "moment_late_repair",
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


def write_csv(path, rows, fields):
    ensure_dir(os.path.dirname(path))
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: csv_value(row.get(field)) for field in fields})


def csv_value(value):
    value = json_safe(value)
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True)
    if value is None:
        return ""
    return value


def parse_ks(text):
    values = tuple(int(part.strip()) for part in str(text).split(",") if part.strip())
    if len(values) != 4:
        raise argparse.ArgumentTypeError("--ks must contain exactly four integers")
    return values


def parse_modes(text, allowed):
    values = tuple(part.strip() for part in str(text).split(",") if part.strip())
    bad = [value for value in values if value not in allowed]
    if bad:
        raise argparse.ArgumentTypeError("unsupported mode(s): {}".format(",".join(bad)))
    return values


def clone_blocks(blocks):
    return [set(block) for block in blocks]


def row_sums_from_ks(p, ks):
    return [int(p - 2 * int(k)) for k in ks]


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
    var_nd = en2 - mean_nd * mean_nd
    return {
        "p": int(p),
        "k": int(k),
        "E_n_d": float(mean_nd),
        "E_n_d_square": float(en2),
        "Var_n_d": float(var_nd),
        "E_energy": float(e_energy),
        "E_AP": float(e_ap),
        "E_Q": float(e_q),
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
        q_excess = float(q) - float(base["E_Q"])
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
                "Q_excess": float(q_excess),
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


def moment_payload(counts, lam, p):
    summary = p_adic_moment_summary(counts, lam, powers=POWERS, modulus=p)
    moments = {"T{}".format(item["power"]): int(item["residue"]) for item in summary["moments"]}
    return {
        "T2": int(moments["T2"]),
        "T4": int(moments["T4"]),
        "T6": int(moments["T6"]),
        "T8": int(moments["T8"]),
        "T10": int(moments["T10"]),
        "T12": int(moments["T12"]),
        "padic_moments": moments,
        "moment_zero_count_3": int(sum(1 for key in ("T2", "T4", "T6") if moments[key] == 0)),
        "moment_zero_count_6": int(summary["moment_zero_count"]),
        "higher_moment_norm": int(sum(balanced_abs(moments[key], p) ** 2 for key in ("T8", "T10", "T12"))),
        "low_moment_norm": int(sum(balanced_abs(moments[key], p) ** 2 for key in ("T2", "T4", "T6"))),
    }


def rho_vector(counts, lam):
    rho = [0] * len(counts)
    for d in range(1, len(counts)):
        rho[d] = int(counts[d] - lam)
    return rho


def score_counts(counts, lam):
    return int(metrics_from_counts(counts, lam)[0])


def defect_pattern(counts, lam, p):
    rho = rho_vector(counts, lam)
    pairs = []
    positive_pairs = []
    negative_pairs = []
    mixed_pairs = []
    nonzero = []
    seen = set()
    for d in range(1, int(p)):
        value = int(rho[d])
        if value != 0:
            nonzero.append({"shift": int(d), "defect": int(value)})
        if d in seen:
            continue
        e = (-d) % int(p)
        seen.add(d)
        seen.add(e)
        values = [int(rho[d]), int(rho[e])]
        if values == [0, 0]:
            continue
        item = {"pair": [int(d), int(e)], "defects": values}
        pairs.append(item)
        if values[0] > 0 and values[1] > 0:
            positive_pairs.append(item)
        elif values[0] < 0 and values[1] < 0:
            negative_pairs.append(item)
        else:
            mixed_pairs.append(item)
    signature = "+pairs{}_ -pairs{}_ mixed{}_ nonzero{}".format(
        len(positive_pairs), len(negative_pairs), len(mixed_pairs), len(nonzero)
    )
    if len(positive_pairs) == 1 and len(negative_pairs) == 1 and not mixed_pairs and len(nonzero) == 4:
        pattern_type = "+1 on one +/- pair, -1 on one +/- pair"
    elif len(nonzero) == 0:
        pattern_type = "exact"
    else:
        pattern_type = "other"
    return {
        "defect_pattern_signature": signature,
        "defect_pattern_type": pattern_type,
        "nonzero_defect_coordinates": nonzero,
        "positive_defect_pairs": positive_pairs,
        "negative_defect_pairs": negative_pairs,
        "mixed_defect_pairs": mixed_pairs,
        "rho_sum": int(sum(rho[1:])),
    }


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


def one_swap_library(blocks, counts, lam, p, max_moves=None):
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
                alpha = None if score <= 0 or q <= 0 else float(-g) / math.sqrt(float(score * q))
                pos_destroy = 0
                neg_repair = 0
                for d, value in delta.items():
                    r = int(rho[d])
                    dv = int(value)
                    pos_destroy += max(0, -dv) * max(0, r)
                    neg_repair += max(0, dv) * max(0, -r)
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
                        "alpha": alpha,
                        "positive_destroy": int(pos_destroy),
                        "negative_repair": int(neg_repair),
                        "defect_target_score": int(pos_destroy + neg_repair),
                    }
                )
    moves.sort(
        key=lambda item: (
            int(item["h"]),
            -float(item["kappa"] if item["kappa"] is not None else -999.0),
            -int(item["defect_target_score"]),
            int(item["q"]),
        )
    )
    if max_moves is not None:
        return moves[: int(max_moves)]
    return moves


def full_diagnostic(blocks, counts, lam, p, baseline):
    p = int(p)
    metrics = metrics_from_counts(counts, lam)
    score, l1_error, max_abs_error, nonzero_defect_count = [int(x) for x in metrics]
    moves = one_swap_library(blocks, counts, lam, p)
    h_values = [int(move["h"]) for move in moves]
    q_values = [int(move["q"]) for move in moves]
    kappas = [float(move["kappa"]) for move in moves if move["kappa"] is not None]
    improving = [move for move in moves if int(move["h"]) < 0]
    near = {}
    for threshold in (0, 4, 8, 16):
        near[threshold] = sum(1 for move in moves if int(move["h"]) <= threshold)
    theta = {}
    for frac in (0.01, 0.05, 0.10):
        theta[frac] = sum(1 for move in moves if score > 0 and int(move["h"]) <= frac * score)
    low_q_cut = quantile(q_values, 0.25) if q_values else None
    high_kappa_cut = quantile(kappas, 0.90) if kappas else None
    low_q_high_kappa_overlap = 0
    if low_q_cut is not None and high_kappa_cut is not None:
        low_q_high_kappa_overlap = sum(
            1
            for move in moves
            if int(move["q"]) <= int(low_q_cut)
            and move["kappa"] is not None
            and float(move["kappa"]) >= float(high_kappa_cut)
        )
    h_min = min(h_values) if h_values else None
    d_min = None if h_min is None else int(score + h_min)
    structure = block_structure_payload(p, blocks, baseline)
    threshold = int(4 * (p - 1) * score)
    out = {
        "score": int(score),
        "l1": int(l1_error),
        "l1_error": int(l1_error),
        "max_abs": int(max_abs_error),
        "max_abs_error": int(max_abs_error),
        "nonzero": int(nonzero_defect_count),
        "nonzero_defect_count": int(nonzero_defect_count),
        "h_min": int(h_min) if h_min is not None else None,
        "D_min_1": int(d_min) if d_min is not None else None,
        "D_min_ratio": float(d_min) / float(score) if score > 0 and d_min is not None else None,
        "improving_swap_count": int(len(improving)),
        "P_<0": float(len(improving)) / float(len(moves)) if moves else None,
        "P_0": float(near[0]) / float(len(moves)) if moves else None,
        "P_4": float(near[4]) / float(len(moves)) if moves else None,
        "P_8": float(near[8]) / float(len(moves)) if moves else None,
        "P_16": float(near[16]) / float(len(moves)) if moves else None,
        "P_thetaS_001": float(theta[0.01]) / float(len(moves)) if moves else None,
        "P_thetaS_005": float(theta[0.05]) / float(len(moves)) if moves else None,
        "P_thetaS_010": float(theta[0.10]) / float(len(moves)) if moves else None,
        "kappa_max": max(kappas) if kappas else None,
        "kappa_quantiles": {
            "q50": quantile(kappas, 0.50),
            "q90": quantile(kappas, 0.90),
            "q99": quantile(kappas, 0.99),
        },
        "low_q_high_kappa_overlap": int(low_q_high_kappa_overlap),
        "Q_tot": int(sum(q_values)),
        "Q_ratio": float(sum(q_values)) / float(threshold) if threshold > 0 else None,
        "InitHardness": float(structure["InitHardness"]),
        "E_total": int(structure["E_total"]),
        "AP_total": int(structure["AP_total"]),
        "E_excess_total": float(structure["E_excess_total"]),
        "AP_excess_total": float(structure["AP_excess_total"]),
        "num_swaps": int(len(moves)),
        "min_h_move": public_row(moves[0]) if moves else None,
    }
    out.update(moment_payload(counts, lam, p))
    out.update(defect_pattern(counts, lam, p))
    return out


def is_hard_basin(diag):
    if not diag:
        return False
    return bool(
        diag.get("h_min") is not None
        and int(diag.get("h_min")) > 0
        and int(diag.get("improving_swap_count", 0)) == 0
        and diag.get("D_min_ratio") is not None
        and float(diag.get("D_min_ratio")) > 1.0
    )


def random_blocks(rng, p, ks):
    universe = list(range(int(p)))
    return [set(rng.sample(universe, int(k))) for k in ks]


def random_swap(rng, blocks, p):
    block_idx = rng.randrange(4)
    block = blocks[block_idx]
    removed = rng.choice(tuple(block))
    added = rng.randrange(int(p))
    while added in block:
        added = rng.randrange(int(p))
    return {"block": int(block_idx), "removed": int(removed), "added": int(added)}


def apply_swap_copy(blocks, move):
    new_blocks = clone_blocks(blocks)
    ok = apply_swap_to_blocks(new_blocks, move)
    if not ok:
        return None
    return new_blocks


def apply_move_to_counts(p, blocks, counts, move):
    delta = delta_swap(p, blocks[int(move["block"])], int(move["removed"]), int(move["added"]))
    return apply_delta(counts, delta)


def deterministic_mode_offset(mode):
    return sum((idx + 1) * ord(ch) for idx, ch in enumerate(str(mode)))


def target_registry_payload(p, ks, lam, exact_json):
    return {
        "targets": [
            {
                "p": int(p),
                "n": int(4 * int(p)),
                "ks": [int(k) for k in ks],
                "lambda": int(lam),
                "row_sums": row_sums_from_ks(p, ks),
                "has_known_exact": bool(exact_json),
                "exact_json": exact_json or None,
                "role": "small_p_validation" if int(p) == 37 else "config_driven_target",
            }
        ]
    }


def validate_exact_candidate(exact_json, p, ks, lam):
    if not exact_json:
        return {
            "has_exact_json": False,
            "score": None,
            "sds_ok": False,
            "hh_t_ok": False,
            "commands": [],
        }
    data, v, n, got_ks, got_lam, blocks = load_candidate(exact_json)
    if int(v) != int(p) or tuple(got_ks) != tuple(ks) or int(got_lam) != int(lam):
        raise ValueError("exact_json target mismatch: got v={}, ks={}, lambda={}".format(v, got_ks, got_lam))
    counts = total_diff_counts(p, blocks)
    score, l1_error, max_abs_error, nonzero = metrics_from_counts(counts, lam)
    sds_ok, bad = verify_sds(p, blocks, lam)
    entries_ok, hh_t_ok = verify_hadamard_exact(p, blocks)
    return {
        "has_exact_json": True,
        "exact_json": exact_json,
        "p": int(p),
        "n": int(n),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "score": int(score),
        "l1_error": int(l1_error),
        "max_abs_error": int(max_abs_error),
        "nonzero_defect_count": int(nonzero),
        "sds_ok": bool(sds_ok),
        "bad_shifts": [{"shift": int(d), "count": int(c)} for d, c in bad[:20]],
        "entries_pm1_ok": bool(entries_ok),
        "hh_t_ok": bool(hh_t_ok),
        "hh_t_expected": "{}I".format(int(4 * int(p))),
        "commands": [
            "sage sage/08_analyze_sds_candidate.sage {}".format(exact_json),
            "sage sage/05_validate_candidate_json.sage {}".format(exact_json),
            "sage sage/04_build_gs_from_sds.sage {}".format(exact_json),
        ],
    }


def candidate_record(blocks, p, ks, lam, baseline, origin_family, origin_stage, seed=None, step=None, source_path=None, extra=None, diagnose=False):
    counts = total_diff_counts(p, blocks)
    score, l1_error, max_abs_error, nonzero = metrics_from_counts(counts, lam)
    structure = block_structure_payload(p, blocks, baseline)
    record = {
        "schema_version": 1,
        "candidate_kind": "cyclic_4_block_sds",
        "p": int(p),
        "v": int(p),
        "n": int(4 * int(p)),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": json_blocks(blocks),
        "canonical_hash": canonical_hash(blocks, ks, p),
        "canonical_repr_summary": canonical_repr_summary(blocks, ks, p),
        "origin_family": origin_family,
        "origin_stage": origin_stage,
        "seed": None if seed is None else int(seed),
        "step": None if step is None else int(step),
        "source_path": source_path,
        "score": int(score),
        "l1_error": int(l1_error),
        "max_abs_error": int(max_abs_error),
        "nonzero_defect_count": int(nonzero),
        "error_histogram": error_histogram(counts, lam),
        "Q_tot": int(structure["Q_formula_total"]),
        "Q_ratio_random_expected": float(structure["Q_formula_total"]) / max(1.0, float(baseline["E_Q_total"])),
        "E_total": int(structure["E_total"]),
        "AP_total": int(structure["AP_total"]),
        "InitHardness": float(structure["InitHardness"]),
        "defect_pattern": defect_pattern(counts, lam, p),
        "score_is_solution": bool(int(score) == 0),
        "_blocks": clone_blocks(blocks),
        "_counts": list(counts),
    }
    record.update(moment_payload(counts, lam, p))
    if diagnose:
        diag = full_diagnostic(blocks, counts, lam, p, baseline)
        record["diagnostic"] = diag
        record["is_hard_basin"] = bool(is_hard_basin(diag))
    if extra:
        record.update(extra)
    return record


def rank_initial_candidate(blocks, p, lam, baseline, family):
    counts = total_diff_counts(p, blocks)
    score = score_counts(counts, lam)
    structure = block_structure_payload(p, blocks, baseline)
    e_score = max(1.0, float(baseline["E_score"]))
    e_q = max(1.0, float(abs(baseline["E_Q_total"])))
    if family == "pure_random":
        return (0.0, rng_tiebreak(blocks, p))
    if family == "low_energy_random":
        energy = sum(max(0.0, row["E_excess"]) for row in structure["blocks"])
        return (float(energy) / e_q, score)
    if family == "score_biased_random":
        return (float(score), structure["InitHardness"])
    if family == "energy_regularized":
        return (float(score) / e_score + 0.25 * max(0.0, structure["InitHardness"]) / e_q, score)
    if family == "mixed_diversity":
        return (
            float(score) / e_score
            + 0.10 * abs(structure["E_excess_total"]) / e_q
            + 0.10 * abs(structure["AP_excess_total"]) / max(1.0, float(p)),
            -structure["InitHardness"],
        )
    return (float(score), structure["InitHardness"])


def rng_tiebreak(blocks, p):
    return sum((idx + 1) * sum(int(x) for x in block) for idx, block in enumerate(blocks)) % int(p)


def discover_existing_candidates(p, ks, lam, max_candidates, score_max=None, score_exact=None):
    roots = [
        os.path.join("outputs", "candidates", "small_p"),
        os.path.join("outputs", "explorations"),
    ]
    paths = []
    for root in roots:
        if os.path.isdir(root):
            paths.extend(glob.glob(os.path.join(root, "**", "*.json"), recursive=True))
    found = []
    seen_hash = set()
    for path in sorted(paths):
        if os.path.getsize(path) > 2_000_000:
            continue
        try:
            data, v, _n, got_ks, got_lam, blocks = load_candidate(path)
        except Exception:
            continue
        if int(v) != int(p) or tuple(got_ks) != tuple(ks) or int(got_lam) != int(lam):
            continue
        counts = total_diff_counts(p, blocks)
        score = score_counts(counts, lam)
        if score_exact is not None and int(score) != int(score_exact):
            continue
        if score_max is not None and int(score) > int(score_max):
            continue
        key = canonical_hash(blocks, ks, p)
        if key in seen_hash:
            continue
        seen_hash.add(key)
        found.append({"path": path, "blocks": clone_blocks(blocks), "score": int(score)})
        if len(found) >= int(max_candidates):
            break
    return found


def perturb_blocks(rng, blocks, p, radius):
    out = clone_blocks(blocks)
    for _ in range(int(radius)):
        move = random_swap(rng, out, p)
        if not apply_swap_to_blocks(out, move):
            break
    return out


def make_initial_candidates(args, p, ks, lam, baseline, exact_blocks):
    rows = []
    seen = set()
    near_hits = discover_existing_candidates(p, ks, lam, max_candidates=20, score_max=8)
    for family in INIT_FAMILIES:
        for idx in range(int(args.initial_per_family)):
            seed = int(args.seed + 1009 * idx + deterministic_mode_offset(family))
            rng = random.Random(seed)
            if family in ("pure_random",):
                blocks = random_blocks(rng, p, ks)
            elif family in ("low_energy_random", "score_biased_random", "energy_regularized", "mixed_diversity"):
                pool = []
                for _ in range(max(1, int(args.init_pool))):
                    candidate = random_blocks(rng, p, ks)
                    pool.append((rank_initial_candidate(candidate, p, lam, baseline, family), candidate))
                pool.sort(key=lambda item: item[0])
                blocks = clone_blocks(pool[0][1])
            elif family == "near_hit_perturbation" and near_hits:
                source = near_hits[idx % len(near_hits)]
                radius = 1 + (idx % 2)
                blocks = perturb_blocks(rng, source["blocks"], p, radius)
            elif family == "exact_perturbation" and exact_blocks is not None:
                radius = 1 + (idx % max(1, int(args.exact_perturb_max_r)))
                blocks = perturb_blocks(rng, exact_blocks, p, radius)
            else:
                blocks = random_blocks(rng, p, ks)
            key = canonical_hash(blocks, ks, p)
            if key in seen:
                continue
            seen.add(key)
            rows.append(
                candidate_record(
                    blocks,
                    p,
                    ks,
                    lam,
                    baseline,
                    origin_family=family,
                    origin_stage="initialization_factory",
                    seed=seed,
                    step=0,
                    extra={"initial_index": int(idx)},
                )
            )
    return rows


def summarize_initialization(rows):
    by_family = {}
    for row in rows:
        family = row["origin_family"]
        by_family.setdefault(family, []).append(row)
    summary = {"candidate_count": int(len(rows)), "families": {}}
    for family, items in sorted(by_family.items()):
        scores = [int(row["score"]) for row in items]
        q_values = [float(row["Q_ratio_random_expected"]) for row in items]
        hardness = [float(row["InitHardness"]) for row in items]
        summary["families"][family] = {
            "count": int(len(items)),
            "best_score": min(scores) if scores else None,
            "median_score": statistics.median(scores) if scores else None,
            "median_Q_ratio_random_expected": statistics.median(q_values) if q_values else None,
            "median_InitHardness": statistics.median(hardness) if hardness else None,
            "hypothesis_probe": "below-random score + near-random hardness + local entropy proxy",
        }
    return summary


def trajectory_initial_blocks(mode, rng, p, ks, lam, baseline, exact_blocks, near_hits, args):
    if mode == "energy_regularized_init":
        family = "energy_regularized"
    elif mode == "mixed_diversity":
        family = rng.choice(("pure_random", "low_energy_random", "score_biased_random", "energy_regularized", "mixed_diversity"))
    elif mode == "threshold_accepting" and near_hits and rng.random() < 0.5:
        source = near_hits[rng.randrange(len(near_hits))]
        return clone_blocks(source["blocks"]), "near_hit_seed"
    else:
        family = "pure_random"
    if family == "pure_random":
        return random_blocks(rng, p, ks), family
    pool = []
    for _ in range(max(1, int(args.init_pool))):
        candidate = random_blocks(rng, p, ks)
        pool.append((rank_initial_candidate(candidate, p, lam, baseline, family), candidate))
    pool.sort(key=lambda item: item[0])
    return clone_blocks(pool[0][1]), family


def sample_best_move(rng, blocks, counts, lam, p, samples, targeted_prob):
    p = int(p)
    score = score_counts(counts, lam)
    rho = rho_vector(counts, lam)
    defects = sorted([(abs(rho[d]), d) for d in range(1, p)], reverse=True)
    best = None
    for _ in range(int(samples)):
        if rng.random() < float(targeted_prob) and defects:
            _weight, d = rng.choice(defects[: min(12, len(defects))])
            move = None
            for _try in range(16):
                block_idx = rng.randrange(4)
                block = blocks[block_idx]
                if rng.random() < 0.5:
                    removed = rng.choice(tuple(block))
                    added = (int(removed) + int(d)) % p
                    if added not in block:
                        move = {"block": int(block_idx), "removed": int(removed), "added": int(added)}
                        break
                added = rng.randrange(p)
                if added in block:
                    continue
                removed = (int(added) + int(d)) % p
                if removed in block:
                    move = {"block": int(block_idx), "removed": int(removed), "added": int(added)}
                    break
            if move is None:
                move = random_swap(rng, blocks, p)
        else:
            move = random_swap(rng, blocks, p)
        new_counts = apply_move_to_counts(p, blocks, counts, move)
        new_score, new_l1, new_max_abs, new_nonzero = metrics_from_counts(new_counts, lam)
        item = {
            "move": move,
            "new_counts": new_counts,
            "metrics": (int(new_score), int(new_l1), int(new_max_abs), int(new_nonzero)),
            "DeltaS": int(new_score - score),
        }
        if best is None or item["metrics"] < best["metrics"]:
            best = item
    return best


def run_trajectory_mode(mode, p, ks, lam, baseline, exact_blocks, args):
    near_hits = discover_existing_candidates(p, ks, lam, max_candidates=20, score_max=8)
    rows = []
    best_candidate_rows = []
    for seed_idx in range(1, int(args.seeds) + 1):
        rng = random.Random(int(args.seed + 1000003 * seed_idx + deterministic_mode_offset(mode)))
        blocks, family = trajectory_initial_blocks(mode, rng, p, ks, lam, baseline, exact_blocks, near_hits, args)
        counts = total_diff_counts(p, blocks)
        initial_score = score_counts(counts, lam)
        best_blocks = clone_blocks(blocks)
        best_counts = list(counts)
        best_score = int(initial_score)
        accepted = 0
        success_step = None
        threshold = int(args.threshold_accepting_delta)
        for step in range(1, int(args.steps) + 1):
            move_item = sample_best_move(rng, blocks, counts, lam, p, int(args.candidate_samples), float(args.targeted_prob))
            delta_s = int(move_item["DeltaS"])
            accept = False
            if delta_s < 0:
                accept = True
            elif mode == "threshold_accepting" and delta_s <= threshold:
                accept = True
            elif mode in ("escapability_aware", "mixed_diversity") and delta_s <= int(args.allowed_worsen):
                accept = rng.random() < math.exp(-float(max(0, delta_s)) / max(0.01, float(args.escape_temperature)))
            elif rng.random() < float(args.random_walk_prob):
                accept = True
            if accept:
                move = move_item["move"]
                if apply_swap_to_blocks(blocks, move):
                    counts = list(move_item["new_counts"])
                    accepted += 1
            score = score_counts(counts, lam)
            if score < best_score:
                best_score = int(score)
                best_blocks = clone_blocks(blocks)
                best_counts = list(counts)
            if score == 0:
                success_step = int(step)
                best_score = 0
                best_blocks = clone_blocks(blocks)
                best_counts = list(counts)
                break
        diag = full_diagnostic(best_blocks, best_counts, lam, p, baseline)
        best_row = candidate_record(
            best_blocks,
            p,
            ks,
            lam,
            baseline,
            origin_family=family,
            origin_stage="trajectory_best",
            seed=seed_idx,
            step=success_step if success_step is not None else int(args.steps),
            extra={"trajectory_mode": mode},
        )
        best_row["diagnostic"] = diag
        best_row["is_hard_basin"] = bool(is_hard_basin(diag))
        best_candidate_rows.append(best_row)
        final_score = score_counts(counts, lam)
        rows.append(
            {
                "mode": mode,
                "seed": int(seed_idx),
                "steps": int(success_step if success_step is not None else args.steps),
                "accepted_moves": int(accepted),
                "initial_score": int(initial_score),
                "final_score": int(final_score),
                "best_score": int(best_score),
                "success_score0": bool(best_score == 0),
                "success_step": success_step,
                "final_hard_basin": bool(is_hard_basin(diag)),
                "best_candidate_hash": best_row["canonical_hash"],
                "h_min": diag.get("h_min"),
                "D_min_ratio": diag.get("D_min_ratio"),
                "P_4": diag.get("P_4"),
                "Q_ratio": diag.get("Q_ratio"),
                "InitHardness": diag.get("InitHardness"),
            }
        )
        print("trajectory mode={} seed={} best_score={} hard={}".format(mode, seed_idx, best_score, rows[-1]["final_hard_basin"]))
        sys.stdout.flush()
    return rows, best_candidate_rows


def summarize_trajectories(rows):
    out = {}
    by_mode = {}
    for row in rows:
        by_mode.setdefault(row["mode"], []).append(row)
    for mode, items in sorted(by_mode.items()):
        out[mode] = {
            "run_count": int(len(items)),
            "best_score": min(int(row["best_score"]) for row in items) if items else None,
            "success_score0_count": int(sum(1 for row in items if row["success_score0"])),
            "final_hard_basin_count": int(sum(1 for row in items if row["final_hard_basin"])),
            "median_best_score": statistics.median([int(row["best_score"]) for row in items]) if items else None,
            "median_accepted_moves": statistics.median([int(row["accepted_moves"]) for row in items]) if items else None,
        }
    return out


def translate_block(block, shift, p):
    return set((int(x) + int(shift)) % int(p) for x in block)


def block_distance(a, b):
    return len(set(a).symmetric_difference(set(b))) // 2


def equal_size_permutations(ks):
    perms = [list(range(len(ks)))]
    groups = {}
    for idx, k in enumerate(ks):
        groups.setdefault(int(k), []).append(idx)
    for indices in groups.values():
        if len(indices) == 2:
            swapped = list(range(len(ks)))
            swapped[indices[0]], swapped[indices[1]] = swapped[indices[1]], swapped[indices[0]]
            if swapped not in perms:
                perms.append(swapped)
    return perms


def align_exact_to_candidate(candidate_blocks, exact_blocks, ks, p):
    best = None
    for shift in range(int(p)):
        shifted = [translate_block(block, shift, p) for block in exact_blocks]
        for perm in equal_size_permutations(ks):
            aligned = [shifted[perm[idx]] for idx in range(len(ks))]
            per_block = [block_distance(candidate_blocks[idx], aligned[idx]) for idx in range(len(ks))]
            distance = int(sum(per_block))
            item = {
                "distance": int(distance),
                "shift": int(shift),
                "perm": [int(x) for x in perm],
                "per_block": [int(x) for x in per_block],
                "aligned_exact_blocks": aligned,
            }
            if best is None or (item["distance"], item["shift"], item["perm"]) < (best["distance"], best["shift"], best["perm"]):
                best = item
    return best


def classify_candidates(candidates, exact_blocks, p, ks, lam, baseline):
    rows = []
    feature_rows = []
    exact_hash = canonical_hash(exact_blocks, ks, p) if exact_blocks is not None else None
    for item in candidates:
        blocks = item["_blocks"]
        diag = item.get("diagnostic") or full_diagnostic(blocks, item["_counts"], lam, p, baseline)
        alignment = align_exact_to_candidate(blocks, exact_blocks, ks, p) if exact_blocks is not None else None
        return_radius = alignment["distance"] if alignment else None
        if item["canonical_hash"] == exact_hash or int(item["score"]) == 0:
            label = "exact"
        elif item.get("origin_family") == "exact_perturbation":
            label = "exact_derived"
        elif int(item["score"]) <= 8 and diag.get("h_min") is not None and int(diag["h_min"]) < 0:
            label = "low_score_escapable"
        elif int(item["score"]) <= 8 and return_radius is not None and int(return_radius) >= max(6, int(p // 3)):
            label = "search_derived_false_basin"
        elif is_hard_basin(diag):
            label = "hard_basin"
        else:
            label = "unknown"
        row = {
            "canonical_hash": item["canonical_hash"],
            "source_path": item.get("source_path"),
            "origin_family": item.get("origin_family"),
            "origin_stage": item.get("origin_stage"),
            "label": label,
            "score": int(item["score"]),
            "h_min": diag.get("h_min"),
            "D_min_ratio": diag.get("D_min_ratio"),
            "P_0": diag.get("P_0"),
            "P_4": diag.get("P_4"),
            "P_8": diag.get("P_8"),
            "P_16": diag.get("P_16"),
            "kappa_max": diag.get("kappa_max"),
            "Q_ratio": diag.get("Q_ratio"),
            "InitHardness": diag.get("InitHardness"),
            "defect_pattern_signature": diag.get("defect_pattern_signature"),
            "return_radius_proxy": return_radius,
            "distance_proxy_note": "global translation plus equal-size block permutation; not exhaustive equivalence distance",
        }
        rows.append(row)
        feature_rows.append(row)
    return rows, feature_rows


def exact_joint_delta_for_block(p, block, remove_set, add_set):
    old = set(block)
    new = (old - set(remove_set)) | set(add_set)
    old_counts = [0] * int(p)
    new_counts = [0] * int(p)
    for values, counts in ((old, old_counts), (new, new_counts)):
        for x in values:
            for y in values:
                if x != y:
                    counts[(int(x) - int(y)) % int(p)] += 1
    return [int(new_counts[d] - old_counts[d]) for d in range(int(p))]


def apply_multiswap(blocks, moves):
    out = clone_blocks(blocks)
    used_remove = set()
    used_add = set()
    for move in moves:
        key_r = (int(move["block"]), int(move["removed"]))
        key_a = (int(move["block"]), int(move["added"]))
        if key_r in used_remove or key_a in used_add:
            return None
        used_remove.add(key_r)
        used_add.add(key_a)
        if not apply_swap_to_blocks(out, move):
            return None
    return out


def diagnostic_brief(blocks, counts, lam, p, baseline):
    diag = full_diagnostic(blocks, counts, lam, p, baseline)
    return {
        "h_min": diag.get("h_min"),
        "D_min_ratio": diag.get("D_min_ratio"),
        "P_4": diag.get("P_4"),
        "P_8": diag.get("P_8"),
        "P_16": diag.get("P_16"),
    }


def repair_attempt(parent, mode, p, ks, lam, baseline, rng, args):
    blocks = clone_blocks(parent["_blocks"])
    counts = list(parent["_counts"])
    score_before = score_counts(counts, lam)
    before = diagnostic_brief(blocks, counts, lam, p, baseline)
    moves = one_swap_library(blocks, counts, lam, p, max_moves=max(20, int(args.repair_library_size)))
    selected = []
    linearized_score = None
    interaction_gap = None
    if not moves:
        new_blocks = blocks
    elif mode == "exact_joint_rswap_lns":
        selected = [moves[0]]
        new_blocks = apply_multiswap(blocks, selected) or blocks
    elif mode == "negative_cross_pair_search":
        best = None
        lib = moves[: int(args.repair_library_size)]
        for i in range(len(lib)):
            for j in range(i + 1, len(lib)):
                if lib[i]["block"] == lib[j]["block"] and (
                    lib[i]["removed"] == lib[j]["removed"]
                    or lib[i]["added"] == lib[j]["added"]
                    or lib[i]["removed"] == lib[j]["added"]
                    or lib[i]["added"] == lib[j]["removed"]
                ):
                    continue
                cross = 2 * sum(int(lib[i]["delta"].get(d, 0)) * int(lib[j]["delta"].get(d, 0)) for d in set(lib[i]["delta"]) | set(lib[j]["delta"]))
                lin = int(score_before + lib[i]["h"] + lib[j]["h"] + cross)
                item = (lin, cross, i, j)
                if best is None or item < best:
                    best = item
        if best:
            linearized_score = int(best[0])
            selected = [lib[best[2]], lib[best[3]]]
        else:
            selected = [moves[0]]
        new_blocks = apply_multiswap(blocks, selected) or blocks
    elif mode == "sparse_vector_cancellation_beam":
        selected = []
        current_blocks = clone_blocks(blocks)
        current_counts = list(counts)
        for _depth in range(2):
            lib = one_swap_library(current_blocks, current_counts, lam, p, max_moves=int(args.repair_library_size))
            if not lib:
                break
            move = lib[0]
            next_counts = apply_move_to_counts(p, current_blocks, current_counts, move)
            if not apply_swap_to_blocks(current_blocks, move):
                break
            current_counts = list(next_counts)
            selected.append(move)
        new_blocks = current_blocks
    elif mode == "pair_level_partial_defect_repair":
        splits = [((0, 1), (2, 3)), ((0, 2), (1, 3)), ((0, 3), (1, 2))]
        best = None
        for left, right in splits:
            for move in moves[: int(args.repair_library_size)]:
                new_candidate = apply_multiswap(blocks, [move])
                if new_candidate is None:
                    continue
                total = total_diff_counts(p, new_candidate)
                score_after = score_counts(total, lam)
                item = (
                    int(score_after),
                    int(move["block"]),
                    int(move["removed"]),
                    int(move["added"]),
                    left,
                    right,
                    move,
                )
                if best is None or item < best:
                    best = item
        selected = [best[6]] if best else [moves[0]]
        new_blocks = apply_multiswap(blocks, selected) or blocks
    elif mode == "moment_late_repair":
        best = None
        for move in moves[: int(args.repair_library_size)]:
            candidate = apply_multiswap(blocks, [move])
            if candidate is None:
                continue
            c_counts = total_diff_counts(p, candidate)
            score_after = score_counts(c_counts, lam)
            moments = moment_payload(c_counts, lam, p)
            penalty = int(moments["low_moment_norm"] + moments["higher_moment_norm"])
            item = (
                float(score_after + 0.01 * penalty),
                int(score_after),
                int(penalty),
                int(move["block"]),
                int(move["removed"]),
                int(move["added"]),
                move,
            )
            if best is None or item < best:
                best = item
        selected = [best[6]] if best else [moves[0]]
        new_blocks = apply_multiswap(blocks, selected) or blocks
    else:
        selected = [moves[0]]
        new_blocks = apply_multiswap(blocks, selected) or blocks
    new_counts = total_diff_counts(p, new_blocks)
    score_after = score_counts(new_counts, lam)
    after = diagnostic_brief(new_blocks, new_counts, lam, p, baseline)
    if linearized_score is not None:
        interaction_gap = int(score_after - linearized_score)
    return {
        "parent_candidate_hash": parent["canonical_hash"],
        "mode": mode,
        "score_before": int(score_before),
        "score_after": int(score_after),
        "score_delta": int(score_after - score_before),
        "h_min_before": before.get("h_min"),
        "h_min_after": after.get("h_min"),
        "D_min_ratio_before": before.get("D_min_ratio"),
        "D_min_ratio_after": after.get("D_min_ratio"),
        "P_tau_before": {"P_4": before.get("P_4"), "P_8": before.get("P_8"), "P_16": before.get("P_16")},
        "P_tau_after": {"P_4": after.get("P_4"), "P_8": after.get("P_8"), "P_16": after.get("P_16")},
        "true_recomputation_score": int(score_after),
        "linearized_score": linearized_score,
        "interaction_gap": interaction_gap,
        "selected_moves": [
            {"block": int(move["block"]), "removed": int(move["removed"]), "added": int(move["added"]), "h": int(move["h"])}
            for move in selected
        ],
        "score0_success": bool(score_after == 0),
        "hook_only": True,
    }


def run_repair_hooks(candidates, p, ks, lam, baseline, args):
    eligible = [row for row in candidates if int(row.get("score", 0)) > 0]
    parents = sorted(eligible, key=lambda row: (int(row["score"]), row["canonical_hash"]))[: int(args.repair_parent_limit)]
    rows = []
    rng = random.Random(int(args.seed + 565656))
    for parent in parents:
        for mode in REPAIR_MODES:
            rows.append(repair_attempt(parent, mode, p, ks, lam, baseline, rng, args))
    summary = {
        "attempt_count": int(len(rows)),
        "parent_count": int(len(parents)),
        "modes": list(REPAIR_MODES),
        "best_score_after": min([row["score_after"] for row in rows], default=None),
        "improvement_count": int(sum(1 for row in rows if int(row["score_after"]) < int(row["score_before"]))),
        "score0_count": int(sum(1 for row in rows if row["score0_success"])),
        "note": "Lightweight hook smoke only; score=0 only is success.",
    }
    return rows, summary


def write_pipeline_design(path, p, ks, lam, exact_json):
    lines = [
        "# Small-p SDS Pipeline Design",
        "",
        "This file documents the config-driven pipeline used by `56_small_p_pipeline_framework.sage`.",
        "The p=37 target is a validation case with a known exact SDS and observed low-score false basins.",
        "",
        "## Stage 1: tuple registry / target registry",
        "",
        "- Input: `p`, `ks`, `lambda`, optional `exact_json`.",
        "- Output: `target_registry.json`.",
        "- Hypothesis: tuple choice is an upstream experimental variable, not a byproduct of best score.",
        "- Metrics: row sums, parameter equation status, known-exact availability.",
        "",
        "## Stage 2: exact validation",
        "",
        "- Input: known exact candidate JSON.",
        "- Output: `exact_validation.json`.",
        "- Hypothesis: pipeline validation should start from a verified SDS/GS baseline.",
        "- Metrics: score, l1, max defect, SDS OK, `HH^T = 4pI`.",
        "",
        "## Stage 3: initialization factory",
        "",
        "- Input: target registry, random seed, optional exact and near-hit pools.",
        "- Output: `initial_candidates.jsonl`, `initialization_summary.json`.",
        "- Families: pure random, low-energy random, score-biased random, energy-regularized, mixed-diversity, near-hit perturbation, exact perturbation.",
        "- Hypothesis: below-random score plus near-random hardness and local entropy proxies should produce better starts.",
        "- Metrics: score, E/AP, Q_tot, Q ratio, InitHardness, defect pattern, canonical hash.",
        "",
        "## Stage 4: trajectory runner",
        "",
        "- Input: target and initialization policy.",
        "- Output: `trajectory_runs.jsonl`.",
        "- Modes: score-only, escapability-aware, energy-regularized init, mixed-diversity, threshold accepting.",
        "- Hypothesis: score-only over-selects low-score false basins; return-like dynamics should separate modes.",
        "- Metrics: accepted moves, best score, final score, score0 success, hard-basin flag.",
        "",
        "## Stage 5: diagnostic engine",
        "",
        "- Input: initial candidates, trajectory bests, exact candidate, discovered low-score candidates.",
        "- Output: `diagnostic_candidates.jsonl`.",
        "- Hypothesis: h_min, D_min/S, P_tau, kappa and Q_ratio expose landscape shape better than score alone.",
        "- Metrics: score, l1, max_abs, nonzero, h_min, D_min, P thresholds, kappa quantiles, Q, E/AP, p-adic moments.",
        "",
        "## Stage 6: false-basin classifier / labeler",
        "",
        "- Input: diagnostic candidate rows and optional exact candidate.",
        "- Output: `candidate_labels.jsonl`, `false_basin_classifier_features.csv`.",
        "- Hypothesis: exact-derived and search-derived false basins differ in return radius proxy and local escapability.",
        "- Metrics: return radius proxy, D_min/S, P_tau, kappa_max, h_min, score, defect pattern.",
        "",
        "## Stage 7: repair / LNS hooks",
        "",
        "- Input: selected low-score or hard-basin diagnostic candidates.",
        "- Output: `repair_attempts.jsonl`, `repair_summary.json`.",
        "- Hooks: exact-joint r-swap LNS, negative-cross pair search, sparse vector cancellation beam, pair-level partial defect repair, moment-late repair.",
        "- Hypothesis: repair API should be uniform before heavy search is added.",
        "- Metrics: score before/after, h_min before/after, D_min before/after, P_tau, true score, linearized score, interaction gap.",
        "",
        "## Stage 8: report generator",
        "",
        "- Input: all stage outputs.",
        "- Output: `pipeline_framework_summary.md`, `comparison_summary.csv`, `comparison_summary.json`.",
        "- Hypothesis: each smoke run should explain what to run next without reading raw JSONL.",
        "",
        "## p=37 validation plan",
        "",
        "- Target: p={}, ks={}, lambda={}.".format(int(p), [int(k) for k in ks], int(lam)),
        "- Exact JSON: `{}`.".format(exact_json or ""),
        "- Run `pipeline_smoke` with 10 seeds, 1000 steps and 20 initial candidates per family.",
        "- Confirm exact SDS/GS validation and compare search-derived score4 false-basin features against exact-derived perturbations.",
        "",
        "## Returning to 668",
        "",
        "- Use this pipeline first to label tuple and candidate families by return-like dynamics.",
        "- Treat score164/176 as diagnostic near-hits, not as solution progress by itself.",
        "- Run moment-late only after score and local repair diagnostics indicate a closure-like state.",
        "- Prefer config changes over new one-off scripts.",
    ]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def comparison_rows(trajectory_summary, label_rows, repair_summary):
    rows = []
    for mode, summary in sorted(trajectory_summary.items()):
        rows.append(
            {
                "section": "trajectory",
                "name": mode,
                "run_count": summary.get("run_count"),
                "best_score": summary.get("best_score"),
                "success_score0_count": summary.get("success_score0_count"),
                "final_hard_basin_count": summary.get("final_hard_basin_count"),
                "label_count": "",
                "repair_improvement_count": "",
            }
        )
    labels = {}
    for row in label_rows:
        labels[row["label"]] = labels.get(row["label"], 0) + 1
    for label, count in sorted(labels.items()):
        rows.append(
            {
                "section": "classifier",
                "name": label,
                "run_count": "",
                "best_score": "",
                "success_score0_count": "",
                "final_hard_basin_count": "",
                "label_count": int(count),
                "repair_improvement_count": "",
            }
        )
    rows.append(
        {
            "section": "repair",
            "name": "all_hooks",
            "run_count": repair_summary.get("attempt_count"),
            "best_score": repair_summary.get("best_score_after"),
            "success_score0_count": repair_summary.get("score0_count"),
            "final_hard_basin_count": "",
            "label_count": "",
            "repair_improvement_count": repair_summary.get("improvement_count"),
        }
    )
    return rows


def write_summary(path, context):
    lines = [
        "# Small-p Pipeline Framework Summary",
        "",
        "This is a config-driven pipeline smoke run, not a Hadamard 668 construction run.",
        "",
        "## Target",
        "",
        "- p: `{}`".format(context["p"]),
        "- ks: `{}`".format(context["ks"]),
        "- lambda: `{}`".format(context["lambda"]),
        "- mode: `{}`".format(context["mode"]),
        "",
        "## Stage Outputs",
        "",
        "- Stage 1 target registry: `target_registry.json`",
        "- Stage 2 exact validation: `exact_validation.json`",
        "- Stage 3 initialization: `initial_candidates.jsonl`, `initialization_summary.json`",
        "- Stage 4 trajectories: `trajectory_runs.jsonl`",
        "- Stage 5 diagnostics: `diagnostic_candidates.jsonl`",
        "- Stage 6 labels: `candidate_labels.jsonl`, `false_basin_classifier_features.csv`",
        "- Stage 7 repair hooks: `repair_attempts.jsonl`, `repair_summary.json`",
        "- Stage 8 report: `comparison_summary.csv`, `comparison_summary.json`, this file",
        "",
        "## Results",
        "",
        "```json",
        json.dumps(json_safe(context["result_brief"]), indent=2, sort_keys=True),
        "```",
        "",
        "## Required Answers",
        "",
        "1. p=37 exact は検証済みか: `{}`.".format(bool(context["exact_validation"].get("sds_ok") and context["exact_validation"].get("hh_t_ok"))),
        "2. pipeline は config-driven に動くか: `True`; CLI args select p/ks/lambda/exact/mode/seeds/steps/out-dir.",
        "3. 各 stage の目的と出力は明確か: `True`; see `pipeline_design.md` and Stage Outputs above.",
        "4. score-only / escapability-aware / energy-regularized / mixed-diversity の比較はできたか: `{}`.".format(bool(context["trajectory_summary"])),
        "5. false basin classifier features は出たか: `{}` rows.".format(int(context["label_count"])),
        "6. repair hook は統一形式で呼べるか: `{}` attempts written.".format(int(context["repair_summary"].get("attempt_count", 0))),
        "7. 今後 p=43/47/67/167 に拡張できるか: `True`; target registry and CLI are p/tuple driven, while exact-distance labels degrade to unknown when no exact is supplied.",
        "",
        "## Interpretation",
        "",
        "- score=0 only is counted as success.",
        "- p=37 remains a validation target because exact and search-derived false basins can both be labeled.",
        "- For 668, use the same outputs to choose tuple/family/mode by return-like dynamics before heavy LNS.",
    ]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Config-driven small-p cyclic SDS pipeline framework.")
    parser.add_argument("--p", type=int, default=37)
    parser.add_argument("--ks", type=parse_ks, default=(13, 16, 18, 18))
    parser.add_argument("--lambda", dest="lam", type=int, default=28)
    parser.add_argument("--exact-json", default="outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json")
    parser.add_argument("--mode", choices=PIPELINE_MODES, default="pipeline_smoke")
    parser.add_argument("--trajectory-modes", default="score_only,escapability_aware,energy_regularized_init,mixed_diversity,threshold_accepting")
    parser.add_argument("--seeds", type=int, default=10)
    parser.add_argument("--steps", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=56037)
    parser.add_argument("--initial-per-family", type=int, default=20)
    parser.add_argument("--init-pool", type=int, default=12)
    parser.add_argument("--exact-perturb-max-r", type=int, default=4)
    parser.add_argument("--diagnostic-max-candidates", type=int, default=100)
    parser.add_argument("--candidate-samples", type=int, default=24)
    parser.add_argument("--targeted-prob", type=float, default=0.30)
    parser.add_argument("--allowed-worsen", type=int, default=8)
    parser.add_argument("--escape-temperature", type=float, default=8.0)
    parser.add_argument("--random-walk-prob", type=float, default=0.002)
    parser.add_argument("--threshold-accepting-delta", type=int, default=8)
    parser.add_argument("--repair-parent-limit", type=int, default=8)
    parser.add_argument("--repair-library-size", type=int, default=30)
    parser.add_argument("--out-dir", default=None)
    return parser.parse_args()


def stage_enabled(mode, stage):
    if mode == "design_only":
        return stage in ("design", "registry")
    if mode == "diagnose_exact":
        return stage in ("design", "registry", "exact")
    if mode == "init_smoke":
        return stage in ("design", "registry", "exact", "init", "diagnostic", "report")
    if mode == "trajectory_smoke":
        return stage in ("design", "registry", "exact", "init", "trajectory", "diagnostic", "report")
    if mode == "classifier_smoke":
        return stage in ("design", "registry", "exact", "init", "trajectory", "diagnostic", "classifier", "report")
    if mode == "repair_smoke":
        return stage in ("design", "registry", "exact", "init", "diagnostic", "classifier", "repair", "report")
    return True


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        p = int(args.p)
        ks = tuple(int(k) for k in args.ks)
        lam = int(args.lam)
        validate_params(p, ks, lam)
        out_dir = args.out_dir or os.path.join("outputs", "explorations", "{}_p{}_pipeline_framework".format(now_stamp(), p))
        ensure_dir(out_dir)
        run_config = {
            "script": SCRIPT_NAME,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "p": int(p),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "exact_json": args.exact_json,
            "mode": args.mode,
            "seeds": int(args.seeds),
            "steps": int(args.steps),
            "initial_per_family": int(args.initial_per_family),
            "diagnostic_max_candidates": int(args.diagnostic_max_candidates),
            "out_dir": out_dir,
        }
        write_json_safe(os.path.join(out_dir, "run_config.json"), run_config)
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# Run Log\n\n")
            f.write("- script: `{}`\n".format(SCRIPT_NAME))
            f.write("- mode: `{}`\n".format(args.mode))
            f.write("- p: `{}`\n".format(p))
            f.write("- ks: `{}`\n".format([int(k) for k in ks]))
            f.write("- lambda: `{}`\n".format(lam))
            f.write("- score=0 only is success\n")

        if stage_enabled(args.mode, "design"):
            write_pipeline_design(os.path.join(out_dir, "pipeline_design.md"), p, ks, lam, args.exact_json)

        registry = target_registry_payload(p, ks, lam, args.exact_json)
        write_json_safe(os.path.join(out_dir, "target_registry.json"), registry)

        exact_validation = {}
        exact_blocks = None
        if args.exact_json and os.path.exists(args.exact_json):
            _data, _v, _n, _ks, _lam, exact_blocks = load_candidate(args.exact_json)
        if stage_enabled(args.mode, "exact"):
            exact_validation = validate_exact_candidate(args.exact_json, p, ks, lam)
        else:
            exact_validation = {"has_exact_json": bool(args.exact_json), "skipped_by_mode": True}
        write_json_safe(os.path.join(out_dir, "exact_validation.json"), exact_validation)

        baseline = random_baseline_tuple(p, ks)
        initial_rows = []
        if stage_enabled(args.mode, "init"):
            initial_rows = make_initial_candidates(args, p, ks, lam, baseline, exact_blocks)
        write_jsonl(os.path.join(out_dir, "initial_candidates.jsonl"), initial_rows)
        init_summary = summarize_initialization(initial_rows)
        write_json_safe(os.path.join(out_dir, "initialization_summary.json"), init_summary)

        trajectory_rows = []
        trajectory_best_rows = []
        if stage_enabled(args.mode, "trajectory"):
            modes = parse_modes(args.trajectory_modes, TRAJECTORY_MODES)
            for mode in modes:
                rows, bests = run_trajectory_mode(mode, p, ks, lam, baseline, exact_blocks, args)
                trajectory_rows.extend(rows)
                trajectory_best_rows.extend(bests)
        write_jsonl(os.path.join(out_dir, "trajectory_runs.jsonl"), trajectory_rows)
        trajectory_summary = summarize_trajectories(trajectory_rows)

        diagnostic_sources = []
        if exact_blocks is not None:
            diagnostic_sources.append(
                candidate_record(
                    exact_blocks,
                    p,
                    ks,
                    lam,
                    baseline,
                    origin_family="known_exact",
                    origin_stage="exact_validation",
                    source_path=args.exact_json,
                    diagnose=True,
                )
            )
        diagnostic_sources.extend(initial_rows)
        diagnostic_sources.extend(trajectory_best_rows)
        for found in discover_existing_candidates(p, ks, lam, max_candidates=20, score_exact=4):
            diagnostic_sources.append(
                candidate_record(
                    found["blocks"],
                    p,
                    ks,
                    lam,
                    baseline,
                    origin_family="search_derived_score4",
                    origin_stage="existing_candidate_pool",
                    source_path=found["path"],
                    diagnose=False,
                )
            )
        diagnostic_rows = []
        seen_diag = set()
        if stage_enabled(args.mode, "diagnostic"):
            for row in sorted(diagnostic_sources, key=lambda item: (int(item["score"]), item.get("origin_family") or "", item["canonical_hash"])):
                if row["canonical_hash"] in seen_diag:
                    continue
                seen_diag.add(row["canonical_hash"])
                blocks = row["_blocks"]
                counts = row["_counts"]
                diag = row.get("diagnostic") or full_diagnostic(blocks, counts, lam, p, baseline)
                row["diagnostic"] = diag
                row["is_hard_basin"] = bool(is_hard_basin(diag))
                public = dict(public_row(row))
                public.update({key: value for key, value in diag.items() if key not in public})
                diagnostic_rows.append(public)
                if len(diagnostic_rows) >= int(args.diagnostic_max_candidates):
                    break
        write_jsonl(os.path.join(out_dir, "diagnostic_candidates.jsonl"), diagnostic_rows)

        internal_for_labels = []
        hash_to_source = {}
        for row in diagnostic_sources:
            hash_to_source[row["canonical_hash"]] = row
        for public in diagnostic_rows:
            src = hash_to_source.get(public["canonical_hash"])
            if src is not None:
                src["diagnostic"] = {key: public.get(key) for key in public.keys()}
                internal_for_labels.append(src)

        label_rows = []
        feature_rows = []
        if stage_enabled(args.mode, "classifier") and internal_for_labels:
            label_rows, feature_rows = classify_candidates(internal_for_labels, exact_blocks, p, ks, lam, baseline)
        write_jsonl(os.path.join(out_dir, "candidate_labels.jsonl"), label_rows)
        feature_fields = [
            "canonical_hash",
            "origin_family",
            "origin_stage",
            "label",
            "score",
            "h_min",
            "D_min_ratio",
            "P_0",
            "P_4",
            "P_8",
            "P_16",
            "kappa_max",
            "Q_ratio",
            "InitHardness",
            "defect_pattern_signature",
            "return_radius_proxy",
            "source_path",
        ]
        write_csv(os.path.join(out_dir, "false_basin_classifier_features.csv"), feature_rows, feature_fields)

        repair_rows = []
        repair_summary = {"attempt_count": 0, "parent_count": 0, "modes": list(REPAIR_MODES), "best_score_after": None, "improvement_count": 0, "score0_count": 0}
        if stage_enabled(args.mode, "repair") and internal_for_labels:
            repair_rows, repair_summary = run_repair_hooks(internal_for_labels, p, ks, lam, baseline, args)
        write_jsonl(os.path.join(out_dir, "repair_attempts.jsonl"), repair_rows)
        write_json_safe(os.path.join(out_dir, "repair_summary.json"), repair_summary)

        comparison = {
            "target": registry["targets"][0],
            "exact_validation": exact_validation,
            "initialization_summary": init_summary,
            "trajectory_summary": trajectory_summary,
            "label_counts": {},
            "repair_summary": repair_summary,
        }
        for row in label_rows:
            comparison["label_counts"][row["label"]] = comparison["label_counts"].get(row["label"], 0) + 1
        write_json_safe(os.path.join(out_dir, "comparison_summary.json"), comparison)
        comp_rows = comparison_rows(trajectory_summary, label_rows, repair_summary)
        write_csv(
            os.path.join(out_dir, "comparison_summary.csv"),
            comp_rows,
            ["section", "name", "run_count", "best_score", "success_score0_count", "final_hard_basin_count", "label_count", "repair_improvement_count"],
        )

        result_brief = {
            "initial_candidate_count": int(len(initial_rows)),
            "trajectory_run_count": int(len(trajectory_rows)),
            "diagnostic_candidate_count": int(len(diagnostic_rows)),
            "label_counts": comparison["label_counts"],
            "repair_attempt_count": int(repair_summary.get("attempt_count", 0)),
            "score0_reached_in_smoke": bool(any(row.get("success_score0") for row in trajectory_rows) or repair_summary.get("score0_count", 0) > 0),
        }
        write_summary(
            os.path.join(out_dir, "pipeline_framework_summary.md"),
            {
                "p": int(p),
                "ks": [int(k) for k in ks],
                "lambda": int(lam),
                "mode": args.mode,
                "exact_validation": exact_validation,
                "trajectory_summary": trajectory_summary,
                "label_count": int(len(label_rows)),
                "repair_summary": repair_summary,
                "result_brief": result_brief,
            },
        )
        print("SUMMARY:", os.path.join(out_dir, "pipeline_framework_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
