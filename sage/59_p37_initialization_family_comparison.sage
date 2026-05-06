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
    p_adic_moment_summary,
    setup_logging,
    total_diff_counts,
    validate_params,
    verify_hadamard_exact,
    verify_sds,
    write_json,
)


SCRIPT_NAME = "59_p37_initialization_family_comparison"
POWERS = (2, 4, 6, 8, 10, 12)
DEFAULT_FAMILIES = (
    "pure_random",
    "low_energy_random",
    "score_biased_random",
    "energy_regularized",
    "AP_regularized",
    "mixed_diversity",
    "exact_perturbation",
    "near_hit_perturbation",
)
INITIAL_FEATURES = (
    "score",
    "score_randnorm",
    "l1",
    "max_abs",
    "nonzero",
    "E_total",
    "AP_total",
    "Q_tot",
    "Q_ratio",
    "InitHardness",
    "E_excess_total",
    "AP_excess_total",
    "h_min",
    "D_min_ratio",
    "P_<0",
    "P_0",
    "P_4",
    "P_8",
    "P_16",
    "kappa_max",
    "kappa_q90",
    "kappa_q99",
    "moment_zero_count_3",
    "moment_zero_count_6",
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


def write_json_safe(path, payload):
    write_json(path, json_safe(payload))


def write_jsonl(path, rows):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(json_safe(row), sort_keys=True) + "\n")


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


