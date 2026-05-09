from sage.all import *

import argparse
import csv
import glob
import hashlib
import json
import math
import os
import statistics
import time

from sds_repair_utils import canonical_hash, json_blocks, total_diff_counts


SCRIPT_NAME = "70_p37_pair_level_profile_validation"
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


def has_prefix(value, prefixes):
    text = str(value or "")
    return any(text.startswith(prefix) for prefix in prefixes)


def file_roots(text):
    if isinstance(text, (list, tuple)):
        return [str(x) for x in text if str(x).strip()]
    return [part.strip() for part in str(text).split(",") if part.strip()]


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


def vector_mean(xs):
    xs = [float(x) for x in xs]
    return sum(xs) / float(len(xs)) if xs else None


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
    if has_prefix(payload.get("canonical_hash"), SUCCESS_CHILD_PREFIXES):
        return "focused_success_child"
    if int(score) == 0 and ("score0_candidate" in source or "focused" in source):
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
    source = str(row.get("source_file") or "").lower()
    if has_prefix(h, SUCCESS_CHILD_PREFIXES):
        return "focused_success_child"
    if score == 0 and ("score0_candidate" in source or origin == "focused_success_child"):
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
    if has_prefix(h, SUCCESS_CHILD_PREFIXES):
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
                # Stored hashes are trusted for artifact provenance, but recompute
                # when a non-canonical hash-like field is absent in future payloads.
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
                    "D_min_ratio": maybe_float(payload.get("D_min_ratio")),
                    "P_4": maybe_float(payload.get("P_4")),
                    "P_8": maybe_float(payload.get("P_8")),
                    "P_16": maybe_float(payload.get("P_16")),
                    "kappa_max": maybe_float(payload.get("kappa_max")),
                    "kappa_q90": maybe_float(payload.get("kappa_q90")),
                    "kappa_q99": maybe_float(payload.get("kappa_q99")),
                    "Q_ratio": maybe_float(payload.get("Q_ratio")),
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


def split_features(candidate, split, per_counts, rho, exact_by_split):
    name, left_idx, right_idx = split
    lam = int(candidate["lambda"])
    left, right = pair_profile_for_split(per_counts, split)
    left_values = [int(left[d]) for d in range(1, len(left))]
    right_values = [int(right[d]) for d in range(1, len(right))]
    target_for_left = [0] + [int(lam) - int(right[d]) for d in range(1, len(right))]
    target_for_right = [0] + [int(lam) - int(left[d]) for d in range(1, len(left))]
    residual = [0] + [int(left[d]) - int(target_for_left[d]) for d in range(1, len(left))]
    positive_ds = [d for d in range(1, len(rho)) if int(rho[d]) > 0]
    negative_ds = [d for d in range(1, len(rho)) if int(rho[d]) < 0]

    left_target_l2 = l2_distance(left_values, target_for_left[1:])
    right_target_l2 = l2_distance(right_values, target_for_right[1:])
    left_repair_pressure = l1_distance(left_values, target_for_left[1:])
    right_repair_pressure = l1_distance(right_values, target_for_right[1:])
    if left_repair_pressure < right_repair_pressure:
        best_side = "left"
    elif right_repair_pressure < left_repair_pressure:
        best_side = "right"
    else:
        best_side = "tie"

    row = {
        "candidate_hash": candidate["candidate_hash"],
        "candidate_hash12": candidate["candidate_hash12"],
        "candidate_group": candidate["candidate_group"],
        "origin": candidate.get("origin"),
        "label": candidate.get("label"),
        "score": int(candidate.get("score")),
        "score_band": candidate.get("score_band"),
        "source_file": candidate.get("source_file"),
        "source_mode": candidate.get("source_mode"),
        "p": int(candidate.get("p")),
        "ks": candidate.get("ks"),
        "lambda": int(candidate.get("lambda")),
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
        "left_target_l2": int(left_target_l2),
        "right_target_l2": int(right_target_l2),
        "pair_profile_l2": l2_distance(left_values, right_values),
        "pair_profile_l1": l1_distance(left_values, right_values),
        "pair_profile_corr": correlation(left_values, right_values),
        "positive_defect_mass": int(sum(int(rho[d]) for d in positive_ds)),
        "negative_defect_mass": int(sum(-int(rho[d]) for d in negative_ds)),
        "left_positive_contribution": int(sum(int(left[d]) for d in positive_ds)),
        "right_positive_contribution": int(sum(int(right[d]) for d in positive_ds)),
        "left_negative_contribution": int(sum(int(left[d]) for d in negative_ds)),
        "right_negative_contribution": int(sum(int(right[d]) for d in negative_ds)),
        "left_repair_pressure": int(left_repair_pressure),
        "right_repair_pressure": int(right_repair_pressure),
        "best_pair_side_to_repair": best_side,
        "pair_residual_equals_rho": all(int(residual[d]) == int(rho[d]) for d in range(1, len(rho))),
        "D_min_ratio": candidate.get("D_min_ratio"),
        "P_4": candidate.get("P_4"),
        "P_8": candidate.get("P_8"),
        "P_16": candidate.get("P_16"),
        "kappa_max": candidate.get("kappa_max"),
        "kappa_q90": candidate.get("kappa_q90"),
        "kappa_q99": candidate.get("kappa_q99"),
        "Q_ratio": candidate.get("Q_ratio"),
    }
    row.update(exact_distance_metrics(left, right, exact_by_split.get(name)))
    return row


