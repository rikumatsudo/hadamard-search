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
import subprocess
import time


SCRIPT_NAME = "73_p167_broad_tuple_trajectory_dataset_calibration"
DEFAULT_CONFIG = "configs/experiments/p167_broad_tuple_stage0_calibration.yaml"
DEFAULT_TUPLE_REGISTRY = "configs/fixtures/p167_tuple_classes.json"
DEFAULT_BENCHMARK_TRAPS = "configs/fixtures/benchmark_traps/p167_score164_176.jsonl"
DEFAULT_OPERATORS = (
    "baseline_score_only",
    "random_walk_score_guarded",
    "focused_plus_small_threshold",
)
DEFAULT_SEED_FAMILIES = ("pure_random", "mixed_diversity")
STAGE1_SEED_FAMILIES = (
    "pure_random",
    "mixed_diversity",
    "score_biased_random",
    "closure_shell_biased",
)
STAGE1_OPERATORS = (
    "baseline_score_only",
    "random_walk_score_guarded",
    "focused_plus_small_threshold",
    "hybrid_pair_repair_to_closure_shell",
    "pair_profile_plus_movespace_filter",
    "mixed_operator_random",
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


def read_jsonl(path):
    rows = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
    except Exception:
        pass
    return rows


def median(values):
    values = [float(v) for v in values if v is not None]
    return statistics.median(values) if values else None


def mean(values):
    values = [float(v) for v in values if v is not None]
    return statistics.mean(values) if values else None


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


def rate(rows, key):
    return float(sum(1 for row in rows if row.get(key))) / float(len(rows)) if rows else None


def delta(before, after):
    if before is None or after is None:
        return None
    return float(after) - float(before)


def as_float(value):
    if value is None:
        return None
    try:
        value = float(value)
    except Exception:
        return None
    return value if math.isfinite(value) else None


def parse_list(text, default=()):
    if text is None or text == "":
        return list(default)
    if isinstance(text, (list, tuple)):
        return [str(x).strip() for x in text if str(x).strip()]
    return [item.strip() for item in str(text).split(",") if item.strip()]


def parse_int_list(text, default=()):
    if text is None or text == "":
        return list(default)
    if isinstance(text, (list, tuple)):
        return [int(x) for x in text]
    return [int(item.strip()) for item in str(text).split(",") if item.strip()]


def deterministic_seed(text):
    digest = hashlib.sha256(str(text).encode("utf-8")).hexdigest()
    return int(digest[:16], 16)


def stable_hash(text):
    return hashlib.sha256(str(text).encode("utf-8")).hexdigest()


def make_rng(seed):
    return random.Random(int(seed))


def load_yaml(path):
    if not path or not os.path.exists(path):
        return {}
    try:
        import yaml
        with open(path) as f:
            return yaml.safe_load(f) or {}
    except Exception:
        return {}


def file_sha256(path):
    if not path or not os.path.exists(path):
        return None
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def git_commit():
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        return None


def load_tuple_registry(path):
    with open(path) as f:
        payload = json.load(f)
    classes = payload.get("tuple_classes", [])
    equivalence_definition = payload.get("equivalence_definition")
    if len(classes) != 10:
        raise RuntimeError("expected 10 p167 tuple classes, found {}".format(len(classes)))
    out = []
    for row in classes:
        p = int(payload.get("p", 167))
        rs = [int(x) for x in row["abs_row_sums"]]
        ks = [int(x) for x in row["representative_tuple"]]
        lam = int(row["lambda"])
        if sum(x * x for x in rs) != 4 * p:
            raise RuntimeError("invalid abs_row_sums for {}".format(row.get("tuple_class_id")))
        if sorted((p - x) // 2 for x in rs) != ks:
            raise RuntimeError("representative tuple mismatch for {}".format(row.get("tuple_class_id")))
        if sum(ks) - p != lam:
            raise RuntimeError("lambda mismatch for {}".format(row.get("tuple_class_id")))
        out.append(
            {
                "tuple_class_id": row["tuple_class_id"],
                "abs_row_sums": rs,
                "ks": ks,
                "representative_tuple": ks,
                "lambda": lam,
                "p": p,
                "n": int(payload.get("n", 4 * p)),
                "equivalence_definition": equivalence_definition,
            }
        )
    return out, payload


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


def support_from_rho(rho):
    return set(d for d in range(1, len(rho)) if int(rho[d]) != 0)


def sign_vector(rho):
    signs = [0] * len(rho)
    for d in range(1, len(rho)):
        signs[d] = 1 if int(rho[d]) > 0 else (-1 if int(rho[d]) < 0 else 0)
    return signs


def apply_sparse_delta(counts, delta):
    out = list(counts)
    for d, value in delta.items():
        out[int(d)] += int(value)
    return out


def apply_move(blocks, move):
    out = [set(block) for block in blocks]
    block_idx = int(move["block"])
    removed = int(move["removed"])
    added = int(move["added"])
    if removed not in out[block_idx] or added in out[block_idx]:
        return None
    out[block_idx].remove(removed)
    out[block_idx].add(added)
    return out


def json_blocks(blocks):
    return [[int(x) for x in sorted(block)] for block in blocks]


def state_hash(blocks, p, ks):
    payload = {"p": int(p), "ks": [int(k) for k in ks], "blocks": json_blocks(blocks)}
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


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
        "kappa": float(-2 * g) / float(q),
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


def high_abs_target(rho, rng):
    support = sorted(support_from_rho(rho))
    if not support:
        return None
    weights = [float(abs(int(rho[d]))) for d in support]
    total = sum(weights)
    if total <= 0:
        return support[rng.randrange(len(support))]
    needle = rng.random() * total
    acc = 0.0
    for d, weight in zip(support, weights):
        acc += weight
        if acc >= needle:
            return d
    return support[-1]


def sample_swap_moves(blocks, counts, rho, lam, p, rng, sample_swaps, target_d=None):
    out = []
    seen = set()
    sample_swaps = max(1, int(sample_swaps))
    if target_d is not None:
        d = int(target_d)
        for block_idx, block in enumerate(blocks):
            outside = [x for x in range(p) if x not in block]
            if not outside:
                continue
            if int(rho[d]) > 0:
                for x in list(block):
                    if (x + d) % p in block or (x - d) % p in block:
                        for added in rng.sample(outside, min(8, len(outside))):
                            add_move_unique(out, seen, blocks, counts, rho, lam, p, block_idx, x, added)
                            if len(out) >= sample_swaps:
                                return out[:sample_swaps]
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
    tries = 0
    max_tries = max(sample_swaps * 12, 200)
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
            "Q_ratio": None,
        }
    h_values = [int(move["h"]) for move in moves]
    kappas = [float(move["kappa"]) for move in moves if move.get("kappa") is not None]
    q_values = [int(move["q"]) for move in moves]
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
        "Q_ratio": float(mean(q_values)) / float(score) if score > 0 and q_values else None,
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
    return best_row or {
        "best_alignment_to_minus_rho": None,
        "best_alignment_move_deltaS": None,
        "best_alignment_move_kappa": None,
        "best_alignment_move_added_support_count": None,
        "best_alignment_move_removed_support_count": None,
        "best_alignment_move_new_support_fraction": None,
    }


def rho_shape_metrics(rho):
    support = sorted(support_from_rho(rho))
    values = [int(rho[d]) for d in support]
    S = int(sum(value * value for value in values))
    value_counts = {}
    for value in values:
        value_counts[str(value)] = value_counts.get(str(value), 0) + 1
    support_size = len(support)
    pm1_count = sum(1 for value in values if abs(value) == 1)
    return {
        "S": S,
        "support_size": int(support_size),
        "S_over_support": float(S) / float(support_size) if support_size else None,
        "max_abs_rho": max([abs(value) for value in values]) if values else 0,
        "pm1_fraction": float(pm1_count) / float(support_size) if support_size else None,
        "value_counts": {key: value_counts[key] for key in sorted(value_counts, key=lambda x: int(x))},
        "defect_support": support,
    }


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
    return {
        "closure_shell_score": float(c_shape + c_pm1 + c_max_abs + c_dmin + c_kappa + c_align - penalty),
        "closure_component_S_over_support": float(c_shape),
        "closure_component_pm1_fraction": float(c_pm1),
        "closure_component_max_abs": float(c_max_abs),
        "closure_component_D_min_ratio": float(c_dmin),
        "closure_component_kappa": float(c_kappa),
        "closure_component_alignment": float(c_align),
        "closure_penalty_new_support": float(penalty),
    }


def state_metrics(blocks, counts, lam, p, rng, diagnostic_samples, initial_support=None, diagnostic_type="sampled"):
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
        out["new_defect_fraction"] = float(len(support - initial_support)) / float(max(1, len(union)))
    out["stubborn_defect_count"] = None
    out["diagnostic_type"] = diagnostic_type
    out["diagnostic_sample_count"] = int(diagnostic_samples)
    out["diagnostic_budget"] = int(diagnostic_samples)
    return out


def random_blocks(p, ks, rng):
    values = list(range(p))
    return [set(rng.sample(values, int(k))) for k in ks]


PAIR_SPLITS = (
    ((0, 1), (2, 3)),
    ((0, 2), (1, 3)),
    ((0, 3), (1, 2)),
)


def pair_profile(block, p):
    values = list(block)
    out = [0 for _ in range(p)]
    for x in values:
        for y in values:
            if x != y:
                out[(int(x) - int(y)) % p] += 1
    return out


def pair_profile_score(blocks, p):
    profiles = [pair_profile(block, p) for block in blocks]
    best = None
    for left, right in PAIR_SPLITS:
        left_profile = [profiles[left[0]][d] + profiles[left[1]][d] for d in range(p)]
        right_profile = [profiles[right[0]][d] + profiles[right[1]][d] for d in range(p)]
        l2 = sum((left_profile[d] - right_profile[d]) ** 2 for d in range(1, p))
        left_energy = sum(left_profile[d] * left_profile[d] for d in range(1, p))
        right_energy = sum(right_profile[d] * right_profile[d] for d in range(1, p))
        score = float(l2 + abs(left_energy - right_energy))
        if best is None or score < best:
            best = score
    return float(best if best is not None else 0.0)


def init_blocks(tuple_row, seed_family, run_seed, args):
    p = int(tuple_row["p"])
    ks = [int(k) for k in tuple_row["ks"]]
    lam = int(tuple_row["lambda"])
    rng = make_rng(run_seed)
    if tuple_row.get("initial_blocks"):
        return [set(int(x) for x in block) for block in tuple_row["initial_blocks"]], "benchmark_trap_fixture"
    if seed_family == "pure_random":
        return random_blocks(p, ks, rng), "pure_random_single"
    pool_size = max(1, int(args.mixed_diversity_pool))
    best = None
    for i in range(pool_size):
        blocks = random_blocks(p, ks, make_rng(run_seed + 7919 * (i + 1)))
        counts = total_diff_counts(p, blocks)
        rho = rho_vector(counts, lam)
        shape = rho_shape_metrics(rho)
        if seed_family == "score_biased_random":
            key = (int(shape["S"]), state_hash(blocks, p, ks))
        elif seed_family == "pair_profile_biased":
            key = (pair_profile_score(blocks, p), int(shape["S"]), state_hash(blocks, p, ks))
        elif seed_family == "closure_shell_biased":
            diagnostic_seed = run_seed + 104729 * (i + 1)
            metrics = state_metrics(
                blocks,
                counts,
                lam,
                p,
                seeded_rng(diagnostic_seed),
                min(50, int(args.diagnostic_sample_count)),
                support_from_rho(rho),
                str(args.diagnostic_type),
            )
            key = (-float(metrics.get("closure_shell_score") or 0.0), -exactlike_score(metrics), int(shape["S"]), state_hash(blocks, p, ks))
        elif seed_family == "trap_avoid":
            diagnostic_seed = run_seed + 104729 * (i + 1)
            metrics = state_metrics(
                blocks,
                counts,
                lam,
                p,
                seeded_rng(diagnostic_seed),
                min(50, int(args.diagnostic_sample_count)),
                support_from_rho(rho),
                str(args.diagnostic_type),
            )
            key = (false_basin_score(metrics), -float(metrics.get("closure_shell_score") or 0.0), int(shape["S"]), state_hash(blocks, p, ks))
        else:
            key = (int(shape["S"]), -int(shape["support_size"]), state_hash(blocks, p, ks))
        if best is None or key < best[0]:
            best = (key, blocks)
    return best[1], "{}_pool{}".format(seed_family, pool_size)


def choose_move(operator, blocks, counts, lam, p, rng, sample_swaps, uphill_threshold):
    if operator == "mixed_operator_random":
        operator = rng.choice(
            [
                "baseline_score_only",
                "random_walk_score_guarded",
                "focused_plus_small_threshold",
                "hybrid_pair_repair_to_closure_shell",
                "pair_profile_plus_movespace_filter",
            ]
        )
    rho = rho_vector(counts, lam)
    target_d = high_abs_target(rho, rng) if operator == "focused_plus_small_threshold" else None
    if operator in ("hybrid_pair_repair_to_closure_shell", "pair_profile_plus_movespace_filter"):
        target_d = high_abs_target(rho, rng)
    moves = sample_swap_moves(blocks, counts, rho, lam, p, rng, int(sample_swaps), target_d)
    if not moves:
        return None, target_d
    if operator == "baseline_score_only":
        for move in moves:
            if int(move["h"]) < 0:
                return move, target_d
        return None, target_d
    if operator == "random_walk_score_guarded":
        allowed = [move for move in moves if int(move["h"]) <= int(uphill_threshold)]
        if not allowed:
            return None, target_d
        weights = [1.0 / float(1 + max(0, int(move["h"]))) for move in allowed]
        total = sum(weights)
        needle = rng.random() * total
        acc = 0.0
        for move, weight in zip(allowed, weights):
            acc += weight
            if acc >= needle:
                return move, target_d
        return allowed[-1], target_d
    if operator == "focused_plus_small_threshold":
        best = None
        for move in moves:
            target_old = abs(int(rho[target_d])) if target_d is not None else 0
            target_new = abs(int(rho[target_d] + move["delta"].get(target_d, 0))) if target_d is not None else 0
            target_improvement = target_old - target_new
            if int(move["h"]) <= int(uphill_threshold) and target_improvement >= 0:
                key = (int(target_improvement), -int(move["h"]), float(move["kappa"]))
                if best is None or key > best[0]:
                    best = (key, move)
        if best is not None:
            return best[1], target_d
        for move in moves:
            if int(move["h"]) < 0:
                return move, target_d
    if operator == "pair_profile_plus_movespace_filter":
        allowed = [
            move
            for move in moves
            if int(move["h"]) <= int(uphill_threshold)
            and float(move["kappa"]) >= 0.75
            and float(move["new_support_fraction"]) <= 0.60
        ]
        if not allowed:
            allowed = [move for move in moves if int(move["h"]) <= int(uphill_threshold)]
        if not allowed:
            return None, target_d
        allowed.sort(key=lambda move: (int(move["h"]), -float(move["kappa"]), -int(move["removed_support_count"]), int(move["added_support_count"])))
        return allowed[0], target_d
    if operator == "hybrid_pair_repair_to_closure_shell":
        allowed = [move for move in moves if int(move["h"]) <= int(uphill_threshold) * 2]
        if not allowed:
            return None, target_d
        best = None
        for move in allowed:
            # Lightweight closure-shell proxy: favor anti-aligned moves that remove support
            # without creating much new support. Exact metrics are recomputed at snapshots.
            proxy = (
                2.0 * float(move["kappa"])
                + 0.35 * float(move["removed_support_count"])
                - 0.35 * float(move["added_support_count"])
                - 0.01 * float(max(0, int(move["h"])))
            )
            key = (proxy, -int(move["h"]), -int(move["added_support_count"]))
            if best is None or key > best[0]:
                best = (key, move)
        if best is not None:
            return best[1], target_d
    return None, target_d


def task_row(stage_name, tuple_row, seed_family, operator, restart_id, run_seed, raw, initial_blocks=None, benchmark_meta=None):
    return {
        "task_id": "{}_".format(stage_name) + stable_hash(raw)[:16],
        "tuple_class_id": tuple_row["tuple_class_id"],
        "abs_row_sums": tuple_row["abs_row_sums"],
        "ks": tuple_row["ks"],
        "representative_tuple": tuple_row.get("representative_tuple", tuple_row["ks"]),
        "lambda": tuple_row["lambda"],
        "p": tuple_row["p"],
        "n": tuple_row["n"],
        "equivalence_definition": tuple_row.get("equivalence_definition"),
        "seed_family": seed_family,
        "operator": operator,
        "restart_id": int(restart_id),
        "run_seed": int(run_seed),
        "initial_blocks": initial_blocks,
        "benchmark_meta": benchmark_meta,
    }


def task_grid(tuple_rows, seed_families, operators, restarts, seed_base, stage_name):
    tasks = []
    for tuple_row in tuple_rows:
        for seed_family in seed_families:
            for operator in operators:
                for restart_id in range(int(restarts)):
                    raw = "{}:{}:{}:{}".format(tuple_row["tuple_class_id"], seed_family, operator, restart_id)
                    run_seed = int(seed_base) + int(deterministic_seed(raw) % 1000000007)
                    tasks.append(task_row(stage_name, tuple_row, seed_family, operator, restart_id, run_seed, raw))
    tasks.sort(key=lambda row: (row["tuple_class_id"], row["seed_family"], row["operator"], row["restart_id"]))
    return tasks


def tuple_row_by_ks(tuple_rows, ks):
    ks = [int(k) for k in ks]
    for row in tuple_rows:
        if [int(k) for k in row["ks"]] == ks:
            return row
    return None


def load_benchmark_tasks(tuple_rows, manifest_path, operators, limit, seed_base, stage_name):
    limit = int(limit or 0)
    if limit <= 0 or not manifest_path or not os.path.exists(manifest_path):
        return []
    manifest_rows = read_jsonl(manifest_path)
    if not manifest_rows:
        return []
    source_fixture = manifest_rows[0].get("source_fixture")
    fixture_rows = read_jsonl(source_fixture) if source_fixture else []
    by_hash = {row.get("candidate_hash"): row for row in fixture_rows if row.get("candidate_hash")}
    tasks = []
    for manifest in manifest_rows[:limit]:
        candidate = by_hash.get(manifest.get("candidate_hash"))
        if not candidate or not candidate.get("blocks"):
            continue
        tuple_row = tuple_row_by_ks(tuple_rows, candidate.get("tuple") or manifest.get("tuple"))
        if tuple_row is None:
            continue
        for operator in operators:
            raw = "benchmark:{}:{}:{}".format(manifest.get("candidate_hash"), operator, manifest.get("fixture_line"))
            run_seed = int(seed_base) + int(deterministic_seed(raw) % 1000000007)
            meta = dict(manifest)
            meta["candidate_hash"] = candidate.get("candidate_hash")
            meta["source_method"] = candidate.get("source_method")
            meta["source_score"] = candidate.get("score")
            tasks.append(
                task_row(
                    stage_name,
                    tuple_row,
                    "benchmark_trap",
                    operator,
                    int(manifest.get("fixture_line") or 0),
                    run_seed,
                    raw,
                    initial_blocks=candidate.get("blocks"),
                    benchmark_meta=meta,
                )
            )
    return tasks


def shard_tasks(tasks, shard_index, shard_count):
    shard_index = int(shard_index)
    shard_count = int(shard_count)
    if shard_count <= 1:
        return tasks
    return [task for idx, task in enumerate(tasks) if idx % shard_count == shard_index]


def format_float(value, digits=4):
    if value is None:
        return "NA"
    try:
        return ("{:.%df}" % digits).format(float(value))
    except Exception:
        return str(value)


def exactlike_score(metrics):
    dmin = metrics.get("D_min_ratio")
    p16 = metrics.get("P_16")
    p32 = metrics.get("P_32")
    kappa = metrics.get("kappa_q99") if metrics.get("kappa_q99") is not None else metrics.get("kappa_max")
    align = metrics.get("best_alignment_to_minus_rho")
    parts = [
        0.0 if dmin is None else max(0.0, 1.0 - min(1.5, float(dmin)) / 1.5),
        0.0 if p16 is None else min(1.0, float(p16) * 5.0),
        0.0 if p32 is None else min(1.0, float(p32) * 4.0),
        0.0 if kappa is None else max(0.0, min(1.0, float(kappa) / 2.0)),
        0.0 if align is None else max(0.0, min(1.0, float(align))),
    ]
    return float(sum(parts) / float(len(parts)))


def false_basin_score(metrics):
    dmin = metrics.get("D_min_ratio")
    p16 = metrics.get("P_16")
    kappa = metrics.get("kappa_q99") if metrics.get("kappa_q99") is not None else metrics.get("kappa_max")
    qratio = metrics.get("Q_ratio")
    parts = [
        0.0 if dmin is None else max(0.0, min(1.0, (float(dmin) - 1.0))),
        0.0 if p16 is None else max(0.0, 1.0 - min(1.0, float(p16) * 5.0)),
        0.0 if kappa is None else max(0.0, 1.0 - min(1.0, float(kappa))),
        0.0 if qratio is None else max(0.0, min(1.0, float(qratio))),
    ]
    return float(sum(parts) / float(len(parts)))


def damage_components(initial_metrics, metrics):
    S0 = as_float(initial_metrics.get("S"))
    S = as_float(metrics.get("S"))
    dmin0 = as_float(initial_metrics.get("D_min_ratio"))
    dmin = as_float(metrics.get("D_min_ratio"))
    p16_0 = as_float(initial_metrics.get("P_16"))
    p16 = as_float(metrics.get("P_16"))
    p32_0 = as_float(initial_metrics.get("P_32"))
    p32 = as_float(metrics.get("P_32"))
    kappa0 = as_float(initial_metrics.get("kappa_q99"))
    kappa = as_float(metrics.get("kappa_q99"))
    q0 = as_float(initial_metrics.get("Q_ratio"))
    q = as_float(metrics.get("Q_ratio"))
    score_component = 0.0 if S0 is None or S is None else max(0.0, (S - S0) / float(max(1.0, S0)))
    dmin_component = 0.0 if dmin0 is None or dmin is None else max(0.0, dmin - dmin0)
    p16_component = 0.0 if p16_0 is None or p16 is None else max(0.0, p16_0 - p16)
    p32_component = 0.0 if p32_0 is None or p32 is None else max(0.0, p32_0 - p32)
    p_tau_component = 0.5 * (p16_component + p32_component)
    kappa_component = 0.0 if kappa0 is None or kappa is None else max(0.0, kappa0 - kappa)
    q_component = 0.0 if q0 is None or q is None else max(0.0, q - q0)
    damage = score_component + dmin_component + p_tau_component + kappa_component + q_component
    return {
        "damage_score": float(damage),
        "damage_score_component_S": float(score_component),
        "damage_score_component_D_min": float(dmin_component),
        "damage_score_component_P_tau": float(p_tau_component),
        "damage_score_component_kappa": float(kappa_component),
        "damage_score_component_Q_ratio": float(q_component),
    }


def build_snapshot_row(row_base, kind, attempted_steps, accepted_moves, metrics, initial_metrics, best_score, diagnostic_seed):
    row = dict(row_base)
    row.update(
        {
            "snapshot_kind": kind,
            "attempted_steps": int(attempted_steps),
            "accepted_moves": int(accepted_moves),
            "acceptance_rate": float(accepted_moves) / float(attempted_steps) if attempted_steps else 0.0,
            "best_S": int(best_score),
            "score_delta_from_start": int(metrics["S"]) - int(initial_metrics["S"]),
            "diagnostic_seed": int(diagnostic_seed),
        }
    )
    row.update({key: value for key, value in metrics.items() if key != "defect_support"})
    row["closure_shell_delta"] = delta(initial_metrics.get("closure_shell_score"), metrics.get("closure_shell_score"))
    row["D_min_ratio_delta"] = delta(initial_metrics.get("D_min_ratio"), metrics.get("D_min_ratio"))
    row["kappa_q99_delta"] = delta(initial_metrics.get("kappa_q99"), metrics.get("kappa_q99"))
    row["alignment_delta"] = delta(initial_metrics.get("best_alignment_to_minus_rho"), metrics.get("best_alignment_to_minus_rho"))
    row["S_delta_from_start"] = delta(initial_metrics.get("S"), metrics.get("S"))
    row["D_min_ratio_delta_from_start"] = row["D_min_ratio_delta"]
    row["P_16_delta_from_start"] = delta(initial_metrics.get("P_16"), metrics.get("P_16"))
    row["P_32_delta_from_start"] = delta(initial_metrics.get("P_32"), metrics.get("P_32"))
    row["kappa_q99_delta_from_start"] = row["kappa_q99_delta"]
    row["kappa_max_delta_from_start"] = delta(initial_metrics.get("kappa_max"), metrics.get("kappa_max"))
    row["alignment_delta_from_start"] = row["alignment_delta"]
    row["closure_shell_delta_from_start"] = row["closure_shell_delta"]
    row.update(damage_components(initial_metrics, metrics))
    row["damage_score_delta_from_start"] = row["damage_score"]
    score_value = as_float(metrics.get("S"))
    row["score_band"] = int(math.floor(score_value / 50.0) * 50) if score_value is not None else None
    row["exactlike_score"] = exactlike_score(metrics)
    row["false_basin_score"] = false_basin_score(metrics)
    return row


def emit_snapshot(row_base, snapshots, kind, attempted_steps, accepted_moves, blocks, counts, lam, p, rng, diagnostic_samples, initial_support, initial_metrics, best_score, diagnostic_type):
    metrics = state_metrics(blocks, counts, lam, p, rng, diagnostic_samples, initial_support, diagnostic_type)
    row = build_snapshot_row(row_base, kind, attempted_steps, accepted_moves, metrics, initial_metrics, best_score, getattr(rng, "_stage_seed", 0))
    snapshots.append(row)
    return row, metrics


def seeded_rng(seed):
    rng = make_rng(seed)
    rng._stage_seed = int(seed)
    return rng


def run_task(task, args, config_hash, input_manifest_hash, code_commit, github_run_id):
    started = time.time()
    p = int(task["p"])
    ks = [int(x) for x in task["ks"]]
    lam = int(task["lambda"])
    run_id = task["task_id"] + "_r{}".format(task["restart_id"])
    blocks, init_method = init_blocks(task, task["seed_family"], task["run_seed"], args)
    counts = total_diff_counts(p, blocks)
    initial_rho = rho_vector(counts, lam)
    initial_support = support_from_rho(initial_rho)
    diagnostic_type = str(args.diagnostic_type)
    initial_diagnostic_seed = int(task["run_seed"] + 101)
    initial_metrics = state_metrics(blocks, counts, lam, p, seeded_rng(initial_diagnostic_seed), int(args.diagnostic_sample_count), initial_support, diagnostic_type)
    best_score = int(initial_metrics["S"])
    best_score_metrics = dict(initial_metrics)
    best_exact_metrics = dict(initial_metrics)
    best_shell_metrics = dict(initial_metrics)
    best_align_metrics = dict(initial_metrics)
    best_score_blocks = [set(block) for block in blocks]
    final_blocks = [set(block) for block in blocks]
    attempted_schedule = set(parse_int_list(args.snapshot_attempted_steps, [0, 25, 50, 100, 200]))
    accepted_schedule = set(parse_int_list(args.snapshot_accepted_moves, [0, 25, 50, 100]))
    emitted_attempted_steps = set([0])
    emitted_accepted_moves = set([0])
    emitted_highres_accepted_moves = set()
    snapshots = []
    row_base = {
        "run_id": run_id,
        "trajectory_id": run_id,
        "run_label": args.run_label,
        "task_id": task["task_id"],
        "tuple_class_id": task["tuple_class_id"],
        "abs_row_sums": task["abs_row_sums"],
        "ks": ks,
        "representative_tuple": task.get("representative_tuple", ks),
        "lambda": lam,
        "equivalence_definition": task.get("equivalence_definition"),
        "seed_family": task["seed_family"],
        "operator": task["operator"],
        "restart_id": int(task["restart_id"]),
        "shard_id": int(args.shard_index),
        "github_run_id": github_run_id,
        "code_commit": code_commit,
        "config_hash": config_hash,
        "input_manifest_hash": input_manifest_hash,
        "artifact_path": args.out_dir,
        "operator_version": "{}_operator_v1".format(args.stage_name or "p167_stage0"),
        "benchmark_role": (task.get("benchmark_meta") or {}).get("benchmark_role"),
        "benchmark_candidate_hash": (task.get("benchmark_meta") or {}).get("candidate_hash"),
    }
    initial_row = build_snapshot_row(row_base, "initial", 0, 0, initial_metrics, initial_metrics, best_score, initial_diagnostic_seed)
    snapshots.append(initial_row)
    best_score_snapshot = dict(initial_row, snapshot_kind="best_score_state")
    best_exact_snapshot = dict(initial_row, snapshot_kind="best_exactlike_state")
    best_shell_snapshot = dict(initial_row, snapshot_kind="best_closure_shell_state")
    best_align_snapshot = dict(initial_row, snapshot_kind="best_alignment_state")
    accepted = 0
    highres_until = -1
    highres_trigger_count = 0
    no_move_streak = 0
    for step in range(1, int(args.steps) + 1):
        rng = seeded_rng(task["run_seed"] + step * 1009)
        move, target_d = choose_move(task["operator"], blocks, counts, lam, p, rng, int(args.sample_swaps), int(args.uphill_threshold))
        if move is None:
            no_move_streak += 1
            if int(args.no_move_patience) > 0 and no_move_streak >= int(args.no_move_patience):
                break
        else:
            next_blocks = apply_move(blocks, move)
            if next_blocks is not None:
                blocks = next_blocks
                counts = apply_sparse_delta(counts, move["delta"])
                accepted += 1
                no_move_streak = 0
                score = score_counts(counts, lam)
                if score < best_score:
                    best_score = int(score)
                    best_score_blocks = [set(block) for block in blocks]
                    best_seed = task["run_seed"] + 400000 + accepted
                    best_score_metrics = state_metrics(blocks, counts, lam, p, seeded_rng(best_seed), int(args.diagnostic_sample_count), initial_support, diagnostic_type)
                    best_score_snapshot = build_snapshot_row(row_base, "best_score_state", step, accepted, best_score_metrics, initial_metrics, best_score, best_seed)
        attempted_due = step in attempted_schedule and step not in emitted_attempted_steps
        accepted_due = accepted in accepted_schedule and accepted not in emitted_accepted_moves
        highres_due = accepted > 0 and accepted <= highres_until and accepted not in emitted_highres_accepted_moves
        need_snapshot = attempted_due or accepted_due or highres_due
        if need_snapshot:
            kind = "high_resolution" if highres_due else "scheduled"
            row, metrics = emit_snapshot(row_base, snapshots, kind, step, accepted, blocks, counts, lam, p, seeded_rng(task["run_seed"] + 200000 + step + accepted), int(args.diagnostic_sample_count), initial_support, initial_metrics, best_score, diagnostic_type)
            if attempted_due:
                emitted_attempted_steps.add(step)
            if accepted_due:
                emitted_accepted_moves.add(accepted)
            if highres_due:
                emitted_highres_accepted_moves.add(accepted)
            if exactlike_score(metrics) > exactlike_score(best_exact_metrics):
                best_exact_metrics = dict(metrics)
                best_exact_snapshot = dict(row, snapshot_kind="best_exactlike_state")
            if float(metrics.get("closure_shell_score") or -999.0) > float(best_shell_metrics.get("closure_shell_score") or -999.0):
                best_shell_metrics = dict(metrics)
                best_shell_snapshot = dict(row, snapshot_kind="best_closure_shell_state")
            if float(metrics.get("best_alignment_to_minus_rho") or -999.0) > float(best_align_metrics.get("best_alignment_to_minus_rho") or -999.0):
                best_align_metrics = dict(metrics)
                best_align_snapshot = dict(row, snapshot_kind="best_alignment_state")
            if bool(args.high_resolution_logging):
                dmin0 = initial_metrics.get("D_min_ratio")
                dmin = metrics.get("D_min_ratio")
                align_delta = row.get("alignment_delta")
                kappa_delta = row.get("kappa_q99_delta")
                shell_delta = row.get("closure_shell_delta")
                trigger = False
                if dmin0 is not None and dmin is not None and float(dmin) <= 0.8 * float(dmin0):
                    trigger = True
                if align_delta is not None and float(align_delta) >= 0.15:
                    trigger = True
                if kappa_delta is not None and float(kappa_delta) >= 0.10:
                    trigger = True
                if shell_delta is not None and float(shell_delta) >= 0.50:
                    trigger = True
                if trigger and accepted + int(args.highres_followup_accepted_moves) > highres_until:
                    highres_until = accepted + int(args.highres_followup_accepted_moves)
                    highres_trigger_count += 1
    final_blocks = [set(block) for block in blocks]
    final_counts = counts
    final_score = score_counts(final_counts, lam)
    final_row, final_metrics = emit_snapshot(row_base, snapshots, "final", min(int(args.steps), step if "step" in locals() else 0), accepted, final_blocks, final_counts, lam, p, seeded_rng(task["run_seed"] + 999999), int(args.diagnostic_sample_count), initial_support, initial_metrics, best_score, diagnostic_type)
    if exactlike_score(final_metrics) > exactlike_score(best_exact_metrics):
        best_exact_metrics = dict(final_metrics)
        best_exact_snapshot = dict(final_row, snapshot_kind="best_exactlike_state")
    if float(final_metrics.get("closure_shell_score") or -999.0) > float(best_shell_metrics.get("closure_shell_score") or -999.0):
        best_shell_metrics = dict(final_metrics)
        best_shell_snapshot = dict(final_row, snapshot_kind="best_closure_shell_state")
    if float(final_metrics.get("best_alignment_to_minus_rho") or -999.0) > float(best_align_metrics.get("best_alignment_to_minus_rho") or -999.0):
        best_align_metrics = dict(final_metrics)
        best_align_snapshot = dict(final_row, snapshot_kind="best_alignment_state")
    snapshots.extend([best_score_snapshot, best_exact_snapshot, best_shell_snapshot, best_align_snapshot])
    completed = time.time()
    damage_score = max(
        0.0,
        (float(final_score - int(initial_metrics["S"])) / float(max(1, int(initial_metrics["S"])))),
        -float(delta(initial_metrics.get("P_16"), best_exact_metrics.get("P_16")) or 0.0),
        -float(delta(initial_metrics.get("kappa_q99"), best_exact_metrics.get("kappa_q99")) or 0.0),
    )
    hardening_score = max(
        0.0,
        -float(delta(initial_metrics.get("D_min_ratio"), final_metrics.get("D_min_ratio")) or 0.0),
        -float(delta(initial_metrics.get("P_16"), final_metrics.get("P_16")) or 0.0),
        -float(delta(initial_metrics.get("kappa_q99"), final_metrics.get("kappa_q99")) or 0.0),
    )
    support_mixing_score = 1.0 - float(final_metrics.get("persistent_defect_fraction") or 1.0)
    final_label = "neutral"
    recommendation = "keep_sampling"
    if damage_score > 0.5:
        final_label = "damage_candidate"
        recommendation = "guard_or_archive"
    elif float(best_shell_metrics.get("closure_shell_score") or 0.0) > float(initial_metrics.get("closure_shell_score") or 0.0):
        final_label = "high_closure_shell_candidate"
        recommendation = "promote_for_stage1"
    elif exactlike_score(best_exact_metrics) > exactlike_score(initial_metrics):
        final_label = "top_decile_exactlike_candidate"
        recommendation = "promote_for_stage1"
    elif support_mixing_score > 0.10:
        final_label = "support_mixing"
        recommendation = "needs_more_logging"
    run_row = dict(row_base)
    run_row.update(
        {
            "diagnostic_type": diagnostic_type,
            "diagnostic_sample_count": int(args.diagnostic_sample_count),
            "diagnostic_seed": int(task["run_seed"] + 101),
            "diagnostic_budget": int(args.diagnostic_sample_count),
            "started_at": int(started),
            "completed_at": int(completed),
            "wall_time_seconds": float(completed - started),
            "status": "completed",
            "init_method": init_method,
            "row_level_config": {
                "config": args.config,
                "steps": int(args.steps),
                "sample_swaps": int(args.sample_swaps),
                "diagnostic_sample_count": int(args.diagnostic_sample_count),
                "snapshot_attempted_steps": args.snapshot_attempted_steps,
                "snapshot_accepted_moves": args.snapshot_accepted_moves,
                "high_resolution_logging": bool(args.high_resolution_logging),
            },
            "config_inline_or_ref": args.config,
            "candidate_lineage_policy": "generated_from_tuple_seed_family_operator_restart",
        }
    )
    trajectory = dict(row_base)
    trajectory.update(
        {
            "initial_score": int(initial_metrics["S"]),
            "best_score": int(best_score),
            "final_score": int(final_score),
            "score_delta_from_start": int(best_score - int(initial_metrics["S"])),
            "best_exactlike_score": exactlike_score(best_exact_metrics),
            "best_false_basin_score": false_basin_score(best_exact_metrics),
            "best_closure_shell_score": best_shell_metrics.get("closure_shell_score"),
            "best_alignment_to_minus_rho": best_align_metrics.get("best_alignment_to_minus_rho"),
            "damage_score": float(damage_score),
            "hardening_score": float(hardening_score),
            "support_mixing_score": float(support_mixing_score),
            "damage_seen": bool(damage_score > 0.5),
            "acceptance_rate": float(accepted) / float(max(1, step if "step" in locals() else 0)),
            "attempted_steps": int(step if "step" in locals() else 0),
            "accepted_moves": int(accepted),
            "best_state_hash": state_hash(best_score_blocks, p, ks),
            "final_state_hash": state_hash(final_blocks, p, ks),
            "final_label": final_label,
            "recommendation": recommendation,
            "runtime_seconds": float(completed - started),
            "artifact_bytes": None,
            "artifact_path": args.out_dir,
            "operator_version": "{}_operator_v1".format(args.stage_name or "p167_stage0"),
            "parent_hash": (task.get("benchmark_meta") or {}).get("candidate_hash"),
            "candidate_lineage": {
                "source": "benchmark_trap_fixture" if task.get("benchmark_meta") else "generated_initial_state",
                "tuple_class_id": task["tuple_class_id"],
                "seed_family": task["seed_family"],
                "operator": task["operator"],
                "restart_id": int(task["restart_id"]),
                "run_seed": int(task["run_seed"]),
                "benchmark_meta": task.get("benchmark_meta"),
            },
            "highres_trigger_count": int(highres_trigger_count),
            "D_min_ratio_delta": delta(initial_metrics.get("D_min_ratio"), best_exact_metrics.get("D_min_ratio")),
            "P_16_delta": delta(initial_metrics.get("P_16"), best_exact_metrics.get("P_16")),
            "P_32_delta": delta(initial_metrics.get("P_32"), best_exact_metrics.get("P_32")),
            "kappa_q99_delta": delta(initial_metrics.get("kappa_q99"), best_exact_metrics.get("kappa_q99")),
            "alignment_delta": delta(initial_metrics.get("best_alignment_to_minus_rho"), best_align_metrics.get("best_alignment_to_minus_rho")),
            "closure_shell_delta": delta(initial_metrics.get("closure_shell_score"), best_shell_metrics.get("closure_shell_score")),
            "S_delta_from_start": int(best_score - int(initial_metrics["S"])),
            "D_min_ratio_delta_from_start": delta(initial_metrics.get("D_min_ratio"), best_exact_metrics.get("D_min_ratio")),
            "P_16_delta_from_start": delta(initial_metrics.get("P_16"), best_exact_metrics.get("P_16")),
            "P_32_delta_from_start": delta(initial_metrics.get("P_32"), best_exact_metrics.get("P_32")),
            "kappa_q99_delta_from_start": delta(initial_metrics.get("kappa_q99"), best_exact_metrics.get("kappa_q99")),
            "kappa_max_delta_from_start": delta(initial_metrics.get("kappa_max"), best_exact_metrics.get("kappa_max")),
            "alignment_delta_from_start": delta(initial_metrics.get("best_alignment_to_minus_rho"), best_align_metrics.get("best_alignment_to_minus_rho")),
            "closure_shell_delta_from_start": delta(initial_metrics.get("closure_shell_score"), best_shell_metrics.get("closure_shell_score")),
            "damage_score_delta_from_start": float(damage_score),
            "score_band": int(math.floor(float(best_score) / 50.0) * 50),
        }
    )
    return run_row, trajectory, snapshots


def rows_by_key(rows, key):
    out = {}
    for row in rows:
        out.setdefault(row.get(key), []).append(row)
    return out


def summarize(rows, key):
    out = []
    for value, group in sorted(rows_by_key(rows, key).items(), key=lambda item: str(item[0])):
        out.append(
            {
                key: value,
                "run_count": len(group),
                "best_score": min(int(row.get("best_score", 10 ** 9)) for row in group) if group else None,
                "median_best_score": median(row.get("best_score") for row in group),
                "median_final_score": median(row.get("final_score") for row in group),
                "exactlike_score_median": median(row.get("best_exactlike_score") for row in group),
                "closure_shell_score_median": median(row.get("best_closure_shell_score") for row in group),
                "false_basin_score_median": median(row.get("best_false_basin_score") for row in group),
                "damage_score_median": median(row.get("damage_score") for row in group),
                "hardening_score_median": median(row.get("hardening_score") for row in group),
                "support_mixing_score_median": median(row.get("support_mixing_score") for row in group),
                "exactlike_recovery_count": sum(1 for row in group if row.get("recommendation") == "promote_for_stage1"),
                "exactlike_recovery_rate": rate([dict(row, flag=row.get("recommendation") == "promote_for_stage1") for row in group], "flag"),
                "score_improvement_rate": rate([dict(row, flag=float(row.get("S_delta_from_start") or 0.0) < 0.0) for row in group], "flag"),
                "closure_shell_improvement_rate": rate([dict(row, flag=float(row.get("closure_shell_delta") or 0.0) > 0.0) for row in group], "flag"),
                "kappa_improvement_rate": rate([dict(row, flag=float(row.get("kappa_q99_delta") or 0.0) > 0.0) for row in group], "flag"),
                "alignment_improvement_rate": rate([dict(row, flag=float(row.get("alignment_delta") or 0.0) > 0.0) for row in group], "flag"),
                "D_min_improvement_rate": rate([dict(row, flag=float(row.get("D_min_ratio_delta") or 0.0) < 0.0) for row in group], "flag"),
                "damage_rate": rate(group, "damage_seen"),
                "hardening_rate": rate([dict(row, flag=float(row.get("hardening_score") or 0.0) > 0.25) for row in group], "flag"),
                "support_mixing_rate": rate([dict(row, flag=float(row.get("support_mixing_score") or 0.0) > 0.10) for row in group], "flag"),
                "high_closure_shell_count": sum(1 for row in group if row.get("final_label") == "high_closure_shell_candidate"),
                "top_decile_exactlike_count": sum(1 for row in group if row.get("final_label") == "top_decile_exactlike_candidate"),
                "median_runtime_seconds": median(row.get("runtime_seconds") for row in group),
                "median_closure_shell_delta": median(row.get("closure_shell_delta") for row in group),
                "median_alignment_delta": median(row.get("alignment_delta") for row in group),
                "median_acceptance_rate": median(row.get("acceptance_rate") for row in group),
            }
        )
    return out


def trajectory_label_summary(rows):
    return summarize(rows, "final_label")


def runtime_summary(run_rows, shard_index, shard_count):
    return [
        {
            "shard_index": int(shard_index),
            "shard_count": int(shard_count),
            "run_count": len(run_rows),
            "total_runtime_seconds": sum(float(row.get("wall_time_seconds") or 0.0) for row in run_rows),
            "median_runtime_seconds": median(row.get("wall_time_seconds") for row in run_rows),
            "max_runtime_seconds": max([float(row.get("wall_time_seconds") or 0.0) for row in run_rows] or [0.0]),
        }
    ]


def artifact_size_summary(out_dir):
    total = 0
    files = {}
    for path in glob.glob(os.path.join(out_dir, "*")):
        if os.path.isfile(path):
            size = os.path.getsize(path)
            files[os.path.basename(path)] = size
            total += size
    return {"artifact_total_bytes": int(total), "files": files}


def enrich_rank_percentiles(snapshot_rows):
    for row in snapshot_rows:
        score_value = as_float(row.get("S"))
        if row.get("score_band") is None:
            row["score_band"] = int(math.floor(score_value / 50.0) * 50) if score_value is not None else None

    specs = [
        ("closure_shell", "closure_shell_score", True),
        ("D_min_ratio", "D_min_ratio", False),
        ("kappa_q99", "kappa_q99", True),
        ("alignment", "best_alignment_to_minus_rho", True),
    ]
    scopes = [
        ("tuple", "tuple_class_id"),
        ("score_band", "score_band"),
        ("run", "run_id"),
    ]

    def grouped(scope_key):
        groups = {}
        for idx, row in enumerate(snapshot_rows):
            groups.setdefault(row.get(scope_key), []).append((idx, row))
        return groups

    for prefix, metric, higher_is_better in specs:
        for scope_name, scope_key in scopes:
            if scope_name == "run" and prefix != "closure_shell":
                continue
            for _scope_value, group in grouped(scope_key).items():
                valued = []
                for idx, row in group:
                    value = as_float(row.get(metric))
                    if value is not None:
                        valued.append((idx, value))
                if not valued:
                    continue
                valued.sort(key=lambda item: item[1], reverse=bool(higher_is_better))
                n = len(valued)
                last_value = None
                last_rank = 0
                for pos, (idx, value) in enumerate(valued, 1):
                    if last_value is None or value != last_value:
                        last_rank = pos
                        last_value = value
                    percentile = 1.0 if n == 1 else 1.0 - float(pos - 1) / float(n - 1)
                    row = snapshot_rows[idx]
                    row["{}_rank_within_{}".format(prefix, scope_name)] = int(last_rank)
                    row["{}_percentile_within_{}".format(prefix, scope_name)] = float(percentile)

    return snapshot_rows


def shard_distribution_summary(run_rows, snapshot_rows, shard_count):
    snapshot_counts = {}
    for row in snapshot_rows:
        shard_id = row.get("shard_id")
        snapshot_counts[shard_id] = snapshot_counts.get(shard_id, 0) + 1
    by_shard = rows_by_key(run_rows, "shard_id")
    out = []
    shard_ids = set(by_shard.keys()).union(snapshot_counts.keys())
    try:
        shard_ids = shard_ids.union(set(range(int(shard_count))))
    except Exception:
        pass
    shard_sort_key = lambda value: (0, int(value)) if str(value).isdigit() else (1, str(value))
    for shard_id in sorted(shard_ids, key=shard_sort_key):
        group = by_shard.get(shard_id, [])
        tuple_ids = sorted(set(row.get("tuple_class_id") for row in group if row.get("tuple_class_id")))
        seed_families = sorted(set(row.get("seed_family") for row in group if row.get("seed_family")))
        operators = sorted(set(row.get("operator") for row in group if row.get("operator")))
        out.append(
            {
                "shard_id": shard_id,
                "task_count": len(group),
                "run_count": len(group),
                "snapshot_count": int(snapshot_counts.get(shard_id, 0)),
                "tuple_class_count": len(tuple_ids),
                "tuple_class_ids": tuple_ids,
                "seed_family_count": len(seed_families),
                "seed_families": seed_families,
                "operator_count": len(operators),
                "operators": operators,
                "wall_time_seconds_sum": sum(float(row.get("wall_time_seconds") or 0.0) for row in group),
                "wall_time_seconds_median": median(row.get("wall_time_seconds") for row in group),
            }
        )
    return out


def shard_matrix(run_rows, field, shard_count):
    values = sorted(set(row.get(field) for row in run_rows if row.get(field) is not None), key=str)
    by_shard = rows_by_key(run_rows, "shard_id")
    shard_ids = set(by_shard.keys())
    try:
        shard_ids = shard_ids.union(set(range(int(shard_count))))
    except Exception:
        pass
    rows = []
    shard_sort_key = lambda value: (0, int(value)) if str(value).isdigit() else (1, str(value))
    for shard_id in sorted(shard_ids, key=shard_sort_key):
        group = by_shard.get(shard_id, [])
        row = {"shard_id": shard_id, "task_count": len(group)}
        for value in values:
            row[str(value)] = sum(1 for item in group if item.get(field) == value)
        rows.append(row)
    return rows


def diagnostic_budget_summary(snapshot_rows):
    grouped = {}
    for row in snapshot_rows:
        key = (
            row.get("diagnostic_type"),
            row.get("diagnostic_sample_count"),
            row.get("diagnostic_budget"),
        )
        grouped.setdefault(key, []).append(row)
    out = []
    for (diagnostic_type, sample_count, budget), group in sorted(grouped.items(), key=lambda item: str(item[0])):
        out.append(
            {
                "diagnostic_type": diagnostic_type,
                "diagnostic_sample_count": sample_count,
                "diagnostic_budget": budget,
                "diagnostic_seed_count": len(set(row.get("diagnostic_seed") for row in group if row.get("diagnostic_seed") is not None)),
                "record_count": len(group),
                "tuple_class_count": len(set(row.get("tuple_class_id") for row in group if row.get("tuple_class_id"))),
                "operator_count": len(set(row.get("operator") for row in group if row.get("operator"))),
            }
        )
    return out


def add_tuple_seed_operator_keys(trajectory_rows):
    for row in trajectory_rows:
        row["tuple_seed_operator"] = "{}|{}|{}".format(row.get("tuple_class_id"), row.get("seed_family"), row.get("operator"))
    return trajectory_rows


def stage2_survivors(trajectory_rows, max_count=50):
    if not trajectory_rows:
        return [], []
    exact_values = [as_float(row.get("best_exactlike_score")) for row in trajectory_rows]
    shell_values = [as_float(row.get("best_closure_shell_score")) for row in trajectory_rows]
    exact_cut = quantile([v for v in exact_values if v is not None], 0.90)
    shell_cut = quantile([v for v in shell_values if v is not None], 0.90)
    candidates = []
    for row in trajectory_rows:
        reasons = []
        exact_value = as_float(row.get("best_exactlike_score"))
        shell_value = as_float(row.get("best_closure_shell_score"))
        damage_value = as_float(row.get("damage_score")) or 0.0
        hardening_value = as_float(row.get("hardening_score")) or 0.0
        if exact_cut is not None and exact_value is not None and exact_value >= exact_cut:
            reasons.append("top_decile_exactlike_score")
        if shell_cut is not None and shell_value is not None and shell_value >= shell_cut:
            reasons.append("top_decile_closure_shell_score")
        if as_float(row.get("D_min_ratio_delta")) is not None and float(row.get("D_min_ratio_delta")) < 0.0:
            reasons.append("D_min_ratio_improved")
        if as_float(row.get("kappa_q99_delta")) is not None and float(row.get("kappa_q99_delta")) > 0.0:
            reasons.append("kappa_q99_improved")
        if as_float(row.get("alignment_delta")) is not None and float(row.get("alignment_delta")) > 0.0:
            reasons.append("alignment_improved")
        if damage_value <= 0.25:
            reasons.append("low_damage")
        if hardening_value <= 0.25:
            reasons.append("low_hardening")
        if as_float(row.get("support_mixing_score")) is not None and float(row.get("support_mixing_score")) > 0.10:
            reasons.append("support_mixing")
        if len(reasons) < 3:
            continue
        candidates.append(
            {
                "tuple_class_id": row.get("tuple_class_id"),
                "ks": row.get("ks"),
                "lambda": row.get("lambda"),
                "seed_family": row.get("seed_family"),
                "operator": row.get("operator"),
                "run_id": row.get("run_id"),
                "trajectory_id": row.get("trajectory_id", row.get("task_id")),
                "best_state_hash": row.get("best_state_hash"),
                "best_score": row.get("best_score"),
                "best_exactlike_score": row.get("best_exactlike_score"),
                "best_closure_shell_score": row.get("best_closure_shell_score"),
                "best_alignment_to_minus_rho": row.get("best_alignment_to_minus_rho"),
                "damage_score": row.get("damage_score"),
                "hardening_score": row.get("hardening_score"),
                "recommendation": "stage2_deepen",
                "why_selected": reasons,
            }
        )
    candidates.sort(
        key=lambda row: (
            -float(row.get("best_closure_shell_score") or 0.0),
            -float(row.get("best_exactlike_score") or 0.0),
            float(row.get("damage_score") or 0.0),
            float(row.get("best_score") or 10 ** 9),
        )
    )
    candidates = candidates[: int(max_count)]
    summary = summarize(candidates, "tuple_class_id") if candidates else []
    return candidates, summary


def build_hypotheses(run_rows, trajectory_rows, snapshot_rows, tuple_summary, seed_summary, operator_summary):
    tuple_coverage = len(set(row.get("tuple_class_id") for row in run_rows))
    layer_ok = bool(run_rows and trajectory_rows and snapshot_rows)
    diagnostic_ok = all(row.get("diagnostic_type") and row.get("diagnostic_sample_count") is not None for row in snapshot_rows[: min(len(snapshot_rows), 100)])
    metadata_ok = all(row.get("code_commit") and row.get("config_hash") and row.get("input_manifest_hash") for row in run_rows)
    rank_ok = all(
        row.get("closure_shell_rank_within_tuple") is not None and row.get("D_min_ratio_rank_within_tuple") is not None
        for row in snapshot_rows[: min(len(snapshot_rows), 100)]
    )
    damage_ok = all(row.get("damage_score") is not None for row in snapshot_rows[: min(len(snapshot_rows), 100)])
    best_score_row = min(trajectory_rows, key=lambda row: float(row.get("best_score") or 10 ** 12)) if trajectory_rows else None
    best_exactlike_row = max(trajectory_rows, key=lambda row: float(row.get("best_exactlike_score") or -1.0)) if trajectory_rows else None
    benchmark_rows = [row for row in trajectory_rows if row.get("seed_family") == "benchmark_trap"]
    regular_rows = [row for row in trajectory_rows if row.get("seed_family") != "benchmark_trap"]
    benchmark_false = median(row.get("best_false_basin_score") for row in benchmark_rows)
    regular_false = median(row.get("best_false_basin_score") for row in regular_rows)
    benchmark_shell = median(row.get("best_closure_shell_score") for row in benchmark_rows)
    regular_shell = median(row.get("best_closure_shell_score") for row in regular_rows)
    low_trap_band = [
        row
        for row in trajectory_rows
        if as_float(row.get("best_score")) is not None and int(row.get("best_score")) in (164, 176)
    ]
    reactive_band = [
        row
        for row in trajectory_rows
        if as_float(row.get("best_score")) is not None and 180 <= float(row.get("best_score")) <= 300
    ]
    low_exact = median(row.get("best_exactlike_score") for row in low_trap_band)
    reactive_exact = median(row.get("best_exactlike_score") for row in reactive_band)
    return {
        "H_CAL_1_tuple_coverage": {
            "status": "supported" if tuple_coverage == 10 else "not_supported",
            "observed_tuple_class_count": tuple_coverage,
        },
        "H_CAL_2_dataset_layers": {
            "status": "supported" if layer_ok else "not_supported",
            "run_rows": len(run_rows),
            "trajectory_rows": len(trajectory_rows),
            "snapshot_rows": len(snapshot_rows),
        },
        "H_CAL_3_sampled_diagnostic_metadata": {
            "status": "supported" if diagnostic_ok else "not_supported",
        },
        "H_CAL_4_reproducibility_metadata": {
            "status": "supported" if metadata_ok else "not_supported",
        },
        "H_CAL_5_rank_percentile_metadata": {
            "status": "supported" if rank_ok else "not_supported",
        },
        "H_CAL_6_snapshot_damage_score": {
            "status": "supported" if damage_ok else "not_supported",
        },
        "H_STAGE1_1_tuple_response_differs": {
            "status": "supported" if len(set(format_float(row.get("closure_shell_score_median"), 3) for row in tuple_summary)) > 1 else "inconclusive",
        },
        "H_STAGE1_2_seed_response_differs": {
            "status": "supported" if len(set(format_float(row.get("damage_rate"), 3) for row in seed_summary)) > 1 else "inconclusive",
        },
        "H_STAGE1_3_operator_response_differs": {
            "status": "supported" if len(set(format_float(row.get("damage_rate"), 3) for row in operator_summary)) > 1 else "inconclusive",
        },
        "H_STAGE1_4_best_score_not_same_as_exactlike": {
            "status": "supported"
            if best_score_row
            and best_exactlike_row
            and best_score_row.get("trajectory_id") != best_exactlike_row.get("trajectory_id")
            else "inconclusive",
            "best_score_trajectory_id": best_score_row.get("trajectory_id") if best_score_row else None,
            "best_exactlike_trajectory_id": best_exactlike_row.get("trajectory_id") if best_exactlike_row else None,
            "note": "Stage 1 uses soft scores, not hard exact labels.",
        },
        "H_STAGE1_5_benchmark_traps_are_harder": {
            "status": "supported"
            if benchmark_rows
            and regular_rows
            and benchmark_false is not None
            and regular_false is not None
            and benchmark_shell is not None
            and regular_shell is not None
            and benchmark_false >= regular_false
            and benchmark_shell <= regular_shell
            else "inconclusive",
            "benchmark_false_basin_median": benchmark_false,
            "regular_false_basin_median": regular_false,
            "benchmark_closure_shell_median": benchmark_shell,
            "regular_closure_shell_median": regular_shell,
        },
        "H_STAGE1_6_reactive_higher_score_band_exists": {
            "status": "supported"
            if reactive_band
            and low_trap_band
            and reactive_exact is not None
            and low_exact is not None
            and reactive_exact > low_exact
            else "inconclusive",
            "score164_176_exactlike_median": low_exact,
            "score180_300_exactlike_median": reactive_exact,
        },
        "H_STAGE1_7_survivor_selection_available": {
            "status": "supported" if any(row.get("recommendation") == "promote_for_stage1" or row.get("recommendation") == "stage2_deepen" for row in trajectory_rows) else "inconclusive",
        },
    }


def write_summary(path, config, run_rows, trajectory_rows, snapshot_rows, tuple_summary, seed_summary, operator_summary, shard_summary, diagnostic_summary, hypotheses, artifact_summary):
    lines = []
    lines.append("# p167 broad tuple trajectory dataset calibration")
    lines.append("")
    lines.append("This is a Stage 0 dataset calibration run, not a Hadamard 668 construction run.")
    lines.append("")
    lines.append("Sampled diagnostics are not full certificates.")
    lines.append("")
    lines.append("## Scope")
    lines.append("")
    lines.append("- run rows: `{}`".format(len(run_rows)))
    lines.append("- trajectory rows: `{}`".format(len(trajectory_rows)))
    lines.append("- snapshot rows: `{}`".format(len(snapshot_rows)))
    lines.append("- tuple classes observed: `{}`".format(len(set(row.get("tuple_class_id") for row in run_rows))))
    lines.append("- shard: `{}/{}`".format(config.get("shard_index"), config.get("shard_count")))
    lines.append("- artifact bytes: `{}`".format(artifact_summary.get("artifact_total_bytes")))
    lines.append("- sampled diagnostic budget groups: `{}`".format(len(diagnostic_summary)))
    lines.append("")
    lines.append("## Tuple Summary")
    lines.append("")
    lines.append("| tuple | runs | best score | median best | exactlike rate | shell rate | damage rate |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")
    for row in tuple_summary:
        lines.append(
            "| `{}` | {} | {} | {} | {} | {} | {} |".format(
                row.get("tuple_class_id"),
                row.get("run_count"),
                row.get("best_score"),
                format_float(row.get("median_best_score")),
                format_float(row.get("exactlike_recovery_rate")),
                format_float(row.get("closure_shell_improvement_rate")),
                format_float(row.get("damage_rate")),
            )
        )
    lines.append("")
    lines.append("## Operator Summary")
    lines.append("")
    lines.append("| operator | runs | best score | exactlike rate | shell rate | damage rate | median runtime |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")
    for row in operator_summary:
        lines.append(
            "| `{}` | {} | {} | {} | {} | {} | {} |".format(
                row.get("operator"),
                row.get("run_count"),
                row.get("best_score"),
                format_float(row.get("exactlike_recovery_rate")),
                format_float(row.get("closure_shell_improvement_rate")),
                format_float(row.get("damage_rate")),
                format_float(row.get("median_runtime_seconds")),
            )
        )
    lines.append("")
    lines.append("## Calibration Checks")
    lines.append("")
    for key in sorted(hypotheses):
        lines.append("- `{}`: `{}`".format(key, hypotheses[key].get("status")))
    lines.append("")
    lines.append("## Rank Direction")
    lines.append("")
    lines.append("- `closure_shell_score`: higher is better.")
    lines.append("- `D_min_ratio`: lower is better.")
    lines.append("- `kappa_q99`: higher is better.")
    lines.append("- `best_alignment_to_minus_rho`: higher is better.")
    lines.append("- Rank `1` is best; percentile `1.0` is best.")
    lines.append("- `score_band = floor(S / 50) * 50`.")
    lines.append("")
    lines.append("## Delta Direction")
    lines.append("")
    lines.append("- `S_delta_from_start < 0` is better.")
    lines.append("- `D_min_ratio_delta_from_start < 0` is better.")
    lines.append("- `P_tau_delta_from_start > 0` is better.")
    lines.append("- `kappa_delta_from_start > 0` is better.")
    lines.append("- `alignment_delta_from_start > 0` is better.")
    lines.append("- `closure_shell_delta_from_start > 0` is better.")
    lines.append("- `damage_score_delta_from_start < 0` is better.")
    lines.append("")
    lines.append("## Damage Score")
    lines.append("")
    lines.append("`damage_score = score_damage + D_min_worsening + P_tau_collapse + kappa_collapse + Q_ratio_worsening`.")
    lines.append("")
    lines.append("The components are heuristic calibration features, not mathematical certificates.")
    lines.append("")
    lines.append("## Shard Distribution")
    lines.append("")
    lines.append("- shard rows: `{}`".format(len(shard_summary)))
    lines.append("- task count min/max: `{}/{}`".format(
        min([int(row.get("task_count") or 0) for row in shard_summary] or [0]),
        max([int(row.get("task_count") or 0) for row in shard_summary] or [0]),
    ))
    lines.append("- every shard keeps at most a small task slice; tuple / seed / operator matrices are emitted separately.")
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    lines.append("1. 10 tuple 全てからデータが取れたか: `{}`.".format(hypotheses["H_CAL_1_tuple_coverage"]["status"]))
    lines.append("2. tuple class の同値定義は repo 内で固定されている: `supported`.")
    lines.append("3. run / trajectory / snapshot の3層 records が出たか: `{}`.".format(hypotheses["H_CAL_2_dataset_layers"]["status"]))
    lines.append("4. `run_level_records.jsonl` / `trajectory_level_records.jsonl` / `snapshot_level_records.jsonl` alias は出力対象。")
    lines.append("5. diagnostic_type / sample_count / seed / budget が記録されたか: `{}`.".format(hypotheses["H_CAL_3_sampled_diagnostic_metadata"]["status"]))
    lines.append("6. config_hash / code_commit / input_manifest_hash / input_manifest_hash.txt が保存されたか: `{}`.".format(hypotheses["H_CAL_4_reproducibility_metadata"]["status"]))
    lines.append("7. accepted_moves と attempted_steps の両方を保存したか: `supported`.")
    lines.append("8. closure_shell_score の delta / rank / percentile を保存したか: `{}`.".format(hypotheses["H_CAL_5_rank_percentile_metadata"]["status"]))
    lines.append("9. D_min_ratio / kappa / alignment の delta / rank / percentile を保存したか: `{}`.".format(hypotheses["H_CAL_5_rank_percentile_metadata"]["status"]))
    lines.append("10. damage_score は snapshot-level に保存されたか: `{}`.".format(hypotheses["H_CAL_6_snapshot_damage_score"]["status"]))
    lines.append("11. artifact_path / operator_version / candidate_lineage 系の nullable metadata は追加済み。")
    lines.append("12. GitHub Actions 40 shard で stratified に実行する前提の schema。")
    lines.append("13. shard_distribution_summary は出力対象。")
    lines.append("14. tuple / seed / operator の shard 分布 matrix は出力対象。")
    lines.append("15. diagnostic_budget_summary は出力対象。")
    lines.append("16. artifact size と runtime は summary に保存された。")
    lines.append("17. sampled diagnostic の限界: sampled diagnostics are not full certificates.")
    lines.append("18. Stage 1 へ進めるか: schema audit checks が supported なら進行可能。")
    lines.append("19. Stage 1 前にさらに直すべき点: full diagnostic が必要な claims は別 run で検証する。")
    lines.append("")
    lines.append("## Formula Notes")
    lines.append("")
    lines.append("- `S = sum_{d != 0} rho(d)^2`")
    lines.append("- `D_min_ratio = D_min_1 / S`")
    lines.append("- `kappa = -2g / q`")
    lines.append("- `alignment = <Delta rho, -rho> / (||Delta rho|| * ||rho||)`")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def write_stage1_summary(path, config, run_rows, trajectory_rows, snapshot_rows, tuple_summary, seed_summary, operator_summary, score_band_summary, survivor_rows, hypotheses, artifact_summary):
    tuple_sorted = sorted(tuple_summary, key=lambda row: float(row.get("closure_shell_score_median") or 0.0), reverse=True)
    seed_sorted = sorted(seed_summary, key=lambda row: float(row.get("closure_shell_score_median") or 0.0), reverse=True)
    operator_sorted = sorted(operator_summary, key=lambda row: (float(row.get("closure_shell_improvement_rate") or 0.0), -float(row.get("damage_rate") or 0.0)), reverse=True)
    lines = []
    lines.append("# p167 broad tuple Stage 1 trajectory scan")
    lines.append("")
    lines.append("This is a broad trajectory-signature scan, not a Hadamard 668 construction run.")
    lines.append("")
    lines.append("Sampled diagnostics are not full certificates.")
    lines.append("")
    lines.append("## Scope")
    lines.append("")
    lines.append("- run rows: `{}`".format(len(run_rows)))
    lines.append("- trajectory rows: `{}`".format(len(trajectory_rows)))
    lines.append("- snapshot rows: `{}`".format(len(snapshot_rows)))
    lines.append("- tuple classes observed: `{}`".format(len(set(row.get("tuple_class_id") for row in run_rows))))
    lines.append("- artifact bytes: `{}`".format(artifact_summary.get("artifact_total_bytes")))
    lines.append("- stage2 survivors: `{}`".format(len(survivor_rows)))
    lines.append("")
    lines.append("## Seed Families")
    lines.append("")
    lines.append("- `pure_random`: sample blocks uniformly at the target tuple sizes.")
    lines.append("- `mixed_diversity`: choose from a small random pool using score/support diversity proxy.")
    lines.append("- `score_biased_random`: choose the lowest initial score from a small random pool.")
    lines.append("- `pair_profile_biased`: choose lower 2+2 pair-profile imbalance from a small random pool.")
    lines.append("- `closure_shell_biased`: choose higher sampled closure-shell score from a small random pool.")
    lines.append("- `trap_avoid`: choose lower sampled false-basin score from a small random pool.")
    lines.append("")
    lines.append("## Tuple Summary")
    lines.append("")
    lines.append("| tuple | runs | best score | exactlike median | closure median | false-basin median | damage rate |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")
    for row in tuple_summary:
        lines.append("| `{}` | {} | {} | {} | {} | {} | {} |".format(
            row.get("tuple_class_id"),
            row.get("run_count"),
            row.get("best_score"),
            format_float(row.get("exactlike_score_median")),
            format_float(row.get("closure_shell_score_median")),
            format_float(row.get("false_basin_score_median")),
            format_float(row.get("damage_rate")),
        ))
    lines.append("")
    lines.append("## Operator Summary")
    lines.append("")
    lines.append("| operator | runs | score improve | exactlike improve | closure improve | alignment improve | damage rate | acceptance median |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
    for row in operator_summary:
        lines.append("| `{}` | {} | {} | {} | {} | {} | {} | {} |".format(
            row.get("operator"),
            row.get("run_count"),
            format_float(row.get("score_improvement_rate")),
            format_float(row.get("exactlike_recovery_rate")),
            format_float(row.get("closure_shell_improvement_rate")),
            format_float(row.get("alignment_improvement_rate")),
            format_float(row.get("damage_rate")),
            format_float(row.get("median_acceptance_rate")),
        ))
    lines.append("")
    lines.append("## Score Band Summary")
    lines.append("")
    lines.append("| score band | runs | best score | exactlike median | closure median | damage rate |")
    lines.append("|---|---:|---:|---:|---:|---:|")
    for row in score_band_summary:
        lines.append("| `{}` | {} | {} | {} | {} | {} |".format(
            row.get("score_band"),
            row.get("run_count"),
            row.get("best_score"),
            format_float(row.get("exactlike_score_median")),
            format_float(row.get("closure_shell_score_median")),
            format_float(row.get("damage_rate")),
        ))
    lines.append("")
    lines.append("## Hypotheses")
    lines.append("")
    for key in sorted(k for k in hypotheses if k.startswith("H_STAGE1")):
        lines.append("- `{}`: `{}`".format(key, hypotheses[key].get("status")))
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    lines.append("1. 10 tuple class 全てから十分な trajectory が取れたか: `{}`.".format(hypotheses["H_CAL_1_tuple_coverage"]["status"]))
    lines.append("2. tuple class ごとの差: closure median top is `{}`.".format(tuple_sorted[0].get("tuple_class_id") if tuple_sorted else "NA"))
    lines.append("3. 最も有望に見える tuple: `{}` by closure_shell_score_median.".format(tuple_sorted[0].get("tuple_class_id") if tuple_sorted else "NA"))
    lines.append("4. seed family ごとの差: top seed is `{}` by closure_shell_score_median.".format(seed_sorted[0].get("seed_family") if seed_sorted else "NA"))
    lines.append("5. operator ごとの差: top operator is `{}` by closure improvement / damage tradeoff.".format(operator_sorted[0].get("operator") if operator_sorted else "NA"))
    lines.append("6. best score と exact-like trajectory は一致するとは仮定しない。score_band_summary と survivor rows で比較する。")
    lines.append("7. score164/176 benchmark traps は `seed_family=benchmark_trap` として別枠記録する。")
    lines.append("8. score180-300帯または高score帯の exact-like signature は score_band_summary で見る。")
    lines.append("9. closure_shell_score / alignment / kappa / D_min/S は sampled diagnostics に基づく。")
    lines.append("10. sampled diagnostic の限界: full certificate ではない。")
    lines.append("11. Stage 2 survivor は `{}` 件抽出。".format(len(survivor_rows)))
    lines.append("12. Stage 2 は survivor の tuple / seed / operator を深掘りする。")
    lines.append("13. artifact size / runtime は runtime_summary と artifact_size_summary を参照。")
    lines.append("14. Stage 1 full へ進む前に lite の artifact size と survivor質を確認する。")
    lines.append("")
    lines.append("## Formula Notes")
    lines.append("")
    lines.append("- `S = sum_{d != 0} rho(d)^2`")
    lines.append("- `D_min_ratio = D_min_1 / S`")
    lines.append("- `kappa = -2g / q`")
    lines.append("- `alignment = <Delta rho, -rho> / (||Delta rho|| * ||rho||)`")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def aggregate_roots(args):
    run_rows = []
    trajectory_rows = []
    snapshot_rows = []
    for root in parse_list(args.aggregate_roots):
        for path in glob.glob(os.path.join(root, "**", "run_level.jsonl"), recursive=True):
            run_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "trajectory_level.jsonl"), recursive=True):
            trajectory_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "snapshot_level.jsonl"), recursive=True):
            snapshot_rows.extend(read_jsonl(path))
    return run_rows, trajectory_rows, snapshot_rows


