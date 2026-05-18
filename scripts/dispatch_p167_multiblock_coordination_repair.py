#!/usr/bin/env python3
import argparse
import shlex
import subprocess


WORKFLOW = "p167-multiblock-coordination-repair.yml"
DEFAULT_FRONTIER_FILES = "configs/fixtures/p167_local_branching_wall_candidates.jsonl"


PRESETS = {
    "remote-smoke": {
        "run_label": "p167-multiblock-coordination-repair-remote-smoke",
        "candidate_count": "1",
        "frontier_files": DEFAULT_FRONTIER_FILES,
        "pool_modes": "defect",
        "pool_size_list": "4",
        "block_radius_list": "1",
        "coordination_orders": "2",
        "max_total_radius": "2",
        "restarts_per_cell": "1",
        "move_cap_per_block": "128",
        "combo_sample_cap_per_block_radius": "2000",
        "combination_eval_cap": "20000",
        "max_wall_time_ms": "10000",
        "shard_count": "1",
        "max_parallel": "1",
        "base_seed": "167431",
    },
    "p167-multiblock-coordination-40": {
        "run_label": "p167-multiblock-coordination-40x",
        "candidate_count": "2",
        "frontier_files": DEFAULT_FRONTIER_FILES,
        "pool_modes": "defect,hybrid,broad_hybrid",
        "pool_size_list": "6,8,10",
        "block_radius_list": "1,2",
        "coordination_orders": "2,3,4",
        "max_total_radius": "6",
        "restarts_per_cell": "4",
        "move_cap_per_block": "4000",
        "combo_sample_cap_per_block_radius": "50000",
        "combination_eval_cap": "2000000",
        "max_wall_time_ms": "120000",
        "shard_count": "40",
        "max_parallel": "40",
        "base_seed": "167431",
    },
}


INPUT_ORDER = [
    "run_label",
    "candidate_count",
    "frontier_files",
    "pool_modes",
    "pool_size_list",
    "block_radius_list",
    "coordination_orders",
    "max_total_radius",
    "restarts_per_cell",
    "move_cap_per_block",
    "combo_sample_cap_per_block_radius",
    "combination_eval_cap",
    "max_wall_time_ms",
    "shard_count",
    "max_parallel",
    "base_seed",
]


def validate(values):
    for key in INPUT_ORDER:
        if key in {"run_label", "frontier_files", "pool_modes", "pool_size_list", "block_radius_list", "coordination_orders"}:
            continue
        if float(values[key]) < 1:
            raise ValueError("{} must be positive".format(key))
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
    parser = argparse.ArgumentParser(description="Build or dispatch p167 multiblock coordination repair runs.")
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
