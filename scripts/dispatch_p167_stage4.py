#!/usr/bin/env python3
import argparse
import shlex
import subprocess
from pathlib import Path


WORKFLOW = "p167-stage4-candidate-deepening.yml"


PRESETS = {
    "remote-smoke": {
        "run_label": "p167-stage4-smoke",
        "config": "configs/experiments/p167_stage4_candidate_deepening.yaml",
        "stage3_run_id": "25632651179",
        "stage3_artifact_name": "p167-stage3-summary-aggregate-25632651179",
        "operators": "stage4_pair_profile_movespace_filter",
        "production_candidate_limit": "0",
        "guarded_repair_limit": "0",
        "repair_target_limit": "1",
        "operator_benchmark_limit": "0",
        "needs_more_diagnostics_limit": "0",
        "archive_limit": "0",
        "total_candidate_limit": "1",
        "production_restarts": "1",
        "repair_restarts": "1",
        "benchmark_restarts": "1",
        "diagnostic_restarts": "1",
        "baseline_restarts": "0",
        "steps": "1",
        "sample_swaps": "5",
        "diagnostic_sample_count": "5",
        "snapshot_attempted_steps": "0,1",
        "snapshot_accepted_moves": "0,1",
        "high_resolution_logging": "false",
        "artifact_mode": "summary_only",
        "snapshot_log_mode": "summary_only",
        "operator_reward_log_mode": "topk",
        "operator_reward_topk": "5",
        "max_tasks": "1",
        "shard_count": "1",
        "max_parallel": "1",
        "stage5_candidate_limit": "5",
    },
    "stage4-medium-40": {
        "run_label": "p167-stage4-medium-40x",
        "config": "configs/experiments/p167_stage4_candidate_deepening.yaml",
        "stage3_run_id": "25632774795",
        "stage3_artifact_name": "p167-stage3-summary-aggregate-25632774795",
        "operators": "stage4_mixed_operator_adaptive,stage4_exact_joint_local_repair,stage4_pair_profile_movespace_filter,stage4_baseline_score_only",
        "production_candidate_limit": "8",
        "guarded_repair_limit": "4",
        "repair_target_limit": "4",
        "operator_benchmark_limit": "2",
        "needs_more_diagnostics_limit": "1",
        "archive_limit": "0",
        "total_candidate_limit": "13",
        "production_restarts": "12",
        "repair_restarts": "8",
        "benchmark_restarts": "4",
        "diagnostic_restarts": "4",
        "baseline_restarts": "2",
        "steps": "5000",
        "sample_swaps": "500",
        "diagnostic_sample_count": "500",
        "snapshot_attempted_steps": "0,100,250,500,1000,2500,5000",
        "snapshot_accepted_moves": "0,50,100,250,500,1000",
        "high_resolution_logging": "true",
        "artifact_mode": "summary_only",
        "snapshot_log_mode": "summary_only",
        "operator_reward_log_mode": "topk",
        "operator_reward_topk": "50",
        "max_tasks": "0",
        "shard_count": "40",
        "max_parallel": "40",
        "stage5_candidate_limit": "20",
    },
}


INPUT_ORDER = [
    "run_label",
    "config",
    "stage3_run_id",
    "stage3_artifact_name",
    "operators",
    "production_candidate_limit",
    "guarded_repair_limit",
    "repair_target_limit",
    "operator_benchmark_limit",
    "needs_more_diagnostics_limit",
    "archive_limit",
    "total_candidate_limit",
    "production_restarts",
    "repair_restarts",
    "benchmark_restarts",
    "diagnostic_restarts",
    "baseline_restarts",
    "steps",
    "sample_swaps",
    "diagnostic_sample_count",
    "snapshot_attempted_steps",
    "snapshot_accepted_moves",
    "high_resolution_logging",
    "artifact_mode",
    "snapshot_log_mode",
    "operator_reward_log_mode",
    "operator_reward_topk",
    "max_tasks",
    "shard_count",
    "max_parallel",
    "stage5_candidate_limit",
]


