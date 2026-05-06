from sage.all import *

import argparse
import csv
import math
import os
import random
import sys
import time

from sds_repair_utils import (
    base_payload,
    delta_swap,
    load_candidate,
    metrics_from_counts,
    save_success,
    setup_logging,
    timestamp,
    total_diff_counts,
    write_json,
)


SCRIPT_NAME = "29_fourier_targeted_search"


def real_part(z):
    attr = z.real
    return float(attr() if callable(attr) else attr)


def imag_part(z):
    attr = z.imag
    return float(attr() if callable(attr) else attr)


def defect_vector(v, counts, lam):
    values = [0] * v
    for d in range(1, v):
        values[d] = int(counts[d] - lam)
    return values


def dft_coeff(values, mode):
    v = len(values)
    total = complex(0.0, 0.0)
    for d, value in enumerate(values):
        if value:
            angle = -2.0 * math.pi * float(mode * d) / float(v)
            total += float(value) * complex(math.cos(angle), math.sin(angle))
    return total


def top_modes_from_counts(v, counts, lam, top_modes):
    defects = defect_vector(v, counts, lam)
    rows = []
    for mode in range(1, v):
        coeff = dft_coeff(defects, mode)
        real = real_part(coeff)
        imag = imag_part(coeff)
        energy = real * real + imag * imag
        rows.append((float(energy), int(mode), coeff))
    rows.sort(key=lambda item: (-item[0], item[1]))
    selected = rows[: int(top_modes)]
    return [mode for _energy, mode, _coeff in selected]


def precompute_roots(v, modes):
    roots = {}
    for mode in modes:
        row = [0j] * v
        for d in range(v):
            angle = -2.0 * math.pi * float(mode * d) / float(v)
            row[d] = complex(math.cos(angle), math.sin(angle))
        roots[int(mode)] = row
    return roots


def coeffs_for_modes(counts, lam, modes, roots):
    v = len(counts)
    coeffs = {}
    for mode in modes:
        total = 0j
        root = roots[int(mode)]
        for d in range(1, v):
            defect = int(counts[d] - lam)
            if defect:
                total += float(defect) * root[d]
        coeffs[int(mode)] = total
    return coeffs


def selected_energy(coeffs):
    total = 0.0
    for coeff in coeffs.values():
        real = real_part(coeff)
        imag = imag_part(coeff)
        total += real * real + imag * imag
    return float(total)


def fourier_energy_stats(coeffs):
    energies = []
    for mode in sorted(coeffs):
        coeff = coeffs[mode]
        real = real_part(coeff)
        imag = imag_part(coeff)
        energies.append(float(real * real + imag * imag))
    total = float(sum(energies))
    max_energy = float(max(energies)) if energies else 0.0
    if total > 0.0:
        hhi = float(sum(e * e for e in energies) / (total * total))
        entropy = 0.0
        for energy in energies:
            if energy > 0.0:
                p = energy / total
                entropy -= p * math.log(p)
        if len(energies) > 1:
            entropy = float(entropy / math.log(float(len(energies))))
    else:
        hhi = 0.0
        entropy = 1.0
    return {
        "selected_energy": total,
        "max_mode_energy": max_energy,
        "hhi": hhi,
        "entropy": float(entropy),
    }


def delta_coeffs(delta, modes, roots):
    out = {}
    for mode in modes:
        total = 0j
        root = roots[int(mode)]
        for d, value in enumerate(delta):
            if value:
                total += float(value) * root[d]
        out[int(mode)] = total
    return out


def add_coeffs(coeffs, delta_by_mode):
    return {
        int(mode): coeffs[int(mode)] + delta_by_mode.get(int(mode), 0j)
        for mode in coeffs
    }


def metric_cap_violation(metrics, args):
    score, l1_error, max_abs_error, _nonzero_defect_count = metrics
    violation = 0
    if args.resolved_score_cap is not None:
        violation += max(0, int(score) - int(args.resolved_score_cap))
    if args.l1_cap > 0:
        violation += max(0, int(l1_error) - int(args.l1_cap))
    if args.maxabs_cap > 0:
        violation += 100 * max(0, int(max_abs_error) - int(args.maxabs_cap))
    return int(violation)


def uses_exact_cap(args):
    return args.objective in ("score_capped_dispersion", "score_capped_hybrid")


