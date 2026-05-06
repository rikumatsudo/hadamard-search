from sage.all import *

import argparse
import csv
import glob
import json
import math
import os
import statistics
import sys
import time

from sds_repair_utils import setup_logging, write_json


SCRIPT_NAME = "57_p37_classifier_feature_analysis"
LABELS = (
    "exact",
    "exact_derived",
    "search_derived_false_basin",
    "hard_basin",
    "unknown",
    "unlabeled",
)
PRIMARY_FEATURES = (
    "score",
    "D_min_ratio",
    "h_min",
    "h_min_over_S",
    "P_<0",
    "P_0",
    "P_4",
    "P_8",
    "P_16",
    "P_thetaS_001",
    "P_thetaS_005",
    "P_thetaS_010",
    "kappa_max",
    "kappa_q90",
    "kappa_q95",
    "kappa_q99",
    "low_q_high_kappa_overlap",
)
SECONDARY_FEATURES = (
    "Q_ratio",
    "Q_tot",
    "InitHardness",
    "E_total",
    "AP_total",
    "E_excess_total",
    "AP_excess_total",
    "improving_swap_count",
    "near_improving_count_h_le_4",
    "near_improving_count_h_le_8",
    "near_improving_count_h_le_16",
    "moment_zero_count_3",
    "moment_zero_count_6",
    "higher_moment_norm",
)
FEATURES = PRIMARY_FEATURES + SECONDARY_FEATURES
PAIR_COMPARISONS = (
    ("exact_derived", "search_derived_false_basin"),
    ("exact_derived", "hard_basin"),
    ("search_derived_false_basin", "unknown"),
    ("exact_derived", "unknown"),
)
LOW_EXACT_LIKE = set(
    [
        "score",
        "D_min_ratio",
        "h_min",
        "h_min_over_S",
        "Q_ratio",
    ]
)
HIGH_EXACT_LIKE = set(
    [
        "P_<0",
        "P_0",
        "P_4",
        "P_8",
        "P_16",
        "P_thetaS_001",
        "P_thetaS_005",
        "P_thetaS_010",
        "kappa_max",
        "kappa_q90",
        "kappa_q95",
        "kappa_q99",
        "low_q_high_kappa_overlap",
        "improving_swap_count",
        "near_improving_count_h_le_4",
        "near_improving_count_h_le_8",
        "near_improving_count_h_le_16",
    ]
)
GROUND_EXACT_LIKE = set(["exact", "exact_derived"])
GROUND_FALSE_LIKE = set(["search_derived_false_basin", "hard_basin"])


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
    if isinstance(value, bool):
        return bool(value)
    if isinstance(value, int):
        return int(value)
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    try:
        if isinstance(value, Integer):
            return int(value)
    except NameError:
        pass
    # Sage real/rational values should not be truncated through int().
    try:
        if str(type(value)).startswith("<class 'sage."):
            as_float = float(value)
            return as_float if math.isfinite(as_float) else None
    except Exception:
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


def write_json_safe(path, payload):
    write_json(path, json_safe(payload))


def write_jsonl(path, rows):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(json_safe(row), sort_keys=True) + "\n")


def write_csv(path, rows, fields):
    ensure_dir(os.path.dirname(path))
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: csv_value(row.get(field)) for field in fields})


def csv_value(value):
    value = json_safe(value)
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True)
    if value is None:
        return ""
    return value


def read_jsonl(path):
    rows = []
    if not path or not os.path.exists(path):
        return rows
    with open(path) as f:
        for line in f:
            text = line.strip()
            if not text:
                continue
            rows.append(json.loads(text))
    return rows


def read_csv(path):
    if not path or not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def latest_pipeline_dir():
    paths = glob.glob(os.path.join("outputs", "explorations", "*p37_pipeline_framework*"))
    paths = [path for path in paths if os.path.isdir(path)]
    if not paths:
        return None
    paths.sort(key=lambda path: os.path.getmtime(path), reverse=True)
    return paths[0]


