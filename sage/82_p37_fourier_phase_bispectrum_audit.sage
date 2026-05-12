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


SCRIPT_NAME = "82_p37_fourier_phase_bispectrum_audit"
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


reg81 = load_module("81_p37_exact_like_feature_registry.sage", "p37_exact_like_feature_registry_81_for_phase")
tri80 = reg81.tri80


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def ensure_dir(path):
    if path:
        os.makedirs(path, exist_ok=True)


def json_safe(value):
    return reg81.json_safe(value)


def public_row(row):
    return {key: json_safe(value) for key, value in row.items() if not str(key).startswith("_")}


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


def normalize_complex(z, eps=1.0e-12):
    mag = abs(z)
    if mag <= eps:
        return 0.0 + 0.0j
    return z / mag


def flatten_nested(rows):
    out = []
    for row in rows:
        out.extend(row)
    return out


def rms_complex(xs, ys):
    n = min(len(xs), len(ys))
    if n == 0:
        return None
    total = 0.0
    for x, y in zip(xs[:n], ys[:n]):
        total += abs(x - y) ** 2
    return math.sqrt(total / float(n))


def nested_rms(xs, ys):
    vals = []
    for x, y in zip(xs, ys):
        d = rms_complex(x, y)
        if d is not None:
            vals.append(d)
    return math.sqrt(sum(v * v for v in vals) / float(len(vals))) if vals else None


def weighted_rms_phase(xs, ys, weights):
    n = min(len(xs), len(ys), len(weights))
    if n == 0:
        return None
    total_w = 0.0
    total = 0.0
    for x, y, w in zip(xs[:n], ys[:n], weights[:n]):
        w = max(0.0, float(w))
        total_w += w
        total += w * (abs(x - y) ** 2)
    if total_w <= 0.0:
        return rms_complex(xs[:n], ys[:n])
    return math.sqrt(total / total_w)


def nested_weighted_rms_phase(xs, ys, weight_rows):
    vals = []
    for x, y, w in zip(xs, ys, weight_rows):
        d = weighted_rms_phase(x, y, w)
        if d is not None:
            vals.append(d)
    return math.sqrt(sum(v * v for v in vals) / float(len(vals))) if vals else None


def sign_insensitive_nested_distance(xs, ys):
    vals = []
    for x, y in zip(xs, ys):
        d1 = rms_complex(x, y)
        d2 = rms_complex(x, [-z for z in y])
        if d1 is not None and d2 is not None:
            vals.append(min(d1, d2))
    return math.sqrt(sum(v * v for v in vals) / float(len(vals))) if vals else None


def fourier_hats(p, blocks):
    return [tri80.fourier_values(p, block) for block in blocks]


def block_bispectrum_raw_phase_weight(p, blocks, pairs):
    hats = fourier_hats(p, blocks)
    raw = []
    phase = []
    weights_abs = []
    weights_min_hat = []
    for hat in hats:
        block_raw = []
        block_phase = []
        block_w_abs = []
        block_w_min = []
        for u, v in pairs:
            z = hat[u] * hat[v] * hat[(u + v) % int(p)].conjugate()
            block_raw.append(z)
            block_phase.append(normalize_complex(z))
            block_w_abs.append(abs(z))
            block_w_min.append(min(abs(hat[u]), abs(hat[v]), abs(hat[(u + v) % int(p)])))
        raw.append(block_raw)
        phase.append(block_phase)
        weights_abs.append(block_w_abs)
        weights_min_hat.append(block_w_min)
    return raw, phase, weights_abs, weights_min_hat, hats


def pair_sum_phase_vectors(block_raw):
    out = {}
    for name, left, right in SPLITS:
        split_vec = []
        for side in (left, right):
            for j in range(len(block_raw[0])):
                split_vec.append(normalize_complex(sum(block_raw[idx][j] for idx in side)))
        out[name] = split_vec
    return out


def pair_sum_raw_vectors(block_raw):
    out = {}
    for name, left, right in SPLITS:
        split_vec = []
        for side in (left, right):
            for j in range(len(block_raw[0])):
                split_vec.append(sum(block_raw[idx][j] for idx in side))
        out[name] = split_vec
    return out


def pair_weight_vectors(block_weights):
    out = {}
    for name, left, right in SPLITS:
        split_vec = []
        for side in (left, right):
            for j in range(len(block_weights[0])):
                split_vec.append(sum(block_weights[idx][j] for idx in side))
        out[name] = split_vec
    return out


def subset_nested(vecs, indices):
    return [[vec[idx] for idx in indices] for vec in vecs]


def subset_pair_vec(vec, indices, pair_count):
    return [vec[idx] for idx in indices] + [vec[pair_count + idx] for idx in indices]


def mean_split_distance(candidate_by_split, exact_by_split):
    values = []
    by_split = {}
    for name in candidate_by_split:
        value = rms_complex(candidate_by_split[name], exact_by_split[name])
        by_split[name] = value
        if value is not None:
            values.append(value)
    best_split = min(by_split, key=lambda k: by_split[k] if by_split[k] is not None else 10**99) if by_split else None
    return mean(values), by_split, best_split


def mean_split_weighted_distance(candidate_by_split, exact_by_split, weights_by_split):
    values = []
    by_split = {}
    for name in candidate_by_split:
        value = weighted_rms_phase(candidate_by_split[name], exact_by_split[name], weights_by_split[name])
        by_split[name] = value
        if value is not None:
            values.append(value)
    best_split = min(by_split, key=lambda k: by_split[k] if by_split[k] is not None else 10**99) if by_split else None
    return mean(values), by_split, best_split


def phase_entropy(phases, bins=12):
    if not phases:
        return None
    counts = [0] * int(bins)
    for z in phases:
        if abs(z) <= 1.0e-12:
            continue
        angle = math.atan2(z.imag, z.real)
        idx = int(math.floor((angle + math.pi) / (2.0 * math.pi) * int(bins)))
        idx = max(0, min(int(bins) - 1, idx))
        counts[idx] += 1
    total = sum(counts)
    if total <= 0:
        return None
    entropy = 0.0
    for c in counts:
        if c:
            p = float(c) / float(total)
            entropy -= p * math.log(p)
    return entropy / math.log(float(bins))


