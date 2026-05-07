from sage.all import *

import argparse
import csv
import json
import math
import os
import random
import statistics
import subprocess
import sys
import time


SCRIPT_NAME = "63_dynamic_defect_weighting_validation"
SCORE_SET = set([4, 8, 12, 16, 24, 32])
MODES = (
    "baseline_score_only_recheck",
    "static_weighted_score",
    "dynamic_weighting_basic",
    "dynamic_weighting_stubborn",
    "dynamic_weighting_breakout",
    "dynamic_weighting_with_exactlike_guard",
)
POWERS_DEFAULT = (2, 4, 6, 8, 10, 12)


def load_s62():
    here = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.path.join(os.getcwd(), "sage")
    path = os.path.join(here, "62_exactlike_guided_generator_validation.sage")
    ns = {"__name__": "sds62_dynamic_import"}
    with open(path) as f:
        code = compile(f.read(), path, "exec")
    exec(code, ns)
    return ns


S62 = load_s62()


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def ensure_dir(path):
    if path:
        os.makedirs(path, exist_ok=True)


def json_safe(value):
    return S62["json_safe"](value)


def public_row(row):
    return S62["public_row"](row)


def write_json(path, payload):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as f:
        json.dump(json_safe(payload), f, indent=2, sort_keys=True)
        f.write("\n")


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


def median(values):
    values = [float(v) for v in values if v is not None]
    return statistics.median(values) if values else None


def mean(values):
    values = [float(v) for v in values if v is not None]
    return statistics.mean(values) if values else None


def count_by(rows, key):
    out = {}
    for row in rows:
        value = row.get(key)
        value = "missing" if value is None else str(value)
        out[value] = out.get(value, 0) + 1
    return {key: int(out[key]) for key in sorted(out)}


def histogram_int(rows, key):
    out = {}
    for row in rows:
        value = row.get(key)
        label = "missing" if value is None else str(int(value))
        out[label] = out.get(label, 0) + 1
    return {key: int(out[key]) for key in sorted(out, key=lambda x: (x == "missing", int(x) if x != "missing" else 0))}


def parse_ks(text):
    return tuple(int(x.strip()) for x in text.split(",") if x.strip())


def clone_blocks(blocks):
    return S62["clone_blocks"](blocks)


def blocks_from_payload(payload):
    raw = payload.get("blocks") or payload.get("X") or payload.get("sets")
    if raw is None:
        return None
    try:
        blocks = [set(int(x) for x in block) for block in raw]
    except Exception:
        return None
    return blocks if len(blocks) == 4 else None


def validate_blocks(blocks, p, ks):
    if blocks is None or len(blocks) != 4:
        return False
    for block, k in zip(blocks, ks):
        if len(block) != int(k):
            return False
        if len(block) != len(set(block)):
            return False
        if any(int(x) < 0 or int(x) >= int(p) for x in block):
            return False
    return True


def candidate_origin(payload, source_path):
    text = " ".join(
        str(payload.get(key, ""))
        for key in ("origin", "origin_type", "origin_family", "mode", "source", "source_path", "label")
    ).lower()
    source = source_path.lower()
    if "exact_perturb" in text or "exact_derived" in text or "exact_perturb" in source:
        return "exact_derived"
    if int(payload.get("score", -1) or -1) == 0:
        return "exact"
    if "false" in text or "search" in text or "trajectory" in text or "score_only" in text or "threshold" in text:
        return "search_derived"
    return "search_derived"


def iter_payloads_from_file(path):
    try:
        if path.endswith(".jsonl"):
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        payload = json.loads(line)
                    except Exception:
                        continue
                    if isinstance(payload, dict):
                        yield payload
        elif path.endswith(".json"):
            with open(path) as f:
                payload = json.load(f)
            if isinstance(payload, list):
                for item in payload:
                    if isinstance(item, dict):
                        yield item
            elif isinstance(payload, dict):
                yield payload
                for key in ("rows", "candidates", "results"):
                    items = payload.get(key)
                    if isinstance(items, list):
                        for item in items:
                            if isinstance(item, dict):
                                yield item
    except Exception:
        return


def candidate_search_paths():
    return [
        "outputs/explorations/20260506_0915_small_p_escapability_validation",
        "outputs/explorations/20260506_1125_small_p_defect_targeted_lns_validation",
        "outputs/explorations/20260506_1200_p37_score4_false_basin_anatomy",
        "outputs/explorations/20260506_1557_p37_pipeline_framework",
        "outputs/explorations/20260506_1619_p37_classifier_feature_analysis",
        "outputs/explorations/20260506_1950_p37_exact_vs_search_low_score_comparison",
        "outputs/explorations/20260506_2216_p37_repair_lns_ablation",
        "outputs/explorations/20260507_0019_p37_exactlike_guided_generator_medium",
        "outputs/candidates/small_p",
    ]


def collect_payload_candidates(p, ks, lam):
    selected_files = []
    for root in candidate_search_paths():
        if not os.path.exists(root):
            continue
        if os.path.isfile(root):
            selected_files.append(root)
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                if not (name.endswith(".json") or name.endswith(".jsonl")):
                    continue
                selected_files.append(os.path.join(dirpath, name))
    raw = {}
    for path in selected_files:
        for payload in iter_payloads_from_file(path):
            blocks = blocks_from_payload(payload)
            if not validate_blocks(blocks, p, ks):
                continue
            counts = S62["total_diff_counts"](p, blocks)
            score = S62["score_counts"](counts, lam)
            if int(score) not in SCORE_SET:
                continue
            stored = payload.get("score")
            if stored is not None and int(stored) != int(score):
                continue
            h = S62["canonical_hash"](blocks, ks, p)
            if h not in raw:
                raw[h] = {
                    "blocks": S62["json_blocks"](blocks),
                    "score": int(score),
                    "origin_type": candidate_origin(payload, path),
                    "source_path": path,
                    "source_label": payload.get("label"),
                    "source_mode": payload.get("mode"),
                    "source_origin": payload.get("origin") or payload.get("origin_type") or payload.get("origin_family"),
                    "canonical_hash": h,
                }
    return list(raw.values())


