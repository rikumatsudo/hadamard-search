from sage.all import *

import argparse
import json
import os
import shutil
import time


SCRIPT_NAME = "76_p167_stage3_survivor_deepening"
STAGE2_LIB_PATH = "sage/75_p167_stage2_survivor_deepening.sage"
DEFAULT_CONFIG = "configs/experiments/p167_stage3_survivor_deepening.yaml"
DEFAULT_TUPLE_REGISTRY = "configs/fixtures/p167_tuple_classes.json"
DEFAULT_STAGE2_ARTIFACT = "/tmp/hadamard-stage2-lite-40-aggregate"
DEFAULT_BENCHMARK_TRAPS = "configs/fixtures/benchmark_traps/p167_score164_176.jsonl"
DEFAULT_NEARHIT_FIXTURE = "configs/fixtures/p167_focused_nearhit_candidates.jsonl"


def load_stage2_lib():
    namespace = {"__name__": "stage2_lib"}
    with open(STAGE2_LIB_PATH) as f:
        code = compile(f.read(), STAGE2_LIB_PATH, "exec")
    exec(code, namespace)
    return namespace


S2 = load_stage2_lib()
S2["SCRIPT_NAME"] = SCRIPT_NAME

ensure_dir = S2["ensure_dir"]
json_safe = S2["json_safe"]
write_json = S2["write_json"]
write_jsonl = S2["write_jsonl"]
write_csv = S2["write_csv"]
read_jsonl = S2["read_jsonl"]
parse_list = S2["parse_list"]
parse_int_list = S2["parse_int_list"]
deterministic_seed = S2["deterministic_seed"]
stable_hash = S2["stable_hash"]
load_yaml = S2["load_yaml"]
file_sha256 = S2["file_sha256"]
load_tuple_registry = S2["load_tuple_registry"]
score_counts = S2["score_counts"]
total_diff_counts = S2["total_diff_counts"]
apply_move = S2["apply_move"]
apply_sparse_delta = S2["apply_sparse_delta"]
make_rng = S2["make_rng"]
state_hash = S2["state_hash"]
json_blocks = S2["json_blocks"]
choose_stage2_move = S2["choose_stage2_move"]
rows_by_key = S2["rows_by_key"]
median = S2["median"]
rate = S2["rate"]
summarize = S2["summarize"]


STAGE3_OPERATORS = (
    "survivor_baseline_score_only",
    "survivor_exact_joint_local_repair",
    "survivor_mixed_operator_adaptive",
    "survivor_pair_profile_movespace_filter",
)


def now_stamp():
    return time.strftime("%Y%m%d_%H%M")


def stage2_paths(stage2_artifact):
    root = stage2_artifact
    if not os.path.isdir(root):
        raise RuntimeError("Stage 2 artifact path does not exist: {}".format(root))
    paths = {
        "recommendations": os.path.join(root, "stage3_candidate_recommendations.jsonl"),
        "trajectory": os.path.join(root, "trajectory_level_records.jsonl"),
        "run": os.path.join(root, "run_level_records.jsonl"),
        "survivors": os.path.join(root, "input_stage2_survivors.jsonl"),
        "controls": os.path.join(root, "input_stage2_controls.jsonl"),
    }
    for name, path in paths.items():
        if not os.path.exists(path):
            raise RuntimeError("Stage 2 artifact missing {}: {}".format(name, path))
    return paths


def select_stage3_recommendations(rows, args):
    grouped = rows_by_key(rows, "recommendation")
    selected = []
    selected.extend(grouped.get("deep_search", [])[: int(args.deep_search_limit)])
    selected.extend(grouped.get("repair_target", [])[: int(args.repair_target_limit)])
    selected.extend(grouped.get("operator_benchmark", [])[: int(args.operator_benchmark_limit)])
    selected.extend(grouped.get("needs_more_diagnostics", [])[: int(args.needs_more_diagnostics_limit)])
    selected.extend(grouped.get("archive", [])[: int(args.archive_limit)])
    if int(args.total_candidate_limit) > 0:
        selected = selected[: int(args.total_candidate_limit)]
    return selected


