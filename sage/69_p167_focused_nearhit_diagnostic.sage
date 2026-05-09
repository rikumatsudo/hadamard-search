from sage.all import *

import argparse
import csv
import glob
import hashlib
import json
import math
import os
import random
import statistics
import time


SCRIPT_NAME = "69_p167_focused_nearhit_diagnostic"
P_DEFAULT = 167
N_DEFAULT = 668
KS_DEFAULT = (73, 78, 79, 81)
LAMBDA_DEFAULT = 144
DEFAULT_MODES = (
    "baseline_score_only_recheck",
    "focused_high_abs_rho",
    "focused_stubborn_defect",
    "focused_weighted_defect",
    "focused_plus_small_threshold",
    "focused_top_defect_pair",
    "focused_with_exactlike_guard",
)
DEFAULT_INPUT_ROOTS = (
    "configs/fixtures/p167_focused_nearhit_candidates.jsonl",
    "outputs/candidates/near_hits",
)
SCORE_BAND_ORDER = (
    "score164",
    "score176",
    "score180_184",
    "score188_192_200",
    "score216_228_232",
    "other",
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
    if value is None or isinstance(value, (str, bool)):
        return value
    if isinstance(value, int):
        return int(value)
    if isinstance(value, float):
        return float(value) if math.isfinite(float(value)) else None
    try:
        if hasattr(value, "is_integer") and value.is_integer():
            return int(value)
    except Exception:
        pass
    try:
        return float(value)
    except Exception:
        pass
    return str(value)


def public_row(row):
    return {key: json_safe(value) for key, value in row.items() if not str(key).startswith("_")}


def write_json(path, payload):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as f:
        json.dump(json_safe(payload), f, indent=2, sort_keys=True)
        f.write("\n")


def write_jsonl(path, rows):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(public_row(row), sort_keys=True) + "\n")


def csv_value(value):
    value = json_safe(value)
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True)
    if value is None:
        return ""
    return value


def write_csv(path, rows, fields=None):
    ensure_dir(os.path.dirname(path))
    if fields is None:
        fields = sorted(set().union(*(public_row(row).keys() for row in rows))) if rows else []
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


def maybe_int(value):
    if value is None or value == "":
        return None
    try:
        return int(value)
    except Exception:
        return None


def maybe_float(value):
    if value is None or value == "":
        return None
    try:
        return float(value)
    except Exception:
        return None


def parse_int_tuple(text):
    if isinstance(text, (list, tuple)):
        return tuple(int(x) for x in text)
    return tuple(int(x.strip()) for x in str(text).replace("[", "").replace("]", "").split(",") if x.strip())


def deterministic_seed(text):
    digest = hashlib.sha256(str(text).encode("utf-8")).hexdigest()
    return int(digest[:16], 16)


def make_rng(seed):
    return random.Random(int(seed))


def stable_raw_hash(blocks, p, ks):
    payload = {
        "p": int(p),
        "ks": [int(k) for k in ks],
        "blocks": [[int(x) for x in sorted(block)] for block in blocks],
    }
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def canonical_block_fast(block, p):
    values = sorted(int(x) % int(p) for x in block)
    if not values:
        return tuple()
    best = None
    for anchor in values:
        shift = (-int(anchor)) % int(p)
        translated = tuple(sorted((x + shift) % int(p) for x in values))
        if best is None or translated < best:
            best = translated
    return best


def canonical_hash_fast(blocks, p, ks):
    # Same equivalence class used by sds_repair_utils.canonical_hash, but with a
    # faster cyclic block normalization. This is for discovery/dedup only.
    p = int(p)
    ks = tuple(int(k) for k in ks)
    best = None
    for u in range(1, p):
        if gcd(u, p) != 1:
            continue
        normalized = []
        for block in blocks:
            normalized.append(canonical_block_fast([int(u) * int(x) % p for x in block], p))
        grouped = list(normalized)
        by_size = {}
        for idx, size in enumerate(ks):
            by_size.setdefault(int(size), []).append(idx)
        for indices in by_size.values():
            if len(indices) <= 1:
                continue
            sorted_blocks = sorted(grouped[idx] for idx in indices)
            for idx, block in zip(indices, sorted_blocks):
                grouped[idx] = block
        candidate = tuple(tuple(int(x) for x in block) for block in grouped)
        if best is None or candidate < best:
            best = candidate
    payload = {
        "v": p,
        "ks": [int(k) for k in ks],
        "blocks": [[int(x) for x in block] for block in best],
    }
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def json_blocks(blocks):
    return [[int(x) for x in sorted(block)] for block in blocks]


def clone_blocks(blocks):
    return [set(int(x) for x in block) for block in blocks]


def blocks_from_payload(payload):
    raw = payload.get("blocks") or payload.get("X") or payload.get("sets")
    if not isinstance(raw, list) or len(raw) != 4:
        return None
    try:
        return [set(int(x) for x in block) for block in raw]
    except Exception:
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
                        payload["_source_file"] = path
                        yield payload
        elif path.endswith(".json"):
            with open(path) as f:
                payload = json.load(f)
            rows = []
            if isinstance(payload, dict):
                rows.append(payload)
                for key in ("rows", "candidates", "results", "parents", "near_hits"):
                    if isinstance(payload.get(key), list):
                        rows.extend(item for item in payload[key] if isinstance(item, dict))
            elif isinstance(payload, list):
                rows.extend(item for item in payload if isinstance(item, dict))
            for row in rows:
                row["_source_file"] = path
                yield row
    except Exception:
        return


def candidate_files(roots):
    files = []
    for root in roots:
        if not root:
            continue
        root = os.path.abspath(root)
        if os.path.isfile(root) and (root.endswith(".json") or root.endswith(".jsonl")):
            files.append(root)
            continue
        if not os.path.isdir(root):
            continue
        for path in glob.glob(os.path.join(root, "**", "*.json"), recursive=True):
            files.append(path)
        for path in glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True):
            files.append(path)
    return sorted(set(files))


def payload_target_ok(payload, p, n, ks, lam):
    got_p = payload.get("p", payload.get("v"))
    if got_p is not None and int(got_p) != int(p):
        return False
    got_n = payload.get("n")
    if got_n is not None and int(got_n) != int(n):
        return False
    got_ks = payload.get("ks")
    if got_ks is not None and parse_int_tuple(got_ks) != tuple(int(x) for x in ks):
        return False
    got_lam = payload.get("lambda", payload.get("lam"))
    if got_lam is not None and int(got_lam) != int(lam):
        return False
    return True


def source_method(payload, path):
    text = " ".join(
        str(payload.get(key, ""))
        for key in ("source_method", "search_method", "method", "mode", "strategy", "origin", "source", "label")
    ).lower()
    text = text + " " + str(path).lower()
    if "ilp" in text:
        return "ILP"
    if "beam" in text:
        return "beam"
    if "repair" in text or "2swap" in text or "multiswap" in text:
        return "repair"
    if "steepest" in text:
        return "steepest"
    if "seed" in text or payload.get("seed") is not None:
        return "seed"
    return "unknown"


def score_band(score):
    score = int(score)
    if score == 164:
        return "score164"
    if score == 176:
        return "score176"
    if score in (180, 184):
        return "score180_184"
    if score in (188, 192, 200):
        return "score188_192_200"
    if score in (216, 228, 232):
        return "score216_228_232"
    return "other"


def score_band_rank(score):
    band = score_band(score)
    return SCORE_BAND_ORDER.index(band) if band in SCORE_BAND_ORDER else 99


