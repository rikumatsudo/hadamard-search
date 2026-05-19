#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
import random
import statistics
import time
from pathlib import Path

import p167_frontier_repair_benchmark as base
import p167_pair_profile_lift_smoke as pair_lift


P_DEFAULT = 167
OUTPUT_ROOT_DEFAULT = "outputs/p167_quotient_profile_lift_probe"
EXPERIMENT_DEFAULT = "p167_quotient_profile_lift_probe"
FRONTIER_FILES_DEFAULT = ",".join(
    [
        "configs/fixtures/p167_local_branching_wall_candidates.jsonl",
        "configs/fixtures/p167_softwall_escape_frontier_candidates.jsonl",
        "configs/fixtures/p167_targeted_deep_frontier_repair_candidates.jsonl",
        "configs/fixtures/p167_frontier_repair_seed_candidates.jsonl",
        "configs/fixtures/p167_focused_nearhit_candidates.jsonl",
        "configs/fixtures/benchmark_traps/p167_score164_176.jsonl",
    ]
)
TUPLE_CLASSES_DEFAULT = "p167_c01,p167_c05,p167_c09"
MODES_DEFAULT = "atom_random_balanced,atom_pair_profile_guided,atom_profile_lift_from_source"
ATOM_BASIS_DEFAULT = "antipodal_pm"
SOLVER_MODE_DEFAULT = "heuristic_atom_lift"
CONSTRAINT_FAMILY_DEFAULT = "pair_profile_selected_defect_per_block_fourier"
SPLITS = pair_lift.SPLITS
THRESHOLDS = (1000, 500, 300, 240, 200, 180, 160, 120, 100)
TRIG_TABLE_CACHE = {}


def ensure_dir(path):
    if path:
        os.makedirs(path, exist_ok=True)


def parse_csv(text, cast=str):
    if isinstance(text, (list, tuple)):
        return [cast(x) for x in text]
    return [cast(part.strip()) for part in str(text).split(",") if part.strip()]


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def stable_int(text):
    digest = hashlib.sha256(str(text).encode("utf-8")).hexdigest()
    return int(digest[:16], 16)


def median(values):
    vals = [float(v) for v in values if v is not None]
    return statistics.median(vals) if vals else None


def rate(rows, pred):
    return sum(1 for row in rows if pred(row)) / float(len(rows)) if rows else 0.0