def generate_exact_controls(exact_blocks, p, ks, lam, need, seed):
    if exact_blocks is None or need <= 0:
        return []
    rng = random.Random(seed)
    out = {}
    tries = 0
    while len(out) < need and tries < max(500, need * 250):
        tries += 1
        blocks = clone_blocks(exact_blocks)
        radius = rng.choice([1, 2, 3, 4, 5, 6])
        ok = True
        moves = []
        for _ in range(radius):
            move = S62["random_swap"](rng, blocks, p)
            if not S62["apply_swap_to_blocks"](blocks, move):
                ok = False
                break
            moves.append(S62["compact_move"](move))
        if not ok:
            continue
        score = S62["quick_score"](blocks, p, lam)
        if score not in SCORE_SET:
            continue
        h = S62["canonical_hash"](blocks, ks, p)
        out[h] = {
            "blocks": S62["json_blocks"](blocks),
            "score": int(score),
            "origin_type": "exact_derived",
            "source_path": "generated_exact_perturbation",
            "perturb_radius": int(radius),
            "applied_moves": moves,
            "canonical_hash": h,
        }
    return list(out.values())


def defect_pattern_signature(counts, lam):
    rho = S62["rho_vector"](counts, lam)
    p = len(rho)
    pairs = []
    positives = 0
    negatives = 0
    other = 0
    support = []
    for d in range(1, p):
        if rho[d] != 0:
            support.append(d)
    seen = set()
    for d in support:
        if d in seen:
            continue
        e = (-d) % p
        seen.add(d)
        seen.add(e)
        a = int(rho[d])
        b = int(rho[e])
        pairs.append((min(d, e), max(d, e), a, b))
        if a == b == 1:
            positives += 1
        elif a == b == -1:
            negatives += 1
        else:
            other += 1
    return {
        "defect_support": support,
        "defect_support_size": int(len(support)),
        "pattern_signature": "+pairs{}_ -pairs{}_ other{}".format(positives, negatives, other),
        "positive_defect_pairs": int(positives),
        "negative_defect_pairs": int(negatives),
        "other_defect_pairs": int(other),
    }


def make_parent_rows(payloads, p, ks, lam, baseline, powers):
    rows = []
    for idx, item in enumerate(payloads):
        blocks = [set(block) for block in item["blocks"]]
        row = S62["candidate_record"](
            blocks,
            p,
            ks,
            lam,
            baseline,
            origin=item.get("origin_type") or "candidate_pool",
            mode="parent_pool",
            seed=None,
            step=idx,
            family=item.get("origin_type") or "candidate_pool",
            extra={
                "parent_origin_type": item.get("origin_type"),
                "source_path": item.get("source_path"),
                "source_label": item.get("source_label"),
                "source_mode": item.get("source_mode"),
                "source_origin": item.get("source_origin"),
                "perturb_radius": item.get("perturb_radius"),
            },
            powers=powers,
        )
        row.update(defect_pattern_signature(row["_counts"], lam))
        row["label"] = S62["label_candidate"](row, {})
        rows.append(row)
    S62["apply_exactlike_scores"](rows, default_exactlike_cfg())
    return rows


def default_exactlike_cfg():
    return {
        "exactlike_score": {
            "features": {
                "D_min_ratio": {"weight": -1.0, "transform": "zscore"},
                "P_4": {"weight": 1.0, "transform": "zscore"},
                "P_8": {"weight": 1.0, "transform": "zscore"},
                "kappa_max": {"weight": 1.0, "transform": "zscore"},
                "Q_ratio": {"weight": -0.25, "transform": "zscore"},
            }
        }
    }