def total_diff_counts(p, blocks):
    counts = [0 for _ in range(p)]
    for block in blocks:
        values = [int(x) % p for x in block]
        for x in values:
            for y in values:
                if x != y:
                    counts[(x - y) % p] += 1
    return counts


def rho_vector(counts, lam):
    return [0] + [int(counts[d]) - int(lam) for d in range(1, len(counts))]


def score_counts(counts, lam):
    return int(sum((int(counts[d]) - int(lam)) ** 2 for d in range(1, len(counts))))


def apply_sparse_delta(counts, delta):
    out = list(counts)
    for d, value in delta.items():
        out[int(d)] += int(value)
    return out


def apply_move(blocks, move):
    out = clone_blocks(blocks)
    block_idx = int(move["block"])
    removed = int(move["removed"])
    added = int(move["added"])
    if removed not in out[block_idx] or added in out[block_idx]:
        return None
    out[block_idx].remove(removed)
    out[block_idx].add(added)
    return out


def support_from_rho(rho):
    return set(d for d in range(1, len(rho)) if int(rho[d]) != 0)


def sign_vector(rho):
    signs = [0] * len(rho)
    for d in range(1, len(rho)):
        signs[d] = 1 if int(rho[d]) > 0 else (-1 if int(rho[d]) < 0 else 0)
    return signs


def pair_key(d, p):
    e = (-int(d)) % int(p)
    return [int(x) for x in sorted([int(d), int(e)])]


def rho_shape_metrics(rho):
    support = sorted(support_from_rho(rho))
    values = [int(rho[d]) for d in support]
    S = int(sum(value * value for value in values))
    value_counts = {}
    for value in values:
        value_counts[str(value)] = value_counts.get(str(value), 0) + 1
    value_counts = {key: value_counts[key] for key in sorted(value_counts, key=lambda x: int(x))}
    support_size = len(support)
    pm1_count = sum(1 for value in values if abs(value) == 1)
    return {
        "S": S,
        "support_size": int(support_size),
        "support_fraction": float(support_size) / float(max(1, len(rho) - 1)),
        "S_over_support": float(S) / float(support_size) if support_size else None,
        "max_abs_rho": max([abs(value) for value in values]) if values else 0,
        "pm1_fraction": float(pm1_count) / float(support_size) if support_size else None,
        "value_counts": value_counts,
        "defect_support": support,
    }


def delta_sparse(p, block, removed, added):
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


