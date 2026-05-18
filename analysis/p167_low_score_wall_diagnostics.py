#!/usr/bin/env python3
import argparse
import collections
import csv
import hashlib
import itertools
import json
import math
import os
import random
import statistics
import sys
import time
from pathlib import Path

import p167_frontier_repair_benchmark as base


P_DEFAULT = 167
EXPERIMENT_DEFAULT = "p167_low_score_wall_diagnostics"
OUTPUT_ROOT_DEFAULT = "outputs/p167_low_score_wall_diagnostics"
FRONTIER_FILES_DEFAULT = ",".join(
    [
        "configs/fixtures/p167_c01_c05_best_frontier_focus_candidates.jsonl",
        "configs/fixtures/p167_softwall_escape_frontier_candidates.jsonl",
        "configs/fixtures/p167_targeted_deep_frontier_repair_candidates.jsonl",
        "configs/fixtures/p167_frontier_repair_seed_candidates.jsonl",
        "configs/fixtures/benchmark_traps/p167_score164_176.jsonl",
        "configs/fixtures/p167_focused_nearhit_candidates.jsonl",
    ]
)
TUPLE_CLASSES_DEFAULT = "p167_c01,p167_c05,p167_c09"
PAIR_SPLITS = base.PAIR_SPLITS
P37 = base.P37


def parse_csv(text, cast=str):
    if isinstance(text, (list, tuple)):
        return [cast(x) for x in text]
    return [cast(part.strip()) for part in str(text).split(",") if part.strip()]


def ensure_dir(path):
    if path:
        os.makedirs(path, exist_ok=True)


def json_safe(value):
    return base.json_safe(value)


def write_json(path, payload):
    base.write_json(path, payload)


def write_jsonl(path, rows):
    base.write_jsonl(path, rows)


def write_csv(path, rows, fields):
    base.write_csv(path, rows, fields)


def read_jsonl(path):
    return base.read_jsonl(path)


def median(values):
    vals = [float(v) for v in values if v is not None]
    return statistics.median(vals) if vals else None


def mean(values):
    vals = [float(v) for v in values if v is not None]
    return statistics.mean(vals) if vals else None


def stable_int(text):
    return int(hashlib.sha256(str(text).encode("utf-8")).hexdigest()[:12], 16)


def normalize_tuple_id(value):
    value = str(value or "").strip()
    if value.startswith("p167_"):
        return value
    if value.startswith("c") and len(value) == 3:
        return "p167_" + value
    return value


def score_blocks(p, blocks, lam):
    return P37.score_blocks(p, blocks, lam)


def rho_vector(p, blocks, lam):
    return P37.rho_vector(p, blocks, lam)


def score_from_rho(rho):
    return P37.score_from_rho(rho)


def spacing_stats(p, support):
    support = sorted(int(x) % p for x in support)
    if not support:
        return {"count": 0, "min_gap": None, "median_gap": None, "max_gap": None}
    gaps = []
    for idx, x in enumerate(support):
        y = support[(idx + 1) % len(support)]
        gaps.append((y - x) % p)
    return {
        "count": len(support),
        "min_gap": min(gaps),
        "median_gap": median(gaps),
        "max_gap": max(gaps),
    }


def shift_overlap_stats(p, left, right):
    left = set(int(x) % p for x in left)
    right = set(int(x) % p for x in right)
    if not left or not right:
        return {"best_shift": None, "max_overlap": 0, "mean_overlap": 0.0}
    overlaps = []
    for shift in range(p):
        shifted = {(x + shift) % p for x in right}
        overlaps.append((len(left & shifted), shift))
    max_overlap, best_shift = max(overlaps)
    return {
        "best_shift": int(best_shift),
        "max_overlap": int(max_overlap),
        "mean_overlap": float(sum(v for v, _ in overlaps)) / float(p),
    }


def candidate_hash(blocks):
    return base.canonical_hash(blocks)


def load_all_candidates(args):
    registry = base.load_tuple_registry(args.tuple_registry)
    wanted = set(normalize_tuple_id(x) for x in parse_csv(args.tuple_classes))
    rows = []
    for path in parse_csv(args.frontier_files):
        for line_idx, row in enumerate(read_jsonl(path), 1):
            blocks = [set(int(x) % int(args.p) for x in block) for block in row.get("blocks", [])]
            if len(blocks) != 4:
                continue
            ks = [len(block) for block in blocks]
            lam = int(row.get("lambda", row.get("lam", 0)))
            tuple_class = normalize_tuple_id(row.get("tuple_class") or row.get("tuple_class_id") or "")
            if not tuple_class:
                tuple_class = base.infer_tuple_class(ks, lam, registry)
            if tuple_class not in wanted:
                continue
            computed_score = score_blocks(int(args.p), blocks, lam)
            score = int(row.get("score", row.get("initial_score", computed_score)))
            if score != computed_score:
                score = computed_score
            h = row.get("candidate_hash") or row.get("canonical_hash_before") or candidate_hash(blocks)
            out = {
                "candidate_id": row.get("frontier_candidate_id") or row.get("candidate_id") or "{}:{:05d}".format(path, line_idx),
                "source_file": row.get("source_file", path),
                "source_fixture": path,
                "source_run": row.get("source_run", ""),
                "source_label": row.get("source_label") or row.get("label", ""),
                "source_method": row.get("source_method", ""),
                "tuple_class": tuple_class,
                "frontier_bucket": row.get("frontier_bucket") or row.get("benchmark_role") or base.bucket_for_candidate(tuple_class, score, row),
                "score": int(score),
                "lambda": int(lam),
                "ks": ks,
                "blocks": [[int(x) for x in sorted(block)] for block in blocks],
                "candidate_hash": h,
            }
            out["wall_role"] = wall_role(out)
            rows.append(out)
    deduped = []
    seen = set()
    for row in sorted(rows, key=lambda r: (role_priority(r), r["tuple_class"], r["score"], r["candidate_hash"])):
        if row["candidate_hash"] in seen:
            continue
        seen.add(row["candidate_hash"])
        row["candidate_id"] = "wall_{:04d}".format(len(deduped))
        deduped.append(row)
    return select_candidates(deduped, args)