def validate_path(value, name):
    if not value:
        raise ValueError("{} is required".format(name))
    if ".." in Path(value).parts:
        raise ValueError("{} must not contain '..'".format(name))
    if not Path(value).is_file():
        raise ValueError("{} does not exist: {}".format(name, value))


def positive_int(value, name):
    parsed = int(value)
    if parsed < 1:
        raise ValueError("{} must be positive".format(name))
    return parsed


def nonnegative_int(value, name):
    parsed = int(value)
    if parsed < 0:
        raise ValueError("{} must be non-negative".format(name))
    return parsed


def parse_bool(value, name):
    if str(value).lower() not in ("true", "false"):
        raise ValueError("{} must be true or false".format(name))
    return str(value).lower()


def apply_overrides(values, args):
    overrides = set()
    for key in INPUT_ORDER:
        value = getattr(args, key, None)
        if value is not None:
            values[key] = str(value)
            overrides.add(key)
    if args.run_label_suffix:
        values["run_label"] = "{}-{}".format(values["run_label"], args.run_label_suffix)
        overrides.add("run_label")
    return values, overrides


def validate(values):
    validate_path(values["config"], "config")
    positive_int(values["stage3_run_id"], "stage3_run_id")
    for key in (
        "production_candidate_limit",
        "guarded_repair_limit",
        "repair_target_limit",
        "operator_benchmark_limit",
        "needs_more_diagnostics_limit",
        "archive_limit",
        "total_candidate_limit",
        "baseline_restarts",
        "max_tasks",
    ):
        nonnegative_int(values[key], key)
    for key in (
        "production_restarts",
        "repair_restarts",
        "benchmark_restarts",
        "diagnostic_restarts",
        "steps",
        "sample_swaps",
        "diagnostic_sample_count",
        "operator_reward_topk",
        "shard_count",
        "max_parallel",
        "stage5_candidate_limit",
    ):
        positive_int(values[key], key)
    if int(values["max_parallel"]) > int(values["shard_count"]):
        raise ValueError("max_parallel should not exceed shard_count")
    values["high_resolution_logging"] = parse_bool(values["high_resolution_logging"], "high_resolution_logging")
    if values["artifact_mode"] not in ("summary_only", "summary_plus_raw"):
        raise ValueError("artifact_mode must be summary_only or summary_plus_raw")
    if values["snapshot_log_mode"] not in ("summary_only", "scheduled", "triggered", "full"):
        raise ValueError("snapshot_log_mode must be summary_only, scheduled, triggered, or full")
    if values["operator_reward_log_mode"] not in ("summary_only", "topk", "sampled", "full_compressed"):
        raise ValueError("operator_reward_log_mode must be summary_only, topk, sampled, or full_compressed")


def build_command(args, values, overrides):
    command = ["gh", "workflow", "run", WORKFLOW, "--repo", args.repo, "--ref", args.ref]
    command.extend(["-f", "preset={}".format(args.preset)])
    dispatch_keys = {"run_label"} | set(overrides)
    for key in INPUT_ORDER:
        if key not in dispatch_keys:
            continue
        value = values.get(key)
        if value is not None and str(value) != "":
            command.extend(["-f", "{}={}".format(key, value)])
    return command


def printable(command):
    return "env -u GITHUB_TOKEN " + " ".join(shlex.quote(part) for part in command)


def parse_args():
    parser = argparse.ArgumentParser(description="Build or dispatch p167 Stage 4 candidate deepening runs.")
    parser.add_argument("--preset", choices=sorted(PRESETS), default="remote-smoke")
    parser.add_argument("--repo", default="rikumatsudo/hadamard-search")
    parser.add_argument("--ref", default="main")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--run-label-suffix", default="")
    for key in INPUT_ORDER:
        parser.add_argument("--{}".format(key.replace("_", "-")), dest=key, default=None)
    return parser.parse_args()


def main():
    args = parse_args()
    values = dict(PRESETS[args.preset])
    values, overrides = apply_overrides(values, args)
    validate(values)
    command = build_command(args, values, overrides)
    print(printable(command))
    if args.execute:
        subprocess.run(["env", "-u", "GITHUB_TOKEN"] + command, check=True)


if __name__ == "__main__":
    main()