class AtomBasis:
    """Antipodal atom basis.

    Atom 0 is the singleton {0}.  For x=1..(p-1)/2, atom x is {x, -x}.
    Per block, each nonzero atom can be in states none / +x / -x / both.
    """

    def __init__(self, p, basis_name=ATOM_BASIS_DEFAULT):
        if basis_name != ATOM_BASIS_DEFAULT:
            raise ValueError("unsupported atom basis {}".format(basis_name))
        self.p = int(p)
        self.basis_name = basis_name
        self.atoms = [{"atom_index": 0, "kind": "singleton_zero", "points": [0]}]
        for x in range(1, (self.p + 1) // 2):
            self.atoms.append({"atom_index": x, "kind": "antipodal_pair", "points": [x, (-x) % self.p]})
        self.point_to_atom = {}
        self.point_orientation = {}
        for atom in self.atoms:
            points = atom["points"]
            if atom["kind"] == "singleton_zero":
                self.point_to_atom[0] = atom["atom_index"]
                self.point_orientation[0] = "zero"
            else:
                plus, minus = points
                self.point_to_atom[plus] = atom["atom_index"]
                self.point_to_atom[minus] = atom["atom_index"]
                self.point_orientation[plus] = "plus"
                self.point_orientation[minus] = "minus"

    def summary(self):
        return {
            "atom_basis": self.basis_name,
            "p": self.p,
            "atom_count": len(self.atoms),
            "singleton_zero_count": 1,
            "antipodal_pair_count": len(self.atoms) - 1,
            "state_model": "per block: none/+x/-x/both for nonzero atoms; zero singleton optional",
        }

    def atom_points(self, atom_index):
        return list(self.atoms[int(atom_index)]["points"])

    def state_counts_for_blocks(self, blocks):
        counts = {"zero_selected": 0, "none": 0, "plus": 0, "minus": 0, "both": 0}
        for block in blocks:
            block = set(block)
            if 0 in block:
                counts["zero_selected"] += 1
            for atom in self.atoms[1:]:
                plus, minus = atom["points"]
                has_plus = plus in block
                has_minus = minus in block
                if has_plus and has_minus:
                    counts["both"] += 1
                elif has_plus:
                    counts["plus"] += 1
                elif has_minus:
                    counts["minus"] += 1
                else:
                    counts["none"] += 1
        return counts

    def valid_atom_state_blocks(self, blocks):
        seen_points = set(range(self.p))
        return all(all(int(x) in seen_points for x in block) for block in blocks)


def random_block_atom_balanced(p, size, basis, rng):
    points = set()
    atom_indices = list(range(1, len(basis.atoms)))
    rng.shuffle(atom_indices)
    if int(size) % 2 == 1 and rng.random() < 0.5:
        points.add(0)
    while len(points) < int(size):
        remaining = int(size) - len(points)
        atom_index = rng.choice(atom_indices)
        choices = [x for x in basis.atom_points(atom_index) if x not in points]
        if not choices:
            continue
        if remaining >= 2 and len(choices) == 2 and rng.random() < 0.35:
            points.update(choices)
        else:
            points.add(rng.choice(choices))
    return points


def random_blocks_atom_balanced(p, ks, basis, rng):
    return [random_block_atom_balanced(p, int(k), basis, rng) for k in ks]


def sample_atom_swap(blocks, basis, rng):
    bidx = rng.randrange(4)
    block = set(blocks[bidx])
    if not block:
        return None
    if rng.random() < 0.35:
        single_atoms = []
        for atom in basis.atoms[1:]:
            p0, p1 = atom["points"]
            if (p0 in block) ^ (p1 in block):
                single_atoms.append(atom)
        if single_atoms:
            atom = rng.choice(single_atoms)
            p0, p1 = atom["points"]
            remove = p0 if p0 in block else p1
            add = p1 if remove == p0 else p0
            return {"block": bidx, "removes": [remove], "adds": [add], "kind": "orientation_flip"}
    remove_atom = rng.choice([atom for atom in basis.atoms if any(x in block for x in atom["points"])])
    remove_points = [x for x in remove_atom["points"] if x in block]
    rng.shuffle(remove_points)
    remove_count = 2 if len(remove_points) >= 2 and rng.random() < 0.35 else 1
    removes = remove_points[:remove_count]
    add_atoms = [atom for atom in basis.atoms if sum(1 for x in atom["points"] if x not in block) >= remove_count]
    if not add_atoms:
        return None
    add_atom = rng.choice(add_atoms)
    add_points = [x for x in add_atom["points"] if x not in block]
    rng.shuffle(add_points)
    adds = add_points[:remove_count]
    if set(removes) == set(adds):
        return None
    return {"block": bidx, "removes": removes, "adds": adds, "kind": "atom_swap_{}".format(remove_count)}


def apply_move(blocks, move):
    out = [set(block) for block in blocks]
    bidx = int(move["block"])
    for x in move["removes"]:
        out[bidx].remove(int(x))
    for x in move["adds"]:
        out[bidx].add(int(x))
    return out


def block_sizes_valid(blocks, ks):
    return [len(block) for block in blocks] == [int(k) for k in ks]


def score_blocks(p, blocks, lam):
    return int(base.P37.score_blocks(int(p), [set(block) for block in blocks], int(lam)))


def rho_vector(p, blocks, lam):
    return base.rho_vector(int(p), [set(block) for block in blocks], int(lam))


def diff_counts_by_block(p, blocks):
    return base.P37.all_diff_counts(int(p), [set(block) for block in blocks], include_zero=False)


def top_rho_coords(rho, count):
    if int(count) <= 0:
        return []
    coords = sorted(range(1, len(rho)), key=lambda d: (-abs(int(rho[d])), d))
    return [int(d) for d in coords[: int(count)]]


def selected_difference_loss(rho, coords, dynamic_count):
    selected = set(int(d) for d in coords)
    selected.update(top_rho_coords(rho, int(dynamic_count)))
    return int(sum(int(rho[d]) * int(rho[d]) for d in selected if d != 0)), sorted(selected)


def per_block_defect_loss(p, blocks, source_counts, coords):
    if not coords:
        return 0
    counts = diff_counts_by_block(p, blocks)
    loss = 0
    for bidx in range(4):
        for d in coords:
            delta = int(counts[bidx][d]) - int(source_counts[bidx][d])
            loss += delta * delta
    return int(loss)


def trig_tables(p, freqs):
    key = (int(p), tuple(int(u) for u in freqs))
    if key in TRIG_TABLE_CACHE:
        return TRIG_TABLE_CACHE[key]
    tables = {}
    for u in key[1]:
        cos_row = [math.cos(2.0 * math.pi * float(u * x) / float(p)) for x in range(p)]
        sin_row = [math.sin(2.0 * math.pi * float(u * x) / float(p)) for x in range(p)]
        tables[int(u)] = (cos_row, sin_row)
    TRIG_TABLE_CACHE[key] = tables
    return tables


def fourier_power_residuals(p, blocks, freqs, tables=None):
    if not freqs:
        return {}
    if tables is None:
        tables = trig_tables(p, freqs)
    residuals = {}
    for u in freqs:
        cos_row, sin_row = tables[int(u)]
        total_power = 0.0
        for block in blocks:
            re = 0.0
            im = 0.0
            for x in block:
                # Fourier convention: hat f(u)=sum_x f(x) exp(-2*pi*i*u*x/p).
                re += cos_row[int(x) % int(p)]
                im -= sin_row[int(x) % int(p)]
            total_power += re * re + im * im
        residuals[int(u)] = total_power - float(p)
    return residuals


def select_fourier_freqs(p, source_blocks, count):
    if int(count) <= 0:
        return []
    freqs = list(range(1, (int(p) // 2) + 1))
    residuals = fourier_power_residuals(p, source_blocks, freqs)
    return sorted(freqs, key=lambda u: (-abs(float(residuals[u])), u))[: int(count)]


def fourier_selected_loss(p, blocks, freqs, tables=None):
    if not freqs:
        return 0.0
    residuals = fourier_power_residuals(p, blocks, freqs, tables=tables)
    return float(sum(float(v) * float(v) for v in residuals.values()))


def profile_loss_for_targets(p, blocks, split_mode, left_target, right_target):
    if split_mode == "none" or not left_target or not right_target:
        return 0
    left_pair, right_pair = pair_lift.split_pairs(split_mode)
    left_profile = pair_lift.pair_profile(p, blocks, left_pair)
    right_profile = pair_lift.pair_profile(p, blocks, right_pair)
    return int(pair_lift.pair_profile_loss(left_profile, left_target) + pair_lift.pair_profile_loss(right_profile, right_target))


def split_pair_residual(p, blocks, lam, split_mode):
    if split_mode == "none":
        return None
    return int(pair_lift.split_pair_residual_loss(p, blocks, lam, split_mode))


def make_constraint_context(args, p, source_blocks, lam):
    source_rho = rho_vector(p, source_blocks, lam)
    selected_coords = top_rho_coords(source_rho, int(args.selected_defect_count))
    fourier_freqs = select_fourier_freqs(p, source_blocks, int(args.selected_fourier_count))
    return {
        "source_rho": source_rho,
        "source_counts": diff_counts_by_block(p, source_blocks),
        "selected_defect_coords": selected_coords,
        "selected_fourier_freqs": fourier_freqs,
        "fourier_tables": trig_tables(p, fourier_freqs),
    }


def objective_components(p, blocks, lam, split_mode, left_target, right_target, context, args):
    score = score_blocks(p, blocks, lam)
    target_loss = profile_loss_for_targets(p, blocks, split_mode, left_target, right_target)
    rho = rho_vector(p, blocks, lam)
    selected_loss, selected_coords_used = selected_difference_loss(
        rho,
        context.get("selected_defect_coords", []),
        int(args.selected_dynamic_defect_count),
    )
    per_block_loss = per_block_defect_loss(
        p,
        blocks,
        context.get("source_counts", []),
        context.get("selected_defect_coords", []),
    )
    fourier_loss = fourier_selected_loss(
        p,
        blocks,
        context.get("selected_fourier_freqs", []),
        tables=context.get("fourier_tables"),
    )
    obj = (
        float(score)
        + float(args.alpha_pair) * float(target_loss)
        + float(args.alpha_selected_defect) * float(selected_loss)
        + float(args.alpha_block_defect) * float(per_block_loss)
        + float(args.alpha_fourier) * float(fourier_loss)
    )
    return {
        "objective": float(obj),
        "score": int(score),
        "target_loss": int(target_loss),
        "selected_defect_loss": int(selected_loss),
        "per_block_defect_loss": int(per_block_loss),
        "fourier_selected_loss": float(fourier_loss),
        "selected_defect_coords_used": selected_coords_used,
    }


def perturb_atom_blocks(blocks, basis, moves, rng):
    out = [set(block) for block in blocks]
    for _ in range(int(moves)):
        move = sample_atom_swap(out, basis, rng)
        if move is not None:
            out = apply_move(out, move)
    return out


def make_targets(args, p, source_blocks, lam, split_mode, target_mode, rng):
    if split_mode == "none" or target_mode == "none":
        return [], []
    return pair_lift.make_pair_targets(p, source_blocks, lam, target_mode, split_mode, rng)


def initial_blocks_for_mode(args, mode, p, ks, source_blocks, basis, rng):
    if mode == "atom_random_balanced":
        return random_blocks_atom_balanced(p, ks, basis, rng)
    if mode == "atom_pair_profile_guided":
        return random_blocks_atom_balanced(p, ks, basis, rng)
    if mode == "atom_profile_lift_from_source":
        return perturb_atom_blocks(source_blocks, basis, int(args.perturb_atom_moves), rng)
    raise ValueError("unknown mode {}".format(mode))


def atom_lift(args, mode, p, lam, ks, source_blocks, split_mode, target_mode, seed):
    rng = random.Random(int(seed))
    basis = AtomBasis(p, args.atom_basis)
    left_target, right_target = make_targets(args, p, source_blocks, lam, split_mode, target_mode, rng)
    constraint_context = make_constraint_context(args, p, source_blocks, lam)
    blocks = initial_blocks_for_mode(args, mode, p, ks, source_blocks, basis, rng)
    start_components = objective_components(p, blocks, lam, split_mode, left_target, right_target, constraint_context, args)
    best_blocks = [set(block) for block in blocks]
    best_components = dict(start_components)
    current_obj = float(start_components["objective"])
    accepted = 0
    uphill = 0
    started = time.time()
    for _step in range(int(args.atom_steps)):
        if (time.time() - started) * 1000.0 >= float(args.max_wall_time_ms_per_candidate):
            break
        best_move = None
        for _ in range(int(args.atom_sample_count)):
            move = sample_atom_swap(blocks, basis, rng)
            if move is None:
                continue
            candidate_blocks = apply_move(blocks, move)
            components = objective_components(p, candidate_blocks, lam, split_mode, left_target, right_target, constraint_context, args)
            delta = float(components["objective"]) - float(current_obj)
            if best_move is None or delta < best_move["delta_obj"]:
                best_move = {
                    "move": move,
                    "blocks": candidate_blocks,
                    "components": components,
                    "delta_obj": delta,
                }
        if best_move is None:
            break
        accept = False
        if best_move["delta_obj"] <= 0:
            accept = True
        elif float(args.temperature) > 0:
            prob = math.exp(-best_move["delta_obj"] / max(1e-9, float(args.temperature)))
            accept = rng.random() < prob
        if not accept:
            break
        blocks = [set(block) for block in best_move["blocks"]]
        current_obj = float(best_move["components"]["objective"])
        accepted += 1
        if best_move["delta_obj"] > 0:
            uphill += 1
        if (
            int(best_move["components"]["score"]),
            float(best_move["components"]["objective"]),
        ) < (
            int(best_components["score"]),
            float(best_components["objective"]),
        ):
            best_blocks = [set(block) for block in blocks]
            best_components = dict(best_move["components"])
    return {
        "blocks": best_blocks,
        "objective_before_lift": float(start_components["objective"]),
        "objective_after_lift": float(best_components["objective"]),
        "target_loss_before": int(start_components["target_loss"]),
        "target_loss_after": int(best_components["target_loss"]),
        "selected_defect_loss_before": int(start_components["selected_defect_loss"]),
        "selected_defect_loss_after": int(best_components["selected_defect_loss"]),
        "per_block_defect_loss_before": int(start_components["per_block_defect_loss"]),
        "per_block_defect_loss_after": int(best_components["per_block_defect_loss"]),
        "fourier_selected_loss_before": float(start_components["fourier_selected_loss"]),
        "fourier_selected_loss_after": float(best_components["fourier_selected_loss"]),
        "score_before_lift": int(start_components["score"]),
        "score_after_lift": int(best_components["score"]),
        "accepted_atom_steps": int(accepted),
        "uphill_atom_steps": int(uphill),
        "atom_state_counts": basis.state_counts_for_blocks(best_blocks),
        "selected_defect_coords": constraint_context.get("selected_defect_coords", []),
        "selected_defect_coords_used": best_components.get("selected_defect_coords_used", []),
        "selected_fourier_freqs": constraint_context.get("selected_fourier_freqs", []),
    }


def run_repair(p, blocks, lam, args, seed):
    if int(args.repair_budget) <= 0:
        return [set(block) for block in blocks], score_blocks(p, blocks, lam), 0, False
    return base.P37.repair_candidate(
        p,
        [set(block) for block in blocks],
        int(lam),
        int(args.repair_budget),
        int(seed),
        int(args.repair_swap_sample_count),
    )


def flags(prefix, score):
    return {"{}_score_le_{}".format(prefix, threshold): bool(int(score) <= threshold) for threshold in THRESHOLDS}


def task_key(candidate, mode, split_mode, target_mode, restart_id):
    return "{}::{}::{}::{}::{}".format(candidate["frontier_candidate_id"], mode, split_mode, target_mode, restart_id)


def shard_tasks(candidates, modes, split_modes, target_modes, restarts, shard_id, shard_count):
    tasks = []
    for candidate in candidates:
        for mode in modes:
            mode_splits = ["none"] if mode == "atom_random_balanced" else split_modes
            mode_targets = ["none"] if mode == "atom_random_balanced" else target_modes
            for split_mode in mode_splits:
                for target_mode in mode_targets:
                    for restart_id in range(int(restarts)):
                        key = task_key(candidate, mode, split_mode, target_mode, restart_id)
                        if stable_int(key) % int(shard_count) == int(shard_id):
                            tasks.append((candidate, mode, split_mode, target_mode, restart_id))
    return tasks


def run_one(candidate, mode, split_mode, target_mode, restart_id, args):
    p = int(args.p)
    source_blocks = [set(int(x) for x in block) for block in candidate["blocks"]]
    lam = int(candidate["lambda"])
    ks = [int(x) for x in candidate["ks"]]
    source_score = score_blocks(p, source_blocks, lam)
    seed = (
        int(args.base_seed)
        + int(args.shard_id) * 10000000
        + stable_int(candidate["frontier_candidate_id"]) % 100000
        + stable_int(mode) % 10000
        + stable_int(split_mode) % 10000
        + stable_int(target_mode) % 10000
        + int(restart_id)
    )
    started = time.time()
    lift = atom_lift(args, mode, p, lam, ks, source_blocks, split_mode, target_mode, seed)
    generated = lift["blocks"]
    score_generated = score_blocks(p, generated, lam)
    repaired, score_after, repair_steps, repair_improved = run_repair(p, generated, lam, args, seed + 99991)
    elapsed_ms = int(round((time.time() - started) * 1000.0))
    basis = AtomBasis(p, args.atom_basis)
    row = {
        "run_id": args.run_id,
        "shard_id": int(args.shard_id),
        "task_id": task_key(candidate, mode, split_mode, target_mode, restart_id),
        "source_candidate_id": candidate["frontier_candidate_id"],
        "tuple_class": candidate["tuple_class"],
        "frontier_bucket": candidate.get("frontier_bucket", ""),
        "mode": mode,
        "seed": int(seed),
        "atom_basis": args.atom_basis,
        "atom_count": len(basis.atoms),
        "singleton_zero_state": json.dumps([bool(0 in block) for block in generated], separators=(",", ":")),
        "split_mode": split_mode,
        "target_mode": target_mode,
        "solver_mode": args.solver_mode,
        "constraint_family": args.constraint_family,
        "lambda": int(lam),
        "ks": ks,
        "source_score": int(source_score),
        "score_before_lift": int(lift["score_before_lift"]),
        "score_generated": int(score_generated),
        "score_after_repair": int(score_after),
        "score_improvement_from_generated": int(score_generated) - int(score_after),
        "score_improvement_from_source": int(source_score) - int(score_after),
        "objective_before_lift": float(lift["objective_before_lift"]),
        "objective_after_lift": float(lift["objective_after_lift"]),
        "target_loss_before": int(lift["target_loss_before"]),
        "target_loss_after": int(lift["target_loss_after"]),
        "selected_defect_loss_before": int(lift["selected_defect_loss_before"]),
        "selected_defect_loss_after": int(lift["selected_defect_loss_after"]),
        "per_block_defect_loss_before": int(lift["per_block_defect_loss_before"]),
        "per_block_defect_loss_after": int(lift["per_block_defect_loss_after"]),
        "fourier_selected_loss_before": float(lift["fourier_selected_loss_before"]),
        "fourier_selected_loss_after": float(lift["fourier_selected_loss_after"]),
        "selected_defect_coords": lift["selected_defect_coords"],
        "selected_defect_coords_used": lift["selected_defect_coords_used"],
        "selected_fourier_freqs": lift["selected_fourier_freqs"],
        "pair_residual_generated": split_pair_residual(p, generated, lam, split_mode),
        "accepted_atom_steps": int(lift["accepted_atom_steps"]),
        "uphill_atom_steps": int(lift["uphill_atom_steps"]),
        "block_sizes_valid": bool(block_sizes_valid(generated, ks)),
        "atom_state_valid": bool(basis.valid_atom_state_blocks(generated)),
        "score0_generated": bool(int(score_generated) == 0),
        "score0_after_repair": bool(int(score_after) == 0),
        "repair_operator": "score_only_1swap_greedy" if int(args.repair_budget) > 0 else "none",
        "repair_steps_used": int(repair_steps),
        "repair_improved": bool(repair_improved),
        "wall_time_ms": int(elapsed_ms),
        "canonical_hash_source": candidate["canonical_hash_before"],
        "canonical_hash_generated": base.canonical_hash(generated),
        "canonical_hash_after": base.canonical_hash(repaired),
        "source_reproduction_generated": bool(base.canonical_hash(generated) == candidate["canonical_hash_before"]),
        "source_reproduction_after": bool(base.canonical_hash(repaired) == candidate["canonical_hash_before"]),
        "atom_state_counts": lift["atom_state_counts"],
        "blocks_generated": base.candidate_json(generated, p, ks, lam)["blocks"],
        "blocks_after_repair": base.candidate_json(repaired, p, ks, lam)["blocks"],
    }
    row.update(flags("generated", score_generated))
    row.update(flags("after_repair", score_after))
    return row


def summarize_group(rows, keys):
    buckets = {}
    for row in rows:
        key = tuple(row.get(k) for k in keys)
        buckets.setdefault(key, []).append(row)
    out = []
    for key, group in sorted(buckets.items(), key=lambda item: item[0]):
        summary = {keys[i]: key[i] for i in range(len(keys))}
        summary["row_count"] = len(group)
        summary["best_score_generated"] = min(int(row["score_generated"]) for row in group) if group else None
        summary["best_score_after_repair"] = min(int(row["score_after_repair"]) for row in group) if group else None
        summary["median_score_generated"] = median(row["score_generated"] for row in group)
        summary["median_score_after_repair"] = median(row["score_after_repair"] for row in group)
        summary["best_target_loss_after"] = min(int(row["target_loss_after"]) for row in group) if group else None
        summary["median_target_loss_after"] = median(row["target_loss_after"] for row in group)
        summary["median_selected_defect_loss_after"] = median(row.get("selected_defect_loss_after") for row in group)
        summary["median_per_block_defect_loss_after"] = median(row.get("per_block_defect_loss_after") for row in group)
        summary["median_fourier_selected_loss_after"] = median(row.get("fourier_selected_loss_after") for row in group)
        summary["repair_improvement_rate"] = rate(group, lambda row: bool(row.get("repair_improved")))
        summary["source_reproduction_after_count"] = sum(1 for row in group if row.get("source_reproduction_after"))
        summary["diversity_hash_count"] = len({row["canonical_hash_after"] for row in group})
        summary["wall_time_ms_median"] = median(row["wall_time_ms"] for row in group)
        for threshold in THRESHOLDS:
            summary["generated_score_le_{}_count".format(threshold)] = sum(1 for row in group if int(row["score_generated"]) <= threshold)
            summary["generated_score_le_{}_rate".format(threshold)] = rate(group, lambda row, t=threshold: int(row["score_generated"]) <= t)
            summary["after_repair_score_le_{}_count".format(threshold)] = sum(1 for row in group if int(row["score_after_repair"]) <= threshold)
            summary["after_repair_score_le_{}_rate".format(threshold)] = rate(group, lambda row, t=threshold: int(row["score_after_repair"]) <= t)
        out.append(summary)
    return out


def best_rows(rows, limit=100):
    return sorted(rows, key=lambda row: (int(row["score_after_repair"]), int(row["score_generated"]), int(row["target_loss_after"])))[:limit]


def threshold_rows(rows, threshold):
    return [row for row in rows if int(row["score_generated"]) <= threshold or int(row["score_after_repair"]) <= threshold]


ROW_FIELDS = [
    "run_id",
    "shard_id",
    "task_id",
    "tuple_class",
    "source_candidate_id",
    "frontier_bucket",
    "mode",
    "seed",
    "atom_basis",
    "atom_count",
    "singleton_zero_state",
    "split_mode",
    "target_mode",
    "solver_mode",
    "constraint_family",
    "lambda",
    "ks",
    "source_score",
    "score_before_lift",
    "score_generated",
    "score_after_repair",
    "score_improvement_from_generated",
    "score_improvement_from_source",
    "objective_before_lift",
    "objective_after_lift",
    "target_loss_before",
    "target_loss_after",
    "selected_defect_loss_before",
    "selected_defect_loss_after",
    "per_block_defect_loss_before",
    "per_block_defect_loss_after",
    "fourier_selected_loss_before",
    "fourier_selected_loss_after",
    "selected_defect_coords",
    "selected_defect_coords_used",
    "selected_fourier_freqs",
    "pair_residual_generated",
    "accepted_atom_steps",
    "uphill_atom_steps",
    "block_sizes_valid",
    "atom_state_valid",
    "score0_generated",
    "score0_after_repair",
    "repair_operator",
    "repair_steps_used",
    "repair_improved",
    "wall_time_ms",
    "canonical_hash_source",
    "canonical_hash_generated",
    "canonical_hash_after",
    "source_reproduction_generated",
    "source_reproduction_after",
] + ["generated_score_le_{}".format(t) for t in THRESHOLDS] + ["after_repair_score_le_{}".format(t) for t in THRESHOLDS]


def write_readme(out_dir, config, rows, tuple_mode_summary, split_mode_summary, target_mode_summary):
    non_source = [row for row in rows if not row.get("source_reproduction_after")]
    best = best_rows(rows, 10)
    non_source_best = best_rows(non_source, 10)
    lines = [
        "# p167 quotient/profile lift probe",
        "",
        "This is a representation probe over antipodal atoms `{x,-x}`. It is not a filter, classifier, reranker, or Hadamard 668 success claim.",
        "",
        "## Run",
        "",
        "- run_id: `{}`".format(config["run_id"]),
        "- row_count: `{}`".format(len(rows)),
        "- candidate_count: `{}`".format(config["candidate_count"]),
        "- atom_basis: `{}`".format(config["atom_basis"]),
        "- modes: `{}`".format(config["modes"]),
        "- split_modes: `{}`".format(config["split_modes"]),
        "- target_modes: `{}`".format(config["target_modes"]),
        "- atom_steps: `{}`".format(config["atom_steps"]),
        "- atom_sample_count: `{}`".format(config["atom_sample_count"]),
        "- constraint_family: `{}`".format(config["constraint_family"]),
        "- alpha_selected_defect / alpha_block_defect / alpha_fourier: `{}` / `{}` / `{}`".format(
            config["alpha_selected_defect"],
            config["alpha_block_defect"],
            config["alpha_fourier"],
        ),
        "- selected_defect_count / selected_dynamic_defect_count / selected_fourier_count: `{}` / `{}` / `{}`".format(
            config["selected_defect_count"],
            config["selected_dynamic_defect_count"],
            config["selected_fourier_count"],
        ),
        "- repair_budget: `{}`".format(config["repair_budget"]),
        "",
        "## Direct Answers",
        "",
        "1. Did atom/quotient representation produce a non-source candidate <=300: `{}`".format(any(int(row["score_after_repair"]) <= 300 for row in non_source)),
        "2. Did any non-source candidate reach <=240/200/180/160: `{}`".format(any(int(row["score_after_repair"]) <= 240 for row in non_source)),
        "3. Did c01/c05 improve relative to known walls: check `tuple_mode_summary.csv`; improvement is `score_improvement_from_source > 0` only when source score is beaten.",
        "4. Did c09 remain benchmark/control: compare c09 rows in `tuple_mode_summary.csv`.",
        "5. Best mode is the row with lowest `best_score_after_repair` in `tuple_mode_summary.csv`.",
        "6. Best split/target pair is summarized in `split_mode_summary.csv` and `target_mode_summary.csv`.",
        "7. Source reproduction after repair count: `{}`".format(sum(1 for row in rows if row.get("source_reproduction_after"))),
        "8. Did short repair help: `{}`".format(any(bool(row.get("repair_improved")) for row in rows)),
        "9. Constraint verdict: selected-difference, per-block defect, and selected Fourier losses are generation-time guidance terms; compare their loss columns against score in the CSV summaries.",
        "10. Score0 appeared: `{}`".format(any(int(row["score_generated"]) == 0 or int(row["score_after_repair"]) == 0 for row in rows)),
        "",
        "## Best Rows",
        "",
        base.markdown_table(best, ["tuple_class", "mode", "source_score", "score_generated", "score_after_repair", "split_mode", "target_mode", "target_loss_after", "repair_steps_used"], limit=10),
        "",
        "## Best Non-Source Rows",
        "",
        base.markdown_table(non_source_best, ["tuple_class", "mode", "source_score", "score_generated", "score_after_repair", "split_mode", "target_mode", "target_loss_after", "repair_steps_used"], limit=10),
        "",
        "## Tuple Mode Summary",
        "",
        base.markdown_table(tuple_mode_summary, ["tuple_class", "mode", "row_count", "best_score_generated", "best_score_after_repair", "median_score_after_repair", "median_selected_defect_loss_after", "median_per_block_defect_loss_after", "median_fourier_selected_loss_after", "source_reproduction_after_count", "diversity_hash_count"], limit=30),
        "",
        "## Split Summary",
        "",
        base.markdown_table(split_mode_summary, ["split_mode", "mode", "row_count", "best_score_after_repair", "median_score_after_repair", "diversity_hash_count"], limit=30),
        "",
        "## Target Summary",
        "",
        base.markdown_table(target_mode_summary, ["target_mode", "mode", "row_count", "best_score_after_repair", "median_score_after_repair", "diversity_hash_count"], limit=30),
        "",
    ]
    with open(os.path.join(out_dir, "README.md"), "w") as f:
        f.write("\n".join(lines))


def write_next_actions(out_dir, rows):
    non_source = [row for row in rows if not row.get("source_reproduction_after")]
    best = best_rows(non_source or rows, 5)
    lines = [
        "# Next actions",
        "",
        "1. If non-source candidates reach <=300, deepen the best mode/split/target cell.",
        "2. If target loss improves but score remains high, add per-block defect, selected-difference, or Fourier constraints to the atom objective.",
        "3. If source reproduction dominates, increase atom perturbation and add anti-reproduction constraints for source-lift mode.",
        "4. If random atom mode is weak, keep it only as calibration and focus on source/profile lift.",
        "",
        "Best candidate rows:",
        "",
        base.markdown_table(best, ["tuple_class", "mode", "source_score", "score_generated", "score_after_repair", "split_mode", "target_mode", "target_loss_after"], limit=5),
        "",
    ]
    with open(os.path.join(out_dir, "next_actions.md"), "w") as f:
        f.write("\n".join(lines))


def write_outputs(args, rows, candidates, out_dir):
    ensure_dir(out_dir)
    tuple_mode_summary = summarize_group(rows, ["tuple_class", "mode"])
    split_mode_summary = summarize_group(rows, ["split_mode", "mode"])
    target_mode_summary = summarize_group(rows, ["target_mode", "mode"])
    config = {
        "experiment_name": args.experiment_name,
        "run_id": args.run_id,
        "candidate_count": len(candidates),
        "row_count": len(rows),
        "frontier_files": args.frontier_files,
        "tuple_classes": args.tuple_classes,
        "representatives_per_tuple": int(args.representatives_per_tuple),
        "atom_basis": args.atom_basis,
        "modes": args.modes,
        "split_modes": args.split_modes,
        "target_modes": args.target_modes,
        "solver_mode": args.solver_mode,
        "constraint_family": args.constraint_family,
        "restarts_per_cell": int(args.restarts_per_cell),
        "atom_steps": int(args.atom_steps),
        "atom_sample_count": int(args.atom_sample_count),
        "temperature": float(args.temperature),
        "alpha_pair": float(args.alpha_pair),
        "alpha_selected_defect": float(args.alpha_selected_defect),
        "alpha_block_defect": float(args.alpha_block_defect),
        "alpha_fourier": float(args.alpha_fourier),
        "selected_defect_count": int(args.selected_defect_count),
        "selected_dynamic_defect_count": int(args.selected_dynamic_defect_count),
        "selected_fourier_count": int(args.selected_fourier_count),
        "alpha_size": float(args.alpha_size),
        "perturb_atom_moves": int(args.perturb_atom_moves),
        "repair_budget": int(args.repair_budget),
        "repair_swap_sample_count": int(args.repair_swap_sample_count),
        "shard_id": int(args.shard_id),
        "shard_count": int(args.shard_count),
    }
    basis_summary = AtomBasis(int(args.p), args.atom_basis).summary()
    pair_lift.write_json(os.path.join(out_dir, "run_config.json"), config)
    pair_lift.write_json(os.path.join(out_dir, "actual_effective_config.json"), config)
    pair_lift.write_json(os.path.join(out_dir, "atom_basis_summary.json"), basis_summary)
    pair_lift.write_jsonl(os.path.join(out_dir, "candidate_list.jsonl"), candidates)
    pair_lift.write_jsonl(os.path.join(out_dir, "candidate_rows.jsonl"), rows)
    pair_lift.write_csv(os.path.join(out_dir, "candidate_rows.csv"), rows, ROW_FIELDS)
    for name, summary in (
        ("tuple_mode_summary", tuple_mode_summary),
        ("split_mode_summary", split_mode_summary),
        ("target_mode_summary", target_mode_summary),
    ):
        fields = sorted({k for row in summary for k in row})
        pair_lift.write_csv(os.path.join(out_dir, "{}.csv".format(name)), summary, fields)
        pair_lift.write_json(os.path.join(out_dir, "{}.json".format(name)), summary)
    pair_lift.write_jsonl(os.path.join(out_dir, "best_candidates.jsonl"), best_rows(rows, 100))
    for threshold in THRESHOLDS:
        pair_lift.write_jsonl(os.path.join(out_dir, "score_under_{}_candidates.jsonl".format(threshold)), threshold_rows(rows, threshold))
    score0_rows = [row for row in rows if int(row["score_generated"]) == 0 or int(row["score_after_repair"]) == 0]
    score0_dir = os.path.join(out_dir, "score0_candidate_jsons")
    for idx, row in enumerate(score0_rows):
        ensure_dir(score0_dir)
        candidate = {
            "v": int(args.p),
            "n": int(4 * int(args.p)),
            "ks": row["ks"],
            "lambda": int(row["lambda"]),
            "blocks": row["blocks_after_repair"],
        }
        pair_lift.write_json(os.path.join(score0_dir, "score0_{:04d}.json".format(idx)), candidate)
    pair_lift.write_jsonl(os.path.join(out_dir, "score0_candidates.jsonl"), score0_rows)
    pair_lift.write_json(os.path.join(out_dir, "validation_report.json"), {"score0_count": len(score0_rows), "validated_score0_count": 0})
    write_readme(out_dir, config, rows, tuple_mode_summary, split_mode_summary, target_mode_summary)
    write_next_actions(out_dir, rows)


def load_candidates(args):
    return pair_lift.load_lift_candidates(args)


def run_mode(args):
    candidates = load_candidates(args)
    modes = parse_csv(args.modes)
    split_modes = parse_csv(args.split_modes)
    target_modes = parse_csv(args.target_modes)
    tasks = shard_tasks(candidates, modes, split_modes, target_modes, int(args.restarts_per_cell), int(args.shard_id), int(args.shard_count))
    if args.smoke:
        tasks = tasks[: max(1, int(args.smoke_task_limit))]
    print(
        "quotient-profile-lift-start shard={}/{} candidates={} tasks={} modes={} splits={} targets={}".format(
            args.shard_id, args.shard_count, len(candidates), len(tasks), modes, split_modes, target_modes
        ),
        flush=True,
    )
    rows = []
    for idx, (candidate, mode, split_mode, target_mode, restart_id) in enumerate(tasks, start=1):
        print(
            "task {}/{} candidate={} tuple={} source_score={} mode={} split={} target={} restart={}".format(
                idx,
                len(tasks),
                candidate["frontier_candidate_id"],
                candidate["tuple_class"],
                candidate["initial_score"],
                mode,
                split_mode,
                target_mode,
                restart_id,
            ),
            flush=True,
        )
        rows.append(run_one(candidate, mode, split_mode, target_mode, restart_id, args))
    write_outputs(args, rows, candidates, args.out_dir)
    print("wrote {} quotient/profile rows to {}".format(len(rows), args.out_dir), flush=True)


def aggregate_mode(args):
    rows = []
    by_hash = {}
    for path in Path(args.aggregate_input_dir).rglob("candidate_rows.jsonl"):
        rows.extend(base.read_jsonl(str(path)))
    for path in Path(args.aggregate_input_dir).rglob("candidate_list.jsonl"):
        for row in base.read_jsonl(str(path)):
            by_hash[row["canonical_hash_before"]] = row
    candidates = list(by_hash.values())
    write_outputs(args, rows, candidates, args.out_dir)
    print("aggregated {} quotient/profile rows to {}".format(len(rows), args.out_dir), flush=True)


def parse_args():
    parser = argparse.ArgumentParser(description="p167 quotient/profile lift probe over antipodal atoms.")
    parser.add_argument("--p", type=int, default=P_DEFAULT)
    parser.add_argument("--frontier-files", default=FRONTIER_FILES_DEFAULT)
    parser.add_argument("--tuple-registry", default=base.TUPLE_REGISTRY_DEFAULT)
    parser.add_argument("--tuple-classes", default=TUPLE_CLASSES_DEFAULT)
    parser.add_argument("--frontier-count", "--candidate-count", dest="frontier_count", type=int, default=9)
    parser.add_argument("--representatives-per-tuple", type=int, default=3)
    parser.add_argument("--auto-tuple-representatives", action="store_true")
    parser.add_argument("--source-repair-budget", type=int, default=0)
    parser.add_argument("--source-repair-swap-sample-count", type=int, default=96)
    parser.add_argument("--modes", default=MODES_DEFAULT)
    parser.add_argument("--atom-basis", default=ATOM_BASIS_DEFAULT)
    parser.add_argument("--split-modes", default="fixed_01_23,fixed_02_13,fixed_03_12")
    parser.add_argument("--target-modes", default="midpoint,seed_left,seed_right_complement,jitter_midpoint")
    parser.add_argument("--solver-mode", default=SOLVER_MODE_DEFAULT)
    parser.add_argument("--constraint-family", default=CONSTRAINT_FAMILY_DEFAULT)
    parser.add_argument("--restarts-per-cell", type=int, default=4)
    parser.add_argument("--atom-steps", type=int, default=80)
    parser.add_argument("--atom-sample-count", type=int, default=64)
    parser.add_argument("--temperature", type=float, default=0.05)
    parser.add_argument("--alpha-pair", type=float, default=0.05)
    parser.add_argument("--alpha-selected-defect", type=float, default=0.25)
    parser.add_argument("--alpha-block-defect", type=float, default=0.05)
    parser.add_argument("--alpha-fourier", type=float, default=0.001)
    parser.add_argument("--selected-defect-count", type=int, default=12)
    parser.add_argument("--selected-dynamic-defect-count", type=int, default=4)
    parser.add_argument("--selected-fourier-count", type=int, default=8)
    parser.add_argument("--alpha-size", type=float, default=1000.0)
    parser.add_argument("--perturb-atom-moves", type=int, default=8)
    parser.add_argument("--repair-budget", type=int, default=6)
    parser.add_argument("--repair-swap-sample-count", type=int, default=96)
    parser.add_argument("--max-wall-time-ms-per-candidate", type=int, default=12000)
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--output-root", default=OUTPUT_ROOT_DEFAULT)
    parser.add_argument("--experiment-name", default=EXPERIMENT_DEFAULT)
    parser.add_argument("--run-id", default="")
    parser.add_argument("--base-seed", type=int, default=167914)
    parser.add_argument("--shard-id", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--smoke-task-limit", type=int, default=2)
    parser.add_argument("--aggregate", action="store_true")
    parser.add_argument("--aggregate-input-dir", default="")
    args = parser.parse_args()
    if not args.run_id:
        args.run_id = "{}-{}".format(args.experiment_name, now_stamp())
    if not args.out_dir:
        args.out_dir = os.path.join(args.output_root, args.run_id)
    return args


def main():
    args = parse_args()
    if args.aggregate:
        aggregate_mode(args)
    else:
        run_mode(args)


if __name__ == "__main__":
    main()
