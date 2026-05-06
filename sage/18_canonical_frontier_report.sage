from sage.all import *

import argparse
import json
import os
import time

from sds_repair_utils import (
    canonical_candidate,
    canonical_hash,
    canonical_repr_summary,
    load_candidate,
    metrics_from_counts,
    total_diff_counts,
)


KNOWN_CANDIDATES = [
    {
        "name": "known_sds_v3_n12",
        "v": 3,
        "n": 12,
        "ks": [0, 1, 1, 1],
        "lambda": 0,
        "blocks": [[], [0], [0], [0]],
    },
    {
        "name": "known_sds_v5_n20",
        "v": 5,
        "n": 20,
        "ks": [1, 1, 2, 2],
        "lambda": 1,
        "blocks": [[0], [0], [0, 1], [0, 2]],
    },
    {
        "name": "known_sds_v7_n28",
        "v": 7,
        "n": 28,
        "ks": [1, 3, 3, 3],
        "lambda": 3,
        "blocks": [[0], [0, 2, 4], [0, 1, 2], [0, 1, 4]],
    },
]


def timestamp():
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def write_text(path, text):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def json_safe(value):
    if isinstance(value, dict):
        return {str(k): json_safe(v) for k, v in value.items()}
    if isinstance(value, list):
        return [json_safe(v) for v in value]
    if isinstance(value, tuple):
        return [json_safe(v) for v in value]
    try:
        if isinstance(value, Integer):
            return int(value)
    except NameError:
        pass
    return value


def write_json(path, payload):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        json.dump(json_safe(payload), f, indent=2)


def json_text(payload):
    return json.dumps(json_safe(payload), indent=2)


def read_json(path):
    with open(path) as f:
        return json.load(f)


def json_blocks_to_sets(blocks):
    return [set(int(x) for x in block) for block in blocks]


def metric_tuple(v, blocks, lam):
    return metrics_from_counts(total_diff_counts(v, blocks), lam)


def transformed_blocks(v, blocks):
    out = []
    unit = 2 if gcd(2, v) == 1 else 1
    for idx, block in enumerate(blocks):
        shift = idx + 1
        out.append(set((unit * int(x) + shift) % v for x in block))
    return out


def same_size_swapped_blocks(blocks, ks):
    out = [set(block) for block in blocks]
    seen = {}
    for idx, size in enumerate(ks):
        if size in seen:
            j = seen[size]
            out[idx], out[j] = out[j], out[idx]
            return out
        seen[size] = idx
    return out


def validate_one(name, v, ks, lam, blocks):
    orig_metrics = metric_tuple(v, blocks, lam)
    canonical_blocks = [set(block) for block in canonical_candidate(blocks, ks, v)]
    canonical_metrics = metric_tuple(v, canonical_blocks, lam)
    orig_hash = canonical_hash(blocks, ks, v)
    transformed = transformed_blocks(v, blocks)
    transformed_hash = canonical_hash(transformed, ks, v)
    swapped = same_size_swapped_blocks(blocks, ks)
    swapped_hash = canonical_hash(swapped, ks, v)
    return {
        "name": name,
        "v": int(v),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "original_metrics": [int(x) for x in orig_metrics],
        "canonical_metrics": [int(x) for x in canonical_metrics],
        "metrics_preserved": tuple(orig_metrics) == tuple(canonical_metrics),
        "hash": orig_hash,
        "transformed_hash": transformed_hash,
        "transformed_hash_same": orig_hash == transformed_hash,
        "same_size_swap_hash": swapped_hash,
        "same_size_swap_hash_same": orig_hash == swapped_hash,
    }


def load_frontier_records(path):
    if not os.path.exists(path):
        return []
    data = read_json(path)
    return data.get("records", [])


