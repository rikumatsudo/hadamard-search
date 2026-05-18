#!/usr/bin/env python3
import argparse
import csv
import hashlib
import json
import math
import os
import random
import statistics
import time
from pathlib import Path

import p167_frontier_repair_benchmark as base


P_DEFAULT = 167
FRONTIER_FIXTURE_DEFAULT = "configs/fixtures/p167_local_branching_wall_candidates.jsonl"
OUTPUT_ROOT_DEFAULT = "outputs/p167_pair_profile_lift_smoke"
EXPERIMENT_DEFAULT = "p167_pair_profile_lift_smoke"
TUPLE_CLASSES_DEFAULT = "p167_c01,p167_c05"
ALL_TUPLE_CLASSES = ",".join("p167_c{:02d}".format(i) for i in range(1, 11))
SPLITS = {
    "fixed_01_23": ((0, 1), (2, 3)),
    "fixed_02_13": ((0, 2), (1, 3)),
    "fixed_03_12": ((0, 3), (1, 2)),
}
THRESHOLDS = (1000, 500, 300, 240, 200, 180, 160, 120, 100)


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
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    try:
        out = float(value)
        return out if math.isfinite(out) else None
    except Exception:
        return str(value)


def csv_value(value):
    value = json_safe(value)
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True, separators=(",", ":"))
    return value


def write_json(path, payload):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as f:
        json.dump(json_safe(payload), f, indent=2, sort_keys=True)
        f.write("\n")


def write_jsonl(path, rows):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(json_safe(row), sort_keys=True, separators=(",", ":")) + "\n")


def write_csv(path, rows, fields):
    ensure_dir(os.path.dirname(path))
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: csv_value(row.get(field)) for field in fields})


def parse_csv(text, cast=str):
    if isinstance(text, (list, tuple)):
        return [cast(x) for x in text]
    return [cast(part.strip()) for part in str(text).split(",") if part.strip()]


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def median(values):
    vals = [float(v) for v in values if v is not None]
    return statistics.median(vals) if vals else None


def mean(values):
    vals = [float(v) for v in values if v is not None]
    return statistics.mean(vals) if vals else None


def rate(rows, pred):
    return sum(1 for row in rows if pred(row)) / float(len(rows)) if rows else 0.0


def stable_int(text):
    digest = hashlib.sha256(str(text).encode("utf-8")).hexdigest()
    return int(digest[:16], 16)


def pair_profile(p, blocks, pair):
    counts = base.P37.all_diff_counts(p, blocks, include_zero=False)
    profile = [0] * p
    for d in range(1, p):
        profile[d] = sum(int(counts[idx][d]) for idx in pair)
    return profile


def pair_profile_loss(profile, target):
    return int(sum((int(profile[d]) - int(target[d])) ** 2 for d in range(1, len(profile))))


def split_pairs(split_mode):
    if split_mode not in SPLITS:
        raise ValueError("unknown split mode {}".format(split_mode))
    return SPLITS[split_mode]


def split_pair_residual_loss(p, blocks, lam, split_mode):
    left_pair, right_pair = split_pairs(split_mode)
    left = pair_profile(p, blocks, left_pair)
    right = pair_profile(p, blocks, right_pair)
    return int(sum((int(left[d]) + int(right[d]) - int(lam)) ** 2 for d in range(1, p)))


def make_pair_targets(p, source_blocks, lam, target_mode, split_mode, rng):
    left_pair, right_pair = split_pairs(split_mode)
    left = pair_profile(p, source_blocks, left_pair)
    right = pair_profile(p, source_blocks, right_pair)
    target = [0] * p
    if target_mode == "seed_left":
        for d in range(1, p):
            target[d] = int(left[d])
    elif target_mode == "seed_right_complement":
        for d in range(1, p):
            target[d] = int(lam) - int(right[d])
    elif target_mode == "midpoint":
        for d in range(1, p):
            target[d] = int(round((int(left[d]) + int(lam) - int(right[d])) / 2.0))
    elif target_mode == "lambda_half":
        lo = int(lam) // 2
        hi = int(lam) - lo
        for d in range(1, p):
            target[d] = lo if d % 2 == 0 else hi
    elif target_mode == "jitter_midpoint":
        for d in range(1, p):
            val = int(round((int(left[d]) + int(lam) - int(right[d])) / 2.0))
            target[d] = val + rng.choice((-1, 0, 1))
    else:
        raise ValueError("unknown target mode {}".format(target_mode))
    for d in range(1, p):
        target[d] = max(0, min(int(lam), int(target[d])))
    complement = [0] * p
    for d in range(1, p):
        complement[d] = int(lam) - int(target[d])
    return target, complement


