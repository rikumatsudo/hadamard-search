#!/usr/bin/env python3
import argparse
import csv
import hashlib
import importlib.util
import itertools
import json
import math
import os
import random
import statistics
import sys
import time
from pathlib import Path


P_DEFAULT = 167
TUPLE_CLASSES_DEFAULT = ("p167_c01", "p167_c05", "p167_c09")
FRONTIER_FIXTURE_DEFAULT = "configs/fixtures/p167_frontier_repair_seed_candidates.jsonl"
NEARHIT_FIXTURE_DEFAULT = "configs/fixtures/p167_focused_nearhit_candidates.jsonl"
TUPLE_REGISTRY_DEFAULT = "configs/fixtures/p167_tuple_classes.json"
OUTPUT_ROOT_DEFAULT = "outputs/p167_frontier_repair_benchmark"
EXPERIMENT_DEFAULT = "p167_frontier_repair_benchmark"
OPERATORS_DEFAULT = (
    "score_only_1swap_greedy",
    "exact_joint_2swap_beam",
    "exact_joint_3swap_beam",
    "defect_targeted_destroy_repair",
    "pair_level_partial_defect_repair",
    "restricted_exact_joint_lns",
)
THRESHOLDS = (1000, 800, 600, 500, 400, 300, 240, 200, 180, 160, 120, 100)
PAIR_SPLITS = {
    "fixed_01_23": ((0, 1), (2, 3)),
    "fixed_02_13": ((0, 2), (1, 3)),
    "fixed_03_12": ((0, 3), (1, 2)),
}