def parse_families(text):
    families = tuple(part.strip() for part in str(text).split(",") if part.strip())
    bad = [family for family in families if family not in DEFAULT_FAMILIES]
    if bad:
        raise argparse.ArgumentTypeError("unknown families: {}".format(",".join(bad)))
    return families


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
    weighted_ap_excess = 0.0
    for idx, block in enumerate(blocks):
        base = baseline["blocks"][idx]
        e = additive_energy(p, block)
        ap = ap_count(p, block)
        q = q_formula_block(p, block)
        coeff = 2 * (int(p) - 2 * len(block))
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
                "AP_coefficient": int(coeff),
            }
        )
        total_e += int(e)
        total_ap += int(ap)
        total_q += int(q)
        total_e_excess += e_excess
        total_ap_excess += ap_excess
        weighted_ap_excess += float(coeff) * ap_excess
        total_q_expected += float(base["E_Q"])
    return {
        "blocks": rows,
        "E_total": int(total_e),
        "AP_total": int(total_ap),
        "Q_formula_total": int(total_q),
        "Q_expected_total": float(total_q_expected),
        "E_excess_total": float(total_e_excess),
        "AP_excess_total": float(total_ap_excess),
        "weighted_AP_excess_total": float(weighted_ap_excess),
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


def rho_vector(counts, lam):
    rho = [0] * len(counts)
    for d in range(1, len(counts)):
        rho[d] = int(counts[d] - lam)
    return rho


def score_counts(counts, lam):
    return int(metrics_from_counts(counts, lam)[0])


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
    p = int(p)
    score, l1_error, max_abs_error, nonzero_defect_count = [int(x) for x in metrics_from_counts(counts, lam)]
    moves = one_swap_library(blocks, counts, lam, p)
    h_values = [int(move["h"]) for move in moves]
    q_values = [int(move["q"]) for move in moves]
    kappas = [float(move["kappa"]) for move in moves if move["kappa"] is not None]
    improving = [move for move in moves if int(move["h"]) < 0]
    near = {threshold: sum(1 for move in moves if int(move["h"]) <= threshold) for threshold in (0, 4, 8, 16)}
    theta = {frac: sum(1 for move in moves if score > 0 and int(move["h"]) <= frac * score) for frac in (0.01, 0.05, 0.10)}
    h_min = min(h_values) if h_values else None
    d_min = None if h_min is None else int(score + h_min)
    structure = block_structure_payload(p, blocks, baseline)
    q_threshold = int(4 * (p - 1) * score)
    out = {
        "score": int(score),
        "l1": int(l1_error),
        "max_abs": int(max_abs_error),
        "nonzero": int(nonzero_defect_count),
        "h_min": int(h_min) if h_min is not None else None,
        "D_min_1": int(d_min) if d_min is not None else None,
        "D_min_ratio": float(d_min) / float(score) if score > 0 and d_min is not None else None,
        "P_<0": float(len(improving)) / float(len(moves)) if moves else None,
        "P_0": float(near[0]) / float(len(moves)) if moves else None,
        "P_4": float(near[4]) / float(len(moves)) if moves else None,
        "P_8": float(near[8]) / float(len(moves)) if moves else None,
        "P_16": float(near[16]) / float(len(moves)) if moves else None,
        "P_thetaS_001": float(theta[0.01]) / float(len(moves)) if moves else None,
        "P_thetaS_005": float(theta[0.05]) / float(len(moves)) if moves else None,
        "P_thetaS_010": float(theta[0.10]) / float(len(moves)) if moves else None,
        "kappa_max": max(kappas) if kappas else None,
        "kappa_q90": quantile(kappas, 0.90),
        "kappa_q95": quantile(kappas, 0.95),
        "kappa_q99": quantile(kappas, 0.99),
        "Q_ratio": float(sum(q_values)) / float(q_threshold) if q_threshold > 0 else None,
        "Q_tot": int(sum(q_values)),
        "Q_formula_total": int(structure["Q_formula_total"]),
        "InitHardness": float(structure["InitHardness"]),
        "E_total": int(structure["E_total"]),
        "AP_total": int(structure["AP_total"]),
        "E_excess_total": float(structure["E_excess_total"]),
        "AP_excess_total": float(structure["AP_excess_total"]),
        "weighted_AP_excess_total": float(structure["weighted_AP_excess_total"]),
        "improving_swap_count": int(len(improving)),
        "near_improving_count_h_le_4": int(near[4]),
        "near_improving_count_h_le_8": int(near[8]),
        "near_improving_count_h_le_16": int(near[16]),
    }
    out.update(moment_payload(counts, lam, p))
    return out


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


def apply_move_to_counts(p, blocks, counts, move):
    delta = delta_swap(p, blocks[int(move["block"])], int(move["removed"]), int(move["added"]))
    return apply_delta(counts, delta)


def deterministic_offset(text):
    return int(sum((idx + 1) * ord(ch) for idx, ch in enumerate(str(text))))


def candidate_rank(blocks, p, lam, baseline, family):
    counts = total_diff_counts(p, blocks)
    score = score_counts(counts, lam)
    structure = block_structure_payload(p, blocks, baseline)
    e_score = max(1.0, float(baseline["E_score"]))
    e_q = max(1.0, float(abs(baseline["E_Q_total"])))
    weighted_ap = float(structure["weighted_AP_excess_total"])
    ap_scale = max(1.0, float(sum(abs(2 * (int(p) - 2 * int(k))) * baseline["blocks"][idx]["E_AP"] for idx, k in enumerate([len(block) for block in blocks]))))
    if family == "low_energy_random":
        return (float(structure["E_total"]), float(score), float(abs(structure["InitHardness"])))
    if family == "score_biased_random":
        return (float(score), float(abs(structure["InitHardness"])))
    if family == "energy_regularized":
        return (float(score) / e_score + 0.25 * max(0.0, float(structure["InitHardness"])) / e_q, float(score))
    if family == "AP_regularized":
        return (float(score) / e_score + 0.35 * max(0.0, weighted_ap) / ap_scale, float(score), weighted_ap)
    return (0.0, float(score))


def ranked_random_blocks(rng, p, ks, lam, baseline, family, pool_size):
    pool = []
    for _ in range(max(1, int(pool_size))):
        blocks = random_blocks(rng, p, ks)
        pool.append((candidate_rank(blocks, p, lam, baseline, family), blocks))
    pool.sort(key=lambda item: item[0])
    return clone_blocks(pool[0][1])


def perturb_blocks(rng, source_blocks, p, radius):
    blocks = clone_blocks(source_blocks)
    for _ in range(max(0, int(radius))):
        move = random_swap(rng, blocks, p)
        apply_swap_to_blocks(blocks, move)
    return blocks


def discover_existing_candidates(p, ks, lam, max_candidates, score_max=None):
    roots = [
        os.path.join("outputs", "candidates", "small_p"),
        os.path.join("outputs", "explorations", "20260506_0915_small_p_escapability_validation"),
        os.path.join("outputs", "explorations", "20260506_1125_small_p_defect_targeted_lns_validation"),
        os.path.join("outputs", "explorations", "20260506_1200_p37_score4_false_basin_anatomy"),
        os.path.join("outputs", "explorations"),
    ]
    paths = []
    for root in roots:
        if os.path.isdir(root):
            paths.extend(glob.glob(os.path.join(root, "**", "*.json"), recursive=True))
    found = []
    seen = set()
    for path in sorted(set(paths)):
        try:
            if os.path.getsize(path) > 2_000_000:
                continue
            _data, v, _n, got_ks, got_lam, blocks = load_candidate(path)
        except Exception:
            continue
        if int(v) != int(p) or tuple(got_ks) != tuple(ks) or int(got_lam) != int(lam):
            continue
        counts = total_diff_counts(p, blocks)
        score = score_counts(counts, lam)
        if score_max is not None and int(score) > int(score_max):
            continue
        key = canonical_hash(blocks, ks, p)
        if key in seen:
            continue
        seen.add(key)
        found.append({"path": path, "blocks": clone_blocks(blocks), "score": int(score), "canonical_hash": key})
        if len(found) >= int(max_candidates):
            break
    return found


def generate_one_family_candidate(family, rng, p, ks, lam, baseline, exact_blocks, near_hits, args, index):
    if family == "pure_random":
        return random_blocks(rng, p, ks), {"origin_detail": "direct_random"}
    if family in ("low_energy_random", "score_biased_random", "energy_regularized", "AP_regularized"):
        return ranked_random_blocks(rng, p, ks, lam, baseline, family, int(args.init_pool)), {"origin_detail": "ranked_pool", "pool_size": int(args.init_pool)}
    if family == "mixed_diversity":
        subfamilies = ("pure_random", "low_energy_random", "score_biased_random", "energy_regularized", "AP_regularized")
        subfamily = subfamilies[(int(index) + rng.randrange(len(subfamilies))) % len(subfamilies)]
        if subfamily == "pure_random":
            blocks = random_blocks(rng, p, ks)
        else:
            blocks = ranked_random_blocks(rng, p, ks, lam, baseline, subfamily, int(args.init_pool))
        return blocks, {"origin_detail": "mixed_subfamily", "subfamily": subfamily}
    if family == "exact_perturbation":
        if exact_blocks is None:
            return None, {"skip_reason": "missing_exact_json"}
        radius = 1 + (int(index) % max(1, int(args.exact_perturb_max_r)))
        return perturb_blocks(rng, exact_blocks, p, radius), {"origin_detail": "exact_rswap_perturbation", "radius": int(radius)}
    if family == "near_hit_perturbation":
        if not near_hits:
            return None, {"skip_reason": "no_score_le_8_near_hits_found"}
        source = near_hits[rng.randrange(len(near_hits))]
        radius = 1 + (int(index) % max(1, int(args.near_hit_perturb_max_r)))
        return perturb_blocks(rng, source["blocks"], p, radius), {
            "origin_detail": "near_hit_rswap_perturbation",
            "radius": int(radius),
            "source_path": source["path"],
            "source_score": int(source["score"]),
            "source_hash": source["canonical_hash"],
        }
    raise ValueError("unsupported family {}".format(family))


def make_initial_row(family, seed, candidate_id, blocks, p, ks, lam, baseline, origin):
    counts = total_diff_counts(p, blocks)
    diag = full_diagnostic(blocks, counts, lam, p, baseline)
    row = {
        "family": family,
        "seed": int(seed),
        "candidate_id": candidate_id,
        "canonical_hash": canonical_hash(blocks, ks, p),
        "score_randnorm": float(diag["score"]) / float(max(1.0, baseline["E_score"])),
        "blocks": json_blocks(blocks),
        "canonical_repr_summary": canonical_repr_summary(blocks, ks, p),
    }
    row.update(origin or {})
    row.update(diag)
    return row


def generate_initial_candidates(families, p, ks, lam, baseline, exact_blocks, near_hits, args):
    rows = []
    skipped = []
    for family in families:
        rng = random.Random(int(int(args.seed) + deterministic_offset(family)))
        seen = set()
        attempts = 0
        target = int(args.candidates_per_family)
        while len([row for row in rows if row["family"] == family]) < target and attempts < max(50, target * 25):
            attempts += 1
            local_index = len([row for row in rows if row["family"] == family])
            blocks, origin = generate_one_family_candidate(family, rng, p, ks, lam, baseline, exact_blocks, near_hits, args, local_index + attempts)
            if blocks is None:
                skipped.append({"family": family, "reason": origin.get("skip_reason"), "attempt": int(attempts)})
                break
            key = canonical_hash(blocks, ks, p)
            if key in seen:
                continue
            seen.add(key)
            row = make_initial_row(family, attempts, "{}_{:03d}".format(family, local_index + 1), blocks, p, ks, lam, baseline, origin)
            rows.append(row)
            print("initial family={} count={} score={} D_min_ratio={} P8={}".format(family, local_index + 1, row["score"], row.get("D_min_ratio"), row.get("P_8")))
            sys.stdout.flush()
    return rows, skipped


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
                removed = rng.choice(tuple(block))
                added = (int(removed) + int(d)) % p
                if added not in block:
                    move = {"block": int(block_idx), "removed": int(removed), "added": int(added)}
                    break
            if move is None:
                move = random_swap(rng, blocks, p)
        else:
            move = random_swap(rng, blocks, p)
        new_counts = apply_move_to_counts(p, blocks, counts, move)
        new_metrics = tuple(int(x) for x in metrics_from_counts(new_counts, lam))
        item = {"move": move, "new_counts": new_counts, "metrics": new_metrics, "DeltaS": int(new_metrics[0] - score)}
        if best is None or item["metrics"] < best["metrics"]:
            best = item
    return best


def outcome_label(final_diag):
    score = final_diag.get("score")
    if score is not None and int(score) == 0:
        return "success_score0"
    h_min = final_diag.get("h_min")
    ratio = final_diag.get("D_min_ratio")
    p_neg = final_diag.get("P_<0")
    if score is not None and int(score) > 0 and h_min is not None and ratio is not None:
        if int(h_min) > 0 and float(ratio) > 1.0 and float(p_neg or 0.0) == 0.0:
            return "false_basin_final"
        if int(h_min) < 0 or float(ratio) < 1.0:
            return "escapable_final"
    return "unknown_final"


def snapshot_row(run_id, family, seed, step, accepted, blocks, counts, lam, p, ks, baseline):
    diag = full_diagnostic(blocks, counts, lam, p, baseline)
    row = {
        "run_id": run_id,
        "family": family,
        "trajectory_mode": "score_only_with_diagnostics",
        "seed": int(seed),
        "step": int(step),
        "accepted_moves": int(accepted),
        "canonical_hash": canonical_hash(blocks, ks, p),
    }
    row.update(diag)
    return row


def save_score0_candidate(out_dir, run_id, family, seed, blocks, p, ks, lam, counts):
    ok, _bad = verify_sds(p, blocks, lam)
    entries_ok, hh_t_ok = verify_hadamard_exact(p, blocks)
    score, l1_error, max_abs_error, nonzero = metrics_from_counts(counts, lam)
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
        "search_method": SCRIPT_NAME,
        "family": family,
        "run_id": run_id,
        "seed": int(seed),
        "canonical_hash": canonical_hash(blocks, ks, p),
        "canonical_repr_summary": canonical_repr_summary(blocks, ks, p),
        "error_histogram": error_histogram(counts, lam),
    }
    path = os.path.join(out_dir, "score0_candidate_{}.json".format(run_id))
    write_json_safe(path, payload)
    return path


