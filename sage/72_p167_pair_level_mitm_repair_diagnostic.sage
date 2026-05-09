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

from sds_repair_utils import json_blocks, total_diff_counts


SCRIPT_NAME = "72_p167_pair_level_mitm_repair_diagnostic"
P_DEFAULT = 167
N_DEFAULT = 668
KS_DEFAULT = (73, 78, 79, 81)
LAMBDA_DEFAULT = 144
DEFAULT_CANDIDATE_ROOTS = (
    "outputs/candidates/near_hits",
)
SPLITS = (
    ("split_01_23", (0, 1), (2, 3)),
    ("split_02_13", (0, 2), (1, 3)),
    ("split_03_12", (0, 3), (1, 2)),
)
DEFAULT_MODES = (
    "baseline_score_only_recheck",
    "pair_profile_plus_movespace_filter",
    "hybrid_pair_repair_to_closure_shell",
    "exact_joint_pair_lns",
    "sketch_mitm_pair_generation",
    "focused_plus_small_threshold_reference",
)
TARGET_SCORES = set([164, 176, 180, 184, 188, 192, 200, 216, 228, 232])
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


def maybe_float(value):
    if value is None or value == "":
        return None
    try:
        return float(value)
    except Exception:
        return None


def delta_float(after, before):
    if after is None or before is None:
        return None
    try:
        return float(after) - float(before)
    except Exception:
        return None


def parse_ks(text):
    if isinstance(text, (list, tuple)):
        values = tuple(int(x) for x in text)
    else:
        values = tuple(int(part.strip()) for part in str(text).replace("[", "").replace("]", "").split(",") if part.strip())
    if len(values) != 4:
        raise argparse.ArgumentTypeError("--ks must contain exactly four integers")
    return values


def parse_score_set(text):
    if text is None or str(text).strip() == "":
        return set(TARGET_SCORES)
    return set(int(part.strip()) for part in str(text).split(",") if part.strip())


def parse_list(text, defaults):
    if text is None or str(text).strip() == "":
        return list(defaults)
    values = [part.strip() for part in str(text).split(",") if part.strip()]
    return values


def split_by_name(names):
    selected = set(parse_list(names, [name for name, _l, _r in SPLITS]))
    out = [split for split in SPLITS if split[0] in selected]
    if not out:
        raise RuntimeError("No valid splits selected")
    return out


def has_prefix(value, prefixes):
    text = str(value or "")
    return any(text.startswith(prefix) for prefix in prefixes)


def file_roots(text):
    if isinstance(text, (list, tuple)):
        return [str(x) for x in text if str(x).strip()]
    return [part.strip() for part in str(text).split(",") if part.strip()]


def deterministic_seed(text):
    digest = hashlib.sha256(str(text).encode("utf-8")).hexdigest()
    return int(digest[:16], 16)


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


def canonical_hash(blocks, ks, p):
    # Discovery/dedup only.  This matches the repo convention: simultaneous
    # multiplier, independent cyclic block normalization, and permutation only
    # among equal-size blocks.  It intentionally avoids complement equivalence.
    p = int(p)
    ks = tuple(int(k) for k in ks)
    best = None
    for u in range(1, p):
        if gcd(u, p) != 1:
            continue
        normalized = [canonical_block_fast([int(u) * int(x) % p for x in block], p) for block in blocks]
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


def discover_files(roots):
    files = []
    for root in roots:
        if not root:
            continue
        if os.path.isfile(root) and (root.endswith(".json") or root.endswith(".jsonl")):
            files.append(root)
            continue
        if not os.path.isdir(root):
            continue
        files.extend(glob.glob(os.path.join(root, "**", "*.json"), recursive=True))
        files.extend(glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True))
    return sorted(set(files))


def iter_payloads(path):
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
                for key in (
                    "rows",
                    "candidates",
                    "results",
                    "parents",
                    "near_hits",
                    "frontier",
                    "items",
                    "snapshots",
                    "attempts",
                    "generated_candidates",
                ):
                    items = payload.get(key)
                    if isinstance(items, list):
                        rows.extend(item for item in items if isinstance(item, dict))
            elif isinstance(payload, list):
                rows.extend(item for item in payload if isinstance(item, dict))
            for row in rows:
                row["_source_file"] = path
                yield row
    except Exception:
        return


def blocks_from_payload(payload):
    raw = payload.get("blocks") or payload.get("X") or payload.get("sets")
    if not isinstance(raw, list) or len(raw) != 4:
        return None
    try:
        return [set(int(x) for x in block) for block in raw]
    except Exception:
        return None


def params_from_payload(payload):
    p = payload.get("p", payload.get("v"))
    ks = payload.get("ks", payload.get("tuple"))
    lam = payload.get("lambda", payload.get("lam"))
    try:
        p = int(p) if p is not None else None
        ks = parse_ks(ks) if ks is not None else None
        lam = int(lam) if lam is not None else None
    except Exception:
        return None, None, None
    return p, ks, lam


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


def clone_blocks(blocks):
    return [set(int(x) for x in block) for block in blocks]


def block_diff_counts(p, block):
    counts = [0] * int(p)
    values = [int(x) % int(p) for x in block]
    for x in values:
        for y in values:
            if x == y:
                continue
            counts[(x - y) % int(p)] += 1
    return counts


def per_block_diff_counts(p, blocks):
    return [block_diff_counts(p, block) for block in blocks]


def rho_vector(counts, lam):
    return [0] + [int(counts[d]) - int(lam) for d in range(1, len(counts))]


def score_from_counts(counts, lam):
    return int(sum((int(counts[d]) - int(lam)) ** 2 for d in range(1, len(counts))))


def value_counts(values):
    out = {}
    for value in values:
        key = str(int(value))
        out[key] = out.get(key, 0) + 1
    return {key: out[key] for key in sorted(out, key=lambda x: int(x))}


def variance(xs):
    xs = [float(x) for x in xs]
    if not xs:
        return None
    m = sum(xs) / float(len(xs))
    return sum((x - m) * (x - m) for x in xs) / float(len(xs))


def correlation(xs, ys):
    xs = [float(x) for x in xs]
    ys = [float(y) for y in ys]
    if len(xs) != len(ys) or not xs:
        return None
    mx = sum(xs) / float(len(xs))
    my = sum(ys) / float(len(ys))
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    denx = math.sqrt(sum((x - mx) * (x - mx) for x in xs))
    deny = math.sqrt(sum((y - my) * (y - my) for y in ys))
    if denx == 0.0 or deny == 0.0:
        return None
    return float(num) / float(denx * deny)


def l1_distance(xs, ys):
    return int(sum(abs(int(x) - int(y)) for x, y in zip(xs, ys)))


def l2_distance(xs, ys):
    return int(sum((int(x) - int(y)) ** 2 for x, y in zip(xs, ys)))


def pair_profile_for_split(per_counts, split):
    _name, left_idx, right_idx = split
    p = len(per_counts[0])
    left = [0] * p
    right = [0] * p
    for idx in left_idx:
        for d in range(p):
            left[d] += int(per_counts[idx][d])
    for idx in right_idx:
        for d in range(p):
            right[d] += int(per_counts[idx][d])
    return left, right


def reference_profiles(_reference_json, _p, _ks, _lam):
    # p167 has no known exact reference in this diagnostic.  Keep the hook so
    # pair-profile distance fields remain stable if a reference is supplied later.
    return {}


def source_method(payload, source_file):
    for key in ("source_method", "search_method", "method", "mode", "strategy", "origin", "source", "label"):
        value = payload.get(key)
        if value:
            return str(value)
    source = os.path.basename(str(source_file or "")).lower()
    for token in ("steepest", "beam", "ilp", "repair", "seed", "fourier", "pair", "frontier"):
        if token in source:
            return token
    return "unknown"


def infer_origin(payload, source_file, score):
    text = " ".join(
        str(payload.get(key, ""))
        for key in (
            "origin",
            "origin_type",
            "origin_family",
            "mode",
            "source",
            "source_path",
            "label",
            "parent_origin",
            "search_method",
            "family",
        )
    ).lower()
    source = str(source_file or "").lower()
    if "ilp" in text or "ilp" in source:
        return "ilp"
    if "beam" in text or "beam" in source:
        return "beam"
    if "steepest" in text or "steepest" in source:
        return "steepest"
    if "repair" in text or "repair" in source:
        return "repair"
    if "seed" in text or "seed" in source:
        return "seed"
    if "fourier" in text or "fourier" in source:
        return "fourier"
    return str(payload.get("origin") or payload.get("origin_type") or payload.get("origin_family") or "unknown")


def infer_label(payload, origin, score):
    label = payload.get("label") or payload.get("parent_label") or payload.get("candidate_label") or payload.get("source_label")
    if label:
        return str(label)
    return "p167_near_hit"


def source_mode(payload):
    return payload.get("mode") or payload.get("source_mode") or payload.get("search_method") or payload.get("strategy")


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
    try:
        return SCORE_BAND_ORDER.index(band)
    except ValueError:
        return len(SCORE_BAND_ORDER)


def candidate_group(row):
    tuple_key = ",".join(str(int(k)) for k in row.get("ks", []))
    prefix = "tuple_A" if tuple_key == "73,78,79,81" else "other_tuple"
    return "{}_{}".format(prefix, row.get("score_band") or "other")


def candidate_preference(row):
    return -score_band_rank(row.get("score", 999999))