def replay_stage2_best_blocks(candidate, trajectory, args):
    p = int(candidate["p"])
    ks = [int(k) for k in candidate["ks"]]
    lam = int(candidate["lambda"])
    blocks = [set(int(x) for x in block) for block in candidate["blocks"]]
    counts = total_diff_counts(p, blocks)
    initial_score = score_counts(counts, lam)
    best_score = int(initial_score)
    best_blocks = [set(block) for block in blocks]
    stage_name = trajectory.get("stage_name") or "p167_stage2"
    candidate_id = trajectory.get("candidate_id") or candidate.get("candidate_id")
    operator = trajectory.get("operator")
    restart_id = int(trajectory.get("restart_id") or 0)
    seed_base = int(args.stage2_seed_base)
    raw = "{}:{}:{}:{}".format(candidate_id, operator, restart_id, stage_name)
    run_seed = int(seed_base) + int(deterministic_seed(raw) % 1000000007)
    row_cfg = trajectory.get("row_level_config") or {}
    steps = int(row_cfg.get("steps") or args.stage2_replay_steps)
    sample_swaps = int(row_cfg.get("sample_swaps") or args.stage2_replay_sample_swaps)
    uphill_threshold = int(row_cfg.get("uphill_threshold") or args.uphill_threshold)
    operator_state = {}
    accepted = 0
    for step in range(1, steps + 1):
        rng = S2["seeded_rng"](run_seed + step * 1009)
        move, _target_d, _selected_operator, _selected_reason = choose_stage2_move(
            operator,
            blocks,
            counts,
            lam,
            p,
            rng,
            sample_swaps,
            uphill_threshold,
            operator_state,
        )
        if move is None:
            continue
        next_blocks = apply_move(blocks, move)
        if next_blocks is None:
            continue
        blocks = next_blocks
        counts = apply_sparse_delta(counts, move["delta"])
        accepted += 1
        score = score_counts(counts, lam)
        if score < best_score:
            best_score = int(score)
            best_blocks = [set(block) for block in blocks]
    recovered_hash = state_hash(best_blocks, p, ks)
    return {
        "blocks": best_blocks,
        "best_score": int(best_score),
        "accepted_moves_replayed": int(accepted),
        "recovered_hash": recovered_hash,
        "expected_hash": trajectory.get("best_state_hash"),
        "hash_match": recovered_hash == trajectory.get("best_state_hash"),
    }


