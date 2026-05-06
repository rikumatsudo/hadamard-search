from sage.all import *

import argparse
import csv
import glob
import json
import os
import random
import statistics
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


SCRIPT_NAME = "48_near_hit_swap_neighborhood_census"
POWERS = (2, 4, 6, 8, 10, 12)
LOW_POWERS = (2, 4, 6)
THRESHOLDS = (160, 140, 120, 100, 80, 48, 0)


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
    return value


def parse_int_list(text, default):
    if text is None or str(text).strip() == "":
        return list(default)
    return [int(part.strip()) for part in str(text).split(",") if part.strip()]


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
            stored = int(data.get("score", -1))
            if int(metrics[0]) == int(score) and stored == int(score):
                return path
        except Exception:
            continue
    raise RuntimeError("could not find valid score={} candidate".format(score))


def balanced_abs(residue, modulus):
    residue = int(residue) % int(modulus)
    return min(residue, int(modulus) - residue)


def moment_payload(counts, lam, v):
    low = p_adic_moment_summary(counts, lam, powers=LOW_POWERS, modulus=v)
    high = p_adic_moment_summary(counts, lam, powers=POWERS, modulus=v)
    by_power = {"T{}".format(item["power"]): int(item["residue"]) for item in high["moments"]}
    higher_norm = 0
    for key in ("T8", "T10", "T12"):
        higher_norm += balanced_abs(by_power[key], v) ** 2
    return {
        "padic_moments": by_power,
        "p_adic_moments_3": low,
        "p_adic_moments_6": high,
        "moment_zero_count_3": int(low["moment_zero_count"]),
        "moment_zero_count_6": int(high["moment_zero_count"]),
        "moment_signature_3": low["moment_signature"],
        "moment_signature_6": high["moment_signature"],
        "moment_abs_sum_3": int(low["moment_abs_sum"]),
        "moment_abs_sum_6": int(high["moment_abs_sum"]),
        "higher_moment_norm": int(higher_norm),
    }


def evaluate_counts(counts, lam, v):
    metrics = metrics_from_counts(counts, lam)
    moment = moment_payload(counts, lam, v)
    return {
        "score": int(metrics[0]),
        "l1_error": int(metrics[1]),
        "max_abs_error": int(metrics[2]),
        "nonzero_defect_count": int(metrics[3]),
        **moment,
    }


def compact_metrics(record):
    return {
        "score": int(record["score"]),
        "l1_error": int(record["l1_error"]),
        "max_abs_error": int(record["max_abs_error"]),
        "nonzero_defect_count": int(record["nonzero_defect_count"]),
        "T2": int(record["padic_moments"]["T2"]),
        "T4": int(record["padic_moments"]["T4"]),
        "T6": int(record["padic_moments"]["T6"]),
        "T8": int(record["padic_moments"]["T8"]),
        "T10": int(record["padic_moments"]["T10"]),
        "T12": int(record["padic_moments"]["T12"]),
        "moment_zero_count_3": int(record["moment_zero_count_3"]),
        "moment_zero_count_6": int(record["moment_zero_count_6"]),
        "higher_moment_norm": int(record["higher_moment_norm"]),
    }


def clone_blocks(blocks):
    return [set(block) for block in blocks]


def normalized_move(move):
    return {
        "block_index": int(move["block"]),
        "block": int(move["block"]),
        "remove": int(move["remove"]),
        "removed": int(move["remove"]),
        "add": int(move["add"]),
        "added": int(move["add"]),
    }


def apply_moves_true(v, parent_blocks, parent_counts, lam, moves):
    blocks = clone_blocks(parent_blocks)
    counts = list(parent_counts)
    applied = []
    for raw in moves:
        move = normalized_move(raw)
        block_idx = int(move["block"])
        removed = int(move["remove"])
        added = int(move["add"])
        if removed not in blocks[block_idx] or added in blocks[block_idx]:
            return None
        delta = delta_swap(v, blocks[block_idx], removed, added)
        counts = apply_delta(counts, delta)
        blocks[block_idx].remove(removed)
        blocks[block_idx].add(added)
        applied.append(move)
    metrics = metrics_from_counts(counts, lam)
    record = evaluate_counts(counts, lam, v)
    return {
        "blocks": blocks,
        "counts": counts,
        "moves": applied,
        "metrics_tuple": metrics,
        "record": record,
    }


def apply_moves_basic(v, parent_blocks, parent_counts, lam, moves):
    blocks = clone_blocks(parent_blocks)
    counts = list(parent_counts)
    applied = []
    for raw in moves:
        move = normalized_move(raw)
        block_idx = int(move["block"])
        removed = int(move["remove"])
        added = int(move["add"])
        if removed not in blocks[block_idx] or added in blocks[block_idx]:
            return None
        delta = delta_swap(v, blocks[block_idx], removed, added)
        counts = apply_delta(counts, delta)
        blocks[block_idx].remove(removed)
        blocks[block_idx].add(added)
        applied.append(move)
    return {
        "blocks": blocks,
        "counts": counts,
        "moves": applied,
        "metrics_tuple": metrics_from_counts(counts, lam),
    }


