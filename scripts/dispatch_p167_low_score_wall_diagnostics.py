#!/usr/bin/env python3
import argparse
import shlex
import subprocess


WORKFLOW = "p167-low-score-wall-diagnostics.yml"


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
        "run_label": "p167-low-score-wall-diagnostics-remote-smoke",
        "candidate_count": "3",
        "frontier_files": DEFAULT_FRONTIER_FILES,
        "rswap_pool_size": "12",
        "rswap_eval_cap": "80",
        "max_wall_time_ms": "10000",
        "shard_count": "1",
        "max_parallel": "1",
        "base_seed": "170167",
    },
    "p167-low-score-wall-diagnostics-40": {
        "run_label": "p167-low-score-wall-diagnostics-40x",
        "candidate_count": "60",
        "frontier_files": DEFAULT_FRONTIER_FILES,
        "rswap_pool_size": "48",
        "rswap_eval_cap": "8000",
        "max_wall_time_ms": "120000",
        "shard_count": "40",
        "max_parallel": "40",
        "base_seed": "170167",
    },
}


INPUT_ORDER = [
    "run_label",
    "candidate_count",
    "frontier_files",
    "rswap_pool_size",
    "rswap_eval_cap",
    "max_wall_time_ms",
    "shard_count",
    "max_parallel",
    "base_seed",
]


def validate(values):
    for key in INPUT_ORDER:
        if key in {"run_label", "frontier_files"}:
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
    parser = argparse.ArgumentParser(description="Build or dispatch p167 low score wall diagnostics runs.")
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