def make_move(blocks, counts, rho, lam, p, block_idx, removed, added):
    block_idx = int(block_idx)
    removed = int(removed)
    added = int(added)
    if removed not in blocks[block_idx] or added in blocks[block_idx]:
        return None
    delta = delta_sparse(p, blocks[block_idx], removed, added)
    q = int(sum(int(v) * int(v) for v in delta.values()))
    if q <= 0:
        return None
    g = int(sum(int(rho[d]) * int(v) for d, v in delta.items()))
    h = int(2 * g + q)
    kappa = float(-2 * g) / float(q)
    added_support = 0
    removed_support = 0
    delta_support = 0
    for d, dv in delta.items():
        before = int(rho[d])
        after = before + int(dv)
        delta_support += 1
        if before == 0 and after != 0:
            added_support += 1
        if before != 0 and after == 0:
            removed_support += 1
    return {
        "block": block_idx,
        "removed": removed,
        "added": added,
        "delta": delta,
        "g": int(g),
        "q": int(q),
        "h": int(h),
        "score_after": int(score_counts(counts, lam) + h),
        "kappa": float(kappa),
        "added_support_count": int(added_support),
        "removed_support_count": int(removed_support),
        "new_support_fraction": float(added_support) / float(max(1, delta_support)),
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
    out = []
    seen = set()
    sample_swaps = max(1, int(sample_swaps))
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
                            tries = min(10, len(outside))
                            for added in rng.sample(outside, tries):
                                add_move_unique(out, seen, blocks, counts, rho, lam, p, block_idx, x, added)
                elif int(rho[d]) < 0:
                    for y in list(block):
                        for added in ((y + d) % p, (y - d) % p):
                            if added in block:
                                continue
                            removals = list(block)
                            rng.shuffle(removals)
                            for removed in removals[: min(10, len(removals))]:
                                add_move_unique(out, seen, blocks, counts, rho, lam, p, block_idx, removed, added)
                if len(out) >= sample_swaps:
                    return out[:sample_swaps]
    max_tries = max(sample_swaps * 10, 200)
    tries = 0
    while len(out) < sample_swaps and tries < max_tries:
        tries += 1
        block_idx = rng.randrange(len(blocks))
        block = blocks[block_idx]
        if len(block) == 0 or len(block) == p:
            continue
        removed = rng.choice(tuple(block))
        added = rng.randrange(p)
        if added in block:
            continue
        add_move_unique(out, seen, blocks, counts, rho, lam, p, block_idx, removed, added)
    out.sort(key=lambda move: (int(move["h"]), -float(move["kappa"]), -int(move["removed_support_count"])))
    return out[:sample_swaps]


def weighted_choice(items, weights, rng):
    if not items:
        return None
    total = sum(max(0.0, float(weight)) for weight in weights)
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


def top_defect_pair_target(rho, p, rng):
    pairs = []
    seen = set()
    for d in range(1, p):
        if d in seen:
            continue
        pair = pair_key(d, p)
        seen.update(pair)
        weight = abs(int(rho[pair[0]])) + abs(int(rho[pair[1]]))
        if weight > 0:
            pairs.append((pair, weight))
    if not pairs:
        return None
    pairs.sort(key=lambda item: (-item[1], item[0]))
    top = pairs[: min(12, len(pairs))]
    return weighted_choice([item[0] for item in top], [item[1] for item in top], rng)


def initialize_weights(rho):
    return [1.0 + 0.5 * abs(int(rho[d])) for d in range(len(rho))]


def update_weights(weights, rho, previous_signs):
    cur = sign_vector(rho)
    stubborn = 0
    for d in range(1, len(weights)):
        weights[d] = max(0.05, 0.98 * float(weights[d]))
        if int(rho[d]) != 0:
            weights[d] += 0.15 * abs(int(rho[d]))
        if previous_signs and cur[d] != 0 and cur[d] == previous_signs[d]:
            weights[d] += 0.2
            stubborn += 1
    return stubborn


def choose_target(mode, rho, signs_history, weights, rng, restart_id):
    p = len(rho)
    if mode == "baseline_score_only_recheck":
        return None
    if mode == "focused_stubborn_defect":
        lag = 50 if int(restart_id) % 2 == 0 else 100
        cur = sign_vector(rho)
        old = signs_history[-lag - 1] if len(signs_history) > lag else (signs_history[0] if signs_history else cur)
        stubborn = [d for d in range(1, p) if cur[d] != 0 and cur[d] == old[d]]
        if stubborn:
            d = weighted_choice(stubborn, [abs(int(rho[x])) for x in stubborn], rng)
            return {"target_d": int(d), "target_pair": pair_key(d, p), "target_selection_reason": "stubborn_sign_lag"}
        d = high_abs_target(rho, rng, alpha=2.0)
        return None if d is None else {"target_d": int(d), "target_pair": pair_key(d, p), "target_selection_reason": "fallback_high_abs_rho"}
    if mode == "focused_weighted_defect":
        support = sorted(support_from_rho(rho))
        if support:
            d = weighted_choice(support, [float(weights[x]) * abs(int(rho[x])) for x in support], rng)
            return {"target_d": int(d), "target_pair": pair_key(d, p), "target_selection_reason": "weighted_abs_rho"}
    if mode == "focused_top_defect_pair":
        pair = top_defect_pair_target(rho, p, rng)
        if pair:
            return {"target_d": int(pair[0]), "target_pair": pair, "target_selection_reason": "top_defect_pair"}
    alpha = 1.0 if int(restart_id) % 2 == 0 else 2.0
    d = high_abs_target(rho, rng, alpha=alpha)
    return None if d is None else {"target_d": int(d), "target_pair": pair_key(d, p), "target_selection_reason": "high_abs_rho_alpha_{}".format(int(alpha))}


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
        if old < 0 and new > old:
            signed_hits += 1
    d0 = int(target_pair[0])
    return int(old_abs - new_abs), int(signed_hits), int(rho[d0]), int(rho[d0] + move["delta"].get(d0, 0))


def quantile(values, q):
    values = sorted(float(v) for v in values if v is not None)
    if not values:
        return None
    if len(values) == 1:
        return values[0]
    pos = (len(values) - 1) * float(q)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return values[lo]
    return values[lo] * (hi - pos) + values[hi] * (pos - lo)


def diagnostic_from_moves(score, moves):
    score = int(score)
    if not moves:
        return {
            "D_min_1": None,
            "D_min_ratio": None,
            "h_min": None,
            "P_8": None,
            "P_16": None,
            "P_32": None,
            "P_thetaS_001": None,
            "P_thetaS_005": None,
            "P_thetaS_010": None,
            "kappa_max": None,
            "kappa_q90": None,
            "kappa_q99": None,
            "diagnostic_evaluated_moves": 0,
        }
    h_values = [int(move["h"]) for move in moves]
    kappas = [float(move["kappa"]) for move in moves if move.get("kappa") is not None]
    h_min = min(h_values)
    def p_threshold(limit):
        return float(sum(1 for h in h_values if h <= int(limit))) / float(len(h_values))
    def p_theta(theta):
        return float(sum(1 for h in h_values if score + h <= float(theta) * float(score))) / float(len(h_values)) if score > 0 else None
    return {
        "D_min_1": int(score + h_min),
        "D_min_ratio": float(score + h_min) / float(score) if score > 0 else None,
        "h_min": int(h_min),
        "P_8": p_threshold(8),
        "P_16": p_threshold(16),
        "P_32": p_threshold(32),
        "P_thetaS_001": p_theta(0.01),
        "P_thetaS_005": p_theta(0.05),
        "P_thetaS_010": p_theta(0.10),
        "kappa_max": max(kappas) if kappas else None,
        "kappa_q90": quantile(kappas, 0.90),
        "kappa_q99": quantile(kappas, 0.99),
        "diagnostic_evaluated_moves": int(len(moves)),
    }


def alignment_from_moves(score, rho, moves):
    S = int(score)
    if S <= 0 or not moves:
        return {
            "best_alignment_to_minus_rho": None,
            "best_alignment_move_deltaS": None,
            "best_alignment_move_kappa": None,
            "best_alignment_move_added_support_count": None,
            "best_alignment_move_removed_support_count": None,
            "best_alignment_move_new_support_fraction": None,
        }
    norm_rho = math.sqrt(float(S))
    best_key = None
    best_row = None
    for move in moves:
        q = int(move["q"])
        if q <= 0:
            continue
        g = int(move["g"])
        alignment = float(-g) / (math.sqrt(float(q)) * norm_rho)
        key = (
            float(alignment),
            float(move["kappa"]),
            int(move["removed_support_count"]),
            -int(move["added_support_count"]),
            -int(move["h"]),
        )
        if best_key is None or key > best_key:
            best_key = key
            best_row = {
                "best_alignment_to_minus_rho": float(alignment),
                "best_alignment_move_deltaS": int(move["h"]),
                "best_alignment_move_kappa": float(move["kappa"]),
                "best_alignment_move_added_support_count": int(move["added_support_count"]),
                "best_alignment_move_removed_support_count": int(move["removed_support_count"]),
                "best_alignment_move_new_support_fraction": float(move["new_support_fraction"]),
            }
    if best_row is None:
        return {
            "best_alignment_to_minus_rho": None,
            "best_alignment_move_deltaS": None,
            "best_alignment_move_kappa": None,
            "best_alignment_move_added_support_count": None,
            "best_alignment_move_removed_support_count": None,
            "best_alignment_move_new_support_fraction": None,
        }
    return best_row


def closure_shell_score(metrics):
    S_over = metrics.get("S_over_support")
    pm1 = metrics.get("pm1_fraction")
    max_abs = metrics.get("max_abs_rho")
    dmin_ratio = metrics.get("D_min_ratio")
    kappa = metrics.get("kappa_q99") if metrics.get("kappa_q99") is not None else metrics.get("kappa_max")
    alignment = metrics.get("best_alignment_to_minus_rho")
    new_support = metrics.get("best_alignment_move_new_support_fraction")
    c_shape = 0.0 if S_over is None else max(0.0, 1.0 - min(1.0, abs(float(S_over) - 1.0)))
    c_pm1 = 0.0 if pm1 is None else max(0.0, min(1.0, float(pm1)))
    c_max_abs = 1.0 if max_abs == 1 else (0.0 if not max_abs else min(1.0, 1.0 / float(max_abs)))
    c_dmin = 0.0 if dmin_ratio is None else max(0.0, 1.0 - min(1.0, float(dmin_ratio)))
    c_kappa = 0.0 if kappa is None else max(0.0, min(1.0, float(kappa) / 2.0))
    c_align = 0.0 if alignment is None else max(0.0, min(1.0, float(alignment)))
    penalty = 0.0 if new_support is None else max(0.0, min(1.0, float(new_support)))
    total = c_shape + c_pm1 + c_max_abs + c_dmin + c_kappa + c_align - penalty
    return {
        "closure_shell_score": float(total),
        "closure_component_S_over_support": float(c_shape),
        "closure_component_pm1_fraction": float(c_pm1),
        "closure_component_max_abs": float(c_max_abs),
        "closure_component_D_min_ratio": float(c_dmin),
        "closure_component_kappa": float(c_kappa),
        "closure_component_alignment": float(c_align),
        "closure_penalty_new_support": float(penalty),
    }


def state_metrics(blocks, counts, lam, p, rng, diagnostic_samples, initial_support=None):
    rho = rho_vector(counts, lam)
    score = score_counts(counts, lam)
    moves = sample_swap_moves(blocks, counts, rho, lam, p, rng, int(diagnostic_samples), None)
    out = rho_shape_metrics(rho)
    out.update(diagnostic_from_moves(score, moves))
    out.update(alignment_from_moves(score, rho, moves))
    out.update(closure_shell_score(out))
    support = support_from_rho(rho)
    if initial_support is not None:
        union = initial_support.union(support)
        out["persistent_defect_fraction"] = float(len(initial_support.intersection(support))) / float(len(initial_support)) if initial_support else None
        out["defect_support_turnover"] = float(len(support - initial_support)) / float(max(1, len(support)))
        out["defect_support_jaccard_turnover"] = float(len(union - initial_support.intersection(support))) / float(max(1, len(union)))
    return out


def collect_candidates(args, roots):
    p = int(args.p)
    n = int(args.n)
    ks = tuple(int(x) for x in args.ks)
    lam = int(args.lam)
    max_score = int(args.max_score)
    raw = {}
    files = candidate_files(roots)
    for idx, path in enumerate(files):
        for payload in iter_payloads_from_file(path):
            if not payload_target_ok(payload, p, n, ks, lam):
                continue
            stored_score = maybe_int(payload.get("score"))
            if stored_score is not None and stored_score > max_score:
                continue
            blocks = blocks_from_payload(payload)
            if not validate_blocks(blocks, p, ks):
                continue
            score = stored_score
            if score is None or not bool(args.trust_stored_score):
                score = score_counts(total_diff_counts(p, blocks), lam)
            if int(score) > max_score:
                continue
            raw_hash = stable_raw_hash(blocks, p, ks)
            if raw_hash in raw:
                continue
            canonical = payload.get("canonical_hash") or payload.get("hash")
            if not canonical:
                canonical = canonical_hash_fast(blocks, p, ks) if bool(args.canonical_dedupe) else raw_hash
            raw[raw_hash] = {
                "candidate_hash": str(canonical),
                "raw_block_hash": raw_hash,
                "canonical_hash_kind": "fast_multiplier_translate" if bool(args.canonical_dedupe) or payload.get("canonical_hash") else "raw_sorted_blocks",
                "source_file": os.path.relpath(path, os.getcwd()),
                "source_method": source_method(payload, path),
                "score": int(score),
                "score_band": score_band(score),
                "tuple": [int(k) for k in ks],
                "lambda": int(lam),
                "p": int(p),
                "n": int(n),
                "seed": payload.get("seed"),
                "step": payload.get("step"),
                "label": payload.get("label") or payload.get("origin") or payload.get("search_method"),
                "blocks": json_blocks(blocks),
            }
        if (idx + 1) % 5000 == 0:
            print("candidate files scanned", idx + 1, "/", len(files), "raw", len(raw))
    return select_candidates(list(raw.values()), int(args.max_candidates), int(args.seed_base))


def select_candidates(items, max_candidates, seed):
    by_hash = {}
    for item in items:
        by_hash.setdefault(item["candidate_hash"], item)
    items = list(by_hash.values())
    items.sort(key=lambda row: (score_band_rank(row["score"]), int(row["score"]), row.get("source_file") or "", row["candidate_hash"]))
    buckets = {band: [] for band in SCORE_BAND_ORDER}
    for item in items:
        buckets.setdefault(score_band(item["score"]), []).append(item)
    caps = {
        "score164": 10 ** 9,
        "score176": 10 ** 9,
        "score180_184": 40,
        "score188_192_200": 45,
        "score216_228_232": 30,
        "other": 0,
    }
    selected = []
    for band in SCORE_BAND_ORDER:
        selected.extend(buckets.get(band, [])[: caps.get(band, 0)])
    if len(selected) > max_candidates:
        selected = sorted(selected, key=lambda row: (score_band_rank(row["score"]), int(row["score"]), row["candidate_hash"]))[:max_candidates]
    elif len(selected) < max_candidates:
        used = set(row["candidate_hash"] for row in selected)
        rest = [row for row in items if row["candidate_hash"] not in used]
        selected.extend(rest[: max_candidates - len(selected)])
    return selected[:max_candidates]


def threshold_for_restart(mode, restart_id):
    if mode == "focused_plus_small_threshold":
        return (4, 8, 16, 32)[int(restart_id) % 4]
    if mode == "focused_with_exactlike_guard":
        return 64
    return 32


def choose_move(mode, blocks, counts, lam, p, weights, signs_history, rng, restart_id, args, old_diag):
    rho = rho_vector(counts, lam)
    score = score_counts(counts, lam)
    target = choose_target(mode, rho, signs_history, weights, rng, restart_id)
    target_pair = target.get("target_pair") if target else None
    moves = sample_swap_moves(blocks, counts, rho, lam, p, rng, int(args.sample_swaps), target_pair)
    local_diag = diagnostic_from_moves(score, moves)
    if not moves:
        return None, local_diag, target, rho
    if mode == "baseline_score_only_recheck":
        for move in moves:
            if int(move["h"]) < 0:
                return move, local_diag, target, rho
        return None, local_diag, target, rho
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
        key=lambda move: (
            -int(move["target_improvement"]),
            -int(move["target_signed_hits"]),
            int(move["h"]),
            -float(move["kappa"]),
            -float(move["target_weight"]),
            -int(move["removed_support_count"]),
        )
    )
    threshold = threshold_for_restart(mode, restart_id)
    for move in evaluated:
        if int(move["target_improvement"]) <= 0:
            continue
        if mode == "focused_with_exactlike_guard":
            if int(move["h"]) > threshold:
                continue
            if old_diag and old_diag.get("D_min_ratio") is not None and local_diag.get("D_min_ratio") is not None:
                if float(local_diag["D_min_ratio"]) > float(old_diag["D_min_ratio"]) + 0.25:
                    continue
            if old_diag and old_diag.get("P_16") is not None and local_diag.get("P_16") is not None:
                if float(local_diag["P_16"]) < 0.5 * float(old_diag["P_16"]):
                    continue
            return move, local_diag, target, rho
        if int(move["h"]) <= threshold:
            return move, local_diag, target, rho
    for move in evaluated:
        if int(move["target_improvement"]) >= 0 and int(move["h"]) < 0:
            return move, local_diag, target, rho
    return None, local_diag, target, rho