def select_parent_payloads(raw_payloads, max_total, exact_blocks, p, ks, lam, seed):
    by_hash = {item["canonical_hash"]: item for item in raw_payloads}
    exact_existing = [item for item in by_hash.values() if item.get("origin_type") == "exact_derived"]
    if len(exact_existing) < 20:
        for item in generate_exact_controls(exact_blocks, p, ks, lam, 20 - len(exact_existing), seed + 991):
            by_hash.setdefault(item["canonical_hash"], item)
    items = list(by_hash.values())
    score4_search = [item for item in items if item["score"] == 4 and item.get("origin_type") != "exact_derived"]
    exact_controls = [item for item in items if item.get("origin_type") == "exact_derived"]
    other_search = [
        item
        for item in items
        if item["score"] in (8, 12, 16, 24, 32) and item.get("origin_type") != "exact_derived"
    ]
    score4_search.sort(key=lambda x: (x.get("source_path") or "", x["canonical_hash"]))
    other_search.sort(key=lambda x: (x["score"], x.get("source_path") or "", x["canonical_hash"]))
    exact_controls.sort(key=lambda x: (x["score"], x.get("perturb_radius") or 99, x["canonical_hash"]))
    max_total = int(max_total)
    if max_total >= 60:
        score4_cap, other_cap, exact_cap = 10, 30, 20
    else:
        score4_cap = min(10, max(1, max_total // 3))
        exact_cap = min(20, max(1, max_total // 3))
        other_cap = max_total - score4_cap - exact_cap
        if other_cap < 0:
            other_cap = 0
    selected = []
    selected.extend(score4_search[:score4_cap])
    selected.extend(other_search[:other_cap])
    selected.extend(exact_controls[:exact_cap])
    dedup = {}
    for item in selected:
        dedup.setdefault(item["canonical_hash"], item)
    return list(dedup.values())[: int(max_total)]


def weighted_score_from_rho(rho, weights):
    return float(sum(float(weights[d]) * float(rho[d] * rho[d]) for d in range(1, len(rho))))


def weighted_delta(move, rho, weights):
    g = 0.0
    q = 0.0
    for d, value in move["delta"].items():
        v = int(value)
        w = float(weights[int(d)])
        g += w * float(rho[int(d)]) * float(v)
        q += w * float(v * v)
    h = 2.0 * g + q
    kappa = None if q <= 1e-12 else -2.0 * g / q
    return h, g, q, kappa


def weight_stats(weights):
    values = [float(weights[d]) for d in range(1, len(weights))]
    total = sum(values)
    entropy = 0.0
    if total > 0:
        for value in values:
            prob = value / total
            if prob > 0:
                entropy -= prob * math.log(prob)
    mean_value = statistics.mean(values) if values else 0.0
    std_value = statistics.pstdev(values) if len(values) > 1 else 0.0
    high_threshold = max(1.25, mean_value + std_value)
    high = [d for d in range(1, len(weights)) if float(weights[d]) >= high_threshold]
    return {
        "weight_entropy": float(entropy),
        "weight_max": max(values) if values else None,
        "weight_min": min(values) if values else None,
        "num_high_weight_coords": int(len(high)),
        "high_weight_coords": high,
    }


def sign_vector(rho):
    signs = [0] * len(rho)
    for d in range(1, len(rho)):
        signs[d] = 1 if rho[d] > 0 else (-1 if rho[d] < 0 else 0)
    return signs


def support_from_rho(rho):
    return set(d for d in range(1, len(rho)) if int(rho[d]) != 0)


def candidate_from_blocks(blocks, p, ks, lam, baseline, powers, mode, parent, restart_id, step, accepted):
    row = S62["candidate_record"](
        blocks,
        p,
        ks,
        lam,
        baseline,
        origin=parent.get("parent_origin_type") or parent.get("origin"),
        mode=mode,
        seed=restart_id,
        step=step,
        family=parent.get("parent_origin_type") or parent.get("origin"),
        extra={
            "parent_hash": parent["canonical_hash"],
            "restart_id": int(restart_id),
            "accepted_moves": int(accepted),
        },
        powers=powers,
    )
    row["label"] = S62["label_candidate"](row, {})
    row.update(defect_pattern_signature(row["_counts"], lam))
    return row


def update_weights(mode, weights, rho, signs_history, step, update_interval, params, current_diag, weighted_phase_until):
    stubborn_count = 0
    if mode == "static_weighted_score" or mode == "baseline_score_only_recheck":
        return stubborn_count, weighted_phase_until
    if mode == "dynamic_weighting_breakout":
        trigger = False
        if current_diag:
            trigger = (
                (current_diag.get("h_min") is not None and int(current_diag.get("h_min")) > 0)
                or (current_diag.get("D_min_ratio") is not None and float(current_diag.get("D_min_ratio")) > 1.0)
                or (current_diag.get("P_8") is not None and float(current_diag.get("P_8")) < 0.02)
                or (current_diag.get("kappa_max") is not None and float(current_diag.get("kappa_max")) < 1.0)
            )
        if trigger:
            eta = float(params.get("eta", 0.5))
            for d in range(1, len(weights)):
                weights[d] += eta * abs(int(rho[d]))
            weighted_phase_until = max(weighted_phase_until, step + int(params.get("weighted_phase_steps", 200)))
        return stubborn_count, weighted_phase_until
    if step <= 0 or step % int(update_interval) != 0:
        return stubborn_count, weighted_phase_until
    gamma = float(params.get("gamma", 0.01))
    eta = float(params.get("eta", 0.25))
    for d in range(1, len(weights)):
        weights[d] = max(0.05, (1.0 - gamma) * float(weights[d]))
    if mode in ("dynamic_weighting_basic", "dynamic_weighting_with_exactlike_guard"):
        for d in support_from_rho(rho):
            weights[d] += eta
    elif mode == "dynamic_weighting_stubborn":
        lag = int(params.get("lag", 100))
        if len(signs_history) > lag:
            old = signs_history[-lag - 1]
            cur = sign_vector(rho)
            for d in range(1, len(weights)):
                if cur[d] != 0 and cur[d] == old[d]:
                    weights[d] += eta
                    stubborn_count += 1
    return stubborn_count, weighted_phase_until


def quick_local_diag_from_moves(score, moves):
    if not moves:
        return {
            "h_min": None,
            "D_min_ratio": None,
            "P_<0": None,
            "P_8": None,
            "kappa_max": None,
        }
    h_values = [int(move["h"]) for move in moves]
    kappas = [float(move["kappa"]) for move in moves if move.get("kappa") is not None]
    h_min = min(h_values)
    return {
        "h_min": int(h_min),
        "D_min_ratio": float(score + h_min) / float(score) if score > 0 else None,
        "P_<0": float(sum(1 for h in h_values if h < 0)) / float(len(h_values)),
        "P_8": float(sum(1 for h in h_values if h <= 8)) / float(len(h_values)),
        "kappa_max": max(kappas) if kappas else None,
    }


def choose_weighted_move(mode, blocks, counts, lam, p, weights, rng, params, weighted_phase_active, old_guard_diag):
    score = S62["score_counts"](counts, lam)
    rho = S62["rho_vector"](counts, lam)
    moves = S62["one_swap_library"](blocks, counts, lam, p, rng=rng)
    if not moves:
        return None, quick_local_diag_from_moves(score, moves), rho, moves
    if mode == "baseline_score_only_recheck":
        for move in moves:
            if int(move["h"]) < 0:
                return move, quick_local_diag_from_moves(score, moves), rho, moves
        return None, quick_local_diag_from_moves(score, moves), rho, moves
    weighted_rows = []
    for move in moves:
        h_w, g_w, q_w, kappa_w = weighted_delta(move, rho, weights)
        row = dict(move)
        row["h_w"] = float(h_w)
        row["g_w"] = float(g_w)
        row["q_w"] = float(q_w)
        row["kappa_w"] = kappa_w
        weighted_rows.append(row)
    weighted_rows.sort(key=lambda m: (float(m["h_w"]), int(m["h"]), -float(m["kappa_w"] if m["kappa_w"] is not None else -999.0)))
    local_diag = quick_local_diag_from_moves(score, moves)
    if mode == "dynamic_weighting_breakout" and not weighted_phase_active:
        for move in moves:
            if int(move["h"]) < 0:
                return move, local_diag, rho, moves
        return None, local_diag, rho, moves
    for move in weighted_rows[:80]:
        if float(move["h_w"]) >= 0.0:
            continue
        if mode == "dynamic_weighting_with_exactlike_guard":
            if int(move["h"]) > 16:
                continue
            next_blocks = S62["apply_moves_copy"](blocks, [move])
            if next_blocks is None:
                continue
            next_counts = S62["total_diff_counts"](p, next_blocks)
            next_score = S62["score_counts"](next_counts, lam)
            next_moves = S62["one_swap_library"](next_blocks, next_counts, lam, p, rng=rng)
            new_diag = quick_local_diag_from_moves(next_score, next_moves)
            if old_guard_diag:
                old_d = old_guard_diag.get("D_min_ratio")
                new_d = new_diag.get("D_min_ratio")
                if old_d is not None and new_d is not None and float(new_d) > float(old_d) + 0.25:
                    continue
                old_p8 = old_guard_diag.get("P_8")
                new_p8 = new_diag.get("P_8")
                if old_p8 is not None and new_p8 is not None and float(new_p8) < 0.5 * float(old_p8):
                    continue
                old_k = old_guard_diag.get("kappa_max")
                new_k = new_diag.get("kappa_max")
                if old_k is not None and new_k is not None and float(new_k) < min(1.0, float(old_k) - 0.25):
                    continue
        return move, local_diag, rho, moves
    return None, local_diag, rho, moves


def mode_params(mode, restart_id):
    if mode == "static_weighted_score":
        return {"alpha": [0.5, 1.0, 2.0][int(restart_id) % 3]}
    if mode == "dynamic_weighting_basic":
        return {"gamma": 0.01, "eta": [0.1, 0.25, 0.5][int(restart_id) % 3]}
    if mode == "dynamic_weighting_stubborn":
        return {"gamma": 0.01, "eta": [0.25, 0.5][int(restart_id) % 2], "lag": [100, 200][int(restart_id) % 2]}
    if mode == "dynamic_weighting_breakout":
        return {"eta": [0.5, 1.0][int(restart_id) % 2], "weighted_phase_steps": 200}
    if mode == "dynamic_weighting_with_exactlike_guard":
        return {"gamma": 0.01, "eta": [0.1, 0.25, 0.5][int(restart_id) % 3]}
    return {}


def initialize_weights(mode, rho, params):
    weights = [1.0] * len(rho)
    if mode == "static_weighted_score":
        alpha = float(params.get("alpha", 1.0))
        for d in range(1, len(weights)):
            weights[d] = 1.0 + alpha * abs(int(rho[d]))
    return weights


def run_weighting_attempt(parent, mode, restart_id, args, p, ks, lam, baseline, powers):
    rng = random.Random(int(args.seed_base + 1000003 * (restart_id + 1) + int(parent["score"]) * 17 + sum(ord(c) for c in mode) + int(parent["canonical_hash"][:6], 16)))
    blocks = clone_blocks(parent["_blocks"])
    counts = S62["total_diff_counts"](p, blocks)
    rho = S62["rho_vector"](counts, lam)
    params = mode_params(mode, restart_id)
    weights = initialize_weights(mode, rho, params)
    start_support = support_from_rho(rho)
    start_sign = sign_vector(rho)
    signs_history = [start_sign]
    accepted = 0
    stubborn_count = 0
    weighted_phase_until = 0
    best_blocks = clone_blocks(blocks)
    best_counts = counts
    best_score = S62["score_counts"](counts, lam)
    best_sw = weighted_score_from_rho(rho, weights)
    snapshots = []
    no_move_streak = 0
    last_local_diag = {
        "h_min": parent.get("h_min"),
        "D_min_ratio": parent.get("D_min_ratio"),
        "P_<0": parent.get("P_<0"),
        "P_8": parent.get("P_8"),
        "kappa_max": parent.get("kappa_max"),
    }

    def snapshot(step, local_stubborn):
        current_counts = S62["total_diff_counts"](p, blocks)
        current_rho = S62["rho_vector"](current_counts, lam)
        row = candidate_from_blocks(blocks, p, ks, lam, baseline, powers, mode, parent, restart_id, step, accepted)
        wstats = weight_stats(weights)
        row.update(
            {
                "S": int(row["score"]),
                "S_w": float(weighted_score_from_rho(current_rho, weights)),
                "weight_entropy": wstats["weight_entropy"],
                "weight_max": wstats["weight_max"],
                "weight_min": wstats["weight_min"],
                "num_high_weight_coords": wstats["num_high_weight_coords"],
                "stubborn_count": int(local_stubborn),
                "changed_defect_coords_since_start": int(len(start_support.symmetric_difference(support_from_rho(current_rho)))),
            }
        )
        snapshots.append(row)
        return row

    snapshot(0, 0)
    for step in range(1, int(args.steps) + 1):
        counts = S62["total_diff_counts"](p, blocks)
        score = S62["score_counts"](counts, lam)
        rho = S62["rho_vector"](counts, lam)
        stubborn_count, weighted_phase_until = update_weights(
            mode,
            weights,
            rho,
            signs_history,
            step,
            int(args.update_interval),
            params,
            last_local_diag,
            weighted_phase_until,
        )
        weighted_active = mode != "dynamic_weighting_breakout" or step <= weighted_phase_until
        move, local_diag, rho, _moves = choose_weighted_move(
            mode,
            blocks,
            counts,
            lam,
            p,
            weights,
            rng,
            params,
            weighted_active,
            last_local_diag,
        )
        last_local_diag = local_diag
        if move is None:
            no_move_streak += 1
            if step % int(args.snapshot_interval) == 0:
                snapshot(step, stubborn_count)
            if mode in ("baseline_score_only_recheck", "static_weighted_score"):
                break
            if int(args.no_move_patience) > 0 and no_move_streak >= int(args.no_move_patience):
                break
            signs_history.append(sign_vector(rho))
            continue
        next_blocks = S62["apply_moves_copy"](blocks, [move])
        if next_blocks is None:
            break
        blocks = next_blocks
        accepted += 1
        no_move_streak = 0
        counts = S62["total_diff_counts"](p, blocks)
        rho = S62["rho_vector"](counts, lam)
        signs_history.append(sign_vector(rho))
        score = S62["score_counts"](counts, lam)
        sw = weighted_score_from_rho(rho, weights)
        if score < best_score or (score == best_score and sw < best_sw):
            best_score = int(score)
            best_sw = float(sw)
            best_blocks = clone_blocks(blocks)
            best_counts = counts
        if step % int(args.snapshot_interval) == 0:
            snapshot(step, stubborn_count)
        if score == 0:
            snapshot(step, stubborn_count)
            best_blocks = clone_blocks(blocks)
            best_counts = counts
            best_score = 0
            best_sw = float(sw)
            break
    final_counts = S62["total_diff_counts"](p, blocks)
    final_rho = S62["rho_vector"](final_counts, lam)
    best_rho = S62["rho_vector"](best_counts, lam)
    final_row = candidate_from_blocks(blocks, p, ks, lam, baseline, powers, mode, parent, restart_id, accepted, accepted)
    best_row = candidate_from_blocks(best_blocks, p, ks, lam, baseline, powers, mode, parent, restart_id, accepted, accepted)
    final_stats = weight_stats(weights)
    parent_score = int(parent["score"])
    score_escape = int(best_row["score"]) < parent_score
    exactlike_escape = bool(
        (best_row.get("D_min_ratio") is not None and float(best_row.get("D_min_ratio")) < 1.0)
        or (best_row.get("h_min") is not None and int(best_row.get("h_min")) < 0)
        or (best_row.get("kappa_max") is not None and float(best_row.get("kappa_max")) > 1.0)
        or (parent.get("P_8") is not None and best_row.get("P_8") is not None and float(best_row.get("P_8")) >= 2.0 * float(parent.get("P_8")))
    )
    escaped_false = bool(parent.get("label") == "false_like" and (score_escape or exactlike_escape))
    sw_start = weighted_score_from_rho(S62["rho_vector"](parent["_counts"], lam), initialize_weights(mode, S62["rho_vector"](parent["_counts"], lam), params))
    sw_final = weighted_score_from_rho(final_rho, weights)
    score_damage_seen = bool(int(final_row["score"]) > parent_score and int(best_row["score"]) >= parent_score and accepted > 0)
    weighted_false_basin_risk = bool(
        score_damage_seen
        or (
            sw_final < sw_start
            and int(final_row["score"]) > parent_score
            and (
                (parent.get("D_min_ratio") is not None and final_row.get("D_min_ratio") is not None and float(final_row["D_min_ratio"]) > float(parent["D_min_ratio"]))
                or (parent.get("P_8") is not None and final_row.get("P_8") is not None and float(final_row["P_8"]) < float(parent["P_8"]))
                or (parent.get("kappa_max") is not None and final_row.get("kappa_max") is not None and float(final_row["kappa_max"]) < float(parent["kappa_max"]))
            )
        )
    )
    attempt = {
        "mode": mode,
        "restart_id": int(restart_id),
        "parent_hash": parent["canonical_hash"],
        "parent_origin": parent.get("parent_origin_type") or parent.get("origin"),
        "parent_score": parent_score,
        "parent_label": parent.get("label"),
        "parent_D_min_ratio": parent.get("D_min_ratio"),
        "parent_P_4": parent.get("P_4"),
        "parent_P_8": parent.get("P_8"),
        "parent_P_16": parent.get("P_16"),
        "parent_kappa_max": parent.get("kappa_max"),
        "parent_Q_ratio": parent.get("Q_ratio"),
        "parent_InitHardness": parent.get("InitHardness"),
        "parent_defect_support_size": parent.get("defect_support_size"),
        "parent_defect_pattern_signature": parent.get("pattern_signature"),
        "accepted_moves": int(accepted),
        "best_S": int(best_row["score"]),
        "best_S_w": float(best_sw),
        "final_S": int(final_row["score"]),
        "final_S_w": float(sw_final),
        "best_score_delta": int(best_row["score"] - parent_score),
        "best_D_min_ratio": best_row.get("D_min_ratio"),
        "best_P_8": best_row.get("P_8"),
        "best_P_16": best_row.get("P_16"),
        "best_kappa_max": best_row.get("kappa_max"),
        "best_Q_ratio": best_row.get("Q_ratio"),
        "score_improvement_seen": bool(int(best_row["score"]) < parent_score),
        "score0_seen": bool(int(best_row["score"]) == 0),
        "score4_to_lower_seen": bool(parent_score == 4 and int(best_row["score"]) < 4),
        "escaped_false_basin": escaped_false,
        "score_escape": bool(parent.get("label") == "false_like" and score_escape),
        "exactlike_escape": bool(parent.get("label") == "false_like" and exactlike_escape),
        "exactlike_improved": bool(exactlike_escape),
        "final_label": final_row.get("label"),
        "best_label": best_row.get("label"),
        "weight_entropy": final_stats["weight_entropy"],
        "weight_max": final_stats["weight_max"],
        "weight_min": final_stats["weight_min"],
        "num_high_weight_coords": final_stats["num_high_weight_coords"],
        "stubborn_count": int(stubborn_count),
        "weighted_false_basin_risk": weighted_false_basin_risk,
        "score_damage_seen": score_damage_seen,
        "params": params,
        "_best_row": best_row,
        "_final_row": final_row,
        "_weights": list(weights),
        "_initial_support": start_support,
        "_final_support": support_from_rho(final_rho),
        "_best_support": support_from_rho(best_rho),
        "_high_weight_coords": set(final_stats["high_weight_coords"]),
    }
    return attempt, snapshots


def defect_dynamics_for_attempt(attempt):
    initial = set(attempt.get("_initial_support", set()))
    final = set(attempt.get("_best_support", set()))
    high = set(attempt.get("_high_weight_coords", set()))
    union = initial.union(final)
    persistent = initial.intersection(final)
    removed = initial - final
    new = final - initial
    return {
        "mode": attempt["mode"],
        "parent_hash": attempt["parent_hash"],
        "restart_id": int(attempt["restart_id"]),
        "parent_score": int(attempt["parent_score"]),
        "best_S": int(attempt["best_S"]),
        "initial_nonzero_defect_support": sorted(initial),
        "final_nonzero_defect_support": sorted(final),
        "overlap": sorted(persistent),
        "removed_coords": sorted(removed),
        "new_coords": sorted(new),
        "persistent_coords": sorted(persistent),
        "high_weight_coords": sorted(high),
        "persistent_defect_fraction": float(len(persistent)) / float(len(initial)) if initial else None,
        "high_weight_persistent_fraction": float(len(high.intersection(persistent))) / float(len(high)) if high else None,
        "defect_support_turnover": float(len(initial.symmetric_difference(final))) / float(len(union)) if union else 0.0,
    }


def summarize_by_mode(attempts):
    groups = {}
    for row in attempts:
        groups.setdefault(row["mode"], []).append(row)
    out = []
    for mode, rows in sorted(groups.items()):
        score4 = [row for row in rows if int(row["parent_score"]) == 4]
        out.append(
            {
                "mode": mode,
                "attempt_count": int(len(rows)),
                "score_improvement_count": int(sum(1 for row in rows if row.get("score_improvement_seen"))),
                "score_improvement_rate": float(sum(1 for row in rows if row.get("score_improvement_seen"))) / float(len(rows)) if rows else None,
                "score0_count": int(sum(1 for row in rows if row.get("score0_seen"))),
                "score0_rate": float(sum(1 for row in rows if row.get("score0_seen"))) / float(len(rows)) if rows else None,
                "score4_parent_count": int(len(score4)),
                "score4_to_lower_count": int(sum(1 for row in score4 if row.get("score4_to_lower_seen"))),
                "score4_to_lower_rate": float(sum(1 for row in score4 if row.get("score4_to_lower_seen"))) / float(len(score4)) if score4 else None,
                "score4_to_zero_count": int(sum(1 for row in score4 if row.get("score0_seen"))),
                "score4_to_zero_rate": float(sum(1 for row in score4 if row.get("score0_seen"))) / float(len(score4)) if score4 else None,
                "escaped_false_basin_count": int(sum(1 for row in rows if row.get("escaped_false_basin"))),
                "escaped_false_basin_rate": float(sum(1 for row in rows if row.get("escaped_false_basin"))) / float(len(rows)) if rows else None,
                "exactlike_improved_count": int(sum(1 for row in rows if row.get("exactlike_improved"))),
                "exactlike_improved_rate": float(sum(1 for row in rows if row.get("exactlike_improved"))) / float(len(rows)) if rows else None,
                "false_like_final_count": int(sum(1 for row in rows if row.get("final_label") == "false_like")),
                "false_like_final_rate": float(sum(1 for row in rows if row.get("final_label") == "false_like")) / float(len(rows)) if rows else None,
                "weighted_false_basin_risk_count": int(sum(1 for row in rows if row.get("weighted_false_basin_risk"))),
                "weighted_false_basin_risk_rate": float(sum(1 for row in rows if row.get("weighted_false_basin_risk"))) / float(len(rows)) if rows else None,
                "score_damage_count": int(sum(1 for row in rows if row.get("score_damage_seen"))),
                "score_damage_rate": float(sum(1 for row in rows if row.get("score_damage_seen"))) / float(len(rows)) if rows else None,
                "median_best_score": median([row.get("best_S") for row in rows]),
                "median_best_D_min_ratio": median([row.get("best_D_min_ratio") for row in rows]),
                "median_best_P_8": median([row.get("best_P_8") for row in rows]),
                "median_best_kappa_max": median([row.get("best_kappa_max") for row in rows]),
                "median_best_Q_ratio": median([row.get("best_Q_ratio") for row in rows]),
                "median_weight_entropy": median([row.get("weight_entropy") for row in rows]),
                "median_weight_max": median([row.get("weight_max") for row in rows]),
                "median_stubborn_count": median([row.get("stubborn_count") for row in rows]),
                "parent_score_distribution": histogram_int(rows, "parent_score"),
                "parent_label_distribution": count_by(rows, "parent_label"),
                "final_label_distribution": count_by(rows, "final_label"),
            }
        )
    return out


def summarize_defect_dynamics(dynamics):
    groups = {}
    for row in dynamics:
        groups.setdefault(row["mode"], []).append(row)
    out = []
    for mode, rows in sorted(groups.items()):
        out.append(
            {
                "mode": mode,
                "count": int(len(rows)),
                "median_persistent_defect_fraction": median([row.get("persistent_defect_fraction") for row in rows]),
                "median_high_weight_persistent_fraction": median([row.get("high_weight_persistent_fraction") for row in rows]),
                "median_defect_support_turnover": median([row.get("defect_support_turnover") for row in rows]),
                "mean_persistent_defect_fraction": mean([row.get("persistent_defect_fraction") for row in rows]),
                "mean_defect_support_turnover": mean([row.get("defect_support_turnover") for row in rows]),
            }
        )
    return out


def evaluate_hypotheses(mode_rows, defect_summary):
    by_mode = {row["mode"]: row for row in mode_rows}
    baseline = by_mode.get("baseline_score_only_recheck", {})
    weighted = [row for row in mode_rows if row["mode"] != "baseline_score_only_recheck"]
    best_escape = max((float(row.get("escaped_false_basin_rate") or 0.0) for row in weighted), default=0.0)
    base_escape = float(baseline.get("escaped_false_basin_rate") or 0.0)
    best_improve = max((float(row.get("score_improvement_rate") or 0.0) for row in weighted), default=0.0)
    base_improve = float(baseline.get("score_improvement_rate") or 0.0)
    best_false_rate = min((float(row.get("false_like_final_rate") or 1.0) for row in weighted), default=1.0)
    base_false_rate = float(baseline.get("false_like_final_rate") or 1.0)
    dyn = {row["mode"]: row for row in defect_summary}
    base_persist = dyn.get("baseline_score_only_recheck", {}).get("median_persistent_defect_fraction")
    dynamic_modes = set(["dynamic_weighting_basic", "dynamic_weighting_stubborn", "dynamic_weighting_breakout", "dynamic_weighting_with_exactlike_guard"])
    best_persist = min(
        [float(row.get("median_persistent_defect_fraction")) for row in defect_summary if row["mode"] in dynamic_modes and row.get("median_persistent_defect_fraction") is not None],
        default=None,
    )
    h4_risk = max((float(row.get("weighted_false_basin_risk_rate") or 0.0) for row in weighted), default=0.0)
    h3 = "supported" if best_false_rate < base_false_rate else "not_supported"
    if h3 == "supported" and h4_risk > 0.0 and best_escape <= base_escape:
        h3 = "supported_label_only"
    return {
        "H_DW1": "supported" if best_escape > base_escape or best_improve > base_improve else "not_supported",
        "H_DW2": "supported" if base_persist is not None and best_persist is not None and best_persist < float(base_persist) else "inconclusive",
        "H_DW3": h3,
        "H_DW4": "supported" if h4_risk > 0.0 else "not_supported",
        "baseline_escape_rate": base_escape,
        "best_weighted_escape_rate": best_escape,
        "baseline_score_improvement_rate": base_improve,
        "best_weighted_score_improvement_rate": best_improve,
        "baseline_false_like_final_rate": base_false_rate,
        "best_weighted_false_like_final_rate": best_false_rate,
        "baseline_persistent_defect_fraction": base_persist,
        "best_weighted_persistent_defect_fraction": best_persist,
        "weighted_false_basin_risk_rate_max": h4_risk,
    }


def write_summary(path, args, parent_rows, mode_rows, defect_summary, hypo, score0_paths, validation_notes):
    by_mode = {row["mode"]: row for row in mode_rows}
    baseline = by_mode.get("baseline_score_only_recheck", {})
    best_mode = None
    weighted = [row for row in mode_rows if row["mode"] != "baseline_score_only_recheck"]
    if weighted:
        best_mode = sorted(
            weighted,
            key=lambda row: (
                -float(row.get("escaped_false_basin_rate") or 0.0),
                -float(row.get("score_improvement_rate") or 0.0),
                float(row.get("median_best_score") or 10**9),
            ),
        )[0]["mode"]
    score4_to_lower = sum(int(row.get("score4_to_lower_count") or 0) for row in mode_rows)
    score4_to_zero = sum(int(row.get("score4_to_zero_count") or 0) for row in mode_rows)
    lines = [
        "# p37 Dynamic Defect Weighting Validation",
        "",
        "This is a p=37 operator validation, not a Hadamard 668 construction run.",
        "",
        "## Run",
        "",
        "- parents: `{}`".format(len(parent_rows)),
        "- steps: `{}`".format(args.steps),
        "- restarts: `{}`".format(args.restarts),
        "- modes: `{}`".format(", ".join(MODES)),
        "- score=0 only is success",
        "",
        "## Mode Summary",
        "",
        "```json",
        json.dumps(json_safe(mode_rows), indent=2, sort_keys=True),
        "```",
        "",
        "## Hypotheses",
        "",
        "```json",
        json.dumps(json_safe(hypo), indent=2, sort_keys=True),
        "```",
        "",
        "## Required Answers",
        "",
        "1. dynamic defect weighting は score-only baseline より score improvement を増やしたか: `{}`.".format(bool(float(hypo.get("best_weighted_score_improvement_rate") or 0.0) > float(hypo.get("baseline_score_improvement_rate") or 0.0))),
        "2. score=4 false basin から score<4 は出たか: `{}`.".format(score4_to_lower > 0),
        "3. score=4 false basin から score=0 は出たか: `{}`.".format(score4_to_zero > 0),
        "4. D_min/S, P_tau, kappa は改善したか: best weighted escape rate `{}` vs baseline `{}`; see `weighting_by_mode_summary.csv`.".format(hypo.get("best_weighted_escape_rate"), hypo.get("baseline_escape_rate")),
        "5. stubborn defect coordinate は減ったか: `{}`; baseline persistent fraction `{}`, best weighted `{}`.".format(hypo.get("H_DW2"), hypo.get("baseline_persistent_defect_fraction"), hypo.get("best_weighted_persistent_defect_fraction")),
        "6. weighting は S_w だけを改善して通常 S を悪化させたか: H-DW4 `{}`; risk max `{}`.".format(hypo.get("H_DW4"), hypo.get("weighted_false_basin_risk_rate_max")),
        "7. どの weighting mode が最も有効だったか: `{}`.".format(best_mode),
        "8. exactlike guard は weighted false basin を防いだか: guard risk `{}` vs max weighted risk `{}`.".format(by_mode.get("dynamic_weighting_with_exactlike_guard", {}).get("weighted_false_basin_risk_rate"), hypo.get("weighted_false_basin_risk_rate_max")),
        "9. H-DW1, H-DW2, H-DW3, H-DW4 の判定はどうか: `{}`.".format(json.dumps({k: hypo.get(k) for k in ("H_DW1", "H_DW2", "H_DW3", "H_DW4")}, sort_keys=True)),
        "10. 668 に戻すなら dynamic weighting を main descent, perturbation, repair preconditioner のどれとして使うべきか: use it as a perturbation or repair preconditioner only if H-DW1/H-DW2 are supported without H-DW4 risk; otherwise keep it as an audit/ablation tool.",
        "",
        "## Validation",
        "",
    ]
    lines.extend("- {}".format(note) for note in validation_notes)
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def save_score0(out_dir, row, mode, p, ks, lam):
    return S62["save_score0_candidate"](out_dir, row, mode, p, ks, lam)


def run_cmd(cmd):
    proc = subprocess.run(cmd, cwd=os.getcwd(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return proc.returncode, proc.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--p", type=int, default=37)
    parser.add_argument("--ks", default="13,16,18,18")
    parser.add_argument("--lambda", dest="lam", type=int, default=28)
    parser.add_argument("--exact-json", default="outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json")
    parser.add_argument("--max-parent-candidates", type=int, default=60)
    parser.add_argument("--steps", type=int, default=1000)
    parser.add_argument("--restarts", type=int, default=3)
    parser.add_argument("--snapshot-interval", type=int, default=50)
    parser.add_argument("--update-interval", type=int, default=50)
    parser.add_argument("--no-move-patience", type=int, default=200)
    parser.add_argument("--seed-base", type=int, default=20260507)
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--no-external-validation", action="store_true")
    args = parser.parse_args()

    p = int(args.p)
    ks = parse_ks(args.ks)
    lam = int(args.lam)
    S62["validate_params"](p, ks, lam)
    out_dir = args.out_dir or os.path.join("outputs/explorations", "{}_p37_dynamic_defect_weighting_validation".format(now_stamp()))
    ensure_dir(out_dir)
    write_json(os.path.join(out_dir, "run_config.json"), vars(args))
    with open(os.path.join(out_dir, "run_log.md"), "w") as f:
        f.write("# Run Log\n\n")
        f.write("- script: `{}`\n".format(SCRIPT_NAME))
        f.write("- score=0 only is success\n")

    baseline = S62["random_baseline_tuple"](p, ks)
    exact_blocks = None
    if args.exact_json:
        _data, v, _n, got_ks, got_lam, exact_blocks = S62["load_candidate"](args.exact_json)
        if int(v) != p or tuple(got_ks) != tuple(ks) or int(got_lam) != lam:
            raise ValueError("exact json does not match requested target")

    raw_payloads = collect_payload_candidates(p, ks, lam)
    selected_payloads = select_parent_payloads(raw_payloads, args.max_parent_candidates, exact_blocks, p, ks, lam, args.seed_base)
    parent_rows = make_parent_rows(selected_payloads, p, ks, lam, baseline, POWERS_DEFAULT)
    write_jsonl(os.path.join(out_dir, "input_weighting_candidates.jsonl"), parent_rows)
    print("Parents:", len(parent_rows))

    attempts = []
    snapshots = []
    dynamics = []
    score0_paths = []
    for parent_idx, parent in enumerate(parent_rows):
        print("parent", parent_idx, "score", parent["score"], "label", parent.get("label"), parent["canonical_hash"][:12])
        for mode in MODES:
            for restart in range(int(args.restarts)):
                attempt, run_snapshots = run_weighting_attempt(parent, mode, restart, args, p, ks, lam, baseline, POWERS_DEFAULT)
                attempts.append(attempt)
                snapshots.extend(run_snapshots)
                dynamics.append(defect_dynamics_for_attempt(attempt))
                best_row = attempt["_best_row"]
                if int(best_row["score"]) == 0:
                    path = save_score0(out_dir, best_row, "{}_r{}".format(mode, restart), p, ks, lam)
                    if path and path not in score0_paths:
                        score0_paths.append(path)
                print("  ", mode, restart, "accepted", attempt["accepted_moves"], "best", attempt["best_S"], "final", attempt["final_S"])
                sys.stdout.flush()

    write_jsonl(os.path.join(out_dir, "weighting_attempts.jsonl"), attempts)
    write_jsonl(os.path.join(out_dir, "weighting_snapshots.jsonl"), snapshots)
    write_jsonl(os.path.join(out_dir, "defect_coordinate_dynamics.jsonl"), dynamics)
    mode_rows = summarize_by_mode(attempts)
    defect_summary = summarize_defect_dynamics(dynamics)
    hypo = evaluate_hypotheses(mode_rows, defect_summary)
    write_csv(
        os.path.join(out_dir, "weighting_by_mode_summary.csv"),
        mode_rows,
        sorted(set().union(*(row.keys() for row in mode_rows))) if mode_rows else ["mode", "attempt_count"],
    )
    write_json(os.path.join(out_dir, "weighting_by_mode_summary.json"), {"rows": mode_rows})
    write_csv(
        os.path.join(out_dir, "defect_coordinate_summary.csv"),
        defect_summary,
        sorted(set().union(*(row.keys() for row in defect_summary))) if defect_summary else ["mode", "count"],
    )
    write_json(os.path.join(out_dir, "hypothesis_evaluation.json"), hypo)

    validation_notes = []
    if not args.no_external_validation:
        code, output = run_cmd(["sage", "sage/06_known_sds_regression.sage"])
        validation_notes.append("`sage sage/06_known_sds_regression.sage`: {}".format("OK" if code == 0 else "FAILED"))
        with open(os.path.join(out_dir, "run_log.md"), "a") as f:
            f.write("\n## External validation\n\n")
            f.write("- known regression: `{}`\n".format("OK" if code == 0 else "FAILED"))
        if code != 0:
            raise RuntimeError("known SDS regression failed:\n{}".format(output))

        for path in score0_paths:
            for script in ("08_analyze_sds_candidate.sage", "05_validate_candidate_json.sage", "04_build_gs_from_sds.sage"):
                code, output = run_cmd(["sage", os.path.join("sage", script), path])
                status = "OK" if code == 0 else "FAILED"
                validation_notes.append("`sage sage/{}` `{}`: {}".format(script, path, status))
                with open(os.path.join(out_dir, "run_log.md"), "a") as f:
                    f.write("- `{}` on `{}`: `{}`\n".format(script, path, status))
                if code != 0:
                    raise RuntimeError("{} failed for {}:\n{}".format(script, path, output))
    else:
        validation_notes.append("External validation skipped by CLI flag.")

    write_summary(
        os.path.join(out_dir, "p37_dynamic_defect_weighting_summary.md"),
        args,
        parent_rows,
        mode_rows,
        defect_summary,
        hypo,
        score0_paths,
        validation_notes,
    )
    print("SUMMARY:", os.path.join(out_dir, "p37_dynamic_defect_weighting_summary.md"))


if __name__ == "__main__":
    main()
