#!/usr/bin/env python3
import argparse
import shlex
import subprocess
from pathlib import Path


WORKFLOW = "p167-stage2-survivor-deepening.yml"


PRESETS = {
    "remote-smoke": {
        "run_label": "p167-stage2-smoke",
        "config": "configs/experiments/p167_stage2_survivor_deepening.yaml",
        "tuple_registry": "configs/fixtures/p167_tuple_classes.json",
        "stage1_run_id": "25626432803",
        "stage1_artifact_name": "p167-broad-stage1-aggregate-25626432803",
        "benchmark_trap_manifest": "configs/fixtures/benchmark_traps/p167_score164_176.jsonl",
        "nearhit_fixture": "configs/fixtures/p167_focused_nearhit_candidates.jsonl",
        "operators": "survivor_baseline_score_only",
        "survivor_limit": "1",
        "benchmark_trap_limit": "0",
        "random_control_limit": "0",
        "nearhit_control_limit": "0",
        "restarts": "1",
        "steps": "1",
        "sample_swaps": "5",
        "diagnostic_sample_count": "5",
        "snapshot_attempted_steps": "0,1",
        "snapshot_accepted_moves": "0,1",
        "high_resolution_logging": "false",
        "high_resolution_mode": "off",
        "high_resolution_max_windows_per_trajectory": "1",
        "high_resolution_window_accepted_moves": "5",
        "artifact_mode": "summary_only",
        "compress_raw_logs": "true",
        "upload_raw_logs": "false",
        "snapshot_log_mode": "summary_only",
        "operator_reward_log_mode": "topk",
        "operator_reward_topk": "5",
        "operator_reward_sample_rate": "0.01",
        "max_tasks": "1",
        "shard_count": "1",
        "max_parallel": "1",
        "stage3_candidate_limit": "5",
    },
    "stage2-lite-40": {
        "run_label": "p167-stage2-lite-40x",
        "config": "configs/experiments/p167_stage2_survivor_deepening.yaml",
        "tuple_registry": "configs/fixtures/p167_tuple_classes.json",
        "stage1_run_id": "25626432803",
        "stage1_artifact_name": "p167-broad-stage1-aggregate-25626432803",
        "benchmark_trap_manifest": "configs/fixtures/benchmark_traps/p167_score164_176.jsonl",
        "nearhit_fixture": "configs/fixtures/p167_focused_nearhit_candidates.jsonl",
        "operators": "survivor_baseline_score_only,survivor_focused_plus_threshold,survivor_hybrid_pair_to_closure_shell,survivor_pair_profile_movespace_filter,survivor_mixed_operator_adaptive,survivor_exact_joint_local_repair",
        "survivor_limit": "50",
        "benchmark_trap_limit": "7",
        "random_control_limit": "20",
        "nearhit_control_limit": "20",
        "restarts": "3",
        "steps": "1000",
        "sample_swaps": "300",
        "diagnostic_sample_count": "300",
        "snapshot_attempted_steps": "0,50,100,200,500,1000",
        "snapshot_accepted_moves": "0,25,50,100,200,500",
        "high_resolution_logging": "true",
        "high_resolution_mode": "triggered",
        "high_resolution_max_windows_per_trajectory": "2",
        "high_resolution_window_accepted_moves": "50",
        "artifact_mode": "summary_only",
        "compress_raw_logs": "true",
        "upload_raw_logs": "false",
        "snapshot_log_mode": "summary_only",
        "operator_reward_log_mode": "topk",
        "operator_reward_topk": "50",
        "operator_reward_sample_rate": "0.01",
        "max_tasks": "0",
        "shard_count": "40",
        "max_parallel": "40",
        "stage3_candidate_limit": "50",
    },
    "stage2-full-40": {
        "run_label": "p167-stage2-full-40x",
        "config": "configs/experiments/p167_stage2_survivor_deepening.yaml",
        "tuple_registry": "configs/fixtures/p167_tuple_classes.json",
        "stage1_run_id": "25626432803",
        "stage1_artifact_name": "p167-broad-stage1-aggregate-25626432803",
        "benchmark_trap_manifest": "configs/fixtures/benchmark_traps/p167_score164_176.jsonl",
        "nearhit_fixture": "configs/fixtures/p167_focused_nearhit_candidates.jsonl",
        "operators": "survivor_baseline_score_only,survivor_focused_plus_threshold,survivor_hybrid_pair_to_closure_shell,survivor_pair_profile_movespace_filter,survivor_mixed_operator_adaptive,survivor_exact_joint_local_repair",
        "survivor_limit": "50",
        "benchmark_trap_limit": "7",
        "random_control_limit": "20",
        "nearhit_control_limit": "20",
        "restarts": "5",
        "steps": "2000",
        "sample_swaps": "500",
        "diagnostic_sample_count": "500",
        "snapshot_attempted_steps": "0,50,100,200,500,1000,2000",
        "snapshot_accepted_moves": "0,25,50,100,200,500",
        "high_resolution_logging": "true",
        "high_resolution_mode": "triggered",
        "high_resolution_max_windows_per_trajectory": "2",
        "high_resolution_window_accepted_moves": "50",
        "artifact_mode": "summary_only",
        "compress_raw_logs": "true",
        "upload_raw_logs": "false",
        "snapshot_log_mode": "summary_only",
        "operator_reward_log_mode": "topk",
        "operator_reward_topk": "50",
        "operator_reward_sample_rate": "0.01",
        "max_tasks": "0",
        "shard_count": "40",
        "max_parallel": "40",
        "stage3_candidate_limit": "100",
    },
}


