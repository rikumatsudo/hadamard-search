#!/usr/bin/env python3
import argparse
import shlex
import subprocess


WORKFLOW = "p167-pair-profile-lift-smoke.yml"
DEFAULT_FRONTIER_FILES = "configs/fixtures/p167_local_branching_wall_candidates.jsonl"


PRESETS = {
    "remote-smoke": {
        "run_label": "p167-pair-profile-lift-smoke-remote-smoke",
        "candidate_count": "1",
        "frontier_files": DEFAULT_FRONTIER_FILES,
        "target_modes": "midpoint",
        "init_modes": "random,seed",
        "restarts_per_cell": "1",
        "lift_steps": "4",
        "swap_sample_count": "16",
        "temperature": "0.0",
        "perturb_swaps": "2",
        "repair_budget": "1",
        "repair_swap_sample_count": "16",
        "max_wall_time_ms_per_lift": "5000",
        "shard_count": "1",
        "max_parallel": "1",
        "base_seed": "167512",
    },
    "p167-pair-profile-lift-smoke-40": {
        "run_label": "p167-pair-profile-lift-smoke-40x",
        "candidate_count": "2",
        "frontier_files": DEFAULT_FRONTIER_FILES,
        "target_modes": "midpoint,seed_left,seed_right_complement,lambda_half,jitter_midpoint",
        "init_modes": "random,seed,perturbed_seed",
        "restarts_per_cell": "12",
        "lift_steps": "60",
        "swap_sample_count": "128",
        "temperature": "0.0",
        "perturb_swaps": "8",
        "repair_budget": "6",
        "repair_swap_sample_count": "96",
        "max_wall_time_ms_per_lift": "15000",
        "shard_count": "40",
        "max_parallel": "40",
        "base_seed": "167512",
    },
}


INPUT_ORDER = [
    "run_label",
    "candidate_count",
    "frontier_files",
    "target_modes",
    "init_modes",
    "restarts_per_cell",
    "lift_steps",
    "swap_sample_count",
    "temperature",
    "perturb_swaps",
    "repair_budget",
    "repair_swap_sample_count",
    "max_wall_time_ms_per_lift",
    "shard_count",
    "max_parallel",
    "base_seed",
]


def validate(values):
    for key in INPUT_ORDER:
        if key in {"run_label", "frontier_files", "target_modes", "init_modes", "temperature", "repair_budget"}:
            continue
        if float(values[key]) < 1:
            raise ValueError("{} must be positive".format(key))
    if float(values["temperature"]) < 0:
        raise ValueError("temperature must be nonnegative")
    if int(values["repair_budget"]) < 0:
        raise ValueError("repair_budget must be nonnegative")
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