def objective_tuple(metrics, fourier_stats, args):
    score, l1_error, max_abs_error, nonzero_defect_count = metrics
    fourier_key = float(fourier_stats["selected_energy"])
    max_mode_energy = float(fourier_stats["max_mode_energy"])
    hhi = float(fourier_stats["hhi"])
    entropy_penalty = float(1.0 - fourier_stats["entropy"])
    if args.objective == "fourier_then_score":
        return (fourier_key, int(score), int(l1_error), int(max_abs_error), int(nonzero_defect_count))
    if args.objective == "score_then_fourier":
        return (int(score), int(l1_error), int(max_abs_error), int(nonzero_defect_count), fourier_key)
    if args.objective == "hybrid":
        return (
            float(score) + float(args.fourier_weight) * fourier_key / float(max(1, args.top_modes)),
            int(score),
            int(l1_error),
            int(max_abs_error),
            int(nonzero_defect_count),
        )
    if args.objective == "maxabs_fourier":
        return (int(max_abs_error), int(l1_error), int(score), fourier_key, int(nonzero_defect_count))
    if args.objective == "score_capped_dispersion":
        violation = metric_cap_violation(metrics, args)
        if violation:
            return (
                int(args.cap_violation_penalty) + int(violation),
                int(score),
                int(l1_error),
                int(max_abs_error),
                int(nonzero_defect_count),
                max_mode_energy,
                hhi,
            )
        return (
            0,
            max_mode_energy,
            hhi,
            entropy_penalty,
            int(score),
            int(l1_error),
            int(max_abs_error),
            int(nonzero_defect_count),
            fourier_key,
        )
    if args.objective == "score_capped_hybrid":
        violation = metric_cap_violation(metrics, args)
        base = (
            float(score)
            + float(args.fourier_weight) * max_mode_energy
            + float(args.dispersion_weight) * hhi * 1000.0
        )
        if violation:
            return (
                float(args.cap_violation_penalty) + float(violation),
                int(score),
                int(l1_error),
                int(max_abs_error),
                int(nonzero_defect_count),
                base,
            )
        return (
            0,
            base,
            int(score),
            int(l1_error),
            int(max_abs_error),
            int(nonzero_defect_count),
            max_mode_energy,
            hhi,
        )
    raise ValueError("unknown objective {}".format(args.objective))


def random_swap(v, blocks):
    block_idx = random.randrange(4)
    block = blocks[block_idx]
    removed = random.choice(tuple(block))
    added = random.randrange(v)
    while added in block:
        added = random.randrange(v)
    return block_idx, int(removed), int(added)


def evaluate_swap(v, blocks, counts, lam, coeffs, modes, roots, block_idx, removed, added):
    block = blocks[block_idx]
    if removed not in block or added in block:
        return None
    delta = delta_swap(v, block, removed, added)
    new_counts = [int(counts[d]) + int(delta[d]) for d in range(v)]
    metrics = metrics_from_counts(new_counts, lam)
    delta_by_mode = delta_coeffs(delta, modes, roots)
    new_coeffs = add_coeffs(coeffs, delta_by_mode)
    fourier_stats = fourier_energy_stats(new_coeffs)
    return {
        "block": int(block_idx),
        "removed": int(removed),
        "added": int(added),
        "delta": delta,
        "counts": new_counts,
        "metrics": metrics,
        "coeffs": new_coeffs,
        "fourier_energy": float(fourier_stats["selected_energy"]),
        "fourier_stats": fourier_stats,
    }


def choose_move(v, blocks, counts, lam, coeffs, modes, roots, args):
    best = None
    for _ in range(max(1, int(args.candidate_trials))):
        block_idx, removed, added = random_swap(v, blocks)
        item = evaluate_swap(v, blocks, counts, lam, coeffs, modes, roots, block_idx, removed, added)
        if item is None:
            continue
        if best is None or objective_tuple(item["metrics"], item["fourier_stats"], args) < objective_tuple(best["metrics"], best["fourier_stats"], args):
            best = item
    return best


def apply_move(blocks, move):
    block = blocks[int(move["block"])]
    block.remove(int(move["removed"]))
    block.add(int(move["added"]))


def temperature(step, steps, args):
    if args.strategy == "greedy":
        return 0.0
    progress = float(step) / float(max(1, steps))
    return max(float(args.min_temperature), float(args.temperature) * (1.0 - progress))


