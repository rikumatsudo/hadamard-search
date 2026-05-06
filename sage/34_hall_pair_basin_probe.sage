from sage.all import *

import argparse
import csv
import json
import math
import os
import random
import time

from sds_repair_utils import setup_logging, write_json


SCRIPT_NAME = "34_hall_pair_basin_probe"


def hall_bound(n):
    return int(3 * int(n) - 1)


def parse_tuple(text):
    parts = [int(x) for x in text.split(",")]
    if len(parts) != 4:
        raise ValueError("--tuple must be x,y,z,w")
    return tuple(parts)


def parse_int_list(text):
    return sorted(set(int(x) for x in str(text).split(",") if str(x).strip()))


def random_pm1_with_sum(length, target_sum):
    length = int(length)
    target_sum = int(target_sum)
    if (length + target_sum) % 2 != 0:
        raise ValueError("length and target sum have different parity")
    plus_count = (length + target_sum) // 2
    if plus_count < 0 or plus_count > length:
        raise ValueError("target sum {} impossible for length {}".format(target_sum, length))
    seq = [1] * plus_count + [-1] * (length - plus_count)
    random.shuffle(seq)
    return seq


def precompute_trig(max_len, grid):
    cos_table = []
    sin_table = []
    for j in range(1, int(grid) + 1):
        theta = math.pi * float(j) / float(grid)
        cos_table.append([math.cos(theta * i) for i in range(int(max_len))])
        sin_table.append([math.sin(theta * i) for i in range(int(max_len))])
    return cos_table, sin_table


def initial_transform(seq, cos_table, sin_table):
    real = []
    imag = []
    for row_c, row_s in zip(cos_table, sin_table):
        r = 0.0
        im = 0.0
        for i, value in enumerate(seq):
            r += float(value) * row_c[i]
            im += float(value) * row_s[i]
        real.append(r)
        imag.append(im)
    return real, imag


def hall_values_from_transform(real, imag):
    return [float(r * r + im * im) for r, im in zip(real, imag)]


def excess_over_bound(pair_values, bound):
    return float(sum(max(0.0, float(value) - float(bound)) for value in pair_values))


def violation_count(pair_values, bound):
    return int(sum(1 for value in pair_values if float(value) > float(bound)))


def pair_metrics(z_hall, w_hall, bound):
    pair = [float(a) + float(b) for a, b in zip(z_hall, w_hall)]
    pair_max = max(pair)
    pair_argmax = max(range(len(pair)), key=lambda i: pair[i])
    sorted_values = sorted(pair, reverse=True)
    mean = sum(pair) / float(len(pair))
    variance = sum((x - mean) ** 2 for x in pair) / float(len(pair))
    return {
        "pair_max": float(pair_max),
        "pair_argmax": int(pair_argmax),
        "pair_mean": float(mean),
        "pair_std": float(math.sqrt(max(0.0, variance))),
        "pair_top_gap": float(sorted_values[0] - sorted_values[1]) if len(sorted_values) > 1 else 0.0,
        "z_max": float(max(z_hall)),
        "w_max": float(max(w_hall)),
        "pair_values": pair,
        "pair_excess_over_bound": excess_over_bound(pair, bound),
        "violation_count": violation_count(pair, bound),
    }


def current_metrics(zr, zi, wr, wi, bound):
    z_hall = hall_values_from_transform(zr, zi)
    w_hall = hall_values_from_transform(wr, wi)
    return pair_metrics(z_hall, w_hall, bound)


def score_tuple(metrics, objective):
    if objective == "pair_max":
        return (float(metrics["pair_max"]), float(metrics["pair_excess_over_bound"]), float(metrics["pair_std"]))
    if objective == "excess_then_pair_max":
        return (float(metrics["pair_excess_over_bound"]), float(metrics["pair_max"]), float(metrics["pair_std"]))
    if objective == "violations_then_pair_max":
        return (
            int(metrics["violation_count"]),
            float(metrics["pair_excess_over_bound"]),
            float(metrics["pair_max"]),
            float(metrics["pair_std"]),
        )
    if objective == "basin_score":
        return (
            float(metrics["pair_max"]) + 0.25 * float(metrics["pair_excess_over_bound"]) + 2.0 * int(metrics["violation_count"]),
            float(metrics["pair_max"]),
        )
    raise ValueError("unknown objective {}".format(objective))