def random_block(p, size, rng):
    return set(rng.sample(range(p), int(size)))


def random_pair_blocks(p, sizes, rng):
    return [random_block(p, sizes[0], rng), random_block(p, sizes[1], rng)]


def perturb_pair_blocks(p, pair_blocks, swaps, rng):
    out = [set(block) for block in pair_blocks]
    for _ in range(int(swaps)):
        bidx = rng.randrange(2)
        block = out[bidx]
        if not block:
            continue
        remove = rng.choice(sorted(block))
        outside = [x for x in range(p) if x not in block]
        if not outside:
            continue
        add = rng.choice(outside)
        block.remove(remove)
        block.add(add)
    return out


def initial_pair_blocks(p, source_blocks, pair, sizes, init_mode, perturb_swaps, rng):
    if init_mode == "seed":
        return [set(source_blocks[pair[0]]), set(source_blocks[pair[1]])]
    if init_mode == "perturbed_seed":
        return perturb_pair_blocks(p, [set(source_blocks[pair[0]]), set(source_blocks[pair[1]])], perturb_swaps, rng)
    if init_mode == "random":
        return random_pair_blocks(p, sizes, rng)
    raise ValueError("unknown init mode {}".format(init_mode))


def choose_profile_swap(p, pair_blocks, target, current_profile, current_loss, rng, swap_sample_count):
    best = None
    for _ in range(int(swap_sample_count)):
        local_idx = rng.randrange(2)
        block = pair_blocks[local_idx]
        if not block:
            continue
        remove = rng.choice(sorted(block))
        outside = [x for x in range(p) if x not in block]
        if not outside:
            continue
        add = rng.choice(outside)
        delta = base.exact_joint_delta_rho(p, block, [remove], [add])
        new_loss = 0
        for d in range(1, p):
            v = int(current_profile[d]) + int(delta[d]) - int(target[d])
            new_loss += v * v
        delta_loss = int(new_loss) - int(current_loss)
        if best is None or delta_loss < best["delta_loss"]:
            best = {
                "local_block": int(local_idx),
                "remove": int(remove),
                "add": int(add),
                "delta": delta,
                "loss": int(new_loss),
                "delta_loss": int(delta_loss),
            }
    return best


def lift_pair_to_target(p, source_blocks, pair, sizes, target, init_mode, args, rng):
    pair_blocks = initial_pair_blocks(p, source_blocks, pair, sizes, init_mode, int(args.perturb_swaps), rng)
    profile = pair_profile(p, pair_blocks, (0, 1))
    start_loss = pair_profile_loss(profile, target)
    current_loss = int(start_loss)
    best_loss = int(current_loss)
    best_blocks = [set(block) for block in pair_blocks]
    accepted = 0
    uphill = 0
    started = time.time()
    for step in range(int(args.lift_steps)):
        if (time.time() - started) * 1000.0 >= float(args.max_wall_time_ms_per_lift):
            break
        move = choose_profile_swap(p, pair_blocks, target, profile, current_loss, rng, int(args.swap_sample_count))
        if move is None:
            break
        accept = False
        if int(move["delta_loss"]) <= 0:
            accept = True
        elif float(args.temperature) > 0:
            prob = math.exp(-float(move["delta_loss"]) / max(1e-9, float(args.temperature)))
            accept = rng.random() < prob
        if not accept:
            break
        bidx = int(move["local_block"])
        pair_blocks[bidx].remove(int(move["remove"]))
        pair_blocks[bidx].add(int(move["add"]))
        for d in range(1, p):
            profile[d] += int(move["delta"][d])
        current_loss = int(move["loss"])
        accepted += 1
        if int(move["delta_loss"]) > 0:
            uphill += 1
        if current_loss < best_loss:
            best_loss = int(current_loss)
            best_blocks = [set(block) for block in pair_blocks]
    return {
        "blocks": best_blocks,
        "start_loss": int(start_loss),
        "best_loss": int(best_loss),
        "accepted_steps": int(accepted),
        "uphill_steps": int(uphill),
        "profile": pair_profile(p, best_blocks, (0, 1)),
    }


def run_score_repair(p, blocks, lam, args, seed):
    if int(args.repair_budget) <= 0:
        return [set(block) for block in blocks], base.P37.score_blocks(p, blocks, lam), 0, False
    return base.P37.repair_candidate(
        p,
        [set(block) for block in blocks],
        int(lam),
        int(args.repair_budget),
        int(seed),
        int(args.repair_swap_sample_count),
    )