def load_stage3_candidates(args, tuple_rows):
    paths = stage2_paths(args.stage2_artifact)
    recommendations = select_stage3_recommendations(read_jsonl(paths["recommendations"]), args)
    trajectory_by_id = {row.get("trajectory_id"): row for row in read_jsonl(paths["trajectory"])}
    run_by_id = {row.get("run_id"): row for row in read_jsonl(paths["run"])}
    input_candidates = read_jsonl(paths["survivors"]) + read_jsonl(paths["controls"])
    input_by_id = {row.get("candidate_id"): row for row in input_candidates}
    input_by_hash = {row.get("candidate_hash"): row for row in input_candidates}
    tuple_by_id = {row["tuple_class_id"]: row for row in tuple_rows}
    out = []
    for idx, rec in enumerate(recommendations, 1):
        trajectory = trajectory_by_id.get(rec.get("trajectory_id")) or trajectory_by_id.get(rec.get("run_id"))
        if not trajectory:
            continue
        candidate = input_by_id.get(trajectory.get("candidate_id")) or input_by_hash.get(trajectory.get("candidate_hash"))
        tuple_row = tuple_by_id.get(trajectory.get("tuple_class_id") or rec.get("tuple_class_id"))
        if not candidate or not tuple_row or not candidate.get("blocks"):
            continue
        replay = replay_stage2_best_blocks(candidate, trajectory, args)
        h = replay["recovered_hash"]
        recommendation = rec.get("recommendation") or "unknown"
        out.append(
            {
                "candidate_id": "stage3_{:03d}_{}".format(idx, h[:12]),
                "candidate_hash": h,
                "source": recommendation,
                "blocks": json_blocks(replay["blocks"]),
                "tuple_class_id": tuple_row["tuple_class_id"],
                "abs_row_sums": tuple_row["abs_row_sums"],
                "ks": tuple_row["ks"],
                "representative_tuple": tuple_row.get("representative_tuple", tuple_row["ks"]),
                "lambda": tuple_row["lambda"],
                "p": tuple_row["p"],
                "n": tuple_row["n"],
                "equivalence_definition": tuple_row.get("equivalence_definition"),
                "seed_family": trajectory.get("seed_family"),
                "operator_from_stage1": trajectory.get("operator_from_stage1"),
                "stage1_run_id": trajectory.get("stage1_run_id"),
                "stage1_trajectory_id": trajectory.get("stage1_trajectory_id"),
                "stage1_selection_reason": trajectory.get("stage1_selection_reason"),
                "stage1_best_score": trajectory.get("stage1_best_score"),
                "stage1_best_exactlike_score": trajectory.get("stage1_best_exactlike_score"),
                "stage1_best_closure_shell_score": trajectory.get("stage1_best_closure_shell_score"),
                "stage1_best_alignment_to_minus_rho": trajectory.get("stage1_best_alignment_to_minus_rho"),
                "stage1_best_state_hash": trajectory.get("stage1_best_state_hash"),
                "stage2_run_id": trajectory.get("run_id"),
                "stage2_trajectory_id": trajectory.get("trajectory_id"),
                "stage2_recommendation": recommendation,
                "stage2_selection_reason": rec.get("why_selected"),
                "stage2_best_score": rec.get("stage2_best_score") or trajectory.get("best_score"),
                "stage2_best_exactlike_score": rec.get("stage2_best_exactlike_score") or trajectory.get("best_exactlike_score"),
                "stage2_best_closure_shell_score": rec.get("stage2_best_closure_shell_score") or trajectory.get("best_closure_shell_score"),
                "stage2_best_alignment_to_minus_rho": rec.get("stage2_best_alignment") or trajectory.get("best_alignment_to_minus_rho"),
                "stage2_damage_score": rec.get("stage2_damage_score") or trajectory.get("damage_score"),
                "stage2_replay_hash": h,
                "stage2_replay_hash_match": replay["hash_match"],
                "stage2_replay_best_score": replay["best_score"],
                "stage2_replay_accepted_moves": replay["accepted_moves_replayed"],
                "candidate_lineage": {
                    "source": "stage2_recommendation_replay",
                    "stage2_recommendation": rec,
                    "stage2_trajectory": {
                        "run_id": trajectory.get("run_id"),
                        "trajectory_id": trajectory.get("trajectory_id"),
                        "candidate_lineage": trajectory.get("candidate_lineage"),
                    },
                    "stage2_replay": {key: value for key, value in replay.items() if key != "blocks"},
                },
            }
        )
    return out, []


