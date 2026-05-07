from sage.all import *

import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
import time


DEFAULT_EXPLORATION_SUFFIX = "hadamard668_low_nonzero_shallow_repair"
DEFAULT_FRONTIER = "outputs/candidates/near_hits/frontier/frontier_index.json"


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def timestamp():
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def write_json(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)


def read_json(path):
    with open(path) as f:
        return json.load(f)


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def parse_int_list(value):
    out = []
    for item in value.split(","):
        item = item.strip()
        if item:
            out.append(int(item))
    return out


def parse_str_list(value):
    return [item.strip() for item in value.split(",") if item.strip()]


def metric_tuple(record):
    return (
        int(record["score"]),
        int(record["l1_error"]),
        int(record["max_abs_error"]),
        int(record["nonzero_defect_count"]),
    )


def format_metrics(record):
    return "{} {} {} {}".format(
        int(record["score"]),
        int(record["l1_error"]),
        int(record["max_abs_error"]),
        int(record["nonzero_defect_count"]),
    )


def load_frontier_records(index_path):
    data = read_json(index_path)
    return data.get("records", [])


def ensure_exploration_tree(exploration_dir):
    dirs = [
        "",
        "raw",
        "logs",
        "review",
        "raw/frontiers",
        "raw/run_outputs",
    ]
    for rel in dirs:
        os.makedirs(os.path.join(exploration_dir, rel), exist_ok=True)


def copy_frontier_seed(source_index, target_dir):
    os.makedirs(target_dir, exist_ok=True)
    shutil.copy2(source_index, os.path.join(target_dir, "frontier_index.json"))