def run_family_trajectory(initial_row, run_seed, p, ks, lam, baseline, args, out_dir, saved_score0_hashes):
    family = initial_row["family"]
    run_id = "{}_seed{}".format(family, int(run_seed))
    rng = random.Random(int(int(args.seed) + 1000003 * int(run_seed) + deterministic_offset(family)))
    blocks = [set(int(x) for x in block) for block in initial_row["blocks"]]
    counts = total_diff_counts(p, blocks)
    accepted = 0
    best_score = score_counts(counts, lam)
    best_hash = canonical_hash(blocks, ks, p)
    snapshots = []
    snapshot_steps = set([0, int(args.steps)])
    for step in range(0, int(args.steps) + 1, max(1, int(args.snapshot_interval))):
        snapshot_steps.add(int(step))
    score0_paths = []
    for step in range(int(args.steps) + 1):
        if step in snapshot_steps and len(snapshots) < int(args.diagnostic_max_per_run):
            snapshots.append(snapshot_row(run_id, family, run_seed, step, accepted, blocks, counts, lam, p, ks, baseline))
        score = score_counts(counts, lam)
        if score < best_score:
            best_score = int(score)
            best_hash = canonical_hash(blocks, ks, p)
        if score == 0:
            key = canonical_hash(blocks, ks, p)
            if key not in saved_score0_hashes:
                saved_score0_hashes.add(key)
                score0_paths.append(save_score0_candidate(out_dir, run_id, family, run_seed, blocks, p, ks, lam, counts))
            break
        if step >= int(args.steps):
            break
        item = sample_best_move(rng, blocks, counts, lam, p, int(args.candidate_samples), float(args.targeted_prob))
        delta_s = int(item["DeltaS"])
        accept = delta_s < 0 or rng.random() < float(args.random_walk_prob)
        if accept:
            move = item["move"]
            if apply_swap_to_blocks(blocks, move):
                counts = list(item["new_counts"])
                accepted += 1
    if not snapshots or int(snapshots[-1]["step"]) != int(step):
        snapshots.append(snapshot_row(run_id, family, run_seed, step, accepted, blocks, counts, lam, p, ks, baseline))
    final_snapshot = snapshots[-1]
    final_label = outcome_label(final_snapshot)
    out = {
        "run_id": run_id,
        "family": family,
        "trajectory_mode": "score_only_with_diagnostics",
        "seed": int(run_seed),
        "starting_candidate_id": initial_row["candidate_id"],
        "initial_canonical_hash": initial_row["canonical_hash"],
        "final_canonical_hash": final_snapshot["canonical_hash"],
        "accepted_moves": int(accepted),
        "steps_run": int(step),
        "score_start": int(initial_row["score"]),
        "score_end": int(final_snapshot["score"]),
        "score_best": int(best_score),
        "best_canonical_hash": best_hash,
        "final_label": final_label,
        "score0_candidate_paths": score0_paths,
        "initial_features": {key: initial_row.get(key) for key in INITIAL_FEATURES},
        "final_features": {key: final_snapshot.get(key) for key in INITIAL_FEATURES},
        "snapshots": snapshots,
    }
    return out