def random_balanced_flip(seq):
    plus = [i for i, x in enumerate(seq) if int(x) == 1]
    minus = [i for i, x in enumerate(seq) if int(x) == -1]
    if not plus or not minus:
        return None
    return int(random.choice(plus)), int(random.choice(minus))


def apply_flip(seq, real, imag, cos_table, sin_table, i, j):
    old_i = int(seq[i])
    old_j = int(seq[j])
    if old_i == old_j:
        raise ValueError("balanced flip needs opposite signs")
    seq[i] = -old_i
    seq[j] = -old_j
    delta_i = float(seq[i] - old_i)
    delta_j = float(seq[j] - old_j)
    for k in range(len(real)):
        real[k] += delta_i * cos_table[k][i] + delta_j * cos_table[k][j]
        imag[k] += delta_i * sin_table[k][i] + delta_j * sin_table[k][j]


def apply_move(move, Z, W, zr, zi, wr, wi, cos_table, sin_table):
    which, i, j = move
    if which == "Z":
        apply_flip(Z, zr, zi, cos_table, sin_table, i, j)
    else:
        apply_flip(W, wr, wi, cos_table, sin_table, i, j)


def undo_move(move, Z, W, zr, zi, wr, wi, cos_table, sin_table):
    apply_move(move, Z, W, zr, zi, wr, wi, cos_table, sin_table)


def random_move(Z, W):
    which = "Z" if random.random() < 0.5 else "W"
    flip = random_balanced_flip(Z if which == "Z" else W)
    if flip is None:
        return None
    return which, flip[0], flip[1]


def top_pair_indices(pair_values, k):
    return sorted(range(len(pair_values)), key=lambda i: pair_values[i], reverse=True)[: max(1, int(k))]


def individual_flip_delta(seq, real, imag, cos_table, sin_table, theta_idx, pos):
    old_value = int(seq[pos])
    delta = float(-2 * old_value)
    dc = delta * cos_table[theta_idx][pos]
    ds = delta * sin_table[theta_idx][pos]
    before = real[theta_idx] * real[theta_idx] + imag[theta_idx] * imag[theta_idx]
    after = (real[theta_idx] + dc) ** 2 + (imag[theta_idx] + ds) ** 2
    return float(after - before)


def ranked_positions_by_theta(seq, real, imag, cos_table, sin_table, theta_idx, pool_size):
    plus = []
    minus = []
    for pos, value in enumerate(seq):
        item = (individual_flip_delta(seq, real, imag, cos_table, sin_table, theta_idx, pos), int(pos))
        if int(value) == 1:
            plus.append(item)
        else:
            minus.append(item)
    plus.sort(key=lambda x: x[0])
    minus.sort(key=lambda x: x[0])
    limit = max(1, int(pool_size))
    return plus[:limit], minus[:limit]


def choose_ranked_position(items):
    if not items:
        return None
    window = max(1, min(len(items), int(math.sqrt(len(items))) + 2))
    return int(random.choice(items[:window])[1])