def build_feature_rows(candidates, exact_by_split):
    rows = []
    for candidate in candidates:
        blocks = [set(int(x) for x in block) for block in candidate["blocks"]]
        p = int(candidate["p"])
        lam = int(candidate["lambda"])
        per_counts = per_block_diff_counts(p, blocks)
        counts = total_diff_counts(p, blocks)
        rho = rho_vector(counts, lam)
        shape = defect_shape(rho)
        candidate["defect_support_size"] = shape["defect_support_size"]
        candidate["rho_value_counts"] = shape["rho_value_counts"]
        candidate["max_abs_rho"] = shape["max_abs_rho"]
        for split in SPLITS:
            row = split_features(candidate, split, per_counts, rho, exact_by_split)
            row.update(shape)
            rows.append(row)
    annotate_best_splits(rows)
    return rows


def annotate_best_splits(rows):
    by_candidate = {}
    for row in rows:
        by_candidate.setdefault(row["candidate_hash"], []).append(row)
    for cand_rows in by_candidate.values():
        valid = [row for row in cand_rows if row.get("distance_to_exact_pair_profile_l2") is not None]
        if valid:
            best_exact = min(valid, key=lambda row: (row["distance_to_exact_pair_profile_l2"], row["split"]))
            best_exact_split = best_exact["split"]
        else:
            best_exact_split = None
        best_balance = min(cand_rows, key=lambda row: (row["pair_energy_gap"], row["split"]))["split"]
        best_pair_l2 = min(cand_rows, key=lambda row: (row["pair_profile_l2"], row["split"]))["split"]
        for row in cand_rows:
            row["best_exact_distance_split"] = best_exact_split
            row["is_best_exact_distance_split"] = row["split"] == best_exact_split
            row["best_energy_balance_split"] = best_balance
            row["is_best_energy_balance_split"] = row["split"] == best_balance
            row["best_pair_profile_l2_split"] = best_pair_l2
            row["is_best_pair_profile_l2_split"] = row["split"] == best_pair_l2


def rows_by_key(rows, key):
    out = {}
    for row in rows:
        out.setdefault(row.get(key), []).append(row)
    return out


def summary_row(rows, label_fields):
    row = dict(label_fields)
    candidates = set(r.get("candidate_hash") for r in rows)
    row.update(
        {
            "row_count": len(rows),
            "candidate_count": len(candidates),
            "median_score": median(r.get("score") for r in rows),
            "median_pair_profile_l2": median(r.get("pair_profile_l2") for r in rows),
            "median_pair_profile_l1": median(r.get("pair_profile_l1") for r in rows),
            "median_pair_profile_corr": median(r.get("pair_profile_corr") for r in rows),
            "median_pair_energy_gap": median(r.get("pair_energy_gap") for r in rows),
            "median_pair_variance_gap": median(r.get("pair_variance_gap") for r in rows),
            "median_distance_to_exact_pair_profile_l2": median(r.get("distance_to_exact_pair_profile_l2") for r in rows),
            "median_distance_to_exact_pair_profile_l1": median(r.get("distance_to_exact_pair_profile_l1") for r in rows),
            "median_distance_to_exact_pair_profile_corr": median(r.get("distance_to_exact_pair_profile_corr") for r in rows),
            "median_left_repair_pressure": median(r.get("left_repair_pressure") for r in rows),
            "median_right_repair_pressure": median(r.get("right_repair_pressure") for r in rows),
            "median_D_min_ratio": median(r.get("D_min_ratio") for r in rows),
            "median_P_8": median(r.get("P_8") for r in rows),
            "median_P_16": median(r.get("P_16") for r in rows),
            "median_kappa_max": median(r.get("kappa_max") for r in rows),
        }
    )
    split_counts = {}
    for r in rows:
        if r.get("is_best_exact_distance_split"):
            split = r.get("split")
            split_counts[split] = split_counts.get(split, 0) + 1
    row["best_exact_distance_split_counts"] = split_counts
    return row