def load_p37_module():
    module_path = Path(__file__).with_name("p37_mixed3_movespace_guard.py")
    spec = importlib.util.spec_from_file_location("p37_mixed3_movespace_guard", module_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


P37 = load_p37_module()


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


def read_jsonl(path):
    if not path or not os.path.exists(path):
        return []
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


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


def quantile(values, q):
    vals = sorted(float(v) for v in values if v is not None)
    if not vals:
        return None
    pos = (len(vals) - 1) * float(q)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return vals[lo]
    return vals[lo] * (hi - pos) + vals[hi] * (pos - lo)


def canonical_hash(blocks):
    payload = [[int(x) for x in sorted(block)] for block in blocks]
    text = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def normalize_tuple_id(value):
    value = str(value).strip()
    if value.startswith("p167_"):
        return value
    if value.startswith("c") and len(value) == 3:
        return "p167_" + value
    return value


def candidate_json(blocks, p, ks, lam):
    return {
        "v": int(p),
        "n": int(4 * p),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": [[int(x) for x in sorted(block)] for block in blocks],
    }


def load_tuple_registry(path):
    with open(path) as f:
        data = json.load(f)
    out = {}
    for row in data.get("tuple_classes", []):
        out[row["tuple_class_id"]] = {
            "tuple_class": row["tuple_class_id"],
            "ks": [int(x) for x in row["representative_tuple"]],
            "lambda": int(row["lambda"]),
        }
    return out


def infer_tuple_class(ks, lam, tuple_registry):
    ks = [int(x) for x in ks]
    for tuple_class, row in tuple_registry.items():
        if row["ks"] == ks and int(row["lambda"]) == int(lam):
            return tuple_class
    return "unknown"


def load_frontier_candidates(args):
    tuple_registry = load_tuple_registry(args.tuple_registry)
    wanted = set(normalize_tuple_id(x) for x in parse_csv(args.tuple_classes))
    rows = []
    for path in parse_csv(args.frontier_files):
        for idx, row in enumerate(read_jsonl(path)):
            blocks = [set(int(x) % int(args.p) for x in block) for block in row.get("blocks", [])]
            if len(blocks) != 4:
                continue
            ks = [len(block) for block in blocks]
            lam = int(row.get("lambda", row.get("lam", 0)))
            tuple_class = normalize_tuple_id(row.get("tuple_class") or row.get("tuple_class_id") or "")
            if not tuple_class:
                tuple_class = infer_tuple_class(ks, lam, tuple_registry)
            if tuple_class not in wanted:
                continue
            score = int(row.get("score", P37.score_blocks(int(args.p), blocks, lam)))
            candidate_hash = row.get("candidate_hash") or canonical_hash(blocks)
            out = {
                "frontier_candidate_id": row.get("frontier_candidate_id") or "frontier_{:05d}".format(len(rows)),
                "source_file": row.get("source_file", path),
                "source_run": row.get("source_run", ""),
                "source_label": row.get("source_label") or row.get("label", ""),
                "source_method": row.get("source_method", ""),
                "tuple_class": tuple_class,
                "frontier_bucket": row.get("frontier_bucket") or bucket_for_candidate(tuple_class, score, row),
                "initial_score": score,
                "lambda": lam,
                "ks": ks,
                "blocks": [[int(x) for x in sorted(block)] for block in blocks],
                "canonical_hash_before": candidate_hash,
            }
            rows.append(out)
    deduped = []
    seen = set()
    for row in sorted(rows, key=lambda r: (r["tuple_class"], r["frontier_bucket"], r["initial_score"], r["frontier_candidate_id"])):
        key = row["canonical_hash_before"]
        if key in seen:
            continue
        seen.add(key)
        row["frontier_candidate_id"] = "frontier_{:04d}".format(len(deduped))
        deduped.append(row)
    if int(args.frontier_count) > 0:
        deduped = balanced_frontier_sample(deduped, int(args.frontier_count), sorted(wanted))
    if args.smoke:
        deduped = deduped[: max(1, int(args.frontier_count))]
    if not deduped:
        raise ValueError("no frontier candidates loaded")
    return deduped


def bucket_for_candidate(tuple_class, score, row):
    if tuple_class == "p167_c09" and score <= 240:
        return "known_low_score_frontier"
    if tuple_class == "p167_c09":
        return "trap_like_control"
    if tuple_class == "p167_c01":
        return "c01_production_like_generated"
    if tuple_class == "p167_c05":
        return "c05_damage_caution_generated"
    return "diversity_control"


def balanced_frontier_sample(rows, target_count, tuple_order):
    by_tuple = {tuple_class: [] for tuple_class in tuple_order}
    for row in rows:
        by_tuple.setdefault(row["tuple_class"], []).append(row)
    target_per_tuple = max(1, target_count // max(1, len(tuple_order)))
    out = []
    for tuple_class in tuple_order:
        bucketed = {}
        for row in by_tuple.get(tuple_class, []):
            bucketed.setdefault(row["frontier_bucket"], []).append(row)
        picked = []
        while len(picked) < target_per_tuple and any(bucketed.values()):
            for bucket in sorted(bucketed):
                if bucketed[bucket] and len(picked) < target_per_tuple:
                    picked.append(bucketed[bucket].pop(0))
        out.extend(picked)
    if len(out) < target_count:
        seen = {row["canonical_hash_before"] for row in out}
        for row in rows:
            if row["canonical_hash_before"] not in seen:
                out.append(row)
                seen.add(row["canonical_hash_before"])
            if len(out) >= target_count:
                break
    return out[:target_count]


def rho_vector(p, blocks, lam):
    return P37.rho_vector(p, blocks, lam)


def score_from_rho(rho):
    return P37.score_from_rho(rho)


def exact_joint_delta_rho(p, block, removes, adds):
    """Exact joint multi-swap update.

    For block indicator f and h = 1_B - 1_R:
    Delta n = h*f_tilde + f*h_tilde + h*h_tilde.
    """
    f = set(int(x) for x in block)
    h = {}
    for x in removes:
        h[int(x) % p] = h.get(int(x) % p, 0) - 1
    for x in adds:
        h[int(x) % p] = h.get(int(x) % p, 0) + 1
    support = [x for x, coeff in h.items() if coeff != 0]
    delta = [0] * p
    for d in range(p):
        total = 0
        for s in support:
            coeff = h[s]
            if (s - d) % p in f:
                total += coeff
        for s in f:
            total += h.get((s - d) % p, 0)
        for s in support:
            total += h[s] * h.get((s - d) % p, 0)
        delta[d] = total
    return delta


def exact_joint_score(p, rho, current_score, block, removes, adds):
    delta = exact_joint_delta_rho(p, block, removes, adds)
    score = 0
    for d in range(1, p):
        v = int(rho[d]) + int(delta[d])
        score += v * v
    return int(score), delta


def apply_joint_move(blocks, bidx, removes, adds):
    out = [set(block) for block in blocks]
    for x in removes:
        out[bidx].remove(int(x))
    for x in adds:
        out[bidx].add(int(x))
    return out


def element_remove_scores(p, block, rho):
    values = list(block)
    scores = {}
    for x in values:
        score = 0.0
        for y in values:
            if x == y:
                continue
            score += max(0, rho[(int(x) - int(y)) % p])
            score += max(0, rho[(int(y) - int(x)) % p])
        scores[int(x)] = score
    return scores


def element_add_scores(p, block, rho):
    values = list(block)
    outside = [x for x in range(p) if x not in block]
    scores = {}
    for x in outside:
        score = 0.0
        for y in values:
            score += max(0, -rho[(int(x) - int(y)) % p])
            score += max(0, -rho[(int(y) - int(x)) % p])
        scores[int(x)] = score
    return scores


def build_pools(p, blocks, rho, pool_size, rng, mode="defect"):
    pools = []
    for block in blocks:
        remove_scores = element_remove_scores(p, block, rho)
        add_scores = element_add_scores(p, block, rho)
        removes = [x for x, _ in sorted(remove_scores.items(), key=lambda item: (-item[1], item[0]))[: int(pool_size)]]
        adds = [x for x, _ in sorted(add_scores.items(), key=lambda item: (-item[1], item[0]))[: int(pool_size)]]
        if mode == "random":
            block_values = list(block)
            outside = [x for x in range(p) if x not in block]
            removes = rng.sample(block_values, min(int(pool_size), len(block_values)))
            adds = rng.sample(outside, min(int(pool_size), len(outside)))
        pools.append((removes, adds))
    return pools


def joint_move_candidates(removes, adds, radius, rng, cap):
    radius = int(radius)
    cap = int(cap)
    if radius <= 0 or cap <= 0:
        return
    removes = list(removes)
    adds = list(adds)
    if len(removes) < radius or len(adds) < radius:
        return
    remove_count = math.comb(len(removes), radius)
    add_count = math.comb(len(adds), radius)
    total = remove_count * add_count
    if total <= cap:
        for rcombo in itertools.combinations(removes, radius):
            for acombo in itertools.combinations(adds, radius):
                yield rcombo, acombo
        return
    seen = set()
    attempts = 0
    # Do not materialize combinations for large radius/pools. For p167 radius 7,
    # 72 choose 7 is enormous; sample capped joint moves lazily instead.
    while len(seen) < cap and attempts < cap * 20:
        attempts += 1
        rcombo = tuple(sorted(rng.sample(removes, radius)))
        acombo = tuple(sorted(rng.sample(adds, radius)))
        key = (rcombo, acombo)
        if key in seen:
            continue
        seen.add(key)
        yield rcombo, acombo


def pair_loss(p, blocks, lam, selected_split):
    return P37.pair_loss(p, blocks, lam, selected_split)


def choose_pair_split(seed):
    keys = sorted(PAIR_SPLITS)
    return keys[int(seed) % len(keys)]


def move_objective(p, blocks, lam, score, operator, selected_split):
    if operator == "pair_level_partial_defect_repair":
        return float(score) + 0.05 * pair_loss(p, blocks, lam, selected_split)
    return float(score)


def best_joint_move(
    p,
    blocks,
    lam,
    rho,
    current_score,
    operator,
    radius_values,
    pool_size,
    beam_width,
    eval_cap,
    rng,
    selected_split,
    started,
    max_wall_time_ms,
):
    pools = build_pools(p, blocks, rho, pool_size, rng, mode="defect")
    best = None
    evaluated = 0
    exact_evals = 0
    timed_out = False
    per_block_cap = max(1, int(eval_cap) // max(1, len(blocks) * len(radius_values)))
    for radius in radius_values:
        for bidx, (removes, adds) in enumerate(pools):
            if len(removes) < radius or len(adds) < radius:
                continue
            candidates = joint_move_candidates(removes, adds, radius, rng, per_block_cap)
            for rcombo, acombo in candidates:
                if (time.time() - started) * 1000.0 >= float(max_wall_time_ms):
                    timed_out = True
                    return best, evaluated, exact_evals, timed_out
                score, _delta = exact_joint_score(p, rho, current_score, blocks[bidx], rcombo, acombo)
                exact_evals += 1
                evaluated += 1
                trial_blocks = None
                obj = float(score)
                if operator == "pair_level_partial_defect_repair":
                    trial_blocks = apply_joint_move(blocks, bidx, rcombo, acombo)
                    obj = move_objective(p, trial_blocks, lam, score, operator, selected_split)
                if best is None or obj < best["objective"]:
                    best = {
                        "score": int(score),
                        "objective": float(obj),
                        "bidx": int(bidx),
                        "removes": [int(x) for x in rcombo],
                        "adds": [int(x) for x in acombo],
                        "radius": int(radius),
                        "trial_blocks": trial_blocks,
                    }
    return best, evaluated, exact_evals, timed_out


def repair_operator_config(operator, args):
    if operator == "score_only_1swap_greedy":
        return [1], int(args.pool_size), int(args.beam_width), int(args.eval_cap_per_step)
    if operator == "exact_joint_2swap_beam":
        return [2], int(args.pool_size), int(args.beam_width), int(args.eval_cap_per_step)
    if operator == "exact_joint_3swap_beam":
        return [3], int(args.pool_size), int(args.beam_width), int(args.eval_cap_per_step)
    if operator == "defect_targeted_destroy_repair":
        return [1, 2], int(args.pool_size), int(args.beam_width), int(args.eval_cap_per_step)
    if operator == "pair_level_partial_defect_repair":
        return [1, 2], int(args.pool_size), int(args.beam_width), int(args.eval_cap_per_step)
    if operator == "restricted_exact_joint_lns":
        return list(range(1, int(args.lns_radius) + 1)), int(args.lns_pool_size), int(args.beam_width), int(args.eval_cap_per_step)
    if operator == "optional_small_cpsat_local_branching":
        return [1, 2, 3], min(int(args.lns_pool_size), 14), int(args.beam_width), max(1, int(args.eval_cap_per_step) // 2)
    raise ValueError("unknown repair operator {}".format(operator))


def repair_candidate_with_operator(p, blocks, lam, operator, seed, args):
    rng = random.Random(int(seed))
    current = [set(block) for block in blocks]
    current_score = P37.score_blocks(p, current, lam)
    best_intermediate = current_score
    started = time.time()
    steps = 0
    total_evaluated = 0
    total_exact = 0
    timeout = False
    selected_split = choose_pair_split(seed)
    radius_values, pool_size, beam_width, eval_cap = repair_operator_config(operator, args)
    while steps < int(args.max_repair_steps) and current_score > 0:
        if (time.time() - started) * 1000.0 >= float(args.max_wall_time_ms):
            timeout = True
            break
        rho = rho_vector(p, current, lam)
        move, evaluated, exact_evals, step_timeout = best_joint_move(
            p,
            current,
            lam,
            rho,
            current_score,
            operator,
            radius_values,
            pool_size,
            beam_width,
            eval_cap,
            rng,
            selected_split,
            started,
            float(args.max_wall_time_ms),
        )
        total_evaluated += evaluated
        total_exact += exact_evals
        timeout = timeout or step_timeout
        if move is None or int(move["score"]) >= int(current_score):
            break
        current = move.get("trial_blocks") or apply_joint_move(current, move["bidx"], move["removes"], move["adds"])
        current_score = int(move["score"])
        best_intermediate = min(best_intermediate, current_score)
        steps += 1
    elapsed_ms = int(round((time.time() - started) * 1000.0))
    return {
        "blocks_after": current,
        "score_after": int(current_score),
        "best_intermediate_score": int(best_intermediate),
        "steps_used": int(steps),
        "beam_width": int(beam_width),
        "pool_size_remove": int(pool_size),
        "pool_size_add": int(pool_size),
        "evaluated_moves_count": int(total_evaluated),
        "exact_joint_evaluations_count": int(total_exact),
        "wall_time_ms": int(elapsed_ms),
        "timeout_flag": bool(timeout),
    }


def restricted_dmin_score(p, blocks, lam, radii, sample_cap, seed):
    rng = random.Random(int(seed))
    score = P37.score_blocks(p, blocks, lam)
    rho = rho_vector(p, blocks, lam)
    pools = build_pools(p, blocks, rho, max(8, min(20, int(math.sqrt(max(1, sample_cap))))), rng, mode="defect")
    best = int(score)
    evals = 0
    per = max(1, int(sample_cap) // max(1, len(radii) * len(blocks)))
    for radius in radii:
        for bidx, (removes, adds) in enumerate(pools):
            if len(removes) < radius or len(adds) < radius:
                continue
            for rcombo, acombo in joint_move_candidates(removes, adds, radius, rng, per):
                s, _ = exact_joint_score(p, rho, score, blocks[bidx], rcombo, acombo)
                best = min(best, int(s))
                evals += 1
    return best, evals


def build_repair_row(frontier, operator, args):
    p = int(args.p)
    blocks = [set(int(x) for x in block) for block in frontier["blocks"]]
    lam = int(frontier["lambda"])
    seed = int(args.base_seed) + int(args.shard_id) * 10000000 + stable_int(frontier["frontier_candidate_id"]) % 100000 + stable_int(operator) % 10000
    score_before = P37.score_blocks(p, blocks, lam)
    result = repair_candidate_with_operator(p, blocks, lam, operator, seed, args)
    after = result["score_after"]
    improvement = int(score_before) - int(after)
    diagnostic_cap = int(args.dmin_sample_count)
    d1, d1_evals = restricted_dmin_score(p, result["blocks_after"], lam, [1], diagnostic_cap, seed + 101)
    d2, d2_evals = restricted_dmin_score(p, result["blocks_after"], lam, [1, 2], diagnostic_cap, seed + 202)
    d3, d3_evals = restricted_dmin_score(p, result["blocks_after"], lam, [1, 2, 3], diagnostic_cap, seed + 303)
    d5, d5_evals = restricted_dmin_score(p, result["blocks_after"], lam, [1, 2, 3, 4, 5], diagnostic_cap, seed + 505)
    row = {
        "run_id": args.run_id,
        "shard_id": int(args.shard_id),
        "frontier_candidate_id": frontier["frontier_candidate_id"],
        "source_file": frontier.get("source_file"),
        "tuple_class": frontier["tuple_class"],
        "frontier_bucket": frontier["frontier_bucket"],
        "initial_score": int(frontier["initial_score"]),
        "lambda": int(lam),
        "repair_operator": operator,
        "repair_seed": int(seed),
        "score_before": int(score_before),
        "score_after": int(after),
        "score_improvement": int(improvement),
        "improvement_rate": float(improvement) / float(max(1, score_before)),
        "best_intermediate_score": int(result["best_intermediate_score"]),
        "steps_used": int(result["steps_used"]),
        "beam_width": int(result["beam_width"]),
        "pool_size_remove": int(result["pool_size_remove"]),
        "pool_size_add": int(result["pool_size_add"]),
        "evaluated_moves_count": int(result["evaluated_moves_count"]),
        "exact_joint_evaluations_count": int(result["exact_joint_evaluations_count"]),
        "wall_time_ms": int(result["wall_time_ms"]),
        "timeout_flag": bool(result["timeout_flag"]),
        "D_min_1_full_score": None,
        "D_min_2_score": int(d2),
        "D_min_2_mode": "restricted_exact_joint_sampled",
        "D_min_3_score": int(d3),
        "D_min_3_mode": "restricted_exact_joint_sampled",
        "D_min_5_score": int(d5),
        "D_min_5_mode": "restricted_exact_joint_sampled",
        "D_min_1_restricted_score": int(d1),
        "D_min_1_restricted_evaluations": int(d1_evals),
        "D_min_2_evaluations": int(d2_evals),
        "D_min_3_evaluations": int(d3_evals),
        "D_min_5_evaluations": int(d5_evals),
        "canonical_hash_before": frontier["canonical_hash_before"],
        "canonical_hash_after": canonical_hash(result["blocks_after"]),
        "candidate_json_path_if_saved": "",
        "blocks_after": candidate_json(result["blocks_after"], p, [len(b) for b in result["blocks_after"]], lam)["blocks"],
    }
    for threshold in THRESHOLDS:
        row["score_after_le_{}".format(threshold)] = bool(int(after) <= threshold)
    return row


def stable_int(text):
    return int(hashlib.sha256(str(text).encode("utf-8")).hexdigest()[:12], 16)


def shard_tasks(frontier, operators, shard_id, shard_count):
    tasks = []
    for cand in frontier:
        for operator in operators:
            key = "{}::{}".format(cand["frontier_candidate_id"], operator)
            if stable_int(key) % int(shard_count) == int(shard_id):
                tasks.append((cand, operator))
    return tasks


def run_mode(args):
    ensure_dir(args.out_dir)
    frontier = load_frontier_candidates(args)
    operators = parse_csv(args.operators)
    tasks = shard_tasks(frontier, operators, int(args.shard_id), int(args.shard_count))
    if args.smoke:
        tasks = tasks[: max(1, int(args.smoke_task_limit))]
    rows = [build_repair_row(cand, operator, args) for cand, operator in tasks]
    write_outputs(args, rows, frontier, args.out_dir)
    print("wrote {} repair rows to {}".format(len(rows), args.out_dir))


def rate(rows, pred):
    return sum(1 for row in rows if pred(row)) / float(len(rows)) if rows else 0.0


def summarize_group(rows, keys):
    buckets = {}
    for row in rows:
        key = tuple(row.get(k) for k in keys)
        buckets.setdefault(key, []).append(row)
    out = []
    for key, group in sorted(buckets.items(), key=lambda item: item[0]):
        summary = {keys[i]: key[i] for i in range(len(keys))}
        before = [int(row["score_before"]) for row in group]
        after = [int(row["score_after"]) for row in group]
        improvements = [int(row["score_improvement"]) for row in group]
        summary["candidate_count"] = len(group)
        summary["best_score_before"] = min(before) if before else None
        summary["best_score_after"] = min(after) if after else None
        summary["median_score_before"] = median(before)
        summary["median_score_after"] = median(after)
        summary["median_score_improvement"] = median(improvements)
        summary["q75_score_improvement"] = quantile(improvements, 0.75)
        summary["q90_score_improvement"] = quantile(improvements, 0.90)
        summary["improvement_rate"] = rate(group, lambda row: int(row["score_after"]) < int(row["score_before"]))
        for threshold in THRESHOLDS:
            summary["score_after_le_{}_count".format(threshold)] = sum(1 for row in group if int(row["score_after"]) <= threshold)
            summary["score_after_le_{}_rate".format(threshold)] = rate(group, lambda row, t=threshold: int(row["score_after"]) <= t)
        summary["score0_count"] = sum(1 for row in group if int(row["score_after"]) == 0)
        summary["validated_score0_count"] = 0
        summary["best_delta_score"] = max(improvements) if improvements else None
        wall = mean(row.get("wall_time_ms") for row in group)
        summary["wall_time_per_candidate"] = wall
        summary["timeout_rate"] = rate(group, lambda row: bool(row.get("timeout_flag")))
        summary["same_compute_yield"] = (mean(improvements) or 0.0) / max(1.0, (wall or 0.0) / 1000.0)
        summary["exact_joint_evaluations_count"] = sum(int(row.get("exact_joint_evaluations_count") or 0) for row in group)
        out.append(summary)
    return out


def frontier_selection_summary(frontier):
    rows = []
    for keys in (["tuple_class"], ["frontier_bucket"], ["tuple_class", "frontier_bucket"]):
        buckets = {}
        for row in frontier:
            key = tuple(row.get(k) for k in keys)
            buckets.setdefault(key, []).append(row)
        for key, group in sorted(buckets.items()):
            out = {"summary_scope": "+".join(keys)}
            for idx, k in enumerate(keys):
                out[k] = key[idx]
            out["candidate_count"] = len(group)
            out["best_initial_score"] = min(int(row["initial_score"]) for row in group)
            out["median_initial_score"] = median(row["initial_score"] for row in group)
            rows.append(out)
    return rows


def threshold_rows(rows, threshold):
    return [row for row in rows if int(row["score_after"]) <= int(threshold)]


def best_rows(rows, limit=100):
    selected = {}
    for row in threshold_rows(rows, 1000):
        selected[(row["frontier_candidate_id"], row["repair_operator"])] = row
    for row in sorted(rows, key=lambda r: int(r["score_after"]))[:limit]:
        selected[(row["frontier_candidate_id"], row["repair_operator"])] = row
    return list(selected.values())


REPAIR_FIELDS = [
    "run_id",
    "shard_id",
    "frontier_candidate_id",
    "source_file",
    "tuple_class",
    "frontier_bucket",
    "initial_score",
    "repair_operator",
    "repair_seed",
    "score_before",
    "score_after",
    "score_improvement",
    "improvement_rate",
    "best_intermediate_score",
    "steps_used",
    "beam_width",
    "pool_size_remove",
    "pool_size_add",
    "evaluated_moves_count",
    "exact_joint_evaluations_count",
    "wall_time_ms",
    "timeout_flag",
] + ["score_after_le_{}".format(t) for t in THRESHOLDS] + [
    "D_min_1_full_score",
    "D_min_2_score",
    "D_min_2_mode",
    "D_min_3_score",
    "D_min_3_mode",
    "D_min_5_score",
    "D_min_5_mode",
    "canonical_hash_before",
    "canonical_hash_after",
    "candidate_json_path_if_saved",
]


def write_score0_candidates(out_dir, rows):
    score0_rows = [row for row in rows if int(row["score_after"]) == 0]
    payloads = []
    for idx, row in enumerate(score0_rows):
        candidate = {
            "candidate_id": "score0_{:04d}".format(idx),
            "frontier_candidate_id": row["frontier_candidate_id"],
            "repair_operator": row["repair_operator"],
            "tuple_class": row["tuple_class"],
            "score_after": row["score_after"],
            "candidate": {
                "v": int(P_DEFAULT),
                "n": int(4 * P_DEFAULT),
                "ks": [len(block) for block in row["blocks_after"]],
                "lambda": int(row.get("lambda", 0) or 0),
                "blocks": row["blocks_after"],
            },
        }
        payloads.append(candidate)
        path = os.path.join(out_dir, "score0_candidate_{:04d}.json".format(idx))
        write_json(path, candidate["candidate"])
        row["candidate_json_path_if_saved"] = path
    write_jsonl(os.path.join(out_dir, "score0_candidates.jsonl"), score0_rows)
    return score0_rows


def markdown_table(rows, keys, limit=20):
    if not rows:
        return "_none_\n"
    lines = ["|" + "|".join(keys) + "|", "|" + "|".join(["---"] * len(keys)) + "|"]
    for row in rows[:limit]:
        vals = []
        for key in keys:
            value = row.get(key)
            if isinstance(value, float):
                value = "{:.4g}".format(value)
            vals.append(str(value))
        lines.append("|" + "|".join(vals) + "|")
    return "\n".join(lines) + "\n"


def decision_from_summaries(operator_summary):
    any_100 = any(int(row.get("score_after_le_100_count") or 0) > 0 for row in operator_summary)
    any_160 = any(int(row.get("score_after_le_160_count") or 0) > 0 for row in operator_summary)
    any_500 = any(int(row.get("score_after_le_500_count") or 0) > 0 for row in operator_summary)
    if any_100 or any_160 or any_500:
        return "Strong GO"
    if not operator_summary:
        return "No GO"
    best = sorted(operator_summary, key=lambda row: int(row.get("best_score_after") or 10**9))[0]
    baseline = next((row for row in operator_summary if row.get("repair_operator") == "score_only_1swap_greedy"), None)
    if baseline and int(best["best_score_after"]) < int(baseline["best_score_after"]):
        return "Weak GO"
    return "No GO"


def write_readme(out_dir, config, frontier_summary, operator_summary, tuple_operator_summary, bucket_operator_summary):
    best_ops = sorted(operator_summary, key=lambda row: int(row.get("best_score_after") or 10**9))
    best_median = sorted(operator_summary, key=lambda row: -(float(row.get("median_score_improvement") or 0.0)))
    decision = decision_from_summaries(operator_summary)
    lines = [
        "# p167 frontier repair benchmark",
        "",
        "This is a repair benchmark on existing frontier candidates, not a generator, filter, classifier, or reranker experiment.",
        "",
        "Exact joint multi-swap update used for multi-swap scoring:",
        "",
        "Delta n = h*f_tilde + f*h_tilde + h*h_tilde",
        "",
        "where h = 1_B - 1_R for remove set R and add set B.",
        "",
        "## Run",
        "",
        "- run_id: `{}`".format(config["run_id"]),
        "- frontier candidates: `{}`".format(config["frontier_candidate_count"]),
        "- repair rows: `{}`".format(config["total_repair_rows"]),
        "- operators: `{}`".format(config["operators"]),
        "- shard_count: `{}`".format(config["shard_count"]),
        "",
        "## Frontier selection",
        "",
        markdown_table(frontier_summary, ["summary_scope", "tuple_class", "frontier_bucket", "candidate_count", "best_initial_score", "median_initial_score"], limit=30),
        "## Operator summary",
        "",
        markdown_table(best_ops, ["repair_operator", "candidate_count", "best_score_after", "median_score_improvement", "improvement_rate", "same_compute_yield", "timeout_rate"], limit=20),
        "## Required answers",
        "",
        "1. Best score operator: `{}`.".format(best_ops[0]["repair_operator"] if best_ops else "none"),
        "2. Best median improvement operator: `{}`.".format(best_median[0]["repair_operator"] if best_median else "none"),
        "3. Same-compute efficiency is in `operator_summary.csv` as `same_compute_yield`.",
        "4. score160 frontier improvement is visible in `score_under_160_candidates.jsonl` if non-empty.",
        "5. score1000/500/300/200 thresholds are written as threshold artifacts.",
        "6. Tuple-specific behavior is in `tuple_operator_summary.csv`.",
        "7. Pair-level repair comparison is the `pair_level_partial_defect_repair` row.",
        "8. Exact-joint 2/3-swap beam comparison is in operator summary.",
        "9. Restricted LNS comparison is the `restricted_exact_joint_lns` row.",
        "10. CP-SAT local branching is optional and not part of the default production operator list.",
        "11. Decision: `{}`.".format(decision),
        "",
        "## Notes",
        "",
        "- score0, if present, is only a candidate until Sage verifies SDS and HH^T = 668I.",
        "- This run does not claim a Hadamard 668 construction.",
        "- D_min r>=2 diagnostics are restricted sampled/beam proxies unless explicitly marked full.",
    ]
    with open(os.path.join(out_dir, "README.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(out_dir, "next_actions.md"), "w") as f:
        f.write(
            "# next actions\n\n"
            "- Expand the best repair operator only if it improves the score160/164/176 frontier or pushes medium candidates below 500.\n"
            "- If exact-joint and LNS do not beat score-only, inspect pool construction before increasing compute.\n"
            "- Keep c09 as benchmark/trap control; do not optimize solely for c09.\n"
        )
    return decision


def write_outputs(args, rows, frontier, out_dir):
    ensure_dir(out_dir)
    frontier_summary = frontier_selection_summary(frontier)
    operator_summary = summarize_group(rows, ["repair_operator"])
    tuple_operator_summary = summarize_group(rows, ["tuple_class", "repair_operator"])
    bucket_operator_summary = summarize_group(rows, ["frontier_bucket", "repair_operator"])
    score0_rows = write_score0_candidates(out_dir, rows)
    config = {
        "run_id": args.run_id,
        "p": int(args.p),
        "frontier_candidate_count": len(frontier),
        "total_repair_rows": len(rows),
        "operators": parse_csv(args.operators),
        "max_repair_steps": int(args.max_repair_steps),
        "pool_size": int(args.pool_size),
        "lns_pool_size": int(args.lns_pool_size),
        "beam_width": int(args.beam_width),
        "eval_cap_per_step": int(args.eval_cap_per_step),
        "max_wall_time_ms": int(args.max_wall_time_ms),
        "shard_id": int(args.shard_id),
        "shard_count": int(args.shard_count),
    }
    write_json(os.path.join(out_dir, "run_config.json"), config)
    write_json(os.path.join(out_dir, "validation_report.json"), {"score0_candidates": len(score0_rows), "validated_score0_count": 0})
    write_jsonl(os.path.join(out_dir, "frontier_candidates.jsonl"), frontier)
    write_csv(os.path.join(out_dir, "frontier_selection_summary.csv"), frontier_summary, sorted({k for row in frontier_summary for k in row}))
    write_jsonl(os.path.join(out_dir, "repair_rows.jsonl"), rows)
    write_csv(os.path.join(out_dir, "repair_rows.csv"), rows, REPAIR_FIELDS)
    write_csv(os.path.join(out_dir, "operator_summary.csv"), operator_summary, sorted({k for row in operator_summary for k in row}))
    write_csv(os.path.join(out_dir, "tuple_operator_summary.csv"), tuple_operator_summary, sorted({k for row in tuple_operator_summary for k in row}))
    write_csv(os.path.join(out_dir, "bucket_operator_summary.csv"), bucket_operator_summary, sorted({k for row in bucket_operator_summary for k in row}))
    write_jsonl(os.path.join(out_dir, "best_candidates_after_repair.jsonl"), best_rows(rows))
    for threshold in (1000, 500, 300, 200, 160):
        write_jsonl(os.path.join(out_dir, "score_under_{}_candidates.jsonl".format(threshold)), threshold_rows(rows, threshold))
    write_readme(out_dir, config, frontier_summary, operator_summary, tuple_operator_summary, bucket_operator_summary)


def aggregate_mode(args):
    rows = []
    frontier_by_hash = {}
    for path in Path(args.aggregate_input_dir).rglob("repair_rows.jsonl"):
        rows.extend(read_jsonl(str(path)))
    for path in Path(args.aggregate_input_dir).rglob("frontier_candidates.jsonl"):
        for row in read_jsonl(str(path)):
            frontier_by_hash[row["canonical_hash_before"]] = row
    frontier = list(frontier_by_hash.values())
    write_outputs(args, rows, frontier, args.out_dir)
    print("aggregated {} repair rows to {}".format(len(rows), args.out_dir))


def parse_args():
    parser = argparse.ArgumentParser(description="p167 frontier repair operator benchmark.")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--tuple-classes", default=",".join(TUPLE_CLASSES_DEFAULT))
    parser.add_argument("--tuple-registry", default=TUPLE_REGISTRY_DEFAULT)
    parser.add_argument("--frontier-files", default=FRONTIER_FIXTURE_DEFAULT)
    parser.add_argument("--operators", default=",".join(OPERATORS_DEFAULT))
    parser.add_argument("--frontier-count", type=int, default=120)
    parser.add_argument("--max-repair-steps", type=int, default=5)
    parser.add_argument("--pool-size", type=int, default=18)
    parser.add_argument("--lns-pool-size", type=int, default=22)
    parser.add_argument("--lns-radius", type=int, default=4)
    parser.add_argument("--beam-width", type=int, default=8)
    parser.add_argument("--eval-cap-per-step", type=int, default=600)
    parser.add_argument("--max-wall-time-ms", type=int, default=15000)
    parser.add_argument("--dmin-sample-count", type=int, default=160)
    parser.add_argument("--base-seed", type=int, default=167991)
    parser.add_argument("--shard-id", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--run-id", default="local")
    parser.add_argument("--output-root", default=OUTPUT_ROOT_DEFAULT)
    parser.add_argument("--experiment-name", default=EXPERIMENT_DEFAULT)
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--smoke-task-limit", type=int, default=2)
    parser.add_argument("--aggregate", action="store_true")
    parser.add_argument("--aggregate-input-dir", default="")
    return parser.parse_args()


def main():
    args = parse_args()
    if not args.out_dir:
        safe = args.run_id.replace("/", "-")
        args.out_dir = os.path.join(args.output_root, "{}_{}".format(now_stamp(), safe))
    if args.aggregate:
        aggregate_mode(args)
    else:
        run_mode(args)


if __name__ == "__main__":
    main()
