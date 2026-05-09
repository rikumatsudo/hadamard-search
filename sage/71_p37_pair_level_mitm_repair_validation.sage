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

from sds_repair_utils import canonical_hash, json_blocks, total_diff_counts


SCRIPT_NAME = "71_p37_pair_level_mitm_repair_validation"
P_DEFAULT = 37
KS_DEFAULT = (13, 16, 18, 18)
LAMBDA_DEFAULT = 28
EXACT_JSON_DEFAULT = "outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json"
DEFAULT_CANDIDATE_ROOTS = (
    "outputs/explorations",
    "outputs/candidates",
    "outputs/candidates/small_p",
)
SPLITS = (
    ("split_01_23", (0, 1), (2, 3)),
    ("split_02_13", (0, 2), (1, 3)),
    ("split_03_12", (0, 3), (1, 2)),
)
DEFAULT_MODES = (
    "baseline_no_pair_repair",
    "pair_profile_guided_single_side_repair",
    "pair_profile_guided_two_side_repair",
    "pair_profile_plus_movespace_filter",
    "sketch_mitm_pair_generation",
    "exact_joint_pair_lns",
    "hybrid_pair_repair_to_closure_shell",
)
LOW_SCORE_SET = set([0, 4, 8, 12, 16, 24, 32])
REPAIRABLE_PARENT_PREFIXES = set(
    [
        "182614375107",
        "2b5e24f7f5a4",
        "3cab4b5cd0ac",
        "8234e0fee3c8",
        "87eadfb3f68d",
    ]
)
SUCCESS_CHILD_PREFIXES = set(
    [
        "ef1f76f89e10",
        "fd24e3e8b366",
        "d3537488708b",
        "6b3c9c3982a1",
        "2dd1d10df43d",
    ]
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
        return set(LOW_SCORE_SET)
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
    ks = payload.get("ks")
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


def exact_profiles(exact_json, p, ks, lam):
    if not exact_json or not os.path.exists(exact_json):
        return {}
    with open(exact_json) as f:
        payload = json.load(f)
    blocks = blocks_from_payload(payload)
    got_p, got_ks, got_lam = params_from_payload(payload)
    if got_p != int(p) or tuple(got_ks or ()) != tuple(ks) or got_lam != int(lam):
        raise RuntimeError("exact_json parameters do not match p/ks/lambda")
    if not validate_blocks(blocks, p, ks):
        raise RuntimeError("exact_json blocks are invalid")
    per_counts = per_block_diff_counts(p, blocks)
    out = {}
    for split in SPLITS:
        name, _left_idx, _right_idx = split
        left, right = pair_profile_for_split(per_counts, split)
        out[name] = {"left": left, "right": right}
    return out


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
    if has_prefix(payload.get("canonical_hash"), SUCCESS_CHILD_PREFIXES) or has_prefix(payload.get("parent_hash"), REPAIRABLE_PARENT_PREFIXES):
        return "focused_success_child"
    if int(score) == 0:
        return "exact"
    if "exact_derived" in text or "exact_perturb" in text or "exactlike" in text or "exact_derived" in source or "exact_perturb" in source:
        return "exact_derived"
    if "false_like" in text or "false" in text or "hard_basin" in text:
        return "search_derived_false_like"
    if "search_derived" in text or "score_only" in text or "escapability" in text or "pipeline" in source:
        return "search_derived"
    return str(payload.get("origin") or payload.get("origin_type") or payload.get("origin_family") or "unknown")


def infer_label(payload, origin, score):
    label = payload.get("label") or payload.get("parent_label") or payload.get("candidate_label") or payload.get("source_label")
    if label:
        return str(label)
    if origin == "focused_success_child":
        return "focused_success_child"
    if int(score) == 0:
        return "exact"
    if origin == "exact_derived":
        return "exact_derived"
    if origin == "search_derived_false_like":
        return "false_like"
    return "unknown"


def source_mode(payload):
    return payload.get("mode") or payload.get("source_mode") or payload.get("search_method") or payload.get("strategy")


def candidate_group(row):
    h = str(row.get("candidate_hash") or "")
    score = int(row.get("score", 999999))
    origin = str(row.get("origin") or "")
    label = str(row.get("label") or "").lower()
    if has_prefix(h, SUCCESS_CHILD_PREFIXES) or (score == 0 and has_prefix(row.get("parent_hash"), REPAIRABLE_PARENT_PREFIXES)):
        return "focused_success_child"
    if score == 0 and origin == "focused_success_child":
        return "focused_success_child"
    if score == 0:
        return "exact"
    if score == 4 and has_prefix(h, REPAIRABLE_PARENT_PREFIXES):
        return "score4_false_like_repairable"
    if score == 4 and ("false_like" in label or "false" in origin or "search_derived" in origin):
        return "score4_false_like_failed"
    if origin == "exact_derived":
        return "exact_derived"
    if origin == "search_derived_false_like" or "false_like" in label:
        return "search_derived_false_like"
    if score in (8, 12, 16, 24, 32):
        return "other_low_score"
    return "ambiguous"


def candidate_preference(row):
    h = str(row.get("candidate_hash") or "")
    source = str(row.get("source_file") or "").lower()
    group = row.get("candidate_group")
    if has_prefix(h, SUCCESS_CHILD_PREFIXES) or (int(row.get("score", 999999)) == 0 and has_prefix(row.get("parent_hash"), REPAIRABLE_PARENT_PREFIXES)):
        return 100
    if "exact_v37_djokovic_2009_g_matrices_order37.json" in source:
        return 95
    if group == "exact":
        return 90
    if group == "focused_success_child":
        return 85
    if group == "score4_false_like_repairable":
        return 80
    if group == "score4_false_like_failed":
        return 75
    if group == "exact_derived":
        return 70
    if group == "search_derived_false_like":
        return 65
    if group == "other_low_score":
        return 60
    return 0


def score_band(score):
    score = int(score)
    if score == 0:
        return "score0"
    if score in (4, 8, 12, 16, 24, 32):
        return "score{}".format(score)
    return "other"


def collect_candidates(args, roots):
    p = int(args.p)
    ks = tuple(int(x) for x in args.ks)
    lam = int(args.lam)
    score_set = parse_score_set(args.score_set)
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
            if score not in score_set:
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
            occurrences.setdefault(h, []).append(
                {
                    "source_file": path,
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
                "score_band": score_band(score),
                "blocks": json_blocks(blocks),
                "candidate_hash": h,
                "candidate_hash12": str(h)[:12],
                "origin": origin,
                "label": label,
                "source_file": path,
                "source_mode": source_mode(payload),
                "source_origin": payload.get("origin") or payload.get("origin_type") or payload.get("origin_family"),
                "parent_hash": payload.get("parent_hash"),
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
    buckets = {
        "exact": [],
        "focused_success_child": [],
        "exact_derived": [],
        "score4_false_like_repairable": [],
        "score4_false_like_failed": [],
        "search_derived_false_like": [],
        "other_low_score": [],
        "ambiguous": [],
    }
    for row in rows:
        buckets.setdefault(row.get("candidate_group") or "ambiguous", []).append(row)
    for key in buckets:
        buckets[key].sort(key=lambda row: (int(row.get("score", 999999)), row.get("source_file") or "", row.get("candidate_hash") or ""))

    selected = []
    selected.extend(buckets["exact"][:50])
    selected.extend(buckets["focused_success_child"])
    selected.extend(buckets["exact_derived"][:50])
    selected.extend(buckets["score4_false_like_repairable"])
    selected.extend(buckets["score4_false_like_failed"])
    selected.extend(buckets["search_derived_false_like"][:60])
    selected.extend(buckets["other_low_score"][:100])
    selected.extend(buckets["ambiguous"][:40])

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
    swaps = list(all_possible_swaps(blocks, block_indices, p))
    if top_defects:
        preferred = []
        defects = set(int(d) for d in top_defects)
        for move in swaps:
            _idx, removed, added = move
            if ((removed - added) % p) in defects or ((added - removed) % p) in defects:
                preferred.append(move)
        if preferred:
            swaps = preferred + swaps
    rng.shuffle(swaps)
    return swaps[: int(sample_count)]


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
    all_swaps = list(all_possible_swaps(blocks, range(4), p))
    rng.shuffle(all_swaps)
    moves = all_swaps[: min(len(all_swaps), int(sample_count))]
    S = int(sum(int(rho[d]) * int(rho[d]) for d in range(1, p)))
    if not moves:
        return {
            "D_min_1": None,
            "D_min_ratio": None,
            "P_4": None,
            "P_8": None,
            "P_16": None,
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
    if mode == "baseline_no_pair_repair":
        return S
    if mode == "hybrid_pair_repair_to_closure_shell":
        return S + 0.02 * pair_dist + 0.01 * pair_l2 + 5.0 * d_ratio - 4.0 * closure - 2.0 * kappa
    if mode == "pair_profile_plus_movespace_filter":
        return S + 0.04 * pair_dist + 0.01 * pair_l2 + 4.0 * d_ratio - 2.0 * closure
    if mode == "exact_joint_pair_lns":
        return S + 0.03 * pair_dist + 0.02 * pair_l2 - closure
    if mode == "sketch_mitm_pair_generation":
        return S + 0.05 * pair_dist - 2.0 * closure
    return S + 0.05 * pair_dist + 0.02 * pair_l2


def exactlike_improved(before, after):
    if after.get("S") is not None and before.get("S") is not None and int(after.get("S")) < int(before.get("S")):
        return True
    b = before.get("D_min_ratio")
    a = after.get("D_min_ratio")
    if b is not None and a is not None and float(a) + 1e-9 < float(b):
        return True
    for key in ("P_8", "P_16", "kappa_max", "kappa_q99", "closure_shell_score", "best_alignment_to_minus_rho"):
        b = before.get(key)
        a = after.get(key)
        if b is not None and a is not None and float(a) > float(b) + 1e-9:
            return True
    return False


def damage_seen(before, after):
    if after.get("S") is not None and before.get("S") is not None and int(after.get("S")) > int(before.get("S")) + 16:
        return True
    for key in ("P_8", "P_16", "kappa_max", "closure_shell_score"):
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
        "P_tau_improved": any(before_eval.get(k) is not None and after_eval.get(k) is not None and float(after_eval[k]) > float(before_eval[k]) for k in ("P_8", "P_16")),
        "kappa_improved": any(before_eval.get(k) is not None and after_eval.get(k) is not None and float(after_eval[k]) > float(before_eval[k]) for k in ("kappa_max", "kappa_q99")),
        "closure_shell_improved": after_eval.get("closure_shell_score") is not None and before_eval.get("closure_shell_score") is not None and float(after_eval["closure_shell_score"]) > float(before_eval["closure_shell_score"]),
        "alignment_improved": after_eval.get("best_alignment_to_minus_rho") is not None and before_eval.get("best_alignment_to_minus_rho") is not None and float(after_eval["best_alignment_to_minus_rho"]) > float(before_eval["best_alignment_to_minus_rho"]),
        "damage_seen": damage_seen(before_eval, after_eval),
    }


def generate_move_sets(mode, blocks, split, pair_before, rho, p, sample_count, rng):
    top_ds = top_defect_coords(rho, 10)
    if mode == "baseline_no_pair_repair":
        return [[move] for move in sample_swaps(blocks, range(4), p, sample_count, rng, top_ds)]
    if mode in ("pair_profile_guided_single_side_repair", "pair_profile_plus_movespace_filter", "hybrid_pair_repair_to_closure_shell"):
        side = choose_side(pair_before, mode, rng)
        return [[move] for move in sample_swaps(blocks, side_indices(split, side), p, sample_count, rng, top_ds)]
    if mode == "pair_profile_guided_two_side_repair":
        left_moves = sample_swaps(blocks, side_indices(split, "left"), p, max(1, int(sample_count) // 2), rng, top_ds)
        right_moves = sample_swaps(blocks, side_indices(split, "right"), p, max(1, int(sample_count) // 2), rng, top_ds)
        out = []
        for left_move in left_moves[: max(1, int(math.sqrt(max(1, sample_count))))]:
            for right_move in right_moves[: max(1, int(math.sqrt(max(1, sample_count))))]:
                out.append([left_move, right_move])
                if len(out) >= int(sample_count):
                    return out
        return out
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


def attempt_repair(candidate, split, mode, args, exact_by_split):
    p = int(candidate["p"])
    ks = tuple(int(k) for k in candidate["ks"])
    lam = int(candidate["lambda"])
    seed = deterministic_seed("{}:{}:{}:{}".format(candidate["candidate_hash"], split[0], mode, args.seed))
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
            candidates = []
            for moves in move_sets:
                trial_blocks = apply_moves(current_blocks, moves)
                if trial_blocks is None or not validate_blocks(trial_blocks, p, ks):
                    continue
                trial_eval, _tper, _tcounts, _trho = eval_blocks(trial_blocks, p, ks, lam, exact_by_split, int(args.diagnostic_swaps), rng)
                trial_pair = pair_features_for_split(trial_blocks, p, lam, split, exact_by_split)
                if mode == "pair_profile_plus_movespace_filter":
                    if damage_seen(current_eval, trial_eval):
                        continue
                    if trial_eval.get("P_8") is not None and current_eval.get("P_8") is not None and float(trial_eval["P_8"]) + 1e-9 < 0.5 * float(current_eval["P_8"]):
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
        "score_band": candidate.get("score_band"),
        "mode": mode,
        "split": split[0],
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
        "before_distance_to_exact_pair_profile_l2": pair_before.get("distance_to_exact_pair_profile_l2"),
        "best_distance_to_exact_pair_profile_l2": best_pair.get("distance_to_exact_pair_profile_l2"),
        "best_side": pair_before.get("best_pair_side_to_repair"),
        "generated_candidate_count": len(generated),
    }
    attempt.update(flags)
    if int(best_eval.get("S", 0)) == 0 and int(before_eval.get("S", 0)) > 0:
        attempt["score0_candidate_hash"] = save_score0_candidate(args.out_dir, candidate, best_blocks, mode, split[0])
    return attempt, snapshots, generated


def snapshot_row(candidate, split, mode, step, accepted, metrics, pair_metrics, reason):
    row = {
        "candidate_hash": candidate["candidate_hash"],
        "candidate_hash12": candidate["candidate_hash12"],
        "candidate_group": candidate.get("candidate_group"),
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
            "mode": "sketch_mitm_pair_generation",
            "split": name,
            "sketch_distance": int(dist),
            "score": int(eval_row.get("S", 0)),
            "score_delta": int(eval_row.get("S", 0)) - int(before_eval.get("S", 0)),
            "D_min_ratio": eval_row.get("D_min_ratio"),
            "P_8": eval_row.get("P_8"),
            "P_16": eval_row.get("P_16"),
            "kappa_max": eval_row.get("kappa_max"),
            "kappa_q99": eval_row.get("kappa_q99"),
            "closure_shell_score": eval_row.get("closure_shell_score"),
            "best_alignment_to_minus_rho": eval_row.get("best_alignment_to_minus_rho"),
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
    mode_rows = [summary_attempts(rows, {"mode": mode}) for mode, rows in sorted(rows_by_key(attempts, "mode").items())]
    split_rows = [summary_attempts(rows, {"split": split}) for split, rows in sorted(rows_by_key(attempts, "split").items())]
    group_rows = [summary_attempts(rows, {"candidate_group": group}) for group, rows in sorted(rows_by_key(attempts, "candidate_group").items())]

    score4_rows = [
        row
        for row in attempts
        if row.get("candidate_group") in ("score4_false_like_repairable", "score4_false_like_failed")
    ]
    score4_summary = [
        summary_attempts(rows, {"candidate_group": group, "comparison": "score4_repairable_vs_failed"})
        for group, rows in sorted(rows_by_key(score4_rows, "candidate_group").items())
    ]

    gen_summary = []
    for mode, rows in sorted(rows_by_key(generated, "mode").items()):
        gen_summary.append(summary_generated(rows, {"mode": mode}))
    for split, rows in sorted(rows_by_key(generated, "split").items()):
        gen_summary.append(summary_generated(rows, {"split": split}))
    return mode_rows, split_rows, group_rows, score4_summary, gen_summary


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
            "damage_count": sum(1 for row in rows if row.get("damage_seen")),
            "damage_rate": rate(rows, "damage_seen"),
            "median_best_score_delta": median(row.get("best_score_delta") for row in rows),
            "median_best_D_min_ratio": median(row.get("best_D_min_ratio") for row in rows),
            "median_best_P_8": median(row.get("best_P_8") for row in rows),
            "median_best_P_16": median(row.get("best_P_16") for row in rows),
            "median_best_kappa_max": median(row.get("best_kappa_max") for row in rows),
            "median_best_kappa_q99": median(row.get("best_kappa_q99") for row in rows),
            "median_best_closure_shell_score": median(row.get("best_closure_shell_score") for row in rows),
            "median_best_alignment": median(row.get("best_alignment") for row in rows),
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
            "median_kappa_max": median(row.get("kappa_max") for row in rows),
            "median_closure_shell_score": median(row.get("closure_shell_score") for row in rows),
            "median_distance_to_exact_pair_profile_l2": median(row.get("distance_to_exact_pair_profile_l2") for row in rows),
        }
    )
    return out


def summary_lookup(rows, key_name, key_value, metric):
    for row in rows:
        if row.get(key_name) == key_value:
            return row.get(metric)
    return None


def build_hypotheses(mode_summary, split_summary, group_summary, score4_summary, generated_summary):
    baseline_score_rate = summary_lookup(mode_summary, "mode", "baseline_no_pair_repair", "score_improvement_rate")
    baseline_exact_rate = summary_lookup(mode_summary, "mode", "baseline_no_pair_repair", "exactlike_improvement_rate")
    pair_rows = [row for row in mode_summary if row.get("mode") != "baseline_no_pair_repair"]
    best_pair_score_rate = max([float(row.get("score_improvement_rate") or 0.0) for row in pair_rows] or [0.0])
    best_pair_exact_rate = max([float(row.get("exactlike_improvement_rate") or 0.0) for row in pair_rows] or [0.0])
    h1 = "supported" if best_pair_score_rate > float(baseline_score_rate or 0.0) + 0.02 or best_pair_exact_rate > float(baseline_exact_rate or 0.0) + 0.02 else "not_supported"

    filter_exact = summary_lookup(mode_summary, "mode", "pair_profile_plus_movespace_filter", "exactlike_improvement_rate")
    filter_damage = summary_lookup(mode_summary, "mode", "pair_profile_plus_movespace_filter", "damage_rate")
    raw_exact = summary_lookup(mode_summary, "mode", "pair_profile_guided_single_side_repair", "exactlike_improvement_rate")
    raw_damage = summary_lookup(mode_summary, "mode", "pair_profile_guided_single_side_repair", "damage_rate")
    if filter_exact is None or raw_exact is None:
        h2 = "inconclusive"
    elif float(filter_exact) >= float(raw_exact) and float(filter_damage or 1.0) <= float(raw_damage or 1.0):
        h2 = "supported"
    else:
        h2 = "partial" if float(filter_exact) > 0.0 else "not_supported"

    repairable_exact = summary_lookup(score4_summary, "candidate_group", "score4_false_like_repairable", "exactlike_improvement_rate")
    failed_exact = summary_lookup(score4_summary, "candidate_group", "score4_false_like_failed", "exactlike_improvement_rate")
    if repairable_exact is None or failed_exact is None:
        h3 = "inconclusive"
    elif abs(float(repairable_exact) - float(failed_exact)) >= 0.05:
        h3 = "supported"
    else:
        h3 = "not_supported"

    split_rates = [(row.get("split"), float(row.get("exactlike_improvement_rate") or 0.0)) for row in split_summary if row.get("split")]
    best_split, best_split_rate = max(split_rates, key=lambda item: item[1]) if split_rates else (None, None)
    median_split_rate = median([rate for _split, rate in split_rates])
    h4 = "supported" if best_split_rate is not None and best_split_rate >= float(median_split_rate or 0.0) + 0.05 else ("inconclusive" if not split_rates else "not_supported")

    gen_total = sum(int(row.get("generated_count") or 0) for row in generated_summary)
    gen_improve = sum(int(row.get("score_improvement_count") or 0) for row in generated_summary)
    gen_score0 = sum(int(row.get("score0_count") or 0) for row in generated_summary)
    h5 = "supported" if gen_score0 > 0 or gen_improve > 0 else ("not_supported" if gen_total > 0 else "inconclusive")

    best_closure_rate = max([float(row.get("closure_shell_improved_rate") or 0.0) for row in pair_rows] or [0.0])
    baseline_closure = summary_lookup(mode_summary, "mode", "baseline_no_pair_repair", "closure_shell_improved_rate")
    h6 = "supported" if best_closure_rate > float(baseline_closure or 0.0) + 0.02 else "not_supported"

    return {
        "H_MITM1": {
            "status": h1,
            "statement": "pair-level repair は score-only/no-pair baseline より score or exact-like improvement を増やす。",
            "baseline_score_improvement_rate": baseline_score_rate,
            "best_pair_score_improvement_rate": best_pair_score_rate,
            "baseline_exactlike_improvement_rate": baseline_exact_rate,
            "best_pair_exactlike_improvement_rate": best_pair_exact_rate,
        },
        "H_MITM2": {
            "status": h2,
            "statement": "pair-level profile と move-space 指標の併用は repair 成功候補を選びやすい。",
            "filtered_exactlike_rate": filter_exact,
            "single_side_exactlike_rate": raw_exact,
            "filtered_damage_rate": filter_damage,
            "single_side_damage_rate": raw_damage,
        },
        "H_MITM3": {
            "status": h3,
            "statement": "score4 repairable parent は pair-level repair response で failed parent と違う。",
            "repairable_exactlike_rate": repairable_exact,
            "failed_exactlike_rate": failed_exact,
        },
        "H_MITM4": {
            "status": h4,
            "statement": "特定 split が pair-level repair/generation に安定して有利。",
            "best_split": best_split,
            "best_split_exactlike_rate": best_split_rate,
        },
        "H_MITM5": {
            "status": h5,
            "statement": "sketch MITM は score-only 由来とは異なる exact-like candidate を生成できる。",
            "generated_count": gen_total,
            "generated_score_improvement_count": gen_improve,
            "generated_score0_count": gen_score0,
        },
        "H_MITM6": {
            "status": h6,
            "statement": "pair-level repair は closure shell score を改善できる。",
            "baseline_closure_shell_improved_rate": baseline_closure,
            "best_pair_closure_shell_improved_rate": best_closure_rate,
        },
    }


def write_summary(path, args, candidates, attempts, mode_summary, split_summary, group_summary, score4_summary, generated_summary, hypotheses):
    group_counts = {}
    for row in candidates:
        group = row.get("candidate_group")
        group_counts[group] = group_counts.get(group, 0) + 1
    score0_count = sum(1 for row in attempts if row.get("score0_seen"))
    best_mode = None
    if mode_summary:
        best_mode = max(mode_summary, key=lambda row: float(row.get("exactlike_improvement_rate") or 0.0)).get("mode")
    best_split = None
    if split_summary:
        best_split = max(split_summary, key=lambda row: float(row.get("exactlike_improvement_rate") or 0.0)).get("split")
    with open(path, "w") as f:
        f.write("# p37 pair-level MITM repair validation\n\n")
        f.write("このrunは Hadamard 668 構成runではなく、p37 candidate に対する pair-level partial repair / sketch MITM validation です。\n\n")
        f.write("Important identity: pair_residual(d) = A_ab(d) - (lambda - B_cd(d)) = rho(d).\n")
        f.write("Therefore this run evaluates left/right profile shape, exact pair-profile distance, split preference, and sampled move-space metrics after exact joint 4-block rescoring.\n\n")
        f.write("## Scope\n\n")
        f.write("- p: `{}`\n".format(args.p))
        f.write("- ks: `{}`\n".format(list(args.ks)))
        f.write("- lambda: `{}`\n".format(args.lam))
        f.write("- selected candidates this shard/run: `{}`\n".format(len(candidates)))
        f.write("- attempts: `{}`\n".format(len(attempts)))
        f.write("- shard: `{}/{}`\n".format(args.shard_index, args.shard_count))
        f.write("\nGroup counts:\n")
        for group, count in sorted(group_counts.items()):
            f.write("- {}: `{}`\n".format(group, count))
        f.write("\n## Hypotheses\n\n")
        for key in sorted(hypotheses):
            f.write("- {}: `{}` - {}\n".format(key, hypotheses[key].get("status"), hypotheses[key].get("statement")))
        f.write("\n## Required Answers\n\n")
        f.write("1. pair-level repair は baseline より score improvement を増やしたか: `{}`。\n".format(hypotheses["H_MITM1"]["status"]))
        f.write("2. pair-level repair は exact-like improvement を増やしたか: `{}`。\n".format(hypotheses["H_MITM1"]["status"]))
        f.write("3. score4 repairable parent と failed parent は repair response で分かれたか: `{}`。\n".format(hypotheses["H_MITM3"]["status"]))
        f.write("4. どの split が最も有用だったか: `{}`。\n".format(best_split))
        f.write("5. pair profile 単独と、move-space 指標併用のどちらが良かったか: `{}`。\n".format(hypotheses["H_MITM2"]["status"]))
        f.write("6. sketch MITM で score-only とは異なる候補を生成できたか: `{}`。\n".format(hypotheses["H_MITM5"]["status"]))
        f.write("7. score0 candidate は出たか: `{}`。出た場合は workflow 側で 08/05/04 validation step の対象にする。\n".format(score0_count > 0))
        f.write("8. closure shell score は pair-level repair で改善したか: `{}`。\n".format(hypotheses["H_MITM6"]["status"]))
        f.write("9. p167 に移すなら、best mode `{}`、best split `{}`、distance_to_exact_pair_profile_l2 / pair_profile_l2 / closure_shell_score / kappa_q99 delta を優先して見る。\n".format(best_mode, best_split))
        f.write("10. 次は p167 pair-level diagnostic に進むか: p37 で H_MITM1/H_MITM6 が supported/partial なら小予算 p167 diagnostic に進む価値がある。negative なら p37 で move proposal を調整する。\n")


def aggregate_roots(args):
    roots = file_roots(args.aggregate_roots)
    candidates = []
    attempts = []
    generated = []
    snapshots = []
    for root in roots:
        for path in glob.glob(os.path.join(root, "**", "input_pair_mitm_repair_candidates.jsonl"), recursive=True):
            candidates.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "pair_mitm_attempts.jsonl"), recursive=True):
            attempts.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "pair_mitm_generated_candidates.jsonl"), recursive=True):
            generated.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "pair_mitm_repair_snapshots.jsonl"), recursive=True):
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
    else:
        roots = file_roots(args.candidate_roots)
        candidates_all = collect_candidates(args, roots)
        candidates = shard_filter(candidates_all, args.shard_index, args.shard_count)
        exact_by_split = exact_profiles(args.exact_json, args.p, args.ks, args.lam)
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
                    attempt, attempt_snapshots, attempt_generated = attempt_repair(candidate, split, mode, args, exact_by_split)
                    attempts.append(attempt)
                    snapshots.extend(attempt_snapshots)
                    generated.extend(attempt_generated)

    mode_summary, split_summary, group_summary, score4_summary, generated_summary = build_summaries(attempts, generated)
    hypotheses = build_hypotheses(mode_summary, split_summary, group_summary, score4_summary, generated_summary)

    run_config = vars(args).copy()
    run_config["script"] = SCRIPT_NAME
    run_config["candidate_count"] = len(candidates)
    run_config["attempt_count"] = len(attempts)
    run_config["generated_count"] = len(generated)
    run_config["timestamp"] = now_stamp()
    write_json(os.path.join(args.out_dir, "run_config.json"), run_config)
    with open(os.path.join(args.out_dir, "run_log.md"), "w") as f:
        f.write("# p37 pair-level MITM repair validation run log\n\n")
        f.write("- script: `{}`\n".format(SCRIPT_NAME))
        f.write("- candidates: `{}`\n".format(len(candidates)))
        f.write("- attempts: `{}`\n".format(len(attempts)))
        f.write("- generated: `{}`\n".format(len(generated)))
        f.write("- shard: `{}/{}`\n".format(args.shard_index, args.shard_count))

    write_jsonl(os.path.join(args.out_dir, "input_pair_mitm_repair_candidates.jsonl"), candidates)
    write_jsonl(os.path.join(args.out_dir, "pair_mitm_attempts.jsonl"), attempts)
    write_jsonl(os.path.join(args.out_dir, "pair_mitm_generated_candidates.jsonl"), generated)
    write_jsonl(os.path.join(args.out_dir, "pair_mitm_repair_snapshots.jsonl"), snapshots)
    write_csv(os.path.join(args.out_dir, "pair_mitm_by_mode_summary.csv"), mode_summary)
    write_json(os.path.join(args.out_dir, "pair_mitm_by_mode_summary.json"), mode_summary)
    write_csv(os.path.join(args.out_dir, "pair_mitm_by_split_summary.csv"), split_summary)
    write_json(os.path.join(args.out_dir, "pair_mitm_by_split_summary.json"), split_summary)
    write_csv(os.path.join(args.out_dir, "pair_mitm_by_group_summary.csv"), group_summary)
    write_json(os.path.join(args.out_dir, "pair_mitm_by_group_summary.json"), group_summary)
    write_csv(os.path.join(args.out_dir, "score4_repairable_vs_failed_mitm_summary.csv"), score4_summary)
    write_json(os.path.join(args.out_dir, "score4_repairable_vs_failed_mitm_summary.json"), score4_summary)
    write_csv(os.path.join(args.out_dir, "mitm_generated_candidate_summary.csv"), generated_summary)
    write_json(os.path.join(args.out_dir, "mitm_generated_candidate_summary.json"), generated_summary)
    write_json(os.path.join(args.out_dir, "hypothesis_evaluation.json"), hypotheses)
    write_summary(
        os.path.join(args.out_dir, "p37_pair_level_mitm_repair_summary.md"),
        args,
        candidates,
        attempts,
        mode_summary,
        split_summary,
        group_summary,
        score4_summary,
        generated_summary,
        hypotheses,
    )

    print("Wrote p37 pair-level MITM repair outputs to {}".format(args.out_dir))
    print("Candidates:", len(candidates), "Attempts:", len(attempts), "Generated:", len(generated))