def select_initial_rows_for_runs(initial_rows, seeds_per_family):
    by_family = {}
    for row in initial_rows:
        by_family.setdefault(row["family"], []).append(row)
    selected = []
    for family, rows in sorted(by_family.items()):
        rows = sorted(rows, key=lambda row: (row.get("score", 10**9), row.get("candidate_id", "")))
        if family in ("pure_random", "mixed_diversity"):
            rows = sorted(rows, key=lambda row: row.get("candidate_id", ""))
        seen = set()
        family_selected = []
        for row in rows:
            if row["canonical_hash"] in seen:
                continue
            seen.add(row["canonical_hash"])
            family_selected.append(row)
            if len(family_selected) >= int(seeds_per_family):
                break
        selected.extend(family_selected)
    return selected


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


def entropy(values):
    values = [value for value in values if value is not None]
    if not values:
        return 0.0
    counts = {}
    for value in values:
        counts[value] = counts.get(value, 0) + 1
    total = float(len(values))
    return float(-sum((count / total) * math.log(count / total, 2) for count in counts.values()))


def initial_feature_summary(initial_rows):
    fields = [
        "score",
        "score_randnorm",
        "InitHardness",
        "Q_ratio",
        "P_8",
        "P_16",
        "kappa_max",
        "E_excess_total",
        "AP_excess_total",
    ]
    out = []
    by_family = {}
    for row in initial_rows:
        by_family.setdefault(row["family"], []).append(row)
    for family, rows in sorted(by_family.items()):
        item = {"family": family, "count": int(len(rows)), "distinct_hashes": int(len(set(row["canonical_hash"] for row in rows)))}
        for field in fields:
            item["median_{}".format(field)] = median([row.get(field) for row in rows])
            item["mean_{}".format(field)] = mean([row.get(field) for row in rows])
        out.append(item)
    return out


def family_summary(trajectory_rows):
    out = []
    by_family = {}
    for row in trajectory_rows:
        by_family.setdefault(row["family"], []).append(row)
    for family, rows in sorted(by_family.items()):
        labels = [row["final_label"] for row in rows]
        run_count = len(rows)
        item = {
            "family": family,
            "run_count": int(run_count),
            "success_score0_count": int(sum(1 for label in labels if label == "success_score0")),
            "false_basin_final_count": int(sum(1 for label in labels if label == "false_basin_final")),
            "escapable_final_count": int(sum(1 for label in labels if label == "escapable_final")),
            "unknown_final_count": int(sum(1 for label in labels if label == "unknown_final")),
            "median_initial_score": median([row["initial_features"].get("score") for row in rows]),
            "median_initial_score_randnorm": median([row["initial_features"].get("score_randnorm") for row in rows]),
            "median_initial_InitHardness": median([row["initial_features"].get("InitHardness") for row in rows]),
            "median_initial_Q_ratio": median([row["initial_features"].get("Q_ratio") for row in rows]),
            "median_initial_P_8": median([row["initial_features"].get("P_8") for row in rows]),
            "median_initial_kappa_max": median([row["initial_features"].get("kappa_max") for row in rows]),
            "median_final_score": median([row["final_features"].get("score") for row in rows]),
            "median_best_score": median([row.get("score_best") for row in rows]),
            "median_final_D_min_ratio": median([row["final_features"].get("D_min_ratio") for row in rows]),
            "median_final_P_8": median([row["final_features"].get("P_8") for row in rows]),
            "median_final_kappa_max": median([row["final_features"].get("kappa_max") for row in rows]),
            "median_final_Q_ratio": median([row["final_features"].get("Q_ratio") for row in rows]),
            "distinct_initial_hashes": int(len(set(row["initial_canonical_hash"] for row in rows))),
            "distinct_final_hashes": int(len(set(row["final_canonical_hash"] for row in rows))),
            "label_entropy": entropy(labels),
        }
        item["false_basin_rate"] = float(item["false_basin_final_count"]) / float(run_count) if run_count else None
        item["escapable_rate"] = float(item["escapable_final_count"]) / float(run_count) if run_count else None
        item["success_rate"] = float(item["success_score0_count"]) / float(run_count) if run_count else None
        out.append(item)
    return out