def stage4_candidates(trajectory_rows, limit):
    rows = []
    for row in trajectory_rows:
        reasons = []
        if float(row.get("closure_shell_delta") or 0.0) > 0.0:
            reasons.append("closure_shell_improved")
        if float(row.get("alignment_delta") or 0.0) > 0.0:
            reasons.append("alignment_improved")
        if float(row.get("D_min_ratio_delta") or 0.0) < 0.0:
            reasons.append("D_min_ratio_decreased")
        if float(row.get("kappa_q99_delta") or 0.0) > 0.0:
            reasons.append("kappa_q99_improved")
        if float(row.get("damage_score") or 0.0) <= 0.35:
            reasons.append("low_damage")
        if float(row.get("hardening_score") or 0.0) <= 0.35:
            reasons.append("low_hardening")
        if float(row.get("support_mixing_score") or 0.0) > 0.10:
            reasons.append("support_mixing_positive")
        initial = float(row.get("initial_score") or 1)
        if float(row.get("score_delta_from_start") or 0.0) > 0.25 * initial:
            continue
        if len(reasons) < 4:
            continue
        rec = "production_deep_search"
        if float(row.get("damage_score") or 0.0) > 0.50:
            rec = "operator_benchmark"
        elif row.get("recommendation") == "repair_target":
            rec = "repair_target"
        rows.append(
            {
                "candidate_hash": row.get("candidate_hash"),
                "tuple_class_id": row.get("tuple_class_id"),
                "ks": row.get("ks"),
                "lambda": row.get("lambda"),
                "source": row.get("source"),
                "stage2_recommendation": row.get("source"),
                "stage3_best_operator": row.get("operator"),
                "stage3_best_score": row.get("best_score"),
                "stage3_best_exactlike_score": row.get("best_exactlike_score"),
                "stage3_best_closure_shell_score": row.get("best_closure_shell_score"),
                "stage3_best_alignment": row.get("best_alignment_to_minus_rho"),
                "stage3_damage_score": row.get("damage_score"),
                "run_id": row.get("run_id"),
                "trajectory_id": row.get("trajectory_id"),
                "best_state_hash": row.get("best_state_hash"),
                "recommendation": rec,
                "why_selected": reasons,
            }
        )
    rows.sort(
        key=lambda row: (
            -float(row.get("stage3_best_closure_shell_score") or 0.0),
            -float(row.get("stage3_best_exactlike_score") or 0.0),
            float(row.get("stage3_damage_score") or 0.0),
            float(row.get("stage3_best_score") or 10 ** 9),
        )
    )
    return rows[: int(limit)]


def candidate_summary_rows(trajectory_rows):
    out = []
    for h, group in sorted(rows_by_key(trajectory_rows, "candidate_hash").items()):
        best_score_row = min(group, key=lambda row: float(row.get("best_score") or 10 ** 12))
        best_shell_row = max(group, key=lambda row: float(row.get("best_closure_shell_score") or -10 ** 12))
        out.append(
            {
                "candidate_hash": h,
                "tuple_class_id": best_shell_row.get("tuple_class_id"),
                "source": best_shell_row.get("source"),
                "attempt_count": len(group),
                "best_score": best_score_row.get("best_score"),
                "best_score_operator": best_score_row.get("operator"),
                "best_closure_shell_score": best_shell_row.get("best_closure_shell_score"),
                "best_closure_operator": best_shell_row.get("operator"),
                "median_damage_score": median(row.get("damage_score") for row in group),
                "median_exactlike_score": median(row.get("best_exactlike_score") for row in group),
            }
        )
    return out