def build_summaries(feature_rows):
    by_group_rows = []
    for group, rows in sorted(rows_by_key(feature_rows, "candidate_group").items(), key=lambda item: str(item[0])):
        by_group_rows.append(summary_row(rows, {"candidate_group": group, "split": "all"}))
        for split, split_rows in sorted(rows_by_key(rows, "split").items(), key=lambda item: str(item[0])):
            by_group_rows.append(summary_row(split_rows, {"candidate_group": group, "split": split}))

    by_split_rows = []
    for split, rows in sorted(rows_by_key(feature_rows, "split").items(), key=lambda item: str(item[0])):
        by_split_rows.append(summary_row(rows, {"split": split, "candidate_group": "all"}))
        for group, group_rows in sorted(rows_by_key(rows, "candidate_group").items(), key=lambda item: str(item[0])):
            by_split_rows.append(summary_row(group_rows, {"split": split, "candidate_group": group}))

    score4_rows = [
        row
        for row in feature_rows
        if row.get("candidate_group") in ("score4_false_like_repairable", "score4_false_like_failed")
    ]
    score4_summary = []
    for group, rows in sorted(rows_by_key(score4_rows, "candidate_group").items(), key=lambda item: str(item[0])):
        score4_summary.append(summary_row(rows, {"comparison": "score4_repairable_vs_failed", "candidate_group": group, "split": "all"}))
        for split, split_rows in sorted(rows_by_key(rows, "split").items(), key=lambda item: str(item[0])):
            score4_summary.append(summary_row(split_rows, {"comparison": "score4_repairable_vs_failed", "candidate_group": group, "split": split}))

    exact_false_rows = [
        row
        for row in feature_rows
        if row.get("candidate_group")
        in ("exact", "exact_derived", "focused_success_child", "search_derived_false_like", "score4_false_like_repairable", "score4_false_like_failed")
    ]
    exact_false_summary = []
    for group, rows in sorted(rows_by_key(exact_false_rows, "candidate_group").items(), key=lambda item: str(item[0])):
        exact_false_summary.append(summary_row(rows, {"comparison": "exact_vs_false", "candidate_group": group, "split": "all"}))
        for split, split_rows in sorted(rows_by_key(rows, "split").items(), key=lambda item: str(item[0])):
            exact_false_summary.append(summary_row(split_rows, {"comparison": "exact_vs_false", "candidate_group": group, "split": split}))

    return by_group_rows, by_split_rows, score4_summary, exact_false_summary


def group_median(summary_rows, group, metric, split="all"):
    for row in summary_rows:
        if row.get("candidate_group") == group and row.get("split") == split:
            return row.get(metric)
    return None


def better_lower(left, right, min_abs=1.0, ratio=0.95):
    if left is None or right is None:
        return "inconclusive"
    if float(left) + float(min_abs) < float(right) and float(left) <= float(right) * float(ratio):
        return "supported"
    return "not_supported"


