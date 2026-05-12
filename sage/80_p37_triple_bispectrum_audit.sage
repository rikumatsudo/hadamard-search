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


SCRIPT_NAME = "80_p37_triple_bispectrum_audit"
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
LOW_SCORE_SET = set([4, 8, 12, 16, 24, 32])


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
        return int(value)
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


def read_json(path):
    with open(path) as f:
        return json.load(f)


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


def parse_ks(text):
    if isinstance(text, (list, tuple)):
        values = tuple(int(x) for x in text)
    else:
        values = tuple(int(part.strip()) for part in str(text).replace("[", "").replace("]", "").split(",") if part.strip())
    if len(values) != 4:
        raise argparse.ArgumentTypeError("--ks must contain exactly four integers")
    return values


def parse_sample_sizes(text):
    out = []
    for part in str(text).split(","):
        part = part.strip()
        if not part:
            continue
        if part.lower() == "full":
            out.append("full")
        else:
            out.append(int(part))
    return out or [100, 300, 1000, "full"]


def short_hash(text):
    return str(text or "")[:12]


def has_prefix(value, prefixes):
    value = str(value or "")
    return any(value.startswith(prefix) for prefix in prefixes)


def normalize_blocks(raw_blocks):
    return [set(int(x) for x in block) for block in raw_blocks]


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


def blocks_from_payload(payload):
    raw = payload.get("blocks") or payload.get("X") or payload.get("sets")
    if not isinstance(raw, list) or len(raw) != 4:
        return None
    try:
        return normalize_blocks(raw)
    except Exception:
        return None


def score_blocks(p, blocks, lam):
    counts = total_diff_counts(int(p), blocks)
    return int(sum((int(counts[d]) - int(lam)) ** 2 for d in range(1, int(p))))


def rho_vector(p, blocks, lam):
    counts = total_diff_counts(int(p), blocks)
    return [0] + [int(counts[d]) - int(lam) for d in range(1, int(p))]


def candidate_hash(blocks, ks, p):
    return canonical_hash(blocks, ks, p)


def add_candidate(rows, seen, payload, group, source_name, p, ks, lam):
    blocks = blocks_from_payload(payload)
    if not validate_blocks(blocks, p, ks):
        return False
    score = score_blocks(p, blocks, lam)
    h = payload.get("canonical_hash") or payload.get("candidate_hash") or candidate_hash(blocks, ks, p)
    candidate_id = payload.get("candidate_id") or "{}_{}_{}".format(short_hash(h), group, len(rows))
    key = "{}:{}".format(group, h)
    if key in seen:
        return False
    seen.add(key)
    row = dict(payload)
    row.update(
        {
            "candidate_id": candidate_id,
            "candidate_hash": h,
            "canonical_hash": h,
            "candidate_group": group,
            "p": int(p),
            "v": int(p),
            "n": int(4 * p),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "score": int(score),
            "S": int(score),
            "blocks": json_blocks(blocks),
            "source_name": source_name,
        }
    )
    rows.append(row)
    return True


def load_exact_candidate(path, p, ks, lam):
    payload = read_json(path)
    blocks = blocks_from_payload(payload)
    if not validate_blocks(blocks, p, ks):
        raise RuntimeError("exact candidate blocks are invalid")
    if score_blocks(p, blocks, lam) != 0:
        raise RuntimeError("exact candidate does not have score 0")
    return payload


def translate_blocks(blocks, shifts, p):
    return [set((int(x) + int(shifts[idx])) % int(p) for x in block) for idx, block in enumerate(blocks)]


def multiply_blocks(blocks, multiplier, p):
    return [set((int(multiplier) * int(x)) % int(p) for x in block) for block in blocks]


def one_swap(blocks, rng, p):
    out = [set(block) for block in blocks]
    idx = rng.randrange(len(out))
    removed = rng.choice(sorted(out[idx]))
    available = sorted(set(range(int(p))) - out[idx])
    added = rng.choice(available)
    out[idx].remove(removed)
    out[idx].add(added)
    return out


def generate_exact_derived(exact_payload, count, p, ks, lam, rng_seed):
    rng = random.Random(int(rng_seed))
    exact_blocks = blocks_from_payload(exact_payload)
    rows = []
    seen = set()
    for idx in range(max(2, min(count, 8))):
        shifts = [(idx * 3 + j * 5) % int(p) for j in range(4)]
        blocks = translate_blocks(exact_blocks, shifts, p)
        payload = {
            "blocks": json_blocks(blocks),
            "canonical_hash": candidate_hash(blocks, ks, p),
            "candidate_id": "exact_derived_translate_{}".format(idx),
            "origin": "exact_derived_translation",
        }
        add_candidate(rows, seen, payload, "exact_derived", "generated_exact_translations", p, ks, lam)
    attempts = 0
    while len(rows) < int(count) and attempts < int(count) * 400:
        attempts += 1
        blocks = one_swap(exact_blocks, rng, p)
        score = score_blocks(p, blocks, lam)
        if score not in LOW_SCORE_SET and score > 32:
            continue
        payload = {
            "blocks": json_blocks(blocks),
            "canonical_hash": candidate_hash(blocks, ks, p),
            "candidate_id": "exact_derived_swap_{}".format(attempts),
            "origin": "exact_derived_one_swap",
            "score": score,
        }
        add_candidate(rows, seen, payload, "exact_derived", "generated_exact_perturbations", p, ks, lam)
    return rows


