#!/usr/bin/env python3

import argparse
import glob
import json
import math
import os
import statistics
import time
from collections import Counter, defaultdict


METRIC_KEYS = ("score", "l1_error", "max_abs_error", "nonzero_defect_count")


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)


def write_json(path, payload):
    ensure_dir(os.path.dirname(path) or ".")
    with open(path, "w") as f:
        json.dump(payload, f, indent=2, sort_keys=True)


def write_text(path, text):
    ensure_dir(os.path.dirname(path) or ".")
    with open(path, "w") as f:
        f.write(text)


def read_json(path):
    with open(path) as f:
        return json.load(f)


def total_diff_counts(v, blocks):
    total = [0] * int(v)
    for block in blocks:
        values = list(block)
        for x in values:
            for y in values:
                if x != y:
                    total[(x - y) % int(v)] += 1
    return total


def metrics_from_counts(counts, lam):
    score = 0
    l1_error = 0
    max_abs_error = 0
    nonzero_defect_count = 0
    for d in range(1, len(counts)):
        err = int(counts[d] - lam)
        abs_err = abs(err)
        score += err * err
        l1_error += abs_err
        max_abs_error = max(max_abs_error, abs_err)
        if err:
            nonzero_defect_count += 1
    return (score, l1_error, max_abs_error, nonzero_defect_count)


def defect_vector(counts, lam):
    return [int(counts[d] - lam) for d in range(1, len(counts))]


def defect_histogram(vec):
    hist = Counter(vec)
    return {str(key): int(hist[key]) for key in sorted(hist)}


def metric_tuple(record):
    return tuple(int(record[key]) for key in METRIC_KEYS)


def parameter_key(record):
    return (
        tuple(int(k) for k in record["ks"]),
        int(record["lambda"]),
    )


def dominates(left, right):
    lm = metric_tuple(left)
    rm = metric_tuple(right)
    return all(a <= b for a, b in zip(lm, rm)) and any(
        a < b for a, b in zip(lm, rm)
    )


def pareto_frontier(records):
    frontier = []
    for idx, record in enumerate(records):
        dominated = False
        for jdx, other in enumerate(records):
            if idx == jdx:
                continue
            if dominates(other, record):
                dominated = True
                break
        if not dominated:
            frontier.append(record)
    frontier.sort(key=lambda item: metric_tuple(item) + (item["path"],))
    return frontier


def pearson(xs, ys):
    n = len(xs)
    if n < 2:
        return None
    mx = sum(xs) / n
    my = sum(ys) / n
    vx = sum((x - mx) ** 2 for x in xs)
    vy = sum((y - my) ** 2 for y in ys)
    if vx == 0 or vy == 0:
        return None
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / math.sqrt(vx * vy)


def rank_values(values):
    indexed = sorted((value, idx) for idx, value in enumerate(values))
    ranks = [0.0] * len(values)
    pos = 0
    while pos < len(indexed):
        end = pos + 1
        while end < len(indexed) and indexed[end][0] == indexed[pos][0]:
            end += 1
        rank = (pos + end - 1) / 2.0 + 1.0
        for _, idx in indexed[pos:end]:
            ranks[idx] = rank
        pos = end
    return ranks


def spearman(xs, ys):
    if len(xs) < 2:
        return None
    return pearson(rank_values(xs), rank_values(ys))


def correlation_table(records):
    pairs = [
        ("score", "l1_error"),
        ("score", "max_abs_error"),
        ("score", "nonzero_defect_count"),
        ("l1_error", "nonzero_defect_count"),
        ("l1_error", "max_abs_error"),
        ("max_abs_error", "nonzero_defect_count"),
    ]
    out = []
    for left, right in pairs:
        xs = [int(record[left]) for record in records]
        ys = [int(record[right]) for record in records]
        out.append(
            {
                "left": left,
                "right": right,
                "pearson": pearson(xs, ys),
                "spearman": spearman(xs, ys),
                "n": len(records),
            }
        )
    return out