def run(args):
    ensure_dir(args.out_dir)
    config_payload = load_yaml(args.config)
    if not args.stage_name:
        config_stage = config_payload.get("stage")
        args.stage_name = "p167_stage{}".format(config_stage) if config_stage is not None else "p167_stage0"
    tuple_registry, tuple_registry_payload = load_tuple_registry(args.tuple_registry)
    config_hash = file_sha256(args.config)
    input_manifest_hash = stable_hash((file_sha256(args.tuple_registry), file_sha256(args.benchmark_trap_manifest), config_hash))
    code_commit = args.code_commit or git_commit()
    github_run_id = args.github_run_id or os.environ.get("GITHUB_RUN_ID")
    if args.aggregate_roots:
        run_rows, trajectory_rows, snapshot_rows = aggregate_roots(args)
        if not run_rows and not trajectory_rows and not snapshot_rows:
            raise RuntimeError("No Stage 0 calibration artifacts found in aggregate roots")
    else:
        seed_families = parse_list(args.seed_families, config_payload.get("seed_families", DEFAULT_SEED_FAMILIES))
        operators = parse_list(args.operators, config_payload.get("operators", DEFAULT_OPERATORS))
        tasks_all = task_grid(tuple_registry, seed_families, operators, int(args.restarts), int(args.seed_base), args.stage_name)
        benchmark_operators = parse_list(args.benchmark_trap_operators, config_payload.get("benchmark_trap_operators", operators))
        tasks_all.extend(
            load_benchmark_tasks(
                tuple_registry,
                args.benchmark_trap_manifest,
                benchmark_operators,
                int(args.benchmark_trap_limit),
                int(args.seed_base) + 170000000,
                args.stage_name,
            )
        )
        tasks_all.sort(key=lambda row: (row["tuple_class_id"], row["seed_family"], row["operator"], row["restart_id"], row["task_id"]))
        if int(args.max_tasks) > 0:
            tasks_all = tasks_all[: int(args.max_tasks)]
        tasks = shard_tasks(tasks_all, int(args.shard_index), int(args.shard_count))
        if not tasks:
            raise RuntimeError("No Stage 0 tasks selected for this shard")
        run_rows = []
        trajectory_rows = []
        snapshot_rows = []
        for idx, task in enumerate(tasks, 1):
            run_row, trajectory, snapshots = run_task(task, args, config_hash, input_manifest_hash, code_commit, github_run_id)
            run_rows.append(run_row)
            trajectory_rows.append(trajectory)
            snapshot_rows.extend(snapshots)
            print(args.stage_name, "task", idx, "/", len(tasks), task["tuple_class_id"], task["seed_family"], task["operator"])
    trajectory_rows = add_tuple_seed_operator_keys(trajectory_rows)
    snapshot_rows = enrich_rank_percentiles(snapshot_rows)
    tuple_summary = summarize(trajectory_rows, "tuple_class_id")
    seed_summary = summarize(trajectory_rows, "seed_family")
    operator_summary = summarize(trajectory_rows, "operator")
    score_band_summary = summarize(trajectory_rows, "score_band")
    tuple_seed_operator_summary = summarize(trajectory_rows, "tuple_seed_operator")
    label_summary = trajectory_label_summary(trajectory_rows)
    runtime_rows = runtime_summary(run_rows, args.shard_index, args.shard_count)
    shard_summary = shard_distribution_summary(run_rows, snapshot_rows, args.shard_count)
    tuple_shard_matrix = shard_matrix(run_rows, "tuple_class_id", args.shard_count)
    seed_shard_matrix = shard_matrix(run_rows, "seed_family", args.shard_count)
    operator_shard_matrix = shard_matrix(run_rows, "operator", args.shard_count)
    diagnostic_summary = diagnostic_budget_summary(snapshot_rows)
    survivor_rows, survivor_summary = stage2_survivors(trajectory_rows, int(args.stage2_survivor_limit))
    hypotheses = build_hypotheses(run_rows, trajectory_rows, snapshot_rows, tuple_summary, seed_summary, operator_summary)

    write_jsonl(os.path.join(args.out_dir, "run_level.jsonl"), run_rows)
    write_jsonl(os.path.join(args.out_dir, "trajectory_level.jsonl"), trajectory_rows)
    write_jsonl(os.path.join(args.out_dir, "snapshot_level.jsonl"), snapshot_rows)
    write_jsonl(os.path.join(args.out_dir, "run_level_records.jsonl"), run_rows)
    write_jsonl(os.path.join(args.out_dir, "trajectory_level_records.jsonl"), trajectory_rows)
    write_jsonl(os.path.join(args.out_dir, "snapshot_level_records.jsonl"), snapshot_rows)
    write_csv(os.path.join(args.out_dir, "tuple_summary.csv"), tuple_summary)
    write_json(os.path.join(args.out_dir, "tuple_summary.json"), tuple_summary)
    write_csv(os.path.join(args.out_dir, "seed_family_summary.csv"), seed_summary)
    write_json(os.path.join(args.out_dir, "seed_family_summary.json"), seed_summary)
    write_csv(os.path.join(args.out_dir, "operator_summary.csv"), operator_summary)
    write_json(os.path.join(args.out_dir, "operator_summary.json"), operator_summary)
    write_csv(os.path.join(args.out_dir, "score_band_summary.csv"), score_band_summary)
    write_json(os.path.join(args.out_dir, "score_band_summary.json"), score_band_summary)
    write_csv(os.path.join(args.out_dir, "tuple_seed_operator_summary.csv"), tuple_seed_operator_summary)
    write_json(os.path.join(args.out_dir, "tuple_seed_operator_summary.json"), tuple_seed_operator_summary)
    write_csv(os.path.join(args.out_dir, "trajectory_label_summary.csv"), label_summary)
    write_json(os.path.join(args.out_dir, "trajectory_label_summary.json"), label_summary)
    write_csv(os.path.join(args.out_dir, "trajectory_type_summary.csv"), label_summary)
    write_json(os.path.join(args.out_dir, "trajectory_type_summary.json"), label_summary)
    write_csv(os.path.join(args.out_dir, "runtime_summary.csv"), runtime_rows)
    write_json(os.path.join(args.out_dir, "runtime_summary.json"), runtime_rows)
    write_csv(os.path.join(args.out_dir, "shard_distribution_summary.csv"), shard_summary)
    write_json(os.path.join(args.out_dir, "shard_distribution_summary.json"), shard_summary)
    write_csv(os.path.join(args.out_dir, "tuple_by_shard_matrix.csv"), tuple_shard_matrix)
    write_csv(os.path.join(args.out_dir, "seed_family_by_shard_matrix.csv"), seed_shard_matrix)
    write_csv(os.path.join(args.out_dir, "operator_by_shard_matrix.csv"), operator_shard_matrix)
    write_csv(os.path.join(args.out_dir, "diagnostic_budget_summary.csv"), diagnostic_summary)
    write_json(os.path.join(args.out_dir, "diagnostic_budget_summary.json"), diagnostic_summary)
    write_jsonl(os.path.join(args.out_dir, "stage2_survivor_candidates.jsonl"), survivor_rows)
    write_csv(os.path.join(args.out_dir, "stage2_survivor_summary.csv"), survivor_summary)
    write_json(os.path.join(args.out_dir, "stage2_survivor_summary.json"), survivor_summary)
    write_json(os.path.join(args.out_dir, "hypothesis_evaluation.json"), hypotheses)
    write_json(os.path.join(args.out_dir, "hypothesis_or_calibration_summary.json"), hypotheses)

    input_manifest = {
        "config": args.config,
        "config_hash": config_hash,
        "tuple_registry": args.tuple_registry,
        "tuple_registry_hash": file_sha256(args.tuple_registry),
        "benchmark_trap_manifest": args.benchmark_trap_manifest,
        "benchmark_trap_manifest_hash": file_sha256(args.benchmark_trap_manifest),
        "input_manifest_hash": input_manifest_hash,
    }
    write_json(os.path.join(args.out_dir, "input_manifest.json"), input_manifest)
    write_json(os.path.join(args.out_dir, "tuple_class_registry.json"), tuple_registry_payload)
    with open(os.path.join(args.out_dir, "input_manifest_hash.txt"), "w") as f:
        f.write(str(input_manifest_hash) + "\n")

    run_config = vars(args).copy()
    run_config.update(
        {
            "script": SCRIPT_NAME,
            "config_hash": config_hash,
            "input_manifest_hash": input_manifest_hash,
            "code_commit": code_commit,
            "tuple_registry_schema": tuple_registry_payload.get("schema_version"),
            "run_rows": len(run_rows),
            "trajectory_rows": len(trajectory_rows),
            "snapshot_rows": len(snapshot_rows),
            "timestamp": now_stamp(),
        }
    )
    write_json(os.path.join(args.out_dir, "run_config.json"), run_config)
    artifact_summary = artifact_size_summary(args.out_dir)
    write_json(os.path.join(args.out_dir, "artifact_size_summary.json"), artifact_summary)
    write_summary(
        os.path.join(args.out_dir, "p167_broad_tuple_stage0_calibration_summary.md"),
        run_config,
        run_rows,
        trajectory_rows,
        snapshot_rows,
        tuple_summary,
        seed_summary,
        operator_summary,
        shard_summary,
        diagnostic_summary,
        hypotheses,
        artifact_summary,
    )
    write_summary(
        os.path.join(args.out_dir, "p167_broad_tuple_trajectory_dataset_calibration_schema_patch_summary.md"),
        run_config,
        run_rows,
        trajectory_rows,
        snapshot_rows,
        tuple_summary,
        seed_summary,
        operator_summary,
        shard_summary,
        diagnostic_summary,
        hypotheses,
        artifact_summary,
    )
    if "stage1" in str(args.stage_name).lower() or "stage1" in str(args.config).lower():
        write_stage1_summary(
            os.path.join(args.out_dir, "p167_broad_tuple_stage1_scan_summary.md"),
            run_config,
            run_rows,
            trajectory_rows,
            snapshot_rows,
            tuple_summary,
            seed_summary,
            operator_summary,
            score_band_summary,
            survivor_rows,
            hypotheses,
            artifact_summary,
        )
    with open(os.path.join(args.out_dir, "run_log.md"), "w") as f:
        f.write("# p167 broad tuple trajectory dataset calibration log\n\n")
        f.write("- run rows: `{}`\n".format(len(run_rows)))
        f.write("- trajectory rows: `{}`\n".format(len(trajectory_rows)))
        f.write("- snapshot rows: `{}`\n".format(len(snapshot_rows)))
        f.write("- sampled diagnostics: `{}`\n".format(args.diagnostic_type == "sampled"))
    print("Wrote {} outputs to {}".format(args.stage_name, args.out_dir))
    print("Run rows:", len(run_rows), "Trajectory rows:", len(trajectory_rows), "Snapshot rows:", len(snapshot_rows))