def generate_random_controls(count, p, ks, lam, rng_seed):
    rng = random.Random(int(int(rng_seed) + 9173))
    rows = []
    seen = set()
    universe = list(range(int(p)))
    for idx in range(int(count)):
        blocks = [set(rng.sample(universe, int(k))) for k in ks]
        payload = {
            "blocks": json_blocks(blocks),
            "canonical_hash": candidate_hash(blocks, ks, p),
            "candidate_id": "random_control_{}".format(idx),
            "origin": "deterministic_random_control",
        }
        add_candidate(rows, seen, payload, "random_control", "generated_random_controls", p, ks, lam)
    return rows


def collect_candidates(args):
    p = int(args.p)
    ks = tuple(int(x) for x in args.ks)
    lam = int(args.lam)
    rows = []
    seen = set()
    exact = load_exact_candidate(args.exact_json, p, ks, lam)
    add_candidate(rows, seen, exact, "exact", "known_exact_json", p, ks, lam)
    for row in generate_exact_derived(exact, args.exact_derived_count, p, ks, lam, args.seed):
        add_candidate(rows, seen, row, row["candidate_group"], row.get("source_name", "generated_exact_derived"), p, ks, lam)
    for payload in read_jsonl(args.parent_fixture):
        h = payload.get("canonical_hash") or payload.get("candidate_hash")
        group = "score4_false_like_repairable_parent" if has_prefix(h, REPAIRABLE_PARENT_PREFIXES) else "score4_false_like_failed_parent"
        add_candidate(rows, seen, payload, group, "p37_focused_parent_fixture", p, ks, lam)
    for payload in read_jsonl(args.success_fixture):
        group = payload.get("candidate_group") or "ambiguous"
        add_candidate(rows, seen, payload, group, "p37_focused_success_preclosure_fixture", p, ks, lam)
    for row in generate_random_controls(args.random_control_count, p, ks, lam, args.seed):
        add_candidate(rows, seen, row, row["candidate_group"], "generated_random_controls", p, ks, lam)
    rows = sorted(rows, key=lambda r: (str(r.get("candidate_group")), int(r.get("score", 999999)), str(r.get("candidate_hash"))))
    if int(args.max_candidates) > 0:
        rows = rows[: int(args.max_candidates)]
    if int(args.shard_count) > 1:
        rows = [row for idx, row in enumerate(rows) if idx % int(args.shard_count) == int(args.shard_index)]
    if int(args.max_tasks) > 0:
        rows = rows[: int(args.max_tasks)]
    return rows


def fourier_values(p, block):
    p = int(p)
    block = set(int(x) % p for x in block)
    omega = complex(math.cos(2.0 * math.pi / p), math.sin(2.0 * math.pi / p))
    values = []
    for u in range(p):
        total = 0.0 + 0.0j
        for x in block:
            total += omega ** (-(u * x) % p)
        values.append(total)
    return values


def bispectrum_pairs(p):
    return [(u, v) for u in range(1, int(p)) for v in range(1, int(p)) if (u + v) % int(p) != 0]


def normalized(z, eps=1.0e-12):
    mag = abs(z)
    if mag <= eps:
        return 0.0 + 0.0j
    return z / mag


def block_bispectrum_vectors(p, blocks, pairs=None, normalized_phase=True):
    p = int(p)
    pairs = pairs or bispectrum_pairs(p)
    out = []
    for block in blocks:
        hat = fourier_values(p, block)
        vec = []
        for u, v in pairs:
            z = hat[u] * hat[v] * hat[(u + v) % p].conjugate()
            vec.append(normalized(z) if normalized_phase else z)
        out.append(vec)
    return out


def pair_signal_bispectrum_vectors(p, blocks, pairs=None):
    p = int(p)
    pairs = pairs or bispectrum_pairs(p)
    hats = [fourier_values(p, block) for block in blocks]
    out = {}
    for name, left, right in SPLITS:
        split_vec = []
        for side in (left, right):
            vec = []
            for u, v in pairs:
                hu = sum(hats[idx][u] for idx in side)
                hv = sum(hats[idx][v] for idx in side)
                huv = sum(hats[idx][(u + v) % p] for idx in side)
                vec.append(normalized(hu * hv * huv.conjugate()))
            split_vec.extend(vec)
        out[name] = split_vec
    return out


def pair_sum_vectors(block_vecs):
    out = {}
    for name, left, right in SPLITS:
        split_vec = []
        for side in (left, right):
            for j in range(len(block_vecs[0])):
                split_vec.append(sum(block_vecs[idx][j] for idx in side))
        out[name] = split_vec
    return out


def triple_correlation_vectors(p, blocks):
    p = int(p)
    out = []
    for block in blocks:
        s = set(int(x) % p for x in block)
        vec = []
        for a in range(p):
            for b in range(p):
                count = 0
                for x in s:
                    if (x + a) % p in s and (x + b) % p in s:
                        count += 1
                vec.append(count)
        out.append(vec)
    return out


def per_block_diff_counts(p, blocks):
    out = []
    for block in blocks:
        counts = [0] * int(p)
        for x in block:
            for y in block:
                if x != y:
                    counts[(int(x) - int(y)) % int(p)] += 1
        out.append(counts)
    return out


def pair_profile_vectors(p, blocks):
    per_counts = per_block_diff_counts(p, blocks)
    out = {}
    for name, left, right in SPLITS:
        vec = []
        for side in (left, right):
            for d in range(1, int(p)):
                vec.append(sum(per_counts[idx][d] for idx in side))
        out[name] = vec
    return out