def improvement_flags(parent_metrics, best_metrics, best_alignment_metrics, best_shell_metrics, parent_score, best_score, final_score):
    dmin_improved = parent_metrics.get("D_min_ratio") is not None and best_metrics.get("D_min_ratio") is not None and float(best_metrics["D_min_ratio"]) < float(parent_metrics["D_min_ratio"])
    p16_improved = parent_metrics.get("P_16") is not None and best_metrics.get("P_16") is not None and float(best_metrics["P_16"]) > float(parent_metrics["P_16"])
    p32_improved = parent_metrics.get("P_32") is not None and best_metrics.get("P_32") is not None and float(best_metrics["P_32"]) > float(parent_metrics["P_32"])
    kappa_improved = parent_metrics.get("kappa_q99") is not None and best_metrics.get("kappa_q99") is not None and float(best_metrics["kappa_q99"]) > float(parent_metrics["kappa_q99"])
    alignment_improved = parent_metrics.get("best_alignment_to_minus_rho") is not None and best_alignment_metrics.get("best_alignment_to_minus_rho") is not None and float(best_alignment_metrics["best_alignment_to_minus_rho"]) > float(parent_metrics["best_alignment_to_minus_rho"])
    shell_improved = parent_metrics.get("closure_shell_score") is not None and best_shell_metrics.get("closure_shell_score") is not None and float(best_shell_metrics["closure_shell_score"]) > float(parent_metrics["closure_shell_score"])
    exactlike = bool(dmin_improved or p16_improved or p32_improved or kappa_improved)
    damage = bool(final_score > parent_score + 64)
    if parent_metrics.get("P_16") is not None and best_metrics.get("P_16") is not None:
        damage = damage or float(best_metrics["P_16"]) < 0.5 * float(parent_metrics["P_16"])
    if parent_metrics.get("kappa_q99") is not None and best_metrics.get("kappa_q99") is not None:
        damage = damage or float(best_metrics["kappa_q99"]) < float(parent_metrics["kappa_q99"]) - 0.25
    return {
        "score_improvement_seen": bool(best_score < parent_score),
        "exactlike_improvement_seen": exactlike,
        "alignment_improvement_seen": bool(alignment_improved),
        "closure_shell_improvement_seen": bool(shell_improved),
        "dmin_improvement_seen": bool(dmin_improved),
        "P_16_improvement_seen": bool(p16_improved),
        "P_32_improvement_seen": bool(p32_improved),
        "kappa_q99_improvement_seen": bool(kappa_improved),
        "damage_seen": bool(damage),
    }