def collect_candidates(args, roots):
    p = int(args.p)
    ks = tuple(int(x) for x in args.ks)
    lam = int(args.lam)
    score_set = parse_score_set(args.score_set)
    max_score = int(args.max_score)
    files = discover_files(roots)
    first = {}
    occurrences = {}
    for idx, path in enumerate(files):
        for payload in iter_payloads(path):
            blocks = blocks_from_payload(payload)
            if blocks is None:
                continue
            got_p, got_ks, got_lam = params_from_payload(payload)
            if got_p is None:
                got_p, got_ks, got_lam = p, ks, lam
            if got_p != p or tuple(got_ks or ()) != ks or got_lam != lam:
                continue
            if not validate_blocks(blocks, p, ks):
                continue
            counts = total_diff_counts(p, blocks)
            score = score_from_counts(counts, lam)
            if score > max_score:
                continue
            if score_set and score not in score_set:
                continue
            stored_score = payload.get("score")
            if stored_score is not None:
                try:
                    if int(stored_score) != int(score):
                        continue
                except Exception:
                    pass
            h = payload.get("canonical_hash") or payload.get("hash")
            if not h:
                h = canonical_hash(blocks, ks, p)
            else:
                h = str(h)
            origin = infer_origin(payload, path, score)
            label = infer_label(payload, origin, score)
            method = source_method(payload, path)
            occurrences.setdefault(h, []).append(
                {
                    "source_file": path,
                    "source_method": method,
                    "source_mode": source_mode(payload),
                    "source_label": label,
                    "origin": origin,
                }
            )
            n_value = payload.get("n")
            row = {
                "p": p,
                "n": int(n_value) if n_value is not None else int(4 * p),
                "ks": [int(k) for k in ks],
                "lambda": lam,
                "score": int(score),
                "score_per_p": float(score) / float(p),
                "score_band": score_band(score),
                "blocks": json_blocks(blocks),
                "candidate_hash": h,
                "candidate_hash12": str(h)[:12],
                "origin": origin,
                "label": label,
                "source_file": path,
                "source_method": method,
                "source_mode": source_mode(payload),
                "source_origin": payload.get("origin") or payload.get("origin_type") or payload.get("origin_family"),
                "parent_hash": payload.get("parent_hash"),
                "tuple": [int(k) for k in ks],
            }
            row["candidate_group"] = candidate_group(row)
            if h not in first or candidate_preference(row) > candidate_preference(first[h]):
                first[h] = row
        if args.max_scan_files and idx + 1 >= int(args.max_scan_files):
            break
    selected = select_candidates(list(first.values()), int(args.max_candidates))
    for row in selected:
        row["occurrence_count"] = len(occurrences.get(row["candidate_hash"], []))
    return selected


def select_candidates(rows, max_candidates):
    buckets = {band: [] for band in SCORE_BAND_ORDER}
    for row in rows:
        buckets.setdefault(row.get("score_band") or "other", []).append(row)
    for key in buckets:
        buckets[key].sort(key=lambda row: (int(row.get("score", 999999)), row.get("source_method") or "", row.get("source_file") or "", row.get("candidate_hash") or ""))

    selected = []
    selected.extend(buckets.get("score164", []))
    selected.extend(buckets.get("score176", []))
    selected.extend(buckets.get("score180_184", [])[:120])
    selected.extend(buckets.get("score188_192_200", [])[:180])
    selected.extend(buckets.get("score216_228_232", [])[:120])
    selected.extend(buckets.get("other", [])[:40])

    out = []
    seen = set()
    for row in selected:
        h = row.get("candidate_hash")
        if h in seen:
            continue
        seen.add(h)
        out.append(row)
        if len(out) >= int(max_candidates):
            break
    if len(out) < int(max_candidates):
        seen = set(row.get("candidate_hash") for row in out)
        for row in sorted(rows, key=lambda r: (int(r.get("score", 999999)), r.get("source_file") or "", r.get("candidate_hash") or "")):
            if row.get("candidate_hash") in seen:
                continue
            out.append(row)
            seen.add(row.get("candidate_hash"))
            if len(out) >= int(max_candidates):
                break
    return out


def shard_filter(rows, shard_index, shard_count):
    shard_index = int(shard_index)
    shard_count = int(shard_count)
    if shard_count <= 1:
        return rows
    if shard_index < 0 or shard_index >= shard_count:
        raise RuntimeError("shard_index must be in [0, shard_count)")
    rows = sorted(rows, key=lambda row: row.get("candidate_hash") or "")
    return [row for idx, row in enumerate(rows) if idx % shard_count == shard_index]


def exact_distance_metrics(left, right, exact_profile):
    if not exact_profile:
        return {
            "distance_to_exact_pair_profile_l1": None,
            "distance_to_exact_pair_profile_l2": None,
            "distance_to_exact_pair_profile_corr": None,
            "exact_pair_orientation": None,
        }
    left_values = left[1:]
    right_values = right[1:]
    exact_left = exact_profile["left"][1:]
    exact_right = exact_profile["right"][1:]
    direct_l2 = l2_distance(left_values, exact_left) + l2_distance(right_values, exact_right)
    swapped_l2 = l2_distance(left_values, exact_right) + l2_distance(right_values, exact_left)
    if swapped_l2 < direct_l2:
        target = exact_right + exact_left
        current = left_values + right_values
        return {
            "distance_to_exact_pair_profile_l1": l1_distance(left_values, exact_right) + l1_distance(right_values, exact_left),
            "distance_to_exact_pair_profile_l2": int(swapped_l2),
            "distance_to_exact_pair_profile_corr": correlation(current, target),
            "exact_pair_orientation": "swapped",
        }
    target = exact_left + exact_right
    current = left_values + right_values
    return {
        "distance_to_exact_pair_profile_l1": l1_distance(left_values, exact_left) + l1_distance(right_values, exact_right),
        "distance_to_exact_pair_profile_l2": int(direct_l2),
        "distance_to_exact_pair_profile_corr": correlation(current, target),
        "exact_pair_orientation": "direct",
    }


def delta_swap(p, block, removed, added):
    delta = [0] * int(p)
    others = set(block)
    if removed not in others or added in others:
        return None
    others.remove(removed)
    for y in others:
        delta[(removed - y) % p] -= 1
        delta[(y - removed) % p] -= 1
        delta[(added - y) % p] += 1
        delta[(y - added) % p] += 1
    return delta


def all_possible_swaps(blocks, block_indices, p):
    universe = set(range(int(p)))
    for block_idx in block_indices:
        block = set(blocks[block_idx])
        outside = sorted(universe - block)
        for removed in sorted(block):
            for added in outside:
                yield (int(block_idx), int(removed), int(added))


def sample_swaps(blocks, block_indices, p, sample_count, rng, top_defects=None):
    p = int(p)
    sample_count = int(sample_count)
    block_indices = [int(idx) for idx in block_indices]
    if sample_count <= 0 or not block_indices:
        return []
    universe = set(range(p))
    out = []
    seen = set()

    def add_move(block_idx, removed, added):
        move = (int(block_idx), int(removed), int(added))
        if move in seen:
            return False
        block = blocks[int(block_idx)]
        if int(removed) not in block or int(added) in block:
            return False
        seen.add(move)
        out.append(move)
        return True

    defects = [int(d) % p for d in (top_defects or []) if int(d) % p != 0]
    attempts = 0
    while defects and len(out) < sample_count and attempts < sample_count * 20:
        attempts += 1
        block_idx = rng.choice(block_indices)
        block = blocks[block_idx]
        removed = rng.choice(tuple(block))
        d = rng.choice(defects)
        for added in ((removed + d) % p, (removed - d) % p):
            if add_move(block_idx, removed, added) and len(out) >= sample_count:
                break

    attempts = 0
    while len(out) < sample_count and attempts < sample_count * 50:
        attempts += 1
        block_idx = rng.choice(block_indices)
        block = blocks[block_idx]
        outside = universe - block
        if not block or not outside:
            continue
        add_move(block_idx, rng.choice(tuple(block)), rng.choice(tuple(outside)))
    return out


def apply_moves(blocks, moves):
    out = clone_blocks(blocks)
    for block_idx, removed, added in moves:
        block_idx = int(block_idx)
        removed = int(removed)
        added = int(added)
        if removed not in out[block_idx] or added in out[block_idx]:
            return None
        out[block_idx].remove(removed)
        out[block_idx].add(added)
    return out


def combined_delta_for_moves(blocks, moves, p):
    temp = clone_blocks(blocks)
    combined = [0] * int(p)
    for block_idx, removed, added in moves:
        block_idx = int(block_idx)
        removed = int(removed)
        added = int(added)
        delta = delta_swap(p, temp[block_idx], removed, added)
        if delta is None:
            return None
        for d in range(int(p)):
            combined[d] += int(delta[d])
        temp[block_idx].remove(removed)
        temp[block_idx].add(added)
    return combined


def score_with_delta(rho, delta, p):
    return int(sum((int(rho[d]) + int(delta[d])) ** 2 for d in range(1, int(p))))


def eval_blocks(blocks, p, ks, lam, exact_by_split=None, diag_samples=80, rng=None):
    per_counts = per_block_diff_counts(p, blocks)
    counts = total_diff_counts(p, blocks)
    rho = rho_vector(counts, lam)
    score = score_from_counts(counts, lam)
    shape = defect_shape(rho)
    metrics = dict(shape)
    metrics["S"] = int(score)
    metrics["score"] = int(score)
    metrics["support_size"] = shape["defect_support_size"]
    metrics["S_over_support"] = float(score) / float(shape["defect_support_size"]) if shape["defect_support_size"] else 0.0
    values = [abs(int(rho[d])) for d in range(1, p) if int(rho[d]) != 0]
    metrics["pm1_fraction"] = float(sum(1 for v in values if v == 1)) / float(len(values)) if values else 1.0
    if rng is None:
        rng = random.Random(0)
    metrics.update(sample_move_space_metrics(blocks, counts, rho, p, lam, diag_samples, rng))
    metrics["closure_shell_score"] = closure_shell_score(metrics)
    return metrics, per_counts, counts, rho


def defect_shape(rho):
    support = [d for d in range(1, len(rho)) if int(rho[d]) != 0]
    values = [int(rho[d]) for d in support]
    positives = [d for d in support if int(rho[d]) > 0]
    negatives = [d for d in support if int(rho[d]) < 0]
    return {
        "defect_support_size": len(support),
        "defect_support": support,
        "rho_value_counts": value_counts(values),
        "max_abs_rho": max([abs(v) for v in values]) if values else 0,
        "positive_defect_mass": int(sum(int(rho[d]) for d in positives)),
        "negative_defect_mass": int(sum(-int(rho[d]) for d in negatives)),
    }


def quantile(values, q):
    values = sorted(float(v) for v in values if v is not None)
    if not values:
        return None
    idx = int(math.ceil(float(q) * len(values))) - 1
    idx = min(max(idx, 0), len(values) - 1)
    return values[idx]


