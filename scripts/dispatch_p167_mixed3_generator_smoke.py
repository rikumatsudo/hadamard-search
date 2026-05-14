#!/usr/bin/env python3
import argparse
import shlex
import subprocess


WORKFLOW = "p167-mixed3-generator-smoke.yml"


PRESETS = {
    "remote-smoke": {
        "run_label": "p167-mixed3-generator-smoke-remote-smoke",
        "tuple_classes": "p167_c01,p167_c05,p167_c09",
        "variants": "random_fixed_size,pair_profile_plus_mixed3_focus",
        "candidates_per_variant_per_tuple": "1",
        "sample_count": "3",
        "repair_budget": "2",
        "repair_swap_sample_count": "16",
        "diagnostic_sample_count": "16",
        "guard_sample_count": "4",
        "shard_count": "1",
        "max_parallel": "1",
        "base_seed": "167003",
    },
    "p167-mixed3-generator-smoke-40": {
        "run_label": "p167-mixed3-generator-smoke-40x",
        "tuple_classes": "p167_c01,p167_c05,p167_c09",
        "variants": "random_fixed_size,pair_profile_guided,pair_profile_plus_mixed3_focus,mixed3_focus_plus_kappa_guard,mixed3_focus_plus_closure_shell_guard",
        "candidates_per_variant_per_tuple": "50",
        "sample_count": "4",
        "repair_budget": "8",
        "repair_swap_sample_count": "96",
        "diagnostic_sample_count": "96",
        "guard_sample_count": "8",
        "shard_count": "40",
        "max_parallel": "40",
        "base_seed": "167503",
    },
}


INPUT_ORDER = [
    "run_label",
    "tuple_classes",
    "variants",
    "candidates_per_variant_per_tuple",
    "sample_count",
    "repair_budget",
    "repair_swap_sample_count",
    "diagnostic_sample_count",
    "guard_sample_count",
    "shard_count",
    "max_parallel",
    "base_seed",
]


def validate(values):
    positive_ints = {
        "candidates_per_variant_per_tuple",
        "sample_count",
        "repair_budget",
        "repair_swap_sample_count",
        "diagnostic_sample_count",
        "guard_sample_count",
        "shard_count",
        "max_parallel",
        "base_seed",
    }
    for key in positive_ints:
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
    parser = argparse.ArgumentParser(description="Build or dispatch p167 mixed3 generator smoke runs.")
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
