from sage.all import *

import argparse
import csv
import json
import math
import os
import random
import sys
import time

from sds_repair_utils import (
    canonical_hash,
    canonical_repr_summary,
    p_adic_moment_summary,
)


DEFAULT_V = 167
DEFAULT_KS = (71, 81, 82, 82)
DEFAULT_LAM = 149


class Tee(object):
    def __init__(self, path):
        self.terminal = sys.stdout
        self.log = open(path, "w")

    def write(self, data):
        self.terminal.write(data)
        self.log.write(data)

    def flush(self):
        self.terminal.flush()
        self.log.flush()

    def close(self):
        self.log.close()


def timestamp():
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def stamp_for_path():
    return "{}_pid{}".format(time.strftime("%Y%m%d_%H%M%S"), os.getpid())


def setup_logging(script_name):
    os.makedirs("outputs/logs", exist_ok=True)
    stamp = stamp_for_path()
    path = os.path.join("outputs/logs", "{}_{}.log".format(script_name, stamp))
    tee = Tee(path)
    sys.stdout = tee
    print("Log:", path)
    return tee, stamp


def parse_ks(value):
    try:
        ks = tuple(int(part.strip()) for part in value.split(",") if part.strip())
    except ValueError:
        raise argparse.ArgumentTypeError("--ks must contain comma-separated ints")
    if len(ks) != 4:
        raise argparse.ArgumentTypeError("--ks must contain exactly four ints")
    return ks


def validate_params(v, ks, lam):
    if v <= 0:
        raise ValueError("v must be positive")
    if len(ks) != 4:
        raise ValueError("ks must contain exactly four block sizes")
    if any(k < 0 or k > v for k in ks):
        raise ValueError("each block size must lie between 0 and v")
    if lam != sum(ks) - v:
        raise ValueError(
            "lambda={} does not equal sum(ks)-v={}".format(lam, sum(ks) - v)
        )
    lhs = sum(k * (k - 1) for k in ks)
    rhs = lam * (v - 1)
    if lhs != rhs:
        raise ValueError(
            "SDS parameter equation failed for ks={}, lambda={}: {} != {}".format(
                ks, lam, lhs, rhs
            )
        )


def load_parameter_sets(path, v):
    with open(path) as f:
        data = json.load(f)
    if int(data.get("v", v)) != v:
        raise ValueError("parameter file v does not match --v")

    out = []
    for item in data.get("parameter_sets", []):
        ks = tuple(int(k) for k in item["ks"])
        lam = int(item["lambda"])
        validate_params(v, ks, lam)
        out.append((ks, lam))
    if not out:
        raise ValueError("no parameter_sets found in {}".format(path))
    return out


def choose_parameter_sets(args):
    if args.all_params or args.param_index is not None:
        params = load_parameter_sets(args.params_json, args.v)
        if args.param_index is not None:
            if args.param_index < 0 or args.param_index >= len(params):
                raise ValueError(
                    "--param-index {} out of range 0..{}".format(
                        args.param_index, len(params) - 1
                    )
                )
            return [params[args.param_index]]
        return params

    if args.resume_json is not None and args.ks is None and args.lam is None:
        with open(args.resume_json) as f:
            data = json.load(f)
        v = int(data["v"])
        if v != args.v:
            raise ValueError("resume v={} does not match --v={}".format(v, args.v))
        ks = tuple(int(k) for k in data["ks"])
        lam = int(data["lambda"])
        validate_params(args.v, ks, lam)
        return [(ks, lam)]

    ks = args.ks if args.ks is not None else DEFAULT_KS
    lam = args.lam if args.lam is not None else sum(ks) - args.v
    validate_params(args.v, ks, lam)
    return [(ks, lam)]


def choose_seeds(args):
    if args.seed is not None:
        return [int(args.seed)]
    if args.seed_start is None and args.seed_end is None:
        return [1]

    start = 1 if args.seed_start is None else int(args.seed_start)
    end = start if args.seed_end is None else int(args.seed_end)
    if end < start:
        raise ValueError("--seed-end must be greater than or equal to --seed-start")
    return list(range(start, end + 1))


def random_blocks(v, ks):
    universe = list(range(v))
    return [set(random.sample(universe, int(k))) for k in ks]


def normalize_blocks(v, raw_blocks):
    if len(raw_blocks) != 4:
        raise ValueError("expected exactly four blocks, got {}".format(len(raw_blocks)))

    blocks = []
    for idx, raw_block in enumerate(raw_blocks):
        values = [int(x) for x in raw_block]
        out_of_range = [x for x in values if x < 0 or x >= v]
        if out_of_range:
            raise ValueError(
                "resume block {} has elements outside Z_{}: {}".format(
                    idx, v, out_of_range[:20]
                )
            )
        if len(values) != len(set(values)):
            raise ValueError("resume block {} has duplicate elements".format(idx))
        blocks.append(set(values))
    return blocks


def load_resume_blocks(path, expected_v, expected_ks, expected_lam):
    with open(path) as f:
        data = json.load(f)

    v = int(data["v"])
    n = int(data.get("n", 4 * v))
    ks = tuple(int(k) for k in data["ks"])
    lam = int(data["lambda"])

    if v != expected_v:
        raise ValueError("resume v={} does not match expected v={}".format(v, expected_v))
    if n != 4 * v:
        raise ValueError("resume n={} does not equal 4*v={}".format(n, 4 * v))
    if ks != tuple(int(k) for k in expected_ks):
        raise ValueError("resume ks={} does not match expected ks={}".format(ks, expected_ks))
    if lam != expected_lam:
        raise ValueError(
            "resume lambda={} does not match expected lambda={}".format(
                lam, expected_lam
            )
        )

    blocks = normalize_blocks(v, data["blocks"])
    block_sizes = tuple(len(block) for block in blocks)
    if block_sizes != ks:
        raise ValueError(
            "resume block sizes {} do not match ks {}".format(block_sizes, ks)
        )

    validate_params(v, ks, lam)
    return blocks, data


def total_diff_counts(v, blocks):
    total = [0] * v
    for block in blocks:
        block = list(block)
        for x in block:
            for y in block:
                if x != y:
                    total[(x - y) % v] += 1
    return total


def delta_swap(v, block, removed, added):
    delta = [0] * v
    others = set(block)
    others.remove(removed)
    for y in others:
        delta[(removed - y) % v] -= 1
        delta[(y - removed) % v] -= 1
        delta[(added - y) % v] += 1
        delta[(y - added) % v] += 1
    return delta


def metrics_from_counts(counts, lam):
    score = 0
    l1_error = 0
    max_abs_error = 0
    nonzero_defect_count = 0
    for d in range(1, len(counts)):
        err = int(counts[d] - lam)
        abs_err = abs(err)
        score += err * err
        l1_error += abs_err
        if abs_err > max_abs_error:
            max_abs_error = abs_err
        if err != 0:
            nonzero_defect_count += 1
    return (
        int(score),
        int(l1_error),
        int(max_abs_error),
        int(nonzero_defect_count),
    )


OBJECTIVE_ORDERS = {
    "score_first": (0, 1, 2, 3),
    "l1_first": (1, 0, 2, 3),
    "nonzero_first": (3, 1, 2, 0),
    "maxabs_first": (2, 1, 0, 3),
}

SOFT_OBJECTIVES = set(["soft_nonzero", "soft_l1_nonzero"])
BOUNDED_OBJECTIVES = set(["bounded_score_nonzero", "bounded_score_l1"])
NOVELTY_OBJECTIVES = set(["novelty_soft_l1", "novelty_score_first"])
CAPPED_NOVELTY_OBJECTIVES = set(
    ["capped_novelty_soft_l1", "capped_novelty_score_first"]
)
MOMENT_OBJECTIVES = set(["moment_score_cap", "moment_lock_score_cap"])
OBJECTIVE_SCHEDULES = (
    set(OBJECTIVE_ORDERS)
    | SOFT_OBJECTIVES
    | BOUNDED_OBJECTIVES
    | NOVELTY_OBJECTIVES
    | CAPPED_NOVELTY_OBJECTIVES
    | MOMENT_OBJECTIVES
)


def defect_vector_from_counts(counts, lam):
    return [int(counts[d] - lam) for d in range(1, len(counts))]


def parse_moment_power_list(value):
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return [int(x) for x in value]
    text = str(value).strip()
    if not text:
        return []
    return [int(part.strip()) for part in text.split(",") if part.strip()]


def moment_lock_target_stats(counts, lam, config):
    if counts is None or lam is None:
        return {}
    all_powers = [2, 4, 6]
    lock_powers = parse_moment_power_list(getattr(config, "moment_lock_powers", ""))
    target_powers = parse_moment_power_list(getattr(config, "moment_target_powers", ""))
    if not target_powers:
        target_powers = [power for power in all_powers if power not in set(lock_powers)]
    lock_summary = (
        p_adic_moment_summary(counts, lam, powers=lock_powers, modulus=len(counts))
        if lock_powers
        else {
            "powers": [],
            "moments": [],
            "moment_zero_count": 0,
            "moment_abs_sum": 0,
            "moment_all_zero": True,
            "moment_signature": "",
        }
    )
    target_summary = (
        p_adic_moment_summary(counts, lam, powers=target_powers, modulus=len(counts))
        if target_powers
        else {
            "powers": [],
            "moments": [],
            "moment_zero_count": 0,
            "moment_abs_sum": 0,
            "moment_all_zero": True,
            "moment_signature": "",
        }
    )
    lock_violation_count = len(lock_powers) - int(lock_summary["moment_zero_count"])
    return {
        "moment_lock_powers": [int(power) for power in lock_powers],
        "moment_target_powers": [int(power) for power in target_powers],
        "moment_lock_summary": lock_summary,
        "moment_target_summary": target_summary,
        "moment_lock_violation_count": int(lock_violation_count),
        "moment_lock_abs_sum": int(lock_summary["moment_abs_sum"]),
        "moment_lock_all_zero": bool(lock_violation_count == 0),
        "moment_target_zero_count": int(target_summary["moment_zero_count"]),
        "moment_target_abs_sum": int(target_summary["moment_abs_sum"]),
        "moment_target_all_zero": bool(target_summary["moment_all_zero"]),
    }