def make_initial_docs(exploration_dir, exploration_id, args, records):
    sorted_records = sorted(records, key=metric_tuple)
    frontier_lines = [
        "# Current Frontier Snapshot",
        "",
        "This is a diagnostic near-hit frontier. None of these entries is a verified Hadamard 668 construction.",
        "",
        "| score | l1 | max | nonzero | ks | lambda | source |",
        "|---:|---:|---:|---:|---|---:|---|",
    ]
    for rec in sorted_records:
        frontier_lines.append(
            "| {} | {} | {} | {} | {} | {} | `{}` |".format(
                int(rec["score"]),
                int(rec["l1_error"]),
                int(rec["max_abs_error"]),
                int(rec["nonzero_defect_count"]),
                rec["ks"],
                int(rec["lambda"]),
                rec.get("source_path", rec.get("path", "")),
            )
        )

    target_payload = {
        "branch_a_score_best": None,
        "branch_b_low_nonzero": None,
        "branch_c_max_abs": [],
    }
    if sorted_records:
        target_payload["branch_a_score_best"] = sorted(
            records,
            key=lambda r: (
                int(r["score"]),
                int(r["l1_error"]),
                int(r["max_abs_error"]),
                int(r["nonzero_defect_count"]),
            ),
        )[0]
        target_payload["branch_b_low_nonzero"] = sorted(
            records,
            key=lambda r: (
                int(r["nonzero_defect_count"]),
                int(r["l1_error"]),
                int(r["score"]),
                int(r["max_abs_error"]),
            ),
        )[0]
        target_payload["branch_c_max_abs"] = [
            r for r in records if int(r["max_abs_error"]) == 2
        ]

    target_lines = [
        "# Target Branches",
        "",
        "Branch A is the best-score branch. Branch B is the low-nonzero branch. Branch C contains max_abs=2 branches.",
        "",
    ]
    a = target_payload["branch_a_score_best"]
    b = target_payload["branch_b_low_nonzero"]
    if a:
        target_lines.append(
            "## Branch A: Score-Best\n\nmetrics=`{}` ks={} lambda={} path=`{}`\n".format(
                format_metrics(a), a["ks"], int(a["lambda"]), a.get("source_path", "")
            )
        )
    if b:
        target_lines.append(
            "## Branch B: Low-Nonzero\n\nmetrics=`{}` ks={} lambda={} path=`{}`\n".format(
                format_metrics(b), b["ks"], int(b["lambda"]), b.get("source_path", "")
            )
        )
    target_lines.append("## Branch C: Max-Abs\n")
    for rec in target_payload["branch_c_max_abs"]:
        target_lines.append(
            "- metrics=`{}` ks={} lambda={} path=`{}`".format(
                format_metrics(rec), rec["ks"], int(rec["lambda"]), rec.get("source_path", "")
            )
        )

    config = {
        "exploration_id": exploration_id,
        "created_at": timestamp(),
        "suite": args.suite,
        "weights": parse_int_list(args.weights),
        "pool_modes": parse_str_list(args.pool_modes),
        "pool_weights": parse_int_list(args.pool_weights),
        "loops": int(args.loops),
        "pool_size": int(args.pool_size),
        "max_moves": int(args.max_moves),
        "beam_width": int(args.beam_width),
        "beam_depth": int(args.beam_depth),
        "beam_rounds": int(args.beam_rounds),
        "steepest_max_rounds": int(args.steepest_max_rounds),
        "max_candidates_per_loop": int(args.max_candidates_per_loop),
        "ilp_time_limit": int(args.ilp_time_limit),
        "isolated_frontier": True,
    }
    write_json(os.path.join(exploration_dir, "raw", "shallow_ab_config.json"), config)
    write_json(os.path.join(exploration_dir, "raw", "target_branches.json"), target_payload)

    plan = """# Experiment Plan

This exploration performs a shallow-wide repair screen around the current n=668 SDS near-hit frontier.

The previous strong zero-protect run used weight 100000 and repeatedly selected no moves on the low-nonzero branch. This suggests the objective over-protected zero-defect shifts and created fixed points. The current plan lowers the zero-protect weight and compares low_nonzero, mixed, and diverse move pools.

Adoption criteria:

- frontier expands in an isolated run
- score < 164
- l1_error < 112
- nonzero_defect_count < 80
- max_abs_error = 2 with better l1
- selected_moves_count > 0 and the post-ILP repair does not immediately undo the branch change

Failure criteria:

- selected_moves_count = 0 dominates
- no isolated frontier growth
- ILP changes are dominated after beam/steepest
- zero-shift damage increases nonzero without improving l1 or score
- pool modes are indistinguishable

Success safety:

score=0 is not enough. A success candidate must pass exact SDS verification and exact Goethals-Seidel HH^T = 668I over ZZ.
"""
    readme = """# {exploration_id}

Hadamard 668 SDS low-nonzero shallow-wide repair exploration.

This folder contains diagnostic exploration logs and reports. It does not claim a Hadamard 668 construction unless a candidate has `verify_sds=true`, `generated_hadamard=true`, and `hh_t=true`.
""".format(exploration_id=exploration_id)

    write_text(os.path.join(exploration_dir, "README.md"), readme)
    write_text(os.path.join(exploration_dir, "experiment_plan.md"), plan)
    write_text(os.path.join(exploration_dir, "current_frontier_snapshot.md"), "\n".join(frontier_lines) + "\n")
    write_text(os.path.join(exploration_dir, "target_branches.md"), "\n".join(target_lines) + "\n")
    write_text(os.path.join(exploration_dir, "review", "README.md"), readme)
    write_text(os.path.join(exploration_dir, "review", "01_experiment_plan.md"), plan)
    write_text(os.path.join(exploration_dir, "review", "02_current_frontier.md"), "\n".join(frontier_lines) + "\n")


def parse_run_paths(output):
    log_match = re.findall(r"Log:\s*(outputs/logs/[^\s]+)", output)
    csv_match = re.findall(r"CSV log:\s*(outputs/logs/[^\s]+)", output)
    front_logs = [path for path in log_match if "14_frontier_repair_batch_" in path]
    front_csvs = [path for path in csv_match if "14_frontier_repair_batch_" in path]
    return {
        "log_path": front_logs[0] if front_logs else (log_match[0] if log_match else ""),
        "csv_path": front_csvs[0] if front_csvs else (csv_match[0] if csv_match else ""),
    }


def run_child(cmd, env, run_stdout_path):
    start = time.time()
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        universal_newlines=True,
        env=env,
        bufsize=int(1),
    )
    lines = []
    with open(run_stdout_path, "w") as out:
        for line in proc.stdout:
            out.write(line)
            lines.append(line.rstrip("\n"))
    code = proc.wait()
    return code, "\n".join(lines), time.time() - start


