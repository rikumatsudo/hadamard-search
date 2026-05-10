#!/usr/bin/env python3
import argparse
import os
import shlex
import subprocess
from pathlib import Path


WORKFLOW = "p167-broad-tuple-stage1-scan.yml"


PRESETS = {
    "remote-smoke": {
        "run_label": "p167-broad-stage1-smoke",
        "config": "configs/experiments/p167_broad_tuple_stage1_scan.yaml",
        "tuple_registry": "configs/fixtures/p167_tuple_classes.json",
        "benchmark_trap_manifest": "configs/fixtures/benchmark_traps/p167_score164_176.jsonl",
        "seed_families": "pure_random",
        "operators": "baseline_score_only",
        "benchmark_trap_limit": "0",
        "benchmark_trap_operators": "baseline_score_only",
        "restarts": "1",
        "steps": "1",
        "sample_swaps": "5",
        "diagnostic_sample_count": "5",
        "snapshot_attempted_steps": "0,1",
        "snapshot_accepted_moves": "0,1",
        "mixed_diversity_pool": "2",
        "high_resolution_logging": "false",
        "highres_followup_accepted_moves": "50",
        "max_tasks": "1",
        "shard_count": "1",
        "max_parallel": "1",
        "stage_name": "p167_stage1",
        "stage2_survivor_limit": "10",
        "artifact_retention_days": "14",
    },
    "stage1-lite-40": {
        "run_label": "p167-broad-stage1-lite-40x",
        "config": "configs/experiments/p167_broad_tuple_stage1_scan.yaml",
        "tuple_registry": "configs/fixtures/p167_tuple_classes.json",
        "benchmark_trap_manifest": "configs/fixtures/benchmark_traps/p167_score164_176.jsonl",
        "seed_families": "pure_random,mixed_diversity,score_biased_random,closure_shell_biased",
        "operators": "baseline_score_only,random_walk_score_guarded,focused_plus_small_threshold,hybrid_pair_repair_to_closure_shell,pair_profile_plus_movespace_filter,mixed_operator_random",
        "benchmark_trap_limit": "7",
        "benchmark_trap_operators": "baseline_score_only,random_walk_score_guarded,hybrid_pair_repair_to_closure_shell",
        "restarts": "2",
        "steps": "300",
        "sample_swaps": "200",
        "diagnostic_sample_count": "200",
        "snapshot_attempted_steps": "0,25,50,100,200,300,500",
        "snapshot_accepted_moves": "0,25,50,100,200",
        "mixed_diversity_pool": "6",
        "high_resolution_logging": "true",
        "highres_followup_accepted_moves": "50",
        "max_tasks": "0",
        "shard_count": "40",
        "max_parallel": "40",
        "stage_name": "p167_stage1",
        "stage2_survivor_limit": "50",
        "artifact_retention_days": "30",
    },
    "stage1-full-40": {
        "run_label": "p167-broad-stage1-full-40x",
        "config": "configs/experiments/p167_broad_tuple_stage1_scan.yaml",
        "tuple_registry": "configs/fixtures/p167_tuple_classes.json",
        "benchmark_trap_manifest": "configs/fixtures/benchmark_traps/p167_score164_176.jsonl",
        "seed_families": "pure_random,mixed_diversity,score_biased_random,pair_profile_biased,closure_shell_biased,trap_avoid",
        "operators": "baseline_score_only,random_walk_score_guarded,focused_plus_small_threshold,hybrid_pair_repair_to_closure_shell,pair_profile_plus_movespace_filter,mixed_operator_random",
        "benchmark_trap_limit": "7",
        "benchmark_trap_operators": "baseline_score_only,random_walk_score_guarded,hybrid_pair_repair_to_closure_shell",
        "restarts": "3",
        "steps": "500",
        "sample_swaps": "300",
        "diagnostic_sample_count": "300",
        "snapshot_attempted_steps": "0,25,50,100,200,300,500",
        "snapshot_accepted_moves": "0,25,50,100,200",
        "mixed_diversity_pool": "8",
        "high_resolution_logging": "true",
        "highres_followup_accepted_moves": "50",
        "max_tasks": "0",
        "shard_count": "40",
        "max_parallel": "40",
        "stage_name": "p167_stage1",
        "stage2_survivor_limit": "100",
        "artifact_retention_days": "30",
    },
}


