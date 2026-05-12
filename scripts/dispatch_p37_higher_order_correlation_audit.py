#!/usr/bin/env python3
import argparse
import shlex
import subprocess


WORKFLOW = "p37-higher-order-correlation-audit.yml"


PRESETS = {
    "remote-smoke": {
        "run_label": "p37-higher-order-correlation-smoke",
        "triple_sample_sizes": "10",
        "fourpoint_sample_sizes": "10",
        "metric_mode": "smoke",
        "max_candidates": "2",
        "max_tasks": "2",
        "exact_derived_count": "2",
        "random_control_count": "1",
        "shard_count": "1",
        "max_parallel": "1",
    },
    "p37-higher-order-correlation-40": {
        "run_label": "p37-higher-order-correlation-40x",
        "triple_sample_sizes": "50,100,300,1000,full",
        "fourpoint_sample_sizes": "100,300,1000",
        "metric_mode": "full",
        "max_candidates": "0",
        "max_tasks": "0",
        "exact_derived_count": "100",
        "random_control_count": "100",
        "shard_count": "40",
        "max_parallel": "40",
    },
}


INPUT_ORDER = [
    "run_label",
    "triple_sample_sizes",
    "fourpoint_sample_sizes",
    "metric_mode",
    "max_candidates",
    "max_tasks",
    "exact_derived_count",
    "random_control_count",
    "shard_count",
    "max_parallel",
]


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


def validate(values):
    if values["metric_mode"] not in ("smoke", "full"):
        raise ValueError("metric_mode must be smoke or full")
    for key in ("max_candidates", "max_tasks"):
        nonnegative_int(values[key], key)
    for key in ("exact_derived_count", "random_control_count", "shard_count", "max_parallel"):
        positive_int(values[key], key)
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
    parser = argparse.ArgumentParser(description="Build or dispatch p37 higher-order correlation audit runs.")
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
