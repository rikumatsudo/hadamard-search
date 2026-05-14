#!/usr/bin/env python3
import argparse
import copy
import csv
import importlib.util
import json
import math
import os
import statistics
import sys
import time
from pathlib import Path
from types import SimpleNamespace


P_DEFAULT = 167
TUPLE_REGISTRY_DEFAULT = "configs/fixtures/p167_tuple_classes.json"
TUPLE_CLASSES_DEFAULT = ("p167_c01", "p167_c05", "p167_c09")
VARIANTS_DEFAULT = (
    "random_fixed_size",
    "pair_profile_guided",
    "pair_profile_plus_mixed3_focus",
    "mixed3_focus_plus_kappa_guard",
    "mixed3_focus_plus_closure_shell_guard",
)
EXPERIMENT_DEFAULT = "p167_mixed3_generator_smoke_c01_c05_c09"
OUTPUT_ROOT_DEFAULT = "outputs/p167_mixed3_generator_smoke"
THRESHOLDS = (100, 120, 160, 180, 200, 240, 300)


def load_p37_module():
    module_path = Path(__file__).with_name("p37_mixed3_movespace_guard.py")
    spec = importlib.util.spec_from_file_location("p37_mixed3_movespace_guard", module_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


P37 = load_p37_module()


def p167_loss_components(p, blocks, lam, selected_split, exact_ap, exact_energy, triple_target, sample_pairs):
    """p167 smoke uses pair/mixed3/guard as generation losses; AP/E/triple are not active here."""
    rho = P37.rho_vector(p, blocks, lam)
    score = P37.score_from_rho(rho)
    pair = P37.pair_loss(p, blocks, lam, selected_split)
    mixed3 = P37.mixed3_loss(p, blocks, lam)
    total_points = max(1, sum(len(block) for block in blocks))
    return {
        "score": float(score),
        "pair": float(pair),
        "mixed3": float(mixed3),
        "AP": 0.0,
        "E": 0.0,
        "triple": 0.0,
        "pair_norm": float(pair) / float(max(1, p - 1)),
        "mixed3_norm": float(mixed3) / float(max(1, p * total_points)),
        "AP_norm": 0.0,
        "E_norm": 0.0,
        "triple_norm": 0.0,
    }


P37.loss_components = p167_loss_components


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
        return json.dumps(value, sort_keys=True)
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
            f.write(json.dumps(json_safe(row), sort_keys=True) + "\n")


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
    values = [float(v) for v in values if v is not None]
    return statistics.median(values) if values else None


def mean(values):
    values = [float(v) for v in values if v is not None]
    return statistics.mean(values) if values else None


def load_tuple_registry(path, tuple_classes):
    with open(path) as f:
        data = json.load(f)
    wanted = set(tuple_classes)
    rows = []
    for row in data.get("tuple_classes", []):
        tuple_id = row.get("tuple_class_id")
        if tuple_id not in wanted:
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
    missing = [x for x in tuple_classes if x not in found]
    if missing:
        raise ValueError("tuple classes not found in registry: {}".format(",".join(missing)))
    return rows


def select_hyperparams(args, tuple_index, variant_index, attempt_id, shard_id):
    betas = parse_csv(args.beta_list, float)
    top_ms = parse_csv(args.top_M_list, int)
    splits = parse_csv(args.split_modes)
    block_modes = parse_csv(args.block_order_modes)
    combo = int(attempt_id) + 7 * int(tuple_index) + 13 * int(variant_index) + 17 * int(shard_id)
    beta = betas[combo % len(betas)]
    top_m = top_ms[(combo // len(betas)) % len(top_ms)]
    split_mode = splits[(combo // max(1, len(betas) * len(top_ms))) % len(splits)]
    block_order_mode = block_modes[
        (combo // max(1, len(betas) * len(top_ms) * len(splits))) % len(block_modes)
    ]
    return split_mode, beta, top_m, block_order_mode


def tuple_args_for(base_args, tuple_row):
    clone = SimpleNamespace(**vars(base_args))
    clone.ks = tuple(tuple_row["ks"])
    clone.lam = int(tuple_row["lambda"])
    return clone


def context_for(tuple_args):
    return {
        "args": tuple_args,
        "exact_ap": [0, 0, 0, 0],
        "exact_energy": [0, 0, 0, 0],
        "triple_target": [{}, {}, {}, {}],
        "triple_pairs": [],
    }


def score_flags(prefix, score):
    return {"{}_score_le_{}".format(prefix, threshold): bool(score <= threshold) for threshold in THRESHOLDS}


def is_false_like_trap(row):
    return bool(
        row["score_generated"] <= 240
        and row["score_after_repair"] >= row["score_generated"]
        and (row.get("sampled_kappa_max") is None or row.get("sampled_kappa_max", 0.0) < 1.0)
        and (row.get("best_deltaS_sampled") is None or row.get("best_deltaS_sampled", 0.0) >= 0.0)
    )


def run_one(tuple_row, tuple_index, variant, variant_index, attempt_id, args):
    p = int(args.p)
    ks = tuple(tuple_row["ks"])
    lam = int(tuple_row["lambda"])
    shard_id = int(args.shard_id)
    split_mode, beta, top_m, block_order_mode = select_hyperparams(
        args, tuple_index, variant_index, attempt_id, shard_id
    )
    selected_split = P37.selected_split_for_mode(split_mode, __import__("random").Random(1 + attempt_id + shard_id))
    seed = (
        int(args.base_seed)
        + shard_id * 10000000
        + int(tuple_index) * 1000000
        + int(variant_index) * 100000
        + int(attempt_id)
    )
    tuple_args = tuple_args_for(args, tuple_row)
    context = context_for(tuple_args)

    started = time.time()
    blocks, generation_meta = P37.generate_candidate(
        p,
        ks,
        lam,
        variant,
        seed,
        selected_split,
        beta,
        top_m,
        int(args.sample_count),
        block_order_mode,
        context,
    )
    score_generated = P37.score_blocks(p, blocks, lam)
    repaired, score_after, repair_steps, repair_improved = P37.repair_candidate(
        p,
        blocks,
        lam,
        int(args.repair_budget),
        seed + 99991,
        int(args.repair_swap_sample_count),
    )
    elapsed_ms = int(round((time.time() - started) * 1000.0))

    comps = p167_loss_components(p, blocks, lam, selected_split, None, None, None, None)
    guard = P37.guard_metrics(p, blocks, lam, variant, tuple_args, seed + 313)
    move_stats = P37.sampled_move_stats(p, repaired, lam, seed + 777, int(args.diagnostic_sample_count))
    closure = P37.closure_shell_proxy_value(p, repaired, lam, move_stats)
    canonical_hash = P37.canonical_hash(repaired)
    row = {
        "run_id": args.run_id,
        "shard_id": shard_id,
        "attempt_id": int(attempt_id),
        "tuple_class": tuple_row["tuple_class"],
        "tuple_ks": list(ks),
        "lambda": lam,
        "variant": variant,
        "seed": int(seed),
        "split": selected_split,
        "split_mode": split_mode,
        "beta": float(beta),
        "top_M": int(top_m),
        "guard_type": P37.variant_guard_type(variant),
        "guard_params": {
            "guard_sample_count": int(args.guard_sample_count),
            "guard_tau_best": float(args.guard_tau_best),
            "guard_kappa_target": float(args.guard_kappa_target),
            "guard_min_fill_fraction": float(args.guard_min_fill_fraction),
            "w_guard": float(args.w_guard),
        },
        "score_generated": int(score_generated),
        "score_after_repair": int(score_after),
        "score_improvement": int(score_generated) - int(score_after),
        "is_score0_generated": bool(score_generated == 0),
        "is_score0_after_repair": bool(score_after == 0),
        "validated_score0": False,
        "canonical_hash": canonical_hash,
        "sampled_kappa_max": move_stats.get("kappa_max_sampled"),
        "best_deltaS_sampled": move_stats.get("best_deltaS_sampled"),
        "closure_shell_proxy": closure.get("closure_shell_proxy"),
        "L_pair_final": comps["pair"],
        "L_mixed3_final": comps["mixed3"],
        "L_guard_final": guard.get("L_guard"),
        "repair_operator": "score_only_1swap_greedy",
        "repair_steps_used": int(repair_steps),
        "wall_time_ms": elapsed_ms,
        "used_mixed3_during_generation": generation_meta.get("used_mixed3_during_generation", False),
        "used_guard_during_generation": generation_meta.get("used_guard_during_generation", False),
        "generation_loss_evaluations": generation_meta.get("generation_loss_evaluations", 0),
        "guard_loss_evaluations": generation_meta.get("guard_loss_evaluations", 0),
        "blocks_generated": P37.candidate_json(blocks, p, ks, lam)["blocks"],
        "blocks_after_repair": P37.candidate_json(repaired, p, ks, lam)["blocks"],
    }
    row.update(score_flags("generated", int(score_generated)))
    row.update(score_flags("after_repair", int(score_after)))
    row["is_false_like_trap"] = is_false_like_trap(row)
    return row


def rate(rows, pred):
    if not rows:
        return 0.0
    return sum(1 for row in rows if pred(row)) / float(len(rows))


def summarize_group(rows, keys):
    buckets = {}
    for row in rows:
        key = tuple(row.get(k) for k in keys)
        buckets.setdefault(key, []).append(row)
    out = []
    for key, group in sorted(buckets.items(), key=lambda item: item[0]):
        summary = {keys[i]: key[i] for i in range(len(keys))}
        summary["candidate_count"] = len(group)
        summary["best_score_generated"] = min(row["score_generated"] for row in group) if group else None
        summary["best_score_after_repair"] = min(row["score_after_repair"] for row in group) if group else None
        summary["median_score_generated"] = median(row["score_generated"] for row in group)
        summary["median_score_after_repair"] = median(row["score_after_repair"] for row in group)
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
        summary["score0_generated_count"] = sum(1 for row in group if row["score_generated"] == 0)
        summary["score0_after_repair_count"] = sum(1 for row in group if row["score_after_repair"] == 0)
        summary["score_improvement_rate"] = rate(group, lambda row: row["score_after_repair"] < row["score_generated"])
        summary["median_score_improvement"] = median(row["score_improvement"] for row in group)
        summary["false_like_trap_count"] = sum(1 for row in group if row.get("is_false_like_trap"))
        summary["false_like_trap_rate"] = rate(group, lambda row: row.get("is_false_like_trap"))
        summary["sampled_kappa_max_median"] = median(row.get("sampled_kappa_max") for row in group)
        summary["best_deltaS_sampled_median"] = median(row.get("best_deltaS_sampled") for row in group)
        summary["closure_shell_proxy_median"] = median(row.get("closure_shell_proxy") for row in group)
        summary["diversity_hash_count"] = len({row.get("canonical_hash") for row in group})
        summary["wall_time_per_candidate_ms"] = mean(row.get("wall_time_ms") for row in group)
        out.append(summary)
    return out


def score_histogram(rows):
    buckets = {}
    for row in rows:
        for phase, field in (("generated", "score_generated"), ("after_repair", "score_after_repair")):
            key = (row["tuple_class"], row["variant"], phase, int(row[field]))
            buckets[key] = buckets.get(key, 0) + 1
    return [
        {
            "tuple_class": key[0],
            "variant": key[1],
            "phase": key[2],
            "score": key[3],
            "count": count,
        }
        for key, count in sorted(buckets.items())
    ]


def nearhit_rows(rows):
    selected = {}
    for row in rows:
        if row["score_generated"] <= 160 or row["score_after_repair"] <= 160:
            selected[(row["tuple_class"], row["variant"], row["attempt_id"], row["shard_id"])] = row
    for tuple_class in sorted({row["tuple_class"] for row in rows}):
        subset = [row for row in rows if row["tuple_class"] == tuple_class]
        for row in sorted(subset, key=lambda r: r["score_generated"])[:50]:
            selected[(row["tuple_class"], row["variant"], row["attempt_id"], row["shard_id"], "generated")] = row
        for row in sorted(subset, key=lambda r: r["score_after_repair"])[:50]:
            selected[(row["tuple_class"], row["variant"], row["attempt_id"], row["shard_id"], "after")] = row
    return list(selected.values())


def threshold_rows(rows, threshold):
    return [row for row in rows if row["score_generated"] <= threshold or row["score_after_repair"] <= threshold]


def write_candidate_jsons(out_dir, rows):
    score0 = [row for row in rows if row["is_score0_generated"] or row["is_score0_after_repair"]]
    score0_payloads = []
    for index, row in enumerate(score0):
        candidate = {
            "candidate_id": "score0_{:04d}".format(index),
            "tuple_class": row["tuple_class"],
            "variant": row["variant"],
            "seed": row["seed"],
            "generated_score": row["score_generated"],
            "after_repair_score": row["score_after_repair"],
            "candidate": {
                "v": P_DEFAULT,
                "n": 4 * P_DEFAULT,
                "ks": row["tuple_ks"],
                "lambda": row["lambda"],
                "blocks": row["blocks_after_repair"] if row["is_score0_after_repair"] else row["blocks_generated"],
            },
        }
        score0_payloads.append(candidate)
        write_json(os.path.join(out_dir, "score0_candidate_{:04d}.json".format(index)), candidate["candidate"])
    write_jsonl(os.path.join(out_dir, "score0_candidates.jsonl"), score0_payloads)
    write_jsonl(os.path.join(out_dir, "validated_score0_candidates.jsonl"), [])
    return score0_payloads


CSV_FIELDS = [
    "run_id",
    "shard_id",
    "attempt_id",
    "tuple_class",
    "tuple_ks",
    "lambda",
    "variant",
    "seed",
    "split",
    "beta",
    "top_M",
    "guard_type",
    "guard_params",
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
    "L_pair_final",
    "L_mixed3_final",
    "L_guard_final",
    "repair_operator",
    "repair_steps_used",
    "wall_time_ms",
    "canonical_hash",
    "used_mixed3_during_generation",
    "used_guard_during_generation",
    "generation_loss_evaluations",
    "guard_loss_evaluations",
]


def markdown_table(rows, keys, limit=20):
    if not rows:
        return "_none_\n"
    rows = rows[:limit]
    lines = ["|" + "|".join(keys) + "|", "|" + "|".join(["---"] * len(keys)) + "|"]
    for row in rows:
        vals = []
        for key in keys:
            value = row.get(key)
            if isinstance(value, float):
                value = "{:.4g}".format(value)
            vals.append(str(value))
        lines.append("|" + "|".join(vals) + "|")
    return "\n".join(lines) + "\n"


def write_readme(out_dir, config, tuple_variant_summary):
    best_generated = sorted(tuple_variant_summary, key=lambda row: (row.get("best_score_generated") is None, row.get("best_score_generated") or 10**9))
    best_after = sorted(tuple_variant_summary, key=lambda row: (row.get("best_score_after_repair") is None, row.get("best_score_after_repair") or 10**9))
    any_under_100 = any((row.get("generated_score_le_100_count", 0) + row.get("after_repair_score_le_100_count", 0)) > 0 for row in tuple_variant_summary)
    any_under_120 = any((row.get("generated_score_le_120_count", 0) + row.get("after_repair_score_le_120_count", 0)) > 0 for row in tuple_variant_summary)
    any_under_160 = any((row.get("generated_score_le_160_count", 0) + row.get("after_repair_score_le_160_count", 0)) > 0 for row in tuple_variant_summary)
    decision = "Weak GO" if any_under_160 else "No GO"
    if any_under_100:
        decision = "Strong GO"

    lines = [
        "# p167 mixed3 generator smoke",
        "",
        "This is a generator-yield smoke, not a filter, classifier, or reranker experiment.",
        "mixed3 and guard terms are used during point-addition generation loss.",
        "",
        "## Run",
        "",
        "- run_id: `{}`".format(config["run_id"]),
        "- p: `{}`".format(config["p"]),
        "- tuple_classes: `{}`".format(config["tuple_classes"]),
        "- variants: `{}`".format(config["variants"]),
        "- candidates_per_variant_per_tuple: `{}`".format(config["candidates_per_variant_per_tuple"]),
        "- total_candidate_rows: `{}`".format(config["total_candidate_rows"]),
        "",
        "## Best generated score by tuple/variant",
        "",
        markdown_table(
            best_generated,
            [
                "tuple_class",
                "variant",
                "candidate_count",
                "best_score_generated",
                "generated_score_le_160_count",
                "generated_score_le_120_count",
                "generated_score_le_100_count",
            ],
            limit=30,
        ),
        "## Best after-repair score by tuple/variant",
        "",
        markdown_table(
            best_after,
            [
                "tuple_class",
                "variant",
                "candidate_count",
                "best_score_after_repair",
                "after_repair_score_le_160_count",
                "after_repair_score_le_120_count",
                "after_repair_score_le_100_count",
                "false_like_trap_rate",
            ],
            limit=30,
        ),
        "## Required answers",
        "",
        "1. Best generated distribution is in `tuple_variant_summary.csv`; see the first table above.",
        "2. Best after-repair distribution is in `tuple_variant_summary.csv`; see the second table above.",
        "3. score100未満: `{}`.".format("yes" if any_under_100 else "no"),
        "4. score120未満: `{}`.".format("yes" if any_under_120 else "no"),
        "5. score160未満: `{}`.".format("yes" if any_under_160 else "no"),
        "6. mixed3_focus vs random/pair-profile should be read from generated threshold rates, not post-hoc filtering.",
        "7. kappa/closure guards are evaluated by trap_rate, after-repair thresholds, and wall_time_per_candidate.",
        "8. after-repair improvement is summarized by `score_improvement_rate` and threshold counts.",
        "9. c01/c05 are production targets; c09 remains benchmark/trap control even if it produces low scores.",
        "10. p167 continuation verdict: `{}`.".format(decision),
        "11. Next action should depend on whether c01/c05 under-160/under-120 yield appears without trap inflation.",
        "",
        "## Notes",
        "",
        "- score0, if present, is only a candidate until Sage verifies SDS and HH^T = 668I over ZZ.",
        "- This run does not claim a Hadamard 668 construction.",
    ]
    with open(os.path.join(out_dir, "README.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(out_dir, "next_actions.md"), "w") as f:
        f.write(
            "# next actions\n\n"
            "- If c01/c05 mixed3 or guard variants produce under-160 or under-120 rows, run a larger p167 generator pass.\n"
            "- If guard variants lower trap_rate while keeping low-score yield, tune guard weights and sample counts.\n"
            "- If only c09 improves, keep it as a benchmark/trap control and do not promote it to production.\n"
        )
    return decision


def aggregate_mode(args):
    rows = []
    for path in sorted(Path(args.aggregate_input_dir).rglob("candidate_rows.jsonl")):
        with open(path) as f:
            for line in f:
                if line.strip():
                    rows.append(json.loads(line))
    if not rows:
        raise ValueError("no candidate_rows.jsonl found under {}".format(args.aggregate_input_dir))
    out_dir = args.out_dir
    ensure_dir(out_dir)
    return write_outputs(args, rows, out_dir)


def write_outputs(args, rows, out_dir):
    tuple_variant = summarize_group(rows, ["tuple_class", "variant"])
    tuple_summary = summarize_group(rows, ["tuple_class"])
    variant_summary = summarize_group(rows, ["variant"])
    config = {
        "run_id": args.run_id,
        "p": int(args.p),
        "tuple_registry": args.tuple_registry,
        "tuple_classes": parse_csv(args.tuple_classes),
        "variants": parse_csv(args.variants),
        "candidates_per_variant_per_tuple": int(args.candidates_per_variant_per_tuple),
        "shard_id": int(args.shard_id),
        "shard_count": int(args.shard_count),
        "sample_count": int(args.sample_count),
        "repair_budget": int(args.repair_budget),
        "repair_swap_sample_count": int(args.repair_swap_sample_count),
        "diagnostic_sample_count": int(args.diagnostic_sample_count),
        "base_seed": int(args.base_seed),
        "total_candidate_rows": len(rows),
    }
    write_json(os.path.join(out_dir, "run_config.json"), config)
    write_json(os.path.join(out_dir, "validation_report.json"), {"score0_candidates": 0, "validated_score0_count": 0})
    write_jsonl(os.path.join(out_dir, "candidate_rows.jsonl"), rows)
    write_csv(os.path.join(out_dir, "candidate_rows.csv"), rows, CSV_FIELDS)
    write_csv(os.path.join(out_dir, "tuple_variant_summary.csv"), tuple_variant, sorted({k for row in tuple_variant for k in row}))
    write_csv(os.path.join(out_dir, "tuple_summary.csv"), tuple_summary, sorted({k for row in tuple_summary for k in row}))
    write_csv(os.path.join(out_dir, "variant_summary.csv"), variant_summary, sorted({k for row in variant_summary for k in row}))
    hist = score_histogram(rows)
    write_csv(os.path.join(out_dir, "score_histogram_by_tuple_variant.csv"), hist, ["tuple_class", "variant", "phase", "score", "count"])
    write_jsonl(os.path.join(out_dir, "nearhit_candidates.jsonl"), nearhit_rows(rows))
    write_jsonl(os.path.join(out_dir, "score_under_160_candidates.jsonl"), threshold_rows(rows, 160))
    write_jsonl(os.path.join(out_dir, "score_under_120_candidates.jsonl"), threshold_rows(rows, 120))
    write_jsonl(os.path.join(out_dir, "score_under_100_candidates.jsonl"), threshold_rows(rows, 100))
    score0_payloads = write_candidate_jsons(out_dir, rows)
    write_json(os.path.join(out_dir, "validation_report.json"), {"score0_candidates": len(score0_payloads), "validated_score0_count": 0})
    decision = write_readme(out_dir, config, tuple_variant)
    return {"rows": len(rows), "decision": decision, "out_dir": out_dir}


def parse_args():
    parser = argparse.ArgumentParser(description="p167 mixed3-guided generator smoke for c01/c05/c09.")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--tuple-registry", default=TUPLE_REGISTRY_DEFAULT)
    parser.add_argument("--tuple-classes", default=",".join(TUPLE_CLASSES_DEFAULT))
    parser.add_argument("--variants", default=",".join(VARIANTS_DEFAULT))
    parser.add_argument("--candidates-per-variant-per-tuple", "--candidates-per-variant", dest="candidates_per_variant_per_tuple", type=int, default=1)
    parser.add_argument("--sample-count", type=int, default=4)
    parser.add_argument("--repair-budget", type=int, default=4)
    parser.add_argument("--repair-swap-sample-count", type=int, default=64)
    parser.add_argument("--diagnostic-sample-count", type=int, default=64)
    parser.add_argument("--base-seed", type=int, default=167003)
    parser.add_argument("--shard-id", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--run-id", default="local")
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--output-root", default=OUTPUT_ROOT_DEFAULT)
    parser.add_argument("--experiment-name", default=EXPERIMENT_DEFAULT)
    parser.add_argument("--aggregate-input-dir", default="")
    parser.add_argument("--aggregate", action="store_true")
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--split-modes", default="fixed_01_23,fixed_02_13,fixed_03_12")
    parser.add_argument("--beta-list", default="0.05,0.10")
    parser.add_argument("--top-M-list", default="5,10")
    parser.add_argument("--block-order-modes", default="random")
    parser.add_argument("--w-pair", type=float, default=1.0)
    parser.add_argument("--w3", type=float, default=1.0)
    parser.add_argument("--w-AP", type=float, default=0.0)
    parser.add_argument("--w-E", type=float, default=0.0)
    parser.add_argument("--w-T", type=float, default=0.0)
    parser.add_argument("--w-guard", type=float, default=1.0)
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
        args.candidates_per_variant_per_tuple = min(args.candidates_per_variant_per_tuple, 1)
        args.sample_count = min(args.sample_count, 3)
        args.repair_budget = min(args.repair_budget, 2)
        args.repair_swap_sample_count = min(args.repair_swap_sample_count, 16)
        args.diagnostic_sample_count = min(args.diagnostic_sample_count, 16)
        args.guard_sample_count = min(args.guard_sample_count, 4)

    tuple_rows = load_tuple_registry(args.tuple_registry, parse_csv(args.tuple_classes))
    variants = parse_csv(args.variants)
    rows = []
    for tuple_index, tuple_row in enumerate(tuple_rows):
        for variant_index, variant in enumerate(variants):
            for attempt_id in range(int(args.candidates_per_variant_per_tuple)):
                rows.append(run_one(tuple_row, tuple_index, variant, variant_index, attempt_id, args))

    out_dir = args.out_dir or os.path.join(args.output_root, "{}_{}".format(now_stamp(), args.experiment_name))
    ensure_dir(out_dir)
    result = write_outputs(args, rows, out_dir)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