def raw_phase_diagnostics(p, hats):
    phase_by_block = []
    entropy_by_block = []
    zero_count = 0
    for hat in hats:
        phases = []
        for u in range(1, int(p)):
            if abs(hat[u]) <= 1.0e-10:
                zero_count += 1
                continue
            phases.append(normalize_complex(hat[u]))
        phase_by_block.append(phases)
        entropy_by_block.append(phase_entropy(phases))
    coherence_by_pair = {}
    coherence_values = []
    for i in range(len(hats)):
        for j in range(i + 1, len(hats)):
            vals = []
            for u in range(1, int(p)):
                if abs(hats[i][u]) <= 1.0e-10 or abs(hats[j][u]) <= 1.0e-10:
                    continue
                vals.append(normalize_complex(hats[i][u]) * normalize_complex(hats[j][u]).conjugate())
            coh = abs(sum(vals) / float(len(vals))) if vals else None
            coherence_by_pair["{}_{}".format(i, j)] = coh
            if coh is not None:
                coherence_values.append(coh)
    return {
        "phase_entropy_by_block": entropy_by_block,
        "phase_entropy_total": mean(entropy_by_block),
        "phase_coherence_by_block_pair": coherence_by_pair,
        "phase_coherence_mean": mean(coherence_values),
        "phase_zero_count": int(zero_count),
        "fourier_zero_count": int(zero_count),
    }


def triple_distance(p, blocks, exact_triple):
    return nested_rms(tri80.triple_correlation_vectors(p, blocks), exact_triple)


def choose_sample_indices(total, sample_size, seed_text):
    return tri80.choose_sample_indices(total, sample_size, seed_text)


def rank_values(values, higher_better=False):
    return tri80.rank_values(values, higher_better)


def spearman(xs, ys):
    return tri80.spearman(xs, ys)


def kendall_tau(xs, ys):
    pairs = [(float(x), float(y)) for x, y in zip(xs, ys) if x is not None and y is not None]
    n = len(pairs)
    if n < 3:
        return None
    concordant = 0
    discordant = 0
    for i in range(n):
        for j in range(i + 1, n):
            dx = pairs[i][0] - pairs[j][0]
            dy = pairs[i][1] - pairs[j][1]
            prod = dx * dy
            if prod > 0:
                concordant += 1
            elif prod < 0:
                discordant += 1
    denom = concordant + discordant
    return float(concordant - discordant) / float(denom) if denom else None


def top_k_overlap(ids, sampled, full, k):
    pairs = [(cid, float(s), float(f)) for cid, s, f in zip(ids, sampled, full) if s is not None and f is not None]
    if not pairs:
        return None
    k = min(int(k), len(pairs))
    top_s = set(cid for cid, _s, _f in sorted(pairs, key=lambda row: row[1])[:k])
    top_f = set(cid for cid, _s, _f in sorted(pairs, key=lambda row: row[2])[:k])
    return float(len(top_s & top_f)) / float(k)


def stability_summary(sweep_rows):
    out = []
    by_key = {}
    for row in sweep_rows:
        by_key.setdefault((str(row.get("feature_name")), str(row.get("sample_size"))), []).append(row)
    order = {"100": 100, "300": 300, "500": 500, "1000": 1000, "full": 10**9}
    for (feature, size), rows in sorted(by_key.items(), key=lambda item: (item[0][0], order.get(item[0][1], 10**8))):
        sampled = [row.get("sampled_value") for row in rows]
        full = [row.get("full_value") for row in rows]
        ids = [row.get("candidate_id") for row in rows]
        out.append(
            {
                "feature_name": feature,
                "sample_size": size,
                "row_count": int(len(rows)),
                "median_abs_error_vs_full": median(row.get("abs_error_vs_full") for row in rows),
                "mean_abs_error_vs_full": mean(row.get("abs_error_vs_full") for row in rows),
                "spearman_to_full": spearman(sampled, full),
                "kendall_to_full": kendall_tau(sampled, full),
                "top_k_overlap_10": top_k_overlap(ids, sampled, full, 10),
                "top_k_overlap_25": top_k_overlap(ids, sampled, full, 25),
                "top_k_overlap_50": top_k_overlap(ids, sampled, full, 50),
            }
        )
    return out


def group_rows(rows):
    out = {}
    for row in rows:
        out.setdefault(row.get("primary_label", "missing"), []).append(row)
    return out


def select_groups(rows, groups):
    groups = set(groups)
    return [row for row in rows if row.get("primary_label") in groups]


def auc_direction(good_values, bad_values, lower_is_better=True):
    good_values = [float(x) for x in good_values if x is not None]
    bad_values = [float(x) for x in bad_values if x is not None]
    if not good_values or not bad_values:
        return None
    wins = 0.0
    total = 0.0
    for g in good_values:
        for b in bad_values:
            total += 1.0
            if lower_is_better:
                wins += 1.0 if g < b else 0.5 if g == b else 0.0
            else:
                wins += 1.0 if g > b else 0.5 if g == b else 0.0
    return wins / total if total else None


def threshold_accuracy(good_values, bad_values, lower_is_better=True):
    good_values = [float(x) for x in good_values if x is not None]
    bad_values = [float(x) for x in bad_values if x is not None]
    if not good_values or not bad_values:
        return None
    threshold = (median(good_values) + median(bad_values)) / 2.0
    if lower_is_better:
        correct = sum(1 for x in good_values if x <= threshold) + sum(1 for x in bad_values if x > threshold)
    else:
        correct = sum(1 for x in good_values if x >= threshold) + sum(1 for x in bad_values if x < threshold)
    return float(correct) / float(len(good_values) + len(bad_values))


def lower_is_better(feature):
    if feature in ("phase_coherence_mean", "kappa_q99", "kappa_max", "closure_shell_score", "alignment_to_minus_rho"):
        return False
    return True


PHASE_FEATURES = [
    "block_bispectrum_distance_to_exact",
    "block_weighted_bispectrum_distance_abs",
    "block_weighted_bispectrum_distance_min_hat",
    "block_complex_bispectrum_distance",
    "pair_sum_bispectrum_distance",
    "pair_sum_weighted_bispectrum_distance",
    "pair_signal_bispectrum_distance",
    "triple_correlation_distance",
    "distance_raw",
    "distance_multiplier_minimized",
    "distance_sign_insensitive",
    "distance_complement_aware",
    "phase_entropy_total",
    "phase_coherence_mean",
    "D_min_ratio",
    "kappa_q99",
    "kappa_max",
    "closure_shell_score",
    "alignment_to_minus_rho",
    "damage_score",
]