def build_runs(args):
    runs = []
    if args.suite in ("all", "weight_sweep"):
        for weight in parse_int_list(args.weights):
            runs.append(
                {
                    "suite": "weight_sweep",
                    "pool_mode": "low_nonzero",
                    "zero_protect_weight": int(weight),
                    "objective_plan": "l1:l1_then_score,score_zero_protect:lex,score_then_l1:lex",
                }
            )
    if args.suite in ("all", "pool_comparison"):
        for mode in parse_str_list(args.pool_modes):
            for weight in parse_int_list(args.pool_weights):
                runs.append(
                    {
                        "suite": "pool_comparison",
                        "pool_mode": mode,
                        "zero_protect_weight": int(weight),
                        "objective_plan": "l1:l1_then_score,score_then_l1:lex",
                    }
                )
    return runs


def write_run_log_header(path, exploration_id, args):
    text = [
        "# Run Log",
        "",
        "- exploration_id: `{}`".format(exploration_id),
        "- started_at: `{}`".format(timestamp()),
        "- cwd: `{}`".format(os.getcwd()),
        "- sage_bin: `{}`".format(args.sage_bin),
        "- DOT_SAGE: `{}`".format(os.environ.get("DOT_SAGE", "")),
        "- suite: `{}`".format(args.suite),
        "- .sage.py cleanup: pending",
        "",
    ]
    write_text(path, "\n".join(text))


def append_text(path, text):
    with open(path, "a") as f:
        f.write(text)


