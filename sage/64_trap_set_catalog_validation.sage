from sage.all import *

import argparse
import csv
import hashlib
import json
import math
import os
import re
import statistics
import subprocess
import sys
import time


SCRIPT_NAME = "64_trap_set_catalog_validation"
P37_SCORE_SET = set([4, 8, 12, 16, 24, 32])
P167_SCORE_SET = set([164, 168, 172, 176, 180, 184, 188, 192, 196, 200, 204, 208, 212, 216, 220, 224, 228, 232])
POWERS_DEFAULT = (2, 4, 6, 8, 10, 12)


def load_s62():
    here = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.path.join(os.getcwd(), "sage")
    path = os.path.join(here, "62_exactlike_guided_generator_validation.sage")
    ns = {"__name__": "sds62_trap_import"}
    with open(path) as f:
        code = compile(f.read(), path, "exec")
    exec(code, ns)
    return ns


S62 = load_s62()


P37_ROOTS = [
    "outputs/explorations/20260506_0915_small_p_escapability_validation",
    "outputs/explorations/20260506_0925_small_p_escapability_validation_all_modes_smoke",
    "outputs/explorations/20260506_1125_small_p_defect_targeted_lns_validation",
    "outputs/explorations/20260506_1200_p37_score4_false_basin_anatomy",
    "outputs/explorations/20260506_1557_p37_pipeline_framework",
    "outputs/explorations/20260506_1619_p37_classifier_feature_analysis",
    "outputs/explorations/20260506_1638_p37_trajectory_signature_tracking",
    "outputs/explorations/20260506_1657_p37_initialization_family_comparison",
    "outputs/explorations/20260506_1950_p37_exact_vs_search_low_score_comparison",
    "outputs/explorations/20260506_2216_p37_repair_lns_ablation",
    "outputs/explorations/20260507_0019_p37_exactlike_guided_generator_medium",
    "outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation",
    "outputs/candidates/small_p",
]


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


def parse_ks(text):
    return tuple(int(x.strip()) for x in text.split(",") if x.strip())


def median(values):
    values = [float(v) for v in values if v is not None]
    return statistics.median(values) if values else None


def mean(values):
    values = [float(v) for v in values if v is not None]
    return statistics.mean(values) if values else None


def count_by(rows, field):
    out = {}
    for row in rows:
        value = row.get(field)
        value = "missing" if value is None else str(value)
        out[value] = out.get(value, 0) + 1
    return {key: int(out[key]) for key in sorted(out)}


def histogram_int(rows, field):
    out = {}
    for row in rows:
        value = row.get(field)
        label = "missing" if value is None else str(int(value))
        out[label] = out.get(label, 0) + 1
    return {key: int(out[key]) for key in sorted(out, key=lambda x: (x == "missing", int(x) if x != "missing" else 0))}


def score_band(score):
    try:
        return str(int(score))
    except Exception:
        return "missing"


def all_json_files(root):
    if not os.path.exists(root):
        return []
    if os.path.isfile(root):
        return [root] if root.endswith(".json") or root.endswith(".jsonl") else []
    paths = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if name.endswith(".json") or name.endswith(".jsonl"):
                paths.append(os.path.join(dirpath, name))
    return paths


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
                        yield payload
        elif path.endswith(".json"):
            with open(path) as f:
                payload = json.load(f)
            if isinstance(payload, dict):
                yield payload
                for key in ("rows", "candidates", "results", "frontier", "items"):
                    items = payload.get(key)
                    if isinstance(items, list):
                        for item in items:
                            if isinstance(item, dict):
                                yield item
            elif isinstance(payload, list):
                for item in payload:
                    if isinstance(item, dict):
                        yield item
    except Exception:
        return


def blocks_from_payload(payload):
    raw = payload.get("blocks") or payload.get("X") or payload.get("sets")
    if raw is None:
        return None
    try:
        blocks = [set(int(x) for x in block) for block in raw]
    except Exception:
        return None
    return blocks if len(blocks) == 4 else None


def candidate_params(payload):
    p = payload.get("p", payload.get("v"))
    ks = payload.get("ks")
    lam = payload.get("lambda", payload.get("lam"))
    try:
        p = int(p) if p is not None else None
        ks = tuple(int(x) for x in ks) if ks is not None else None
        lam = int(lam) if lam is not None else None
    except Exception:
        return None, None, None
    return p, ks, lam


def validate_blocks(blocks, p, ks):
    if blocks is None or len(blocks) != 4 or ks is None:
        return False
    for block, k in zip(blocks, ks):
        if len(block) != int(k):
            return False
        if len(block) != len(set(block)):
            return False
        if any(int(x) < 0 or int(x) >= int(p) for x in block):
            return False
    return True


def infer_origin(payload, source_path, score):
    text = " ".join(
        str(payload.get(key, ""))
        for key in ("origin", "origin_type", "origin_family", "mode", "source", "source_path", "label", "parent_origin")
    ).lower()
    source = source_path.lower()
    if score == 0:
        return "exact"
    if "exact_perturb" in text or "exact_derived" in text or "exact_perturb" in source:
        return "exact_derived"
    if "false" in text or "hard_basin" in text:
        return "search_derived_false_basin"
    if "trajectory" in text or "score_only" in text or "threshold" in text or "search" in text:
        return "search_derived"
    return payload.get("origin") or payload.get("origin_type") or payload.get("origin_family") or "unknown"


def infer_p167_method(payload, source_path):
    text = " ".join(
        str(payload.get(key, ""))
        for key in ("origin", "origin_type", "origin_family", "mode", "source", "source_path", "label", "parent_path", "resume_json")
    ).lower()
    source = source_path.lower()
    source_rules = (
        ("beam", "beam"),
        ("ilp", "ilp"),
        ("filtered_2swap", "filtered_2swap"),
        ("filtered_3swap", "filtered_3swap"),
        ("coherent_multiswap", "coherent_multiswap"),
        ("escapability_aware", "escapability_aware"),
        ("pair_profile", "pair_profile"),
        ("pair_matched", "pair_profile"),
        ("steepest", "steepest"),
        ("seed", "seed"),
    )
    for token, label in source_rules:
        if token in source:
            return label
    text_rules = (
        ("beam", "beam"),
        ("ilp", "ilp"),
        ("filtered_2swap", "filtered_2swap"),
        ("filtered_3swap", "filtered_3swap"),
        ("coherent_multiswap", "coherent_multiswap"),
        ("escapability_aware", "escapability_aware"),
        ("pair_profile", "pair_profile"),
        ("pair_matched", "pair_profile"),
        ("steepest", "steepest"),
        ("seed", "seed"),
        ("frontier", "frontier"),
    )
    for token, label in text_rules:
        if token in text:
            return label
    if "frontier" in source:
        return "frontier"
    return payload.get("method") or payload.get("mode") or "unknown"


def infer_label(payload, origin, score, diag=None):
    label = payload.get("label") or payload.get("parent_label") or payload.get("candidate_label")
    if label:
        label = str(label)
        if label == "search_score4_false_like":
            return "search_derived_false_basin"
        return label
    if score == 0:
        return "exact"
    if origin == "exact_derived":
        return "exact_derived"
    if diag:
        return S62["label_candidate"](diag, {})
    return "unknown"