def feature_separation_summary(rows):
    comparisons = [
        ("exact_derived_vs_search_derived_false_like", ("exact_derived",), ("score4_false_like_repairable_parent", "score4_false_like_failed_parent", "search_derived_false_like", "other_low_score")),
        ("exact_derived_vs_score4_false_like_parent", ("exact_derived",), ("score4_false_like_repairable_parent", "score4_false_like_failed_parent")),
        ("repairable_parent_vs_failed_parent", ("score4_false_like_repairable_parent",), ("score4_false_like_failed_parent",)),
        ("focused_success_child_vs_score4_false_like_parent", ("focused_success_child",), ("score4_false_like_repairable_parent", "score4_false_like_failed_parent")),
        ("late_preclosure_vs_non_preclosure", ("late_preclosure",), ("score4_false_like_repairable_parent", "score4_false_like_failed_parent", "random_control")),
        ("exact_derived_vs_random_control", ("exact_derived",), ("random_control",)),
    ]
    out = []
    by_group = group_rows(rows)
    for name, good_groups, bad_groups in comparisons:
        good = [row for group in good_groups for row in by_group.get(group, [])]
        bad = [row for group in bad_groups for row in by_group.get(group, [])]
        for feature in PHASE_FEATURES:
            gv = [row.get(feature) for row in good if row.get(feature) is not None]
            bv = [row.get(feature) for row in bad if row.get(feature) is not None]
            if not gv or not bv:
                continue
            lib = lower_is_better(feature)
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
                    "rank_separation_score": auc_direction(gv, bv, lib),
                    "simple_threshold_accuracy": threshold_accuracy(gv, bv, lib),
                    "direction": "lower_is_more_exact_like" if lib else "higher_is_more_exact_like",
                }
            )
    return out


def pair_vs_block_summary(separation_rows):
    out = []
    comparisons = sorted(set(row.get("comparison") for row in separation_rows))
    for comparison in comparisons:
        block = next((row for row in separation_rows if row.get("comparison") == comparison and row.get("feature_name") == "block_bispectrum_distance_to_exact"), None)
        pair = next((row for row in separation_rows if row.get("comparison") == comparison and row.get("feature_name") == "pair_sum_bispectrum_distance"), None)
        if not block or not pair:
            continue
        out.append(
            {
                "comparison": comparison,
                "block_rank_separation": block.get("rank_separation_score"),
                "pair_sum_rank_separation": pair.get("rank_separation_score"),
                "pair_minus_block": None if block.get("rank_separation_score") is None or pair.get("rank_separation_score") is None else float(pair.get("rank_separation_score")) - float(block.get("rank_separation_score")),
                "verdict": "pair_at_least_block" if pair.get("rank_separation_score") is not None and block.get("rank_separation_score") is not None and float(pair.get("rank_separation_score")) >= float(block.get("rank_separation_score")) else "block_stronger",
            }
        )
    return out


def gauge_summary(rows):
    features = ["distance_raw", "distance_multiplier_minimized", "distance_sign_insensitive", "distance_complement_aware"]
    out = []
    for label, label_rows in sorted(group_rows(rows).items()):
        for feature in features:
            values = [row.get(feature) for row in label_rows if row.get(feature) is not None]
            if not values:
                continue
            out.append(
                {
                    "primary_label": label,
                    "feature_name": feature,
                    "count": int(len(values)),
                    "median": median(values),
                    "mean": mean(values),
                    "std": stddev(values),
                    "q25": quantile(values, 0.25),
                    "q75": quantile(values, 0.75),
                }
            )
    return out


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