def numeric_values(rows, getter):
    values = []
    for row in rows:
        value = getter(row)
        if value is None:
            continue
        try:
            value = float(value)
        except Exception:
            continue
        if math.isfinite(value):
            values.append(value)
    return values


def zscore(value, mean_value, std_value):
    if value is None:
        return 0.0
    try:
        value = float(value)
    except Exception:
        return 0.0
    if not math.isfinite(value) or std_value is None or std_value == 0:
        return 0.0
    return (value - mean_value) / std_value


def exact_like_score_rows(trajectory_rows):
    points = []
    for row in trajectory_rows:
        points.append({"stage": "initial", "family": row["family"], "run_id": row["run_id"], "features": row["initial_features"], "label": row["final_label"]})
        points.append({"stage": "final", "family": row["family"], "run_id": row["run_id"], "features": row["final_features"], "label": row["final_label"]})
    stats = {}
    for field in ("D_min_ratio", "P_4", "P_8", "kappa_max", "Q_ratio"):
        values = numeric_values(points, lambda row, field=field: row["features"].get(field))
        if values:
            mean_value = sum(values) / float(len(values))
            std_value = statistics.pstdev(values) if len(values) > 1 else 0.0
        else:
            mean_value = 0.0
            std_value = 0.0
        stats[field] = {"mean": float(mean_value), "std": float(std_value)}
    out = []
    for row in points:
        features = row["features"]
        score = (
            -zscore(features.get("D_min_ratio"), stats["D_min_ratio"]["mean"], stats["D_min_ratio"]["std"])
            + zscore(features.get("P_4"), stats["P_4"]["mean"], stats["P_4"]["std"])
            + zscore(features.get("P_8"), stats["P_8"]["mean"], stats["P_8"]["std"])
            + zscore(features.get("kappa_max"), stats["kappa_max"]["mean"], stats["kappa_max"]["std"])
            - 0.25 * zscore(features.get("Q_ratio"), stats["Q_ratio"]["mean"], stats["Q_ratio"]["std"])
        )
        out.append(
            {
                "stage": row["stage"],
                "family": row["family"],
                "run_id": row["run_id"],
                "final_label": row["label"],
                "ExactLikeScore": float(score),
                "D_min_ratio": features.get("D_min_ratio"),
                "P_4": features.get("P_4"),
                "P_8": features.get("P_8"),
                "kappa_max": features.get("kappa_max"),
                "Q_ratio": features.get("Q_ratio"),
            }
        )
    return out, stats


def good_init_rule_evaluation(trajectory_rows):
    thresholds = {
        "score_randnorm_median": median([row["initial_features"].get("score_randnorm") for row in trajectory_rows]),
        "InitHardness_median": median([row["initial_features"].get("InitHardness") for row in trajectory_rows]),
        "P_8_median": median([row["initial_features"].get("P_8") for row in trajectory_rows]),
    }
    rows = []
    counts = {"tp": 0, "fp": 0, "tn": 0, "fn": 0, "unknown": 0, "good_count": 0, "bad_count": 0}
    for row in trajectory_rows:
        features = row["initial_features"]
        good = (
            features.get("score_randnorm") is not None
            and thresholds["score_randnorm_median"] is not None
            and float(features.get("score_randnorm")) <= float(thresholds["score_randnorm_median"])
            and features.get("InitHardness") is not None
            and thresholds["InitHardness_median"] is not None
            and float(features.get("InitHardness")) <= float(thresholds["InitHardness_median"])
            and features.get("P_8") is not None
            and thresholds["P_8_median"] is not None
            and float(features.get("P_8")) >= float(thresholds["P_8_median"])
        )
        positive = row["final_label"] in ("success_score0", "escapable_final")
        known = row["final_label"] in ("success_score0", "escapable_final", "false_basin_final")
        if good:
            counts["good_count"] += 1
        else:
            counts["bad_count"] += 1
        if not known:
            counts["unknown"] += 1
        elif good and positive:
            counts["tp"] += 1
        elif good and not positive:
            counts["fp"] += 1
        elif not good and positive:
            counts["fn"] += 1
        else:
            counts["tn"] += 1
        rows.append(
            {
                "run_id": row["run_id"],
                "family": row["family"],
                "GoodInitRule": bool(good),
                "final_label": row["final_label"],
                "positive_actual": bool(positive),
                "score_randnorm": features.get("score_randnorm"),
                "InitHardness": features.get("InitHardness"),
                "P_8": features.get("P_8"),
            }
        )
    denom = float(counts["tp"] + counts["fp"] + counts["tn"] + counts["fn"])
    summary = {
        "row_type": "summary",
        "tp": counts["tp"],
        "fp": counts["fp"],
        "tn": counts["tn"],
        "fn": counts["fn"],
        "unknown": counts["unknown"],
        "good_count": counts["good_count"],
        "bad_count": counts["bad_count"],
        "accuracy_known": float(counts["tp"] + counts["tn"]) / denom if denom else None,
        "precision_known": float(counts["tp"]) / float(counts["tp"] + counts["fp"]) if counts["tp"] + counts["fp"] else None,
        "recall_known": float(counts["tp"]) / float(counts["tp"] + counts["fn"]) if counts["tp"] + counts["fn"] else None,
        "false_basin_rate_good_known": float(counts["fp"]) / float(counts["tp"] + counts["fp"]) if counts["tp"] + counts["fp"] else None,
        "false_basin_rate_bad_known": float(counts["tn"]) / float(counts["tn"] + counts["fn"]) if counts["tn"] + counts["fn"] else None,
    }
    summary.update(thresholds)
    return [summary] + rows, summary