def bucket_frontier(records):
    classes = {}
    enriched = []
    for record in records:
        source = record.get("source_path") or record.get("path")
        if not source or not os.path.exists(source):
            continue
        data, v, n, ks, lam, blocks = load_candidate(source)
        counts = total_diff_counts(v, blocks)
        metrics = metrics_from_counts(counts, lam)
        h = canonical_hash(blocks, ks, v)
        summary = canonical_repr_summary(blocks, ks, v)
        item = dict(record)
        item["canonical_hash"] = h
        item["canonical_repr_summary"] = summary
        item["metrics_recomputed"] = [int(x) for x in metrics]
        enriched.append(item)
        bucket = classes.setdefault(
            h,
            {
                "canonical_hash": h,
                "entries": [],
                "best_score": None,
                "best_l1": None,
                "best_nonzero": None,
                "best_max_abs": None,
            },
        )
        compact = {
            "source_path": source,
            "score": int(metrics[0]),
            "l1_error": int(metrics[1]),
            "max_abs_error": int(metrics[2]),
            "nonzero_defect_count": int(metrics[3]),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
        }
        bucket["entries"].append(compact)
        if bucket["best_score"] is None or (
            compact["score"],
            compact["l1_error"],
            compact["max_abs_error"],
            compact["nonzero_defect_count"],
        ) < (
            bucket["best_score"]["score"],
            bucket["best_score"]["l1_error"],
            bucket["best_score"]["max_abs_error"],
            bucket["best_score"]["nonzero_defect_count"],
        ):
            bucket["best_score"] = compact
        if bucket["best_l1"] is None or (
            compact["l1_error"],
            compact["score"],
            compact["max_abs_error"],
            compact["nonzero_defect_count"],
        ) < (
            bucket["best_l1"]["l1_error"],
            bucket["best_l1"]["score"],
            bucket["best_l1"]["max_abs_error"],
            bucket["best_l1"]["nonzero_defect_count"],
        ):
            bucket["best_l1"] = compact
        if bucket["best_nonzero"] is None or (
            compact["nonzero_defect_count"],
            compact["l1_error"],
            compact["score"],
            compact["max_abs_error"],
        ) < (
            bucket["best_nonzero"]["nonzero_defect_count"],
            bucket["best_nonzero"]["l1_error"],
            bucket["best_nonzero"]["score"],
            bucket["best_nonzero"]["max_abs_error"],
        ):
            bucket["best_nonzero"] = compact
        if bucket["best_max_abs"] is None or (
            compact["max_abs_error"],
            compact["score"],
            compact["l1_error"],
            compact["nonzero_defect_count"],
        ) < (
            bucket["best_max_abs"]["max_abs_error"],
            bucket["best_max_abs"]["score"],
            bucket["best_max_abs"]["l1_error"],
            bucket["best_max_abs"]["nonzero_defect_count"],
        ):
            bucket["best_max_abs"] = compact

    return {
        "frontier_entries": len(records),
        "enriched_entries": enriched,
        "canonical_classes": len(classes),
        "duplicates_removed": len(enriched) - len(classes),
        "classes": sorted(classes.values(), key=lambda x: x["canonical_hash"]),
    }


def guided_frontier_summary(paths):
    out = []
    for path in paths:
        if not path or not os.path.exists(path):
            out.append({"path": path, "exists": False})
            continue
        data = read_json(path)
        buckets = data.get("buckets", {})
        item = {"path": path, "exists": True, "buckets": {}}
        hashes = set()
        for name, rows in buckets.items():
            hashes.update(row.get("canonical_hash") for row in rows)
            item["buckets"][name] = {
                "count": len(rows),
                "best": rows[0] if rows else None,
            }
        item["canonical_class_count"] = len([h for h in hashes if h])
        out.append(item)
    return out