def support_symdiff(left, right):
    left_support = set(idx for idx, value in enumerate(left) if int(value) != 0)
    right_support = set(idx for idx, value in enumerate(right) if int(value) != 0)
    return len(left_support.symmetric_difference(right_support))


def sign_hamming(left, right):
    def sign(value):
        value = int(value)
        if value < 0:
            return -1
        if value > 0:
            return 1
        return 0

    return sum(1 for a, b in zip(left, right) if sign(a) != sign(b))


def l1_distance(left, right):
    return sum(abs(int(a) - int(b)) for a, b in zip(left, right))


def l2_distance_squared(left, right):
    return sum((int(a) - int(b)) ** 2 for a, b in zip(left, right))


def load_cluster_medoids(path):
    if not path:
        return []
    with open(path) as f:
        data = json.load(f)
    medoids = []
    for item in data.get("clusters", []):
        medoid = item.get("medoid", {})
        vector = medoid.get("defect_vector")
        if not isinstance(vector, list):
            continue
        medoids.append(
            {
                "cluster_id": int(item.get("cluster_id")),
                "members_count": int(item.get("members_count", 0)),
                "medoid_path": medoid.get("path", ""),
                "medoid_metrics": [
                    int(medoid.get("score", 0)),
                    int(medoid.get("l1_error", 0)),
                    int(medoid.get("max_abs_error", 0)),
                    int(medoid.get("nonzero_defect_count", 0)),
                ],
                "defect_vector": [int(x) for x in vector],
            }
        )
    medoids.sort(key=lambda item: item["cluster_id"])
    return medoids


def cluster_distance_stats_from_vector(vector, config):
    if not getattr(config, "cluster_aware", False):
        return {}
    medoids = getattr(config, "cluster_medoids", [])
    if not medoids:
        return {}

    avoid_id = int(getattr(config, "avoid_cluster_id", 0))
    avoid = None
    nearest = None
    nearest_l1 = None
    for medoid in medoids:
        dist = l1_distance(vector, medoid["defect_vector"])
        if medoid["cluster_id"] == avoid_id:
            avoid = medoid
        if nearest_l1 is None or dist < nearest_l1:
            nearest = medoid
            nearest_l1 = dist

    stats = {
        "cluster_aware": True,
        "nearest_cluster_id": int(nearest["cluster_id"]) if nearest else None,
        "nearest_cluster_distance": int(nearest_l1) if nearest_l1 is not None else None,
        "novelty_score": 0,
    }
    if avoid is not None:
        dist_l1 = l1_distance(vector, avoid["defect_vector"])
        stats.update(
            {
                "avoid_cluster_id": int(avoid_id),
                "dist_l1_to_cluster0": int(dist_l1),
                "dist_l2_to_cluster0": float(math.sqrt(l2_distance_squared(vector, avoid["defect_vector"]))),
                "support_symdiff_to_cluster0": int(
                    support_symdiff(vector, avoid["defect_vector"])
                ),
                "sign_hamming_to_cluster0": int(
                    sign_hamming(vector, avoid["defect_vector"])
                ),
                "novelty_score": int(dist_l1),
            }
        )
    return stats


def cluster_distance_stats(counts, lam, config):
    if counts is None or lam is None:
        return {}
    return cluster_distance_stats_from_vector(defect_vector_from_counts(counts, lam), config)


def objective_config(config):
    if hasattr(config, "objective_schedule"):
        return (
            config.objective_schedule,
            float(config.soft_alpha),
            float(config.soft_beta),
            float(config.soft_gamma),
            int(config.score_slack),
        )
    return (config, 0.1, 0.5, 2.0, 60)


def novelty_cap_stats(metrics, config):
    score, l1_error, max_abs_error, nonzero_defect_count = metrics
    score_cap = int(getattr(config, "novelty_score_cap", 240))
    l1_cap = int(getattr(config, "novelty_l1_cap", 140))
    maxabs_cap = int(getattr(config, "novelty_maxabs_cap", 3))
    score_violation = max(0, int(score) - score_cap)
    l1_violation = max(0, int(l1_error) - l1_cap)
    maxabs_violation = max(0, int(max_abs_error) - maxabs_cap)
    violation_amount = score_violation + l1_violation + 100 * maxabs_violation
    return {
        "novelty_score_cap": int(score_cap),
        "novelty_l1_cap": int(l1_cap),
        "novelty_maxabs_cap": int(maxabs_cap),
        "within_novelty_cap": bool(violation_amount == 0),
        "cap_violation_amount": int(violation_amount),
    }


def json_number(value):
    try:
        int_value = int(value)
        if value == int_value:
            return int_value
    except (TypeError, ValueError):
        pass
    return float(value)


def objective_value(metrics, config, reference_score=None, counts=None, lam=None):
    schedule, alpha, beta, gamma, score_slack = objective_config(config)
    score, l1_error, max_abs_error, nonzero_defect_count = metrics
    score = int(score)
    l1_error = int(l1_error)
    max_abs_error = int(max_abs_error)
    nonzero_defect_count = int(nonzero_defect_count)

    if schedule == "moment_score_cap":
        cap = int(getattr(config, "moment_score_cap", 220))
        weight = float(getattr(config, "moment_weight", 1000.0))
        if counts is None or lam is None:
            return float(score)
        summary = p_adic_moment_summary(counts, lam, modulus=len(counts))
        if score <= cap:
            return (
                float(score)
                + float(summary["moment_abs_sum"]) / float(max(1, len(counts)))
                - weight * float(summary["moment_zero_count"])
            )
        return 1000000000.0 + float(score)
    if schedule == "moment_lock_score_cap":
        cap = int(getattr(config, "moment_score_cap", 260))
        lock_penalty = float(getattr(config, "moment_lock_penalty", 500.0))
        target_weight = float(getattr(config, "moment_target_weight", 1.0))
        zero_weight = float(getattr(config, "moment_weight", 1000.0))
        if counts is None or lam is None:
            return float(score)
        stats = moment_lock_target_stats(counts, lam, config)
        lock_violation = int(stats.get("moment_lock_violation_count", 0))
        lock_abs = int(stats.get("moment_lock_abs_sum", 0))
        target_abs = int(stats.get("moment_target_abs_sum", 0))
        target_zero = int(stats.get("moment_target_zero_count", 0))
        value = (
            float(score)
            + lock_penalty * float(lock_violation)
            + target_weight * float(target_abs)
            + float(lock_abs) / float(max(1, len(counts)))
            - zero_weight * float(target_zero)
        )
        if score > cap:
            value += 1000000000.0 + float(score - cap)
        return value
    if schedule == "soft_nonzero":
        return (
            float(score)
            + alpha * float(l1_error)
            + beta * float(nonzero_defect_count)
            + gamma * float(max_abs_error * max_abs_error)
        )
    if schedule == "soft_l1_nonzero":
        return (
            float(score)
            + alpha * float(l1_error)
            + beta * float(nonzero_defect_count)
            + gamma * float(max_abs_error)
        )
    if schedule in NOVELTY_OBJECTIVES:
        stats = cluster_distance_stats(counts, lam, config)
        novelty = float(stats.get("dist_l1_to_cluster0", 0))
        weight = float(getattr(config, "novelty_weight", 0.01))
        if schedule == "novelty_score_first":
            return float(score) - weight * novelty
        return (
            float(score)
            + alpha * float(l1_error)
            + beta * float(nonzero_defect_count)
            + gamma * float(max_abs_error * max_abs_error)
            - weight * novelty
        )
    if schedule in CAPPED_NOVELTY_OBJECTIVES:
        stats = cluster_distance_stats(counts, lam, config)
        cap_stats = novelty_cap_stats(metrics, config)
        novelty = float(stats.get("dist_l1_to_cluster0", 0))
        weight = float(getattr(config, "novelty_weight", 0.01))
        penalty = float(getattr(config, "cap_violation_penalty", 10000.0))
        violation = float(cap_stats["cap_violation_amount"])
        if schedule == "capped_novelty_score_first":
            if cap_stats["within_novelty_cap"]:
                return float(score) - weight * novelty
            return float(score) + penalty + violation
        base = (
            float(score)
            + alpha * float(l1_error)
            + beta * float(nonzero_defect_count)
            + gamma * float(max_abs_error * max_abs_error)
        )
        if cap_stats["within_novelty_cap"]:
            return base - weight * novelty
        return base + penalty + violation
    if schedule in BOUNDED_OBJECTIVES:
        if reference_score is None:
            reference_score = score
        threshold = int(reference_score) + int(score_slack)
        if score <= threshold:
            if schedule == "bounded_score_nonzero":
                return (
                    float(nonzero_defect_count) * 1000.0
                    + float(l1_error)
                    + float(max_abs_error) * 10.0
                    + float(score) / 10000.0
                )
            return (
                float(l1_error) * 1000.0
                + float(nonzero_defect_count)
                + float(max_abs_error) * 10.0
                + float(score) / 10000.0
            )
        return 1000000000.0 + float(score)
    if schedule not in OBJECTIVE_ORDERS:
        raise ValueError("unknown objective schedule: {}".format(schedule))
    return float(metrics[OBJECTIVE_ORDERS[schedule][0]])