def find_family(summary_rows, family):
    for row in summary_rows:
        if row["family"] == family:
            return row
    return None


def verdict_from_bool(value):
    if value is None:
        return "undetermined"
    return "supported" if value else "not_supported"


def hypothesis_evaluation(summary_rows, good_rule_summary, score_rows):
    baseline = [row for row in summary_rows if row["family"] in ("pure_random", "score_biased_random")]
    regularized = [row for row in summary_rows if row["family"] in ("low_energy_random", "energy_regularized", "AP_regularized")]
    mixed = find_family(summary_rows, "mixed_diversity")
    def median_field(rows, field):
        return median([row.get(field) for row in rows])
    baseline_false = median_field(baseline, "false_basin_rate")
    reg_false = median_field(regularized, "false_basin_rate")
    baseline_esc = median_field(baseline, "escapable_rate")
    reg_esc = median_field(regularized, "escapable_rate")
    h12_supported = None
    if baseline_false is not None and reg_false is not None and baseline_esc is not None and reg_esc is not None:
        h12_supported = reg_false <= baseline_false and reg_esc >= baseline_esc
    h13_supported = None
    if mixed is not None:
        other_hashes = median([row.get("distinct_final_hashes") for row in summary_rows if row["family"] != "mixed_diversity"])
        other_entropy = median([row.get("label_entropy") for row in summary_rows if row["family"] != "mixed_diversity"])
        h13_supported = (
            mixed.get("false_basin_rate") is not None
            and mixed.get("distinct_final_hashes") is not None
            and other_hashes is not None
            and mixed["distinct_final_hashes"] >= other_hashes
            and (other_entropy is None or mixed.get("label_entropy", 0.0) >= other_entropy)
        )
    h14_supported = None
    if good_rule_summary.get("precision_known") is not None:
        h14_supported = good_rule_summary.get("precision_known") >= 0.60 and (good_rule_summary.get("false_basin_rate_good_known") or 1.0) <= (good_rule_summary.get("false_basin_rate_bad_known") or 1.0)
    exact_scores = [row["ExactLikeScore"] for row in score_rows if row["stage"] == "initial" and row["family"] == "exact_perturbation"]
    false_scores = [row["ExactLikeScore"] for row in score_rows if row["stage"] == "initial" and row["final_label"] == "false_basin_final"]
    best_false = sorted(summary_rows, key=lambda row: (float(row["false_basin_rate"]) if row["false_basin_rate"] is not None else 999.0, -float(row["escapable_rate"] or 0.0)))
    best_esc = sorted(summary_rows, key=lambda row: (-(float(row["escapable_rate"]) if row["escapable_rate"] is not None else -1.0), float(row["false_basin_rate"] or 999.0)))
    return {
        "H12_energy_AP_regularized_reduces_hard_basin": {
            "verdict": verdict_from_bool(h12_supported),
            "regularized_median_false_basin_rate": reg_false,
            "baseline_median_false_basin_rate": baseline_false,
            "regularized_median_escapable_rate": reg_esc,
            "baseline_median_escapable_rate": baseline_esc,
        },
        "H13_mixed_diversity_increases_basin_diversity": {
            "verdict": verdict_from_bool(h13_supported),
            "mixed_summary": mixed,
        },
        "H14_good_init_rule_predicts_non_false_final": {
            "verdict": verdict_from_bool(h14_supported),
            "rule_summary": good_rule_summary,
        },
        "best_family_by_low_false_basin_rate": best_false[0] if best_false else None,
        "best_family_by_high_escapable_rate": best_esc[0] if best_esc else None,
        "exact_perturbation_initial_ExactLikeScore_median": median(exact_scores),
        "false_final_initial_ExactLikeScore_median": median(false_scores),
    }


