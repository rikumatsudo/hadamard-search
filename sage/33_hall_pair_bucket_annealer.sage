from sage.all import *

import argparse
import csv
import json
import math
import os
import random
import sys
import time

from sds_repair_utils import setup_logging, write_json


SCRIPT_NAME = "33_hall_pair_bucket_annealer"


def hall_bound(n):
    return int(3 * int(n) - 1)


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


def pair_metrics(z_hall, w_hall):
    pair = [float(a) + float(b) for a, b in zip(z_hall, w_hall)]
    pair_max = max(pair)
    pair_argmax = max(range(len(pair)), key=lambda i: pair[i])
    pair_top_indices = sorted(range(len(pair)), key=lambda i: pair[i], reverse=True)[:10]
    pair_l1_excess = sum(max(0.0, value - pair_max) for value in pair)
    # Useful flatness diagnostics independent of the bound.
    mean = sum(pair) / float(len(pair))
    variance = sum((x - mean) ** 2 for x in pair) / float(len(pair))
    return {
        "pair_max": float(pair_max),
        "pair_argmax": int(pair_argmax),
        "pair_top_indices": [int(i) for i in pair_top_indices],
        "pair_mean": float(mean),
        "pair_std": float(math.sqrt(max(0.0, variance))),
        "z_max": float(max(z_hall)),
        "w_max": float(max(w_hall)),
        "pair_values": pair,
        "pair_l1_excess_self": float(pair_l1_excess),
    }


def autocorrelation(seq, shift):
    shift = int(shift)
    if shift <= 0:
        return int(sum(int(x) * int(x) for x in seq))
    if shift >= len(seq):
        return 0
    return int(sum(int(seq[i]) * int(seq[i + shift]) for i in range(len(seq) - shift)))


def target_roughness(values):
    return int(sum((int(values[i + 1]) - int(values[i])) ** 2 for i in range(len(values) - 1)))


def target_profile_metrics(Z, W, n):
    values = []
    for s in range(1, int(n)):
        target = int(-2 * (autocorrelation(Z, s) + autocorrelation(W, s)))
        values.append(target)
    score = int(sum(x * x for x in values))
    l1 = int(sum(abs(x) for x in values))
    max_abs = int(max(abs(x) for x in values)) if values else 0
    nonzero = int(sum(1 for x in values if x != 0))
    return {
        "score": score,
        "l1_error": l1,
        "max_abs_error": max_abs,
        "nonzero_count": nonzero,
        "roughness": target_roughness(values),
        "xy_target": [int(x) for x in values],
    }


def completion_proxy_metrics(metrics, bound, Z, W, n, args):
    pair_values = metrics["pair_values"]
    constant = float(6 * int(n) - 2)
    required = [constant - 2.0 * float(value) for value in pair_values]
    small_margin = float(args.proxy_small_margin)
    near_zero_penalty = 0.0
    reciprocal_penalty = 0.0
    epsilon = 1e-6
    for value in required:
        if value < -epsilon:
            near_zero_penalty += (abs(value) + small_margin) ** 2
            reciprocal_penalty += 1.0 / epsilon
        elif value < small_margin:
            near_zero_penalty += (small_margin - value) ** 2
            reciprocal_penalty += 1.0 / max(epsilon, value)
    target = target_profile_metrics(Z, W, n)
    pair_excess = excess_over_bound(pair_values, bound)
    pair_violations = violation_count(pair_values, bound)
    hall_component = 10.0 * float(pair_excess) + 1000.0 * float(pair_violations)
    fourier_component = (
        10000.0 * float(sum(1 for x in required if x < -epsilon))
        + float(args.proxy_margin_weight) * (near_zero_penalty / float(max(1, len(required))))
        + float(args.proxy_reciprocal_weight) * (reciprocal_penalty / float(max(1, len(required))))
    )
    target_component = (
        float(args.proxy_target_score_weight) * float(target["score"])
        + float(args.proxy_target_l1_weight) * float(target["l1_error"])
        + float(args.proxy_target_maxabs_weight) * float(target["max_abs_error"])
        + float(args.proxy_target_roughness_weight) * float(target["roughness"])
    )
    total = hall_component + fourier_component + target_component
    return {
        "completion_proxy": float(total),
        "hall_component": float(hall_component),
        "fourier_component": float(fourier_component),
        "target_component": float(target_component),
        "min_required": float(min(required)) if required else 0.0,
        "negative_required_count": int(sum(1 for x in required if x < -epsilon)),
        "near_zero_penalty": float(near_zero_penalty / float(max(1, len(required)))),
        "reciprocal_margin_penalty": float(reciprocal_penalty / float(max(1, len(required)))),
        "target_profile": target,
    }