def build_hypotheses(by_group_rows, feature_rows):
    exact_like_groups = ("exact", "exact_derived", "focused_success_child")
    false_groups = ("search_derived_false_like", "score4_false_like_repairable", "score4_false_like_failed")
    exact_like_rows = [row for row in feature_rows if row.get("candidate_group") in exact_like_groups]
    false_rows = [row for row in feature_rows if row.get("candidate_group") in false_groups]
    exact_m = median(row.get("distance_to_exact_pair_profile_l2") for row in exact_like_rows)
    false_m = median(row.get("distance_to_exact_pair_profile_l2") for row in false_rows)
    h1_status = better_lower(exact_m, false_m, min_abs=1.0, ratio=0.90)

    repair_m = group_median(by_group_rows, "score4_false_like_repairable", "median_distance_to_exact_pair_profile_l2")
    failed_m = group_median(by_group_rows, "score4_false_like_failed", "median_distance_to_exact_pair_profile_l2")
    h2_status = better_lower(repair_m, failed_m, min_abs=1.0, ratio=0.95)

    exact_candidates = {}
    for row in exact_like_rows:
        if row.get("is_best_exact_distance_split"):
            exact_candidates[row["candidate_hash"]] = row.get("split")
    split_counts = {}
    for split in exact_candidates.values():
        split_counts[split] = split_counts.get(split, 0) + 1
    total_exact = max(1, len(exact_candidates))
    best_split = max(split_counts, key=lambda key: split_counts[key]) if split_counts else None
    best_rate = float(split_counts.get(best_split, 0)) / float(total_exact) if best_split else None
    h3_status = "supported" if best_rate is not None and best_rate >= 0.60 and total_exact >= 3 else ("inconclusive" if total_exact < 3 else "not_supported")

    h4_status = "supported" if h2_status == "supported" else ("partial" if h1_status == "supported" else "inconclusive")

    move_metric_rows = [row for row in feature_rows if row.get("D_min_ratio") is not None or row.get("kappa_max") is not None]
    if h1_status == "not_supported" and len(move_metric_rows) > 0:
        h5_status = "supported"
    elif len(move_metric_rows) == 0:
        h5_status = "inconclusive"
    else:
        h5_status = "partial"

    return {
        "H_PAIR1": {
            "status": h1_status,
            "statement": "exact-derived と search-derived false basin は pair-level profile で分かれる。",
            "exact_like_median_distance_to_exact_pair_l2": exact_m,
            "false_like_median_distance_to_exact_pair_l2": false_m,
        },
        "H_PAIR2": {
            "status": h2_status,
            "statement": "score4 repairable parent は failed parent より pair-level profile が exact-like に近い。",
            "repairable_median_distance_to_exact_pair_l2": repair_m,
            "failed_median_distance_to_exact_pair_l2": failed_m,
        },
        "H_PAIR3": {
            "status": h3_status,
            "statement": "特定 split が exact-side で安定して良い。",
            "best_split": best_split,
            "best_split_rate": best_rate,
            "best_split_counts": split_counts,
        },
        "H_PAIR4": {
            "status": h4_status,
            "statement": "pair-level profile は repair routing に使える。",
            "basis": "H_PAIR2 if available, otherwise H_PAIR1.",
        },
        "H_PAIR5": {
            "status": h5_status,
            "statement": "pair-level profile alone is not enough; combine with D_min/S, P_tau, kappa.",
            "rows_with_move_space_metrics": len(move_metric_rows),
        },
    }


def best_split_from_rows(feature_rows, metric="distance_to_exact_pair_profile_l2"):
    rows = [row for row in feature_rows if row.get(metric) is not None]
    if not rows:
        return None
    by_split = rows_by_key(rows, "split")
    med = {split: median(row.get(metric) for row in split_rows) for split, split_rows in by_split.items()}
    return min(med, key=lambda key: (med[key], key)) if med else None