def run_attempt(candidate, mode, restart_id, args):
    p = int(args.p)
    lam = int(args.lam)
    seed = int(int(args.seed_base) + int(deterministic_seed("{}:{}:{}".format(candidate["candidate_hash"], mode, restart_id)) % 1000000007))
    rng = make_rng(seed)
    blocks = clone_blocks(candidate["blocks"])
    counts = total_diff_counts(p, blocks)
    rho = rho_vector(counts, lam)
    initial_support = support_from_rho(rho)
    parent_score = score_counts(counts, lam)
    parent_metrics = state_metrics(blocks, counts, lam, p, make_rng(seed + 11), int(args.diagnostic_samples), initial_support)
    weights = initialize_weights(rho)
    signs_history = [sign_vector(rho)]
    snapshot_accepteds = set(int(x) for x in args.snapshot_accepted.split(",") if str(x).strip())
    accepted = 0
    no_move_streak = 0
    best_score = parent_score
    best_blocks = clone_blocks(blocks)
    best_counts = list(counts)
    best_metrics = dict(parent_metrics)
    best_alignment_metrics = dict(parent_metrics)
    best_shell_metrics = dict(parent_metrics)
    best_alignment_value = parent_metrics.get("best_alignment_to_minus_rho")
    best_shell_value = parent_metrics.get("closure_shell_score")
    target_improve_count = 0
    target_attempt_count = 0
    temporary_max_score = parent_score
    snapshots = []
    last_target = {}
    last_diag = parent_metrics
    stubborn_count = 0

    def emit_snapshot(kind, step):
        metrics = state_metrics(blocks, counts, lam, p, make_rng(seed + 1000 + accepted * 17 + step), int(args.diagnostic_samples), initial_support)
        row = {
            "snapshot_kind": kind,
            "candidate_hash": candidate["candidate_hash"],
            "candidate_hash12": candidate["candidate_hash"][:12],
            "mode": mode,
            "restart_id": int(restart_id),
            "step": int(step),
            "accepted_moves": int(accepted),
            "S": int(metrics["S"]),
            "best_S": int(best_score),
            "target_d": last_target.get("target_d"),
            "target_pair": last_target.get("target_pair"),
            "target_selection_reason": last_target.get("target_selection_reason"),
            "target_rho_old": last_target.get("target_rho_old"),
            "target_rho_new": last_target.get("target_rho_new"),
            "target_improved": bool(last_target.get("target_improved", False)),
            "target_defect_improvement_rate": float(target_improve_count) / float(target_attempt_count) if target_attempt_count else None,
            "temporary_max_score": int(temporary_max_score),
            "stubborn_count": int(stubborn_count),
        }
        row.update({key: value for key, value in metrics.items() if key != "defect_support"})
        snapshots.append(row)
        return row

    emit_snapshot("initial", 0)
    for step in range(1, int(args.steps) + 1):
        if mode == "focused_weighted_defect":
            previous = signs_history[-1] if signs_history else None
            stubborn_count = update_weights(weights, rho_vector(counts, lam), previous)
        move, local_diag, target, rho = choose_move(mode, blocks, counts, lam, p, weights, signs_history, rng, restart_id, args, last_diag)
        last_diag = local_diag
        if target:
            last_target.update(target)
        if move is None:
            no_move_streak += 1
            signs_history.append(sign_vector(rho))
            if int(args.no_move_patience) > 0 and no_move_streak >= int(args.no_move_patience):
                break
            continue
        next_blocks = apply_move(blocks, move)
        if next_blocks is None:
            no_move_streak += 1
            continue
        if target:
            target_attempt_count += 1
            improved = int(move.get("target_improvement", 0)) > 0
            if improved:
                target_improve_count += 1
            last_target.update(
                {
                    "target_rho_old": move.get("target_rho_old"),
                    "target_rho_new": move.get("target_rho_new"),
                    "target_improved": bool(improved),
                }
            )
        blocks = next_blocks
        counts = apply_sparse_delta(counts, move["delta"])
        accepted += 1
        no_move_streak = 0
        current_score = score_counts(counts, lam)
        temporary_max_score = max(int(temporary_max_score), int(current_score))
        signs_history.append(sign_vector(rho_vector(counts, lam)))
        if current_score < best_score:
            best_score = int(current_score)
            best_blocks = clone_blocks(blocks)
            best_counts = list(counts)
            best_metrics = state_metrics(best_blocks, best_counts, lam, p, make_rng(seed + 2000 + accepted), int(args.diagnostic_samples), initial_support)
        current_metrics_light = None
        if accepted in snapshot_accepteds:
            current_metrics_light = emit_snapshot("scheduled", step)
        if current_metrics_light is None and (accepted % 25 == 0):
            current_metrics_light = state_metrics(blocks, counts, lam, p, make_rng(seed + 3000 + accepted), int(args.diagnostic_samples), initial_support)
        if current_metrics_light:
            align_value = current_metrics_light.get("best_alignment_to_minus_rho")
            shell_value = current_metrics_light.get("closure_shell_score")
            if align_value is not None and (best_alignment_value is None or float(align_value) > float(best_alignment_value)):
                best_alignment_value = align_value
                best_alignment_metrics = dict(current_metrics_light)
            if shell_value is not None and (best_shell_value is None or float(shell_value) > float(best_shell_value)):
                best_shell_value = shell_value
                best_shell_metrics = dict(current_metrics_light)
        if current_score == 0:
            emit_snapshot("score0", step)
            break

    final_score = score_counts(counts, lam)
    final_metrics = state_metrics(blocks, counts, lam, p, make_rng(seed + 9999), int(args.diagnostic_samples), initial_support)
    emit_snapshot("final", int(args.steps))
    flags = improvement_flags(parent_metrics, best_metrics, best_alignment_metrics, best_shell_metrics, parent_score, best_score, final_score)
    final_label = "neutral"
    if flags["score_improvement_seen"]:
        final_label = "score_improved"
    elif flags["exactlike_improvement_seen"] or flags["alignment_improvement_seen"] or flags["closure_shell_improvement_seen"]:
        final_label = "diagnostic_improved"
    elif flags["damage_seen"]:
        final_label = "damaged"
    attempt = {
        "candidate_hash": candidate["candidate_hash"],
        "candidate_hash12": candidate["candidate_hash"][:12],
        "source_file": candidate.get("source_file"),
        "source_method": candidate.get("source_method"),
        "score_band": candidate.get("score_band"),
        "tuple": candidate.get("tuple"),
        "lambda": candidate.get("lambda"),
        "parent_score": int(parent_score),
        "score_per_p": float(parent_score) / float(p),
        "mode": mode,
        "restart_id": int(restart_id),
        "accepted_moves": int(accepted),
        "best_score": int(best_score),
        "best_score_delta": int(best_score - parent_score),
        "final_score": int(final_score),
        "final_label": final_label,
        "best_D_min_ratio": best_metrics.get("D_min_ratio"),
        "best_P_16": best_metrics.get("P_16"),
        "best_P_32": best_metrics.get("P_32"),
        "best_kappa_max": best_metrics.get("kappa_max"),
        "best_kappa_q99": best_metrics.get("kappa_q99"),
        "best_Q_ratio": None,
        "best_alignment_to_minus_rho": best_alignment_metrics.get("best_alignment_to_minus_rho"),
        "best_closure_shell_score": best_shell_metrics.get("closure_shell_score"),
        "best_D_min_ratio_delta": delta(parent_metrics.get("D_min_ratio"), best_metrics.get("D_min_ratio")),
        "best_P_16_delta": delta(parent_metrics.get("P_16"), best_metrics.get("P_16")),
        "best_P_32_delta": delta(parent_metrics.get("P_32"), best_metrics.get("P_32")),
        "best_kappa_q99_delta": delta(parent_metrics.get("kappa_q99"), best_metrics.get("kappa_q99")),
        "best_alignment_delta": delta(parent_metrics.get("best_alignment_to_minus_rho"), best_alignment_metrics.get("best_alignment_to_minus_rho")),
        "best_closure_shell_score_delta": delta(parent_metrics.get("closure_shell_score"), best_shell_metrics.get("closure_shell_score")),
        "target_defect_improvement_rate": float(target_improve_count) / float(target_attempt_count) if target_attempt_count else None,
        "target_defect_improvement_count": int(target_improve_count),
        "target_defect_move_count": int(target_attempt_count),
        "support_turnover_seen": any(float(row.get("defect_support_turnover") or 0.0) > 0.0 for row in snapshots),
        "score0_seen": bool(best_score == 0),
    }
    attempt.update(flags)
    attempt["exactlike_improvement_count"] = int(sum(1 for key in ("dmin_improvement_seen", "P_16_improvement_seen", "P_32_improvement_seen", "kappa_q99_improvement_seen") if attempt.get(key)))
    attempt["parent_metrics"] = parent_metrics
    return attempt, snapshots