def excess_over_bound(pair_values, bound):
    return float(sum(max(0.0, float(value) - float(bound)) for value in pair_values))


def violation_count(pair_values, bound):
    return int(sum(1 for value in pair_values if float(value) > float(bound)))


def endpoint_signature(seq, width):
    width = int(width)
    return tuple(int(x) for x in (list(seq[:width]) + list(seq[-width:])))


def compact_signature(sig):
    return "".join("+" if int(x) > 0 else "-" for x in sig)


def score_tuple(metrics, bound, objective, Z=None, W=None, n=None, args=None):
    pair_values = metrics["pair_values"]
    excess = excess_over_bound(pair_values, bound)
    violations = violation_count(pair_values, bound)
    if objective == "pair_max":
        return (float(metrics["pair_max"]), excess, float(metrics["pair_std"]))
    if objective == "excess_then_pair_max":
        return (excess, float(metrics["pair_max"]), float(metrics["pair_std"]))
    if objective == "violations_then_pair_max":
        return (violations, excess, float(metrics["pair_max"]), float(metrics["pair_std"]))
    if objective == "excess_then_violations":
        return (excess, violations, float(metrics["pair_max"]), float(metrics["pair_std"]))
    if objective == "flat_pair":
        return (float(metrics["pair_max"]), float(metrics["pair_std"]), excess)
    if objective in ("completion_proxy", "completion_proxy_then_pair_max", "hall_then_completion_proxy", "pair_max_then_completion_proxy"):
        if Z is None or W is None or n is None or args is None:
            raise ValueError("completion_proxy objective requires Z/W state")
        proxy = completion_proxy_metrics(metrics, bound, Z, W, n, args)
        if objective == "completion_proxy":
            return (
                float(proxy["completion_proxy"]),
                int(proxy["negative_required_count"]),
                float(metrics["pair_max"]),
                float(proxy["min_required"] * -1.0),
            )
        return (
            float(proxy["completion_proxy"]),
            float(metrics["pair_max"]),
            float(metrics["pair_std"]),
            int(proxy["negative_required_count"]),
        ) if objective == "completion_proxy_then_pair_max" else (
            int(proxy["negative_required_count"]),
            int(violation_count(pair_values, bound)),
            float(excess),
            float(proxy["completion_proxy"]),
            float(metrics["pair_max"]),
            float(metrics["pair_std"]),
        ) if objective == "hall_then_completion_proxy" else (
            float(metrics["pair_max"]),
            float(proxy["completion_proxy"]),
            float(excess),
            int(proxy["negative_required_count"]),
        )
    raise ValueError("unknown objective {}".format(objective))


def random_balanced_flip(seq):
    plus = [i for i, x in enumerate(seq) if int(x) == 1]
    minus = [i for i, x in enumerate(seq) if int(x) == -1]
    if not plus or not minus:
        return None
    i = random.choice(plus)
    j = random.choice(minus)
    return int(i), int(j)


def apply_flip(seq, real, imag, cos_table, sin_table, i, j):
    # Swap signs at i and j, preserving sequence sum.
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


def undo_flip(seq, real, imag, cos_table, sin_table, i, j):
    apply_flip(seq, real, imag, cos_table, sin_table, i, j)


def clone_state(Z, W, zr, zi, wr, wi):
    return list(Z), list(W), list(zr), list(zi), list(wr), list(wi)


def current_metrics(zr, zi, wr, wi):
    z_hall = hall_values_from_transform(zr, zi)
    w_hall = hall_values_from_transform(wr, wi)
    return pair_metrics(z_hall, w_hall)