def flags(prefix, score):
    return {"{}_score_le_{}".format(prefix, threshold): bool(int(score) <= threshold) for threshold in THRESHOLDS}


def task_key(candidate, split_mode, target_mode, left_init, right_init, restart_id):
    return "{}::{}::{}::{}::{}::{}".format(candidate["frontier_candidate_id"], split_mode, target_mode, left_init, right_init, restart_id)


def shard_tasks(candidates, split_modes, target_modes, init_modes, restarts, shard_id, shard_count):
    tasks = []
    for candidate in candidates:
        for split_mode in split_modes:
            for target_mode in target_modes:
                for left_init in init_modes:
                    for right_init in init_modes:
                        for restart_id in range(int(restarts)):
                            key = task_key(candidate, split_mode, target_mode, left_init, right_init, restart_id)
                            if stable_int(key) % int(shard_count) == int(shard_id):
                                tasks.append((candidate, split_mode, target_mode, left_init, right_init, restart_id))
    return tasks


def run_one(candidate, split_mode, target_mode, left_init, right_init, restart_id, args):
    p = int(args.p)
    source_blocks = [set(int(x) for x in block) for block in candidate["blocks"]]
    lam = int(candidate["lambda"])
    ks = [len(block) for block in source_blocks]
    left_pair, right_pair = split_pairs(split_mode)
    seed = (
        int(args.base_seed)
        + int(args.shard_id) * 10000000
        + stable_int(candidate["frontier_candidate_id"]) % 100000
        + stable_int(split_mode) % 10000
        + stable_int(target_mode) % 10000
        + stable_int(left_init) % 1000
        + stable_int(right_init) % 1000
        + int(restart_id)
    )
    rng = random.Random(seed)
    source_score = base.P37.score_blocks(p, source_blocks, lam)
    source_pair_residual = split_pair_residual_loss(p, source_blocks, lam, split_mode)
    left_target, right_target = make_pair_targets(p, source_blocks, lam, target_mode, split_mode, rng)
    left_sizes = [ks[left_pair[0]], ks[left_pair[1]]]
    right_sizes = [ks[right_pair[0]], ks[right_pair[1]]]
    started = time.time()
    left = lift_pair_to_target(p, source_blocks, left_pair, left_sizes, left_target, left_init, args, rng)
    right = lift_pair_to_target(p, source_blocks, right_pair, right_sizes, right_target, right_init, args, rng)
    generated = [set() for _ in range(4)]
    generated[left_pair[0]] = set(left["blocks"][0])
    generated[left_pair[1]] = set(left["blocks"][1])
    generated[right_pair[0]] = set(right["blocks"][0])
    generated[right_pair[1]] = set(right["blocks"][1])
    score_generated = base.P37.score_blocks(p, generated, lam)
    pair_residual = split_pair_residual_loss(p, generated, lam, split_mode)
    repaired, score_after, repair_steps, repair_improved = run_score_repair(p, generated, lam, args, seed + 99991)
    elapsed_ms = int(round((time.time() - started) * 1000.0))
    row = {
        "run_id": args.run_id,
        "shard_id": int(args.shard_id),
        "candidate_id": candidate["frontier_candidate_id"],
        "tuple_class": candidate["tuple_class"],
        "frontier_bucket": candidate.get("frontier_bucket", ""),
        "source_run": candidate.get("source_run", ""),
        "lambda": int(lam),
        "ks": ks,
        "source_score": int(source_score),
        "source_pair_residual": int(source_pair_residual),
        "split_mode": split_mode,
        "target_mode": target_mode,
        "left_init_mode": left_init,
        "right_init_mode": right_init,
        "restart_id": int(restart_id),
        "seed": int(seed),
        "left_target_loss_start": int(left["start_loss"]),
        "left_target_loss": int(left["best_loss"]),
        "left_lift_accepted_steps": int(left["accepted_steps"]),
        "left_lift_uphill_steps": int(left["uphill_steps"]),
        "right_target_loss_start": int(right["start_loss"]),
        "right_target_loss": int(right["best_loss"]),
        "right_lift_accepted_steps": int(right["accepted_steps"]),
        "right_lift_uphill_steps": int(right["uphill_steps"]),
        "target_loss_total": int(left["best_loss"]) + int(right["best_loss"]),
        "score_generated": int(score_generated),
        "score_after_repair": int(score_after),
        "score_improvement_from_generated": int(score_generated) - int(score_after),
        "score_improvement_from_source_after_repair": int(source_score) - int(score_after),
        "pair_residual_generated": int(pair_residual),
        "pair_residual_improvement_from_source": int(source_pair_residual) - int(pair_residual),
        "repair_operator": "score_only_1swap_greedy" if int(args.repair_budget) > 0 else "none",
        "repair_steps_used": int(repair_steps),
        "repair_improved": bool(repair_improved),
        "wall_time_ms": int(elapsed_ms),
        "canonical_hash_generated": base.canonical_hash(generated),
        "canonical_hash_after": base.canonical_hash(repaired),
        "blocks_generated": base.candidate_json(generated, p, ks, lam)["blocks"],
        "blocks_after_repair": base.candidate_json(repaired, p, ks, lam)["blocks"],
    }
    row.update(flags("generated", score_generated))
    row.update(flags("after_repair", score_after))
    return row