def objective_tuple(metrics, config, reference_score=None, counts=None, lam=None):
    schedule, alpha, beta, gamma, score_slack = objective_config(config)
    score, l1_error, max_abs_error, nonzero_defect_count = metrics
    score = int(score)
    l1_error = int(l1_error)
    max_abs_error = int(max_abs_error)
    nonzero_defect_count = int(nonzero_defect_count)

    if schedule == "moment_score_cap":
        cap = int(getattr(config, "moment_score_cap", 220))
        if counts is None or lam is None:
            return (1, score, l1_error, max_abs_error, nonzero_defect_count)
        summary = p_adic_moment_summary(counts, lam, modulus=len(counts))
        if score <= cap:
            return (
                0,
                -int(summary["moment_zero_count"]),
                int(summary["moment_abs_sum"]),
                score,
                l1_error,
                max_abs_error,
                nonzero_defect_count,
            )
        return (1, score, l1_error, max_abs_error, nonzero_defect_count)
    if schedule == "moment_lock_score_cap":
        cap = int(getattr(config, "moment_score_cap", 260))
        if counts is None or lam is None:
            return (1, score, l1_error, max_abs_error, nonzero_defect_count)
        stats = moment_lock_target_stats(counts, lam, config)
        if score <= cap:
            return (
                0,
                int(stats.get("moment_lock_violation_count", 0)),
                int(stats.get("moment_target_abs_sum", 0)),
                -int(stats.get("moment_target_zero_count", 0)),
                int(stats.get("moment_lock_abs_sum", 0)),
                score,
                l1_error,
                max_abs_error,
                nonzero_defect_count,
            )
        return (1, score, l1_error, max_abs_error, nonzero_defect_count)
    if schedule in OBJECTIVE_ORDERS:
        return tuple(int(metrics[idx]) for idx in OBJECTIVE_ORDERS[schedule])
    if schedule in SOFT_OBJECTIVES:
        return (
            objective_value(metrics, config, reference_score, counts, lam),
            score,
            l1_error,
            max_abs_error,
            nonzero_defect_count,
        )
    if schedule in NOVELTY_OBJECTIVES:
        stats = cluster_distance_stats(counts, lam, config)
        distance = int(stats.get("dist_l1_to_cluster0", 0))
        return (
            objective_value(metrics, config, reference_score, counts, lam),
            score,
            l1_error,
            max_abs_error,
            nonzero_defect_count,
            -distance,
        )
    if schedule in CAPPED_NOVELTY_OBJECTIVES:
        stats = cluster_distance_stats(counts, lam, config)
        cap_stats = novelty_cap_stats(metrics, config)
        distance = int(stats.get("dist_l1_to_cluster0", 0))
        if schedule == "capped_novelty_score_first":
            if cap_stats["within_novelty_cap"]:
                return (
                    score,
                    l1_error,
                    max_abs_error,
                    -distance,
                    nonzero_defect_count,
                )
            return (
                score
                + int(getattr(config, "cap_violation_penalty", 10000))
                + int(cap_stats["cap_violation_amount"]),
                l1_error,
                max_abs_error,
                nonzero_defect_count,
                0,
            )
        return (
            objective_value(metrics, config, reference_score, counts, lam),
            0 if cap_stats["within_novelty_cap"] else 1,
            score,
            l1_error,
            max_abs_error,
            nonzero_defect_count,
            -distance,
        )
    if schedule in BOUNDED_OBJECTIVES:
        if reference_score is None:
            reference_score = score
        threshold = int(reference_score) + int(score_slack)
        if score <= threshold:
            if schedule == "bounded_score_nonzero":
                return (
                    0,
                    nonzero_defect_count,
                    l1_error,
                    max_abs_error,
                    score,
                )
            return (
                0,
                l1_error,
                nonzero_defect_count,
                max_abs_error,
                score,
            )
        return (1, score, l1_error, max_abs_error, nonzero_defect_count)
    raise ValueError("unknown objective schedule: {}".format(schedule))


def objective_json_list(values):
    return [json_number(value) for value in values]


def error_histogram(counts, lam):
    hist = {}
    for d in range(1, len(counts)):
        err = int(counts[d] - lam)
        hist[err] = hist.get(err, 0) + 1
    return {str(key): int(hist[key]) for key in sorted(hist)}


def top_error_shifts(counts, lam, limit=12):
    over = []
    under = []
    for d in range(1, len(counts)):
        err = int(counts[d] - lam)
        if err > 0:
            over.append((d, err))
        elif err < 0:
            under.append((d, err))
    over.sort(key=lambda item: (-item[1], item[0]))
    under.sort(key=lambda item: (item[1], item[0]))
    if limit is None:
        return over, under
    return over[:limit], under[:limit]


def is_better(
    candidate_metrics,
    best_metrics,
    config="score_first",
    reference_score=None,
    candidate_counts=None,
    best_counts=None,
    lam=None,
):
    if best_metrics is None:
        return True
    return objective_tuple(
        candidate_metrics, config, reference_score, candidate_counts, lam
    ) < objective_tuple(
        best_metrics, config, reference_score, best_counts, lam
    )


def verify_sds(v, blocks, lam):
    counts = total_diff_counts(v, blocks)
    bad = []
    for d in range(1, v):
        if counts[d] != lam:
            bad.append((d, counts[d]))
    return len(bad) == 0, bad


def block_to_pm1_circulant(v, block):
    first_row = [-1 if i in block else 1 for i in range(v)]
    return matrix(ZZ, v, v, lambda i, j: first_row[(j - i) % v])


def back_identity(v):
    return matrix(ZZ, v, v, lambda i, j: 1 if i + j == v - 1 else 0)


def goethals_seidel_matrix(v, blocks):
    A, B, C, D = [block_to_pm1_circulant(v, block) for block in blocks]
    R = back_identity(v)
    return block_matrix(
        ZZ,
        [
            [A, B * R, C * R, D * R],
            [-B * R, A, -D.transpose() * R, C.transpose() * R],
            [-C * R, D.transpose() * R, A, -B.transpose() * R],
            [-D * R, -C.transpose() * R, B.transpose() * R, A],
        ],
        subdivide=False,
    )


def verify_hadamard_exact(v, blocks):
    H = goethals_seidel_matrix(v, blocks)
    n = 4 * v
    entries_ok = all(x in (-1, 1) for x in H.list())
    hh_t = H * H.transpose() == n * identity_matrix(ZZ, n)
    return bool(entries_ok), bool(hh_t)


def propose_random_move(v, blocks, movable_blocks):
    block_idx = random.choice(movable_blocks)
    block = blocks[block_idx]
    removed = random.choice(tuple(block))
    added = random.randrange(v)
    while added in block:
        added = random.randrange(v)
    return block_idx, removed, added


def weighted_shift(shifts):
    if not shifts:
        return None
    weights = [abs(err) for _, err in shifts]
    total = sum(weights)
    pick = random.uniform(0, total)
    acc = 0.0
    for (shift, err), weight in zip(shifts, weights):
        acc += weight
        if pick <= acc:
            return shift
    return shifts[-1][0]


def propose_error_guided_candidate(v, blocks, counts, lam, movable_blocks):
    over, under = top_error_shifts(counts, lam, limit=None)
    if not over or not under:
        return propose_random_move(v, blocks, movable_blocks)

    block_idx = random.choice(movable_blocks)
    block = blocks[block_idx]
    block_list = tuple(block)

    removed = None
    for _ in range(20):
        shift = weighted_shift(over)
        if shift is None:
            break
        x = random.choice(block_list)
        y = (x - shift) % v
        if y in block:
            removed = random.choice((x, y))
            break
    if removed is None:
        removed = random.choice(block_list)

    remaining = set(block)
    remaining.remove(removed)

    added = None
    for _ in range(40):
        shift = weighted_shift(under)
        if shift is None or not remaining:
            break
        y = random.choice(tuple(remaining))
        candidate = random.choice(((y + shift) % v, (y - shift) % v))
        if candidate not in remaining and candidate != removed:
            added = candidate
            break
    if added is None:
        added = random.randrange(v)
        while added in remaining or added == removed:
            added = random.randrange(v)

    return block_idx, removed, added


def propose_targeted_move(
    v, blocks, counts, lam, movable_blocks, attempts, args, reference_score
):
    best = None
    for _ in range(max(1, int(attempts))):
        block_idx, removed, added = propose_error_guided_candidate(
            v, blocks, counts, lam, movable_blocks
        )
        delta = delta_swap(v, blocks[block_idx], removed, added)
        new_counts = [counts[d] + delta[d] for d in range(v)]
        new_metrics = metrics_from_counts(new_counts, lam)
        item = (new_metrics, block_idx, removed, added, delta, new_counts)
        if best is None or objective_tuple(
            item[0], args, reference_score, item[5], lam
        ) < objective_tuple(best[0], args, reference_score, best[5], lam):
            best = item
    return best


def shake_blocks(v, blocks, movable_blocks, shake_rate):
    total_size = sum(len(block) for block in blocks)
    moves = max(1, int(round(total_size * float(shake_rate))))
    for _ in range(moves):
        block_idx, removed, added = propose_random_move(v, blocks, movable_blocks)
        blocks[block_idx].remove(removed)
        blocks[block_idx].add(added)
    return moves


def json_blocks(blocks):
    return [[int(x) for x in sorted(list(block))] for block in blocks]


def ensure_unique_path(path):
    if not os.path.exists(path):
        return path
    root, ext = os.path.splitext(path)
    idx = 1
    while True:
        candidate = "{}_{}{}".format(root, idx, ext)
        if not os.path.exists(candidate):
            return candidate
        idx += 1


def write_json(path, payload):
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)


def parse_bucket_list(value):
    return [item.strip() for item in value.split(",") if item.strip()]


BUCKET_KEYS = {
    "objective": (),
    "novelty": (),
    "cluster_distance": (),
    "moment": (),
    "moment_then_score": (),
    "score": ("score", "l1_error", "max_abs_error", "nonzero_defect_count"),
    "l1": ("l1_error", "score", "max_abs_error", "nonzero_defect_count"),
    "nonzero": ("nonzero_defect_count", "l1_error", "score", "max_abs_error"),
    "max_abs": ("max_abs_error", "score", "l1_error", "nonzero_defect_count"),
    "lex_score_l1": ("score", "l1_error", "max_abs_error", "nonzero_defect_count"),
    "lex_nonzero_l1": ("nonzero_defect_count", "l1_error", "score", "max_abs_error"),
    "lex_l1_score": ("l1_error", "score", "max_abs_error", "nonzero_defect_count"),
    "lex_maxabs_l1": ("max_abs_error", "l1_error", "score", "nonzero_defect_count"),
}