def sample_move_space_metrics(blocks, counts, rho, p, lam, sample_count, rng):
    moves = sample_swaps(blocks, range(4), p, int(sample_count), rng)
    S = int(sum(int(rho[d]) * int(rho[d]) for d in range(1, p)))
    if not moves:
        return {
            "D_min_1": None,
            "D_min_ratio": None,
            "P_4": None,
            "P_8": None,
            "P_16": None,
            "P_32": None,
            "P_thetaS_001": None,
            "P_thetaS_005": None,
            "P_thetaS_010": None,
            "kappa_max": None,
            "kappa_q90": None,
            "kappa_q99": None,
            "Q_ratio": None,
            "best_alignment_to_minus_rho": None,
            "best_alignment_move_deltaS": None,
            "best_alignment_move_kappa": None,
            "best_alignment_move_added_support_count": None,
            "best_alignment_move_removed_support_count": None,
            "sampled_move_count": 0,
        }
    new_scores = []
    deltas = []
    kappas = []
    q_values = []
    alignments = []
    best_align = None
    best_align_row = None
    sqrtS = math.sqrt(float(S)) if S > 0 else 0.0
    for block_idx, removed, added in moves:
        delta = delta_swap(p, blocks[block_idx], removed, added)
        if delta is None:
            continue
        new_rho = [0] + [int(rho[d]) + int(delta[d]) for d in range(1, p)]
        newS = int(sum(int(new_rho[d]) * int(new_rho[d]) for d in range(1, p)))
        deltaS = int(newS - S)
        g = int(sum(int(rho[d]) * int(delta[d]) for d in range(1, p)))
        q = int(sum(int(delta[d]) * int(delta[d]) for d in range(1, p)))
        kappa = float(-2.0 * float(g) / float(q)) if q else None
        alignment = None
        if q and sqrtS > 0:
            alignment = float(sum(int(delta[d]) * -int(rho[d]) for d in range(1, p))) / float(math.sqrt(float(q)) * sqrtS)
        added_support = sum(1 for d in range(1, p) if int(rho[d]) == 0 and int(new_rho[d]) != 0)
        removed_support = sum(1 for d in range(1, p) if int(rho[d]) != 0 and int(new_rho[d]) == 0)
        new_scores.append(newS)
        deltas.append(deltaS)
        if kappa is not None:
            kappas.append(kappa)
        if q:
            q_values.append(float(q) / float(max(1, S)))
        if alignment is not None:
            alignments.append(alignment)
            if best_align is None or alignment > best_align:
                best_align = alignment
                best_align_row = {
                    "best_alignment_move_deltaS": deltaS,
                    "best_alignment_move_kappa": kappa,
                    "best_alignment_move_added_support_count": added_support,
                    "best_alignment_move_removed_support_count": removed_support,
                }
    if not new_scores:
        return {
            "D_min_1": None,
            "D_min_ratio": None,
            "P_4": None,
            "P_8": None,
            "P_16": None,
            "P_32": None,
            "P_thetaS_001": None,
            "P_thetaS_005": None,
            "P_thetaS_010": None,
            "kappa_max": None,
            "kappa_q90": None,
            "kappa_q99": None,
            "Q_ratio": None,
            "best_alignment_to_minus_rho": None,
            "best_alignment_move_deltaS": None,
            "best_alignment_move_kappa": None,
            "best_alignment_move_added_support_count": None,
            "best_alignment_move_removed_support_count": None,
            "sampled_move_count": 0,
        }
    out = {
        "D_min_1": min(new_scores),
        "D_min_ratio": float(min(new_scores)) / float(S) if S > 0 else 0.0,
        "P_4": float(sum(1 for d in deltas if d <= 4)) / float(len(deltas)),
        "P_8": float(sum(1 for d in deltas if d <= 8)) / float(len(deltas)),
        "P_16": float(sum(1 for d in deltas if d <= 16)) / float(len(deltas)),
        "P_32": float(sum(1 for d in deltas if d <= 32)) / float(len(deltas)),
        "P_thetaS_001": float(sum(1 for s in new_scores if s <= 0.01 * float(S))) / float(len(new_scores)) if S > 0 else 1.0,
        "P_thetaS_005": float(sum(1 for s in new_scores if s <= 0.05 * float(S))) / float(len(new_scores)) if S > 0 else 1.0,
        "P_thetaS_010": float(sum(1 for s in new_scores if s <= 0.10 * float(S))) / float(len(new_scores)) if S > 0 else 1.0,
        "kappa_max": max(kappas) if kappas else None,
        "kappa_q90": quantile(kappas, 0.90),
        "kappa_q99": quantile(kappas, 0.99),
        "Q_ratio": median(q_values),
        "best_alignment_to_minus_rho": best_align,
        "sampled_move_count": len(new_scores),
    }
    if best_align_row:
        out.update(best_align_row)
    return out


def closure_shell_score(metrics):
    S = float(metrics.get("S") or 0)
    if S <= 0:
        return 10.0
    S_over_support = float(metrics.get("S_over_support") or 999.0)
    pm1 = float(metrics.get("pm1_fraction") or 0.0)
    max_abs = float(metrics.get("max_abs_rho") or 999.0)
    d_ratio = metrics.get("D_min_ratio")
    d_ratio = float(d_ratio) if d_ratio is not None else 1.0
    kappa = metrics.get("kappa_max")
    kappa = float(kappa) if kappa is not None else 0.0
    align = metrics.get("best_alignment_to_minus_rho")
    align = float(align) if align is not None else 0.0
    added = metrics.get("best_alignment_move_added_support_count")
    added = float(added) if added is not None else 0.0
    score = 0.0
    score += max(0.0, 1.0 - abs(S_over_support - 1.0)) * 2.0
    score += pm1 * 2.0
    score += max(0.0, 1.0 - max(0.0, max_abs - 1.0) / 4.0)
    score += max(0.0, 1.0 - min(1.0, d_ratio)) * 2.0
    score += max(0.0, min(2.0, kappa)) / 2.0 * 2.0
    score += max(0.0, min(1.0, align))
    score -= min(1.0, added / 10.0)
    return float(score)


def pair_features_for_split(blocks, p, lam, split, exact_by_split):
    per_counts = per_block_diff_counts(p, blocks)
    counts = total_diff_counts(p, blocks)
    rho = rho_vector(counts, lam)
    name, left_idx, right_idx = split
    left, right = pair_profile_for_split(per_counts, split)
    left_values = [int(left[d]) for d in range(1, p)]
    right_values = [int(right[d]) for d in range(1, p)]
    positive_ds = [d for d in range(1, p) if int(rho[d]) > 0]
    negative_ds = [d for d in range(1, p) if int(rho[d]) < 0]
    left_target = [0] + [int(lam) - int(right[d]) for d in range(1, p)]
    right_target = [0] + [int(lam) - int(left[d]) for d in range(1, p)]
    left_pressure = l1_distance(left_values, left_target[1:])
    right_pressure = l1_distance(right_values, right_target[1:])
    row = {
        "split": name,
        "left_blocks": [int(x) for x in left_idx],
        "right_blocks": [int(x) for x in right_idx],
        "left_energy": int(sum(v * v for v in left_values)),
        "right_energy": int(sum(v * v for v in right_values)),
        "pair_energy_gap": int(abs(sum(v * v for v in left_values) - sum(v * v for v in right_values))),
        "left_variance": variance(left_values),
        "right_variance": variance(right_values),
        "pair_variance_gap": abs(float(variance(left_values)) - float(variance(right_values))),
        "left_max": max(left_values) if left_values else None,
        "right_max": max(right_values) if right_values else None,
        "left_min": min(left_values) if left_values else None,
        "right_min": min(right_values) if right_values else None,
        "pair_profile_l2": l2_distance(left_values, right_values),
        "pair_profile_l1": l1_distance(left_values, right_values),
        "pair_profile_corr": correlation(left_values, right_values),
        "left_repair_pressure": int(left_pressure),
        "right_repair_pressure": int(right_pressure),
        "best_pair_side_to_repair": "left" if left_pressure < right_pressure else ("right" if right_pressure < left_pressure else "tie"),
        "positive_defect_contribution_balance": int(sum(int(left[d]) - int(right[d]) for d in positive_ds)),
        "negative_defect_contribution_balance": int(sum(int(left[d]) - int(right[d]) for d in negative_ds)),
    }
    row.update(exact_distance_metrics(left, right, exact_by_split.get(name)))
    return row


def top_defect_coords(rho, count=8):
    coords = [d for d in range(1, len(rho)) if int(rho[d]) != 0]
    coords.sort(key=lambda d: (-abs(int(rho[d])), d))
    return coords[: int(count)]


def side_indices(split, side):
    _name, left_idx, right_idx = split
    if side == "left":
        return list(left_idx)
    if side == "right":
        return list(right_idx)
    return list(left_idx) + list(right_idx)


def choose_side(pair_before, mode, rng):
    if pair_before.get("best_pair_side_to_repair") in ("left", "right"):
        return pair_before["best_pair_side_to_repair"]
    return "left" if rng.random() < 0.5 else "right"


def move_signature(moves):
    return ";".join("{}:{}>{}".format(int(i), int(r), int(a)) for i, r, a in moves)


def candidate_objective(mode, before_eval, after_eval, pair_before, pair_after):
    S = float(after_eval.get("S") or 0)
    pair_dist = float(pair_after.get("distance_to_exact_pair_profile_l2") or 0)
    pair_l2 = float(pair_after.get("pair_profile_l2") or 0)
    closure = float(after_eval.get("closure_shell_score") or 0)
    d_ratio = float(after_eval.get("D_min_ratio") or 0)
    kappa = float(after_eval.get("kappa_max") or 0)
    if mode == "baseline_score_only_recheck":
        return S
    if mode == "hybrid_pair_repair_to_closure_shell":
        return S + 0.02 * pair_dist + 0.01 * pair_l2 + 5.0 * d_ratio - 4.0 * closure - 2.0 * kappa
    if mode == "pair_profile_plus_movespace_filter":
        return S + 0.04 * pair_dist + 0.01 * pair_l2 + 4.0 * d_ratio - 2.0 * closure
    if mode == "exact_joint_pair_lns":
        return S + 0.03 * pair_dist + 0.02 * pair_l2 - closure
    if mode == "sketch_mitm_pair_generation":
        return S + 0.05 * pair_dist - 2.0 * closure
    if mode == "focused_plus_small_threshold_reference":
        return S + 2.0 * d_ratio - closure - kappa
    return S + 0.05 * pair_dist + 0.02 * pair_l2


