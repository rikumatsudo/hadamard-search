from sage.all import *

import argparse
import json
import math
import os
import random
import sys
import time

from sds_repair_utils import setup_logging, write_json


SCRIPT_NAME = "42_zw_completion_proxy_diagnostics"


def parse_tuple(text):
    parts = [int(x) for x in text.split(",")]
    if len(parts) != 4:
        raise ValueError("--tuple must be x,y,z,w")
    return tuple(parts)


def load_json(path):
    with open(path) as f:
        return json.load(f)


def autocorrelation(seq, shift):
    shift = int(shift)
    if shift <= 0:
        return int(sum(int(x) * int(x) for x in seq))
    if shift >= len(seq):
        return 0
    return int(sum(int(seq[i]) * int(seq[i + shift]) for i in range(len(seq) - shift)))


def autocorrelation_vector(seq, limit):
    return [autocorrelation(seq, s) for s in range(int(limit))]


def metrics_from_vector(values):
    values = [int(x) for x in values]
    return {
        "score": int(sum(x * x for x in values)),
        "l1_error": int(sum(abs(x) for x in values)),
        "max_abs_error": int(max(abs(x) for x in values)) if values else 0,
        "nonzero_count": int(sum(1 for x in values if x != 0)),
    }


def histogram(values):
    out = {}
    for value in values:
        key = str(int(value))
        out[key] = out.get(key, 0) + 1
    return dict(sorted(out.items(), key=lambda item: int(item[0])))


def fixed_zw_vector(Z, W, n):
    nz = autocorrelation_vector(Z, n)
    nw = autocorrelation_vector(W, n)
    return [int(2 * nz[s] + 2 * nw[s]) for s in range(int(n))]


def target_profile(Z, W, n):
    fixed = fixed_zw_vector(Z, W, n)
    xy_target = [int(-fixed[s]) for s in range(1, int(n))]
    pq_target = [int(2 * x) for x in xy_target]
    return fixed, xy_target, pq_target


def target_roughness(values):
    return int(sum((int(values[i + 1]) - int(values[i])) ** 2 for i in range(len(values) - 1)))


def poly_abs_sq(seq, theta):
    total = 0j
    z = complex(math.cos(theta), math.sin(theta))
    power = 1 + 0j
    for value in seq:
        total += int(value) * power
        power *= z
    magnitude = abs(total)
    return float(magnitude * magnitude)


def fourier_required_profile(Z, W, n, grid, epsilon, small_margin):
    constant = float(6 * int(n) - 2)
    required = []
    pair_values = []
    for idx in range(int(grid)):
        theta = 2.0 * math.pi * float(idx) / float(grid)
        pair = poly_abs_sq(Z, theta) + poly_abs_sq(W, theta)
        pair_values.append(float(pair))
        required.append(float(constant - 2.0 * pair))
    mean = sum(required) / float(len(required))
    variance = sum((x - mean) * (x - mean) for x in required) / float(len(required))
    reciprocal_terms = []
    near_zero_penalty = 0.0
    for value in required:
        if value < -float(epsilon):
            reciprocal_terms.append(float(1.0 / float(epsilon)))
            near_zero_penalty += (abs(value) + float(small_margin)) ** 2
        elif value < float(small_margin):
            reciprocal_terms.append(float(1.0 / max(float(epsilon), value)))
            near_zero_penalty += (float(small_margin) - value) ** 2
    bound = float(3 * int(n) - 1)
    excess_values = [max(0.0, x - bound) for x in pair_values]
    return {
        "grid": int(grid),
        "constant": int(constant),
        "min_required": float(min(required)),
        "max_required": float(max(required)),
        "mean_required": float(mean),
        "std_required": float(math.sqrt(max(0.0, variance))),
        "negative_sample_count": int(sum(1 for x in required if x < -float(epsilon))),
        "small_required_count_1": int(sum(1 for x in required if 0 <= x <= 1.0)),
        "small_required_count_5": int(sum(1 for x in required if 0 <= x <= 5.0)),
        "small_required_count_10": int(sum(1 for x in required if 0 <= x <= 10.0)),
        "near_zero_margin": float(small_margin),
        "near_zero_energy_penalty": float(near_zero_penalty / float(len(required))),
        "reciprocal_margin_penalty": float(sum(reciprocal_terms) / float(max(1, len(required)))),
        "pair_hall_bound": float(bound),
        "pair_max": float(max(pair_values)),
        "pair_excess": float(sum(excess_values)),
        "pair_violation_count": int(sum(1 for x in pair_values if x > bound + float(epsilon))),
    }


