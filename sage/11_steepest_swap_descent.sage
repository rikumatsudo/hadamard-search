from sage.all import *

import argparse
import csv
import os
import sys
import time

from sds_repair_utils import (
    all_one_swap_candidates,
    apply_swap_to_blocks,
    load_candidate,
    load_selected_moves,
    metrics_from_counts,
    save_near_hit,
    save_success,
    setup_logging,
    tabu_skips_swap,
    timestamp,
    total_diff_counts,
)


SEARCH_METHOD = "steepest_swap_descent"


def write_row(csv_writer, row):
    csv_writer.writerow(row)


def print_round(row):
    print(
        "round={round} neighborhood={neighborhood_size} score={score} "
        "l1_error={l1_error} max_abs_error={max_abs_error} "
        "nonzero_defect_count={nonzero_defect_count} best_swap={best_swap} "
        "accepted={accepted} tabu_enabled={tabu_enabled} "
        "tabu_hits_skipped={tabu_hits_skipped} "
        "elapsed_sec={elapsed_sec:.2f} path={path}".format(**row)
    )


def make_row(
    round_index,
    neighborhood_size,
    metrics,
    best_swap,
    accepted,
    elapsed,
    path,
    tabu_enabled=False,
    tabu_hits_skipped=0,
    selected_moves_count=0,
):
    swap_text = ""
    if best_swap is not None:
        swap_text = "B{}:{}->{}".format(
            best_swap["block"], best_swap["removed"], best_swap["added"]
        )
    return {
        "timestamp": timestamp(),
        "round": int(round_index),
        "neighborhood_size": int(neighborhood_size),
        "score": int(metrics[0]),
        "l1_error": int(metrics[1]),
        "max_abs_error": int(metrics[2]),
        "nonzero_defect_count": int(metrics[3]),
        "best_swap": swap_text,
        "accepted": bool(accepted),
        "tabu_enabled": bool(tabu_enabled),
        "tabu_hits_skipped": int(tabu_hits_skipped),
        "selected_moves_count": int(selected_moves_count),
        "elapsed_sec": float(elapsed),
        "path": path,
    }


def filter_tabu_candidates(candidates, selected_moves, args, round_index):
    if not selected_moves:
        return candidates, 0, False
    if not (args.no_reversal or args.tabu_touch_elements):
        return candidates, 0, False
    if args.tabu_tenure <= 0 or round_index > args.tabu_tenure:
        return candidates, 0, False

    out = []
    skipped = 0
    for candidate in candidates:
        if tabu_skips_swap(
            candidate,
            selected_moves,
            no_reversal=args.no_reversal,
            touch_elements=args.tabu_touch_elements,
        ):
            skipped += 1
        else:
            out.append(candidate)
    return out, skipped, True