def ap_count(p, block):
    p = int(p)
    s = set(int(x) % p for x in block)
    count = 0
    for z in range(p):
        for d in range(p):
            if (z - d) % p in s and z in s and (z + d) % p in s:
                count += 1
    return int(count)


def additive_energy_from_counts(counts):
    return int(sum(int(x) * int(x) for x in counts))


def rms_distance(xs, ys):
    n = min(len(xs), len(ys))
    if n == 0:
        return None
    total = 0.0
    for x, y in zip(xs[:n], ys[:n]):
        total += abs(x - y) ** 2
    return math.sqrt(total / float(n))


def nested_rms_distance(xs, ys):
    vals = []
    for a, b in zip(xs, ys):
        value = rms_distance(a, b)
        if value is not None:
            vals.append(value)
    return math.sqrt(sum(v * v for v in vals) / float(len(vals))) if vals else None


def sign_insensitive_nested_distance(xs, ys):
    vals = []
    for a, b in zip(xs, ys):
        d1 = rms_distance(a, b)
        d2 = rms_distance(a, [-z for z in b])
        vals.append(min(d1, d2))
    return math.sqrt(sum(v * v for v in vals) / float(len(vals))) if vals else None


def scalar_vector_distance(xs, ys):
    n = min(len(xs), len(ys))
    if n == 0:
        return None
    total = sum((float(x) - float(y)) ** 2 for x, y in zip(xs[:n], ys[:n]))
    return math.sqrt(total / float(n))


def flatten_nested(rows):
    out = []
    for row in rows:
        out.extend(row)
    return out


def choose_sample_indices(total, sample_size, seed_text):
    if sample_size == "full" or int(sample_size) >= int(total):
        return list(range(int(total)))
    rng = random.Random(int(hashlib.sha256(str(seed_text).encode("utf-8")).hexdigest()[:12], 16))
    return sorted(rng.sample(list(range(int(total))), int(sample_size)))


def subset_nested(vecs, indices):
    return [[vec[idx] for idx in indices] for vec in vecs]


def rank_values(values, higher_better=False):
    order = sorted(range(len(values)), key=lambda idx: values[idx], reverse=bool(higher_better))
    ranks = [0] * len(values)
    for rank, idx in enumerate(order, start=1):
        ranks[idx] = rank
    return ranks


def spearman(xs, ys):
    pairs = [(float(x), float(y)) for x, y in zip(xs, ys) if x is not None and y is not None]
    if len(pairs) < 3:
        return None
    rx = rank_values([x for x, _y in pairs])
    ry = rank_values([y for _x, y in pairs])
    mx = mean(rx)
    my = mean(ry)
    num = sum((x - mx) * (y - my) for x, y in zip(rx, ry))
    denx = math.sqrt(sum((x - mx) ** 2 for x in rx))
    deny = math.sqrt(sum((y - my) ** 2 for y in ry))
    if denx == 0.0 or deny == 0.0:
        return None
    return float(num) / float(denx * deny)


