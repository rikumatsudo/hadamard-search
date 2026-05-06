from sage.all import *

import argparse
import csv
import json
import math
import os
import random
import sys
import time


DEFAULT_V = 167
TARGETS = {
    "two83": ((73, 76, 83, 83), 148),
    "one83": ((74, 76, 79, 83), 145),
}


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


def parse_indices(value):
    if value is None or value.strip() == "":
        return None
    try:
        indices = tuple(int(part.strip()) for part in value.split(",") if part.strip())
    except ValueError:
        raise argparse.ArgumentTypeError("indices must be comma-separated ints")
    if len(indices) != len(set(indices)):
        raise argparse.ArgumentTypeError("duplicate skew block index")
    return indices


def validate_params(v, ks, lam):
    if v != 167:
        raise ValueError("skew search is currently implemented for v=167 only")
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


def choose_target(args):
    if args.ks is not None:
        ks = args.ks
        lam = args.lam if args.lam is not None else sum(ks) - args.v
    else:
        ks, lam = TARGETS[args.target]
        if args.lam is not None:
            lam = args.lam
    validate_params(args.v, ks, lam)
    return ks, lam


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


def choose_skew_blocks(args, ks):
    if args.skew_blocks is None:
        indices = tuple(idx for idx, k in enumerate(ks) if k == 83)
    else:
        indices = args.skew_blocks
    if not indices:
        raise ValueError("at least one skew block index is required")
    for idx in indices:
        if idx < 0 or idx >= 4:
            raise ValueError("skew block index {} is outside 0..3".format(idx))
        if ks[idx] != 83:
            raise ValueError(
                "skew block {} has size {}; expected 83".format(idx, ks[idx])
            )
    return tuple(indices)