def compute_phase_rows(candidates, args):
    p = int(args.p)
    ks = tuple(int(x) for x in args.ks)
    lam = int(args.lam)
    pairs = tri80.bispectrum_pairs(p)
    pair_count = len(pairs)
    sample_sizes = parse_sample_sizes(args.sample_sizes)
    exact_blocks = blocks_from_payload(tri80.load_exact_candidate(args.exact_json, p, ks, lam))
    exact_raw, exact_phase, exact_w_abs, exact_w_min, exact_hats = block_bispectrum_raw_phase_weight(p, exact_blocks, pairs)
    exact_pair_sum_phase = pair_sum_phase_vectors(exact_raw)
    exact_pair_sum_raw = pair_sum_raw_vectors(exact_raw)
    exact_pair_signal = tri80.pair_signal_bispectrum_vectors(p, exact_blocks, pairs)
    exact_triple = tri80.triple_correlation_vectors(p, exact_blocks)
    block_rows = []
    pair_rows = []
    triple_rows = []
    phase_diag_rows = []
    sweep_rows = []
    rows_by_hash = {}
    for idx, candidate in enumerate(candidates):
        blocks = blocks_from_payload(candidate)
        basic = candidate_basic(candidate, p, ks, lam)
        h = basic["candidate_hash"]
        raw, phase, w_abs, w_min, hats = block_bispectrum_raw_phase_weight(p, blocks, pairs)
        pair_sum_phase = pair_sum_phase_vectors(raw)
        pair_sum_raw = pair_sum_raw_vectors(raw)
        pair_signal = tri80.pair_signal_bispectrum_vectors(p, blocks, pairs)
        pair_weights = pair_weight_vectors(w_abs)
        triple = tri80.triple_correlation_vectors(p, blocks)
        block_norm = nested_rms(phase, exact_phase)
        block_weighted_abs = nested_weighted_rms_phase(phase, exact_phase, w_abs)
        block_weighted_min = nested_weighted_rms_phase(phase, exact_phase, w_min)
        block_complex = nested_rms(raw, exact_raw)
        block_sign = sign_insensitive_nested_distance(phase, exact_phase)
        min_mult = block_norm
        if args.multiplier_minimized:
            for mult in range(1, p):
                mblocks = tri80.multiply_blocks(blocks, mult, p)
                _mraw, mphase, _mw_abs, _mw_min, _mhats = block_bispectrum_raw_phase_weight(p, mblocks, pairs)
                dist = nested_rms(mphase, exact_phase)
                if min_mult is None or dist < min_mult:
                    min_mult = dist
        pair_sum_dist, pair_sum_by_split, best_pair_split = mean_split_distance(pair_sum_phase, exact_pair_sum_phase)
        pair_sum_weighted, pair_sum_weighted_by_split, _best_pair_weighted = mean_split_weighted_distance(pair_sum_phase, exact_pair_sum_phase, pair_weights)
        pair_signal_dist, pair_signal_by_split, best_pair_signal_split = mean_split_distance(pair_signal, exact_pair_signal)
        pair_sum_complex_dist, pair_sum_complex_by_split, _best_pair_complex = mean_split_distance(pair_sum_raw, exact_pair_sum_raw)
        triple_dist = nested_rms(triple, exact_triple)
        phase_diag = raw_phase_diagnostics(p, hats)
        common = dict(basic)
        common.update(
            {
                "block_bispectrum_distance_to_exact": block_norm,
                "block_weighted_bispectrum_distance_abs": block_weighted_abs,
                "block_weighted_bispectrum_distance_min_hat": block_weighted_min,
                "block_complex_bispectrum_distance": block_complex,
                "distance_raw": block_norm,
                "distance_multiplier_minimized": min_mult,
                "distance_sign_insensitive": block_sign,
                "distance_complement_aware": block_sign,
                "pair_sum_bispectrum_distance": pair_sum_dist,
                "pair_sum_weighted_bispectrum_distance": pair_sum_weighted,
                "pair_signal_bispectrum_distance": pair_signal_dist,
                "pair_sum_complex_bispectrum_distance": pair_sum_complex_dist,
                "triple_correlation_distance": triple_dist,
                "bispectrum_full_available": True,
                "bispectrum_sample_size": args.sample_sizes,
                "bispectrum_sampling_seed": int(args.seed),
                "multiplier_minimized": bool(args.multiplier_minimized),
            }
        )
        common.update({k: phase_diag.get(k) for k in ("phase_entropy_total", "phase_coherence_mean", "phase_zero_count", "fourier_zero_count")})
        rows_by_hash[h] = common
        block_rows.append(common)
        pair_row = dict(basic)
        pair_row.update(
            {
                "pair_sum_bispectrum_distance": pair_sum_dist,
                "pair_sum_bispectrum_distance_by_split": pair_sum_by_split,
                "best_pair_sum_split": best_pair_split,
                "pair_sum_weighted_bispectrum_distance": pair_sum_weighted,
                "pair_sum_weighted_bispectrum_distance_by_split": pair_sum_weighted_by_split,
                "pair_signal_bispectrum_distance": pair_signal_dist,
                "pair_signal_bispectrum_distance_by_split": pair_signal_by_split,
                "best_pair_signal_split": best_pair_signal_split,
                "pair_sum_complex_bispectrum_distance": pair_sum_complex_dist,
                "pair_sum_complex_bispectrum_distance_by_split": pair_sum_complex_by_split,
            }
        )
        pair_rows.append(pair_row)
        triple_rows.append(dict(basic, triple_correlation_distance=triple_dist, triple_correlation_full_available=True))
        phase_diag_rows.append(dict(basic, **phase_diag))
        for sample_size in sample_sizes:
            indices = choose_sample_indices(pair_count, sample_size, "{}:{}:{}".format(h, sample_size, args.seed))
            sample_label = "full" if sample_size == "full" or len(indices) == pair_count else int(sample_size)
            sampled_phase = subset_nested(phase, indices)
            sampled_exact_phase = subset_nested(exact_phase, indices)
            sampled_raw = subset_nested(raw, indices)
            sampled_exact_raw = subset_nested(exact_raw, indices)
            sampled_w_abs = subset_nested(w_abs, indices)
            sampled_block_norm = nested_rms(sampled_phase, sampled_exact_phase)
            sampled_weighted = nested_weighted_rms_phase(sampled_phase, sampled_exact_phase, sampled_w_abs)
            sampled_complex = nested_rms(sampled_raw, sampled_exact_raw)
            sampled_pair_values = []
            sampled_pair_full_values = []
            for name in pair_sum_phase:
                sampled_pair_values.append(rms_complex(subset_pair_vec(pair_sum_phase[name], indices, pair_count), subset_pair_vec(exact_pair_sum_phase[name], indices, pair_count)))
                sampled_pair_full_values.append(rms_complex(pair_sum_phase[name], exact_pair_sum_phase[name]))
            sampled_pair_dist = mean(sampled_pair_values)
            full_pair_dist = mean(sampled_pair_full_values)
            triple_indices = choose_sample_indices(p * p, sample_size, "{}:{}:triple:{}".format(h, sample_size, args.seed))
            sampled_triple = tri80.subset_nested(triple, triple_indices)
            sampled_exact_triple = tri80.subset_nested(exact_triple, triple_indices)
            sampled_triple_dist = nested_rms(sampled_triple, sampled_exact_triple)
            feature_values = {
                "block_bispectrum_distance": (sampled_block_norm, block_norm),
                "weighted_bispectrum_distance": (sampled_weighted, block_weighted_abs),
                "complex_bispectrum_distance": (sampled_complex, block_complex),
                "pair_sum_bispectrum_distance": (sampled_pair_dist, full_pair_dist),
                "triple_correlation_distance": (sampled_triple_dist, triple_dist),
            }
            for feature_name, (sampled_value, full_value) in feature_values.items():
                sweep_rows.append(
                    {
                        "candidate_id": basic["candidate_id"],
                        "candidate_hash": h,
                        "primary_label": basic["primary_label"],
                        "feature_name": feature_name,
                        "sample_size": sample_label,
                        "sampled_pair_count": int(len(indices) if feature_name != "triple_correlation_distance" else len(triple_indices)),
                        "full_pair_count": int(pair_count if feature_name != "triple_correlation_distance" else p * p),
                        "sampled_value": sampled_value,
                        "full_value": full_value,
                        "abs_error_vs_full": abs(float(sampled_value) - float(full_value)) if sampled_value is not None and full_value is not None else None,
                    }
                )
    return block_rows, pair_rows, triple_rows, phase_diag_rows, sweep_rows, rows_by_hash


