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


SCRIPT_NAME = "65_focused_defect_random_walk_validation"
SCORE_SET = set([4, 8, 12, 16, 24, 32])
MODES = (
    "baseline_score_only_recheck",
    "focused_high_abs_rho",
    "focused_stubborn_defect",
    "focused_score4_pair",
    "focused_weighted_defect",
    "focused_with_exactlike_guard",
    "focused_plus_small_threshold",
)
POWERS_DEFAULT = (2, 4, 6, 8, 10, 12)
DYNAMIC_REFERENCE = "outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/hypothesis_evaluation.json"
DYNAMIC_REFERENCE_FALLBACK = "configs/fixtures/p37_dynamic_defect_weighting_reference.json"


def load_sage_namespace(filename, name):
    here = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.path.join(os.getcwd(), "sage")
    path = os.path.join(here, filename)
    ns = {"__name__": name, "__file__": path}
    with open(path) as f:
        code = compile(f.read(), path, "exec")
    exec(code, ns)
    return ns


S63 = load_sage_namespace("63_dynamic_defect_weighting_validation.sage", "sds63_focused_import")
S62 = S63["S62"]


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


def rate(rows, key):
    return float(sum(1 for row in rows if row.get(key))) / float(len(rows)) if rows else None


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


def resolve_path(path, base_path=None):
    if not path:
        return None
    path = str(path)
    candidates = []
    if os.path.isabs(path):
        candidates.append(path)
    else:
        candidates.append(os.path.join(os.getcwd(), path))
        if base_path:
            candidates.append(os.path.join(os.path.dirname(os.path.abspath(base_path)), path))
    for candidate in candidates:
        if os.path.exists(candidate):
            return os.path.abspath(candidate)
    return None


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
                for key in ("rows", "candidates", "results", "parents", "score4_candidates"):
                    items = payload.get(key)
                    if isinstance(items, list):
                        for item in items:
                            if isinstance(item, dict):
                                yield item
    except Exception:
        return


def blocks_from_payload(payload, base_path=None, seen=None):
    raw = payload.get("blocks") or payload.get("X") or payload.get("sets")
    if raw is not None:
        try:
            blocks = [set(int(x) for x in block) for block in raw]
        except Exception:
            blocks = None
        if blocks is not None and len(blocks) == 4:
            return blocks
    seen = set() if seen is None else seen
    for key in ("path", "source_path", "candidate_path", "json_path"):
        ref = payload.get(key)
        resolved = resolve_path(ref, base_path)
        if resolved is None or resolved in seen:
            continue
        seen.add(resolved)
        if not (resolved.endswith(".json") or resolved.endswith(".jsonl")):
            continue
        for item in iter_payloads_from_file(resolved):
            blocks = blocks_from_payload(item, resolved, seen)
            if blocks is not None:
                return blocks
    return None


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
        for key in ("origin", "origin_type", "origin_family", "mode", "source", "source_path", "label", "parent_label")
    ).lower()
    source = str(source_path).lower()
    if "exact_perturb" in text or "exact_derived" in text or "exact_perturb" in source:
        return "exact_derived"
    if int(payload.get("score", -1) or -1) == 0:
        return "exact"
    if "false" in text or "search" in text or "trajectory" in text or "score_only" in text or "threshold" in text:
        return "search_derived"
    return "search_derived"


def candidate_search_paths():
    return [
        "configs/fixtures/p37_focused_defect_random_walk_parents.jsonl",
        "outputs/explorations/20260506_0915_small_p_escapability_validation",
        "outputs/explorations/20260506_1125_small_p_defect_targeted_lns_validation",
        "outputs/explorations/20260506_1200_p37_score4_false_basin_anatomy",
        "outputs/explorations/20260506_1557_p37_pipeline_framework",
        "outputs/explorations/20260506_1619_p37_classifier_feature_analysis",
        "outputs/explorations/20260506_1950_p37_exact_vs_search_low_score_comparison",
        "outputs/explorations/20260506_2216_p37_repair_lns_ablation",
        "outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation",
        "outputs/explorations/20260507_0210_p37_trap_set_catalog_validation",
        "outputs/candidates/small_p",
    ]


def payload_target_mismatch(payload, p, ks, lam):
    got_p = payload.get("p", payload.get("v"))
    if got_p is not None and int(got_p) != int(p):
        return True
    got_ks = payload.get("ks")
    if got_ks is not None:
        if isinstance(got_ks, str):
            got_ks_values = parse_ks(got_ks.replace("[", "").replace("]", ""))
        else:
            got_ks_values = tuple(int(x) for x in got_ks)
        if got_ks_values != tuple(int(x) for x in ks):
            return True
    got_lam = payload.get("lambda", payload.get("lam"))
    if got_lam is not None and int(got_lam) != int(lam):
        return True
    return False


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
                if name.endswith(".json") or name.endswith(".jsonl"):
                    selected_files.append(os.path.join(dirpath, name))
    raw = {}
    for path in selected_files:
        for payload in iter_payloads_from_file(path):
            if payload_target_mismatch(payload, p, ks, lam):
                continue
            blocks = blocks_from_payload(payload, path)
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
                    "source_label": payload.get("label") or payload.get("parent_label"),
                    "source_mode": payload.get("mode"),
                    "source_origin": payload.get("origin") or payload.get("origin_type") or payload.get("origin_family"),
                    "canonical_hash": h,
                }
    return list(raw.values())


def load_exact_blocks(path, p, ks, lam):
    if not path or not os.path.exists(path):
        return None
    data, v, _n, got_ks, got_lam, blocks = S62["load_candidate"](path)
    if int(v) != int(p) or tuple(int(x) for x in got_ks) != tuple(ks) or int(got_lam) != int(lam):
        raise ValueError("exact_json target mismatch: got p={}, ks={}, lambda={}".format(v, got_ks, got_lam))
    return blocks