def bucket_metric_tuple(payload, bucket):
    objective = tuple(payload.get("objective_tuple", []))
    if bucket == "objective":
        return objective + (
            int(payload["score"]),
            int(payload["l1_error"]),
            int(payload["max_abs_error"]),
            int(payload["nonzero_defect_count"]),
        )
    if bucket == "novelty":
        return (
            0 if bool(payload.get("within_novelty_cap", False)) else 1,
            -int(payload.get("novelty_score", 0)),
            int(payload.get("cap_violation_amount", 0)),
            int(payload["score"]),
            int(payload["l1_error"]),
            int(payload["max_abs_error"]),
            int(payload["nonzero_defect_count"]),
        ) + objective
    if bucket == "cluster_distance":
        return (
            0 if bool(payload.get("within_novelty_cap", False)) else 1,
            -int(payload.get("nearest_cluster_distance", 0)),
            int(payload.get("cap_violation_amount", 0)),
            int(payload["score"]),
            int(payload["l1_error"]),
            int(payload["max_abs_error"]),
            int(payload["nonzero_defect_count"]),
        ) + objective
    if bucket in ("moment", "moment_then_score"):
        return (
            -int(payload.get("moment_zero_count", 0)),
            int(payload.get("moment_abs_sum", 0)),
            int(payload["score"]),
            int(payload["l1_error"]),
            int(payload["max_abs_error"]),
            int(payload["nonzero_defect_count"]),
        ) + objective
    return tuple(int(payload[key]) for key in BUCKET_KEYS[bucket]) + objective


class BucketedCanonicalFrontier(object):
    def __init__(self, path, buckets, top_k):
        self.path = path
        self.buckets = list(buckets)
        self.top_k = int(top_k)
        self.data = {
            "timestamp": timestamp(),
            "description": "Canonical near-hit frontier for guided SDS search. Diagnostic only; not a success certificate.",
            "buckets": {bucket: [] for bucket in self.buckets},
        }
        if path and os.path.exists(path):
            with open(path) as f:
                loaded = json.load(f)
            self.data["buckets"].update(loaded.get("buckets", {}))
            self.data["description"] = loaded.get("description", self.data["description"])
        for bucket in self.buckets:
            self.data["buckets"].setdefault(bucket, [])

    def update(self, payload, path):
        if not self.path:
            return []
        updates = []
        record = {
            "canonical_hash": payload.get("canonical_hash", ""),
            "canonical_repr_summary": payload.get("canonical_repr_summary", {}),
            "path": path,
            "v": int(payload["v"]),
            "n": int(payload["n"]),
            "ks": [int(k) for k in payload["ks"]],
            "lambda": int(payload["lambda"]),
            "score": int(payload["score"]),
            "l1_error": int(payload["l1_error"]),
            "max_abs_error": int(payload["max_abs_error"]),
            "nonzero_defect_count": int(payload["nonzero_defect_count"]),
            "objective_schedule": payload.get("objective_schedule", "score_first"),
            "objective_value": payload.get("objective_value", 0),
            "objective_tuple": payload.get("objective_tuple", []),
            "cluster_aware": bool(payload.get("cluster_aware", False)),
            "nearest_cluster_id": payload.get("nearest_cluster_id"),
            "nearest_cluster_distance": payload.get("nearest_cluster_distance"),
            "dist_l1_to_cluster0": payload.get("dist_l1_to_cluster0"),
            "support_symdiff_to_cluster0": payload.get("support_symdiff_to_cluster0"),
            "novelty_score": int(payload.get("novelty_score", 0)),
            "novelty_score_cap": int(payload.get("novelty_score_cap", 240)),
            "novelty_l1_cap": int(payload.get("novelty_l1_cap", 140)),
            "novelty_maxabs_cap": int(payload.get("novelty_maxabs_cap", 3)),
            "within_novelty_cap": bool(payload.get("within_novelty_cap", False)),
            "cap_violation_amount": int(payload.get("cap_violation_amount", 0)),
            "p_adic_moments": payload.get("p_adic_moments", {}),
            "moment_signature": payload.get("moment_signature", ""),
            "moment_zero_count": int(payload.get("moment_zero_count", 0)),
            "moment_abs_sum": int(payload.get("moment_abs_sum", 0)),
            "moment_all_zero": bool(payload.get("moment_all_zero", False)),
            "p_adic_moment_lock": payload.get("p_adic_moment_lock", {}),
            "moment_lock_violation_count": int(
                payload.get("moment_lock_violation_count", 0)
            ),
            "moment_lock_abs_sum": int(payload.get("moment_lock_abs_sum", 0)),
            "moment_lock_all_zero": bool(payload.get("moment_lock_all_zero", True)),
            "moment_target_zero_count": int(
                payload.get("moment_target_zero_count", 0)
            ),
            "moment_target_abs_sum": int(payload.get("moment_target_abs_sum", 0)),
            "moment_target_all_zero": bool(
                payload.get("moment_target_all_zero", True)
            ),
            "soft_alpha": float(payload.get("soft_alpha", 0.1)),
            "soft_beta": float(payload.get("soft_beta", 0.5)),
            "soft_gamma": float(payload.get("soft_gamma", 2.0)),
            "score_slack": int(payload.get("score_slack", 60)),
            "seed": int(payload.get("seed", -1)),
            "step": int(payload.get("step", -1)),
            "verify_sds": bool(payload.get("verify_sds", False)),
            "generated_hadamard": bool(payload.get("generated_hadamard", False)),
            "hh_t": bool(payload.get("hh_t", False)),
            "timestamp": timestamp(),
        }
        for bucket in self.buckets:
            items = list(self.data["buckets"].get(bucket, []))
            replaced = False
            for idx, old in enumerate(items):
                if old.get("canonical_hash") != record["canonical_hash"]:
                    continue
                if bucket_metric_tuple(record, bucket) < bucket_metric_tuple(old, bucket):
                    items[idx] = dict(record)
                    updates.append({"bucket": bucket, "action": "replace"})
                replaced = True
                break
            if not replaced:
                items.append(dict(record))
                updates.append({"bucket": bucket, "action": "add"})
            items.sort(key=lambda item: bucket_metric_tuple(item, bucket))
            self.data["buckets"][bucket] = items[: self.top_k]
        self.data["timestamp"] = timestamp()
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        write_json(self.path, self.data)
        return updates


def base_payload(
    v,
    ks,
    lam,
    blocks,
    metrics,
    seed,
    step,
    restart_count,
    resume_json,
    args,
    plateau_escape_count,
    counts,
    reference_score=None,
):
    score, l1_error, max_abs_error, nonzero_defect_count = metrics
    payload = {
        "v": int(v),
        "n": int(4 * v),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": json_blocks(blocks),
        "score": int(score),
        "l1_error": int(l1_error),
        "max_abs_error": int(max_abs_error),
        "nonzero_defect_count": int(nonzero_defect_count),
        "seed": int(seed),
        "step": int(step),
        "restart_count": int(restart_count),
        "plateau_escape_count": int(plateau_escape_count),
        "objective_schedule": args.objective_schedule,
        "objective_value": json_number(
            objective_value(metrics, args, reference_score, counts, lam)
        ),
        "objective_tuple": objective_json_list(
            objective_tuple(metrics, args, reference_score, counts, lam)
        ),
        "soft_alpha": float(args.soft_alpha),
        "soft_beta": float(args.soft_beta),
        "soft_gamma": float(args.soft_gamma),
        "score_slack": int(args.score_slack),
        "moment_score_cap": int(getattr(args, "moment_score_cap", 220)),
        "moment_weight": float(getattr(args, "moment_weight", 1000.0)),
        "moment_lock_powers": getattr(args, "moment_lock_powers", ""),
        "moment_target_powers": getattr(args, "moment_target_powers", ""),
        "moment_lock_penalty": float(getattr(args, "moment_lock_penalty", 500.0)),
        "moment_target_weight": float(getattr(args, "moment_target_weight", 1.0)),
        "novelty_weight": float(getattr(args, "novelty_weight", 0.01)),
        "cap_violation_penalty": float(
            getattr(args, "cap_violation_penalty", 10000.0)
        ),
        "min_cluster_distance": int(getattr(args, "min_cluster_distance", 0)),
        "avoid_cluster_id": int(getattr(args, "avoid_cluster_id", 0)),
        "cluster_medoids_json": getattr(args, "cluster_medoids_json", ""),
        "objective_reference_score": (
            int(reference_score) if reference_score is not None else int(score)
        ),
        "strategy": args.strategy,
        "targeted_prob": float(args.targeted_prob),
        "shake_rate": float(args.shake_rate),
        "verify_sds": False,
        "generated_hadamard": False,
        "hh_t": False,
        "construction": "Goethals-Seidel",
        "search_method": "guided_swap_local_search",
        "timestamp": timestamp(),
    }
    payload.update(cluster_distance_stats(counts, lam, args))
    payload.update(novelty_cap_stats(metrics, args))
    if not payload.get("cluster_aware"):
        payload["cluster_aware"] = bool(getattr(args, "cluster_aware", False))
    if counts is not None:
        payload["error_histogram"] = error_histogram(counts, lam)
        moment_summary = p_adic_moment_summary(counts, lam, modulus=v)
        payload["p_adic_moments"] = moment_summary
        payload["moment_signature"] = moment_summary["moment_signature"]
        payload["moment_zero_count"] = int(moment_summary["moment_zero_count"])
        payload["moment_abs_sum"] = int(moment_summary["moment_abs_sum"])
        payload["moment_all_zero"] = bool(moment_summary["moment_all_zero"])
        lock_target = moment_lock_target_stats(counts, lam, args)
        payload["p_adic_moment_lock"] = lock_target
        payload["moment_lock_violation_count"] = int(
            lock_target.get("moment_lock_violation_count", 0)
        )
        payload["moment_lock_abs_sum"] = int(lock_target.get("moment_lock_abs_sum", 0))
        payload["moment_lock_all_zero"] = bool(
            lock_target.get("moment_lock_all_zero", True)
        )
        payload["moment_target_zero_count"] = int(
            lock_target.get("moment_target_zero_count", 0)
        )
        payload["moment_target_abs_sum"] = int(
            lock_target.get("moment_target_abs_sum", 0)
        )
        payload["moment_target_all_zero"] = bool(
            lock_target.get("moment_target_all_zero", True)
        )
    payload["canonical_hash"] = canonical_hash(blocks, ks, v)
    if getattr(args, "canonical_dedup", False):
        payload["canonical_repr_summary"] = canonical_repr_summary(blocks, ks, v)
    if resume_json is not None:
        payload["resume_json"] = resume_json
    return payload