def to_float(value):
    if value is None:
        return None
    if isinstance(value, bool):
        return float(int(value))
    if isinstance(value, (int, float)):
        value = float(value)
        return value if math.isfinite(value) else None
    text = str(value).strip()
    if text == "" or text.lower() in ("none", "null", "nan"):
        return None
    try:
        value = float(text)
        return value if math.isfinite(value) else None
    except ValueError:
        return None


def nested_get(row, dotted):
    current = row
    for part in dotted.split("."):
        if not isinstance(current, dict) or part not in current:
            return None
        current = current[part]
    return current


def feature_value(row, feature):
    if feature in row:
        value = to_float(row.get(feature))
        if value is not None:
            return value
    diagnostic = row.get("diagnostic") if isinstance(row.get("diagnostic"), dict) else {}
    if feature in diagnostic:
        value = to_float(diagnostic.get(feature))
        if value is not None:
            return value
    if feature == "h_min_over_S":
        score = feature_value(row, "score")
        h_min = feature_value(row, "h_min")
        if score is not None and score > 0 and h_min is not None:
            return float(h_min) / float(score)
        return None
    if feature == "kappa_q90":
        return to_float(nested_get(row, "kappa_quantiles.q90") or nested_get(diagnostic, "kappa_quantiles.q90"))
    if feature == "kappa_q95":
        return to_float(nested_get(row, "kappa_quantiles.q95") or nested_get(diagnostic, "kappa_quantiles.q95"))
    if feature == "kappa_q99":
        return to_float(nested_get(row, "kappa_quantiles.q99") or nested_get(diagnostic, "kappa_quantiles.q99"))
    if feature == "near_improving_count_h_le_4":
        p4 = feature_value(row, "P_4")
        n = feature_value(row, "num_swaps")
        if p4 is not None and n is not None:
            return float(p4) * float(n)
    if feature == "near_improving_count_h_le_8":
        p8 = feature_value(row, "P_8")
        n = feature_value(row, "num_swaps")
        if p8 is not None and n is not None:
            return float(p8) * float(n)
    if feature == "near_improving_count_h_le_16":
        p16 = feature_value(row, "P_16")
        n = feature_value(row, "num_swaps")
        if p16 is not None and n is not None:
            return float(p16) * float(n)
    return None


def merge_rows(classifier_rows, label_rows, diagnostic_rows):
    by_hash = {}
    order = []
    for source_name, rows in (
        ("classifier_csv", classifier_rows),
        ("candidate_labels", label_rows),
        ("diagnostics", diagnostic_rows),
    ):
        for row in rows:
            key = row.get("canonical_hash")
            if not key:
                continue
            if key not in by_hash:
                by_hash[key] = {"canonical_hash": key, "_sources": []}
                order.append(key)
            by_hash[key]["_sources"].append(source_name)
            # Keep richer diagnostic values, but do not overwrite labels with blanks.
            for field, value in row.items():
                if field == "label" and value:
                    by_hash[key][field] = value
                elif field not in by_hash[key] or by_hash[key].get(field) in (None, ""):
                    by_hash[key][field] = value
                elif source_name == "diagnostics" and field not in ("label",):
                    by_hash[key][field] = value
    merged = []
    for key in order:
        row = by_hash[key]
        if not row.get("label"):
            row["label"] = "unlabeled"
        if row["label"] not in LABELS:
            row["label"] = str(row["label"])
        for feature in FEATURES:
            row[feature] = feature_value(row, feature)
        merged.append(row)
    return merged


def percentile(sorted_values, frac):
    if not sorted_values:
        return None
    if len(sorted_values) == 1:
        return float(sorted_values[0])
    pos = float(frac) * float(len(sorted_values) - 1)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return float(sorted_values[lo])
    weight = pos - lo
    return float(sorted_values[lo]) * (1.0 - weight) + float(sorted_values[hi]) * weight


