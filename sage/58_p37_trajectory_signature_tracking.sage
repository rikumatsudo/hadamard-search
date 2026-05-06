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


SCRIPT_NAME = "58_p37_trajectory_signature_tracking"
POWERS = (2, 4, 6, 8, 10, 12)
DEFAULT_MODES = "score_only,threshold_accepting,mixed_diversity,exact_derived_return"
TRACK_FEATURES = (
    "score",
    "D_min_ratio",
    "P_4",
    "P_8",
    "P_16",
    "kappa_max",
    "Q_ratio",
    "InitHardness",
)
SNAPSHOT_FIELDS = (
    "run_id",
    "mode",
    "seed",
    "step",
    "accepted_moves",
    "score",
    "l1",
    "max_abs",
    "nonzero",
    "h_min",
    "D_min_1",
    "D_min_ratio",
    "P_<0",
    "P_0",
    "P_4",
    "P_8",
    "P_16",
    "P_thetaS_001",
    "P_thetaS_005",
    "P_thetaS_010",
    "kappa_max",
    "kappa_q90",
    "kappa_q99",
    "Q_ratio",
    "Q_tot",
    "InitHardness",
    "E_total",
    "AP_total",
    "moment_zero_count_3",
    "moment_zero_count_6",
    "label_if_available",
    "canonical_hash",
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


def parse_modes(text):
    return tuple(part.strip() for part in str(text).split(",") if part.strip())


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
        "kappa_q99": quantile(kappas, 0.99),
        "Q_ratio": float(sum(q_values)) / float(q_threshold) if q_threshold > 0 else None,
        "Q_tot": int(sum(q_values)),
        "InitHardness": float(structure["InitHardness"]),
        "E_total": int(structure["E_total"]),
        "AP_total": int(structure["AP_total"]),
        "improving_swap_count": int(len(improving)),
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


def deterministic_mode_offset(mode):
    return sum((idx + 1) * ord(ch) for idx, ch in enumerate(str(mode)))


def rank_initial_candidate(blocks, p, lam, baseline, family):
    counts = total_diff_counts(p, blocks)
    score = score_counts(counts, lam)
    structure = block_structure_payload(p, blocks, baseline)
    e_score = max(1.0, float(baseline["E_score"]))
    e_q = max(1.0, float(abs(baseline["E_Q_total"])))
    if family == "pure_random":
        return (0.0, score)
    if family == "low_energy_random":
        return (abs(structure["InitHardness"]) / e_q, score)
    if family == "score_biased_random":
        return (float(score), structure["InitHardness"])
    if family == "energy_regularized":
        return (float(score) / e_score + 0.25 * max(0.0, structure["InitHardness"]) / e_q, score)
    if family == "mixed_diversity":
        return (float(score) / e_score + 0.05 * abs(structure["InitHardness"]) / e_q, -structure["InitHardness"])
    return (float(score), structure["InitHardness"])


def discover_existing_candidates(p, ks, lam, max_candidates, score_max=None):
    roots = [os.path.join("outputs", "candidates", "small_p"), os.path.join("outputs", "explorations")]
    paths = []
    for root in roots:
        if os.path.isdir(root):
            paths.extend(glob.glob(os.path.join(root, "**", "*.json"), recursive=True))
    found = []
    seen = set()
    for path in sorted(paths):
        if os.path.getsize(path) > 2_000_000:
            continue
        try:
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
        found.append({"path": path, "blocks": clone_blocks(blocks), "score": int(score)})
        if len(found) >= int(max_candidates):
            break
    return found


def perturb_exact_with_inverse_moves(rng, exact_blocks, p, radius):
    blocks = clone_blocks(exact_blocks)
    inverse_moves = []
    for _ in range(int(radius)):
        move = random_swap(rng, blocks, p)
        if apply_swap_to_blocks(blocks, move):
            inverse_moves.append({"block": int(move["block"]), "removed": int(move["added"]), "added": int(move["removed"])})
    inverse_moves.reverse()
    return blocks, inverse_moves


def initial_blocks_for_mode(mode, rng, p, ks, lam, baseline, exact_blocks, near_hits, args):
    if mode == "threshold_accepting" and near_hits and rng.random() < 0.5:
        source = near_hits[rng.randrange(len(near_hits))]
        return clone_blocks(source["blocks"]), "near_hit_seed", []
    if mode == "exact_derived_return" and exact_blocks is not None:
        blocks, inverse = perturb_exact_with_inverse_moves(rng, exact_blocks, p, int(args.exact_perturb_radius))
        return blocks, "exact_perturbation", inverse
    if mode == "mixed_diversity":
        family = rng.choice(("pure_random", "low_energy_random", "score_biased_random", "energy_regularized", "mixed_diversity"))
    else:
        family = "pure_random"
    if family == "pure_random":
        return random_blocks(rng, p, ks), family, []
    pool = []
    for _ in range(max(1, int(args.init_pool))):
        candidate = random_blocks(rng, p, ks)
        pool.append((rank_initial_candidate(candidate, p, lam, baseline, family), candidate))
    pool.sort(key=lambda item: item[0])
    return clone_blocks(pool[0][1]), family, []


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


def label_snapshot(mode, diag, score):
    if int(score) == 0:
        return "exact"
    if mode == "exact_derived_return":
        return "exact_derived"
    if diag.get("h_min") is not None and diag.get("D_min_ratio") is not None:
        if int(score) <= 8 and int(diag["h_min"]) > 0 and float(diag["D_min_ratio"]) > 1.0 and float(diag.get("P_<0") or 0.0) == 0.0:
            return "false_basin_like"
        if int(diag["h_min"]) < 0 or float(diag["D_min_ratio"]) < 1.0:
            return "escapable_like"
    return "unknown"


def make_snapshot(run_id, mode, seed, step, accepted, blocks, counts, lam, p, ks, baseline):
    diag = full_diagnostic(blocks, counts, lam, p, baseline)
    row = {
        "run_id": run_id,
        "mode": mode,
        "seed": int(seed),
        "step": int(step),
        "accepted_moves": int(accepted),
        "canonical_hash": canonical_hash(blocks, ks, p),
    }
    row.update(diag)
    row["label_if_available"] = label_snapshot(mode, diag, diag["score"])
    return row


def outcome_label(final_snapshot):
    score = final_snapshot.get("score")
    if score is not None and int(score) == 0:
        return "success_score0"
    h_min = final_snapshot.get("h_min")
    ratio = final_snapshot.get("D_min_ratio")
    p_neg = final_snapshot.get("P_<0")
    if score is not None and int(score) > 0 and h_min is not None and ratio is not None:
        if int(h_min) > 0 and float(ratio) > 1.0 and float(p_neg or 0.0) == 0.0:
            return "false_basin_final"
        if int(h_min) < 0 or float(ratio) < 1.0:
            return "escapable_final"
    return "unknown_final"


def slope_simple(start, end, steps):
    if start is None or end is None or steps is None or int(steps) == 0:
        return None
    return float(end - start) / float(steps)


def ls_slope(points):
    clean = [(float(x), float(y)) for x, y in points if y is not None]
    if len(clean) < 2:
        return None
    xs = [x for x, _y in clean]
    ys = [y for _x, y in clean]
    x_mean = sum(xs) / float(len(xs))
    y_mean = sum(ys) / float(len(ys))
    denom = sum((x - x_mean) ** 2 for x in xs)
    if denom == 0:
        return None
    return sum((x - x_mean) * (y - y_mean) for x, y in clean) / denom


def summarize_run(run_id, mode, seed, family, snapshots, accepted_moves):
    snapshots = sorted(snapshots, key=lambda row: int(row["step"]))
    start = snapshots[0]
    end = snapshots[-1]
    steps = max(1, int(end["step"]) - int(start["step"]))
    out = {
        "run_id": run_id,
        "mode": mode,
        "seed": int(seed),
        "family": family,
        "snapshot_count": int(len(snapshots)),
        "accepted_moves": int(accepted_moves),
        "score_start": start.get("score"),
        "score_end": end.get("score"),
        "score_best": min(int(row["score"]) for row in snapshots if row.get("score") is not None),
        "final_label": outcome_label(end),
        "final_canonical_hash": end.get("canonical_hash"),
    }
    for feature in TRACK_FEATURES:
        start_key = "{}_start".format(feature)
        end_key = "{}_end".format(feature)
        slope_key = "{}_slope".format(feature)
        ls_key = "{}_ls_slope".format(feature)
        out[start_key] = start.get(feature)
        out[end_key] = end.get(feature)
        out[slope_key] = slope_simple(start.get(feature), end.get(feature), steps)
        out[ls_key] = ls_slope([(row["step"], row.get(feature)) for row in snapshots])
    return out


def save_score0_candidate(out_dir, run_id, mode, seed, blocks, p, ks, lam, counts):
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
        "run_id": run_id,
        "mode": mode,
        "seed": int(seed),
        "canonical_hash": canonical_hash(blocks, ks, p),
        "canonical_repr_summary": canonical_repr_summary(blocks, ks, p),
        "error_histogram": error_histogram(counts, lam),
    }
    path = os.path.join(out_dir, "score0_candidate_{}.json".format(run_id))
    write_json_safe(path, payload)
    return path