def collect_candidates_for_target(roots, target_p, target_ks, target_lam, score_set, max_scan_files=None):
    occurrences = {}
    first = {}
    files = []
    for root in roots:
        files.extend(all_json_files(root))
    if max_scan_files:
        files = files[: int(max_scan_files)]
    for path in files:
        for payload in iter_payloads(path):
            blocks = blocks_from_payload(payload)
            p, ks, lam = candidate_params(payload)
            if p is None and blocks is not None:
                p, ks, lam = target_p, target_ks, target_lam
            if p != int(target_p) or tuple(ks or ()) != tuple(target_ks) or lam != int(target_lam):
                continue
            if not validate_blocks(blocks, p, ks):
                continue
            counts = S62["total_diff_counts"](p, blocks)
            score = S62["score_counts"](counts, lam)
            if int(score) not in score_set:
                continue
            stored = payload.get("score")
            if stored is not None:
                try:
                    if int(stored) != int(score):
                        continue
                except Exception:
                    pass
            h = S62["canonical_hash"](blocks, ks, p)
            occurrences.setdefault(h, []).append(
                {
                    "source_file": path,
                    "source_mode": payload.get("mode"),
                    "source_label": payload.get("label"),
                    "source_origin": payload.get("origin") or payload.get("origin_type") or payload.get("origin_family"),
                }
            )
            if h not in first:
                origin = infer_origin(payload, path, score)
                first[h] = {
                    "p": int(p),
                    "ks": [int(k) for k in ks],
                    "lambda": int(lam),
                    "score": int(score),
                    "blocks": S62["json_blocks"](blocks),
                    "canonical_hash": h,
                    "origin": origin,
                    "candidate_label": payload.get("label"),
                    "source_file": path,
                    "source_mode": payload.get("mode"),
                    "source_origin": payload.get("origin") or payload.get("origin_type") or payload.get("origin_family"),
                }
    return list(first.values()), occurrences


def select_p37_candidates(raw_rows, max_total):
    score4_false = [
        row
        for row in raw_rows
        if row["score"] == 4 and row.get("origin") != "exact_derived"
    ]
    search_low = [
        row
        for row in raw_rows
        if row["score"] in (8, 12, 16) and row.get("origin") != "exact_derived"
    ]
    exact = [row for row in raw_rows if row.get("origin") == "exact_derived"]
    other = [
        row
        for row in raw_rows
        if row not in score4_false and row not in search_low and row not in exact
    ]
    score4_false.sort(key=lambda r: (r["source_file"], r["canonical_hash"]))
    search_low.sort(key=lambda r: (r["score"], r["source_file"], r["canonical_hash"]))
    exact.sort(key=lambda r: (r["score"], r["source_file"], r["canonical_hash"]))
    other.sort(key=lambda r: (r["score"], r["source_file"], r["canonical_hash"]))
    selected = score4_false[:30] + search_low[:80] + exact[:50] + other[:50]
    out = []
    seen = set()
    for row in selected:
        if row["canonical_hash"] in seen:
            continue
        seen.add(row["canonical_hash"])
        out.append(row)
        if len(out) >= int(max_total):
            break
    return out


def collect_p167_candidates(nearhit_dir, max_total, max_score=232, max_per_score=100, focus_scores=(164, 176)):
    buckets = {}
    for path in all_json_files(nearhit_dir):
        name = os.path.basename(path)
        if not name.endswith(".json"):
            continue
        match = re.search(r"v167_score(\d+)", name)
        if not match:
            continue
        if int(match.group(1)) > int(max_score):
            continue
        buckets.setdefault(int(match.group(1)), []).append(path)

    focus_scores = set(int(x) for x in focus_scores)
    files = []
    focus_files = []
    other_files = []
    for score in sorted(buckets):
        paths = sorted(buckets[score])
        if score in focus_scores:
            focus_files.extend(paths)
        else:
            other_files.extend(paths[: int(max_per_score)])
    files = focus_files + other_files
    if len(files) > int(max_total) * 3:
        files = files[: int(max_total) * 3]

    first = {}
    occurrences = {}
    score_buckets = {}
    for path in files:
        filename_score = int(re.search(r"v167_score(\d+)", os.path.basename(path)).group(1))
        for payload in iter_payloads(path):
            blocks = blocks_from_payload(payload)
            p, ks, lam = candidate_params(payload)
            n = payload.get("n")
            try:
                n = int(n) if n is not None else None
            except Exception:
                n = None
            if p is None and n == 668:
                p = 167
            if p != 167 or ks is None or lam is None:
                continue
            if not validate_blocks(blocks, p, ks):
                continue
            counts = S62["total_diff_counts"](p, blocks)
            score = int(S62["score_counts"](counts, lam))
            if score > int(max_score):
                continue
            stored = payload.get("score")
            if stored is not None:
                try:
                    if int(stored) != score:
                        continue
                except Exception:
                    pass
            if filename_score != score:
                # Keep the recomputed score authoritative, but avoid likely stale files.
                continue
            h = S62["canonical_hash"](blocks, ks, p)
            method = infer_p167_method(payload, path)
            seed = payload.get("seed")
            if seed is None:
                seed_match = re.search(r"seed(\d+)", os.path.basename(path))
                seed = int(seed_match.group(1)) if seed_match else None
            occurrences.setdefault(h, []).append(
                {
                    "source_file": path,
                    "source_mode": payload.get("mode"),
                    "source_label": payload.get("label"),
                    "source_method": method,
                    "score": score,
                }
            )
            if h not in first:
                first[h] = {
                    "p": 167,
                    "n": 668,
                    "ks": [int(k) for k in ks],
                    "lambda": int(lam),
                    "score": int(score),
                    "blocks": S62["json_blocks"](blocks),
                    "canonical_hash": h,
                    "origin": infer_origin(payload, path, score),
                    "candidate_label": payload.get("label"),
                    "source_file": path,
                    "source_mode": payload.get("mode"),
                    "source_method": method,
                    "source_origin": payload.get("origin") or payload.get("origin_type") or payload.get("origin_family"),
                    "seed": seed,
                }
                score_buckets.setdefault(score, []).append(first[h])

    selected = []
    seen = set()
    for score in sorted(score_buckets):
        rows = sorted(score_buckets[score], key=lambda r: (r["source_method"], r["source_file"], r["canonical_hash"]))
        limit = len(rows) if score in focus_scores else int(max_per_score)
        for row in rows[:limit]:
            if row["canonical_hash"] in seen:
                continue
            selected.append(row)
            seen.add(row["canonical_hash"])
    selected.sort(key=lambda r: (r["score"], r["tuple"] if "tuple" in r else ",".join(str(k) for k in r["ks"]), r.get("source_method") or "", r["source_file"]))
    return selected[: int(max_total)], occurrences