def select_parent_payloads(raw_payloads, max_total, exact_blocks, p, ks, lam, seed):
    by_hash = {item["canonical_hash"]: item for item in raw_payloads}
    exact_existing = [item for item in by_hash.values() if item.get("origin_type") == "exact_derived"]
    if len(exact_existing) < 20:
        control_seed = int(int(seed) + 991)
        for item in S63["generate_exact_controls"](exact_blocks, p, ks, lam, 20 - len(exact_existing), control_seed):
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

    max_total = min(int(max_total), 80)
    if max_total >= 80:
        score4_cap, other_cap, exact_cap = 20, 40, 20
    elif max_total >= 20:
        score4_cap = min(20, max(1, max_total // 3))
        exact_cap = min(20, max(1, max_total // 4))
        other_cap = max_total - score4_cap - exact_cap
    else:
        score4_cap = min(20, max(1, max_total // 3))
        exact_cap = min(20, max(1, max_total // 3))
        other_cap = max(0, max_total - score4_cap - exact_cap)

    selected = []
    selected.extend(score4_search[:score4_cap])
    selected.extend(other_search[:other_cap])
    selected.extend(exact_controls[:exact_cap])
    if len(selected) < max_total:
        used = set(item["canonical_hash"] for item in selected)
        for item in score4_search + other_search + exact_controls:
            if item["canonical_hash"] in used:
                continue
            selected.append(item)
            used.add(item["canonical_hash"])
            if len(selected) >= max_total:
                break
    dedup = {}
    for item in selected:
        dedup.setdefault(item["canonical_hash"], item)
    return list(dedup.values())[:max_total]


def support_from_rho(rho):
    return set(d for d in range(1, len(rho)) if int(rho[d]) != 0)


def sign_vector(rho):
    signs = [0] * len(rho)
    for d in range(1, len(rho)):
        signs[d] = 1 if rho[d] > 0 else (-1 if rho[d] < 0 else 0)
    return signs


def pair_key(d, p):
    e = (-int(d)) % int(p)
    return tuple(sorted([int(d), int(e)]))


def score4_pairs(rho):
    p = len(rho)
    plus = []
    minus = []
    other = []
    seen = set()
    for d in range(1, p):
        if d in seen or int(rho[d]) == 0:
            continue
        e = (-d) % p
        seen.add(d)
        seen.add(e)
        pair = list(pair_key(d, p))
        vals = (int(rho[d]), int(rho[e]))
        if vals == (1, 1):
            plus.append(pair)
        elif vals == (-1, -1):
            minus.append(pair)
        else:
            other.append({"pair": pair, "rho": [vals[0], vals[1]]})
    return {"plus_pairs": plus, "minus_pairs": minus, "other_pairs": other}


def defect_pattern_signature(counts, lam):
    out = S63["defect_pattern_signature"](counts, lam)
    out.update(score4_pairs(S62["rho_vector"](counts, lam)))
    return out


def default_exactlike_cfg():
    return S63["default_exactlike_cfg"]()


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


def weighted_score_from_rho(rho, weights):
    return float(sum(float(weights[d]) * float(rho[d] * rho[d]) for d in range(1, len(rho))))


def initialize_weights(rho):
    weights = [1.0] * len(rho)
    for d in range(1, len(weights)):
        weights[d] = 1.0 + 0.5 * abs(int(rho[d]))
    return weights


def update_weights(weights, rho, signs_history, step, update_interval):
    stubborn_count = 0
    if step <= 0 or step % int(update_interval) != 0:
        return stubborn_count
    gamma = 0.02
    eta = 0.35
    for d in range(1, len(weights)):
        weights[d] = max(0.05, (1.0 - gamma) * float(weights[d]))
    cur = sign_vector(rho)
    old = signs_history[0] if not signs_history else signs_history[max(0, len(signs_history) - min(100, len(signs_history)))]
    for d in support_from_rho(rho):
        weights[d] += eta * abs(int(rho[d]))
        if cur[d] != 0 and cur[d] == old[d]:
            weights[d] += eta
            stubborn_count += 1
    return stubborn_count


def weighted_choice(items, weights, rng):
    if not items:
        return None
    total = sum(max(0.0, float(w)) for w in weights)
    if total <= 0:
        return items[rng.randrange(len(items))]
    needle = rng.random() * total
    acc = 0.0
    for item, weight in zip(items, weights):
        acc += max(0.0, float(weight))
        if acc >= needle:
            return item
    return items[-1]


def high_abs_target(rho, rng, alpha=1.0):
    support = sorted(support_from_rho(rho))
    if not support:
        return None
    weights = [float(abs(int(rho[d]))) ** float(alpha) for d in support]
    return weighted_choice(support, weights, rng)


def choose_target(mode, rho, signs_history, weights, parent_score, rng, restart_id):
    p = len(rho)
    if mode == "baseline_score_only_recheck":
        return None
    reason = mode
    d = None
    if mode == "focused_stubborn_defect":
        lags = [50, 100, 200]
        lag = lags[int(restart_id) % len(lags)]
        if len(signs_history) > lag:
            old = signs_history[-lag - 1]
            cur = sign_vector(rho)
            stubborn = [x for x in range(1, p) if cur[x] != 0 and cur[x] == old[x]]
        else:
            cur = sign_vector(rho)
            old = signs_history[0] if signs_history else cur
            stubborn = [x for x in range(1, p) if cur[x] != 0 and cur[x] == old[x]]
        if stubborn:
            d = weighted_choice(stubborn, [abs(int(rho[x])) for x in stubborn], rng)
            reason = "stubborn_sign_lag"
        else:
            d = high_abs_target(rho, rng, alpha=2.0)
            reason = "fallback_high_abs_rho"
    elif mode == "focused_score4_pair":
        pairs = score4_pairs(rho)
        pair_rows = []
        for pair in pairs["plus_pairs"]:
            pair_rows.append((pair, "score4_plus_pair"))
        for pair in pairs["minus_pairs"]:
            pair_rows.append((pair, "score4_minus_pair"))
        if int(parent_score) == 4 and pair_rows:
            pair, reason = pair_rows[rng.randrange(len(pair_rows))]
            d = int(pair[0])
            return {"target_d": d, "target_pair": [int(pair[0]), int(pair[1])], "target_selection_reason": reason}
        d = high_abs_target(rho, rng, alpha=2.0)
        reason = "fallback_high_abs_rho"
    elif mode == "focused_weighted_defect":
        support = sorted(support_from_rho(rho))
        if support:
            d = weighted_choice(support, [float(weights[x]) * abs(int(rho[x])) for x in support], rng)
            reason = "weighted_abs_rho"
    else:
        alpha = 1.0 if int(restart_id) % 2 == 0 else 2.0
        d = high_abs_target(rho, rng, alpha=alpha)
        reason = "high_abs_rho_alpha_{}".format(int(alpha))
    if d is None:
        return None
    return {"target_d": int(d), "target_pair": list(pair_key(d, p)), "target_selection_reason": reason}


def make_move(blocks, counts, rho, lam, p, block_idx, removed, added):
    block_idx = int(block_idx)
    removed = int(removed)
    added = int(added)
    if removed not in blocks[block_idx] or added in blocks[block_idx]:
        return None
    delta = S62["delta_sparse"](p, blocks[block_idx], removed, added)
    if delta is None:
        return None
    score = S62["score_counts"](counts, lam)
    g = int(sum(int(rho[d]) * int(v) for d, v in delta.items()))
    q = int(sum(int(v) * int(v) for v in delta.values()))
    h = int(2 * g + q)
    kappa = None if q == 0 else float(-2 * g) / float(q)
    pos_destroy = 0
    neg_repair = 0
    for d, value in delta.items():
        r = int(rho[int(d)])
        dv = int(value)
        pos_destroy += max(0, -dv) * max(0, r)
        neg_repair += max(0, dv) * max(0, -r)
    return {
        "block": block_idx,
        "removed": removed,
        "added": added,
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


def add_move_unique(out, seen, blocks, counts, rho, lam, p, block_idx, removed, added):
    key = (int(block_idx), int(removed), int(added))
    if key in seen:
        return
    move = make_move(blocks, counts, rho, lam, p, block_idx, removed, added)
    if move is None:
        return
    seen.add(key)
    out.append(move)


def sample_swap_moves(blocks, counts, rho, lam, p, rng, sample_swaps, target_pair=None):
    sample_swaps = max(1, int(sample_swaps))
    out = []
    seen = set()
    if target_pair:
        for block_idx, block in enumerate(blocks):
            outside = [x for x in range(p) if x not in block]
            if not outside:
                continue
            for d in target_pair:
                d = int(d)
                if int(rho[d]) > 0:
                    for x in list(block):
                        if (x + d) % p in block or (x - d) % p in block:
                            tries = min(8, len(outside))
                            for added in rng.sample(outside, tries):
                                add_move_unique(out, seen, blocks, counts, rho, lam, p, block_idx, x, added)
                elif int(rho[d]) < 0:
                    for y in list(block):
                        for added in ((y + d) % p, (y - d) % p):
                            if added in block:
                                continue
                            removals = list(block)
                            rng.shuffle(removals)
                            for removed in removals[: min(8, len(removals))]:
                                add_move_unique(out, seen, blocks, counts, rho, lam, p, block_idx, removed, added)
                if len(out) >= sample_swaps:
                    return out[:sample_swaps]
    max_tries = max(sample_swaps * 8, 100)
    tries = 0
    while len(out) < sample_swaps and tries < max_tries:
        tries += 1
        block_idx = rng.randrange(4)
        block = blocks[block_idx]
        if len(block) == 0 or len(block) == p:
            continue
        removed = rng.choice(tuple(block))
        added = rng.randrange(p)
        if added in block:
            continue
        add_move_unique(out, seen, blocks, counts, rho, lam, p, block_idx, removed, added)
    out.sort(key=lambda item: (int(item["h"]), -float(item["kappa"] if item["kappa"] is not None else -999.0), -int(item["defect_target_score"])))
    return out[:sample_swaps]


def target_effect(move, rho, target_pair):
    if not target_pair:
        return 0, 0, None, None
    old_abs = 0
    new_abs = 0
    signed_hits = 0
    for d in target_pair:
        d = int(d)
        old = int(rho[d])
        new = old + int(move["delta"].get(d, 0))
        old_abs += abs(old)
        new_abs += abs(new)
        if old > 0 and new < old:
            signed_hits += 1
        elif old < 0 and new > old:
            signed_hits += 1
    target_d = int(target_pair[0])
    return int(old_abs - new_abs), int(signed_hits), int(rho[target_d]), int(rho[target_d] + move["delta"].get(target_d, 0))


def quick_local_diag_from_moves(score, moves):
    if not moves:
        return {"h_min": None, "D_min_ratio": None, "P_8": None, "kappa_max": None}
    h_values = [int(move["h"]) for move in moves]
    kappas = [float(move["kappa"]) for move in moves if move.get("kappa") is not None]
    h_min = min(h_values)
    return {
        "h_min": int(h_min),
        "D_min_ratio": float(score + h_min) / float(score) if score > 0 else None,
        "P_8": float(sum(1 for h in h_values if h <= 8)) / float(len(h_values)),
        "kappa_max": max(kappas) if kappas else None,
    }


def guard_allows(move, blocks, counts, rho, lam, p, rng, old_guard_diag):
    if int(move["h"]) > 16:
        return False
    next_blocks = S62["apply_moves_copy"](blocks, [move])
    if next_blocks is None:
        return False
    next_counts = S62["apply_sparse_delta"](counts, move["delta"])
    next_score = S62["score_counts"](next_counts, lam)
    next_rho = S62["rho_vector"](next_counts, lam)
    next_moves = sample_swap_moves(next_blocks, next_counts, next_rho, lam, p, rng, 160, None)
    new_diag = quick_local_diag_from_moves(next_score, next_moves)
    if old_guard_diag:
        old_d = old_guard_diag.get("D_min_ratio")
        new_d = new_diag.get("D_min_ratio")
        if old_d is not None and new_d is not None and float(new_d) > float(old_d) + 0.25:
            return False
        old_p8 = old_guard_diag.get("P_8")
        new_p8 = new_diag.get("P_8")
        if old_p8 is not None and new_p8 is not None and float(new_p8) < 0.5 * float(old_p8):
            return False
        old_k = old_guard_diag.get("kappa_max")
        new_k = new_diag.get("kappa_max")
        if old_k is not None and new_k is not None and float(new_k) < min(1.0, float(old_k) - 0.25):
            return False
    return True


def choose_focused_move(mode, blocks, counts, lam, p, weights, signs_history, rng, parent_score, restart_id, args, old_guard_diag):
    score = S62["score_counts"](counts, lam)
    rho = S62["rho_vector"](counts, lam)
    target = choose_target(mode, rho, signs_history, weights, parent_score, rng, restart_id)
    target_pair = None if target is None else target["target_pair"]
    moves = sample_swap_moves(blocks, counts, rho, lam, p, rng, int(args.sample_swaps), target_pair)
    local_diag = quick_local_diag_from_moves(score, moves)
    if not moves:
        return None, local_diag, rho, target
    if mode == "baseline_score_only_recheck":
        for move in moves:
            if int(move["h"]) < 0:
                return move, local_diag, rho, target
        return None, local_diag, rho, target
    evaluated = []
    for move in moves:
        improvement, signed_hits, old_rho, new_rho = target_effect(move, rho, target_pair)
        row = dict(move)
        row["target_improvement"] = int(improvement)
        row["target_signed_hits"] = int(signed_hits)
        row["target_rho_old"] = old_rho
        row["target_rho_new"] = new_rho
        row["target_weight"] = float(weights[int(target_pair[0])]) if target_pair else 1.0
        evaluated.append(row)
    evaluated.sort(
        key=lambda m: (
            -int(m["target_improvement"]),
            -int(m["target_signed_hits"]),
            int(m["h"]),
            -float(m["target_weight"]),
            -float(m["kappa"] if m["kappa"] is not None else -999.0),
            int(m["q"]),
        )
    )
    for move in evaluated:
        if int(move["target_improvement"]) <= 0:
            continue
        if mode == "focused_plus_small_threshold":
            if int(move["h"]) <= 8:
                return move, local_diag, rho, target
            continue
        if mode == "focused_with_exactlike_guard":
            if guard_allows(move, blocks, counts, rho, lam, p, rng, old_guard_diag):
                return move, local_diag, rho, target
            continue
        if mode in ("focused_score4_pair", "focused_weighted_defect", "focused_high_abs_rho", "focused_stubborn_defect"):
            if int(move["h"]) <= 8:
                return move, local_diag, rho, target
            continue
        if int(move["h"]) <= 4:
            return move, local_diag, rho, target
    for move in evaluated:
        if int(move["target_improvement"]) >= 0 and int(move["h"]) < 0:
            return move, local_diag, rho, target
    return None, local_diag, rho, target


def exactlike_improved(parent, row):
    checks = []
    if parent.get("D_min_ratio") is not None and row.get("D_min_ratio") is not None:
        checks.append(float(row["D_min_ratio"]) < float(parent["D_min_ratio"]))
    if parent.get("P_8") is not None and row.get("P_8") is not None:
        checks.append(float(row["P_8"]) > float(parent["P_8"]))
    if parent.get("P_16") is not None and row.get("P_16") is not None:
        checks.append(float(row["P_16"]) > float(parent["P_16"]))
    if parent.get("kappa_max") is not None and row.get("kappa_max") is not None:
        checks.append(float(row["kappa_max"]) > float(parent["kappa_max"]))
    if parent.get("Q_ratio") is not None and row.get("Q_ratio") is not None:
        checks.append(float(row["Q_ratio"]) < float(parent["Q_ratio"]))
    return any(checks)


def false_basin_exactlike_escape(parent, row):
    return bool(
        (row.get("D_min_ratio") is not None and float(row.get("D_min_ratio")) < 1.0)
        or (row.get("h_min") is not None and int(row.get("h_min")) < 0)
        or (row.get("kappa_max") is not None and float(row.get("kappa_max")) > 1.0)
        or (parent.get("P_8") is not None and row.get("P_8") is not None and float(row.get("P_8")) >= 2.0 * float(parent.get("P_8")))
    )


def metric_row_for_parent(parent, best_row, final_row):
    best_gain = 0
    final_gain = 0
    if exactlike_improved(parent, best_row):
        best_gain += 1
    if exactlike_improved(parent, final_row):
        final_gain += 1
    for key, direction in (("D_min_ratio", -1), ("P_8", 1), ("P_16", 1), ("kappa_max", 1), ("Q_ratio", -1)):
        base = parent.get(key)
        b = best_row.get(key)
        f = final_row.get(key)
        if base is None or b is None or f is None:
            continue
        if direction < 0:
            if float(b) < float(base):
                best_gain += 1
            if float(f) < float(base):
                final_gain += 1
        else:
            if float(b) > float(base):
                best_gain += 1
            if float(f) > float(base):
                final_gain += 1
    return final_row if final_gain > best_gain else best_row


def run_focused_attempt(parent, mode, restart_id, args, p, ks, lam, baseline, powers):
    seed = int(args.seed_base + 1000003 * (restart_id + 1) + int(parent["score"]) * 17 + sum(ord(c) for c in mode) + int(parent["canonical_hash"][:6], 16))
    rng = random.Random(seed)
    blocks = clone_blocks(parent["_blocks"])
    counts = S62["total_diff_counts"](p, blocks)
    rho = S62["rho_vector"](counts, lam)
    weights = initialize_weights(rho)
    start_support = support_from_rho(rho)
    start_pairs = score4_pairs(rho)
    signs_history = [sign_vector(rho)]
    targeted_coords = set()
    changed_target_coords = set()
    accepted = 0
    stubborn_count = 0
    no_move_streak = 0
    best_blocks = clone_blocks(blocks)
    best_counts = list(counts)
    best_score = S62["score_counts"](counts, lam)
    best_target_improvements = 0
    target_defect_improvement_seen = False
    snapshots = []
    last_local_diag = {
        "h_min": parent.get("h_min"),
        "D_min_ratio": parent.get("D_min_ratio"),
        "P_8": parent.get("P_8"),
        "kappa_max": parent.get("kappa_max"),
    }
    last_target = {
        "target_d": None,
        "target_pair": None,
        "target_rho_old": None,
        "target_rho_new": None,
        "target_improved": False,
        "target_selection_reason": None,
    }

    def snapshot(step):
        current_counts = S62["total_diff_counts"](p, blocks)
        current_rho = S62["rho_vector"](current_counts, lam)
        row = candidate_from_blocks(blocks, p, ks, lam, baseline, powers, mode, parent, restart_id, step, accepted)
        row.update(
            {
                "S": int(row["score"]),
                "target_d": last_target.get("target_d"),
                "target_pair": last_target.get("target_pair"),
                "target_rho_old": last_target.get("target_rho_old"),
                "target_rho_new": last_target.get("target_rho_new"),
                "target_improved": bool(last_target.get("target_improved")),
                "target_selection_reason": last_target.get("target_selection_reason"),
                "stubborn_count": int(stubborn_count),
                "changed_defect_coords_since_start": int(len(start_support.symmetric_difference(support_from_rho(current_rho)))),
            }
        )
        snapshots.append(row)
        return row

    snapshot(0)
    for step in range(1, int(args.steps) + 1):
        counts = S62["total_diff_counts"](p, blocks)
        score = S62["score_counts"](counts, lam)
        rho = S62["rho_vector"](counts, lam)
        if mode == "focused_weighted_defect":
            stubborn_count = update_weights(weights, rho, signs_history, step, int(args.update_interval))
        move, local_diag, rho, target = choose_focused_move(
            mode, blocks, counts, lam, p, weights, signs_history, rng, int(parent["score"]), restart_id, args, last_local_diag
        )
        last_local_diag = local_diag
        if target is not None:
            targeted_coords.update(int(x) for x in target.get("target_pair") or [])
            last_target.update(target)
        if move is None:
            no_move_streak += 1
            if step % int(args.snapshot_interval) == 0:
                snapshot(step)
            if int(args.no_move_patience) > 0 and no_move_streak >= int(args.no_move_patience):
                break
            signs_history.append(sign_vector(rho))
            continue
        next_blocks = S62["apply_moves_copy"](blocks, [move])
        if next_blocks is None:
            break
        if target is not None:
            improvement = int(move.get("target_improvement", 0))
            old_rho = move.get("target_rho_old")
            new_rho = move.get("target_rho_new")
            last_target.update(
                {
                    "target_rho_old": old_rho,
                    "target_rho_new": new_rho,
                    "target_improved": bool(improvement > 0),
                }
            )
            if improvement > 0:
                target_defect_improvement_seen = True
                best_target_improvements += 1
                changed_target_coords.update(int(x) for x in target.get("target_pair") or [])
        blocks = next_blocks
        accepted += 1
        no_move_streak = 0
        counts = S62["apply_sparse_delta"](counts, move["delta"])
        rho = S62["rho_vector"](counts, lam)
        signs_history.append(sign_vector(rho))
        score = S62["score_counts"](counts, lam)
        if score < best_score:
            best_score = int(score)
            best_blocks = clone_blocks(blocks)
            best_counts = list(counts)
        if step % int(args.snapshot_interval) == 0:
            snapshot(step)
        if score == 0:
            snapshot(step)
            best_blocks = clone_blocks(blocks)
            best_counts = list(counts)
            best_score = 0
            break

    final_counts = S62["total_diff_counts"](p, blocks)
    final_rho = S62["rho_vector"](final_counts, lam)
    best_rho = S62["rho_vector"](best_counts, lam)
    final_row = candidate_from_blocks(blocks, p, ks, lam, baseline, powers, mode, parent, restart_id, accepted, accepted)
    best_row = candidate_from_blocks(best_blocks, p, ks, lam, baseline, powers, mode, parent, restart_id, accepted, accepted)
    final_support = support_from_rho(final_rho)
    best_support = support_from_rho(best_rho)
    initial_best_persistent = start_support.intersection(best_support)
    union_support = start_support.union(best_support)
    parent_score = int(parent["score"])
    score_escape = int(best_row["score"]) < parent_score
    metric_row = metric_row_for_parent(parent, best_row, final_row)
    exactlike_escape = false_basin_exactlike_escape(parent, best_row) or false_basin_exactlike_escape(parent, final_row)
    escaped_false = bool(parent.get("label") == "false_like" and (score_escape or exactlike_escape))
    best_pairs = score4_pairs(best_rho)
    plus_changed = set(tuple(x) for x in start_pairs["plus_pairs"]) != set(tuple(x) for x in best_pairs["plus_pairs"])
    minus_changed = set(tuple(x) for x in start_pairs["minus_pairs"]) != set(tuple(x) for x in best_pairs["minus_pairs"])
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
        "parent_defect_support_size": parent.get("defect_support_size"),
        "parent_defect_pattern_signature": parent.get("pattern_signature"),
        "accepted_moves": int(accepted),
        "best_S": int(best_row["score"]),
        "final_S": int(final_row["score"]),
        "best_score_delta": int(best_row["score"] - parent_score),
        "best_D_min_ratio": metric_row.get("D_min_ratio"),
        "best_P_8": metric_row.get("P_8"),
        "best_P_16": metric_row.get("P_16"),
        "best_kappa_max": metric_row.get("kappa_max"),
        "best_Q_ratio": metric_row.get("Q_ratio"),
        "score_improvement_seen": bool(int(best_row["score"]) < parent_score),
        "score0_seen": bool(int(best_row["score"]) == 0),
        "score4_to_lower_seen": bool(parent_score == 4 and int(best_row["score"]) < 4),
        "target_defect_improvement_seen": bool(target_defect_improvement_seen),
        "target_defect_improvement_count": int(best_target_improvements),
        "persistent_defect_fraction": float(len(initial_best_persistent)) / float(len(start_support)) if start_support else None,
        "defect_support_turnover": float(len(start_support.symmetric_difference(best_support))) / float(len(union_support)) if union_support else 0.0,
        "escaped_false_basin": escaped_false,
        "score_escape": bool(parent.get("label") == "false_like" and score_escape),
        "exactlike_escape": bool(parent.get("label") == "false_like" and exactlike_escape),
        "target_defect_escape": bool(parent.get("label") == "false_like" and target_defect_improvement_seen),
        "exactlike_improved": bool(exactlike_improved(parent, best_row) or exactlike_improved(parent, final_row)),
        "final_label": final_row.get("label"),
        "best_label": best_row.get("label"),
        "targeted_coord_count": int(len(targeted_coords)),
        "changed_target_coord_count": int(len(changed_target_coords)),
        "score4_plus_pair_changed": bool(parent_score == 4 and plus_changed),
        "score4_minus_pair_changed": bool(parent_score == 4 and minus_changed),
        "score4_plus_minus_pair_both_improved": bool(parent_score == 4 and plus_changed and minus_changed and target_defect_improvement_seen),
        "initial_plus_pairs": start_pairs["plus_pairs"],
        "initial_minus_pairs": start_pairs["minus_pairs"],
        "best_plus_pairs": best_pairs["plus_pairs"],
        "best_minus_pairs": best_pairs["minus_pairs"],
        "_best_row": best_row,
        "_final_row": final_row,
        "_initial_support": start_support,
        "_final_support": final_support,
        "_best_support": best_support,
        "_targeted_coords": targeted_coords,
    }
    return attempt, snapshots


def defect_dynamics_for_attempt(attempt):
    initial = set(attempt.get("_initial_support", set()))
    final = set(attempt.get("_best_support", set()))
    targeted = set(attempt.get("_targeted_coords", set()))
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
        "targeted_coords": sorted(targeted),
        "targeted_removed_count": int(len(targeted.intersection(removed))),
        "targeted_persistent_count": int(len(targeted.intersection(persistent))),
        "persistent_defect_fraction": float(len(persistent)) / float(len(initial)) if initial else None,
        "targeted_persistent_fraction": float(len(targeted.intersection(persistent))) / float(len(targeted)) if targeted else None,
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
                "score_improvement_rate": rate(rows, "score_improvement_seen"),
                "score0_count": int(sum(1 for row in rows if row.get("score0_seen"))),
                "score0_rate": rate(rows, "score0_seen"),
                "score4_parent_count": int(len(score4)),
                "score4_to_lower_count": int(sum(1 for row in score4 if row.get("score4_to_lower_seen"))),
                "score4_to_lower_rate": float(sum(1 for row in score4 if row.get("score4_to_lower_seen"))) / float(len(score4)) if score4 else None,
                "score4_to_score0_count": int(sum(1 for row in score4 if row.get("score0_seen"))),
                "score4_to_score0_rate": float(sum(1 for row in score4 if row.get("score0_seen"))) / float(len(score4)) if score4 else None,
                "target_defect_improvement_count": int(sum(1 for row in rows if row.get("target_defect_improvement_seen"))),
                "target_defect_improvement_rate": rate(rows, "target_defect_improvement_seen"),
                "escaped_false_basin_count": int(sum(1 for row in rows if row.get("escaped_false_basin"))),
                "escaped_false_basin_rate": rate(rows, "escaped_false_basin"),
                "exactlike_improved_count": int(sum(1 for row in rows if row.get("exactlike_improved"))),
                "exactlike_improved_rate": rate(rows, "exactlike_improved"),
                "median_best_score": median([row.get("best_S") for row in rows]),
                "median_best_D_min_ratio": median([row.get("best_D_min_ratio") for row in rows]),
                "median_best_P_8": median([row.get("best_P_8") for row in rows]),
                "median_best_kappa_max": median([row.get("best_kappa_max") for row in rows]),
                "median_best_Q_ratio": median([row.get("best_Q_ratio") for row in rows]),
                "median_persistent_defect_fraction": median([row.get("persistent_defect_fraction") for row in rows]),
                "median_defect_support_turnover": median([row.get("defect_support_turnover") for row in rows]),
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
                "median_targeted_persistent_fraction": median([row.get("targeted_persistent_fraction") for row in rows]),
                "median_defect_support_turnover": median([row.get("defect_support_turnover") for row in rows]),
                "mean_persistent_defect_fraction": mean([row.get("persistent_defect_fraction") for row in rows]),
                "mean_defect_support_turnover": mean([row.get("defect_support_turnover") for row in rows]),
                "targeted_removed_count": int(sum(int(row.get("targeted_removed_count") or 0) for row in rows)),
                "targeted_persistent_count": int(sum(int(row.get("targeted_persistent_count") or 0) for row in rows)),
            }
        )
    return out


def summarize_score4(attempts):
    rows = [row for row in attempts if int(row["parent_score"]) == 4]
    if not rows:
        return {
            "score4_parent_count": 0,
            "score4_attempt_count": 0,
            "score4_to_lower_count": 0,
            "score4_to_lower_rate": None,
            "score4_to_score0_count": 0,
            "score4_to_score0_rate": None,
        }
    return {
        "score4_parent_count": int(len(set(row["parent_hash"] for row in rows))),
        "score4_attempt_count": int(len(rows)),
        "score4_to_lower_count": int(sum(1 for row in rows if row.get("score4_to_lower_seen"))),
        "score4_to_lower_rate": rate(rows, "score4_to_lower_seen"),
        "score4_to_score0_count": int(sum(1 for row in rows if row.get("score0_seen"))),
        "score4_to_score0_rate": rate(rows, "score0_seen"),
        "target_plus_pair_changed": int(sum(1 for row in rows if row.get("score4_plus_pair_changed"))),
        "target_minus_pair_changed": int(sum(1 for row in rows if row.get("score4_minus_pair_changed"))),
        "plus_minus_pair_both_improved": int(sum(1 for row in rows if row.get("score4_plus_minus_pair_both_improved"))),
        "best_D_min_ratio_after": min([float(row["best_D_min_ratio"]) for row in rows if row.get("best_D_min_ratio") is not None], default=None),
        "best_P_8_after": max([float(row["best_P_8"]) for row in rows if row.get("best_P_8") is not None], default=None),
        "best_kappa_after": max([float(row["best_kappa_max"]) for row in rows if row.get("best_kappa_max") is not None], default=None),
        "by_mode": summarize_by_mode(rows),
    }


def load_dynamic_reference(path):
    for candidate in (path, DYNAMIC_REFERENCE_FALLBACK):
        if not candidate or not os.path.exists(candidate):
            continue
        try:
            with open(candidate) as f:
                payload = json.load(f)
            if isinstance(payload, dict):
                payload["_reference_path"] = candidate
            return payload
        except Exception:
            continue
    return None


def evaluate_hypotheses(mode_rows, defect_summary, attempts, dynamic_reference):
    by_mode = {row["mode"]: row for row in mode_rows}
    baseline = by_mode.get("baseline_score_only_recheck", {})
    focused = [row for row in mode_rows if row["mode"] != "baseline_score_only_recheck"]
    best_score_improve = max((float(row.get("score_improvement_rate") or 0.0) for row in focused), default=0.0)
    base_score_improve = float(baseline.get("score_improvement_rate") or 0.0)
    best_score4_lower = max((float(row.get("score4_to_lower_rate") or 0.0) for row in focused), default=0.0)
    base_score4_lower = float(baseline.get("score4_to_lower_rate") or 0.0)
    best_escape = max((float(row.get("escaped_false_basin_rate") or 0.0) for row in focused), default=0.0)
    base_escape = float(baseline.get("escaped_false_basin_rate") or 0.0)
    best_p8 = max((float(row.get("median_best_P_8") or 0.0) for row in focused), default=0.0)
    base_p8 = float(baseline.get("median_best_P_8") or 0.0)
    best_kappa = max((float(row.get("median_best_kappa_max") or 0.0) for row in focused), default=0.0)
    base_kappa = float(baseline.get("median_best_kappa_max") or 0.0)
    best_dmin = min((float(row.get("median_best_D_min_ratio") or 10**9) for row in focused), default=10**9)
    base_dmin = float(baseline.get("median_best_D_min_ratio") or 10**9)
    dyn_by_mode = {row["mode"]: row for row in defect_summary}
    base_persist = dyn_by_mode.get("baseline_score_only_recheck", {}).get("median_persistent_defect_fraction")
    best_persist = min(
        [float(row.get("median_persistent_defect_fraction")) for row in defect_summary if row["mode"] != "baseline_score_only_recheck" and row.get("median_persistent_defect_fraction") is not None],
        default=None,
    )
    best_turnover = max(
        [float(row.get("median_defect_support_turnover") or 0.0) for row in defect_summary if row["mode"] != "baseline_score_only_recheck"],
        default=0.0,
    )
    base_turnover = float(dyn_by_mode.get("baseline_score_only_recheck", {}).get("median_defect_support_turnover") or 0.0)
    best_target = max((float(row.get("target_defect_improvement_rate") or 0.0) for row in focused), default=0.0)
    target_only_rows = [row for row in attempts if row.get("target_defect_improvement_seen") and not row.get("score_improvement_seen") and not row.get("exactlike_improved")]
    target_only_rate = float(len(target_only_rows)) / float(len(attempts)) if attempts else 0.0
    dyn_best_score = None
    dyn_best_escape = None
    if dynamic_reference:
        dyn_best_score = dynamic_reference.get("best_weighted_score_improvement_rate")
        dyn_best_escape = dynamic_reference.get("best_weighted_escape_rate")
    h1_supported = (
        best_score4_lower > base_score4_lower
        or best_escape > base_escape
        or best_score_improve > base_score_improve
        or best_dmin < base_dmin
        or best_p8 > base_p8
        or best_kappa > base_kappa
    )
    h2_supported = (
        best_target > float(baseline.get("target_defect_improvement_rate") or 0.0)
        and (
            (base_persist is not None and best_persist is not None and best_persist < float(base_persist))
            or best_turnover > base_turnover
        )
    )
    h3_supported = False
    if dyn_best_score is not None:
        h3_supported = best_score_improve > float(dyn_best_score)
    if dyn_best_escape is not None:
        h3_supported = h3_supported or best_escape > float(dyn_best_escape)
    h4_supported = target_only_rate >= 0.25 and best_target > 0.0
    return {
        "H_FRW1": "supported" if h1_supported else "not_supported",
        "H_FRW2": "supported" if h2_supported else "not_supported",
        "H_FRW3": "supported" if h3_supported else ("inconclusive_no_dynamic_reference" if dynamic_reference is None else "not_supported"),
        "H_FRW4": "supported" if h4_supported else "not_supported",
        "baseline_score_improvement_rate": base_score_improve,
        "best_focused_score_improvement_rate": best_score_improve,
        "baseline_score4_to_lower_rate": base_score4_lower,
        "best_focused_score4_to_lower_rate": best_score4_lower,
        "baseline_escaped_false_basin_rate": base_escape,
        "best_focused_escaped_false_basin_rate": best_escape,
        "baseline_median_D_min_ratio": None if base_dmin == 10**9 else base_dmin,
        "best_focused_median_D_min_ratio": None if best_dmin == 10**9 else best_dmin,
        "baseline_median_P_8": base_p8,
        "best_focused_median_P_8": best_p8,
        "baseline_median_kappa_max": base_kappa,
        "best_focused_median_kappa_max": best_kappa,
        "baseline_persistent_defect_fraction": base_persist,
        "best_focused_persistent_defect_fraction": best_persist,
        "baseline_defect_support_turnover": base_turnover,
        "best_focused_defect_support_turnover": best_turnover,
        "best_focused_target_defect_improvement_rate": best_target,
        "target_only_shift_rate": target_only_rate,
        "dynamic_reference_path": dynamic_reference.get("_reference_path") if dynamic_reference else None,
        "dynamic_best_weighted_score_improvement_rate": dyn_best_score,
        "dynamic_best_weighted_escape_rate": dyn_best_escape,
    }


def best_focused_mode(mode_rows):
    focused = [row for row in mode_rows if row["mode"] != "baseline_score_only_recheck"]
    if not focused:
        return None
    return sorted(
        focused,
        key=lambda row: (
            -float(row.get("escaped_false_basin_rate") or 0.0),
            -float(row.get("score4_to_lower_rate") or 0.0),
            -float(row.get("score_improvement_rate") or 0.0),
            -float(row.get("target_defect_improvement_rate") or 0.0),
            float(row.get("median_best_score") or 10**9),
        ),
    )[0]["mode"]


def write_summary(path, args, parent_rows, mode_rows, defect_summary, score4_summary, hypo, score0_paths, validation_notes):
    best_mode = best_focused_mode(mode_rows)
    score4_to_lower = int(score4_summary.get("score4_to_lower_count") or 0)
    score4_to_zero = int(score4_summary.get("score4_to_score0_count") or 0)
    target_changed = max((float(row.get("target_defect_improvement_rate") or 0.0) for row in mode_rows if row["mode"] != "baseline_score_only_recheck"), default=0.0) > 0
    persist_down = (
        hypo.get("baseline_persistent_defect_fraction") is not None
        and hypo.get("best_focused_persistent_defect_fraction") is not None
        and float(hypo["best_focused_persistent_defect_fraction"]) < float(hypo["baseline_persistent_defect_fraction"])
    )
    exactlike_metric_improved = bool(
        (hypo.get("best_focused_median_D_min_ratio") is not None and hypo.get("baseline_median_D_min_ratio") is not None and float(hypo["best_focused_median_D_min_ratio"]) < float(hypo["baseline_median_D_min_ratio"]))
        or float(hypo.get("best_focused_median_P_8") or 0.0) > float(hypo.get("baseline_median_P_8") or 0.0)
        or float(hypo.get("best_focused_median_kappa_max") or 0.0) > float(hypo.get("baseline_median_kappa_max") or 0.0)
    )
    dynamic_better = hypo.get("H_FRW3") == "supported"
    lines = [
        "# p37 Focused Defect Random Walk Validation",
        "",
        "これは p=37 の false basin / low-score candidate に対する focused random walk の検証です。Hadamard 668 を解くrunではありません。",
        "",
        "## Run",
        "",
        "- parents: `{}`".format(len(parent_rows)),
        "- steps: `{}`".format(args.steps),
        "- restarts: `{}`".format(args.restarts),
        "- sample_swaps: `{}`".format(args.sample_swaps),
        "- modes: `{}`".format(", ".join(MODES)),
        "- score=0 だけを success と呼ぶ",
        "",
        "## Mode Summary",
        "",
        "```json",
        json.dumps(json_safe(mode_rows), indent=2, sort_keys=True),
        "```",
        "",
        "## Defect Dynamics Summary",
        "",
        "```json",
        json.dumps(json_safe(defect_summary), indent=2, sort_keys=True),
        "```",
        "",
        "## Score=4 Summary",
        "",
        "```json",
        json.dumps(json_safe(score4_summary), indent=2, sort_keys=True),
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
        "1. focused random walk は score-only baseline より score improvement を増やしたか: `{}`。baseline `{}` vs focused best `{}`。".format(
            bool(float(hypo.get("best_focused_score_improvement_rate") or 0.0) > float(hypo.get("baseline_score_improvement_rate") or 0.0)),
            hypo.get("baseline_score_improvement_rate"),
            hypo.get("best_focused_score_improvement_rate"),
        ),
        "2. score=4 false basin から score<4 は出たか: `{}`。count `{}`。".format(score4_to_lower > 0, score4_to_lower),
        "3. score=4 false basin から score=0 は出たか: `{}`。count `{}`。".format(score4_to_zero > 0, score4_to_zero),
        "4. target defect coordinate は実際に変化したか: `{}`。best target improvement rate `{}`。".format(target_changed, hypo.get("best_focused_target_defect_improvement_rate")),
        "5. persistent defect fraction は下がったか: `{}`。baseline `{}` vs focused best `{}`。".format(persist_down, hypo.get("baseline_persistent_defect_fraction"), hypo.get("best_focused_persistent_defect_fraction")),
        "6. D_min/S, P_tau, kappa は改善したか: `{}`。D_min `{}` -> `{}`, P_8 `{}` -> `{}`, kappa `{}` -> `{}`。".format(
            exactlike_metric_improved,
            hypo.get("baseline_median_D_min_ratio"),
            hypo.get("best_focused_median_D_min_ratio"),
            hypo.get("baseline_median_P_8"),
            hypo.get("best_focused_median_P_8"),
            hypo.get("baseline_median_kappa_max"),
            hypo.get("best_focused_median_kappa_max"),
        ),
        "7. focused modes は dynamic defect weighting より有効だったか: `{}`。H-FRW3 `{}`。".format(dynamic_better, hypo.get("H_FRW3")),
        "8. どの focused mode が最も有効だったか: `{}`。".format(best_mode),
        "9. focused move は局所 defect を改善しただけで、別 defect にズレを移しただけではないか: H-FRW4 `{}`、target-only shift rate `{}`。".format(hypo.get("H_FRW4"), hypo.get("target_only_shift_rate")),
        "10. H-FRW1, H-FRW2, H-FRW3, H-FRW4 の判定はどうか: `{}`。".format(json.dumps({k: hypo.get(k) for k in ("H_FRW1", "H_FRW2", "H_FRW3", "H_FRW4")}, sort_keys=True)),
        "11. 668 に戻すなら focused random walk を main descent, perturbation, repair preconditioner のどれとして使うべきか: H-FRW1/H-FRW2 が supported なら repair preconditioner か perturbation として使い、score=0検証前の success 判定には使わない。main descent 化は p=37 で score escape と exact-like 指標改善が同時に安定してからにする。",
        "",
        "## Validation",
        "",
    ]
    lines.extend("- {}".format(note) for note in validation_notes)
    if score0_paths:
        lines.append("")
        lines.append("## Score0 Candidates")
        lines.extend("- `{}`".format(path) for path in score0_paths)
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def save_score0(out_dir, row, mode, p, ks, lam):
    return S62["save_score0_candidate"](out_dir, row, mode, p, ks, lam)


def run_cmd(cmd):
    proc = subprocess.run(cmd, cwd=os.getcwd(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return proc.returncode, proc.stdout


def delete_sage_py_temps():
    removed = []
    for dirpath, _dirnames, filenames in os.walk("sage"):
        for name in filenames:
            if name.endswith(".sage.py"):
                path = os.path.join(dirpath, name)
                try:
                    os.remove(path)
                    removed.append(path)
                except Exception:
                    pass
    return removed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--p", type=int, default=37)
    parser.add_argument("--ks", default="13,16,18,18")
    parser.add_argument("--lambda", dest="lam", type=int, default=28)
    parser.add_argument("--exact-json", default="outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json")
    parser.add_argument("--max-parent-candidates", type=int, default=60)
    parser.add_argument("--steps", type=int, default=500)
    parser.add_argument("--restarts", type=int, default=2)
    parser.add_argument("--sample-swaps", type=int, default=200)
    parser.add_argument("--snapshot-interval", type=int, default=50)
    parser.add_argument("--update-interval", type=int, default=50)
    parser.add_argument("--no-move-patience", type=int, default=80)
    parser.add_argument("--seed-base", type=int, default=20260507)
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--no-external-validation", action="store_true")
    args = parser.parse_args()

    p = int(args.p)
    ks = parse_ks(args.ks)
    lam = int(args.lam)
    baseline = S62["random_baseline_tuple"](p, ks)
    out_dir = args.out_dir or os.path.join("outputs", "explorations", "{}_p37_focused_defect_random_walk_validation".format(now_stamp()))
    ensure_dir(out_dir)

    exact_blocks = load_exact_blocks(args.exact_json, p, ks, lam)
    config = {
        "script": SCRIPT_NAME,
        "p": p,
        "ks": list(ks),
        "lambda": lam,
        "exact_json": args.exact_json,
        "max_parent_candidates": int(args.max_parent_candidates),
        "steps": int(args.steps),
        "restarts": int(args.restarts),
        "sample_swaps": int(args.sample_swaps),
        "snapshot_interval": int(args.snapshot_interval),
        "modes": list(MODES),
        "candidate_search_paths": candidate_search_paths(),
        "dynamic_reference": DYNAMIC_REFERENCE,
        "dynamic_reference_fallback": DYNAMIC_REFERENCE_FALLBACK,
    }
    write_json(os.path.join(out_dir, "run_config.json"), config)
    with open(os.path.join(out_dir, "run_log.md"), "w") as f:
        f.write("# p37 focused defect random walk run log\n\n")
        f.write("- script: `{}`\n".format(SCRIPT_NAME))
        f.write("- started_at: `{}`\n".format(time.strftime("%Y-%m-%d %H:%M:%S %Z")))

    raw_payloads = collect_payload_candidates(p, ks, lam)
    selected_payloads = select_parent_payloads(raw_payloads, int(args.max_parent_candidates), exact_blocks, p, ks, lam, int(args.seed_base))
    if not selected_payloads:
        raise RuntimeError("no p37 parent candidates found")
    parent_rows = make_parent_rows(selected_payloads, p, ks, lam, baseline, POWERS_DEFAULT)
    write_jsonl(os.path.join(out_dir, "input_focused_walk_candidates.jsonl"), parent_rows)
    print("Parents:", len(parent_rows))

    attempts = []
    snapshots = []
    dynamics = []
    score0_paths = []
    for parent_idx, parent in enumerate(parent_rows):
        print("parent", parent_idx, "score", parent["score"], "label", parent.get("label"), parent["canonical_hash"][:12])
        for mode in MODES:
            for restart in range(int(args.restarts)):
                attempt, run_snapshots = run_focused_attempt(parent, mode, restart, args, p, ks, lam, baseline, POWERS_DEFAULT)
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

    write_jsonl(os.path.join(out_dir, "focused_walk_attempts.jsonl"), attempts)
    write_jsonl(os.path.join(out_dir, "focused_walk_snapshots.jsonl"), snapshots)
    write_jsonl(os.path.join(out_dir, "focused_defect_coordinate_dynamics.jsonl"), dynamics)
    mode_rows = summarize_by_mode(attempts)
    defect_summary = summarize_defect_dynamics(dynamics)
    score4_summary = summarize_score4(attempts)
    dynamic_reference = load_dynamic_reference(DYNAMIC_REFERENCE)
    hypo = evaluate_hypotheses(mode_rows, defect_summary, attempts, dynamic_reference)
    write_csv(
        os.path.join(out_dir, "focused_walk_by_mode_summary.csv"),
        mode_rows,
        sorted(set().union(*(row.keys() for row in mode_rows))) if mode_rows else ["mode", "attempt_count"],
    )
    write_json(os.path.join(out_dir, "focused_walk_by_mode_summary.json"), {"rows": mode_rows})
    write_csv(
        os.path.join(out_dir, "focused_defect_coordinate_summary.csv"),
        defect_summary,
        sorted(set().union(*(row.keys() for row in defect_summary))) if defect_summary else ["mode", "count"],
    )
    write_csv(
        os.path.join(out_dir, "score4_focused_walk_summary.csv"),
        [score4_summary],
        sorted(score4_summary.keys()),
    )
    write_json(os.path.join(out_dir, "score4_focused_walk_summary.json"), score4_summary)
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
    removed = delete_sage_py_temps()
    validation_notes.append("Removed `.sage.py` temp files: `{}`.".format(len(removed)))

    write_summary(
        os.path.join(out_dir, "p37_focused_defect_random_walk_summary.md"),
        args,
        parent_rows,
        mode_rows,
        defect_summary,
        score4_summary,
        hypo,
        score0_paths,
        validation_notes,
    )
    print("SUMMARY:", os.path.join(out_dir, "p37_focused_defect_random_walk_summary.md"))


if __name__ == "__main__":
    main()