def support_possibilities(n, x_sum, y_sum):
    p_sum = int(x_sum) + int(y_sum)
    q_sum = int(x_sum) - int(y_sum)
    out = []
    if p_sum % 2 != 0 or q_sum % 2 != 0:
        return out
    p_value_sum = p_sum // 2
    q_value_sum = q_sum // 2
    for p_support in range(int(n) + 1):
        q_support = int(n) - p_support
        if (p_support + p_value_sum) % 2 != 0:
            continue
        if (q_support + q_value_sum) % 2 != 0:
            continue
        p_plus = (p_support + p_value_sum) // 2
        p_minus = p_support - p_plus
        q_plus = (q_support + q_value_sum) // 2
        q_minus = q_support - q_plus
        if min(p_plus, p_minus, q_plus, q_minus) < 0:
            continue
        out.append(
            {
                "P_support": int(p_support),
                "P_positive": int(p_plus),
                "P_negative": int(p_minus),
                "Q_support": int(q_support),
                "Q_positive": int(q_plus),
                "Q_negative": int(q_minus),
            }
        )
    return out


def pq_from_xy(X, Y):
    return [int(x) + int(y) for x, y in zip(X, Y)], [int(x) - int(y) for x, y in zip(X, Y)]


def pq_support_summary(P, Q):
    return {
        "P_support": int(sum(1 for x in P if int(x) != 0)),
        "P_positive": int(sum(1 for x in P if int(x) > 0)),
        "P_negative": int(sum(1 for x in P if int(x) < 0)),
        "P_sum": int(sum(P)),
        "Q_support": int(sum(1 for x in Q if int(x) != 0)),
        "Q_positive": int(sum(1 for x in Q if int(x) > 0)),
        "Q_negative": int(sum(1 for x in Q if int(x) < 0)),
        "Q_sum": int(sum(Q)),
    }


def pq_autocorrelation(P, Q, shift):
    shift = int(shift)
    n = len(P)
    total = 0
    for i in range(0, n - shift):
        total += int(P[i]) * int(P[i + shift])
        total += int(Q[i]) * int(Q[i + shift])
    return int(total)


def pq_residuals(P, Q, pq_target):
    return [int(pq_autocorrelation(P, Q, s)) - int(pq_target[s - 1]) for s in range(1, len(P))]


def residual_metrics(residuals):
    metrics = metrics_from_vector(residuals)
    metrics["residual_histogram"] = histogram(residuals)
    return metrics


def categories_from_support(option):
    categories = []
    categories.extend(["P+"] * int(option["P_positive"]))
    categories.extend(["P-"] * int(option["P_negative"]))
    categories.extend(["Q+"] * int(option["Q_positive"]))
    categories.extend(["Q-"] * int(option["Q_negative"]))
    return categories


def categories_to_pq(categories):
    P = []
    Q = []
    for item in categories:
        if item == "P+":
            P.append(2)
            Q.append(0)
        elif item == "P-":
            P.append(-2)
            Q.append(0)
        elif item == "Q+":
            P.append(0)
            Q.append(2)
        elif item == "Q-":
            P.append(0)
            Q.append(-2)
        else:
            raise ValueError("bad category {}".format(item))
    return P, Q


