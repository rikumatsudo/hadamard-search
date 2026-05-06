from sage.all import *

import argparse
import csv
import json
import os
import re
import subprocess
import sys
import time

from sds_repair_utils import (
    canonical_hash,
    canonical_repr_summary,
    load_candidate,
    load_selected_moves,
    metrics_from_counts,
    setup_logging,
    timestamp,
    total_diff_counts,
    write_json,
)


def script_path(name):
    return os.path.join("sage", name)


def run_command(cmd, log_prefix):
    print("\nRUN {}: {}".format(log_prefix, " ".join(cmd)))
    start = time.time()
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        universal_newlines=True,
        bufsize=int(1),
    )
    lines = []
    for line in proc.stdout:
        line = line.rstrip("\n")
        lines.append(line)
        print(line)
    code = proc.wait()
    elapsed = time.time() - start
    print("END {}: code={} elapsed_sec={:.2f}".format(log_prefix, code, elapsed))
    return code, "\n".join(lines), elapsed


def parse_saved_path(output):
    saved = re.findall(r"NEAR_HIT saved path=([^\s]+)", output)
    if saved:
        return saved[-1]
    done = re.findall(r"DONE: final .* path=([^\s]+)", output)
    if done:
        return done[-1]
    success = re.findall(r"SUCCESS saved:\s*([^\s]+)", output)
    if success:
        return success[-1]
    return ""


def append_tabu_args(cmd, args, tabu_json):
    if not args.tabu_after_ilp or not tabu_json:
        return cmd
    cmd.extend(["--tabu-json", tabu_json])
    cmd.extend(["--tabu-tenure", str(args.tabu_tenure)])
    if args.no_reversal:
        cmd.append("--no-reversal")
    if args.tabu_touch_elements:
        cmd.append("--tabu-touch-elements")
    return cmd


def candidate_metrics(path):
    data, v, n, ks, lam, blocks = load_candidate(path)
    counts = total_diff_counts(v, blocks)
    metrics = metrics_from_counts(counts, lam)
    return data, v, n, ks, lam, metrics


def parameter_key(record):
    return (
        int(record["v"]),
        int(record["n"]),
        tuple(int(k) for k in record["ks"]),
        int(record["lambda"]),
    )


def metric_tuple(record):
    return (
        int(record["score"]),
        int(record["l1_error"]),
        int(record["max_abs_error"]),
        int(record["nonzero_defect_count"]),
    )


def dominates(left, right):
    if parameter_key(left) != parameter_key(right):
        return False
    left_metrics = metric_tuple(left)
    right_metrics = metric_tuple(right)
    if left_metrics == right_metrics:
        return (
            str(left.get("timestamp", "")),
            str(left.get("source_path", "")),
        ) < (
            str(right.get("timestamp", "")),
            str(right.get("source_path", "")),
        )
    return all(a <= b for a, b in zip(left_metrics, right_metrics)) and any(
        a < b for a, b in zip(left_metrics, right_metrics)
    )


def load_frontier(frontier_dir):
    index_path = os.path.join(frontier_dir, "frontier_index.json")
    if not os.path.exists(index_path):
        return []
    with open(index_path) as f:
        data = json.load(f)
    return data.get("records", [])


def copy_to_frontier(path, frontier_dir):
    os.makedirs(frontier_dir, exist_ok=True)
    with open(path) as f:
        payload = json.load(f)
    out_path = os.path.join(frontier_dir, os.path.basename(path))
    if os.path.exists(out_path):
        root, ext = os.path.splitext(out_path)
        idx = 1
        while os.path.exists("{}_{}{}".format(root, idx, ext)):
            idx += 1
        out_path = "{}_{}{}".format(root, idx, ext)
    write_json(out_path, payload)
    return out_path