def run_one_trajectory(mode, seed, p, ks, lam, baseline, exact_blocks, near_hits, args, out_dir, saved_score0_hashes):
    run_id = "{}_seed{}".format(mode, seed)
    rng = random.Random(int(args.seed + 1000003 * int(seed) + deterministic_mode_offset(mode)))
    blocks, family, inverse_moves = initial_blocks_for_mode(mode, rng, p, ks, lam, baseline, exact_blocks, near_hits, args)
    counts = total_diff_counts(p, blocks)
    accepted = 0
    snapshots = []
    snapshot_steps = set([0, int(args.steps)])
    for step in range(0, int(args.steps) + 1, int(args.snapshot_interval)):
        snapshot_steps.add(int(step))
    if mode == "exact_derived_return":
        snapshot_steps.update(range(0, min(int(args.steps), int(args.exact_perturb_radius) + 2) + 1))
    score0_paths = []
    for step in range(int(args.steps) + 1):
        if step in snapshot_steps and len(snapshots) < int(args.full_diagnostic_max_per_run):
            snapshots.append(make_snapshot(run_id, mode, seed, step, accepted, blocks, counts, lam, p, ks, baseline))
        score = score_counts(counts, lam)
        if score == 0:
            key = canonical_hash(blocks, ks, p)
            if key not in saved_score0_hashes:
                saved_score0_hashes.add(key)
                score0_paths.append(save_score0_candidate(out_dir, run_id, mode, seed, blocks, p, ks, lam, counts))
            if mode == "exact_derived_return":
                break
        if step >= int(args.steps):
            break
        move_item = None
        accept = False
        if mode == "exact_derived_return" and inverse_moves:
            move = inverse_moves.pop(0)
            new_counts = apply_move_to_counts(p, blocks, counts, move)
            move_item = {"move": move, "new_counts": new_counts, "DeltaS": int(score_counts(new_counts, lam) - score)}
            accept = True
        else:
            move_item = sample_best_move(rng, blocks, counts, lam, p, int(args.candidate_samples), float(args.targeted_prob))
            delta_s = int(move_item["DeltaS"])
            if delta_s < 0:
                accept = True
            elif mode == "threshold_accepting" and delta_s <= int(args.threshold_accepting_delta):
                accept = True
            elif mode == "mixed_diversity" and delta_s <= int(args.allowed_worsen):
                accept = rng.random() < math.exp(-float(max(0, delta_s)) / max(0.01, float(args.escape_temperature)))
            elif rng.random() < float(args.random_walk_prob):
                accept = True
        if accept:
            move = move_item["move"]
            if apply_swap_to_blocks(blocks, move):
                counts = list(move_item["new_counts"])
                accepted += 1
    if not snapshots or int(snapshots[-1]["step"]) != min(int(args.steps), step):
        snapshots.append(make_snapshot(run_id, mode, seed, step, accepted, blocks, counts, lam, p, ks, baseline))
    summary = summarize_run(run_id, mode, seed, family, snapshots, accepted)
    summary["score0_candidate_paths"] = score0_paths
    return snapshots, summary