def feature_stats(rows, feature):
    values = [feature_value(row, feature) for row in rows]
    present = sorted([value for value in values if value is not None])
    if not present:
        return {
            "row_count": int(len(rows)),
            "count": 0,
            "missing_count": int(len(rows)),
            "mean": None,
            "median": None,
            "std": None,
            "min": None,
            "p10": None,
            "p25": None,
            "p75": None,
            "p90": None,
            "max": None,
        }
    return {
        "row_count": int(len(rows)),
        "count": int(len(present)),
        "missing_count": int(len(rows) - len(present)),
        "mean": float(sum(present)) / float(len(present)),
        "median": percentile(present, 0.50),
        "std": statistics.pstdev(present) if len(present) > 1 else 0.0,
        "min": float(present[0]),
        "p10": percentile(present, 0.10),
        "p25": percentile(present, 0.25),
        "p75": percentile(present, 0.75),
        "p90": percentile(present, 0.90),
        "max": float(present[-1]),
    }


def summarize_by_label(rows):
    by_label = {}
    for row in rows:
        by_label.setdefault(row.get("label") or "unlabeled", []).append(row)
    csv_rows = []
    json_payload = {"labels": {}, "features": list(FEATURES)}
    for label in sorted(by_label):
        label_rows = by_label[label]
        json_payload["labels"][label] = {"row_count": int(len(label_rows)), "features": {}}
        for feature in FEATURES:
            stats = feature_stats(label_rows, feature)
            json_payload["labels"][label]["features"][feature] = stats
            csv_rows.append({"label": label, "feature": feature, **stats})
    return csv_rows, json_payload


def pooled_std(a_stats, b_stats):
    a_n = int(a_stats.get("count") or 0)
    b_n = int(b_stats.get("count") or 0)
    a_std = a_stats.get("std")
    b_std = b_stats.get("std")
    if a_n <= 0 or b_n <= 0 or a_std is None or b_std is None:
        return None
    value = math.sqrt((float(a_std) ** 2 + float(b_std) ** 2) / 2.0)
    return value if value > 0 else None


def auc_like(a_values, b_values, high=True):
    if not a_values or not b_values:
        return None
    wins = 0.0
    total = 0
    for a in a_values:
        for b in b_values:
            total += 1
            if a == b:
                wins += 0.5
            elif high and a > b:
                wins += 1.0
            elif (not high) and a < b:
                wins += 1.0
    return float(wins) / float(total) if total else None


def pair_separation(rows):
    by_label = {}
    for row in rows:
        by_label.setdefault(row.get("label") or "unlabeled", []).append(row)
    out = []
    for label_a, label_b in PAIR_COMPARISONS:
        a_rows = by_label.get(label_a, [])
        b_rows = by_label.get(label_b, [])
        for feature in FEATURES:
            a_values = [feature_value(row, feature) for row in a_rows]
            b_values = [feature_value(row, feature) for row in b_rows]
            a_values = [value for value in a_values if value is not None]
            b_values = [value for value in b_values if value is not None]
            a_stats = feature_stats(a_rows, feature)
            b_stats = feature_stats(b_rows, feature)
            ps = pooled_std(a_stats, b_stats)
            mean_diff = None
            effect = None
            if a_stats["mean"] is not None and b_stats["mean"] is not None:
                mean_diff = float(a_stats["mean"] - b_stats["mean"])
                if ps is not None:
                    effect = float(mean_diff) / float(ps)
            high_auc = auc_like(a_values, b_values, high=True)
            low_auc = auc_like(a_values, b_values, high=False)
            if feature in LOW_EXACT_LIKE:
                exact_like_direction = "low"
                exact_like_auc = low_auc
            elif feature in HIGH_EXACT_LIKE:
                exact_like_direction = "high"
                exact_like_auc = high_auc
            else:
                exact_like_direction = "unspecified"
                exact_like_auc = None
            out.append(
                {
                    "label_a": label_a,
                    "label_b": label_b,
                    "feature": feature,
                    "count_a": int(len(a_values)),
                    "count_b": int(len(b_values)),
                    "median_a": a_stats["median"],
                    "median_b": b_stats["median"],
                    "median_difference": None if a_stats["median"] is None or b_stats["median"] is None else float(a_stats["median"] - b_stats["median"]),
                    "mean_a": a_stats["mean"],
                    "mean_b": b_stats["mean"],
                    "mean_difference": mean_diff,
                    "effect_size": effect,
                    "auc_like_A_gt_B": high_auc,
                    "auc_like_A_lt_B": low_auc,
                    "exact_like_direction": exact_like_direction,
                    "exact_like_auc": exact_like_auc,
                }
            )
    return out