def build_summary(config, candidates, feature_rows, by_group_rows, by_split_rows, score4_rows, exact_false_rows, hypotheses):
    group_counts = {}
    for row in candidates:
        group = row.get("candidate_group")
        group_counts[group] = group_counts.get(group, 0) + 1
    split = best_split_from_rows(feature_rows)
    lines = []
    lines.append("# p37 pair-level profile validation")
    lines.append("")
    lines.append("このrunは Hadamard 668 構成runではなく、p37 candidate の 2+2 pair aggregate profile を比較する解析です。")
    lines.append("")
    lines.append("## Scope")
    lines.append("")
    lines.append("- p: `{}`".format(config["p"]))
    lines.append("- ks: `{}`".format(config["ks"]))
    lines.append("- lambda: `{}`".format(config["lambda"]))
    lines.append("- selected candidates this shard/run: `{}`".format(len(candidates)))
    lines.append("- feature rows: `{}`".format(len(feature_rows)))
    lines.append("- shard: `{}/{}`".format(config["shard_index"], config["shard_count"]))
    lines.append("")
    lines.append("Group counts:")
    for key in sorted(group_counts):
        lines.append("- {}: `{}`".format(key, group_counts[key]))
    lines.append("")
    lines.append("Important identity: pair_residual(d) = left_pair_profile(d) - (lambda - right_pair_profile(d)) = rho(d).")
    lines.append("Therefore this analysis emphasizes left/right profile shape, balance, and distance to the known exact pair profile.")
    lines.append("")
    lines.append("## Hypotheses")
    lines.append("")
    for key in sorted(hypotheses):
        h = hypotheses[key]
        lines.append("- {}: `{}` - {}".format(key, h.get("status"), h.get("statement")))
    lines.append("")
    lines.append("## Key Tables")
    lines.append("")
    lines.append("Group-level medians are written to `pair_profile_by_group_summary.csv`.")
    lines.append("Split-level medians are written to `pair_profile_by_split_summary.csv`.")
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    lines.append("1. exact-derived と search-derived false basin は pair-level profile で分かれたか: `{}`。".format(hypotheses["H_PAIR1"]["status"]))
    lines.append("2. score4 repairable parent と failed parent は pair-level profile で分かれたか: `{}`。".format(hypotheses["H_PAIR2"]["status"]))
    lines.append("3. どの split が最も有用だったか: exact profile distance の中央値では `{}`。".format(split or "unknown"))
    lines.append("4. exact-side に安定した pair-level signature はあったか: `{}`。".format(hypotheses["H_PAIR3"]["status"]))
    lines.append("5. pair-level metrics は D_min/S, P_tau, kappa より追加情報を持つか: pair residual は rho と同一なので単独では限定的。ただし left/right shape と exact-pair distance は別特徴として保存した。")
    lines.append("6. pair-level profile は repair routing に使えそうか: `{}`。".format(hypotheses["H_PAIR4"]["status"]))
    lines.append("7. p167 に移すなら、pair_profile_l2、pair_energy_gap、distance_to_reference_pair_profile、split preference、positive/negative defect contribution を relative delta で見る。")
    lines.append("8. 次に pair-level MITM / partial repair に進む価値があるか: H_PAIR1/H_PAIR2/H_PAIR4 が supported/partial なら進める。negative でも pair residual identity の限界が分かるため、MITM では profile shape と move-space 指標を併用する。")
    lines.append("")
    return "\n".join(lines) + "\n"


def load_aggregate_rows(roots):
    candidates = {}
    features = []
    for root in roots:
        for path in glob.glob(os.path.join(root, "**", "input_pair_profile_candidates.jsonl"), recursive=True):
            for payload in iter_payloads(path):
                h = payload.get("candidate_hash")
                if h and h not in candidates:
                    candidates[h] = payload
        for path in glob.glob(os.path.join(root, "**", "pair_profile_features.jsonl"), recursive=True):
            for payload in iter_payloads(path):
                if payload.get("candidate_hash") and payload.get("split"):
                    features.append(payload)
    # Deduplicate feature rows by candidate/split.
    unique = {}
    for row in features:
        key = (row.get("candidate_hash"), row.get("split"))
        unique[key] = row
    return list(candidates.values()), [unique[key] for key in sorted(unique)]