def accept_move(cur_metrics, cur_fourier_stats, move, step, args):
    if uses_exact_cap(args) and metric_cap_violation(move["metrics"], args) > 0:
        return False
    if objective_tuple(move["metrics"], move["fourier_stats"], args) <= objective_tuple(cur_metrics, cur_fourier_stats, args):
        return True
    if args.strategy == "greedy":
        return False
    if args.strategy == "mixed" and (step // max(1, int(args.mixed_period))) % 2 == 0:
        return False
    temp = temperature(step, args.steps, args)
    if temp <= 0:
        return False
    delta = float(move["metrics"][0] - cur_metrics[0])
    return random.random() < math.exp(-max(0.0, delta) / temp)


def shake(v, blocks, moves):
    for _ in range(max(1, int(moves))):
        block_idx, removed, added = random_swap(v, blocks)
        blocks[block_idx].remove(removed)
        blocks[block_idx].add(added)


def save_current(path_base, v, ks, lam, blocks, metrics, source_json, step, counts, modes, fourier_stats, args):
    exact_counts = total_diff_counts(v, blocks)
    exact_metrics = metrics_from_counts(exact_counts, lam)
    if exact_metrics != metrics:
        raise RuntimeError("metrics mismatch {} != {}".format(metrics, exact_metrics))
    extra = {
        "fourier_targeted_search_step": int(step),
        "fourier_modes": [int(m) for m in modes],
        "selected_fourier_energy": float(fourier_stats["selected_energy"]),
        "max_mode_energy": float(fourier_stats["max_mode_energy"]),
        "mode_energy_hhi": float(fourier_stats["hhi"]),
        "mode_energy_entropy": float(fourier_stats["entropy"]),
        "objective": args.objective,
        "resolved_score_cap": args.resolved_score_cap,
        "l1_cap": int(args.l1_cap),
        "maxabs_cap": int(args.maxabs_cap),
        "cap_violation": int(metric_cap_violation(metrics, args)),
        "cap_violation_penalty": int(args.cap_violation_penalty),
        "dispersion_weight": float(args.dispersion_weight),
        "strategy": args.strategy,
        "candidate_trials": int(args.candidate_trials),
        "mode_refresh": int(args.mode_refresh),
        "notes": "Fourier energy is floating-point heuristic only; metrics and verification are exact.",
    }
    if metrics[0] == 0:
        return save_success(
            "outputs/candidates",
            "outputs/candidates/near_hits",
            v,
            ks,
            lam,
            blocks,
            metrics,
            source_json,
            "fourier_targeted_search",
            step,
            step,
            counts,
            extra=extra,
        )
    payload = base_payload(
        v,
        ks,
        lam,
        blocks,
        metrics,
        source_json,
        "fourier_targeted_search",
        step,
        step,
        counts,
        extra=extra,
    )
    path = "{}_step{}_score{}.json".format(path_base, int(step), int(metrics[0]))
    root, ext = os.path.splitext(path)
    if not ext:
        ext = ".json"
        path = root + ext
    counter = 1
    while os.path.exists(path):
        path = "{}_{}{}".format(root, counter, ext)
        counter += 1
    write_json(path, payload)
    return path


def parse_args():
    parser = argparse.ArgumentParser(
        description="Fourier-mode targeted swap search for SDS near-hits."
    )
    parser.add_argument("candidate_json")
    parser.add_argument("--steps", type=int, default=50000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--top-modes", type=int, default=12)
    parser.add_argument("--mode-refresh", type=int, default=5000)
    parser.add_argument("--candidate-trials", type=int, default=64)
    parser.add_argument(
        "--objective",
        choices=[
            "fourier_then_score",
            "score_then_fourier",
            "hybrid",
            "maxabs_fourier",
            "score_capped_dispersion",
            "score_capped_hybrid",
        ],
        default="fourier_then_score",
    )
    parser.add_argument("--fourier-weight", type=float, default=0.01)
    parser.add_argument(
        "--score-cap",
        type=int,
        default=0,
        help="Absolute exact score cap. If 0, use initial score + --score-cap-slack.",
    )
    parser.add_argument("--score-cap-slack", type=int, default=40)
    parser.add_argument("--l1-cap", type=int, default=0)
    parser.add_argument("--maxabs-cap", type=int, default=0)
    parser.add_argument("--cap-violation-penalty", type=int, default=100000)
    parser.add_argument("--dispersion-weight", type=float, default=1.0)
    parser.add_argument("--strategy", choices=["greedy", "anneal", "mixed"], default="mixed")
    parser.add_argument("--temperature", type=float, default=20.0)
    parser.add_argument("--min-temperature", type=float, default=0.01)
    parser.add_argument("--mixed-period", type=int, default=1000)
    parser.add_argument("--plateau-escape", action="store_true")
    parser.add_argument("--restart-patience", type=int, default=10000)
    parser.add_argument("--shake-rate", type=float, default=0.04)
    parser.add_argument("--save-improvements", action="store_true")
    parser.add_argument("--out-prefix", default="outputs/candidates/near_hits/fourier_targeted")
    parser.add_argument("--csv", default="")
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    csv_path = args.csv or os.path.join("outputs/logs", "{}_{}.csv".format(SCRIPT_NAME, stamp))
    try:
        _data, v, n, ks, lam, blocks = load_candidate(args.candidate_json)
        blocks = [set(block) for block in blocks]
        random.seed(int(args.seed))
        counts = total_diff_counts(v, blocks)
        metrics = metrics_from_counts(counts, lam)
        modes = top_modes_from_counts(v, counts, lam, args.top_modes)
        roots = precompute_roots(v, modes)
        coeffs = coeffs_for_modes(counts, lam, modes, roots)
        fourier_stats = fourier_energy_stats(coeffs)
        fourier_energy = float(fourier_stats["selected_energy"])
        if int(args.score_cap) > 0:
            args.resolved_score_cap = int(args.score_cap)
        else:
            args.resolved_score_cap = int(metrics[0]) + int(args.score_cap_slack)
        best_metrics = metrics
        best_counts = list(counts)
        best_blocks = [set(block) for block in blocks]
        best_coeffs = dict(coeffs)
        best_fourier_stats = dict(fourier_stats)
        best_fourier_energy = float(best_fourier_stats["selected_energy"])
        best_step = 0
        last_improvement_step = 0
        plateau_escape_count = 0
        start = time.time()

        os.makedirs(os.path.dirname(csv_path) or ".", exist_ok=True)
        csv_file = open(csv_path, "w", newline="")
        fieldnames = [
            "timestamp",
            "step",
            "score",
            "l1_error",
            "max_abs_error",
            "nonzero_defect_count",
            "fourier_energy",
            "max_mode_energy",
            "mode_energy_hhi",
            "mode_energy_entropy",
            "cap_violation",
            "best_score",
            "best_l1_error",
            "best_max_abs_error",
            "best_nonzero_defect_count",
            "best_fourier_energy",
            "best_max_mode_energy",
            "best_mode_energy_hhi",
            "modes",
            "accepted",
            "improved_best",
            "plateau_escape_count",
            "elapsed_sec",
        ]
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()

        print("CSV log:", csv_path)
        print("Input:", args.candidate_json)
        print("v={} n={} ks={} lambda={}".format(v, n, ks, lam))
        print(
            "initial_metrics={} initial_modes={} initial_fourier_energy={:.6f} score_cap={}".format(
                metrics, modes, fourier_energy, args.resolved_score_cap
            )
        )

        for step in range(1, int(args.steps) + 1):
            if args.mode_refresh > 0 and step > 1 and (step - 1) % int(args.mode_refresh) == 0:
                modes = top_modes_from_counts(v, counts, lam, args.top_modes)
                roots = precompute_roots(v, modes)
                coeffs = coeffs_for_modes(counts, lam, modes, roots)
                fourier_stats = fourier_energy_stats(coeffs)
                fourier_energy = float(fourier_stats["selected_energy"])
                print("MODE_REFRESH step={} modes={} fourier_energy={:.6f}".format(step, modes, fourier_energy))
                sys.stdout.flush()

            move = choose_move(v, blocks, counts, lam, coeffs, modes, roots, args)
            accepted = False
            improved_best = False
            if move is not None and accept_move(metrics, fourier_stats, move, step, args):
                apply_move(blocks, move)
                counts = move["counts"]
                metrics = move["metrics"]
                coeffs = move["coeffs"]
                fourier_stats = move["fourier_stats"]
                fourier_energy = float(fourier_stats["selected_energy"])
                accepted = True

            if objective_tuple(metrics, fourier_stats, args) < objective_tuple(best_metrics, best_fourier_stats, args):
                best_metrics = metrics
                best_counts = list(counts)
                best_blocks = [set(block) for block in blocks]
                best_coeffs = dict(coeffs)
                best_fourier_stats = dict(fourier_stats)
                best_fourier_energy = float(best_fourier_stats["selected_energy"])
                best_step = step
                last_improvement_step = step
                improved_best = True
                print(
                    "BEST step={} metrics={} fourier_energy={:.6f} modes={}".format(
                        step, best_metrics, best_fourier_energy, modes
                    )
                )
                if args.save_improvements:
                    path = save_current(
                        args.out_prefix,
                        v,
                        ks,
                        lam,
                        best_blocks,
                        best_metrics,
                        args.candidate_json,
                        step,
                        best_counts,
                        modes,
                        best_fourier_stats,
                        args,
                    )
                    print("saved_best:", path)
                sys.stdout.flush()

            if args.plateau_escape and step - last_improvement_step >= int(args.restart_patience):
                escape_rejected_by_cap = False
                old_blocks = [set(block) for block in blocks]
                old_counts = list(counts)
                old_metrics = metrics
                old_coeffs = dict(coeffs)
                old_fourier_stats = dict(fourier_stats)
                old_fourier_energy = float(fourier_energy)
                shake_moves = max(1, int(sum(len(block) for block in blocks) * float(args.shake_rate)))
                shake(v, blocks, shake_moves)
                counts = total_diff_counts(v, blocks)
                metrics = metrics_from_counts(counts, lam)
                modes = top_modes_from_counts(v, counts, lam, args.top_modes)
                roots = precompute_roots(v, modes)
                coeffs = coeffs_for_modes(counts, lam, modes, roots)
                fourier_stats = fourier_energy_stats(coeffs)
                fourier_energy = float(fourier_stats["selected_energy"])
                if uses_exact_cap(args) and metric_cap_violation(metrics, args) > 0:
                    blocks = old_blocks
                    counts = old_counts
                    metrics = old_metrics
                    coeffs = old_coeffs
                    fourier_stats = old_fourier_stats
                    fourier_energy = old_fourier_energy
                    modes = top_modes_from_counts(v, counts, lam, args.top_modes)
                    roots = precompute_roots(v, modes)
                    coeffs = coeffs_for_modes(counts, lam, modes, roots)
                    fourier_stats = fourier_energy_stats(coeffs)
                    fourier_energy = float(fourier_stats["selected_energy"])
                    last_improvement_step = step
                    print(
                        "PLATEAU_ESCAPE_REJECTED_BY_CAP step={} shake_moves={} cur_metrics={}".format(
                            step, shake_moves, metrics
                        )
                    )
                    sys.stdout.flush()
                    escape_rejected_by_cap = True
                if not escape_rejected_by_cap:
                    plateau_escape_count += 1
                    last_improvement_step = step
                    print(
                        "PLATEAU_ESCAPE step={} count={} shake_moves={} cur_metrics={} modes={}".format(
                            step, plateau_escape_count, shake_moves, metrics, modes
                        )
                    )
                    sys.stdout.flush()

            if step % 5000 == 0 or step == int(args.steps) or improved_best:
                row = {
                    "timestamp": timestamp(),
                    "step": int(step),
                    "score": int(metrics[0]),
                    "l1_error": int(metrics[1]),
                    "max_abs_error": int(metrics[2]),
                    "nonzero_defect_count": int(metrics[3]),
                    "fourier_energy": float(fourier_energy),
                    "max_mode_energy": float(fourier_stats["max_mode_energy"]),
                    "mode_energy_hhi": float(fourier_stats["hhi"]),
                    "mode_energy_entropy": float(fourier_stats["entropy"]),
                    "cap_violation": int(metric_cap_violation(metrics, args)),
                    "best_score": int(best_metrics[0]),
                    "best_l1_error": int(best_metrics[1]),
                    "best_max_abs_error": int(best_metrics[2]),
                    "best_nonzero_defect_count": int(best_metrics[3]),
                    "best_fourier_energy": float(best_fourier_energy),
                    "best_max_mode_energy": float(best_fourier_stats["max_mode_energy"]),
                    "best_mode_energy_hhi": float(best_fourier_stats["hhi"]),
                    "modes": ",".join(str(int(m)) for m in modes),
                    "accepted": bool(accepted),
                    "improved_best": bool(improved_best),
                    "plateau_escape_count": int(plateau_escape_count),
                    "elapsed_sec": round(time.time() - start, 3),
                }
                writer.writerow(row)
                csv_file.flush()
                if step % 5000 == 0 or step == int(args.steps):
                    print(
                        "step={} cur={} fourier={:.3f} best={} best_fourier={:.3f} plateau={} elapsed={:.1f}s".format(
                            step,
                            metrics,
                            fourier_energy,
                            best_metrics,
                            best_fourier_energy,
                            plateau_escape_count,
                            time.time() - start,
                        )
                    )
                    sys.stdout.flush()

            if best_metrics[0] == 0:
                break

        final_path = save_current(
            args.out_prefix,
            v,
            ks,
            lam,
            best_blocks,
            best_metrics,
            args.candidate_json,
            best_step,
            best_counts,
            modes,
            best_fourier_stats,
            args,
        )
        print("FINAL_BEST path={} metrics={} step={} fourier_energy={:.6f}".format(final_path, best_metrics, best_step, best_fourier_energy))
        if best_metrics[0] == 0:
            print("SUCCESS CANDIDATE GENERATED AND VERIFIED")
        else:
            print("DONE: no verified success candidate from Fourier targeted search.")
        csv_file.close()
    finally:
        tee.close()


if __name__ == "__main__":
    main()
