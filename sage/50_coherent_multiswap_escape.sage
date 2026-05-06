from sage.all import *

import argparse
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
    canonical_hash,
    canonical_repr_summary,
    delta_swap,
    ensure_unique_path,
    error_histogram,
    json_blocks,
    load_candidate,
    metrics_from_counts,
    p_adic_moment_summary,
    setup_logging,
    total_diff_counts,
    write_json,
)


SCRIPT_NAME = "50_coherent_multiswap_escape"
POWERS = (2, 4, 6, 8, 10, 12)
THRESHOLDS = (160, 120, 80, 48, 0)


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
        int_value = int(value)
        if value == int_value:
            return int_value
    except Exception:
        pass
    try:
        return float(value)
    except Exception:
        return str(value)


def parse_int_list(text, default):
    if text is None or str(text).strip() == "":
        return list(default)
    return [int(part.strip()) for part in str(text).split(",") if part.strip()]


def balanced_abs(residue, modulus):
    residue = int(residue) % int(modulus)
    return min(residue, int(modulus) - residue)


def moment_payload(counts, lam, v):
    high = p_adic_moment_summary(counts, lam, powers=POWERS, modulus=v)
    by_power = {"T{}".format(item["power"]): int(item["residue"]) for item in high["moments"]}
    higher_norm = sum(balanced_abs(by_power[key], v) ** 2 for key in ("T8", "T10", "T12"))
    return {
        "padic_moments": by_power,
        "moment_zero_count_3": int(sum(1 for key in ("T2", "T4", "T6") if by_power[key] == 0)),
        "moment_zero_count_6": int(high["moment_zero_count"]),
        "moment_signature_6": high["moment_signature"],
        "moment_abs_sum_6": int(high["moment_abs_sum"]),
        "higher_moment_norm": int(higher_norm),
    }


def evaluate_counts(counts, lam, v):
    metrics = metrics_from_counts(counts, lam)
    return {
        "score": int(metrics[0]),
        "l1_error": int(metrics[1]),
        "max_abs_error": int(metrics[2]),
        "nonzero_defect_count": int(metrics[3]),
        **moment_payload(counts, lam, v),
    }


def compact_metrics(record):
    out = {
        "score": int(record["score"]),
        "l1_error": int(record["l1_error"]),
        "max_abs_error": int(record["max_abs_error"]),
        "nonzero_defect_count": int(record["nonzero_defect_count"]),
        "moment_zero_count_3": int(record.get("moment_zero_count_3", 0)),
        "moment_zero_count_6": int(record.get("moment_zero_count_6", 0)),
        "higher_moment_norm": int(record.get("higher_moment_norm", 0)),
    }
    moments = record.get("padic_moments", {})
    for key in ("T2", "T4", "T6", "T8", "T10", "T12"):
        if key in moments:
            out[key] = int(moments[key])
    return out


def find_candidate_by_score(score, preferred_names):
    candidates = []
    for name in preferred_names:
        path = os.path.join("outputs", "candidates", "near_hits", name)
        if os.path.exists(path):
            candidates.append(path)
    pattern = os.path.join("outputs", "candidates", "near_hits", "**", "*score{}*.json".format(score))
    candidates.extend(sorted(glob.glob(pattern, recursive=True)))
    seen = set()
    for path in candidates:
        if path in seen:
            continue
        seen.add(path)
        try:
            data, v, _n, _ks, lam, blocks = load_candidate(path)
            if int(v) != 167:
                continue
            counts = total_diff_counts(v, blocks)
            metrics = metrics_from_counts(counts, lam)
            if int(metrics[0]) == int(score) and int(data.get("score", -1)) == int(score):
                return path
        except Exception:
            continue
    raise RuntimeError("could not find valid score={} candidate".format(score))


def clone_blocks(blocks):
    return [set(block) for block in blocks]


def move_key(move):
    return (int(move["block"]), int(move["remove"]), int(move["add"]))


def moves_key(moves):
    return tuple(sorted(move_key(move) for move in moves))


def conflict_free_static(moves):
    by_block = {}
    for move in moves:
        block = int(move["block"])
        removed = int(move["remove"])
        added = int(move["add"])
        state = by_block.setdefault(block, {"removed": set(), "added": set()})
        if removed in state["removed"] or added in state["added"]:
            return False
        if removed in state["added"] or added in state["removed"]:
            return False
        state["removed"].add(removed)
        state["added"].add(added)
    return True


def apply_moves_true(parent, moves):
    v = parent["v"]
    lam = parent["lambda"]
    blocks = clone_blocks(parent["blocks"])
    counts = list(parent["counts"])
    applied = []
    for move in moves:
        block = int(move["block"])
        removed = int(move["remove"])
        added = int(move["add"])
        if removed not in blocks[block] or added in blocks[block]:
            return None
        delta = delta_swap(v, blocks[block], removed, added)
        counts = apply_delta(counts, delta)
        blocks[block].remove(removed)
        blocks[block].add(added)
        applied.append({
            "block": block,
            "block_index": block,
            "remove": removed,
            "removed": removed,
            "add": added,
            "added": added,
        })
    record = evaluate_counts(counts, lam, v)
    return {"blocks": blocks, "counts": counts, "moves": applied, "record": record}