def complete_basic_result(v, lam, basic):
    record = evaluate_counts(basic["counts"], lam, v)
    return {
        "blocks": basic["blocks"],
        "counts": basic["counts"],
        "moves": basic["moves"],
        "metrics_tuple": basic["metrics_tuple"],
        "record": record,
    }


def moves_key(moves):
    return tuple(sorted((int(m["block"]), int(m["remove"]), int(m["add"])) for m in moves))


def conflict_free_static(moves):
    by_block = {}
    for raw in moves:
        block = int(raw["block"])
        removed = int(raw["remove"])
        added = int(raw["add"])
        state = by_block.setdefault(block, {"removed": set(), "added": set(), "touched": set()})
        if removed in state["removed"] or added in state["added"]:
            return False
        if removed in state["added"] or added in state["removed"]:
            return False
        state["removed"].add(removed)
        state["added"].add(added)
    return True


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


def notable_threshold(record, parent_score):
    score = int(record["score"])
    return score <= int(parent_score) or any(score <= threshold for threshold in THRESHOLDS)


def candidate_payload(parent, result, depth, method_label, result_key):
    record = result["record"]
    blocks = result["blocks"]
    counts = result["counts"]
    v = parent["v"]
    ks = parent["ks"]
    lam = parent["lambda"]
    score = int(record["score"])
    payload = {
        "v": int(v),
        "n": int(4 * v),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": json_blocks(blocks),
        "parent_path": parent["path"],
        "parent_hash": parent.get("canonical_hash", ""),
        "parent_score": int(parent["metrics"]["score"]),
        "depth": int(depth),
        "moves": result["moves"],
        "score": score,
        "l1_error": int(record["l1_error"]),
        "max_abs_error": int(record["max_abs_error"]),
        "nonzero_defect_count": int(record["nonzero_defect_count"]),
        "counts": [int(x) for x in counts],
        "defect_histogram": error_histogram(counts, lam),
        "padic_moments": record["padic_moments"],
        "p_adic_moments_3": record["p_adic_moments_3"],
        "p_adic_moments_6": record["p_adic_moments_6"],
        "moment_zero_count_3": int(record["moment_zero_count_3"]),
        "moment_zero_count_6": int(record["moment_zero_count_6"]),
        "moment_signature_3": record["moment_signature_3"],
        "moment_signature_6": record["moment_signature_6"],
        "higher_moment_norm": int(record["higher_moment_norm"]),
        "canonical_hash": canonical_hash(blocks, ks, v),
        "canonical_repr_summary": canonical_repr_summary(blocks, ks, v),
        "search_method": "near_hit_swap_neighborhood_census",
        "census_stage": method_label,
        "true_metrics_recomputed": True,
        "verify_sds": False,
        "generated_hadamard": False,
        "hh_t": False,
        "verification_status": "not_verified_score_nonzero" if score != 0 else "score0_requires_explicit_sds_gs_verification",
        "construction": "Goethals-Seidel",
        "result_key": result_key,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    return payload


def save_candidate(parent, result, depth, method_label, result_key, out_name_hint):
    payload = candidate_payload(parent, result, depth, method_label, result_key)
    path = os.path.join(
        "outputs",
        "candidates",
        "near_hits",
        "near_hit_v{}_score{}_{}_{}.json".format(
            parent["v"], payload["score"], method_label, out_name_hint
        ),
    )
    path = ensure_unique_path(path)
    write_json(path, payload)
    return path, payload


def row_from_result(parent, result, depth, method_label, include_moves=True):
    record = result["record"]
    out = {
        "parent_id": parent["id"],
        "parent_path": parent["path"],
        "parent_score": int(parent["metrics"]["score"]),
        "depth": int(depth),
        "method": method_label,
        "score": int(record["score"]),
        "l1_error": int(record["l1_error"]),
        "max_abs_error": int(record["max_abs_error"]),
        "nonzero_defect_count": int(record["nonzero_defect_count"]),
        "delta_score": int(record["score"]) - int(parent["metrics"]["score"]),
        "delta_l1": int(record["l1_error"]) - int(parent["metrics"]["l1_error"]),
        "delta_max_abs": int(record["max_abs_error"]) - int(parent["metrics"]["max_abs_error"]),
        "delta_nonzero": int(record["nonzero_defect_count"]) - int(parent["metrics"]["nonzero_defect_count"]),
        "moment_zero_count_3": int(record["moment_zero_count_3"]),
        "moment_zero_count_6": int(record["moment_zero_count_6"]),
        "higher_moment_norm": int(record["higher_moment_norm"]),
    }
    for key, value in record["padic_moments"].items():
        out[key] = int(value)
    if include_moves:
        out["moves"] = result["moves"]
    return out


def one_swap_census(parent, out_dir):
    v = parent["v"]
    lam = parent["lambda"]
    blocks = parent["blocks"]
    counts = parent["counts"]
    parent_metrics = parent["metrics"]
    path = os.path.join(out_dir, "full_1swap_{}.csv".format(parent["id"]))
    fieldnames = [
        "parent_id", "parent_score", "block_index", "remove", "add",
        "score", "l1_error", "max_abs_error", "nonzero_defect_count",
        "delta_score", "delta_l1", "delta_max_abs", "delta_nonzero",
        "T2", "T4", "T6", "T8", "T10", "T12",
        "moment_zero_count_3", "moment_zero_count_6", "higher_moment_norm",
        "canonical_hash",
    ]
    rows = []
    scores = []
    l1s = []
    zero_hist = {}
    threshold_counts = {str(t): 0 for t in THRESHOLDS}
    improvement_count = 0
    best_records = []
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for block_idx, block in enumerate(blocks):
            outside = [x for x in range(v) if x not in block]
            for removed in sorted(block):
                for added in outside:
                    delta = delta_swap(v, block, int(removed), int(added))
                    new_counts = apply_delta(counts, delta)
                    record = evaluate_counts(new_counts, lam, v)
                    score = int(record["score"])
                    scores.append(score)
                    l1s.append(int(record["l1_error"]))
                    if score < int(parent_metrics["score"]):
                        improvement_count += 1
                    for threshold in THRESHOLDS:
                        if score <= threshold:
                            threshold_counts[str(threshold)] += 1
                    zero_key = str(record["moment_zero_count_3"])
                    zero_hist[zero_key] = zero_hist.get(zero_key, 0) + 1
                    row = {
                        "parent_id": parent["id"],
                        "parent_score": int(parent_metrics["score"]),
                        "block_index": int(block_idx),
                        "remove": int(removed),
                        "add": int(added),
                        "score": score,
                        "l1_error": int(record["l1_error"]),
                        "max_abs_error": int(record["max_abs_error"]),
                        "nonzero_defect_count": int(record["nonzero_defect_count"]),
                        "delta_score": score - int(parent_metrics["score"]),
                        "delta_l1": int(record["l1_error"]) - int(parent_metrics["l1_error"]),
                        "delta_max_abs": int(record["max_abs_error"]) - int(parent_metrics["max_abs_error"]),
                        "delta_nonzero": int(record["nonzero_defect_count"]) - int(parent_metrics["nonzero_defect_count"]),
                        "moment_zero_count_3": int(record["moment_zero_count_3"]),
                        "moment_zero_count_6": int(record["moment_zero_count_6"]),
                        "higher_moment_norm": int(record["higher_moment_norm"]),
                        "canonical_hash": "",
                    }
                    for key, value in record["padic_moments"].items():
                        row[key] = int(value)
                    writer.writerow(row)
                    move = {"block": int(block_idx), "remove": int(removed), "add": int(added)}
                    pool_item = dict(row)
                    pool_item["move"] = move
                    pool_item["delta"] = delta
                    rows.append(pool_item)
                    best_records.append(pool_item)
                    best_records.sort(key=lambda item: (
                        item["score"], item["l1_error"], item["max_abs_error"], item["nonzero_defect_count"],
                        item["block_index"], item["remove"], item["add"]
                    ))
                    del best_records[200:]
    summary = {
        "csv": path,
        "count": int(len(rows)),
        "best_score": int(min(scores)) if scores else None,
        "best_l1": int(min(l1s)) if l1s else None,
        "score_min": int(min(scores)) if scores else None,
        "score_p1": quantile(scores, 0.01),
        "score_p5": quantile(scores, 0.05),
        "score_p10": quantile(scores, 0.10),
        "score_median": quantile(scores, 0.50),
        "count_score_less_than_parent": int(improvement_count),
        "threshold_counts": threshold_counts,
        "moment_zero_count_3_histogram": zero_hist,
        "is_one_swap_local_minimum": bool(improvement_count == 0),
        "best_rows": [
            {key: item[key] for key in item if key not in ("delta",)}
            for item in best_records[:20]
        ],
    }
    return rows, summary


def add_unique(items, out, seen, limit=None):
    for item in items:
        key = (int(item["move"]["block"]), int(item["move"]["remove"]), int(item["move"]["add"]))
        if key in seen:
            continue
        seen.add(key)
        out.append(item)
        if limit is not None and len(out) >= int(limit):
            return


def build_move_pool(one_rows, parent, size, seed):
    rng = random.Random(int(seed) + int(parent["metrics"]["score"]))
    pool = []
    seen = set()
    sorted_by_score = sorted(one_rows, key=lambda r: (r["score"], r["l1_error"], r["max_abs_error"], r["nonzero_defect_count"]))
    sorted_by_l1 = sorted(one_rows, key=lambda r: (r["l1_error"], r["score"], r["max_abs_error"], r["nonzero_defect_count"]))
    sorted_by_max = sorted(one_rows, key=lambda r: (r["max_abs_error"], r["score"], r["l1_error"], r["nonzero_defect_count"]))
    sorted_by_nonzero = sorted(one_rows, key=lambda r: (r["nonzero_defect_count"], r["l1_error"], r["score"]))
    sorted_by_moment3 = sorted(one_rows, key=lambda r: (
        -int(r["moment_zero_count_3"]),
        abs_bal_tuple(r, parent["v"], ("T2", "T4", "T6")),
        r["score"],
    ))
    sorted_by_moment6 = sorted(one_rows, key=lambda r: (
        -int(r["moment_zero_count_6"]),
        int(r["higher_moment_norm"]),
        r["score"],
    ))
    per_category = max(20, int(size) // 8)
    for items in (sorted_by_score, sorted_by_l1, sorted_by_max, sorted_by_nonzero, sorted_by_moment3, sorted_by_moment6):
        add_unique(items[:per_category], pool, seen)
    for block_idx in range(4):
        block_rows = [row for row in sorted_by_score if int(row["block_index"]) == block_idx]
        add_unique(block_rows[: max(10, int(size) // 20)], pool, seen)
    shuffled = list(one_rows)
    rng.shuffle(shuffled)
    add_unique(shuffled, pool, seen, limit=size)
    if len(pool) < int(size):
        add_unique(sorted_by_score, pool, seen, limit=size)
    return pool[: int(size)]


def abs_bal_tuple(row, modulus, keys):
    return tuple(balanced_abs(int(row[key]), modulus) for key in keys)


class Aggregate(object):
    def __init__(self, parent_score):
        self.count = 0
        self.conflict_skipped = 0
        self.duplicate_skipped = 0
        self.scores = []
        self.threshold_counts = {str(t): 0 for t in THRESHOLDS}
        self.improvement_count = 0
        self.zero_hist = {}
        self.best_score = None
        self.best_record = None
        self.parent_score = int(parent_score)

    def add(self, record):
        self.count += 1
        score = int(record["score"])
        self.scores.append(score)
        if self.best_score is None or score < self.best_score:
            self.best_score = score
            self.best_record = dict(record)
        if score < self.parent_score:
            self.improvement_count += 1
        for threshold in THRESHOLDS:
            if score <= threshold:
                self.threshold_counts[str(threshold)] += 1
        key = str(record.get("moment_zero_count_3", 0))
        self.zero_hist[key] = self.zero_hist.get(key, 0) + 1

    def add_basic(self, metrics_tuple):
        self.count += 1
        score = int(metrics_tuple[0])
        self.scores.append(score)
        if self.best_score is None or score < self.best_score:
            self.best_score = score
            self.best_record = {
                "score": int(metrics_tuple[0]),
                "l1_error": int(metrics_tuple[1]),
                "max_abs_error": int(metrics_tuple[2]),
                "nonzero_defect_count": int(metrics_tuple[3]),
            }
        if score < self.parent_score:
            self.improvement_count += 1
        for threshold in THRESHOLDS:
            if score <= threshold:
                self.threshold_counts[str(threshold)] += 1

    def summary(self):
        return {
            "evaluated_count": int(self.count),
            "conflict_skipped_count": int(self.conflict_skipped),
            "duplicate_skipped_count": int(self.duplicate_skipped),
            "best_score": int(self.best_score) if self.best_score is not None else None,
            "score_min": int(min(self.scores)) if self.scores else None,
            "score_p1": quantile(self.scores, 0.01),
            "score_p5": quantile(self.scores, 0.05),
            "score_p10": quantile(self.scores, 0.10),
            "score_median": quantile(self.scores, 0.50),
            "count_score_less_than_parent": int(self.improvement_count),
            "threshold_counts": self.threshold_counts,
            "moment_zero_count_3_histogram": self.zero_hist,
            "best_record": self.best_record,
        }


def make_result_payload(parent, result, depth, method_label):
    key = "{}:{}:{}".format(parent["id"], depth, json.dumps(moves_key(result["moves"])))
    return {
        "result_key": key,
        "parent_id": parent["id"],
        "parent_path": parent["path"],
        "depth": int(depth),
        "method": method_label,
        "moves": result["moves"],
        **compact_metrics(result["record"]),
        "_result": result,
        "_parent": parent,
    }


def update_frontiers(frontiers, parent, result, depth, method_label):
    payload = make_result_payload(parent, result, depth, method_label)
    frontiers["score"].add(
        (payload["score"], payload["l1_error"], payload["max_abs_error"], payload["nonzero_defect_count"], payload["result_key"]),
        payload,
    )
    frontiers["l1"].add(
        (payload["l1_error"], payload["score"], payload["max_abs_error"], payload["nonzero_defect_count"], payload["result_key"]),
        payload,
    )
    frontiers["max_abs"].add(
        (payload["max_abs_error"], payload["score"], payload["l1_error"], payload["nonzero_defect_count"], payload["result_key"]),
        payload,
    )
    frontiers["nonzero"].add(
        (payload["nonzero_defect_count"], payload["l1_error"], payload["score"], payload["max_abs_error"], payload["result_key"]),
        payload,
    )
    frontiers["moment"].add(
        (-payload["moment_zero_count_6"], payload["higher_moment_norm"], payload["score"], payload["result_key"]),
        payload,
    )


def frontier_gate(frontiers, parent, metrics_tuple):
    score, l1, max_abs, nonzero = [int(x) for x in metrics_tuple]
    parent_metrics = parent["metrics"]
    if score <= int(parent_metrics["score"]) + 120:
        return True
    if l1 <= int(parent_metrics["l1_error"]) + 36:
        return True
    if max_abs <= int(parent_metrics["max_abs_error"]):
        return True
    if nonzero <= int(parent_metrics["nonzero_defect_count"]) + 8:
        return True
    for keeper, rank in (
        (frontiers["score"], (score, l1, max_abs, nonzero, "")),
        (frontiers["l1"], (l1, score, max_abs, nonzero, "")),
        (frontiers["max_abs"], (max_abs, score, l1, nonzero, "")),
        (frontiers["nonzero"], (nonzero, l1, score, max_abs, "")),
    ):
        if len(keeper.items) < keeper.limit:
            return True
        if rank < keeper.items[-1][0]:
            return True
    return False


def record_if_notable(notable, parent, result, depth, method_label):
    score = int(result["record"]["score"])
    if notable_threshold(result["record"], parent["metrics"]["score"]):
        key = "{}:{}:{}".format(parent["id"], depth, json.dumps(moves_key(result["moves"])))
        notable[key] = {
            "parent": parent,
            "result": result,
            "depth": int(depth),
            "method": method_label,
            "reason": "threshold_or_parent_improvement",
        }
    return score == 0


def filtered_two_swap(parent, pool, pool_size, out_dir, frontiers, notable):
    out_path = os.path.join(out_dir, "filtered_2swap_{}_M{}.jsonl".format(parent["id"], pool_size))
    agg = Aggregate(parent["metrics"]["score"])
    seen = set()
    with open(out_path, "w") as f:
        for i in range(len(pool)):
            move_i = pool[i]["move"]
            for j in range(i + 1, len(pool)):
                moves = [move_i, pool[j]["move"]]
                key = moves_key(moves)
                if key in seen:
                    agg.duplicate_skipped += 1
                    continue
                seen.add(key)
                if not conflict_free_static(moves):
                    agg.conflict_skipped += 1
                    continue
                basic = apply_moves_basic(parent["v"], parent["blocks"], parent["counts"], parent["lambda"], moves)
                if basic is None:
                    agg.conflict_skipped += 1
                    continue
                agg.add_basic(basic["metrics_tuple"])
                if not frontier_gate(frontiers, parent, basic["metrics_tuple"]):
                    continue
                result = complete_basic_result(parent["v"], parent["lambda"], basic)
                row = row_from_result(parent, result, 2, "filtered_2swap_M{}".format(pool_size), include_moves=True)
                update_frontiers(frontiers, parent, result, 2, "filtered_2swap_M{}".format(pool_size))
                if notable_threshold(result["record"], parent["metrics"]["score"]) or len(frontiers["score"].items) < frontiers["score"].limit:
                    f.write(json.dumps(json_safe(row), sort_keys=True) + "\n")
                record_if_notable(notable, parent, result, 2, "filtered_2swap_M{}".format(pool_size))
    summary = agg.summary()
    summary["jsonl"] = out_path
    summary["move_pool_size"] = int(pool_size)
    return summary


def approx_move_delta(row):
    return {
        "score": int(row["delta_score"]),
        "l1": int(row["delta_l1"]),
        "max_abs": int(row["delta_max_abs"]),
        "nonzero": int(row["delta_nonzero"]),
        "moment3_abs": sum(balanced_abs(int(row[key]), 167) for key in ("T2", "T4", "T6")),
        "higher_norm": int(row["higher_moment_norm"]),
    }


def approximate_triple_candidates(parent, pool, screen_top, extend_limit, true_eval_limit):
    pair_states = []
    seen_pairs = set()
    for i in range(len(pool)):
        mi = pool[i]["move"]
        for j in range(i + 1, len(pool)):
            mj = pool[j]["move"]
            moves = [mi, mj]
            key = moves_key(moves)
            if key in seen_pairs or not conflict_free_static(moves):
                continue
            seen_pairs.add(key)
            score_delta = int(pool[i]["delta_score"]) + int(pool[j]["delta_score"])
            l1_delta = int(pool[i]["delta_l1"]) + int(pool[j]["delta_l1"])
            moment_abs = (
                sum(balanced_abs(int(pool[i][key]) + int(pool[j][key]), parent["v"]) for key in ("T2", "T4", "T6"))
            )
            pair_states.append((score_delta, l1_delta, moment_abs, i, j))
    pair_states.sort(key=lambda item: (item[0], item[1], item[2]))
    pair_states = pair_states[: int(screen_top)]
    move_order = sorted(
        range(len(pool)),
        key=lambda idx: (
            int(pool[idx]["delta_score"]),
            int(pool[idx]["delta_l1"]),
            int(pool[idx]["higher_moment_norm"]),
        ),
    )[: int(extend_limit)]
    triples = []
    seen_triples = set()
    for score_delta, l1_delta, moment_abs, i, j in pair_states:
        for k in move_order:
            if k == i or k == j:
                continue
            moves = [pool[i]["move"], pool[j]["move"], pool[k]["move"]]
            key = moves_key(moves)
            if key in seen_triples or not conflict_free_static(moves):
                continue
            seen_triples.add(key)
            approx_score = score_delta + int(pool[k]["delta_score"])
            approx_l1 = l1_delta + int(pool[k]["delta_l1"])
            approx_moment = moment_abs + sum(balanced_abs(int(pool[k][mk]), parent["v"]) for mk in ("T2", "T4", "T6"))
            triples.append((approx_score, approx_l1, approx_moment, key, moves))
            if len(triples) >= int(true_eval_limit) * 4:
                triples.sort(key=lambda item: (item[0], item[1], item[2], item[3]))
                del triples[int(true_eval_limit):]
    triples.sort(key=lambda item: (item[0], item[1], item[2], item[3]))
    return [moves for _s, _l, _m, _key, moves in triples[: int(true_eval_limit)]], {
        "pair_states_kept": int(len(pair_states)),
        "triple_candidates_screened": int(len(triples)),
    }


def filtered_three_swap(parent, pool, pool_size, args, out_dir, frontiers, notable):
    out_path = os.path.join(out_dir, "filtered_3swap_{}_M{}.jsonl".format(parent["id"], pool_size))
    triples, screen_stats = approximate_triple_candidates(
        parent,
        pool,
        args.triple_screen_top,
        args.triple_extend_limit,
        args.triple_true_eval,
    )
    agg = Aggregate(parent["metrics"]["score"])
    with open(out_path, "w") as f:
        for moves in triples:
            basic = apply_moves_basic(parent["v"], parent["blocks"], parent["counts"], parent["lambda"], moves)
            if basic is None:
                agg.conflict_skipped += 1
                continue
            agg.add_basic(basic["metrics_tuple"])
            if not frontier_gate(frontiers, parent, basic["metrics_tuple"]):
                continue
            result = complete_basic_result(parent["v"], parent["lambda"], basic)
            row = row_from_result(parent, result, 3, "filtered_3swap_M{}".format(pool_size), include_moves=True)
            update_frontiers(frontiers, parent, result, 3, "filtered_3swap_M{}".format(pool_size))
            if notable_threshold(result["record"], parent["metrics"]["score"]) or len(frontiers["score"].items) < frontiers["score"].limit:
                f.write(json.dumps(json_safe(row), sort_keys=True) + "\n")
            record_if_notable(notable, parent, result, 3, "filtered_3swap_M{}".format(pool_size))
    summary = agg.summary()
    summary["jsonl"] = out_path
    summary["move_pool_size"] = int(pool_size)
    summary.update(screen_stats)
    return summary


def parent_record(path, parent_id):
    data, v, n, ks, lam, blocks = load_candidate(path)
    counts = total_diff_counts(v, blocks)
    metrics_tuple = metrics_from_counts(counts, lam)
    record = evaluate_counts(counts, lam, v)
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
        "metrics_tuple": metrics_tuple,
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


def save_frontier_file(path, keeper, category):
    with open(path, "w") as f:
        for rank, payload in enumerate(keeper.records(), start=1):
            clean = {k: v for k, v in payload.items() if not k.startswith("_")}
            clean["rank"] = int(rank)
            clean["frontier_category"] = category
            f.write(json.dumps(json_safe(clean), sort_keys=True) + "\n")


def save_retained_candidates(frontiers, notable, out_dir):
    retained = {}
    for category, keeper in frontiers.items():
        for payload in keeper.records():
            retained[payload["result_key"]] = {
                "parent": payload["_parent"],
                "result": payload["_result"],
                "depth": payload["depth"],
                "method": payload["method"],
                "reason": "frontier_{}".format(category),
            }
    retained.update(notable)
    saved = []
    seen_hash = set()
    for idx, (key, item) in enumerate(sorted(retained.items()), start=1):
        parent = item["parent"]
        result = item["result"]
        path, payload = save_candidate(
            parent,
            result,
            item["depth"],
            item["method"],
            key,
            "{}_{}".format(parent["id"], idx),
        )
        duplicate = payload["canonical_hash"] in seen_hash
        seen_hash.add(payload["canonical_hash"])
        saved.append({
            "path": path,
            "reason": item["reason"],
            "duplicate_canonical_hash_in_saved_set": bool(duplicate),
            "score": int(payload["score"]),
            "l1_error": int(payload["l1_error"]),
            "max_abs_error": int(payload["max_abs_error"]),
            "nonzero_defect_count": int(payload["nonzero_defect_count"]),
            "moment_zero_count_3": int(payload["moment_zero_count_3"]),
            "moment_zero_count_6": int(payload["moment_zero_count_6"]),
            "canonical_hash": payload["canonical_hash"],
        })
    write_json(os.path.join(out_dir, "saved_candidate_index.json"), saved)
    return saved


def write_move_pool(path, pool):
    with open(path, "w") as f:
        for rank, item in enumerate(pool, start=1):
            clean = {key: item[key] for key in item if key not in ("delta",)}
            clean["rank"] = int(rank)
            f.write(json.dumps(json_safe(clean), sort_keys=True) + "\n")


def copy_text_file(src, dst):
    with open(src) as f_src, open(dst, "w") as f_dst:
        for line in f_src:
            f_dst.write(line)


def write_summary(out_dir, parents, summaries, saved_candidates, args):
    lines = []
    lines.append("# 668 Score-neighborhood Census Summary")
    lines.append("")
    lines.append("This is a local-neighborhood diagnostic for n=668 near-hits. No score-nonzero row is a Hadamard construction.")
    lines.append("")
    lines.append("## 428 Calibration")
    lines.append("")
    lines.append("| distance | score min | score median | note |")
    lines.append("|---:|---:|---:|---|")
    lines.append("| 1 | 48 | 104 | exact 428 after one swap; moments mostly nonzero |")
    lines.append("| 2 | 80 | 200 | excluding exact-return degeneracy |")
    lines.append("| 3 | 120 | 300 | sampled perturbations |")
    lines.append("| 4 | 168 | 392 | sampled perturbations |")
    lines.append("")
    lines.append("## Parents")
    lines.append("")
    for parent in parents:
        lines.append("- `{}`: path `{}`, metrics `{}`, moments `{}`, metrics_match `{}`".format(
            parent["id"],
            parent["path"],
            compact_metrics(parent["metrics"]),
            parent["metrics"]["padic_moments"],
            parent["metrics_match"],
        ))
    lines.append("")
    lines.append("## Main Results")
    lines.append("")
    for parent in parents:
        pid = parent["id"]
        lines.append("### {}".format(pid))
        lines.append("")
        one = summaries[pid]["one_swap"]
        lines.append("- full 1-swap local minimum: `{}`".format(one["is_one_swap_local_minimum"]))
        lines.append("- full 1-swap count score < parent: `{}`".format(one["count_score_less_than_parent"]))
        lines.append("- full 1-swap best score: `{}`".format(one["best_score"]))
        lines.append("- full 1-swap quantiles: min `{}`, p1 `{}`, p5 `{}`, p10 `{}`, median `{}`".format(
            one["score_min"], one["score_p1"], one["score_p5"], one["score_p10"], one["score_median"]
        ))
        lines.append("- full 1-swap threshold counts: `{}`".format(one["threshold_counts"]))
        for run in summaries[pid]["two_swap"]:
            lines.append("- 2-swap M={}: best `{}`, count score < parent `{}`, thresholds `{}`".format(
                run["move_pool_size"], run["best_score"], run["count_score_less_than_parent"], run["threshold_counts"]
            ))
        for run in summaries[pid]["three_swap"]:
            lines.append("- 3-swap M={}: best `{}`, count score < parent `{}`, thresholds `{}`, pair states `{}`, screened triples `{}`".format(
                run["move_pool_size"], run["best_score"], run["count_score_less_than_parent"], run["threshold_counts"],
                run.get("pair_states_kept"), run.get("triple_candidates_screened"),
            ))
        lines.append("")
    lines.append("## Saved Candidates")
    lines.append("")
    lines.append("Saved candidate JSON count: `{}`".format(len(saved_candidates)))
    for item in saved_candidates[:30]:
        lines.append("- `{}` score `{}` l1 `{}` max `{}` nonzero `{}` reason `{}`".format(
            item["path"], item["score"], item["l1_error"], item["max_abs_error"], item["nonzero_defect_count"], item["reason"]
        ))
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    for parent in parents:
        pid = parent["id"]
        one = summaries[pid]["one_swap"]
        two_improve = any(run["count_score_less_than_parent"] > 0 for run in summaries[pid]["two_swap"])
        three_improve = any(run["count_score_less_than_parent"] > 0 for run in summaries[pid]["three_swap"])
        all_best = [one["best_score"]]
        all_best.extend(run["best_score"] for run in summaries[pid]["two_swap"] if run["best_score"] is not None)
        all_best.extend(run["best_score"] for run in summaries[pid]["three_swap"] if run["best_score"] is not None)
        best = min(all_best)
        lines.append("- `{}`: 1-swap local min `{}`; 2-swap improvement `{}`; 3-swap improvement `{}`; best searched score `{}`.".format(
            pid, one["is_one_swap_local_minimum"], two_improve, three_improve, best
        ))
    lines.append("")
    lines.append("Threshold interpretation: score <=120/80/48 would match the 428 3/2/1-swap positive-control low-end scale. score=0 would trigger exact SDS and GS HH^T verification.")
    lines.append("")
    lines.append("## Safety")
    lines.append("")
    lines.append("- No Hadamard 668 construction is claimed here unless a score=0 candidate also passes exact SDS validation and Goethals-Seidel HH^T=668I over ZZ.")
    lines.append("- p-adic moments are diagnostics; 428 perturbation shows they are not a smooth proximity metric under ordinary swaps.")
    with open(os.path.join(out_dir, "swap_neighborhood_summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Census 1-3 swap neighborhoods around important v=167 near-hits.")
    parser.add_argument("--score164-path", default="")
    parser.add_argument("--score176-path", default="")
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--move-pool-sizes", default="500,1000")
    parser.add_argument("--triple-screen-top", type=int, default=200000)
    parser.add_argument("--triple-true-eval", type=int, default=50000)
    parser.add_argument("--triple-extend-limit", type=int, default=60)
    parser.add_argument("--seed", type=int, default=48)
    parser.add_argument("--skip-three-swap", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    out_dir = args.out_dir or os.path.join(
        "outputs",
        "explorations",
        "{}_hadamard668_score_neighborhood_census".format(now_stamp()),
    )
    ensure_dir(out_dir)
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        score164_path = args.score164_path or find_candidate_by_score(
            164,
            [
                "near_hit_v167_score164_steepest_swap_descent_round1.json",
                "near_hit_v167_score164_beam_two_swap_repair_round2.json",
            ],
        )
        score176_path = args.score176_path or find_candidate_by_score(
            176,
            [
                "near_hit_v167_score176_seed101_step8576.json",
                "near_hit_v167_score176_steepest_swap_descent_round1.json",
            ],
        )
        parents = [
            parent_record(score164_path, "score164"),
            parent_record(score176_path, "score176"),
        ]
        for parent in parents:
            print("Parent {} path={} metrics={} stored={} match={}".format(
                parent["id"], parent["path"], compact_metrics(parent["metrics"]), parent["stored_metrics"], parent["metrics_match"]
            ))
        move_pool_sizes = parse_int_list(args.move_pool_sizes, [500, 1000])
        run_config = {
            "script": SCRIPT_NAME,
            "out_dir": out_dir,
            "score164_path": score164_path,
            "score176_path": score176_path,
            "move_pool_sizes": move_pool_sizes,
            "triple_screen_top": int(args.triple_screen_top),
            "triple_true_eval": int(args.triple_true_eval),
            "triple_extend_limit": int(args.triple_extend_limit),
            "skip_three_swap": bool(args.skip_three_swap),
            "seed": int(args.seed),
        }
        write_json(os.path.join(out_dir, "run_config.json"), run_config)
        summaries = {}
        frontiers = {
            "score": TopKeeper(20),
            "l1": TopKeeper(20),
            "max_abs": TopKeeper(20),
            "nonzero": TopKeeper(20),
            "moment": TopKeeper(20),
        }
        notable = {}
        for parent in parents:
            pid = parent["id"]
            summaries[pid] = {"one_swap": None, "move_pools": {}, "two_swap": [], "three_swap": []}
            print("Running full 1-swap census for", pid)
            one_rows, one_summary = one_swap_census(parent, out_dir)
            summaries[pid]["one_swap"] = one_summary
            write_json(os.path.join(out_dir, "full_1swap_{}_summary.json".format(pid)), one_summary)
            for row in one_rows[:200]:
                # Seed frontiers from the best one-swap rows.
                result = apply_moves_true(parent["v"], parent["blocks"], parent["counts"], parent["lambda"], [row["move"]])
                if result is not None:
                    update_frontiers(frontiers, parent, result, 1, "full_1swap")
                    record_if_notable(notable, parent, result, 1, "full_1swap")
            for pool_index, pool_size in enumerate(move_pool_sizes):
                print("Building move pool parent={} M={}".format(pid, pool_size))
                pool = build_move_pool(one_rows, parent, pool_size, args.seed)
                pool_path = os.path.join(out_dir, "move_pool_{}_M{}.jsonl".format(pid, pool_size))
                write_move_pool(pool_path, pool)
                if pool_index == 0:
                    copy_text_file(pool_path, os.path.join(out_dir, "move_pool_{}.jsonl".format(pid)))
                summaries[pid]["move_pools"][str(pool_size)] = {"path": pool_path, "size": len(pool)}
                print("Running filtered 2-swap parent={} M={}".format(pid, pool_size))
                two_summary = filtered_two_swap(parent, pool, pool_size, out_dir, frontiers, notable)
                summaries[pid]["two_swap"].append(two_summary)
                write_json(os.path.join(out_dir, "filtered_2swap_{}_M{}_summary.json".format(pid, pool_size)), two_summary)
                if pool_index == 0:
                    copy_text_file(
                        two_summary["jsonl"],
                        os.path.join(out_dir, "filtered_2swap_{}.jsonl".format(pid)),
                    )
                if not args.skip_three_swap:
                    print("Running filtered 3-swap parent={} M={}".format(pid, pool_size))
                    three_summary = filtered_three_swap(parent, pool, pool_size, args, out_dir, frontiers, notable)
                    summaries[pid]["three_swap"].append(three_summary)
                    write_json(os.path.join(out_dir, "filtered_3swap_{}_M{}_summary.json".format(pid, pool_size)), three_summary)
                    if pool_index == 0:
                        copy_text_file(
                            three_summary["jsonl"],
                            os.path.join(out_dir, "filtered_3swap_{}.jsonl".format(pid)),
                        )
        for category, keeper in frontiers.items():
            save_frontier_file(os.path.join(out_dir, "frontier_best_by_{}.jsonl".format(category)), keeper, category)
        saved_candidates = save_retained_candidates(frontiers, notable, out_dir)
        write_json(os.path.join(out_dir, "neighborhood_summaries.json"), summaries)
        write_summary(out_dir, parents, summaries, saved_candidates, args)
        print("OUT_DIR:", out_dir)
        print("SUMMARY:", os.path.join(out_dir, "swap_neighborhood_summary.md"))
        score0 = [item for item in saved_candidates if int(item["score"]) == 0]
        if score0:
            print("WARNING: score=0 candidates saved. Run exact SDS and GS HH^T validation before any success claim:")
            for item in score0:
                print(item["path"])
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