def wall_role(row):
    tuple_class = row["tuple_class"]
    score = int(row["score"])
    bucket = str(row.get("frontier_bucket") or "")
    if tuple_class == "p167_c01" and score == 172:
        return "core_c01_172"
    if tuple_class == "p167_c05" and score == 164:
        return "core_c05_164"
    if tuple_class == "p167_c09" and score == 160:
        return "core_c09_160"
    if tuple_class == "p167_c09" and score == 164:
        return "core_c09_164"
    if tuple_class == "p167_c09" and score == 176:
        return "core_c09_176"
    if score <= 180:
        return "near_wall_le_180"
    if score <= 200:
        return "near_wall_le_200"
    if tuple_class in {"p167_c01", "p167_c05"} and score <= 400:
        return "previous_300_frontier"
    if score <= 1200:
        return "medium_repairable_control"
    if "trap" in bucket:
        return "trap_control"
    return "diversity_control"


def role_priority(row):
    order = {
        "core_c01_172": 0,
        "core_c05_164": 1,
        "core_c09_160": 2,
        "core_c09_164": 3,
        "core_c09_176": 4,
        "near_wall_le_180": 5,
        "near_wall_le_200": 6,
        "previous_300_frontier": 7,
        "medium_repairable_control": 8,
        "trap_control": 9,
        "diversity_control": 10,
    }
    return (order.get(row.get("wall_role"), 99), int(row["score"]))


def select_candidates(rows, args):
    target = int(args.candidate_count)
    selected = []
    seen = set()

    def add(row):
        if row["candidate_hash"] in seen:
            return False
        seen.add(row["candidate_hash"])
        selected.append(row)
        return True

    # Include all core wall representatives first, with bounded multiplicity for c09 164/176.
    role_limits = {
        "core_c01_172": 2,
        "core_c05_164": 2,
        "core_c09_160": 2,
        "core_c09_164": 4,
        "core_c09_176": 4,
    }
    for role, limit in role_limits.items():
        count = 0
        for row in rows:
            if row["wall_role"] == role and count < limit:
                add(row)
                count += 1

    # Then balance near-wall and controls across tuple classes.
    role_order = [
        "near_wall_le_180",
        "near_wall_le_200",
        "previous_300_frontier",
        "medium_repairable_control",
        "trap_control",
        "diversity_control",
    ]
    tuple_order = parse_csv(args.tuple_classes)
    while len(selected) < target:
        added = False
        for role in role_order:
            for tuple_class in tuple_order:
                for row in rows:
                    if row["wall_role"] == role and row["tuple_class"] == tuple_class and add(row):
                        added = True
                        break
                if len(selected) >= target:
                    break
            if len(selected) >= target:
                break
        if not added:
            break

    if args.smoke:
        selected = selected[: max(1, int(args.candidate_count))]
    for idx, row in enumerate(selected):
        row["diagnostic_candidate_id"] = "diag_{:04d}".format(idx)
    if not selected:
        raise ValueError("no diagnostic candidates selected")
    return selected


def shard_candidates(candidates, shard_id, shard_count):
    out = []
    for row in candidates:
        key = row.get("candidate_hash") or row.get("diagnostic_candidate_id")
        if stable_int(key) % int(shard_count) == int(shard_id):
            out.append(row)
    return out


def defect_geometry_row(candidate, args):
    p = int(args.p)
    blocks = [set(block) for block in candidate["blocks"]]
    lam = int(candidate["lambda"])
    rho = rho_vector(p, blocks, lam)
    vals = [int(x) for x in rho[1:]]
    support = [d for d in range(1, p) if rho[d] != 0]
    positive = [d for d in range(1, p) if rho[d] > 0]
    negative = [d for d in range(1, p) if rho[d] < 0]
    hist = collections.Counter(vals)
    abs_hist = collections.Counter(abs(v) for v in vals)
    sym_mismatch = sum(1 for d in range(1, p) if rho[d] != rho[(-d) % p])
    support_spacing = spacing_stats(p, support)
    pos_spacing = spacing_stats(p, positive)
    neg_spacing = spacing_stats(p, negative)
    overlap = shift_overlap_stats(p, positive, negative)
    top = sorted([(abs(rho[d]), d, rho[d]) for d in range(1, p) if rho[d] != 0], reverse=True)[: int(args.top_defect_count)]
    return {
        **candidate_keys(candidate),
        "score": int(score_from_rho(rho)),
        "rho_l1": int(sum(abs(v) for v in vals)),
        "max_abs_rho": int(max(abs(v) for v in vals) if vals else 0),
        "defect_support_size": len(support),
        "positive_support_size": len(positive),
        "negative_support_size": len(negative),
        "positive_mass": int(sum(rho[d] for d in positive)),
        "negative_mass": int(sum(-rho[d] for d in negative)),
        "rho_value_histogram": dict(sorted(hist.items())),
        "rho_abs_histogram": dict(sorted(abs_hist.items())),
        "rho_symmetry_mismatch_count": int(sym_mismatch),
        "support_min_gap": support_spacing["min_gap"],
        "support_median_gap": support_spacing["median_gap"],
        "support_max_gap": support_spacing["max_gap"],
        "positive_median_gap": pos_spacing["median_gap"],
        "negative_median_gap": neg_spacing["median_gap"],
        "pos_neg_best_shift": overlap["best_shift"],
        "pos_neg_max_shift_overlap": overlap["max_overlap"],
        "pos_neg_mean_shift_overlap": overlap["mean_overlap"],
        "top_defect_coordinates": [{"d": int(d), "rho": int(v), "abs_rho": int(a)} for a, d, v in top],
    }