def main():
    parser = argparse.ArgumentParser(
        description="Run shallow-wide repair A/B experiments using 14_frontier_repair_batch."
    )
    parser.add_argument("--exploration-id", default="")
    parser.add_argument("--suite", choices=["all", "weight_sweep", "pool_comparison"], default="all")
    parser.add_argument("--weights", default="3000,1000,300,100,0")
    parser.add_argument("--pool-modes", default="low_nonzero,mixed,diverse")
    parser.add_argument("--pool-weights", default="1000,300,100,0")
    parser.add_argument("--loops", type=int, default=2)
    parser.add_argument("--pool-size", type=int, default=160)
    parser.add_argument("--max-moves", type=int, default=6)
    parser.add_argument("--beam-width", type=int, default=80)
    parser.add_argument("--beam-depth", type=int, choices=[1, 2, 3], default=3)
    parser.add_argument("--beam-rounds", type=int, default=1)
    parser.add_argument("--beam-rank-mode", default="mixed")
    parser.add_argument("--steepest-max-rounds", type=int, default=3)
    parser.add_argument("--frontier-select", default="mixed")
    parser.add_argument("--post-ilp-order", default="beam_then_steepest")
    parser.add_argument("--tabu-tenure", type=int, default=3)
    parser.add_argument("--max-candidates-per-loop", type=int, default=3)
    parser.add_argument("--residual-bound", type=int, default=8)
    parser.add_argument("--ilp-time-limit", type=int, default=0)
    parser.add_argument("--frontier-index", default=DEFAULT_FRONTIER)
    parser.add_argument("--sage-bin", default=os.environ.get("SAGE_BINARY", "sage"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    exploration_id = args.exploration_id.strip()
    if not exploration_id:
        exploration_id = "{}_{}".format(now_stamp(), DEFAULT_EXPLORATION_SUFFIX)
    exploration_dir = os.path.join("outputs", "explorations", exploration_id)
    ensure_exploration_tree(exploration_dir)

    records = load_frontier_records(args.frontier_index)
    write_json(
        os.path.join(exploration_dir, "raw", "current_frontier_snapshot.json"),
        {"timestamp": timestamp(), "records": records},
    )
    write_json(
        os.path.join(exploration_dir, "raw", "current_frontier_snapshot_before.json"),
        {"timestamp": timestamp(), "records": records},
    )
    make_initial_docs(exploration_dir, exploration_id, args, records)

    run_log_path = os.path.join(exploration_dir, "run_log.md")
    write_run_log_header(run_log_path, exploration_id, args)

    runs = build_runs(args)
    manifest = {
        "exploration_id": exploration_id,
        "exploration_dir": exploration_dir,
        "started_at": timestamp(),
        "frontier_index": args.frontier_index,
        "runs": [],
    }
    manifest_path = os.path.join(exploration_dir, "raw", "run_manifest.json")
    write_json(manifest_path, manifest)

    env = os.environ.copy()
    env.setdefault("DOT_SAGE", os.path.join(os.environ.get("TMPDIR", "/tmp"), "sage-dot"))

    for idx, run in enumerate(runs, start=1):
        run_id = "{:02d}_{}_{}_w{}".format(
            idx, run["suite"], run["pool_mode"], run["zero_protect_weight"]
        )
        run_frontier_dir = os.path.join(exploration_dir, "raw", "frontiers", run_id)
        copy_frontier_seed(args.frontier_index, run_frontier_dir)
        run_stdout_path = os.path.join(exploration_dir, "raw", "run_outputs", run_id + ".stdout.log")

        cmd = [
            args.sage_bin,
            os.path.join("sage", "14_frontier_repair_batch.sage"),
            "--loops",
            str(args.loops),
            "--pool-size",
            str(args.pool_size),
            "--pool-mode",
            run["pool_mode"],
            "--max-moves",
            str(args.max_moves),
            "--objective-plan",
            run["objective_plan"],
            "--zero-protect-weight",
            str(run["zero_protect_weight"]),
            "--beam-width",
            str(args.beam_width),
            "--beam-depth",
            str(args.beam_depth),
            "--beam-rank-mode",
            args.beam_rank_mode,
            "--beam-rounds",
            str(args.beam_rounds),
            "--steepest-max-rounds",
            str(args.steepest_max_rounds),
            "--frontier-select",
            args.frontier_select,
            "--post-ilp-order",
            args.post_ilp_order,
            "--tabu-after-ilp",
            "--no-reversal",
            "--tabu-tenure",
            str(args.tabu_tenure),
            "--residual-bound",
            str(args.residual_bound),
            "--frontier-dir",
            run_frontier_dir,
        ]
        if args.ilp_time_limit > 0:
            cmd.extend(["--ilp-time-limit", str(args.ilp_time_limit)])
        if args.max_candidates_per_loop > 0:
            cmd.extend(["--max-candidates-per-loop", str(args.max_candidates_per_loop)])

        append_text(
            run_log_path,
            "\n## {}\n\n```bash\n{}\n```\n\n".format(run_id, " ".join(cmd)),
        )
        print("\n=== RUN {} / {}: {} ===".format(idx, len(runs), run_id))
        print(" ".join(cmd))
        sys.stdout.flush()

        if args.dry_run:
            code, output, elapsed = 0, "", 0.0
            paths = {"log_path": "", "csv_path": ""}
        else:
            code, output, elapsed = run_child(cmd, env, run_stdout_path)
            paths = parse_run_paths(output)

        record = {
            "run_id": run_id,
            "suite": run["suite"],
            "pool_mode": run["pool_mode"],
            "zero_protect_weight": int(run["zero_protect_weight"]),
            "objective_plan": run["objective_plan"],
            "command": cmd,
            "returncode": int(code),
            "elapsed_sec": float(elapsed),
            "stdout_path": run_stdout_path,
            "frontier_dir": run_frontier_dir,
            "frontier_index": os.path.join(run_frontier_dir, "frontier_index.json"),
            "log_path": paths["log_path"],
            "csv_path": paths["csv_path"],
        }
        manifest["runs"].append(record)
        write_json(manifest_path, manifest)
        append_text(
            run_log_path,
            "- returncode: `{}`\n- elapsed_sec: `{:.2f}`\n- csv: `{}`\n- log: `{}`\n".format(
                code, elapsed, paths["csv_path"], paths["log_path"]
            ),
        )
        if code != 0:
            print("WARNING: run failed:", run_id)
        else:
            print(
                "completed {} elapsed_sec={:.2f} csv={}".format(
                    run_id, elapsed, paths["csv_path"]
                )
            )
        sys.stdout.flush()

    manifest["finished_at"] = timestamp()
    write_json(manifest_path, manifest)
    append_text(run_log_path, "\nFinished at `{}`.\n".format(timestamp()))
    print("DONE: shallow A/B repair batch")
    print("exploration_id:", exploration_id)
    print("manifest:", manifest_path)


if __name__ == "__main__":
    main()