def late_preclosure_transitions(candidates, rows_by_hash, args):
    parent_by_hash = {}
    late_rows = []
    child_rows = []
    for candidate in candidates:
        label = candidate.get("primary_label")
        h = candidate.get("candidate_hash") or candidate.get("canonical_hash")
        if label in ("score4_false_like_repairable_parent", "score4_false_like_failed_parent"):
            parent_by_hash[h] = candidate
        if label == "late_preclosure":
            late_rows.append(candidate)
        if label == "focused_success_child":
            child_rows.append(candidate)
    children_by_key = {}
    for child in child_rows:
        key = (child.get("parent_hash"), child.get("restart_id"), child.get("mode"))
        children_by_key.setdefault(key, []).append(child)
    out = []
    for late in late_rows:
        parent_hash = late.get("parent_hash")
        key = (parent_hash, late.get("restart_id"), late.get("mode"))
        child_candidates = sorted(children_by_key.get(key, []), key=lambda r: int(r.get("step", 10**9)))
        child = None
        for cand in child_candidates:
            if int(cand.get("step", -1)) >= int(late.get("step", -1)):
                child = cand
                break
        parent_features = rows_by_hash.get(parent_hash)
        late_features = rows_by_hash.get(late.get("candidate_hash") or late.get("canonical_hash"))
        child_features = rows_by_hash.get(child.get("candidate_hash") or child.get("canonical_hash")) if child else None
        if not late_features:
            continue
        row = {
            "parent_hash": parent_hash,
            "late_preclosure_hash": late.get("candidate_hash") or late.get("canonical_hash"),
            "success_child_hash": child.get("candidate_hash") or child.get("canonical_hash") if child else None,
            "restart_id": late.get("restart_id"),
            "mode": late.get("mode"),
            "late_step": late.get("step"),
            "child_step": child.get("step") if child else None,
        }
        for feature in [
            "block_bispectrum_distance_to_exact",
            "pair_sum_bispectrum_distance",
            "triple_correlation_distance",
        ]:
            row["parent_{}".format(feature)] = parent_features.get(feature) if parent_features else None
            row["late_{}".format(feature)] = late_features.get(feature) if late_features else None
            row["child_{}".format(feature)] = child_features.get(feature) if child_features else None
            row["delta_parent_to_late_{}".format(feature)] = None if not parent_features or parent_features.get(feature) is None or late_features.get(feature) is None else float(late_features.get(feature)) - float(parent_features.get(feature))
            row["delta_late_to_child_{}".format(feature)] = None if not child_features or child_features.get(feature) is None or late_features.get(feature) is None else float(child_features.get(feature)) - float(late_features.get(feature))
        for feature in ["D_min_ratio", "kappa_q99", "closure_shell_score", "alignment_to_minus_rho"]:
            parent_move = parent_features.get(feature) if parent_features else None
            late_move = late_features.get(feature) if late_features else None
            child_move = child_features.get(feature) if child_features else None
            row["parent_{}".format(feature)] = parent_move
            row["late_{}".format(feature)] = late_move
            row["child_{}".format(feature)] = child_move
            row["delta_parent_to_late_{}".format(feature)] = None if parent_move is None or late_move is None else float(late_move) - float(parent_move)
            row["delta_late_to_child_{}".format(feature)] = None if child_move is None or late_move is None else float(child_move) - float(late_move)
        out.append(row)
    return out


def attach_movespace(block_rows, args):
    p = int(args.p)
    ks = tuple(int(x) for x in args.ks)
    lam = int(args.lam)
    by_hash = {row.get("candidate_hash"): row for row in block_rows}
    for row in block_rows:
        blocks = blocks_from_payload(row)
        if blocks is None:
            continue
    # block_rows already omit blocks; collect candidates separately when computing movespace.


def compute_movespace_for_phase_rows(phase_rows, candidates, args):
    by_hash = {row.get("candidate_hash"): row for row in phase_rows}
    p = int(args.p)
    lam = int(args.lam)
    for candidate in candidates:
        h = candidate.get("candidate_hash") or candidate.get("canonical_hash")
        if h not in by_hash:
            continue
        blocks = blocks_from_payload(candidate)
        diagnostic_seed = int(hashlib.sha256(str(h).encode("utf-8")).hexdigest()[:8], 16) % (2**31)
        move = reg81.move_space_features(
            p,
            blocks,
            lam,
            diagnostic_type=args.diagnostic_type,
            diagnostic_sample_count=int(args.diagnostic_sample_count),
            diagnostic_seed=diagnostic_seed,
        )
        by_hash[h].update(move)
    return phase_rows