def median(values):
    values = sorted([v for v in values if v is not None])
    return percentile(values, 0.50) if values else None


def zscore(value, stats):
    if value is None or stats["mean"] is None or stats["std"] is None or float(stats["std"]) == 0.0:
        return 0.0
    return (float(value) - float(stats["mean"])) / float(stats["std"])


def exact_like_scores(rows):
    score_features = ["D_min_ratio", "P_4", "P_8", "kappa_max", "Q_ratio"]
    global_stats = {feature: feature_stats(rows, feature) for feature in score_features}
    scored = []
    for row in rows:
        d = feature_value(row, "D_min_ratio")
        p4 = feature_value(row, "P_4")
        p8 = feature_value(row, "P_8")
        kappa = feature_value(row, "kappa_max")
        q_ratio = feature_value(row, "Q_ratio")
        components = {
            "z_D_min_ratio": zscore(d, global_stats["D_min_ratio"]),
            "z_P_4": zscore(p4, global_stats["P_4"]),
            "z_P_8": zscore(p8, global_stats["P_8"]),
            "z_kappa_max": zscore(kappa, global_stats["kappa_max"]),
            "z_Q_ratio": zscore(q_ratio, global_stats["Q_ratio"]),
        }
        exact_like_score = (
            -components["z_D_min_ratio"]
            + components["z_P_4"]
            + components["z_P_8"]
            + components["z_kappa_max"]
            - 0.25 * components["z_Q_ratio"]
        )
        scored.append(
            {
                "canonical_hash": row.get("canonical_hash"),
                "label": row.get("label") or "unlabeled",
                "origin_family": row.get("origin_family"),
                "score": feature_value(row, "score"),
                "D_min_ratio": d,
                "P_4": p4,
                "P_8": p8,
                "kappa_max": kappa,
                "Q_ratio": q_ratio,
                "ExactLikeScore": float(exact_like_score),
                "components": components,
            }
        )
    return scored, global_stats


def rule_prediction(row, thresholds, score_row=None):
    d = feature_value(row, "D_min_ratio")
    kappa = feature_value(row, "kappa_max")
    p4 = feature_value(row, "P_4")
    p8 = feature_value(row, "P_8")
    pred1 = "missing"
    if d is not None:
        pred1 = "exact_like" if d < 1.0 else "false_like"
    pred2 = "missing"
    if kappa is not None:
        if kappa >= 1.0:
            pred2 = "exact_like"
        elif kappa >= 0.95:
            pred2 = "near_exact_like"
        else:
            pred2 = "false_like"
    pred3 = "missing"
    if p4 is not None or p8 is not None:
        p4_ok = p4 is not None and p4 > thresholds["P_4_median"]
        p8_ok = p8 is not None and p8 > thresholds["P_8_median"]
        pred3 = "locally_rich" if (p4_ok or p8_ok) else "locally_dead"
    pred4 = "missing"
    if score_row is not None:
        if score_row["ExactLikeScore"] >= thresholds["ExactLikeScore_threshold"]:
            pred4 = "exact_like"
        else:
            pred4 = "false_like"
    return {
        "D_min_ratio_rule": pred1,
        "kappa_rule": pred2,
        "P_tau_rule": pred3,
        "composite_rule": pred4,
    }


def ground_truth(label):
    if label in GROUND_EXACT_LIKE:
        return "exact_like"
    if label in GROUND_FALSE_LIKE:
        return "false_like"
    return None


def normalize_prediction(rule_name, pred):
    if pred in ("exact_like", "near_exact_like", "locally_rich"):
        return "exact_like"
    if pred in ("false_like", "locally_dead"):
        return "false_like"
    return None