def compute_feature_rows(candidates, args):
    p = int(args.p)
    ks = tuple(int(x) for x in args.ks)
    lam = int(args.lam)
    sample_sizes = parse_sample_sizes(args.sample_sizes)
    pairs = bispectrum_pairs(p)
    exact_blocks = blocks_from_payload(load_exact_candidate(args.exact_json, p, ks, lam))
    exact_block_bis = block_bispectrum_vectors(p, exact_blocks, pairs)
    exact_pair_sum = pair_sum_vectors(exact_block_bis)
    exact_pair_signal = pair_signal_bispectrum_vectors(p, exact_blocks, pairs)
    exact_triple = triple_correlation_vectors(p, exact_blocks)
    exact_pair_profile = pair_profile_vectors(p, exact_blocks)
    exact_counts = per_block_diff_counts(p, exact_blocks)
    exact_ap = [ap_count(p, block) for block in exact_blocks]
    exact_energy = [additive_energy_from_counts(counts) for counts in exact_counts]
    rows = []
    triple_rows = []
    ap_rows = []
    pair_rows = []
    sweep_rows = []
    bis_cache = {}
    for idx, candidate in enumerate(candidates):
        blocks = blocks_from_payload(candidate)
        h = candidate.get("candidate_hash") or candidate.get("canonical_hash") or candidate_hash(blocks, ks, p)
        cid = candidate.get("candidate_id") or "{}_{}".format(short_hash(h), idx)
        score = score_blocks(p, blocks, lam)
        block_bis = block_bispectrum_vectors(p, blocks, pairs)
        pair_sum = pair_sum_vectors(block_bis)
        pair_signal = pair_signal_bispectrum_vectors(p, blocks, pairs)
        triple = triple_correlation_vectors(p, blocks)
        pair_profile = pair_profile_vectors(p, blocks)
        counts = per_block_diff_counts(p, blocks)
        ap = [ap_count(p, block) for block in blocks]
        energy = [additive_energy_from_counts(c) for c in counts]
        block_dist = nested_rms_distance(block_bis, exact_block_bis)
        block_sign_dist = sign_insensitive_nested_distance(block_bis, exact_block_bis)
        min_mult = block_dist
        if args.multiplier_minimized:
            for mult in range(1, p):
                mblocks = multiply_blocks(blocks, mult, p)
                mbis = block_bispectrum_vectors(p, mblocks, pairs)
                dist = nested_rms_distance(mbis, exact_block_bis)
                if min_mult is None or dist < min_mult:
                    min_mult = dist
        split_pair_dist = {}
        split_pair_signal_dist = {}
        split_pair_profile_dist = {}
        for name, _left, _right in SPLITS:
            split_pair_dist[name] = rms_distance(pair_sum[name], exact_pair_sum[name])
            split_pair_signal_dist[name] = rms_distance(pair_signal[name], exact_pair_signal[name])
            split_pair_profile_dist[name] = scalar_vector_distance(pair_profile[name], exact_pair_profile[name])
        pair_bis_dist = mean(split_pair_dist.values())
        pair_signal_dist = mean(split_pair_signal_dist.values())
        pair_profile_dist = mean(split_pair_profile_dist.values())
        triple_dist = nested_rms_distance(triple, exact_triple)
        ap_dist = scalar_vector_distance(ap, exact_ap)
        energy_dist = scalar_vector_distance(energy, exact_energy)
        rho = rho_vector(p, blocks, lam)
        row = {
            "candidate_id": cid,
            "candidate_hash": h,
            "candidate_hash12": short_hash(h),
            "candidate_group": candidate.get("candidate_group", "ambiguous"),
            "source_name": candidate.get("source_name"),
            "score": int(score),
            "autocorrelation_score_S": int(score),
            "rho_support_size": int(sum(1 for d in range(1, p) if rho[d] != 0)),
            "block_bispectrum_distance_to_exact": block_dist,
            "block_bispectrum_distance_to_exact_sign_insensitive": block_sign_dist,
            "block_bispectrum_distance_to_exact_multiplier_min": min_mult,
            "pair_bispectrum_distance_to_exact": pair_bis_dist,
            "pair_signal_bispectrum_distance_to_exact": pair_signal_dist,
            "triple_correlation_distance_to_exact": triple_dist,
            "AP_distance_to_exact": ap_dist,
            "energy_distance_to_exact": energy_dist,
            "pair_profile_distance_to_exact": pair_profile_dist,
            "pair_profile_plus_bispectrum_distance": None if pair_profile_dist is None or pair_bis_dist is None else math.sqrt(pair_profile_dist * pair_profile_dist + pair_bis_dist * pair_bis_dist),
            "AP_total": int(sum(ap)),
            "energy_total": int(sum(energy)),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "p": int(p),
            "blocks": json_blocks(blocks),
        }
        rows.append(row)
        bis_cache[cid] = block_bis
        triple_rows.append({key: row.get(key) for key in ("candidate_id", "candidate_hash", "candidate_group", "score", "triple_correlation_distance_to_exact")})
        ap_rows.append({key: row.get(key) for key in ("candidate_id", "candidate_hash", "candidate_group", "score", "AP_total", "AP_distance_to_exact", "energy_total", "energy_distance_to_exact")})
        pair_row = {key: row.get(key) for key in ("candidate_id", "candidate_hash", "candidate_group", "score", "pair_bispectrum_distance_to_exact", "pair_signal_bispectrum_distance_to_exact", "pair_profile_distance_to_exact", "pair_profile_plus_bispectrum_distance")}
        for name in split_pair_dist:
            pair_row["{}_pair_bispectrum_distance".format(name)] = split_pair_dist[name]
            pair_row["{}_pair_signal_bispectrum_distance".format(name)] = split_pair_signal_dist[name]
            pair_row["{}_pair_profile_distance".format(name)] = split_pair_profile_dist[name]
        pair_rows.append(pair_row)
        for sample_size in sample_sizes:
            indices = choose_sample_indices(len(pairs), sample_size, "{}:{}:{}".format(h, sample_size, args.seed))
            sampled_candidate = subset_nested(block_bis, indices)
            sampled_exact = subset_nested(exact_block_bis, indices)
            sampled_dist = nested_rms_distance(sampled_candidate, sampled_exact)
            sweep_rows.append(
                {
                    "candidate_id": cid,
                    "candidate_hash": h,
                    "candidate_group": candidate.get("candidate_group", "ambiguous"),
                    "sample_size": "full" if sample_size == "full" or len(indices) == len(pairs) else int(sample_size),
                    "sampled_pair_count": int(len(indices)),
                    "full_pair_count": int(len(pairs)),
                    "sampled_block_bispectrum_distance_to_exact": sampled_dist,
                    "full_block_bispectrum_distance_to_exact": block_dist,
                    "abs_error_vs_full": abs(float(sampled_dist) - float(block_dist)) if sampled_dist is not None and block_dist is not None else None,
                }
            )
    apply_exact_derived_distribution_fields(rows)
    return rows, triple_rows, ap_rows, pair_rows, sweep_rows


def apply_exact_derived_distribution_fields(rows):
    exact_dists = [row.get("block_bispectrum_distance_to_exact") for row in rows if row.get("candidate_group") == "exact_derived" and row.get("block_bispectrum_distance_to_exact") is not None]
    if not exact_dists:
        return
    med = median(exact_dists)
    sd = stddev(exact_dists) or 1.0
    sorted_d = sorted(float(x) for x in exact_dists)
    for row in rows:
        value = row.get("block_bispectrum_distance_to_exact")
        if value is None:
            continue
        z = (float(value) - float(med)) / float(sd)
        rank = sum(1 for x in sorted_d if x <= float(value))
        row["distance_to_exact_derived_distribution"] = abs(z)
        row["zscore_against_exact_derived"] = z
        row["rank_within_exact_derived_template"] = float(rank) / float(len(sorted_d))


