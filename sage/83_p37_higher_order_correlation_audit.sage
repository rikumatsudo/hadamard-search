from sage.all import *

import argparse
import csv
import glob
import hashlib
import importlib.machinery
import importlib.util
import json
import math
import os
import random
import statistics
import time


SCRIPT_NAME = "83_p37_higher_order_correlation_audit"
P_DEFAULT = 37
KS_DEFAULT = (13, 16, 18, 18)
LAMBDA_DEFAULT = 28
EXACT_JSON_DEFAULT = "outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json"
PARENT_FIXTURE_DEFAULT = "configs/fixtures/p37_focused_defect_random_walk_parents.jsonl"
SUCCESS_FIXTURE_DEFAULT = "configs/fixtures/p37_focused_success_preclosure_states.jsonl"
SPLITS = (
    ("split_01_23", (0, 1), (2, 3)),
    ("split_02_13", (0, 2), (1, 3)),
    ("split_03_12", (0, 3), (1, 2)),
)


def load_module(filename, module_name):
    path = os.path.join(os.path.dirname(__file__), filename)
    loader = importlib.machinery.SourceFileLoader(module_name, path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


reg81 = load_module("81_p37_exact_like_feature_registry.sage", "p37_exact_like_feature_registry_81_for_ho")
tri80 = reg81.tri80


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def ensure_dir(path):
    if path:
        os.makedirs(path, exist_ok=True)


def write_json(path, payload):
    reg81.write_json(path, payload)


def write_jsonl(path, rows):
    reg81.write_jsonl(path, rows)


def write_csv(path, rows, fields=None):
    reg81.write_csv(path, rows, fields)


def read_jsonl(path):
    return reg81.read_jsonl(path)


def median(values):
    return reg81.median(values)


def mean(values):
    return reg81.mean(values)


def stddev(values):
    return reg81.stddev(values)


def quantile(values, q):
    return reg81.quantile(values, q)


def parse_ks(text):
    return reg81.parse_ks(text)


def parse_sample_sizes(text):
    return reg81.parse_sample_sizes(text)


def short_hash(text):
    return reg81.short_hash(text)


def blocks_from_payload(payload):
    return reg81.blocks_from_payload(payload)


def candidate_hash(blocks, ks, p):
    return reg81.candidate_hash(blocks, ks, p)


def score_blocks(p, blocks, lam):
    return reg81.score_blocks(p, blocks, lam)


def rho_vector(p, blocks, lam):
    return reg81.rho_vector(p, blocks, lam)


def collect_candidates(args):
    return reg81.collect_candidates(args)


def scalar_distance(xs, ys):
    xs = [float(x) for x in xs]
    ys = [float(y) for y in ys]
    n = min(len(xs), len(ys))
    if n == 0:
        return None
    return math.sqrt(sum((xs[i] - ys[i]) ** 2 for i in range(n)) / float(n))


def l1_distance(xs, ys):
    xs = [float(x) for x in xs]
    ys = [float(y) for y in ys]
    n = min(len(xs), len(ys))
    if n == 0:
        return None
    return sum(abs(xs[i] - ys[i]) for i in range(n)) / float(n)


def max_abs_diff(xs, ys):
    xs = [float(x) for x in xs]
    ys = [float(y) for y in ys]
    n = min(len(xs), len(ys))
    if n == 0:
        return None
    return max(abs(xs[i] - ys[i]) for i in range(n))


def nested_flatten(rows):
    out = []
    for row in rows:
        out.extend(row)
    return out


def triple_vectors_flat(p, blocks):
    return [list(vec) for vec in tri80.triple_correlation_vectors(p, blocks)]


def pair_triple_vectors(block_triples):
    out = {}
    for name, left, right in SPLITS:
        split_vec = []
        for side in (left, right):
            side_vec = []
            for idx in range(len(block_triples[0])):
                side_vec.append(sum(block_triples[j][idx] for j in side))
            split_vec.extend(side_vec)
        out[name] = split_vec
    return out


def choose_sample_indices(total, sample_size, seed_text):
    return tri80.choose_sample_indices(total, sample_size, seed_text)


def sampled_distance(vec, exact_vec, indices):
    return scalar_distance([vec[i] for i in indices], [exact_vec[i] for i in indices])


def rank_values(values, higher_better=False):
    return tri80.rank_values(values, higher_better)


def spearman(xs, ys):
    return tri80.spearman(xs, ys)


def top_k_overlap(ids, sampled, full, k):
    pairs = [(cid, float(s), float(f)) for cid, s, f in zip(ids, sampled, full) if s is not None and f is not None]
    if not pairs:
        return None
    k = min(int(k), len(pairs))
    top_s = set(cid for cid, _s, _f in sorted(pairs, key=lambda row: row[1])[:k])
    top_f = set(cid for cid, _s, _f in sorted(pairs, key=lambda row: row[2])[:k])
    return float(len(top_s & top_f)) / float(k)


def sample_stability(rows, feature_name, sampled_key, reference_key, size_key="sample_size"):
    by_size = {}
    for row in rows:
        by_size.setdefault(str(row.get(size_key)), []).append(row)
    out = []
    order = {"50": 50, "100": 100, "300": 300, "1000": 1000, "full": 10**9}
    for size, group in sorted(by_size.items(), key=lambda item: order.get(item[0], 10**8)):
        sampled = [row.get(sampled_key) for row in group]
        full = [row.get(reference_key) for row in group]
        ids = [row.get("candidate_id") for row in group]
        out.append(
            {
                "feature_name": feature_name,
                "sample_size": size,
                "row_count": int(len(group)),
                "spearman_to_reference": spearman(sampled, full),
                "top_k_overlap_10": top_k_overlap(ids, sampled, full, 10),
                "top_k_overlap_25": top_k_overlap(ids, sampled, full, 25),
                "top_k_overlap_50": top_k_overlap(ids, sampled, full, 50),
                "median_abs_error_vs_reference": median(abs(float(row.get(sampled_key)) - float(row.get(reference_key))) for row in group if row.get(sampled_key) is not None and row.get(reference_key) is not None),
            }
        )
    return out


def ap_features_for_blocks(p, blocks, exact_ap):
    aps = [tri80.ap_count(p, block) for block in blocks]
    pair = {}
    gap = {}
    balance = {}
    for name, left, right in SPLITS:
        lval = sum(aps[i] for i in left)
        rval = sum(aps[i] for i in right)
        pair[name] = {"left": int(lval), "right": int(rval)}
        gap[name] = int(lval - rval)
        balance[name] = abs(float(lval - rval)) / float(max(1, lval + rval))
    best_split = min(balance, key=lambda k: balance[k]) if balance else None
    return {
        "AP_by_block": aps,
        "AP_total": int(sum(aps)),
        "AP_mean": mean(aps),
        "AP_std": stddev(aps),
        "AP_min": min(aps),
        "AP_max": max(aps),
        "AP_pair_by_split": pair,
        "AP_pair_gap_by_split": gap,
        "AP_pair_balance_by_split": balance,
        "best_AP_pair_split": best_split,
        "AP_distance_to_exact": scalar_distance(aps, exact_ap),
    }


def energy_features_for_blocks(p, blocks, exact_energy):
    counts = tri80.per_block_diff_counts(p, blocks)
    energies = [tri80.additive_energy_from_counts(c) for c in counts]
    pair = {}
    gap = {}
    balance = {}
    for name, left, right in SPLITS:
        lval = sum(energies[i] for i in left)
        rval = sum(energies[i] for i in right)
        pair[name] = {"left": int(lval), "right": int(rval)}
        gap[name] = int(lval - rval)
        balance[name] = abs(float(lval - rval)) / float(max(1, lval + rval))
    best_split = min(balance, key=lambda k: balance[k]) if balance else None
    return {
        "additive_energy_by_block": energies,
        "additive_energy_total": int(sum(energies)),
        "additive_energy_mean": mean(energies),
        "additive_energy_std": stddev(energies),
        "additive_energy_min": min(energies),
        "additive_energy_max": max(energies),
        "energy_pair_by_split": pair,
        "energy_pair_gap_by_split": gap,
        "energy_pair_balance_by_split": balance,
        "best_energy_pair_split": best_split,
        "energy_distance_to_exact": scalar_distance(energies, exact_energy),
    }


def fourpoint_value(p, block_set, a, b, c):
    count = 0
    for x in block_set:
        if (x + a) % p in block_set and (x + b) % p in block_set and (x + c) % p in block_set:
            count += 1
    return count


def fourpoint_sample_vector(p, blocks, indices):
    p = int(p)
    sets = [set(int(x) % p for x in block) for block in blocks]
    out = []
    for block in sets:
        vec = []
        for idx in indices:
            a = idx // (p * p)
            rem = idx % (p * p)
            b = rem // p
            c = rem % p
            vec.append(fourpoint_value(p, block, a, b, c))
        out.append(vec)
    return out


def nested_distance(xs, ys):
    vals = []
    for x, y in zip(xs, ys):
        d = scalar_distance(x, y)
        if d is not None:
            vals.append(d)
    return math.sqrt(sum(v * v for v in vals) / float(len(vals))) if vals else None


def candidate_basic(candidate, p, ks, lam):
    blocks = blocks_from_payload(candidate)
    h = candidate.get("candidate_hash") or candidate.get("canonical_hash") or candidate_hash(blocks, ks, p)
    score = score_blocks(p, blocks, lam)
    rho = rho_vector(p, blocks, lam)
    return {
        "candidate_id": candidate.get("candidate_id") or short_hash(h),
        "candidate_hash": h,
        "candidate_hash12": short_hash(h),
        "primary_label": candidate.get("primary_label") or candidate.get("candidate_group") or "ambiguous",
        "labels": candidate.get("labels") or [candidate.get("primary_label") or candidate.get("candidate_group") or "ambiguous"],
        "source_file": candidate.get("source_file"),
        "source_run": candidate.get("source_run") or candidate.get("fixture_source") or candidate.get("source_name"),
        "p": int(p),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "S": int(score),
        "computed_score": int(score),
        "rho_support_size": int(sum(1 for d in range(1, int(p)) if rho[d] != 0)),
        "canonical_hash": h,
    }


def add_exact_distribution_fields(rows):
    exact_rows = [row for row in rows if row.get("primary_label") == "exact_derived"]
    features = [
        "AP_distance_to_exact",
        "energy_distance_to_exact",
        "triple_distance_to_exact",
        "triple_l1_distance_to_exact",
        "triple_l2_distance_to_exact",
        "triple_max_abs_diff_to_exact",
        "fourpoint_sampled_distance_100",
        "fourpoint_sampled_distance_300",
        "fourpoint_sampled_distance_1000",
    ]
    for feature in features:
        values = [row.get(feature) for row in exact_rows if row.get(feature) is not None]
        if not values:
            continue
        mu = mean(values)
        med = median(values)
        sd = stddev(values) or 1.0
        for row in rows:
            value = row.get(feature)
            if value is None:
                continue
            row["{}_exact_derived_mean".format(feature)] = mu
            row["{}_zscore_against_exact_derived".format(feature)] = (float(value) - float(med)) / float(sd)
    for row in rows:
        row["AP_distance_to_exact_derived_mean"] = row.get("AP_distance_to_exact_exact_derived_mean")
        row["AP_zscore_against_exact_derived"] = row.get("AP_distance_to_exact_zscore_against_exact_derived")
        row["energy_distance_to_exact_derived_mean"] = row.get("energy_distance_to_exact_exact_derived_mean")
        row["energy_zscore_against_exact_derived"] = row.get("energy_distance_to_exact_zscore_against_exact_derived")
        row["triple_distance_to_exact_derived_mean"] = row.get("triple_distance_to_exact_exact_derived_mean")
        row["triple_zscore_against_exact_derived"] = row.get("triple_distance_to_exact_zscore_against_exact_derived")
        row["fourpoint_sampled_distance_to_exact_derived_mean"] = row.get("fourpoint_sampled_distance_1000_exact_derived_mean")
        row["fourpoint_sampled_zscore_against_exact_derived"] = row.get("fourpoint_sampled_distance_1000_zscore_against_exact_derived")


def combined_scores(rows):
    components = {
        "AP": "AP_zscore_against_exact_derived",
        "energy": "energy_zscore_against_exact_derived",
        "triple": "triple_zscore_against_exact_derived",
        "fourpoint": "fourpoint_sampled_zscore_against_exact_derived",
    }
    for row in rows:
        vals = {k: row.get(v) for k, v in components.items()}
        valid = [float(v) for v in vals.values() if v is not None]
        row["higher_order_score"] = sum(valid) if valid else None
        no_triple = [float(v) for k, v in vals.items() if k != "triple" and v is not None]
        row["higher_order_score_without_triple"] = sum(no_triple) if no_triple else None
        cheap = [float(vals[k]) for k in ("AP", "energy") if vals.get(k) is not None]
        row["higher_order_score_cheap_only"] = sum(cheap) if cheap else None
    return rows


def compute_rows(candidates, args):
    p = int(args.p)
    ks = tuple(int(x) for x in args.ks)
    lam = int(args.lam)
    triple_sample_sizes = parse_sample_sizes(args.triple_sample_sizes)
    fourpoint_sample_sizes = [int(x) for x in str(args.fourpoint_sample_sizes).split(",") if str(x).strip()]
    exact_blocks = blocks_from_payload(tri80.load_exact_candidate(args.exact_json, p, ks, lam))
    exact_ap = [tri80.ap_count(p, block) for block in exact_blocks]
    exact_energy = [tri80.additive_energy_from_counts(c) for c in tri80.per_block_diff_counts(p, exact_blocks)]
    exact_triples = triple_vectors_flat(p, exact_blocks)
    exact_triple_flat = nested_flatten(exact_triples)
    exact_pair_triples = pair_triple_vectors(exact_triples)
    exact_fourpoint_samples = {}
    for sample_size in fourpoint_sample_sizes:
        idxs = choose_sample_indices(p**3, sample_size, "exact:fourpoint:{}".format(sample_size))
        exact_fourpoint_samples[int(sample_size)] = (idxs, fourpoint_sample_vector(p, exact_blocks, idxs))
    ap_rows = []
    energy_rows = []
    triple_rows = []
    fourpoint_rows = []
    combined_rows = []
    triple_sweep = []
    fourpoint_sweep = []
    for candidate in candidates:
        blocks = blocks_from_payload(candidate)
        basic = candidate_basic(candidate, p, ks, lam)
        h = basic["candidate_hash"]
        ap = ap_features_for_blocks(p, blocks, exact_ap)
        energy = energy_features_for_blocks(p, blocks, exact_energy)
        triples = triple_vectors_flat(p, blocks)
        triple_flat = nested_flatten(triples)
        pair_triples = pair_triple_vectors(triples)
        pair_triple_dist_by_split = {name: scalar_distance(pair_triples[name], exact_pair_triples[name]) for name in pair_triples}
        triple_l2 = scalar_distance(triple_flat, exact_triple_flat)
        triple_l1 = l1_distance(triple_flat, exact_triple_flat)
        triple_max = max_abs_diff(triple_flat, exact_triple_flat)
        row = dict(basic)
        row.update(ap)
        row.update(energy)
        row.update(
            {
                "triple_distance_to_exact": triple_l2,
                "triple_l1_distance_to_exact": triple_l1,
                "triple_l2_distance_to_exact": triple_l2,
                "triple_max_abs_diff_to_exact": triple_max,
                "pair_triple_distance_by_split": pair_triple_dist_by_split,
                "best_pair_triple_split": min(pair_triple_dist_by_split, key=lambda k: pair_triple_dist_by_split[k]) if pair_triple_dist_by_split else None,
            }
        )
        for sample_size in triple_sample_sizes:
            total = len(triple_flat)
            idxs = choose_sample_indices(total, sample_size, "{}:triple:{}".format(h, sample_size))
            label = "full" if sample_size == "full" or len(idxs) == total else int(sample_size)
            sampled_dist = sampled_distance(triple_flat, exact_triple_flat, idxs)
            triple_sweep.append(
                {
                    "candidate_id": basic["candidate_id"],
                    "candidate_hash": h,
                    "primary_label": basic["primary_label"],
                    "sample_size": label,
                    "sampled_triple_distance": sampled_dist,
                    "full_triple_distance": triple_l2,
                    "abs_error_vs_full": abs(float(sampled_dist) - float(triple_l2)) if sampled_dist is not None and triple_l2 is not None else None,
                }
            )
        four_dists = {}
        for sample_size in fourpoint_sample_sizes:
            idxs, exact_vec = exact_fourpoint_samples[int(sample_size)]
            cand_vec = fourpoint_sample_vector(p, blocks, idxs)
            dist = nested_distance(cand_vec, exact_vec)
            four_dists[int(sample_size)] = dist
            row["fourpoint_sampled_distance_{}".format(int(sample_size))] = dist
            row["fourpoint_sample_size_{}".format(int(sample_size))] = int(sample_size)
            row["fourpoint_sampling_seed_{}".format(int(sample_size))] = int(hashlib.sha256("{}:fourpoint:{}".format(h, sample_size).encode("utf-8")).hexdigest()[:8], 16)
        reference_size = max(four_dists)
        for sample_size, dist in four_dists.items():
            fourpoint_sweep.append(
                {
                    "candidate_id": basic["candidate_id"],
                    "candidate_hash": h,
                    "primary_label": basic["primary_label"],
                    "sample_size": int(sample_size),
                    "sampled_fourpoint_distance": dist,
                    "reference_fourpoint_distance": four_dists.get(reference_size),
                    "reference_sample_size": int(reference_size),
                    "abs_error_vs_reference": abs(float(dist) - float(four_dists.get(reference_size))) if dist is not None and four_dists.get(reference_size) is not None else None,
                }
            )
        row["fourpoint_sampled_distance_to_exact"] = four_dists.get(reference_size)
        row["fourpoint_sample_size"] = int(reference_size)
        row["fourpoint_sampling_seed"] = int(hashlib.sha256("{}:fourpoint".format(h).encode("utf-8")).hexdigest()[:8], 16)
        ap_rows.append({k: row.get(k) for k in list(basic.keys()) + ["AP_by_block", "AP_total", "AP_mean", "AP_std", "AP_min", "AP_max", "AP_pair_by_split", "AP_pair_gap_by_split", "AP_pair_balance_by_split", "best_AP_pair_split", "AP_distance_to_exact"]})
        energy_rows.append({k: row.get(k) for k in list(basic.keys()) + ["additive_energy_by_block", "additive_energy_total", "additive_energy_mean", "additive_energy_std", "additive_energy_min", "additive_energy_max", "energy_pair_by_split", "energy_pair_gap_by_split", "energy_pair_balance_by_split", "best_energy_pair_split", "energy_distance_to_exact"]})
        triple_rows.append({k: row.get(k) for k in list(basic.keys()) + ["triple_distance_to_exact", "triple_l1_distance_to_exact", "triple_l2_distance_to_exact", "triple_max_abs_diff_to_exact", "pair_triple_distance_by_split", "best_pair_triple_split"]})
        fourpoint_rows.append({k: row.get(k) for k in list(basic.keys()) + [key for key in row if key.startswith("fourpoint_")]})
        combined_rows.append(row)
    add_exact_distribution_fields(combined_rows)
    combined_scores(combined_rows)
    by_hash = {row["candidate_hash"]: row for row in combined_rows}
    for rows in (ap_rows, energy_rows, triple_rows, fourpoint_rows):
        for row in rows:
            extra = by_hash.get(row["candidate_hash"], {})
            for key in ("AP_distance_to_exact_derived_mean", "AP_zscore_against_exact_derived", "energy_distance_to_exact_derived_mean", "energy_zscore_against_exact_derived", "triple_distance_to_exact_derived_mean", "triple_zscore_against_exact_derived", "fourpoint_sampled_distance_to_exact_derived_mean", "fourpoint_sampled_zscore_against_exact_derived"):
                if key in extra:
                    row[key] = extra[key]
    return ap_rows, energy_rows, triple_rows, fourpoint_rows, combined_rows, triple_sweep, fourpoint_sweep


HO_FEATURES = [
    "AP_distance_to_exact",
    "energy_distance_to_exact",
    "triple_distance_to_exact",
    "triple_l1_distance_to_exact",
    "triple_max_abs_diff_to_exact",
    "fourpoint_sampled_distance_to_exact",
    "higher_order_score",
    "higher_order_score_without_triple",
    "higher_order_score_cheap_only",
]


def group_rows(rows):
    out = {}
    for row in rows:
        out.setdefault(row.get("primary_label", "missing"), []).append(row)
    return out


def auc_lower(good_values, bad_values):
    good_values = [float(x) for x in good_values if x is not None]
    bad_values = [float(x) for x in bad_values if x is not None]
    if not good_values or not bad_values:
        return None
    wins = 0.0
    total = 0.0
    for g in good_values:
        for b in bad_values:
            total += 1.0
            wins += 1.0 if g < b else 0.5 if g == b else 0.0
    return wins / total if total else None


def threshold_accuracy(good_values, bad_values):
    good_values = [float(x) for x in good_values if x is not None]
    bad_values = [float(x) for x in bad_values if x is not None]
    if not good_values or not bad_values:
        return None
    threshold = (median(good_values) + median(bad_values)) / 2.0
    correct = sum(1 for x in good_values if x <= threshold) + sum(1 for x in bad_values if x > threshold)
    return float(correct) / float(len(good_values) + len(bad_values))


def separation_summary(rows):
    comparisons = [
        ("exact_derived_vs_search_derived_false_like", ("exact_derived",), ("score4_false_like_repairable_parent", "score4_false_like_failed_parent", "search_derived_false_like", "other_low_score")),
        ("exact_derived_vs_score4_false_like_parent", ("exact_derived",), ("score4_false_like_repairable_parent", "score4_false_like_failed_parent")),
        ("score4_repairable_parent_vs_score4_failed_parent", ("score4_false_like_repairable_parent",), ("score4_false_like_failed_parent",)),
        ("focused_success_child_vs_score4_false_like_parent", ("focused_success_child",), ("score4_false_like_repairable_parent", "score4_false_like_failed_parent")),
        ("late_preclosure_vs_non_preclosure", ("late_preclosure",), ("score4_false_like_repairable_parent", "score4_false_like_failed_parent", "random_control")),
        ("exact_derived_vs_random_control", ("exact_derived",), ("random_control",)),
    ]
    by_group = group_rows(rows)
    out = []
    for name, good_groups, bad_groups in comparisons:
        good = [row for group in good_groups for row in by_group.get(group, [])]
        bad = [row for group in bad_groups for row in by_group.get(group, [])]
        for feature in HO_FEATURES:
            gv = [row.get(feature) for row in good if row.get(feature) is not None]
            bv = [row.get(feature) for row in bad if row.get(feature) is not None]
            if not gv or not bv:
                continue
            mg = median(gv)
            mb = median(bv)
            pooled = math.sqrt((stddev(gv) ** 2 + stddev(bv) ** 2) / 2.0) or 1.0
            out.append(
                {
                    "comparison": name,
                    "feature_name": feature,
                    "group_a": ",".join(good_groups),
                    "group_b": ",".join(bad_groups),
                    "median_a": mg,
                    "median_b": mb,
                    "effect_size": (float(mb) - float(mg)) / float(pooled),
                    "rank_separation_score": auc_lower(gv, bv),
                    "simple_threshold_accuracy": threshold_accuracy(gv, bv),
                    "direction": "lower_is_more_exact_like",
                }
            )
    return out


def template(rows, label, selected_labels):
    selected = [row for row in rows if row.get("primary_label") in selected_labels]
    feature_values = {}
    for feature in HO_FEATURES:
        values = [row.get(feature) for row in selected if row.get(feature) is not None]
        if values:
            feature_values[feature] = values
    return {
        "template_version": "p37_higher_order_{}_v1".format(label),
        "p": P_DEFAULT,
        "ks": list(KS_DEFAULT),
        "lambda": LAMBDA_DEFAULT,
        "label": label,
        "candidate_hashes": [row.get("candidate_hash") for row in selected],
        "feature_list": sorted(feature_values),
        "feature_medians": {k: median(v) for k, v in feature_values.items()},
        "feature_means": {k: mean(v) for k, v in feature_values.items()},
        "feature_stds": {k: stddev(v) for k, v in feature_values.items()},
        "recommended_features": ["triple_distance_to_exact", "AP_distance_to_exact", "energy_distance_to_exact", "fourpoint_sampled_distance_to_exact"],
        "notes": ["Diagnostic evidence only; do not transfer p37 behavior to p167 without p167 audit."],
    }


def hypothesis_evaluation(rows, sep_rows, triple_stability, fourpoint_stability):
    def auc(comparison, feature):
        for row in sep_rows:
            if row.get("comparison") == comparison and row.get("feature_name") == feature:
                return row.get("rank_separation_score")
        return None

    def supported(value, threshold=0.75):
        if value is None:
            return "inconclusive"
        return "supported" if float(value) >= threshold else "not_supported"

    ap_auc = auc("exact_derived_vs_search_derived_false_like", "AP_distance_to_exact")
    energy_auc = auc("exact_derived_vs_search_derived_false_like", "energy_distance_to_exact")
    triple_auc = auc("exact_derived_vs_search_derived_false_like", "triple_distance_to_exact")
    four_auc = auc("exact_derived_vs_search_derived_false_like", "fourpoint_sampled_distance_to_exact")
    combo_auc = auc("exact_derived_vs_search_derived_false_like", "higher_order_score")
    repair_auc = auc("score4_repairable_parent_vs_score4_failed_parent", "higher_order_score")
    late_auc = auc("late_preclosure_vs_non_preclosure", "higher_order_score")
    best_triple_stability = max([float(row.get("spearman_to_reference")) for row in triple_stability if row.get("spearman_to_reference") is not None and str(row.get("sample_size")) in ("300", "1000")] or [0.0])
    return {
        "H_HO37_1": {"statement": "AP count is a useful cheap exact-vs-false proxy.", "status": supported(ap_auc, 0.65), "ap_auc": ap_auc},
        "H_HO37_2": {"statement": "additive energy / parallelogram count separates exact-derived and false-like to some degree.", "status": supported(energy_auc, 0.65), "energy_auc": energy_auc},
        "H_HO37_3": {"statement": "sampled/full triple correlation strongly separates exact-derived and false-like.", "status": supported(triple_auc), "triple_auc": triple_auc, "best_triple_sample_stability": best_triple_stability},
        "H_HO37_4": {"statement": "4-point sampled correlation adds information beyond AP / energy / triple.", "status": "supported" if combo_auc is not None and four_auc is not None and combo_auc >= max(ap_auc or 0.0, energy_auc or 0.0, triple_auc or 0.0) - 0.02 and four_auc >= 0.65 else "not_supported" if four_auc is not None else "inconclusive", "fourpoint_auc": four_auc, "combined_auc": combo_auc},
        "H_HO37_5": {"statement": "repairable parent and failed parent are weakly separated by higher-order features alone.", "status": "supported" if repair_auc is not None and repair_auc < 0.75 else "not_supported" if repair_auc is not None else "inconclusive", "repairable_vs_failed_auc": repair_auc},
        "H_HO37_6": {"statement": "late-preclosure is more distinctive in move-space than higher-order features.", "status": "supported" if late_auc is not None and late_auc < 0.75 else "not_supported" if late_auc is not None else "inconclusive", "late_preclosure_higher_order_auc": late_auc},
        "H_HO37_7": {"statement": "AP / energy alone are insufficient; sampled triple is needed.", "status": "supported" if triple_auc is not None and triple_auc > max(ap_auc or 0.0, energy_auc or 0.0) + 0.05 else "not_supported" if triple_auc is not None else "inconclusive", "ap_auc": ap_auc, "energy_auc": energy_auc, "triple_auc": triple_auc},
        "H_HO37_8": {"statement": "recommended p167 higher-order features can be selected.", "status": "supported" if triple_auc is not None and max(triple_auc, ap_auc or 0.0, energy_auc or 0.0, four_auc or 0.0) >= 0.65 else "not_supported"},
    }


def build_summary(config, rows, sep_rows, triple_stability, fourpoint_stability, hypotheses):
    counts = {label: len(label_rows) for label, label_rows in sorted(group_rows(rows).items())}
    top = sorted([row for row in sep_rows if row.get("comparison") == "exact_derived_vs_search_derived_false_like"], key=lambda r: r.get("rank_separation_score") if r.get("rank_separation_score") is not None else -1, reverse=True)[:8]
    lines = []
    lines.append("# p37 higher-order correlation audit")
    lines.append("")
    lines.append("This is a theory-diagnostic run, not a Hadamard 668 construction run and not a new score0 search.")
    lines.append("")
    lines.append("## Core formulas")
    lines.append("")
    lines.append("n_X(d) = #{(x,y) in X^2 : x - y = d}.")
    lines.append("")
    lines.append("rho(d) = N(d) - lambda for d != 0.")
    lines.append("")
    lines.append("S = sum_{d != 0} rho(d)^2.")
    lines.append("")
    lines.append("T_X(a,b) = sum_x f_X(x) f_X(x+a) f_X(x+b).")
    lines.append("")
    lines.append("AP(X) = #{(x,y,z) in X^3 : x + y = 2z}.")
    lines.append("")
    lines.append("Q_X(a,b,c) = sum_x f_X(x) f_X(x+a) f_X(x+b) f_X(x+c).")
    lines.append("")
    lines.append("E(X) = #{(a,b,c,d) in X^4 : a - b = c - d} = sum_t n_X(t)^2.")
    lines.append("")
    lines.append("AP is a cheap 3-point slice; additive energy is a cheap 4-point additive proxy.")
    lines.append("")
    lines.append("## Inputs")
    lines.append("")
    lines.append("- candidate rows: `{}`".format(len(rows)))
    lines.append("- label counts: `{}`".format(counts))
    lines.append("- triple sample sizes: `{}`".format(config.get("triple_sample_sizes")))
    lines.append("- fourpoint sample sizes: `{}`".format(config.get("fourpoint_sample_sizes")))
    lines.append("")
    lines.append("## Strongest exact-derived vs false-like separations")
    lines.append("")
    lines.append("| feature | AUC/rank separation | threshold accuracy |")
    lines.append("|---|---:|---:|")
    for row in top:
        lines.append("| {} | {} | {} |".format(row.get("feature_name"), fmt(row.get("rank_separation_score")), fmt(row.get("simple_threshold_accuracy"))))
    lines.append("")
    lines.append("## Hypotheses")
    lines.append("")
    for key in sorted(hypotheses):
        lines.append("- `{}`: `{}`. {}".format(key, hypotheses[key].get("status"), hypotheses[key].get("statement")))
    lines.append("")
    lines.append("## Required answers")
    lines.append("")
    lines.append("1. AP count exact-vs-false: `{}`.".format(hypotheses["H_HO37_1"]["status"]))
    lines.append("2. additive energy / parallelogram count: `{}`.".format(hypotheses["H_HO37_2"]["status"]))
    lines.append("3. sampled/full triple correlation: `{}`.".format(hypotheses["H_HO37_3"]["status"]))
    lines.append("4. sampled 4-point additional information: `{}`.".format(hypotheses["H_HO37_4"]["status"]))
    lines.append("5. repairable vs failed by higher-order alone: `{}`.".format(hypotheses["H_HO37_5"]["status"]))
    lines.append("6. late-preclosure higher-order distinctiveness: `{}`; move-space should remain primary if weak.".format(hypotheses["H_HO37_6"]["status"]))
    lines.append("7. AP / energy only vs triple: `{}`.".format(hypotheses["H_HO37_7"]["status"]))
    lines.append("8. p167 carry-forward: sampled triple, AP, energy, and sampled 4-point only if cost allows.")
    lines.append("9. generator/reranker use: AP/energy as cheap prefilter, sampled triple as stronger rerank, sampled 4-point as diagnostic/top-k rerank.")
    lines.append("10. pair-level profile + bispectrum + move-space combined rerank remains the next practical integration target.")
    lines.append("")
    lines.append("Important caveat: higher-order separation is diagnostic evidence, not a theorem, and p37 behavior should not be transferred to p167 without a p167 audit.")
    return "\n".join(lines) + "\n"


def fmt(value):
    if value is None:
        return ""
    try:
        return "{:.6g}".format(float(value))
    except Exception:
        return str(value)


def config_from_args(args):
    return {
        "script": SCRIPT_NAME,
        "p": int(args.p),
        "ks": [int(x) for x in args.ks],
        "lambda": int(args.lam),
        "exact_json": args.exact_json,
        "parent_fixture": args.parent_fixture,
        "success_fixture": args.success_fixture,
        "triple_sample_sizes": args.triple_sample_sizes,
        "fourpoint_sample_sizes": args.fourpoint_sample_sizes,
        "metric_mode": args.metric_mode,
        "max_candidates": int(args.max_candidates),
        "max_tasks": int(args.max_tasks),
        "shard_index": int(args.shard_index),
        "shard_count": int(args.shard_count),
        "seed": int(args.seed),
        "exact_derived_count": int(args.exact_derived_count),
        "random_control_count": int(args.random_control_count),
    }


def write_outputs(out_dir, config, candidates, ap_rows, energy_rows, triple_rows, fourpoint_rows, combined_rows, triple_sweep, fourpoint_sweep):
    ensure_dir(out_dir)
    sep_rows = separation_summary(combined_rows)
    triple_stability = sample_stability(triple_sweep, "triple_distance", "sampled_triple_distance", "full_triple_distance")
    fourpoint_stability = sample_stability(fourpoint_sweep, "fourpoint_distance", "sampled_fourpoint_distance", "reference_fourpoint_distance")
    hypotheses = hypothesis_evaluation(combined_rows, sep_rows, triple_stability, fourpoint_stability)
    write_json(os.path.join(out_dir, "run_config.json"), config)
    write_jsonl(os.path.join(out_dir, "input_p37_higher_order_candidates.jsonl"), candidates)
    write_jsonl(os.path.join(out_dir, "p37_ap_features.jsonl"), ap_rows)
    write_jsonl(os.path.join(out_dir, "p37_additive_energy_features.jsonl"), energy_rows)
    write_jsonl(os.path.join(out_dir, "p37_triple_correlation_features.jsonl"), triple_rows)
    write_jsonl(os.path.join(out_dir, "p37_fourpoint_sampled_features.jsonl"), fourpoint_rows)
    write_jsonl(os.path.join(out_dir, "p37_higher_order_combined_features.jsonl"), combined_rows)
    write_csv(os.path.join(out_dir, "higher_order_feature_separation_summary.csv"), sep_rows)
    write_json(os.path.join(out_dir, "higher_order_feature_separation_summary.json"), {"rows": sep_rows})
    write_csv(os.path.join(out_dir, "sampled_triple_stability.csv"), triple_stability)
    write_json(os.path.join(out_dir, "sampled_triple_stability.json"), {"rows": triple_stability, "source_rows": triple_sweep})
    write_csv(os.path.join(out_dir, "sampled_fourpoint_stability.csv"), fourpoint_stability)
    write_json(os.path.join(out_dir, "sampled_fourpoint_stability.json"), {"rows": fourpoint_stability, "source_rows": fourpoint_sweep})
    write_json(os.path.join(out_dir, "p37_higher_order_exact_template.json"), template(combined_rows, "exact", ("exact_derived",)))
    write_json(os.path.join(out_dir, "p37_higher_order_false_template.json"), template(combined_rows, "false", ("score4_false_like_repairable_parent", "score4_false_like_failed_parent", "search_derived_false_like", "other_low_score")))
    write_json(os.path.join(out_dir, "hypothesis_evaluation.json"), hypotheses)
    with open(os.path.join(out_dir, "p37_higher_order_correlation_audit_summary.md"), "w") as f:
        f.write(build_summary(config, combined_rows, sep_rows, triple_stability, fourpoint_stability, hypotheses))
    with open(os.path.join(out_dir, "run_log.md"), "w") as f:
        f.write("# p37 higher-order correlation audit log\n\n")
        f.write("- generated_at: `{}`\n".format(time.strftime("%Y-%m-%dT%H:%M:%S%z")))
        f.write("- candidate_rows: `{}`\n".format(len(candidates)))
        f.write("- combined_rows: `{}`\n".format(len(combined_rows)))
        f.write("- output_dir: `{}`\n".format(out_dir))


def dedupe_rows(rows, keys):
    seen = set()
    out = []
    for row in rows:
        key = tuple(str(row.get(k)) for k in keys)
        if key in seen:
            continue
        seen.add(key)
        out.append(row)
    return out


def aggregate_mode(args):
    roots = [root.strip() for root in str(args.aggregate_roots).split(",") if root.strip()]
    if not roots:
        raise RuntimeError("--aggregate-roots is required in aggregate mode")
    candidates = []
    ap_rows = []
    energy_rows = []
    triple_rows = []
    fourpoint_rows = []
    combined_rows = []
    triple_sweep = []
    fourpoint_sweep = []
    for root in roots:
        for path in glob.glob(os.path.join(root, "**", "input_p37_higher_order_candidates.jsonl"), recursive=True):
            candidates.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_ap_features.jsonl"), recursive=True):
            ap_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_additive_energy_features.jsonl"), recursive=True):
            energy_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_triple_correlation_features.jsonl"), recursive=True):
            triple_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_fourpoint_sampled_features.jsonl"), recursive=True):
            fourpoint_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_higher_order_combined_features.jsonl"), recursive=True):
            combined_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "sampled_triple_stability_source.jsonl"), recursive=True):
            triple_sweep.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "sampled_fourpoint_stability_source.jsonl"), recursive=True):
            fourpoint_sweep.extend(read_jsonl(path))
    candidates = dedupe_rows(candidates, ("candidate_hash",))
    ap_rows = dedupe_rows(ap_rows, ("candidate_hash",))
    energy_rows = dedupe_rows(energy_rows, ("candidate_hash",))
    triple_rows = dedupe_rows(triple_rows, ("candidate_hash",))
    fourpoint_rows = dedupe_rows(fourpoint_rows, ("candidate_hash",))
    combined_rows = dedupe_rows(combined_rows, ("candidate_hash",))
    config = config_from_args(args)
    config["aggregate_mode"] = True
    config["aggregate_roots"] = roots
    write_outputs(args.out_dir, config, candidates, ap_rows, energy_rows, triple_rows, fourpoint_rows, combined_rows, triple_sweep, fourpoint_sweep)


