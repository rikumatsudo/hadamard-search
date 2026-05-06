from sage.all import *

import argparse
import hashlib
import json
import os
import random
import statistics
import sys
import time
from collections import defaultdict

from sds_repair_utils import (
    canonical_hash,
    error_histogram,
    metrics_from_counts,
    p_adic_moment_summary,
    save_near_hit,
    save_success,
    setup_logging,
    total_diff_counts,
    validate_params,
    write_json,
)


SEARCH_METHOD = "moment_compatible_pool_mitm"
P = 167
LOW_POWERS = (2, 4, 6)
HIGH_POWERS = (2, 4, 6, 8, 10, 12)
TUPLES = {
    "A": ((73, 78, 79, 81), 144),
    "B": ((73, 76, 83, 83), 148),
    "C": ((76, 76, 77, 80), 142),
}
THRESHOLDS = (500, 450, 424, 400, 360, 320, 300, 280, 240)


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)


def append_jsonl(path, payload):
    ensure_dir(os.path.dirname(path) or ".")
    with open(path, "a") as f:
        f.write(json.dumps(json_safe(payload), sort_keys=True) + "\n")


def json_safe(value):
    if isinstance(value, dict):
        return {str(key): json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    try:
        if isinstance(value, Integer):
            return int(value)
    except NameError:
        pass
    return value


def min_mod_abs(x, p=P):
    x = int(x) % int(p)
    return min(x, int(p) - x)


def centered_block(values, k, p=P):
    values = [int(x) % p for x in values]
    shift = (-sum(values) * inverse_mod(int(k), int(p))) % p
    return tuple(sorted(((x + shift) % p) for x in values))


def block_bitset(block):
    bits = 0
    for x in block:
        bits |= 1 << int(x)
    return bits


def block_hash(block, k, p=P):
    text = "{}:{}:{}".format(p, int(k), ",".join(str(int(x)) for x in block))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def power_sums(block, p=P):
    out = {}
    for power in (1, 2, 3, 4, 6):
        out[power] = sum(pow(int(x) % p, power, p) for x in block) % p
    return out


def block_feature(block, k, p=P):
    sums = power_sums(block, p)
    s2 = sums[2]
    s3 = sums[3]
    s4 = sums[4]
    s6 = sums[6]
    g2 = (int(k) * s2) % p
    g4 = (int(k) * s4 + 3 * s2 * s2) % p
    g6 = (int(k) * s6 + 15 * s2 * s4 - 10 * s3 * s3) % p
    return (int(g2), int(g4), int(g6)), sums


def diff_counts_block(v, block):
    counts = [0] * int(v)
    values = list(block)
    for x in values:
        for y in values:
            if x != y:
                counts[(x - y) % int(v)] += 1
    return counts


def random_centered_block(rng, k, p=P):
    values = rng.sample(range(p), int(k))
    return centered_block(values, k, p)


def mutate_block(rng, block, k, swaps, p=P):
    values = set(int(x) for x in block)
    for _ in range(int(swaps)):
        removed = rng.choice(tuple(values))
        added = rng.randrange(p)
        while added in values:
            added = rng.randrange(p)
        values.remove(removed)
        values.add(added)
    return centered_block(values, k, p)


def load_mutation_sources(paths, tuple_ks, limit=None, seed=1):
    if limit is not None:
        paths = list(paths)
        rng = random.Random(int(seed))
        rng.shuffle(paths)
        paths = paths[: int(limit)]
    out = [[] for _ in range(4)]
    for path in paths:
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception:
            continue
        if tuple(int(k) for k in data.get("ks", [])) != tuple(tuple_ks):
            continue
        blocks = data.get("blocks")
        if not isinstance(blocks, list) or len(blocks) != 4:
            continue
        for idx, block in enumerate(blocks):
            out[idx].append(tuple(sorted(int(x) % P for x in block)))
    return out


def make_block_entry(block, k, origin, source=None):
    feature, sums = block_feature(block, k)
    return {
        "block": tuple(int(x) for x in block),
        "k": int(k),
        "feature": feature,
        "power_sums": sums,
        "hash": block_hash(block, k),
        "bitset": block_bitset(block),
        "origin": origin,
        "source": source,
        "counts": None,
    }


def build_block_pool(position, k, args, mutation_sources):
    rng = random.Random(int(int(args.seed) + 1009 * int(position) + 17 * int(k)))
    entries = []
    seen = set()
    target = int(args.blocks_per_k)

    def add_block(block, origin, source=None):
        if len(entries) >= target:
            return False
        h = block_hash(block, k)
        if h in seen:
            return False
        seen.add(h)
        entries.append(make_block_entry(block, k, origin, source=source))
        return True

    for source_idx, block in enumerate(mutation_sources[position]):
        if len(entries) >= target:
            break
        centered = centered_block(block, k)
        add_block(centered, "mutated_pool_seed", "source_block_{}".format(source_idx))
        for _ in range(int(args.mutations_per_source)):
            if len(entries) >= target:
                break
            swaps = rng.randint(1, max(1, int(args.max_mutation_swaps)))
            add_block(
                mutate_block(rng, centered, k, swaps),
                "mutated_pool",
                "source_block_{}".format(source_idx),
            )

    attempts = 0
    max_attempts = max(target * 20, target + 1000)
    while len(entries) < target and attempts < max_attempts:
        attempts += 1
        add_block(random_centered_block(rng, k), "random_pool")
    return entries


def pair_feature(left, right, p=P):
    return (
        (left[0] + right[0]) % p,
        (left[1] + right[1]) % p,
        (left[2] + right[2]) % p,
    )


def negative_feature(feature, p=P):
    return ((-feature[0]) % p, (-feature[1]) % p, (-feature[2]) % p)


def sampled_pair_indices(rng, n1, n2, samples):
    total = int(n1) * int(n2)
    samples = min(int(samples), total)
    if samples >= total:
        for i in range(n1):
            for j in range(n2):
                yield i, j
    else:
        seen = set()
        while len(seen) < samples:
            key = (rng.randrange(n1), rng.randrange(n2))
            if key in seen:
                continue
            seen.add(key)
            yield key


def build_left_pair_map(pools, args):
    rng = random.Random(int(int(args.seed) + 50000))
    left_map = defaultdict(list)
    samples = int(args.pair_samples)
    n1, n2 = len(pools[0]), len(pools[1])
    generated = 0
    kept = 0
    for i, j in sampled_pair_indices(rng, n1, n2, samples):
        feature = pair_feature(pools[0][i]["feature"], pools[1][j]["feature"])
        bucket = left_map[feature]
        generated += 1
        if len(bucket) < int(args.pair_bucket_limit):
            bucket.append((int(i), int(j)))
            kept += 1
    return left_map, {"left_pair_samples": generated, "left_pairs_kept": kept, "left_keys": len(left_map)}


def get_counts(pool, idx, v=P):
    entry = pool[int(idx)]
    if entry["counts"] is None:
        entry["counts"] = diff_counts_block(v, entry["block"])
    return entry["counts"]


def candidate_counts(pools, indices, v=P):
    total = [0] * int(v)
    for pos, idx in enumerate(indices):
        counts = get_counts(pools[pos], idx, v)
        for d in range(v):
            total[d] += counts[d]
    return total


def high_moment_payload(counts, lam, v=P):
    low = p_adic_moment_summary(counts, lam, powers=LOW_POWERS, modulus=v)
    high = p_adic_moment_summary(counts, lam, powers=HIGH_POWERS, modulus=v)
    by_power = {"T{}".format(item["power"]): int(item["residue"]) for item in high["moments"]}
    high_tail = [by_power["T8"], by_power["T10"], by_power["T12"]]
    higher_norm = sum(min_mod_abs(x, v) ** 2 for x in high_tail)
    return {
        "padic_moments": by_power,
        "p_adic_moments": high,
        "p_adic_moments_3": low,
        "moment_signature_3": low["moment_signature"],
        "moment_signature_6": high["moment_signature"],
        "moment_zero_count_3": int(low["moment_zero_count"]),
        "moment_zero_count_6": int(high["moment_zero_count"]),
        "moment_abs_sum_3": int(low["moment_abs_sum"]),
        "moment_abs_sum_6": int(high["moment_abs_sum"]),
        "higher_moment_norm": int(higher_norm),
    }


def record_from_indices(pools, indices, ks, lam, tuple_id, origin, v=P):
    counts = candidate_counts(pools, indices, v)
    metrics = metrics_from_counts(counts, lam)
    moment = high_moment_payload(counts, lam, v)
    blocks = [pools[pos][idx]["block"] for pos, idx in enumerate(indices)]
    block_hashes = [pools[pos][idx]["hash"] for pos, idx in enumerate(indices)]
    origins = [pools[pos][idx]["origin"] for pos, idx in enumerate(indices)]
    return {
        "tuple_id": tuple_id,
        "v": int(v),
        "n": int(4 * v),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "indices": [int(idx) for idx in indices],
        "blocks": [[int(x) for x in block] for block in blocks],
        "block_hashes": block_hashes,
        "origin": origin,
        "block_origins": origins,
        "score": int(metrics[0]),
        "l1_error": int(metrics[1]),
        "max_abs_error": int(metrics[2]),
        "nonzero_defect_count": int(metrics[3]),
        "counts": counts,
        "metrics_tuple": tuple(int(x) for x in metrics),
        **moment,
    }


def compact_record(record, include_blocks=False):
    keys = [
        "tuple_id",
        "ks",
        "lambda",
        "score",
        "l1_error",
        "max_abs_error",
        "nonzero_defect_count",
        "moment_signature_3",
        "moment_signature_6",
        "moment_zero_count_3",
        "moment_zero_count_6",
        "higher_moment_norm",
        "origin",
        "block_origins",
        "block_hashes",
        "indices",
    ]
    out = {key: record.get(key) for key in keys}
    out["padic_moments"] = record.get("padic_moments", {})
    if include_blocks:
        out["blocks"] = record["blocks"]
    if "saved_path" in record:
        out["saved_path"] = record["saved_path"]
    return out


def update_frontier(frontiers, name, record, key_fn, limit):
    items = frontiers.setdefault(name, [])
    items.append(record)
    items.sort(key=key_fn)
    del items[int(limit):]


def quantiles(values):
    if not values:
        return {}
    values = sorted(int(x) for x in values)
    def q(frac):
        idx = int(frac * (len(values) - 1))
        return int(values[idx])
    return {
        "min": int(values[0]),
        "p1": q(0.01),
        "p5": q(0.05),
        "p10": q(0.10),
        "median": q(0.50),
        "count": len(values),
    }


def save_record_as_near_hit(record, args, round_index):
    blocks = [set(block) for block in record["blocks"]]
    extra = {
        "tuple_id": record["tuple_id"],
        "origin": record["origin"],
        "block_hashes": record["block_hashes"],
        "block_origins": record["block_origins"],
        "padic_moments": record["padic_moments"],
        "p_adic_moments": record["p_adic_moments"],
        "p_adic_moments_3": record["p_adic_moments_3"],
        "moment_zero_count_3": record["moment_zero_count_3"],
        "moment_zero_count_6": record["moment_zero_count_6"],
        "moment_signature_3": record["moment_signature_3"],
        "moment_signature_6": record["moment_signature_6"],
        "higher_moment_norm": record["higher_moment_norm"],
        "verify_sds": False,
        "generated_hadamard": False,
        "hh_t": False,
        "search_method_detail": "block_feature_pool_mitm_true_score_recomputed",
    }
    metrics = (
        record["score"],
        record["l1_error"],
        record["max_abs_error"],
        record["nonzero_defect_count"],
    )
    if record["score"] == 0:
        return save_success(
            args.candidate_dir,
            args.near_hit_dir,
            P,
            tuple(record["ks"]),
            record["lambda"],
            blocks,
            metrics,
            "moment_pool_mitm",
            SEARCH_METHOD,
            round_index,
            0,
            record["counts"],
            extra,
        )
    return save_near_hit(
        args.near_hit_dir,
        P,
        tuple(record["ks"]),
        record["lambda"],
        blocks,
        metrics,
        "moment_pool_mitm",
        SEARCH_METHOD,
        round_index,
        0,
        record["counts"],
        extra,
    )


def evaluate_mitm_candidates(pools, left_map, ks, lam, tuple_id, args, frontiers):
    rng = random.Random(int(int(args.seed) + 60000))
    n3, n4 = len(pools[2]), len(pools[3])
    evaluated = 0
    right_samples = 0
    matches_seen = 0
    seen_candidates = set()
    scores = []
    threshold_counts = {str(t): 0 for t in THRESHOLDS}
    eval_path = os.path.join(args.out_dir, "evaluated_candidates.jsonl")
    for k3, k4 in sampled_pair_indices(rng, n3, n4, int(args.pair_samples)):
        right_samples += 1
        right_feature = pair_feature(pools[2][k3]["feature"], pools[3][k4]["feature"])
        need = negative_feature(right_feature)
        left_pairs = left_map.get(need)
        if not left_pairs:
            continue
        for i1, i2 in left_pairs:
            indices = (int(i1), int(i2), int(k3), int(k4))
            if indices in seen_candidates:
                continue
            seen_candidates.add(indices)
            matches_seen += 1
            record = record_from_indices(pools, indices, ks, lam, tuple_id, "moment_pool_mitm")
            # This should be true by construction; keep a defensive check.
            if record["moment_zero_count_3"] != 3:
                continue
            scores.append(record["score"])
            for threshold in THRESHOLDS:
                if record["score"] <= threshold:
                    threshold_counts[str(threshold)] += 1
            append_jsonl(eval_path, compact_record(record))
            evaluated += 1
            update_all_frontiers(frontiers, record, args.frontier_size)
            if evaluated >= int(args.max_candidates_eval):
                return {
                    "right_pair_samples": right_samples,
                    "matches_seen": matches_seen,
                    "evaluated": evaluated,
                    "threshold_counts": threshold_counts,
                    "score_quantiles": quantiles(scores),
                }
    return {
        "right_pair_samples": right_samples,
        "matches_seen": matches_seen,
        "evaluated": evaluated,
        "threshold_counts": threshold_counts,
        "score_quantiles": quantiles(scores),
    }


def update_all_frontiers(frontiers, record, limit):
    update_frontier(
        frontiers,
        "best_by_score",
        record,
        lambda r: (r["score"], r["l1_error"], r["max_abs_error"], r["nonzero_defect_count"], r["higher_moment_norm"]),
        limit,
    )
    update_frontier(
        frontiers,
        "best_by_l1",
        record,
        lambda r: (r["l1_error"], r["score"], r["max_abs_error"], r["nonzero_defect_count"]),
        limit,
    )
    update_frontier(
        frontiers,
        "best_by_max_abs",
        record,
        lambda r: (r["max_abs_error"], r["score"], r["l1_error"], r["nonzero_defect_count"]),
        limit,
    )
    update_frontier(
        frontiers,
        "best_by_nonzero",
        record,
        lambda r: (r["nonzero_defect_count"], r["score"], r["l1_error"], r["max_abs_error"]),
        limit,
    )
    update_frontier(
        frontiers,
        "best_by_moment_zero_count_6",
        record,
        lambda r: (-r["moment_zero_count_6"], r["higher_moment_norm"], r["score"], r["l1_error"]),
        limit,
    )
    update_frontier(
        frontiers,
        "best_by_higher_moment_norm",
        record,
        lambda r: (r["higher_moment_norm"], r["score"], r["l1_error"], r["max_abs_error"]),
        limit,
    )


def evaluate_baseline(pools, ks, lam, tuple_id, args):
    rng = random.Random(int(int(args.seed) + 70000))
    scores = []
    records = []
    samples = min(int(args.baseline_samples), int(args.max_candidates_eval))
    for _ in range(samples):
        indices = tuple(rng.randrange(len(pool)) for pool in pools)
        record = record_from_indices(pools, indices, ks, lam, tuple_id, "random_unconstrained_pool")
        scores.append(record["score"])
        records.append(compact_record(record))
    records.sort(key=lambda r: (r["score"], r["l1_error"], r["max_abs_error"], r["nonzero_defect_count"]))
    return {
        "samples": samples,
        "score_quantiles": quantiles(scores),
        "best": records[: min(20, len(records))],
    }


def write_frontiers(frontiers, args):
    saved_paths = []
    for name, records in frontiers.items():
        path = os.path.join(args.out_dir, "{}.jsonl".format("frontier_" + name))
        for record in records:
            append_jsonl(path, compact_record(record))
        if name in ("best_by_score", "best_by_l1", "best_by_higher_moment_norm"):
            for idx, record in enumerate(records[: int(args.save_candidates_per_frontier)], start=1):
                saved_path = save_record_as_near_hit(record, args, idx)
                record["saved_path"] = saved_path
                saved_paths.append(saved_path)
    return saved_paths


def write_summary(args, tuple_id, ks, lam, pool_stats, mitm_stats, baseline, frontiers, saved_paths):
    best = frontiers.get("best_by_score", [None])[0]
    best_higher = frontiers.get("best_by_higher_moment_norm", [None])[0]
    lines = []
    lines.append("# Moment-compatible Pool MITM Summary")
    lines.append("")
    lines.append("Diagnostic only. `T2=T4=T6=0` is a low-degree necessary condition, not an SDS success certificate.")
    lines.append("")
    lines.append("## Run")
    lines.append("")
    lines.append("- tuple: `{}`".format(tuple_id))
    lines.append("- ks/lambda: `{}` / `{}`".format(list(ks), lam))
    lines.append("- blocks_per_k: `{}`".format(args.blocks_per_k))
    lines.append("- pair_samples: `{}`".format(args.pair_samples))
    lines.append("- pair_bucket_limit: `{}`".format(args.pair_bucket_limit))
    lines.append("- max_candidates_eval: `{}`".format(args.max_candidates_eval))
    lines.append("")
    lines.append("## Pool Stats")
    lines.append("")
    for item in pool_stats:
        lines.append("- pos {position}, k={k}: count={count}, origins={origins}".format(**item))
    lines.append("")
    lines.append("## MITM Stats")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(json_safe(mitm_stats), indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("## Baseline")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(json_safe(baseline["score_quantiles"]), indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("## Best Moment-compatible Candidate")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(json_safe(compact_record(best) if best else None), indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("## Best Higher-moment Candidate")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(json_safe(compact_record(best_higher) if best_higher else None), indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    lines.append("## Saved Candidate JSON")
    lines.append("")
    for path in saved_paths:
        lines.append("- `{}`".format(path))
    lines.append("")
    lines.append("## Verdict")
    lines.append("")
    if best is None:
        lines.append("No moment-compatible candidate was evaluated.")
    elif best["score"] <= 300:
        lines.append("Strong positive: score <= 300 appeared in the moment-compatible pool.")
    elif best["score"] <= 360:
        lines.append("Positive: score <= 360 appeared in the moment-compatible pool.")
    elif best["score"] < 424:
        lines.append("Weak positive: the pool beat the previous all-zero score 424.")
    elif best["score"] <= 424:
        lines.append("Neutral: the pool reached the existing all-zero score range.")
    else:
        lines.append("Negative for generative use in this run: best score stayed above 424.")
    lines.append("")
    lines.append("No Hadamard 668 construction is claimed unless score 0 plus SDS and GS exact verification pass.")
    with open(os.path.join(args.out_dir, "moment_pool_summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Generate T2=T4=T6=0 moment-compatible SDS candidate pools by MITM.")
    parser.add_argument("--tuple", choices=sorted(TUPLES), default="A")
    parser.add_argument("--blocks-per-k", type=int, default=5000)
    parser.add_argument("--pair-bucket-limit", type=int, default=100)
    parser.add_argument("--pair-samples", type=int, default=1000000)
    parser.add_argument("--max-candidates-eval", type=int, default=50000)
    parser.add_argument("--baseline-samples", type=int, default=5000)
    parser.add_argument("--frontier-size", type=int, default=50)
    parser.add_argument("--save-candidates-per-frontier", type=int, default=3)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--mutation-source-glob", default="outputs/candidates/near_hits/*.json")
    parser.add_argument("--mutation-source-limit", type=int, default=2000)
    parser.add_argument("--mutations-per-source", type=int, default=20)
    parser.add_argument("--max-mutation-swaps", type=int, default=3)
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--near-hit-dir", default="outputs/candidates/near_hits")
    parser.add_argument("--candidate-dir", default="outputs/candidates")
    return parser.parse_args()


def main():
    args = parse_args()
    tuple_id = args.tuple
    ks, lam = TUPLES[tuple_id]
    validate_params(P, ks, lam)
    if args.out_dir is None:
        args.out_dir = os.path.join("outputs", "explorations", "{}_hadamard668_moment_compatible_pool_mitm_{}".format(now_stamp(), tuple_id))
    ensure_dir(args.out_dir)
    ensure_dir(os.path.join(args.out_dir, "raw"))
    tee, stamp = setup_logging("46_moment_compatible_pool_mitm")
    try:
        run_config = vars(args).copy()
        run_config["ks"] = list(ks)
        run_config["lambda"] = int(lam)
        write_json(os.path.join(args.out_dir, "run_config.json"), json_safe(run_config))
        write_json(os.path.join(args.out_dir, "raw", "run_config.json"), json_safe(run_config))
        print("Output dir:", args.out_dir)
        print("tuple={} ks={} lambda={}".format(tuple_id, ks, lam))
        print("blocks_per_k={} pair_samples={} pair_bucket_limit={} max_eval={}".format(args.blocks_per_k, args.pair_samples, args.pair_bucket_limit, args.max_candidates_eval))

        import glob
        mutation_paths = []
        if args.mutation_source_glob:
            mutation_paths = glob.glob(args.mutation_source_glob)
        mutation_sources = load_mutation_sources(
            mutation_paths,
            ks,
            limit=args.mutation_source_limit,
            seed=int(args.seed) + 90000,
        )
        pools = []
        pool_stats = []
        for pos, k in enumerate(ks):
            pool = build_block_pool(pos, k, args, mutation_sources)
            pools.append(pool)
            origins = {}
            for entry in pool:
                origins[entry["origin"]] = origins.get(entry["origin"], 0) + 1
            stat = {"position": int(pos), "k": int(k), "count": int(len(pool)), "origins": origins}
            pool_stats.append(stat)
            print("POOL", stat)
        write_json(os.path.join(args.out_dir, "raw", "block_pool_stats.json"), json_safe(pool_stats))

        left_map, left_stats = build_left_pair_map(pools, args)
        print("LEFT", left_stats)
        frontiers = {}
        mitm_stats = evaluate_mitm_candidates(pools, left_map, ks, lam, tuple_id, args, frontiers)
        mitm_stats.update(left_stats)
        print("MITM", mitm_stats)
        baseline = evaluate_baseline(pools, ks, lam, tuple_id, args)
        print("BASELINE", baseline["score_quantiles"])
        saved_paths = write_frontiers(frontiers, args)

        write_json(os.path.join(args.out_dir, "raw", "mitm_stats.json"), json_safe(mitm_stats))
        write_json(os.path.join(args.out_dir, "baseline_random_summary.json"), json_safe(baseline))
        write_json(os.path.join(args.out_dir, "raw", "baseline_random_summary.json"), json_safe(baseline))
        frontier_summary = {name: [compact_record(record) for record in records] for name, records in frontiers.items()}
        write_json(os.path.join(args.out_dir, "raw", "frontier_summary.json"), json_safe(frontier_summary))
        write_summary(args, tuple_id, ks, lam, pool_stats, mitm_stats, baseline, frontiers, saved_paths)
        print("SUMMARY:", os.path.join(args.out_dir, "moment_pool_summary.md"))
    finally:
        tee.flush()
        tee.close()
        sys.stdout = tee.terminal


if __name__ == "__main__":
    main()