def rows_by_group(rows):
    out = {}
    for row in rows:
        out.setdefault(row.get("candidate_group", "missing"), []).append(row)
    return out


def group_summary(rows):
    out = []
    for group, group_rows in sorted(rows_by_group(rows).items()):
        out.append(
            {
                "candidate_group": group,
                "count": int(len(group_rows)),
                "score_median": median(row.get("score") for row in group_rows),
                "score_min": min(int(row.get("score", 999999)) for row in group_rows) if group_rows else None,
                "block_bispectrum_distance_median": median(row.get("block_bispectrum_distance_to_exact") for row in group_rows),
                "block_bispectrum_multiplier_min_median": median(row.get("block_bispectrum_distance_to_exact_multiplier_min") for row in group_rows),
                "pair_bispectrum_distance_median": median(row.get("pair_bispectrum_distance_to_exact") for row in group_rows),
                "triple_correlation_distance_median": median(row.get("triple_correlation_distance_to_exact") for row in group_rows),
                "pair_profile_distance_median": median(row.get("pair_profile_distance_to_exact") for row in group_rows),
                "AP_distance_median": median(row.get("AP_distance_to_exact") for row in group_rows),
                "energy_distance_median": median(row.get("energy_distance_to_exact") for row in group_rows),
            }
        )
    return out


def select_groups(rows, groups):
    groups = set(groups)
    return [row for row in rows if row.get("candidate_group") in groups]


def auc_lower(good_values, bad_values):
    good_values = [float(x) for x in good_values if x is not None]
    bad_values = [float(x) for x in bad_values if x is not None]
    if not good_values or not bad_values:
        return None
    wins = 0.0
    total = 0.0
    for a in good_values:
        for b in bad_values:
            total += 1.0
            if a < b:
                wins += 1.0
            elif a == b:
                wins += 0.5
    return wins / total if total else None


def threshold_accuracy(good_values, bad_values):
    good_values = [float(x) for x in good_values if x is not None]
    bad_values = [float(x) for x in bad_values if x is not None]
    if not good_values or not bad_values:
        return None
    threshold = (median(good_values) + median(bad_values)) / 2.0
    correct = sum(1 for x in good_values if x <= threshold) + sum(1 for x in bad_values if x > threshold)
    return float(correct) / float(len(good_values) + len(bad_values))


def comparison_summary(rows, name, good_groups, bad_groups, metric):
    good = select_groups(rows, good_groups)
    bad = select_groups(rows, bad_groups)
    gv = [row.get(metric) for row in good]
    bv = [row.get(metric) for row in bad]
    mg = median(gv)
    mb = median(bv)
    pooled = math.sqrt((stddev(gv) ** 2 + stddev(bv) ** 2) / 2.0) or 1.0
    return {
        "comparison": name,
        "metric": metric,
        "lower_is_more_exact_like": True,
        "good_groups": list(good_groups),
        "bad_groups": list(bad_groups),
        "good_count": int(len(good)),
        "bad_count": int(len(bad)),
        "good_median": mg,
        "bad_median": mb,
        "effect_size": None if mg is None or mb is None else (float(mb) - float(mg)) / float(pooled),
        "simple_threshold_accuracy": threshold_accuracy(gv, bv),
        "rank_separation_score": auc_lower(gv, bv),
    }


def build_distance_summaries(rows):
    exact_like = ("exact", "exact_derived", "focused_success_child")
    false_like = ("score4_false_like_repairable_parent", "score4_false_like_failed_parent")
    comparisons = [
        ("exact_derived_vs_search_derived_false_like", ("exact_derived",), false_like),
        ("repairable_parent_vs_failed_parent", ("score4_false_like_repairable_parent",), ("score4_false_like_failed_parent",)),
        ("focused_success_child_vs_false_like_parent", ("focused_success_child",), false_like),
        ("late_preclosure_vs_false_like_parent", ("late_preclosure",), false_like),
        ("exact_like_vs_false_like", exact_like, false_like),
    ]
    bis = [comparison_summary(rows, name, good, bad, "block_bispectrum_distance_to_exact") for name, good, bad in comparisons]
    tri = [comparison_summary(rows, name, good, bad, "triple_correlation_distance_to_exact") for name, good, bad in comparisons]
    pair = [comparison_summary(rows, name, good, bad, "pair_bispectrum_distance_to_exact") for name, good, bad in comparisons]
    pair_profile = [comparison_summary(rows, name, good, bad, "pair_profile_distance_to_exact") for name, good, bad in comparisons]
    pair_combo = [comparison_summary(rows, name, good, bad, "pair_profile_plus_bispectrum_distance") for name, good, bad in comparisons]
    return bis, tri, pair, pair_profile, pair_combo


def sampled_sweep_summary(sweep_rows):
    out = []
    by_size = {}
    for row in sweep_rows:
        by_size.setdefault(str(row.get("sample_size")), []).append(row)
    for size, rows in sorted(by_size.items(), key=lambda item: (item[0] == "full", int(item[0]) if item[0].isdigit() else 10**9)):
        sampled = [row.get("sampled_block_bispectrum_distance_to_exact") for row in rows]
        full = [row.get("full_block_bispectrum_distance_to_exact") for row in rows]
        out.append(
            {
                "sample_size": size,
                "row_count": int(len(rows)),
                "median_abs_error_vs_full": median(row.get("abs_error_vs_full") for row in rows),
                "mean_abs_error_vs_full": mean(row.get("abs_error_vs_full") for row in rows),
                "spearman_rank_correlation_vs_full": spearman(sampled, full),
            }
        )
    return out


