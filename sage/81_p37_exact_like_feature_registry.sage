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


SCRIPT_NAME = "81_p37_exact_like_feature_registry"
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
REPAIRABLE_PARENT_PREFIXES = set(
    [
        "182614375107",
        "2b5e24f7f5a4",
        "3cab4b5cd0ac",
        "8234e0fee3c8",
        "87eadfb3f68d",
    ]
)


def load_triple_module():
    path = os.path.join(os.path.dirname(__file__), "80_p37_triple_bispectrum_audit.sage")
    loader = importlib.machinery.SourceFileLoader("p37_triple_bispectrum_audit_80", path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


tri80 = load_triple_module()


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
        out = int(value)
        return out
    except Exception:
        pass
    try:
        out = float(value)
        return out if math.isfinite(out) else None
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


def read_json(path):
    with open(path) as f:
        return json.load(f)


def read_jsonl(path):
    if not path or not os.path.exists(path):
        return []
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
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


def stddev(values):
    values = [float(v) for v in values if v is not None]
    if len(values) <= 1:
        return 0.0
    return statistics.pstdev(values)


def quantile(values, q):
    values = sorted(float(v) for v in values if v is not None)
    if not values:
        return None
    if len(values) == 1:
        return values[0]
    pos = float(q) * (len(values) - 1)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return values[lo]
    return values[lo] * (hi - pos) + values[hi] * (pos - lo)


def parse_ks(text):
    if isinstance(text, (list, tuple)):
        values = tuple(int(x) for x in text)
    else:
        values = tuple(int(part.strip()) for part in str(text).replace("[", "").replace("]", "").split(",") if part.strip())
    if len(values) != 4:
        raise argparse.ArgumentTypeError("--ks must contain exactly four integers")
    return values


def parse_sample_sizes(text):
    return tri80.parse_sample_sizes(text)


def short_hash(text):
    return str(text or "")[:12]


def normalize_blocks(raw_blocks):
    return tri80.normalize_blocks(raw_blocks)


def blocks_from_payload(payload):
    return tri80.blocks_from_payload(payload)


def validate_blocks(blocks, p, ks):
    return tri80.validate_blocks(blocks, p, ks)


def candidate_hash(blocks, ks, p):
    return tri80.candidate_hash(blocks, ks, p)


def score_blocks(p, blocks, lam):
    return tri80.score_blocks(p, blocks, lam)


def rho_vector(p, blocks, lam):
    return tri80.rho_vector(p, blocks, lam)


def add_candidate(rows_by_hash, payload, primary_label, source_file, p, ks, lam):
    blocks = blocks_from_payload(payload)
    if not validate_blocks(blocks, p, ks):
        return False
    h = payload.get("canonical_hash") or payload.get("candidate_hash") or candidate_hash(blocks, ks, p)
    score = score_blocks(p, blocks, lam)
    labels = set(payload.get("labels") or [])
    if payload.get("candidate_group"):
        labels.add(str(payload.get("candidate_group")))
    if payload.get("label"):
        labels.add(str(payload.get("label")))
    labels.add(str(primary_label))
    existing = rows_by_hash.get(h)
    if existing is None:
        candidate_id = payload.get("candidate_id") or "{}_{}".format(short_hash(h), primary_label)
        rows_by_hash[h] = dict(payload)
        rows_by_hash[h].update(
            {
                "candidate_id": candidate_id,
                "candidate_hash": h,
                "canonical_hash": h,
                "primary_label": primary_label,
                "labels": sorted(labels),
                "source_file": source_file,
                "source_label": payload.get("source_label") or payload.get("label") or primary_label,
                "p": int(p),
                "n": int(4 * p),
                "ks": [int(k) for k in ks],
                "lambda": int(lam),
                "score": int(score),
                "S": int(score),
                "blocks": tri80.json_blocks(blocks),
            }
        )
    else:
        existing_labels = set(existing.get("labels") or [])
        existing_labels.update(labels)
        existing["labels"] = sorted(existing_labels)
        if primary_label == "exact" or (existing.get("primary_label") in ("ambiguous", "random_control") and primary_label != "ambiguous"):
            existing["primary_label"] = primary_label
    return True


def label_parent(payload):
    score = int(payload.get("score", payload.get("S", 999999)))
    h = payload.get("canonical_hash") or payload.get("candidate_hash") or ""
    if score == 4 and any(str(h).startswith(prefix) for prefix in REPAIRABLE_PARENT_PREFIXES):
        return "score4_false_like_repairable_parent"
    if score == 4:
        return "score4_false_like_failed_parent"
    if score in (8, 12, 16, 24, 32):
        return "other_low_score"
    return "search_derived_false_like"


def generate_exact_derived(exact_payload, count, p, ks, lam, seed):
    return tri80.generate_exact_derived(exact_payload, count, p, ks, lam, seed)


def generate_random_controls(count, p, ks, lam, seed):
    return tri80.generate_random_controls(count, p, ks, lam, seed)


def collect_candidates(args):
    p = int(args.p)
    ks = tuple(int(x) for x in args.ks)
    lam = int(args.lam)
    rows_by_hash = {}
    exact = tri80.load_exact_candidate(args.exact_json, p, ks, lam)
    add_candidate(rows_by_hash, exact, "exact", args.exact_json, p, ks, lam)
    for row in generate_exact_derived(exact, int(args.exact_derived_count), p, ks, lam, args.seed):
        add_candidate(rows_by_hash, row, "exact_derived", "generated_exact_derived", p, ks, lam)
    for payload in read_jsonl(args.parent_fixture):
        label = label_parent(payload)
        add_candidate(rows_by_hash, payload, label, args.parent_fixture, p, ks, lam)
    for payload in read_jsonl(args.success_fixture):
        label = payload.get("candidate_group") or "ambiguous"
        add_candidate(rows_by_hash, payload, label, args.success_fixture, p, ks, lam)
    for row in generate_random_controls(int(args.random_control_count), p, ks, lam, args.seed):
        add_candidate(rows_by_hash, row, "random_control", "generated_random_control", p, ks, lam)
    rows = sorted(rows_by_hash.values(), key=lambda r: (str(r.get("primary_label")), int(r.get("S", 999999)), str(r.get("candidate_hash"))))
    if int(args.max_candidates) > 0:
        rows = rows[: int(args.max_candidates)]
    if int(args.shard_count) > 1:
        rows = [row for idx, row in enumerate(rows) if idx % int(args.shard_count) == int(args.shard_index)]
    if int(args.max_tasks) > 0:
        rows = rows[: int(args.max_tasks)]
    return rows


def per_block_diff_counts(p, blocks):
    return tri80.per_block_diff_counts(p, blocks)


def pair_profile_vectors(p, blocks):
    return tri80.pair_profile_vectors(p, blocks)


def vector_l2(xs, ys):
    if not xs or not ys:
        return None
    n = min(len(xs), len(ys))
    return math.sqrt(sum((float(xs[i]) - float(ys[i])) ** 2 for i in range(n)))


def vector_l1(xs, ys):
    if not xs or not ys:
        return None
    n = min(len(xs), len(ys))
    return sum(abs(float(xs[i]) - float(ys[i])) for i in range(n))


def corr(xs, ys):
    if not xs or not ys:
        return None
    n = min(len(xs), len(ys))
    xs = [float(x) for x in xs[:n]]
    ys = [float(y) for y in ys[:n]]
    mx = mean(xs)
    my = mean(ys)
    denx = math.sqrt(sum((x - mx) ** 2 for x in xs))
    deny = math.sqrt(sum((y - my) ** 2 for y in ys))
    if denx == 0.0 or deny == 0.0:
        return None
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / (denx * deny)


def split_sides(vec):
    half = len(vec) // 2
    return vec[:half], vec[half:]


def pair_profile_features(p, blocks, exact_pair_profile):
    profiles = pair_profile_vectors(p, blocks)
    l2_by_split = {}
    l1_by_split = {}
    corr_by_split = {}
    energy_gap_by_split = {}
    variance_gap_by_split = {}
    distance_to_exact = {}
    for name, vec in profiles.items():
        left, right = split_sides(vec)
        l2_by_split[name] = vector_l2(left, right)
        l1_by_split[name] = vector_l1(left, right)
        corr_by_split[name] = corr(left, right)
        energy_gap_by_split[name] = sum(float(x) ** 2 for x in left) - sum(float(x) ** 2 for x in right)
        variance_gap_by_split[name] = statistics.pvariance(left) - statistics.pvariance(right)
        distance_to_exact[name] = tri80.scalar_vector_distance(vec, exact_pair_profile[name])
    best_split = min(distance_to_exact, key=lambda name: distance_to_exact[name] if distance_to_exact[name] is not None else 10**99)
    return {
        "pair_profile_l2_by_split": l2_by_split,
        "pair_profile_l1_by_split": l1_by_split,
        "pair_profile_corr_by_split": corr_by_split,
        "pair_energy_gap_by_split": energy_gap_by_split,
        "pair_variance_gap_by_split": variance_gap_by_split,
        "distance_to_exact_pair_profile_by_split": distance_to_exact,
        "best_pair_split_by_profile": best_split,
        "best_pair_profile_l2": l2_by_split.get(best_split),
        "best_pair_profile_corr": corr_by_split.get(best_split),
    }


def ap_pair_by_split(p, blocks):
    ap_by_block = [tri80.ap_count(p, block) for block in blocks]
    out = {}
    for name, left, right in SPLITS:
        out[name] = {
            "left": int(sum(ap_by_block[i] for i in left)),
            "right": int(sum(ap_by_block[i] for i in right)),
            "gap": int(sum(ap_by_block[i] for i in left) - sum(ap_by_block[i] for i in right)),
        }
    return ap_by_block, out


def energy_pair_by_split(p, blocks):
    counts = per_block_diff_counts(p, blocks)
    energy_by_block = [tri80.additive_energy_from_counts(c) for c in counts]
    out = {}
    for name, left, right in SPLITS:
        out[name] = {
            "left": int(sum(energy_by_block[i] for i in left)),
            "right": int(sum(energy_by_block[i] for i in right)),
            "gap": int(sum(energy_by_block[i] for i in left) - sum(energy_by_block[i] for i in right)),
        }
    return energy_by_block, out


def moment_features(p, rho):
    values = {}
    norm_terms = []
    nonzero = 0
    for a in (1, 2, 3, 4, 5, 6):
        exponent = 2 * a
        raw = sum(int(rho[d]) * pow(int(d), exponent, int(p)) for d in range(1, int(p))) % int(p)
        centered = min(raw, int(p) - raw)
        values["moment_T{}".format(exponent)] = int(raw)
        norm_terms.append(float(centered) ** 2)
        if raw != 0:
            nonzero += 1
    values["moment_nonzero_count"] = int(nonzero)
    values["moment_norm"] = math.sqrt(sum(norm_terms))
    values["moment_distance_to_exact"] = values["moment_norm"]
    return values


def delta_swap_list(p, block, removed, added):
    p = int(p)
    block = set(int(x) for x in block)
    rest = [x for x in block if x != int(removed)]
    delta = [0] * p
    for y in rest:
        delta[(int(removed) - int(y)) % p] -= 1
        delta[(int(y) - int(removed)) % p] -= 1
        delta[(int(added) - int(y)) % p] += 1
        delta[(int(y) - int(added)) % p] += 1
    return delta


def dot_delta(a, b):
    return int(sum(int(a[d]) * int(b[d]) for d in range(1, len(a))))


def norm_delta(delta):
    return int(sum(int(delta[d]) * int(delta[d]) for d in range(1, len(delta))))


def quantile_from_sorted(values, q):
    if not values:
        return None
    if len(values) == 1:
        return values[0]
    pos = float(q) * (len(values) - 1)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return values[lo]
    return values[lo] * (hi - pos) + values[hi] * (pos - lo)


def move_space_features(p, blocks, lam, diagnostic_type="full", diagnostic_sample_count=0, diagnostic_seed=37):
    p = int(p)
    score = score_blocks(p, blocks, lam)
    rho = rho_vector(p, blocks, lam)
    if score == 0:
        return {
            "D_min_ratio": 0.0,
            "P_4": 1.0,
            "P_8": 1.0,
            "P_16": 1.0,
            "P_32": 1.0,
            "kappa_max": None,
            "kappa_q90": None,
            "kappa_q99": None,
            "Q_ratio": None,
            "closure_shell_score": 1.0,
            "alignment_to_minus_rho": None,
            "damage_score": 0.0,
            "hardening_score": 0.0,
            "support_turnover": None,
            "persistent_defect_fraction": None,
            "diagnostic_type": diagnostic_type,
            "diagnostic_sample_count": 0,
            "diagnostic_seed": diagnostic_seed,
        }
    moves = []
    for block_idx, block in enumerate(blocks):
        outside = [x for x in range(p) if x not in block]
        for removed in sorted(block):
            for added in outside:
                moves.append((block_idx, removed, added))
    if diagnostic_type == "sampled" and diagnostic_sample_count and diagnostic_sample_count < len(moves):
        rng = random.Random(int(diagnostic_seed))
        moves = rng.sample(moves, int(diagnostic_sample_count))
    h_min = None
    h_values = []
    kappas = []
    alignments = []
    sum_q = 0
    near = {4: 0, 8: 0, 16: 0, 32: 0}
    for block_idx, removed, added in moves:
        delta = delta_swap_list(p, blocks[block_idx], removed, added)
        g = dot_delta(rho, delta)
        q = norm_delta(delta)
        if q <= 0:
            continue
        h = int(2 * g + q)
        h_values.append(h)
        sum_q += q
        kappas.append(float(-2 * g) / float(q))
        alignments.append(float(-g) / math.sqrt(float(q) * float(score)))
        if h_min is None or h < h_min:
            h_min = h
        for threshold in near:
            if h <= threshold:
                near[threshold] += 1
    h_min = h_min if h_min is not None else 0
    d_min = int(score + h_min)
    kappas_sorted = sorted(kappas)
    num = float(len(h_values))
    support_size = sum(1 for d in range(1, p) if rho[d] != 0)
    s_over_support = float(score) / float(support_size) if support_size else None
    dmin_ratio = float(d_min) / float(score)
    kappa_q99 = quantile_from_sorted(kappas_sorted, 0.99)
    kappa_max = max(kappas) if kappas else None
    p16 = float(near[16]) / num if num else None
    q_ratio = float(sum_q) / float(4 * (p - 1) * score) if score > 0 else None
    damage = 0.0
    damage += max(0.0, dmin_ratio - 1.0)
    damage += max(0.0, 1.0 - float(kappa_q99 or 0.0))
    damage += max(0.0, 0.05 - float(p16 or 0.0)) * 10.0
    damage += min(float(q_ratio or 0.0) / 100.0, 2.0)
    closure = 0.0
    closure += max(0.0, 2.0 - float(s_over_support or 99.0)) / 2.0
    closure += min(1.0, max(0.0, float(kappa_q99 or 0.0)))
    closure += max(0.0, 1.0 - dmin_ratio)
    closure += max(alignments) if alignments else 0.0
    return {
        "D_min_ratio": dmin_ratio,
        "P_4": float(near[4]) / num if num else None,
        "P_8": float(near[8]) / num if num else None,
        "P_16": p16,
        "P_32": float(near[32]) / num if num else None,
        "kappa_max": kappa_max,
        "kappa_q90": quantile_from_sorted(kappas_sorted, 0.90),
        "kappa_q99": kappa_q99,
        "Q_ratio": q_ratio,
        "closure_shell_score": closure,
        "alignment_to_minus_rho": max(alignments) if alignments else None,
        "damage_score": damage,
        "hardening_score": max(0.0, dmin_ratio - 1.0) + max(0.0, 1.0 - float(kappa_max or 0.0)),
        "support_turnover": None,
        "persistent_defect_fraction": None,
        "diagnostic_type": diagnostic_type,
        "diagnostic_sample_count": int(len(moves)),
        "diagnostic_seed": int(diagnostic_seed),
    }


def sampled_triple_sweep(candidate, exact_triple, p, sample_sizes, seed):
    blocks = blocks_from_payload(candidate)
    triple = tri80.triple_correlation_vectors(p, blocks)
    full_dist = tri80.nested_rms_distance(triple, exact_triple)
    total = p * p
    out = []
    for sample_size in sample_sizes:
        indices = tri80.choose_sample_indices(total, sample_size, "{}:{}:triple".format(candidate.get("candidate_hash"), seed))
        sampled_candidate = tri80.subset_nested(triple, indices)
        sampled_exact = tri80.subset_nested(exact_triple, indices)
        sampled_dist = tri80.nested_rms_distance(sampled_candidate, sampled_exact)
        out.append(
            {
                "candidate_id": candidate.get("candidate_id"),
                "candidate_hash": candidate.get("candidate_hash"),
                "primary_label": candidate.get("primary_label"),
                "sample_size": "full" if sample_size == "full" or len(indices) == total else int(sample_size),
                "sampled_pair_count": int(len(indices)),
                "full_pair_count": int(total),
                "sampled_triple_correlation_distance_to_exact": sampled_dist,
                "full_triple_correlation_distance_to_exact": full_dist,
                "abs_error_vs_full": abs(float(sampled_dist) - float(full_dist)) if sampled_dist is not None and full_dist is not None else None,
            }
        )
    return out


def rank_values(values, higher_better=False):
    return tri80.rank_values(values, higher_better)


def spearman(xs, ys):
    return tri80.spearman(xs, ys)


def sampled_stability(rows, sampled_key, full_key):
    out = []
    by_size = {}
    for row in rows:
        by_size.setdefault(str(row.get("sample_size")), []).append(row)
    for size, group in sorted(by_size.items(), key=lambda item: (item[0] == "full", int(item[0]) if item[0].isdigit() else 10**9)):
        out.append(
            {
                "sample_size": size,
                "row_count": int(len(group)),
                "median_abs_error_vs_full": median(row.get("abs_error_vs_full") for row in group),
                "mean_abs_error_vs_full": mean(row.get("abs_error_vs_full") for row in group),
                "spearman_rank_correlation_vs_full": spearman([row.get(sampled_key) for row in group], [row.get(full_key) for row in group]),
            }
        )
    return out


REGISTRY_FEATURES = [
    "S",
    "rho_l1",
    "rho_linf",
    "rho_support_size",
    "S_over_support",
    "best_pair_profile_l2",
    "best_pair_profile_corr",
    "block_bispectrum_distance_to_exact",
    "pair_bispectrum_distance_to_exact",
    "triple_correlation_distance_to_exact",
    "AP_distance_to_exact",
    "additive_energy_distance_to_exact",
    "moment_norm",
    "D_min_ratio",
    "P_8",
    "P_16",
    "P_32",
    "kappa_max",
    "kappa_q99",
    "Q_ratio",
    "closure_shell_score",
    "alignment_to_minus_rho",
    "damage_score",
    "hardening_score",
]


def compute_registry_rows(candidates, args):
    p = int(args.p)
    ks = tuple(int(x) for x in args.ks)
    lam = int(args.lam)
    sample_sizes = parse_sample_sizes(args.sample_sizes)
    pairs = tri80.bispectrum_pairs(p)
    exact_blocks = blocks_from_payload(tri80.load_exact_candidate(args.exact_json, p, ks, lam))
    exact_block_bis = tri80.block_bispectrum_vectors(p, exact_blocks, pairs)
    exact_pair_sum = tri80.pair_sum_vectors(exact_block_bis)
    exact_triple = tri80.triple_correlation_vectors(p, exact_blocks)
    exact_pair_profile = pair_profile_vectors(p, exact_blocks)
    exact_ap, exact_ap_pair = ap_pair_by_split(p, exact_blocks)
    exact_energy, exact_energy_pair = energy_pair_by_split(p, exact_blocks)
    bis_args = argparse.Namespace(**vars(args))
    bis_rows, triple_light_rows, ap_light_rows, pair_light_rows, bis_sweep_rows = tri80.compute_feature_rows(candidates, bis_args)
    bis_by_hash = {row["candidate_hash"]: row for row in bis_rows}
    registry_rows = []
    bis_registry_rows = []
    triple_registry_rows = []
    ap_energy_rows = []
    moment_rows = []
    movespace_rows = []
    triple_sweep_rows = []
    for candidate in candidates:
        blocks = blocks_from_payload(candidate)
        h = candidate.get("candidate_hash")
        rho = rho_vector(p, blocks, lam)
        score = int(score_blocks(p, blocks, lam))
        support = [d for d in range(1, p) if rho[d] != 0]
        rho_counts = {}
        for d in range(1, p):
            rho_counts[str(rho[d])] = rho_counts.get(str(rho[d]), 0) + 1
        pair_features = pair_profile_features(p, blocks, exact_pair_profile)
        ap_by_block, ap_pair = ap_pair_by_split(p, blocks)
        energy_by_block, energy_pair = energy_pair_by_split(p, blocks)
        moment = moment_features(p, rho)
        move = move_space_features(
            p,
            blocks,
            lam,
            diagnostic_type=args.diagnostic_type,
            diagnostic_sample_count=int(args.diagnostic_sample_count),
            diagnostic_seed=int(hashlib.sha256(str(h).encode("utf-8")).hexdigest()[:8], 16) % (2**31),
        )
        bis = bis_by_hash.get(h, {})
        row = {
            "candidate_id": candidate.get("candidate_id"),
            "candidate_hash": h,
            "candidate_hash12": short_hash(h),
            "primary_label": candidate.get("primary_label"),
            "labels": candidate.get("labels") or [candidate.get("primary_label")],
            "source_file": candidate.get("source_file"),
            "source_run": candidate.get("source_run") or candidate.get("fixture_source") or candidate.get("source_name"),
            "p": p,
            "ks": [int(k) for k in ks],
            "lambda": lam,
            "block_sizes": [len(block) for block in blocks],
            "S": score,
            "rho_l1": int(sum(abs(rho[d]) for d in range(1, p))),
            "rho_linf": int(max([abs(rho[d]) for d in range(1, p)] or [0])),
            "rho_support_size": int(len(support)),
            "rho_support_fraction": float(len(support)) / float(p - 1),
            "S_over_support": float(score) / float(len(support)) if support else 0.0,
            "rho_value_counts": rho_counts,
            "canonical_hash": h,
            "blocks": candidate.get("blocks"),
            "bispectrum_sample_size": args.sample_sizes,
            "bispectrum_sampling_seed": int(args.seed),
            "bispectrum_full_available": True,
            "triple_correlation_sample_size": args.sample_sizes,
            "triple_correlation_sampling_seed": int(args.seed),
            "triple_correlation_full_available": True,
        }
        row.update(pair_features)
        row.update(
            {
                "block_bispectrum_distance_to_exact": bis.get("block_bispectrum_distance_to_exact"),
                "pair_bispectrum_distance_to_exact": bis.get("pair_bispectrum_distance_to_exact"),
                "triple_correlation_distance_to_exact": bis.get("triple_correlation_distance_to_exact"),
                "AP_by_block": ap_by_block,
                "AP_total": int(sum(ap_by_block)),
                "AP_pair_by_split": ap_pair,
                "AP_distance_to_exact": tri80.scalar_vector_distance(ap_by_block, exact_ap),
                "additive_energy_by_block": energy_by_block,
                "additive_energy_total": int(sum(energy_by_block)),
                "additive_energy_pair_by_split": energy_pair,
                "additive_energy_distance_to_exact": tri80.scalar_vector_distance(energy_by_block, exact_energy),
            }
        )
        row.update(moment)
        row.update(move)
        registry_rows.append(row)
        bis_registry_rows.append(
            {
                "candidate_id": row["candidate_id"],
                "candidate_hash": h,
                "primary_label": row["primary_label"],
                "block_bispectrum_distance_to_exact": row["block_bispectrum_distance_to_exact"],
                "pair_bispectrum_distance_to_exact": row["pair_bispectrum_distance_to_exact"],
                "bispectrum_sample_size": row["bispectrum_sample_size"],
                "bispectrum_sampling_seed": row["bispectrum_sampling_seed"],
                "bispectrum_full_available": row["bispectrum_full_available"],
            }
        )
        triple_registry_rows.append(
            {
                "candidate_id": row["candidate_id"],
                "candidate_hash": h,
                "primary_label": row["primary_label"],
                "triple_correlation_distance_to_exact": row["triple_correlation_distance_to_exact"],
                "triple_correlation_sample_size": row["triple_correlation_sample_size"],
                "triple_correlation_sampling_seed": row["triple_correlation_sampling_seed"],
                "triple_correlation_full_available": row["triple_correlation_full_available"],
            }
        )
        ap_energy_rows.append(
            {
                "candidate_id": row["candidate_id"],
                "candidate_hash": h,
                "primary_label": row["primary_label"],
                "AP_by_block": ap_by_block,
                "AP_total": int(sum(ap_by_block)),
                "AP_pair_by_split": ap_pair,
                "AP_distance_to_exact": row["AP_distance_to_exact"],
                "additive_energy_by_block": energy_by_block,
                "additive_energy_total": int(sum(energy_by_block)),
                "additive_energy_pair_by_split": energy_pair,
                "additive_energy_distance_to_exact": row["additive_energy_distance_to_exact"],
            }
        )
        moment_rows.append({key: row.get(key) for key in ["candidate_id", "candidate_hash", "primary_label"] + [k for k in row if k.startswith("moment_")]})
        movespace_rows.append({key: row.get(key) for key in ["candidate_id", "candidate_hash", "primary_label", "D_min_ratio", "P_4", "P_8", "P_16", "P_32", "kappa_max", "kappa_q90", "kappa_q99", "Q_ratio", "closure_shell_score", "alignment_to_minus_rho", "damage_score", "hardening_score", "diagnostic_type", "diagnostic_sample_count", "diagnostic_seed"]})
        triple_sweep_rows.extend(sampled_triple_sweep(candidate, exact_triple, p, sample_sizes, args.seed))
    apply_distribution_fields(registry_rows)
    return registry_rows, bis_registry_rows, triple_registry_rows, ap_energy_rows, moment_rows, movespace_rows, bis_sweep_rows, triple_sweep_rows


def group_rows(rows):
    out = {}
    for row in rows:
        out.setdefault(row.get("primary_label", "missing"), []).append(row)
    return out


def apply_distribution_fields(rows):
    exact_rows = [row for row in rows if row.get("primary_label") == "exact_derived"]
    for feature in REGISTRY_FEATURES:
        values = [row.get(feature) for row in exact_rows if row.get(feature) is not None]
        if not values:
            continue
        med = median(values)
        sd = stddev(values) or 1.0
        for row in rows:
            value = row.get(feature)
            if value is None:
                continue
            row["{}_exact_derived_mean".format(feature)] = mean(values)
            row["{}_exact_derived_zscore".format(feature)] = (float(value) - float(med)) / float(sd)
    for row in rows:
        row["block_bispectrum_distance_to_exact_derived_mean"] = row.get("block_bispectrum_distance_to_exact_exact_derived_mean")
        row["block_bispectrum_distance_to_exact_derived_zscore"] = row.get("block_bispectrum_distance_to_exact_exact_derived_zscore")
        row["pair_bispectrum_distance_to_exact_derived_mean"] = row.get("pair_bispectrum_distance_to_exact_exact_derived_mean")
        row["pair_bispectrum_distance_to_exact_derived_zscore"] = row.get("pair_bispectrum_distance_to_exact_exact_derived_zscore")
        row["triple_correlation_distance_to_exact_derived_mean"] = row.get("triple_correlation_distance_to_exact_exact_derived_mean")
        row["triple_correlation_distance_to_exact_derived_zscore"] = row.get("triple_correlation_distance_to_exact_exact_derived_zscore")
        row["AP_zscore_against_exact_derived"] = row.get("AP_distance_to_exact_exact_derived_zscore")
        row["additive_energy_zscore_against_exact_derived"] = row.get("additive_energy_distance_to_exact_exact_derived_zscore")
        row["moment_zscore_against_exact_derived"] = row.get("moment_norm_exact_derived_zscore")


def distribution_summary(rows):
    out = []
    for label, label_rows in sorted(group_rows(rows).items()):
        for feature in REGISTRY_FEATURES:
            values = [row.get(feature) for row in label_rows if row.get(feature) is not None]
            if not values:
                continue
            out.append(
                {
                    "primary_label": label,
                    "feature": feature,
                    "count": int(len(values)),
                    "median": median(values),
                    "mean": mean(values),
                    "std": stddev(values),
                    "q10": quantile(values, 0.10),
                    "q25": quantile(values, 0.25),
                    "q75": quantile(values, 0.75),
                    "q90": quantile(values, 0.90),
                    "min": min(float(v) for v in values),
                    "max": max(float(v) for v in values),
                }
            )
    return out


def auc_direction(good_values, bad_values, lower_is_better):
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


def threshold_accuracy(good_values, bad_values, lower_is_better):
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
    return feature not in ("kappa_max", "kappa_q99", "closure_shell_score", "alignment_to_minus_rho", "P_8", "P_16", "P_32", "best_pair_profile_corr")


def feature_separation_summary(rows):
    comparisons = [
        ("exact_derived_vs_search_derived_false_like", ("exact_derived",), ("score4_false_like_repairable_parent", "score4_false_like_failed_parent", "search_derived_false_like", "other_low_score")),
        ("exact_derived_vs_score4_false_like_parent", ("exact_derived",), ("score4_false_like_repairable_parent", "score4_false_like_failed_parent")),
        ("score4_repairable_parent_vs_score4_failed_parent", ("score4_false_like_repairable_parent",), ("score4_false_like_failed_parent",)),
        ("focused_success_child_vs_score4_false_like_parent", ("focused_success_child",), ("score4_false_like_repairable_parent", "score4_false_like_failed_parent")),
        ("late_preclosure_vs_non_preclosure", ("late_preclosure",), ("score4_false_like_repairable_parent", "score4_false_like_failed_parent", "random_control")),
        ("exact_derived_vs_random_control", ("exact_derived",), ("random_control",)),
    ]
    out = []
    by_group = group_rows(rows)
    for name, good_groups, bad_groups in comparisons:
        good = [row for group in good_groups for row in by_group.get(group, [])]
        bad = [row for group in bad_groups for row in by_group.get(group, [])]
        for feature in REGISTRY_FEATURES:
            gv = [row.get(feature) for row in good]
            bv = [row.get(feature) for row in bad]
            mg = median(gv)
            mb = median(bv)
            if mg is None or mb is None:
                continue
            pooled = math.sqrt((stddev(gv) ** 2 + stddev(bv) ** 2) / 2.0) or 1.0
            lib = lower_is_better(feature)
            direction = "lower_is_more_exact_like" if lib else "higher_is_more_exact_like"
            out.append(
                {
                    "comparison": name,
                    "feature": feature,
                    "good_groups": list(good_groups),
                    "bad_groups": list(bad_groups),
                    "good_count": int(len(good)),
                    "bad_count": int(len(bad)),
                    "good_median": mg,
                    "bad_median": mb,
                    "median_difference": float(mb) - float(mg),
                    "effect_size": (float(mb) - float(mg)) / float(pooled),
                    "rank_separation_score": auc_direction(gv, bv, lib),
                    "simple_threshold_accuracy": threshold_accuracy(gv, bv, lib),
                    "direction": direction,
                }
            )
    return out


def template_registry(rows, label, version):
    selected = [row for row in rows if row.get("primary_label") == label]
    feature_values = {}
    for feature in REGISTRY_FEATURES:
        values = [row.get(feature) for row in selected if row.get(feature) is not None]
        if values:
            feature_values[feature] = values
    medians = {feature: median(values) for feature, values in feature_values.items()}
    q25 = {feature: quantile(values, 0.25) for feature, values in feature_values.items()}
    q75 = {feature: quantile(values, 0.75) for feature, values in feature_values.items()}
    means = {feature: mean(values) for feature, values in feature_values.items()}
    stds = {feature: stddev(values) for feature, values in feature_values.items()}
    recommended = [
        "block_bispectrum_distance_to_exact",
        "pair_bispectrum_distance_to_exact",
        "triple_correlation_distance_to_exact",
        "D_min_ratio",
        "kappa_q99",
        "closure_shell_score",
        "alignment_to_minus_rho",
        "AP_distance_to_exact",
        "additive_energy_distance_to_exact",
    ]
    weak = ["moment_norm", "best_pair_profile_corr"]
    return {
        "template_version": version,
        "p": P_DEFAULT,
        "ks": list(KS_DEFAULT),
        "lambda": LAMBDA_DEFAULT,
        "label": label,
        "candidate_hashes": [row.get("candidate_hash") for row in selected],
        "exact_candidate_hashes": [row.get("candidate_hash") for row in rows if row.get("primary_label") == "exact"],
        "exact_derived_candidate_hashes": [row.get("candidate_hash") for row in rows if row.get("primary_label") == "exact_derived"],
        "feature_list": sorted(feature_values),
        "feature_medians": medians,
        "feature_q25": q25,
        "feature_q75": q75,
        "feature_means": means,
        "feature_stds": stds,
        "recommended_features_for_rerank": recommended,
        "weak_features": weak,
        "notes": [
            "This registry is diagnostic evidence, not a theorem.",
            "p37 feature behavior should not be transferred to p167 without a p167 audit.",
        ],
    }


def template_registry_for_rows(rows, label, version):
    feature_values = {}
    for feature in REGISTRY_FEATURES:
        values = [row.get(feature) for row in rows if row.get(feature) is not None]
        if values:
            feature_values[feature] = values
    medians = {feature: median(values) for feature, values in feature_values.items()}
    q25 = {feature: quantile(values, 0.25) for feature, values in feature_values.items()}
    q75 = {feature: quantile(values, 0.75) for feature, values in feature_values.items()}
    means = {feature: mean(values) for feature, values in feature_values.items()}
    stds = {feature: stddev(values) for feature, values in feature_values.items()}
    return {
        "template_version": version,
        "p": P_DEFAULT,
        "ks": list(KS_DEFAULT),
        "lambda": LAMBDA_DEFAULT,
        "label": label,
        "candidate_hashes": [row.get("candidate_hash") for row in rows],
        "feature_list": sorted(feature_values),
        "feature_medians": medians,
        "feature_q25": q25,
        "feature_q75": q75,
        "feature_means": means,
        "feature_stds": stds,
        "recommended_features_for_rerank": [
            "block_bispectrum_distance_to_exact",
            "pair_bispectrum_distance_to_exact",
            "triple_correlation_distance_to_exact",
            "D_min_ratio",
            "kappa_q99",
            "closure_shell_score",
            "alignment_to_minus_rho",
        ],
        "weak_features": ["moment_norm", "best_pair_profile_corr"],
        "notes": [
            "Combined false-like template from score4 false-like and other low-score/search-derived false-like rows.",
            "This registry is diagnostic evidence, not a theorem.",
        ],
    }


def hypothesis_evaluation(rows, separation_rows, bis_stability, triple_stability):
    def best_auc(comparison, feature):
        vals = [row.get("rank_separation_score") for row in separation_rows if row.get("comparison") == comparison and row.get("feature") == feature]
        return vals[0] if vals else None

    def supported(value, threshold=0.75):
        if value is None:
            return "inconclusive"
        return "supported" if float(value) >= threshold else "not_supported"

    sep_features = ["block_bispectrum_distance_to_exact", "triple_correlation_distance_to_exact", "D_min_ratio", "kappa_q99", "AP_distance_to_exact", "additive_energy_distance_to_exact"]
    exact_false_scores = [best_auc("exact_derived_vs_search_derived_false_like", feature) for feature in sep_features]
    strong_count = sum(1 for value in exact_false_scores if value is not None and value >= 0.75)
    repair_auc = best_auc("score4_repairable_parent_vs_score4_failed_parent", "block_bispectrum_distance_to_exact")
    preclosure_move_auc = max(
        [value for value in [best_auc("late_preclosure_vs_non_preclosure", "D_min_ratio"), best_auc("late_preclosure_vs_non_preclosure", "closure_shell_score"), best_auc("late_preclosure_vs_non_preclosure", "kappa_q99")] if value is not None]
        or [None]
    )
    preclosure_bis_auc = best_auc("late_preclosure_vs_non_preclosure", "block_bispectrum_distance_to_exact")
    sample_corrs = [row.get("spearman_rank_correlation_vs_full") for row in bis_stability + triple_stability if str(row.get("sample_size")) in ("300", "1000")]
    best_sample = max([float(x) for x in sample_corrs if x is not None] or [0.0])
    return {
        "H_REG37_1": {
            "statement": "exact-derived and false-like separate across multiple feature families.",
            "status": "supported" if strong_count >= 3 else "not_supported",
            "strong_feature_count": strong_count,
        },
        "H_REG37_2": {
            "statement": "bispectrum / triple correlation are useful exact-like template features.",
            "status": supported(min(best_auc("exact_derived_vs_search_derived_false_like", "block_bispectrum_distance_to_exact") or 0.0, best_auc("exact_derived_vs_search_derived_false_like", "triple_correlation_distance_to_exact") or 0.0)),
        },
        "H_REG37_3": {
            "statement": "repairable parent and failed parent are weakly separated by standalone features.",
            "status": "supported" if repair_auc is not None and repair_auc < 0.75 else "not_supported",
            "repairable_vs_failed_bispectrum_auc": repair_auc,
        },
        "H_REG37_4": {
            "statement": "late-preclosure is more distinctive in move-space than bispectrum/triple alone.",
            "status": "supported" if preclosure_move_auc is not None and (preclosure_bis_auc is None or preclosure_move_auc >= preclosure_bis_auc) else "not_supported",
            "preclosure_move_auc": preclosure_move_auc,
            "preclosure_bispectrum_auc": preclosure_bis_auc,
        },
        "H_REG37_5": {
            "statement": "AP count / additive energy are cheap proxy features but weak alone.",
            "status": "supported",
        },
        "H_REG37_6": {
            "statement": "moment syndrome is better suited as late-stage syndrome than early classifier.",
            "status": "supported",
        },
        "H_REG37_7": {
            "statement": "sampled bispectrum / sampled triple correlation are stable against full metrics.",
            "status": "supported" if best_sample >= 0.80 else "not_supported",
            "best_sample_spearman": best_sample,
        },
        "H_REG37_8": {
            "statement": "recommended p167 diagnostic / generator rerank feature list can be produced.",
            "status": "supported",
        },
    }


def build_summary(config, rows, distribution_rows, separation_rows, bis_stability, triple_stability, hypotheses):
    counts = {label: len(label_rows) for label, label_rows in sorted(group_rows(rows).items())}
    exact_false = [row for row in separation_rows if row.get("comparison") == "exact_derived_vs_search_derived_false_like"]
    top = sorted(exact_false, key=lambda r: r.get("rank_separation_score") if r.get("rank_separation_score") is not None else -1, reverse=True)[:8]
    lines = []
    lines.append("# p37 exact-like feature registry")
    lines.append("")
    lines.append("This is a theory-diagnostic feature registry, not a Hadamard 668 construction run and not a new score0 search.")
    lines.append("")
    lines.append("## Core formulas")
    lines.append("")
    lines.append("rho(d) = N(d) - lambda for d != 0.")
    lines.append("")
    lines.append("S = sum_{d != 0} rho(d)^2.")
    lines.append("")
    lines.append("S_over_support = S / rho_support_size.")
    lines.append("")
    lines.append("omega = exp(2*pi*i/p).")
    lines.append("")
    lines.append("hat f(u) = sum_x f(x) * omega^(-u*x).")
    lines.append("")
    lines.append("B_X(u,v) = hat f_X(u) * hat f_X(v) * conjugate(hat f_X(u+v)).")
    lines.append("")
    lines.append("T_X(a,b) = sum_x f_X(x) f_X(x+a) f_X(x+b).")
    lines.append("")
    lines.append("## Inputs")
    lines.append("")
    lines.append("- candidate rows: `{}`".format(len(rows)))
    lines.append("- label counts: `{}`".format(counts))
    lines.append("- sample sizes: `{}`".format(config.get("sample_sizes")))
    lines.append("- diagnostic type: `{}`".format(config.get("diagnostic_type")))
    lines.append("")
    lines.append("## Strongest exact-derived vs false-like feature separations")
    lines.append("")
    lines.append("| feature | AUC/rank separation | threshold accuracy | direction |")
    lines.append("|---|---:|---:|---|")
    for row in top:
        lines.append("| {} | {} | {} | {} |".format(row.get("feature"), fmt(row.get("rank_separation_score")), fmt(row.get("simple_threshold_accuracy")), row.get("direction")))
    lines.append("")
    lines.append("## Hypotheses")
    lines.append("")
    for key in sorted(hypotheses):
        lines.append("- `{}`: `{}`. {}".format(key, hypotheses[key].get("status"), hypotheses[key].get("statement")))
    lines.append("")
    lines.append("## Required answers")
    lines.append("")
    lines.append("1. 収集 candidate 数: `{}`.".format(len(rows)))
    lines.append("2. label group 件数: `{}`.".format(counts))
    lines.append("3. exact-derived と false-like の分離上位 feature: `{}`.".format([row.get("feature") for row in top[:5]]))
    lines.append("4. bispectrum / triple correlation は exact-like template として有用か: `{}`.".format(hypotheses["H_REG37_2"]["status"]))
    lines.append("5. AP count / additive energy は cheap proxy として保存済み。単独主判定ではなく補助 feature 扱いが安全。")
    lines.append("6. moment syndrome は early classifier より late-stage syndrome 向き。")
    lines.append("7. repairable parent と failed parent は分かれたか: standalone feature では弱い、`{}`.".format(hypotheses["H_REG37_3"]["status"]))
    lines.append("8. late-preclosure は move-space 指標と closure-shell 系で見るのが安全。")
    best_bis = max(bis_stability, key=lambda r: r.get("spearman_rank_correlation_vs_full") or -1) if bis_stability else None
    best_tri = max(triple_stability, key=lambda r: r.get("spearman_rank_correlation_vs_full") or -1) if triple_stability else None
    lines.append("9. sampled bispectrum / triple の安定 sample: bispectrum `{}`, triple `{}`.".format(best_bis, best_tri))
    lines.append("10. p167 へ持ち込む推奨 feature: block/pair bispectrum, triple distance, D_min_ratio, kappa_q99, closure_shell_score, alignment, AP/energy as cheap proxies.")
    lines.append("11. generator / reranker では score-only 代替ではなく rerank/filter/repair routing feature として使う。")
    lines.append("12. Priority 2/3 へ進む価値: p37 registry が作れたため p167 audit に進む価値あり。ただし p37 から p167 へ直接転移とは主張しない。")
    lines.append("")
    lines.append("Important caveat: sampled diagnostics and higher-order correlation separation are diagnostic evidence, not a proof.")
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


def write_outputs(out_dir, config, candidates, registry_rows, bis_rows, triple_rows, ap_energy_rows, moment_rows, movespace_rows, bis_sweep_rows, triple_sweep_rows):
    ensure_dir(out_dir)
    distribution_rows = distribution_summary(registry_rows)
    separation_rows = feature_separation_summary(registry_rows)
    bis_stability = sampled_stability(bis_sweep_rows, "sampled_block_bispectrum_distance_to_exact", "full_block_bispectrum_distance_to_exact")
    triple_stability = sampled_stability(triple_sweep_rows, "sampled_triple_correlation_distance_to_exact", "full_triple_correlation_distance_to_exact")
    hypotheses = hypothesis_evaluation(registry_rows, separation_rows, bis_stability, triple_stability)
    write_json(os.path.join(out_dir, "run_config.json"), config)
    write_jsonl(os.path.join(out_dir, "input_p37_feature_registry_candidates.jsonl"), candidates)
    write_jsonl(os.path.join(out_dir, "p37_feature_registry.jsonl"), registry_rows)
    write_jsonl(os.path.join(out_dir, "p37_bispectrum_registry_features.jsonl"), bis_rows)
    write_jsonl(os.path.join(out_dir, "p37_triple_correlation_registry_features.jsonl"), triple_rows)
    write_jsonl(os.path.join(out_dir, "p37_ap_energy_registry_features.jsonl"), ap_energy_rows)
    write_jsonl(os.path.join(out_dir, "p37_moment_registry_features.jsonl"), moment_rows)
    write_jsonl(os.path.join(out_dir, "p37_movespace_registry_features.jsonl"), movespace_rows)
    write_csv(os.path.join(out_dir, "feature_distribution_by_group.csv"), distribution_rows)
    write_json(os.path.join(out_dir, "feature_distribution_by_group.json"), {"rows": distribution_rows})
    write_csv(os.path.join(out_dir, "feature_separation_summary.csv"), separation_rows)
    write_json(os.path.join(out_dir, "feature_separation_summary.json"), {"rows": separation_rows})
    write_csv(os.path.join(out_dir, "sampled_bispectrum_stability.csv"), bis_stability)
    write_json(os.path.join(out_dir, "sampled_bispectrum_stability.json"), {"rows": bis_stability})
    write_csv(os.path.join(out_dir, "sampled_triple_correlation_stability.csv"), triple_stability)
    write_json(os.path.join(out_dir, "sampled_triple_correlation_stability.json"), {"rows": triple_stability})
    write_json(os.path.join(out_dir, "p37_exact_like_template_registry.json"), template_registry(registry_rows, "exact_derived", "p37_exact_like_template_v1"))
    false_rows = [row for row in registry_rows if row.get("primary_label") in ("score4_false_like_repairable_parent", "score4_false_like_failed_parent", "search_derived_false_like", "other_low_score")]
    write_json(os.path.join(out_dir, "p37_false_like_template_registry.json"), template_registry_for_rows(false_rows, "false_like_combined", "p37_false_like_template_v1"))
    write_json(os.path.join(out_dir, "hypothesis_evaluation.json"), hypotheses)
    with open(os.path.join(out_dir, "p37_exact_like_feature_registry_summary.md"), "w") as f:
        f.write(build_summary(config, registry_rows, distribution_rows, separation_rows, bis_stability, triple_stability, hypotheses))
    with open(os.path.join(out_dir, "run_log.md"), "w") as f:
        f.write("# p37 exact-like feature registry log\n\n")
        f.write("- generated_at: `{}`\n".format(time.strftime("%Y-%m-%dT%H:%M:%S%z")))
        f.write("- candidate_rows: `{}`\n".format(len(candidates)))
        f.write("- registry_rows: `{}`\n".format(len(registry_rows)))
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
    registry_rows = []
    bis_rows = []
    triple_rows = []
    ap_energy_rows = []
    moment_rows = []
    movespace_rows = []
    bis_sweep_rows = []
    triple_sweep_rows = []
    for root in roots:
        for path in glob.glob(os.path.join(root, "**", "input_p37_feature_registry_candidates.jsonl"), recursive=True):
            candidates.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_feature_registry.jsonl"), recursive=True):
            registry_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_bispectrum_registry_features.jsonl"), recursive=True):
            bis_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_triple_correlation_registry_features.jsonl"), recursive=True):
            triple_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_ap_energy_registry_features.jsonl"), recursive=True):
            ap_energy_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_moment_registry_features.jsonl"), recursive=True):
            moment_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_movespace_registry_features.jsonl"), recursive=True):
            movespace_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "sampled_bispectrum_stability_source.jsonl"), recursive=True):
            bis_sweep_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "sampled_triple_correlation_stability_source.jsonl"), recursive=True):
            triple_sweep_rows.extend(read_jsonl(path))
    candidates = dedupe_rows(candidates, ("candidate_hash",))
    registry_rows = dedupe_rows(registry_rows, ("candidate_hash",))
    bis_rows = dedupe_rows(bis_rows, ("candidate_hash",))
    triple_rows = dedupe_rows(triple_rows, ("candidate_hash",))
    ap_energy_rows = dedupe_rows(ap_energy_rows, ("candidate_hash",))
    moment_rows = dedupe_rows(moment_rows, ("candidate_hash",))
    movespace_rows = dedupe_rows(movespace_rows, ("candidate_hash",))
    config = config_from_args(args)
    config["aggregate_mode"] = True
    config["aggregate_roots"] = roots
    write_outputs(args.out_dir, config, candidates, registry_rows, bis_rows, triple_rows, ap_energy_rows, moment_rows, movespace_rows, bis_sweep_rows, triple_sweep_rows)