def objective_tuple(metrics, objective):
    if objective == "score":
        return (
            int(metrics["score"]),
            int(metrics["l1_error"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_count"]),
        )
    if objective == "l1":
        return (
            int(metrics["l1_error"]),
            int(metrics["score"]),
            int(metrics["max_abs_error"]),
            int(metrics["nonzero_count"]),
        )
    if objective == "max_abs":
        return (
            int(metrics["max_abs_error"]),
            int(metrics["l1_error"]),
            int(metrics["score"]),
            int(metrics["nonzero_count"]),
        )
    raise ValueError("unknown objective {}".format(objective))


def evaluate_categories(categories, pq_target):
    P, Q = categories_to_pq(categories)
    residuals = pq_residuals(P, Q, pq_target)
    metrics = residual_metrics(residuals)
    return P, Q, residuals, metrics


def pressure_by_position(categories, residuals):
    n = len(categories)
    pressure = [0] * n
    for s, defect in enumerate(residuals, start=1):
        if int(defect) == 0:
            continue
        value = abs(int(defect))
        for i in range(0, n - s):
            pressure[i] += value
            pressure[i + s] += value
    return pressure


def propose_category_swap(categories, residuals, targeted_prob):
    n = len(categories)
    if random.random() >= float(targeted_prob):
        i = random.randrange(n)
        j = random.randrange(n)
        while j == i or categories[j] == categories[i]:
            j = random.randrange(n)
        return int(i), int(j)
    pressure = pressure_by_position(categories, residuals)
    ranked = sorted(range(n), key=lambda idx: pressure[idx], reverse=True)
    window = max(2, min(n, int(math.sqrt(n)) + 4))
    for _ in range(32):
        i = random.choice(ranked[:window])
        j = random.randrange(n)
        if i != j and categories[i] != categories[j]:
            return int(i), int(j)
    return propose_category_swap(categories, residuals, 0.0)


def relax_one_support(option, pq_target, args):
    best = None
    best_categories = None
    best_residuals = None
    restarts = max(1, int(args.pq_relax_restarts))
    steps = max(0, int(args.pq_relax_steps))
    trials = max(1, int(args.pq_relax_candidate_trials))
    for restart in range(restarts):
        categories = categories_from_support(option)
        random.shuffle(categories)
        _, _, residuals, cur_metrics = evaluate_categories(categories, pq_target)
        cur_key = objective_tuple(cur_metrics, args.pq_relax_objective)
        if best is None or cur_key < objective_tuple(best, args.pq_relax_objective):
            best = dict(cur_metrics)
            best_categories = list(categories)
            best_residuals = list(residuals)
        for step in range(steps):
            best_move = None
            best_move_metrics = None
            best_move_residuals = None
            best_move_key = None
            for _ in range(trials):
                i, j = propose_category_swap(categories, residuals, args.pq_relax_targeted_prob)
                categories[i], categories[j] = categories[j], categories[i]
                _, _, cand_residuals, cand_metrics = evaluate_categories(categories, pq_target)
                key = objective_tuple(cand_metrics, args.pq_relax_objective)
                categories[i], categories[j] = categories[j], categories[i]
                if best_move is None or key < best_move_key:
                    best_move = (i, j)
                    best_move_metrics = cand_metrics
                    best_move_residuals = cand_residuals
                    best_move_key = key
            if best_move is None:
                continue
            accept = best_move_key <= cur_key
            if not accept and args.pq_relax_anneal:
                delta = float(best_move_key[0] - cur_key[0])
                temp = max(0.05, 2.0 * (1.0 - float(step) / float(max(1, steps))))
                accept = random.random() < math.exp(-max(0.0, delta) / temp)
            if accept:
                i, j = best_move
                categories[i], categories[j] = categories[j], categories[i]
                residuals = best_move_residuals
                cur_metrics = dict(best_move_metrics)
                cur_key = best_move_key
                if cur_key < objective_tuple(best, args.pq_relax_objective):
                    best = dict(cur_metrics)
                    best_categories = list(categories)
                    best_residuals = list(residuals)
    P, Q = categories_to_pq(best_categories)
    return {
        "support_option": option,
        "metrics": best,
        "P": [int(x) for x in P],
        "Q": [int(x) for x in Q],
        "residuals": [int(x) for x in best_residuals],
        "residual_histogram": histogram(best_residuals),
    }


def support_option_rank(option, supplied_support):
    if not supplied_support:
        return (
            abs(int(option["P_support"]) - int(option["Q_support"])),
            int(option["P_support"]),
        )
    return (
        abs(int(option["P_support"]) - int(supplied_support["P_support"])),
        abs(int(option["P_positive"]) - int(supplied_support["P_positive"])),
        abs(int(option["Q_positive"]) - int(supplied_support["Q_positive"])),
        int(option["P_support"]),
    )


def pq_relaxation(pq_target, support_options, args, supplied_support=None):
    if args.skip_pq_relax:
        return None
    options = sorted(
        support_options,
        key=lambda item: support_option_rank(item, supplied_support),
    )
    if int(args.support_limit) > 0:
        options = options[: int(args.support_limit)]
    rows = []
    best = None
    for idx, option in enumerate(options, 1):
        print("P/Q relax support {}/{}: {}".format(idx, len(options), option))
        sys.stdout.flush()
        row = relax_one_support(option, pq_target, args)
        rows.append(row)
        if best is None or objective_tuple(row["metrics"], args.pq_relax_objective) < objective_tuple(
            best["metrics"], args.pq_relax_objective
        ):
            best = row
        print("  best metrics:", row["metrics"])
        sys.stdout.flush()
    return {
        "objective": args.pq_relax_objective,
        "support_options_evaluated": int(len(rows)),
        "steps": int(args.pq_relax_steps),
        "restarts": int(args.pq_relax_restarts),
        "candidate_trials": int(args.pq_relax_candidate_trials),
        "best": best,
        "rows": rows,
    }


def supplied_xy_diagnostics(data, n, tuple_value, pq_target):
    if "X" not in data or "Y" not in data:
        return None
    X = [int(x) for x in data["X"]]
    Y = [int(x) for x in data["Y"]]
    if len(X) != int(n) or len(Y) != int(n):
        raise ValueError("supplied X/Y lengths incompatible with n={}".format(n))
    if (sum(X), sum(Y)) != (tuple_value[0], tuple_value[1]):
        raise ValueError("supplied X/Y sums {} != tuple {}".format((sum(X), sum(Y)), tuple_value[:2]))
    P, Q = pq_from_xy(X, Y)
    residuals = pq_residuals(P, Q, pq_target)
    return {
        "X_sum": int(sum(X)),
        "Y_sum": int(sum(Y)),
        "P": [int(x) for x in P],
        "Q": [int(x) for x in Q],
        "pq_support": pq_support_summary(P, Q),
        "pq_residual_metrics": residual_metrics(residuals),
        "pq_residuals": [int(x) for x in residuals],
    }


def _pq_metrics_for_proxy(pq_relax, supplied_xy):
    candidates = []
    if pq_relax and pq_relax.get("best"):
        candidates.append(("relaxed_pq", pq_relax["best"]["metrics"]))
    if supplied_xy:
        candidates.append(("supplied_xy", supplied_xy["pq_residual_metrics"]))
    if not candidates:
        return None, None
    candidates.sort(key=lambda row: (int(row[1]["l1_error"]), int(row[1]["score"]), int(row[1]["max_abs_error"])))
    return candidates[0]


def completion_proxy_score(target_metrics, target_roughness_value, fourier, pq_relax, supplied_xy=None):
    hall_component = 10.0 * float(fourier["pair_excess"]) + 1000.0 * float(fourier["pair_violation_count"])
    negative_component = 10000.0 * float(fourier["negative_sample_count"])
    margin_component = 50.0 * float(fourier["near_zero_energy_penalty"]) + 10.0 * float(
        fourier["reciprocal_margin_penalty"]
    )
    target_component = (
        0.10 * float(target_metrics["score"])
        + 1.0 * float(target_metrics["l1_error"])
        + 5.0 * float(target_metrics["max_abs_error"])
        + 0.01 * float(target_roughness_value)
    )
    pq_component = 0.0
    pq_source, best = _pq_metrics_for_proxy(pq_relax, supplied_xy)
    if best:
        pq_component = 0.25 * float(best["score"]) + 5.0 * float(best["l1_error"]) + 20.0 * float(
            best["max_abs_error"]
        )
    return {
        "hall_component": float(hall_component),
        "negative_fourier_component": float(negative_component),
        "fourier_margin_component": float(margin_component),
        "target_profile_component": float(target_component),
        "pq_relax_component": float(pq_component),
        "pq_component_source": pq_source,
        "pq_component_metrics": best,
        "total": float(hall_component + negative_component + margin_component + target_component + pq_component),
        "formula": "10*pair_excess + 1000*pair_violations + 10000*negative_samples + 50*near_zero_energy_penalty + 10*reciprocal_margin_penalty + 0.10*target_score + l1 + 5*max_abs + 0.01*roughness + 0.25*pq_score + 5*pq_l1 + 20*pq_max_abs",
    }


def write_markdown(path, payload):
    lines = []
    lines.append("# Z/W Completion Proxy Diagnostics")
    lines.append("")
    lines.append("This is a heuristic diagnostic for X/Y-completability of a fixed Turyn Z/W pair.")
    lines.append("It is not a proof and not a Hadamard construction.")
    lines.append("")
    lines.append("## Input")
    lines.append("")
    lines.append("- path: `{}`".format(payload["input"]["path"]))
    lines.append("- n: `{}`".format(payload["n"]))
    lines.append("- order: `{}`".format(payload["target_order"]))
    lines.append("- tuple: `{}`".format(payload["tuple"]))
    lines.append("")
    lines.append("## Target Profile")
    lines.append("")
    t = payload["target_profile"]
    lines.append("- metrics: `{}`".format(t["metrics"]))
    lines.append("- roughness: `{}`".format(t["roughness"]))
    lines.append("- histogram: `{}`".format(t["histogram"]))
    lines.append("")
    lines.append("## Fourier and Hall")
    lines.append("")
    f = payload["fourier_required"]
    for key in [
        "min_required",
        "max_required",
        "std_required",
        "negative_sample_count",
        "small_required_count_10",
        "near_zero_energy_penalty",
        "reciprocal_margin_penalty",
        "pair_max",
        "pair_excess",
        "pair_violation_count",
    ]:
        lines.append("- {}: `{}`".format(key, f[key]))
    lines.append("")
    if payload.get("supplied_xy"):
        lines.append("## Supplied X/Y")
        lines.append("")
        lines.append("- P/Q support: `{}`".format(payload["supplied_xy"]["pq_support"]))
        lines.append("- P/Q residual metrics: `{}`".format(payload["supplied_xy"]["pq_residual_metrics"]))
        lines.append("")
    if payload.get("pq_relaxation"):
        lines.append("## P/Q Relaxation Proxy")
        lines.append("")
        best = payload["pq_relaxation"]["best"]
        lines.append("- support options evaluated: `{}`".format(payload["pq_relaxation"]["support_options_evaluated"]))
        lines.append("- best support option: `{}`".format(best["support_option"]))
        lines.append("- best residual metrics: `{}`".format(best["metrics"]))
        lines.append("")
    lines.append("## Completion Proxy Score")
    lines.append("")
    for key, value in payload["completion_proxy_score"].items():
        lines.append("- {}: `{}`".format(key, value))
    lines.append("")
    lines.append("## Interpretation")
    lines.append("")
    for item in payload["interpretation"]:
        lines.append("- {}".format(item))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Score a fixed Turyn Z/W pair by cheap X/Y-completability proxies.")
    parser.add_argument("zw_json")
    parser.add_argument("--n", type=int, default=56)
    parser.add_argument("--tuple", default="0,-18,-2,1")
    parser.add_argument("--fourier-grid", type=int, default=1000)
    parser.add_argument("--epsilon", type=float, default=1e-6)
    parser.add_argument("--small-margin", type=float, default=10.0)
    parser.add_argument("--support-limit", type=int, default=8)
    parser.add_argument("--pq-relax-steps", type=int, default=500)
    parser.add_argument("--pq-relax-restarts", type=int, default=3)
    parser.add_argument("--pq-relax-candidate-trials", type=int, default=32)
    parser.add_argument("--pq-relax-targeted-prob", type=float, default=0.7)
    parser.add_argument("--pq-relax-objective", choices=["score", "l1", "max_abs"], default="l1")
    parser.add_argument("--pq-relax-anneal", action="store_true")
    parser.add_argument("--skip-pq-relax", action="store_true")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--out-prefix", default="outputs/turyn/zw_completion_proxy")
    args = parser.parse_args()
    args.tuple_value = parse_tuple(args.tuple)
    return args


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        random.seed(int(args.seed))
        data = load_json(args.zw_json)
        n = int(args.n)
        tuple_value = args.tuple_value
        if tuple(data.get("tuple", tuple_value)) != tuple_value:
            print("warning: input tuple {} differs from CLI tuple {}".format(data.get("tuple"), tuple_value))
        Z = [int(x) for x in data["Z"]]
        W = [int(x) for x in data["W"]]
        if len(Z) != n or len(W) != n - 1:
            raise ValueError("Z/W lengths {},{} incompatible with n={}".format(len(Z), len(W), n))
        if (sum(Z), sum(W)) != (tuple_value[2], tuple_value[3]):
            raise ValueError("Z/W sums {} != tuple Z/W {}".format((sum(Z), sum(W)), tuple_value[2:]))

        fixed, xy_target, pq_target = target_profile(Z, W, n)
        target_metrics = metrics_from_vector(xy_target)
        roughness = target_roughness(xy_target)
        fourier = fourier_required_profile(Z, W, n, args.fourier_grid, args.epsilon, args.small_margin)
        support_options = support_possibilities(n, tuple_value[0], tuple_value[1])
        supplied = supplied_xy_diagnostics(data, n, tuple_value, pq_target)
        supplied_support = supplied["pq_support"] if supplied else None
        pq_relax = pq_relaxation(pq_target, support_options, args, supplied_support=supplied_support)
        proxy = completion_proxy_score(target_metrics, roughness, fourier, pq_relax, supplied_xy=supplied)

        interpretation = []
        if supplied and supplied["pq_residual_metrics"]["score"] == 0:
            interpretation.append("The supplied X/Y realizes the Z/W target exactly; this is a positive-control completion.")
        if fourier["negative_sample_count"] > 0:
            interpretation.append("The sampled Fourier required profile has negative samples; this Z/W is unsuitable on this diagnostic grid.")
        elif fourier["min_required"] < 1.0:
            interpretation.append("The sampled Fourier required profile is nonnegative but has near-zero modes; completion is likely phase-sensitive.")
        else:
            interpretation.append("The sampled Fourier required profile has positive margin on this grid.")
        if pq_relax and pq_relax.get("best"):
            best_metrics = pq_relax["best"]["metrics"]
            interpretation.append(
                "The P/Q relaxation residual is a cheap basin proxy only; low residual suggests X/Y-completability but does not prove it."
            )
            if best_metrics["l1_error"] > 0:
                interpretation.append("The relaxation did not reach zero residual in the allotted budget.")
        interpretation.append("Exact success still requires Turyn type, T-sequence, and integer HH^T verification.")

        payload = {
            "script": SCRIPT_NAME,
            "classification": "turyn_zw_completion_proxy_diagnostic",
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "input": {
                "path": args.zw_json,
                "classification": data.get("classification"),
                "pair_max": data.get("pair_max"),
                "pair_hall_pass": data.get("pair_hall_pass"),
            },
            "n": int(n),
            "target_order": int(4 * (3 * n - 1)),
            "tuple": [int(x) for x in tuple_value],
            "z_sum": int(sum(Z)),
            "w_sum": int(sum(W)),
            "target_profile": {
                "xy_target": [int(x) for x in xy_target],
                "pq_target": [int(x) for x in pq_target],
                "metrics": target_metrics,
                "histogram": histogram(xy_target),
                "roughness": int(roughness),
            },
            "fourier_required": fourier,
            "pq_support_possibilities": support_options,
            "supplied_xy": supplied,
            "pq_relaxation": pq_relax,
            "completion_proxy_score": proxy,
            "interpretation": interpretation,
            "notes": [
                "This proxy is intended for ranking Z/W basins before expensive X/Y completion.",
                "Floating-point Fourier diagnostics are not used as final proof.",
                "Near-hit or proxy improvement is not a Hadamard construction.",
            ],
        }

        out_json = "{}_n{}_seed{}.json".format(args.out_prefix, n, int(args.seed))
        out_md = "{}_n{}_seed{}.md".format(args.out_prefix, n, int(args.seed))
        write_json(out_json, payload)
        write_markdown(out_md, payload)

        print("input:", args.zw_json)
        print("target metrics:", target_metrics, "roughness:", roughness)
        print(
            "fourier min={:.12f} neg={} near_zero_penalty={:.6f} pair_max={:.6f}".format(
                fourier["min_required"],
                fourier["negative_sample_count"],
                fourier["near_zero_energy_penalty"],
                fourier["pair_max"],
            )
        )
        if supplied:
            print("supplied XY P/Q residual:", supplied["pq_residual_metrics"])
        if pq_relax and pq_relax.get("best"):
            print("relaxed P/Q best:", pq_relax["best"]["metrics"])
        print("completion proxy total:", proxy["total"])
        print("WROTE:", out_json)
        print("WROTE:", out_md)
    finally:
        tee.close()


if __name__ == "__main__":
    main()