def build_parser():
    parser = argparse.ArgumentParser(description=SCRIPT_NAME)
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--tuple-registry", default=DEFAULT_TUPLE_REGISTRY)
    parser.add_argument("--benchmark-trap-manifest", default=DEFAULT_BENCHMARK_TRAPS)
    parser.add_argument("--benchmark-trap-limit", type=int, default=0)
    parser.add_argument("--benchmark-trap-operators", default="")
    parser.add_argument("--aggregate-roots", default="")
    parser.add_argument("--seed-families", default="")
    parser.add_argument("--operators", default="")
    parser.add_argument("--restarts", type=int, default=1)
    parser.add_argument("--steps", type=int, default=200)
    parser.add_argument("--sample-swaps", type=int, default=100)
    parser.add_argument("--diagnostic-sample-count", type=int, default=100)
    parser.add_argument("--diagnostic-type", default="sampled")
    parser.add_argument("--snapshot-attempted-steps", default="0,25,50,100,200")
    parser.add_argument("--snapshot-accepted-moves", default="0,25,50,100")
    parser.add_argument("--mixed-diversity-pool", type=int, default=4)
    parser.add_argument("--uphill-threshold", type=int, default=16)
    parser.add_argument("--no-move-patience", type=int, default=80)
    parser.add_argument("--high-resolution-logging", action="store_true", default=False)
    parser.add_argument("--disable-high-resolution-logging", action="store_false", dest="high_resolution_logging")
    parser.add_argument("--highres-followup-accepted-moves", type=int, default=50)
    parser.add_argument("--shard-index", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--max-tasks", type=int, default=0)
    parser.add_argument("--seed-base", type=int, default=730167)
    parser.add_argument("--stage2-survivor-limit", type=int, default=50)
    parser.add_argument("--github-run-id", default="")
    parser.add_argument("--code-commit", default="")
    parser.add_argument("--run-label", default="")
    parser.add_argument("--stage-name", default="")
    parser.add_argument("--out-dir", default=None)
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    if not args.run_label:
        args.run_label = args.github_run_id or "local-stage0"
    if args.out_dir is None:
        suffix = "p167_broad_tuple_stage1_scan" if "stage1" in str(args.config) or "stage1" in str(args.stage_name) else "p167_broad_tuple_stage0_calibration_schema_patch"
        args.out_dir = os.path.join("outputs", "explorations", "{}_{}".format(now_stamp(), suffix))
    if int(args.shard_index) < 0 or int(args.shard_count) < 1 or int(args.shard_index) >= int(args.shard_count):
        raise RuntimeError("shard_index must satisfy 0 <= shard_index < shard_count")
    run(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(int(main() or 0))
