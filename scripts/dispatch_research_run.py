#!/usr/bin/env python3
import argparse
import os
import shlex
import subprocess
from pathlib import Path


PRESETS = {
    "rust-smoke": {
        "engine": "rust",
        "config": "configs/experiments/p167_tuple_A_actions_smoke.yaml",
        "run_label": "p167-rust-smoke",
        "seeds": "1",
        "steps": "1",
        "candidates_per_family": "1",
        "selected_per_family": "1",
        "artifact_retention_days": "7",
    },
    "fanout-20": {
        "engine": "rust",
        "config": "configs/experiments/p167_tuple_A_rust_production.yaml",
        "run_label": "p167-rust-20x",
        "total_seeds": "200",
        "shard_count": "20",
        "max_parallel": "20",
        "steps": "10000",
        "artifact_retention_days": "30",
    },
    "production-40": {
        "engine": "rust",
        "config": "configs/experiments/p167_tuple_A_rust_production.yaml",
        "run_label": "p167-rust-40x",
        "total_seeds": "400",
        "shard_count": "40",
        "max_parallel": "40",
        "steps": "10000",
        "artifact_retention_days": "30",
    },
    "rerun-shard": {
        "engine": "rust",
        "config": "configs/experiments/p167_tuple_A_rust_production.yaml",
        "run_label": "p167-rust-rerun",
        "total_seeds": "400",
        "shard_count": "40",
        "max_parallel": "1",
        "steps": "10000",
        "artifact_retention_days": "30",
    },
}


INPUT_ORDER = [
    "run_label",
    "engine",
    "config",
    "seeds",
    "seed_start",
    "seed_count",
    "total_seeds",
    "shard_count",
    "shard_index",
    "max_parallel",
    "steps",
    "snapshot_interval",
    "candidates_per_family",
    "selected_per_family",
    "max_repair_candidates",
    "artifact_retention_days",
]


def positive_int(value, name):
    if value is None or value == "":
        return None
    try:
        parsed = int(value)
    except ValueError:
        raise ValueError("{} must be an integer".format(name))
    if parsed < 1:
        raise ValueError("{} must be positive".format(name))
    return parsed


def nonnegative_int(value, name):
    if value is None or value == "":
        return None
    try:
        parsed = int(value)
    except ValueError:
        raise ValueError("{} must be an integer".format(name))
    if parsed < 0:
        raise ValueError("{} must be non-negative".format(name))
    return parsed


def apply_overrides(values, args):
    overrides = {
        "run_label": args.run_label,
        "engine": args.engine,
        "config": args.config,
        "seeds": args.seeds,
        "seed_start": args.seed_start,
        "seed_count": args.seed_count,
        "total_seeds": args.total_seeds,
        "shard_count": args.shard_count,
        "shard_index": args.shard_index,
        "max_parallel": args.max_parallel,
        "steps": args.steps,
        "snapshot_interval": args.snapshot_interval,
        "candidates_per_family": args.candidates_per_family,
        "selected_per_family": args.selected_per_family,
        "max_repair_candidates": args.max_repair_candidates,
        "artifact_retention_days": args.artifact_retention_days,
    }
    for key, value in overrides.items():
        if value is not None:
            values[key] = str(value)
    if args.run_label_suffix:
        values["run_label"] = "{}-{}".format(values["run_label"], args.run_label_suffix)
    return values


def validate(values, preset):
    config = values.get("config", "")
    if not config.startswith("configs/experiments/") or not config.endswith(".yaml"):
        raise ValueError("config must be under configs/experiments/*.yaml")
    if not Path(config).is_file():
        raise ValueError("config does not exist: {}".format(config))

    engine = values.get("engine")
    if engine not in ("sage", "rust"):
        raise ValueError("engine must be sage or rust")

    total_seeds = positive_int(values.get("total_seeds"), "total_seeds")
    shard_count = positive_int(values.get("shard_count"), "shard_count")
    shard_index = nonnegative_int(values.get("shard_index"), "shard_index")
    max_parallel = positive_int(values.get("max_parallel"), "max_parallel")
    positive_int(values.get("seeds"), "seeds")
    positive_int(values.get("seed_count"), "seed_count")
    nonnegative_int(values.get("seed_start"), "seed_start")
    positive_int(values.get("steps"), "steps")
    retention_days = positive_int(values.get("artifact_retention_days"), "artifact_retention_days")
    if retention_days is not None and retention_days > 90:
        raise ValueError("artifact_retention_days must be 1-90")

    if preset == "rerun-shard" and shard_index is None:
        raise ValueError("rerun-shard requires --shard-index")
    if shard_index is not None and shard_count is None:
        raise ValueError("shard_index requires shard_count")
    if shard_count is not None and total_seeds is not None and total_seeds < shard_count:
        raise ValueError("total_seeds must be greater than or equal to shard_count")
    if shard_index is not None and shard_count is not None and shard_index >= shard_count:
        raise ValueError("shard_index must satisfy 0 <= shard_index < shard_count")
    if max_parallel is not None and shard_count is not None and max_parallel > shard_count:
        raise ValueError("max_parallel should not exceed shard_count")


def build_command(args, values):
    command = [
        "gh",
        "workflow",
        "run",
        "research.yml",
        "--repo",
        args.repo,
        "--ref",
        args.ref,
    ]
    for key in INPUT_ORDER:
        value = values.get(key)
        if value is not None and str(value) != "":
            command.extend(["-f", "{}={}".format(key, value)])
    return command


def printable(command):
    return "env -u GITHUB_TOKEN " + " ".join(shlex.quote(part) for part in command)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Build or dispatch validated GitHub Actions research runs."
    )
    parser.add_argument("--preset", choices=sorted(PRESETS), default="rust-smoke")
    parser.add_argument("--repo", default="rikumatsudo/hadamard-search")
    parser.add_argument("--ref", default="main")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--run-label")
    parser.add_argument("--run-label-suffix")
    parser.add_argument("--engine", choices=("sage", "rust"))
    parser.add_argument("--config")
    parser.add_argument("--seeds")
    parser.add_argument("--seed-start")
    parser.add_argument("--seed-count")
    parser.add_argument("--total-seeds")
    parser.add_argument("--shard-count")
    parser.add_argument("--shard-index")
    parser.add_argument("--max-parallel")
    parser.add_argument("--steps")
    parser.add_argument("--snapshot-interval")
    parser.add_argument("--candidates-per-family")
    parser.add_argument("--selected-per-family")
    parser.add_argument("--max-repair-candidates")
    parser.add_argument("--artifact-retention-days")
    return parser.parse_args()


def main():
    args = parse_args()
    values = apply_overrides(dict(PRESETS[args.preset]), args)
    try:
        validate(values, args.preset)
    except ValueError as exc:
        raise SystemExit("error: {}".format(exc))

    command = build_command(args, values)
    print(printable(command))
    if not args.execute:
        print("# dry-run only; add --execute to dispatch")
        return 0

    env = dict(os.environ)
    env.pop("GITHUB_TOKEN", None)
    return subprocess.call(command, env=env)


if __name__ == "__main__":
    raise SystemExit(main())
