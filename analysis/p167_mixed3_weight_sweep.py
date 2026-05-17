#!/usr/bin/env python3
import argparse
import csv
import importlib.util
import json
import math
import os
import random
import statistics
import sys
import time
from pathlib import Path
from types import SimpleNamespace


P_DEFAULT = 167
TUPLE_REGISTRY_DEFAULT = "configs/fixtures/p167_tuple_classes.json"
TUPLE_CLASSES_DEFAULT = ("p167_c01", "p167_c05", "p167_c09")
OUTPUT_ROOT_DEFAULT = "outputs/p167_mixed3_weight_sweep"
EXPERIMENT_DEFAULT = "p167_mixed3_weight_sweep"
THRESHOLDS = (100, 120, 160, 180, 200, 240, 300)
W3_DEFAULT = (0.0, 0.25, 0.5, 1.0, 2.0, 4.0)
W_GUARD_DEFAULT = (0.0, 0.25, 0.5, 1.0, 2.0, 4.0)
GUARD_TYPES_DEFAULT = ("closure_shell_guard", "kappa_guard")
EPS = 1.0e-9


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


def write_json(path, payload):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as f:
        json.dump(json_safe(payload), f, indent=2, sort_keys=True)
        f.write("\n")


def write_jsonl(path, rows):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(json_safe(row), sort_keys=True) + "\n")


def csv_value(value):
    value = json_safe(value)
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True)
    return value


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


def normalize_tuple_id(value):
    value = str(value).strip()
    if value.startswith("p167_"):
        return value
    if value.startswith("c") and len(value) == 3:
        return "p167_" + value
    return value


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def median(values):
    vals = [float(v) for v in values if v is not None]
    return statistics.median(vals) if vals else None


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


def mean(values):
    vals = [float(v) for v in values if v is not None]
    return statistics.mean(vals) if vals else None


def load_tuple_registry(path, tuple_classes):
    wanted = [normalize_tuple_id(x) for x in tuple_classes]
    wanted_set = set(wanted)
    with open(path) as f:
        data = json.load(f)
    rows = []
    for row in data.get("tuple_classes", []):
        tuple_id = row.get("tuple_class_id")
        if tuple_id not in wanted_set:
            continue
        rows.append(
            {
                "tuple_class": tuple_id,
                "ks": tuple(int(x) for x in row["representative_tuple"]),
                "lambda": int(row["lambda"]),
                "abs_row_sums": [int(x) for x in row.get("abs_row_sums", [])],
                "notes": row.get("notes", ""),
            }
        )
    found = {row["tuple_class"] for row in rows}
    missing = [x for x in wanted if x not in found]
    if missing:
        raise ValueError("tuple classes not found: {}".format(",".join(missing)))
    rows.sort(key=lambda row: wanted.index(row["tuple_class"]))
    return rows


def variant_for_guard_type(guard_type):
    if guard_type == "closure_shell_guard":
        return "mixed3_focus_plus_closure_shell_guard"
    if guard_type == "kappa_guard":
        return "mixed3_focus_plus_kappa_guard"
    raise ValueError("unknown guard_type {}".format(guard_type))


def tuple_args_for(base_args, tuple_row, w3=None, w_guard=None):
    clone = SimpleNamespace(**vars(base_args))
    clone.ks = tuple(tuple_row["ks"])
    clone.lam = int(tuple_row["lambda"])
    if w3 is not None:
        clone.w3 = float(w3)
    if w_guard is not None:
        clone.w_guard = float(w_guard)
    return clone