def evaluate_rule(rule_name, rows, scored_by_hash, thresholds):
    tp = fp = tn = fn = missing = 0
    evaluated = 0
    for row in rows:
        truth = ground_truth(row.get("label") or "unlabeled")
        if truth is None:
            continue
        score_row = scored_by_hash.get(row.get("canonical_hash"))
        pred = rule_prediction(row, thresholds, score_row).get(rule_name)
        normalized = normalize_prediction(rule_name, pred)
        if normalized is None:
            missing += 1
            continue
        evaluated += 1
        if truth == "exact_like" and normalized == "exact_like":
            tp += 1
        elif truth == "exact_like" and normalized == "false_like":
            fn += 1
        elif truth == "false_like" and normalized == "false_like":
            tn += 1
        elif truth == "false_like" and normalized == "exact_like":
            fp += 1
    accuracy = float(tp + tn) / float(evaluated) if evaluated else None
    precision = float(tp) / float(tp + fp) if (tp + fp) else None
    recall = float(tp) / float(tp + fn) if (tp + fn) else None
    false_precision = float(tn) / float(tn + fn) if (tn + fn) else None
    false_recall = float(tn) / float(tn + fp) if (tn + fp) else None
    return {
        "rule_name": rule_name,
        "evaluated_count": int(evaluated),
        "missing_count": int(missing),
        "tp_exact_like": int(tp),
        "fp_exact_like": int(fp),
        "tn_false_like": int(tn),
        "fn_exact_like": int(fn),
        "accuracy": accuracy,
        "precision_exact_like": precision,
        "recall_exact_like": recall,
        "precision_false_like": false_precision,
        "recall_false_like": false_recall,
    }


def rule_evaluation(rows, scored):
    p4_median = median([feature_value(row, "P_4") for row in rows])
    p8_median = median([feature_value(row, "P_8") for row in rows])
    exact_scores = [row["ExactLikeScore"] for row in scored if row["label"] in GROUND_EXACT_LIKE]
    false_scores = [row["ExactLikeScore"] for row in scored if row["label"] in GROUND_FALSE_LIKE]
    exact_med = median(exact_scores)
    false_med = median(false_scores)
    if exact_med is not None and false_med is not None:
        threshold = (float(exact_med) + float(false_med)) / 2.0
        margin = max(0.25, abs(float(exact_med) - float(false_med)) * 0.25)
    else:
        threshold = median([row["ExactLikeScore"] for row in scored]) or 0.0
        margin = 0.25
    thresholds = {
        "P_4_median": p4_median if p4_median is not None else 0.0,
        "P_8_median": p8_median if p8_median is not None else 0.0,
        "ExactLikeScore_exact_median": exact_med,
        "ExactLikeScore_false_median": false_med,
        "ExactLikeScore_threshold": threshold,
        "ExactLikeScore_ambiguous_margin": margin,
    }
    scored_by_hash = {row["canonical_hash"]: row for row in scored}
    eval_rows = []
    for rule_name in ("D_min_ratio_rule", "kappa_rule", "P_tau_rule", "composite_rule"):
        payload = evaluate_rule(rule_name, rows, scored_by_hash, thresholds)
        payload.update(thresholds)
        eval_rows.append(payload)
    for row in scored:
        raw = next((item for item in rows if item.get("canonical_hash") == row["canonical_hash"]), None)
        row["rule_predictions"] = rule_prediction(raw, thresholds, row) if raw else {}
    return eval_rows, thresholds