def median(values):
    values = sorted([float(v) for v in values if v is not None])
    if not values:
        return None
    n = len(values)
    if n % 2:
        return values[n // 2]
    return (values[n // 2 - 1] + values[n // 2]) / 2.0


def score_bin(score):
    if score is None:
        return "missing"
    score = int(score)
    if score <= 4:
        return "0-4"
    if score <= 8:
        return "5-8"
    if score <= 16:
        return "9-16"
    if score <= 32:
        return "17-32"
    if score <= 64:
        return "33-64"
    if score <= 128:
        return "65-128"
    return ">128"


def score_binned_summary(snapshots, run_summaries):
    labels = {row["run_id"]: row["final_label"] for row in run_summaries}
    groups = {}
    for row in snapshots:
        key = (row["mode"], labels.get(row["run_id"], "unknown_final"), score_bin(row.get("score")))
        groups.setdefault(key, []).append(row)
    out = []
    for key, rows in sorted(groups.items()):
        mode, final_label, bin_name = key
        out.append(
            {
                "mode": mode,
                "final_label": final_label,
                "score_bin": bin_name,
                "count": int(len(rows)),
                "median_D_min_ratio": median([row.get("D_min_ratio") for row in rows]),
                "median_P_4": median([row.get("P_4") for row in rows]),
                "median_P_8": median([row.get("P_8") for row in rows]),
                "median_P_16": median([row.get("P_16") for row in rows]),
                "median_kappa_max": median([row.get("kappa_max") for row in rows]),
                "median_Q_ratio": median([row.get("Q_ratio") for row in rows]),
            }
        )
    return out


def mode_outcome_summary(run_summaries):
    groups = {}
    for row in run_summaries:
        groups.setdefault(row["mode"], []).append(row)
    out = []
    for mode, rows in sorted(groups.items()):
        counts = {}
        for row in rows:
            counts[row["final_label"]] = counts.get(row["final_label"], 0) + 1
        out.append(
            {
                "mode": mode,
                "run_count": int(len(rows)),
                "success_score0": int(counts.get("success_score0", 0)),
                "false_basin_final": int(counts.get("false_basin_final", 0)),
                "escapable_final": int(counts.get("escapable_final", 0)),
                "unknown_final": int(counts.get("unknown_final", 0)),
                "median_score_best": median([row.get("score_best") for row in rows]),
                "median_score_end": median([row.get("score_end") for row in rows]),
                "median_P_8_slope": median([row.get("P_8_ls_slope") for row in rows]),
                "median_Q_ratio_slope": median([row.get("Q_ratio_ls_slope") for row in rows]),
            }
        )
    return out


def fraction(items, predicate):
    if not items:
        return None
    return float(sum(1 for item in items if predicate(item))) / float(len(items))


def hypothesis_evaluation(run_summaries, snapshots):
    by_run = {}
    for row in snapshots:
        by_run.setdefault(row["run_id"], []).append(row)
    false_runs = [row for row in run_summaries if row["final_label"] == "false_basin_final"]
    exact_runs = [row for row in run_summaries if row["mode"] == "exact_derived_return" or row["final_label"] == "success_score0"]
    score_only = [row for row in run_summaries if row["mode"] == "score_only"]
    threshold = [row for row in run_summaries if row["mode"] == "threshold_accepting"]
    mixed = [row for row in run_summaries if row["mode"] == "mixed_diversity"]

    def score_decreases(row):
        return row.get("score_end") is not None and row.get("score_start") is not None and float(row["score_end"]) < float(row["score_start"])

    h4_support = fraction(false_runs, lambda row: score_decreases(row) and (row.get("D_min_ratio_end") or 0) > 1.0 and (row.get("P_8_ls_slope") or 0) <= 0 and (row.get("kappa_max_end") or 999) < 1.0)
    h5_support = fraction(exact_runs, lambda row: score_decreases(row) and (row.get("D_min_ratio_ls_slope") is None or row.get("D_min_ratio_ls_slope") <= 0) and (row.get("P_8_end") or 0) >= (row.get("P_8_start") or 0) and (row.get("kappa_max_end") or 0) >= 1.0)
    h15_support = fraction(score_only, lambda row: score_decreases(row) and row.get("Q_ratio_ls_slope") is not None and row.get("Q_ratio_ls_slope") > 0)
    h16_support = fraction(false_runs, lambda row: (row.get("P_4_ls_slope") or 0) < 0 or (row.get("P_8_ls_slope") or 0) < 0 or (row.get("P_16_ls_slope") or 0) < 0)
    h17_support = fraction(false_runs, lambda row: row.get("kappa_max_end") is not None and float(row["kappa_max_end"]) < 1.0)
    exact_trap_runs = 0
    for row in exact_runs:
        pre = [snap for snap in by_run.get(row["run_id"], []) if int(snap.get("score") or 0) > 0]
        if not pre:
            continue
        last = sorted(pre, key=lambda snap: int(snap["step"]))[-1]
        if (last.get("D_min_ratio") or 0) > 1 and (last.get("P_8") or 1) <= 0.01 and (last.get("kappa_max") or 999) < 1:
            exact_trap_runs += 1
    h6_support = float(exact_trap_runs) / float(len(exact_runs)) if exact_runs else None
    return {
        "H4_false_basin_paths_disappear": {"support_fraction": h4_support, "run_count": int(len(false_runs))},
        "H5_exact_paths_remain": {"support_fraction": h5_support, "run_count": int(len(exact_runs))},
        "H6_exact_basin_trap_like": {"support_fraction": h6_support, "run_count": int(len(exact_runs))},
        "H15_score_only_Q_hardening": {"support_fraction": h15_support, "run_count": int(len(score_only))},
        "H16_false_basin_P_tau_declines": {"support_fraction": h16_support, "run_count": int(len(false_runs))},
        "H17_false_basin_kappa_below_1": {"support_fraction": h17_support, "run_count": int(len(false_runs))},
        "threshold_accepting": {
            "run_count": int(len(threshold)),
            "escapable_final_count": int(sum(1 for row in threshold if row["final_label"] == "escapable_final")),
            "false_basin_final_count": int(sum(1 for row in threshold if row["final_label"] == "false_basin_final")),
            "median_P_8_slope": median([row.get("P_8_ls_slope") for row in threshold]),
        },
        "mixed_diversity": {
            "run_count": int(len(mixed)),
            "distinct_final_hashes": int(len(set(row.get("final_canonical_hash") for row in mixed))),
            "median_P_8_slope": median([row.get("P_8_ls_slope") for row in mixed]),
            "median_Q_ratio_slope": median([row.get("Q_ratio_ls_slope") for row in mixed]),
        },
    }


def verdict(value):
    if value is None:
        return "undetermined"
    if value >= 0.67:
        return "supported"
    if value >= 0.34:
        return "mixed"
    return "not_supported"


def make_summary(path, context):
    hyp = context["hypotheses"]
    outcome = context["mode_outcomes"]
    lines = [
        "# p37 Trajectory Signature Tracking Summary",
        "",
        "This run tracks trajectory signatures on p=37. It is not a Hadamard 668 construction run.",
        "",
        "## Run",
        "",
        "- p: `{}`".format(context["p"]),
        "- ks: `{}`".format(context["ks"]),
        "- lambda: `{}`".format(context["lambda"]),
        "- modes: `{}`".format(context["modes"]),
        "- seeds: `{}`".format(context["seeds"]),
        "- steps: `{}`".format(context["steps"]),
        "- snapshot_interval: `{}`".format(context["snapshot_interval"]),
        "",
        "## Outcomes",
        "",
        "```json",
        json.dumps(json_safe(outcome), indent=2, sort_keys=True),
        "```",
        "",
        "## Hypothesis Evaluation",
        "",
        "```json",
        json.dumps(json_safe(hyp), indent=2, sort_keys=True),
        "```",
        "",
        "## Required Answers",
        "",
        "1. false_basin_final trajectory は score が下がるほど D_min/S が悪化したか: `{}`.".format(verdict(hyp["H4_false_basin_paths_disappear"]["support_fraction"])),
        "2. false_basin_final trajectory は P_tau が低下したか: `{}`.".format(verdict(hyp["H16_false_basin_P_tau_declines"]["support_fraction"])),
        "3. false_basin_final trajectory は kappa_max < 1 に閉じ込められたか: `{}`.".format(verdict(hyp["H17_false_basin_kappa_below_1"]["support_fraction"])),
        "4. score-only は Q_ratio を悪化させやすかったか: `{}`.".format(verdict(hyp["H15_score_only_Q_hardening"]["support_fraction"])),
        "5. threshold_accepting は false basin から抜ける兆候を作ったか: escapable_final `{}`, false_basin_final `{}`。".format(hyp["threshold_accepting"]["escapable_final_count"], hyp["threshold_accepting"]["false_basin_final_count"]),
        "6. mixed_diversity は trajectory diversity を増やしたか: distinct final hashes `{}` / runs `{}`。".format(hyp["mixed_diversity"]["distinct_final_hashes"], hyp["mixed_diversity"]["run_count"]),
        "7. exact-derived または success trajectory は蟻地獄型だったか、それとも落とし穴型だったか: H5 `{}`, H6 `{}`。".format(verdict(hyp["H5_exact_paths_remain"]["support_fraction"]), verdict(hyp["H6_exact_basin_trap_like"]["support_fraction"])),
        "8. H4, H5, H6, H15, H16, H17 の判定: H4 `{}`, H5 `{}`, H6 `{}`, H15 `{}`, H16 `{}`, H17 `{}`。".format(
            verdict(hyp["H4_false_basin_paths_disappear"]["support_fraction"]),
            verdict(hyp["H5_exact_paths_remain"]["support_fraction"]),
            verdict(hyp["H6_exact_basin_trap_like"]["support_fraction"]),
            verdict(hyp["H15_score_only_Q_hardening"]["support_fraction"]),
            verdict(hyp["H16_false_basin_P_tau_declines"]["support_fraction"]),
            verdict(hyp["H17_false_basin_kappa_below_1"]["support_fraction"]),
        ),
        "9. 次に p=43/47/668 へ拡張すべきか: `yes`, but use these as heuristic trajectory signatures, not absolute proof.",
        "10. 668 の frontier / restart policy にどう反映すべきか: keep candidates with decreasing D_min/S and non-collapsing P_tau/kappa; restart or de-prioritize score drops with rising Q_ratio and vanishing P_tau.",
    ]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Track p37 trajectory signatures for false/exact basin diagnostics.")
    parser.add_argument("--p", type=int, default=37)
    parser.add_argument("--ks", type=parse_ks, default=(13, 16, 18, 18))
    parser.add_argument("--lambda", dest="lam", type=int, default=28)
    parser.add_argument("--exact-json", default="outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json")
    parser.add_argument("--modes", default=DEFAULT_MODES)
    parser.add_argument("--seeds", type=int, default=20)
    parser.add_argument("--steps", type=int, default=3000)
    parser.add_argument("--snapshot-interval", type=int, default=100)
    parser.add_argument("--full-diagnostic-max-per-run", type=int, default=40)
    parser.add_argument("--candidate-samples", type=int, default=24)
    parser.add_argument("--targeted-prob", type=float, default=0.30)
    parser.add_argument("--allowed-worsen", type=int, default=8)
    parser.add_argument("--escape-temperature", type=float, default=8.0)
    parser.add_argument("--random-walk-prob", type=float, default=0.002)
    parser.add_argument("--threshold-accepting-delta", type=int, default=8)
    parser.add_argument("--init-pool", type=int, default=12)
    parser.add_argument("--exact-perturb-radius", type=int, default=4)
    parser.add_argument("--seed", type=int, default=58037)
    parser.add_argument("--out-dir", default=None)
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        p = int(args.p)
        ks = tuple(int(k) for k in args.ks)
        lam = int(args.lam)
        validate_params(p, ks, lam)
        modes = parse_modes(args.modes)
        out_dir = args.out_dir or os.path.join("outputs", "explorations", "{}_p37_trajectory_signature_tracking".format(now_stamp()))
        ensure_dir(out_dir)
        run_config = {
            "script": SCRIPT_NAME,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "p": int(p),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "exact_json": args.exact_json,
            "modes": list(modes),
            "seeds": int(args.seeds),
            "steps": int(args.steps),
            "snapshot_interval": int(args.snapshot_interval),
            "full_diagnostic_max_per_run": int(args.full_diagnostic_max_per_run),
            "candidate_samples": int(args.candidate_samples),
            "out_dir": out_dir,
            "note": "score=0 only is success; p=37 trajectory signature validation only.",
        }
        write_json_safe(os.path.join(out_dir, "run_config.json"), run_config)
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# Run Log\n\n")
            f.write("- script: `{}`\n".format(SCRIPT_NAME))
            f.write("- modes: `{}`\n".format(list(modes)))
            f.write("- score=0 only is success\n")

        exact_blocks = None
        if args.exact_json and os.path.exists(args.exact_json):
            _data, _v, _n, _ks, _lam, exact_blocks = load_candidate(args.exact_json)
        baseline = random_baseline_tuple(p, ks)
        near_hits = discover_existing_candidates(p, ks, lam, max_candidates=20, score_max=8)
        all_snapshots = []
        run_summaries = []
        saved_score0_hashes = set()
        for mode in modes:
            for seed in range(1, int(args.seeds) + 1):
                snapshots, summary = run_one_trajectory(mode, seed, p, ks, lam, baseline, exact_blocks, near_hits, args, out_dir, saved_score0_hashes)
                all_snapshots.extend(snapshots)
                run_summaries.append(summary)
                print("mode={} seed={} final={} best={} label={}".format(mode, seed, summary["score_end"], summary["score_best"], summary["final_label"]))
                sys.stdout.flush()

        write_jsonl(os.path.join(out_dir, "trajectory_snapshots.jsonl"), all_snapshots)
        summary_fields = [
            "run_id", "mode", "seed", "family", "snapshot_count", "accepted_moves",
            "score_start", "score_end", "score_best", "score_slope", "score_ls_slope",
            "D_min_ratio_start", "D_min_ratio_end", "D_min_ratio_slope", "D_min_ratio_ls_slope",
            "P_4_start", "P_4_end", "P_4_slope", "P_4_ls_slope",
            "P_8_start", "P_8_end", "P_8_slope", "P_8_ls_slope",
            "P_16_start", "P_16_end", "P_16_slope", "P_16_ls_slope",
            "kappa_max_start", "kappa_max_end", "kappa_max_slope", "kappa_max_ls_slope",
            "Q_ratio_start", "Q_ratio_end", "Q_ratio_slope", "Q_ratio_ls_slope",
            "InitHardness_start", "InitHardness_end", "InitHardness_slope", "InitHardness_ls_slope",
            "final_label", "final_canonical_hash", "score0_candidate_paths",
        ]
        write_csv(os.path.join(out_dir, "trajectory_run_summary.csv"), run_summaries, summary_fields)
        write_json_safe(os.path.join(out_dir, "trajectory_run_summary.json"), {"runs": run_summaries})

        bin_rows = score_binned_summary(all_snapshots, run_summaries)
        write_csv(
            os.path.join(out_dir, "score_binned_signature_summary.csv"),
            bin_rows,
            ["mode", "final_label", "score_bin", "count", "median_D_min_ratio", "median_P_4", "median_P_8", "median_P_16", "median_kappa_max", "median_Q_ratio"],
        )
        write_json_safe(os.path.join(out_dir, "score_binned_signature_summary.json"), {"rows": bin_rows})

        outcome_rows = mode_outcome_summary(run_summaries)
        write_csv(
            os.path.join(out_dir, "mode_outcome_summary.csv"),
            outcome_rows,
            ["mode", "run_count", "success_score0", "false_basin_final", "escapable_final", "unknown_final", "median_score_best", "median_score_end", "median_P_8_slope", "median_Q_ratio_slope"],
        )
        write_json_safe(os.path.join(out_dir, "mode_outcome_summary.json"), {"rows": outcome_rows})

        hyp = hypothesis_evaluation(run_summaries, all_snapshots)
        write_json_safe(os.path.join(out_dir, "hypothesis_evaluation.json"), hyp)
        make_summary(
            os.path.join(out_dir, "p37_trajectory_signature_tracking_summary.md"),
            {
                "p": p,
                "ks": [int(k) for k in ks],
                "lambda": lam,
                "modes": list(modes),
                "seeds": int(args.seeds),
                "steps": int(args.steps),
                "snapshot_interval": int(args.snapshot_interval),
                "mode_outcomes": outcome_rows,
                "hypotheses": hyp,
            },
        )
        print("SUMMARY:", os.path.join(out_dir, "p37_trajectory_signature_tracking_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