def stage3_hypotheses(trajectory_rows, stage4_rows):
    by_source = rows_by_key(trajectory_rows, "source")
    by_tuple = rows_by_key(trajectory_rows, "tuple_class_id")
    by_operator = rows_by_key(trajectory_rows, "operator")
    c05_c01 = by_tuple.get("p167_c05", []) + by_tuple.get("p167_c01", [])
    other = [row for row in trajectory_rows if row.get("tuple_class_id") not in ("p167_c05", "p167_c01")]
    mixed = by_operator.get("survivor_mixed_operator_adaptive", [])
    baseline = by_operator.get("survivor_baseline_score_only", [])
    exact_joint = by_operator.get("survivor_exact_joint_local_repair", [])
    pair_filter = by_operator.get("survivor_pair_profile_movespace_filter", [])
    best_score_row = min(trajectory_rows, key=lambda row: float(row.get("best_score") or 10 ** 12)) if trajectory_rows else None
    best_exact_row = max(trajectory_rows, key=lambda row: float(row.get("best_exactlike_score") or -1.0)) if trajectory_rows else None
    deep = by_source.get("deep_search", [])

    def med(rows, key):
        return median(row.get(key) for row in rows)

    return {
        "H_STAGE3_1_deep_search_persists": {
            "status": "supported" if deep and (med(deep, "closure_shell_delta") or 0.0) >= 0.0 else "inconclusive",
            "evidence": {"deep_search_count": len(deep), "median_closure_delta": med(deep, "closure_shell_delta")},
        },
        "H_STAGE3_2_c05_c01_promising": {
            "status": "supported" if c05_c01 and (not other or (med(c05_c01, "best_closure_shell_score") or 0.0) >= (med(other, "best_closure_shell_score") or 0.0)) else "inconclusive",
            "evidence": {"c05_c01_count": len(c05_c01), "other_count": len(other), "c05_c01_median_closure": med(c05_c01, "best_closure_shell_score"), "other_median_closure": med(other, "best_closure_shell_score")},
        },
        "H_STAGE3_3_mixed_beats_baseline": {
            "status": "supported" if mixed and baseline and (med(mixed, "best_closure_shell_score") or 0.0) > (med(baseline, "best_closure_shell_score") or 0.0) else ("inconclusive" if not baseline else "not_supported"),
            "evidence": {"mixed_count": len(mixed), "baseline_count": len(baseline), "mixed_median_closure": med(mixed, "best_closure_shell_score"), "baseline_median_closure": med(baseline, "best_closure_shell_score")},
        },
        "H_STAGE3_4_exact_joint_score_damage_tradeoff": {
            "status": "supported" if exact_joint and (med(exact_joint, "score_delta_from_start") or 0.0) < 0.0 and (med(exact_joint, "damage_score") or 0.0) >= 0.35 else "inconclusive",
            "evidence": {"exact_joint_count": len(exact_joint), "median_score_delta": med(exact_joint, "score_delta_from_start"), "median_damage": med(exact_joint, "damage_score")},
        },
        "H_STAGE3_5_pair_filter_safe": {
            "status": "supported" if pair_filter and (med(pair_filter, "damage_score") or 1.0) <= 0.50 else "inconclusive",
            "evidence": {"pair_filter_count": len(pair_filter), "median_damage": med(pair_filter, "damage_score")},
        },
        "H_STAGE3_6_best_score_not_exactlike": {
            "status": "supported" if best_score_row and best_exact_row and best_score_row.get("trajectory_id") != best_exact_row.get("trajectory_id") else "inconclusive",
            "evidence": {"best_score_trajectory": best_score_row.get("trajectory_id") if best_score_row else None, "best_exactlike_trajectory": best_exact_row.get("trajectory_id") if best_exact_row else None},
        },
        "H_STAGE3_7_stage4_candidates_available": {
            "status": "supported" if len(stage4_rows) > 0 else "not_supported",
            "evidence": {"stage4_candidate_count": len(stage4_rows)},
        },
        "H_STAGE3_8_low_score_trap_or_benchmark": {
            "status": "inconclusive" if not best_score_row else ("supported" if float(best_score_row.get("damage_score") or 0.0) >= 0.35 or float(best_score_row.get("false_basin_score") or 0.0) >= 0.35 else "not_supported"),
            "evidence": {"best_score": best_score_row.get("best_score") if best_score_row else None, "damage_score": best_score_row.get("damage_score") if best_score_row else None, "false_basin_score": best_score_row.get("best_false_basin_score") if best_score_row else None},
        },
    }