def dot_delta(a, b):
    return int(sum(int(a[d]) * int(b[d]) for d in range(1, len(a))))


def delta_norm(delta):
    return int(sum(int(delta[d]) * int(delta[d]) for d in range(1, len(delta))))


def add_delta_into(target, delta):
    for idx in range(len(target)):
        target[idx] += int(delta[idx])


def parent_record(path, parent_id):
    data, v, n, ks, lam, blocks = load_candidate(path)
    counts = total_diff_counts(v, blocks)
    record = evaluate_counts(counts, lam, v)
    rho = [0] * int(v)
    for d in range(1, int(v)):
        rho[d] = int(counts[d] - lam)
    stored = {
        "score": int(data.get("score", -1)),
        "l1_error": int(data.get("l1_error", -1)),
        "max_abs_error": int(data.get("max_abs_error", -1)),
        "nonzero_defect_count": int(data.get("nonzero_defect_count", -1)),
    }
    return {
        "id": parent_id,
        "path": path,
        "data": data,
        "v": int(v),
        "n": int(n),
        "ks": tuple(int(k) for k in ks),
        "lambda": int(lam),
        "blocks": blocks,
        "counts": counts,
        "rho": rho,
        "metrics": record,
        "stored_metrics": stored,
        "metrics_match": bool(
            stored["score"] == record["score"]
            and stored["l1_error"] == record["l1_error"]
            and stored["max_abs_error"] == record["max_abs_error"]
            and stored["nonzero_defect_count"] == record["nonzero_defect_count"]
        ),
        "canonical_hash": data.get("canonical_hash") or canonical_hash(blocks, ks, v),
    }


def enumerate_one_swaps(parent):
    v = parent["v"]
    lam = parent["lambda"]
    counts = parent["counts"]
    rho = parent["rho"]
    parent_score = int(parent["metrics"]["score"])
    parent_higher = int(parent["metrics"]["higher_moment_norm"])
    parent_low_zero = int(parent["metrics"]["moment_zero_count_3"])
    rows = []
    swap_id = 0
    for block_idx, block in enumerate(parent["blocks"]):
        outside = [x for x in range(v) if x not in block]
        for removed in sorted(block):
            for added in outside:
                delta = delta_swap(v, block, int(removed), int(added))
                g = dot_delta(rho, delta)
                q = delta_norm(delta)
                h = int(2 * g + q)
                new_counts = apply_delta(counts, delta)
                record = evaluate_counts(new_counts, lam, v)
                alpha = None
                if parent_score > 0 and q > 0:
                    alpha = float(-g) / math.sqrt(float(parent_score) * float(q))
                row = {
                    "swap_id": int(swap_id),
                    "move": {
                        "block": int(block_idx),
                        "block_index": int(block_idx),
                        "remove": int(removed),
                        "removed": int(removed),
                        "add": int(added),
                        "added": int(added),
                    },
                    "block": int(block_idx),
                    "remove": int(removed),
                    "add": int(added),
                    "delta": [int(x) for x in delta],
                    "g": int(g),
                    "q": int(q),
                    "h": int(h),
                    "new_score": int(record["score"]),
                    "new_l1": int(record["l1_error"]),
                    "new_max_abs": int(record["max_abs_error"]),
                    "new_nonzero": int(record["nonzero_defect_count"]),
                    "alpha": alpha,
                    "moment_zero_count_3": int(record["moment_zero_count_3"]),
                    "moment_zero_count_6": int(record["moment_zero_count_6"]),
                    "higher_moment_norm": int(record["higher_moment_norm"]),
                    "low_moment_zero_gain": int(record["moment_zero_count_3"]) - parent_low_zero,
                    "higher_moment_improvement": int(parent_higher) - int(record["higher_moment_norm"]),
                }
                for key, value in record["padic_moments"].items():
                    row[key] = int(value)
                rows.append(row)
                swap_id += 1
    return rows


def add_unique(items, out, seen, limit=None):
    for item in items:
        key = move_key(item["move"])
        if key in seen:
            continue
        seen.add(key)
        out.append(item)
        if limit is not None and len(out) >= int(limit):
            return