def skew_pairs(v):
    return [(a, (-a) % v) for a in range(1, (v + 1) // 2)]


def random_skew_block(v):
    block = set()
    for a, b in skew_pairs(v):
        block.add(a if random.randrange(2) == 0 else b)
    return block


def validate_skew_block(v, block):
    if 0 in block:
        return False
    if len(block) != (v - 1) // 2:
        return False
    for a, b in skew_pairs(v):
        if (a in block) == (b in block):
            return False
    return True


def random_blocks(v, ks, skew_blocks):
    universe = list(range(v))
    blocks = []
    for idx, k in enumerate(ks):
        if idx in skew_blocks:
            blocks.append(random_skew_block(v))
        else:
            blocks.append(set(random.sample(universe, int(k))))
    return blocks


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
    for d in range(1, len(counts)):
        err = int(counts[d] - lam)
        abs_err = abs(err)
        score += err * err
        l1_error += abs_err
        if abs_err > max_abs_error:
            max_abs_error = abs_err
    return int(score), int(l1_error), int(max_abs_error)


def is_better(candidate_metrics, best_metrics):
    if best_metrics is None:
        return True
    return tuple(candidate_metrics) < tuple(best_metrics)


def propose_move(v, block, is_skew):
    if is_skew:
        a = random.randrange(1, (v + 1) // 2)
        b = (-a) % v
        if a in block:
            return a, b
        if b in block:
            return b, a
        raise ValueError("invalid skew block: pair {{{}, {}}} has no selected element".format(a, b))

    removed = random.choice(tuple(block))
    added = random.randrange(v)
    while added in block:
        added = random.randrange(v)
    return removed, added


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


def json_blocks(blocks):
    return [[int(x) for x in sorted(list(block))] for block in blocks]


def write_json(path, payload):
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)


def base_payload(v, ks, lam, blocks, metrics, seed, step, restart_count, skew_blocks):
    score, l1_error, max_abs_error = metrics
    return {
        "v": int(v),
        "n": int(4 * v),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": json_blocks(blocks),
        "score": int(score),
        "l1_error": int(l1_error),
        "max_abs_error": int(max_abs_error),
        "seed": int(seed),
        "step": int(step),
        "restart_count": int(restart_count),
        "skew_blocks": [int(idx) for idx in skew_blocks],
        "verify_sds": False,
        "generated_hadamard": False,
        "hh_t": False,
        "construction": "Goethals-Seidel",
        "search_method": "skew_guided_swap_local_search",
        "timestamp": timestamp(),
    }


def save_near_hit(outdir, v, ks, lam, blocks, metrics, seed, step, restart_count, skew_blocks):
    os.makedirs(outdir, exist_ok=True)
    score, l1_error, max_abs_error = metrics
    payload = base_payload(v, ks, lam, blocks, metrics, seed, step, restart_count, skew_blocks)
    name = "near_hit_skew_v{}_score{}_seed{}_step{}.json".format(v, score, seed, step)
    path = ensure_unique_path(os.path.join(outdir, name))
    write_json(path, payload)
    print(
        "NEAR_HIT saved path={} score={} l1_error={} max_abs_error={}".format(
            path, score, l1_error, max_abs_error
        )
    )
    return path


def save_success(outdir, v, ks, lam, blocks, metrics, seed, step, restart_count, skew_blocks):
    os.makedirs(outdir, exist_ok=True)
    payload = base_payload(v, ks, lam, blocks, metrics, seed, step, restart_count, skew_blocks)

    sds_ok, bad = verify_sds(v, blocks, lam)
    payload["verify_sds"] = bool(sds_ok)
    if not sds_ok:
        payload["sds_failure_first_bad_shifts"] = [
            [int(d), int(count)] for d, count in bad[:30]
        ]
        path = ensure_unique_path(
            os.path.join(
                "outputs/candidates/near_hits",
                "near_hit_skew_v{}_score0_seed{}_step{}.json".format(v, seed, step),
            )
        )
        write_json(path, payload)
        raise RuntimeError("score 0 candidate failed SDS verification; saved {}".format(path))

    entries_ok, hh_t = verify_hadamard_exact(v, blocks)
    payload["generated_hadamard"] = bool(entries_ok)
    payload["hh_t"] = bool(hh_t)
    if not entries_ok or not hh_t:
        path = ensure_unique_path(
            os.path.join(
                "outputs/candidates/near_hits",
                "near_hit_skew_v{}_score0_seed{}_step{}.json".format(v, seed, step),
            )
        )
        write_json(path, payload)
        raise RuntimeError("score 0 SDS failed GS Hadamard verification; saved {}".format(path))

    name = "candidate_skew_sds_v{}_n{}_seed{}_step{}.json".format(v, 4 * v, seed, step)
    path = ensure_unique_path(os.path.join(outdir, name))
    write_json(path, payload)
    print("SUCCESS saved:", path)
    return path


def temperature_at(args, step):
    if args.anneal == "none":
        return float(args.temperature)
    progress = min(1.0, float(step) / float(args.steps)) if args.steps > 0 else 0.0
    return max(float(args.min_temperature), float(args.temperature) * (1.0 - progress))


def accept_move(cur_score, new_score, temp):
    if new_score <= cur_score:
        return True
    if temp <= 0:
        return False
    exponent = float(cur_score - new_score) / float(temp)
    if exponent < -700:
        return False
    return random.random() < math.exp(exponent)


def progress_row(v, ks, lam, seed, step, total_steps, cur_metrics, best_metrics, restart_count, start_time, found, path):
    score, l1_error, max_abs_error = cur_metrics
    best_score, best_l1_error, best_max_abs_error = best_metrics
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
        "best_score": int(best_score),
        "best_l1_error": int(best_l1_error),
        "best_max_abs_error": int(best_max_abs_error),
        "restart_count": int(restart_count),
        "elapsed_sec": float(time.time() - start_time),
        "found": bool(found),
        "path": path,
    }


def print_progress(row):
    print(
        "step={step} score={score} l1_error={l1_error} "
        "max_abs_error={max_abs_error} best_score={best_score} "
        "best_l1_error={best_l1_error} best_max_abs_error={best_max_abs_error} "
        "seed={seed} restart_count={restart_count} elapsed_sec={elapsed_sec:.2f}".format(
            **row
        )
    )


def search_one(v, ks, lam, skew_blocks, seed, args, csv_writer):
    random.seed(int(seed))
    blocks = random_blocks(v, ks, skew_blocks)
    for idx in skew_blocks:
        if not validate_skew_block(v, blocks[idx]):
            raise ValueError("generated invalid skew block {}".format(idx))

    counts = total_diff_counts(v, blocks)
    cur_metrics = metrics_from_counts(counts, lam)
    cur_score = cur_metrics[0]
    best_metrics = None
    best_blocks = None
    best_path = None
    last_improvement_step = 0
    restart_count = 0
    start_time = time.time()
    movable_blocks = [idx for idx, k in enumerate(ks) if 0 < k < v]

    print(
        "\nSkew search v={} n={} ks={} lambda={} skew_blocks={} seed={} steps={}".format(
            v, 4 * v, ks, lam, skew_blocks, seed, args.steps
        )
    )

    if is_better(cur_metrics, best_metrics):
        best_metrics = cur_metrics
        best_blocks = [set(block) for block in blocks]
        best_path = save_near_hit(
            args.near_hit_dir,
            v,
            ks,
            lam,
            best_blocks,
            best_metrics,
            seed,
            0,
            restart_count,
            skew_blocks,
        )

    for step in range(1, args.steps + 1):
        block_idx = random.choice(movable_blocks)
        is_skew = block_idx in skew_blocks
        removed, added = propose_move(v, blocks[block_idx], is_skew)
        delta = delta_swap(v, blocks[block_idx], removed, added)
        new_counts = [counts[d] + delta[d] for d in range(v)]
        new_metrics = metrics_from_counts(new_counts, lam)
        new_score = new_metrics[0]

        if accept_move(cur_score, new_score, temperature_at(args, step)):
            blocks[block_idx].remove(removed)
            blocks[block_idx].add(added)
            if is_skew and not validate_skew_block(v, blocks[block_idx]):
                raise RuntimeError("skew invariant was broken for block {}".format(block_idx))
            counts = new_counts
            cur_metrics = new_metrics
            cur_score = new_score

            if is_better(cur_metrics, best_metrics):
                best_metrics = cur_metrics
                best_blocks = [set(block) for block in blocks]
                last_improvement_step = step
                best_path = save_near_hit(
                    args.near_hit_dir,
                    v,
                    ks,
                    lam,
                    best_blocks,
                    best_metrics,
                    seed,
                    step,
                    restart_count,
                    skew_blocks,
                )

        if cur_score == 0:
            print("FOUND score 0 at step {}; running exact verification".format(step))
            found_path = save_success(
                args.candidate_dir,
                v,
                ks,
                lam,
                blocks,
                cur_metrics,
                seed,
                step,
                restart_count,
                skew_blocks,
            )
            row = progress_row(
                v, ks, lam, seed, step, args.steps, cur_metrics, best_metrics,
                restart_count, start_time, True, found_path
            )
            csv_writer.writerow(row)
            print_progress(row)
            return {"found": True, "path": found_path, "best_metrics": cur_metrics, "best_path": found_path}

        if args.log_interval > 0 and step % args.log_interval == 0:
            row = progress_row(
                v, ks, lam, seed, step, args.steps, cur_metrics, best_metrics,
                restart_count, start_time, False, best_path or ""
            )
            csv_writer.writerow(row)
            print_progress(row)

        stagnant = step - last_improvement_step
        if (
            args.restart_patience > 0
            and stagnant >= args.restart_patience
            and restart_count < args.max_restarts
        ):
            restart_count += 1
            print(
                "RESTART seed={} restart_count={} step={} stagnant_steps={}".format(
                    seed, restart_count, step, stagnant
                )
            )
            blocks = random_blocks(v, ks, skew_blocks)
            counts = total_diff_counts(v, blocks)
            cur_metrics = metrics_from_counts(counts, lam)
            cur_score = cur_metrics[0]
            last_improvement_step = step
            if is_better(cur_metrics, best_metrics):
                best_metrics = cur_metrics
                best_blocks = [set(block) for block in blocks]
                best_path = save_near_hit(
                    args.near_hit_dir,
                    v,
                    ks,
                    lam,
                    best_blocks,
                    best_metrics,
                    seed,
                    step,
                    restart_count,
                    skew_blocks,
                )

    row = progress_row(
        v, ks, lam, seed, args.steps, args.steps, cur_metrics, best_metrics,
        restart_count, start_time, False, best_path or ""
    )
    csv_writer.writerow(row)
    print_progress(row)
    print(
        "NOT FOUND seed={} best_score={} best_l1_error={} "
        "best_max_abs_error={} best_path={}".format(
            seed, best_metrics[0], best_metrics[1], best_metrics[2], best_path
        )
    )
    return {"found": False, "path": "", "best_metrics": best_metrics, "best_path": best_path}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Skew-constrained SDS search for selected k=83 blocks over Z_167."
    )
    parser.add_argument("--v", type=int, default=DEFAULT_V)
    parser.add_argument(
        "--target",
        choices=sorted(TARGETS.keys()),
        default="two83",
        help="two83=(73,76,83,83), one83=(74,76,79,83).",
    )
    parser.add_argument("--ks", type=parse_ks, default=None)
    parser.add_argument("--lam", type=int, default=None)
    parser.add_argument(
        "--skew-blocks",
        type=parse_indices,
        default=None,
        help="0-based block indices to constrain as skew. Default: all k=83 blocks.",
    )
    parser.add_argument("--steps", type=int, default=1000000)
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--seed-start", type=int, default=None)
    parser.add_argument("--seed-end", type=int, default=None)
    parser.add_argument("--temperature", type=float, default=1.0)
    parser.add_argument("--min-temperature", type=float, default=0.01)
    parser.add_argument("--anneal", choices=["linear", "none"], default="linear")
    parser.add_argument("--restart-patience", type=int, default=50000)
    parser.add_argument("--max-restarts", type=int, default=100)
    parser.add_argument("--log-interval", type=int, default=5000)
    parser.add_argument("--near-hit-dir", default="outputs/candidates/near_hits")
    parser.add_argument("--candidate-dir", default="outputs/candidates")
    parser.add_argument("--continue-after-found", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging("10_skew_sds_search_668")
    csv_path = os.path.join("outputs/logs", "10_skew_sds_search_668_{}.csv".format(stamp))
    csv_file = None
    try:
        ks, lam = choose_target(args)
        skew_blocks = choose_skew_blocks(args, ks)
        seeds = choose_seeds(args)

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
            "best_score",
            "best_l1_error",
            "best_max_abs_error",
            "restart_count",
            "elapsed_sec",
            "found",
            "path",
        ]
        csv_writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        csv_writer.writeheader()

        print("CSV log:", csv_path)
        print("Target ks={} lambda={} skew_blocks={} seeds={}".format(ks, lam, skew_blocks, seeds))

        overall_best = None
        overall_best_path = ""
        for seed in seeds:
            result = search_one(args.v, ks, lam, skew_blocks, seed, args, csv_writer)
            csv_file.flush()
            if is_better(result["best_metrics"], overall_best):
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
                "overall_best_max_abs_error={} overall_best_path={}".format(
                    overall_best[0], overall_best[1], overall_best[2], overall_best_path
                )
            )
    finally:
        if csv_file is not None:
            csv_file.close()
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