def write_stage3_summary(out_dir, trajectory_rows, stage4_rows, hypotheses, artifact_summary):
    tuple_summary = summarize(trajectory_rows, "tuple_class_id")
    operator_summary = summarize(trajectory_rows, "operator")
    tuple_sorted = sorted(tuple_summary, key=lambda row: float(row.get("closure_shell_score_median") or 0.0), reverse=True)
    operator_sorted = sorted(operator_summary, key=lambda row: (float(row.get("closure_shell_improvement_rate") or 0.0), -float(row.get("damage_rate") or 0.0)), reverse=True)
    best_score_row = min(trajectory_rows, key=lambda row: float(row.get("best_score") or 10 ** 12)) if trajectory_rows else None
    best_exact_row = max(trajectory_rows, key=lambda row: float(row.get("best_exactlike_score") or -1.0)) if trajectory_rows else None
    score0_count = sum(1 for row in trajectory_rows if int(row.get("best_score") or 1) == 0)
    lines = []
    lines.append("# p167 Stage 3 survivor deepening")
    lines.append("")
    lines.append("This is a Stage 3 survivor deepening diagnostic, not a Hadamard 668 construction run.")
    lines.append("")
    lines.append("Sampled diagnostics are not full certificates.")
    lines.append("")
    lines.append("## Scope")
    lines.append("")
    lines.append("- trajectory rows: `{}`".format(len(trajectory_rows)))
    lines.append("- Stage 4 recommendations: `{}`".format(len(stage4_rows)))
    lines.append("- score0 candidates: `{}`".format(score0_count))
    lines.append("- artifact bytes: `{}`".format(artifact_summary.get("artifact_total_bytes")))
    lines.append("")
    lines.append("## Hypotheses")
    lines.append("")
    for key in sorted(hypotheses):
        lines.append("- `{}`: `{}`".format(key, hypotheses[key].get("status")))
    lines.append("")
    lines.append("## Required Answers")
    lines.append("")
    lines.append("1. Stage 3 対象 candidate 数: `{}`.".format(len(set(row.get("candidate_hash") for row in trajectory_rows))))
    lines.append("2. p167_c05 / p167_c01 は有望か: `{}`.".format(hypotheses["H_STAGE3_2_c05_c01_promising"]["status"]))
    lines.append("3. 最良 operator: `{}` by closure improvement / damage tradeoff.".format(operator_sorted[0].get("operator") if operator_sorted else "NA"))
    lines.append("4. mixed_operator_adaptive は baseline より良かったか: `{}`.".format(hypotheses["H_STAGE3_3_mixed_beats_baseline"]["status"]))
    lines.append("5. exact_joint_local_repair の score/damage tradeoff: `{}`.".format(hypotheses["H_STAGE3_4_exact_joint_score_damage_tradeoff"]["status"]))
    lines.append("6. pair_profile_movespace_filter は安全 operator か: `{}`.".format(hypotheses["H_STAGE3_5_pair_filter_safe"]["status"]))
    lines.append("7. best score は `{}`.".format(best_score_row.get("best_score") if best_score_row else "NA"))
    lines.append("8. best score と exact-like metrics は一致したか: `{}`.".format("no" if best_score_row and best_exact_row and best_score_row.get("trajectory_id") != best_exact_row.get("trajectory_id") else "inconclusive"))
    lines.append("9. score0 candidate は出たか: `{}`。出た場合のみ 08/05/04 検証対象。".format("yes" if score0_count else "no"))
    lines.append("10. Stage 4 candidate は `{}` 件。".format(len(stage4_rows)))
    lines.append("11. Stage 4 は `{}` / `{}` を中心に深掘り。".format(tuple_sorted[0].get("tuple_class_id") if tuple_sorted else "NA", operator_sorted[0].get("operator") if operator_sorted else "NA"))
    lines.append("12. artifact size / runtime は artifact_size_summary と runtime_summary を参照。")
    lines.append("13. sampled diagnostic の限界: full certificate ではない。")
    lines.append("")
    lines.append("## Formula Notes")
    lines.append("")
    lines.append("- `S = sum_{d != 0} rho(d)^2`")
    lines.append("- `D_min_ratio = D_min_1 / S`")
    lines.append("- `kappa = -2g / q`")
    lines.append("- `alignment = <Delta rho, -rho> / (||Delta rho|| * ||rho||)`")
    with open(os.path.join(out_dir, "p167_stage3_survivor_deepening_summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def copy_if_exists(src, dst):
    if os.path.exists(src):
        shutil.copyfile(src, dst)


def postprocess_stage3_outputs(args):
    out_dir = args.out_dir
    copy_if_exists(os.path.join(out_dir, "input_stage2_survivors.jsonl"), os.path.join(out_dir, "input_stage3_candidates.jsonl"))
    copy_if_exists(os.path.join(out_dir, "stage3_candidate_recommendations.jsonl"), os.path.join(out_dir, "stage4_candidate_recommendations.jsonl"))
    copy_if_exists(os.path.join(out_dir, "stage3_candidate_summary.csv"), os.path.join(out_dir, "stage4_candidate_summary.csv"))
    copy_if_exists(os.path.join(out_dir, "stage3_candidate_summary.json"), os.path.join(out_dir, "stage4_candidate_summary.json"))
    copy_if_exists(os.path.join(out_dir, "stage2_artifact_policy_summary.md"), os.path.join(out_dir, "stage3_artifact_policy_summary.md"))

    trajectory_rows = read_jsonl(os.path.join(out_dir, "trajectory_level_records.jsonl")) if os.path.exists(os.path.join(out_dir, "trajectory_level_records.jsonl")) else []
    stage4_rows = read_jsonl(os.path.join(out_dir, "stage4_candidate_recommendations.jsonl")) if os.path.exists(os.path.join(out_dir, "stage4_candidate_recommendations.jsonl")) else []
    candidate_summary = candidate_summary_rows(trajectory_rows)
    write_csv(os.path.join(out_dir, "candidate_summary.csv"), candidate_summary)
    write_json(os.path.join(out_dir, "candidate_summary.json"), candidate_summary)

    hypotheses = stage3_hypotheses(trajectory_rows, stage4_rows)
    write_json(os.path.join(out_dir, "hypothesis_evaluation.json"), hypotheses)

    manifest_path = os.path.join(out_dir, "stage2_artifact_manifest.json")
    if os.path.exists(manifest_path):
        with open(manifest_path) as f:
            manifest = json.load(f)
        run_id = args.github_run_id or os.environ.get("GITHUB_RUN_ID") or "<run_id>"
        manifest["summary_artifact_name"] = "p167-stage3-summary-{}".format(run_id)
        manifest["raw_artifact_name"] = "p167-stage3-raw-logs-{}".format(run_id)
        manifest["notes"] = list(manifest.get("notes") or []) + ["stage3 postprocess aliases Stage 2-compatible file names"]
        write_json(os.path.join(out_dir, "stage3_artifact_manifest.json"), manifest)

    effective_path = os.path.join(out_dir, "actual_effective_config.json")
    if os.path.exists(effective_path):
        with open(effective_path) as f:
            effective = json.load(f)
        effective["stage2_artifact"] = args.stage2_artifact
        effective["artifact_names"] = {"summary": "p167-stage3-summary-<run_id>", "raw": "p167-stage3-raw-logs-<run_id>"}
        write_json(effective_path, effective)

    artifact_summary = S2["artifact_size_summary"](out_dir)
    write_json(os.path.join(out_dir, "artifact_size_summary.json"), artifact_summary)
    write_stage3_summary(out_dir, trajectory_rows, stage4_rows, hypotheses, artifact_summary)
    with open(os.path.join(out_dir, "run_log.md"), "a") as f:
        f.write("\n## Stage 3 postprocess\n\n")
        f.write("- input_stage3_candidates.jsonl alias written\n")
        f.write("- stage4_candidate_recommendations.jsonl alias written\n")
        f.write("- p167_stage3_survivor_deepening_summary.md written\n")


def build_parser():
    parser = argparse.ArgumentParser(description=SCRIPT_NAME)
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--tuple-registry", default=DEFAULT_TUPLE_REGISTRY)
    parser.add_argument("--stage2-artifact", default=DEFAULT_STAGE2_ARTIFACT)
    parser.add_argument("--stage2-seed-base", type=int, default=750167)
    parser.add_argument("--stage2-replay-steps", type=int, default=1000)
    parser.add_argument("--stage2-replay-sample-swaps", type=int, default=300)
    parser.add_argument("--aggregate-roots", default="")
    parser.add_argument("--benchmark-trap-manifest", default=DEFAULT_BENCHMARK_TRAPS)
    parser.add_argument("--nearhit-fixture", default=DEFAULT_NEARHIT_FIXTURE)
    parser.add_argument("--operators", default=",".join(STAGE3_OPERATORS))
    parser.add_argument("--deep-search-limit", type=int, default=41)
    parser.add_argument("--repair-target-limit", type=int, default=2)
    parser.add_argument("--operator-benchmark-limit", type=int, default=3)
    parser.add_argument("--needs-more-diagnostics-limit", type=int, default=1)
    parser.add_argument("--archive-limit", type=int, default=2)
    parser.add_argument("--survivor-limit", type=int, default=49)
    parser.add_argument("--benchmark-trap-limit", type=int, default=0)
    parser.add_argument("--random-control-limit", type=int, default=0)
    parser.add_argument("--nearhit-control-limit", type=int, default=0)
    parser.add_argument("--total-candidate-limit", type=int, default=49)
    parser.add_argument("--restarts", type=int, default=4)
    parser.add_argument("--steps", type=int, default=1500)
    parser.add_argument("--sample-swaps", type=int, default=400)
    parser.add_argument("--diagnostic-sample-count", type=int, default=300)
    parser.add_argument("--diagnostic-type", default="sampled")
    parser.add_argument("--snapshot-attempted-steps", default="0,50,100,200,500,1000,1500")
    parser.add_argument("--snapshot-accepted-moves", default="0,25,50,100,200,500")
    parser.add_argument("--uphill-threshold", type=int, default=16)
    parser.add_argument("--no-move-patience", type=int, default=160)
    parser.add_argument("--high-resolution-logging", action="store_true", default=False)
    parser.add_argument("--disable-high-resolution-logging", action="store_false", dest="high_resolution_logging")
    parser.add_argument("--highres-followup-accepted-moves", type=int, default=50)
    parser.add_argument("--high-resolution-mode", choices=["off", "triggered", "all"], default="triggered")
    parser.add_argument("--high-resolution-max-windows-per-trajectory", type=int, default=2)
    parser.add_argument("--high-resolution-window-accepted-moves", type=int, default=50)
    parser.add_argument("--artifact-mode", choices=["summary_only", "summary_plus_raw"], default="summary_only")
    parser.add_argument("--compress-raw-logs", action="store_true", default=True)
    parser.add_argument("--no-compress-raw-logs", action="store_false", dest="compress_raw_logs")
    parser.add_argument("--upload-raw-logs", action="store_true", default=False)
    parser.add_argument("--disable-raw-log-upload", action="store_false", dest="upload_raw_logs")
    parser.add_argument("--snapshot-log-mode", choices=["summary_only", "scheduled", "triggered", "full"], default="summary_only")
    parser.add_argument("--operator-reward-log-mode", choices=["summary_only", "topk", "sampled", "full_compressed"], default="topk")
    parser.add_argument("--operator-reward-topk", type=int, default=50)
    parser.add_argument("--operator-reward-sample-rate", type=float, default=0.01)
    parser.add_argument("--shard-index", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--max-tasks", type=int, default=0)
    parser.add_argument("--seed-base", type=int, default=760167)
    parser.add_argument("--stage3-candidate-limit", type=int, default=50)
    parser.add_argument("--github-run-id", default="")
    parser.add_argument("--code-commit", default="")
    parser.add_argument("--run-label", default="")
    parser.add_argument("--stage-name", default="p167_stage3")
    parser.add_argument("--out-dir", default=None)
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    if not args.run_label:
        args.run_label = args.github_run_id or "local-stage3"
    if args.out_dir is None:
        args.out_dir = os.path.join("outputs", "explorations", "{}_p167_stage3_survivor_deepening".format(now_stamp()))
    if not bool(args.high_resolution_logging):
        args.high_resolution_mode = "off"
    if str(args.artifact_mode) == "summary_plus_raw":
        args.upload_raw_logs = True
    # Stage 2 runner compatibility fields.
    args.stage1_artifact = args.stage2_artifact

    S2["load_stage2_candidates"] = load_stage3_candidates
    S2["stage3_candidates"] = stage4_candidates
    S2["run"](args)
    postprocess_stage3_outputs(args)
    print("Wrote p167_stage3 postprocessed outputs to {}".format(args.out_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(int(main() or 0))