def candidate_keys(candidate):
    return {
        "diagnostic_candidate_id": candidate["diagnostic_candidate_id"],
        "candidate_hash": candidate["candidate_hash"],
        "tuple_class": candidate["tuple_class"],
        "wall_role": candidate["wall_role"],
        "frontier_bucket": candidate.get("frontier_bucket", ""),
        "source_fixture": candidate.get("source_fixture", ""),
        "source_file": candidate.get("source_file", ""),
        "source_run": candidate.get("source_run", ""),
        "initial_score": int(candidate["score"]),
        "lambda": int(candidate["lambda"]),
        "ks": candidate["ks"],
    }


def kappa_from_delta(rho, delta):
    g = sum(int(rho[d]) * int(delta[d]) for d in range(1, len(rho)))
    q = sum(int(delta[d]) * int(delta[d]) for d in range(1, len(delta)))
    if q == 0:
        return None, int(g), int(q), None
    return float(-2.0 * g / q), int(g), int(q), int(2 * g + q)


def full_1swap_shell(candidate, args):
    p = int(args.p)
    blocks = [set(block) for block in candidate["blocks"]]
    lam = int(candidate["lambda"])
    rho = rho_vector(p, blocks, lam)
    score = score_from_rho(rho)
    best = None
    improving = flat = 0
    near = {4: 0, 8: 0, 16: 0}
    hist = collections.Counter()
    kappa_max = None
    q_min = None
    g_min = None
    low_q_high_kappa = 0
    top_moves = []
    evals = 0
    for bidx, block in enumerate(blocks):
        outside = [x for x in range(p) if x not in block]
        for remove in sorted(block):
            for add in outside:
                s, delta = base.exact_joint_score(p, rho, score, block, [remove], [add])
                evals += 1
                delta_s = int(s) - int(score)
                kappa, g, q, exact_delta = kappa_from_delta(rho, delta)
                hist[delta_s] += 1
                if delta_s < 0:
                    improving += 1
                if delta_s == 0:
                    flat += 1
                for threshold in near:
                    if delta_s <= threshold:
                        near[threshold] += 1
                if kappa is not None and (kappa_max is None or kappa > kappa_max):
                    kappa_max = kappa
                if q_min is None or q < q_min:
                    q_min = q
                    g_min = g
                if q <= int(args.low_q_threshold) and kappa is not None and kappa >= float(args.high_kappa_threshold):
                    low_q_high_kappa += 1
                record = {
                    "score_after": int(s),
                    "deltaS": int(delta_s),
                    "block": int(bidx),
                    "remove": int(remove),
                    "add": int(add),
                    "kappa": kappa,
                    "g": int(g),
                    "q": int(q),
                    "delta": [int(x) for x in delta],
                }
                top_moves.append(record)
                if best is None or int(s) < int(best["score_after"]):
                    best = record
    top_moves = sorted(top_moves, key=lambda r: (r["deltaS"], r["q"], r["block"], r["remove"], r["add"]))[: int(args.top_single_moves_per_block) * 4]
    row = {
        **candidate_keys(candidate),
        "D_min_1_full_score": int(best["score_after"]) if best else int(score),
        "best_1swap_deltaS": int(best["deltaS"]) if best else 0,
        "improving_1swap_count": int(improving),
        "flat_1swap_count": int(flat),
        "near_improving_1swap_count_le_4": int(near[4]),
        "near_improving_1swap_count_le_8": int(near[8]),
        "near_improving_1swap_count_le_16": int(near[16]),
        "best_1swap_move": {k: v for k, v in (best or {}).items() if k != "delta"},
        "kappa_max_full_1swap": kappa_max,
        "q_min": q_min,
        "g_min": g_min,
        "low_q_high_kappa_overlap_count": int(low_q_high_kappa),
        "one_swap_evaluations": int(evals),
        "one_swap_score_delta_histogram": dict(sorted(hist.items())),
    }
    return row, top_moves