def hypothesis_evaluation(rows, separation_rows, stability_rows, gauge_rows, transition_rows):
    def auc(comparison, feature):
        for row in separation_rows:
            if row.get("comparison") == comparison and row.get("feature_name") == feature:
                return row.get("rank_separation_score")
        return None

    def status(value, threshold=0.75):
        if value is None:
            return "inconclusive"
        return "supported" if float(value) >= float(threshold) else "not_supported"

    exact_false_block = auc("exact_derived_vs_search_derived_false_like", "block_bispectrum_distance_to_exact")
    exact_false_pair = auc("exact_derived_vs_search_derived_false_like", "pair_sum_bispectrum_distance")
    repair_auc = auc("repairable_parent_vs_failed_parent", "block_bispectrum_distance_to_exact")
    best_variant = None
    for feature in ["block_bispectrum_distance_to_exact", "block_weighted_bispectrum_distance_abs", "block_weighted_bispectrum_distance_min_hat", "block_complex_bispectrum_distance", "pair_sum_bispectrum_distance"]:
        value = auc("exact_derived_vs_search_derived_false_like", feature)
        if value is not None and (best_variant is None or value > best_variant[1]):
            best_variant = (feature, value)
    stable_300 = [row.get("spearman_to_full") for row in stability_rows if str(row.get("sample_size")) in ("300", "500", "1000") and row.get("feature_name") in ("block_bispectrum_distance", "pair_sum_bispectrum_distance", "weighted_bispectrum_distance")]
    best_stability = max([float(x) for x in stable_300 if x is not None] or [0.0])
    raw_std = median(row.get("std") for row in gauge_rows if row.get("feature_name") == "distance_raw")
    min_std = median(row.get("std") for row in gauge_rows if row.get("feature_name") in ("distance_multiplier_minimized", "distance_sign_insensitive", "distance_complement_aware"))
    late_bis_auc = max([x for x in [
        auc("late_preclosure_vs_non_preclosure", "block_bispectrum_distance_to_exact"),
        auc("late_preclosure_vs_non_preclosure", "pair_sum_bispectrum_distance"),
        auc("late_preclosure_vs_non_preclosure", "triple_correlation_distance"),
    ] if x is not None] or [None])
    late_move_auc = max([x for x in [
        auc("late_preclosure_vs_non_preclosure", "D_min_ratio"),
        auc("late_preclosure_vs_non_preclosure", "kappa_q99"),
        auc("late_preclosure_vs_non_preclosure", "closure_shell_score"),
        auc("late_preclosure_vs_non_preclosure", "alignment_to_minus_rho"),
    ] if x is not None] or [None])
    false_rows = [row for row in rows if row.get("primary_label") in ("score4_false_like_repairable_parent", "score4_false_like_failed_parent")]
    false_score_low = bool(false_rows) and median(row.get("S") for row in false_rows) <= 4
    return {
        "H_PHASE37_1": {
            "statement": "block-level bispectrum separates exact-derived from false-like.",
            "status": status(exact_false_block),
            "rank_separation_score": exact_false_block,
        },
        "H_PHASE37_2": {
            "statement": "pair-level bispectrum is at least as useful as block-level bispectrum.",
            "status": "supported" if exact_false_pair is not None and exact_false_block is not None and float(exact_false_pair) >= float(exact_false_block) - 0.02 else "not_supported" if exact_false_pair is not None and exact_false_block is not None else "inconclusive",
            "block_auc": exact_false_block,
            "pair_auc": exact_false_pair,
        },
        "H_PHASE37_3": {
            "statement": "a best stable bispectrum variant can be identified.",
            "status": "supported" if best_variant is not None and best_variant[1] >= 0.75 and best_stability >= 0.80 else "not_supported" if best_variant else "inconclusive",
            "best_variant": best_variant[0] if best_variant else None,
            "best_variant_auc": best_variant[1] if best_variant else None,
            "best_sample_stability": best_stability,
        },
        "H_PHASE37_4": {
            "statement": "repairable and failed parents are weakly separated by bispectrum alone.",
            "status": "supported" if repair_auc is not None and repair_auc < 0.75 else "not_supported" if repair_auc is not None else "inconclusive",
            "repairable_vs_failed_auc": repair_auc,
        },
        "H_PHASE37_5": {
            "statement": "late-preclosure is more distinctive in move-space than bispectrum/triple.",
            "status": "supported" if late_bis_auc is not None and late_move_auc is not None and float(late_move_auc) >= float(late_bis_auc) else "not_supported" if late_bis_auc is not None and late_move_auc is not None else "inconclusive",
            "late_preclosure_best_bispectrum_or_triple_auc": late_bis_auc,
            "late_preclosure_best_movespace_auc": late_move_auc,
        },
        "H_PHASE37_6": {
            "statement": "sampled bispectrum 300-1000 is stable against full features.",
            "status": "supported" if best_stability >= 0.80 else "not_supported",
            "best_sample_stability": best_stability,
        },
        "H_PHASE37_7": {
            "statement": "multiplier / complement gauge handling affects bispectrum distance stability.",
            "status": "supported" if raw_std is not None and min_std is not None and float(min_std) <= float(raw_std) else "not_supported" if raw_std is not None and min_std is not None else "inconclusive",
            "raw_std_median": raw_std,
            "gauge_handled_std_median": min_std,
        },
        "H_PHASE37_8": {
            "statement": "false basin is magnitude-near but phase/bispectrum-wrong as a broad classification.",
            "status": "supported" if false_score_low and exact_false_block is not None and exact_false_block >= 0.75 else "not_supported" if false_rows else "inconclusive",
            "false_like_median_score": median(row.get("S") for row in false_rows),
            "block_bispectrum_auc": exact_false_block,
        },
    }


def build_summary(config, rows, separation_rows, pair_block_rows, gauge_rows, stability_rows, transition_rows, hypotheses):
    counts = {label: len(label_rows) for label, label_rows in sorted(group_rows(rows).items())}
    top = sorted(
        [row for row in separation_rows if row.get("comparison") == "exact_derived_vs_search_derived_false_like"],
        key=lambda r: r.get("rank_separation_score") if r.get("rank_separation_score") is not None else -1,
        reverse=True,
    )[:10]
    lines = []
    lines.append("# p37 Fourier phase / bispectrum audit")
    lines.append("")
    lines.append("This is a theory-diagnostic run, not a Hadamard 668 construction run and not a new score0 search.")
    lines.append("")
    lines.append("## Core formulas")
    lines.append("")
    lines.append("rho(d) = N(d) - lambda for d != 0.")
    lines.append("")
    lines.append("S = sum_{d != 0} rho(d)^2.")
    lines.append("")
    lines.append("omega = exp(2*pi*i/p).")
    lines.append("")
    lines.append("hat f(u) = sum_x f(x) * omega^(-u*x).")
    lines.append("")
    lines.append("n_X(d) = #{(x,y) in X^2 : x - y = d}.")
    lines.append("")
    lines.append("hat n_X(u) = |hat f_X(u)|^2, so score sees autocorrelation / Fourier magnitude but not raw phase.")
    lines.append("")
    lines.append("B_X(u,v) = hat f_X(u) * hat f_X(v) * conjugate(hat f_X(u+v)).")
    lines.append("")
    lines.append("b_X(u,v) = B_X(u,v) / |B_X(u,v)|.")
    lines.append("")
    lines.append("B_X contains phase combination phi(u) + phi(v) - phi(u+v), and translation phases cancel.")
    lines.append("")
    lines.append("Raw phase features are gauge-dependent and are diagnostic only.")
    lines.append("")
    lines.append("## Inputs")
    lines.append("")
    lines.append("- candidate rows: `{}`".format(len(rows)))
    lines.append("- label counts: `{}`".format(counts))
    lines.append("- sample sizes: `{}`".format(config.get("sample_sizes")))
    lines.append("- multiplier-minimized distance enabled: `{}`".format(config.get("multiplier_minimized")))
    lines.append("")
    lines.append("## Strongest exact-derived vs false-like separations")
    lines.append("")
    lines.append("| feature | AUC/rank separation | threshold accuracy | direction |")
    lines.append("|---|---:|---:|---|")
    for row in top:
        lines.append("| {} | {} | {} | {} |".format(row.get("feature_name"), fmt(row.get("rank_separation_score")), fmt(row.get("simple_threshold_accuracy")), row.get("direction")))
    lines.append("")
    lines.append("## Hypotheses")
    lines.append("")
    for key in sorted(hypotheses):
        lines.append("- `{}`: `{}`. {}".format(key, hypotheses[key].get("status"), hypotheses[key].get("statement")))
    lines.append("")
    lines.append("## Required answers")
    lines.append("")
    lines.append("1. block-level bispectrum separation: `{}`.".format(hypotheses["H_PHASE37_1"]["status"]))
    lines.append("2. pair-level vs block-level bispectrum: `{}`.".format(hypotheses["H_PHASE37_2"]["status"]))
    lines.append("3. normalized / weighted / complex variant selection: `{}` with best `{}`.".format(hypotheses["H_PHASE37_3"]["status"], hypotheses["H_PHASE37_3"].get("best_variant")))
    lines.append("4. repairable parent vs failed parent: `{}`; standalone bispectrum is expected to be weak here.".format(hypotheses["H_PHASE37_4"]["status"]))
    lines.append("5. late-preclosure transition: `{}`; inspect `late_preclosure_bispectrum_transition.csv` for deltas.".format(hypotheses["H_PHASE37_5"]["status"]))
    lines.append("6. sampled bispectrum stability: `{}`.".format(hypotheses["H_PHASE37_6"]["status"]))
    lines.append("7. multiplier / complement gauge handling: `{}`.".format(hypotheses["H_PHASE37_7"]["status"]))
    lines.append("8. raw phase features: saved as diagnostic only because they are translation-gauge dependent.")
    lines.append("9. false basin = magnitude-near but phase/bispectrum-wrong: `{}` for broad p37 exact-vs-false classification, not repairability.".format(hypotheses["H_PHASE37_8"]["status"]))
    lines.append("10. p167 feature variants to carry forward: normalized block bispectrum, pair-sum normalized bispectrum, weighted bispectrum, sampled triple distance, and gauge-aware distances.")
    lines.append("11. generator/reranker use: use bispectrum as rerank/filter/repair-routing feature, not as a score-only replacement.")
    lines.append("12. Next step: p37 higher-order audit or p167 c01/c05/c09 bispectrum audit is justified if hypotheses remain supported.")
    lines.append("")
    lines.append("Important caveat: bispectrum / triple-correlation separation is diagnostic evidence, not a theorem, and p37 behavior should not be transferred to p167 without a p167 audit.")
    return "\n".join(lines) + "\n"


