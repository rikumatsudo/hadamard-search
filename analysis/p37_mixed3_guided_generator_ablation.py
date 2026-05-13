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


P_DEFAULT = 37
KS_DEFAULT = (13, 16, 18, 18)
LAMBDA_DEFAULT = 28
EXACT_JSON_DEFAULT = "outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json"
VARIANTS_DEFAULT = (
    "random_fixed_size",
    "pair_profile_guided",
    "pair_profile_plus_AP_E",
    "pair_profile_plus_mixed3",
    "pair_profile_plus_mixed3_plus_AP_E",
    "pair_profile_plus_mixed3_plus_sampled_triple",
)
PREVIOUS_SCORE0_HASH_DEFAULT = "51009665990a3845550821c4c085ea28ce52cab065ef5a1d38a95123a0261ba7"
NEARHIT_THRESHOLDS = (4, 8, 16, 50)
SPLITS = {
    "fixed_01_23": ((0, 1), (2, 3)),
    "fixed_02_13": ((0, 2), (1, 3)),
    "fixed_03_12": ((0, 3), (1, 2)),
}


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


def parse_ks(text):
    return tuple(int(x) for x in str(text).replace("[", "").replace("]", "").split(",") if str(x).strip())


def median(values):
    values = [float(v) for v in values if v is not None]
    return statistics.median(values) if values else None


def mean(values):
    values = [float(v) for v in values if v is not None]
    return statistics.mean(values) if values else None


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def load_exact(path, p, ks, lam):
    with open(path) as f:
        data = json.load(f)
    blocks = [set(int(x) % p for x in block) for block in data["blocks"]]
    if [len(b) for b in blocks] != list(ks):
        raise ValueError("exact candidate block sizes do not match ks")
    if int(data.get("lambda", lam)) != int(lam):
        raise ValueError("exact candidate lambda mismatch")
    return blocks


