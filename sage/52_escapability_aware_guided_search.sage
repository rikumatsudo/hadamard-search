from sage.all import *

import argparse
import csv
import hashlib
import json
import math
import os
import random
import statistics
import sys
import time

from sds_repair_utils import (
    apply_delta,
    canonical_hash,
    canonical_repr_summary,
    delta_swap,
    ensure_unique_path,
    error_histogram,
    json_blocks,
    metrics_from_counts,
    p_adic_moment_summary,
    setup_logging,
    total_diff_counts,
    validate_params,
    write_json,
)


SCRIPT_NAME = "52_escapability_aware_guided_search"
POWERS = (2, 4, 6, 8, 10, 12)


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)


def json_safe(value):
    if isinstance(value, dict):
        return {str(key): json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
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


def parse_int_list(text, default=()):
    if text is None or str(text).strip() == "":
        return list(default)
    return [int(part.strip()) for part in str(text).split(",") if part.strip()]


def parse_ks(text):
    values = tuple(int(part.strip()) for part in str(text).split(",") if part.strip())
    if len(values) != 4:
        raise argparse.ArgumentTypeError("--ks must contain exactly four integers")
    return values


def balanced_abs(residue, modulus):
    residue = int(residue) % int(modulus)
    return min(residue, int(modulus) - residue)


def moment_payload(counts, lam, p):
    summary = p_adic_moment_summary(counts, lam, powers=POWERS, modulus=p)
    moments = {"T{}".format(item["power"]): int(item["residue"]) for item in summary["moments"]}
    higher_norm = sum(balanced_abs(moments[key], p) ** 2 for key in ("T8", "T10", "T12"))
    low_norm = sum(balanced_abs(moments[key], p) ** 2 for key in ("T2", "T4", "T6"))
    return {
        "padic_moments": moments,
        "moment_zero_count_3": int(sum(1 for key in ("T2", "T4", "T6") if moments[key] == 0)),
        "moment_zero_count_6": int(summary["moment_zero_count"]),
        "moment_abs_sum_6": int(summary["moment_abs_sum"]),
        "low_moment_norm": int(low_norm),
        "higher_moment_norm": int(higher_norm),
        "moment_signature_6": summary["moment_signature"],
    }


def metric_record(counts, lam, p):
    score, l1_error, max_abs_error, nonzero_defect_count = metrics_from_counts(counts, lam)
    return {
        "score": int(score),
        "l1_error": int(l1_error),
        "max_abs_error": int(max_abs_error),
        "nonzero_defect_count": int(nonzero_defect_count),
        **moment_payload(counts, lam, p),
    }


def fast_block_hash(blocks, p, ks):
    payload = {
        "v": int(p),
        "ks": [int(k) for k in ks],
        "blocks": [[int(x) for x in sorted(block)] for block in blocks],
    }
    text = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def clone_blocks(blocks):
    return [set(block) for block in blocks]


def random_blocks(rng, p, ks):
    universe = list(range(int(p)))
    return [set(rng.sample(universe, int(k))) for k in ks]


def apply_swap_state(blocks, counts, p, block_idx, removed, added):
    block = blocks[int(block_idx)]
    if int(removed) not in block or int(added) in block:
        return False
    delta = delta_swap(p, block, int(removed), int(added))
    counts[:] = apply_delta(counts, delta)
    block.remove(int(removed))
    block.add(int(added))
    return True


def random_swap(rng, blocks, p):
    block_idx = rng.randrange(len(blocks))
    block = blocks[block_idx]
    removed = rng.choice(tuple(block))
    added = rng.randrange(int(p))
    while added in block:
        added = rng.randrange(int(p))
    return int(block_idx), int(removed), int(added)


def targeted_swap(rng, blocks, counts, lam, p):
    defects = [(abs(int(counts[d] - lam)), d) for d in range(1, int(p))]
    defects.sort(reverse=True)
    _abs_defect, d = rng.choice(defects[: min(20, len(defects))])
    # Choose a move likely to touch the active shift d.
    for _ in range(100):
        block_idx = rng.randrange(len(blocks))
        block = blocks[block_idx]
        if rng.random() < 0.5 and block:
            removed = rng.choice(tuple(block))
            added = (removed + d) % int(p)
            if added not in block:
                return int(block_idx), int(removed), int(added)
        added = rng.randrange(int(p))
        if added in block:
            continue
        removed = (added + d) % int(p)
        if removed in block:
            return int(block_idx), int(removed), int(added)
    return random_swap(rng, blocks, p)


def sample_best_swap(rng, blocks, counts, lam, p, samples, targeted_prob):
    current_metrics = metrics_from_counts(counts, lam)
    best = None
    for _ in range(int(samples)):
        if rng.random() < float(targeted_prob):
            block_idx, removed, added = targeted_swap(rng, blocks, counts, lam, p)
        else:
            block_idx, removed, added = random_swap(rng, blocks, p)
        delta = delta_swap(p, blocks[block_idx], removed, added)
        new_counts = apply_delta(counts, delta)
        metrics = metrics_from_counts(new_counts, lam)
        item = (tuple(int(x) for x in metrics), int(block_idx), int(removed), int(added), delta, new_counts)
        if best is None or item < best:
            best = item
    return current_metrics, best


def delta_swap_sparse(p, block, removed, added):
    p = int(p)
    removed = int(removed)
    added = int(added)
    out = {}
    for y in block:
        y = int(y)
        if y == removed:
            continue
        for d, coeff in (
            ((removed - y) % p, -1),
            ((y - removed) % p, -1),
            ((added - y) % p, 1),
            ((y - added) % p, 1),
        ):
            if d == 0:
                continue
            value = out.get(d, 0) + coeff
            if value:
                out[d] = value
            elif d in out:
                del out[d]
    return out


def q_formula_total(blocks, p):
    # For this script Q_ratio is diagnostic; direct sparse q sum is used below for exactness.
    total = 0
    for block in blocks:
        for removed in block:
            outside_count = int(p) - len(block)
            # Placeholder-free: direct loop below is the source of truth; keep this zero unused.
            total += 0 * outside_count * int(removed)
    return total


def escapability_diagnostic(blocks, counts, lam, p):
    score, l1_error, max_abs_error, nonzero_defect_count = metrics_from_counts(counts, lam)
    score = int(score)
    rho = [0] * int(p)
    for d in range(1, int(p)):
        rho[d] = int(counts[d] - lam)
    num_swaps = 0
    sum_q = 0
    h_min = None
    min_move = None
    improving = 0
    near_counts = {0: 0, 4: 0, 8: 0, 16: 0, 32: 0}
    for block_idx, block in enumerate(blocks):
        outside = [x for x in range(int(p)) if x not in block]
        for removed in block:
            for added in outside:
                delta = delta_swap_sparse(p, block, int(removed), int(added))
                g = int(sum(int(rho[d]) * int(value) for d, value in delta.items()))
                q = int(sum(int(value) * int(value) for value in delta.values()))
                h = int(2 * g + q)
                num_swaps += 1
                sum_q += q
                if h < 0:
                    improving += 1
                for threshold in near_counts:
                    if h <= threshold:
                        near_counts[threshold] += 1
                if h_min is None or h < h_min:
                    h_min = h
                    min_move = {
                        "block": int(block_idx),
                        "remove": int(removed),
                        "add": int(added),
                        "g": int(g),
                        "q": int(q),
                        "h": int(h),
                    }
    d_min_1 = None if h_min is None else int(score + h_min)
    threshold = int(4 * (int(p) - 1) * score)
    return {
        "h_min": int(h_min) if h_min is not None else None,
        "D_min_1": d_min_1,
        "D_min_ratio": (float(d_min_1) / float(score)) if score > 0 and d_min_1 is not None else None,
        "improving_swap_count": int(improving),
        "near_improving_count_h_le_0": int(near_counts[0]),
        "near_improving_count_h_le_4": int(near_counts[4]),
        "near_improving_count_h_le_8": int(near_counts[8]),
        "near_improving_count_h_le_16": int(near_counts[16]),
        "near_improving_count_h_le_32": int(near_counts[32]),
        "Q_tot": int(sum_q),
        "Q_ratio": (float(sum_q) / float(threshold)) if threshold > 0 else None,
        "num_swaps": int(num_swaps),
        "min_h_move": min_move,
    }


def is_hard_basin(esc):
    if not esc:
        return False
    return bool(
        esc.get("h_min") is not None
        and int(esc.get("h_min")) > 0
        and int(esc.get("improving_swap_count", 0)) == 0
        and esc.get("D_min_ratio") is not None
        and float(esc.get("D_min_ratio")) > 1.0
    )


def should_diagnose(record, step, diagnosed_count, args):
    if int(diagnosed_count) >= int(args.max_diagnostics_per_run):
        return False
    if int(args.diagnostic_interval) > 0 and step > 0 and step % int(args.diagnostic_interval) == 0:
        return True
    score = int(record["score"])
    for threshold in parse_int_list(args.diagnostic_score_thresholds, (800, 600, 500, 400, 300, 240, 200)):
        if score <= int(threshold):
            return True
    return False


def frontier_insert(frontiers, name, row, key_func, limit):
    bucket = frontiers.setdefault(name, [])
    key = row.get("fast_hash") or row.get("canonical_hash")
    if key and any((item.get("fast_hash") or item.get("canonical_hash")) == key for item in bucket):
        return False
    bucket.append(row)
    bucket.sort(key=key_func)
    del bucket[int(limit):]
    return row in bucket


def balanced_rank(row):
    esc = row.get("escapability") or {}
    score = int(row["score"])
    h_penalty = max(0, int(esc.get("h_min", 999999) or 999999))
    ratio = esc.get("D_min_ratio")
    ratio_penalty = 0 if ratio is None else max(0.0, float(ratio) - 1.0) * score
    q_ratio = esc.get("Q_ratio") or 0.0
    near = int(esc.get("near_improving_count_h_le_8", 0) or 0)
    return float(score) + 2.0 * h_penalty + ratio_penalty + 0.05 * float(q_ratio) - 4.0 * math.log(1 + near)


def update_frontiers(frontiers, row, limit):
    esc = row.get("escapability") or {}
    frontier_insert(frontiers, "best_by_score", row, lambda x: (x["score"], x["l1_error"], x["max_abs_error"], x["nonzero_defect_count"]), limit)
    if esc.get("h_min") is not None and int(esc["h_min"]) < 0:
        frontier_insert(frontiers, "best_by_score_with_hmin_negative", row, lambda x: (x["score"], x["escapability"]["h_min"]), limit)
    if esc.get("D_min_ratio") is not None:
        frontier_insert(frontiers, "best_by_low_D_min_ratio", row, lambda x: (x["escapability"]["D_min_ratio"], x["score"]), limit)
    frontier_insert(frontiers, "best_by_improving_swap_count", row, lambda x: (-int((x.get("escapability") or {}).get("improving_swap_count", 0)), x["score"]), limit)
    frontier_insert(frontiers, "best_by_near_improving", row, lambda x: (-int((x.get("escapability") or {}).get("near_improving_count_h_le_8", 0)), x["score"]), limit)
    if esc.get("Q_ratio") is not None:
        frontier_insert(frontiers, "best_by_low_Q_ratio", row, lambda x: (x["escapability"]["Q_ratio"], x["score"]), limit)
    if not is_hard_basin(esc):
        frontier_insert(frontiers, "best_by_not_local_minimum", row, lambda x: (x["score"], (x.get("escapability") or {}).get("h_min", 999999)), limit)
    frontier_insert(frontiers, "best_by_balanced_score_escapability", row, lambda x: (balanced_rank(x), x["score"]), limit)


def make_row(mode, seed, step, blocks, counts, ks, lam, p, parent_hash, reason, diagnose, args):
    record = metric_record(counts, lam, p)
    fast_hash = fast_block_hash(blocks, p, ks)
    esc = escapability_diagnostic(blocks, counts, lam, p) if diagnose else None
    hard = is_hard_basin(esc)
    return {
        "mode": mode,
        "seed": int(seed),
        "step": int(step),
        "v": int(p),
        "n": int(4 * int(p)),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "score": int(record["score"]),
        "l1_error": int(record["l1_error"]),
        "max_abs_error": int(record["max_abs_error"]),
        "nonzero_defect_count": int(record["nonzero_defect_count"]),
        "padic_moments": record["padic_moments"],
        "moment_zero_count_3": int(record["moment_zero_count_3"]),
        "moment_zero_count_6": int(record["moment_zero_count_6"]),
        "higher_moment_norm": int(record["higher_moment_norm"]),
        "fast_hash": fast_hash,
        "parent_hash": parent_hash,
        "frontier_reason": reason,
        "escapability": esc,
        "is_hard_basin": bool(hard),
        "_blocks": clone_blocks(blocks),
        "_counts": list(counts),
    }


def candidate_payload(row):
    blocks = row["_blocks"]
    p = int(row["v"])
    ks = tuple(int(k) for k in row["ks"])
    lam = int(row["lambda"])
    can_hash = canonical_hash(blocks, ks, p)
    payload = {
        "v": p,
        "n": int(row["n"]),
        "ks": [int(k) for k in ks],
        "lambda": lam,
        "blocks": json_blocks(blocks),
        "search_method": SCRIPT_NAME,
        "mode": row["mode"],
        "score": int(row["score"]),
        "l1_error": int(row["l1_error"]),
        "max_abs_error": int(row["max_abs_error"]),
        "nonzero_defect_count": int(row["nonzero_defect_count"]),
        "verify_sds": bool(int(row["score"]) == 0),
        "generated_hadamard": False,
        "hh_t": False,
        "construction": "Goethals-Seidel",
        "escapability": row.get("escapability"),
        "padic_moments": row["padic_moments"],
        "moment_zero_count_3": int(row["moment_zero_count_3"]),
        "moment_zero_count_6": int(row["moment_zero_count_6"]),
        "higher_moment_norm": int(row["higher_moment_norm"]),
        "frontier_reason": row.get("frontier_reason", ""),
        "is_hard_basin": bool(row.get("is_hard_basin", False)),
        "parent_hash": row.get("parent_hash", ""),
        "canonical_hash": can_hash,
        "canonical_repr_summary": canonical_repr_summary(blocks, ks, p),
        "error_histogram": error_histogram(row["_counts"], lam),
        "notes": [
            "Escapability-aware guided-search diagnostic candidate.",
            "Near-hit/frontier rows are not success candidates unless score=0 and exact SDS/GS verification passes.",
        ],
    }
    return payload


def save_candidate(row, out_dir):
    payload = candidate_payload(row)
    name = "near_hit_v{}_score{}_{}_{}_seed{}_step{}.json".format(
        row["v"],
        row["score"],
        SCRIPT_NAME,
        row["mode"],
        row["seed"],
        row["step"],
    )
    path = ensure_unique_path(os.path.join("outputs", "candidates", "near_hits", name))
    write_json(path, payload)
    return path


def choose_resume(rng, mode, frontiers, ks, p):
    if mode == "score_only":
        rows = frontiers.get("best_by_score", [])
    else:
        pools = [
            "best_by_score_with_hmin_negative",
            "best_by_low_D_min_ratio",
            "best_by_improving_swap_count",
            "best_by_near_improving",
            "best_by_not_local_minimum",
            "best_by_balanced_score_escapability",
            "best_by_score",
        ]
        rows = []
        for name in pools:
            rows.extend(frontiers.get(name, [])[:3])
        rows = [row for row in rows if not row.get("is_hard_basin")]
        if not rows:
            rows = frontiers.get("best_by_score", [])
    if not rows:
        return None
    row = rng.choice(rows[: min(10, len(rows))])
    return clone_blocks(row["_blocks"]), list(row["_counts"]), row.get("fast_hash")


def run_mode(mode, seed_values, args, out_dir):
    p = int(args.v)
    ks = tuple(int(k) for k in args.ks)
    lam = int(args.lam)
    validate_params(p, ks, lam)
    frontiers = {}
    diagnostics = []
    hard_archive = []
    saved_paths = []
    summary_runs = []
    diagnostic_count = 0
    rng_global = random.Random(int(int(args.seed_base) + (0 if mode == "score_only" else 100000)))
    for seed in seed_values:
        rng = random.Random(int(seed))
        resume = choose_resume(rng_global, mode, frontiers, ks, p) if mode == "escapability_aware" else None
        if resume:
            blocks, counts, parent_hash = resume
        else:
            blocks = random_blocks(rng, p, ks)
            counts = total_diff_counts(p, blocks)
            parent_hash = ""
        best_score = int(metric_record(counts, lam, p)["score"])
        patience = 0
        run_best = None
        for step in range(int(args.steps_per_seed) + 1):
            record = metric_record(counts, lam, p)
            if run_best is None or int(record["score"]) < int(run_best["score"]):
                diagnose = should_diagnose(record, step, diagnostic_count, args)
                if diagnose:
                    diagnostic_count += 1
                row = make_row(mode, seed, step, blocks, counts, ks, lam, p, parent_hash, "run_best", diagnose, args)
                run_best = row
                update_frontiers(frontiers, row, int(args.frontier_limit))
                if row.get("escapability"):
                    diagnostics.append(row)
                    if row["is_hard_basin"]:
                        hard_archive.append(row)
                if int(row["score"]) <= int(args.save_score_threshold) or row.get("escapability"):
                    saved_paths.append(save_candidate(row, out_dir))
            if step >= int(args.steps_per_seed):
                break

            current_metrics, best = sample_best_swap(
                rng,
                blocks,
                counts,
                lam,
                p,
                int(args.candidate_samples),
                float(args.targeted_prob),
            )
            best_metrics, block_idx, removed, added, _delta, new_counts = best
            accept = False
            if tuple(best_metrics) < tuple(current_metrics):
                accept = True
                patience = 0
            else:
                patience += 1
                temp = max(0.01, float(args.escape_temperature))
                delta_score = int(best_metrics[0]) - int(current_metrics[0])
                if mode == "escapability_aware" and delta_score <= int(args.allowed_worsen) and rng.random() < math.exp(-float(max(0, delta_score)) / temp):
                    accept = True
                elif rng.random() < float(args.random_walk_prob):
                    accept = True
            if accept:
                counts[:] = list(new_counts)
                blocks[int(block_idx)].remove(int(removed))
                blocks[int(block_idx)].add(int(added))
                best_score = min(best_score, int(best_metrics[0]))
            if patience >= int(args.restart_patience):
                resume = choose_resume(rng_global, mode, frontiers, ks, p)
                if resume:
                    blocks, counts, parent_hash = resume
                else:
                    blocks = random_blocks(rng, p, ks)
                    counts = total_diff_counts(p, blocks)
                    parent_hash = ""
                patience = 0
        # Always diagnose the final run-best row.  A low score can be reached
        # between interval/threshold diagnostic events; leaving that row with
        # escapability=None hides exactly the hard-basin cases this script is
        # meant to detect.
        if run_best is not None and not run_best.get("escapability"):
            run_best["escapability"] = escapability_diagnostic(run_best["_blocks"], run_best["_counts"], lam, p)
            run_best["is_hard_basin"] = bool(is_hard_basin(run_best["escapability"]))
            run_best["frontier_reason"] = "{};final_diagnostic".format(run_best.get("frontier_reason", "run_best"))
            diagnostic_count += 1
            diagnostics.append(run_best)
            if run_best["is_hard_basin"]:
                hard_archive.append(run_best)
            update_frontiers(frontiers, run_best, int(args.frontier_limit))
            saved_paths.append(save_candidate(run_best, out_dir))
        summary_runs.append({
            "mode": mode,
            "seed": int(seed),
            "best_score": int(run_best["score"]) if run_best else None,
            "best_l1_error": int(run_best["l1_error"]) if run_best else None,
            "best_max_abs_error": int(run_best["max_abs_error"]) if run_best else None,
            "best_nonzero_defect_count": int(run_best["nonzero_defect_count"]) if run_best else None,
            "best_hash": run_best.get("fast_hash") if run_best else "",
        })
        print("mode={} seed={} best_score={}".format(mode, seed, summary_runs[-1]["best_score"]))
        sys.stdout.flush()
    return {
        "mode": mode,
        "frontiers": frontiers,
        "diagnostics": diagnostics,
        "hard_archive": hard_archive,
        "saved_paths": saved_paths,
        "runs": summary_runs,
    }


def public_row(row):
    out = {key: value for key, value in row.items() if not key.startswith("_")}
    return json_safe(out)


def summarize_mode(result):
    diagnostics = result["diagnostics"]
    frontiers = result["frontiers"]
    hard = result["hard_archive"]
    all_rows = []
    for rows in frontiers.values():
        all_rows.extend(rows)
    best_score = min([row["score"] for row in all_rows], default=None)
    best_l1 = min([row["l1_error"] for row in all_rows], default=None)
    best_max = min([row["max_abs_error"] for row in all_rows], default=None)
    best_nonzero = min([row["nonzero_defect_count"] for row in all_rows], default=None)
    esc_rows = [row for row in diagnostics if row.get("escapability")]
    hneg = [row for row in esc_rows if row["escapability"]["h_min"] is not None and int(row["escapability"]["h_min"]) < 0]
    dlt1 = [row for row in esc_rows if row["escapability"].get("D_min_ratio") is not None and float(row["escapability"]["D_min_ratio"]) < 1.0]
    not_local = [row for row in esc_rows if not row.get("is_hard_basin")]
    score164_like = [
        row for row in esc_rows
        if int(row["score"]) <= 180 and row.get("is_hard_basin")
    ]
    score176_like = [
        row for row in esc_rows
        if 170 <= int(row["score"]) <= 190 and row.get("is_hard_basin")
    ]
    return {
        "mode": result["mode"],
        "best_score": int(best_score) if best_score is not None else None,
        "best_l1_error": int(best_l1) if best_l1 is not None else None,
        "best_max_abs_error": int(best_max) if best_max is not None else None,
        "best_nonzero_defect_count": int(best_nonzero) if best_nonzero is not None else None,
        "best_score_with_hmin_negative": min([row["score"] for row in hneg], default=None),
        "best_score_with_D_min_ratio_below_1": min([row["score"] for row in dlt1], default=None),
        "best_score_not_local_minimum": min([row["score"] for row in not_local], default=None),
        "lowest_h_min": min([row["escapability"]["h_min"] for row in esc_rows if row["escapability"].get("h_min") is not None], default=None),
        "lowest_D_min_ratio": min([row["escapability"]["D_min_ratio"] for row in esc_rows if row["escapability"].get("D_min_ratio") is not None], default=None),
        "highest_improving_swap_count": max([row["escapability"]["improving_swap_count"] for row in esc_rows], default=0),
        "highest_near_improving_count_h_le_8": max([row["escapability"]["near_improving_count_h_le_8"] for row in esc_rows], default=0),
        "hard_basin_count": int(len(hard)),
        "hard_basin_best_score": min([row["score"] for row in hard], default=None),
        "hard_basin_archive_count": int(len(hard)),
        "score164_like_count": int(len(score164_like)),
        "score176_like_count": int(len(score176_like)),
        "diagnostic_count": int(len(diagnostics)),
        "saved_candidate_count": int(len(result["saved_paths"])),
    }


def write_jsonl(path, rows):
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(public_row(row), sort_keys=True) + "\n")