def write_frontier(frontier_dir, records):
    os.makedirs(frontier_dir, exist_ok=True)
    records = sorted(
        records,
        key=lambda item: (
            parameter_key(item),
            metric_tuple(item),
            item.get("source_path", ""),
        ),
    )
    write_json(
        os.path.join(frontier_dir, "frontier_index.json"),
        {
            "timestamp": timestamp(),
            "metric_order": [
                "score",
                "l1_error",
                "max_abs_error",
                "nonzero_defect_count",
            ],
            "records": records,
        },
    )


def register_frontier(path, frontier_dir, label):
    if not path or not os.path.exists(path):
        return {"registered": False, "pareto_active": False, "frontier_count": 0}

    data, v, n, ks, lam, metrics = candidate_metrics(path)
    records = load_frontier(frontier_dir)
    norm_path = os.path.normpath(path)
    already = None
    for record in records:
        if os.path.normpath(record.get("source_path", "")) == norm_path:
            already = record
            break

    if already is None:
        frontier_path = copy_to_frontier(path, frontier_dir)
        canon_hash = canonical_hash(blocks, ks, v)
        records.append(
            {
                "path": frontier_path,
                "source_path": path,
                "label": label,
                "v": int(v),
                "n": int(n),
                "ks": [int(k) for k in ks],
                "lambda": int(lam),
                "score": int(metrics[0]),
                "l1_error": int(metrics[1]),
                "max_abs_error": int(metrics[2]),
                "nonzero_defect_count": int(metrics[3]),
                "canonical_hash": canon_hash,
                "canonical_repr_summary": canonical_repr_summary(blocks, ks, v),
                "timestamp": timestamp(),
            }
        )

    active = []
    for idx, record in enumerate(records):
        is_dominated = False
        for jdx, other in enumerate(records):
            if idx == jdx:
                continue
            if dominates(other, record):
                is_dominated = True
                break
        if not is_dominated:
            active.append(record)

    write_frontier(frontier_dir, active)
    pareto_active = any(
        os.path.normpath(record.get("source_path", "")) == norm_path
        for record in active
    )
    return {
        "registered": True,
        "pareto_active": bool(pareto_active),
        "frontier_count": int(len(active)),
        "metrics": metrics,
    }


def frontier_candidate_paths(frontier_dir):
    paths = []
    for record in load_frontier(frontier_dir):
        source = record.get("source_path") or record.get("path")
        if source and os.path.exists(source):
            paths.append(source)
        elif record.get("path") and os.path.exists(record["path"]):
            paths.append(record["path"])
    return paths


def unique_existing(paths):
    out = []
    seen = set()
    for path in paths:
        if not path or not os.path.exists(path):
            continue
        key = os.path.normpath(path)
        if key in seen:
            continue
        seen.add(key)
        out.append(path)
    return out


def sorted_candidate_paths(paths, mode, loop_index):
    scored = []
    for path in unique_existing(paths):
        try:
            _, _, _, _, _, metrics = candidate_metrics(path)
        except Exception as exc:
            print("WARNING: cannot score frontier candidate {}: {}".format(path, exc))
            continue
        scored.append((path, metrics))

    if mode == "best_score":
        scored.sort(key=lambda item: tuple(item[1]) + (item[0],))
        return [path for path, _ in scored]
    if mode == "best_l1":
        scored.sort(
            key=lambda item: (
                item[1][1],
                item[1][0],
                item[1][2],
                item[1][3],
                item[0],
            )
        )
        return [path for path, _ in scored]
    if mode == "best_nonzero":
        scored.sort(
            key=lambda item: (
                item[1][3],
                item[1][1],
                item[1][0],
                item[1][2],
                item[0],
            )
        )
        return [path for path, _ in scored]
    if mode == "mixed":
        score_sorted = sorted(scored, key=lambda item: tuple(item[1]) + (item[0],))
        nonzero_sorted = sorted(
            scored,
            key=lambda item: (
                item[1][3],
                item[1][1],
                item[1][0],
                item[1][2],
                item[0],
            ),
        )
        first = nonzero_sorted if loop_index % 2 == 0 else score_sorted
        second = score_sorted if loop_index % 2 == 0 else nonzero_sorted
        out = []
        seen = set()
        for bucket in (first, second):
            for path, _ in bucket:
                key = os.path.normpath(path)
                if key in seen:
                    continue
                seen.add(key)
                out.append(path)
        return out
    raise ValueError("unknown frontier selector: {}".format(mode))