def source_type(path, data):
    method = str(data.get("search_method") or "")
    name = os.path.basename(path)
    if "guided" in method or "07_guided" in name:
        return "guided"
    if "steepest" in method or "11_steepest" in name:
        return "steepest"
    if "beam" in method or "12_beam" in name:
        return "beam"
    if "ilp" in method or "13_ilp" in name:
        return "ilp"
    if "frontier" in path:
        return "frontier_copy"
    if "one_block" in method or "15_one_block" in name:
        return "one_block_completion"
    return "unknown"


def load_records(pattern):
    paths = sorted(set(glob.glob(pattern, recursive=True)))
    records = []
    invalid = []
    metric_mismatches = []
    for path in paths:
        try:
            data = read_json(path)
        except Exception as exc:
            invalid.append({"path": path, "reason": "json_error:{}".format(exc)})
            continue
        if not isinstance(data, dict):
            invalid.append({"path": path, "reason": "not_object"})
            continue
        required = ["v", "n", "ks", "lambda", "blocks"] + list(METRIC_KEYS)
        missing = [key for key in required if key not in data]
        if missing:
            invalid.append({"path": path, "reason": "missing:{}".format(missing)})
            continue
        try:
            v = int(data["v"])
            n = int(data["n"])
            if v != 167 or n != 668:
                continue
            ks = tuple(int(k) for k in data["ks"])
            lam = int(data["lambda"])
            blocks = [set(int(x) for x in block) for block in data["blocks"]]
            counts = total_diff_counts(v, blocks)
            recomputed = metrics_from_counts(counts, lam)
            saved = tuple(int(data[key]) for key in METRIC_KEYS)
            vec = defect_vector(counts, lam)
        except Exception as exc:
            invalid.append({"path": path, "reason": "parse_error:{}".format(exc)})
            continue

        metrics_match = saved == recomputed
        if not metrics_match:
            metric_mismatches.append(
                {
                    "path": path,
                    "saved": list(saved),
                    "recomputed": list(recomputed),
                }
            )

        record = {
            "path": path,
            "v": v,
            "n": n,
            "ks": list(ks),
            "lambda": lam,
            "score": int(recomputed[0]),
            "l1_error": int(recomputed[1]),
            "max_abs_error": int(recomputed[2]),
            "nonzero_defect_count": int(recomputed[3]),
            "saved_metrics": list(saved),
            "metrics_match": bool(metrics_match),
            "canonical_hash": data.get("canonical_hash", ""),
            "source_type": source_type(path, data),
            "search_method": data.get("search_method", ""),
            "objective_schedule": data.get("objective_schedule")
            or data.get("objective")
            or data.get("diagnostic_objective")
            or "",
            "seed": data.get("seed"),
            "step": data.get("step"),
            "source_json": data.get("source_json"),
            "selected_moves_count": len(data.get("selected_moves", []) or []),
            "defect_vector": vec,
            "defect_support": [idx + 1 for idx, value in enumerate(vec) if value != 0],
            "positive_support": [idx + 1 for idx, value in enumerate(vec) if value > 0],
            "negative_support": [idx + 1 for idx, value in enumerate(vec) if value < 0],
            "defect_histogram": defect_histogram(vec),
        }
        records.append(record)
    return paths, records, invalid, metric_mismatches


def compact_record(record, include_vector=False):
    keys = [
        "path",
        "canonical_hash",
        "ks",
        "lambda",
        "score",
        "l1_error",
        "max_abs_error",
        "nonzero_defect_count",
        "source_type",
        "search_method",
        "objective_schedule",
        "seed",
        "step",
        "metrics_match",
    ]
    out = {key: record.get(key) for key in keys}
    if include_vector:
        out["defect_vector"] = record["defect_vector"]
        out["defect_support"] = record["defect_support"]
        out["positive_support"] = record["positive_support"]
        out["negative_support"] = record["negative_support"]
        out["defect_histogram"] = record["defect_histogram"]
    return out