def build_move_pool(one_swaps, parent, size, seed):
    rng = random.Random(int(seed) + int(parent["metrics"]["score"]))
    size = int(size)
    pool = []
    seen = set()
    per_category = max(25, size // 9)
    categories = [
        sorted(one_swaps, key=lambda r: (r["h"], r["q"], r["g"])),
        sorted(one_swaps, key=lambda r: (r["g"], r["h"], r["q"])),
        sorted(one_swaps, key=lambda r: (r["q"], r["h"], r["g"])),
        sorted(one_swaps, key=lambda r: (-(r["alpha"] if r["alpha"] is not None else -999), r["h"])),
        sorted(one_swaps, key=lambda r: (r["new_score"], r["new_l1"], r["new_nonzero"])),
        sorted(one_swaps, key=lambda r: (-r["higher_moment_improvement"], r["h"])),
        sorted(one_swaps, key=lambda r: (-r["low_moment_zero_gain"], r["h"])),
    ]
    for items in categories:
        add_unique(items[:per_category], pool, seen)
    for threshold in (4, 8, 16, 32, 64):
        add_unique([row for row in categories[0] if row["h"] <= threshold][:per_category], pool, seen)
    for block_idx in range(4):
        block_rows = [row for row in categories[0] if int(row["block"]) == block_idx]
        add_unique(block_rows[: max(12, size // 24)], pool, seen)
    shuffled = list(one_swaps)
    rng.shuffle(shuffled)
    add_unique(shuffled, pool, seen, limit=size)
    if len(pool) < size:
        add_unique(categories[0], pool, seen, limit=size)
    return pool[:size]


def write_move_pool(path, pool):
    with open(path, "w") as f:
        for rank, item in enumerate(pool, start=1):
            clean = {key: item[key] for key in item if key != "delta"}
            clean["rank"] = int(rank)
            f.write(json.dumps(json_safe(clean), sort_keys=True) + "\n")


def quantile(values, frac):
    if not values:
        return None
    values = sorted(values)
    idx = int(float(frac) * (len(values) - 1))
    return int(values[idx])


class TopKeeper(object):
    def __init__(self, limit=20):
        self.limit = int(limit)
        self.items = []
        self.keys = set()

    def add(self, rank, payload):
        key = payload["result_key"]
        if key in self.keys:
            return
        self.keys.add(key)
        self.items.append((rank, payload))
        self.items.sort(key=lambda item: item[0])
        if len(self.items) > self.limit:
            _rank, removed = self.items.pop()
            self.keys.discard(removed["result_key"])

    def records(self):
        return [payload for _rank, payload in self.items]


class Aggregate(object):
    def __init__(self, parent_score):
        self.parent_score = int(parent_score)
        self.count = 0
        self.conflict_skipped = 0
        self.duplicate_skipped = 0
        self.score_mismatch_count = 0
        self.scores = []
        self.improvement_count = 0
        self.threshold_counts = {str(t): 0 for t in THRESHOLDS}
        self.best = None
        self.best_score = None
        self.best_cross = None

    def add(self, row):
        self.count += 1
        score = int(row["true_score"])
        self.scores.append(score)
        if score < self.parent_score:
            self.improvement_count += 1
        for threshold in THRESHOLDS:
            if score <= threshold:
                self.threshold_counts[str(threshold)] += 1
        if int(row["score_mismatch"]) != 0:
            self.score_mismatch_count += 1
        if self.best_score is None or score < self.best_score:
            self.best_score = score
            self.best = dict(row)
        if self.best_cross is None or int(row["cross_cancellation"]) > int(self.best_cross["cross_cancellation"]):
            self.best_cross = dict(row)

    def summary(self):
        return {
            "evaluated_count": int(self.count),
            "conflict_skipped_count": int(self.conflict_skipped),
            "duplicate_skipped_count": int(self.duplicate_skipped),
            "score_mismatch_count": int(self.score_mismatch_count),
            "best_score": int(self.best_score) if self.best_score is not None else None,
            "score_min": int(min(self.scores)) if self.scores else None,
            "score_p1": quantile(self.scores, 0.01),
            "score_p5": quantile(self.scores, 0.05),
            "score_p10": quantile(self.scores, 0.10),
            "score_median": quantile(self.scores, 0.50),
            "count_score_less_than_parent": int(self.improvement_count),
            "threshold_counts": self.threshold_counts,
            "best_record": self.best,
            "best_cross_record": self.best_cross,
        }


def approx_from_items(parent, items):
    v = parent["v"]
    delta_total = [0] * v
    sum_g = 0
    sum_q = 0
    for item in items:
        add_delta_into(delta_total, item["delta"])
        sum_g += int(item["g"])
        sum_q += int(item["q"])
    g_total = dot_delta(parent["rho"], delta_total)
    q_total = delta_norm(delta_total)
    h_total = int(2 * g_total + q_total)
    return {
        "delta_total": delta_total,
        "g_total": int(g_total),
        "q_total": int(q_total),
        "h_total": int(h_total),
        "approx_score": int(parent["metrics"]["score"]) + int(h_total),
        "sum_individual_g": int(sum_g),
        "sum_individual_q": int(sum_q),
        "cross_cancellation": int(sum_q - q_total),
        "cross_cancellation_ratio": (float(sum_q - q_total) / float(sum_q)) if sum_q else None,
    }


def result_key(parent, moves, depth, method):
    return "{}:{}:{}:{}".format(parent["id"], method, depth, json.dumps(moves_key(moves)))


def evaluate_combo(parent, items, depth, method, compute_hash=False):
    moves = [item["move"] for item in items]
    if not conflict_free_static(moves):
        return None
    approx = approx_from_items(parent, items)
    true = apply_moves_true(parent, moves)
    if true is None:
        return None
    record = true["record"]
    true_score = int(record["score"])
    row = {
        "result_key": result_key(parent, moves, depth, method),
        "parent_id": parent["id"],
        "parent_path": parent["path"],
        "parent_score": int(parent["metrics"]["score"]),
        "depth": int(depth),
        "method": method,
        "moves": true["moves"],
        "approx_score": int(approx["approx_score"]),
        "true_score": int(true_score),
        "score_delta": int(true_score - int(parent["metrics"]["score"])),
        "true_l1": int(record["l1_error"]),
        "true_max_abs": int(record["max_abs_error"]),
        "true_nonzero": int(record["nonzero_defect_count"]),
        "g_total": int(approx["g_total"]),
        "q_total": int(approx["q_total"]),
        "h_total": int(approx["h_total"]),
        "sum_individual_g": int(approx["sum_individual_g"]),
        "sum_individual_q": int(approx["sum_individual_q"]),
        "cross_cancellation": int(approx["cross_cancellation"]),
        "cross_cancellation_ratio": approx["cross_cancellation_ratio"],
        "D_min_ratio": (float(true_score) / float(parent["metrics"]["score"])) if int(parent["metrics"]["score"]) else None,
        "score_mismatch": int(true_score - int(approx["approx_score"])),
        "approx_h": int(approx["h_total"]),
        "true_h": int(true_score - int(parent["metrics"]["score"])),
        "conflict_free": True,
        "true_metrics_recomputed": True,
        "moment_zero_count_3": int(record["moment_zero_count_3"]),
        "moment_zero_count_6": int(record["moment_zero_count_6"]),
        "higher_moment_norm": int(record["higher_moment_norm"]),
        "_result": true,
        "_parent": parent,
    }
    for key, value in record["padic_moments"].items():
        row[key] = int(value)
    if compute_hash:
        row["canonical_hash"] = canonical_hash(true["blocks"], parent["ks"], parent["v"])
    return row


def update_frontiers(frontiers, row):
    frontiers["true_score"].add((row["true_score"], row["true_l1"], row["true_max_abs"], row["true_nonzero"], row["result_key"]), row)
    frontiers["h_total"].add((row["h_total"], row["q_total"], row["true_score"], row["result_key"]), row)
    frontiers["l1"].add((row["true_l1"], row["true_score"], row["true_max_abs"], row["result_key"]), row)
    frontiers["max_abs"].add((row["true_max_abs"], row["true_score"], row["true_l1"], row["result_key"]), row)
    frontiers["nonzero"].add((row["true_nonzero"], row["true_l1"], row["true_score"], row["result_key"]), row)
    frontiers["cross"].add((-row["cross_cancellation"], row["true_score"], row["result_key"]), row)
    frontiers["moment"].add((-row["moment_zero_count_6"], row["higher_moment_norm"], row["true_score"], row["result_key"]), row)


def notable(row):
    parent_score = int(row["parent_score"])
    if int(row["true_score"]) < parent_score:
        return True
    if int(row["true_score"]) <= parent_score + 16:
        return True
    return any(int(row["true_score"]) <= threshold for threshold in THRESHOLDS)


def clean_row(row, include_result=False):
    out = {key: value for key, value in row.items() if not key.startswith("_")}
    if not include_result:
        return out
    return out


def exact_pair_search(parent, pool, pool_size, out_dir, frontiers, notable_rows):
    method = "exact_pair_M{}".format(pool_size)
    out_path = os.path.join(out_dir, "pair_search_{}_M{}.jsonl".format(parent["id"], pool_size))
    agg = Aggregate(parent["metrics"]["score"])
    seen = set()
    with open(out_path, "w") as f:
        for i in range(len(pool)):
            for j in range(i + 1, len(pool)):
                moves = [pool[i]["move"], pool[j]["move"]]
                key = moves_key(moves)
                if key in seen:
                    agg.duplicate_skipped += 1
                    continue
                seen.add(key)
                if not conflict_free_static(moves):
                    agg.conflict_skipped += 1
                    continue
                row = evaluate_combo(parent, [pool[i], pool[j]], 2, method, compute_hash=False)
                if row is None:
                    agg.conflict_skipped += 1
                    continue
                agg.add(row)
                update_frontiers(frontiers, row)
                if notable(row):
                    f.write(json.dumps(json_safe(clean_row(row)), sort_keys=True) + "\n")
                    notable_rows[row["result_key"]] = row
    summary = agg.summary()
    summary["jsonl"] = out_path
    summary["move_pool_size"] = int(pool_size)
    return summary


def state_from_item(parent, item, idx):
    delta = [int(x) for x in item["delta"]]
    return {
        "indices": (int(idx),),
        "items": (item,),
        "moves": (item["move"],),
        "delta_total": delta,
        "g_total": int(item["g"]),
        "q_total": int(item["q"]),
        "h_total": int(item["h"]),
        "sum_individual_g": int(item["g"]),
        "sum_individual_q": int(item["q"]),
        "cross_cancellation": 0,
        "last_index": int(idx),
    }


def extend_state(parent, state, item, idx):
    moves = list(state["moves"]) + [item["move"]]
    if not conflict_free_static(moves):
        return None
    delta = list(state["delta_total"])
    add_delta_into(delta, item["delta"])
    g_total = dot_delta(parent["rho"], delta)
    q_total = delta_norm(delta)
    h_total = int(2 * g_total + q_total)
    sum_g = int(state["sum_individual_g"] + int(item["g"]))
    sum_q = int(state["sum_individual_q"] + int(item["q"]))
    return {
        "indices": tuple(list(state["indices"]) + [int(idx)]),
        "items": tuple(list(state["items"]) + [item]),
        "moves": tuple(moves),
        "delta_total": delta,
        "g_total": int(g_total),
        "q_total": int(q_total),
        "h_total": int(h_total),
        "sum_individual_g": int(sum_g),
        "sum_individual_q": int(sum_q),
        "cross_cancellation": int(sum_q - q_total),
        "last_index": int(idx),
    }


def state_rank(state, mode="score"):
    if mode == "target_delta":
        return (
            int(state["h_total"]),
            -int(state["cross_cancellation"]),
            int(state["q_total"]),
            int(state["g_total"]),
            tuple(state["indices"]),
        )
    return (
        int(state["h_total"]),
        int(state["q_total"]),
        -int(state["cross_cancellation"]),
        int(state["g_total"]),
        tuple(state["indices"]),
    )


def beam_search(parent, pool, pool_size, max_depth, beam_width, expand_per_state, true_eval_limit, out_dir, frontiers, notable_rows, mode="score"):
    method_prefix = "beam_{}_M{}_D{}".format(mode, pool_size, max_depth)
    out_path = os.path.join(out_dir, "beam_search_{}_{}_M{}_D{}.jsonl".format(parent["id"], mode, pool_size, max_depth))
    agg_by_depth = {}
    pool_order = sorted(range(len(pool)), key=lambda idx: (pool[idx]["h"], pool[idx]["q"], pool[idx]["g"], idx))
    beam = [state_from_item(parent, pool[idx], idx) for idx in pool_order[: min(len(pool_order), int(beam_width))]]
    beam.sort(key=lambda st: state_rank(st, mode))
    beam = beam[: int(beam_width)]
    with open(out_path, "w") as f:
        for depth in range(2, int(max_depth) + 1):
            expanded = []
            seen = set()
            for state in beam:
                added = 0
                for idx in pool_order:
                    if idx <= state["last_index"]:
                        continue
                    child = extend_state(parent, state, pool[idx], idx)
                    if child is None:
                        continue
                    key = tuple(child["indices"])
                    if key in seen:
                        continue
                    seen.add(key)
                    expanded.append(child)
                    added += 1
                    if added >= int(expand_per_state):
                        break
            expanded.sort(key=lambda st: state_rank(st, mode))
            beam = expanded[: int(beam_width)]
            print("beam parent={} mode={} pool={} depth={} states={}".format(parent["id"], mode, pool_size, depth, len(beam)))
            if depth < 3:
                continue
            agg = Aggregate(parent["metrics"]["score"])
            eval_states = beam[: min(len(beam), int(true_eval_limit))]
            for state in eval_states:
                row = evaluate_combo(parent, list(state["items"]), depth, method_prefix, compute_hash=False)
                if row is None:
                    agg.conflict_skipped += 1
                    continue
                agg.add(row)
                update_frontiers(frontiers, row)
                if notable(row):
                    f.write(json.dumps(json_safe(clean_row(row)), sort_keys=True) + "\n")
                    notable_rows[row["result_key"]] = row
            summary = agg.summary()
            summary["depth"] = int(depth)
            summary["mode"] = mode
            summary["move_pool_size"] = int(pool_size)
            summary["beam_states"] = int(len(beam))
            summary["true_eval_limit"] = int(true_eval_limit)
            summary["jsonl"] = out_path
            agg_by_depth[str(depth)] = summary
    return agg_by_depth


def candidate_payload(row):
    parent = row["_parent"]
    result = row["_result"]
    record = result["record"]
    score = int(record["score"])
    blocks = result["blocks"]
    counts = result["counts"]
    payload = {
        "v": int(parent["v"]),
        "n": int(parent["n"]),
        "ks": [int(k) for k in parent["ks"]],
        "lambda": int(parent["lambda"]),
        "blocks": json_blocks(blocks),
        "parent_path": parent["path"],
        "parent_hash": parent["canonical_hash"],
        "parent_score": int(parent["metrics"]["score"]),
        "depth": int(row["depth"]),
        "moves": result["moves"],
        "approx_score": int(row["approx_score"]),
        "true_score": int(row["true_score"]),
        "score": score,
        "score_delta": int(row["score_delta"]),
        "l1_error": int(record["l1_error"]),
        "max_abs_error": int(record["max_abs_error"]),
        "nonzero_defect_count": int(record["nonzero_defect_count"]),
        "counts": [int(x) for x in counts],
        "defect_histogram": error_histogram(counts, parent["lambda"]),
        "padic_moments": record["padic_moments"],
        "moment_zero_count_3": int(record["moment_zero_count_3"]),
        "moment_zero_count_6": int(record["moment_zero_count_6"]),
        "higher_moment_norm": int(record["higher_moment_norm"]),
        "g_total": int(row["g_total"]),
        "q_total": int(row["q_total"]),
        "h_total": int(row["h_total"]),
        "sum_individual_g": int(row["sum_individual_g"]),
        "sum_individual_q": int(row["sum_individual_q"]),
        "cross_cancellation": int(row["cross_cancellation"]),
        "cross_cancellation_ratio": row["cross_cancellation_ratio"],
        "D_min_ratio": row["D_min_ratio"],
        "score_mismatch": int(row["score_mismatch"]),
        "approx_h": int(row["approx_h"]),
        "true_h": int(row["true_h"]),
        "canonical_hash": canonical_hash(blocks, parent["ks"], parent["v"]),
        "canonical_repr_summary": canonical_repr_summary(blocks, parent["ks"], parent["v"]),
        "search_method": "coherent_multiswap_escape",
        "method": row["method"],
        "true_metrics_recomputed": True,
        "verify_sds": False,
        "generated_hadamard": False,
        "hh_t": False,
        "verification_status": "not_verified_score_nonzero" if score != 0 else "score0_requires_explicit_sds_gs_verification",
        "construction": "Goethals-Seidel",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    return payload


def save_candidate(row, hint):
    payload = candidate_payload(row)
    path = os.path.join(
        "outputs",
        "candidates",
        "near_hits",
        "near_hit_v{}_score{}_coherent_multiswap_escape_{}.json".format(
            payload["v"], payload["score"], hint
        ),
    )
    path = ensure_unique_path(path)
    write_json(path, json_safe(payload))
    return path, payload


def save_frontiers(out_dir, frontiers):
    for name, keeper in frontiers.items():
        path = os.path.join(out_dir, "frontier_best_by_{}.jsonl".format(name))
        with open(path, "w") as f:
            for rank, row in enumerate(keeper.records(), start=1):
                clean = clean_row(row)
                clean["rank"] = int(rank)
                clean["frontier"] = name
                f.write(json.dumps(json_safe(clean), sort_keys=True) + "\n")


def save_retained_candidates(out_dir, frontiers, notable_rows):
    retained = {}
    for name, keeper in frontiers.items():
        for row in keeper.records():
            retained[row["result_key"]] = (row, "frontier_{}".format(name))
    for key, row in notable_rows.items():
        retained[key] = (row, "notable_threshold_or_improvement")
    saved = []
    seen_hash = set()
    for idx, (key, (row, reason)) in enumerate(sorted(retained.items()), start=1):
        path, payload = save_candidate(row, "{}_{}".format(row["parent_id"], idx))
        duplicate = payload["canonical_hash"] in seen_hash
        seen_hash.add(payload["canonical_hash"])
        saved.append({
            "path": path,
            "reason": reason,
            "score": int(payload["score"]),
            "l1_error": int(payload["l1_error"]),
            "max_abs_error": int(payload["max_abs_error"]),
            "nonzero_defect_count": int(payload["nonzero_defect_count"]),
            "depth": int(payload["depth"]),
            "method": payload["method"],
            "parent_id": row["parent_id"],
            "cross_cancellation": int(payload["cross_cancellation"]),
            "score_mismatch": int(payload["score_mismatch"]),
            "canonical_hash": payload["canonical_hash"],
            "duplicate_canonical_hash_in_saved_set": bool(duplicate),
        })
    write_json(os.path.join(out_dir, "saved_candidate_index.json"), json_safe(saved))
    return saved


def write_summary(out_dir, parents, summaries, saved, args):
    lines = []
    lines.append("# Coherent Multiswap Escape Summary")
    lines.append("")
    lines.append("This experiment tests whether shallow 1-swap walls around score164/score176 can be escaped by coherent multi-swaps. It is not a Hadamard 668 construction claim.")
    lines.append("")
    lines.append("## Parents")
    lines.append("")
    for parent in parents:
        lines.append("- `{}` path `{}` metrics `{}` metrics_match `{}`".format(
            parent["id"], parent["path"], compact_metrics(parent["metrics"]), parent["metrics_match"]
        ))
    lines.append("")
    lines.append("## 428 Calibration")
    lines.append("")
    lines.append("- 428 distance1 score48: one-swap return has `min_h=-48`, `D_min_ratio=0`.")
    lines.append("- 428 distance2 score80: one-swap returns/improvements exist, `D_min_ratio=0`.")
    lines.append("")
    lines.append("## Results")
    lines.append("")
    for parent in parents:
        pid = parent["id"]
        lines.append("### {}".format(pid))
        lines.append("")
        for run in summaries[pid]["pair"]:
            lines.append("- pair M={}: evaluated `{}`, best `{}`, improvements `{}`, mismatches `{}`, thresholds `{}`".format(
                run["move_pool_size"], run["evaluated_count"], run["best_score"],
                run["count_score_less_than_parent"], run["score_mismatch_count"], run["threshold_counts"]
            ))
        for run in summaries[pid]["beam"]:
            lines.append("- beam mode={} M={} depth={}: states `{}`, evaluated `{}`, best `{}`, improvements `{}`, mismatches `{}`".format(
                run["mode"], run["move_pool_size"], run["depth"], run["beam_states"],
                run["evaluated_count"], run["best_score"], run["count_score_less_than_parent"],
                run["score_mismatch_count"],
            ))
        lines.append("")
    lines.append("## Saved Candidates")
    lines.append("")
    lines.append("Saved candidate JSON count: `{}`".format(len(saved)))
    for item in saved[:40]:
        lines.append("- `{}` parent `{}` depth `{}` method `{}` score `{}` l1 `{}` max `{}` nonzero `{}` reason `{}` mismatch `{}`".format(
            item["path"], item["parent_id"], item["depth"], item["method"], item["score"],
            item["l1_error"], item["max_abs_error"], item["nonzero_defect_count"],
            item["reason"], item["score_mismatch"],
        ))
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    for parent in parents:
        pid = parent["id"]
        parent_score = int(parent["metrics"]["score"])
        all_runs = summaries[pid]["pair"] + summaries[pid]["beam"]
        best = min(run["best_score"] for run in all_runs if run["best_score"] is not None)
        improved = any(run["count_score_less_than_parent"] > 0 for run in all_runs)
        best_depths = [run for run in all_runs if run["best_score"] == best]
        lines.append("1/2. `{}` true_score < parent: `{}`; best score `{}` from `{}`.".format(
            pid, improved, best, ", ".join("{} depth {}".format(run.get("mode", "pair"), run.get("depth", 2)) for run in best_depths[:5])
        ))
    global_best = min((item["score"] for item in saved), default=None)
    lines.append("3. score <=120 / 80 / 48 / 0 reached: `{}` / `{}` / `{}` / `{}`.".format(
        bool(global_best is not None and global_best <= 120),
        bool(global_best is not None and global_best <= 80),
        bool(global_best is not None and global_best <= 48),
        bool(global_best == 0),
    ))
    lines.append("4. Best depth is shown per parent above.")
    lines.append("5. Cross-cancellation is recorded in all saved candidate JSON and `frontier_best_by_cross.jsonl`.")
    lines.append("6. Individual-h-bad but combined-improving examples exist iff any saved row has `score < parent_score` and depth > 1.")
    lines.append("7. Moment diagnostics are saved, but they are not the main objective.")
    lines.append("8. If no improvement appears through tested depths, these basins remain hard under coherent multi-swap at this search scale.")
    lines.append("9. Next direction should be based on whether improvement was found: continue depth/LNS if yes; otherwise move to pair-level defect repair or new basin.")
    lines.append("")
    lines.append("## Safety")
    lines.append("")
    lines.append("- No score-nonzero candidate is a success candidate.")
    lines.append("- score=0 would still require exact SDS validation and Goethals-Seidel HH^T=668I over ZZ.")
    lines.append("- Approximate delta scores are always checked against true recomputation for retained/evaluated candidates.")
    with open(os.path.join(out_dir, "coherent_multiswap_summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Coherent multi-swap escape around score164/score176 near-hits.")
    parser.add_argument("--score164-path", default="")
    parser.add_argument("--score176-path", default="")
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--move-pool-sizes", default="500,1000")
    parser.add_argument("--beam-pool-size", type=int, default=1000)
    parser.add_argument("--beam-depths", default="3,4")
    parser.add_argument("--beam-width", type=int, default=2000)
    parser.add_argument("--expand-per-state", type=int, default=200)
    parser.add_argument("--beam-true-eval", type=int, default=2000)
    parser.add_argument("--beam-modes", default="score")
    parser.add_argument("--skip-pair", action="store_true")
    parser.add_argument("--target-delta", action="store_true")
    parser.add_argument("--seed", type=int, default=50)
    return parser.parse_args()


def main():
    args = parse_args()
    out_dir = args.out_dir or os.path.join(
        "outputs",
        "explorations",
        "{}_hadamard668_coherent_multiswap_escape".format(now_stamp()),
    )
    ensure_dir(out_dir)
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        score164_path = args.score164_path or find_candidate_by_score(
            164,
            ["near_hit_v167_score164_steepest_swap_descent_round1.json"],
        )
        score176_path = args.score176_path or find_candidate_by_score(
            176,
            ["near_hit_v167_score176_seed101_step8576.json"],
        )
        parents = [
            parent_record(score164_path, "score164"),
            parent_record(score176_path, "score176"),
        ]
        move_pool_sizes = parse_int_list(args.move_pool_sizes, [500, 1000])
        beam_depths = parse_int_list(args.beam_depths, [3, 4])
        beam_modes = [part.strip() for part in str(args.beam_modes).split(",") if part.strip()]
        if args.target_delta and "target_delta" not in beam_modes:
            beam_modes.append("target_delta")
        run_config = {
            "script": SCRIPT_NAME,
            "out_dir": out_dir,
            "score164_path": score164_path,
            "score176_path": score176_path,
            "move_pool_sizes": move_pool_sizes,
            "beam_pool_size": int(args.beam_pool_size),
            "beam_depths": beam_depths,
            "beam_width": int(args.beam_width),
            "expand_per_state": int(args.expand_per_state),
            "beam_true_eval": int(args.beam_true_eval),
            "beam_modes": beam_modes,
            "skip_pair": bool(args.skip_pair),
            "target_delta": bool(args.target_delta),
            "seed": int(args.seed),
        }
        write_json(os.path.join(out_dir, "run_config.json"), json_safe(run_config))
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# Coherent Multiswap Escape Run Log\n\n")
            f.write("- started: `{}`\n".format(time.strftime("%Y-%m-%dT%H:%M:%S")))
            f.write("- log: `{}`\n".format(getattr(tee, "log", None).name if getattr(tee, "log", None) else ""))
        print("Parents:")
        for parent in parents:
            print(parent["id"], parent["path"], compact_metrics(parent["metrics"]), "match", parent["metrics_match"])
        frontiers = {
            "true_score": TopKeeper(20),
            "h_total": TopKeeper(20),
            "l1": TopKeeper(20),
            "max_abs": TopKeeper(20),
            "nonzero": TopKeeper(20),
            "cross": TopKeeper(20),
            "moment": TopKeeper(20),
        }
        notable_rows = {}
        summaries = {}
        for parent in parents:
            pid = parent["id"]
            summaries[pid] = {"pair": [], "beam": []}
            print("Enumerating one-swaps for", pid)
            one_swaps = enumerate_one_swaps(parent)
            pools = {}
            for size in sorted(set(move_pool_sizes + [int(args.beam_pool_size)])):
                pool = build_move_pool(one_swaps, parent, int(size), args.seed)
                pools[int(size)] = pool
                write_move_pool(os.path.join(out_dir, "move_pool_{}_M{}.jsonl".format(pid, size)), pool)
                if int(size) == max(move_pool_sizes):
                    write_move_pool(os.path.join(out_dir, "move_pool_{}.jsonl".format(pid)), pool)
            if not args.skip_pair:
                for size in move_pool_sizes:
                    print("Pair search parent={} M={}".format(pid, size))
                    summary = exact_pair_search(parent, pools[int(size)], int(size), out_dir, frontiers, notable_rows)
                    summaries[pid]["pair"].append(summary)
            for depth in beam_depths:
                if int(depth) < 3:
                    continue
                for mode in beam_modes:
                    print("Beam search parent={} M={} depth={} mode={}".format(pid, args.beam_pool_size, depth, mode))
                    beam_summaries = beam_search(
                        parent,
                        pools[int(args.beam_pool_size)],
                        int(args.beam_pool_size),
                        int(depth),
                        int(args.beam_width),
                        int(args.expand_per_state),
                        int(args.beam_true_eval),
                        out_dir,
                        frontiers,
                        notable_rows,
                        mode=mode,
                    )
                    summaries[pid]["beam"].extend(beam_summaries.values())
        save_frontiers(out_dir, frontiers)
        saved = save_retained_candidates(out_dir, frontiers, notable_rows)
        write_json(os.path.join(out_dir, "run_summary.json"), json_safe(summaries))
        write_summary(out_dir, parents, summaries, saved, args)
        with open(os.path.join(out_dir, "run_log.md"), "a") as f:
            f.write("- finished: `{}`\n".format(time.strftime("%Y-%m-%dT%H:%M:%S")))
            f.write("- saved candidates: `{}`\n".format(len(saved)))
        print("OUT_DIR:", out_dir)
        print("SUMMARY:", os.path.join(out_dir, "coherent_multiswap_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
