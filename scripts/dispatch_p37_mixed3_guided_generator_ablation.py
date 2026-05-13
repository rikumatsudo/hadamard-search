#!/usr/bin/env python3
import argparse
import shlex
import subprocess


WORKFLOW = "p37-mixed3-guided-generator-ablation.yml"


PRESETS = {
    "remote-smoke": {
        "run_label": "p37-mixed3-guided-generator-smoke",
        "variants": "random_fixed_size,pair_profile_plus_mixed3",
        "candidates_per_variant": "1",
        "sample_count": "5",
        "repair_budget": "2",
        "repair_swap_sample_count": "16",
        "diagnostic_sample_count": "16",
        "triple_sample_size": "10",
        "shard_count": "1",
        "max_parallel": "1",
    },
    "p37-mixed3-guided-generator-40": {
        "run_label": "p37-mixed3-guided-generator-40x",
        "variants": "random_fixed_size,pair_profile_guided,pair_profile_plus_AP_E,pair_profile_plus_mixed3,pair_profile_plus_mixed3_plus_AP_E,pair_profile_plus_mixed3_plus_sampled_triple",
        "candidates_per_variant": "200",
        "sample_count": "12",
        "repair_budget": "20",
        "repair_swap_sample_count": "128",
        "diagnostic_sample_count": "128",
        "triple_sample_size": "100",
        "shard_count": "40",
        "max_parallel": "40",
    },
}


INPUT_ORDER = [
    "run_label",
    "variants",
    "candidates_per_variant",
    "sample_count",
    "repair_budget",
    "repair_swap_sample_count",
    "diagnostic_sample_count",
    "triple_sample_size",
    "shard_count",
    "max_parallel",
]


def validate(values):
    for key in INPUT_ORDER:
        if key in ("run_label", "variants"):
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
    parser = argparse.ArgumentParser(description="Build or dispatch p37 mixed3-guided generator ablation runs.")
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