def random_move(Z, W):
    which = "Z" if random.random() < 0.5 else "W"
    if which == "Z":
        flip = random_balanced_flip(Z)
    else:
        flip = random_balanced_flip(W)
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
    # Bias toward the strongest few positions without becoming deterministic.
    window = max(1, min(len(items), int(math.sqrt(len(items))) + 2))
    return int(random.choice(items[:window])[1])


def targeted_worst_theta_move(Z, W, zr, zi, wr, wi, cos_table, sin_table, base_metrics, args):
    pair_values = base_metrics["pair_values"]
    worst = top_pair_indices(pair_values, args.worst_theta_k)
    if not worst:
        return random_move(Z, W)
    theta_idx = random.choice(worst)

    z_value = zr[theta_idx] * zr[theta_idx] + zi[theta_idx] * zi[theta_idx]
    w_value = wr[theta_idx] * wr[theta_idx] + wi[theta_idx] * wi[theta_idx]
    if random.random() < 0.75:
        which = "Z" if z_value >= w_value else "W"
    else:
        which = "W" if z_value >= w_value else "Z"

    if which == "Z":
        plus, minus = ranked_positions_by_theta(
            Z, zr, zi, cos_table, sin_table, theta_idx, args.position_pool
        )
    else:
        plus, minus = ranked_positions_by_theta(
            W, wr, wi, cos_table, sin_table, theta_idx, args.position_pool
        )
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
            return targeted_worst_theta_move(
                Z, W, zr, zi, wr, wi, cos_table, sin_table, base_metrics, args
            ), "targeted"
        return random_move(Z, W), "random"
    raise ValueError("unknown move mode {}".format(args.move_mode))


def apply_move(move, Z, W, zr, zi, wr, wi, cos_table, sin_table):
    which, i, j = move
    if which == "Z":
        apply_flip(Z, zr, zi, cos_table, sin_table, i, j)
    else:
        apply_flip(W, wr, wi, cos_table, sin_table, i, j)


def undo_move(move, Z, W, zr, zi, wr, wi, cos_table, sin_table):
    apply_move(move, Z, W, zr, zi, wr, wi, cos_table, sin_table)