def canonical_hash(blocks):
    payload = [[int(x) for x in sorted(block)] for block in blocks]
    text = json.dumps(payload, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def candidate_json(blocks, p, ks, lam):
    return {
        "v": int(p),
        "n": int(4 * p),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": [[int(x) for x in sorted(block)] for block in blocks],
    }


def diff_counts(p, block, include_zero=False):
    counts = [0] * p
    values = list(block)
    for x in values:
        for y in values:
            if include_zero or x != y:
                counts[(int(x) - int(y)) % p] += 1
    return counts


def all_diff_counts(p, blocks, include_zero=False):
    return [diff_counts(p, block, include_zero=include_zero) for block in blocks]


def rho_vector(p, blocks, lam):
    counts = all_diff_counts(p, blocks, include_zero=False)
    rho = [0] * p
    for d in range(1, p):
        rho[d] = sum(c[d] for c in counts) - int(lam)
    return rho


def score_from_rho(rho):
    return int(sum(int(x) * int(x) for x in rho[1:]))


def score_blocks(p, blocks, lam):
    return score_from_rho(rho_vector(p, blocks, lam))


def ap_count(p, block):
    values = list(block)
    pair_sums = [0] * p
    for x in values:
        for y in values:
            pair_sums[(int(x) + int(y)) % p] += 1
    return int(sum(pair_sums[(2 * int(z)) % p] for z in values))


def additive_energy(p, block):
    counts = diff_counts(p, block, include_zero=True)
    return int(sum(c * c for c in counts))


def triple_value(p, block, a, b):
    block = set(block)
    return sum(1 for x in block if (x + a) % p in block and (x + b) % p in block)


def triple_loss(p, blocks, target, sample_pairs):
    if not sample_pairs:
        return 0.0
    total = 0.0
    for j, block in enumerate(blocks):
        for a, b in sample_pairs:
            diff = triple_value(p, block, a, b) - target[j][(a, b)]
            total += diff * diff
    return total / float(max(1, len(sample_pairs) * len(blocks)))


def exact_triple_target(p, exact_blocks, sample_pairs):
    return [{(a, b): triple_value(p, block, a, b) for a, b in sample_pairs} for block in exact_blocks]


def pair_loss(p, blocks, lam, selected_split):
    counts = all_diff_counts(p, blocks, include_zero=False)
    left, right = SPLITS.get(selected_split, SPLITS["fixed_01_23"])
    total = 0.0
    for d in range(1, p):
        left_profile = sum(counts[i][d] for i in left)
        right_target = int(lam) - sum(counts[i][d] for i in right)
        diff = left_profile - right_target
        total += diff * diff
    return float(total)


def mixed3_loss(p, blocks, lam):
    rho = rho_vector(p, blocks, lam)
    total = 0
    for block in blocks:
        if not block:
            continue
        for t in range(p):
            coeff = 0
            for x in block:
                coeff += rho[(t - int(x)) % p]
            total += coeff * coeff
    return float(total)


def ap_loss(p, blocks, exact_ap):
    vals = [ap_count(p, block) for block in blocks]
    return float(sum((vals[i] - exact_ap[i]) ** 2 for i in range(4)))


def energy_loss(p, blocks, exact_energy):
    vals = [additive_energy(p, block) for block in blocks]
    return float(sum((vals[i] - exact_energy[i]) ** 2 for i in range(4)))


def loss_components(p, blocks, lam, selected_split, exact_ap, exact_energy, triple_target, sample_pairs):
    rho = rho_vector(p, blocks, lam)
    score = score_from_rho(rho)
    pair = pair_loss(p, blocks, lam, selected_split)
    mixed3 = mixed3_loss(p, blocks, lam)
    ap = ap_loss(p, blocks, exact_ap)
    energy = energy_loss(p, blocks, exact_energy)
    triple = triple_loss(p, blocks, triple_target, sample_pairs)
    total_points = max(1, sum(len(block) for block in blocks))
    return {
        "score": float(score),
        "pair": pair,
        "mixed3": mixed3,
        "AP": ap,
        "E": energy,
        "triple": triple,
        "pair_norm": pair / float(max(1, p - 1)),
        "mixed3_norm": mixed3 / float(max(1, p * total_points)),
        "AP_norm": ap / float(max(1, p * p)),
        "E_norm": energy / float(max(1, p * p * p)),
        "triple_norm": triple,
    }


def variant_weights(variant, args):
    weights = {
        "pair": 0.0,
        "mixed3": 0.0,
        "AP": 0.0,
        "E": 0.0,
        "triple": 0.0,
    }
    if variant in (
        "pair_profile_guided",
        "pair_profile_plus_AP_E",
        "pair_profile_plus_mixed3",
        "pair_profile_plus_mixed3_focus",
        "pair_profile_plus_mixed3_plus_AP_E",
        "pair_profile_plus_mixed3_plus_sampled_triple",
        "pair_profile_plus_mixed3_plus_AP_E_plus_sampled_triple",
    ):
        weights["pair"] = float(args.w_pair)
    if "mixed3" in variant:
        weights["mixed3"] = float(args.w3)
    if "AP_E" in variant:
        weights["AP"] = float(args.w_AP)
        weights["E"] = float(args.w_E)
    if "sampled_triple" in variant:
        weights["triple"] = float(args.w_T)
    return weights


def weighted_loss(components, weights):
    return (
        weights["pair"] * components["pair_norm"]
        + weights["mixed3"] * components["mixed3_norm"]
        + weights["AP"] * components["AP_norm"]
        + weights["E"] * components["E_norm"]
        + weights["triple"] * components["triple_norm"]
    )


def choose_weighted(candidates, beta, rng):
    if not candidates:
        raise ValueError("no candidates to choose from")
    min_delta = min(row["delta_loss"] for row in candidates)
    weights = [math.exp(-float(beta) * (row["delta_loss"] - min_delta)) for row in candidates]
    total = sum(weights)
    if total <= 0 or not math.isfinite(total):
        return candidates[0]
    threshold = rng.random() * total
    accum = 0.0
    for row, weight in zip(candidates, weights):
        accum += weight
        if accum >= threshold:
            return row
    return candidates[-1]


def selected_split_for_mode(split_mode, rng):
    if split_mode == "random_split":
        return rng.choice(sorted(SPLITS))
    return split_mode if split_mode in SPLITS else "fixed_01_23"


def block_order_for_mode(mode, rng):
    order = [0, 1, 2, 3]
    if mode == "random":
        rng.shuffle(order)
    return order


def generate_candidate(p, ks, lam, variant, seed, selected_split, beta, top_M, sample_count, block_order_mode, context):
    rng = random.Random(int(seed))
    if variant == "random_fixed_size":
        return [set(rng.sample(range(p), int(k))) for k in ks], {
            "used_mixed3_during_generation": False,
            "generation_loss_evaluations": 0,
        }

    blocks = [set() for _ in ks]
    weights = variant_weights(variant, context["args"])
    used_mixed3 = weights["mixed3"] > 0.0
    current_components = loss_components(
        p,
        blocks,
        lam,
        selected_split,
        context["exact_ap"],
        context["exact_energy"],
        context["triple_target"],
        context["triple_pairs"],
    )
    current_loss = weighted_loss(current_components, weights)
    evaluations = 0
    for bidx in block_order_for_mode(block_order_mode, rng):
        while len(blocks[bidx]) < int(ks[bidx]):
            available = [x for x in range(p) if x not in blocks[bidx]]
            if int(sample_count) > 0 and len(available) > int(sample_count):
                available = rng.sample(available, int(sample_count))
            scored = []
            for point in available:
                trial = [set(block) for block in blocks]
                trial[bidx].add(point)
                comps = loss_components(
                    p,
                    trial,
                    lam,
                    selected_split,
                    context["exact_ap"],
                    context["exact_energy"],
                    context["triple_target"],
                    context["triple_pairs"],
                )
                new_loss = weighted_loss(comps, weights)
                scored.append({"point": point, "delta_loss": new_loss - current_loss, "loss": new_loss})
                evaluations += 1
            scored.sort(key=lambda row: row["delta_loss"])
            top = scored[: max(1, min(int(top_M), len(scored)))]
            choice = choose_weighted(top, beta, rng)
            blocks[bidx].add(choice["point"])
            current_components = loss_components(
                p,
                blocks,
                lam,
                selected_split,
                context["exact_ap"],
                context["exact_energy"],
                context["triple_target"],
                context["triple_pairs"],
            )
            current_loss = weighted_loss(current_components, weights)
    return blocks, {
        "used_mixed3_during_generation": used_mixed3,
        "generation_loss_evaluations": evaluations,
    }


def enumerate_swaps(p, blocks, rng, sample_count):
    swaps = []
    for bidx, block in enumerate(blocks):
        outside = [x for x in range(p) if x not in block]
        for remove in block:
            for add in outside:
                swaps.append((bidx, int(remove), int(add)))
    if int(sample_count) > 0 and len(swaps) > int(sample_count):
        swaps = rng.sample(swaps, int(sample_count))
    return swaps


def apply_swap(blocks, swap):
    bidx, remove, add = swap
    out = [set(block) for block in blocks]
    out[bidx].remove(remove)
    out[bidx].add(add)
    return out


def repair_candidate(p, blocks, lam, budget, seed, swap_sample_count):
    rng = random.Random(int(seed))
    current = [set(block) for block in blocks]
    current_score = score_blocks(p, current, lam)
    steps = 0
    improved = False
    while steps < int(budget) and current_score > 0:
        best = None
        for swap in enumerate_swaps(p, current, rng, int(swap_sample_count)):
            trial = apply_swap(current, swap)
            s = score_blocks(p, trial, lam)
            if best is None or s < best[0]:
                best = (s, swap, trial)
        if best is None or best[0] >= current_score:
            break
        current_score, _swap, current = best
        improved = True
        steps += 1
    return current, int(current_score), int(steps), improved


def one_swap_diagnostics(p, blocks, lam, score, seed, sample_count):
    rng = random.Random(int(seed))
    swaps = enumerate_swaps(p, blocks, rng, int(sample_count))
    scores = [score_blocks(p, apply_swap(blocks, swap), lam) for swap in swaps]
    if not scores:
        return {
            "D_min_ratio": None,
            "P_4": None,
            "P_8": None,
            "P_16": None,
            "kappa_max": None,
            "diagnostic_sample_count": 0,
        }
    best = min(scores)
    denom = float(max(1, score))
    gain = max(0, int(score) - int(best))
    return {
        "D_min_ratio": float(best) / denom,
        "P_4": sum(1 for s in scores if s <= 4) / float(len(scores)),
        "P_8": sum(1 for s in scores if s <= 8) / float(len(scores)),
        "P_16": sum(1 for s in scores if s <= 16) / float(len(scores)),
        "kappa_max": float(gain) / denom,
        "diagnostic_sample_count": int(len(scores)),
    }


def closure_shell_score(p, blocks, lam, score, diag):
    rho = rho_vector(p, blocks, lam)
    support = sum(1 for d in range(1, p) if rho[d] != 0)
    max_abs = max([abs(rho[d]) for d in range(1, p)] or [0])
    shell = 1.0 if int(score) == int(support) and max_abs == 1 else 0.0
    return shell + float(diag.get("P_8") or 0.0) + float(diag.get("P_16") or 0.0) + 1.0 / (1.0 + float(diag.get("D_min_ratio") or 999.0))


def is_late_preclosure(p, blocks, lam, score, diag):
    rho = rho_vector(p, blocks, lam)
    support = sum(1 for d in range(1, p) if rho[d] != 0)
    max_abs = max([abs(rho[d]) for d in range(1, p)] or [0])
    return bool(int(score) > 0 and int(score) == int(support) and max_abs == 1 and (diag.get("D_min_ratio") == 0 or float(diag.get("kappa_max") or 0.0) >= 0.9))


def is_false_like_trap(score, score_after, diag):
    return bool(
        int(score) <= 32
        and not int(score_after) < int(score)
        and (diag.get("D_min_ratio") is None or float(diag.get("D_min_ratio")) > 1.0)
        and float(diag.get("P_8") or 0.0) == 0.0
        and float(diag.get("kappa_max") or 0.0) < 1.0
    )


def run_one(variant, attempt_id, args, context):
    p = int(args.p)
    ks = tuple(int(k) for k in args.ks)
    lam = int(args.lam)
    beta_values = parse_csv(args.beta_list, float)
    top_values = parse_csv(args.top_M_list, int)
    split_modes = parse_csv(args.split_modes, str)
    order_modes = parse_csv(args.block_order_modes, str)
    beta = beta_values[attempt_id % len(beta_values)]
    top_M = top_values[(attempt_id // max(1, len(beta_values))) % len(top_values)]
    split_mode = split_modes[(attempt_id // max(1, len(beta_values) * len(top_values))) % len(split_modes)]
    block_order_mode = order_modes[(attempt_id // max(1, len(beta_values) * len(top_values) * len(split_modes))) % len(order_modes)]
    variant_id = context["variant_ids"][variant]
    seed = int(args.base_seed) + int(args.shard_id) * 100000 + variant_id * 1000 + int(attempt_id)
    explicit = context.get("explicit_override") or {}
    if variant == "pair_profile_plus_mixed3_focus":
        beta = 0.05
        top_M = 5
        split_mode = "fixed_03_12"
        block_order_mode = "random"
    if explicit:
        seed = int(explicit.get("seed", seed))
        beta = float(explicit.get("beta", beta))
        top_M = int(explicit.get("top_M", top_M))
        split_mode = str(explicit.get("split_mode", split_mode))
        block_order_mode = str(explicit.get("block_order_mode", block_order_mode))
    rng = random.Random(seed)
    selected_split = selected_split_for_mode(split_mode, rng)
    if explicit.get("selected_split"):
        selected_split = str(explicit["selected_split"])
    blocks, gen_meta = generate_candidate(
        p,
        ks,
        lam,
        variant,
        seed,
        selected_split,
        beta,
        top_M,
        int(args.sample_count),
        block_order_mode,
        context,
    )
    score_generated = score_blocks(p, blocks, lam)
    repaired, score_after, repair_steps, improved = repair_candidate(
        p,
        blocks,
        lam,
        int(args.repair_budget),
        seed + 17,
        int(args.repair_swap_sample_count),
    )
    diag = one_swap_diagnostics(p, repaired, lam, score_after, seed + 29, int(args.diagnostic_sample_count))
    closure = closure_shell_score(p, repaired, lam, score_after, diag)
    late = is_late_preclosure(p, repaired, lam, score_after, diag)
    score0_generated = int(score_generated) == 0
    score0_after = int(score_after) == 0
    repairable = bool(improved or score0_after or late)
    false_trap = is_false_like_trap(score_generated, score_after, diag)
    generated_thresholds = {threshold: int(score_generated) <= threshold for threshold in NEARHIT_THRESHOLDS}
    after_thresholds = {threshold: int(score_after) <= threshold for threshold in NEARHIT_THRESHOLDS}
    final_components = loss_components(
        p,
        repaired,
        lam,
        selected_split,
        context["exact_ap"],
        context["exact_energy"],
        context["triple_target"],
        context["triple_pairs"],
    )
    h = canonical_hash(repaired)
    row = {
        "run_id": args.run_id,
        "shard_id": int(args.shard_id),
        "attempt_id": int(attempt_id),
        "variant": variant,
        "seed": int(seed),
        "p": int(p),
        "lambda": int(lam),
        "ks": [int(k) for k in ks],
        "split_mode": split_mode,
        "selected_split": selected_split,
        "beta": float(beta),
        "top_M": int(top_M),
        "sample_count": int(args.sample_count),
        "block_order_mode": block_order_mode,
        "score_generated": int(score_generated),
        "score_after_repair": int(score_after),
        "is_score0_generated": bool(score0_generated),
        "is_score0_after_repair": bool(score0_after),
        "canonical_hash": h,
        "is_unique_score0": False,
        "is_late_preclosure": bool(late),
        "is_repairable_parent": bool(repairable),
        "is_false_like_trap": bool(false_trap),
        "generated_score_le_4": bool(generated_thresholds[4]),
        "generated_score_le_8": bool(generated_thresholds[8]),
        "generated_score_le_16": bool(generated_thresholds[16]),
        "generated_score_le_50": bool(generated_thresholds[50]),
        "after_repair_score_le_4": bool(after_thresholds[4]),
        "after_repair_score_le_8": bool(after_thresholds[8]),
        "after_repair_score_le_16": bool(after_thresholds[16]),
        "after_repair_score_le_50": bool(after_thresholds[50]),
        "D_min_ratio": diag.get("D_min_ratio"),
        "P_4": diag.get("P_4"),
        "P_8": diag.get("P_8"),
        "P_16": diag.get("P_16"),
        "kappa_max": diag.get("kappa_max"),
        "closure_shell_score": closure,
        "L_pair_final": final_components["pair"],
        "L_mixed3_final": final_components["mixed3"],
        "L_AP_final": final_components["AP"],
        "L_E_final": final_components["E"],
        "L_triple_final": final_components["triple"],
        "repair_operator": "score_only_1swap_greedy",
        "repair_steps_used": int(repair_steps),
        "used_mixed3_during_generation": bool(gen_meta["used_mixed3_during_generation"]),
        "generation_loss_evaluations": int(gen_meta["generation_loss_evaluations"]),
        "diagnostic_sample_count": int(diag.get("diagnostic_sample_count") or 0),
        "is_explicit_reproduce_previous": bool(explicit),
        "notes": "mixed3 used only during construction" if gen_meta["used_mixed3_during_generation"] else "",
        "blocks": [[int(x) for x in sorted(block)] for block in repaired],
    }
    previous_hash = str(getattr(args, "previous_score0_hash", "") or "")
    row["matches_previous_score0_hash"] = bool(previous_hash and h == previous_hash)
    return row


def annotate_unique_score0(rows):
    seen = set()
    for row in rows:
        if row.get("is_score0_generated") or row.get("is_score0_after_repair"):
            h = row.get("canonical_hash")
            row["is_unique_score0"] = h not in seen
            seen.add(h)
        else:
            row["is_unique_score0"] = False


def summarize(rows, group_key):
    out = []
    groups = {}
    for row in rows:
        groups.setdefault(row.get(group_key), []).append(row)
    for key, group in sorted(groups.items(), key=lambda kv: str(kv[0])):
        count = len(group)
        score0_generated = [row for row in group if row.get("is_score0_generated")]
        score0_after = [row for row in group if row.get("is_score0_after_repair")]
        late = [row for row in group if row.get("is_late_preclosure")]
        repairable = [row for row in group if row.get("is_repairable_parent")]
        traps = [row for row in group if row.get("is_false_like_trap")]
        repair_success = [row for row in group if int(row.get("score_after_repair", 0)) < int(row.get("score_generated", 0))]
        gen_le = {threshold: [row for row in group if int(row.get("score_generated", 10**9)) <= threshold] for threshold in NEARHIT_THRESHOLDS}
        after_le = {threshold: [row for row in group if int(row.get("score_after_repair", 10**9)) <= threshold] for threshold in NEARHIT_THRESHOLDS}
        same_compute_yield = (
            10.0 * len(score0_after)
            + 5.0 * len(score0_generated)
            + 3.0 * len(late)
            + 2.0 * len(after_le[4])
            + 1.0 * len(after_le[8])
            + 0.25 * len(gen_le[50])
            + 1.0 * len(repairable)
            - 0.5 * len(traps)
        ) / float(max(1, count))
        row = {
                group_key: key,
                "candidate_count": count,
                "score0_generated_count": len(score0_generated),
                "score0_after_repair_count": len(score0_after),
                "score0_rate": len(score0_after) / float(max(1, count)),
                "unique_score0_children": len(set(row.get("canonical_hash") for row in score0_after)),
                "late_preclosure_count": len(late),
                "late_preclosure_rate": len(late) / float(max(1, count)),
                "repairable_parent_count": len(repairable),
                "repairable_parent_rate": len(repairable) / float(max(1, count)),
                "false_like_trap_count": len(traps),
                "false_like_trap_rate": len(traps) / float(max(1, count)),
                "post_generation_repair_success_count": len(repair_success),
                "post_generation_repair_success_rate": len(repair_success) / float(max(1, count)),
                "same_compute_yield": same_compute_yield,
                "median_score_generated": median(row.get("score_generated") for row in group),
                "median_score_after_repair": median(row.get("score_after_repair") for row in group),
                "best_score_generated": min(int(row.get("score_generated")) for row in group) if group else None,
                "best_score_after_repair": min(int(row.get("score_after_repair")) for row in group) if group else None,
                "diversity_hash_count": len(set(row.get("canonical_hash") for row in group)),
                "matches_previous_score0_hash_count": sum(1 for row in group if row.get("matches_previous_score0_hash")),
                "explicit_reproduce_previous_count": sum(1 for row in group if row.get("is_explicit_reproduce_previous")),
        }
        for threshold in NEARHIT_THRESHOLDS:
            row["generated_score_le_{}_count".format(threshold)] = len(gen_le[threshold])
            row["generated_score_le_{}_rate".format(threshold)] = len(gen_le[threshold]) / float(max(1, count))
            row["after_repair_score_le_{}_count".format(threshold)] = len(after_le[threshold])
            row["after_repair_score_le_{}_rate".format(threshold)] = len(after_le[threshold]) / float(max(1, count))
        out.append(row)
    return out


def score_histogram(rows):
    groups = {}
    for row in rows:
        for phase, key in (("generated", "score_generated"), ("after_repair", "score_after_repair")):
            hkey = (row.get("variant"), phase, int(row.get(key)))
            groups[hkey] = groups.get(hkey, 0) + 1
    out = []
    for (variant, phase, score), count in sorted(groups.items(), key=lambda kv: (str(kv[0][0]), str(kv[0][1]), int(kv[0][2]))):
        out.append({"variant": variant, "phase": phase, "score": score, "count": count})
    return out


def hyperparam_summary(rows):
    out = []
    groups = {}
    for row in rows:
        key = (row.get("variant"), row.get("beta"), row.get("top_M"), row.get("block_order_mode"), row.get("split_mode"))
        groups.setdefault(key, []).append(row)
    for key, group in sorted(groups.items(), key=lambda kv: str(kv[0])):
        variant, beta, top_M, order, split = key
        summary = summarize(group, "variant")[0]
        summary.update({"variant": variant, "beta": beta, "top_M": top_M, "block_order_mode": order, "split_mode": split})
        out.append(summary)
    return out


def verdict(variant_rows):
    by_variant = {row["variant"]: row for row in variant_rows}
    baselines = [by_variant[v] for v in ("random_fixed_size", "pair_profile_guided", "pair_profile_plus_AP_E") if v in by_variant]
    mixed = [by_variant[v] for v in by_variant if "mixed3" in v]
    if not baselines or not mixed:
        return {"go_no_go": "inconclusive", "reason": "missing baseline or mixed3 variants"}
    base_best = {
        "score0_rate": max(row["score0_rate"] for row in baselines),
        "unique_score0_children": max(row["unique_score0_children"] for row in baselines),
        "generated_score_le_50_rate": max(row.get("generated_score_le_50_rate", 0.0) for row in baselines),
        "after_repair_score_le_4_rate": max(row.get("after_repair_score_le_4_rate", 0.0) for row in baselines),
        "after_repair_score_le_8_rate": max(row.get("after_repair_score_le_8_rate", 0.0) for row in baselines),
        "late_preclosure_rate": max(row["late_preclosure_rate"] for row in baselines),
        "repairable_parent_rate": max(row["repairable_parent_rate"] for row in baselines),
        "post_generation_repair_success_rate": max(row["post_generation_repair_success_rate"] for row in baselines),
        "same_compute_yield": max(row["same_compute_yield"] for row in baselines),
        "false_like_trap_rate": min(row["false_like_trap_rate"] for row in baselines),
    }
    best = None
    best_improvements = -999
    for row in mixed:
        improvements = 0
        for key in (
            "score0_rate",
            "unique_score0_children",
            "generated_score_le_50_rate",
            "after_repair_score_le_4_rate",
            "after_repair_score_le_8_rate",
            "late_preclosure_rate",
            "repairable_parent_rate",
            "post_generation_repair_success_rate",
            "same_compute_yield",
        ):
            if row[key] > base_best[key]:
                improvements += 1
        if row["false_like_trap_rate"] <= base_best["false_like_trap_rate"]:
            improvements += 1
        if improvements > best_improvements:
            best = row
            best_improvements = improvements
    if any(row.get("score0_after_repair_count", 0) > 1 or row.get("unique_score0_children", 0) > 1 for row in mixed):
        label = "STRONG_GO"
    elif any(row.get("score0_after_repair_count", 0) > 0 for row in mixed):
        label = "WEAK_GO"
    elif best_improvements >= 2:
        label = "WEAK_GO"
    elif best_improvements <= 0:
        label = "NO_GO"
    else:
        label = "INCONCLUSIVE"
    return {
        "go_no_go": label,
        "best_mixed3_variant": best.get("variant") if best else None,
        "mixed3_improved_metric_count": best_improvements,
        "baseline_reference": base_best,
    }


def write_score0_jsons(out_dir, rows, p, ks, lam):
    score_dir = Path(out_dir) / "score0_candidate_jsons"
    ensure_dir(str(score_dir))
    written = []
    for idx, row in enumerate(rows):
        if not (row.get("is_score0_generated") or row.get("is_score0_after_repair")):
            continue
        path = score_dir / "{}_{}_{}.json".format(row.get("variant"), row.get("canonical_hash", "")[:12], idx)
        write_json(str(path), candidate_json([set(block) for block in row["blocks"]], p, ks, lam))
        written.append(str(path))
    return written


def write_readme(out_dir, config, variant_rows, decision):
    by_variant = {row["variant"]: row for row in variant_rows}
    def row_value(variant, key):
        row = by_variant.get(variant)
        return row.get(key) if row else None
    lines = []
    lines.append("# p37 mixed3-guided generator reproducibility")
    lines.append("")
    lines.append("This is a generator-yield experiment, not a classifier, filter, reranker, or Hadamard 668 construction run.")
    lines.append("")
    lines.append("mixed3 is used only during point-addition construction through Delta L_gen. It is not used as a post-hoc filter.")
    lines.append("")
    lines.append("## Definitions")
    lines.append("")
    lines.append("rho(d) = N(d) - lambda for d != 0, rho(0) = 0.")
    lines.append("")
    lines.append("S = sum_{d != 0} rho(d)^2.")
    lines.append("")
    lines.append("R_j = r X_j, where r(d)=rho(d) for d != 0 and r(0)=0.")
    lines.append("")
    lines.append("L_mixed3 = sum_j sum_t R_j(t)^2.")
    lines.append("")
    lines.append("P(a) proportional to exp(-beta Delta L_gen(a)).")
    lines.append("")
    lines.append("The pair-profile construction loss uses the current partial aggregate split residual:")
    lines.append("L_pair = ||n_Xa + n_Xb - (lambda - n_Xc - n_Xd)||^2 over d != 0.")
    lines.append("")
    lines.append("## Variant summary")
    lines.append("")
    lines.append("| variant | count | score0_rate | generated<=50 | after<=4 | after<=8 | repairable_parent_rate | false_like_trap_rate | same_compute_yield |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for row in variant_rows:
        lines.append(
            "| {variant} | {candidate_count} | {score0_rate:.6g} | {generated_score_le_50_rate:.6g} | {after_repair_score_le_4_rate:.6g} | {after_repair_score_le_8_rate:.6g} | {repairable_parent_rate:.6g} | {false_like_trap_rate:.6g} | {same_compute_yield:.6g} |".format(**row)
        )
    lines.append("")
    lines.append("## Required answers")
    lines.append("")
    lines.append("Q1. pair_profile_plus_mixed3 score0 reproducibility: see `variant_summary.csv`; best mixed3 variant `{}`.".format(decision.get("best_mixed3_variant")))
    lines.append("Q2. focus condition score0 / near-score0: see `focus_summary.csv`.")
    lines.append("Q3. unique_score0_children: max mixed3 `{}`.".format(max([row["unique_score0_children"] for row in variant_rows if "mixed3" in row["variant"]] or [0])))
    lines.append("Q4. Sage validation status: see `validation_report.json` and `validated_score0_candidates.jsonl`.")
    lines.append("Q5. mixed3 generated_score<=50: V3 `{}`, V1 `{}`.".format(row_value("pair_profile_plus_mixed3", "generated_score_le_50_rate"), row_value("pair_profile_guided", "generated_score_le_50_rate")))
    lines.append("Q6. repair after<=4 / after<=8: V3 `{} / {}`, V1 `{} / {}`.".format(row_value("pair_profile_plus_mixed3", "after_repair_score_le_4_rate"), row_value("pair_profile_plus_mixed3", "after_repair_score_le_8_rate"), row_value("pair_profile_guided", "after_repair_score_le_4_rate"), row_value("pair_profile_guided", "after_repair_score_le_8_rate")))
    lines.append("Q7. AP/E or sampled triple on top of mixed3: compare V4/V5 with V3 in `variant_summary.csv`.")
    lines.append("Q8. false_like_trap_rate: V3 `{}`, V1 `{}`.".format(row_value("pair_profile_plus_mixed3", "false_like_trap_rate"), row_value("pair_profile_guided", "false_like_trap_rate")))
    lines.append("Q9. reproducibility verdict: `{}`.".format(decision.get("go_no_go")))
    lines.append("Q10. next step: only transfer to p167 after p37 reproducibility is at least Weak GO; use p167-specific smoke/audit.")
    lines.append("")
    lines.append("score0 is only a candidate until Sage verifies SDS, Goethals-Seidel construction, and HH^T=nI over ZZ.")
    with open(os.path.join(out_dir, "README.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def write_next_actions(out_dir, decision):
    lines = []
    lines.append("# Next actions")
    lines.append("")
    if decision.get("go_no_go") in ("STRONG_GO", "WEAK_GO"):
        lines.append("- Consider a p37 larger-budget rerun to confirm stability of the mixed3-guided yield.")
        lines.append("- Only after p37 stability, design a p167 c01/c05 generator smoke with normalized losses.")
    elif decision.get("go_no_go") == "NO_GO":
        lines.append("- Do not move mixed3-guided construction to p167 yet.")
        lines.append("- Redesign loss scaling or try mixed3 only in late constructive phases.")
    else:
        lines.append("- Increase candidate count or reduce hyperparameter spread before deciding.")
    with open(os.path.join(out_dir, "next_actions.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def output_all(out_dir, rows, config, p, ks, lam):
    ensure_dir(out_dir)
    annotate_unique_score0(rows)
    variant_rows = summarize(rows, "variant")
    focus_rows = summarize([row for row in rows if row.get("variant") == "pair_profile_plus_mixed3_focus"], "variant")
    split_rows = summarize(rows, "selected_split")
    hyper_rows = hyperparam_summary(rows)
    score0_rows = [row for row in rows if row.get("is_score0_generated") or row.get("is_score0_after_repair")]
    late_rows = [row for row in rows if row.get("is_late_preclosure")]
    repair_rows = [row for row in rows if row.get("is_repairable_parent")]
    trap_rows = [row for row in rows if row.get("is_false_like_trap")]
    nearhit_rows = [
        row for row in rows
        if int(row.get("score_generated", 10**9)) <= 50 or int(row.get("score_after_repair", 10**9)) <= 8
    ]
    histogram_rows = score_histogram(rows)
    decision = verdict(variant_rows)
    score0_jsons = write_score0_jsons(out_dir, score0_rows, p, ks, lam)
    validation = {
        "score0_candidate_count": len(score0_rows),
        "score0_candidate_jsons": score0_jsons,
        "validated_score0_count": 0,
        "validated_score0_candidates_jsonl": os.path.join(out_dir, "validated_score0_candidates.jsonl"),
        "sage_validation_required": bool(score0_jsons),
        "sage_validation_status": "pending_if_score0_present" if score0_jsons else "not_required_no_score0",
    }
    candidate_csv_fields = [
        "run_id", "shard_id", "attempt_id", "variant", "seed", "p", "lambda", "ks",
        "split_mode", "selected_split", "beta", "top_M", "sample_count", "block_order_mode",
        "score_generated", "score_after_repair", "is_score0_generated", "is_score0_after_repair",
        "canonical_hash", "is_unique_score0", "is_late_preclosure", "is_repairable_parent",
        "is_false_like_trap", "D_min_ratio", "P_4", "P_8", "P_16", "kappa_max",
        "generated_score_le_4", "generated_score_le_8", "generated_score_le_16", "generated_score_le_50",
        "after_repair_score_le_4", "after_repair_score_le_8", "after_repair_score_le_16", "after_repair_score_le_50",
        "closure_shell_score", "L_pair_final", "L_mixed3_final", "L_AP_final", "L_E_final",
        "L_triple_final", "repair_operator", "repair_steps_used", "notes",
        "used_mixed3_during_generation", "generation_loss_evaluations",
        "is_explicit_reproduce_previous", "matches_previous_score0_hash",
    ]
    variant_fields = [
        "variant", "candidate_count", "score0_generated_count", "score0_after_repair_count",
        "score0_rate", "unique_score0_children",
        "generated_score_le_4_count", "generated_score_le_4_rate",
        "generated_score_le_8_count", "generated_score_le_8_rate",
        "generated_score_le_16_count", "generated_score_le_16_rate",
        "generated_score_le_50_count", "generated_score_le_50_rate",
        "after_repair_score_le_4_count", "after_repair_score_le_4_rate",
        "after_repair_score_le_8_count", "after_repair_score_le_8_rate",
        "after_repair_score_le_16_count", "after_repair_score_le_16_rate",
        "after_repair_score_le_50_count", "after_repair_score_le_50_rate",
        "late_preclosure_count", "late_preclosure_rate",
        "repairable_parent_count", "repairable_parent_rate", "false_like_trap_count",
        "false_like_trap_rate", "post_generation_repair_success_count",
        "post_generation_repair_success_rate", "same_compute_yield", "median_score_generated",
        "median_score_after_repair", "best_score_generated", "best_score_after_repair",
        "diversity_hash_count", "matches_previous_score0_hash_count", "explicit_reproduce_previous_count",
    ]
    write_csv(os.path.join(out_dir, "candidate_rows.csv"), rows, candidate_csv_fields)
    write_jsonl(os.path.join(out_dir, "candidate_rows.jsonl"), rows)
    write_csv(os.path.join(out_dir, "variant_summary.csv"), variant_rows, variant_fields)
    write_json(os.path.join(out_dir, "variant_summary.json"), {"rows": variant_rows})
    write_csv(os.path.join(out_dir, "focus_summary.csv"), focus_rows, variant_fields)
    write_csv(os.path.join(out_dir, "split_summary.csv"), split_rows, ["selected_split"] + [f for f in variant_fields if f != "variant"])
    write_csv(os.path.join(out_dir, "hyperparam_summary.csv"), hyper_rows, sorted(set().union(*(row.keys() for row in hyper_rows))) if hyper_rows else [])
    write_jsonl(os.path.join(out_dir, "score0_candidates.jsonl"), score0_rows)
    write_jsonl(os.path.join(out_dir, "validated_score0_candidates.jsonl"), [])
    write_jsonl(os.path.join(out_dir, "nearhit_candidates.jsonl"), nearhit_rows)
    write_csv(os.path.join(out_dir, "score_histogram_by_variant.csv"), histogram_rows, ["variant", "phase", "score", "count"])
    write_jsonl(os.path.join(out_dir, "late_preclosure_candidates.jsonl"), late_rows)
    write_jsonl(os.path.join(out_dir, "repairable_parent_candidates.jsonl"), repair_rows)
    write_jsonl(os.path.join(out_dir, "false_like_trap_examples.jsonl"), trap_rows[:200])
    write_json(os.path.join(out_dir, "validation_report.json"), validation)
    write_json(os.path.join(out_dir, "run_config.json"), config)
    write_readme(out_dir, config, variant_rows, decision)
    write_next_actions(out_dir, decision)
    with open(os.path.join(out_dir, "run_log.md"), "w") as f:
        f.write("# p37 mixed3-guided generator ablation log\n\n")
        f.write("- generated_at: `{}`\n".format(time.strftime("%Y-%m-%dT%H:%M:%S%z")))
        f.write("- candidate_rows: `{}`\n".format(len(rows)))
        f.write("- score0_candidates: `{}`\n".format(len(score0_rows)))
        f.write("- verdict: `{}`\n".format(decision.get("go_no_go")))
    return variant_rows, decision, validation


def aggregate(args):
    roots = [root.strip() for root in str(args.aggregate_roots).split(",") if root.strip()]
    rows = []
    for root in roots:
        for path in Path(root).glob("**/candidate_rows.jsonl"):
            rows.extend(read_jsonl(str(path)))
    if not rows:
        raise RuntimeError("no candidate_rows.jsonl found under aggregate roots")
    config = config_from_args(args)
    config["aggregate"] = True
    config["aggregate_roots"] = roots
    output_all(args.out_dir, rows, config, int(args.p), tuple(args.ks), int(args.lam))
    print("aggregate rows:", len(rows))


def config_from_args(args):
    return {
        "experiment": getattr(args, "experiment_name", "p37_mixed3_guided_generator_ablation"),
        "run_id": args.run_id,
        "p": int(args.p),
        "ks": [int(k) for k in args.ks],
        "lambda": int(args.lam),
        "variants": parse_csv(args.variants, str),
        "candidates_per_variant": int(args.candidates_per_variant),
        "beta_list": args.beta_list,
        "top_M_list": args.top_M_list,
        "split_modes": args.split_modes,
        "block_order_modes": args.block_order_modes,
        "sample_count": int(args.sample_count),
        "repair_budget": int(args.repair_budget),
        "repair_swap_sample_count": int(args.repair_swap_sample_count),
        "diagnostic_sample_count": int(args.diagnostic_sample_count),
        "triple_sample_size": int(args.triple_sample_size),
        "shard_id": int(args.shard_id),
        "shard_count": int(args.shard_count),
        "base_seed": int(args.base_seed),
        "previous_score0_hash": str(args.previous_score0_hash or ""),
        "include_explicit_reproduce_previous": bool(args.include_explicit_reproduce_previous),
        "weights": {
            "w_pair": float(args.w_pair),
            "w3": float(args.w3),
            "w_AP": float(args.w_AP),
            "w_E": float(args.w_E),
            "w_T": float(args.w_T),
        },
    }


def run(args):
    p = int(args.p)
    ks = tuple(int(k) for k in args.ks)
    lam = int(args.lam)
    exact = load_exact(args.exact_json, p, ks, lam)
    exact_ap = [ap_count(p, block) for block in exact]
    exact_energy = [additive_energy(p, block) for block in exact]
    rng = random.Random(int(args.base_seed))
    all_pairs = [(a, b) for a in range(p) for b in range(p)]
    triple_pairs = rng.sample(all_pairs, min(int(args.triple_sample_size), len(all_pairs)))
    triple_target = exact_triple_target(p, exact, triple_pairs)
    variants = parse_csv(args.variants, str)
    variant_ids = {variant: idx for idx, variant in enumerate(variants)}
    context = {
        "args": args,
        "exact_ap": exact_ap,
        "exact_energy": exact_energy,
        "triple_pairs": triple_pairs,
        "triple_target": triple_target,
        "variant_ids": variant_ids,
    }
    rows = []
    for variant in variants:
        for attempt_id in range(int(args.candidates_per_variant)):
            rows.append(run_one(variant, attempt_id, args, context))
    if bool(args.include_explicit_reproduce_previous) and int(args.shard_id) == 0 and "pair_profile_plus_mixed3" in variants:
        explicit_context = dict(context)
        explicit_context["explicit_override"] = {
            "seed": 640108,
            "beta": 0.05,
            "top_M": 5,
            "split_mode": "random_split",
            "selected_split": "fixed_03_12",
            "block_order_mode": "random",
        }
        rows.append(run_one("pair_profile_plus_mixed3", int(args.candidates_per_variant), args, explicit_context))
    config = config_from_args(args)
    output_all(args.out_dir, rows, config, p, ks, lam)
    print("candidate rows:", len(rows))
    print("output:", args.out_dir)


def parse_args():
    parser = argparse.ArgumentParser(description="p37 mixed3-guided generator ablation")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--ks", type=parse_ks, default=KS_DEFAULT)
    parser.add_argument("--lam", "--lambda", dest="lam", type=int, default=LAMBDA_DEFAULT)
    parser.add_argument("--exact-json", default=EXACT_JSON_DEFAULT)
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--run-id", default="")
    parser.add_argument("--variants", default=",".join(VARIANTS_DEFAULT))
    parser.add_argument("--candidates-per-variant", type=int, default=200)
    parser.add_argument("--beta-list", default="0.05,0.1,0.2,0.5,1.0")
    parser.add_argument("--top-M-list", default="5,10,20")
    parser.add_argument("--split-modes", default="fixed_01_23,fixed_02_13,fixed_03_12,random_split")
    parser.add_argument("--block-order-modes", default="fixed,random")
    parser.add_argument("--sample-count", type=int, default=12)
    parser.add_argument("--repair-budget", type=int, default=20)
    parser.add_argument("--repair-swap-sample-count", type=int, default=128)
    parser.add_argument("--diagnostic-sample-count", type=int, default=128)
    parser.add_argument("--triple-sample-size", type=int, default=100)
    parser.add_argument("--base-seed", type=int, default=37003)
    parser.add_argument("--previous-score0-hash", default=PREVIOUS_SCORE0_HASH_DEFAULT)
    parser.add_argument("--include-explicit-reproduce-previous", action="store_true")
    parser.add_argument("--experiment-name", default="p37_mixed3_guided_generator_ablation")
    parser.add_argument("--output-root", default=None)
    parser.add_argument("--shard-id", "--shard-index", dest="shard_id", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--w-pair", type=float, default=1.0)
    parser.add_argument("--w3", type=float, default=1.0)
    parser.add_argument("--w-AP", dest="w_AP", type=float, default=1.0)
    parser.add_argument("--w-E", dest="w_E", type=float, default=1.0)
    parser.add_argument("--w-T", dest="w_T", type=float, default=1.0)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--aggregate", action="store_true")
    parser.add_argument("--aggregate-roots", default="")
    args = parser.parse_args()
    if args.out_dir is None:
        output_root = args.output_root or os.path.join("outputs", args.experiment_name)
        args.out_dir = os.path.join(output_root, now_stamp())
    if not args.run_id:
        args.run_id = Path(args.out_dir).name
    if args.smoke:
        args.variants = args.variants or "random_fixed_size,pair_profile_plus_mixed3"
        if args.variants == ",".join(VARIANTS_DEFAULT):
            args.variants = "random_fixed_size,pair_profile_plus_mixed3"
        args.candidates_per_variant = min(args.candidates_per_variant, 1)
        args.beta_list = "0.1"
        args.top_M_list = "5"
        args.split_modes = "fixed_01_23"
        args.block_order_modes = "fixed"
        args.sample_count = min(args.sample_count, 5)
        args.repair_budget = min(args.repair_budget, 2)
        args.repair_swap_sample_count = min(args.repair_swap_sample_count, 16)
        args.diagnostic_sample_count = min(args.diagnostic_sample_count, 16)
        args.triple_sample_size = min(args.triple_sample_size, 10)
    return args


def main():
    args = parse_args()
    if args.aggregate:
        aggregate(args)
    else:
        run(args)


if __name__ == "__main__":
    main()