def build_parser():
    parser = argparse.ArgumentParser(description=SCRIPT_NAME)
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--ks", type=parse_ks, default=KS_DEFAULT)
    parser.add_argument("--lambda", dest="lam", type=int, default=LAMBDA_DEFAULT)
    parser.add_argument("--exact-json", default=EXACT_JSON_DEFAULT)
    parser.add_argument("--candidate-roots", default=",".join(DEFAULT_CANDIDATE_ROOTS))
    parser.add_argument("--aggregate-roots", default="")
    parser.add_argument("--max-candidates", type=int, default=2)
    parser.add_argument("--max-scan-files", type=int, default=0)
    parser.add_argument("--score-set", default="0,4,8,12,16,24,32")
    parser.add_argument("--splits", default=",".join(name for name, _l, _r in SPLITS))
    parser.add_argument("--modes", default="baseline_no_pair_repair")
    parser.add_argument("--repair-samples", type=int, default=5)
    parser.add_argument("--repair-steps", type=int, default=1)
    parser.add_argument("--diagnostic-swaps", type=int, default=30)
    parser.add_argument("--mitm-sketch-candidates", type=int, default=20)
    parser.add_argument("--seed", type=int, default=71037)
    parser.add_argument("--shard-index", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--out-dir", default=os.path.join("outputs", "explorations", "{}_p37_pair_level_mitm_repair_validation".format(now_stamp())))
    return parser


if __name__ == "__main__":
    run(build_parser().parse_args())