def summarize_group(rows, keys):
    buckets = {}
    for row in rows:
        key = tuple(row.get(k) for k in keys)
        buckets.setdefault(key, []).append(row)
    out = []
    for key, group in sorted(buckets.items(), key=lambda item: item[0]):
        summary = {keys[i]: key[i] for i in range(len(keys))}
        summary["row_count"] = len(group)
        summary["best_score_generated"] = min(int(row["score_generated"]) for row in group) if group else None
        summary["best_score_after_repair"] = min(int(row["score_after_repair"]) for row in group) if group else None
        summary["median_score_generated"] = median(row["score_generated"] for row in group)
        summary["median_score_after_repair"] = median(row["score_after_repair"] for row in group)
        summary["best_target_loss_total"] = min(int(row["target_loss_total"]) for row in group) if group else None
        summary["median_target_loss_total"] = median(row["target_loss_total"] for row in group)
        summary["best_pair_residual_generated"] = min(int(row["pair_residual_generated"]) for row in group) if group else None
        summary["median_pair_residual_generated"] = median(row["pair_residual_generated"] for row in group)
        summary["repair_improvement_rate"] = rate(group, lambda row: bool(row.get("repair_improved")))
        summary["diversity_hash_count"] = len({row["canonical_hash_after"] for row in group})
        summary["wall_time_ms_median"] = median(row["wall_time_ms"] for row in group)
        for threshold in THRESHOLDS:
            summary["generated_score_le_{}_count".format(threshold)] = sum(1 for row in group if int(row["score_generated"]) <= threshold)
            summary["generated_score_le_{}_rate".format(threshold)] = rate(group, lambda row, t=threshold: int(row["score_generated"]) <= t)
            summary["after_repair_score_le_{}_count".format(threshold)] = sum(1 for row in group if int(row["score_after_repair"]) <= threshold)
            summary["after_repair_score_le_{}_rate".format(threshold)] = rate(group, lambda row, t=threshold: int(row["score_after_repair"]) <= t)
        out.append(summary)
    return out


def normalize_tuple_classes(text):
    values = parse_csv(text)
    if len(values) == 1 and values[0].lower() == "all":
        return parse_csv(ALL_TUPLE_CLASSES)
    return [base.normalize_tuple_id(value) for value in values]


def load_fixture_candidates(args, wanted):
    tuple_registry = base.load_tuple_registry(args.tuple_registry)
    rows = []
    if not str(args.frontier_files).strip():
        return rows
    for path in parse_csv(args.frontier_files):
        if not path or not os.path.exists(path):
            continue
        for idx, raw in enumerate(base.read_jsonl(path)):
            blocks = [set(int(x) % int(args.p) for x in block) for block in raw.get("blocks", [])]
            if len(blocks) != 4:
                continue
            ks = [len(block) for block in blocks]
            lam = int(raw.get("lambda", raw.get("lam", 0)))
            tuple_class = base.normalize_tuple_id(raw.get("tuple_class") or raw.get("tuple_class_id") or "")
            if not tuple_class:
                tuple_class = base.infer_tuple_class(ks, lam, tuple_registry)
            if tuple_class not in wanted:
                continue
            score = int(raw.get("score", raw.get("initial_score", base.P37.score_blocks(int(args.p), blocks, lam))))
            rows.append(
                {
                    "frontier_candidate_id": raw.get("frontier_candidate_id") or raw.get("candidate_id") or "{}:{:05d}".format(path, idx),
                    "source_file": raw.get("source_file", path),
                    "source_run": raw.get("source_run", ""),
                    "source_label": raw.get("source_label") or raw.get("label", ""),
                    "source_method": raw.get("source_method", ""),
                    "tuple_class": tuple_class,
                    "frontier_bucket": raw.get("frontier_bucket") or base.bucket_for_candidate(tuple_class, score, raw),
                    "initial_score": score,
                    "lambda": lam,
                    "ks": ks,
                    "blocks": [[int(x) for x in sorted(block)] for block in blocks],
                    "canonical_hash_before": raw.get("candidate_hash") or raw.get("canonical_hash_before") or base.canonical_hash(blocks),
                }
            )
    deduped = []
    seen = set()
    for row in sorted(rows, key=lambda r: (r["tuple_class"], int(r["initial_score"]), r["frontier_bucket"], r["frontier_candidate_id"])):
        if row["canonical_hash_before"] in seen:
            continue
        seen.add(row["canonical_hash_before"])
        deduped.append(row)
    return deduped