def fmt(value):
    if value is None:
        return ""
    try:
        return "{:.6g}".format(float(value))
    except Exception:
        return str(value)


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


def config_from_args(args):
    return {
        "script": SCRIPT_NAME,
        "p": int(args.p),
        "ks": [int(x) for x in args.ks],
        "lambda": int(args.lam),
        "exact_json": args.exact_json,
        "parent_fixture": args.parent_fixture,
        "success_fixture": args.success_fixture,
        "sample_sizes": args.sample_sizes,
        "metric_mode": args.metric_mode,
        "max_candidates": int(args.max_candidates),
        "max_tasks": int(args.max_tasks),
        "shard_index": int(args.shard_index),
        "shard_count": int(args.shard_count),
        "seed": int(args.seed),
        "exact_derived_count": int(args.exact_derived_count),
        "random_control_count": int(args.random_control_count),
        "diagnostic_type": args.diagnostic_type,
        "diagnostic_sample_count": int(args.diagnostic_sample_count),
        "multiplier_minimized": bool(args.multiplier_minimized),
    }


def write_outputs(out_dir, config, candidates, block_rows, pair_rows, triple_rows, phase_diag_rows, sweep_rows, transition_rows):
    ensure_dir(out_dir)
    separation_rows = feature_separation_summary(block_rows)
    pair_block_rows = pair_vs_block_summary(separation_rows)
    gauge_rows = gauge_summary(block_rows)
    stability_rows = stability_summary(sweep_rows)
    hypotheses = hypothesis_evaluation(block_rows, separation_rows, stability_rows, gauge_rows, transition_rows)
    write_json(os.path.join(out_dir, "run_config.json"), config)
    write_jsonl(os.path.join(out_dir, "input_p37_phase_bispectrum_candidates.jsonl"), candidates)
    write_jsonl(os.path.join(out_dir, "p37_block_bispectrum_variant_features.jsonl"), block_rows)
    write_jsonl(os.path.join(out_dir, "p37_pair_bispectrum_variant_features.jsonl"), pair_rows)
    write_jsonl(os.path.join(out_dir, "p37_triple_correlation_variant_features.jsonl"), triple_rows)
    write_jsonl(os.path.join(out_dir, "p37_phase_diagnostic_features.jsonl"), phase_diag_rows)
    write_csv(os.path.join(out_dir, "bispectrum_feature_separation_summary.csv"), separation_rows)
    write_json(os.path.join(out_dir, "bispectrum_feature_separation_summary.json"), {"rows": separation_rows})
    write_csv(os.path.join(out_dir, "pair_vs_block_bispectrum_summary.csv"), pair_block_rows)
    write_json(os.path.join(out_dir, "pair_vs_block_bispectrum_summary.json"), {"rows": pair_block_rows})
    write_csv(os.path.join(out_dir, "gauge_handling_summary.csv"), gauge_rows)
    write_json(os.path.join(out_dir, "gauge_handling_summary.json"), {"rows": gauge_rows})
    write_jsonl(os.path.join(out_dir, "sampled_bispectrum_variant_stability_source.jsonl"), sweep_rows)
    write_csv(os.path.join(out_dir, "sampled_bispectrum_variant_stability.csv"), [row for row in stability_rows if row.get("feature_name") != "triple_correlation_distance"])
    write_json(os.path.join(out_dir, "sampled_bispectrum_variant_stability.json"), {"rows": [row for row in stability_rows if row.get("feature_name") != "triple_correlation_distance"]})
    write_csv(os.path.join(out_dir, "sampled_triple_variant_stability.csv"), [row for row in stability_rows if row.get("feature_name") == "triple_correlation_distance"])
    write_json(os.path.join(out_dir, "sampled_triple_variant_stability.json"), {"rows": [row for row in stability_rows if row.get("feature_name") == "triple_correlation_distance"]})
    write_csv(os.path.join(out_dir, "late_preclosure_bispectrum_transition.csv"), transition_rows)
    write_json(os.path.join(out_dir, "late_preclosure_bispectrum_transition.json"), {"rows": transition_rows})
    write_json(os.path.join(out_dir, "hypothesis_evaluation.json"), hypotheses)
    with open(os.path.join(out_dir, "p37_fourier_phase_bispectrum_audit_summary.md"), "w") as f:
        f.write(build_summary(config, block_rows, separation_rows, pair_block_rows, gauge_rows, stability_rows, transition_rows, hypotheses))
    with open(os.path.join(out_dir, "run_log.md"), "w") as f:
        f.write("# p37 Fourier phase / bispectrum audit log\n\n")
        f.write("- generated_at: `{}`\n".format(time.strftime("%Y-%m-%dT%H:%M:%S%z")))
        f.write("- candidate_rows: `{}`\n".format(len(candidates)))
        f.write("- feature_rows: `{}`\n".format(len(block_rows)))
        f.write("- output_dir: `{}`\n".format(out_dir))