def exactlike_improved(before, after):
    if after.get("S") is not None and before.get("S") is not None and int(after.get("S")) < int(before.get("S")):
        return True
    b = before.get("D_min_ratio")
    a = after.get("D_min_ratio")
    if b is not None and a is not None and float(a) + 1e-9 < float(b):
        return True
    for key in ("P_16", "P_32", "kappa_max", "kappa_q99", "closure_shell_score", "best_alignment_to_minus_rho"):
        b = before.get(key)
        a = after.get(key)
        if b is not None and a is not None and float(a) > float(b) + 1e-9:
            return True
    return False


def damage_seen(before, after):
    if after.get("S") is not None and before.get("S") is not None and int(after.get("S")) > int(before.get("S")) + 64:
        return True
    for key in ("P_16", "P_32", "kappa_max", "closure_shell_score"):
        b = before.get(key)
        a = after.get(key)
        if b is not None and a is not None and float(a) + 1e-9 < 0.5 * float(b):
            return True
    return False


def improve_flags(before_eval, after_eval):
    return {
        "score_improvement_seen": int(after_eval.get("S", 0)) < int(before_eval.get("S", 0)),
        "score0_seen": int(after_eval.get("S", 0)) == 0 and int(before_eval.get("S", 0)) > 0,
        "exactlike_improvement_seen": exactlike_improved(before_eval, after_eval),
        "D_min_ratio_improved": before_eval.get("D_min_ratio") is not None and after_eval.get("D_min_ratio") is not None and float(after_eval["D_min_ratio"]) < float(before_eval["D_min_ratio"]),
        "P_tau_improved": any(before_eval.get(k) is not None and after_eval.get(k) is not None and float(after_eval[k]) > float(before_eval[k]) for k in ("P_16", "P_32")),
        "kappa_improved": any(before_eval.get(k) is not None and after_eval.get(k) is not None and float(after_eval[k]) > float(before_eval[k]) for k in ("kappa_max", "kappa_q99")),
        "closure_shell_improved": after_eval.get("closure_shell_score") is not None and before_eval.get("closure_shell_score") is not None and float(after_eval["closure_shell_score"]) > float(before_eval["closure_shell_score"]),
        "alignment_improved": after_eval.get("best_alignment_to_minus_rho") is not None and before_eval.get("best_alignment_to_minus_rho") is not None and float(after_eval["best_alignment_to_minus_rho"]) > float(before_eval["best_alignment_to_minus_rho"]),
        "damage_seen": damage_seen(before_eval, after_eval),
    }