def synthetic_candidate_for_tuple(tuple_class, tuple_row, rep_idx, args):
    p = int(args.p)
    seed = int(args.base_seed) + stable_int("synthetic:{}:{}".format(tuple_class, rep_idx)) % 100000000
    rng = random.Random(seed)
    blocks = [random_block(p, int(size), rng) for size in tuple_row["ks"]]
    if int(args.source_repair_budget) > 0:
        blocks, _, _, _ = base.P37.repair_candidate(
            p,
            [set(block) for block in blocks],
            int(tuple_row["lambda"]),
            int(args.source_repair_budget),
            seed + 31337,
            int(args.source_repair_swap_sample_count),
        )
    score = base.P37.score_blocks(p, blocks, int(tuple_row["lambda"]))
    return {
        "frontier_candidate_id": "synthetic_{}_{:02d}".format(tuple_class, rep_idx),
        "source_file": "synthetic_from_tuple_registry",
        "source_run": "",
        "source_label": "deterministic_random_fixed_size_source",
        "source_method": "random_fixed_size_source_repair_budget_{}".format(int(args.source_repair_budget)),
        "tuple_class": tuple_class,
        "frontier_bucket": "synthetic_tuple_representative",
        "initial_score": int(score),
        "lambda": int(tuple_row["lambda"]),
        "ks": [int(x) for x in tuple_row["ks"]],
        "blocks": [[int(x) for x in sorted(block)] for block in blocks],
        "canonical_hash_before": base.canonical_hash(blocks),
    }


def load_lift_candidates(args):
    wanted = normalize_tuple_classes(args.tuple_classes)
    tuple_registry = base.load_tuple_registry(args.tuple_registry)
    rows = load_fixture_candidates(args, set(wanted))
    by_tuple = {tuple_class: [] for tuple_class in wanted}
    seen = set()
    for row in rows:
        key = row["canonical_hash_before"]
        if key in seen:
            continue
        seen.add(key)
        by_tuple.setdefault(row["tuple_class"], []).append(row)
    reps = max(1, int(args.representatives_per_tuple))
    if args.auto_tuple_representatives:
        for tuple_class in wanted:
            tuple_row = tuple_registry.get(tuple_class)
            if not tuple_row:
                continue
            rep_idx = 0
            while len(by_tuple.get(tuple_class, [])) < reps:
                candidate = synthetic_candidate_for_tuple(tuple_class, tuple_row, rep_idx, args)
                rep_idx += 1
                if candidate["canonical_hash_before"] in seen:
                    continue
                seen.add(candidate["canonical_hash_before"])
                by_tuple.setdefault(tuple_class, []).append(candidate)
    selected = []
    for tuple_class in wanted:
        selected.extend(by_tuple.get(tuple_class, [])[:reps])
    if int(args.frontier_count) > 0 and not args.auto_tuple_representatives:
        selected = selected[: int(args.frontier_count)]
    for idx, row in enumerate(selected):
        row["frontier_candidate_id"] = "frontier_{:04d}".format(idx)
    if args.smoke:
        selected = selected[: max(1, int(args.frontier_count))]
    if not selected:
        raise ValueError("no lift candidates loaded")
    return selected


def best_rows(rows, limit=100):
    return sorted(rows, key=lambda row: (int(row["score_after_repair"]), int(row["score_generated"]), int(row["target_loss_total"])))[:limit]


def threshold_rows(rows, threshold):
    return [row for row in rows if int(row["score_generated"]) <= threshold or int(row["score_after_repair"]) <= threshold]