def save_near_hit(
    outdir,
    v,
    ks,
    lam,
    blocks,
    metrics,
    seed,
    step,
    restart_count,
    resume_json,
    args,
    plateau_escape_count,
    counts,
    reference_score=None,
    canonical_frontier=None,
):
    os.makedirs(outdir, exist_ok=True)
    score, l1_error, max_abs_error, nonzero_defect_count = metrics
    payload = base_payload(
        v,
        ks,
        lam,
        blocks,
        metrics,
        seed,
        step,
        restart_count,
        resume_json,
        args,
        plateau_escape_count,
        counts,
        reference_score,
    )
    name = "near_hit_v{}_score{}_seed{}_step{}.json".format(
        v, score, seed, step
    )
    path = ensure_unique_path(os.path.join(outdir, name))
    write_json(path, payload)
    bucket_updates = []
    if canonical_frontier is not None:
        bucket_updates = canonical_frontier.update(payload, path)
        payload["canonical_frontier_updates"] = bucket_updates
        write_json(path, payload)
    print(
        "NEAR_HIT saved path={} score={} l1_error={} max_abs_error={} "
        "nonzero_defect_count={} within_novelty_cap={} "
        "cap_violation_amount={}".format(
            path,
            score,
            l1_error,
            max_abs_error,
            nonzero_defect_count,
            payload.get("within_novelty_cap", False),
            payload.get("cap_violation_amount", 0),
        )
    )
    if payload.get("canonical_hash"):
        print("NEAR_HIT canonical_hash={}".format(payload["canonical_hash"]))
    if bucket_updates:
        print("NEAR_HIT bucket_updates={}".format(bucket_updates))
    print("NEAR_HIT error_histogram={}".format(payload.get("error_histogram", {})))
    return path, payload.get("canonical_hash", "")


def save_success(
    outdir,
    v,
    ks,
    lam,
    blocks,
    metrics,
    seed,
    step,
    restart_count,
    resume_json,
    args,
    plateau_escape_count,
    counts,
    reference_score=None,
    canonical_frontier=None,
):
    os.makedirs(outdir, exist_ok=True)
    payload = base_payload(
        v,
        ks,
        lam,
        blocks,
        metrics,
        seed,
        step,
        restart_count,
        resume_json,
        args,
        plateau_escape_count,
        counts,
        reference_score,
    )

    sds_ok, bad = verify_sds(v, blocks, lam)
    payload["verify_sds"] = bool(sds_ok)
    if not sds_ok:
        payload["sds_failure_first_bad_shifts"] = [
            [int(d), int(count)] for d, count in bad[:30]
        ]
        path = ensure_unique_path(
            os.path.join(
                "outputs/candidates/near_hits",
                "near_hit_v{}_score0_seed{}_step{}.json".format(v, seed, step),
            )
        )
        write_json(path, payload)
        raise RuntimeError(
            "score 0 candidate failed explicit SDS verification; saved {}".format(
                path
            )
        )

    entries_ok, hh_t = verify_hadamard_exact(v, blocks)
    payload["generated_hadamard"] = bool(entries_ok)
    payload["hh_t"] = bool(hh_t)
    if not entries_ok or not hh_t:
        path = ensure_unique_path(
            os.path.join(
                "outputs/candidates/near_hits",
                "near_hit_v{}_score0_seed{}_step{}.json".format(v, seed, step),
            )
        )
        write_json(path, payload)
        raise RuntimeError(
            "score 0 SDS failed Goethals-Seidel Hadamard verification; saved {}".format(
                path
            )
        )

    name = "candidate_sds_v{}_n{}_seed{}_step{}.json".format(
        v, 4 * v, seed, step
    )
    path = ensure_unique_path(os.path.join(outdir, name))
    if canonical_frontier is not None:
        payload["canonical_frontier_updates"] = canonical_frontier.update(payload, path)
    write_json(path, payload)
    print("SUCCESS saved:", path)
    return path


def temperature_at(args, step):
    if args.anneal == "none":
        return float(args.temperature)
    progress = 0.0
    if args.steps > 0:
        progress = min(1.0, float(step) / float(args.steps))
    return max(float(args.min_temperature), float(args.temperature) * (1.0 - progress))