INPUT_ORDER = [
    "run_label",
    "config",
    "tuple_registry",
    "stage1_run_id",
    "stage1_artifact_name",
    "benchmark_trap_manifest",
    "nearhit_fixture",
    "operators",
    "survivor_limit",
    "benchmark_trap_limit",
    "random_control_limit",
    "nearhit_control_limit",
    "restarts",
    "steps",
    "sample_swaps",
    "diagnostic_sample_count",
    "snapshot_attempted_steps",
    "snapshot_accepted_moves",
    "high_resolution_logging",
    "high_resolution_mode",
    "high_resolution_max_windows_per_trajectory",
    "high_resolution_window_accepted_moves",
    "artifact_mode",
    "compress_raw_logs",
    "upload_raw_logs",
    "snapshot_log_mode",
    "operator_reward_log_mode",
    "operator_reward_topk",
    "operator_reward_sample_rate",
    "max_tasks",
    "shard_count",
    "max_parallel",
    "stage3_candidate_limit",
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
    for key in INPUT_ORDER:
        value = getattr(args, key, None)
        if value is not None:
            values[key] = str(value)
    if args.run_label_suffix:
        values["run_label"] = "{}-{}".format(values["run_label"], args.run_label_suffix)
    return values


def validate(values):
    validate_path(values["config"], "config")
    validate_path(values["tuple_registry"], "tuple_registry")
    validate_path(values["benchmark_trap_manifest"], "benchmark_trap_manifest")
    validate_path(values["nearhit_fixture"], "nearhit_fixture")
    positive_int(values["stage1_run_id"], "stage1_run_id")
    for key in (
        "survivor_limit",
        "benchmark_trap_limit",
        "random_control_limit",
        "nearhit_control_limit",
        "max_tasks",
    ):
        nonnegative_int(values[key], key)
    for key in (
        "restarts",
        "steps",
        "sample_swaps",
        "diagnostic_sample_count",
        "high_resolution_window_accepted_moves",
        "operator_reward_topk",
        "shard_count",
        "max_parallel",
        "stage3_candidate_limit",
    ):
        positive_int(values[key], key)
    nonnegative_int(values["high_resolution_max_windows_per_trajectory"], "high_resolution_max_windows_per_trajectory")
    if int(values["max_parallel"]) > int(values["shard_count"]):
        raise ValueError("max_parallel should not exceed shard_count")
    values["high_resolution_logging"] = parse_bool(values["high_resolution_logging"], "high_resolution_logging")
    values["compress_raw_logs"] = parse_bool(values["compress_raw_logs"], "compress_raw_logs")
    values["upload_raw_logs"] = parse_bool(values["upload_raw_logs"], "upload_raw_logs")
    if values["high_resolution_mode"] not in ("off", "triggered", "all"):
        raise ValueError("high_resolution_mode must be off, triggered, or all")
    if values["artifact_mode"] not in ("summary_only", "summary_plus_raw"):
        raise ValueError("artifact_mode must be summary_only or summary_plus_raw")
    if values["snapshot_log_mode"] not in ("summary_only", "scheduled", "triggered", "full"):
        raise ValueError("snapshot_log_mode must be summary_only, scheduled, triggered, or full")
    if values["operator_reward_log_mode"] not in ("summary_only", "topk", "sampled", "full_compressed"):
        raise ValueError("operator_reward_log_mode must be summary_only, topk, sampled, or full_compressed")
    sample_rate = float(values["operator_reward_sample_rate"])
    if sample_rate < 0.0 or sample_rate > 1.0:
        raise ValueError("operator_reward_sample_rate must be in [0, 1]")


def build_command(args, values):
    command = ["gh", "workflow", "run", WORKFLOW, "--repo", args.repo, "--ref", args.ref]
    for key in INPUT_ORDER:
        value = values.get(key)
        if value is not None and str(value) != "":
            command.extend(["-f", "{}={}".format(key, value)])
    return command


def printable(command):
    return "env -u GITHUB_TOKEN " + " ".join(shlex.quote(part) for part in command)


def parse_args():
    parser = argparse.ArgumentParser(description="Build or dispatch p167 Stage 2 survivor deepening runs.")
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
    values = apply_overrides(values, args)
    validate(values)
    command = build_command(args, values)
    print(printable(command))
    if args.execute:
        subprocess.run(["env", "-u", "GITHUB_TOKEN"] + command, check=True)


if __name__ == "__main__":
    main()