ROW_FIELDS = [
    "run_id",
    "shard_id",
    "candidate_id",
    "tuple_class",
    "frontier_bucket",
    "source_run",
    "lambda",
    "ks",
    "source_score",
    "source_pair_residual",
    "split_mode",
    "target_mode",
    "left_init_mode",
    "right_init_mode",
    "restart_id",
    "seed",
    "left_target_loss_start",
    "left_target_loss",
    "left_lift_accepted_steps",
    "left_lift_uphill_steps",
    "right_target_loss_start",
    "right_target_loss",
    "right_lift_accepted_steps",
    "right_lift_uphill_steps",
    "target_loss_total",
    "score_generated",
    "score_after_repair",
    "score_improvement_from_generated",
    "score_improvement_from_source_after_repair",
    "pair_residual_generated",
    "pair_residual_improvement_from_source",
    "repair_operator",
    "repair_steps_used",
    "repair_improved",
    "wall_time_ms",
    "canonical_hash_generated",
    "canonical_hash_after",
] + ["generated_score_le_{}".format(t) for t in THRESHOLDS] + ["after_repair_score_le_{}".format(t) for t in THRESHOLDS]


def write_readme(out_dir, config, rows, tuple_summary, target_summary):
    best = best_rows(rows, 10)
    non_seed_seed = [row for row in rows if not (row["left_init_mode"] == "seed" and row["right_init_mode"] == "seed")]
    lines = [
        "# p167 pair profile lift smoke",
        "",
        "This is a broad, shallow test of the pair split profile -> block lift representation. It is not a repair-depth run, filter, classifier, or reranker experiment.",
        "",
        "The fixed split is `fixed_01_23`: pair A = (X0, X1), pair B = (X2, X3). A target profile `T(d)` is generated first, then `(X0, X1)` is lifted toward `T(d)` and `(X2, X3)` is lifted toward `lambda - T(d)`.",
        "",
        "## Run",
        "",
        "- run_id: `{}`".format(config["run_id"]),
        "- row_count: `{}`".format(len(rows)),
        "- candidate_count: `{}`".format(config["candidate_count"]),
        "- tuple_classes: `{}`".format(config["tuple_classes"]),
        "- split_modes: `{}`".format(config["split_modes"]),
        "- target_modes: `{}`".format(config["target_modes"]),
        "- init_modes: `{}`".format(config["init_modes"]),
        "- lift_steps: `{}`".format(config["lift_steps"]),
        "- swap_sample_count: `{}`".format(config["swap_sample_count"]),
        "- repair_budget: `{}`".format(config["repair_budget"]),
        "",
        "## Direct Answers",
        "",
        "1. Did pair-profile lift generate score <= 300: `{}`".format(any(int(row["score_generated"]) <= 300 for row in rows)),
        "2. Did pair-profile lift generate score <= 200: `{}`".format(any(int(row["score_generated"]) <= 200 for row in rows)),
        "3. Did pair-profile lift repair to score <= 300: `{}`".format(any(int(row["score_after_repair"]) <= 300 for row in rows)),
        "4. Did pair-profile lift repair to score <= 200: `{}`".format(any(int(row["score_after_repair"]) <= 200 for row in rows)),
        "5. Did score0 appear: `{}`".format(any(int(row["score_after_repair"]) == 0 or int(row["score_generated"]) == 0 for row in rows)),
        "6. Did lift beat the source wall after repair: `{}`".format(any(int(row["score_after_repair"]) < int(row["source_score"]) for row in rows)),
        "7. Best non-seed/seed after-repair score: `{}`".format(min([int(row["score_after_repair"]) for row in non_seed_seed], default=None)),
        "",
        "## Best Rows",
        "",
        base.markdown_table(best, ["tuple_class", "source_score", "score_generated", "score_after_repair", "split_mode", "target_mode", "left_init_mode", "right_init_mode", "target_loss_total", "pair_residual_generated", "repair_steps_used"], limit=10),
        "",
        "## Tuple Summary",
        "",
        base.markdown_table(tuple_summary, ["tuple_class", "row_count", "best_score_generated", "best_score_after_repair", "median_score_after_repair", "best_target_loss_total", "best_pair_residual_generated", "diversity_hash_count"], limit=20),
        "",
        "## Target Mode Summary",
        "",
        base.markdown_table(target_summary, ["target_mode", "row_count", "best_score_generated", "best_score_after_repair", "median_score_after_repair", "best_target_loss_total", "best_pair_residual_generated", "diversity_hash_count"], limit=20),
        "",
        "## Interpretation",
        "",
        "- A useful signal is not just low score; it is low `target_loss_total` together with better generated/repaired score than random lift.",
        "- If target losses improve but score remains poor, pair-profile lift is underconstrained and needs additional constraints.",
        "- If one target mode consistently gives lower scores, it is the candidate representation to expand.",
        "",
    ]
    with open(os.path.join(out_dir, "README.md"), "w") as f:
        f.write("\n".join(lines))