def write_docs(outdir, payloads):
    os.makedirs(outdir, exist_ok=True)
    os.makedirs(os.path.join(outdir, "raw"), exist_ok=True)
    os.makedirs(os.path.join(outdir, "logs"), exist_ok=True)
    os.makedirs(os.path.join(outdir, "review"), exist_ok=True)

    design = {
        "allowed_equivalences": [
            "independent cyclic translation per block",
            "simultaneous unit multiplier in Z_v^*",
            "same-size block permutation only",
        ],
        "excluded_equivalences": [
            "complement transformation",
            "unequal-size block permutation",
        ],
        "hash": "SHA256(JSON(v,ks,canonical_blocks))",
        "purpose": "discovery and dedup only; not a mathematical success condition",
    }
    write_json(os.path.join(outdir, "raw", "canonical_hash_design.json"), design)
    write_json(os.path.join(outdir, "raw", "canonical_hash_validation.json"), payloads["validation"])
    write_json(os.path.join(outdir, "raw", "bucketed_frontier_summary.json"), payloads["bucket"])
    write_json(os.path.join(outdir, "raw", "guided_search_results.json"), payloads["guided"])

    active_plan = {
        "status": "implemented entry points, not yet used as a success claim",
        "script": "sage/13_ilp_repair_from_near_hit.sage",
        "pool_mode": "active_defect_lns",
        "objectives": ["l1_then_nonzero", "nonzero_then_l1"],
        "aliases": ["--swap-pool", "--max-swaps"],
        "selection": "prioritize swaps affecting nonzero defects while recording zero-shift damage",
        "success_condition": "still requires score=0, SDS OK, and Goethals-Seidel HH^T=668I over ZZ",
    }
    failure_modes = {
        "observed_previous": [
            "repair_framework_still_saturated",
            "selected=0 fixed point",
            "ILP output dominated by existing frontier",
            "beam-depth=3 no surviving improvement",
            "score-best and low-nonzero basins remain separated",
        ],
        "new_risks": [
            "canonical dedup reveals duplicate basins",
            "guided search returns to existing basins",
            "active-defect repair too small / too large",
        ],
    }
    route_verdict = {
        "success_candidate_generated": False,
        "verdict": "open_pending_guided_long_run",
        "notes": [
            "Canonical dedup is implemented and validated as a diagnostic layer.",
            "Full guided new-basin generation may be long-running and should be evaluated from bucketed frontier files.",
        ],
    }
    next_candidates = {
        "candidates": [
            {
                "candidate_name": "Active-defect ILP repair on new low-nonzero basin",
                "classification": "heuristic repair",
                "why_now": "shallow repair saturated; new canonical basins need targeted repair",
                "success_condition": "frontier metric improvement, then exact SDS/GS verification if score=0",
                "failure_condition": "selected=0 or dominated outputs",
                "required_compute": "medium",
                "risk": "ILP pool may be too small or too large",
                "rank_reason": "most direct follow-up after canonical new basin generation",
            },
            {
                "candidate_name": "Continue guided new-basin generation",
                "classification": "heuristic search",
                "why_now": "current repair frontier is saturated",
                "success_condition": "new canonical_hash with score/l1/nonzero improvement",
                "failure_condition": "returns to existing canonical classes",
                "required_compute": "high",
                "risk": "long runtime",
                "rank_reason": "best way to escape existing basins",
            },
            {
                "candidate_name": "Constantine [76,76,77,80] one-block completion",
                "classification": "side route",
                "why_now": "if guided search also saturates",
                "success_condition": "new verified SDS route candidate",
                "failure_condition": "no compatible completion",
                "required_compute": "medium-high",
                "risk": "may miss unconstrained solutions",
                "rank_reason": "changes search geometry",
            },
        ]
    }
    safety = {
        "hadamard_668_claimed": False,
        "near_hit_treated_as_solution": False,
        "score_zero_alone_success": False,
        "sds_verification_required": True,
        "gs_hht_required": True,
        "canonical_hash_is_success_condition": False,
        "frontier_update_is_success": False,
    }
    current_status = {
        "timestamp": timestamp(),
        "n": 668,
        "v": 167,
        "success_candidate_generated": False,
        "frontier_summary": payloads["bucket"],
    }
    write_json(os.path.join(outdir, "raw", "active_defect_repair_plan.json"), active_plan)
    write_json(os.path.join(outdir, "raw", "failure_modes.json"), failure_modes)
    write_json(os.path.join(outdir, "raw", "route_verdict.json"), route_verdict)
    write_json(os.path.join(outdir, "raw", "refined_next_candidates.json"), next_candidates)
    write_json(os.path.join(outdir, "raw", "current_status.json"), current_status)

    docs = {
        "README.md": "# Canonical New-Basin Generation\n\nDiagnostic exploration folder for Hadamard 668 SDS search. No construction success is claimed here.\n",
        "experiment_plan.md": "# Experiment Plan\n\nImplement canonical hash/dedup, generate bucketed guided frontiers, then use active-defect LNS/ILP repair on new canonical basins.\n",
        "canonical_hash_design.md": "# Canonical Hash Design\n\n```json\n{}\n```\n".format(json_text(design)),
        "canonical_hash_validation.md": "# Canonical Hash Validation\n\n```json\n{}\n```\n".format(json_text(payloads["validation"])),
        "bucketed_frontier_summary.md": "# Bucketed Frontier Summary\n\n```json\n{}\n```\n".format(json_text(payloads["bucket"])),
        "guided_search_results.md": "# Guided Search Results\n\n```json\n{}\n```\n".format(json_text(payloads["guided"])),
        "active_defect_repair_plan.md": "# Active-Defect Repair Plan\n\n```json\n{}\n```\n".format(json_text(active_plan)),
        "failure_modes.md": "# Failure Modes\n\n```json\n{}\n```\n".format(json_text(failure_modes)),
        "route_verdict.md": "# Route Verdict\n\n```json\n{}\n```\n".format(json_text(route_verdict)),
        "refined_next_candidates.md": "# Refined Next Candidates\n\n```json\n{}\n```\n".format(json_text(next_candidates)),
        "proof_safety_check.md": "# Proof Safety Check\n\n```json\n{}\n```\n".format(json_text(safety)),
        "current_status.md": "# Current Status\n\n```json\n{}\n```\n".format(json_text(current_status)),
    }
    summary = """## Final Summary

1. Implemented canonical hash/dedup utilities for SDS near-hit discovery.
2. Added bucketed canonical frontier support to guided search.
3. Added canonical metadata to repair/frontier payloads.
4. Added active-defect LNS entry points to ILP repair.
5. Canonical hash is diagnostic only and is not a success condition.
6. n=668 Hadamard construction has not been achieved in this report.

今回の出力は Hadamard 668 SDS の canonical-dedup new-basin generation 用の基盤である。
n=668 の Hadamard 行列構成には成功していない。
成功候補は、SDS検証と Goethals-Seidel HH^T=668I 検証を通った場合のみである。
near-hit / frontier / canonical basin は研究ログであり、解ではない。
得られたものは、canonical重複除去、新basin生成結果、bucketed frontier、次の active-defect repair 方針である。
"""
    docs["summary.md"] = summary
    for name, text in docs.items():
        write_text(os.path.join(outdir, name), text)

    review_map = {
        "README.md": "README.md",
        "summary.md": "00_summary.md",
        "canonical_hash_validation.md": "01_canonical_hash.md",
        "guided_search_results.md": "02_guided_search.md",
        "bucketed_frontier_summary.md": "03_frontier_summary.md",
        "active_defect_repair_plan.md": "04_active_defect_plan.md",
        "failure_modes.md": "05_failure_modes.md",
        "route_verdict.md": "06_verdict.md",
        "refined_next_candidates.md": "07_next_candidates.md",
        "proof_safety_check.md": "08_safety_check.md",
    }
    for src, dst in review_map.items():
        write_text(os.path.join(outdir, "review", dst), docs[src])

    write_text(os.path.join(outdir, "logs", "copied_or_linked_logs.txt"), "Logs remain in outputs/logs; guided frontier paths are recorded in raw/guided_search_results.json.\n")
    write_text(os.path.join(outdir, "run_log.md"), "# Run Log\n\nGenerated at `{}` by `18_canonical_frontier_report.sage`.\n".format(timestamp()))