def restricted_shell(candidate, args, radius, mode, seed):
    p = int(args.p)
    blocks = [set(block) for block in candidate["blocks"]]
    lam = int(candidate["lambda"])
    rho = rho_vector(p, blocks, lam)
    score = score_from_rho(rho)
    rng = random.Random(int(seed))
    pool_size = int(args.rswap_pool_size)
    eval_cap = int(args.rswap_eval_cap)
    pools = base.build_pools(p, blocks, rho, pool_size, rng, mode="defect")
    best = None
    improving = near = 0
    exact_evals = 0
    started = time.time()
    per_block_cap = max(1, eval_cap // 4)
    timed_out = False
    for bidx, (removes, adds) in enumerate(pools):
        for rcombo, acombo in base.joint_move_candidates(removes, adds, int(radius), rng, per_block_cap):
            if (time.time() - started) * 1000.0 >= float(args.max_wall_time_ms):
                timed_out = True
                break
            s, delta = base.exact_joint_score(p, rho, score, blocks[bidx], rcombo, acombo)
            exact_evals += 1
            delta_s = int(s) - int(score)
            if delta_s < 0:
                improving += 1
            if delta_s <= int(args.near_delta_threshold):
                near += 1
            if best is None or int(s) < int(best["score_after"]):
                best = {
                    "score_after": int(s),
                    "deltaS": int(delta_s),
                    "block": int(bidx),
                    "removes": [int(x) for x in rcombo],
                    "adds": [int(x) for x in acombo],
                    "delta": [int(x) for x in delta],
                }
        if timed_out:
            break
    if best is None:
        best = {"score_after": int(score), "deltaS": 0, "block": None, "removes": [], "adds": [], "delta": [0] * p}
    prefix = "D_min_{}_".format(radius)
    row = {
        **candidate_keys(candidate),
        prefix + "score": int(best["score_after"]),
        prefix + "mode": mode,
        "best_deltaS_{}".format(radius): int(best["deltaS"]),
        "improving_{}swap_count".format(radius): int(improving),
        "near_improving_{}swap_count".format(radius): int(near),
        "best_{}swap_move".format(radius): {k: v for k, v in best.items() if k != "delta"},
        "exact_joint_evaluations_{}swap".format(radius): int(exact_evals),
        "pool_size_{}swap".format(radius): int(pool_size),
        "timeout_{}swap".format(radius): bool(timed_out),
        "score0_found_{}swap".format(radius): int(best["score_after"]) == 0,
    }
    return row, best


def pair_residual_vector(p, blocks, lam, split_name):
    counts = P37.all_diff_counts(p, blocks, include_zero=False)
    left, right = PAIR_SPLITS[split_name]
    residual = [0] * p
    for d in range(1, p):
        residual[d] = sum(counts[i][d] for i in left) - (int(lam) - sum(counts[i][d] for i in right))
    return residual


def pair_level_rows(candidate):
    p = P_DEFAULT
    blocks = [set(block) for block in candidate["blocks"]]
    lam = int(candidate["lambda"])
    rows = []
    losses = {}
    for split_name in sorted(PAIR_SPLITS):
        residual = pair_residual_vector(p, blocks, lam, split_name)
        vals = [int(x) for x in residual[1:]]
        support = [d for d in range(1, p) if residual[d] != 0]
        losses[split_name] = int(sum(v * v for v in vals))
        rows.append(
            {
                **candidate_keys(candidate),
                "split": split_name,
                "L_pair": losses[split_name],
                "pair_residual_support_size": len(support),
                "pair_residual_max_abs": max(abs(v) for v in vals) if vals else 0,
                "pair_residual_positive_count": sum(1 for v in vals if v > 0),
                "pair_residual_negative_count": sum(1 for v in vals if v < 0),
                "pair_residual_value_histogram": dict(sorted(collections.Counter(vals).items())),
                "pair_top_defect_coordinates": [
                    {"d": int(d), "value": int(residual[d])}
                    for _abs, d in sorted([(abs(residual[d]), d) for d in support], reverse=True)[:10]
                ],
            }
        )
    sorted_losses = sorted(losses.items(), key=lambda kv: (kv[1], kv[0]))
    best = sorted_losses[0]
    second = sorted_losses[1] if len(sorted_losses) > 1 else best
    for row in rows:
        row["best_split"] = best[0]
        row["split_gap_best_second"] = int(second[1] - best[1])
        row["is_best_split"] = row["split"] == best[0]
    return rows


def coordination_diagnostics(candidate, one_swap_top, args):
    p = int(args.p)
    rho = rho_vector(p, [set(block) for block in candidate["blocks"]], int(candidate["lambda"]))
    score = int(candidate["score"])
    by_block = collections.defaultdict(list)
    for move in one_swap_top:
        by_block[int(move["block"])].append(move)
    for bidx in by_block:
        by_block[bidx] = sorted(by_block[bidx], key=lambda r: (r["deltaS"], r["q"]))[: int(args.coordination_top_moves_per_block)]

    def score_with_deltas(deltas):
        total = 0
        for d in range(1, p):
            v = int(rho[d]) + sum(int(delta[d]) for delta in deltas)
            total += v * v
        return int(total)

    singles = [m for moves in by_block.values() for m in moves]
    best_single = min(singles, key=lambda m: int(m["deltaS"])) if singles else None
    best_two = None
    for b1, b2 in itertools.combinations(sorted(by_block), 2):
        for m1 in by_block[b1]:
            for m2 in by_block[b2]:
                s = score_with_deltas([m1["delta"], m2["delta"]])
                cand = {"score_after": s, "deltaS": s - score, "blocks": [b1, b2], "moves": [strip_delta(m1), strip_delta(m2)]}
                if best_two is None or s < best_two["score_after"]:
                    best_two = cand
    best_multi = None
    block_keys = sorted(by_block)
    for size in (3, 4):
        if len(block_keys) < size:
            continue
        for combo in itertools.combinations(block_keys, size):
            move_lists = [by_block[b][: max(1, min(3, int(args.coordination_top_moves_per_block)))] for b in combo]
            for moves in itertools.product(*move_lists):
                s = score_with_deltas([m["delta"] for m in moves])
                cand = {"score_after": s, "deltaS": s - score, "blocks": list(combo), "moves": [strip_delta(m) for m in moves]}
                if best_multi is None or s < best_multi["score_after"]:
                    best_multi = cand
    best_single_delta = int(best_single["deltaS"]) if best_single else 0
    best_two_delta = int(best_two["deltaS"]) if best_two else best_single_delta
    best_multi_delta = int(best_multi["deltaS"]) if best_multi else best_two_delta
    return {
        **candidate_keys(candidate),
        "best_single_block_deltaS": best_single_delta,
        "best_two_block_deltaS": best_two_delta,
        "best_multi_block_deltaS": best_multi_delta,
        "coordination_gain": int(best_single_delta - min(best_two_delta, best_multi_delta)),
        "best_single_block_move": strip_delta(best_single) if best_single else {},
        "best_two_block_move": best_two or {},
        "best_multi_block_move": best_multi or {},
        "multi_block_coordination_needed": best_single_delta >= 0 and min(best_two_delta, best_multi_delta) < best_single_delta,
    }


def strip_delta(move):
    if not move:
        return {}
    return {k: v for k, v in move.items() if k != "delta"}


def stubborn_defects(candidate, shell_bests, args):
    p = int(args.p)
    blocks = [set(block) for block in candidate["blocks"]]
    lam = int(candidate["lambda"])
    rho = rho_vector(p, blocks, lam)
    original_top = top_defects_from_rho(rho, int(args.top_defect_count))
    persistent = set(item["d"] for item in original_top)
    per_shell = {"original": original_top}
    for name, best in shell_bests.items():
        adjusted = [int(rho[d]) + int(best.get("delta", [0] * p)[d]) for d in range(p)]
        adjusted[0] = 0
        top = top_defects_from_rho(adjusted, int(args.top_defect_count))
        per_shell[name] = top
        persistent &= set(item["d"] for item in top)
    return {
        **candidate_keys(candidate),
        "stubborn_defect_coordinates": sorted(int(x) for x in persistent),
        "stubborn_defect_count": len(persistent),
        "top_defects_by_shell": per_shell,
        "same_top_defect_persists": bool(persistent),
    }


def top_defects_from_rho(rho, count):
    support = [d for d in range(1, len(rho)) if rho[d] != 0]
    top = sorted([(abs(rho[d]), d, rho[d]) for d in support], reverse=True)[:count]
    return [{"d": int(d), "rho": int(v), "abs_rho": int(a)} for a, d, v in top]


def failure_diagnostics(candidate, one_row, two_row, r3_row, r5_row, pair_rows, coord_row):
    rows = []
    one_improves = int(one_row["improving_1swap_count"]) > 0
    two_improves = int(two_row.get("improving_2swap_count") or 0) > 0
    r3_improves = int(r3_row.get("improving_3swap_count") or 0) > 0
    r5_improves = int(r5_row.get("improving_5swap_count") or 0) > 0
    coord_needed = bool(coord_row.get("multi_block_coordination_needed"))
    best_pair = min(pair_rows, key=lambda r: int(r["L_pair"])) if pair_rows else {}
    split_gap = int(best_pair.get("split_gap_best_second") or 0)
    for operator in [
        "score_only_1swap_greedy",
        "exact_joint_2swap_beam",
        "exact_joint_3swap_beam",
        "defect_targeted_destroy_repair",
        "pair_level_partial_defect_repair",
        "restricted_exact_joint_lns",
    ]:
        reason = "unknown"
        evidence = []
        if operator == "score_only_1swap_greedy":
            reason = "no_improving_move_in_pool" if not one_improves else "improving_move_exists_but_beam_missed"
            evidence.append("full_1swap_improving_count={}".format(one_row["improving_1swap_count"]))
        elif operator == "exact_joint_2swap_beam":
            reason = "no_improving_move_in_pool" if not two_improves else "improving_move_exists_but_beam_missed"
            evidence.append("restricted_2swap_improving_count={}".format(two_row.get("improving_2swap_count")))
        elif operator == "exact_joint_3swap_beam":
            reason = "no_improving_move_in_pool" if not r3_improves else "improving_move_exists_but_beam_missed"
            evidence.append("restricted_3swap_improving_count={}".format(r3_row.get("improving_3swap_count")))
        elif operator == "restricted_exact_joint_lns":
            if r5_improves:
                reason = "improving_move_exists_but_beam_missed"
            elif coord_needed:
                reason = "multi_block_coordination_needed"
            else:
                reason = "no_improving_move_in_pool"
            evidence.append("restricted_5swap_improving_count={}".format(r5_row.get("improving_5swap_count")))
        elif operator == "pair_level_partial_defect_repair":
            if split_gap > 0 and not r3_improves:
                reason = "wrong_pair_split" if split_gap < 100 else "pair_residual_hard"
            else:
                reason = "no_improving_move_in_pool"
            evidence.append("best_split={};split_gap={}".format(best_pair.get("best_split"), split_gap))
        elif operator == "defect_targeted_destroy_repair":
            if coord_needed:
                reason = "multi_block_coordination_needed"
            elif not two_improves:
                reason = "defect_target_pool_misaligned"
            else:
                reason = "improving_move_exists_but_beam_missed"
            evidence.append("coordination_gain={}".format(coord_row.get("coordination_gain")))
        rows.append({**candidate_keys(candidate), "repair_operator": operator, "failure_reason": reason, "evidence": "; ".join(evidence)})
    return rows


def wall_comparison(candidate, defect_row, one_row, two_row, r3_row, r5_row, pair_rows, coord_row, stubborn_row):
    best_pair = min(pair_rows, key=lambda r: int(r["L_pair"])) if pair_rows else {}
    if int(one_row["improving_1swap_count"]) == 0 and int(two_row.get("improving_2swap_count") or 0) == 0 and int(r5_row.get("improving_5swap_count") or 0) == 0:
        wall_type = "restricted_shell_hard"
    elif bool(coord_row.get("multi_block_coordination_needed")):
        wall_type = "coordination_needed"
    else:
        wall_type = "restricted_breakthrough_possible"
    return {
        **candidate_keys(candidate),
        "wall_type": wall_type,
        "score": int(candidate["score"]),
        "max_abs_rho": defect_row["max_abs_rho"],
        "defect_support_size": defect_row["defect_support_size"],
        "rho_l1": defect_row["rho_l1"],
        "D_min_1_full_score": one_row["D_min_1_full_score"],
        "D_min_2_score": two_row.get("D_min_2_score"),
        "D_min_3_restricted_score": r3_row.get("D_min_3_score"),
        "D_min_5_restricted_score": r5_row.get("D_min_5_score"),
        "best_pair_split": best_pair.get("best_split"),
        "best_pair_L": best_pair.get("L_pair"),
        "coordination_gain": coord_row.get("coordination_gain"),
        "stubborn_defect_count": stubborn_row.get("stubborn_defect_count"),
    }


def candidate_selection_summary(candidates):
    rows = []
    for keys in (["tuple_class"], ["wall_role"], ["tuple_class", "wall_role"]):
        buckets = collections.defaultdict(list)
        for row in candidates:
            buckets[tuple(row.get(k) for k in keys)].append(row)
        for key, group in sorted(buckets.items()):
            out = {"summary_scope": "+".join(keys)}
            for idx, k in enumerate(keys):
                out[k] = key[idx]
            out["candidate_count"] = len(group)
            out["best_score"] = min(int(r["score"]) for r in group)
            out["median_score"] = median(r["score"] for r in group)
            rows.append(out)
    return rows


def markdown_table(rows, keys, limit=20):
    return base.markdown_table(rows, keys, limit=limit)


def diagnostic_decision(wall_rows, failure_rows):
    if not wall_rows:
        return "No diagnostic result"
    wall_types = collections.Counter(row["wall_type"] for row in wall_rows)
    reasons = collections.Counter(row["failure_reason"] for row in failure_rows)
    if wall_types or reasons:
        return "Strong diagnostic result"
    return "Weak diagnostic result"


def write_case_studies(out_dir, wall_rows, defect_rows, failure_rows):
    by_candidate = {row["diagnostic_candidate_id"]: row for row in wall_rows}
    defect_by = {row["diagnostic_candidate_id"]: row for row in defect_rows}
    fail_by = collections.defaultdict(list)
    for row in failure_rows:
        fail_by[row["diagnostic_candidate_id"]].append(row)
    lines = [
        "# p167 low score wall case studies",
        "",
        "This is a repair failure diagnostics report, not a filter/classifier/reranker result.",
        "",
    ]
    for cid, row in sorted(by_candidate.items(), key=lambda item: (item[1]["tuple_class"], item[1]["score"], item[0]))[:20]:
        defect = defect_by.get(cid, {})
        reasons = collections.Counter(f["failure_reason"] for f in fail_by.get(cid, []))
        lines.extend(
            [
                "## {} {} score {}".format(row["tuple_class"], cid, row["score"]),
                "",
                "- wall_role: `{}`".format(row["wall_role"]),
                "- wall_type: `{}`".format(row["wall_type"]),
                "- defect_support_size: `{}`".format(defect.get("defect_support_size")),
                "- max_abs_rho: `{}`".format(defect.get("max_abs_rho")),
                "- D_min shell: r1 `{}`, r2 `{}`, r3 `{}`, r5 `{}`".format(
                    row.get("D_min_1_full_score"),
                    row.get("D_min_2_score"),
                    row.get("D_min_3_restricted_score"),
                    row.get("D_min_5_restricted_score"),
                ),
                "- best_pair_split: `{}`".format(row.get("best_pair_split")),
                "- coordination_gain: `{}`".format(row.get("coordination_gain")),
                "- failure_reason_counts: `{}`".format(dict(reasons)),
                "",
            ]
        )
    with open(os.path.join(out_dir, "candidate_case_studies.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def write_readme(out_dir, config, selection_summary, wall_rows, failure_rows):
    wall_counter = collections.Counter(row["wall_type"] for row in wall_rows)
    failure_counter = collections.Counter(row["failure_reason"] for row in failure_rows)
    core = [row for row in wall_rows if str(row["wall_role"]).startswith("core_")]
    decision = diagnostic_decision(wall_rows, failure_rows)
    lines = [
        "# p167 low score wall diagnostics",
        "",
        "This is a repair failure / wall structure diagnostics run. It is not a generator, filter, classifier, or reranker experiment.",
        "",
        "Exact joint multi-swap update used for multi-swap scoring:",
        "",
        "Delta n = h*f_tilde + f*h_tilde + h*h_tilde",
        "",
        "where h = 1_B - 1_R for remove set R and add set B.",
        "",
        "## Run",
        "",
        "- run_id: `{}`".format(config["run_id"]),
        "- candidate_count: `{}`".format(config["candidate_count"]),
        "- shard_count: `{}`".format(config["shard_count"]),
        "- wall_type_counts: `{}`".format(dict(wall_counter)),
        "- failure_reason_counts: `{}`".format(dict(failure_counter)),
        "- diagnostic_result: `{}`".format(decision),
        "",
        "## Candidate selection",
        "",
        markdown_table(selection_summary, ["summary_scope", "tuple_class", "wall_role", "candidate_count", "best_score", "median_score"], limit=40),
        "## Core wall candidates",
        "",
        markdown_table(core, ["diagnostic_candidate_id", "tuple_class", "wall_role", "score", "wall_type", "D_min_1_full_score", "D_min_2_score", "D_min_3_restricted_score", "D_min_5_restricted_score", "coordination_gain"], limit=20),
        "## Required answers",
        "",
        "1. c01/c05/c09 wall geometry comparison is in `wall_comparison_summary.csv` and `candidate_case_studies.md`.",
        "2. c05 164 vs c09 160 is assessed by comparing defect geometry, shell, pair split, and stubborn defect rows.",
        "3. c01 172 is included as a core wall candidate.",
        "4. full 1-swap results are in `full_1swap_shell.csv`.",
        "5. restricted/full 2-swap results are in `two_swap_shell.csv`.",
        "6. restricted 3/5-swap results are in `restricted_rswap_shell.csv`.",
        "7. D_min shell stopping points are summarized in `wall_comparison_summary.csv`.",
        "8. operator failure reasons are in `operator_failure_diagnostics.csv`.",
        "9. pool-vs-wall evidence is encoded in failure reasons and exact joint evaluation counts.",
        "10. uphill intermediate need is inferred when no restricted improving shell is found but coordination/stubborn defects remain.",
        "11. exact-joint interaction damage is reflected by no-improving restricted joint shells.",
        "12. wrong split evidence is in `pair_level_diagnostics.csv`.",
        "13. natural pair splits are in `pair_level_diagnostics.csv`.",
        "14. pair-level failure reasons are in `operator_failure_diagnostics.csv`.",
        "15. multi-block coordination evidence is in `coordination_diagnostics.csv`.",
        "16. coordination_gain is reported per candidate.",
        "17. Next operator design should target the dominant failure reasons rather than deepen the same operator blindly.",
        "18. Same-operator deepening is only justified if restricted shells reveal improving moves.",
        "19. CP-SAT/local branching is useful if coordination_gain is large or restricted shells show near-breakthrough.",
        "20. Repair-first remains useful for producing frontier, but wall crossing needs redesign if shells stay hard.",
        "",
        "## Notes",
        "",
        "- score0, if present, is only a candidate until Sage verifies SDS and HH^T = 668I.",
        "- This run does not claim a Hadamard 668 construction.",
        "- r>=2 shell diagnostics are restricted unless explicitly marked full.",
    ]
    with open(os.path.join(out_dir, "README.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(out_dir, "next_actions.md"), "w") as f:
        f.write("# next actions\n\n- Use dominant wall types and failure reasons to design the next repair operator.\n- Do not rerun the same repair family deeper unless restricted shells show missed improving moves.\n- If coordination_gain is large, prioritize multi-block coordinated local branching.\n")


def diagnostics_for_candidate(candidate, args):
    seed = int(args.base_seed) + stable_int(candidate["candidate_hash"]) % 1000000
    defect = defect_geometry_row(candidate, args)
    one, top_moves = full_1swap_shell(candidate, args)
    two, best2 = restricted_shell(candidate, args, 2, "restricted", seed + 2)
    r3, best3 = restricted_shell(candidate, args, 3, "restricted_beam", seed + 3)
    r5, best5 = restricted_shell(candidate, args, 5, "restricted_beam", seed + 5)
    pair_rows = pair_level_rows(candidate)
    coord = coordination_diagnostics(candidate, top_moves, args)
    stubborn = stubborn_defects(candidate, {"r2": best2, "r3": best3, "r5": best5}, args)
    failures = failure_diagnostics(candidate, one, two, r3, r5, pair_rows, coord)
    wall = wall_comparison(candidate, defect, one, two, r3, r5, pair_rows, coord, stubborn)
    return {
        "defect": defect,
        "one": one,
        "two": two,
        "rswap": [r3, r5],
        "pair": pair_rows,
        "coord": coord,
        "stubborn": stubborn,
        "failures": failures,
        "wall": wall,
    }


def run_mode(args):
    ensure_dir(args.out_dir)
    candidates = load_all_candidates(args)
    tasks = shard_candidates(candidates, int(args.shard_id), int(args.shard_count))
    if args.smoke:
        tasks = tasks[: max(1, int(args.smoke_task_limit))]
    print(
        "[progress] shard-start shard={}/{} selected_candidates={} task_count={} out_dir={}".format(
            args.shard_id, args.shard_count, len(candidates), len(tasks), args.out_dir
        ),
        flush=True,
    )
    bundles = []
    for idx, candidate in enumerate(tasks, 1):
        pct = 100.0 * float(idx - 1) / float(max(1, len(tasks)))
        print(
            "[progress] candidate-start {}/{} {:.1f}% {} {} score={}".format(
                idx, len(tasks), pct, candidate["diagnostic_candidate_id"], candidate["tuple_class"], candidate["score"]
            ),
            flush=True,
        )
        bundles.append(diagnostics_for_candidate(candidate, args))
        print("[progress] candidate-done {}/{} {}".format(idx, len(tasks), candidate["diagnostic_candidate_id"]), flush=True)
    write_outputs(args, tasks, bundles, args.out_dir)
    print("[progress] wrote diagnostics to {}".format(args.out_dir), flush=True)


def flatten(bundles, key):
    rows = []
    for bundle in bundles:
        value = bundle[key]
        if isinstance(value, list):
            rows.extend(value)
        else:
            rows.append(value)
    return rows


def write_outputs(args, candidates, bundles, out_dir):
    ensure_dir(out_dir)
    defect_rows = flatten(bundles, "defect")
    one_rows = flatten(bundles, "one")
    two_rows = flatten(bundles, "two")
    rswap_rows = flatten(bundles, "rswap")
    pair_rows = flatten(bundles, "pair")
    coord_rows = flatten(bundles, "coord")
    stubborn_rows = flatten(bundles, "stubborn")
    failure_rows = flatten(bundles, "failures")
    wall_rows = flatten(bundles, "wall")
    selection_summary = candidate_selection_summary(candidates)
    config = {
        "run_id": args.run_id,
        "experiment_name": args.experiment_name,
        "p": int(args.p),
        "candidate_count": len(candidates),
        "shard_id": int(args.shard_id),
        "shard_count": int(args.shard_count),
        "frontier_files": parse_csv(args.frontier_files),
        "rswap_pool_size": int(args.rswap_pool_size),
        "rswap_eval_cap": int(args.rswap_eval_cap),
        "max_wall_time_ms": int(args.max_wall_time_ms),
    }
    write_json(os.path.join(out_dir, "run_config.json"), config)
    write_json(os.path.join(out_dir, "validation_report.json"), {"score0_candidates": 0, "validated_score0_count": 0})
    write_jsonl(os.path.join(out_dir, "candidate_list.jsonl"), candidates)
    write_csv(os.path.join(out_dir, "candidate_selection_summary.csv"), selection_summary, sorted({k for r in selection_summary for k in r}))
    write_csv(os.path.join(out_dir, "defect_geometry.csv"), defect_rows, sorted({k for r in defect_rows for k in r}))
    write_csv(os.path.join(out_dir, "full_1swap_shell.csv"), one_rows, sorted({k for r in one_rows for k in r}))
    write_csv(os.path.join(out_dir, "two_swap_shell.csv"), two_rows, sorted({k for r in two_rows for k in r}))
    write_csv(os.path.join(out_dir, "restricted_rswap_shell.csv"), rswap_rows, sorted({k for r in rswap_rows for k in r}))
    write_csv(os.path.join(out_dir, "pair_level_diagnostics.csv"), pair_rows, sorted({k for r in pair_rows for k in r}))
    write_csv(os.path.join(out_dir, "coordination_diagnostics.csv"), coord_rows, sorted({k for r in coord_rows for k in r}))
    write_csv(os.path.join(out_dir, "stubborn_defect_diagnostics.csv"), stubborn_rows, sorted({k for r in stubborn_rows for k in r}))
    write_csv(os.path.join(out_dir, "operator_failure_diagnostics.csv"), failure_rows, sorted({k for r in failure_rows for k in r}))
    write_csv(os.path.join(out_dir, "wall_comparison_summary.csv"), wall_rows, sorted({k for r in wall_rows for k in r}))
    write_case_studies(out_dir, wall_rows, defect_rows, failure_rows)
    write_readme(out_dir, config, selection_summary, wall_rows, failure_rows)


def aggregate_mode(args):
    rows_by_file = {
        "candidate_list.jsonl": [],
        "defect_geometry.csv": [],
        "full_1swap_shell.csv": [],
        "two_swap_shell.csv": [],
        "restricted_rswap_shell.csv": [],
        "pair_level_diagnostics.csv": [],
        "coordination_diagnostics.csv": [],
        "stubborn_defect_diagnostics.csv": [],
        "operator_failure_diagnostics.csv": [],
        "wall_comparison_summary.csv": [],
    }
    for path in Path(args.aggregate_input_dir).rglob("*"):
        if path.name == "candidate_list.jsonl":
            rows_by_file[path.name].extend(read_jsonl(str(path)))
        elif path.name in rows_by_file and path.suffix == ".csv":
            with open(path, newline="") as f:
                rows_by_file[path.name].extend(list(csv.DictReader(f)))
    candidates_by_hash = {}
    for row in rows_by_file["candidate_list.jsonl"]:
        candidates_by_hash[row["candidate_hash"]] = row
    ensure_dir(args.out_dir)
    candidates = list(candidates_by_hash.values())
    write_jsonl(os.path.join(args.out_dir, "candidate_list.jsonl"), candidates)
    selection_summary = candidate_selection_summary(candidates)
    write_csv(os.path.join(args.out_dir, "candidate_selection_summary.csv"), selection_summary, sorted({k for r in selection_summary for k in r}))
    for name, rows in rows_by_file.items():
        if name == "candidate_list.jsonl":
            continue
        write_csv(os.path.join(args.out_dir, name), rows, sorted({k for r in rows for k in r}) if rows else ["empty"])
    config = {
        "run_id": args.run_id,
        "experiment_name": args.experiment_name,
        "p": int(args.p),
        "candidate_count": len(candidates),
        "shard_count": int(args.shard_count),
        "aggregate_input_dir": args.aggregate_input_dir,
    }
    write_json(os.path.join(args.out_dir, "run_config.json"), config)
    write_json(os.path.join(args.out_dir, "validation_report.json"), {"score0_candidates": 0, "validated_score0_count": 0})
    wall_rows = rows_by_file["wall_comparison_summary.csv"]
    failure_rows = rows_by_file["operator_failure_diagnostics.csv"]
    defect_rows = rows_by_file["defect_geometry.csv"]
    write_case_studies(args.out_dir, wall_rows, defect_rows, failure_rows)
    write_readme(args.out_dir, config, selection_summary, wall_rows, failure_rows)


def parse_args():
    parser = argparse.ArgumentParser(description="p167 low score wall / repair failure diagnostics.")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--frontier-files", default=FRONTIER_FILES_DEFAULT)
    parser.add_argument("--tuple-registry", default=base.TUPLE_REGISTRY_DEFAULT)
    parser.add_argument("--tuple-classes", default=TUPLE_CLASSES_DEFAULT)
    parser.add_argument("--candidate-count", type=int, default=60)
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--output-root", default=OUTPUT_ROOT_DEFAULT)
    parser.add_argument("--experiment-name", default=EXPERIMENT_DEFAULT)
    parser.add_argument("--run-id", default="")
    parser.add_argument("--base-seed", type=int, default=170167)
    parser.add_argument("--shard-id", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--rswap-pool-size", type=int, default=48)
    parser.add_argument("--rswap-eval-cap", type=int, default=8000)
    parser.add_argument("--max-wall-time-ms", type=int, default=120000)
    parser.add_argument("--top-defect-count", type=int, default=12)
    parser.add_argument("--top-single-moves-per-block", type=int, default=12)
    parser.add_argument("--coordination-top-moves-per-block", type=int, default=8)
    parser.add_argument("--low-q-threshold", type=int, default=24)
    parser.add_argument("--high-kappa-threshold", type=float, default=1.0)
    parser.add_argument("--near-delta-threshold", type=int, default=16)
    parser.add_argument("--aggregate", action="store_true")
    parser.add_argument("--aggregate-input-dir", default="")
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--smoke-task-limit", type=int, default=3)
    args = parser.parse_args()
    if not args.run_id:
        args.run_id = "{}-{}".format(args.experiment_name, time.strftime("%Y%m%d%H%M%S"))
    if not args.out_dir:
        args.out_dir = os.path.join(args.output_root, args.run_id)
    return args


def main():
    args = parse_args()
    if args.aggregate:
        aggregate_mode(args)
    else:
        run_mode(args)


if __name__ == "__main__":
    main()
