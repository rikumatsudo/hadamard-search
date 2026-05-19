#!/usr/bin/env python3
import argparse
import shlex
import subprocess


WORKFLOW = "p167-quotient-profile-lift-probe.yml"
FRONTIER_FILES = ",".join(
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
        "run_label": "p167-quotient-profile-lift-probe-remote-smoke",
        "candidate_count": "1",
        "tuple_classes": "p167_c01",
        "representatives_per_tuple": "1",
        "frontier_files": FRONTIER_FILES,
        "modes": "atom_random_balanced,atom_profile_lift_from_source",
        "split_modes": "fixed_01_23",
        "target_modes": "midpoint",
        "restarts_per_cell": "1",
        "atom_steps": "2",
        "atom_sample_count": "8",
        "temperature": "0.05",
        "alpha_pair": "0.05",
        "alpha_selected_defect": "0.25",
        "alpha_block_defect": "0.05",
        "alpha_fourier": "0.001",
        "selected_defect_count": "12",
        "selected_dynamic_defect_count": "4",
        "selected_fourier_count": "8",
        "alpha_size": "1000.0",
        "perturb_atom_moves": "2",
        "repair_budget": "1",
        "repair_swap_sample_count": "16",
        "max_wall_time_ms_per_candidate": "5000",
        "shard_count": "1",
        "max_parallel": "1",
        "base_seed": "167914",
    },
    "p167-quotient-profile-lift-light-40": {
        "run_label": "p167-quotient-profile-lift-light-40x",
        "candidate_count": "9",
        "tuple_classes": "p167_c01,p167_c05,p167_c09",
        "representatives_per_tuple": "3",
        "frontier_files": FRONTIER_FILES,
        "modes": "atom_random_balanced,atom_pair_profile_guided,atom_profile_lift_from_source",
        "split_modes": "fixed_01_23,fixed_02_13,fixed_03_12",
        "target_modes": "midpoint,seed_left,seed_right_complement,jitter_midpoint",
        "restarts_per_cell": "4",
        "atom_steps": "80",
        "atom_sample_count": "64",
        "temperature": "0.05",
        "alpha_pair": "0.05",
        "alpha_selected_defect": "0.0",
        "alpha_block_defect": "0.0",
        "alpha_fourier": "0.0",
        "selected_defect_count": "12",
        "selected_dynamic_defect_count": "0",
        "selected_fourier_count": "8",
        "alpha_size": "1000.0",
        "perturb_atom_moves": "8",
        "repair_budget": "6",
        "repair_swap_sample_count": "96",
        "max_wall_time_ms_per_candidate": "12000",
        "shard_count": "40",
        "max_parallel": "40",
        "base_seed": "167914",
    },
    "p167-quotient-profile-lift-constrained-40": {
        "run_label": "p167-quotient-profile-lift-constrained-40x",
        "candidate_count": "9",
        "tuple_classes": "p167_c01,p167_c05,p167_c09",
        "representatives_per_tuple": "3",
        "frontier_files": FRONTIER_FILES,
        "modes": "atom_random_balanced,atom_pair_profile_guided,atom_profile_lift_from_source",
        "split_modes": "fixed_01_23,fixed_02_13,fixed_03_12",
        "target_modes": "midpoint,seed_left,seed_right_complement,jitter_midpoint",
        "restarts_per_cell": "4",
        "atom_steps": "80",
        "atom_sample_count": "64",
        "temperature": "0.05",
        "alpha_pair": "0.05",
        "alpha_selected_defect": "0.25",
        "alpha_block_defect": "0.05",
        "alpha_fourier": "0.001",
        "selected_defect_count": "12",
        "selected_dynamic_defect_count": "4",
        "selected_fourier_count": "8",
        "alpha_size": "1000.0",
        "perturb_atom_moves": "8",
        "repair_budget": "6",
        "repair_swap_sample_count": "96",
        "max_wall_time_ms_per_candidate": "12000",
        "shard_count": "40",
        "max_parallel": "40",
        "base_seed": "167925",
    },
}


INPUT_ORDER = [
    "run_label",
    "candidate_count",
    "tuple_classes",
    "representatives_per_tuple",
    "frontier_files",
    "modes",
    "split_modes",
    "target_modes",
    "restarts_per_cell",
    "atom_steps",
    "atom_sample_count",
    "temperature",
    "alpha_pair",
    "alpha_size",
    "perturb_atom_moves",
    "repair_budget",
    "repair_swap_sample_count",
    "max_wall_time_ms_per_candidate",
    "shard_count",
    "max_parallel",
    "base_seed",
]


def validate(values):
    for key in INPUT_ORDER:
        if key in {"run_label", "tuple_classes", "frontier_files", "modes", "split_modes", "target_modes"}:
            continue
        if float(values[key]) < 0:
            raise ValueError("{} must be nonnegative".format(key))
    if int(values["candidate_count"]) < 1:
        raise ValueError("candidate_count must be positive")
    if int(values["shard_count"]) < 1:
        raise ValueError("shard_count must be positive")
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
    parser = argparse.ArgumentParser(description="Build or dispatch p167 quotient/profile lift probe runs.")
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