def parse_args():
    parser = argparse.ArgumentParser(description="Canonical hash validation and frontier bucket report.")
    parser.add_argument("--outdir", required=True)
    parser.add_argument(
        "--frontier-index",
        default="outputs/candidates/near_hits/frontier/frontier_index.json",
    )
    parser.add_argument("--guided-frontier", action="append", default=[])
    parser.add_argument("--near-hit", action="append", default=[])
    return parser.parse_args()


def main():
    args = parse_args()
    validation_items = []
    for item in KNOWN_CANDIDATES:
        validation_items.append(
            validate_one(
                item["name"],
                int(item["v"]),
                tuple(int(k) for k in item["ks"]),
                int(item["lambda"]),
                json_blocks_to_sets(item["blocks"]),
            )
        )
    for path in args.near_hit:
        if os.path.exists(path):
            data, v, n, ks, lam, blocks = load_candidate(path)
            validation_items.append(validate_one(path, v, ks, lam, blocks))

    validation = {
        "all_passed": all(
            item["metrics_preserved"]
            and item["transformed_hash_same"]
            and item["same_size_swap_hash_same"]
            for item in validation_items
        ),
        "items": validation_items,
    }
    records = load_frontier_records(args.frontier_index)
    bucket = bucket_frontier(records)
    guided = guided_frontier_summary(args.guided_frontier)
    payloads = {"validation": validation, "bucket": bucket, "guided": guided}
    write_docs(args.outdir, payloads)
    print("canonical validation passed:", validation["all_passed"])
    print("frontier entries:", bucket["frontier_entries"])
    print("canonical classes:", bucket["canonical_classes"])
    print("outdir:", args.outdir)


if __name__ == "__main__":
    main()