def rho_pair_payload(counts, lam):
    rho = S62["rho_vector"](counts, lam)
    p = len(rho)
    pairs = []
    value_counts = {}
    support_pairs = []
    for d in range(1, (p + 1) // 2):
        e = (-d) % p
        value = int(rho[d])
        mate = int(rho[e])
        if value != 0 or mate != 0:
            pair = (min(d, e), max(d, e))
            support_pairs.append(pair)
            pairs.append((pair[0], pair[1], value, mate))
            if value == mate:
                key = str(value)
            else:
                key = "{}:{}".format(value, mate)
            value_counts[key] = value_counts.get(key, 0) + 1
    positives = int(value_counts.get("1", 0))
    negatives = int(value_counts.get("-1", 0))
    other = int(sum(v for k, v in value_counts.items() if k not in ("1", "-1")))
    support_signature = ";".join("{}:{}".format(a, b) for a, b in support_pairs)
    value_pattern = "+pairs{}_ -pairs{}_ other{}".format(positives, negatives, other)
    return {
        "rho_support_signature": support_signature,
        "rho_value_pattern": value_pattern,
        "support_pairs": support_pairs,
        "values_on_pairs": pairs,
        "value_counts": value_counts,
        "support_pair_count": int(len(support_pairs)),
        "max_abs_rho": max([abs(int(rho[d])) for d in range(1, p)] or [0]),
        "rho_support_size": int(sum(1 for d in range(1, p) if int(rho[d]) != 0)),
    }


def pair_rep(pair, p):
    a, b = int(pair[0]) % p, int(pair[1]) % p
    a = min(a, (-a) % p)
    b = min(b, (-b) % p)
    return min(a, b)


def orbit_normalize(values_on_pairs, p, normalize_global_sign=True):
    if not values_on_pairs:
        return "empty"
    reps = []
    signs = [1, -1] if normalize_global_sign else [1]
    for multiplier in range(1, int(p)):
        rows = []
        for a, b, va, vb in values_on_pairs:
            d = pair_rep(((multiplier * int(a)) % p, (multiplier * int(b)) % p), p)
            value = int(va) if int(va) == int(vb) else (int(va), int(vb))
            rows.append((int(d), value))
        for sign in signs:
            normalized = []
            for d, value in rows:
                if isinstance(value, tuple):
                    val = (sign * value[0], sign * value[1])
                    val_txt = "{}:{}".format(val[0], val[1])
                else:
                    val_txt = str(sign * value)
                normalized.append((d, val_txt))
            normalized.sort()
            reps.append(";".join("{}={}".format(d, val) for d, val in normalized))
    return min(reps)


def bin_dmin(value):
    if value is None:
        return "missing"
    value = float(value)
    if value < 1.0:
        return "<1"
    if abs(value - 1.0) <= 1e-9:
        return "=1"
    if value < 1.5:
        return "1-1.5"
    if value < 2.0:
        return "1.5-2"
    return ">2"


def bin_p8(value):
    if value is None:
        return "missing"
    value = float(value)
    if value == 0.0:
        return "0"
    if value < 0.02:
        return "low"
    if value < 0.10:
        return "mid"
    return "high"


def bin_kappa(value):
    if value is None:
        return "missing"
    value = float(value)
    if value > 1.0:
        return ">1"
    if value >= 0.9:
        return "0.9-1"
    if value >= 0.75:
        return "0.75-0.9"
    return "<0.75"


def bin_qratio(value):
    if value is None:
        return "missing"
    value = float(value)
    if value < 10:
        return "<10"
    if value < 30:
        return "10-30"
    if value < 60:
        return "30-60"
    return ">60"


def repair_response_bin(row):
    if row.get("repair_score0_seen"):
        return "score0"
    if row.get("repair_score_improvement_seen"):
        return "score_improved"
    if row.get("repair_exactlike_improved"):
        return "exactlike_improved"
    if row.get("repair_damage_seen") or row.get("dynamic_weighting_damage_seen"):
        return "damaged"
    return "no_response"


def response_join_rows():
    paths = []
    for root in [
        "outputs/explorations/20260506_1125_small_p_defect_targeted_lns_validation",
        "outputs/explorations/20260506_2216_p37_repair_lns_ablation",
        "outputs/explorations/20260507_0019_p37_exactlike_guided_generator_medium",
        "outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation",
    ]:
        for name in (
            "repair_attempts.jsonl",
            "threshold_accepting_results.jsonl",
            "negative_cross_pair_results.jsonl",
            "sparse_vector_beam_results.jsonl",
            "exact_joint_rswap_results.jsonl",
            "pair_level_repair_results.jsonl",
            "weighting_attempts.jsonl",
        ):
            path = os.path.join(root, name)
            if os.path.exists(path):
                paths.append(path)
    rows = []
    for path in paths:
        for payload in iter_payloads(path):
            parent_hash = payload.get("parent_hash")
            if not parent_hash:
                continue
            mode = payload.get("mode") or payload.get("repair_mode") or os.path.basename(path).replace(".jsonl", "")
            score_after = payload.get("score_after", payload.get("best_S", payload.get("best_score_after", payload.get("true_score"))))
            parent_score = payload.get("parent_score")
            try:
                damage = score_after is not None and parent_score is not None and int(score_after) > int(parent_score)
            except Exception:
                damage = False
            rows.append(
                {
                    "parent_hash": parent_hash,
                    "operator": mode,
                    "score_improvement_seen": bool(payload.get("score_improvement_seen") or payload.get("true_score_improved")),
                    "score0_seen": bool(payload.get("score0_seen") or payload.get("success_score0")),
                    "exactlike_improved": bool(payload.get("exactlike_improved") or payload.get("escaped_false_basin")),
                    "damage_seen": bool(payload.get("weighted_false_basin_risk") or payload.get("score_damage_seen") or damage),
                    "score_after": score_after,
                    "D_min_ratio_after": payload.get("D_min_ratio_after") or payload.get("best_D_min_ratio"),
                    "P_8_after": payload.get("P_8_after") or payload.get("best_P_8"),
                    "kappa_after": payload.get("kappa_max_after") or payload.get("best_kappa_max"),
                }
            )
    return rows


def summarize_response_by_hash(response_rows):
    groups = {}
    for row in response_rows:
        groups.setdefault(row["parent_hash"], []).append(row)
    out = {}
    for h, rows in groups.items():
        score0 = any(row["score0_seen"] for row in rows)
        improved = any(row["score_improvement_seen"] for row in rows)
        exactlike = any(row["exactlike_improved"] for row in rows)
        damage = any(row["damage_seen"] for row in rows)
        best_score = None
        best_mode = None
        best_d = None
        best_p8 = None
        best_kappa = None
        for row in rows:
            score_after = row.get("score_after")
            if score_after is None:
                continue
            try:
                score_after = int(score_after)
            except Exception:
                continue
            if best_score is None or score_after < best_score:
                best_score = score_after
                best_mode = row.get("operator")
                best_d = row.get("D_min_ratio_after")
                best_p8 = row.get("P_8_after")
                best_kappa = row.get("kappa_after")
        out[h] = {
            "repair_score_improvement_seen": bool(improved),
            "repair_score0_seen": bool(score0),
            "repair_exactlike_improved": bool(exactlike),
            "repair_damage_seen": bool(damage),
            "repair_best_score_after": best_score,
            "repair_best_D_min_ratio_after": best_d,
            "repair_best_P_8_after": best_p8,
            "repair_best_kappa_after": best_kappa,
            "best_repair_mode": best_mode,
            "repair_attempt_count": int(len(rows)),
            "dynamic_weighting_response": response_label([row for row in rows if "dynamic_weighting" in str(row.get("operator")) or row.get("operator") == "static_weighted_score"]),
            "pair_level_response": response_label([row for row in rows if "pair_level" in str(row.get("operator"))]),
            "negative_cross_response": response_label([row for row in rows if "negative_cross" in str(row.get("operator"))]),
            "sparse_beam_response": response_label([row for row in rows if "sparse" in str(row.get("operator"))]),
        }
    return out


def response_label(rows):
    if not rows:
        return None
    if any(row["score0_seen"] for row in rows):
        return "score0"
    if any(row["score_improvement_seen"] for row in rows):
        return "score_improved"
    if any(row["exactlike_improved"] for row in rows):
        return "exactlike_improved"
    if any(row["damage_seen"] for row in rows):
        return "damaged"
    return "no_response"


def diagnostic_with_thresholds(blocks, counts, lam, p, baseline, max_moves=None):
    p = int(p)
    score, l1_error, max_abs_error, nonzero = [int(x) for x in S62["metrics_from_counts"](counts, lam)]
    moves = S62["one_swap_library"](blocks, counts, lam, p, max_moves=max_moves)
    h_values = [int(move["h"]) for move in moves]
    q_values = [int(move["q"]) for move in moves]
    kappas = [float(move["kappa"]) for move in moves if move["kappa"] is not None]
    improving = [move for move in moves if int(move["h"]) < 0]
    near = {threshold: sum(1 for move in moves if int(move["h"]) <= threshold) for threshold in (0, 4, 8, 16, 32)}
    theta = {
        frac: sum(1 for move in moves if score > 0 and int(move["h"]) <= float(frac) * float(score))
        for frac in (0.01, 0.05, 0.10)
    }
    h_min = min(h_values) if h_values else None
    d_min = None if h_min is None else int(score + h_min)
    structure = S62["block_structure_payload"](p, blocks, baseline)
    q_threshold = int(4 * (p - 1) * score)
    out = {
        "score": int(score),
        "l1": int(l1_error),
        "max_abs": int(max_abs_error),
        "nonzero": int(nonzero),
        "h_min": int(h_min) if h_min is not None else None,
        "D_min_1": int(d_min) if d_min is not None else None,
        "D_min_ratio": float(d_min) / float(score) if score > 0 and d_min is not None else None,
        "improving_swap_count": int(len(improving)),
        "P_<0": float(len(improving)) / float(len(moves)) if moves else None,
        "P_0": float(near[0]) / float(len(moves)) if moves else None,
        "P_4": float(near[4]) / float(len(moves)) if moves else None,
        "P_8": float(near[8]) / float(len(moves)) if moves else None,
        "P_16": float(near[16]) / float(len(moves)) if moves else None,
        "P_32": float(near[32]) / float(len(moves)) if moves else None,
        "P_thetaS_001": float(theta[0.01]) / float(len(moves)) if moves else None,
        "P_thetaS_005": float(theta[0.05]) / float(len(moves)) if moves else None,
        "P_thetaS_010": float(theta[0.10]) / float(len(moves)) if moves else None,
        "kappa_max": max(kappas) if kappas else None,
        "kappa_q90": S62["quantile"](kappas, 0.90),
        "kappa_q99": S62["quantile"](kappas, 0.99),
        "Q_tot": int(sum(q_values)),
        "Q_ratio": float(sum(q_values)) / float(q_threshold) if q_threshold > 0 else None,
        "InitHardness": float(structure["InitHardness"]),
        "E_total": int(structure["E_total"]),
        "AP_total": int(structure["AP_total"]),
        "E_excess_total": float(structure["E_excess_total"]),
        "AP_excess_total": float(structure["AP_excess_total"]),
        "num_swaps_diagnosed": int(len(moves)),
    }
    out.update(S62["moment_payload"](counts, lam, p, powers=POWERS_DEFAULT))
    return out


def feature_row(candidate, response_by_hash, occurrences, baseline_cache, p167_max_moves=500):
    p = int(candidate["p"])
    ks = tuple(int(k) for k in candidate["ks"])
    lam = int(candidate["lambda"])
    blocks = [set(block) for block in candidate["blocks"]]
    baseline_key = (p, ks)
    if baseline_key not in baseline_cache:
        baseline_cache[baseline_key] = S62["random_baseline_tuple"](p, ks)
    baseline = baseline_cache[baseline_key]
    counts = S62["total_diff_counts"](p, blocks)
    max_moves = None if p <= 67 else int(p167_max_moves)
    diag = diagnostic_with_thresholds(blocks, counts, lam, p, baseline, max_moves=max_moves)
    pattern = rho_pair_payload(counts, lam)
    orbit = orbit_normalize(pattern["values_on_pairs"], p, normalize_global_sign=True)
    orbit_no_sign = orbit_normalize(pattern["values_on_pairs"], p, normalize_global_sign=False)
    h = candidate["canonical_hash"]
    response = response_by_hash.get(h, {})
    label = infer_label(candidate, candidate.get("origin"), int(diag["score"]), diag)
    local_bin = "D{}_P8{}_K{}_Q{}".format(bin_dmin(diag.get("D_min_ratio")), bin_p8(diag.get("P_8")), bin_kappa(diag.get("kappa_max")), bin_qratio(diag.get("Q_ratio")))
    row = {
        "p": p,
        "n": int(candidate.get("n") or 4 * p),
        "ks": [int(k) for k in ks],
        "tuple": ",".join(str(k) for k in ks),
        "lambda": lam,
        "score": int(diag["score"]),
        "score_per_p": float(diag["score"]) / float(p),
        "l1": int(diag["l1"]),
        "max_abs": int(diag["max_abs"]),
        "nonzero": int(diag["nonzero"]),
        "canonical_hash": h,
        "origin": candidate.get("origin"),
        "source_file": candidate.get("source_file"),
        "source_mode": candidate.get("source_mode"),
        "source_method": candidate.get("source_method") or infer_p167_method(candidate, candidate.get("source_file", "")),
        "seed": candidate.get("seed"),
        "candidate_label": label,
        "occurrence_count": int(len(occurrences.get(h, []))),
        "source_run_count": int(len(set(item["source_file"] for item in occurrences.get(h, [])))),
        "source_mode_count": int(len(set(str(item.get("source_mode")) for item in occurrences.get(h, []) if item.get("source_mode") is not None))),
        "orbit_normalized_pattern": orbit,
        "orbit_normalized_pattern_no_global_sign": orbit_no_sign,
        "orbit_class_id": hashlib.sha1("{}|{}".format(p, orbit).encode("utf-8")).hexdigest()[:16],
        "D_min_ratio_bin": bin_dmin(diag.get("D_min_ratio")),
        "P_8_bin": bin_p8(diag.get("P_8")),
        "kappa_bin": bin_kappa(diag.get("kappa_max")),
        "Q_ratio_bin": bin_qratio(diag.get("Q_ratio")),
        "local_dynamics_bin": local_bin,
        "support_fraction": float(pattern["support_pair_count"]) / float((p - 1) // 2) if p > 2 else None,
    }
    row.update(pattern)
    row.update(diag)
    row.update(response)
    row["repair_response_bin"] = repair_response_bin(row)
    row["trap_type_level1"] = "{}|{}|{}".format(row["score"], row["rho_value_pattern"], row["orbit_normalized_pattern"])
    row["trap_type_level2"] = "{}|{}|{}".format(row["trap_type_level1"], row["D_min_ratio_bin"], row["P_8_bin"] + "|" + row["kappa_bin"] + "|" + row["Q_ratio_bin"])
    row["trap_type_level3"] = "{}|{}".format(row["trap_type_level2"], row["repair_response_bin"])
    return row


def aggregate(rows, group_fields, extra_name=None):
    groups = {}
    for row in rows:
        key = tuple(str(row.get(field)) for field in group_fields)
        groups.setdefault(key, []).append(row)
    out = []
    for key, group in sorted(groups.items(), key=lambda item: (-len(item[1]), item[0])):
        item = {field: key[idx] for idx, field in enumerate(group_fields)}
        if extra_name:
            item[extra_name] = "|".join(key)
        item.update(
            {
                "count": int(len(group)),
                "distinct_hashes": int(len(set(row["canonical_hash"] for row in group))),
                "occurrence_count_sum": int(sum(int(row.get("occurrence_count") or 0) for row in group)),
                "origin_distribution": count_by(group, "origin"),
                "label_distribution": count_by(group, "candidate_label"),
                "score_distribution": histogram_int(group, "score"),
                "median_D_min_ratio": median([row.get("D_min_ratio") for row in group]),
                "median_P_8": median([row.get("P_8") for row in group]),
                "median_kappa_max": median([row.get("kappa_max") for row in group]),
                "median_Q_ratio": median([row.get("Q_ratio") for row in group]),
                "repair_response_distribution": count_by(group, "repair_response_bin"),
                "score_improvement_rate": mean([1.0 if row.get("repair_score_improvement_seen") else 0.0 for row in group]),
                "score0_rate": mean([1.0 if row.get("repair_score0_seen") else 0.0 for row in group]),
                "damage_rate": mean([1.0 if row.get("repair_damage_seen") else 0.0 for row in group]),
            }
        )
        out.append(item)
    return out


def trap_by_origin(rows):
    out = []
    groups = {}
    for row in rows:
        key = row.get("candidate_label") or row.get("origin") or "unknown"
        groups.setdefault(key, []).append(row)
    for key, group in sorted(groups.items()):
        out.append(
            {
                "group": key,
                "count": int(len(group)),
                "score_distribution": histogram_int(group, "score"),
                "trap_type_distribution": count_by(group, "trap_type_level1"),
                "orbit_class_distribution": count_by(group, "orbit_normalized_pattern"),
                "local_dynamics_distribution": count_by(group, "local_dynamics_bin"),
                "repair_response_distribution": count_by(group, "repair_response_bin"),
                "median_D_min_ratio": median([row.get("D_min_ratio") for row in group]),
                "median_P_8": median([row.get("P_8") for row in group]),
                "median_kappa_max": median([row.get("kappa_max") for row in group]),
                "median_Q_ratio": median([row.get("Q_ratio") for row in group]),
            }
        )
    return out


def recurrence_summary(rows):
    level1 = aggregate(rows, ["trap_type_level1"])
    orbit = aggregate(rows, ["orbit_normalized_pattern"])
    hashes = aggregate(rows, ["canonical_hash"])
    out = []
    for name, data in (("trap_type_level1", level1), ("orbit_normalized_pattern", orbit), ("canonical_hash", hashes)):
        for row in data[:50]:
            item = {"recurrence_key_kind": name}
            if name in row:
                item["recurrence_key"] = row[name]
            else:
                item["recurrence_key"] = row.get("trap_type_level1") or row.get("orbit_normalized_pattern") or row.get("canonical_hash")
            item.update(row)
            out.append(item)
    return out


def operator_response(rows, response_rows):
    features_by_hash = {row["canonical_hash"]: row for row in rows}
    grouped = {}
    for response in response_rows:
        feat = features_by_hash.get(response.get("parent_hash"))
        if not feat:
            continue
        key = (feat["trap_type_level2"], response.get("operator"))
        grouped.setdefault(key, []).append(response)
    out = []
    for (trap_type, operator), group in sorted(grouped.items(), key=lambda item: (-len(item[1]), str(item[0]))):
        out.append(
            {
                "trap_type": trap_type,
                "operator": operator,
                "attempt_count": int(len(group)),
                "score_improvement_rate": mean([1.0 if row.get("score_improvement_seen") else 0.0 for row in group]),
                "score0_rate": mean([1.0 if row.get("score0_seen") else 0.0 for row in group]),
                "exactlike_improvement_rate": mean([1.0 if row.get("exactlike_improved") else 0.0 for row in group]),
                "damage_rate": mean([1.0 if row.get("damage_seen") else 0.0 for row in group]),
            }
        )
    return out


def nearhit_comparison(p37_rows, nearhit_rows):
    p37_false = [row for row in p37_rows if row.get("candidate_label") in ("false_like", "search_derived_false_basin", "hard_basin") or row.get("origin") == "search_derived_false_basin"]
    false_patterns = set(row["rho_value_pattern"] for row in p37_false)
    false_bins = set(row["local_dynamics_bin"] for row in p37_false)
    out = []
    for row in nearhit_rows:
        out.append(
            {
                "canonical_hash": row["canonical_hash"],
                "score": row["score"],
                "score_per_p": row["score_per_p"],
                "tuple": row["tuple"],
                "support_pair_count": row["support_pair_count"],
                "support_fraction": row["support_fraction"],
                "rho_value_pattern": row["rho_value_pattern"],
                "D_min_ratio": row.get("D_min_ratio"),
                "P_8": row.get("P_8"),
                "P_16": row.get("P_16"),
                "kappa_max": row.get("kappa_max"),
                "kappa_q99": row.get("kappa_q99"),
                "Q_ratio": row.get("Q_ratio"),
                "matches_p37_rho_value_pattern": row["rho_value_pattern"] in false_patterns,
                "matches_p37_local_dynamics_bin": row["local_dynamics_bin"] in false_bins,
                "source_file": row.get("source_file"),
            }
        )
    return out


def summarize_p167(rows, group_fields):
    groups = {}
    for row in rows:
        key = tuple(str(row.get(field, "missing")) for field in group_fields)
        groups.setdefault(key, []).append(row)
    out = []
    for key, group in sorted(groups.items(), key=lambda item: (-len(item[1]), item[0])):
        item = {field: key[idx] for idx, field in enumerate(group_fields)}
        item.update(
            {
                "count": int(len(group)),
                "distinct_hashes": int(len(set(row["canonical_hash"] for row in group))),
                "score_distribution": histogram_int(group, "score"),
                "tuple_distribution": count_by(group, "tuple"),
                "lambda_distribution": histogram_int(group, "lambda"),
                "method_distribution": count_by(group, "source_method"),
                "rho_value_pattern_distribution": count_by(group, "rho_value_pattern"),
                "local_dynamics_distribution": count_by(group, "local_dynamics_bin"),
                "median_score": median([row.get("score") for row in group]),
                "median_score_per_p": median([row.get("score_per_p") for row in group]),
                "median_support_pair_count": median([row.get("support_pair_count") for row in group]),
                "median_support_fraction": median([row.get("support_fraction") for row in group]),
                "median_max_abs_rho": median([row.get("max_abs_rho") for row in group]),
                "median_D_min_ratio": median([row.get("D_min_ratio") for row in group]),
                "median_P_4": median([row.get("P_4") for row in group]),
                "median_P_8": median([row.get("P_8") for row in group]),
                "median_P_16": median([row.get("P_16") for row in group]),
                "median_P_32": median([row.get("P_32") for row in group]),
                "median_P_thetaS_001": median([row.get("P_thetaS_001") for row in group]),
                "median_P_thetaS_005": median([row.get("P_thetaS_005") for row in group]),
                "median_P_thetaS_010": median([row.get("P_thetaS_010") for row in group]),
                "median_kappa_max": median([row.get("kappa_max") for row in group]),
                "median_kappa_q90": median([row.get("kappa_q90") for row in group]),
                "median_kappa_q99": median([row.get("kappa_q99") for row in group]),
                "median_Q_ratio": median([row.get("Q_ratio") for row in group]),
                "median_InitHardness": median([row.get("InitHardness") for row in group]),
                "false_like_indicator_rate": mean([1.0 if is_false_like_signature(row) else 0.0 for row in group]),
                "exact_like_indicator_rate": mean([1.0 if is_exact_like_signature(row) else 0.0 for row in group]),
            }
        )
        out.append(item)
    return out


def is_false_like_signature(row):
    d = row.get("D_min_ratio")
    kappa = row.get("kappa_max")
    p_neg = row.get("P_<0")
    if d is None or kappa is None:
        return False
    return float(d) > 1.0 and float(kappa) < 1.0 and (p_neg is None or float(p_neg) <= 0.001)


def is_exact_like_signature(row):
    d = row.get("D_min_ratio")
    h_min = row.get("h_min")
    kappa = row.get("kappa_max")
    return (
        (d is not None and float(d) < 1.0)
        or (h_min is not None and float(h_min) < 0.0)
        or (kappa is not None and float(kappa) > 1.0)
    )


def reference_profile(rows, label):
    fields = ["score_per_p", "support_fraction", "D_min_ratio", "P_8", "P_16", "P_thetaS_005", "kappa_max", "kappa_q99", "Q_ratio"]
    return {"label": label, **{"median_" + field: median([row.get(field) for row in rows]) for field in fields}, "count": int(len(rows))}


def profile_distance(row, profile):
    fields = [
        ("score_per_p", 1.0),
        ("support_fraction", 1.0),
        ("D_min_ratio", 1.0),
        ("P_8", 10.0),
        ("P_16", 10.0),
        ("P_thetaS_005", 10.0),
        ("kappa_max", 1.0),
        ("kappa_q99", 1.0),
        ("Q_ratio", 0.05),
    ]
    total = 0.0
    used = 0
    for field, weight in fields:
        a = row.get(field)
        b = profile.get("median_" + field)
        if a is None or b is None:
            continue
        total += weight * abs(float(a) - float(b))
        used += 1
    return total / float(used) if used else None


def p37_vs_p167_comparison(p37_rows, p167_rows):
    p37_false = [
        row
        for row in p37_rows
        if row.get("candidate_label") in ("false_like", "search_derived_false_basin", "hard_basin")
        or row.get("origin") == "search_derived_false_basin"
    ]
    p37_exact = [
        row
        for row in p37_rows
        if row.get("candidate_label") in ("exact", "exact_derived", "exact_like")
        or row.get("origin") == "exact_derived"
    ]
    false_profile = reference_profile(p37_false, "p37_false_like")
    exact_profile = reference_profile(p37_exact, "p37_exact_like")
    groups = {}
    for row in p167_rows:
        groups.setdefault(("score", score_band(row.get("score"))), []).append(row)
        if int(row.get("score")) in (164, 176):
            groups.setdefault(("score164_176", "score164_176"), []).append(row)
        groups.setdefault(("method", str(row.get("source_method"))), []).append(row)
        groups.setdefault(("tuple", row.get("tuple")), []).append(row)
    out = []
    for (kind, name), rows in sorted(groups.items(), key=lambda item: (item[0][0], item[0][1])):
        summary = summarize_p167(rows, ["p"])[0] if rows else {}
        pseudo_row = {
            "score_per_p": summary.get("median_score_per_p"),
            "support_fraction": summary.get("median_support_fraction"),
            "D_min_ratio": summary.get("median_D_min_ratio"),
            "P_8": summary.get("median_P_8"),
            "P_16": summary.get("median_P_16"),
            "P_thetaS_005": summary.get("median_P_thetaS_005"),
            "kappa_max": summary.get("median_kappa_max"),
            "kappa_q99": summary.get("median_kappa_q99"),
            "Q_ratio": summary.get("median_Q_ratio"),
        }
        d_false = profile_distance(pseudo_row, false_profile)
        d_exact = profile_distance(pseudo_row, exact_profile)
        closer = "inconclusive"
        if d_false is not None and d_exact is not None:
            closer = "p37_false_like" if d_false < d_exact else "p37_exact_like"
        out.append(
            {
                "comparison_kind": kind,
                "comparison_group": name,
                "count": int(len(rows)),
                "distance_to_p37_false_profile": d_false,
                "distance_to_p37_exact_profile": d_exact,
                "closer_to": closer,
                "p37_false_reference": false_profile,
                "p37_exact_reference": exact_profile,
                **{k: v for k, v in summary.items() if k not in ("p", "tuple_distribution", "method_distribution", "rho_value_pattern_distribution", "local_dynamics_distribution")},
            }
        )
    return out


def score164_176_detail_rows(rows):
    wanted = []
    for row in rows:
        if int(row.get("score")) not in (164, 176):
            continue
        wanted.append(
            {
                "score": row.get("score"),
                "score_per_p": row.get("score_per_p"),
                "tuple": row.get("tuple"),
                "lambda": row.get("lambda"),
                "source_method": row.get("source_method"),
                "seed": row.get("seed"),
                "canonical_hash": row.get("canonical_hash"),
                "rho_value_pattern": row.get("rho_value_pattern"),
                "orbit_normalized_pattern": row.get("orbit_normalized_pattern"),
                "support_pair_count": row.get("support_pair_count"),
                "support_fraction": row.get("support_fraction"),
                "max_abs_rho": row.get("max_abs_rho"),
                "D_min_ratio": row.get("D_min_ratio"),
                "h_min": row.get("h_min"),
                "P_<0": row.get("P_<0"),
                "P_4": row.get("P_4"),
                "P_8": row.get("P_8"),
                "P_16": row.get("P_16"),
                "P_32": row.get("P_32"),
                "P_thetaS_001": row.get("P_thetaS_001"),
                "P_thetaS_005": row.get("P_thetaS_005"),
                "P_thetaS_010": row.get("P_thetaS_010"),
                "kappa_max": row.get("kappa_max"),
                "kappa_q90": row.get("kappa_q90"),
                "kappa_q99": row.get("kappa_q99"),
                "Q_ratio": row.get("Q_ratio"),
                "InitHardness": row.get("InitHardness"),
                "false_like_signature": is_false_like_signature(row),
                "exact_like_signature": is_exact_like_signature(row),
                "source_file": row.get("source_file"),
            }
        )
    return sorted(wanted, key=lambda r: (r["score"], r.get("source_method") or "", r.get("source_file") or ""))


def evaluate_p167_hypotheses(p37_rows, p167_rows, comparison_rows, method_summary):
    score_focus = [row for row in p167_rows if int(row.get("score")) in (164, 176)]
    focus_cmp = [row for row in comparison_rows if row.get("comparison_kind") == "score164_176"]
    closer_false = bool(focus_cmp and focus_cmp[0].get("closer_to") == "p37_false_like")
    false_like_rate = mean([1.0 if is_false_like_signature(row) else 0.0 for row in score_focus]) or 0.0
    exact_like_rate = mean([1.0 if is_exact_like_signature(row) else 0.0 for row in score_focus]) or 0.0
    rows164 = [row for row in score_focus if int(row.get("score")) == 164]
    rows176 = [row for row in score_focus if int(row.get("score")) == 176]
    same_family = False
    if rows164 and rows176:
        med164 = {
            "D": median([row.get("D_min_ratio") for row in rows164]),
            "P8": median([row.get("P_8") for row in rows164]),
            "K": median([row.get("kappa_max") for row in rows164]),
            "Q": median([row.get("Q_ratio") for row in rows164]),
        }
        med176 = {
            "D": median([row.get("D_min_ratio") for row in rows176]),
            "P8": median([row.get("P_8") for row in rows176]),
            "K": median([row.get("kappa_max") for row in rows176]),
            "Q": median([row.get("Q_ratio") for row in rows176]),
        }
        same_family = (
            med164["D"] is not None
            and med176["D"] is not None
            and abs(float(med164["D"]) - float(med176["D"])) <= 0.25
            and abs(float(med164["K"] or 0.0) - float(med176["K"] or 0.0)) <= 0.25
        )
    method_rows = [row for row in method_summary if int(row.get("count") or 0) >= 3]
    method_diff = False
    if len(method_rows) >= 2:
        d_vals = [row.get("median_D_min_ratio") for row in method_rows if row.get("median_D_min_ratio") is not None]
        k_vals = [row.get("median_kappa_max") for row in method_rows if row.get("median_kappa_max") is not None]
        p8_vals = [row.get("median_P_8") for row in method_rows if row.get("median_P_8") is not None]
        method_diff = (
            (d_vals and max(d_vals) - min(d_vals) >= 0.25)
            or (k_vals and max(k_vals) - min(k_vals) >= 0.25)
            or (p8_vals and max(p8_vals) - min(p8_vals) >= 0.02)
        )
    return {
        "H_P167_1": "supported" if closer_false else "not_supported" if score_focus else "inconclusive",
        "H_P167_2": "supported" if false_like_rate >= 0.5 and false_like_rate > exact_like_rate else "not_supported" if score_focus else "inconclusive",
        "H_P167_3": "supported" if same_family else "not_supported" if rows164 and rows176 else "inconclusive",
        "H_P167_4": "supported" if method_diff else "not_supported" if len(method_rows) >= 2 else "inconclusive",
        "H_P167_5": "supported" if score_focus and (closer_false or false_like_rate >= 0.5 or exact_like_rate >= 0.5) else "inconclusive",
        "p167_candidate_count": int(len(p167_rows)),
        "score164_count": int(len(rows164)),
        "score176_count": int(len(rows176)),
        "tuple_A_73_78_79_81_lambda144_count": int(sum(1 for row in p167_rows if row.get("tuple") == "73,78,79,81" and int(row.get("lambda")) == 144)),
        "score164_176_false_like_rate": false_like_rate,
        "score164_176_exact_like_rate": exact_like_rate,
        "score164_176_closer_to": focus_cmp[0].get("closer_to") if focus_cmp else None,
        "method_summary_groups": int(len(method_rows)),
    }


def evaluate_hypotheses(rows, nearhit_rows, operator_rows):
    false_rows = [row for row in rows if row.get("candidate_label") in ("false_like", "search_derived_false_basin", "hard_basin") or row.get("origin") == "search_derived_false_basin"]
    exact_rows = [row for row in rows if row.get("candidate_label") in ("exact", "exact_derived", "exact_like") or row.get("origin") == "exact_derived"]
    total_false = len(false_rows)
    top_pattern_share = 0.0
    if false_rows:
        counts = count_by(false_rows, "trap_type_level1")
        top_pattern_share = max(counts.values()) / float(total_false)
    exact_types = set(row["trap_type_level2"] for row in exact_rows)
    false_types = set(row["trap_type_level2"] for row in false_rows)
    overlap = len(exact_types.intersection(false_types))
    separation = 1.0 - float(overlap) / float(max(1, len(false_types)))
    op_supported = any(
        (row.get("score_improvement_rate") not in (None, 0.0) or row.get("damage_rate") not in (None, 0.0))
        for row in operator_rows
    )
    return {
        "H_TRAP1": "supported" if top_pattern_share >= 0.5 else "not_supported",
        "H_TRAP2": "supported" if separation >= 0.5 else "inconclusive",
        "H_TRAP3": "inconclusive" if not nearhit_rows else "supported" if any(row.get("matches_p37_local_dynamics_bin") for row in nearhit_rows) else "not_supported",
        "H_TRAP4": "supported" if op_supported else "inconclusive",
        "false_basin_count": int(total_false),
        "false_top_trap_type_share": top_pattern_share,
        "exact_false_level2_overlap_count": int(overlap),
        "exact_false_level2_separation_proxy": separation,
        "nearhit_668_count": int(len(nearhit_rows)),
        "operator_response_rows": int(len(operator_rows)),
    }


def run_cmd(cmd):
    proc = subprocess.run(cmd, cwd=os.getcwd(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return proc.returncode, proc.stdout


def write_summary(path, context):
    hypo = context["hypothesis"]
    level1 = context["level1"]
    origin = context["origin_summary"]
    recurrence = context["recurrence"]
    nearhit = context["nearhit"]
    op = context["operator"]
    score4 = [row for row in context["features"] if int(row["score"]) == 4 and (row.get("candidate_label") in ("false_like", "search_derived_false_basin") or row.get("origin") == "search_derived_false_basin")]
    score4_ok = bool(score4) and all(row["rho_value_pattern"] == "+pairs1_ -pairs1_ other0" for row in score4)
    top_type = level1[0]["trap_type_level1"] if level1 else None
    exact_false_sep = hypo.get("exact_false_level2_separation_proxy")
    lines = [
        "# p37 Trap Set Catalog Validation",
        "",
        "This is a trap catalog validation, not a Hadamard 668 construction run.",
        "",
        "## Counts",
        "",
        "- p37 trap candidates: `{}`".format(len(context["features"])),
        "- p167 near-hit candidates: `{}`".format(len(context["nearhit_features"])),
        "- top level1 trap type: `{}`".format(top_type),
        "",
        "## Hypotheses",
        "",
        "```json",
        json.dumps(json_safe(hypo), indent=2, sort_keys=True),
        "```",
        "",
        "## Required Answers",
        "",
        "1. p=37 false basin は少数の trap type に分類できたか: `{}`; top share `{}`.".format(hypo["H_TRAP1"], hypo["false_top_trap_type_share"]),
        "2. score=4 false basin は理論通り +1 on ±a, -1 on ±b の型だったか: `{}`.".format(score4_ok),
        "3. exact-derived と search-derived false basin は trap type 分布で分かれたか: `{}`; separation proxy `{}`.".format(hypo["H_TRAP2"], exact_false_sep),
        "4. D_min/S, P_tau, kappa を加えると trap type の分離は強まったか: level2 separation proxy `{}`; compare level1/level2 catalogs.".format(exact_false_sep),
        "5. repair response を加えると trap type の意味は増したか: `{}` operator response rows joined.".format(len(op)),
        "6. 同じ trap type が複数 run / 複数 source で再発していたか: top recurrence count `{}`.".format(recurrence[0].get("count") if recurrence else None),
        "7. 668 score164/176 または p=167 near-hit は catalog に載せられたか: `{}` candidates.".format(len(nearhit)),
        "8. 668 near-hit は p=37 trap type と似ていたか: `{}`.".format(hypo["H_TRAP3"]),
        "9. trap type ごとに有効な operator の違いは見えたか: `{}`.".format(hypo["H_TRAP4"]),
        "10. H-TRAP1, H-TRAP2, H-TRAP3, H-TRAP4 の判定はどうか: `{}`.".format(json.dumps({k: hypo[k] for k in ("H_TRAP1", "H_TRAP2", "H_TRAP3", "H_TRAP4")}, sort_keys=True)),
        "11. 668 に戻す場合、trap catalog は archive / restart / repair routing のどこに使うべきか: use level2 signatures for early archive/restart; use level3 response only as repair routing hints after more p167 evidence.",
        "",
        "## Validation",
        "",
    ]
    lines.extend("- {}".format(note) for note in context["validation_notes"])
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def write_p167_summary(path, context):
    hypo = context["hypothesis"]
    score_detail = context["score_detail"]
    score164 = [row for row in score_detail if int(row.get("score")) == 164]
    score176 = [row for row in score_detail if int(row.get("score")) == 176]
    tuple_a = hypo.get("tuple_A_73_78_79_81_lambda144_count")
    focus_cmp = [row for row in context["comparison"] if row.get("comparison_kind") == "score164_176"]
    closer = focus_cmp[0].get("closer_to") if focus_cmp else None
    lines = [
        "# p167 Near-Hit Trap Catalog Validation",
        "",
        "This is a catalog / analysis run, not a Hadamard 668 construction run.",
        "",
        "## Counts",
        "",
        "- p167 near-hit candidates analyzed: `{}`".format(len(context["features"])),
        "- score164 analyzed: `{}`".format(len(score164)),
        "- score176 analyzed: `{}`".format(len(score176)),
        "- tuple [73,78,79,81], lambda=144 candidates: `{}`".format(tuple_a),
        "",
        "## Hypotheses",
        "",
        "```json",
        json.dumps(json_safe(hypo), indent=2, sort_keys=True),
        "```",
        "",
        "## Required Answers",
        "",
        "1. p167 near-hit は何件収集できたか: `{}` unique candidates.".format(len(context["features"])),
        "2. score164 / score176 は何件分析できたか: score164 `{}`, score176 `{}`.".format(len(score164), len(score176)),
        "3. tuple [73,78,79,81], lambda=144 の候補は何件か: `{}`.".format(tuple_a),
        "4. p167 score164/176 は p37 false-basin trap に近いか、exact-derived 側に近いか: `{}`.".format(closer),
        "5. score164 と score176 は同じ trap family に見えるか: `{}`.".format(hypo.get("H_P167_3")),
        "6. p167 near-hit は D_min/S, P_tau, kappa 的に false-like か exact-like か: false-like rate `{}`, exact-like rate `{}` for score164/176.".format(hypo.get("score164_176_false_like_rate"), hypo.get("score164_176_exact_like_rate")),
        "7. steepest / beam / ILP / seed など source method ごとに signature 差はあるか: `{}`.".format(hypo.get("H_P167_4")),
        "8. p37 trap catalog は p167 near-hit 解釈に使えそうか: `{}`.".format(hypo.get("H_P167_5")),
        "9. 668 探索で score164/176 を archive / repair target / deep search target のどれにすべきか: use as repair/deep-search targets only when exact-like route indicators improve; archive repeated false-like signatures early.",
        "10. 次に見るべき operator / generator は何か: route score164/176 through exactlike-guided repair and compare against fresh exactlike-guided generator frontier, using p167 rank-normalized P_tau/kappa.",
        "",
        "## Validation",
        "",
    ]
    lines.extend("- {}".format(note) for note in context["validation_notes"])
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--p", type=int, default=37)
    parser.add_argument("--ks", default="13,16,18,18")
    parser.add_argument("--lambda", dest="lam", type=int, default=28)
    parser.add_argument("--exact-json", default="outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json")
    parser.add_argument("--max-trap-candidates", type=int, default=200)
    parser.add_argument("--max-668-candidates", type=int, default=1000)
    parser.add_argument("--include-p167-nearhits", dest="include_p167_nearhits", action="store_true", default=True)
    parser.add_argument("--skip-p167-nearhits", dest="include_p167_nearhits", action="store_false")
    parser.add_argument("--nearhit-dir", default="outputs/candidates/near_hits")
    parser.add_argument("--p167-max-score", type=int, default=232)
    parser.add_argument("--p167-max-per-score", type=int, default=100)
    parser.add_argument("--p167-diagnostic-max-moves", type=int, default=500)
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--no-external-validation", action="store_true")
    args = parser.parse_args()

    p = int(args.p)
    ks = parse_ks(args.ks)
    lam = int(args.lam)
    S62["validate_params"](p, ks, lam)
    out_dir = args.out_dir or os.path.join("outputs/explorations", "{}_p37_trap_set_catalog_validation".format(now_stamp()))
    ensure_dir(out_dir)
    write_json(os.path.join(out_dir, "run_config.json"), vars(args))
    with open(os.path.join(out_dir, "run_log.md"), "w") as f:
        f.write("# Run Log\n\n")
        f.write("- script: `{}`\n".format(SCRIPT_NAME))
        f.write("- score=0 only is success; this script does not generate new candidates\n")

    raw_p37, occ_p37 = collect_candidates_for_target(P37_ROOTS, p, ks, lam, P37_SCORE_SET)
    selected_p37 = select_p37_candidates(raw_p37, args.max_trap_candidates)
    if args.include_p167_nearhits:
        p167_rows, occ_167 = collect_p167_candidates(
            args.nearhit_dir,
            args.max_668_candidates,
            max_score=args.p167_max_score,
            max_per_score=args.p167_max_per_score,
        )
    else:
        p167_rows, occ_167 = [], {}
    response_rows = response_join_rows()
    response_by_hash = summarize_response_by_hash(response_rows)
    baseline_cache = {}
    p37_features = [feature_row(row, response_by_hash, occ_p37, baseline_cache, p167_max_moves=args.p167_diagnostic_max_moves) for row in selected_p37]
    nearhit_features = [feature_row(row, response_by_hash, occ_167, baseline_cache, p167_max_moves=args.p167_diagnostic_max_moves) for row in p167_rows]
    write_jsonl(os.path.join(out_dir, "input_trap_candidates.jsonl"), selected_p37)
    write_jsonl(os.path.join(out_dir, "input_668_nearhit_candidates.jsonl"), p167_rows)
    write_jsonl(os.path.join(out_dir, "input_p167_nearhit_candidates.jsonl"), p167_rows)
    write_jsonl(os.path.join(out_dir, "trap_candidate_features.jsonl"), p37_features)
    write_jsonl(os.path.join(out_dir, "p167_nearhit_trap_features.jsonl"), nearhit_features)

    level1 = aggregate(p37_features, ["score", "rho_value_pattern", "orbit_normalized_pattern"], "trap_type_level1")
    level2 = aggregate(p37_features, ["score", "orbit_normalized_pattern", "D_min_ratio_bin", "P_8_bin", "kappa_bin", "Q_ratio_bin"], "trap_type_level2")
    level3 = aggregate(p37_features, ["score", "orbit_normalized_pattern", "local_dynamics_bin", "repair_response_bin"], "trap_type_level3")
    origin_summary = trap_by_origin(p37_features)
    recurrence = recurrence_summary(p37_features)
    operator = operator_response(p37_features, response_rows)
    nearhit_cmp = nearhit_comparison(p37_features, nearhit_features)
    hypo = evaluate_hypotheses(p37_features, nearhit_cmp, operator)
    p167_score_band = summarize_p167(nearhit_features, ["score"])
    p167_tuple = summarize_p167(nearhit_features, ["tuple", "lambda"])
    p167_method = summarize_p167(nearhit_features, ["source_method"])
    p37_p167_cmp = p37_vs_p167_comparison(p37_features, nearhit_features)
    score_detail = score164_176_detail_rows(nearhit_features)
    p167_hypo = evaluate_p167_hypotheses(p37_features, nearhit_features, p37_p167_cmp, p167_method)

    outputs = [
        ("trap_type_catalog_level1", level1),
        ("trap_type_catalog_level2", level2),
        ("trap_type_catalog_level3", level3),
        ("trap_by_origin_summary", origin_summary),
        ("trap_recurrence_summary", recurrence),
        ("trap_operator_response", operator),
        ("nearhit_668_trap_comparison", nearhit_cmp),
        ("p167_score_band_summary", p167_score_band),
        ("p167_tuple_summary", p167_tuple),
        ("p167_method_summary", p167_method),
        ("p37_vs_p167_trap_comparison", p37_p167_cmp),
        ("score164_176_detail", score_detail),
    ]
    for name, rows in outputs:
        fields = sorted(set().union(*(row.keys() for row in rows))) if rows else ["empty"]
        write_csv(os.path.join(out_dir, name + ".csv"), rows, fields)
        write_json(os.path.join(out_dir, name + ".json"), {"rows": rows})
    combined_hypo = dict(hypo)
    combined_hypo.update(p167_hypo)
    write_json(os.path.join(out_dir, "hypothesis_evaluation.json"), combined_hypo)
    write_json(os.path.join(out_dir, "p167_hypothesis_evaluation.json"), p167_hypo)

    validation_notes = []
    if not args.no_external_validation:
        code, output = run_cmd(["sage", "sage/06_known_sds_regression.sage"])
        validation_notes.append("`sage sage/06_known_sds_regression.sage`: {}".format("OK" if code == 0 else "FAILED"))
        with open(os.path.join(out_dir, "run_log.md"), "a") as f:
            f.write("\n## External validation\n\n")
            f.write("- known regression: `{}`\n".format("OK" if code == 0 else "FAILED"))
        if code != 0:
            raise RuntimeError("known SDS regression failed:\n{}".format(output))
    else:
        validation_notes.append("External validation skipped by CLI flag.")

    write_summary(
        os.path.join(out_dir, "p37_trap_set_catalog_summary.md"),
        {
            "features": p37_features,
            "nearhit_features": nearhit_features,
            "level1": level1,
            "origin_summary": origin_summary,
            "recurrence": recurrence,
            "operator": operator,
            "nearhit": nearhit_cmp,
            "hypothesis": hypo,
            "validation_notes": validation_notes,
        },
    )
    write_p167_summary(
        os.path.join(out_dir, "p167_nearhit_trap_catalog_summary.md"),
        {
            "features": nearhit_features,
            "score_detail": score_detail,
            "comparison": p37_p167_cmp,
            "hypothesis": p167_hypo,
            "validation_notes": validation_notes,
        },
    )
    print("p37 candidates:", len(p37_features))
    print("p167 nearhits:", len(nearhit_features))
    print("SUMMARY:", os.path.join(out_dir, "p37_trap_set_catalog_summary.md"))
    print("P167 SUMMARY:", os.path.join(out_dir, "p167_nearhit_trap_catalog_summary.md"))


if __name__ == "__main__":
    main()