def active_strategy(args, step):
    if args.strategy != "mixed":
        return args.strategy
    phase = (int(step) // max(1, int(args.mixed_period))) % 2
    return "greedy" if phase == 0 else "anneal"


def accept_move(
    cur_metrics,
    new_metrics,
    temp,
    strategy,
    args,
    reference_score,
    cur_counts=None,
    new_counts=None,
    lam=None,
):
    cur_objective = objective_tuple(cur_metrics, args, reference_score, cur_counts, lam)
    new_objective = objective_tuple(new_metrics, args, reference_score, new_counts, lam)
    if strategy == "greedy":
        return new_objective < cur_objective

    if new_objective <= cur_objective:
        return True
    if temp <= 0:
        return False
    cur_value = objective_value(cur_metrics, args, reference_score, cur_counts, lam)
    new_value = objective_value(new_metrics, args, reference_score, new_counts, lam)
    exponent = float(cur_value - new_value) / float(temp)
    if exponent > 700:
        return True
    if exponent < -700:
        return False
    return random.random() < math.exp(exponent)


def write_progress(csv_writer, row):
    csv_writer.writerow(row)


def print_progress(row):
    print(
        "step={step} score={score} l1_error={l1_error} "
        "max_abs_error={max_abs_error} nonzero_defect_count={nonzero_defect_count} "
        "best_score={best_score} "
        "best_l1_error={best_l1_error} best_max_abs_error={best_max_abs_error} "
        "best_nonzero_defect_count={best_nonzero_defect_count} "
        "seed={seed} strategy={strategy} active_strategy={active_strategy} "
        "objective_schedule={objective_schedule} objective_value={objective_value} "
        "objective_tuple={objective_tuple} "
        "nearest_cluster_id={nearest_cluster_id} "
        "cluster_distance={nearest_cluster_distance} "
        "dist_l1_to_cluster0={dist_l1_to_cluster0} "
        "novelty_score={novelty_score} "
        "moment_signature={moment_signature} "
        "moment_zero_count={moment_zero_count} "
        "moment_lock_violation_count={moment_lock_violation_count} "
        "moment_target_zero_count={moment_target_zero_count} "
        "within_novelty_cap={within_novelty_cap} "
        "cap_violation_amount={cap_violation_amount} "
        "targeted_prob={targeted_prob} plateau_escape_count={plateau_escape_count} "
        "last_improvement_step={last_improvement_step} "
        "last_progress_step={last_progress_step} "
        "current_temperature={current_temperature:.4f} restart_count={restart_count} "
        "elapsed_sec={elapsed_sec:.2f}".format(
            **row
        )
    )


def search_one(v, ks, lam, seed, args, csv_writer, canonical_frontier=None):
    random.seed(int(seed))

    near_hit_dir = args.near_hit_dir
    candidate_dir = args.candidate_dir

    if args.resume_json is not None:
        blocks, resume_data = load_resume_blocks(args.resume_json, v, ks, lam)
        print("Resume JSON:", args.resume_json)
        print(
            "Resume source score={} l1_error={} max_abs_error={} step={}".format(
                resume_data.get("score"),
                resume_data.get("l1_error"),
                resume_data.get("max_abs_error"),
                resume_data.get("step"),
            )
        )
    else:
        blocks = random_blocks(v, ks)
    counts = total_diff_counts(v, blocks)
    cur_metrics = metrics_from_counts(counts, lam)
    cur_score = cur_metrics[0]
    best_score_seen = int(cur_score)

    best_metrics = None
    best_blocks = None
    best_counts = None
    best_path = None
    best_canonical_hash = ""
    last_improvement_step = 0
    last_progress_step = 0
    restart_count = 0
    plateau_escape_count = 0
    start_time = time.time()
    found_path = ""

    movable_blocks = [idx for idx, k in enumerate(ks) if 0 < k < v]
    if not movable_blocks:
        raise ValueError("no block can be changed by one-point swap")

    print(
        "\nSearch target v={} n={} ks={} lambda={} seed={} steps={}".format(
            v, 4 * v, ks, lam, seed, args.steps
        )
    )

    if is_better(cur_metrics, best_metrics, args, best_score_seen, counts, best_counts, lam):
        best_metrics = cur_metrics
        best_blocks = [set(block) for block in blocks]
        best_counts = list(counts)
        best_path, best_canonical_hash = save_near_hit(
            near_hit_dir,
            v,
            ks,
            lam,
            best_blocks,
            best_metrics,
            seed,
            0,
            restart_count,
            args.resume_json,
            args,
            plateau_escape_count,
            counts,
            best_score_seen,
            canonical_frontier,
        )

    if cur_score == 0:
        print("FOUND score 0 at initialization; running exact verification")
        found_path = save_success(
            candidate_dir,
            v,
            ks,
            lam,
            blocks,
            cur_metrics,
            seed,
            0,
            restart_count,
            args.resume_json,
            args,
            plateau_escape_count,
            counts,
            best_score_seen,
            canonical_frontier,
        )
        row = progress_row(
            v,
            ks,
            lam,
            seed,
            0,
            args.steps,
            cur_metrics,
            best_metrics,
            restart_count,
            plateau_escape_count,
            args,
            active_strategy(args, 0),
            temperature_at(args, 0),
            start_time,
            True,
            found_path,
            last_improvement_step,
            last_progress_step,
            best_canonical_hash,
            best_score_seen,
            counts,
            best_counts,
        )
        write_progress(csv_writer, row)
        print_progress(row)
        return {
            "found": True,
            "path": found_path,
            "best_metrics": cur_metrics,
            "best_path": found_path,
        }

    for step in range(1, args.steps + 1):
        use_targeted = random.random() < float(args.targeted_prob)
        if use_targeted:
            targeted = propose_targeted_move(
                v,
                blocks,
                counts,
                lam,
                movable_blocks,
                args.targeted_attempts,
                args,
                best_score_seen,
            )
            new_metrics, block_idx, removed, added, delta, new_counts = targeted
        else:
            block_idx, removed, added = propose_random_move(v, blocks, movable_blocks)
            delta = delta_swap(v, blocks[block_idx], removed, added)
            new_counts = [counts[d] + delta[d] for d in range(v)]
            new_metrics = metrics_from_counts(new_counts, lam)

        new_score = new_metrics[0]
        temp = temperature_at(args, step)
        strategy = active_strategy(args, step)

        if accept_move(
            cur_metrics,
            new_metrics,
            temp,
            strategy,
            args,
            best_score_seen,
            counts,
            new_counts,
            lam,
        ):
            blocks[block_idx].remove(removed)
            blocks[block_idx].add(added)
            counts = new_counts
            cur_metrics = new_metrics
            cur_score = new_score
            if int(cur_score) < best_score_seen:
                best_score_seen = int(cur_score)

            if is_better(
                cur_metrics,
                best_metrics,
                args,
                best_score_seen,
                counts,
                best_counts,
                lam,
            ):
                best_metrics = cur_metrics
                best_blocks = [set(block) for block in blocks]
                best_counts = list(counts)
                last_improvement_step = step
                last_progress_step = step
                best_path, best_canonical_hash = save_near_hit(
                    near_hit_dir,
                    v,
                    ks,
                    lam,
                    best_blocks,
                    best_metrics,
                    seed,
                    step,
                    restart_count,
                    args.resume_json,
                    args,
                    plateau_escape_count,
                    counts,
                    best_score_seen,
                    canonical_frontier,
                )

        if cur_score == 0:
            print("FOUND score 0 at step {}; running exact verification".format(step))
            found_path = save_success(
                candidate_dir,
                v,
                ks,
                lam,
                blocks,
                cur_metrics,
                seed,
                step,
                restart_count,
                args.resume_json,
                args,
                plateau_escape_count,
                counts,
                best_score_seen,
                canonical_frontier,
            )
            row = progress_row(
                v,
                ks,
                lam,
                seed,
                step,
                args.steps,
                cur_metrics,
                best_metrics,
                restart_count,
                plateau_escape_count,
                args,
                strategy,
                temp,
                start_time,
                True,
                found_path,
                last_improvement_step,
                last_progress_step,
                best_canonical_hash,
                best_score_seen,
                counts,
                best_counts,
            )
            write_progress(csv_writer, row)
            print_progress(row)
            return {
                "found": True,
                "path": found_path,
                "best_metrics": cur_metrics,
                "best_path": found_path,
            }

        if args.log_interval > 0 and step % args.log_interval == 0:
            row = progress_row(
                v,
                ks,
                lam,
                seed,
                step,
                args.steps,
                cur_metrics,
                best_metrics,
                restart_count,
                plateau_escape_count,
                args,
                strategy,
                temp,
                start_time,
                False,
                best_path or "",
                last_improvement_step,
                last_progress_step,
                best_canonical_hash,
                best_score_seen,
                counts,
                best_counts,
            )
            write_progress(csv_writer, row)
            print_progress(row)

        stagnant = step - last_progress_step
        if (
            args.restart_patience > 0
            and stagnant >= args.restart_patience
            and (
                (
                    args.plateau_escape
                    and plateau_escape_count < args.max_plateau_escapes
                )
                or restart_count < args.max_restarts
            )
        ):
            if args.plateau_escape and plateau_escape_count < args.max_plateau_escapes:
                plateau_escape_count += 1
                moves = shake_blocks(v, blocks, movable_blocks, args.shake_rate)
                counts = total_diff_counts(v, blocks)
                cur_metrics = metrics_from_counts(counts, lam)
                cur_score = cur_metrics[0]
                if int(cur_score) < best_score_seen:
                    best_score_seen = int(cur_score)
                last_progress_step = step
                print(
                    "PLATEAU_ESCAPE seed={} plateau_escape_count={} step={} "
                    "stagnant_steps={} shake_moves={}".format(
                        seed, plateau_escape_count, step, stagnant, moves
                    )
                )
            else:
                restart_count += 1
                print(
                    "RESTART seed={} restart_count={} step={} stagnant_steps={}".format(
                        seed, restart_count, step, stagnant
                    )
                )
                blocks = random_blocks(v, ks)
                counts = total_diff_counts(v, blocks)
                cur_metrics = metrics_from_counts(counts, lam)
                cur_score = cur_metrics[0]
                if int(cur_score) < best_score_seen:
                    best_score_seen = int(cur_score)
                last_progress_step = step
            if is_better(
                cur_metrics,
                best_metrics,
                args,
                best_score_seen,
                counts,
                best_counts,
                lam,
            ):
                best_metrics = cur_metrics
                best_blocks = [set(block) for block in blocks]
                best_counts = list(counts)
                last_improvement_step = step
                last_progress_step = step
                best_path, best_canonical_hash = save_near_hit(
                    near_hit_dir,
                    v,
                    ks,
                    lam,
                    best_blocks,
                    best_metrics,
                    seed,
                    step,
                    restart_count,
                    args.resume_json,
                    args,
                    plateau_escape_count,
                    counts,
                    best_score_seen,
                    canonical_frontier,
                )
            if cur_score == 0:
                print(
                    "FOUND score 0 after escape/restart at step {}; running exact verification".format(
                        step
                    )
                )
                found_path = save_success(
                    candidate_dir,
                    v,
                    ks,
                    lam,
                    blocks,
                    cur_metrics,
                    seed,
                    step,
                    restart_count,
                    args.resume_json,
                    args,
                    plateau_escape_count,
                    counts,
                    best_score_seen,
                    canonical_frontier,
                )
                row = progress_row(
                    v,
                    ks,
                    lam,
                    seed,
                    step,
                    args.steps,
                    cur_metrics,
                    best_metrics,
                    restart_count,
                    plateau_escape_count,
                    args,
                    active_strategy(args, step),
                    temperature_at(args, step),
                    start_time,
                    True,
                    found_path,
                    last_improvement_step,
                    last_progress_step,
                    best_canonical_hash,
                    best_score_seen,
                    counts,
                    best_counts,
                )
                write_progress(csv_writer, row)
                print_progress(row)
                return {
                    "found": True,
                    "path": found_path,
                    "best_metrics": cur_metrics,
                    "best_path": found_path,
                }

    row = progress_row(
        v,
        ks,
        lam,
        seed,
        args.steps,
        args.steps,
        cur_metrics,
        best_metrics,
        restart_count,
        plateau_escape_count,
        args,
        active_strategy(args, args.steps),
        temperature_at(args, args.steps),
        start_time,
        False,
        best_path or "",
        last_improvement_step,
        last_progress_step,
        best_canonical_hash,
        best_score_seen,
        counts,
        best_counts,
    )
    write_progress(csv_writer, row)
    print_progress(row)
    print(
        "NOT FOUND seed={} best_score={} best_l1_error={} "
        "best_max_abs_error={} best_nonzero_defect_count={} best_path={}".format(
            seed,
            best_metrics[0],
            best_metrics[1],
            best_metrics[2],
            best_metrics[3],
            best_path,
        )
    )
    return {
        "found": False,
        "path": "",
        "best_metrics": best_metrics,
        "best_path": best_path,
    }


def progress_row(
    v,
    ks,
    lam,
    seed,
    step,
    total_steps,
    cur_metrics,
    best_metrics,
    restart_count,
    plateau_escape_count,
    args,
    active_strategy_name,
    current_temperature,
    start_time,
    found,
    path,
    last_improvement_step,
    last_progress_step,
    best_canonical_hash,
    best_score_seen,
    cur_counts,
    best_counts,
):
    score, l1_error, max_abs_error, nonzero_defect_count = cur_metrics
    (
        best_score,
        best_l1_error,
        best_max_abs_error,
        best_nonzero_defect_count,
    ) = best_metrics
    elapsed = time.time() - start_time
    cur_objective = objective_tuple(cur_metrics, args, best_score_seen, cur_counts, lam)
    best_objective = objective_tuple(best_metrics, args, best_score_seen, best_counts, lam)
    cur_objective_value = objective_value(cur_metrics, args, best_score_seen, cur_counts, lam)
    best_objective_value = objective_value(best_metrics, args, best_score_seen, best_counts, lam)
    cur_cluster = cluster_distance_stats(cur_counts, lam, args)
    best_cluster = cluster_distance_stats(best_counts, lam, args)
    cur_moment = p_adic_moment_summary(cur_counts, lam, modulus=v)
    best_moment = p_adic_moment_summary(best_counts, lam, modulus=v)
    cur_lock = moment_lock_target_stats(cur_counts, lam, args)
    best_lock = moment_lock_target_stats(best_counts, lam, args)
    return {
        "timestamp": timestamp(),
        "v": int(v),
        "n": int(4 * v),
        "ks": ",".join(str(int(k)) for k in ks),
        "lambda": int(lam),
        "seed": int(seed),
        "step": int(step),
        "steps": int(total_steps),
        "score": int(score),
        "l1_error": int(l1_error),
        "max_abs_error": int(max_abs_error),
        "nonzero_defect_count": int(nonzero_defect_count),
        "best_score": int(best_score),
        "best_l1_error": int(best_l1_error),
        "best_max_abs_error": int(best_max_abs_error),
        "best_nonzero_defect_count": int(best_nonzero_defect_count),
        "restart_count": int(restart_count),
        "plateau_escape_count": int(plateau_escape_count),
        "strategy": args.strategy,
        "active_strategy": active_strategy_name,
        "objective_schedule": args.objective_schedule,
        "objective_value": json_number(cur_objective_value),
        "best_objective_value": json_number(best_objective_value),
        "objective_tuple": json.dumps(objective_json_list(cur_objective)),
        "best_objective_tuple": json.dumps(objective_json_list(best_objective)),
        "last_improvement_step": int(last_improvement_step),
        "last_progress_step": int(last_progress_step),
        "objective_reference_score": int(best_score_seen),
        "soft_alpha": float(args.soft_alpha),
        "soft_beta": float(args.soft_beta),
        "soft_gamma": float(args.soft_gamma),
        "score_slack": int(args.score_slack),
        "moment_score_cap": int(getattr(args, "moment_score_cap", 220)),
        "moment_weight": float(getattr(args, "moment_weight", 1000.0)),
        "moment_lock_powers": getattr(args, "moment_lock_powers", ""),
        "moment_target_powers": getattr(args, "moment_target_powers", ""),
        "moment_lock_penalty": float(getattr(args, "moment_lock_penalty", 500.0)),
        "moment_target_weight": float(getattr(args, "moment_target_weight", 1.0)),
        "moment_signature": cur_moment["moment_signature"],
        "moment_zero_count": int(cur_moment["moment_zero_count"]),
        "moment_abs_sum": int(cur_moment["moment_abs_sum"]),
        "moment_all_zero": bool(cur_moment["moment_all_zero"]),
        "moment_lock_violation_count": int(
            cur_lock.get("moment_lock_violation_count", 0)
        ),
        "moment_lock_abs_sum": int(cur_lock.get("moment_lock_abs_sum", 0)),
        "moment_lock_all_zero": bool(cur_lock.get("moment_lock_all_zero", True)),
        "moment_target_zero_count": int(
            cur_lock.get("moment_target_zero_count", 0)
        ),
        "moment_target_abs_sum": int(cur_lock.get("moment_target_abs_sum", 0)),
        "moment_target_all_zero": bool(
            cur_lock.get("moment_target_all_zero", True)
        ),
        "best_moment_signature": best_moment["moment_signature"],
        "best_moment_zero_count": int(best_moment["moment_zero_count"]),
        "best_moment_abs_sum": int(best_moment["moment_abs_sum"]),
        "best_moment_all_zero": bool(best_moment["moment_all_zero"]),
        "best_moment_lock_violation_count": int(
            best_lock.get("moment_lock_violation_count", 0)
        ),
        "best_moment_lock_abs_sum": int(best_lock.get("moment_lock_abs_sum", 0)),
        "best_moment_lock_all_zero": bool(
            best_lock.get("moment_lock_all_zero", True)
        ),
        "best_moment_target_zero_count": int(
            best_lock.get("moment_target_zero_count", 0)
        ),
        "best_moment_target_abs_sum": int(
            best_lock.get("moment_target_abs_sum", 0)
        ),
        "best_moment_target_all_zero": bool(
            best_lock.get("moment_target_all_zero", True)
        ),
        "novelty_score_cap": int(getattr(args, "novelty_score_cap", 240)),
        "novelty_l1_cap": int(getattr(args, "novelty_l1_cap", 140)),
        "novelty_maxabs_cap": int(getattr(args, "novelty_maxabs_cap", 3)),
        "cap_violation_penalty": float(
            getattr(args, "cap_violation_penalty", 10000.0)
        ),
        "within_novelty_cap": bool(novelty_cap_stats(cur_metrics, args)["within_novelty_cap"]),
        "cap_violation_amount": int(
            novelty_cap_stats(cur_metrics, args)["cap_violation_amount"]
        ),
        "best_within_novelty_cap": bool(
            novelty_cap_stats(best_metrics, args)["within_novelty_cap"]
        ),
        "best_cap_violation_amount": int(
            novelty_cap_stats(best_metrics, args)["cap_violation_amount"]
        ),
        "targeted_prob": float(args.targeted_prob),
        "shake_rate": float(args.shake_rate),
        "current_temperature": float(current_temperature),
        "elapsed_sec": float(elapsed),
        "found": bool(found),
        "path": path,
        "canonical_hash": best_canonical_hash,
        "canonical_dedup": bool(getattr(args, "canonical_dedup", False)),
        "frontier_out": getattr(args, "frontier_out", ""),
        "cluster_aware": bool(getattr(args, "cluster_aware", False)),
        "nearest_cluster_id": cur_cluster.get("nearest_cluster_id", ""),
        "nearest_cluster_distance": cur_cluster.get("nearest_cluster_distance", ""),
        "dist_l1_to_cluster0": cur_cluster.get("dist_l1_to_cluster0", ""),
        "support_symdiff_to_cluster0": cur_cluster.get("support_symdiff_to_cluster0", ""),
        "novelty_score": cur_cluster.get("novelty_score", ""),
        "best_nearest_cluster_id": best_cluster.get("nearest_cluster_id", ""),
        "best_nearest_cluster_distance": best_cluster.get("nearest_cluster_distance", ""),
        "best_dist_l1_to_cluster0": best_cluster.get("dist_l1_to_cluster0", ""),
        "best_support_symdiff_to_cluster0": best_cluster.get("support_symdiff_to_cluster0", ""),
        "best_novelty_score": best_cluster.get("novelty_score", ""),
    }


def parse_args():
    parser = argparse.ArgumentParser(
        description="Guided swap local search for SDS candidates over Z_167."
    )
    parser.add_argument("--v", type=int, default=DEFAULT_V, help="Group order.")
    parser.add_argument(
        "--ks",
        type=parse_ks,
        default=None,
        help="Comma-separated block sizes. Default: 71,81,82,82.",
    )
    parser.add_argument(
        "--lam",
        type=int,
        default=None,
        help="SDS lambda. Default is sum(ks)-v.",
    )
    parser.add_argument("--steps", type=int, default=1000000, help="Steps per seed.")
    parser.add_argument("--seed", type=int, default=None, help="Single seed.")
    parser.add_argument("--seed-start", type=int, default=None, help="First seed.")
    parser.add_argument("--seed-end", type=int, default=None, help="Last seed.")
    parser.add_argument(
        "--params-json",
        default="outputs/params/sds_params_v167_n668.json",
        help="Parameter JSON produced by 01_sds_params.sage.",
    )
    parser.add_argument(
        "--all-params",
        action="store_true",
        help="Run all parameter candidates in --params-json.",
    )
    parser.add_argument(
        "--param-index",
        type=int,
        default=None,
        help="Run one 0-based parameter candidate from --params-json.",
    )
    parser.add_argument(
        "--temperature",
        type=float,
        default=1.0,
        help="Initial temperature for accepting worse moves.",
    )
    parser.add_argument(
        "--min-temperature",
        type=float,
        default=0.01,
        help="Minimum annealing temperature.",
    )
    parser.add_argument(
        "--anneal",
        choices=["linear", "none"],
        default="linear",
        help="Temperature schedule.",
    )
    parser.add_argument(
        "--strategy",
        choices=["baseline", "anneal", "greedy", "mixed"],
        default="baseline",
        help="Move acceptance strategy. baseline preserves previous behavior.",
    )
    parser.add_argument(
        "--objective-schedule",
        choices=sorted(OBJECTIVE_SCHEDULES),
        default="score_first",
        help=(
            "Metric priority or soft/bounded objective used for move acceptance, "
            "targeted proposal ranking, and best near-hit updates."
        ),
    )
    parser.add_argument(
        "--soft-alpha",
        type=float,
        default=0.1,
        help="l1_error weight for soft objective schedules.",
    )
    parser.add_argument(
        "--soft-beta",
        type=float,
        default=0.5,
        help="nonzero_defect_count weight for soft objective schedules.",
    )
    parser.add_argument(
        "--soft-gamma",
        type=float,
        default=2.0,
        help="max_abs_error weight for soft objective schedules.",
    )
    parser.add_argument(
        "--score-slack",
        type=int,
        default=60,
        help="Allowed score slack above the best score seen for bounded schedules.",
    )
    parser.add_argument(
        "--moment-score-cap",
        type=int,
        default=220,
        help="Score cap used by moment_score_cap objective.",
    )
    parser.add_argument(
        "--moment-weight",
        type=float,
        default=1000.0,
        help="Reward weight for each zero p-adic moment in moment_score_cap.",
    )
    parser.add_argument(
        "--moment-lock-powers",
        default="",
        help="Comma-separated moment powers that should remain zero, e.g. 2.",
    )
    parser.add_argument(
        "--moment-target-powers",
        default="",
        help="Comma-separated moment powers to improve after locks, e.g. 4,6.",
    )
    parser.add_argument(
        "--moment-lock-penalty",
        type=float,
        default=500.0,
        help="Soft penalty for each nonzero locked p-adic moment.",
    )
    parser.add_argument(
        "--moment-target-weight",
        type=float,
        default=1.0,
        help="Weight on target moment balanced absolute residue in moment_lock_score_cap.",
    )
    parser.add_argument(
        "--cluster-aware",
        action="store_true",
        help="Enable defect-cluster novelty diagnostics and novelty objectives.",
    )
    parser.add_argument(
        "--cluster-medoids-json",
        default="",
        help="defect_cluster_analysis.json generated by 20_defect_vector_analysis.py.",
    )
    parser.add_argument(
        "--avoid-cluster-id",
        type=int,
        default=0,
        help="Cluster id used as the novelty avoidance reference.",
    )
    parser.add_argument(
        "--novelty-weight",
        type=float,
        default=0.01,
        help="Weight multiplying distance from the avoided cluster in novelty objectives.",
    )
    parser.add_argument(
        "--novelty-score-cap",
        type=int,
        default=240,
        help="Score cap for capped novelty objectives and capped novelty buckets.",
    )
    parser.add_argument(
        "--novelty-l1-cap",
        type=int,
        default=140,
        help="l1_error cap for capped novelty objectives and capped novelty buckets.",
    )
    parser.add_argument(
        "--novelty-maxabs-cap",
        type=int,
        default=3,
        help="max_abs_error cap for capped novelty objectives and capped novelty buckets.",
    )
    parser.add_argument(
        "--cap-violation-penalty",
        type=float,
        default=10000.0,
        help="Penalty added when a capped novelty candidate violates score/l1/max_abs caps.",
    )
    parser.add_argument(
        "--min-cluster-distance",
        type=int,
        default=0,
        help="Diagnostic threshold for retained cluster distance. Does not filter success checks.",
    )
    parser.add_argument(
        "--mixed-period",
        type=int,
        default=1000,
        help="Steps per phase for --strategy mixed.",
    )
    parser.add_argument(
        "--targeted-prob",
        type=float,
        default=0.0,
        help="Probability of proposing an error-vector guided swap.",
    )
    parser.add_argument(
        "--targeted-attempts",
        type=int,
        default=12,
        help="Candidate attempts per targeted swap proposal.",
    )
    parser.add_argument(
        "--plateau-escape",
        action="store_true",
        help="Shake part of the current state instead of full restart on plateaus.",
    )
    parser.add_argument(
        "--shake-rate",
        type=float,
        default=0.03,
        help="Fraction of block elements to perturb during plateau escape.",
    )
    parser.add_argument(
        "--max-plateau-escapes",
        type=int,
        default=100,
        help="Maximum plateau escapes per seed before falling back to restarts.",
    )
    parser.add_argument(
        "--restart-patience",
        "--plateau-restart-patience",
        dest="restart_patience",
        type=int,
        default=50000,
        help=(
            "Restart or plateau-escape after this many steps without objective "
            "improvement."
        ),
    )
    parser.add_argument(
        "--max-restarts",
        type=int,
        default=100,
        help="Maximum restarts per seed and parameter set.",
    )
    parser.add_argument(
        "--log-interval",
        type=int,
        default=5000,
        help="Progress log interval in steps.",
    )
    parser.add_argument(
        "--near-hit-dir",
        default="outputs/candidates/near_hits",
        help="Directory for near-hit JSON files.",
    )
    parser.add_argument(
        "--candidate-dir",
        default="outputs/candidates",
        help="Directory for fully verified success candidates.",
    )
    parser.add_argument(
        "--continue-after-found",
        action="store_true",
        help="Continue remaining runs after a verified success candidate.",
    )
    parser.add_argument(
        "--resume-json",
        default=None,
        help="Resume from a saved candidate or near-hit JSON.",
    )
    parser.add_argument(
        "--canonical-dedup",
        action="store_true",
        help="Attach canonical hashes to saved near-hits and update a bucketed canonical frontier.",
    )
    parser.add_argument(
        "--save-top-k-per-bucket",
        type=int,
        default=50,
        help="Number of canonical classes retained in each bucket.",
    )
    parser.add_argument(
        "--frontier-out",
        default="",
        help="Bucketed canonical frontier JSON output path.",
    )
    parser.add_argument(
        "--bucket",
        default="score,l1,nonzero,max_abs,lex_score_l1,lex_nonzero_l1,lex_l1_score,lex_maxabs_l1",
        help="Comma-separated bucket names for canonical frontier retention.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging("07_guided_sds_search_668")
    csv_path = os.path.join(
        "outputs/logs", "07_guided_sds_search_668_{}.csv".format(stamp)
    )
    csv_file = None
    try:
        if args.targeted_prob < 0 or args.targeted_prob > 1:
            raise ValueError("--targeted-prob must be between 0 and 1")
        if args.shake_rate <= 0 or args.shake_rate > 1:
            raise ValueError("--shake-rate must be in (0, 1]")
        if args.soft_alpha < 0 or args.soft_beta < 0 or args.soft_gamma < 0:
            raise ValueError("--soft-alpha, --soft-beta, and --soft-gamma must be nonnegative")
        if args.score_slack < 0:
            raise ValueError("--score-slack must be nonnegative")
        if args.moment_score_cap < 0:
            raise ValueError("--moment-score-cap must be nonnegative")
        if args.moment_weight < 0:
            raise ValueError("--moment-weight must be nonnegative")
        if args.moment_lock_penalty < 0:
            raise ValueError("--moment-lock-penalty must be nonnegative")
        if args.moment_target_weight < 0:
            raise ValueError("--moment-target-weight must be nonnegative")
        for power in parse_moment_power_list(args.moment_lock_powers) + parse_moment_power_list(args.moment_target_powers):
            if power <= 0 or power >= args.v:
                raise ValueError("moment powers must lie between 1 and v-1")
        if args.novelty_weight < 0:
            raise ValueError("--novelty-weight must be nonnegative")
        if args.novelty_score_cap < 0 or args.novelty_l1_cap < 0:
            raise ValueError("--novelty-score-cap and --novelty-l1-cap must be nonnegative")
        if args.novelty_maxabs_cap < 0:
            raise ValueError("--novelty-maxabs-cap must be nonnegative")
        if args.cap_violation_penalty < 0:
            raise ValueError("--cap-violation-penalty must be nonnegative")
        if args.min_cluster_distance < 0:
            raise ValueError("--min-cluster-distance must be nonnegative")
        args.cluster_medoids = []
        if args.cluster_aware:
            if not args.cluster_medoids_json:
                raise ValueError("--cluster-aware requires --cluster-medoids-json")
            args.cluster_medoids = load_cluster_medoids(args.cluster_medoids_json)
            if not args.cluster_medoids:
                raise ValueError("no medoids loaded from {}".format(args.cluster_medoids_json))
        if args.mixed_period <= 0:
            raise ValueError("--mixed-period must be positive")
        buckets = parse_bucket_list(args.bucket)
        unknown_buckets = [bucket for bucket in buckets if bucket not in BUCKET_KEYS]
        if unknown_buckets:
            raise ValueError("unknown --bucket values: {}".format(unknown_buckets))
        if args.canonical_dedup and not args.frontier_out:
            raise ValueError("--canonical-dedup requires --frontier-out")
        params = choose_parameter_sets(args)
        seeds = choose_seeds(args)
        if args.resume_json is not None and len(params) != 1:
            raise ValueError("--resume-json requires exactly one parameter set")

        os.makedirs("outputs/logs", exist_ok=True)
        csv_file = open(csv_path, "w")
        fieldnames = [
            "timestamp",
            "v",
            "n",
            "ks",
            "lambda",
            "seed",
            "step",
            "steps",
            "score",
            "l1_error",
            "max_abs_error",
            "nonzero_defect_count",
            "best_score",
            "best_l1_error",
            "best_max_abs_error",
            "best_nonzero_defect_count",
            "restart_count",
            "plateau_escape_count",
            "strategy",
            "active_strategy",
            "objective_schedule",
            "objective_value",
            "best_objective_value",
            "objective_tuple",
            "best_objective_tuple",
            "last_improvement_step",
            "last_progress_step",
            "objective_reference_score",
            "soft_alpha",
            "soft_beta",
            "soft_gamma",
            "score_slack",
            "moment_score_cap",
            "moment_weight",
            "moment_lock_powers",
            "moment_target_powers",
            "moment_lock_penalty",
            "moment_target_weight",
            "moment_signature",
            "moment_zero_count",
            "moment_abs_sum",
            "moment_all_zero",
            "moment_lock_violation_count",
            "moment_lock_abs_sum",
            "moment_lock_all_zero",
            "moment_target_zero_count",
            "moment_target_abs_sum",
            "moment_target_all_zero",
            "best_moment_signature",
            "best_moment_zero_count",
            "best_moment_abs_sum",
            "best_moment_all_zero",
            "best_moment_lock_violation_count",
            "best_moment_lock_abs_sum",
            "best_moment_lock_all_zero",
            "best_moment_target_zero_count",
            "best_moment_target_abs_sum",
            "best_moment_target_all_zero",
            "novelty_score_cap",
            "novelty_l1_cap",
            "novelty_maxabs_cap",
            "cap_violation_penalty",
            "within_novelty_cap",
            "cap_violation_amount",
            "best_within_novelty_cap",
            "best_cap_violation_amount",
            "targeted_prob",
            "shake_rate",
            "current_temperature",
            "elapsed_sec",
            "found",
            "path",
            "canonical_hash",
            "canonical_dedup",
            "frontier_out",
            "cluster_aware",
            "nearest_cluster_id",
            "nearest_cluster_distance",
            "dist_l1_to_cluster0",
            "support_symdiff_to_cluster0",
            "novelty_score",
            "best_nearest_cluster_id",
            "best_nearest_cluster_distance",
            "best_dist_l1_to_cluster0",
            "best_support_symdiff_to_cluster0",
            "best_novelty_score",
        ]
        csv_writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        csv_writer.writeheader()

        print("CSV log:", csv_path)
        print("Parameter sets:", params)
        print("Seeds:", seeds)
        print("Objective schedule:", args.objective_schedule)
        if args.cluster_aware:
            print("Cluster-aware novelty: enabled")
            print("Cluster medoids:", args.cluster_medoids_json)
            print("Avoid cluster:", args.avoid_cluster_id)
            print("Novelty weight:", args.novelty_weight)
            print(
                "Novelty caps: score={} l1={} max_abs={} penalty={}".format(
                    args.novelty_score_cap,
                    args.novelty_l1_cap,
                    args.novelty_maxabs_cap,
                    args.cap_violation_penalty,
                )
            )
            print("Loaded medoids:", len(args.cluster_medoids))
        canonical_frontier = None
        if args.canonical_dedup:
            canonical_frontier = BucketedCanonicalFrontier(
                args.frontier_out,
                buckets,
                args.save_top_k_per_bucket,
            )
            print("Canonical dedup: enabled")
            print("Canonical frontier:", args.frontier_out)
            print("Canonical buckets:", buckets)

        overall_best = None
        overall_best_path = ""
        overall_best_score_seen = None
        for ks, lam in params:
            validate_params(args.v, ks, lam)
            for seed in seeds:
                result = search_one(
                    args.v,
                    ks,
                    lam,
                    seed,
                    args,
                    csv_writer,
                    canonical_frontier,
                )
                csv_file.flush()

                candidate_score = int(result["best_metrics"][0])
                if overall_best_score_seen is None or candidate_score < overall_best_score_seen:
                    overall_best_score_seen = candidate_score
                if is_better(result["best_metrics"], overall_best, args, overall_best_score_seen):
                    overall_best = result["best_metrics"]
                    overall_best_path = result["best_path"] or result["path"]

                if result["found"] and not args.continue_after_found:
                    print("\nSTOP: verified success candidate found")
                    print("path:", result["path"])
                    return

        if overall_best is not None:
            print(
                "\nDONE: no verified success candidate in this run. "
                "overall_best_score={} overall_best_l1_error={} "
                "overall_best_max_abs_error={} "
                "overall_best_nonzero_defect_count={} overall_best_path={}".format(
                    overall_best[0],
                    overall_best[1],
                    overall_best[2],
                    overall_best[3],
                    overall_best_path,
                )
            )
    finally:
        if csv_file is not None:
            csv_file.close()
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