def targeted_worst_theta_move(Z, W, zr, zi, wr, wi, cos_table, sin_table, base_metrics, args):
    worst = top_pair_indices(base_metrics["pair_values"], args.worst_theta_k)
    theta_idx = random.choice(worst)
    z_value = zr[theta_idx] * zr[theta_idx] + zi[theta_idx] * zi[theta_idx]
    w_value = wr[theta_idx] * wr[theta_idx] + wi[theta_idx] * wi[theta_idx]
    if random.random() < 0.75:
        which = "Z" if z_value >= w_value else "W"
    else:
        which = "W" if z_value >= w_value else "Z"
    if which == "Z":
        plus, minus = ranked_positions_by_theta(Z, zr, zi, cos_table, sin_table, theta_idx, args.position_pool)
    else:
        plus, minus = ranked_positions_by_theta(W, wr, wi, cos_table, sin_table, theta_idx, args.position_pool)
    i = choose_ranked_position(plus)
    j = choose_ranked_position(minus)
    if i is None or j is None:
        return random_move(Z, W)
    return which, i, j


def propose_move(Z, W, zr, zi, wr, wi, cos_table, sin_table, base_metrics, args):
    if args.move_mode == "random":
        return random_move(Z, W), "random"
    if args.move_mode == "worst_theta":
        return targeted_worst_theta_move(Z, W, zr, zi, wr, wi, cos_table, sin_table, base_metrics, args), "targeted"
    if args.move_mode == "mixed":
        if random.random() < float(args.targeted_prob):
            return targeted_worst_theta_move(Z, W, zr, zi, wr, wi, cos_table, sin_table, base_metrics, args), "targeted"
        return random_move(Z, W), "random"
    raise ValueError("unknown move mode {}".format(args.move_mode))