def aggregate_mode(args):
    roots = [root.strip() for root in str(args.aggregate_roots).split(",") if root.strip()]
    if not roots:
        raise RuntimeError("--aggregate-roots is required in aggregate mode")
    candidates = []
    block_rows = []
    pair_rows = []
    triple_rows = []
    phase_diag_rows = []
    sweep_rows = []
    transition_rows = []
    for root in roots:
        for path in glob.glob(os.path.join(root, "**", "input_p37_phase_bispectrum_candidates.jsonl"), recursive=True):
            candidates.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_block_bispectrum_variant_features.jsonl"), recursive=True):
            block_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_pair_bispectrum_variant_features.jsonl"), recursive=True):
            pair_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_triple_correlation_variant_features.jsonl"), recursive=True):
            triple_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_phase_diagnostic_features.jsonl"), recursive=True):
            phase_diag_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "sampled_bispectrum_variant_stability_source.jsonl"), recursive=True):
            sweep_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "late_preclosure_bispectrum_transition.csv"), recursive=True):
            with open(path) as f:
                reader = csv.DictReader(f)
                for row in reader:
                    converted = {}
                    for key, value in row.items():
                        if value == "":
                            converted[key] = None
                        else:
                            try:
                                converted[key] = int(value)
                            except Exception:
                                try:
                                    converted[key] = float(value)
                                except Exception:
                                    converted[key] = value
                    transition_rows.append(converted)
    candidates = dedupe_rows(candidates, ("candidate_hash",))
    block_rows = dedupe_rows(block_rows, ("candidate_hash",))
    pair_rows = dedupe_rows(pair_rows, ("candidate_hash",))
    triple_rows = dedupe_rows(triple_rows, ("candidate_hash",))
    phase_diag_rows = dedupe_rows(phase_diag_rows, ("candidate_hash",))
    transition_rows = dedupe_rows(transition_rows, ("late_preclosure_hash",))
    config = config_from_args(args)
    config["aggregate_mode"] = True
    config["aggregate_roots"] = roots
    write_outputs(args.out_dir, config, candidates, block_rows, pair_rows, triple_rows, phase_diag_rows, sweep_rows, transition_rows)


def parse_args():
    parser = argparse.ArgumentParser(description="p37 Fourier phase / bispectrum audit")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--ks", type=parse_ks, default=KS_DEFAULT)
    parser.add_argument("--lam", "--lambda", dest="lam", type=int, default=LAMBDA_DEFAULT)
    parser.add_argument("--exact-json", default=EXACT_JSON_DEFAULT)
    parser.add_argument("--parent-fixture", default=PARENT_FIXTURE_DEFAULT)
    parser.add_argument("--success-fixture", default=SUCCESS_FIXTURE_DEFAULT)
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--metric-mode", choices=("smoke", "full"), default="full")
    parser.add_argument("--sample-sizes", default="100,300,500,1000,full")
    parser.add_argument("--max-candidates", type=int, default=0)
    parser.add_argument("--max-tasks", type=int, default=0)
    parser.add_argument("--shard-index", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--seed", type=int, default=37)
    parser.add_argument("--exact-derived-count", type=int, default=100)
    parser.add_argument("--random-control-count", type=int, default=100)
    parser.add_argument("--diagnostic-type", choices=("full", "sampled"), default="full")
    parser.add_argument("--diagnostic-sample-count", type=int, default=0)
    parser.add_argument("--no-multiplier-minimized", dest="multiplier_minimized", action="store_false")
    parser.set_defaults(multiplier_minimized=True)
    parser.add_argument("--aggregate-roots", default="")
    parser.add_argument("--aggregate", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    if args.out_dir is None:
        args.out_dir = os.path.join("outputs", "explorations", "{}_p37_fourier_phase_bispectrum_audit".format(now_stamp()))
    if args.metric_mode == "smoke":
        if args.max_candidates <= 0:
            args.max_candidates = 2
        if args.max_tasks <= 0:
            args.max_tasks = 2
        args.sample_sizes = "10"
        args.exact_derived_count = min(int(args.exact_derived_count), 2)
        args.random_control_count = min(int(args.random_control_count), 1)
        args.multiplier_minimized = False
        args.diagnostic_type = "sampled"
        args.diagnostic_sample_count = min(int(args.diagnostic_sample_count or 20), 20)
    if args.aggregate:
        aggregate_mode(args)
        print("SUMMARY:", os.path.join(args.out_dir, "p37_fourier_phase_bispectrum_audit_summary.md"))
        return
    candidates = collect_candidates(args)
    if not candidates:
        raise RuntimeError("no candidates selected for this shard")
    block_rows, pair_rows, triple_rows, phase_diag_rows, sweep_rows, rows_by_hash = compute_phase_rows(candidates, args)
    block_rows = compute_movespace_for_phase_rows(block_rows, candidates, args)
    rows_by_hash = {row.get("candidate_hash"): row for row in block_rows}
    transition_rows = late_preclosure_transitions(candidates, rows_by_hash, args)
    write_outputs(args.out_dir, config_from_args(args), candidates, block_rows, pair_rows, triple_rows, phase_diag_rows, sweep_rows, transition_rows)
    print("candidates:", len(candidates))
    print("SUMMARY:", os.path.join(args.out_dir, "p37_fourier_phase_bispectrum_audit_summary.md"))


if __name__ == "__main__":
    main()