def best_by(records, keys):
    if not records:
        return None
    return compact_record(min(records, key=lambda item: tuple(item[key] for key in keys)))


def dataset_summary(paths, records, invalid, mismatches):
    by_param = defaultdict(list)
    by_source = Counter()
    by_objective = Counter()
    for record in records:
        by_param[parameter_key(record)].append(record)
        by_source[record["source_type"]] += 1
        by_objective[record["objective_schedule"] or "(none)"] += 1
    param_summary = []
    for key, group in sorted(
        by_param.items(), key=lambda item: best_by(item[1], ["score"])["score"]
    ):
        param_summary.append(
            {
                "ks": list(key[0]),
                "lambda": key[1],
                "count": len(group),
                "best_by_score": best_by(
                    group,
                    ["score", "l1_error", "max_abs_error", "nonzero_defect_count"],
                ),
                "best_by_l1": best_by(
                    group,
                    ["l1_error", "score", "max_abs_error", "nonzero_defect_count"],
                ),
                "best_by_nonzero": best_by(
                    group,
                    ["nonzero_defect_count", "score", "l1_error", "max_abs_error"],
                ),
                "best_by_max_abs": best_by(
                    group,
                    ["max_abs_error", "score", "l1_error", "nonzero_defect_count"],
                ),
            }
        )
    hashes = [record["canonical_hash"] for record in records if record["canonical_hash"]]
    return {
        "total_json_files": len(paths),
        "valid_near_hits": len(records),
        "invalid_or_skipped_json": len(invalid),
        "metrics_mismatch_count": len(mismatches),
        "unique_canonical_hashes": len(set(hashes)),
        "missing_canonical_hash_count": sum(1 for record in records if not record["canonical_hash"]),
        "counts_by_ks_lambda": param_summary,
        "counts_by_source_type": dict(sorted(by_source.items())),
        "counts_by_objective_schedule": dict(sorted(by_objective.items())),
        "best_overall_by_score": best_by(
            records, ["score", "l1_error", "max_abs_error", "nonzero_defect_count"]
        ),
        "best_overall_by_l1": best_by(
            records, ["l1_error", "score", "max_abs_error", "nonzero_defect_count"]
        ),
        "best_overall_by_nonzero": best_by(
            records, ["nonzero_defect_count", "score", "l1_error", "max_abs_error"]
        ),
        "metric_mismatches_first": mismatches[:20],
        "invalid_first": invalid[:20],
    }


def correlation_analysis(records):
    overall = correlation_table(records)
    by_param = []
    groups = defaultdict(list)
    for record in records:
        groups[parameter_key(record)].append(record)
    for key, group in sorted(groups.items()):
        if len(group) >= 3:
            by_param.append(
                {
                    "ks": list(key[0]),
                    "lambda": key[1],
                    "count": len(group),
                    "correlations": correlation_table(group),
                }
            )
    by_objective = []
    groups = defaultdict(list)
    for record in records:
        groups[record["objective_schedule"] or "(none)"].append(record)
    for key, group in sorted(groups.items()):
        if len(group) >= 10:
            by_objective.append(
                {"objective": key, "count": len(group), "correlations": correlation_table(group)}
            )
    score_nonzero_gap = sorted(
        records,
        key=lambda record: (
            record["score"] / max(1, record["nonzero_defect_count"]),
            record["score"],
        ),
    )[:30]
    return {
        "overall": overall,
        "by_parameter": by_param,
        "by_objective": by_objective,
        "low_score_per_nonzero_examples": [compact_record(r) for r in score_nonzero_gap],
    }