def choose_move(Z, W, zr, zi, wr, wi, cos_table, sin_table, bound, args, base_metrics):
    best = None
    best_metrics = None
    best_key = None
    best_source = ""
    for _ in range(max(1, int(args.candidate_trials))):
        move, source = propose_move(Z, W, zr, zi, wr, wi, cos_table, sin_table, base_metrics, args)
        if move is None:
            continue
        apply_move(move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
        metrics = current_metrics(zr, zi, wr, wi)
        key = score_tuple(metrics, bound, args.objective, Z=Z, W=W, n=args.n, args=args)
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
    temp = temperature(step, args.steps, args.temperature, args.min_temperature)
    if temp <= 0:
        return False
    delta = float(new_key[0] - cur_key[0])
    return random.random() < math.exp(-max(0.0, delta) / temp)


def save_pair(path, n, tuple_value, Z, W, metrics, args, step, source):
    payload = {
        "script": SCRIPT_NAME,
        "classification": "hall_pair_bucket",
        "n": int(n),
        "target_order": int(4 * (3 * int(n) - 1)),
        "tuple": [int(x) for x in tuple_value],
        "Z": [int(x) for x in Z],
        "W": [int(x) for x in W],
        "z_sum": int(sum(Z)),
        "w_sum": int(sum(W)),
        "bound": int(hall_bound(n)),
        "pair_max": float(metrics["pair_max"]),
        "pair_argmax": int(metrics["pair_argmax"]),
        "pair_top_indices": [int(x) for x in metrics["pair_top_indices"]],
        "pair_mean": float(metrics["pair_mean"]),
        "pair_std": float(metrics["pair_std"]),
        "z_max": float(metrics["z_max"]),
        "w_max": float(metrics["w_max"]),
        "pair_excess_over_bound": excess_over_bound(metrics["pair_values"], hall_bound(n)),
        "pair_violation_count": violation_count(metrics["pair_values"], hall_bound(n)),
        "pair_hall_pass": bool(metrics["pair_max"] <= hall_bound(n)),
        "z_signature": compact_signature(endpoint_signature(Z, args.endpoint_width)),
        "w_signature": compact_signature(endpoint_signature(W, args.endpoint_width)),
        "endpoint_width": int(args.endpoint_width),
        "move_mode": args.move_mode,
        "targeted_prob": float(args.targeted_prob),
        "worst_theta_k": int(args.worst_theta_k),
        "position_pool": int(args.position_pool),
        "resume_pair_json": args.resume_pair_json,
        "step": int(step),
        "source": source,
        "notes": [
            "This is not a Hadamard construction.",
            "A Z/W Hall pair pass only permits a later X/Y completion attempt.",
        ],
    }
    if args.objective in (
        "completion_proxy",
        "completion_proxy_then_pair_max",
        "hall_then_completion_proxy",
        "pair_max_then_completion_proxy",
    ):
        payload["completion_proxy_metrics"] = completion_proxy_metrics(metrics, hall_bound(n), Z, W, n, args)
    write_json(path, payload)
    return path


def parse_tuple(text):
    parts = [int(x) for x in text.split(",")]
    if len(parts) != 4:
        raise ValueError("--tuple must be x,y,z,w")
    return tuple(parts)


def load_resume_pair(path, n, tuple_value):
    with open(path) as f:
        data = json.load(f)
    Z = [int(x) for x in data["Z"]]
    W = [int(x) for x in data["W"]]
    if len(Z) != int(n):
        raise ValueError("resume Z length {} != n {}".format(len(Z), n))
    if len(W) != int(n) - 1:
        raise ValueError("resume W length {} != n-1 {}".format(len(W), int(n) - 1))
    resume_tuple = data.get("tuple")
    if resume_tuple is not None and tuple(int(x) for x in resume_tuple) != tuple_value:
        raise ValueError("resume tuple {} != requested tuple {}".format(resume_tuple, tuple_value))
    z_sum = tuple_value[2]
    w_sum = tuple_value[3]
    if sum(Z) != z_sum:
        raise ValueError("resume Z sum {} != target {}".format(sum(Z), z_sum))
    if sum(W) != w_sum:
        raise ValueError("resume W sum {} != target {}".format(sum(W), w_sum))
    return Z, W


def parse_args():
    parser = argparse.ArgumentParser(
        description="Anneal Z/W pairs directly against the Turyn Hall pair bound."
    )
    parser.add_argument("--n", type=int, default=56)
    parser.add_argument("--tuple", default="0,-18,-2,1")
    parser.add_argument("--steps", type=int, default=50000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--grid", type=int, default=100)
    parser.add_argument("--candidate-trials", type=int, default=32)
    parser.add_argument(
        "--objective",
        choices=[
            "pair_max",
            "excess_then_pair_max",
            "violations_then_pair_max",
            "excess_then_violations",
            "flat_pair",
            "completion_proxy",
            "completion_proxy_then_pair_max",
            "hall_then_completion_proxy",
            "pair_max_then_completion_proxy",
        ],
        default="pair_max",
    )
    parser.add_argument("--strategy", choices=["greedy", "anneal"], default="anneal")
    parser.add_argument("--temperature", type=float, default=5.0)
    parser.add_argument("--min-temperature", type=float, default=0.01)
    parser.add_argument("--restart-patience", type=int, default=10000)
    parser.add_argument("--shake-rate", type=float, default=0.05)
    parser.add_argument("--endpoint-width", type=int, default=6)
    parser.add_argument("--move-mode", choices=["random", "worst_theta", "mixed"], default="random")
    parser.add_argument("--targeted-prob", type=float, default=0.7)
    parser.add_argument("--worst-theta-k", type=int, default=3)
    parser.add_argument("--position-pool", type=int, default=24)
    parser.add_argument("--resume-pair-json", default="")
    parser.add_argument("--proxy-small-margin", type=float, default=10.0)
    parser.add_argument("--proxy-margin-weight", type=float, default=50.0)
    parser.add_argument("--proxy-reciprocal-weight", type=float, default=10.0)
    parser.add_argument("--proxy-target-score-weight", type=float, default=0.10)
    parser.add_argument("--proxy-target-l1-weight", type=float, default=1.0)
    parser.add_argument("--proxy-target-maxabs-weight", type=float, default=5.0)
    parser.add_argument("--proxy-target-roughness-weight", type=float, default=0.01)
    parser.add_argument("--save-improvements", action="store_true")
    parser.add_argument("--continue-after-hall-pass", action="store_true")
    parser.add_argument("--out-prefix", default="outputs/turyn/hall_pair_anneal")
    parser.add_argument("--csv", default="")
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    csv_file = None
    try:
        random.seed(int(args.seed))
        tuple_value = parse_tuple(args.tuple)
        x_sum, y_sum, z_sum, w_sum = tuple_value
        n = int(args.n)
        rhs = x_sum * x_sum + y_sum * y_sum + 2 * z_sum * z_sum + 2 * w_sum * w_sum
        if rhs != 6 * n - 2:
            raise ValueError("tuple {} violates sum identity: {} != {}".format(tuple_value, rhs, 6 * n - 2))
        bound = hall_bound(n)
        max_len = n
        cos_table, sin_table = precompute_trig(max_len, args.grid)
        if args.resume_pair_json:
            Z, W = load_resume_pair(args.resume_pair_json, n, tuple_value)
        else:
            Z = random_pm1_with_sum(n, z_sum)
            W = random_pm1_with_sum(n - 1, w_sum)
        zr, zi = initial_transform(Z, cos_table, sin_table)
        wr, wi = initial_transform(W, cos_table, sin_table)
        metrics = current_metrics(zr, zi, wr, wi)
        cur_key = score_tuple(metrics, bound, args.objective, Z=Z, W=W, n=n, args=args)
        best_Z, best_W, best_zr, best_zi, best_wr, best_wi = clone_state(Z, W, zr, zi, wr, wi)
        best_metrics = dict(metrics)
        best_key = cur_key
        best_step = 0
        last_improvement = 0
        plateau_count = 0
        start = time.time()

        csv_path = args.csv or os.path.join("outputs/logs", "{}_{}.csv".format(SCRIPT_NAME, stamp))
        os.makedirs(os.path.dirname(csv_path) or ".", exist_ok=True)
        csv_file = open(csv_path, "w", newline="")
        writer = csv.DictWriter(
            csv_file,
            fieldnames=[
                "timestamp",
                "step",
                "pair_max",
                "z_max",
                "w_max",
                "pair_std",
                "pair_argmax",
                "pair_excess",
                "pair_violations",
                "best_pair_max",
                "best_z_max",
                "best_w_max",
                "best_pair_std",
                "best_pair_argmax",
                "best_pair_excess",
                "best_pair_violations",
                "accepted",
                "improved",
                "move_source",
                "move_mode",
                "plateau_count",
                "elapsed_sec",
            ],
        )
        writer.writeheader()

        print("CSV log:", csv_path)
        print("n={} target_order={} tuple={} bound={}".format(n, 4 * (3 * n - 1), tuple_value, bound))
        if args.resume_pair_json:
            print("resume_pair_json:", args.resume_pair_json)
        print(
            "move_mode={} targeted_prob={} worst_theta_k={} position_pool={}".format(
                args.move_mode, args.targeted_prob, args.worst_theta_k, args.position_pool
            )
        )
        print(
            "initial pair_max={:.6f} z_max={:.6f} w_max={:.6f} excess={:.6f}".format(
                metrics["pair_max"], metrics["z_max"], metrics["w_max"], excess_over_bound(metrics["pair_values"], bound)
            )
        )

        for step in range(1, int(args.steps) + 1):
            move, new_metrics, new_key, move_source = choose_move(
                Z, W, zr, zi, wr, wi, cos_table, sin_table, bound, args, metrics
            )
            accepted = False
            improved = False
            if move is not None and accept(cur_key, new_key, step, args):
                apply_move(move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
                metrics = new_metrics
                cur_key = new_key
                accepted = True
            if cur_key < best_key:
                best_Z, best_W, best_zr, best_zi, best_wr, best_wi = clone_state(Z, W, zr, zi, wr, wi)
                best_metrics = dict(metrics)
                best_key = cur_key
                best_step = step
                last_improvement = step
                improved = True
                print(
                    "BEST step={} pair_max={:.6f} theta={} z_max={:.6f} w_max={:.6f} excess={:.6f}".format(
                        step,
                        best_metrics["pair_max"],
                        best_metrics["pair_argmax"] + 1,
                        best_metrics["z_max"],
                        best_metrics["w_max"],
                        excess_over_bound(best_metrics["pair_values"], bound),
                    )
                )
                if args.save_improvements:
                    path = "{}_step{}_pairmax{:.3f}.json".format(args.out_prefix, step, best_metrics["pair_max"])
                    save_pair(path, n, tuple_value, best_Z, best_W, best_metrics, args, best_step, "improvement")
                    print("saved:", path)
                sys.stdout.flush()
            if args.restart_patience > 0 and step - last_improvement >= int(args.restart_patience):
                flips = max(1, int((len(Z) + len(W)) * float(args.shake_rate)))
                for _ in range(flips):
                    move = random_move(Z, W)
                    if move is not None:
                        apply_move(move, Z, W, zr, zi, wr, wi, cos_table, sin_table)
                metrics = current_metrics(zr, zi, wr, wi)
                cur_key = score_tuple(metrics, bound, args.objective, Z=Z, W=W, n=n, args=args)
                plateau_count += 1
                last_improvement = step
                print(
                    "PLATEAU_SHAKE step={} count={} flips={} pair_max={:.6f}".format(
                        step, plateau_count, flips, metrics["pair_max"]
                    )
                )
                sys.stdout.flush()
            if improved or step % 1000 == 0 or step == int(args.steps):
                writer.writerow(
                    {
                        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
                        "step": int(step),
                        "pair_max": float(metrics["pair_max"]),
                        "z_max": float(metrics["z_max"]),
                        "w_max": float(metrics["w_max"]),
                        "pair_std": float(metrics["pair_std"]),
                        "pair_argmax": int(metrics["pair_argmax"]) + 1,
                        "pair_excess": excess_over_bound(metrics["pair_values"], bound),
                        "pair_violations": violation_count(metrics["pair_values"], bound),
                        "best_pair_max": float(best_metrics["pair_max"]),
                        "best_z_max": float(best_metrics["z_max"]),
                        "best_w_max": float(best_metrics["w_max"]),
                        "best_pair_std": float(best_metrics["pair_std"]),
                        "best_pair_argmax": int(best_metrics["pair_argmax"]) + 1,
                        "best_pair_excess": excess_over_bound(best_metrics["pair_values"], bound),
                        "best_pair_violations": violation_count(best_metrics["pair_values"], bound),
                        "accepted": bool(accepted),
                        "improved": bool(improved),
                        "move_source": move_source,
                        "move_mode": args.move_mode,
                        "plateau_count": int(plateau_count),
                        "elapsed_sec": round(time.time() - start, 3),
                    }
                )
                csv_file.flush()
                if step % 1000 == 0 or step == int(args.steps):
                    print(
                        "step={} cur_pair={:.3f} best_pair={:.3f} best_theta={} excess={:.3f} elapsed={:.1f}s".format(
                            step,
                            metrics["pair_max"],
                            best_metrics["pair_max"],
                            best_metrics["pair_argmax"] + 1,
                            excess_over_bound(best_metrics["pair_values"], bound),
                            time.time() - start,
                        )
                    )
                    sys.stdout.flush()
            if best_metrics["pair_max"] <= bound and not args.continue_after_hall_pass:
                print("PAIR_HALL_BOUND_PASSED step={} pair_max={:.6f}".format(best_step, best_metrics["pair_max"]))
                break

        final_path = "{}_seed{}_step{}_pairmax{:.3f}.json".format(
            args.out_prefix, int(args.seed), int(best_step), float(best_metrics["pair_max"])
        )
        final_path = final_path.replace(" ", "_")
        save_pair(final_path, n, tuple_value, best_Z, best_W, best_metrics, args, best_step, "final_best")
        print("FINAL_BEST:", final_path)
        print(
            "best pair_max={:.6f} theta={} z_max={:.6f} w_max={:.6f} excess={:.6f} pass={}".format(
                best_metrics["pair_max"],
                best_metrics["pair_argmax"] + 1,
                best_metrics["z_max"],
                best_metrics["w_max"],
                excess_over_bound(best_metrics["pair_values"], bound),
                best_metrics["pair_max"] <= bound,
            )
        )
    finally:
        if csv_file is not None:
            csv_file.close()
        tee.close()


if __name__ == "__main__":
    main()