def emit_outputs(out_dir, config, candidates, feature_rows):
    by_group_rows, by_split_rows, score4_summary, exact_false_summary = build_summaries(feature_rows)
    hypotheses = build_hypotheses(by_group_rows, feature_rows)
    write_json(os.path.join(out_dir, "run_config.json"), config)
    write_jsonl(os.path.join(out_dir, "input_pair_profile_candidates.jsonl"), candidates)
    write_jsonl(os.path.join(out_dir, "pair_profile_features.jsonl"), feature_rows)
    write_csv(os.path.join(out_dir, "pair_profile_by_group_summary.csv"), by_group_rows)
    write_json(os.path.join(out_dir, "pair_profile_by_group_summary.json"), {"rows": by_group_rows})
    write_csv(os.path.join(out_dir, "pair_profile_by_split_summary.csv"), by_split_rows)
    write_json(os.path.join(out_dir, "pair_profile_by_split_summary.json"), {"rows": by_split_rows})
    write_csv(os.path.join(out_dir, "score4_repairable_vs_failed_pair_profile.csv"), score4_summary)
    write_json(os.path.join(out_dir, "score4_repairable_vs_failed_pair_profile.json"), {"rows": score4_summary})
    write_csv(os.path.join(out_dir, "exact_vs_false_pair_profile_comparison.csv"), exact_false_summary)
    write_json(os.path.join(out_dir, "exact_vs_false_pair_profile_comparison.json"), {"rows": exact_false_summary})
    write_json(os.path.join(out_dir, "hypothesis_evaluation.json"), hypotheses)
    summary = build_summary(config, candidates, feature_rows, by_group_rows, by_split_rows, score4_summary, exact_false_summary, hypotheses)
    with open(os.path.join(out_dir, "p37_pair_level_profile_validation_summary.md"), "w") as f:
        f.write(summary)
    with open(os.path.join(out_dir, "run_log.md"), "w") as f:
        f.write("# p37 pair-level profile validation log\n\n")
        f.write("- script: `{}`\n".format(SCRIPT_NAME))
        f.write("- candidates: `{}`\n".format(len(candidates)))
        f.write("- feature rows: `{}`\n".format(len(feature_rows)))
        f.write("- shard: `{}/{}`\n".format(config.get("shard_index"), config.get("shard_count")))
        f.write("- note: no stochastic search was run; this is candidate/profile analysis only.\n")
    return hypotheses


def main():
    parser = argparse.ArgumentParser(description="p37 pair-level profile validation")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--ks", type=parse_ks, default=KS_DEFAULT)
    parser.add_argument("--lambda", dest="lam", type=int, default=LAMBDA_DEFAULT)
    parser.add_argument("--exact-json", default=EXACT_JSON_DEFAULT)
    parser.add_argument("--candidate-roots", default=",".join(DEFAULT_CANDIDATE_ROOTS))
    parser.add_argument("--score-set", default=",".join(str(x) for x in sorted(LOW_SCORE_SET)))
    parser.add_argument("--max-candidates", type=int, default=200)
    parser.add_argument("--max-scan-files", type=int, default=0)
    parser.add_argument("--shard-index", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--aggregate-roots", default="")
    parser.add_argument("--out-dir", default="")
    args = parser.parse_args()

    out_dir = args.out_dir or os.path.join(
        "outputs",
        "explorations",
        "{}_p37_pair_level_profile_validation".format(now_stamp()),
    )
    ensure_dir(out_dir)

    if args.aggregate_roots:
        aggregate_roots = file_roots(args.aggregate_roots)
        candidates, feature_rows = load_aggregate_rows(aggregate_roots)
        config = {
            "script": SCRIPT_NAME,
            "mode": "aggregate",
            "aggregate_roots": aggregate_roots,
            "p": int(args.p),
            "ks": [int(k) for k in args.ks],
            "lambda": int(args.lam),
            "candidate_count": len(candidates),
            "feature_row_count": len(feature_rows),
            "shard_index": None,
            "shard_count": None,
        }
        emit_outputs(out_dir, config, candidates, feature_rows)
        print("Wrote aggregate pair-level profile outputs to", out_dir)
        return

    roots = file_roots(args.candidate_roots)
    exact_by_split = exact_profiles(args.exact_json, int(args.p), tuple(args.ks), int(args.lam))
    candidates_all = collect_candidates(args, roots)
    candidates = shard_filter(candidates_all, int(args.shard_index), int(args.shard_count))
    if not candidates:
        raise RuntimeError("no p37 candidates found for this shard")
    feature_rows = build_feature_rows(candidates, exact_by_split)
    config = {
        "script": SCRIPT_NAME,
        "mode": "analyze",
        "candidate_roots": roots,
        "exact_json": args.exact_json,
        "p": int(args.p),
        "ks": [int(k) for k in args.ks],
        "lambda": int(args.lam),
        "score_set": sorted(parse_score_set(args.score_set)),
        "max_candidates": int(args.max_candidates),
        "selected_candidates_total": len(candidates_all),
        "selected_candidates_this_shard": len(candidates),
        "feature_row_count": len(feature_rows),
        "shard_index": int(args.shard_index),
        "shard_count": int(args.shard_count),
        "note": "No stochastic search was run. Pair residual equals global rho, so profile shape metrics are emphasized.",
    }
    emit_outputs(out_dir, config, candidates, feature_rows)
    print("Wrote pair-level profile outputs to", out_dir)


if __name__ == "__main__":
    main()