def delta(before, after):
    if before is None or after is None:
        return None
    return float(after) - float(before)


def rows_by_key(rows, key):
    out = {}
    for row in rows:
        out.setdefault(row.get(key), []).append(row)
    return out


def summarize_group(rows, group_key, group_value):
    out = {
        group_key: group_value,
        "candidate_count": len(set(row.get("candidate_hash") for row in rows)),
        "attempt_count": len(rows),
        "score_improvement_count": sum(1 for row in rows if row.get("score_improvement_seen")),
        "score_improvement_rate": rate(rows, "score_improvement_seen"),
        "exactlike_improvement_count": sum(1 for row in rows if row.get("exactlike_improvement_seen")),
        "exactlike_improvement_rate": rate(rows, "exactlike_improvement_seen"),
        "alignment_improvement_count": sum(1 for row in rows if row.get("alignment_improvement_seen")),
        "closure_shell_improvement_count": sum(1 for row in rows if row.get("closure_shell_improvement_seen")),
        "damage_count": sum(1 for row in rows if row.get("damage_seen")),
        "damage_rate": rate(rows, "damage_seen"),
        "median_best_score_delta": median(row.get("best_score_delta") for row in rows),
        "median_D_min_ratio_delta": median(row.get("best_D_min_ratio_delta") for row in rows),
        "median_P_16_delta": median(row.get("best_P_16_delta") for row in rows),
        "median_P_32_delta": median(row.get("best_P_32_delta") for row in rows),
        "median_kappa_q99_delta": median(row.get("best_kappa_q99_delta") for row in rows),
        "median_alignment_delta": median(row.get("best_alignment_delta") for row in rows),
        "median_closure_shell_score_delta": median(row.get("best_closure_shell_score_delta") for row in rows),
    }
    return out


def build_summaries(attempts, candidates):
    score_band_rows = []
    for band in SCORE_BAND_ORDER:
        rows = [row for row in attempts if row.get("score_band") == band]
        if rows:
            score_band_rows.append(summarize_group(rows, "score_band", band))
    mode_rows = []
    for mode, rows in sorted(rows_by_key(attempts, "mode").items()):
        mode_rows.append(summarize_group(rows, "mode", mode))
    source_rows = []
    for method, rows in sorted(rows_by_key(attempts, "source_method").items()):
        source_rows.append(summarize_group(rows, "source_method", method))
    candidate_rows = []
    for candidate_hash, rows in sorted(rows_by_key(attempts, "candidate_hash").items()):
        best = sorted(
            rows,
            key=lambda row: (
                int(row.get("best_score_delta", 0)),
                -float(row.get("exactlike_improvement_count", 0)),
                -float(row.get("best_closure_shell_score_delta") or -999),
                -float(row.get("best_alignment_delta") or -999),
            ),
        )[0]
        improvement_attempts = sum(1 for row in rows if row.get("score_improvement_seen") or row.get("exactlike_improvement_seen"))
        shell_attempts = sum(1 for row in rows if row.get("closure_shell_improvement_seen") or row.get("alignment_improvement_seen"))
        recommendation = "archive"
        if any(row.get("score_improvement_seen") for row in rows):
            recommendation = "repair_target"
        elif improvement_attempts >= 2:
            recommendation = "promising_for_deepening"
        elif shell_attempts >= 2:
            recommendation = "needs_more_logging"
        elif any(row.get("support_turnover_seen") for row in rows):
            recommendation = "benchmark_trap"
        candidate_rows.append(
            {
                "candidate_hash": candidate_hash,
                "candidate_hash12": str(candidate_hash)[:12],
                "score": best.get("parent_score"),
                "score_band": best.get("score_band"),
                "tuple": best.get("tuple"),
                "source_method": best.get("source_method"),
                "attempt_count": len(rows),
                "best_mode": best.get("mode"),
                "best_score_delta": best.get("best_score_delta"),
                "best_D_min_ratio_delta": best.get("best_D_min_ratio_delta"),
                "best_P_16_delta": best.get("best_P_16_delta"),
                "best_kappa_q99_delta": best.get("best_kappa_q99_delta"),
                "best_alignment_delta": best.get("best_alignment_delta"),
                "best_closure_shell_delta": best.get("best_closure_shell_score_delta"),
                "recommendation": recommendation,
            }
        )
    return score_band_rows, mode_rows, source_rows, candidate_rows


def find_summary(rows, key, value):
    for row in rows:
        if row.get(key) == value:
            return row
    return {}