def make_summary(path, context):
    family_rows = context["family_summary"]
    hyp = context["hypotheses"]
    skipped = context["skipped"]
    ap_coefficients = context["ap_coefficients"]
    best_false = hyp.get("best_family_by_low_false_basin_rate") or {}
    score_biased = find_family(family_rows, "score_biased_random") or {}
    exact_pert = find_family(family_rows, "exact_perturbation") or {}
    near_hit = find_family(family_rows, "near_hit_perturbation") or {}
    mixed = find_family(family_rows, "mixed_diversity") or {}
    lines = [
        "# p37 Initialization Family Comparison Summary",
        "",
        "This run compares p=37 initialization families with the same lightweight score-only trajectory budget. It is not a Hadamard 668 construction run.",
        "",
        "## Run",
        "",
        "- p: `{}`".format(context["p"]),
        "- ks: `{}`".format(context["ks"]),
        "- lambda: `{}`".format(context["lambda"]),
        "- families: `{}`".format(context["families"]),
        "- candidates_per_family: `{}`".format(context["candidates_per_family"]),
        "- seeds_per_family: `{}`".format(context["seeds_per_family"]),
        "- steps: `{}`".format(context["steps"]),
        "- trajectory_mode: `score_only_with_diagnostics`",
        "- score=0 only is success.",
        "",
        "## AP Coefficients",
        "",
        "For Q_X = C(p,k)+8E(X)+2(p-2k)AP(X), the p=37 tuple has AP coefficients `{}` for ks `{}`. All are positive, so AP_regularized penalizes positive AP excess.".format(ap_coefficients, context["ks"]),
        "",
        "## Family Summary",
        "",
        "```json",
        json.dumps(json_safe(family_rows), indent=2, sort_keys=True),
        "```",
        "",
        "## Hypothesis Evaluation",
        "",
        "```json",
        json.dumps(json_safe(hyp), indent=2, sort_keys=True),
        "```",
    ]
    if skipped:
        lines.extend(["", "## Skipped", "", "```json", json.dumps(json_safe(skipped), indent=2, sort_keys=True), "```"])
    lines.extend(
        [
            "",
            "## Required Answers",
            "",
            "1. どの initialization family が最も hard basin rate を下げたか: `{}` (false_basin_rate `{}`).".format(best_false.get("family"), best_false.get("false_basin_rate")),
            "2. energy_regularized / AP_regularized は H12 を支持したか: `{}`.".format(hyp["H12_energy_AP_regularized_reduces_hard_basin"]["verdict"]),
            "3. mixed_diversity は H13 を支持したか: `{}`; distinct_final_hashes `{}`, label_entropy `{}`.".format(hyp["H13_mixed_diversity_increases_basin_diversity"]["verdict"], mixed.get("distinct_final_hashes"), mixed.get("label_entropy")),
            "4. GoodInitRule は H14 を支持したか: `{}`; precision_known `{}`, recall_known `{}`.".format(hyp["H14_good_init_rule_predicts_non_false_final"]["verdict"], hyp["H14_good_init_rule_predicts_non_false_final"]["rule_summary"].get("precision_known"), hyp["H14_good_init_rule_predicts_non_false_final"]["rule_summary"].get("recall_known")),
            "5. score_biased_random は低 score だが false basin に落ちやすかったか: false_basin_rate `{}`, median_initial_score `{}`.".format(score_biased.get("false_basin_rate"), score_biased.get("median_initial_score")),
            "6. initial InitHardness / Q_ratio / P_tau / kappa は final outcome を予測したか: GoodInitRule と ExactLikeScore は初期仮説として `{}`; detailed rows are in exact_like_scores.jsonl.".format(hyp["H14_good_init_rule_predicts_non_false_final"]["verdict"]),
            "7. exact_perturbation family はどのような signature を持ったか: false_basin_rate `{}`, escapable_rate `{}`, median_initial_P_8 `{}`, median_initial_kappa_max `{}`.".format(exact_pert.get("false_basin_rate"), exact_pert.get("escapable_rate"), exact_pert.get("median_initial_P_8"), exact_pert.get("median_initial_kappa_max")),
            "8. near_hit_perturbation family は false basin に戻りやすかったか: false_basin_rate `{}`, escapable_rate `{}`.".format(near_hit.get("false_basin_rate"), near_hit.get("escapable_rate")),
            "9. 次に p=43/47/668 へ拡張すべき初期化 family はどれか: prioritize families with low false_basin_rate and high escapable_rate in family_summary.csv; controlled exact_perturbation remains diagnostic only.",
            "10. 668 の initialization policy にどう反映すべきか: use score as a filter, but retain candidates with low D_min/S, non-collapsing P_tau/kappa, and moderate InitHardness/Q_ratio; avoid over-selecting score-biased low-score candidates when their local entropy collapses.",
        ]
    )
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Compare p37 initialization families under a common lightweight trajectory budget.")
    parser.add_argument("--p", type=int, default=37)
    parser.add_argument("--ks", type=parse_ks, default=(13, 16, 18, 18))
    parser.add_argument("--lambda", dest="lam", type=int, default=28)
    parser.add_argument("--exact-json", default="outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json")
    parser.add_argument("--families", type=parse_families, default=",".join(DEFAULT_FAMILIES))
    parser.add_argument("--candidates-per-family", type=int, default=50)
    parser.add_argument("--seeds-per-family", type=int, default=20)
    parser.add_argument("--steps", type=int, default=1500)
    parser.add_argument("--snapshot-interval", type=int, default=150)
    parser.add_argument("--diagnostic-max-per-run", type=int, default=20)
    parser.add_argument("--candidate-samples", type=int, default=16)
    parser.add_argument("--targeted-prob", type=float, default=0.30)
    parser.add_argument("--random-walk-prob", type=float, default=0.002)
    parser.add_argument("--init-pool", type=int, default=24)
    parser.add_argument("--exact-perturb-max-r", type=int, default=5)
    parser.add_argument("--near-hit-perturb-max-r", type=int, default=2)
    parser.add_argument("--near-hit-max-candidates", type=int, default=30)
    parser.add_argument("--seed", type=int, default=59037)
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
        families = tuple(args.families)
        out_dir = args.out_dir or os.path.join("outputs", "explorations", "{}_p37_initialization_family_comparison".format(now_stamp()))
        ensure_dir(out_dir)
        baseline = random_baseline_tuple(p, ks)
        exact_blocks = None
        if args.exact_json and os.path.exists(args.exact_json):
            _data, _v, _n, _ks, _lam, exact_blocks = load_candidate(args.exact_json)
        near_hits = discover_existing_candidates(p, ks, lam, max_candidates=int(args.near_hit_max_candidates), score_max=8)
        ap_coefficients = [int(2 * (p - 2 * int(k))) for k in ks]
        run_config = {
            "script": SCRIPT_NAME,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "p": int(p),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "exact_json": args.exact_json,
            "families": list(families),
            "candidates_per_family": int(args.candidates_per_family),
            "seeds_per_family": int(args.seeds_per_family),
            "steps": int(args.steps),
            "snapshot_interval": int(args.snapshot_interval),
            "diagnostic_max_per_run": int(args.diagnostic_max_per_run),
            "candidate_samples": int(args.candidate_samples),
            "init_pool": int(args.init_pool),
            "random_baseline": baseline,
            "ap_coefficients": ap_coefficients,
            "near_hit_count": int(len(near_hits)),
            "out_dir": out_dir,
            "note": "score=0 only is success; p=37 initialization-family comparison only.",
        }
        write_json_safe(os.path.join(out_dir, "run_config.json"), run_config)
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# Run Log\n\n")
            f.write("- script: `{}`\n".format(SCRIPT_NAME))
            f.write("- score=0 only is success\n")
            f.write("- trajectory_mode: `score_only_with_diagnostics`\n")
            f.write("- near_hit_count: `{}`\n".format(len(near_hits)))

        print("Generating initial candidates")
        initial_rows, skipped = generate_initial_candidates(families, p, ks, lam, baseline, exact_blocks, near_hits, args)
        write_jsonl(os.path.join(out_dir, "initial_candidates_by_family.jsonl"), initial_rows)
        initial_summary = initial_feature_summary(initial_rows)
        initial_summary_fields = [
            "family",
            "count",
            "distinct_hashes",
            "median_score",
            "mean_score",
            "median_score_randnorm",
            "mean_score_randnorm",
            "median_InitHardness",
            "mean_InitHardness",
            "median_Q_ratio",
            "mean_Q_ratio",
            "median_P_8",
            "mean_P_8",
            "median_P_16",
            "mean_P_16",
            "median_kappa_max",
            "mean_kappa_max",
            "median_E_excess_total",
            "mean_E_excess_total",
            "median_AP_excess_total",
            "mean_AP_excess_total",
        ]
        write_csv(os.path.join(out_dir, "initial_feature_summary.csv"), initial_summary, initial_summary_fields)

        selected_rows = select_initial_rows_for_runs(initial_rows, int(args.seeds_per_family))
        trajectory_rows = []
        saved_score0_hashes = set()
        print("Running trajectories:", len(selected_rows))
        for idx, initial_row in enumerate(selected_rows, start=1):
            row = run_family_trajectory(initial_row, idx, p, ks, lam, baseline, args, out_dir, saved_score0_hashes)
            trajectory_rows.append(row)
            print(
                "trajectory family={} seed={} start={} end={} best={} label={}".format(
                    row["family"], row["seed"], row["score_start"], row["score_end"], row["score_best"], row["final_label"]
                )
            )
            sys.stdout.flush()
        write_jsonl(os.path.join(out_dir, "trajectory_by_family.jsonl"), trajectory_rows)

        fam_summary = family_summary(trajectory_rows)
        family_summary_fields = [
            "family",
            "run_count",
            "success_score0_count",
            "false_basin_final_count",
            "escapable_final_count",
            "unknown_final_count",
            "false_basin_rate",
            "escapable_rate",
            "success_rate",
            "median_initial_score",
            "median_initial_score_randnorm",
            "median_initial_InitHardness",
            "median_initial_Q_ratio",
            "median_initial_P_8",
            "median_initial_kappa_max",
            "median_final_score",
            "median_best_score",
            "median_final_D_min_ratio",
            "median_final_P_8",
            "median_final_kappa_max",
            "median_final_Q_ratio",
            "distinct_initial_hashes",
            "distinct_final_hashes",
            "label_entropy",
        ]
        write_csv(os.path.join(out_dir, "family_summary.csv"), fam_summary, family_summary_fields)
        write_json_safe(os.path.join(out_dir, "family_summary.json"), {"rows": fam_summary})

        good_rule_rows, good_rule_summary = good_init_rule_evaluation(trajectory_rows)
        write_csv(
            os.path.join(out_dir, "good_init_rule_evaluation.csv"),
            good_rule_rows,
            [
                "row_type",
                "run_id",
                "family",
                "GoodInitRule",
                "final_label",
                "positive_actual",
                "score_randnorm",
                "InitHardness",
                "P_8",
                "tp",
                "fp",
                "tn",
                "fn",
                "unknown",
                "good_count",
                "bad_count",
                "accuracy_known",
                "precision_known",
                "recall_known",
                "false_basin_rate_good_known",
                "false_basin_rate_bad_known",
                "score_randnorm_median",
                "InitHardness_median",
                "P_8_median",
            ],
        )

        score_rows, score_stats = exact_like_score_rows(trajectory_rows)
        write_jsonl(os.path.join(out_dir, "exact_like_scores.jsonl"), score_rows)
        hyp = hypothesis_evaluation(fam_summary, good_rule_summary, score_rows)
        hyp["ExactLikeScore_z_stats"] = score_stats
        hyp["skipped_families_or_attempts"] = skipped
        write_json_safe(os.path.join(out_dir, "hypothesis_evaluation.json"), hyp)
        make_summary(
            os.path.join(out_dir, "p37_initialization_family_comparison_summary.md"),
            {
                "p": p,
                "ks": [int(k) for k in ks],
                "lambda": lam,
                "families": list(families),
                "candidates_per_family": int(args.candidates_per_family),
                "seeds_per_family": int(args.seeds_per_family),
                "steps": int(args.steps),
                "family_summary": fam_summary,
                "hypotheses": hyp,
                "skipped": skipped,
                "ap_coefficients": ap_coefficients,
            },
        )
        print("SUMMARY:", os.path.join(out_dir, "p37_initialization_family_comparison_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
