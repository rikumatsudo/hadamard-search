#!/usr/bin/env python3
import argparse
import shlex
import subprocess


WORKFLOW = "p167-local-branching-wall-check.yml"
DEFAULT_FRONTIER_FILES = "configs/fixtures/p167_local_branching_wall_candidates.jsonl"


PRESETS = {
    "remote-smoke": {
        "run_label": "p167-local-branching-wall-check-remote-smoke",
        "candidate_count": "1",
        "frontier_files": DEFAULT_FRONTIER_FILES,
        "solver_modes": "dfs",
        "pool_modes": "defect",
        "pool_size_list": "4",
        "radius_list": "2",
        "restarts_per_cell": "1",
        "block_candidate_cap_per_radius": "1000",
        "solver_move_cap_per_block": "5000",
        "mitm_state_cap_per_radius": "50000",
        "cp_sat_move_cap_per_block": "64",
        "cp_sat_time_limit_seconds": "30",
        "cp_sat_workers": "1",
        "global_eval_cap": "20000",
        "max_wall_time_ms": "10000",
        "shard_count": "1",
        "max_parallel": "1",
        "base_seed": "164168",
    },
    "p167-local-branching-wall-check-40": {
        "run_label": "p167-local-branching-wall-check-40x",
        "candidate_count": "2",
        "frontier_files": DEFAULT_FRONTIER_FILES,
        "solver_modes": "dfs",
        "pool_modes": "defect,hybrid",
        "pool_size_list": "6,8,10",
        "radius_list": "2,3,4",
        "restarts_per_cell": "4",
        "block_candidate_cap_per_radius": "50000",
        "solver_move_cap_per_block": "5000",
        "mitm_state_cap_per_radius": "50000",
        "cp_sat_move_cap_per_block": "64",
        "cp_sat_time_limit_seconds": "30",
        "cp_sat_workers": "1",
        "global_eval_cap": "4000000",
        "max_wall_time_ms": "120000",
        "shard_count": "40",
        "max_parallel": "40",
        "base_seed": "164168",
    },
    "p167-local-branching-cpsat-40": {
        "run_label": "p167-local-branching-cpsat-40x",
        "candidate_count": "2",
        "frontier_files": DEFAULT_FRONTIER_FILES,
        "solver_modes": "mitm,cp_sat",
        "pool_modes": "defect,hybrid",
        "pool_size_list": "8,10",
        "radius_list": "3,4",
        "restarts_per_cell": "4",
        "block_candidate_cap_per_radius": "80000",
        "solver_move_cap_per_block": "8000",
        "mitm_state_cap_per_radius": "100000",
        "cp_sat_move_cap_per_block": "96",
        "cp_sat_time_limit_seconds": "60",
        "cp_sat_workers": "1",
        "global_eval_cap": "8000000",
        "max_wall_time_ms": "240000",
        "shard_count": "40",
        "max_parallel": "40",
        "base_seed": "164168",
    },
}


INPUT_ORDER = [
    "run_label",
    "candidate_count",
    "frontier_files",
    "solver_modes",
    "pool_modes",
    "pool_size_list",
    "radius_list",
    "restarts_per_cell",
    "block_candidate_cap_per_radius",
    "solver_move_cap_per_block",
    "mitm_state_cap_per_radius",
    "cp_sat_move_cap_per_block",
    "cp_sat_time_limit_seconds",
    "cp_sat_workers",
    "global_eval_cap",
    "max_wall_time_ms",
    "shard_count",
    "max_parallel",
    "base_seed",
]


def validate(values):
    for key in INPUT_ORDER:
        if key in {"run_label", "frontier_files", "solver_modes", "pool_modes", "pool_size_list", "radius_list"}:
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
    parser = argparse.ArgumentParser(description="Build or dispatch p167 local branching wall check runs.")
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