def hypothesis_evaluation(attempts, score_band_rows, mode_rows, source_rows):
    target_rows = [row for row in attempts if row.get("parent_score") in (164, 176)]
    target_improved_candidates = set(
        row.get("candidate_hash")
        for row in target_rows
        if row.get("score_improvement_seen") or row.get("exactlike_improvement_seen") or row.get("alignment_improvement_seen") or row.get("closure_shell_improvement_seen")
    )
    focused_rows = [row for row in attempts if row.get("mode") != "baseline_score_only_recheck"]
    baseline_rows = [row for row in attempts if row.get("mode") == "baseline_score_only_recheck"]
    focused_exact = rate(focused_rows, "exactlike_improvement_seen")
    baseline_exact = rate(baseline_rows, "exactlike_improvement_seen")
    focused_score = rate(focused_rows, "score_improvement_seen")
    baseline_score = rate(baseline_rows, "score_improvement_seen")
    h1_status = "supported" if len(target_improved_candidates) >= 2 else ("inconclusive" if target_rows else "inconclusive")
    turnover_f = median(row.get("defect_support_turnover") for row in focused_rows if row.get("defect_support_turnover") is not None)
    turnover_b = median(row.get("defect_support_turnover") for row in baseline_rows if row.get("defect_support_turnover") is not None)
    h2_status = "supported" if turnover_f is not None and turnover_b is not None and turnover_f > turnover_b else "inconclusive"
    h3_status = "supported" if (
        focused_exact is not None and baseline_exact is not None and focused_exact > baseline_exact
    ) or (
        focused_score is not None and baseline_score is not None and focused_score > baseline_score
    ) else "inconclusive"
    s164 = find_summary(score_band_rows, "score_band", "score164")
    s176 = find_summary(score_band_rows, "score_band", "score176")
    if s164 and s176:
        diffs = []
        for key in ("median_D_min_ratio_delta", "median_P_16_delta", "median_kappa_q99_delta", "median_alignment_delta", "median_closure_shell_score_delta"):
            if s164.get(key) is not None and s176.get(key) is not None:
                diffs.append(abs(float(s164[key]) - float(s176[key])))
        h4_status = "supported" if diffs and median(diffs) < 0.05 else "inconclusive"
    else:
        h4_status = "inconclusive"
    known_sources = [row for row in source_rows if row.get("source_method") != "unknown" and row.get("attempt_count", 0) >= 5]
    rates = [row.get("exactlike_improvement_rate") for row in known_sources if row.get("exactlike_improvement_rate") is not None]
    h5_status = "supported" if len(rates) >= 2 and max(rates) - min(rates) >= 0.10 else "inconclusive"
    return {
        "H_P167_FRW1": {
            "status": h1_status,
            "improved_score164_176_candidate_count": len(target_improved_candidates),
            "score164_176_attempt_count": len(target_rows),
        },
        "H_P167_FRW2": {
            "status": h2_status,
            "focused_median_support_turnover": turnover_f,
            "baseline_median_support_turnover": turnover_b,
        },
        "H_P167_FRW3": {
            "status": h3_status,
            "focused_exactlike_improvement_rate": focused_exact,
            "baseline_exactlike_improvement_rate": baseline_exact,
            "focused_score_improvement_rate": focused_score,
            "baseline_score_improvement_rate": baseline_score,
        },
        "H_P167_FRW4": {
            "status": h4_status,
            "score164_summary": s164,
            "score176_summary": s176,
        },
        "H_P167_FRW5": {
            "status": h5_status,
            "source_method_summary": source_rows,
        },
    }


def format_float(value, digits=4):
    if value is None:
        return "NA"
    try:
        return ("{:.%df}" % digits).format(float(value))
    except Exception:
        return str(value)


def best_mode(mode_rows):
    if not mode_rows:
        return "NA"
    rows = sorted(
        mode_rows,
        key=lambda row: (
            -float(row.get("score_improvement_rate") or 0.0),
            -float(row.get("exactlike_improvement_rate") or 0.0),
            -float(row.get("median_alignment_delta") or -999.0),
            -float(row.get("median_closure_shell_score_delta") or -999.0),
        ),
    )
    return rows[0].get("mode")


def build_summary(config, candidates, attempts, score_band_rows, mode_rows, source_rows, candidate_rows, hypotheses):
    s164_count = sum(1 for row in candidates if int(row.get("score")) == 164)
    s176_count = sum(1 for row in candidates if int(row.get("score")) == 176)
    target_attempts = [row for row in attempts if row.get("parent_score") in (164, 176)]
    score_down = sum(1 for row in target_attempts if row.get("score_improvement_seen"))
    exactlike = sum(1 for row in target_attempts if row.get("exactlike_improvement_seen"))
    turnover = sum(1 for row in target_attempts if row.get("support_turnover_seen"))
    align = sum(1 for row in target_attempts if row.get("alignment_improvement_seen"))
    shell = sum(1 for row in target_attempts if row.get("closure_shell_improvement_seen"))
    baseline = find_summary(mode_rows, "mode", "baseline_score_only_recheck")
    focused = [row for row in mode_rows if row.get("mode") != "baseline_score_only_recheck"]
    repair_targets = [row for row in candidate_rows if row.get("recommendation") == "repair_target"]
    promising = [row for row in candidate_rows if row.get("recommendation") == "promising_for_deepening"]
    lines = []
    lines.append("# p167 focused near-hit diagnostic")
    lines.append("")
    lines.append("このrunは Hadamard 668 構成runではなく、p167 score164/176 near-hit が focused defect 操作に反応するかを見る小予算診断です。")
    lines.append("")
    lines.append("## Dataset")
    lines.append("")
    lines.append("- candidates: `{}`".format(len(candidates)))
    lines.append("- attempts: `{}`".format(len(attempts)))
    lines.append("- modes: `{}`".format(", ".join(config["modes"])))
    lines.append("- steps/restarts/sample_swaps: `{}` / `{}` / `{}`".format(config["steps"], config["restarts"], config["sample_swaps"]))
    lines.append("- shard: `{}/{}`".format(config["shard_index"], config["shard_count"]))
    lines.append("- score164 candidates: `{}`".format(s164_count))
    lines.append("- score176 candidates: `{}`".format(s176_count))
    lines.append("")
    lines.append("Diagnostics are sampled 1-swap probes, not full certificates. Absolute p37 thresholds are not treated as p167 success criteria.")
    lines.append("")
    lines.append("## Mode Summary")
    lines.append("")
    lines.append("| mode | attempts | score improve rate | exactlike improve rate | median score delta | median alignment delta | median shell delta |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")
    for row in mode_rows:
        lines.append(
            "| `{}` | {} | {} | {} | {} | {} | {} |".format(
                row.get("mode"),
                row.get("attempt_count"),
                format_float(row.get("score_improvement_rate")),
                format_float(row.get("exactlike_improvement_rate")),
                format_float(row.get("median_best_score_delta")),
                format_float(row.get("median_alignment_delta")),
                format_float(row.get("median_closure_shell_score_delta")),
            )
        )
    lines.append("")
    lines.append("## Hypotheses")
    lines.append("")
    for key in sorted(hypotheses):
        lines.append("- `{}`: `{}`".format(key, hypotheses[key]["status"]))
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    lines.append("1. p167 near-hit は何件対象にしたか: `{}` 件。".format(len(candidates)))
    lines.append("2. score164 / score176 は何件対象にしたか: score164 `{}`, score176 `{}`。".format(s164_count, s176_count))
    lines.append("3. focused walk は score164/176 の score を下げたか: `{}` attemptsでscore改善。".format(score_down))
    lines.append("4. score は下がらなくても D_min/S, P_tau, kappa は改善したか: `{}` attemptsでexact-like proxy改善。".format(exactlike))
    lines.append("5. support turnover / persistent defect fraction は動いたか: `{}` attemptsでsupport turnoverを観測。".format(turnover))
    lines.append("6. closure shell score / alignment_to_minus_rho は改善したか: alignment `{}`, closure shell `{}` attemptsで改善。".format(align, shell))
    lines.append("7. focused modes は baseline より良かったか: `{}`。".format(hypotheses["H_P167_FRW3"]["status"]))
    lines.append("8. どの focused mode が一番有望か: `{}`。".format(best_mode(mode_rows)))
    lines.append("9. score164 と score176 は response 的にも同じ trap family に見えるか: `{}`。".format(hypotheses["H_P167_FRW4"]["status"]))
    lines.append("10. source method 別に response の差はあるか: `{}`。".format(hypotheses["H_P167_FRW5"]["status"]))
    if repair_targets:
        decision = "repair_target"
    elif promising:
        decision = "promising_for_deepening"
    else:
        decision = "benchmark_trap / archive"
    lines.append("11. score164/176 をどこへ回すべきか: shard単位では `{}`。全40 shard aggregateで最終判断する。".format(decision))
    lines.append("12. 次にやるべき実験: positiveなら longer focused run、neutralなら pair-level repair / ALNS、negativeなら fresh generator と benchmark化を優先。")
    lines.append("")
    lines.append("## Formula Notes")
    lines.append("")
    lines.append("- `S = sum_{d != 0} rho(d)^2`")
    lines.append("- `D_min_ratio = D_min_1 / S`")
    lines.append("- `kappa = -2g / q`")
    lines.append("- `alignment = <Delta rho, -rho> / (||Delta rho|| * ||rho||)`")
    return "\n".join(lines) + "\n"