def parse_args():
    parser = argparse.ArgumentParser(
        description="Repair an SDS near-hit by complete steepest 1-swap descent."
    )
    parser.add_argument("json_path", help="Candidate or near-hit JSON path.")
    parser.add_argument(
        "--max-rounds",
        type=int,
        default=1000,
        help="Safety cap for accepted steepest-descent rounds.",
    )
    parser.add_argument(
        "--near-hit-dir",
        default="outputs/candidates/near_hits",
        help="Directory for repaired near-hit JSON files.",
    )
    parser.add_argument(
        "--candidate-dir",
        default="outputs/candidates",
        help="Directory for fully verified success candidates.",
    )
    parser.add_argument(
        "--save-initial",
        action="store_true",
        help="Also save the input state as a repair near-hit JSON.",
    )
    parser.add_argument(
        "--tabu-json",
        default=None,
        help="JSON containing selected_moves/selected_swaps whose reverse moves are tabu.",
    )
    parser.add_argument(
        "--tabu-tenure",
        type=int,
        default=1,
        help="Number of accepted/local rounds for which the input tabu list applies.",
    )
    parser.add_argument(
        "--no-reversal",
        action="store_true",
        help="Skip swaps that exactly reverse moves in --tabu-json.",
    )
    parser.add_argument(
        "--tabu-touch-elements",
        action="store_true",
        help="Also skip swaps touching elements moved by --tabu-json in the same block.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging("11_steepest_swap_descent")
    csv_path = os.path.join(
        "outputs/logs", "11_steepest_swap_descent_{}.csv".format(stamp)
    )
    csv_file = None
    try:
        data, v, n, ks, lam, blocks = load_candidate(args.json_path)
        selected_moves = load_selected_moves(args.tabu_json) if args.tabu_json else []
        counts = total_diff_counts(v, blocks)
        metrics = metrics_from_counts(counts, lam)
        start = time.time()

        os.makedirs("outputs/logs", exist_ok=True)
        csv_file = open(csv_path, "w")
        fieldnames = [
            "timestamp",
            "round",
            "neighborhood_size",
            "score",
            "l1_error",
            "max_abs_error",
            "nonzero_defect_count",
            "best_swap",
            "accepted",
            "tabu_enabled",
            "tabu_hits_skipped",
            "selected_moves_count",
            "elapsed_sec",
            "path",
        ]
        csv_writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        csv_writer.writeheader()

        print("CSV log:", csv_path)
        print("Input:", args.json_path)
        print("v={} n={} ks={} lambda={}".format(v, n, ks, lam))
        print(
            "tabu_json={} no_reversal={} tabu_touch_elements={} "
            "tabu_tenure={} selected_moves_count={}".format(
                args.tabu_json,
                bool(args.no_reversal),
                bool(args.tabu_touch_elements),
                int(args.tabu_tenure),
                int(len(selected_moves)),
            )
        )
        print(
            "initial score={} l1_error={} max_abs_error={} "
            "nonzero_defect_count={}".format(
                metrics[0], metrics[1], metrics[2], metrics[3]
            )
        )

        path = args.json_path
        if args.save_initial:
            path = save_near_hit(
                args.near_hit_dir,
                v,
                ks,
                lam,
                blocks,
                metrics,
                args.json_path,
                SEARCH_METHOD,
                0,
                0,
                counts,
                {
                    "input_score": data.get("score"),
                    "tabu_json": args.tabu_json,
                    "tabu_selected_moves_count": int(len(selected_moves)),
                    "tabu_no_reversal": bool(args.no_reversal),
                    "tabu_touch_elements": bool(args.tabu_touch_elements),
                    "tabu_tenure": int(args.tabu_tenure),
                },
            )

        if metrics[0] == 0:
            print("FOUND score 0 at input; running exact verification")
            path = save_success(
                args.candidate_dir,
                args.near_hit_dir,
                v,
                ks,
                lam,
                blocks,
                metrics,
                args.json_path,
                SEARCH_METHOD,
                0,
                0,
                counts,
                {
                    "input_score": data.get("score"),
                    "tabu_json": args.tabu_json,
                    "tabu_selected_moves_count": int(len(selected_moves)),
                    "tabu_no_reversal": bool(args.no_reversal),
                    "tabu_touch_elements": bool(args.tabu_touch_elements),
                    "tabu_tenure": int(args.tabu_tenure),
                },
            )
            row = make_row(
                0,
                0,
                metrics,
                None,
                True,
                time.time() - start,
                path,
                False,
                0,
                len(selected_moves),
            )
            write_row(csv_writer, row)
            print_round(row)
            return

        for round_index in range(1, args.max_rounds + 1):
            raw_candidates = all_one_swap_candidates(v, blocks, counts, lam)
            candidates, tabu_hits_skipped, tabu_enabled = filter_tabu_candidates(
                raw_candidates, selected_moves, args, round_index
            )
            neighborhood_size = len(candidates)
            best = candidates[0] if candidates else None

            if best is None or tuple(best["metrics"]) >= tuple(metrics):
                row = make_row(
                    round_index,
                    neighborhood_size,
                    metrics,
                    best,
                    False,
                    time.time() - start,
                    path,
                    tabu_enabled,
                    tabu_hits_skipped,
                    len(selected_moves),
                )
                write_row(csv_writer, row)
                print_round(row)
                print("STOP: 1-swap local optimum reached")
                break

            ok = apply_swap_to_blocks(blocks, best)
            if not ok:
                raise RuntimeError("internal error: selected best swap is invalid")
            counts = best["counts"]
            metrics = best["metrics"]

            path = save_near_hit(
                args.near_hit_dir,
                v,
                ks,
                lam,
                blocks,
                metrics,
                args.json_path,
                SEARCH_METHOD,
                round_index,
                round_index,
                counts,
                {
                    "swap": {
                        "block": int(best["block"]),
                        "removed": int(best["removed"]),
                        "added": int(best["added"]),
                    },
                    "tabu_json": args.tabu_json,
                    "tabu_selected_moves_count": int(len(selected_moves)),
                    "tabu_no_reversal": bool(args.no_reversal),
                    "tabu_touch_elements": bool(args.tabu_touch_elements),
                    "tabu_tenure": int(args.tabu_tenure),
                    "tabu_hits_skipped": int(tabu_hits_skipped),
                },
            )
            row = make_row(
                round_index,
                neighborhood_size,
                metrics,
                best,
                True,
                time.time() - start,
                path,
                tabu_enabled,
                tabu_hits_skipped,
                len(selected_moves),
            )
            write_row(csv_writer, row)
            print_round(row)
            csv_file.flush()

            if metrics[0] == 0:
                print(
                    "FOUND score 0 after round {}; running exact verification".format(
                        round_index
                    )
                )
                path = save_success(
                    args.candidate_dir,
                    args.near_hit_dir,
                    v,
                    ks,
                    lam,
                    blocks,
                    metrics,
                    args.json_path,
                    SEARCH_METHOD,
                    round_index,
                    round_index,
                    counts,
                    {
                        "swap": {
                            "block": int(best["block"]),
                            "removed": int(best["removed"]),
                            "added": int(best["added"]),
                        },
                        "tabu_json": args.tabu_json,
                        "tabu_selected_moves_count": int(len(selected_moves)),
                        "tabu_no_reversal": bool(args.no_reversal),
                        "tabu_touch_elements": bool(args.tabu_touch_elements),
                        "tabu_tenure": int(args.tabu_tenure),
                        "tabu_hits_skipped": int(tabu_hits_skipped),
                    },
                )
                break

        print(
            "DONE: final score={} l1_error={} max_abs_error={} "
            "nonzero_defect_count={} path={}".format(
                metrics[0], metrics[1], metrics[2], metrics[3], path
            )
        )
    finally:
        if csv_file is not None:
            csv_file.close()
        sys.stdout = tee.terminal
        tee.close()


if __name__ == "__main__":
    main()