def hypothesis_evaluation(rows, bis_summary, tri_summary, pair_profile_summary, pair_combo_summary, sweep_summary):
    def comp(rows, comparison, metric="rank_separation_score"):
        for row in rows:
            if row.get("comparison") == comparison:
                return row.get(metric)
        return None

    def status_direction(value, threshold=0.60):
        if value is None:
            return "inconclusive"
        return "supported" if float(value) >= float(threshold) else "not_supported"

    h1_auc = comp(bis_summary, "exact_derived_vs_search_derived_false_like")
    h2_auc = comp(bis_summary, "repairable_parent_vs_failed_parent")
    h3_auc = comp(bis_summary, "focused_success_child_vs_false_like_parent")
    h4_auc = comp(bis_summary, "late_preclosure_vs_false_like_parent")
    pair_auc = comp(pair_profile_summary, "exact_like_vs_false_like")
    combo_auc = comp(pair_combo_summary, "exact_like_vs_false_like")
    best_sample = None
    for row in sweep_summary:
        if row.get("sample_size") in ("300", "1000"):
            corr = row.get("spearman_rank_correlation_vs_full")
            if corr is not None and (best_sample is None or corr > best_sample):
                best_sample = corr
    false_like_rows = select_groups(rows, ("score4_false_like_repairable_parent", "score4_false_like_failed_parent"))
    exact_rows = select_groups(rows, ("exact_derived",))
    false_score_low = bool(false_like_rows) and median(row.get("score") for row in false_like_rows) <= 4
    false_bis_far = h1_auc is not None and h1_auc >= 0.60
    return {
        "H_TRI37_1": {
            "statement": "p37 score=4 false basin is farther from exact-derived in bispectrum.",
            "status": status_direction(h1_auc),
            "rank_separation_score": h1_auc,
        },
        "H_TRI37_2": {
            "statement": "repairable score4 parents are more exact-like than failed score4 parents in higher-order features.",
            "status": status_direction(h2_auc),
            "rank_separation_score": h2_auc,
        },
        "H_TRI37_3": {
            "statement": "focused success score0 children are close to the known exact template under bispectrum/triple features.",
            "status": status_direction(h3_auc),
            "rank_separation_score": h3_auc,
        },
        "H_TRI37_4": {
            "statement": "late preclosure states are distinctive in bispectrum/triple correlation, not only score.",
            "status": status_direction(h4_auc),
            "rank_separation_score": h4_auc,
        },
        "H_TRI37_5": {
            "statement": "pair-level profile plus bispectrum improves exact/false separation over pair profile alone.",
            "status": "supported" if pair_auc is not None and combo_auc is not None and combo_auc > pair_auc else "not_supported" if pair_auc is not None and combo_auc is not None else "inconclusive",
            "pair_profile_auc": pair_auc,
            "pair_profile_plus_bispectrum_auc": combo_auc,
        },
        "H_TRI37_6": {
            "statement": "score4 false basin is autocorrelation-near but bispectrum-far.",
            "status": "supported" if false_score_low and false_bis_far else "not_supported" if false_like_rows and exact_rows else "inconclusive",
            "false_like_median_score": median(row.get("score") for row in false_like_rows),
            "bispectrum_separation_auc": h1_auc,
        },
        "H_TRI37_7": {
            "statement": "sampled bispectrum agrees sufficiently with full bispectrum ranking.",
            "status": "supported" if best_sample is not None and best_sample >= 0.80 else "not_supported" if best_sample is not None else "inconclusive",
            "best_spearman_for_300_or_1000": best_sample,
        },
    }


def project_rows(rows, fields):
    return [{field: row.get(field) for field in fields} for row in rows]