def pareto_analysis(records):
    overall = pareto_frontier(records)
    by_param = []
    groups = defaultdict(list)
    for record in records:
        groups[parameter_key(record)].append(record)
    for key, group in sorted(groups.items()):
        front = pareto_frontier(group)
        by_param.append(
            {
                "ks": list(key[0]),
                "lambda": key[1],
                "frontier_count": len(front),
                "representatives": [compact_record(r) for r in front[:50]],
            }
        )
    best_by_hash = {}
    for record in records:
        h = record["canonical_hash"] or record["path"]
        if h not in best_by_hash or metric_tuple(record) < metric_tuple(best_by_hash[h]):
            best_by_hash[h] = record
    canonical_front = pareto_frontier(list(best_by_hash.values()))
    return {
        "overall_frontier_count": len(overall),
        "overall_representatives": [compact_record(r) for r in overall[:80]],
        "parameter_frontiers": by_param,
        "canonical_dedup_frontier_count": len(canonical_front),
        "canonical_dedup_representatives": [compact_record(r) for r in canonical_front[:80]],
    }


def canonical_basin_analysis(records):
    groups = defaultdict(list)
    for record in records:
        h = record["canonical_hash"] or "missing:" + record["path"]
        groups[h].append(record)
    basins = []
    for h, group in groups.items():
        best_score = min(
            group, key=lambda item: (item["score"], item["l1_error"], item["max_abs_error"], item["nonzero_defect_count"])
        )
        best_l1 = min(
            group, key=lambda item: (item["l1_error"], item["score"], item["max_abs_error"], item["nonzero_defect_count"])
        )
        basins.append(
            {
                "canonical_hash": h,
                "count": len(group),
                "best_score": compact_record(best_score),
                "best_l1": compact_record(best_l1),
                "source_types": dict(Counter(record["source_type"] for record in group)),
                "objectives": dict(Counter(record["objective_schedule"] or "(none)" for record in group)),
                "defect_vector_representative": best_score["defect_vector"],
            }
        )
    basins.sort(
        key=lambda item: (
            item["best_score"]["score"],
            item["best_score"]["l1_error"],
            item["best_score"]["max_abs_error"],
            item["best_score"]["nonzero_defect_count"],
        )
    )
    return {
        "canonical_basin_count": len(basins),
        "top_basins": basins[:200],
    }


def l1_distance(left, right):
    return sum(abs(a - b) for a, b in zip(left, right))


def support_distance(left, right):
    ls = {idx for idx, value in enumerate(left) if value != 0}
    rs = {idx for idx, value in enumerate(right) if value != 0}
    return len(ls.symmetric_difference(rs))


def sign_hamming(left, right):
    def sign(x):
        return -1 if x < 0 else (1 if x > 0 else 0)

    return sum(1 for a, b in zip(left, right) if sign(a) != sign(b))