def unknown_suggestions(rows, scored, thresholds):
    scored_by_hash = {row["canonical_hash"]: row for row in scored}
    out = []
    threshold = float(thresholds["ExactLikeScore_threshold"])
    margin = float(thresholds["ExactLikeScore_ambiguous_margin"])
    for row in rows:
        if row.get("label") != "unknown":
            continue
        score_row = scored_by_hash.get(row.get("canonical_hash"))
        if score_row is None:
            continue
        value = float(score_row["ExactLikeScore"])
        if value >= threshold + margin:
            tentative = "unknown_exact_like"
        elif value <= threshold - margin:
            tentative = "unknown_false_like"
        else:
            tentative = "unknown_ambiguous"
        out.append(
            {
                "canonical_hash": row.get("canonical_hash"),
                "origin_family": row.get("origin_family"),
                "origin_stage": row.get("origin_stage"),
                "score": feature_value(row, "score"),
                "D_min_ratio": feature_value(row, "D_min_ratio"),
                "P_4": feature_value(row, "P_4"),
                "P_8": feature_value(row, "P_8"),
                "kappa_max": feature_value(row, "kappa_max"),
                "Q_ratio": feature_value(row, "Q_ratio"),
                "ExactLikeScore": value,
                "tentative_label": tentative,
                "threshold": threshold,
                "ambiguous_margin": margin,
            }
        )
    return out


def top_separators(pair_rows, label_a="exact_derived", label_b="search_derived_false_basin"):
    candidates = []
    for row in pair_rows:
        if row["label_a"] != label_a or row["label_b"] != label_b:
            continue
        if row["feature"] == "score":
            continue
        effect = row.get("effect_size")
        auc = row.get("exact_like_auc")
        score = 0.0
        if effect is not None:
            score += abs(float(effect))
        if auc is not None:
            score += 2.0 * abs(float(auc) - 0.5)
        if score > 0:
            candidates.append((score, row))
    candidates.sort(key=lambda item: item[0], reverse=True)
    return [row for _score, row in candidates[:8]]


def label_score_distribution(scored):
    by_label = {}
    for row in scored:
        by_label.setdefault(row["label"], []).append(row["ExactLikeScore"])
    return {label: feature_stats([{"x": value} for value in values], "x") for label, values in sorted(by_label.items())}


def feature_stats_from_pair(pair_rows, feature, label_a, label_b):
    for row in pair_rows:
        if row["feature"] == feature and row["label_a"] == label_a and row["label_b"] == label_b:
            return row
    return {}