def build_summary_md(config, candidates, rows, group_rows, bis_summary, tri_summary, pair_summary, pair_profile_summary, pair_combo_summary, sweep_summary, hypotheses):
    group_count = {row["candidate_group"]: row["count"] for row in group_rows}
    lines = []
    lines.append("# p37 triple correlation / bispectrum audit")
    lines.append("")
    lines.append("This is a diagnostic run, not a Hadamard 668 construction run and not a new score0 search.")
    lines.append("")
    lines.append("## Fourier and correlation conventions")
    lines.append("")
    lines.append("G = Z_p, p = 37, ks = [13, 16, 18, 18], lambda = 28.")
    lines.append("")
    lines.append("n_X(d) = #{(x,y) in X^2 : x - y = d}.")
    lines.append("")
    lines.append("N(d) = n_X1(d) + n_X2(d) + n_X3(d) + n_X4(d).")
    lines.append("")
    lines.append("rho(d) = N(d) - lambda for d != 0.")
    lines.append("")
    lines.append("S = sum_{d != 0} rho(d)^2.")
    lines.append("")
    lines.append("omega = exp(2*pi*i/p).")
    lines.append("")
    lines.append("hat f(u) = sum_x f(x) * omega^(-u*x).")
    lines.append("")
    lines.append("With this convention, translation X -> X+t gives hat f_{X+t}(u) = omega^(-u*t) * hat f_X(u).")
    lines.append("")
    lines.append("For u != 0, SDS exact implies sum_i |hat f_i(u)|^2 = p.")
    lines.append("")
    lines.append("T_X(a,b) = sum_x f_X(x) f_X(x+a) f_X(x+b).")
    lines.append("")
    lines.append("B_X(u,v) = hat f_X(u) * hat f_X(v) * conjugate(hat f_X(u+v)).")
    lines.append("")
    lines.append("Normalized bispectrum phase is b_X(u,v) = B_X(u,v) / |B_X(u,v)| when nonzero.")
    lines.append("")
    lines.append("Bispectrum is translation-invariant because the translation phases cancel.")
    lines.append("")
    lines.append("## Inputs")
    lines.append("")
    lines.append("- candidate rows analyzed: `{}`".format(len(rows)))
    lines.append("- input rows before sharding/limits: `{}`".format(len(candidates)))
    lines.append("- group counts: `{}`".format(group_count))
    lines.append("- sample sizes: `{}`".format(config.get("sample_sizes")))
    lines.append("- multiplier-minimized distance enabled: `{}`".format(config.get("multiplier_minimized")))
    lines.append("")
    lines.append("## Group summary")
    lines.append("")
    lines.append("| group | count | median S | median block bispectrum distance | median triple distance | median pair bispectrum distance |")
    lines.append("|---|---:|---:|---:|---:|---:|")
    for row in group_rows:
        lines.append(
            "| {} | {} | {} | {} | {} | {} |".format(
                row.get("candidate_group"),
                row.get("count"),
                fmt(row.get("score_median")),
                fmt(row.get("block_bispectrum_distance_median")),
                fmt(row.get("triple_correlation_distance_median")),
                fmt(row.get("pair_bispectrum_distance_median")),
            )
        )
    lines.append("")
    lines.append("## Hypotheses")
    lines.append("")
    for key in sorted(hypotheses):
        row = hypotheses[key]
        lines.append("- `{}`: `{}`. {}".format(key, row.get("status"), row.get("statement")))
    lines.append("")
    lines.append("## Required answers")
    lines.append("")
    lines.append("1. p37 exact-derived と false-like は bispectrum で分かれたか: `{}`.".format(hypotheses["H_TRI37_1"]["status"]))
    lines.append("2. score4 false basin は autocorrelation-near but bispectrum-far と言えるか: `{}`.".format(hypotheses["H_TRI37_6"]["status"]))
    lines.append("3. repairable parent と failed parent は bispectrum / triple correlation で分かれたか: `{}`.".format(hypotheses["H_TRI37_2"]["status"]))
    lines.append("4. focused success child は known exact と bispectrum 的に近いか: `{}`.".format(hypotheses["H_TRI37_3"]["status"]))
    lines.append("5. late preclosure は bispectrum / triple correlation でも distinctive か: `{}`.".format(hypotheses["H_TRI37_4"]["status"]))
    lines.append("6. pair-level bispectrum は pair-level profile alone より有用か: `{}`.".format(hypotheses["H_TRI37_5"]["status"]))
    lines.append("7. AP count / additive energy は cheap scalar diagnosticsとして保存済み。分離力は `group_summary` と distance summaries で確認する。")
    stable = [row for row in sweep_summary if row.get("spearman_rank_correlation_vs_full") is not None]
    best = max(stable, key=lambda r: r.get("spearman_rank_correlation_vs_full")) if stable else None
    lines.append("8. sampled bispectrum はどの sample size で安定するか: best observed `{}`.".format(best))
    lines.append("9. p167 c01/c05/c09 に持ち込むべき metric: block/pair normalized bispectrum distance, triple-correlation distance, sampled-bispectrum rank stability, and pair-profile-plus-bispectrum combined distance.")
    lines.append("10. 次に p167 bispectrum audit へ進む価値はあるか: p37 hypotheses の supported 数を見て判断する。supported count `{}`.".format(sum(1 for row in hypotheses.values() if row.get("status") == "supported")))
    lines.append("11. generator に使うなら、score-only の代替ではなく move-space rerank / archive filter / pair-level rerank feature として使うのが安全。")
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