def write_next_actions(out_dir, rows):
    best = best_rows(rows, 5)
    lines = [
        "# Next actions",
        "",
        "1. If any target mode gives substantially lower generated or repaired scores, expand only that target mode with more restarts.",
        "2. If target loss falls but score stays high, add constraints to the lift, such as per-block defect contribution, Fourier magnitude, or cross-pair consistency.",
        "3. If seed initialization dominates random initialization, explore structured perturbations of existing c01/c05 wall pairs.",
        "4. If random initialization works comparably, move toward a pure pair-profile generator.",
        "",
        "Best observed rows:",
        "",
        base.markdown_table(best, ["tuple_class", "source_score", "score_generated", "score_after_repair", "split_mode", "target_mode", "left_init_mode", "right_init_mode", "target_loss_total"], limit=5),
        "",
    ]
    with open(os.path.join(out_dir, "next_actions.md"), "w") as f:
        f.write("\n".join(lines))


def write_outputs(args, rows, candidates, out_dir):
    ensure_dir(out_dir)
    tuple_summary = summarize_group(rows, ["tuple_class"])
    split_summary = summarize_group(rows, ["split_mode"])
    target_summary = summarize_group(rows, ["target_mode"])
    init_summary = summarize_group(rows, ["left_init_mode", "right_init_mode"])
    tuple_target_summary = summarize_group(rows, ["tuple_class", "target_mode"])
    tuple_split_summary = summarize_group(rows, ["tuple_class", "split_mode"])
    config = {
        "experiment_name": args.experiment_name,
        "run_id": args.run_id,
        "candidate_count": len(candidates),
        "row_count": len(rows),
        "frontier_files": args.frontier_files,
        "tuple_classes": args.tuple_classes,
        "representatives_per_tuple": int(args.representatives_per_tuple),
        "auto_tuple_representatives": bool(args.auto_tuple_representatives),
        "source_repair_budget": int(args.source_repair_budget),
        "split_modes": args.split_modes,
        "target_modes": args.target_modes,
        "init_modes": args.init_modes,
        "restarts_per_cell": int(args.restarts_per_cell),
        "lift_steps": int(args.lift_steps),
        "swap_sample_count": int(args.swap_sample_count),
        "temperature": float(args.temperature),
        "repair_budget": int(args.repair_budget),
        "shard_id": int(args.shard_id),
        "shard_count": int(args.shard_count),
    }
    write_json(os.path.join(out_dir, "run_config.json"), config)
    write_jsonl(os.path.join(out_dir, "candidate_list.jsonl"), candidates)
    write_jsonl(os.path.join(out_dir, "lift_rows.jsonl"), rows)
    write_csv(os.path.join(out_dir, "lift_rows.csv"), rows, ROW_FIELDS)
    write_csv(os.path.join(out_dir, "tuple_summary.csv"), tuple_summary, sorted({k for row in tuple_summary for k in row}))
    write_csv(os.path.join(out_dir, "split_summary.csv"), split_summary, sorted({k for row in split_summary for k in row}))
    write_csv(os.path.join(out_dir, "target_mode_summary.csv"), target_summary, sorted({k for row in target_summary for k in row}))
    write_csv(os.path.join(out_dir, "init_mode_summary.csv"), init_summary, sorted({k for row in init_summary for k in row}))
    write_csv(os.path.join(out_dir, "tuple_target_summary.csv"), tuple_target_summary, sorted({k for row in tuple_target_summary for k in row}))
    write_csv(os.path.join(out_dir, "tuple_split_summary.csv"), tuple_split_summary, sorted({k for row in tuple_split_summary for k in row}))
    write_jsonl(os.path.join(out_dir, "best_lift_candidates.jsonl"), best_rows(rows, 100))
    for threshold in THRESHOLDS:
        write_jsonl(os.path.join(out_dir, "score_under_{}_candidates.jsonl".format(threshold)), threshold_rows(rows, threshold))
    score0_rows = [row for row in rows if int(row["score_generated"]) == 0 or int(row["score_after_repair"]) == 0]
    score0_dir = os.path.join(out_dir, "score0_candidate_jsons")
    for idx, row in enumerate(score0_rows):
        ensure_dir(score0_dir)
        candidate = {
            "v": int(args.p),
            "n": int(4 * int(args.p)),
            "ks": row["ks"],
            "lambda": int(row["lambda"]),
            "blocks": row["blocks_after_repair"],
        }
        write_json(os.path.join(score0_dir, "score0_{:04d}.json".format(idx)), candidate)
    write_jsonl(os.path.join(out_dir, "score0_candidates.jsonl"), score0_rows)
    write_json(os.path.join(out_dir, "validation_report.json"), {"score0_count": len(score0_rows), "validated_score0_count": 0})
    write_readme(out_dir, config, rows, tuple_summary, target_summary)
    write_next_actions(out_dir, rows)


