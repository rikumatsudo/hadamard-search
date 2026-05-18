#!/usr/bin/env python3
import argparse
import shlex
import subprocess


WORKFLOW = "p167-fixed0123-nonmonotone-pair-lns.yml"

DEFAULT_FRONTIER_FILES = (
    "configs/fixtures/p167_c01_c05_best_frontier_focus_candidates.jsonl,"
    "configs/fixtures/p167_softwall_escape_frontier_candidates.jsonl,"
    "configs/fixtures/p167_targeted_deep_frontier_repair_candidates.jsonl,"
    "configs/fixtures/p167_frontier_repair_seed_candidates.jsonl,"
    "configs/fixtures/benchmark_traps/p167_score164_176.jsonl,"
    "configs/fixtures/p167_focused_nearhit_candidates.jsonl"
)


PRESETS = {
    "remote-smoke": {
        "run_label": "p167-fixed0123-nonmonotone-pair-lns-remote-smoke",
        "candidate_count": "3",
        "frontier_files": DEFAULT_FRONTIER_FILES,
        "operators": "O0,O1",
        "alpha_values": "0.0",
        "max_uphill_values": "16",
        "restarts_per_candidate_operator": "1",
        "pool_size": "12",
        "beam_width": "4",
        "eval_cap_per_attempt": "80",
        "max_wall_time_ms": "10000",
        "shard_count": "1",
        "max_parallel": "1",
        "base_seed": "172123",
    },
    "p167-fixed0123-nonmonotone-pair-lns-40": {
        "run_label": "p167-fixed0123-nonmonotone-pair-lns-40x",
        "candidate_count": "40",
        "frontier_files": DEFAULT_FRONTIER_FILES,
        "operators": "O0,O1,O2,O3,O4,O5",
        "alpha_values": "0.0,0.1,0.25",
        "max_uphill_values": "32,64,128",
        "restarts_per_candidate_operator": "2",
        "pool_size": "48",
        "beam_width": "24",
        "eval_cap_per_attempt": "3000",
        "max_wall_time_ms": "90000",
        "shard_count": "40",
        "max_parallel": "40",
        "base_seed": "172123",
    },
}


INPUT_ORDER = [
    "run_label",
    "candidate_count",
    "frontier_files",
    "operators",
    "alpha_values",
    "max_uphill_values",
    "restarts_per_candidate_operator",
    "pool_size",
    "beam_width",
    "eval_cap_per_attempt",
    "max_wall_time_ms",
    "shard_count",
    "max_parallel",
    "base_seed",
]


def validate(values):
    numeric = [
        "candidate_count",
        "restarts_per_candidate_operator",
        "pool_size",
        "beam_width",
        "eval_cap_per_attempt",
        "max_wall_time_ms",
        "shard_count",
        "max_parallel",
        "base_seed",
    ]
    for key in numeric:
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
    parser = argparse.ArgumentParser(description="Build or dispatch p167 fixed_01_23 non-monotone pair LNS runs.")
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