def write_outputs(out_dir, config, candidates, rows, triple_rows, ap_rows, pair_rows, sweep_rows):
    ensure_dir(out_dir)
    group_rows = group_summary(rows)
    bis_summary, tri_summary, pair_summary, pair_profile_summary, pair_combo_summary = build_distance_summaries(rows)
    sweep_summary = sampled_sweep_summary(sweep_rows)
    hypotheses = hypothesis_evaluation(rows, bis_summary, tri_summary, pair_profile_summary, pair_combo_summary, sweep_summary)
    write_json(os.path.join(out_dir, "run_config.json"), config)
    write_jsonl(os.path.join(out_dir, "input_p37_triple_bispectrum_candidates.jsonl"), candidates)
    write_jsonl(os.path.join(out_dir, "p37_bispectrum_features.jsonl"), rows)
    write_jsonl(os.path.join(out_dir, "p37_triple_correlation_features.jsonl"), triple_rows)
    write_jsonl(os.path.join(out_dir, "p37_ap_energy_features.jsonl"), ap_rows)
    write_jsonl(os.path.join(out_dir, "p37_pair_bispectrum_features.jsonl"), pair_rows)
    write_csv(os.path.join(out_dir, "group_summary.csv"), group_rows)
    write_json(os.path.join(out_dir, "group_summary.json"), {"rows": group_rows})
    write_csv(os.path.join(out_dir, "bispectrum_distance_summary.csv"), bis_summary)
    write_json(os.path.join(out_dir, "bispectrum_distance_summary.json"), {"rows": bis_summary})
    write_csv(os.path.join(out_dir, "triple_correlation_distance_summary.csv"), tri_summary)
    write_json(os.path.join(out_dir, "triple_correlation_distance_summary.json"), {"rows": tri_summary})
    write_csv(os.path.join(out_dir, "pair_bispectrum_split_summary.csv"), pair_summary + pair_profile_summary + pair_combo_summary)
    write_json(os.path.join(out_dir, "pair_bispectrum_split_summary.json"), {"bispectrum_rows": pair_summary, "pair_profile_rows": pair_profile_summary, "combined_rows": pair_combo_summary})
    write_csv(os.path.join(out_dir, "sampled_bispectrum_sweep.csv"), sweep_rows)
    write_json(os.path.join(out_dir, "sampled_bispectrum_sweep.json"), {"rows": sweep_rows, "summary": sweep_summary})
    write_json(os.path.join(out_dir, "hypothesis_evaluation.json"), hypotheses)
    with open(os.path.join(out_dir, "p37_triple_bispectrum_audit_summary.md"), "w") as f:
        f.write(build_summary_md(config, candidates, rows, group_rows, bis_summary, tri_summary, pair_summary, pair_profile_summary, pair_combo_summary, sweep_summary, hypotheses))
    with open(os.path.join(out_dir, "run_log.md"), "w") as f:
        f.write("# p37 triple bispectrum audit log\n\n")
        f.write("- generated_at: `{}`\n".format(time.strftime("%Y-%m-%dT%H:%M:%S%z")))
        f.write("- candidate_rows: `{}`\n".format(len(candidates)))
        f.write("- feature_rows: `{}`\n".format(len(rows)))
        f.write("- output_dir: `{}`\n".format(out_dir))


def aggregate_mode(args):
    roots = []
    for root in str(args.aggregate_roots).split(","):
        root = root.strip()
        if root:
            roots.append(root)
    if not roots:
        raise RuntimeError("--aggregate-roots is required in aggregate mode")
    candidates = []
    rows = []
    triple_rows = []
    ap_rows = []
    pair_rows = []
    sweep_rows = []
    for root in roots:
        for path in glob.glob(os.path.join(root, "**", "input_p37_triple_bispectrum_candidates.jsonl"), recursive=True):
            candidates.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_bispectrum_features.jsonl"), recursive=True):
            rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_triple_correlation_features.jsonl"), recursive=True):
            triple_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_ap_energy_features.jsonl"), recursive=True):
            ap_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "p37_pair_bispectrum_features.jsonl"), recursive=True):
            pair_rows.extend(read_jsonl(path))
        for path in glob.glob(os.path.join(root, "**", "sampled_bispectrum_sweep.csv"), recursive=True):
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
                    sweep_rows.append(converted)
    candidates = dedupe_rows(candidates, ("candidate_group", "candidate_hash"))
    rows = dedupe_rows(rows, ("candidate_group", "candidate_hash"))
    triple_rows = dedupe_rows(triple_rows, ("candidate_group", "candidate_hash"))
    ap_rows = dedupe_rows(ap_rows, ("candidate_group", "candidate_hash"))
    pair_rows = dedupe_rows(pair_rows, ("candidate_group", "candidate_hash"))
    config = config_from_args(args)
    config["aggregate_roots"] = roots
    config["aggregate_mode"] = True
    write_outputs(args.out_dir, config, candidates, rows, triple_rows, ap_rows, pair_rows, sweep_rows)


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
        "multiplier_minimized": bool(args.multiplier_minimized),
    }


def parse_args():
    parser = argparse.ArgumentParser(description="p37 triple correlation / bispectrum audit")
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
    parser.add_argument("--exact-derived-count", type=int, default=24)
    parser.add_argument("--random-control-count", type=int, default=12)
    parser.add_argument("--no-multiplier-minimized", dest="multiplier_minimized", action="store_false")
    parser.set_defaults(multiplier_minimized=True)
    parser.add_argument("--aggregate-roots", default="")
    parser.add_argument("--aggregate", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    if args.out_dir is None:
        args.out_dir = os.path.join("outputs", "explorations", "{}_p37_triple_bispectrum_audit".format(now_stamp()))
    if args.metric_mode == "smoke":
        if args.max_candidates <= 0:
            args.max_candidates = 2
        if args.max_tasks <= 0:
            args.max_tasks = 2
        args.sample_sizes = "10"
        args.exact_derived_count = min(int(args.exact_derived_count), 2)
        args.random_control_count = min(int(args.random_control_count), 1)
        args.multiplier_minimized = False
    if args.aggregate:
        aggregate_mode(args)
        print("SUMMARY:", os.path.join(args.out_dir, "p37_triple_bispectrum_audit_summary.md"))
        return
    candidates = collect_candidates(args)
    if not candidates:
        raise RuntimeError("no candidates selected for this shard")
    rows, triple_rows, ap_rows, pair_rows, sweep_rows = compute_feature_rows(candidates, args)
    write_outputs(args.out_dir, config_from_args(args), candidates, rows, triple_rows, ap_rows, pair_rows, sweep_rows)
    print("candidates:", len(candidates))
    print("SUMMARY:", os.path.join(args.out_dir, "p37_triple_bispectrum_audit_summary.md"))


if __name__ == "__main__":
    main()