def parse_args():
    parser = argparse.ArgumentParser(description="p37 higher-order correlation audit")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--ks", type=parse_ks, default=KS_DEFAULT)
    parser.add_argument("--lam", "--lambda", dest="lam", type=int, default=LAMBDA_DEFAULT)
    parser.add_argument("--exact-json", default=EXACT_JSON_DEFAULT)
    parser.add_argument("--parent-fixture", default=PARENT_FIXTURE_DEFAULT)
    parser.add_argument("--success-fixture", default=SUCCESS_FIXTURE_DEFAULT)
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--metric-mode", choices=("smoke", "full"), default="full")
    parser.add_argument("--triple-sample-sizes", default="50,100,300,1000,full")
    parser.add_argument("--fourpoint-sample-sizes", default="100,300,1000")
    parser.add_argument("--max-candidates", type=int, default=0)
    parser.add_argument("--max-tasks", type=int, default=0)
    parser.add_argument("--shard-index", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--seed", type=int, default=37)
    parser.add_argument("--exact-derived-count", type=int, default=100)
    parser.add_argument("--random-control-count", type=int, default=100)
    parser.add_argument("--aggregate-roots", default="")
    parser.add_argument("--aggregate", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    if args.out_dir is None:
        args.out_dir = os.path.join("outputs", "explorations", "{}_p37_higher_order_correlation_audit".format(now_stamp()))
    if args.metric_mode == "smoke":
        if args.max_candidates <= 0:
            args.max_candidates = 2
        if args.max_tasks <= 0:
            args.max_tasks = 2
        args.triple_sample_sizes = "10"
        args.fourpoint_sample_sizes = "10"
        args.exact_derived_count = min(int(args.exact_derived_count), 2)
        args.random_control_count = min(int(args.random_control_count), 1)
    if args.aggregate:
        aggregate_mode(args)
        print("SUMMARY:", os.path.join(args.out_dir, "p37_higher_order_correlation_audit_summary.md"))
        return
    candidates = collect_candidates(args)
    if not candidates:
        raise RuntimeError("no candidates selected for this shard")
    rows = compute_rows(candidates, args)
    ap_rows, energy_rows, triple_rows, fourpoint_rows, combined_rows, triple_sweep, fourpoint_sweep = rows
    write_jsonl(os.path.join(args.out_dir, "sampled_triple_stability_source.jsonl"), triple_sweep)
    write_jsonl(os.path.join(args.out_dir, "sampled_fourpoint_stability_source.jsonl"), fourpoint_sweep)
    write_outputs(args.out_dir, config_from_args(args), candidates, ap_rows, energy_rows, triple_rows, fourpoint_rows, combined_rows, triple_sweep, fourpoint_sweep)
    print("candidates:", len(candidates))
    print("SUMMARY:", os.path.join(args.out_dir, "p37_higher_order_correlation_audit_summary.md"))


if __name__ == "__main__":
    main()