def select_hyperparams(args, tuple_index, guard_index, cell_index, attempt_id, shard_id):
    betas = parse_csv(args.beta_list, float)
    top_ms = parse_csv(args.top_M_list, int)
    splits = parse_csv(args.split_modes)
    modes = parse_csv(args.block_order_modes)
    combo = int(attempt_id) + 7 * tuple_index + 11 * guard_index + 13 * cell_index + 17 * int(shard_id)
    beta = betas[combo % len(betas)]
    top_m = top_ms[(combo // len(betas)) % len(top_ms)]
    split = splits[(combo // max(1, len(betas) * len(top_ms))) % len(splits)]
    block_mode = modes[(combo // max(1, len(betas) * len(top_ms) * len(splits))) % len(modes)]
    return split, float(beta), int(top_m), block_mode


def raw_components(p, blocks, lam, selected_split, guard_type, args, seed):
    score = P37.score_blocks(p, blocks, lam)
    pair = P37.pair_loss(p, blocks, lam, selected_split)
    mixed3 = P37.mixed3_loss(p, blocks, lam)
    guard = P37.guard_metrics(p, blocks, lam, variant_for_guard_type(guard_type), args, seed)
    return {
        "score": int(score),
        "pair": float(pair),
        "mixed3": float(mixed3),
        "guard": float(guard.get("L_guard") or 0.0),
        "guard_metrics": guard,
    }


def empty_guard(guard_type):
    return {
        "guard_type": guard_type,
        "L_guard": 0.0,
        "best_deltaS_sampled": None,
        "kappa_max_sampled": None,
        "closure_shell_proxy": None,
        "sampled_move_count": 0,
    }


def pair_only_generation_loss(p, blocks, lam, selected_split, context, weights, variant, seed):
    pair = P37.pair_loss(p, blocks, lam, selected_split)
    comps = {
        "score": 0.0,
        "pair": float(pair),
        "mixed3": 0.0,
        "AP": 0.0,
        "E": 0.0,
        "triple": 0.0,
        "pair_norm": float(pair) / float(max(1, p - 1)),
        "mixed3_norm": 0.0,
        "AP_norm": 0.0,
        "E_norm": 0.0,
        "triple_norm": 0.0,
    }
    return comps, empty_guard("none"), comps["pair_norm"]


def normalized_generation_loss(p, blocks, lam, selected_split, context, weights, variant, seed):
    args = context["args"]
    norm = context["normalization"][context["tuple_class"]]
    guard_type = context["guard_type"]
    pair = P37.pair_loss(p, blocks, lam, selected_split)
    mixed3 = P37.mixed3_loss(p, blocks, lam) if float(args.w3) != 0.0 else 0.0
    if float(args.w_guard) != 0.0:
        guard = P37.guard_metrics(p, blocks, lam, variant_for_guard_type(guard_type), args, seed)
    else:
        guard = empty_guard(guard_type)
    pair_tilde = float(pair) / float(norm["L_pair_median"] + EPS)
    mixed3_tilde = float(mixed3) / float(norm["L_mixed3_median"] + EPS)
    guard_tilde = float(guard.get("L_guard") or 0.0) / float(norm["L_guard_median_by_type"][guard_type] + EPS)
    loss = pair_tilde + float(args.w3) * mixed3_tilde + float(args.w_guard) * guard_tilde
    comps = {
        "score": 0.0,
        "pair": float(pair),
        "mixed3": float(mixed3),
        "AP": 0.0,
        "E": 0.0,
        "triple": 0.0,
        "pair_norm": pair_tilde,
        "mixed3_norm": mixed3_tilde,
        "AP_norm": 0.0,
        "E_norm": 0.0,
        "triple_norm": 0.0,
    }
    return comps, guard, loss


def compute_normalization(args, tuple_rows):
    old_generation_loss = P37.generation_loss_for_blocks
    P37.generation_loss_for_blocks = pair_only_generation_loss
    stats = {
        "schema_version": "p167_mixed3_weight_sweep_normalization_v1",
        "source": "pair_profile_guided_calibration",
        "calibration_count_per_tuple": int(args.normalization_calibration_count),
        "tuple_stats": {},
    }
    try:
        for tuple_index, tuple_row in enumerate(tuple_rows):
            p = int(args.p)
            ks = tuple(tuple_row["ks"])
            lam = int(tuple_row["lambda"])
            tuple_args = tuple_args_for(args, tuple_row, w3=0.0, w_guard=0.0)
            context = {"args": tuple_args}
            pair_vals = []
            mixed_vals = []
            guard_vals = {guard_type: [] for guard_type in parse_csv(args.guard_types)}
            score_vals = []
            for attempt in range(int(args.normalization_calibration_count)):
                split, beta, top_m, block_mode = select_hyperparams(args, tuple_index, 0, 0, attempt, 0)
                seed = int(args.base_seed) + 900000000 + tuple_index * 10000 + attempt
                blocks, _meta = P37.generate_candidate(
                    p,
                    ks,
                    lam,
                    "pair_profile_guided",
                    seed,
                    P37.selected_split_for_mode(split, random.Random(seed)),
                    beta,
                    top_m,
                    int(args.normalization_sample_count),
                    block_mode,
                    context,
                )
                score_vals.append(P37.score_blocks(p, blocks, lam))
                pair_vals.append(P37.pair_loss(p, blocks, lam, split))
                mixed_vals.append(P37.mixed3_loss(p, blocks, lam))
                for guard_type in guard_vals:
                    guard = P37.guard_metrics(
                        p,
                        blocks,
                        lam,
                        variant_for_guard_type(guard_type),
                        tuple_args,
                        seed + 131,
                    )
                    guard_vals[guard_type].append(float(guard.get("L_guard") or 0.0))
            tuple_stat = {
                "tuple_class": tuple_row["tuple_class"],
                "L_pair_median": median(pair_vals) or 1.0,
                "L_mixed3_median": median(mixed_vals) or 1.0,
                "L_guard_median_by_type": {
                    guard_type: (median(vals) if median(vals) not in (None, 0.0) else 1.0)
                    for guard_type, vals in guard_vals.items()
                },
                "calibration_score_median": median(score_vals),
                "calibration_score_min": min(score_vals) if score_vals else None,
                "fallback_used": False,
            }
            for key in ("L_pair_median", "L_mixed3_median"):
                if tuple_stat[key] == 0.0:
                    tuple_stat[key] = 1.0
                    tuple_stat["fallback_used"] = True
            stats["tuple_stats"][tuple_row["tuple_class"]] = tuple_stat
    finally:
        P37.generation_loss_for_blocks = old_generation_loss
    return stats


def score_flags(prefix, score):
    return {"{}_score_le_{}".format(prefix, threshold): bool(int(score) <= threshold) for threshold in THRESHOLDS}


def is_false_like_trap(row):
    return bool(
        int(row["score_after_repair"]) >= int(row["score_generated"])
        and float(row.get("sampled_kappa_max") or 0.0) < 1.0
        and float(row.get("best_deltaS_sampled") or 0.0) >= 0.0
    )


def run_one(tuple_row, tuple_index, guard_type, guard_index, w3, w_guard, cell_index, attempt_id, args, normalization):
    p = int(args.p)
    ks = tuple(tuple_row["ks"])
    lam = int(tuple_row["lambda"])
    shard_id = int(args.shard_id)
    split_mode, beta, top_m, block_mode = select_hyperparams(
        args, tuple_index, guard_index, cell_index, attempt_id, shard_id
    )
    seed = (
        int(args.base_seed)
        + shard_id * 100000000
        + tuple_index * 10000000
        + guard_index * 1000000
        + cell_index * 10000
        + attempt_id
    )
    selected_split = P37.selected_split_for_mode(split_mode, random.Random(seed))
    tuple_args = tuple_args_for(args, tuple_row, w3=w3, w_guard=w_guard)
    context = {
        "args": tuple_args,
        "tuple_class": tuple_row["tuple_class"],
        "guard_type": guard_type,
        "normalization": normalization["tuple_stats"],
    }
    P37.generation_loss_for_blocks = normalized_generation_loss
    started = time.time()
    blocks, meta = P37.generate_candidate(
        p,
        ks,
        lam,
        variant_for_guard_type(guard_type),
        seed,
        selected_split,
        beta,
        top_m,
        int(args.sample_count),
        block_mode,
        context,
    )
    score_generated = P37.score_blocks(p, blocks, lam)
    repaired, score_after, repair_steps, _improved = P37.repair_candidate(
        p,
        blocks,
        lam,
        int(args.repair_budget),
        seed + 777777,
        int(args.repair_swap_sample_count),
    )
    elapsed_ms = int(round((time.time() - started) * 1000.0))
    final_args = tuple_args_for(args, tuple_row, w3=w3, w_guard=w_guard)
    comps = raw_components(p, blocks, lam, selected_split, guard_type, final_args, seed + 313)
    norm = normalization["tuple_stats"][tuple_row["tuple_class"]]
    guard_raw = float(comps["guard"])
    move_stats = P37.sampled_move_stats(p, repaired, lam, seed + 101, int(args.diagnostic_sample_count))
    closure = P37.closure_shell_proxy_value(p, repaired, lam, move_stats)
    row = {
        "run_id": args.run_id,
        "shard_id": shard_id,
        "attempt_id": int(attempt_id),
        "tuple_class": tuple_row["tuple_class"],
        "tuple_ks": list(ks),
        "lambda": lam,
        "guard_type": guard_type,
        "w3": float(w3),
        "w_guard": float(w_guard),
        "split": selected_split,
        "beta": float(beta),
        "top_M": int(top_m),
        "seed": int(seed),
        "score_generated": int(score_generated),
        "score_after_repair": int(score_after),
        "score_improvement": int(score_generated) - int(score_after),
        "sampled_kappa_max": move_stats.get("kappa_max_sampled"),
        "best_deltaS_sampled": move_stats.get("best_deltaS_sampled"),
        "closure_shell_proxy": closure.get("closure_shell_proxy"),
        "L_pair_raw": float(comps["pair"]),
        "L_mixed3_raw": float(comps["mixed3"]),
        "L_guard_raw": guard_raw,
        "L_pair_tilde": float(comps["pair"]) / float(norm["L_pair_median"] + EPS),
        "L_mixed3_tilde": float(comps["mixed3"]) / float(norm["L_mixed3_median"] + EPS),
        "L_guard_tilde": guard_raw / float(norm["L_guard_median_by_type"][guard_type] + EPS),
        "repair_operator": "score_only_1swap_greedy",
        "repair_steps_used": int(repair_steps),
        "wall_time_ms": elapsed_ms,
        "canonical_hash": P37.canonical_hash(repaired),
        "generation_loss_evaluations": meta.get("generation_loss_evaluations", 0),
        "used_mixed3_during_generation": bool(float(w3) != 0.0),
        "used_guard_during_generation": bool(float(w_guard) != 0.0),
        "blocks_generated": P37.candidate_json(blocks, p, ks, lam)["blocks"],
        "blocks_after_repair": P37.candidate_json(repaired, p, ks, lam)["blocks"],
    }
    row.update(score_flags("generated", score_generated))
    row.update(score_flags("after_repair", score_after))
    row["is_false_like_trap"] = is_false_like_trap(row)
    return row


def rate(rows, pred):
    return sum(1 for row in rows if pred(row)) / float(len(rows)) if rows else 0.0


def utility(summary):
    return (
        -float(summary.get("median_score_after_repair") or 0.0)
        - 2.0 * float(summary.get("best_score_after_repair") or 0.0)
        + 500.0 * float(summary.get("after_repair_score_le_200_rate") or 0.0)
        + 1000.0 * float(summary.get("after_repair_score_le_180_rate") or 0.0)
        + 2000.0 * float(summary.get("after_repair_score_le_160_rate") or 0.0)
        - 1000.0 * float(summary.get("false_like_trap_rate") or 0.0)
    )


def summarize_group(rows, keys):
    buckets = {}
    for row in rows:
        key = tuple(row.get(k) for k in keys)
        buckets.setdefault(key, []).append(row)
    out = []
    for key, group in sorted(buckets.items(), key=lambda item: item[0]):
        summary = {keys[i]: key[i] for i in range(len(keys))}
        summary["candidate_count"] = len(group)
        scores_generated = [row["score_generated"] for row in group]
        scores_after = [row["score_after_repair"] for row in group]
        summary["best_score_generated"] = min(scores_generated) if scores_generated else None
        summary["best_score_after_repair"] = min(scores_after) if scores_after else None
        summary["q01_score_after_repair"] = quantile(scores_after, 0.01)
        summary["q05_score_after_repair"] = quantile(scores_after, 0.05)
        summary["median_score_generated"] = median(scores_generated)
        summary["median_score_after_repair"] = median(scores_after)
        for threshold in THRESHOLDS:
            summary["generated_score_le_{}_count".format(threshold)] = sum(
                1 for row in group if row["score_generated"] <= threshold
            )
            summary["generated_score_le_{}_rate".format(threshold)] = rate(
                group, lambda row, t=threshold: row["score_generated"] <= t
            )
            summary["after_repair_score_le_{}_count".format(threshold)] = sum(
                1 for row in group if row["score_after_repair"] <= threshold
            )
            summary["after_repair_score_le_{}_rate".format(threshold)] = rate(
                group, lambda row, t=threshold: row["score_after_repair"] <= t
            )
        summary["score_improvement_rate"] = rate(group, lambda row: row["score_after_repair"] < row["score_generated"])
        summary["median_score_improvement"] = median(row["score_improvement"] for row in group)
        summary["false_like_trap_rate"] = rate(group, lambda row: row.get("is_false_like_trap"))
        summary["false_like_trap_count"] = sum(1 for row in group if row.get("is_false_like_trap"))
        summary["sampled_kappa_max_median"] = median(row.get("sampled_kappa_max") for row in group)
        summary["best_deltaS_sampled_median"] = median(row.get("best_deltaS_sampled") for row in group)
        summary["closure_shell_proxy_median"] = median(row.get("closure_shell_proxy") for row in group)
        summary["diversity_hash_count"] = len({row.get("canonical_hash") for row in group})
        summary["wall_time_per_candidate"] = mean(row.get("wall_time_ms") for row in group)
        summary["utility"] = utility(summary)
        out.append(summary)
    return out


def build_maxmin_summary(tuple_weight_summary):
    by_key = {}
    for row in tuple_weight_summary:
        key = (row["guard_type"], float(row["w3"]), float(row["w_guard"]))
        by_key.setdefault(key, {})[row["tuple_class"]] = row
    out = []
    for key, by_tuple in sorted(by_key.items()):
        c01 = by_tuple.get("p167_c01")
        c05 = by_tuple.get("p167_c05")
        c09 = by_tuple.get("p167_c09")
        u01 = float(c01["utility"]) if c01 else None
        u05 = float(c05["utility"]) if c05 else None
        u09 = float(c09["utility"]) if c09 else None
        u_min = min(u for u in [u01, u05] if u is not None) if u01 is not None and u05 is not None else None
        out.append(
            {
                "guard_type": key[0],
                "w3": key[1],
                "w_guard": key[2],
                "U_c01": u01,
                "U_c05": u05,
                "U_min_c01_c05": u_min,
                "U_c09": u09,
                "best_after_c01": c01.get("best_score_after_repair") if c01 else None,
                "best_after_c05": c05.get("best_score_after_repair") if c05 else None,
                "best_after_c09": c09.get("best_score_after_repair") if c09 else None,
                "median_after_c01": c01.get("median_score_after_repair") if c01 else None,
                "median_after_c05": c05.get("median_score_after_repair") if c05 else None,
                "median_after_c09": c09.get("median_score_after_repair") if c09 else None,
            }
        )
    return sorted(out, key=lambda row: (row["U_min_c01_c05"] is None, -(row["U_min_c01_c05"] or -10**18)))


def nearhit_rows(rows):
    selected = {}
    for row in rows:
        if row["score_generated"] <= 300 or row["score_after_repair"] <= 300:
            selected[(row["shard_id"], row["tuple_class"], row["guard_type"], row["w3"], row["w_guard"], row["attempt_id"])] = row
    for tuple_class in sorted({row["tuple_class"] for row in rows}):
        subset = [row for row in rows if row["tuple_class"] == tuple_class]
        for row in sorted(subset, key=lambda item: item["score_after_repair"])[:100]:
            selected[(row["shard_id"], row["tuple_class"], row["guard_type"], row["w3"], row["w_guard"], row["attempt_id"], "top_after")] = row
    return list(selected.values())


def threshold_rows(rows, threshold):
    return [row for row in rows if row["score_generated"] <= threshold or row["score_after_repair"] <= threshold]


def write_score0_jsons(out_dir, rows):
    score0_rows = [row for row in rows if row["score_generated"] == 0 or row["score_after_repair"] == 0]
    payloads = []
    for idx, row in enumerate(score0_rows):
        candidate = {
            "candidate_id": "score0_{:04d}".format(idx),
            "tuple_class": row["tuple_class"],
            "guard_type": row["guard_type"],
            "w3": row["w3"],
            "w_guard": row["w_guard"],
            "seed": row["seed"],
            "generated_score": row["score_generated"],
            "after_repair_score": row["score_after_repair"],
            "candidate": {
                "v": int(P_DEFAULT),
                "n": int(4 * P_DEFAULT),
                "ks": row["tuple_ks"],
                "lambda": row["lambda"],
                "blocks": row["blocks_after_repair"] if row["score_after_repair"] == 0 else row["blocks_generated"],
            },
        }
        payloads.append(candidate)
        write_json(os.path.join(out_dir, "score0_candidate_{:04d}.json".format(idx)), candidate["candidate"])
    write_jsonl(os.path.join(out_dir, "score0_candidates.jsonl"), payloads)
    return payloads


CSV_FIELDS = [
    "run_id",
    "shard_id",
    "attempt_id",
    "tuple_class",
    "tuple_ks",
    "lambda",
    "guard_type",
    "w3",
    "w_guard",
    "split",
    "beta",
    "top_M",
    "seed",
    "score_generated",
    "score_after_repair",
    "score_improvement",
] + ["generated_score_le_{}".format(t) for t in THRESHOLDS] + [
    "after_repair_score_le_{}".format(t) for t in THRESHOLDS
] + [
    "is_false_like_trap",
    "sampled_kappa_max",
    "best_deltaS_sampled",
    "closure_shell_proxy",
    "L_pair_raw",
    "L_mixed3_raw",
    "L_guard_raw",
    "L_pair_tilde",
    "L_mixed3_tilde",
    "L_guard_tilde",
    "repair_operator",
    "repair_steps_used",
    "wall_time_ms",
    "canonical_hash",
]


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


def write_readme(out_dir, config, maxmin_summary, tuple_weight_summary, guard_type_summary):
    best_maxmin = maxmin_summary[0] if maxmin_summary else {}
    best_by_tuple = {}
    for row in sorted(tuple_weight_summary, key=lambda item: item["best_score_after_repair"]):
        best_by_tuple.setdefault(row["tuple_class"], row)
    any_300 = any(row.get("after_repair_score_le_300_count", 0) or row.get("generated_score_le_300_count", 0) for row in tuple_weight_summary)
    any_200 = any(row.get("after_repair_score_le_200_count", 0) or row.get("generated_score_le_200_count", 0) for row in tuple_weight_summary)
    any_160 = any(row.get("after_repair_score_le_160_count", 0) or row.get("generated_score_le_160_count", 0) for row in tuple_weight_summary)
    previous_improved = (
        best_by_tuple.get("p167_c01", {}).get("best_score_after_repair", 10**9) < 1096
        or best_by_tuple.get("p167_c05", {}).get("best_score_after_repair", 10**9) < 1188
    )
    if any_200 or any_160:
        decision = "Strong GO"
    elif any_300 or previous_improved:
        decision = "Weak GO"
    else:
        decision = "No GO"

    lines = [
        "# p167 mixed3 weight sweep",
        "",
        "This is a generator-time loss sweep, not a filter, classifier, or reranker experiment.",
        "",
        "L_gen = L_pair_tilde + w3 L_mixed3_tilde + w_guard L_guard_tilde",
        "L_tilde = L / (median_pair_profile_guided(L) + epsilon), per tuple_class.",
        "",
        "## Run",
        "",
        "- run_id: `{}`".format(config["run_id"]),
        "- rows: `{}`".format(config["total_candidate_rows"]),
        "- tuple_classes: `{}`".format(config["tuple_classes"]),
        "- guard_types: `{}`".format(config["guard_types"]),
        "- w3_values: `{}`".format(config["w3_values"]),
        "- w_guard_values: `{}`".format(config["w_guard_values"]),
        "",
        "## Best max-min c01/c05 weights",
        "",
        markdown_table(
            [best_maxmin],
            ["guard_type", "w3", "w_guard", "U_min_c01_c05", "best_after_c01", "best_after_c05", "best_after_c09"],
            limit=1,
        ),
        "## Best per tuple by after-repair score",
        "",
        markdown_table(
            [best_by_tuple[k] for k in sorted(best_by_tuple)],
            ["tuple_class", "guard_type", "w3", "w_guard", "best_score_after_repair", "median_score_after_repair", "false_like_trap_rate"],
            limit=10,
        ),
        "## Guard summary",
        "",
        markdown_table(
            sorted(guard_type_summary, key=lambda row: row["best_score_after_repair"]),
            ["guard_type", "candidate_count", "best_score_after_repair", "median_score_after_repair", "wall_time_per_candidate"],
            limit=10,
        ),
        "## Required answers",
        "",
        "1. Max-min c01/c05 best: `{}`.".format(best_maxmin),
        "2. Nonzero w3 comparison is in `maxmin_summary.csv`; inspect against `w3=0` rows.",
        "3. Nonzero w_guard comparison is in `maxmin_summary.csv`; inspect against `w_guard=0` rows.",
        "4. Guard type comparison is in `guard_type_summary.csv`.",
        "5. c01/c05 previous best after-repair 1096/1188 improved: `{}`.".format("yes" if previous_improved else "no"),
        "6. c09 previous best after-repair 1072 should be compared in `tuple_weight_summary.csv`.",
        "7. score<=300 appeared: `{}`; score<=200 appeared: `{}`.".format("yes" if any_300 else "no", "yes" if any_200 else "no"),
        "8. score160 or score100 appeared: `{}`.".format("yes" if any_160 else "no"),
        "9. trap_rate is reported per tuple/weight; not used for filtering.",
        "10. Robust region should be judged by neighboring high rows in `maxmin_summary.csv`, not isolated candidates.",
        "11. Decision: `{}`.".format(decision),
        "",
        "## Notes",
        "",
        "- score0, if present, is only a candidate until Sage verifies SDS and HH^T = 668I.",
        "- This run does not claim a Hadamard 668 construction.",
    ]
    with open(os.path.join(out_dir, "README.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(out_dir, "next_actions.md"), "w") as f:
        f.write(
            "# next actions\n\n"
            "- Expand the best c01/c05 max-min neighborhood if the sweep improves previous bests or reaches <=300.\n"
            "- If no improvement, reduce p167 generator cost by optimizing mixed3 incrementally before another broad sweep.\n"
            "- Treat c09 as benchmark/trap control; do not optimize solely for c09.\n"
        )
    return decision


def write_outputs(args, rows, normalization, out_dir):
    ensure_dir(out_dir)
    tuple_weight = summarize_group(rows, ["tuple_class", "guard_type", "w3", "w_guard"])
    weight_grid = summarize_group(rows, ["guard_type", "w3", "w_guard"])
    guard_summary = summarize_group(rows, ["guard_type"])
    maxmin = build_maxmin_summary(tuple_weight)
    config = {
        "run_id": args.run_id,
        "p": int(args.p),
        "tuple_classes": [normalize_tuple_id(x) for x in parse_csv(args.tuple_classes)],
        "guard_types": parse_csv(args.guard_types),
        "w3_values": parse_csv(args.w3_list, float),
        "w_guard_values": parse_csv(args.w_guard_list, float),
        "candidates_per_cell": int(args.candidates_per_cell),
        "sample_count": int(args.sample_count),
        "repair_budget": int(args.repair_budget),
        "repair_swap_sample_count": int(args.repair_swap_sample_count),
        "diagnostic_sample_count": int(args.diagnostic_sample_count),
        "normalization_calibration_count": int(args.normalization_calibration_count),
        "total_candidate_rows": len(rows),
        "shard_id": int(args.shard_id),
        "shard_count": int(args.shard_count),
    }
    write_json(os.path.join(out_dir, "run_config.json"), config)
    write_json(os.path.join(out_dir, "normalization_stats.json"), normalization)
    write_jsonl(os.path.join(out_dir, "candidate_rows.jsonl"), rows)
    write_csv(os.path.join(out_dir, "candidate_rows.csv"), rows, CSV_FIELDS)
    write_csv(os.path.join(out_dir, "tuple_weight_summary.csv"), tuple_weight, sorted({k for row in tuple_weight for k in row}))
    write_csv(os.path.join(out_dir, "weight_grid_summary.csv"), weight_grid, sorted({k for row in weight_grid for k in row}))
    write_csv(os.path.join(out_dir, "guard_type_summary.csv"), guard_summary, sorted({k for row in guard_summary for k in row}))
    write_csv(os.path.join(out_dir, "maxmin_summary.csv"), maxmin, sorted({k for row in maxmin for k in row}))
    write_jsonl(os.path.join(out_dir, "nearhit_candidates.jsonl"), nearhit_rows(rows))
    write_jsonl(os.path.join(out_dir, "score_under_300_candidates.jsonl"), threshold_rows(rows, 300))
    write_jsonl(os.path.join(out_dir, "score_under_200_candidates.jsonl"), threshold_rows(rows, 200))
    write_jsonl(os.path.join(out_dir, "score_under_160_candidates.jsonl"), threshold_rows(rows, 160))
    write_jsonl(os.path.join(out_dir, "score_under_120_candidates.jsonl"), threshold_rows(rows, 120))
    write_jsonl(os.path.join(out_dir, "score_under_100_candidates.jsonl"), threshold_rows(rows, 100))
    score0_payloads = write_score0_jsons(out_dir, rows)
    write_jsonl(os.path.join(out_dir, "validated_score0_candidates.jsonl"), [])
    write_json(
        os.path.join(out_dir, "validation_report.json"),
        {"score0_candidates": len(score0_payloads), "validated_score0_count": 0},
    )
    decision = write_readme(out_dir, config, maxmin, tuple_weight, guard_summary)
    return {"rows": len(rows), "out_dir": out_dir, "decision": decision}


def aggregate_mode(args):
    rows = []
    normalizations = []
    for path in sorted(Path(args.aggregate_input_dir).rglob("candidate_rows.jsonl")):
        with open(path) as f:
            for line in f:
                if line.strip():
                    rows.append(json.loads(line))
    for path in sorted(Path(args.aggregate_input_dir).rglob("normalization_stats.json")):
        with open(path) as f:
            normalizations.append(json.load(f))
    if not rows:
        raise ValueError("no candidate rows found under {}".format(args.aggregate_input_dir))
    normalization = normalizations[0] if normalizations else {"tuple_stats": {}}
    return write_outputs(args, rows, normalization, args.out_dir)


def parse_args():
    parser = argparse.ArgumentParser(description="p167 normalized mixed3/guard weight sweep.")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--tuple-registry", default=TUPLE_REGISTRY_DEFAULT)
    parser.add_argument("--tuple-classes", default=",".join(TUPLE_CLASSES_DEFAULT))
    parser.add_argument("--guard-types", "--guard-type", dest="guard_types", default=",".join(GUARD_TYPES_DEFAULT))
    parser.add_argument("--w3-list", "--w3", dest="w3_list", default=",".join(str(x) for x in W3_DEFAULT))
    parser.add_argument("--w-guard-list", "--w-guard", dest="w_guard_list", default=",".join(str(x) for x in W_GUARD_DEFAULT))
    parser.add_argument("--candidates-per-cell", type=int, default=1)
    parser.add_argument("--sample-count", type=int, default=4)
    parser.add_argument("--repair-budget", type=int, default=8)
    parser.add_argument("--repair-swap-sample-count", type=int, default=96)
    parser.add_argument("--diagnostic-sample-count", type=int, default=96)
    parser.add_argument("--normalization-calibration-count", type=int, default=4)
    parser.add_argument("--normalization-sample-count", type=int, default=3)
    parser.add_argument("--base-seed", type=int, default=167907)
    parser.add_argument("--shard-id", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--run-id", default="local")
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--output-root", default=OUTPUT_ROOT_DEFAULT)
    parser.add_argument("--experiment-name", default=EXPERIMENT_DEFAULT)
    parser.add_argument("--aggregate", action="store_true")
    parser.add_argument("--aggregate-input-dir", default="")
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--split-modes", default="fixed_01_23,fixed_02_13,fixed_03_12")
    parser.add_argument("--beta-list", default="0.05,0.10")
    parser.add_argument("--top-M-list", default="5,10")
    parser.add_argument("--block-order-modes", default="random")
    parser.add_argument("--w-pair", type=float, default=1.0)
    parser.add_argument("--w-AP", type=float, default=0.0)
    parser.add_argument("--w-E", type=float, default=0.0)
    parser.add_argument("--w-T", type=float, default=0.0)
    parser.add_argument("--guard-sample-count", type=int, default=8)
    parser.add_argument("--guard-tau-best", type=float, default=0.0)
    parser.add_argument("--guard-kappa-target", type=float, default=1.25)
    parser.add_argument("--guard-min-fill-fraction", type=float, default=0.75)
    parser.add_argument("--guard-lookahead-steps", type=int, default=1)
    parser.add_argument("--guard-lookahead-sample-count", type=int, default=8)
    return parser.parse_args()


def main():
    args = parse_args()
    if args.aggregate:
        result = aggregate_mode(args)
        print(json.dumps(result, sort_keys=True))
        return
    if args.smoke:
        args.candidates_per_cell = min(int(args.candidates_per_cell), 1)
        args.sample_count = min(int(args.sample_count), 3)
        args.repair_budget = min(int(args.repair_budget), 2)
        args.repair_swap_sample_count = min(int(args.repair_swap_sample_count), 16)
        args.diagnostic_sample_count = min(int(args.diagnostic_sample_count), 16)
        args.normalization_calibration_count = min(int(args.normalization_calibration_count), 2)
        args.normalization_sample_count = min(int(args.normalization_sample_count), 2)

    tuple_rows = load_tuple_registry(args.tuple_registry, parse_csv(args.tuple_classes))
    guard_types = parse_csv(args.guard_types)
    w3_values = parse_csv(args.w3_list, float)
    w_guard_values = parse_csv(args.w_guard_list, float)
    normalization = compute_normalization(args, tuple_rows)
    rows = []
    cell_index = 0
    for guard_index, guard_type in enumerate(guard_types):
        for w3 in w3_values:
            for w_guard in w_guard_values:
                for tuple_index, tuple_row in enumerate(tuple_rows):
                    for attempt_id in range(int(args.candidates_per_cell)):
                        rows.append(
                            run_one(
                                tuple_row,
                                tuple_index,
                                guard_type,
                                guard_index,
                                w3,
                                w_guard,
                                cell_index,
                                attempt_id,
                                args,
                                normalization,
                            )
                        )
                cell_index += 1
    out_dir = args.out_dir or os.path.join(args.output_root, "{}_{}".format(now_stamp(), args.experiment_name))
    result = write_outputs(args, rows, normalization, out_dir)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