def choose_move(Z, W, zr, zi, wr, wi, cos_table, sin_table, args, base_metrics, bound):
    best = None
    best_metrics = None
    best_key = None
    best_source = ""
    for _ in range(max(1, int(args.candidate_trials))):
        move, source = propose_move(Z, W, zr, zi, wr, wi, cos_table, sin_table, base_metrics, args)
        if move is None:
            continue
        apply_move(move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
        metrics = current_metrics(zr, zi, wr, wi, bound)
        key = score_tuple(metrics, args.search_objective)
        undo_move(move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
        if best is None or key < best_key:
            best = move
            best_metrics = metrics
            best_key = key
            best_source = source
    return best, best_metrics, best_key, best_source


def temperature(step, steps, start, minimum):
    progress = float(step) / float(max(1, int(steps)))
    return max(float(minimum), float(start) * (1.0 - progress))


def accept(cur_key, new_key, step, args):
    if new_key <= cur_key:
        return True
    if args.strategy == "greedy":
        return False
    temp = temperature(step, args.probe_steps, args.temperature, args.min_temperature)
    if temp <= 0:
        return False
    delta = float(new_key[0] - cur_key[0])
    return random.random() < math.exp(-max(0.0, delta) / temp)


def clone_state(Z, W, zr, zi, wr, wi):
    return list(Z), list(W), list(zr), list(zi), list(wr), list(wi)


def compact_metrics(metrics):
    return {
        "pair_max": float(metrics["pair_max"]),
        "pair_excess_over_bound": float(metrics["pair_excess_over_bound"]),
        "violation_count": int(metrics["violation_count"]),
        "pair_std": float(metrics["pair_std"]),
        "pair_top_gap": float(metrics["pair_top_gap"]),
        "pair_argmax": int(metrics["pair_argmax"]) + 1,
        "z_max": float(metrics["z_max"]),
        "w_max": float(metrics["w_max"]),
    }


def endpoint_signature(seq, width):
    width = int(width)
    return tuple(int(x) for x in (list(seq[:width]) + list(seq[-width:])))


def compact_signature(sig):
    return "".join("+" if int(x) > 0 else "-" for x in sig)


def basin_score(initial_metrics, best_metrics, best_step, update_count, args):
    drop = float(initial_metrics["pair_max"]) - float(best_metrics["pair_max"])
    early_speed = drop / float(max(1, int(best_step)))
    return float(
        float(best_metrics["pair_max"])
        + float(args.basin_excess_weight) * float(best_metrics["pair_excess_over_bound"])
        + float(args.basin_violation_weight) * int(best_metrics["violation_count"])
        + float(args.basin_std_weight) * float(best_metrics["pair_std"])
        + float(args.basin_step_weight) * int(best_step)
        - float(args.basin_drop_weight) * drop
        - float(args.basin_update_weight) * int(update_count)
        - float(args.basin_speed_weight) * early_speed
    )


def probe_one_seed(seed, tuple_value, cos_table, sin_table, args):
    random.seed(int(seed))
    x_sum, y_sum, z_sum, w_sum = tuple_value
    n = int(args.n)
    bound = hall_bound(n)
    Z = random_pm1_with_sum(n, z_sum)
    W = random_pm1_with_sum(n - 1, w_sum)
    zr, zi = initial_transform(Z, cos_table, sin_table)
    wr, wi = initial_transform(W, cos_table, sin_table)
    metrics = current_metrics(zr, zi, wr, wi, bound)
    initial_metrics = dict(metrics)
    cur_key = score_tuple(metrics, args.search_objective)
    best_Z, best_W, best_zr, best_zi, best_wr, best_wi = clone_state(Z, W, zr, zi, wr, wi)
    best_metrics = dict(metrics)
    best_key = cur_key
    best_step = 0
    last_improvement = 0
    update_count = 0
    accepted_count = 0
    targeted_count = 0
    random_count = 0
    plateau_count = 0
    checkpoints = {}
    checkpoint_set = set(parse_int_list(args.checkpoints))

    for step in range(1, int(args.probe_steps) + 1):
        move, new_metrics, new_key, move_source = choose_move(
            Z, W, zr, zi, wr, wi, cos_table, sin_table, args, metrics, bound
        )
        if move_source == "targeted":
            targeted_count += 1
        elif move_source == "random":
            random_count += 1
        if move is not None and accept(cur_key, new_key, step, args):
            apply_move(move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
            metrics = new_metrics
            cur_key = new_key
            accepted_count += 1
        if cur_key < best_key:
            best_Z, best_W, best_zr, best_zi, best_wr, best_wi = clone_state(Z, W, zr, zi, wr, wi)
            best_metrics = dict(metrics)
            best_key = cur_key
            best_step = step
            last_improvement = step
            update_count += 1
        if args.restart_patience > 0 and step - last_improvement >= int(args.restart_patience):
            flips = max(1, int((len(Z) + len(W)) * float(args.shake_rate)))
            for _ in range(flips):
                shake_move = random_move(Z, W)
                if shake_move is not None:
                    apply_move(shake_move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
            metrics = current_metrics(zr, zi, wr, wi, bound)
            cur_key = score_tuple(metrics, args.search_objective)
            plateau_count += 1
            last_improvement = step
        if step in checkpoint_set:
            checkpoints[str(step)] = {
                "current": compact_metrics(metrics),
                "best": compact_metrics(best_metrics),
                "best_step": int(best_step),
                "update_count": int(update_count),
            }
        if best_metrics["pair_max"] <= bound:
            break

    score = basin_score(initial_metrics, best_metrics, best_step, update_count, args)
    return {
        "seed": int(seed),
        "basin_score": float(score),
        "initial": compact_metrics(initial_metrics),
        "best": compact_metrics(best_metrics),
        "best_step": int(best_step),
        "update_count": int(update_count),
        "accepted_count": int(accepted_count),
        "targeted_proposals": int(targeted_count),
        "random_proposals": int(random_count),
        "plateau_count": int(plateau_count),
        "checkpoints": checkpoints,
        "Z": [int(x) for x in best_Z],
        "W": [int(x) for x in best_W],
        "z_signature": compact_signature(endpoint_signature(best_Z, args.endpoint_width)),
        "w_signature": compact_signature(endpoint_signature(best_W, args.endpoint_width)),
        "pair_hall_pass": bool(best_metrics["pair_max"] <= bound),
    }


def write_best_json(path, result, tuple_value, args):
    payload = {
        "script": SCRIPT_NAME,
        "classification": "hall_pair_basin_probe_best",
        "n": int(args.n),
        "target_order": int(4 * hall_bound(args.n)),
        "tuple": [int(x) for x in tuple_value],
        "bound": int(hall_bound(args.n)),
        "seed": int(result["seed"]),
        "basin_score": float(result["basin_score"]),
        "probe_steps": int(args.probe_steps),
        "search_objective": args.search_objective,
        "move_mode": args.move_mode,
        "targeted_prob": float(args.targeted_prob),
        "worst_theta_k": int(args.worst_theta_k),
        "position_pool": int(args.position_pool),
        "best": result["best"],
        "best_step": int(result["best_step"]),
        "update_count": int(result["update_count"]),
        "checkpoints": result["checkpoints"],
        "Z": result["Z"],
        "W": result["W"],
        "pair_hall_pass": bool(result["pair_hall_pass"]),
        "notes": [
            "This is a basin-probe triage artifact, not a Hadamard construction.",
            "Promotion means the seed deserves a longer Hall-pair annealing run.",
        ],
    }
    write_json(path, payload)


def row_for_csv(result):
    best = result["best"]
    initial = result["initial"]
    return {
        "seed": int(result["seed"]),
        "basin_score": float(result["basin_score"]),
        "initial_pair_max": float(initial["pair_max"]),
        "best_pair_max": float(best["pair_max"]),
        "best_excess": float(best["pair_excess_over_bound"]),
        "best_violations": int(best["violation_count"]),
        "best_pair_std": float(best["pair_std"]),
        "best_top_gap": float(best["pair_top_gap"]),
        "best_theta": int(best["pair_argmax"]),
        "z_max": float(best["z_max"]),
        "w_max": float(best["w_max"]),
        "best_step": int(result["best_step"]),
        "update_count": int(result["update_count"]),
        "accepted_count": int(result["accepted_count"]),
        "plateau_count": int(result["plateau_count"]),
        "pair_hall_pass": bool(result["pair_hall_pass"]),
        "z_signature": result["z_signature"],
        "w_signature": result["w_signature"],
    }


def promotion_command(result, args):
    resume_part = ""
    if result.get("probe_best_json"):
        resume_part = "--resume-pair-json {path} ".format(path=result["probe_best_json"])
    return (
        "DOT_SAGE=/private/tmp/sage-dot sage sage/33_hall_pair_bucket_annealer.sage "
        "--n {n} --tuple {tuple_text} --steps {steps} --seed {seed} --grid {grid} "
        "--candidate-trials {trials} --objective {objective} --strategy {strategy} "
        "--temperature {temperature} --restart-patience {patience} --shake-rate {shake_rate} "
        "--move-mode {move_mode} --targeted-prob {targeted_prob} "
        "--worst-theta-k {worst_theta_k} --position-pool {position_pool} "
        "{resume_part}"
        "--out-prefix {out_prefix}_seed{seed}"
    ).format(
        n=int(args.n),
        tuple_text=args.tuple,
        steps=int(args.promote_steps),
        seed=int(result["seed"]),
        grid=int(args.grid),
        trials=int(args.promote_candidate_trials),
        objective=args.promote_objective,
        strategy=args.strategy,
        temperature=float(args.temperature),
        patience=int(args.promote_restart_patience),
        shake_rate=float(args.shake_rate),
        move_mode=args.move_mode,
        targeted_prob=float(args.targeted_prob),
        worst_theta_k=int(args.worst_theta_k),
        position_pool=int(args.position_pool),
        resume_part=resume_part,
        out_prefix=args.promote_out_prefix,
    )


def parse_args():
    parser = argparse.ArgumentParser(description="Short Hall-pair basin probes for seed triage.")
    parser.add_argument("--n", type=int, default=56)
    parser.add_argument("--tuple", default="0,-18,-2,1")
    parser.add_argument("--seed-start", type=int, default=1)
    parser.add_argument("--seed-end", type=int, default=50)
    parser.add_argument("--probe-steps", type=int, default=1500)
    parser.add_argument("--checkpoints", default="100,300,500,1000,1500")
    parser.add_argument("--grid", type=int, default=100)
    parser.add_argument("--candidate-trials", type=int, default=24)
    parser.add_argument(
        "--search-objective",
        choices=["pair_max", "excess_then_pair_max", "violations_then_pair_max", "basin_score"],
        default="pair_max",
    )
    parser.add_argument("--strategy", choices=["greedy", "anneal"], default="anneal")
    parser.add_argument("--temperature", type=float, default=5.0)
    parser.add_argument("--min-temperature", type=float, default=0.01)
    parser.add_argument("--restart-patience", type=int, default=1000)
    parser.add_argument("--shake-rate", type=float, default=0.05)
    parser.add_argument("--move-mode", choices=["random", "worst_theta", "mixed"], default="mixed")
    parser.add_argument("--targeted-prob", type=float, default=0.8)
    parser.add_argument("--worst-theta-k", type=int, default=4)
    parser.add_argument("--position-pool", type=int, default=24)
    parser.add_argument("--endpoint-width", type=int, default=6)
    parser.add_argument("--promote-top-k", type=int, default=10)
    parser.add_argument("--promote-steps", type=int, default=16000)
    parser.add_argument("--promote-candidate-trials", type=int, default=32)
    parser.add_argument("--promote-objective", default="pair_max")
    parser.add_argument("--promote-restart-patience", type=int, default=2000)
    parser.add_argument("--promote-out-prefix", default="outputs/turyn/hall_pair_promoted_n56")
    parser.add_argument("--basin-excess-weight", type=float, default=0.25)
    parser.add_argument("--basin-violation-weight", type=float, default=2.0)
    parser.add_argument("--basin-std-weight", type=float, default=0.03)
    parser.add_argument("--basin-step-weight", type=float, default=0.001)
    parser.add_argument("--basin-drop-weight", type=float, default=0.02)
    parser.add_argument("--basin-update-weight", type=float, default=0.25)
    parser.add_argument("--basin-speed-weight", type=float, default=1.0)
    parser.add_argument("--out-dir", default="outputs/turyn/basin_probe")
    parser.add_argument("--csv", default="")
    parser.add_argument("--json", default="")
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        tuple_value = parse_tuple(args.tuple)
        x_sum, y_sum, z_sum, w_sum = tuple_value
        rhs = x_sum * x_sum + y_sum * y_sum + 2 * z_sum * z_sum + 2 * w_sum * w_sum
        if rhs != 6 * int(args.n) - 2:
            raise ValueError("tuple {} violates sum identity: {} != {}".format(tuple_value, rhs, 6 * int(args.n) - 2))
        os.makedirs(args.out_dir, exist_ok=True)
        csv_path = args.csv or os.path.join(args.out_dir, "{}_{}.csv".format(SCRIPT_NAME, stamp))
        json_path = args.json or os.path.join(args.out_dir, "{}_{}.json".format(SCRIPT_NAME, stamp))
        commands_path = os.path.join(args.out_dir, "{}_{}_promote_commands.sh".format(SCRIPT_NAME, stamp))
        cos_table, sin_table = precompute_trig(int(args.n), int(args.grid))
        start = time.time()
        results = []
        print(
            "basin probe n={} target_order={} tuple={} seeds={}..{} probe_steps={} bound={}".format(
                args.n,
                4 * hall_bound(args.n),
                tuple_value,
                args.seed_start,
                args.seed_end,
                args.probe_steps,
                hall_bound(args.n),
            )
        )
        print("csv:", csv_path)
        print("json:", json_path)
        for seed in range(int(args.seed_start), int(args.seed_end) + 1):
            result = probe_one_seed(seed, tuple_value, cos_table, sin_table, args)
            results.append(result)
            best = result["best"]
            print(
                "seed={} basin={:.3f} pair={:.3f} excess={:.3f} viol={} step={} updates={}".format(
                    seed,
                    result["basin_score"],
                    best["pair_max"],
                    best["pair_excess_over_bound"],
                    best["violation_count"],
                    result["best_step"],
                    result["update_count"],
                )
            )
        results.sort(key=lambda x: (float(x["basin_score"]), float(x["best"]["pair_max"])))
        os.makedirs(os.path.dirname(csv_path) or ".", exist_ok=True)
        with open(csv_path, "w", newline="") as f:
            fieldnames = list(row_for_csv(results[0]).keys()) if results else []
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            for result in results:
                writer.writerow(row_for_csv(result))
        promoted = results[: max(0, int(args.promote_top_k))]
        for rank, result in enumerate(promoted, 1):
            best_path = os.path.join(
                args.out_dir,
                "probe_best_rank{}_seed{}_pairmax{:.3f}.json".format(
                    rank, int(result["seed"]), float(result["best"]["pair_max"])
                ),
            )
            write_best_json(best_path, result, tuple_value, args)
            result["probe_best_json"] = best_path
        with open(commands_path, "w") as f:
            f.write("#!/usr/bin/env bash\n")
            f.write("set -euo pipefail\n")
            for result in promoted:
                f.write(promotion_command(result, args) + "\n")
        summary = {
            "script": SCRIPT_NAME,
            "classification": "hall_pair_basin_probe_summary",
            "n": int(args.n),
            "target_order": int(4 * hall_bound(args.n)),
            "tuple": [int(x) for x in tuple_value],
            "bound": int(hall_bound(args.n)),
            "seed_start": int(args.seed_start),
            "seed_end": int(args.seed_end),
            "probe_steps": int(args.probe_steps),
            "search_objective": args.search_objective,
            "move_mode": args.move_mode,
            "targeted_prob": float(args.targeted_prob),
            "worst_theta_k": int(args.worst_theta_k),
            "position_pool": int(args.position_pool),
            "basin_score_weights": {
                "excess": float(args.basin_excess_weight),
                "violation": float(args.basin_violation_weight),
                "std": float(args.basin_std_weight),
                "step": float(args.basin_step_weight),
                "drop": float(args.basin_drop_weight),
                "update": float(args.basin_update_weight),
                "speed": float(args.basin_speed_weight),
            },
            "csv": csv_path,
            "promotion_commands": commands_path,
            "elapsed_sec": float(round(float(time.time() - start), 3)),
            "top": [
                {
                    "rank": i + 1,
                    "seed": int(result["seed"]),
                    "basin_score": float(result["basin_score"]),
                    "best": result["best"],
                    "best_step": int(result["best_step"]),
                    "update_count": int(result["update_count"]),
                    "probe_best_json": result.get("probe_best_json", ""),
                }
                for i, result in enumerate(promoted)
            ],
            "all_results": [
                {
                    "seed": int(result["seed"]),
                    "basin_score": float(result["basin_score"]),
                    "best": result["best"],
                    "best_step": int(result["best_step"]),
                    "update_count": int(result["update_count"]),
                }
                for result in results
            ],
            "notes": [
                "This is a seed/basin triage diagnostic, not a Hadamard construction.",
                "Promoted seeds still need longer Hall-pair annealing and later exact Turyn/T verification.",
            ],
        }
        write_json(json_path, summary)
        print("PROMOTION_COMMANDS:", commands_path)
        print("SUMMARY_JSON:", json_path)
        print("TOP")
        for item in summary["top"]:
            best = item["best"]
            print(
                "rank={} seed={} basin={:.3f} pair={:.3f} excess={:.3f} viol={} step={}".format(
                    item["rank"],
                    item["seed"],
                    item["basin_score"],
                    best["pair_max"],
                    best["pair_excess_over_bound"],
                    best["violation_count"],
                    item["best_step"],
                )
            )
    finally:
        tee.close()


if __name__ == "__main__":
    main()