def choose_cluster_sample(records, max_records):
    selected = []
    seen = set()
    ranked_lists = [
        sorted(records, key=lambda r: (r["score"], r["l1_error"], r["max_abs_error"], r["nonzero_defect_count"])),
        sorted(records, key=lambda r: (r["l1_error"], r["score"], r["max_abs_error"], r["nonzero_defect_count"])),
        sorted(records, key=lambda r: (r["nonzero_defect_count"], r["score"], r["l1_error"], r["max_abs_error"])),
        sorted(records, key=lambda r: (r["max_abs_error"], r["score"], r["l1_error"], r["nonzero_defect_count"])),
    ]
    for ranked in ranked_lists:
        for record in ranked[: max(50, max_records // 4)]:
            key = record["path"]
            if key not in seen:
                seen.add(key)
                selected.append(record)
            if len(selected) >= max_records:
                return selected
    return selected[:max_records]


def farthest_first_medoids(sample, k):
    if not sample:
        return []
    medoids = [min(sample, key=lambda r: metric_tuple(r))]
    while len(medoids) < min(k, len(sample)):
        best = None
        best_distance = -1
        for record in sample:
            if record in medoids:
                continue
            distance = min(l1_distance(record["defect_vector"], m["defect_vector"]) for m in medoids)
            if distance > best_distance:
                best = record
                best_distance = distance
        medoids.append(best)
    return medoids


def branch_label(record):
    m = metric_tuple(record)
    ks = tuple(record["ks"])
    lam = int(record["lambda"])
    labels = []
    if m == (164, 116, 3, 96) and ks == (73, 78, 79, 81) and lam == 144:
        labels.append("score164")
    if m == (176, 112, 3, 86) and ks == (73, 78, 79, 81) and lam == 144:
        labels.append("score176")
    if m == (184, 112, 3, 80) and ks == (73, 76, 83, 83) and lam == 148:
        labels.append("low_nonzero")
    if int(record["max_abs_error"]) == 2:
        labels.append("maxabs2")
    return labels


def defect_cluster_analysis(records, max_records=1200, k=12):
    sample = choose_cluster_sample(records, max_records)
    medoids = farthest_first_medoids(sample, k)
    clusters = [
        {
            "cluster_id": idx,
            "medoid": medoid,
            "members": [],
        }
        for idx, medoid in enumerate(medoids)
    ]
    for record in sample:
        distances = [l1_distance(record["defect_vector"], m["defect_vector"]) for m in medoids]
        cluster_idx = min(range(len(distances)), key=lambda idx: (distances[idx], idx))
        clusters[cluster_idx]["members"].append(record)

    out_clusters = []
    representatives = {
        label: next((r for r in records if label in branch_label(r)), None)
        for label in ["score164", "score176", "low_nonzero"]
    }
    for cluster in clusters:
        members = cluster["members"]
        if not members:
            continue
        best = min(members, key=lambda r: metric_tuple(r))
        mean_metrics = {
            key: statistics.mean(record[key] for record in members) for key in METRIC_KEYS
        }
        labels = Counter(label for record in members for label in branch_label(record))
        distances_to_known = {}
        for label, rep in representatives.items():
            if rep is None:
                distances_to_known[label] = None
            else:
                distances_to_known[label] = {
                    "l1_distance": l1_distance(cluster["medoid"]["defect_vector"], rep["defect_vector"]),
                    "support_symmetric_difference": support_distance(cluster["medoid"]["defect_vector"], rep["defect_vector"]),
                    "sign_hamming": sign_hamming(cluster["medoid"]["defect_vector"], rep["defect_vector"]),
                }
        out_clusters.append(
            {
                "cluster_id": cluster["cluster_id"],
                "members_count": len(members),
                "medoid": compact_record(cluster["medoid"], include_vector=True),
                "best_metrics_record": compact_record(best),
                "mean_metrics": {key: float(value) for key, value in mean_metrics.items()},
                "branch_labels": dict(labels),
                "dominant_source_type": Counter(record["source_type"] for record in members).most_common(1)[0][0],
                "representative_ks_lambda": Counter(
                    (tuple(record["ks"]), record["lambda"]) for record in members
                ).most_common(1)[0][0],
                "distances_to_known_branches": distances_to_known,
            }
        )
    out_clusters.sort(key=lambda item: item["best_metrics_record"]["score"])
    return {
        "sample_size": len(sample),
        "cluster_count": len(out_clusters),
        "distance": "L1 defect vector with farthest-first medoids",
        "clusters": out_clusters,
    }


def repair_transition_analysis(records):
    by_path = {os.path.normpath(record["path"]): record for record in records}
    transitions = []
    for record in records:
        source = record.get("source_json")
        if not source:
            continue
        source_norm = os.path.normpath(source)
        if source_norm not in by_path and os.path.exists(source_norm):
            # Source may be outside the glob result but still parseable.
            continue
        before = by_path.get(source_norm)
        if before is None:
            continue
        transitions.append(
            {
                "transition_type": record["source_type"],
                "input_path": before["path"],
                "output_path": record["path"],
                "before_metrics": {
                    key: int(before[key]) for key in METRIC_KEYS
                },
                "after_metrics": {
                    key: int(record[key]) for key in METRIC_KEYS
                },
                "delta_metrics": {
                    key: int(record[key]) - int(before[key]) for key in METRIC_KEYS
                },
                "input_hash": before["canonical_hash"],
                "output_hash": record["canonical_hash"],
                "same_hash": bool(before["canonical_hash"] == record["canonical_hash"]),
                "selected_moves_count": int(record.get("selected_moves_count", 0)),
            }
        )
    return {
        "transition_count": len(transitions),
        "same_hash_count": sum(1 for t in transitions if t["same_hash"]),
        "improved_score_count": sum(1 for t in transitions if t["delta_metrics"]["score"] < 0),
        "improved_l1_count": sum(1 for t in transitions if t["delta_metrics"]["l1_error"] < 0),
        "transitions": transitions[:500],
    }


def md_table(records, headers, value_fn):
    lines = ["|" + "|".join(headers) + "|", "|" + "|".join(["---"] * len(headers)) + "|"]
    for record in records:
        lines.append("|" + "|".join(str(x) for x in value_fn(record)) + "|")
    return "\n".join(lines)


def write_reports(out_dir, analyses):
    raw_dir = os.path.join(out_dir, "raw")
    review_dir = os.path.join(out_dir, "review")
    logs_dir = os.path.join(out_dir, "logs")
    for path in (out_dir, raw_dir, review_dir, logs_dir):
        ensure_dir(path)

    for name, payload in analyses.items():
        write_json(os.path.join(raw_dir, name + ".json"), payload)

    summary = analyses["near_hit_dataset_summary"]
    corr = analyses["metric_correlation_analysis"]
    pareto = analyses["pareto_frontier_analysis"]
    clusters = analyses["defect_cluster_analysis"]
    transitions = analyses["repair_transition_analysis"]

    write_text(
        os.path.join(out_dir, "near_hit_dataset_summary.md"),
        "# Near-Hit Dataset Summary\n\n"
        "- total_json_files: `{}`\n"
        "- valid_near_hits: `{}`\n"
        "- unique_canonical_hashes: `{}`\n"
        "- metrics_mismatch_count: `{}`\n\n"
        "## Counts by Source Type\n\n```json\n{}\n```\n".format(
            summary["total_json_files"],
            summary["valid_near_hits"],
            summary["unique_canonical_hashes"],
            summary["metrics_mismatch_count"],
            json.dumps(summary["counts_by_source_type"], indent=2, sort_keys=True),
        ),
    )
    write_text(
        os.path.join(out_dir, "metric_correlation_analysis.md"),
        "# Metric Correlation Analysis\n\n"
        + md_table(
            corr["overall"],
            ["left", "right", "pearson", "spearman", "n"],
            lambda r: [
                r["left"],
                r["right"],
                "{:.4f}".format(r["pearson"]) if r["pearson"] is not None else "NA",
                "{:.4f}".format(r["spearman"]) if r["spearman"] is not None else "NA",
                r["n"],
            ],
        )
        + "\n",
    )
    write_text(
        os.path.join(out_dir, "pareto_frontier_analysis.md"),
        "# Pareto Frontier Analysis\n\n"
        "- overall_frontier_count: `{}`\n"
        "- canonical_dedup_frontier_count: `{}`\n\n"
        "## Representatives\n\n{}".format(
            pareto["overall_frontier_count"],
            pareto["canonical_dedup_frontier_count"],
            md_table(
                pareto["overall_representatives"][:30],
                ["score", "l1", "max", "nonzero", "ks", "lambda", "path"],
                lambda r: [
                    r["score"],
                    r["l1_error"],
                    r["max_abs_error"],
                    r["nonzero_defect_count"],
                    r["ks"],
                    r["lambda"],
                    r["path"],
                ],
            ),
        ),
    )
    write_text(
        os.path.join(out_dir, "defect_cluster_analysis.md"),
        "# Defect Cluster Analysis\n\n"
        "- sample_size: `{}`\n"
        "- cluster_count: `{}`\n\n"
        "## Clusters\n\n{}".format(
            clusters["sample_size"],
            clusters["cluster_count"],
            md_table(
                clusters["clusters"],
                ["cluster", "members", "best", "labels", "medoid_path"],
                lambda r: [
                    r["cluster_id"],
                    r["members_count"],
                    (
                        r["best_metrics_record"]["score"],
                        r["best_metrics_record"]["l1_error"],
                        r["best_metrics_record"]["max_abs_error"],
                        r["best_metrics_record"]["nonzero_defect_count"],
                    ),
                    r["branch_labels"],
                    r["medoid"]["path"],
                ],
            ),
        ),
    )
    write_text(
        os.path.join(out_dir, "repair_transition_analysis.md"),
        "# Repair Transition Analysis\n\n"
        "- transition_count: `{}`\n"
        "- same_hash_count: `{}`\n"
        "- improved_score_count: `{}`\n"
        "- improved_l1_count: `{}`\n".format(
            transitions["transition_count"],
            transitions["same_hash_count"],
            transitions["improved_score_count"],
            transitions["improved_l1_count"],
        ),
    )

    lns_design = {
        "classification": "heuristic prototype design",
        "variables": "remove/add membership variables on a small free set per block",
        "objective": "active_l1 with bounded exact post-validation",
        "success_condition": "score=0 plus exact SDS and Goethals-Seidel HH^T=668I verification",
        "not_success": "LNS improvement, cluster, frontier entry, or near-hit alone",
    }
    analyses["lns_model_design"] = lns_design
    write_json(os.path.join(raw_dir, "lns_model_design.json"), lns_design)
    write_text(
        os.path.join(out_dir, "lns_model_design.md"),
        "# Bounded Active-Defect Partial Membership LNS Design\n\n"
        "The prototype opens a small set of remove/add membership decisions around a near-hit. "
        "The model optimizes active defect L1 on selected shifts, then exact metrics are "
        "recomputed from the resulting blocks and bounded by score slack, max_abs, and "
        "zero-shift damage. This is heuristic repair, not a success condition.\n",
    )

    verdict = {
        "route_verdict": "analysis_generated",
        "success_candidate_generated": False,
        "note": "Defect clustering and LNS diagnostics are research logs, not Hadamard constructions.",
    }
    candidates = [
        {
            "candidate_name": "Run partial membership LNS on score176 and low-nonzero branches",
            "classification": "heuristic repair",
            "success_condition": "exact score improvement or score=0 with full verification",
            "failure_condition": "selected=0, timeout, or exact post-validation rejects outputs",
        },
        {
            "candidate_name": "Cluster-specific LNS objective tuning",
            "classification": "diagnostic/heuristic",
            "success_condition": "cluster medoid improves without returning to old basin",
            "failure_condition": "same cluster and dominated output",
        },
    ]
    safety = {
        "hadamard_668_claimed": False,
        "near_hit_called_solution": False,
        "score_zero_alone_success": False,
        "requires_sds_and_gs_hh_t": True,
        "notes": "All reports must distinguish near-hit/frontier/cluster/LNS result from success candidate.",
    }
    write_json(os.path.join(raw_dir, "route_verdict.json"), verdict)
    write_json(os.path.join(raw_dir, "refined_next_candidates.json"), candidates)
    write_json(os.path.join(raw_dir, "proof_safety_check.json"), safety)
    write_text(os.path.join(out_dir, "route_verdict.md"), "# Route Verdict\n\nAnalysis generated; no success candidate generated.\n")
    write_text(os.path.join(out_dir, "refined_next_candidates.md"), "# Refined Next Candidates\n\n" + json.dumps(candidates, indent=2) + "\n")
    write_text(os.path.join(out_dir, "proof_safety_check.md"), "# Proof Safety Check\n\nNo Hadamard 668 construction is claimed. Near-hits, frontiers, clusters, and LNS outputs are research logs, not solutions.\n")

    final_summary = """# Final Summary

1. 今回は Hadamard 668 SDS の defect-vector clustering and bounded active-defect LNS prototype の分析基盤を作成した。
2. near-hit dataset を読み、保存metricsを差分カウントから再計算した。
3. metric correlation、Pareto frontier、canonical basin、defect cluster、repair transition を出力した。
4. partial membership LNS は `sage/21_partial_membership_lns_repair.sage` で実行する。
5. n=668 の Hadamard 行列構成には成功していない。
6. 成功候補は、SDS検証と Goethals-Seidel HH^T=668I 検証を通った場合のみである。
7. near-hit / frontier / defect cluster / LNS result は研究ログであり、解ではない。
"""
    write_text(os.path.join(out_dir, "summary.md"), final_summary)
    write_text(os.path.join(out_dir, "README.md"), final_summary)
    for idx, name in enumerate(
        [
            "summary",
            "near_hit_dataset_summary",
            "pareto_frontier_analysis",
            "defect_cluster_analysis",
            "lns_model_design",
            "route_verdict",
            "proof_safety_check",
        ]
    ):
        src = os.path.join(out_dir, name + ".md")
        if os.path.exists(src):
            write_text(os.path.join(review_dir, "{:02d}_{}.md".format(idx, name)), open(src).read())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--near-hit-glob", default="outputs/candidates/near_hits/**/*.json")
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--max-cluster-records", type=int, default=1200)
    parser.add_argument("--cluster-count", type=int, default=12)
    args = parser.parse_args()

    exploration_id = "{}_hadamard668_defect_cluster_lns".format(now_stamp())
    out_dir = args.out_dir or os.path.join("outputs/explorations", exploration_id)

    paths, records, invalid, mismatches = load_records(args.near_hit_glob)
    analyses = {
        "current_status": {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "near_hit_glob": args.near_hit_glob,
            "out_dir": out_dir,
        },
        "near_hit_dataset_summary": dataset_summary(paths, records, invalid, mismatches),
        "defect_vector_extraction": {
            "records_count": len(records),
            "records": [compact_record(record, include_vector=True) for record in records],
        },
        "metric_correlation_analysis": correlation_analysis(records),
        "pareto_frontier_analysis": pareto_analysis(records),
        "canonical_basin_analysis": canonical_basin_analysis(records),
        "defect_cluster_analysis": defect_cluster_analysis(
            records, max_records=args.max_cluster_records, k=args.cluster_count
        ),
        "repair_transition_analysis": repair_transition_analysis(records),
        "partial_membership_lns_results": {
            "status": "not_run_by_analysis_script",
            "script": "sage/21_partial_membership_lns_repair.sage",
        },
        "failure_modes": {
            "known": [
                "swap repair saturation",
                "selected=0 fixed point",
                "force-move returns to old basin",
                "active-defect ILP timeout",
                "partial LNS may be too weak or too large",
                "metrics objective mismatch",
            ]
        },
    }
    write_reports(out_dir, analyses)
    print("analysis_out_dir={}".format(out_dir))
    print(
        "valid_near_hits={} unique_canonical_hashes={} pareto_count={} cluster_count={}".format(
            analyses["near_hit_dataset_summary"]["valid_near_hits"],
            analyses["near_hit_dataset_summary"]["unique_canonical_hashes"],
            analyses["pareto_frontier_analysis"]["overall_frontier_count"],
            analyses["defect_cluster_analysis"]["cluster_count"],
        )
    )


if __name__ == "__main__":
    main()