def parse_plan(value):
    out = []
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        if ":" in item:
            objective, acceptance = item.split(":", 1)
        else:
            objective, acceptance = item, "lex"
        out.append((objective.strip(), acceptance.strip()))
    if not out:
        raise ValueError("--objective-plan is empty")
    return out


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run frontier-driven repair loops over SDS near-hits."
    )
    parser.add_argument("--loops", type=int, default=10)
    parser.add_argument("--pool-size", type=int, default=60)
    parser.add_argument("--pool-mode", default="diverse")
    parser.add_argument("--max-moves", type=int, default=4)
    parser.add_argument("--residual-bound", type=int, default=8)
    parser.add_argument(
        "--objective-plan",
        default="score_then_l1:lex,l1:l1_then_score,max_then_l1:max_then_score",
        help="Comma-separated objective:acceptance pairs cycled by loop.",
    )
    parser.add_argument("--steepest-max-rounds", type=int, default=20)
    parser.add_argument("--beam-width", type=int, default=100)
    parser.add_argument("--beam-rounds", type=int, default=1)
    parser.add_argument("--beam-depth", type=int, choices=[1, 2, 3], default=2)
    parser.add_argument(
        "--beam-rank-mode",
        choices=["score", "l1", "zero_protect", "mixed"],
        default="score",
    )
    parser.add_argument(
        "--frontier-select",
        choices=["best_score", "best_l1", "best_nonzero", "mixed"],
        default="best_score",
    )
    parser.add_argument("--zero-protect-weight", type=int, default=100000)
    parser.add_argument(
        "--ilp-time-limit",
        type=int,
        default=0,
        help="Optional per-candidate ILP time limit passed to 13; 0 means no limit.",
    )
    parser.add_argument(
        "--post-ilp-order",
        choices=["steepest_then_beam", "beam_then_steepest"],
        default="steepest_then_beam",
    )
    parser.add_argument(
        "--tabu-after-ilp",
        action="store_true",
        help="Pass ILP selected_moves to post-ILP repairs as a tabu source.",
    )
    parser.add_argument("--tabu-tenure", type=int, default=1)
    parser.add_argument(
        "--no-reversal",
        action="store_true",
        help="Post-ILP repairs skip exact reverse moves from selected_moves.",
    )
    parser.add_argument(
        "--tabu-touch-elements",
        action="store_true",
        help="Post-ILP repairs also skip swaps touching ILP-moved elements.",
    )
    parser.add_argument(
        "--frontier-dir",
        default="outputs/candidates/near_hits/frontier",
    )
    parser.add_argument(
        "--extra-json",
        action="append",
        default=[],
        help="Additional near-hit JSON to include in every loop.",
    )
    parser.add_argument(
        "--sage-bin",
        default=os.environ.get("SAGE_BINARY", "sage"),
        help="Sage executable used for child repair scripts.",
    )
    parser.add_argument(
        "--max-candidates-per-loop",
        type=int,
        default=0,
        help="Optional cap; 0 means all frontier plus extras.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    if args.loops < 1:
        raise ValueError("--loops must be positive")
    objective_plan = parse_plan(args.objective_plan)

    tee, stamp = setup_logging("14_frontier_repair_batch")
    csv_path = os.path.join(
        "outputs/logs", "14_frontier_repair_batch_{}.csv".format(stamp)
    )
    csv_file = None
    try:
        os.makedirs("outputs/logs", exist_ok=True)
        csv_file = open(csv_path, "w")
        fieldnames = [
            "timestamp",
            "loop",
            "candidate",
            "objective",
            "acceptance",
            "ilp_path",
            "steepest_path",
            "beam_path",
            "final_path",
            "final_score",
            "final_l1_error",
            "final_max_abs_error",
            "final_nonzero_defect_count",
            "pareto_active",
            "frontier_count",
            "selected_moves_count",
            "tabu_enabled",
            "post_ilp_order",
            "beam_depth",
            "rank_mode",
            "frontier_select",
            "ilp_elapsed_sec",
            "steepest_elapsed_sec",
            "beam_elapsed_sec",
        ]
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()

        print("CSV log:", csv_path)
        print("frontier_dir:", args.frontier_dir)
        print("extra_json:", args.extra_json)
        print("objective_plan:", objective_plan)
        print(
            "post_ilp_order={} tabu_after_ilp={} no_reversal={} "
            "tabu_touch_elements={} tabu_tenure={} beam_depth={} "
            "beam_rank_mode={} frontier_select={} zero_protect_weight={}".format(
                args.post_ilp_order,
                bool(args.tabu_after_ilp),
                bool(args.no_reversal),
                bool(args.tabu_touch_elements),
                int(args.tabu_tenure),
                int(args.beam_depth),
                args.beam_rank_mode,
                args.frontier_select,
                int(args.zero_protect_weight),
            )
        )

        for extra in args.extra_json:
            if os.path.exists(extra):
                info = register_frontier(extra, args.frontier_dir, "extra_input")
                print("registered extra:", extra, info)
            else:
                print("WARNING: extra JSON not found:", extra)

        for loop_index in range(1, args.loops + 1):
            objective, acceptance = objective_plan[(loop_index - 1) % len(objective_plan)]
            candidates = sorted_candidate_paths(
                frontier_candidate_paths(args.frontier_dir) + args.extra_json,
                args.frontier_select,
                loop_index,
            )
            if args.max_candidates_per_loop > 0:
                candidates = candidates[: args.max_candidates_per_loop]
            print(
                "\nLOOP {} objective={} acceptance={} frontier_select={} "
                "candidates={}".format(
                    loop_index,
                    objective,
                    acceptance,
                    args.frontier_select,
                    len(candidates),
                )
            )

            for candidate_idx, candidate in enumerate(candidates):
                seed = loop_index * 1000 + candidate_idx + 1
                ilp_cmd = [
                    args.sage_bin,
                    script_path("13_ilp_repair_from_near_hit.sage"),
                    candidate,
                    "--pool-size",
                    str(args.pool_size),
                    "--pool-mode",
                    args.pool_mode,
                    "--max-moves",
                    str(args.max_moves),
                    "--rounds",
                    "1",
                    "--objective",
                    objective,
                    "--acceptance",
                    acceptance,
                    "--residual-bound",
                    str(args.residual_bound),
                    "--zero-protect-weight",
                    str(args.zero_protect_weight),
                    "--pool-random-seed",
                    str(seed),
                    "--frontier-dir",
                    args.frontier_dir,
                ]
                if args.ilp_time_limit > 0:
                    ilp_cmd.extend(["--time-limit", str(args.ilp_time_limit)])
                code, output, ilp_elapsed = run_command(
                    ilp_cmd, "loop{}_cand{}_ilp".format(loop_index, candidate_idx + 1)
                )
                if code != 0:
                    print("WARNING: ILP repair failed for", candidate)
                    continue

                ilp_path = parse_saved_path(output) or candidate
                steepest_path = ilp_path
                beam_path = ilp_path
                steepest_elapsed = 0.0
                beam_elapsed = 0.0
                selected_moves_count = 0
                tabu_enabled = False

                if os.path.normpath(ilp_path) != os.path.normpath(candidate):
                    selected_moves_count = len(load_selected_moves(ilp_path))
                    tabu_enabled = bool(
                        args.tabu_after_ilp
                        and selected_moves_count > 0
                        and (args.no_reversal or args.tabu_touch_elements)
                    )
                    tabu_json = ilp_path if args.tabu_after_ilp else None

                    def run_steepest(input_path):
                        steepest_cmd = [
                            args.sage_bin,
                            script_path("11_steepest_swap_descent.sage"),
                            input_path,
                            "--max-rounds",
                            str(args.steepest_max_rounds),
                        ]
                        append_tabu_args(steepest_cmd, args, tabu_json)
                        return run_command(
                            steepest_cmd,
                            "loop{}_cand{}_steepest".format(
                                loop_index, candidate_idx + 1
                            ),
                        )

                    def run_beam(input_path):
                        beam_cmd = [
                            args.sage_bin,
                            script_path("12_beam_two_swap_repair.sage"),
                            input_path,
                            "--beam-width",
                            str(args.beam_width),
                            "--rounds",
                            str(args.beam_rounds),
                            "--depth",
                            str(args.beam_depth),
                            "--rank-mode",
                            args.beam_rank_mode,
                        ]
                        append_tabu_args(beam_cmd, args, tabu_json)
                        return run_command(
                            beam_cmd,
                            "loop{}_cand{}_beam".format(
                                loop_index, candidate_idx + 1
                            ),
                        )

                    if args.post_ilp_order == "steepest_then_beam":
                        code, output, steepest_elapsed = run_steepest(ilp_path)
                        if code == 0:
                            steepest_path = parse_saved_path(output) or ilp_path
                        else:
                            print("WARNING: steepest repair failed for", ilp_path)

                        code, output, beam_elapsed = run_beam(steepest_path)
                        if code == 0:
                            beam_path = parse_saved_path(output) or steepest_path
                        else:
                            print("WARNING: beam repair failed for", steepest_path)
                    else:
                        code, output, beam_elapsed = run_beam(ilp_path)
                        if code == 0:
                            beam_path = parse_saved_path(output) or ilp_path
                        else:
                            print("WARNING: beam repair failed for", ilp_path)

                        code, output, steepest_elapsed = run_steepest(beam_path)
                        if code == 0:
                            steepest_path = parse_saved_path(output) or beam_path
                        else:
                            print("WARNING: steepest repair failed for", beam_path)

                final_path = beam_path
                if args.post_ilp_order == "beam_then_steepest":
                    final_path = steepest_path
                info = register_frontier(
                    final_path,
                    args.frontier_dir,
                    "loop{}_candidate{}".format(loop_index, candidate_idx + 1),
                )
                metrics = info.get("metrics")
                if metrics is None:
                    _, _, _, _, _, metrics = candidate_metrics(final_path)

                row = {
                    "timestamp": timestamp(),
                    "loop": loop_index,
                    "candidate": candidate,
                    "objective": objective,
                    "acceptance": acceptance,
                    "ilp_path": ilp_path,
                    "steepest_path": steepest_path,
                    "beam_path": beam_path,
                    "final_path": final_path,
                    "final_score": int(metrics[0]),
                    "final_l1_error": int(metrics[1]),
                    "final_max_abs_error": int(metrics[2]),
                    "final_nonzero_defect_count": int(metrics[3]),
                    "pareto_active": bool(info.get("pareto_active", False)),
                    "frontier_count": int(info.get("frontier_count", 0)),
                    "selected_moves_count": int(selected_moves_count),
                    "tabu_enabled": bool(tabu_enabled),
                    "post_ilp_order": args.post_ilp_order,
                    "beam_depth": int(args.beam_depth),
                    "rank_mode": args.beam_rank_mode,
                    "frontier_select": args.frontier_select,
                    "ilp_elapsed_sec": float(ilp_elapsed),
                    "steepest_elapsed_sec": float(steepest_elapsed),
                    "beam_elapsed_sec": float(beam_elapsed),
                }
                writer.writerow(row)
                csv_file.flush()
                print("BATCH_ROW:", row)

        print("\nDONE: frontier repair batch complete")
        print("frontier index:", os.path.join(args.frontier_dir, "frontier_index.json"))
    finally:
        if csv_file is not None:
            csv_file.close()
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