def write_frontiers(out_dir, combined):
    names = [
        "best_by_score",
        "best_by_score_with_hmin_negative",
        "best_by_low_D_min_ratio",
        "best_by_improving_swap_count",
        "best_by_near_improving",
        "best_by_low_Q_ratio",
        "best_by_not_local_minimum",
        "best_by_balanced_score_escapability",
    ]
    for name in names:
        rows = []
        for result in combined:
            rows.extend(result["frontiers"].get(name, []))
        if name == "best_by_balanced_score_escapability":
            rows.sort(key=lambda row: (balanced_rank(row), row["score"]))
        else:
            rows.sort(key=lambda row: (row["score"], row["l1_error"], row["max_abs_error"], row["nonzero_defect_count"]))
        write_jsonl(os.path.join(out_dir, "frontier_{}.jsonl".format(name)), rows[:50])
    hard = []
    diagnostics = []
    for result in combined:
        hard.extend(result["hard_archive"])
        diagnostics.extend(result["diagnostics"])
    write_jsonl(os.path.join(out_dir, "hard_basin_archive.jsonl"), hard)
    write_jsonl(os.path.join(out_dir, "diagnostic_candidates.jsonl"), diagnostics)


def write_summary(out_dir, score_summary, escape_summary, comparison):
    lines = []
    lines.append("# Escapability-aware Guided Search Summary")
    lines.append("")
    lines.append("This is an exploration-design diagnostic for Hadamard 668 SDS search. It is not a construction claim.")
    lines.append("")
    lines.append("## Score-only Summary")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(json_safe(score_summary), indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("## Escapability-aware Summary")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(json_safe(escape_summary), indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("## Comparison")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(json_safe(comparison), indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    lines.append("1. Score-only best score: `{}`; escapability-aware best score: `{}`.".format(score_summary.get("best_score"), escape_summary.get("best_score")))
    lines.append("2. Hard-basin counts: score-only `{}`, escapability-aware `{}`.".format(score_summary.get("hard_basin_count"), escape_summary.get("hard_basin_count")))
    lines.append("3. score<=200 and h_min<0 best: score-only `{}`, escapability-aware `{}`.".format(score_summary.get("best_score_with_hmin_negative"), escape_summary.get("best_score_with_hmin_negative")))
    lines.append("4. score<=240 and D_min_ratio<1 best: score-only `{}`, escapability-aware `{}`.".format(score_summary.get("best_score_with_D_min_ratio_below_1"), escape_summary.get("best_score_with_D_min_ratio_below_1")))
    lines.append("5. Highest near-improving h<=8 count: score-only `{}`, escapability-aware `{}`.".format(score_summary.get("highest_near_improving_count_h_le_8"), escape_summary.get("highest_near_improving_count_h_le_8")))
    lines.append("6. score164/176-like hard basin counts are reported as `score164_like_count`.")
    lines.append("7. Distinct frontier files preserve score-only and escapability-aware candidates for later inspection.")
    lines.append("8. Next candidate selection should favor low score with `D_min_ratio < 1` or high near-improving counts over score-only hard minima.")
    lines.append("9. This run supports expanding escapability-aware search only if it finds low-score escapable candidates not present in score-only.")
    lines.append("")
    lines.append("## Safety")
    lines.append("")
    lines.append("- score=0 is required before SDS/GS validation can produce a success candidate.")
    lines.append("- Near-hits and frontier entries are research logs, not solutions.")
    with open(os.path.join(out_dir, "escapability_search_summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Compare score-only and escapability-aware guided SDS search.")
    parser.add_argument("--v", type=int, default=167)
    parser.add_argument("--ks", type=parse_ks, default=(73, 78, 79, 81))
    parser.add_argument("--lam", type=int, default=144)
    parser.add_argument("--modes", default="score_only,escapability_aware")
    parser.add_argument("--seed-start", type=int, default=1)
    parser.add_argument("--seed-end", type=int, default=10)
    parser.add_argument("--steps-per-seed", type=int, default=5000)
    parser.add_argument("--candidate-samples", type=int, default=32)
    parser.add_argument("--targeted-prob", type=float, default=0.3)
    parser.add_argument("--restart-patience", type=int, default=1000)
    parser.add_argument("--diagnostic-score-thresholds", default="800,600,500,400,300,240,200")
    parser.add_argument("--diagnostic-interval", type=int, default=1000)
    parser.add_argument("--max-diagnostics-per-run", type=int, default=80)
    parser.add_argument("--frontier-limit", type=int, default=50)
    parser.add_argument("--save-score-threshold", type=int, default=300)
    parser.add_argument("--escape-temperature", type=float, default=12.0)
    parser.add_argument("--allowed-worsen", type=int, default=24)
    parser.add_argument("--random-walk-prob", type=float, default=0.001)
    parser.add_argument("--seed-base", type=int, default=52)
    parser.add_argument("--out-dir", default="")
    return parser.parse_args()


def main():
    args = parse_args()
    out_dir = args.out_dir or os.path.join(
        "outputs",
        "explorations",
        "{}_hadamard668_escapability_aware_guided_search".format(now_stamp()),
    )
    ensure_dir(out_dir)
    tee, _stamp = setup_logging(SCRIPT_NAME)
    try:
        modes = [part.strip() for part in str(args.modes).split(",") if part.strip()]
        seeds = list(range(int(args.seed_start), int(args.seed_end) + 1))
        run_config = {
            "script": SCRIPT_NAME,
            "out_dir": out_dir,
            "v": int(args.v),
            "ks": [int(k) for k in args.ks],
            "lambda": int(args.lam),
            "modes": modes,
            "seed_start": int(args.seed_start),
            "seed_end": int(args.seed_end),
            "steps_per_seed": int(args.steps_per_seed),
            "candidate_samples": int(args.candidate_samples),
            "targeted_prob": float(args.targeted_prob),
            "diagnostic_score_thresholds": args.diagnostic_score_thresholds,
            "diagnostic_interval": int(args.diagnostic_interval),
            "max_diagnostics_per_run": int(args.max_diagnostics_per_run),
        }
        write_json(os.path.join(out_dir, "run_config.json"), run_config)
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# Run Log\n\n")
            f.write("- timestamp: `{}`\n".format(time.strftime("%Y-%m-%dT%H:%M:%S")))
            f.write("- script: `{}`\n".format(SCRIPT_NAME))
            f.write("- output dir: `{}`\n".format(out_dir))
            f.write("- modes: `{}`\n".format(modes))
        print("Output dir:", out_dir)
        results = []
        for mode in modes:
            print("Running mode:", mode)
            result = run_mode(mode, seeds, args, out_dir)
            results.append(result)
        write_frontiers(out_dir, results)
        summaries = {result["mode"]: summarize_mode(result) for result in results}
        score_summary = summaries.get("score_only", {})
        escape_summary = summaries.get("escapability_aware", {})
        comparison = {
            "score_only": score_summary,
            "escapability_aware": escape_summary,
            "best_score_delta_aware_minus_score_only": (
                None
                if not score_summary or not escape_summary
                else int(escape_summary.get("best_score") or 10**9) - int(score_summary.get("best_score") or 10**9)
            ),
        }
        write_json(os.path.join(out_dir, "score_only_summary.json"), json_safe(score_summary))
        write_json(os.path.join(out_dir, "escapability_aware_summary.json"), json_safe(escape_summary))
        write_json(os.path.join(out_dir, "comparison_summary.json"), json_safe(comparison))
        write_summary(out_dir, score_summary, escape_summary, comparison)
        print("SUMMARY:", os.path.join(out_dir, "escapability_search_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