def shard_filter(items, shard_index, shard_count):
    if int(shard_count) <= 1:
        return items
    out = []
    for idx, item in enumerate(items):
        if idx % int(shard_count) == int(shard_index):
            out.append(item)
    return out


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--n", type=int, default=N_DEFAULT)
    parser.add_argument("--ks", type=parse_int_tuple, default=KS_DEFAULT)
    parser.add_argument("--lambda", dest="lam", type=int, default=LAMBDA_DEFAULT)
    parser.add_argument("--candidate-roots", default=",".join(DEFAULT_INPUT_ROOTS))
    parser.add_argument("--max-score", type=int, default=232)
    parser.add_argument("--max-candidates", type=int, default=80)
    parser.add_argument("--steps", type=int, default=300)
    parser.add_argument("--restarts", type=int, default=3)
    parser.add_argument("--sample-swaps", type=int, default=200)
    parser.add_argument("--diagnostic-samples", type=int, default=200)
    parser.add_argument("--snapshot-accepted", default="0,25,50,100,150,200,300,500")
    parser.add_argument("--modes", default=",".join(DEFAULT_MODES))
    parser.add_argument("--shard-index", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--seed-base", type=int, default=690167)
    parser.add_argument("--no-move-patience", type=int, default=80)
    parser.add_argument("--trust-stored-score", action="store_true", default=True)
    parser.add_argument("--recompute-score", action="store_false", dest="trust_stored_score")
    parser.add_argument("--canonical-dedupe", action="store_true", default=False)
    parser.add_argument("--fixture-out", default=None)
    parser.add_argument("--collect-only", action="store_true", default=False)
    parser.add_argument("--out-dir", default=None)
    return parser.parse_args()


def main():
    args = parse_args()
    roots = [item.strip() for item in str(args.candidate_roots).split(",") if item.strip()]
    out_dir = args.out_dir or os.path.join(
        "outputs",
        "explorations",
        "{}_p167_focused_nearhit_diagnostic".format(now_stamp()),
    )
    ensure_dir(out_dir)
    modes = tuple(item.strip() for item in str(args.modes).split(",") if item.strip())
    invalid_modes = [mode for mode in modes if mode not in DEFAULT_MODES]
    if invalid_modes:
        raise ValueError("unknown modes: {}".format(invalid_modes))
    if int(args.shard_index) < 0 or int(args.shard_count) < 1 or int(args.shard_index) >= int(args.shard_count):
        raise ValueError("shard_index must satisfy 0 <= shard_index < shard_count")

    candidates_all = collect_candidates(args, roots)
    if args.fixture_out:
        write_jsonl(args.fixture_out, candidates_all)
    candidates = shard_filter(candidates_all, int(args.shard_index), int(args.shard_count))
    if not candidates:
        raise RuntimeError("no p167 near-hit candidates found for this shard")

    write_jsonl(os.path.join(out_dir, "input_p167_focused_candidates.jsonl"), candidates)
    config = {
        "script": SCRIPT_NAME,
        "p": int(args.p),
        "n": int(args.n),
        "ks": [int(x) for x in args.ks],
        "lambda": int(args.lam),
        "candidate_roots": roots,
        "max_score": int(args.max_score),
        "max_candidates": int(args.max_candidates),
        "selected_candidates_total": len(candidates_all),
        "selected_candidates_this_shard": len(candidates),
        "modes": list(modes),
        "steps": int(args.steps),
        "restarts": int(args.restarts),
        "sample_swaps": int(args.sample_swaps),
        "diagnostic_samples": int(args.diagnostic_samples),
        "snapshot_accepted": args.snapshot_accepted,
        "shard_index": int(args.shard_index),
        "shard_count": int(args.shard_count),
        "seed_base": int(args.seed_base),
        "sampled_diagnostics_note": "D_min/P_tau/kappa/alignment are sampled 1-swap probes, not certificates.",
    }
    write_json(os.path.join(out_dir, "run_config.json"), config)

    if bool(args.collect_only):
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# p167 focused near-hit diagnostic\n\n")
            f.write("Collect-only mode wrote candidate input fixture.\n")
        return 0

    attempts = []
    snapshots = []
    total_attempts = len(candidates) * len(modes) * int(args.restarts)
    done = 0
    for candidate in candidates:
        for mode in modes:
            for restart_id in range(int(args.restarts)):
                attempt, attempt_snapshots = run_attempt(candidate, mode, restart_id, args)
                attempts.append(attempt)
                snapshots.extend(attempt_snapshots)
                done += 1
                if done % 20 == 0 or done == total_attempts:
                    print("attempts", done, "/", total_attempts)

    score_band_rows, mode_rows, source_rows, candidate_rows = build_summaries(attempts, candidates)
    hypotheses = hypothesis_evaluation(attempts, score_band_rows, mode_rows, source_rows)

    write_jsonl(os.path.join(out_dir, "p167_focused_attempts.jsonl"), attempts)
    write_jsonl(os.path.join(out_dir, "p167_focused_snapshots.jsonl"), snapshots)
    write_csv(os.path.join(out_dir, "p167_focused_score_band_summary.csv"), score_band_rows)
    write_json(os.path.join(out_dir, "p167_focused_score_band_summary.json"), score_band_rows)
    write_csv(os.path.join(out_dir, "p167_focused_mode_summary.csv"), mode_rows)
    write_json(os.path.join(out_dir, "p167_focused_mode_summary.json"), mode_rows)
    write_csv(os.path.join(out_dir, "p167_focused_source_method_summary.csv"), source_rows)
    write_json(os.path.join(out_dir, "p167_focused_source_method_summary.json"), source_rows)
    write_csv(os.path.join(out_dir, "p167_focused_candidate_summary.csv"), candidate_rows)
    write_json(os.path.join(out_dir, "p167_focused_candidate_summary.json"), candidate_rows)
    write_json(os.path.join(out_dir, "p167_focused_hypothesis_evaluation.json"), hypotheses)

    summary = build_summary(config, candidates, attempts, score_band_rows, mode_rows, source_rows, candidate_rows, hypotheses)
    with open(os.path.join(out_dir, "p167_focused_nearhit_diagnostic_summary.md"), "w") as f:
        f.write(summary)
    with open(os.path.join(out_dir, "run_log.md"), "w") as f:
        f.write("# p167 focused near-hit diagnostic log\n\n")
        f.write("- candidates total: `{}`\n".format(len(candidates_all)))
        f.write("- candidates this shard: `{}`\n".format(len(candidates)))
        f.write("- attempts: `{}`\n".format(len(attempts)))
        f.write("- snapshots: `{}`\n".format(len(snapshots)))
        f.write("- sampled diagnostics: true\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(int(main() or 0))
