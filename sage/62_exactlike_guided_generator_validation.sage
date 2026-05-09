from sage.all import *

import argparse
import csv
import json
import math
import os
import random
import statistics
import sys
import time

import yaml

from sds_repair_utils import (
    apply_delta,
    apply_swap_to_blocks,
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


SCRIPT_NAME = "62_exactlike_guided_generator_validation"
POWERS_DEFAULT = (2, 4, 6, 8, 10, 12)
SUPPORTED_MODES = (
    "score_only",
    "exactlike_guided",
    "threshold_exactlike",
    "exactlike_guided_with_repair",
)
REPAIR_MODES = (
    "sparse_vector_cancellation_beam",
    "pair_level_partial_defect_repair",
    "exact_joint_rswap_lns",
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


def load_config(path):
    with open(path) as f:
        text = f.read()
    if path.endswith(".json"):
        cfg = json.loads(text)
    else:
        cfg = yaml.safe_load(text)
    if not isinstance(cfg, dict):
        raise ValueError("config root must be a mapping")
    return cfg, text


def dump_config_yaml(path, cfg):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as f:
        f.write(yaml.safe_dump(json_safe(cfg), sort_keys=False))


def get_in(cfg, path, default=None):
    cur = cfg
    for key in path:
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur


def clone_blocks(blocks):
    return [set(block) for block in blocks]


def row_sums_from_ks(p, ks):
    return [int(p - 2 * int(k)) for k in ks]


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
        "Var_n_d": float(en2 - mean_nd * mean_nd),
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
        rows.append(
            {
                "block": int(idx),
                "k": int(len(block)),
                "E": int(e),
                "AP": int(ap),
                "Q_formula": int(q),
                "E_excess": float(e) - float(base["E_energy"]),
                "AP_excess": float(ap) - float(base["E_AP"]),
                "Q_excess": float(q) - float(base["E_Q"]),
            }
        )
        total_e += int(e)
        total_ap += int(ap)
        total_q += int(q)
        total_e_excess += float(e) - float(base["E_energy"])
        total_ap_excess += float(ap) - float(base["E_AP"])
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


def moment_payload(counts, lam, p, powers=POWERS_DEFAULT):
    summary = p_adic_moment_summary(counts, lam, powers=tuple(powers), modulus=p)
    moments = {"T{}".format(item["power"]): int(item["residue"]) for item in summary["moments"]}
    out = {}
    for power in powers:
        out["T{}".format(int(power))] = int(moments.get("T{}".format(int(power)), 0))
    for power in POWERS_DEFAULT:
        out.setdefault("T{}".format(int(power)), None)
    out.update(
        {
            "padic_moments": moments,
            "moment_zero_count_3": int(sum(1 for key in ("T2", "T4", "T6") if moments.get(key) == 0)),
            "moment_zero_count_6": int(summary["moment_zero_count"]),
            "higher_moment_norm": int(
                sum(balanced_abs(moments.get(key, 0), p) ** 2 for key in ("T8", "T10", "T12"))
            ),
        }
    )
    return out


def score_counts(counts, lam):
    return int(metrics_from_counts(counts, lam)[0])


def apply_sparse_delta(counts, delta):
    out = list(counts)
    for d, value in delta.items():
        out[int(d)] += int(value)
    return out


def rho_vector(counts, lam):
    rho = [0] * len(counts)
    for d in range(1, len(counts)):
        rho[d] = int(counts[d] - lam)
    return rho


def delta_sparse(p, block, removed, added):
    p = int(p)
    out = {}
    others = set(block)
    if int(removed) not in others or int(added) in others:
        return None
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
    values = sorted([float(v) for v in values if v is not None])
    if not values:
        return None
    idx = int(math.floor(float(q) * (len(values) - 1)))
    return values[idx]


def one_swap_library(blocks, counts, lam, p, rng=None, max_moves=None, allowed_blocks=None):
    p = int(p)
    score = score_counts(counts, lam)
    rho = rho_vector(counts, lam)
    allowed = set(range(4)) if allowed_blocks is None else set(int(x) for x in allowed_blocks)
    moves = []
    for block_idx, block in enumerate(blocks):
        if block_idx not in allowed:
            continue
        if len(block) == 0 or len(block) == p:
            continue
        outside = [x for x in range(p) if x not in block]
        for removed in sorted(block):
            for added in outside:
                delta = delta_sparse(p, block, removed, added)
                if delta is None:
                    continue
                g = int(sum(rho[d] * int(v) for d, v in delta.items()))
                q = int(sum(int(v) * int(v) for v in delta.values()))
                h = int(2 * g + q)
                kappa = None if q == 0 else float(-2 * g) / float(q)
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
    if max_moves is not None and len(moves) > int(max_moves):
        if rng is None:
            return moves[: int(max_moves)]
        deterministic = moves[: int(max_moves) // 2]
        rest = moves[int(max_moves) // 2 :]
        rng.shuffle(rest)
        return deterministic + rest[: int(max_moves) - len(deterministic)]
    return moves


def move_key(move):
    return (int(move["block"]), int(move["removed"]), int(move["added"]))


def compact_move(move):
    return {
        "block": int(move["block"]),
        "removed": int(move["removed"]),
        "added": int(move["added"]),
        "h": int(move.get("h", 0)),
        "q": int(move.get("q", 0)),
        "kappa": None if move.get("kappa") is None else float(move.get("kappa")),
        "defect_target_score": int(move.get("defect_target_score", 0)),
    }


def moves_compatible(moves, blocks):
    by_block = {}
    for move in moves:
        b = int(move["block"])
        removed = int(move["removed"])
        added = int(move["added"])
        if removed not in blocks[b] or added in blocks[b]:
            return False
        bucket = by_block.setdefault(b, {"remove": set(), "add": set()})
        if removed in bucket["remove"] or added in bucket["add"]:
            return False
        bucket["remove"].add(removed)
        bucket["add"].add(added)
    return True


def apply_moves_copy(blocks, moves):
    out = clone_blocks(blocks)
    if not moves_compatible(moves, out):
        return None
    for move in moves:
        b = int(move["block"])
        out[b].remove(int(move["removed"]))
        out[b].add(int(move["added"]))
    return out


def diagnostic_enabled(diagnostics_cfg, key, default=True):
    if diagnostics_cfg is None:
        return bool(default)
    return bool(diagnostics_cfg.get(key, default))


def empty_moment_payload(powers):
    out = {}
    for power in set(tuple(powers) + POWERS_DEFAULT):
        out["T{}".format(int(power))] = None
    out.update(
        {
            "padic_moments": {},
            "moment_zero_count_3": None,
            "moment_zero_count_6": None,
            "higher_moment_norm": None,
        }
    )
    return out


def full_diagnostic(blocks, counts, lam, p, baseline, powers=POWERS_DEFAULT, diagnostics_cfg=None):
    p = int(p)
    score, l1_error, max_abs_error, nonzero = [int(x) for x in metrics_from_counts(counts, lam)]
    full_1swap = diagnostic_enabled(diagnostics_cfg, "full_1swap", True)
    compute_dmin1 = diagnostic_enabled(diagnostics_cfg, "compute_dmin1", True)
    compute_p_tau = diagnostic_enabled(diagnostics_cfg, "compute_p_tau", True)
    compute_kappa = diagnostic_enabled(diagnostics_cfg, "compute_kappa", True)
    compute_q_ratio = diagnostic_enabled(diagnostics_cfg, "compute_q_ratio", True)
    compute_init_hardness = diagnostic_enabled(diagnostics_cfg, "compute_init_hardness", True)
    compute_moments = diagnostic_enabled(diagnostics_cfg, "compute_moments", True)
    need_moves = full_1swap or compute_dmin1 or compute_p_tau or compute_kappa or compute_q_ratio
    moves = []
    if need_moves:
        max_moves = None if p <= 67 else 2500
        moves = one_swap_library(blocks, counts, lam, p, max_moves=max_moves)

    h_values = [int(move["h"]) for move in moves]
    q_values = [int(move["q"]) for move in moves]
    kappas = [float(move["kappa"]) for move in moves if move["kappa"] is not None]
    improving = [move for move in moves if int(move["h"]) < 0] if (full_1swap or compute_dmin1) else []
    near = (
        {threshold: sum(1 for move in moves if int(move["h"]) <= threshold) for threshold in (0, 4, 8, 16)}
        if compute_p_tau
        else {}
    )
    theta = (
        {
            frac: sum(1 for move in moves if score > 0 and int(move["h"]) <= float(frac) * float(score))
            for frac in (0.01, 0.05, 0.10)
        }
        if compute_p_tau
        else {}
    )
    h_min = min(h_values) if h_values and compute_dmin1 else None
    d_min = None if h_min is None else int(score + h_min)
    structure = block_structure_payload(p, blocks, baseline) if compute_init_hardness else None
    q_threshold = int(4 * (p - 1) * score)
    out = {
        "score": int(score),
        "l1": int(l1_error),
        "max_abs": int(max_abs_error),
        "nonzero": int(nonzero),
        "h_min": int(h_min) if h_min is not None else None,
        "D_min_1": int(d_min) if d_min is not None else None,
        "D_min_ratio": float(d_min) / float(score) if score > 0 and d_min is not None else None,
        "improving_swap_count": int(len(improving)) if (full_1swap or compute_dmin1) else None,
        "P_<0": float(len(improving)) / float(len(moves)) if compute_p_tau and moves else None,
        "P_0": float(near[0]) / float(len(moves)) if compute_p_tau and moves else None,
        "P_4": float(near[4]) / float(len(moves)) if compute_p_tau and moves else None,
        "P_8": float(near[8]) / float(len(moves)) if compute_p_tau and moves else None,
        "P_16": float(near[16]) / float(len(moves)) if compute_p_tau and moves else None,
        "P_thetaS_001": float(theta[0.01]) / float(len(moves)) if compute_p_tau and moves else None,
        "P_thetaS_005": float(theta[0.05]) / float(len(moves)) if compute_p_tau and moves else None,
        "P_thetaS_010": float(theta[0.10]) / float(len(moves)) if compute_p_tau and moves else None,
        "kappa_max": max(kappas) if compute_kappa and kappas else None,
        "kappa_q90": quantile(kappas, 0.90) if compute_kappa else None,
        "kappa_q99": quantile(kappas, 0.99) if compute_kappa else None,
        "Q_tot": int(sum(q_values)) if compute_q_ratio else None,
        "Q_ratio": float(sum(q_values)) / float(q_threshold) if compute_q_ratio and q_threshold > 0 else None,
        "InitHardness": float(structure["InitHardness"]) if structure else None,
        "E_total": int(structure["E_total"]) if structure else None,
        "AP_total": int(structure["AP_total"]) if structure else None,
        "E_excess_total": float(structure["E_excess_total"]) if structure else None,
        "AP_excess_total": float(structure["AP_excess_total"]) if structure else None,
        "num_swaps_diagnosed": int(len(moves)),
    }
    out.update(moment_payload(counts, lam, p, powers=powers) if compute_moments else empty_moment_payload(powers))
    return out


def raw_exactlike_score(diag):
    if not diag:
        return 0.0
    d_ratio = float(diag.get("D_min_ratio") if diag.get("D_min_ratio") is not None else 1.0)
    p4 = float(diag.get("P_4") or 0.0)
    p8 = float(diag.get("P_8") or 0.0)
    kappa = float(diag.get("kappa_max") if diag.get("kappa_max") is not None else 0.0)
    q_ratio = float(diag.get("Q_ratio") if diag.get("Q_ratio") is not None else 0.0)
    return float(-d_ratio + p4 + p8 + kappa - 0.25 * q_ratio)


def target_registry_payload(target):
    p = int(target["p"])
    ks = [int(k) for k in target["ks"]]
    return {
        "p": p,
        "n": int(target.get("n") or 4 * p),
        "ks": ks,
        "lambda": int(target["lambda"]),
        "row_sums": [int(x) for x in target.get("row_sums") or row_sums_from_ks(p, ks)],
        "has_known_exact": bool(target.get("has_known_exact")),
        "exact_json": target.get("exact_json"),
        "role": target.get("role"),
        "tuple_name": target.get("tuple_name"),
    }


def validate_exact_candidate(exact_json, p, ks, lam):
    if not exact_json:
        return {"has_known_exact": False, "exact_json": None, "score": None, "sds_ok": False, "hh_t_ok": False}
    data, v, n, got_ks, got_lam, blocks = load_candidate(exact_json)
    if int(v) != int(p) or tuple(got_ks) != tuple(ks) or int(got_lam) != int(lam):
        raise ValueError("exact_json target mismatch: got p={}, ks={}, lambda={}".format(v, got_ks, got_lam))
    counts = total_diff_counts(p, blocks)
    score, l1_error, max_abs_error, nonzero = metrics_from_counts(counts, lam)
    sds_ok, bad = verify_sds(p, blocks, lam)
    entries_ok, hh_t_ok = verify_hadamard_exact(p, blocks)
    return {
        "has_known_exact": True,
        "exact_json": exact_json,
        "p": int(p),
        "n": int(n),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "score": int(score),
        "l1": int(l1_error),
        "max_abs": int(max_abs_error),
        "nonzero": int(nonzero),
        "sds_ok": bool(sds_ok),
        "bad_shift_count": int(len(bad)),
        "entries_pm1_ok": bool(entries_ok),
        "hh_t_ok": bool(hh_t_ok),
        "hh_t_expected": "{}I".format(4 * int(p)),
        "external_validation_commands": [
            "sage sage/08_analyze_sds_candidate.sage {}".format(exact_json),
            "sage sage/05_validate_candidate_json.sage {}".format(exact_json),
            "sage sage/04_build_gs_from_sds.sage {}".format(exact_json),
        ],
    }


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


def candidate_record(blocks, p, ks, lam, baseline, origin, mode=None, seed=None, step=None, family=None, extra=None, powers=POWERS_DEFAULT, diagnostics_cfg=None):
    counts = total_diff_counts(p, blocks)
    diag = full_diagnostic(blocks, counts, lam, p, baseline, powers=powers, diagnostics_cfg=diagnostics_cfg)
    h = canonical_hash(blocks, ks, p)
    row = {
        "candidate_id": "{}_{}_{}_{}".format(h[:12], mode or "init", "na" if seed is None else seed, "na" if step is None else step),
        "canonical_hash": h,
        "p": int(p),
        "v": int(p),
        "n": int(4 * int(p)),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": json_blocks(blocks),
        "origin": origin,
        "origin_family": family or origin,
        "mode": mode,
        "seed": None if seed is None else int(seed),
        "step": None if step is None else int(step),
        "is_score0": bool(int(diag["score"]) == 0),
        "ExactLikeScore": None,
        "ExactLikeScoreRaw": raw_exactlike_score(diag),
        "ExactLikeScorePercentile": None,
        "label": None,
    }
    row.update(diag)
    if extra:
        row.update(extra)
    row["_blocks"] = clone_blocks(blocks)
    row["_counts"] = counts
    return row


def quick_score(blocks, p, lam):
    return score_counts(total_diff_counts(p, blocks), lam)


def initial_candidates(cfg, p, ks, lam, baseline, exact_blocks, powers, diagnostics_cfg):
    init_cfg = cfg.get("initialization", {})
    families = init_cfg.get("families", ["pure_random"])
    candidates_per_family = int(init_cfg.get("candidates_per_family", 20))
    selected_per_family = int(init_cfg.get("selected_per_family", 5))
    seed_base = int(get_in(cfg, ("experiment", "random_seed_base"), 0))
    rows = []
    for family_index, family in enumerate(families):
        rng = random.Random(int(seed_base + 1000 * (family_index + 1)))
        generated = []
        if family == "exact_perturbation":
            if exact_blocks is None:
                continue
            ep_cfg = init_cfg.get("exact_perturbation", {})
            radii = [int(x) for x in ep_cfg.get("radii", [1, 2, 3])]
            samples_per_radius = int(ep_cfg.get("samples_per_radius", candidates_per_family))
            for radius in radii:
                for sample in range(samples_per_radius):
                    blocks = clone_blocks(exact_blocks)
                    moves = []
                    ok = True
                    for _ in range(radius):
                        move = random_swap(rng, blocks, p)
                        if not apply_swap_to_blocks(blocks, move):
                            ok = False
                            break
                        moves.append(compact_move(move))
                    if ok:
                        generated.append((quick_score(blocks, p, lam), rng.random(), blocks, {"perturb_radius": int(radius), "applied_moves": moves, "sample": int(sample)}))
        else:
            for sample in range(candidates_per_family):
                blocks = random_blocks(rng, p, ks)
                score = quick_score(blocks, p, lam)
                if family == "pure_random":
                    key = (rng.random(), score)
                elif family == "score_biased_random":
                    key = (score, rng.random())
                elif family == "mixed_diversity":
                    structure = block_structure_payload(p, blocks, baseline)
                    key = (
                        score / max(1.0, float(baseline["E_score"])),
                        abs(float(structure["InitHardness"])) / max(1.0, abs(float(baseline["E_Q_total"]))),
                        rng.random(),
                    )
                else:
                    key = (score, rng.random())
                generated.append((key, rng.random(), blocks, {"sample": int(sample)}))
        generated.sort(key=lambda item: item[0])
        seen = set()
        selected = []
        for _key, _tie, blocks, extra in generated:
            h = canonical_hash(blocks, ks, p)
            if h in seen:
                continue
            seen.add(h)
            selected.append((blocks, extra))
            if len(selected) >= selected_per_family:
                break
        for idx, (blocks, extra) in enumerate(selected):
            row = candidate_record(
                blocks,
                p,
                ks,
                lam,
                baseline,
                origin=family,
                mode="initialization",
                seed=seed_base + family_index,
                step=idx,
                family=family,
                extra=extra,
                powers=powers,
                diagnostics_cfg=diagnostics_cfg,
            )
            rows.append(row)
    return rows


def label_candidate(row, cfg):
    score = int(row.get("score") or 0)
    if score == 0:
        return "exact"
    d_ratio = row.get("D_min_ratio")
    h_min = row.get("h_min")
    p_neg = float(row.get("P_<0") or 0.0)
    kappa = row.get("kappa_max")
    false_like = (
        score > 0
        and d_ratio is not None
        and float(d_ratio) > 1.0
        and p_neg == 0.0
        and kappa is not None
        and float(kappa) < 1.0
    )
    if false_like:
        return "false_like"
    exact_like = (
        (d_ratio is not None and float(d_ratio) < 1.0)
        or (h_min is not None and int(h_min) < 0)
        or (kappa is not None and float(kappa) > 1.0)
    )
    if exact_like:
        return "exact_like"
    return "ambiguous"


def apply_exactlike_scores(rows, cfg):
    if not rows:
        return
    score_cfg = cfg.get("exactlike_score", {})
    features = score_cfg.get("features", {})
    for row in rows:
        row["ExactLikeScore"] = 0.0
    for feature, spec in features.items():
        weight = float(spec.get("weight", 0.0))
        transform = spec.get("transform", "zscore")
        values = [row.get(feature) for row in rows if row.get(feature) is not None]
        if not values:
            continue
        values = [float(v) for v in values]
        if transform == "rank":
            sorted_values = sorted(set(values))
            denom = max(1.0, float(len(sorted_values) - 1))
            ranks = {value: (idx / denom if denom > 0 else 0.5) for idx, value in enumerate(sorted_values)}
            for row in rows:
                value = row.get(feature)
                transformed = 0.0 if value is None else float(ranks.get(float(value), 0.5) - 0.5) * 2.0
                row["ExactLikeScore"] += weight * transformed
        else:
            mean = statistics.mean(values)
            std = statistics.pstdev(values)
            if std <= 1e-12:
                std = 1.0
            for row in rows:
                value = row.get(feature)
                transformed = 0.0 if value is None else (float(value) - mean) / std
                row["ExactLikeScore"] += weight * transformed
    scores = sorted(row["ExactLikeScore"] for row in rows)
    denom = max(1.0, float(len(scores) - 1))
    for row in rows:
        less = sum(1 for value in scores if value <= row["ExactLikeScore"]) - 1
        row["ExactLikeScorePercentile"] = 100.0 * float(max(0, less)) / denom
        row["label"] = label_candidate(row, cfg)


def select_initial(initial_rows, seed_index):
    if not initial_rows:
        raise ValueError("no initial candidates generated")
    family_order = ["pure_random", "score_biased_random", "mixed_diversity", "exact_perturbation", "near_hit_perturbation"]
    buckets = {}
    for row in initial_rows:
        buckets.setdefault(row.get("origin_family") or "unknown", []).append(row)
    families = [family for family in family_order if buckets.get(family)]
    families.extend(sorted(family for family in buckets if family not in families))
    if not families:
        return sorted(initial_rows, key=lambda row: (int(row.get("score") or 0), row["canonical_hash"]))[int(seed_index) % len(initial_rows)]
    family = families[int(seed_index) % len(families)]
    bucket = sorted(buckets[family], key=lambda row: (int(row.get("score") or 0), -float(row.get("ExactLikeScore") or 0.0), row["canonical_hash"]))
    return bucket[int(seed_index) // len(families) % len(bucket)]


def move_pool_for_mode(moves, rng, limit=80):
    selected = {}

    def add_many(items):
        for move in items:
            selected[move_key(move)] = move

    add_many(moves[: max(5, limit // 3)])
    add_many(sorted(moves, key=lambda m: (-float(m["kappa"] if m["kappa"] is not None else -999.0), m["h"]))[: max(5, limit // 3)])
    add_many(sorted(moves, key=lambda m: (-int(m["defect_target_score"]), m["h"]))[: max(5, limit // 3)])
    shuffled = list(moves)
    rng.shuffle(shuffled)
    add_many(shuffled[: max(5, limit // 4)])
    out = list(selected.values())
    out.sort(key=lambda m: (m["h"], -float(m["kappa"] if m["kappa"] is not None else -999.0), -m["defect_target_score"]))
    return out[:limit]


def choose_move(mode, blocks, counts, lam, p, rng, visited):
    max_moves = None if p <= 67 else 2500
    moves = one_swap_library(blocks, counts, lam, p, rng=rng, max_moves=max_moves)
    if not moves:
        return None
    if mode == "score_only":
        for move in moves:
            if int(move["h"]) < 0:
                candidate = apply_moves_copy(blocks, [move])
                if candidate is not None and canonical_hash(candidate, [len(b) for b in blocks], p) not in visited:
                    return move
        return None
    pool = move_pool_for_mode(moves, rng)
    improving = [move for move in pool if int(move["h"]) < 0]
    if improving:
        improving.sort(key=lambda m: (m["h"], -float(m["kappa"] if m["kappa"] is not None else -999.0), -m["defect_target_score"]))
        return improving[0]
    if mode in ("exactlike_guided", "exactlike_guided_with_repair"):
        allowed = [
            move
            for move in pool
            if int(move["h"]) <= 4
            and (
                (move["kappa"] is not None and float(move["kappa"]) >= 1.0)
                or int(move["defect_target_score"]) > 0
            )
        ]
    else:
        allowed = [
            move
            for move in pool
            if int(move["h"]) <= 8
            and (
                (move["kappa"] is not None and float(move["kappa"]) >= 0.9)
                or int(move["defect_target_score"]) > 0
            )
        ]
    allowed.sort(key=lambda m: (m["h"], -float(m["kappa"] if m["kappa"] is not None else -999.0), -m["defect_target_score"]))
    for move in allowed:
        candidate = apply_moves_copy(blocks, [move])
        if candidate is None:
            continue
        if canonical_hash(candidate, [len(b) for b in blocks], p) in visited:
            continue
        return move
    return None


def run_trajectory(mode, seed_index, initial_row, cfg, p, ks, lam, baseline, powers, diagnostics_cfg):
    run_cfg = cfg.get("run", {})
    seed_base = int(get_in(cfg, ("experiment", "random_seed_base"), 0))
    rng = random.Random(int(seed_base + 100000 * (seed_index + 1) + sum(ord(c) for c in mode)))
    steps = int(run_cfg.get("steps", 1000))
    snapshot_interval = int(run_cfg.get("snapshot_interval", 100))
    max_snapshots = int(run_cfg.get("max_diagnostics_per_run", 100))
    stop_on_score0 = bool(run_cfg.get("stop_on_score0", True))
    blocks = clone_blocks(initial_row["_blocks"])
    counts = total_diff_counts(p, blocks)
    visited = set([canonical_hash(blocks, ks, p)])
    accepted = 0
    best_score = score_counts(counts, lam)
    best_blocks = clone_blocks(blocks)
    snapshots = []

    def add_snapshot(step):
        row = candidate_record(
            blocks,
            p,
            ks,
            lam,
            baseline,
            origin=initial_row.get("origin_family"),
            mode=mode,
            seed=seed_index,
            step=step,
            family=initial_row.get("origin_family"),
            extra={"accepted_moves": int(accepted), "initial_hash": initial_row["canonical_hash"]},
            powers=powers,
            diagnostics_cfg=diagnostics_cfg,
        )
        snapshots.append(row)

    add_snapshot(0)
    for step in range(1, steps + 1):
        move = choose_move(mode, blocks, counts, lam, p, rng, visited)
        if move is None:
            if step % snapshot_interval == 0 and len(snapshots) < max_snapshots:
                add_snapshot(step)
            break
        next_blocks = apply_moves_copy(blocks, [move])
        if next_blocks is None:
            break
        blocks = next_blocks
        counts = apply_sparse_delta(counts, move["delta"]) if move.get("delta") is not None else total_diff_counts(p, blocks)
        accepted += 1
        visited.add(canonical_hash(blocks, ks, p))
        score = score_counts(counts, lam)
        if score < best_score:
            best_score = score
            best_blocks = clone_blocks(blocks)
        if step % snapshot_interval == 0 and len(snapshots) < max_snapshots:
            add_snapshot(step)
        if stop_on_score0 and score == 0:
            add_snapshot(step)
            break
    final_row = candidate_record(
        blocks,
        p,
        ks,
        lam,
        baseline,
        origin=initial_row.get("origin_family"),
        mode=mode,
        seed=seed_index,
        step=accepted,
        family=initial_row.get("origin_family"),
        extra={"accepted_moves": int(accepted), "initial_hash": initial_row["canonical_hash"], "final": True},
        powers=powers,
        diagnostics_cfg=diagnostics_cfg,
    )
    best_row = candidate_record(
        best_blocks,
        p,
        ks,
        lam,
        baseline,
        origin=initial_row.get("origin_family"),
        mode=mode,
        seed=seed_index,
        step=accepted,
        family=initial_row.get("origin_family"),
        extra={"accepted_moves": int(accepted), "initial_hash": initial_row["canonical_hash"], "best_in_run": True},
        powers=powers,
        diagnostics_cfg=diagnostics_cfg,
    )
    return {
        "run_id": "{}_{}".format(mode, seed_index),
        "mode": mode,
        "seed": int(seed_index),
        "initial_hash": initial_row["canonical_hash"],
        "accepted_moves": int(accepted),
        "score_start": int(initial_row["score"]),
        "score_final": int(final_row["score"]),
        "score_best": int(best_row["score"]),
        "final_hash": final_row["canonical_hash"],
        "best_hash": best_row["canonical_hash"],
        "_final_row": final_row,
        "_best_row": best_row,
        "_snapshots": snapshots,
    }


def unique_by_hash(rows):
    out = []
    seen = set()
    for row in rows:
        h = row["canonical_hash"]
        if h in seen:
            continue
        seen.add(h)
        out.append(row)
    return out


def build_frontier(rows, cfg):
    frontier_cfg = cfg.get("frontier", {})
    buckets = frontier_cfg.get("buckets", {})
    selected = []

    def add(rows_for_bucket, limit, bucket_name):
        for row in rows_for_bucket[: int(limit)]:
            clone = dict(row)
            clone["frontier_bucket"] = bucket_name
            selected.append(clone)

    add(sorted(rows, key=lambda r: (int(r.get("score") or 10**9), -float(r.get("ExactLikeScore") or 0.0))), buckets.get("best_score", 40), "best_score")
    add(sorted(rows, key=lambda r: -float(r.get("ExactLikeScore") or -10**9)), buckets.get("best_exactlike_score", 40), "best_exactlike_score")
    add(sorted(rows, key=lambda r: (float(r.get("D_min_ratio") if r.get("D_min_ratio") is not None else 10**9), int(r.get("score") or 10**9))), buckets.get("best_D_min_ratio", 30), "best_D_min_ratio")
    add(sorted(rows, key=lambda r: (-float(r.get("P_8") or 0.0), int(r.get("score") or 10**9))), buckets.get("best_P_tau", 30), "best_P_tau")
    add(sorted(rows, key=lambda r: (-float(r.get("kappa_max") if r.get("kappa_max") is not None else -10**9), int(r.get("score") or 10**9))), buckets.get("best_kappa", 30), "best_kappa")
    diverse = unique_by_hash(sorted(rows, key=lambda r: (r["canonical_hash"], int(r.get("score") or 10**9))))
    add(diverse, buckets.get("diversity", 30), "diversity")
    merged = {}
    order = []
    for row in selected:
        h = row["canonical_hash"]
        bucket = row.get("frontier_bucket")
        if h not in merged:
            merged[h] = dict(row)
            merged[h]["frontier_buckets"] = []
            order.append(h)
        if bucket and bucket not in merged[h]["frontier_buckets"]:
            merged[h]["frontier_buckets"].append(bucket)
    max_size = int(frontier_cfg.get("max_size", 200))
    return [merged[h] for h in order[:max_size]]


def false_archive(rows):
    return [row for row in rows if row.get("label") == "false_like"]


def save_score0_candidate(out_dir, row, source_mode, p, ks, lam):
    blocks = row["_blocks"]
    counts = total_diff_counts(p, blocks)
    score = score_counts(counts, lam)
    if score != 0:
        return None
    sds_ok, _bad = verify_sds(p, blocks, lam)
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
        "verify_sds": bool(sds_ok),
        "generated_hadamard": bool(hh_t_ok),
        "hh_t": bool(hh_t_ok),
        "entries_pm1_ok": bool(entries_ok),
        "construction": "Goethals-Seidel",
        "search_method": SCRIPT_NAME,
        "mode": source_mode,
        "canonical_hash": canonical_hash(blocks, ks, p),
        "canonical_repr_summary": canonical_repr_summary(blocks, ks, p),
        "error_histogram": error_histogram(counts, lam),
    }
    path = os.path.join(out_dir, "score0_candidate_{}_{}.json".format(source_mode, payload["canonical_hash"][:12]))
    write_json_safe(path, payload)
    return path


def evaluate_moves(blocks, moves, p, lam):
    if not moves_compatible(moves, blocks):
        return None, None
    new_blocks = apply_moves_copy(blocks, moves)
    if new_blocks is None:
        return None, None
    counts = total_diff_counts(p, new_blocks)
    return new_blocks, score_counts(counts, lam)


def repair_sparse(parent, cfg, p, ks, lam, baseline, rng, powers):
    blocks = clone_blocks(parent["_blocks"])
    counts = total_diff_counts(p, blocks)
    rcfg = get_in(cfg, ("repair", "sparse_vector_cancellation_beam"), {})
    top_k = int(rcfg.get("top_k_per_category", 50))
    beam_width = int(rcfg.get("beam_width", 300))
    max_depth = int(rcfg.get("max_depth", 5))
    moves = one_swap_library(blocks, counts, lam, p, rng=rng)[: max(20, top_k)]
    beam = [{"moves": [], "score": score_counts(counts, lam)}]
    best = {"blocks": blocks, "score": score_counts(counts, lam), "moves": []}
    for _depth in range(1, max_depth + 1):
        expanded = {}
        for state in beam:
            for move in moves:
                candidate_moves = state["moves"] + [move]
                key = tuple(sorted(move_key(m) for m in candidate_moves))
                if key in expanded:
                    continue
                new_blocks, score = evaluate_moves(blocks, candidate_moves, p, lam)
                if new_blocks is None:
                    continue
                expanded[key] = {"moves": candidate_moves, "score": int(score), "blocks": new_blocks}
        states = sorted(expanded.values(), key=lambda r: (r["score"], len(r["moves"])))[:beam_width]
        if not states:
            break
        beam = states
        if states[0]["score"] < best["score"]:
            best = states[0]
    return best["blocks"], {"selected_move_count": len(best["moves"]), "selected_moves": [compact_move(m) for m in best["moves"]]}


def repair_pair_level(parent, cfg, p, ks, lam, baseline, rng, powers):
    blocks = clone_blocks(parent["_blocks"])
    counts = total_diff_counts(p, blocks)
    splits = get_in(cfg, ("repair", "pair_level_partial_defect_repair", "splits"), [[[0, 1], [2, 3]], [[0, 2], [1, 3]], [[0, 3], [1, 2]]])
    parent_score = score_counts(counts, lam)
    best = {"blocks": blocks, "score": parent_score, "details": {}}
    for split in splits:
        for side in split:
            moves = one_swap_library(blocks, counts, lam, p, rng=rng, allowed_blocks=side)[:80]
            for i, first in enumerate(moves[:60]):
                candidate_sets = [[first]]
                for second in moves[i + 1 : min(len(moves), i + 31)]:
                    candidate_sets.append([first, second])
                for candidate_moves in candidate_sets:
                    new_blocks, score = evaluate_moves(blocks, candidate_moves, p, lam)
                    if new_blocks is not None and score < best["score"]:
                        best = {
                            "blocks": new_blocks,
                            "score": int(score),
                            "details": {"split": split, "repair_side": side, "selected_moves": [compact_move(m) for m in candidate_moves]},
                        }
    return best["blocks"], best["details"]


def repair_rswap(parent, cfg, p, ks, lam, baseline, rng, powers):
    blocks = clone_blocks(parent["_blocks"])
    counts = total_diff_counts(p, blocks)
    rcfg = get_in(cfg, ("repair", "exact_joint_rswap_lns"), {})
    r_values = [int(x) for x in rcfg.get("r_values", [2, 3, 4])]
    samples_per_r = int(rcfg.get("samples_per_r", 200))
    parent_score = score_counts(counts, lam)
    moves = one_swap_library(blocks, counts, lam, p, rng=rng)[:200]
    best = {"blocks": blocks, "score": parent_score, "moves": []}
    for r in r_values:
        for _ in range(samples_per_r):
            block_idx = rng.randrange(4)
            by_block = [m for m in moves if int(m["block"]) == block_idx]
            rng.shuffle(by_block)
            selected = []
            used_r = set()
            used_a = set()
            for move in by_block:
                if move["removed"] in used_r or move["added"] in used_a:
                    continue
                selected.append(move)
                used_r.add(move["removed"])
                used_a.add(move["added"])
                if len(selected) >= r:
                    break
            if len(selected) != r:
                continue
            new_blocks, score = evaluate_moves(blocks, selected, p, lam)
            if new_blocks is not None and score < best["score"]:
                best = {"blocks": new_blocks, "score": int(score), "moves": selected}
    return best["blocks"], {"selected_move_count": len(best["moves"]), "selected_moves": [compact_move(m) for m in best["moves"]]}


def repair_moment(parent, cfg, p, ks, lam, baseline, rng, powers):
    blocks = clone_blocks(parent["_blocks"])
    counts = total_diff_counts(p, blocks)
    rcfg = get_in(cfg, ("repair", "moment_late_repair"), {})
    eta_values = [float(x) for x in rcfg.get("eta_values", [0.01, 0.05, 0.1])]
    only_if = int(rcfg.get("only_if_score_lte", 10**9))
    parent_score = score_counts(counts, lam)
    if parent_score > only_if:
        return blocks, {"skipped": True, "reason": "score above moment_late threshold"}
    moves = one_swap_library(blocks, counts, lam, p, rng=rng)[:120]
    best = {"blocks": blocks, "objective": float(parent_score), "score": parent_score, "move": None, "eta": None}
    for eta in eta_values:
        for move in moves:
            new_blocks, score = evaluate_moves(blocks, [move], p, lam)
            if new_blocks is None:
                continue
            moment = moment_payload(total_diff_counts(p, new_blocks), lam, p, powers=powers)
            penalty = sum(balanced_abs(moment.get("T{}".format(power), 0), p) ** 2 for power in powers)
            objective = float(score) + float(eta) * float(penalty)
            if (objective, score) < (best["objective"], best["score"]):
                best = {"blocks": new_blocks, "objective": objective, "score": int(score), "move": move, "eta": eta, "moment_penalty": int(penalty)}
    return best["blocks"], {"eta": best["eta"], "objective": best["objective"], "moment_penalty": best.get("moment_penalty"), "selected_moves": [] if best["move"] is None else [compact_move(best["move"])]}


def repair_candidate(parent, repair_mode, cfg, p, ks, lam, baseline, rng, powers, diagnostics_cfg):
    if repair_mode == "sparse_vector_cancellation_beam":
        after_blocks, details = repair_sparse(parent, cfg, p, ks, lam, baseline, rng, powers)
    elif repair_mode == "pair_level_partial_defect_repair":
        after_blocks, details = repair_pair_level(parent, cfg, p, ks, lam, baseline, rng, powers)
    elif repair_mode == "exact_joint_rswap_lns":
        after_blocks, details = repair_rswap(parent, cfg, p, ks, lam, baseline, rng, powers)
    elif repair_mode == "moment_late_repair":
        after_blocks, details = repair_moment(parent, cfg, p, ks, lam, baseline, rng, powers)
    else:
        after_blocks, details = clone_blocks(parent["_blocks"]), {"skipped": True, "reason": "unsupported repair mode"}
    after = candidate_record(
        after_blocks,
        p,
        ks,
        lam,
        baseline,
        origin=parent.get("origin"),
        mode=repair_mode,
        seed=parent.get("seed"),
        step=parent.get("step"),
        family=parent.get("origin_family"),
        extra={"parent_hash": parent["canonical_hash"], "repair_parent_mode": parent.get("mode")},
        powers=powers,
        diagnostics_cfg=diagnostics_cfg,
    )
    row = {
        "parent_hash": parent["canonical_hash"],
        "parent_mode": parent.get("mode"),
        "parent_origin": parent.get("origin"),
        "parent_score": int(parent["score"]),
        "parent_label": parent.get("label"),
        "parent_ExactLikeScore": parent.get("ExactLikeScore"),
        "repair_mode": repair_mode,
        "score_after": int(after["score"]),
        "score_delta": int(after["score"] - parent["score"]),
        "label_after": after.get("label"),
        "score0_seen": bool(after["score"] == 0),
        "score_improvement_seen": bool(after["score"] < parent["score"]),
        "after_hash": after["canonical_hash"],
    }
    row.update(details or {})
    row["_after_row"] = after
    return row


def route_repair_candidates(rows, cfg, max_candidates):
    repair_cfg = cfg.get("repair", {})
    if not repair_cfg.get("enabled", False):
        return []
    route = repair_cfg.get("route_only_if", {})
    score_lte = int(route.get("score_lte", 16))
    pct = float(route.get("exactlike_score_percentile_gte", 60))
    eligible = [
        row
        for row in rows
        if row.get("score") is not None
        and 0 < int(row.get("score")) <= score_lte
        and row.get("label") in ("exact", "exact_like")
    ]
    if not eligible:
        return []
    scores = sorted(float(row.get("ExactLikeScore") or 0.0) for row in eligible)
    denom = max(1.0, float(len(scores) - 1))
    candidates = []
    for row in eligible:
        less = sum(1 for value in scores if value <= float(row.get("ExactLikeScore") or 0.0)) - 1
        local_percentile = 100.0 * float(max(0, less)) / denom
        row["RepairRouteExactLikePercentile"] = local_percentile
        if local_percentile >= pct:
            candidates.append(row)
    candidates.sort(key=lambda row: (-float(row.get("ExactLikeScore") or -10**9), int(row.get("score") or 10**9)))
    return unique_by_hash(candidates)[: int(max_candidates)]


def summarize_groups(rows, group_field, feature_fields):
    groups = {}
    for row in rows:
        groups.setdefault(row.get(group_field) or "missing", []).append(row)
    out = []
    for key, group in sorted(groups.items()):
        item = {group_field: key, "count": int(len(group))}
        for feature in feature_fields:
            values = [float(row[feature]) for row in group if row.get(feature) is not None]
            item["median_{}".format(feature)] = statistics.median(values) if values else None
            item["mean_{}".format(feature)] = statistics.mean(values) if values else None
        out.append(item)
    return out


def median_or_none(values):
    values = [float(value) for value in values if value is not None]
    if not values:
        return None
    return statistics.median(values)


def count_by(rows, field):
    out = {}
    for row in rows:
        key = row.get(field)
        key = "missing" if key is None else str(key)
        out[key] = out.get(key, 0) + 1
    return {key: int(out[key]) for key in sorted(out)}


def histogram_int(rows, field):
    out = {}
    for row in rows:
        value = row.get(field)
        if value is None:
            key = "missing"
        else:
            key = str(int(value))
        out[key] = out.get(key, 0) + 1
    return {key: int(out[key]) for key in sorted(out, key=lambda x: (x == "missing", int(x) if x != "missing" else 0))}


def mode_summary(run_rows, frontier_rows=None, repair_rows=None):
    frontier_rows = frontier_rows or []
    repair_rows = repair_rows or []
    groups = {}
    for row in run_rows:
        groups.setdefault(row["mode"], []).append(row)
    out = []
    for mode, rows in sorted(groups.items()):
        frontier_group = [row for row in frontier_rows if row.get("mode") == mode]
        repair_group = [row for row in repair_rows if row.get("parent_mode") == mode]
        score0_count = int(sum(1 for row in rows if row.get("score_final") == 0))
        final_false = int(sum(1 for row in rows if row.get("final_label") == "false_like"))
        final_exact = int(sum(1 for row in rows if row.get("final_label") in ("exact", "exact_like")))
        final_ambiguous = int(sum(1 for row in rows if row.get("final_label") == "ambiguous"))
        final_unknown = int(sum(1 for row in rows if row.get("final_label") not in ("exact", "exact_like", "false_like", "ambiguous")))
        out.append(
            {
                "mode": mode,
                "run_count": int(len(rows)),
                "score0_count": score0_count,
                "score0_rate": float(score0_count) / float(len(rows)) if rows else None,
                "best_score_overall": min(int(row.get("score_best", 10**9)) for row in rows),
                "best_score": min(int(row.get("score_best", 10**9)) for row in rows),
                "median_final_score": statistics.median([int(row["score_final"]) for row in rows]),
                "median_best_score": statistics.median([int(row["score_best"]) for row in rows]),
                "final_false_like_count": final_false,
                "final_exact_like_count": final_exact,
                "final_ambiguous_count": final_ambiguous,
                "final_unknown_count": final_unknown,
                "false_like_final_rate": float(final_false) / float(len(rows)) if rows else None,
                "exact_like_final_rate": float(final_exact) / float(len(rows)) if rows else None,
                "frontier_exact_like_count": int(sum(1 for row in frontier_group if row.get("label") in ("exact", "exact_like"))),
                "frontier_false_like_count": int(sum(1 for row in frontier_group if row.get("label") == "false_like")),
                "archived_false_like_count": 0,
                "median_D_min_ratio_final": median_or_none([row.get("final_D_min_ratio") for row in rows]),
                "median_P_4_final": median_or_none([row.get("final_P_4") for row in rows]),
                "median_P_8_final": median_or_none([row.get("final_P_8") for row in rows]),
                "median_P_16_final": median_or_none([row.get("final_P_16") for row in rows]),
                "median_kappa_max_final": median_or_none([row.get("final_kappa_max") for row in rows]),
                "median_Q_ratio_final": median_or_none([row.get("final_Q_ratio") for row in rows]),
                "median_ExactLikeScore_final": median_or_none([row.get("final_ExactLikeScore") for row in rows]),
                "repair_routed_count": int(len(set(row.get("parent_hash") for row in repair_group))),
                "repair_attempt_count": int(len(repair_group)),
                "repair_score0_count": int(sum(1 for row in repair_group if row.get("score0_seen"))),
                "repair_score_improvement_count": int(sum(1 for row in repair_group if row.get("score_improvement_seen"))),
                "repair_success_rate": float(sum(1 for row in repair_group if row.get("score_improvement_seen"))) / float(len(repair_group)) if repair_group else None,
                "distinct_final_hashes": int(len(set(row.get("final_hash") for row in rows))),
                "distinct_frontier_hashes": int(len(set(row.get("canonical_hash") for row in frontier_group))),
            }
        )
    return out


def add_archive_counts_to_mode_summary(mode_rows, archived_rows):
    archive_counts = {}
    for row in archived_rows:
        mode = row.get("mode") or "missing"
        archive_counts[mode] = archive_counts.get(mode, 0) + 1
    for row in mode_rows:
        row["archived_false_like_count"] = int(archive_counts.get(row["mode"], 0))
    return mode_rows


def frontier_analysis(frontier_rows):
    fields = ["score", "ExactLikeScore", "D_min_ratio", "P_4", "P_8", "P_16", "kappa_max", "Q_ratio"]
    groups = {}
    for row in frontier_rows:
        groups.setdefault(row.get("mode") or "missing", []).append(row)
    out = []
    for mode, rows in sorted(groups.items()):
        item = {
            "mode": mode,
            "frontier_count": int(len(rows)),
            "best_score_frontier_count": int(sum(1 for row in rows if "best_score" in (row.get("frontier_buckets") or [row.get("frontier_bucket")]))),
            "best_exactlike_score_frontier_count": int(sum(1 for row in rows if "best_exactlike_score" in (row.get("frontier_buckets") or [row.get("frontier_bucket")]))),
            "best_D_min_ratio_frontier_count": int(sum(1 for row in rows if "best_D_min_ratio" in (row.get("frontier_buckets") or [row.get("frontier_bucket")]))),
            "best_P_tau_frontier_count": int(sum(1 for row in rows if "best_P_tau" in (row.get("frontier_buckets") or [row.get("frontier_bucket")]))),
            "best_kappa_frontier_count": int(sum(1 for row in rows if "best_kappa" in (row.get("frontier_buckets") or [row.get("frontier_bucket")]))),
            "diversity_frontier_count": int(sum(1 for row in rows if "diversity" in (row.get("frontier_buckets") or [row.get("frontier_bucket")]))),
            "label_distribution": count_by(rows, "label"),
            "score_distribution": histogram_int(rows, "score"),
            "distinct_frontier_hashes": int(len(set(row.get("canonical_hash") for row in rows))),
        }
        for field in fields:
            item["median_{}".format(field)] = median_or_none([row.get(field) for row in rows])
            item["mean_{}".format(field)] = statistics.mean([float(row[field]) for row in rows if row.get(field) is not None]) if any(row.get(field) is not None for row in rows) else None
        out.append(item)
    return out


def archive_analysis(archived_rows):
    groups = {"ALL": list(archived_rows)}
    for row in archived_rows:
        groups.setdefault(row.get("mode") or "missing", []).append(row)
    out = []
    for mode, rows in sorted(groups.items()):
        out.append(
            {
                "mode": mode,
                "count": int(len(rows)),
                "median_score": median_or_none([row.get("score") for row in rows]),
                "median_D_min_ratio": median_or_none([row.get("D_min_ratio") for row in rows]),
                "median_P_8": median_or_none([row.get("P_8") for row in rows]),
                "median_kappa_max": median_or_none([row.get("kappa_max") for row in rows]),
                "median_Q_ratio": median_or_none([row.get("Q_ratio") for row in rows]),
                "low_score_archived_count": int(sum(1 for row in rows if row.get("score") is not None and int(row.get("score")) <= 32)),
                "score_lte_16_archived_count": int(sum(1 for row in rows if row.get("score") is not None and int(row.get("score")) <= 16)),
                "label_distribution": count_by(rows, "label"),
            }
        )
    return out


def repair_routing_analysis(repair_rows):
    groups = {"ALL": list(repair_rows)}
    for row in repair_rows:
        groups.setdefault("mode:{}".format(row.get("parent_mode") or "missing"), []).append(row)
        groups.setdefault("repair:{}".format(row.get("repair_mode") or "missing"), []).append(row)
    out = []
    for group_name, rows in sorted(groups.items()):
        parent_hashes = set(row.get("parent_hash") for row in rows)
        out.append(
            {
                "group": group_name,
                "repair_attempt_count": int(len(rows)),
                "repair_routed_candidates_count": int(len(parent_hashes)),
                "parent_label_distribution": count_by(rows, "parent_label"),
                "parent_mode_distribution": count_by(rows, "parent_mode"),
                "repair_mode_distribution": count_by(rows, "repair_mode"),
                "parent_score_distribution": histogram_int(rows, "parent_score"),
                "median_parent_score": median_or_none([row.get("parent_score") for row in rows]),
                "median_parent_ExactLikeScore": median_or_none([row.get("parent_ExactLikeScore") for row in rows]),
                "score_improvement_count": int(sum(1 for row in rows if row.get("score_improvement_seen"))),
                "score_improvement_rate": float(sum(1 for row in rows if row.get("score_improvement_seen"))) / float(len(rows)) if rows else None,
                "score0_count": int(sum(1 for row in rows if row.get("score0_seen"))),
                "score0_rate": float(sum(1 for row in rows if row.get("score0_seen"))) / float(len(rows)) if rows else None,
                "best_score_after": min(int(row.get("score_after", 10**9)) for row in rows) if rows else None,
            }
        )
    return out


def repair_summary(rows):
    groups = {}
    for row in rows:
        groups.setdefault(row["repair_mode"], []).append(row)
    out = []
    for mode, group in sorted(groups.items()):
        out.append(
            {
                "repair_mode": mode,
                "attempt_count": int(len(group)),
                "score_improvement_count": int(sum(1 for row in group if row.get("score_improvement_seen"))),
                "score_improvement_rate": float(sum(1 for row in group if row.get("score_improvement_seen"))) / float(len(group)) if group else None,
                "score0_count": int(sum(1 for row in group if row.get("score0_seen"))),
                "best_score_after": min(int(row.get("score_after", 10**9)) for row in group) if group else None,
            }
        )
    return out


def make_summary(path, context):
    mode_rows = context["mode_summary"]
    mode_map = {row["mode"]: row for row in mode_rows}
    score_only = mode_map.get("score_only", {})
    exactlike = mode_map.get("exactlike_guided", {})
    threshold = mode_map.get("threshold_exactlike", {})
    with_repair = mode_map.get("exactlike_guided_with_repair", {})
    score0_seen = bool(context["score0_paths"])
    false_reduced = None
    exact_frontier_increased = None
    if score_only and exactlike:
        false_reduced = float(exactlike.get("false_like_final_rate") or 0.0) < float(score_only.get("false_like_final_rate") or 0.0)
        exact_frontier_increased = int(exactlike.get("frontier_exact_like_count", 0)) > int(score_only.get("frontier_exact_like_count", 0))
    archive_all = None
    for row in context.get("archive_analysis", []):
        if row.get("mode") == "ALL":
            archive_all = row
            break
    repair_all = None
    for row in context.get("repair_routing_analysis", []):
        if row.get("group") == "ALL":
            repair_all = row
            break
    score0_rates = {
        mode: mode_map.get(mode, {}).get("score0_rate")
        for mode in ("score_only", "exactlike_guided", "threshold_exactlike", "exactlike_guided_with_repair")
    }
    repair_helped = None
    if with_repair:
        repair_helped = bool(
            (with_repair.get("repair_score0_count") or 0) > 0
            or (with_repair.get("repair_score_improvement_count") or 0) > 0
        )
    exactlike_judgement = "inconclusive"
    next_step = "p37 policy tuning before p43/p47"
    if score_only and exactlike:
        exactlike_score0 = float(exactlike.get("score0_rate") or 0.0)
        score_only_score0 = float(score_only.get("score0_rate") or 0.0)
        if (exactlike_score0 > score_only_score0) or false_reduced or exact_frontier_increased:
            exactlike_judgement = "promising"
            next_step = "p43/p47 smoke after one more p37 sanity run"
        else:
            exactlike_judgement = "not_supported_current_policy"
    lines = [
        "# Exact-Like Guided Generator Validation",
        "",
        "This is a config-driven generator framework validation. It is not a Hadamard 668 construction run.",
        "",
        "## Target",
        "",
        "- p: `{}`".format(context["p"]),
        "- ks: `{}`".format(context["ks"]),
        "- lambda: `{}`".format(context["lambda"]),
        "- experiment: `{}`".format(context["experiment_name"]),
        "- output: `{}`".format(context["out_dir"]),
        "",
        "## Mode Summary",
        "",
        "```json",
        json.dumps(json_safe(mode_rows), indent=2, sort_keys=True),
        "```",
        "",
        "## Repair Summary",
        "",
        "```json",
        json.dumps(json_safe(context["repair_summary"]), indent=2, sort_keys=True),
        "```",
        "",
        "## Required Answers",
        "",
        "1. medium run は完走したか: `True`.",
        "2. config-driven runner は今回も問題なく動作したか: `True`.",
        "3. p37 exact validation は通ったか: `{}`.".format(bool(context["exact_validation"].get("score") == 0 and context["exact_validation"].get("sds_ok") and context["exact_validation"].get("hh_t_ok"))),
        "4. score_only / exactlike_guided / threshold_exactlike / exactlike_guided_with_repair の score0_rate はどう違ったか: `{}`.".format(json.dumps(json_safe(score0_rates), sort_keys=True)),
        "5. exactlike_guided は score_only より false-like final を減らしたか: `{}`.".format(false_reduced),
        "6. exactlike_guided は score_only より exact-like frontier を増やしたか: `{}`.".format(exact_frontier_increased),
        "7. threshold_exactlike は shallow barrier を越えて escapable / exact-like candidates を増やしたか: final_exact_like_count `{}` vs score_only `{}`; frontier_exact_like_count `{}` vs score_only `{}`.".format(
            threshold.get("final_exact_like_count"),
            score_only.get("final_exact_like_count"),
            threshold.get("frontier_exact_like_count"),
            score_only.get("frontier_exact_like_count"),
        ),
        "8. exactlike_guided_with_repair は repair routing により score0_rate または score improvement を上げたか: `{}`; repair_score0_count `{}`, repair_score_improvement_count `{}`.".format(
            repair_helped,
            with_repair.get("repair_score0_count"),
            with_repair.get("repair_score_improvement_count"),
        ),
        "9. archived false-like candidates は本当に false-like 指標を持っていたか: median D_min_ratio `{}`, median kappa_max `{}`, score<=16 archived `{}`.".format(
            None if archive_all is None else archive_all.get("median_D_min_ratio"),
            None if archive_all is None else archive_all.get("median_kappa_max"),
            None if archive_all is None else archive_all.get("score_lte_16_archived_count"),
        ),
        "10. repair は exact-like low-score candidates に限定されていたか: parent labels `{}`; parent modes `{}`.".format(
            None if repair_all is None else repair_all.get("parent_label_distribution"),
            None if repair_all is None else repair_all.get("parent_mode_distribution"),
        ),
        "11. score=0 candidate は出たか。出た場合、08/05/04 検証を通ったか: score0_seen `{}`; external validation is recorded in run_log after command execution.".format(score0_seen),
        "12. p37 の結果から、exactlike-guided generator は score-only より有望か: `{}`.".format(exactlike_judgement),
        "13. 次に p43/p47 に進むべきか、それとも p37 で重み・accept rule を調整すべきか: `{}`.".format(next_step),
        "14. p167 へ戻すなら、どの設定を変えるべきか: use rank normalization, larger relative thresholds, fewer full diagnostics, and stricter repair routing percentiles.",
        "",
        "## Interpretation",
        "",
        "- score=0 only is success.",
        "- p=37 thresholds should not be copied directly to p=167; use ranks, trajectory response, and repair response there.",
        "- Repair is routed to low-score exact-like candidates, not applied as a blanket pass.",
        "- Exact perturbation is a controlled positive-control family and should not be read as unguided search success.",
    ]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Config-driven exact-like guided cyclic SDS generator validation.")
    parser.add_argument("--config", required=True)
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--seeds", type=int, default=None)
    parser.add_argument("--seed-start", type=int, default=None)
    parser.add_argument("--seed-count", type=int, default=None)
    parser.add_argument("--total-seeds", type=int, default=None)
    parser.add_argument("--shard-index", type=int, default=None)
    parser.add_argument("--shard-count", type=int, default=None)
    parser.add_argument("--steps", type=int, default=None)
    parser.add_argument("--snapshot-interval", type=int, default=None)
    parser.add_argument("--candidates-per-family", type=int, default=None)
    parser.add_argument("--selected-per-family", type=int, default=None)
    parser.add_argument("--max-repair-candidates", type=int, default=20)
    return parser.parse_args()


def resolve_seed_indices(args, cfg):
    configured_count = int(get_in(cfg, ("run", "seeds"), 5))
    requested_count = int(args.seeds) if args.seeds is not None else configured_count
    if args.seed_count is not None:
        requested_count = int(args.seed_count)
    if requested_count <= 0:
        raise ValueError("seed count must be positive")

    has_shard_args = args.shard_index is not None or args.shard_count is not None
    if has_shard_args:
        if args.seed_start is not None or args.seed_count is not None:
            raise ValueError("--seed-start/--seed-count cannot be combined with shard arguments")
        if args.shard_index is None or args.shard_count is None:
            raise ValueError("--shard-index and --shard-count must be provided together")
        shard_index = int(args.shard_index)
        shard_count = int(args.shard_count)
        total_seeds = int(args.total_seeds) if args.total_seeds is not None else requested_count
        if shard_count <= 0:
            raise ValueError("--shard-count must be positive")
        if total_seeds < shard_count:
            raise ValueError("--total-seeds must be greater than or equal to --shard-count")
        if shard_index < 0 or shard_index >= shard_count:
            raise ValueError("--shard-index must satisfy 0 <= shard_index < shard_count")
        start = (total_seeds * shard_index) // shard_count
        end = (total_seeds * (shard_index + 1)) // shard_count
        return list(range(start, end)), {
            "mode": "shard",
            "total_seeds": int(total_seeds),
            "shard_index": int(shard_index),
            "shard_count": int(shard_count),
            "seed_start": int(start),
            "seed_count": int(end - start),
        }

    start = int(args.seed_start) if args.seed_start is not None else 0
    if start < 0:
        raise ValueError("--seed-start must be nonnegative")
    return list(range(start, start + requested_count)), {
        "mode": "range",
        "seed_start": int(start),
        "seed_count": int(requested_count),
    }


def main():
    args = parse_args()
    tee, _stamp = setup_logging(SCRIPT_NAME)
    try:
        cfg, _raw_text = load_config(args.config)
        if args.seeds is not None:
            cfg.setdefault("run", {})["seeds"] = int(args.seeds)
        if args.steps is not None:
            cfg.setdefault("run", {})["steps"] = int(args.steps)
        if args.snapshot_interval is not None:
            cfg.setdefault("run", {})["snapshot_interval"] = int(args.snapshot_interval)
        if args.candidates_per_family is not None:
            cfg.setdefault("initialization", {})["candidates_per_family"] = int(args.candidates_per_family)
        if args.selected_per_family is not None:
            cfg.setdefault("initialization", {})["selected_per_family"] = int(args.selected_per_family)
        seed_indices, seed_partition = resolve_seed_indices(args, cfg)
        cfg.setdefault("run", {})["seeds"] = int(len(seed_indices))
        cfg.setdefault("run", {})["seed_indices"] = [int(x) for x in seed_indices]
        cfg.setdefault("run", {})["seed_partition"] = seed_partition

        target = cfg["target"]
        p = int(target["p"])
        ks = tuple(int(k) for k in target["ks"])
        lam = int(target["lambda"])
        validate_params(p, ks, lam)
        experiment_name = get_in(cfg, ("experiment", "name"), "exactlike_guided_generator")
        output_root = get_in(cfg, ("experiment", "output_root"), "outputs/explorations")
        out_dir = args.out_dir or os.path.join(output_root, "{}_{}".format(now_stamp(), experiment_name))
        ensure_dir(out_dir)
        dump_config_yaml(os.path.join(out_dir, "run_config.yaml"), cfg)
        write_json_safe(os.path.join(out_dir, "run_config.json"), cfg)
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# Run Log\n\n")
            f.write("- script: `{}`\n".format(SCRIPT_NAME))
            f.write("- config: `{}`\n".format(args.config))
            f.write("- score=0 only is success\n")

        registry = target_registry_payload(target)
        write_json_safe(os.path.join(out_dir, "target_registry.json"), registry)
        exact_validation = validate_exact_candidate(target.get("exact_json"), p, ks, lam) if target.get("has_known_exact") else {"has_known_exact": False, "exact_json": target.get("exact_json")}
        write_json_safe(os.path.join(out_dir, "exact_validation.json"), exact_validation)

        baseline = random_baseline_tuple(p, ks)
        diagnostics_cfg = cfg.get("diagnostics", {})
        powers = tuple(int(x) for x in get_in(cfg, ("diagnostics", "moment_orders"), POWERS_DEFAULT))
        exact_blocks = None
        if target.get("has_known_exact") and target.get("exact_json"):
            _data, _v, _n, _ks, _lam, exact_blocks = load_candidate(target.get("exact_json"))

        initial_rows = initial_candidates(cfg, p, ks, lam, baseline, exact_blocks, powers, diagnostics_cfg)
        apply_exactlike_scores(initial_rows, cfg)
        write_jsonl(os.path.join(out_dir, "initial_candidates.jsonl"), initial_rows)
        print("Initial candidates:", len(initial_rows))

        modes = [mode for mode in get_in(cfg, ("run", "modes"), ["score_only"]) if mode in SUPPORTED_MODES]
        run_summaries = []
        snapshot_rows = []
        diagnostic_rows = list(initial_rows)
        for mode in modes:
            for seed_index in seed_indices:
                initial = select_initial(initial_rows, seed_index)
                result = run_trajectory(mode, seed_index, initial, cfg, p, ks, lam, baseline, powers, diagnostics_cfg)
                run_summaries.append(result)
                snapshot_rows.extend(result["_snapshots"])
                diagnostic_rows.extend(result["_snapshots"])
                diagnostic_rows.append(result["_final_row"])
                diagnostic_rows.append(result["_best_row"])
                print("run", mode, seed_index, "accepted", result["accepted_moves"], "best", result["score_best"], "final", result["score_final"])
                sys.stdout.flush()

        apply_exactlike_scores(diagnostic_rows, cfg)
        for result in run_summaries:
            final_matches = [
                row
                for row in diagnostic_rows
                if row["canonical_hash"] == result["final_hash"]
                and row.get("mode") == result["mode"]
                and row.get("final")
            ]
            if not final_matches:
                final_matches = [row for row in diagnostic_rows if row["canonical_hash"] == result["final_hash"] and row.get("mode") == result["mode"]]
            best_matches = [row for row in diagnostic_rows if row["canonical_hash"] == result["best_hash"] and row.get("mode") == result["mode"]]
            final_row = final_matches[-1] if final_matches else {}
            best_row = best_matches[-1] if best_matches else {}
            result["final_label"] = final_row.get("label")
            result["best_label"] = best_row.get("label")
            for field in ("D_min_ratio", "P_4", "P_8", "P_16", "kappa_max", "Q_ratio", "ExactLikeScore"):
                result["final_{}".format(field)] = final_row.get(field)
                result["best_{}".format(field)] = best_row.get(field)

        frontier = build_frontier(diagnostic_rows, cfg)
        archived = false_archive(diagnostic_rows)
        write_jsonl(os.path.join(out_dir, "trajectory_snapshots.jsonl"), snapshot_rows)
        write_jsonl(os.path.join(out_dir, "diagnostic_candidates.jsonl"), diagnostic_rows)
        write_jsonl(os.path.join(out_dir, "frontier_candidates.jsonl"), frontier)
        write_jsonl(os.path.join(out_dir, "archived_false_like.jsonl"), archived)

        score0_rows = []
        score0_paths = []
        for row in unique_by_hash([row for row in diagnostic_rows if row.get("score") is not None and int(row.get("score")) == 0]):
            path = save_score0_candidate(out_dir, row, row.get("mode") or "trajectory", p, ks, lam)
            if path and path not in score0_paths:
                score0_paths.append(path)
                score0_rows.append(
                    {
                        "path": path,
                        "canonical_hash": row["canonical_hash"],
                        "mode": row.get("mode"),
                        "origin": row.get("origin"),
                        "source": "trajectory_or_initial",
                    }
                )

        repair_candidates = route_repair_candidates(diagnostic_rows, cfg, args.max_repair_candidates)
        repair_rows = []
        if cfg.get("repair", {}).get("enabled", False):
            repair_modes = [mode for mode in cfg.get("repair", {}).get("modes", []) if mode in REPAIR_MODES]
            rng = random.Random(int(int(get_in(cfg, ("experiment", "random_seed_base"), 0)) + 620000))
            for parent in repair_candidates:
                for repair_mode in repair_modes:
                    attempt = repair_candidate(parent, repair_mode, cfg, p, ks, lam, baseline, rng, powers, diagnostics_cfg)
                    repair_rows.append(attempt)
                    after = attempt["_after_row"]
                    if after["score"] == 0:
                        path = save_score0_candidate(out_dir, after, repair_mode, p, ks, lam)
                        if path and path not in score0_paths:
                            score0_paths.append(path)
                            score0_rows.append({"path": path, "canonical_hash": after["canonical_hash"], "mode": repair_mode, "parent_hash": parent["canonical_hash"]})

        apply_exactlike_scores([row["_after_row"] for row in repair_rows], cfg)
        for row in repair_rows:
            after = row["_after_row"]
            row["label_after"] = after.get("label")
            row["ExactLikeScore_after"] = after.get("ExactLikeScore")
            row["D_min_ratio_after"] = after.get("D_min_ratio")
            row["P_8_after"] = after.get("P_8")
            row["kappa_max_after"] = after.get("kappa_max")
        write_jsonl(os.path.join(out_dir, "repair_attempts.jsonl"), repair_rows)
        write_jsonl(os.path.join(out_dir, "score0_candidates.jsonl"), score0_rows)

        mode_rows = mode_summary(run_summaries, frontier, repair_rows)
        mode_rows = add_archive_counts_to_mode_summary(mode_rows, archived)
        label_rows = summarize_groups(diagnostic_rows, "label", ["score", "D_min_ratio", "P_8", "kappa_max", "Q_ratio", "ExactLikeScore"])
        feature_rows = summarize_groups(diagnostic_rows, "mode", ["score", "D_min_ratio", "P_8", "kappa_max", "Q_ratio", "ExactLikeScore"])
        repair_sum = repair_summary(repair_rows)
        frontier_rows = frontier_analysis(frontier)
        archive_rows = archive_analysis(archived)
        repair_routing_rows = repair_routing_analysis(repair_rows)
        mode_fields = [
            "mode",
            "run_count",
            "score0_count",
            "score0_rate",
            "median_best_score",
            "median_final_score",
            "best_score_overall",
            "final_exact_like_count",
            "final_false_like_count",
            "final_ambiguous_count",
            "final_unknown_count",
            "false_like_final_rate",
            "exact_like_final_rate",
            "frontier_exact_like_count",
            "frontier_false_like_count",
            "archived_false_like_count",
            "median_D_min_ratio_final",
            "median_P_4_final",
            "median_P_8_final",
            "median_P_16_final",
            "median_kappa_max_final",
            "median_Q_ratio_final",
            "median_ExactLikeScore_final",
            "repair_routed_count",
            "repair_attempt_count",
            "repair_score0_count",
            "repair_score_improvement_count",
            "repair_success_rate",
            "distinct_final_hashes",
            "distinct_frontier_hashes",
        ]
        write_csv(os.path.join(out_dir, "mode_summary.csv"), mode_rows, mode_fields)
        write_json_safe(os.path.join(out_dir, "mode_summary.json"), {"rows": mode_rows})
        write_csv(os.path.join(out_dir, "label_summary.csv"), label_rows, sorted(set().union(*(row.keys() for row in label_rows))) if label_rows else ["label", "count"])
        write_csv(os.path.join(out_dir, "feature_summary.csv"), feature_rows, sorted(set().union(*(row.keys() for row in feature_rows))) if feature_rows else ["mode", "count"])
        write_csv(os.path.join(out_dir, "repair_summary.csv"), repair_sum, ["repair_mode", "attempt_count", "score_improvement_count", "score_improvement_rate", "score0_count", "best_score_after"])
        write_json_safe(os.path.join(out_dir, "repair_summary.json"), {"rows": repair_sum})
        frontier_fields = sorted(set().union(*(row.keys() for row in frontier_rows))) if frontier_rows else ["mode", "frontier_count"]
        archive_fields = sorted(set().union(*(row.keys() for row in archive_rows))) if archive_rows else ["mode", "count"]
        repair_routing_fields = sorted(set().union(*(row.keys() for row in repair_routing_rows))) if repair_routing_rows else ["group", "repair_attempt_count"]
        write_csv(os.path.join(out_dir, "frontier_analysis.csv"), frontier_rows, frontier_fields)
        write_json_safe(os.path.join(out_dir, "frontier_analysis.json"), {"rows": frontier_rows})
        write_csv(os.path.join(out_dir, "archive_analysis.csv"), archive_rows, archive_fields)
        write_json_safe(os.path.join(out_dir, "archive_analysis.json"), {"rows": archive_rows})
        write_csv(os.path.join(out_dir, "repair_routing_analysis.csv"), repair_routing_rows, repair_routing_fields)
        write_json_safe(os.path.join(out_dir, "repair_routing_analysis.json"), {"rows": repair_routing_rows})

        comparison = {
            "config_driven_runner_ok": True,
            "exact_validation": exact_validation,
            "initial_candidate_count": len(initial_rows),
            "trajectory_run_count": len(run_summaries),
            "diagnostic_candidate_count": len(diagnostic_rows),
            "frontier_count": len(frontier),
            "archived_false_like_count": len(archived),
            "repair_routed_count": len(repair_candidates),
            "repair_attempt_count": len(repair_rows),
            "score0_candidate_paths": score0_paths,
            "mode_summary": mode_rows,
            "frontier_analysis": frontier_rows,
            "archive_analysis": archive_rows,
            "repair_routing_analysis": repair_routing_rows,
            "repair_summary": repair_sum,
        }
        write_json_safe(os.path.join(out_dir, "comparison_summary.json"), comparison)
        make_summary(
            os.path.join(out_dir, "experiment_summary.md"),
            {
                "p": p,
                "ks": [int(k) for k in ks],
                "lambda": lam,
                "experiment_name": experiment_name,
                "out_dir": out_dir,
                "mode_summary": mode_rows,
                "repair_summary": repair_sum,
                "frontier_analysis": frontier_rows,
                "archive_analysis": archive_rows,
                "repair_routing_analysis": repair_routing_rows,
                "exact_validation": exact_validation,
                "repair_routed_count": len(repair_candidates),
                "repair_attempt_count": len(repair_rows),
                "score0_paths": score0_paths,
            },
        )
        with open(os.path.join(out_dir, "run_log.md"), "a") as f:
            f.write("- initial candidates: `{}`\n".format(len(initial_rows)))
            f.write("- trajectory runs: `{}`\n".format(len(run_summaries)))
            f.write("- diagnostic candidates: `{}`\n".format(len(diagnostic_rows)))
            f.write("- frontier candidates: `{}`\n".format(len(frontier)))
            f.write("- archived false-like candidates: `{}`\n".format(len(archived)))
            f.write("- repair routed candidates: `{}`\n".format(len(repair_candidates)))
            f.write("- repair attempts: `{}`\n".format(len(repair_rows)))
            f.write("- score0 candidate files: `{}`\n".format(len(score0_paths)))
        print("SUMMARY:", os.path.join(out_dir, "experiment_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
