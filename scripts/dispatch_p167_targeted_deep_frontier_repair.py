#!/usr/bin/env python3
import argparse
import shlex
import subprocess


WORKFLOW = "p167-targeted-deep-frontier-repair.yml"


PRESETS = {
    "remote-smoke": {
        "run_label": "p167-targeted-deep-frontier-repair-remote-smoke",
        "frontier_count": "3",
        "operators": "score_only_1swap_greedy,exact_joint_2swap_beam_deep",
        "max_repair_steps": "1",
        "pool_size": "8",
        "lns_pool_size": "10",
        "lns_radius": "2",
        "beam_width": "4",
        "eval_cap_per_step": "40",
        "dmin_sample_count": "20",
        "max_wall_time_ms": "2000",
        "shard_count": "1",
        "max_parallel": "1",
        "base_seed": "168337",
    },
    "p167-targeted-deep-frontier-repair-40": {
        "run_label": "p167-targeted-deep-frontier-repair-40x",
        "frontier_count": "90",
        "operators": (
            "score_only_1swap_greedy,"
            "exact_joint_2swap_beam_deep,"
            "exact_joint_3swap_beam,"
            "defect_targeted_destroy_repair_deep,"
            "pair_level_partial_defect_repair_deep,"
            "restricted_exact_joint_lns_radius3_5"
        ),
        "max_repair_steps": "16",
        "pool_size": "40",
        "lns_pool_size": "48",
        "lns_radius": "5",
        "beam_width": "16",
        "eval_cap_per_step": "3000",
        "dmin_sample_count": "320",
        "max_wall_time_ms": "60000",
        "shard_count": "40",
        "max_parallel": "40",
        "base_seed": "168337",
    },
}


INPUT_ORDER = [
    "run_label",
    "frontier_count",
    "operators",
    "max_repair_steps",
    "pool_size",
    "lns_pool_size",
    "lns_radius",
    "beam_width",
    "eval_cap_per_step",
    "dmin_sample_count",
    "max_wall_time_ms",
    "shard_count",
    "max_parallel",
    "base_seed",
]


def validate(values):
    for key in INPUT_ORDER:
        if key in {"run_label", "operators"}:
            continue
        if int(values[key]) < 1:
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
    parser = argparse.ArgumentParser(description="Build or dispatch p167 targeted deep frontier repair runs.")
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
