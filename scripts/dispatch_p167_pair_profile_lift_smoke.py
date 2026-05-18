#!/usr/bin/env python3
import argparse
import shlex
import subprocess


WORKFLOW = "p167-pair-profile-lift-smoke.yml"
DEFAULT_FRONTIER_FILES = "configs/fixtures/p167_local_branching_wall_candidates.jsonl"
TUPLEWIDE_FRONTIER_FILES = ",".join(
    [
        "configs/fixtures/p167_local_branching_wall_candidates.jsonl",
        "configs/fixtures/p167_softwall_escape_frontier_candidates.jsonl",
        "configs/fixtures/p167_targeted_deep_frontier_repair_candidates.jsonl",
        "configs/fixtures/p167_frontier_repair_seed_candidates.jsonl",
        "configs/fixtures/p167_focused_nearhit_candidates.jsonl",
        "configs/fixtures/benchmark_traps/p167_score164_176.jsonl",
    ]
)


PRESETS = {
    "remote-smoke": {
        "run_label": "p167-pair-profile-lift-smoke-remote-smoke",
        "candidate_count": "1",
        "tuple_classes": "p167_c01,p167_c05",
        "representatives_per_tuple": "1",
        "auto_tuple_representatives": "false",
        "frontier_files": DEFAULT_FRONTIER_FILES,
        "split_modes": "fixed_01_23",
        "target_modes": "midpoint",
        "init_modes": "random,seed",
        "restarts_per_cell": "1",
        "lift_steps": "4",
        "swap_sample_count": "16",
        "temperature": "0.0",
        "perturb_swaps": "2",
        "repair_budget": "1",
        "repair_swap_sample_count": "16",
        "source_repair_budget": "0",
        "source_repair_swap_sample_count": "96",
        "max_wall_time_ms_per_lift": "5000",
        "shard_count": "1",
        "max_parallel": "1",
        "base_seed": "167512",
    },
    "p167-pair-profile-lift-smoke-40": {
        "run_label": "p167-pair-profile-lift-smoke-40x",
        "candidate_count": "2",
        "tuple_classes": "p167_c01,p167_c05",
        "representatives_per_tuple": "1",
        "auto_tuple_representatives": "false",
        "frontier_files": DEFAULT_FRONTIER_FILES,
        "split_modes": "fixed_01_23",
        "target_modes": "midpoint,seed_left,seed_right_complement,lambda_half,jitter_midpoint",
        "init_modes": "random,seed,perturbed_seed",
        "restarts_per_cell": "12",
        "lift_steps": "60",
        "swap_sample_count": "128",
        "temperature": "0.0",
        "perturb_swaps": "8",
        "repair_budget": "6",
        "repair_swap_sample_count": "96",
        "source_repair_budget": "0",
        "source_repair_swap_sample_count": "96",
        "max_wall_time_ms_per_lift": "15000",
        "shard_count": "40",
        "max_parallel": "40",
        "base_seed": "167512",
    },
    "p167-pair-profile-lift-tuplewide-40": {
        "run_label": "p167-pair-profile-lift-tuplewide-40x",
        "candidate_count": "30",
        "tuple_classes": "all",
        "representatives_per_tuple": "3",
        "auto_tuple_representatives": "true",
        "frontier_files": TUPLEWIDE_FRONTIER_FILES,
        "split_modes": "fixed_01_23,fixed_02_13,fixed_03_12",
        "target_modes": "midpoint,seed_left,seed_right_complement,jitter_midpoint",
        "init_modes": "random,seed,perturbed_seed",
        "restarts_per_cell": "4",
        "lift_steps": "50",
        "swap_sample_count": "96",
        "temperature": "0.0",
        "perturb_swaps": "8",
        "repair_budget": "6",
        "repair_swap_sample_count": "96",
        "source_repair_budget": "3",
        "source_repair_swap_sample_count": "96",
        "max_wall_time_ms_per_lift": "12000",
        "shard_count": "40",
        "max_parallel": "40",
        "base_seed": "167613",
    },
}


INPUT_ORDER = [
    "run_label",
    "candidate_count",
    "tuple_classes",
    "representatives_per_tuple",
    "auto_tuple_representatives",
    "frontier_files",
    "split_modes",
    "target_modes",
    "init_modes",
    "restarts_per_cell",
    "lift_steps",
    "swap_sample_count",
    "temperature",
    "perturb_swaps",
    "repair_budget",
    "repair_swap_sample_count",
    "source_repair_budget",
    "source_repair_swap_sample_count",
    "max_wall_time_ms_per_lift",
    "shard_count",
    "max_parallel",
    "base_seed",
]


def validate(values):
    for key in INPUT_ORDER:
        if key in {
            "run_label",
            "tuple_classes",
            "auto_tuple_representatives",
            "frontier_files",
            "split_modes",
            "target_modes",
            "init_modes",
            "temperature",
            "repair_budget",
            "source_repair_budget",
        }:
            continue
        if float(values[key]) < 1:
            raise ValueError("{} must be positive".format(key))
    if float(values["temperature"]) < 0:
        raise ValueError("temperature must be nonnegative")
    if int(values["repair_budget"]) < 0:
        raise ValueError("repair_budget must be nonnegative")
    if int(values["source_repair_budget"]) < 0:
        raise ValueError("source_repair_budget must be nonnegative")
    if values["auto_tuple_representatives"] not in {"true", "false"}:
        raise ValueError("auto_tuple_representatives must be true or false")
    if int(values["max_parallel"]) > int(values["shard_count"]):
        raise ValueError("max_parallel should not exceed shard_count")


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
    parser = argparse.ArgumentParser(description="Build or dispatch p167 pair profile lift smoke runs.")
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