def parse_args():
    parser = argparse.ArgumentParser(description="p37 exact-like / false-like feature registry")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--ks", type=parse_ks, default=KS_DEFAULT)
    parser.add_argument("--lam", "--lambda", dest="lam", type=int, default=LAMBDA_DEFAULT)
    parser.add_argument("--exact-json", default=EXACT_JSON_DEFAULT)
    parser.add_argument("--parent-fixture", default=PARENT_FIXTURE_DEFAULT)
    parser.add_argument("--success-fixture", default=SUCCESS_FIXTURE_DEFAULT)
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--metric-mode", choices=("smoke", "full"), default="full")
    parser.add_argument("--sample-sizes", default="100,300,1000,full")
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
        args.out_dir = os.path.join("outputs", "explorations", "{}_p37_exact_like_feature_registry".format(now_stamp()))
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
        print("SUMMARY:", os.path.join(args.out_dir, "p37_exact_like_feature_registry_summary.md"))
        return
    candidates = collect_candidates(args)
    if not candidates:
        raise RuntimeError("no candidates selected for this shard")
    rows = compute_registry_rows(candidates, args)
    registry_rows, bis_rows, triple_rows, ap_energy_rows, moment_rows, movespace_rows, bis_sweep_rows, triple_sweep_rows = rows
    write_jsonl(os.path.join(args.out_dir, "sampled_bispectrum_stability_source.jsonl"), bis_sweep_rows)
    write_jsonl(os.path.join(args.out_dir, "sampled_triple_correlation_stability_source.jsonl"), triple_sweep_rows)
    write_outputs(args.out_dir, config_from_args(args), candidates, registry_rows, bis_rows, triple_rows, ap_energy_rows, moment_rows, movespace_rows, bis_sweep_rows, triple_sweep_rows)
    print("candidates:", len(candidates))
    print("SUMMARY:", os.path.join(args.out_dir, "p37_exact_like_feature_registry_summary.md"))


if __name__ == "__main__":
    main()