INPUT_ORDER = [
    "run_label",
    "config",
    "tuple_registry",
    "benchmark_trap_manifest",
    "seed_families",
    "operators",
    "benchmark_trap_limit",
    "benchmark_trap_operators",
    "restarts",
    "steps",
    "sample_swaps",
    "diagnostic_sample_count",
    "snapshot_attempted_steps",
    "snapshot_accepted_moves",
    "mixed_diversity_pool",
    "high_resolution_logging",
    "highres_followup_accepted_moves",
    "max_tasks",
    "shard_count",
    "max_parallel",
    "stage_name",
    "stage2_survivor_limit",
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


def parse_bool(value, name):
    if str(value).lower() not in ("true", "false"):
        raise ValueError("{} must be true or false".format(name))
    return str(value).lower()


def apply_overrides(values, args):
    overrides = {
        "run_label": args.run_label,
        "config": args.config,
        "tuple_registry": args.tuple_registry,
        "benchmark_trap_manifest": args.benchmark_trap_manifest,
        "seed_families": args.seed_families,
        "operators": args.operators,
        "benchmark_trap_limit": args.benchmark_trap_limit,
        "benchmark_trap_operators": args.benchmark_trap_operators,
        "restarts": args.restarts,
        "steps": args.steps,
        "sample_swaps": args.sample_swaps,
        "diagnostic_sample_count": args.diagnostic_sample_count,
        "snapshot_attempted_steps": args.snapshot_attempted_steps,
        "snapshot_accepted_moves": args.snapshot_accepted_moves,
        "mixed_diversity_pool": args.mixed_diversity_pool,
        "high_resolution_logging": args.high_resolution_logging,
        "highres_followup_accepted_moves": args.highres_followup_accepted_moves,
        "max_tasks": args.max_tasks,
        "shard_count": args.shard_count,
        "max_parallel": args.max_parallel,
        "stage_name": args.stage_name,
        "stage2_survivor_limit": args.stage2_survivor_limit,
        "artifact_retention_days": args.artifact_retention_days,
    }
    for key, value in overrides.items():
        if value is not None:
            values[key] = str(value)
    if args.run_label_suffix:
        values["run_label"] = "{}-{}".format(values["run_label"], args.run_label_suffix)
    return values


def validate_path(value, name):
    if not value:
        raise ValueError("{} is required".format(name))
    if ".." in Path(value).parts:
        raise ValueError("{} must not contain '..'".format(name))
    if not Path(value).is_file():
        raise ValueError("{} does not exist: {}".format(name, value))


def validate(values):
    validate_path(values.get("config"), "config")
    validate_path(values.get("tuple_registry"), "tuple_registry")
    validate_path(values.get("benchmark_trap_manifest"), "benchmark_trap_manifest")
    nonnegative_int(values.get("benchmark_trap_limit"), "benchmark_trap_limit")
    positive_int(values.get("restarts"), "restarts")
    positive_int(values.get("steps"), "steps")
    positive_int(values.get("sample_swaps"), "sample_swaps")
    positive_int(values.get("diagnostic_sample_count"), "diagnostic_sample_count")
    positive_int(values.get("mixed_diversity_pool"), "mixed_diversity_pool")
    positive_int(values.get("highres_followup_accepted_moves"), "highres_followup_accepted_moves")
    nonnegative_int(values.get("max_tasks"), "max_tasks")
    positive_int(values.get("stage2_survivor_limit"), "stage2_survivor_limit")
    shard_count = positive_int(values.get("shard_count"), "shard_count")
    max_parallel = positive_int(values.get("max_parallel"), "max_parallel")
    retention_days = positive_int(values.get("artifact_retention_days"), "artifact_retention_days")
    if max_parallel is not None and shard_count is not None and max_parallel > shard_count:
        raise ValueError("max_parallel should not exceed shard_count")
    if retention_days is not None and retention_days > 90:
        raise ValueError("artifact_retention_days must be 1-90")
    values["high_resolution_logging"] = parse_bool(values.get("high_resolution_logging"), "high_resolution_logging")


def build_command(args, values):
    command = [
        "gh",
        "workflow",
        "run",
        WORKFLOW,
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
    parser = argparse.ArgumentParser(description="Build or dispatch p167 broad tuple Stage 1 scan runs.")
    parser.add_argument("--preset", choices=sorted(PRESETS), default="remote-smoke")
    parser.add_argument("--repo", default="rikumatsudo/hadamard-search")
    parser.add_argument("--ref", default="main")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--run-label")
    parser.add_argument("--run-label-suffix")
    parser.add_argument("--config")
    parser.add_argument("--tuple-registry")
    parser.add_argument("--benchmark-trap-manifest")
    parser.add_argument("--seed-families")
    parser.add_argument("--operators")
    parser.add_argument("--benchmark-trap-limit")
    parser.add_argument("--benchmark-trap-operators")
    parser.add_argument("--restarts")
    parser.add_argument("--steps")
    parser.add_argument("--sample-swaps")
    parser.add_argument("--diagnostic-sample-count")
    parser.add_argument("--snapshot-attempted-steps")
    parser.add_argument("--snapshot-accepted-moves")
    parser.add_argument("--mixed-diversity-pool")
    parser.add_argument("--high-resolution-logging")
    parser.add_argument("--highres-followup-accepted-moves")
    parser.add_argument("--max-tasks")
    parser.add_argument("--shard-count")
    parser.add_argument("--max-parallel")
    parser.add_argument("--stage-name")
    parser.add_argument("--stage2-survivor-limit")
    parser.add_argument("--artifact-retention-days")
    return parser.parse_args()


def main():
    args = parse_args()
    values = apply_overrides(dict(PRESETS[args.preset]), args)
    try:
        validate(values)
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