def make_summary(path, context):
    top = context["top_features"]
    top_names = [row["feature"] for row in top[:5]]
    pair_rows = context["pair_rows"]
    d_row = feature_stats_from_pair(pair_rows, "D_min_ratio", "exact_derived", "search_derived_false_basin")
    p4_row = feature_stats_from_pair(pair_rows, "P_4", "exact_derived", "search_derived_false_basin")
    p8_row = feature_stats_from_pair(pair_rows, "P_8", "exact_derived", "search_derived_false_basin")
    k_row = feature_stats_from_pair(pair_rows, "kappa_max", "exact_derived", "search_derived_false_basin")
    q_row = feature_stats_from_pair(pair_rows, "Q_ratio", "exact_derived", "search_derived_false_basin")
    ih_row = feature_stats_from_pair(pair_rows, "InitHardness", "exact_derived", "search_derived_false_basin")
    unknown_counts = {}
    for row in context["unknown_suggestions"]:
        unknown_counts[row["tentative_label"]] = unknown_counts.get(row["tentative_label"], 0) + 1
    separated = any(
        row.get("exact_like_auc") is not None and abs(float(row["exact_like_auc"]) - 0.5) >= 0.25
        for row in top[:5]
    ) or any(row.get("effect_size") is not None and abs(float(row["effect_size"])) >= 0.8 for row in top[:5])
    lines = [
        "# p37 Classifier Feature Analysis Summary",
        "",
        "This analysis reads existing pipeline classifier rows only. No new SDS search was run.",
        "",
        "## Input",
        "",
        "- input_dir: `{}`".format(context["input_dir"]),
        "- merged classifier rows: `{}`".format(context["row_count"]),
        "- labels: `{}`".format(context["label_counts"]),
        "",
        "## Missing / Derived Features",
        "",
        "- Missing requested features with no values: `{}`".format(context["missing_features"]),
        "- Derived features: `h_min_over_S`, `near_improving_count_h_le_4/8/16` when source fields allowed it.",
        "- `kappa_q95` was not present in the current diagnostic rows.",
        "",
        "## Strongest Separators",
        "",
        "```json",
        json.dumps(json_safe(top[:8]), indent=2, sort_keys=True),
        "```",
        "",
        "## Rule Evaluation",
        "",
        "```json",
        json.dumps(json_safe(context["rule_rows"]), indent=2, sort_keys=True),
        "```",
        "",
        "## Unknown Relabel Suggestions",
        "",
        "```json",
        json.dumps(json_safe(unknown_counts), indent=2, sort_keys=True),
        "```",
        "",
        "## Required Answers",
        "",
        "1. exact_derived と search_derived_false_basin は、score 以外の特徴量で分かれたか: `{}`。ただし p=37 pipeline の heuristic label 上での初期検証であり、確定分類器ではない。".format("yes" if separated else "weak/partial"),
        "2. 最も効いた feature は何か: `{}`.".format(", ".join(top_names) if top_names else "no clear non-score separator"),
        "3. D_min_ratio は primary classifier として有効か: median exact_derived `{}`, false_basin `{}`, exact-like AUC `{}`。".format(d_row.get("median_a"), d_row.get("median_b"), d_row.get("exact_like_auc")),
        "4. P_tau は local entropy feature として有効か: P_4 AUC `{}`, P_8 AUC `{}`。".format(p4_row.get("exact_like_auc"), p8_row.get("exact_like_auc")),
        "5. kappa_max は g/q separation feature として有効か: median exact_derived `{}`, false_basin `{}`, exact-like AUC `{}`。".format(k_row.get("median_a"), k_row.get("median_b"), k_row.get("exact_like_auc")),
        "6. Q_ratio / InitHardness は primary か secondary か: Q_ratio effect `{}`, InitHardness effect `{}`。現段階では secondary と扱う。".format(q_row.get("effect_size"), ih_row.get("effect_size")),
        "7. unknown candidates は exact-like と false-like に再分類できそうか: `{}`。".format(unknown_counts),
        "8. p=37 で得た classifier を 668 に使う場合の注意点: label は heuristic で、p=37 exact distance proxy に依存する。668 では exact がないため absolute threshold ではなく rank / trajectory / repair response として使うべき。",
        "9. 次に Codex で検証すべき feature / trajectory 実験: D_min_ratio, P_4/P_8, kappa_max の composite score を trajectory frontier selection に入れ、p=43/47 と 668 low-score rows で同じ feature table を比較する。",
    ]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def inventory(input_dir):
    files = [
        "false_basin_classifier_features.csv",
        "candidate_labels.jsonl",
        "diagnostic_candidates.jsonl",
        "comparison_summary.json",
        "pipeline_framework_summary.md",
    ]
    payload = {"input_dir": input_dir, "files": {}}
    for name in files:
        path = os.path.join(input_dir, name)
        item = {"path": path, "exists": os.path.exists(path)}
        if os.path.exists(path):
            item["size_bytes"] = os.path.getsize(path)
            if name.endswith(".jsonl"):
                item["row_count"] = len(read_jsonl(path))
            elif name.endswith(".csv"):
                rows = read_csv(path)
                item["row_count"] = len(rows)
                item["columns"] = list(rows[0].keys()) if rows else []
        payload["files"][name] = item
    return payload