def generate_move_sets(mode, blocks, split, pair_before, rho, p, sample_count, rng):
    top_ds = top_defect_coords(rho, 10)
    if mode == "baseline_score_only_recheck":
        return [[move] for move in sample_swaps(blocks, range(4), p, sample_count, rng, top_ds)]
    if mode in ("pair_profile_plus_movespace_filter", "hybrid_pair_repair_to_closure_shell"):
        side = choose_side(pair_before, mode, rng)
        return [[move] for move in sample_swaps(blocks, side_indices(split, side), p, sample_count, rng, top_ds)]
    if mode == "focused_plus_small_threshold_reference":
        return [[move] for move in sample_swaps(blocks, range(4), p, sample_count, rng, top_ds)]
    if mode == "exact_joint_pair_lns":
        side = choose_side(pair_before, mode, rng)
        pool = sample_swaps(blocks, side_indices(split, side), p, max(2, int(sample_count) * 2), rng, top_ds)
        out = [[move] for move in pool[: max(1, int(sample_count) // 2)]]
        for i in range(0, len(pool) - 1, 2):
            out.append([pool[i], pool[i + 1]])
            if len(out) >= int(sample_count):
                break
        return out
    return []


def should_record_snapshot(step, accepted, args):
    if int(step) in (0, 1, 25, 50, 100, 150, 200, 300, 500):
        return True
    interval = int(getattr(args, "snapshot_interval", 0) or 0)
    return interval > 0 and int(step) % interval == 0


def attempt_repair(candidate, split, mode, args, exact_by_split, restart_id=0):
    p = int(candidate["p"])
    ks = tuple(int(k) for k in candidate["ks"])
    lam = int(candidate["lambda"])
    seed = deterministic_seed("{}:{}:{}:{}:{}".format(candidate["candidate_hash"], split[0], mode, restart_id, args.seed))
    rng = random.Random(seed)
    initial_blocks = [set(int(x) for x in block) for block in candidate["blocks"]]
    current_blocks = clone_blocks(initial_blocks)
    before_eval, _per, _counts, rho = eval_blocks(current_blocks, p, ks, lam, exact_by_split, int(args.diagnostic_swaps), rng)
    pair_before = pair_features_for_split(current_blocks, p, lam, split, exact_by_split)
    snapshots = []
    generated = []
    best_blocks = clone_blocks(current_blocks)
    best_eval = dict(before_eval)
    best_pair = dict(pair_before)
    best_obj = candidate_objective(mode, before_eval, before_eval, pair_before, pair_before)
    accepted = 0

    snapshots.append(snapshot_row(candidate, split, mode, 0, 0, before_eval, pair_before, "initial"))

    if mode == "sketch_mitm_pair_generation":
        mitm_generated, mitm_best = run_sketch_mitm(candidate, split, args, exact_by_split, before_eval, pair_before, rng)
        generated.extend(mitm_generated)
        if mitm_best:
            best_blocks = [set(int(x) for x in block) for block in mitm_best["_blocks"]]
            best_eval = mitm_best["_eval"]
            best_pair = mitm_best["_pair"]
            accepted = 1 if int(best_eval.get("S", 0)) <= int(before_eval.get("S", 0)) or exactlike_improved(before_eval, best_eval) else 0
            snapshots.append(snapshot_row(candidate, split, mode, 1, accepted, best_eval, best_pair, "mitm_best"))
    else:
        for step in range(1, int(args.repair_steps) + 1):
            current_eval, _per, _counts, rho = eval_blocks(current_blocks, p, ks, lam, exact_by_split, int(args.diagnostic_swaps), rng)
            pair_current = pair_features_for_split(current_blocks, p, lam, split, exact_by_split)
            move_sets = generate_move_sets(mode, current_blocks, split, pair_current, rho, p, int(args.repair_samples), rng)
            prefiltered = []
            for moves in move_sets:
                delta = combined_delta_for_moves(current_blocks, moves, p)
                if delta is None:
                    continue
                approx_score = score_with_delta(rho, delta, p)
                prefiltered.append((approx_score, move_signature(moves), moves))
            prefiltered.sort(key=lambda item: (int(item[0]), item[1]))

            candidates = []
            for approx_score, _approx_sig, moves in prefiltered[: max(1, int(args.eval_top_k))]:
                trial_blocks = apply_moves(current_blocks, moves)
                if trial_blocks is None or not validate_blocks(trial_blocks, p, ks):
                    continue
                trial_eval, _tper, _tcounts, _trho = eval_blocks(trial_blocks, p, ks, lam, exact_by_split, int(args.diagnostic_swaps), rng)
                trial_pair = pair_features_for_split(trial_blocks, p, lam, split, exact_by_split)
                if mode == "pair_profile_plus_movespace_filter":
                    if damage_seen(current_eval, trial_eval):
                        continue
                    if trial_eval.get("P_16") is not None and current_eval.get("P_16") is not None and float(trial_eval["P_16"]) + 1e-9 < 0.5 * float(current_eval["P_16"]):
                        continue
                    if trial_eval.get("P_32") is not None and current_eval.get("P_32") is not None and float(trial_eval["P_32"]) + 1e-9 < 0.5 * float(current_eval["P_32"]):
                        continue
                obj = candidate_objective(mode, before_eval, trial_eval, pair_current, trial_pair)
                candidates.append((obj, trial_eval.get("S"), move_signature(moves), moves, trial_blocks, trial_eval, trial_pair))
            if not candidates:
                break
            candidates.sort(key=lambda item: (float(item[0]), int(item[1]), item[2]))
            obj, _score, _sig, moves, trial_blocks, trial_eval, trial_pair = candidates[0]
            current_obj = candidate_objective(mode, before_eval, current_eval, pair_before, pair_current)
            should_accept = obj <= current_obj or int(trial_eval.get("S", 0)) < int(current_eval.get("S", 0)) or exactlike_improved(current_eval, trial_eval)
            if mode == "hybrid_pair_repair_to_closure_shell":
                should_accept = should_accept or float(trial_eval.get("closure_shell_score") or 0) > float(current_eval.get("closure_shell_score") or 0)
            if mode == "focused_plus_small_threshold_reference":
                deltaS = int(trial_eval.get("S", 0)) - int(current_eval.get("S", 0))
                should_accept = should_accept or (
                    deltaS <= int(args.uphill_threshold)
                    and not damage_seen(current_eval, trial_eval)
                    and float(trial_eval.get("best_alignment_to_minus_rho") or 0.0) + 1e-9 >= 0.75 * float(current_eval.get("best_alignment_to_minus_rho") or 0.0)
                )
            if should_accept:
                current_blocks = trial_blocks
                accepted += 1
                current_eval = trial_eval
                pair_current = trial_pair
            if obj < best_obj or int(trial_eval.get("S", 0)) < int(best_eval.get("S", 0)) or exactlike_improved(best_eval, trial_eval):
                best_obj = obj
                best_blocks = trial_blocks
                best_eval = trial_eval
                best_pair = trial_pair
            if should_record_snapshot(step, accepted, args) or int(best_eval.get("S", 0)) < int(before_eval.get("S", 0)):
                snapshots.append(snapshot_row(candidate, split, mode, step, accepted, current_eval, pair_current, move_signature(moves)))
            if int(best_eval.get("S", 0)) == 0:
                break

    flags = improve_flags(before_eval, best_eval)
    after_eval, _aper, _acounts, _arho = eval_blocks(best_blocks, p, ks, lam, exact_by_split, int(args.diagnostic_swaps), rng)
    attempt = {
        "candidate_hash": candidate["candidate_hash"],
        "candidate_hash12": candidate["candidate_hash12"],
        "candidate_group": candidate.get("candidate_group"),
        "origin": candidate.get("origin"),
        "label": candidate.get("label"),
        "source_file": candidate.get("source_file"),
        "source_method": candidate.get("source_method"),
        "score_band": candidate.get("score_band"),
        "tuple": candidate.get("tuple"),
        "mode": mode,
        "split": split[0],
        "restart_id": int(restart_id),
        "left_blocks": [int(x) for x in split[1]],
        "right_blocks": [int(x) for x in split[2]],
        "accepted_moves": int(accepted),
        "parent_score": int(before_eval.get("S", 0)),
        "best_score": int(best_eval.get("S", 0)),
        "best_score_delta": int(best_eval.get("S", 0)) - int(before_eval.get("S", 0)),
        "final_score": int(after_eval.get("S", 0)),
        "before_D_min_ratio": before_eval.get("D_min_ratio"),
        "best_D_min_ratio": best_eval.get("D_min_ratio"),
        "before_P_8": before_eval.get("P_8"),
        "best_P_8": best_eval.get("P_8"),
        "before_P_16": before_eval.get("P_16"),
        "best_P_16": best_eval.get("P_16"),
        "before_P_32": before_eval.get("P_32"),
        "best_P_32": best_eval.get("P_32"),
        "before_kappa_max": before_eval.get("kappa_max"),
        "best_kappa_max": best_eval.get("kappa_max"),
        "before_kappa_q99": before_eval.get("kappa_q99"),
        "best_kappa_q99": best_eval.get("kappa_q99"),
        "before_closure_shell_score": before_eval.get("closure_shell_score"),
        "best_closure_shell_score": best_eval.get("closure_shell_score"),
        "before_alignment": before_eval.get("best_alignment_to_minus_rho"),
        "best_alignment": best_eval.get("best_alignment_to_minus_rho"),
        "before_pair_profile_l2": pair_before.get("pair_profile_l2"),
        "best_pair_profile_l2": best_pair.get("pair_profile_l2"),
        "before_pair_energy_gap": pair_before.get("pair_energy_gap"),
        "best_pair_energy_gap": best_pair.get("pair_energy_gap"),
        "before_distance_to_exact_pair_profile_l2": pair_before.get("distance_to_exact_pair_profile_l2"),
        "best_distance_to_exact_pair_profile_l2": best_pair.get("distance_to_exact_pair_profile_l2"),
        "best_side": pair_before.get("best_pair_side_to_repair"),
        "generated_candidate_count": len(generated),
    }
    attempt.update(flags)
    attempt["best_D_min_ratio_delta"] = delta_float(best_eval.get("D_min_ratio"), before_eval.get("D_min_ratio"))
    attempt["best_P_16_delta"] = delta_float(best_eval.get("P_16"), before_eval.get("P_16"))
    attempt["best_P_32_delta"] = delta_float(best_eval.get("P_32"), before_eval.get("P_32"))
    attempt["best_kappa_q99_delta"] = delta_float(best_eval.get("kappa_q99"), before_eval.get("kappa_q99"))
    attempt["best_alignment_delta"] = delta_float(best_eval.get("best_alignment_to_minus_rho"), before_eval.get("best_alignment_to_minus_rho"))
    attempt["best_closure_shell_delta"] = delta_float(best_eval.get("closure_shell_score"), before_eval.get("closure_shell_score"))
    attempt["best_pair_profile_l2_delta"] = delta_float(best_pair.get("pair_profile_l2"), pair_before.get("pair_profile_l2"))
    attempt["best_pair_energy_gap_delta"] = delta_float(best_pair.get("pair_energy_gap"), pair_before.get("pair_energy_gap"))
    attempt["pair_profile_improvement_seen"] = (
        best_pair.get("pair_profile_l2") is not None
        and pair_before.get("pair_profile_l2") is not None
        and float(best_pair["pair_profile_l2"]) < float(pair_before["pair_profile_l2"])
    )
    before_support = set(int(d) for d in before_eval.get("defect_support") or [])
    best_support = set(int(d) for d in best_eval.get("defect_support") or [])
    attempt["support_turnover_seen"] = before_support != best_support
    attempt["persistent_defect_fraction"] = float(len(before_support & best_support)) / float(len(before_support)) if before_support else 0.0
    attempt["defect_support_turnover"] = float(len(best_support - before_support)) / float(len(best_support)) if best_support else 0.0
    if int(best_eval.get("S", 0)) == 0 and int(before_eval.get("S", 0)) > 0:
        attempt["score0_candidate_hash"] = save_score0_candidate(args.out_dir, candidate, best_blocks, mode, split[0])
    return attempt, snapshots, generated


def snapshot_row(candidate, split, mode, step, accepted, metrics, pair_metrics, reason):
    row = {
        "candidate_hash": candidate["candidate_hash"],
        "candidate_hash12": candidate["candidate_hash12"],
        "candidate_group": candidate.get("candidate_group"),
        "source_method": candidate.get("source_method"),
        "score_band": candidate.get("score_band"),
        "mode": mode,
        "split": split[0],
        "step": int(step),
        "accepted_moves": int(accepted),
        "snapshot_reason": reason,
    }
    for key in (
        "S",
        "support_size",
        "S_over_support",
        "pm1_fraction",
        "max_abs_rho",
        "D_min_ratio",
        "P_4",
        "P_8",
        "P_16",
        "P_32",
        "kappa_max",
        "kappa_q99",
        "Q_ratio",
        "best_alignment_to_minus_rho",
        "closure_shell_score",
    ):
        row[key] = metrics.get(key)
    for key in (
        "pair_profile_l2",
        "pair_profile_l1",
        "pair_energy_gap",
        "distance_to_exact_pair_profile_l2",
        "positive_defect_contribution_balance",
        "negative_defect_contribution_balance",
        "best_pair_side_to_repair",
    ):
        row[key] = pair_metrics.get(key)
    return row


def side_variant(blocks, split, side, p, rng, rho, sample_count):
    indices = side_indices(split, side)
    moves = sample_swaps(blocks, indices, p, max(1, sample_count), rng, top_defect_coords(rho, 8))
    variants = [(clone_blocks(blocks), [])]
    for move in moves:
        trial = apply_moves(blocks, [move])
        if trial is not None:
            variants.append((trial, [move]))
    return variants


def profile_sketch(profile, coords):
    values = [int(profile[d]) for d in coords]
    hist = {}
    for value in profile[1:]:
        hist[int(value)] = hist.get(int(value), 0) + 1
    hist_part = [hist.get(v, 0) for v in range(0, 12)]
    return values + hist_part


def sketch_distance(left_profile, right_profile, lam, coords):
    target = [int(lam) - int(right_profile[d]) for d in coords]
    left = [int(left_profile[d]) for d in coords]
    coord_dist = sum((a - b) * (a - b) for a, b in zip(left, target))
    total_resid = sum((int(left_profile[d]) + int(right_profile[d]) - int(lam)) ** 2 for d in range(1, len(left_profile)))
    return int(coord_dist + total_resid)


def run_sketch_mitm(candidate, split, args, exact_by_split, before_eval, pair_before, rng):
    p = int(candidate["p"])
    ks = tuple(int(k) for k in candidate["ks"])
    lam = int(candidate["lambda"])
    blocks = [set(int(x) for x in block) for block in candidate["blocks"]]
    _metrics, _per, _counts, rho = eval_blocks(blocks, p, ks, lam, exact_by_split, int(args.diagnostic_swaps), rng)
    budget = max(4, int(args.mitm_budget_per_attempt))
    side_budget = max(2, int(math.sqrt(float(budget))) + 1)
    coords = top_defect_coords(rho, min(10, p - 1))
    left_variants = side_variant(blocks, split, "left", p, rng, rho, side_budget)
    right_variants = side_variant(blocks, split, "right", p, rng, rho, side_budget)
    left_rows = []
    right_rows = []
    for trial_blocks, moves in left_variants:
        per = per_block_diff_counts(p, trial_blocks)
        left, _right = pair_profile_for_split(per, split)
        left_rows.append((left, trial_blocks, moves, profile_sketch(left, coords)))
    for trial_blocks, moves in right_variants:
        per = per_block_diff_counts(p, trial_blocks)
        _left, right = pair_profile_for_split(per, split)
        right_rows.append((right, trial_blocks, moves, profile_sketch(right, coords)))
    generated = []
    best = None
    best_obj = None
    name, left_idx, right_idx = split
    considered = 0
    scored_pairs = []
    for left_profile, left_blocks_variant, left_moves, _left_sketch in left_rows:
        for right_profile, right_blocks_variant, right_moves, _right_sketch in right_rows:
            dist = sketch_distance(left_profile, right_profile, lam, coords)
            scored_pairs.append((dist, left_profile, right_profile, left_blocks_variant, right_blocks_variant, left_moves, right_moves))
    scored_pairs.sort(key=lambda row: row[0])
    for dist, _lp, _rp, left_blocks_variant, right_blocks_variant, left_moves, right_moves in scored_pairs[:budget]:
        combined = clone_blocks(blocks)
        for idx in left_idx:
            combined[int(idx)] = set(left_blocks_variant[int(idx)])
        for idx in right_idx:
            combined[int(idx)] = set(right_blocks_variant[int(idx)])
        if not validate_blocks(combined, p, ks):
            continue
        eval_row, _per, _counts, _rho = eval_blocks(combined, p, ks, lam, exact_by_split, int(args.diagnostic_swaps), rng)
        pair_row = pair_features_for_split(combined, p, lam, split, exact_by_split)
        h = canonical_hash(combined, ks, p)
        gen = {
            "parent_hash": candidate["candidate_hash"],
            "parent_hash12": candidate["candidate_hash12"],
            "candidate_hash": h,
            "candidate_hash12": h[:12],
            "candidate_group": candidate.get("candidate_group"),
            "source_method": candidate.get("source_method"),
            "score_band": candidate.get("score_band"),
            "parent_score": int(before_eval.get("S", 0)),
            "mode": "sketch_mitm_pair_generation",
            "split": name,
            "sketch_distance": int(dist),
            "score": int(eval_row.get("S", 0)),
            "score_delta": int(eval_row.get("S", 0)) - int(before_eval.get("S", 0)),
            "D_min_ratio": eval_row.get("D_min_ratio"),
            "P_8": eval_row.get("P_8"),
            "P_16": eval_row.get("P_16"),
            "P_32": eval_row.get("P_32"),
            "kappa_max": eval_row.get("kappa_max"),
            "kappa_q99": eval_row.get("kappa_q99"),
            "closure_shell_score": eval_row.get("closure_shell_score"),
            "best_alignment_to_minus_rho": eval_row.get("best_alignment_to_minus_rho"),
            "pair_profile_l2": pair_row.get("pair_profile_l2"),
            "pair_energy_gap": pair_row.get("pair_energy_gap"),
            "distance_to_exact_pair_profile_l2": pair_row.get("distance_to_exact_pair_profile_l2"),
            "left_moves": move_signature(left_moves),
            "right_moves": move_signature(right_moves),
            "blocks": json_blocks(combined),
        }
        generated.append(gen)
        obj = candidate_objective("sketch_mitm_pair_generation", before_eval, eval_row, pair_before, pair_row)
        if best is None or obj < best_obj or int(eval_row.get("S", 0)) < int(best["_eval"].get("S", 0)):
            best_obj = obj
            best = dict(gen)
            best["_blocks"] = clone_blocks(combined)
            best["_eval"] = eval_row
            best["_pair"] = pair_row
        considered += 1
        if considered >= budget:
            break
    return generated, best


def save_score0_candidate(out_dir, parent, blocks, mode, split_name):
    p = int(parent["p"])
    ks = tuple(int(k) for k in parent["ks"])
    h = canonical_hash(blocks, ks, p)
    ensure_dir(os.path.join(out_dir, "score0_candidates"))
    path = os.path.join(out_dir, "score0_candidates", "{}_{}_{}.json".format(h[:12], mode, split_name))
    payload = {
        "p": p,
        "v": p,
        "n": int(4 * p),
        "ks": [int(k) for k in ks],
        "lambda": int(parent["lambda"]),
        "score": 0,
        "blocks": json_blocks(blocks),
        "canonical_hash": h,
        "parent_hash": parent["candidate_hash"],
        "source_script": SCRIPT_NAME,
        "mode": mode,
        "split": split_name,
    }
    write_json(path, payload)
    return h


def build_summaries(attempts, generated):
    score_band_rows = []
    for band in SCORE_BAND_ORDER:
        rows = [row for row in attempts if row.get("score_band") == band]
        if rows:
            score_band_rows.append(summary_attempts(rows, {"score_band": band}))
    mode_rows = [summary_attempts(rows, {"mode": mode}) for mode, rows in sorted(rows_by_key(attempts, "mode").items())]
    split_rows = [summary_attempts(rows, {"split": split}) for split, rows in sorted(rows_by_key(attempts, "split").items())]
    source_rows = [summary_attempts(rows, {"source_method": method}) for method, rows in sorted(rows_by_key(attempts, "source_method").items())]
    candidate_rows = []
    for candidate_hash, rows in sorted(rows_by_key(attempts, "candidate_hash").items()):
        best = min(rows, key=lambda row: (int(row.get("best_score", 999999)), -float(row.get("best_closure_shell_delta") or 0.0), -float(row.get("best_alignment_delta") or 0.0)))
        recommendation = "archive"
        if best.get("score_improvement_seen") or float(best.get("best_closure_shell_delta") or 0.0) > 0.5:
            recommendation = "repair_target"
        elif best.get("exactlike_improvement_seen") or best.get("alignment_improved"):
            recommendation = "promising_for_deepening"
        elif best.get("support_turnover_seen"):
            recommendation = "needs_more_logging"
        elif int(best.get("parent_score", 999999)) in (164, 176):
            recommendation = "benchmark_trap"
        candidate_rows.append(
            {
                "candidate_hash": candidate_hash,
                "candidate_hash12": str(candidate_hash)[:12],
                "score": best.get("parent_score"),
                "score_band": best.get("score_band"),
                "tuple": best.get("tuple"),
                "source_method": best.get("source_method"),
                "best_mode": best.get("mode"),
                "best_split": best.get("split"),
                "best_score_delta": best.get("best_score_delta"),
                "best_D_min_ratio_delta": best.get("best_D_min_ratio_delta"),
                "best_P_16_delta": best.get("best_P_16_delta"),
                "best_P_32_delta": best.get("best_P_32_delta"),
                "best_kappa_q99_delta": best.get("best_kappa_q99_delta"),
                "best_alignment_delta": best.get("best_alignment_delta"),
                "best_closure_shell_delta": best.get("best_closure_shell_delta"),
                "best_pair_profile_delta": best.get("best_pair_profile_l2_delta"),
                "recommendation": recommendation,
            }
        )

    gen_summary = []
    for mode, rows in sorted(rows_by_key(generated, "mode").items()):
        gen_summary.append(summary_generated(rows, {"mode": mode}))
    for split, rows in sorted(rows_by_key(generated, "split").items()):
        gen_summary.append(summary_generated(rows, {"split": split}))
    return score_band_rows, mode_rows, split_rows, source_rows, candidate_rows, gen_summary


def rows_by_key(rows, key):
    out = {}
    for row in rows:
        out.setdefault(row.get(key), []).append(row)
    return out


def summary_attempts(rows, labels):
    candidate_count = len(set(row.get("candidate_hash") for row in rows))
    out = dict(labels)
    out.update(
        {
            "attempt_count": len(rows),
            "candidate_count": candidate_count,
            "score_improvement_count": sum(1 for row in rows if row.get("score_improvement_seen")),
            "score_improvement_rate": rate(rows, "score_improvement_seen"),
            "score0_count": sum(1 for row in rows if row.get("score0_seen")),
            "exactlike_improvement_count": sum(1 for row in rows if row.get("exactlike_improvement_seen")),
            "exactlike_improvement_rate": rate(rows, "exactlike_improvement_seen"),
            "D_min_ratio_improved_count": sum(1 for row in rows if row.get("D_min_ratio_improved")),
            "P_tau_improved_count": sum(1 for row in rows if row.get("P_tau_improved")),
            "kappa_improved_count": sum(1 for row in rows if row.get("kappa_improved")),
            "closure_shell_improved_count": sum(1 for row in rows if row.get("closure_shell_improved")),
            "closure_shell_improved_rate": rate(rows, "closure_shell_improved"),
            "alignment_improved_count": sum(1 for row in rows if row.get("alignment_improved")),
            "pair_profile_improvement_count": sum(1 for row in rows if row.get("pair_profile_improvement_seen")),
            "support_turnover_count": sum(1 for row in rows if row.get("support_turnover_seen")),
            "damage_count": sum(1 for row in rows if row.get("damage_seen")),
            "damage_rate": rate(rows, "damage_seen"),
            "median_best_score_delta": median(row.get("best_score_delta") for row in rows),
            "median_score_delta": median(row.get("best_score_delta") for row in rows),
            "median_best_D_min_ratio": median(row.get("best_D_min_ratio") for row in rows),
            "median_D_min_ratio_delta": median(row.get("best_D_min_ratio_delta") for row in rows),
            "median_best_P_8": median(row.get("best_P_8") for row in rows),
            "median_best_P_16": median(row.get("best_P_16") for row in rows),
            "median_P_16_delta": median(row.get("best_P_16_delta") for row in rows),
            "median_best_P_32": median(row.get("best_P_32") for row in rows),
            "median_P_32_delta": median(row.get("best_P_32_delta") for row in rows),
            "median_best_kappa_max": median(row.get("best_kappa_max") for row in rows),
            "median_best_kappa_q99": median(row.get("best_kappa_q99") for row in rows),
            "median_kappa_q99_delta": median(row.get("best_kappa_q99_delta") for row in rows),
            "median_best_closure_shell_score": median(row.get("best_closure_shell_score") for row in rows),
            "median_closure_shell_score_delta": median(row.get("best_closure_shell_delta") for row in rows),
            "median_best_alignment": median(row.get("best_alignment") for row in rows),
            "median_alignment_delta": median(row.get("best_alignment_delta") for row in rows),
            "median_pair_profile_l2_delta": median(row.get("best_pair_profile_l2_delta") for row in rows),
            "median_pair_energy_gap_delta": median(row.get("best_pair_energy_gap_delta") for row in rows),
            "median_support_turnover": median(row.get("defect_support_turnover") for row in rows),
            "median_best_distance_to_exact_pair_profile_l2": median(row.get("best_distance_to_exact_pair_profile_l2") for row in rows),
        }
    )
    return out


def summary_generated(rows, labels):
    out = dict(labels)
    out.update(
        {
            "generated_count": len(rows),
            "unique_generated_count": len(set(row.get("candidate_hash") for row in rows)),
            "score0_count": sum(1 for row in rows if int(row.get("score", 999999)) == 0),
            "score_improvement_count": sum(1 for row in rows if int(row.get("score_delta", 999999)) < 0),
            "score_improvement_rate": rate([dict(row, score_improved=int(row.get("score_delta", 999999)) < 0) for row in rows], "score_improved"),
            "median_score": median(row.get("score") for row in rows),
            "median_score_delta": median(row.get("score_delta") for row in rows),
            "median_D_min_ratio": median(row.get("D_min_ratio") for row in rows),
            "median_P_8": median(row.get("P_8") for row in rows),
            "median_P_16": median(row.get("P_16") for row in rows),
            "median_P_32": median(row.get("P_32") for row in rows),
            "median_kappa_max": median(row.get("kappa_max") for row in rows),
            "median_closure_shell_score": median(row.get("closure_shell_score") for row in rows),
            "median_pair_profile_l2": median(row.get("pair_profile_l2") for row in rows),
            "median_pair_energy_gap": median(row.get("pair_energy_gap") for row in rows),
            "median_distance_to_exact_pair_profile_l2": median(row.get("distance_to_exact_pair_profile_l2") for row in rows),
        }
    )
    return out


def summary_lookup(rows, key_name, key_value, metric):
    for row in rows:
        if row.get(key_name) == key_value:
            return row.get(metric)
    return None


def build_hypotheses(score_band_summary, mode_summary, split_summary, source_summary, generated_summary):
    baseline_score_rate = summary_lookup(mode_summary, "mode", "baseline_score_only_recheck", "score_improvement_rate")
    baseline_exact_rate = summary_lookup(mode_summary, "mode", "baseline_score_only_recheck", "exactlike_improvement_rate")
    baseline_closure = summary_lookup(mode_summary, "mode", "baseline_score_only_recheck", "closure_shell_improved_rate")
    focused_exact = summary_lookup(mode_summary, "mode", "focused_plus_small_threshold_reference", "exactlike_improvement_rate")
    pair_rows = [row for row in mode_summary if row.get("mode") not in ("baseline_score_only_recheck", "focused_plus_small_threshold_reference")]
    best_pair_score_rate = max([float(row.get("score_improvement_rate") or 0.0) for row in pair_rows] or [0.0])
    best_pair_exact_rate = max([float(row.get("exactlike_improvement_rate") or 0.0) for row in pair_rows] or [0.0])
    best_pair_closure = max([float(row.get("closure_shell_improved_rate") or 0.0) for row in pair_rows] or [0.0])
    hybrid_closure = summary_lookup(mode_summary, "mode", "hybrid_pair_repair_to_closure_shell", "closure_shell_improved_rate")

    h1 = "supported" if best_pair_score_rate > float(baseline_score_rate or 0.0) + 0.02 else "not_supported"
    h2 = "supported" if best_pair_exact_rate > float(baseline_exact_rate or 0.0) + 0.03 else ("partial" if best_pair_exact_rate > float(baseline_exact_rate or 0.0) else "not_supported")
    h3 = "supported" if float(hybrid_closure or 0.0) > max(float(baseline_closure or 0.0), float(summary_lookup(mode_summary, "mode", "focused_plus_small_threshold_reference", "closure_shell_improved_rate") or 0.0)) + 0.03 else "not_supported"

    s164 = summary_lookup(score_band_summary, "score_band", "score164", "exactlike_improvement_rate")
    s176 = summary_lookup(score_band_summary, "score_band", "score176", "exactlike_improvement_rate")
    s164_score = summary_lookup(score_band_summary, "score_band", "score164", "score_improvement_rate")
    s176_score = summary_lookup(score_band_summary, "score_band", "score176", "score_improvement_rate")
    if s164 is None or s176 is None:
        h4 = "inconclusive"
    elif abs(float(s164) - float(s176)) <= 0.05 and abs(float(s164_score or 0.0) - float(s176_score or 0.0)) <= 0.02:
        h4 = "supported"
    else:
        h4 = "not_supported"

    high_rows = [row for row in score_band_summary if row.get("score_band") in ("score180_184", "score188_192_200", "score216_228_232")]
    target_rows = [row for row in score_band_summary if row.get("score_band") in ("score164", "score176")]
    high_exact = median(row.get("exactlike_improvement_rate") for row in high_rows)
    target_exact = median(row.get("exactlike_improvement_rate") for row in target_rows)
    high_closure = median(row.get("closure_shell_improved_rate") for row in high_rows)
    target_closure = median(row.get("closure_shell_improved_rate") for row in target_rows)
    h5 = "supported" if high_exact is not None and target_exact is not None and (float(high_exact) > float(target_exact) + 0.03 or float(high_closure or 0.0) > float(target_closure or 0.0) + 0.03) else ("inconclusive" if high_exact is None or target_exact is None else "not_supported")

    split_rates = [float(row.get("exactlike_improvement_rate") or 0.0) for row in split_summary if row.get("split")]
    source_rates = [float(row.get("exactlike_improvement_rate") or 0.0) for row in source_summary if row.get("source_method") and row.get("attempt_count", 0) >= 10]
    split_gap = (max(split_rates) - min(split_rates)) if split_rates else 0.0
    source_gap = (max(source_rates) - min(source_rates)) if source_rates else 0.0
    h6 = "supported" if split_gap >= 0.05 or source_gap >= 0.10 else ("inconclusive" if not split_rates and not source_rates else "not_supported")

    gen_total = sum(int(row.get("generated_count") or 0) for row in generated_summary)
    gen_improve = sum(int(row.get("score_improvement_count") or 0) for row in generated_summary)
    gen_score0 = sum(int(row.get("score0_count") or 0) for row in generated_summary)
    h7 = "supported" if gen_improve > 0 or gen_score0 > 0 else ("not_supported" if gen_total > 0 else "inconclusive")

    return {
        "H_P167_MITM1": {
            "status": h1,
            "statement": "pair-level / closure-shell guided repair は baseline より score improvement を増やす。",
            "baseline_score_improvement_rate": baseline_score_rate,
            "best_pair_score_improvement_rate": best_pair_score_rate,
        },
        "H_P167_MITM2": {
            "status": h2,
            "statement": "score は下がらなくても exact-like metrics を改善する。",
            "baseline_exactlike_improvement_rate": baseline_exact_rate,
            "best_pair_exactlike_improvement_rate": best_pair_exact_rate,
            "focused_reference_exactlike_improvement_rate": focused_exact,
        },
        "H_P167_MITM3": {
            "status": h3,
            "statement": "hybrid_pair_repair_to_closure_shell は p167 near-hit でも closure_shell_score を改善する。",
            "baseline_closure_shell_improved_rate": baseline_closure,
            "hybrid_closure_shell_improved_rate": hybrid_closure,
        },
        "H_P167_MITM4": {
            "status": h4,
            "statement": "score164 と score176 は response 的にも同じ hard trap family に見える。",
            "score164_exactlike_rate": s164,
            "score176_exactlike_rate": s176,
            "score164_score_improvement_rate": s164_score,
            "score176_score_improvement_rate": s176_score,
        },
        "H_P167_MITM5": {
            "status": h5,
            "statement": "score が少し高い near-hit の方が pair-level / closure-shell response が良い。",
            "target_exactlike_rate_median": target_exact,
            "higher_score_exactlike_rate_median": high_exact,
            "target_closure_rate_median": target_closure,
            "higher_score_closure_rate_median": high_closure,
        },
        "H_P167_MITM6": {
            "status": h6,
            "statement": "split / source method ごとに response 差がある。",
            "split_exactlike_rate_gap": split_gap,
            "source_exactlike_rate_gap": source_gap,
        },
        "H_P167_MITM7": {
            "status": h7,
            "statement": "sketch MITM は score-only 由来と異なる exact-like candidate を生成できる。",
            "generated_count": gen_total,
            "generated_score_improvement_count": gen_improve,
            "generated_score0_count": gen_score0,
        },
    }


def write_summary(path, args, candidates, attempts, score_band_summary, mode_summary, split_summary, source_summary, candidate_summary, generated_summary, hypotheses):
    band_counts = {}
    for row in candidates:
        band = row.get("score_band")
        band_counts[band] = band_counts.get(band, 0) + 1
    score0_count = sum(1 for row in attempts if row.get("score0_seen"))
    s164_count = sum(1 for row in candidates if int(row.get("score", -1)) == 164)
    s176_count = sum(1 for row in candidates if int(row.get("score", -1)) == 176)
    best_mode = None
    if mode_summary:
        best_mode = max(mode_summary, key=lambda row: float(row.get("exactlike_improvement_rate") or 0.0)).get("mode")
    best_split = None
    if split_summary:
        best_split = max(split_summary, key=lambda row: float(row.get("exactlike_improvement_rate") or 0.0)).get("split")
    repair_targets = sum(1 for row in candidate_summary if row.get("recommendation") == "repair_target")
    benchmark_traps = sum(1 for row in candidate_summary if row.get("recommendation") == "benchmark_trap")
    with open(path, "w") as f:
        f.write("# p167 pair-level MITM repair diagnostic\n\n")
        f.write("このrunは Hadamard 668 構成runではなく、p167 near-hit に対する pair-level / MITM / closure-shell diagnostic です。\n\n")
        f.write("Important identity: pair_residual(d) = A_ab(d) - (lambda - B_cd(d)) = rho(d).\n")
        f.write("Therefore this run emphasizes left/right profile shape, pair balance, split preference, and sampled move-space / closure-shell deltas after exact joint 4-block rescoring.\n")
        f.write("Sampled diagnostics are not full certificates.\n\n")
        f.write("## Scope\n\n")
        f.write("- p: `{}`\n".format(args.p))
        f.write("- ks: `{}`\n".format(list(args.ks)))
        f.write("- lambda: `{}`\n".format(args.lam))
        f.write("- selected candidates this shard/run: `{}`\n".format(len(candidates)))
        f.write("- score164 candidates: `{}`\n".format(s164_count))
        f.write("- score176 candidates: `{}`\n".format(s176_count))
        f.write("- attempts: `{}`\n".format(len(attempts)))
        f.write("- shard: `{}/{}`\n".format(args.shard_index, args.shard_count))
        f.write("- repair_target recommendations: `{}`\n".format(repair_targets))
        f.write("- benchmark_trap recommendations: `{}`\n".format(benchmark_traps))
        f.write("\nScore band counts:\n")
        for band, count in sorted(band_counts.items()):
            f.write("- {}: `{}`\n".format(band, count))
        f.write("\n## Hypotheses\n\n")
        for key in sorted(hypotheses):
            f.write("- {}: `{}` - {}\n".format(key, hypotheses[key].get("status"), hypotheses[key].get("statement")))
        f.write("\n## Required Answers\n\n")
        f.write("1. p167 near-hit は何件対象にしたか: `{}`。\n".format(len(candidates)))
        f.write("2. score164 / score176 は何件対象にしたか: `{}` / `{}`。\n".format(s164_count, s176_count))
        f.write("3. pair-level / closure-shell guided repair は score164/176 の score を下げたか: H-P167-MITM1 `{}`。\n".format(hypotheses["H_P167_MITM1"]["status"]))
        f.write("4. score は下がらなくても D_min/S, P_tau, kappa は改善したか: H-P167-MITM2 `{}`。\n".format(hypotheses["H_P167_MITM2"]["status"]))
        f.write("5. closure_shell_score / alignment_to_minus_rho は改善したか: H-P167-MITM3 `{}`。\n".format(hypotheses["H_P167_MITM3"]["status"]))
        f.write("6. pair_profile_l2 / pair_energy_gap は改善したか: mode/split summary を参照。\n")
        f.write("7. hybrid_pair_repair_to_closure_shell は baseline / focused reference より良かったか: `{}`。\n".format(hypotheses["H_P167_MITM3"]["status"]))
        f.write("8. どの mode が一番有望か: `{}`。\n".format(best_mode))
        f.write("9. どの split が一番有望か: `{}`。\n".format(best_split))
        f.write("10. score164 と score176 は response 的にも同じ hard trap family か: `{}`。\n".format(hypotheses["H_P167_MITM4"]["status"]))
        f.write("11. score180〜232 の方が score164/176 より反応したか: `{}`。\n".format(hypotheses["H_P167_MITM5"]["status"]))
        f.write("12. source method 別に response 差はあるか: `{}`。\n".format(hypotheses["H_P167_MITM6"]["status"]))
        f.write("13. sketch MITM で input と異なる exact-like candidate を生成できたか: `{}`。\n".format(hypotheses["H_P167_MITM7"]["status"]))
        f.write("14. score164/176 をどこへ回すべきか: repair_target `{}`, benchmark_trap `{}`。aggregateで最終判断。\n".format(repair_targets, benchmark_traps))
        f.write("15. 次にやるべき実験: scoreが動かない場合は ALNS / Fourier phase / fresh generator を優先。closure-shellだけ動く場合は longer repair を検討。\n")
        f.write("\nscore=0 candidate は出たか: `{}`。score=0 以外を success とは呼ばない。\n".format(score0_count > 0))


def aggregate_roots(args):
    roots = file_roots(args.aggregate_roots)
    candidates = []
    attempts = []
    generated = []
    snapshots = []
    for root in roots:
        for path in glob.glob(os.path.join(root, "**", "input_p167_pair_mitm_candidates.jsonl"), recursive=True):
            candidates.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p167_pair_mitm_attempts.jsonl"), recursive=True):
            attempts.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p167_pair_mitm_generated_candidates.jsonl"), recursive=True):
            generated.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p167_pair_mitm_snapshots.jsonl"), recursive=True):
            snapshots.extend(read_jsonl(path))
    candidates = dedupe_rows(candidates, "candidate_hash")
    generated = dedupe_rows(generated, "candidate_hash")
    return candidates, attempts, generated, snapshots


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


def dedupe_rows(rows, key):
    out = []
    seen = set()
    for row in rows:
        value = row.get(key)
        if value in seen:
            continue
        seen.add(value)
        out.append(row)
    return out


def run(args):
    ensure_dir(args.out_dir)
    if args.aggregate_roots:
        candidates, attempts, generated, snapshots = aggregate_roots(args)
        if not candidates and not attempts and not generated:
            raise RuntimeError("No aggregate p167 pair-level MITM outputs were found in --aggregate-roots")
    else:
        roots = file_roots(args.candidate_roots)
        candidates_all = collect_candidates(args, roots)
        if not candidates_all:
            raise RuntimeError(
                "No p167 near-hit candidates matched the input roots. "
                "Use configs/fixtures/p167_focused_nearhit_candidates.jsonl or provide prior artifact roots."
            )
        candidates = shard_filter(candidates_all, args.shard_index, args.shard_count)
        exact_by_split = reference_profiles(args.reference_json, args.p, args.ks, args.lam)
        selected_splits = split_by_name(args.splits)
        selected_modes = parse_list(args.modes, DEFAULT_MODES)
        selected_modes = [mode for mode in selected_modes if mode in DEFAULT_MODES]
        if not selected_modes:
            raise RuntimeError("No valid modes selected")
        if "sketch_mitm_pair_generation" in selected_modes:
            denom = max(1, len(candidates) * len(selected_splits))
            args.mitm_budget_per_attempt = max(4, int(math.ceil(float(args.mitm_sketch_candidates) / float(denom))))
        else:
            args.mitm_budget_per_attempt = 0

        attempts = []
        generated = []
        snapshots = []
        for candidate in candidates:
            for split in selected_splits:
                for mode in selected_modes:
                    for restart_id in range(int(args.restarts)):
                        attempt, attempt_snapshots, attempt_generated = attempt_repair(candidate, split, mode, args, exact_by_split, restart_id)
                        attempts.append(attempt)
                        snapshots.extend(attempt_snapshots)
                        generated.extend(attempt_generated)

    score_band_summary, mode_summary, split_summary, source_summary, candidate_summary, generated_summary = build_summaries(attempts, generated)
    hypotheses = build_hypotheses(score_band_summary, mode_summary, split_summary, source_summary, generated_summary)

    run_config = vars(args).copy()
    run_config["script"] = SCRIPT_NAME
    run_config["candidate_count"] = len(candidates)
    run_config["attempt_count"] = len(attempts)
    run_config["generated_count"] = len(generated)
    run_config["timestamp"] = now_stamp()
    write_json(os.path.join(args.out_dir, "run_config.json"), run_config)
    with open(os.path.join(args.out_dir, "run_log.md"), "w") as f:
        f.write("# p167 pair-level MITM repair diagnostic run log\n\n")
        f.write("- script: `{}`\n".format(SCRIPT_NAME))
        f.write("- candidates: `{}`\n".format(len(candidates)))
        f.write("- attempts: `{}`\n".format(len(attempts)))
        f.write("- generated: `{}`\n".format(len(generated)))
        f.write("- shard: `{}/{}`\n".format(args.shard_index, args.shard_count))

    write_jsonl(os.path.join(args.out_dir, "input_p167_pair_mitm_candidates.jsonl"), candidates)
    write_jsonl(os.path.join(args.out_dir, "p167_pair_mitm_attempts.jsonl"), attempts)
    write_jsonl(os.path.join(args.out_dir, "p167_pair_mitm_generated_candidates.jsonl"), generated)
    write_jsonl(os.path.join(args.out_dir, "p167_pair_mitm_snapshots.jsonl"), snapshots)
    write_csv(os.path.join(args.out_dir, "p167_pair_mitm_score_band_summary.csv"), score_band_summary)
    write_json(os.path.join(args.out_dir, "p167_pair_mitm_score_band_summary.json"), score_band_summary)
    write_csv(os.path.join(args.out_dir, "p167_pair_mitm_mode_summary.csv"), mode_summary)
    write_json(os.path.join(args.out_dir, "p167_pair_mitm_mode_summary.json"), mode_summary)
    write_csv(os.path.join(args.out_dir, "p167_pair_mitm_split_summary.csv"), split_summary)
    write_json(os.path.join(args.out_dir, "p167_pair_mitm_split_summary.json"), split_summary)
    write_csv(os.path.join(args.out_dir, "p167_pair_mitm_source_method_summary.csv"), source_summary)
    write_json(os.path.join(args.out_dir, "p167_pair_mitm_source_method_summary.json"), source_summary)
    write_csv(os.path.join(args.out_dir, "p167_pair_mitm_candidate_summary.csv"), candidate_summary)
    write_json(os.path.join(args.out_dir, "p167_pair_mitm_candidate_summary.json"), candidate_summary)
    write_csv(os.path.join(args.out_dir, "p167_pair_mitm_generated_candidate_summary.csv"), generated_summary)
    write_json(os.path.join(args.out_dir, "p167_pair_mitm_generated_candidate_summary.json"), generated_summary)
    write_json(os.path.join(args.out_dir, "p167_pair_mitm_hypothesis_evaluation.json"), hypotheses)
    write_summary(
        os.path.join(args.out_dir, "p167_pair_level_mitm_repair_diagnostic_summary.md"),
        args,
        candidates,
        attempts,
        score_band_summary,
        mode_summary,
        split_summary,
        source_summary,
        candidate_summary,
        generated_summary,
        hypotheses,
    )

    print("Wrote p167 pair-level MITM repair diagnostic outputs to {}".format(args.out_dir))
    print("Candidates:", len(candidates), "Attempts:", len(attempts), "Generated:", len(generated))


def build_parser():
    parser = argparse.ArgumentParser(description=SCRIPT_NAME)
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--ks", type=parse_ks, default=KS_DEFAULT)
    parser.add_argument("--lambda", dest="lam", type=int, default=LAMBDA_DEFAULT)
    parser.add_argument("--reference-json", default="")
    parser.add_argument("--candidate-roots", default=",".join(DEFAULT_CANDIDATE_ROOTS))
    parser.add_argument("--aggregate-roots", default="")
    parser.add_argument("--max-candidates", type=int, default=300)
    parser.add_argument("--max-score", type=int, default=232)
    parser.add_argument("--max-scan-files", type=int, default=0)
    parser.add_argument("--score-set", default="164,176,180,184,188,192,200,216,228,232")
    parser.add_argument("--splits", default=",".join(name for name, _l, _r in SPLITS))
    parser.add_argument("--modes", default=",".join(DEFAULT_MODES))
    parser.add_argument("--restarts", type=int, default=3)
    parser.add_argument("--repair-samples", type=int, default=200)
    parser.add_argument("--repair-steps", type=int, default=50)
    parser.add_argument("--steps", dest="repair_steps", type=int, default=argparse.SUPPRESS)
    parser.add_argument("--diagnostic-swaps", type=int, default=80)
    parser.add_argument("--sample-swaps", dest="diagnostic_swaps", type=int, default=argparse.SUPPRESS)
    parser.add_argument("--eval-top-k", type=int, default=20)
    parser.add_argument("--snapshot-interval", type=int, default=100)
    parser.add_argument("--mitm-sketch-candidates", type=int, default=2000)
    parser.add_argument("--uphill-threshold", type=int, default=16)
    parser.add_argument("--seed", type=int, default=720167)
    parser.add_argument("--shard-index", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--out-dir", default=os.path.join("outputs", "explorations", "{}_p167_pair_level_mitm_repair_diagnostic".format(now_stamp())))
    return parser


if __name__ == "__main__":
    run(build_parser().parse_args())