def run_mode(args):
    candidates = load_lift_candidates(args)
    split_modes = parse_csv(args.split_modes)
    target_modes = parse_csv(args.target_modes)
    init_modes = parse_csv(args.init_modes)
    tasks = shard_tasks(candidates, split_modes, target_modes, init_modes, int(args.restarts_per_cell), int(args.shard_id), int(args.shard_count))
    if args.smoke:
        tasks = tasks[: max(1, int(args.smoke_task_limit))]
    print(
        "pair-profile-lift-start shard={}/{} candidates={} tasks={} split_modes={} target_modes={} init_modes={}".format(
            args.shard_id, args.shard_count, len(candidates), len(tasks), split_modes, target_modes, init_modes
        ),
        flush=True,
    )
    rows = []
    for idx, (candidate, split_mode, target_mode, left_init, right_init, restart_id) in enumerate(tasks, start=1):
        print(
            "task {}/{} candidate={} tuple={} score={} split={} target={} left_init={} right_init={} restart={}".format(
                idx,
                len(tasks),
                candidate["frontier_candidate_id"],
                candidate["tuple_class"],
                candidate["initial_score"],
                split_mode,
                target_mode,
                left_init,
                right_init,
                restart_id,
            ),
            flush=True,
        )
        rows.append(run_one(candidate, split_mode, target_mode, left_init, right_init, restart_id, args))
    write_outputs(args, rows, candidates, args.out_dir)
    print("wrote {} lift rows to {}".format(len(rows), args.out_dir), flush=True)


def aggregate_mode(args):
    rows = []
    by_hash = {}
    for path in Path(args.aggregate_input_dir).rglob("lift_rows.jsonl"):
        rows.extend(base.read_jsonl(str(path)))
    for path in Path(args.aggregate_input_dir).rglob("candidate_list.jsonl"):
        for row in base.read_jsonl(str(path)):
            by_hash[row["canonical_hash_before"]] = row
    candidates = list(by_hash.values())
    write_outputs(args, rows, candidates, args.out_dir)
    print("aggregated {} lift rows to {}".format(len(rows), args.out_dir), flush=True)


def parse_args():
    parser = argparse.ArgumentParser(description="p167 pair split profile to block lift smoke.")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--frontier-files", default=FRONTIER_FIXTURE_DEFAULT)
    parser.add_argument("--tuple-registry", default=base.TUPLE_REGISTRY_DEFAULT)
    parser.add_argument("--tuple-classes", default=TUPLE_CLASSES_DEFAULT)
    parser.add_argument("--frontier-count", "--candidate-count", dest="frontier_count", type=int, default=2)
    parser.add_argument("--representatives-per-tuple", type=int, default=1)
    parser.add_argument("--auto-tuple-representatives", action="store_true")
    parser.add_argument("--split-modes", default="fixed_01_23")
    parser.add_argument("--target-modes", default="midpoint,seed_left,seed_right_complement,lambda_half,jitter_midpoint")
    parser.add_argument("--init-modes", default="random,seed,perturbed_seed")
    parser.add_argument("--restarts-per-cell", type=int, default=12)
    parser.add_argument("--lift-steps", type=int, default=60)
    parser.add_argument("--swap-sample-count", type=int, default=128)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--perturb-swaps", type=int, default=8)
    parser.add_argument("--repair-budget", type=int, default=6)
    parser.add_argument("--repair-swap-sample-count", type=int, default=96)
    parser.add_argument("--source-repair-budget", type=int, default=0)
    parser.add_argument("--source-repair-swap-sample-count", type=int, default=96)
    parser.add_argument("--max-wall-time-ms-per-lift", type=int, default=15000)
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--output-root", default=OUTPUT_ROOT_DEFAULT)
    parser.add_argument("--experiment-name", default=EXPERIMENT_DEFAULT)
    parser.add_argument("--run-id", default="")
    parser.add_argument("--base-seed", type=int, default=167512)
    parser.add_argument("--shard-id", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--smoke-task-limit", type=int, default=2)
    parser.add_argument("--aggregate", action="store_true")
    parser.add_argument("--aggregate-input-dir", default="")
    args = parser.parse_args()
    if not args.run_id:
        args.run_id = "{}-{}".format(args.experiment_name, now_stamp())
    if not args.out_dir:
        args.out_dir = os.path.join(args.output_root, args.run_id)
    return args


def main():
    args = parse_args()
    if args.aggregate:
        aggregate_mode(args)
    else:
        run_mode(args)


if __name__ == "__main__":
    main()