def parse_args():
    parser = argparse.ArgumentParser(description="Analyze p=37 classifier feature distributions by label.")
    parser.add_argument("--input-dir", default="outputs/explorations/20260506_1557_p37_pipeline_framework")
    parser.add_argument("--out-dir", default=None)
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        input_dir = args.input_dir
        if not input_dir or not os.path.isdir(input_dir):
            input_dir = latest_pipeline_dir()
        if not input_dir or not os.path.isdir(input_dir):
            raise ValueError("could not find p37 pipeline framework output directory")
        out_dir = args.out_dir or os.path.join("outputs", "explorations", "{}_p37_classifier_feature_analysis".format(now_stamp()))
        ensure_dir(out_dir)

        paths = {
            "classifier_csv": os.path.join(input_dir, "false_basin_classifier_features.csv"),
            "labels_jsonl": os.path.join(input_dir, "candidate_labels.jsonl"),
            "diagnostics_jsonl": os.path.join(input_dir, "diagnostic_candidates.jsonl"),
        }
        run_config = {
            "script": SCRIPT_NAME,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "input_dir": input_dir,
            "out_dir": out_dir,
            "features": list(FEATURES),
            "pair_comparisons": [list(pair) for pair in PAIR_COMPARISONS],
            "note": "Existing pipeline rows only; no search was run.",
        }
        write_json_safe(os.path.join(out_dir, "run_config.json"), run_config)
        with open(os.path.join(out_dir, "run_log.md"), "w") as f:
            f.write("# Run Log\n\n")
            f.write("- script: `{}`\n".format(SCRIPT_NAME))
            f.write("- input_dir: `{}`\n".format(input_dir))
            f.write("- no new search was run\n")

        inv = inventory(input_dir)
        write_json_safe(os.path.join(out_dir, "input_file_inventory.json"), inv)

        classifier_rows = read_csv(paths["classifier_csv"])
        label_rows = read_jsonl(paths["labels_jsonl"])
        diagnostic_rows = read_jsonl(paths["diagnostics_jsonl"])
        merged = merge_rows(classifier_rows, label_rows, diagnostic_rows)
        label_counts = {}
        for row in merged:
            label_counts[row.get("label") or "unlabeled"] = label_counts.get(row.get("label") or "unlabeled", 0) + 1
        missing_features = [feature for feature in FEATURES if not any(feature_value(row, feature) is not None for row in merged)]
        summary_rows, summary_json = summarize_by_label(merged)
        summary_json["missing_features"] = missing_features
        summary_json["label_counts"] = label_counts
        write_csv(
            os.path.join(out_dir, "label_feature_summary.csv"),
            summary_rows,
            ["label", "feature", "row_count", "count", "missing_count", "mean", "median", "std", "min", "p10", "p25", "p75", "p90", "max"],
        )
        write_json_safe(os.path.join(out_dir, "label_feature_summary.json"), summary_json)

        pair_rows = pair_separation(merged)
        write_csv(
            os.path.join(out_dir, "label_pair_feature_separation.csv"),
            pair_rows,
            [
                "label_a",
                "label_b",
                "feature",
                "count_a",
                "count_b",
                "median_a",
                "median_b",
                "median_difference",
                "mean_a",
                "mean_b",
                "mean_difference",
                "effect_size",
                "auc_like_A_gt_B",
                "auc_like_A_lt_B",
                "exact_like_direction",
                "exact_like_auc",
            ],
        )

        scored, _global_stats = exact_like_scores(merged)
        rule_rows, thresholds = rule_evaluation(merged, scored)
        write_csv(
            os.path.join(out_dir, "classifier_rule_evaluation.csv"),
            rule_rows,
            [
                "rule_name",
                "evaluated_count",
                "missing_count",
                "tp_exact_like",
                "fp_exact_like",
                "tn_false_like",
                "fn_exact_like",
                "accuracy",
                "precision_exact_like",
                "recall_exact_like",
                "precision_false_like",
                "recall_false_like",
                "P_4_median",
                "P_8_median",
                "ExactLikeScore_exact_median",
                "ExactLikeScore_false_median",
                "ExactLikeScore_threshold",
                "ExactLikeScore_ambiguous_margin",
            ],
        )
        write_jsonl(os.path.join(out_dir, "classifier_scores.jsonl"), scored)
        suggestions = unknown_suggestions(merged, scored, thresholds)
        write_jsonl(os.path.join(out_dir, "unknown_relabel_suggestions.jsonl"), suggestions)

        top = top_separators(pair_rows)
        make_summary(
            os.path.join(out_dir, "p37_classifier_feature_analysis_summary.md"),
            {
                "input_dir": input_dir,
                "row_count": len(merged),
                "label_counts": label_counts,
                "missing_features": missing_features,
                "top_features": top,
                "pair_rows": pair_rows,
                "rule_rows": rule_rows,
                "unknown_suggestions": suggestions,
            },
        )
        print("SUMMARY:", os.path.join(out_dir, "p37_classifier_feature_analysis_summary.md"))
    finally:
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
