from sage.all import *

import argparse
import csv
import itertools
import os
import sys
import time

from sds_repair_utils import (
    all_one_swap_candidates,
    apply_delta,
    apply_swap_to_blocks,
    delta_swap,
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


SEARCH_METHOD = "beam_two_swap_repair"


def clone_blocks(blocks):
    return [set(block) for block in blocks]


def simple_swap(move):
    return {
        "block": int(move["block"]),
        "removed": int(move["removed"]),
        "added": int(move["added"]),
    }


def evaluate_ordered_sequence(v, blocks, counts, lam, sequence):
    trial_blocks = clone_blocks(blocks)
    trial_counts = list(counts)
    out_moves = []
    for move in sequence:
        block_idx = int(move["block"])
        removed = int(move["removed"])
        added = int(move["added"])
        if removed not in trial_blocks[block_idx]:
            return None
        if added in trial_blocks[block_idx]:
            return None

        delta = delta_swap(v, trial_blocks[block_idx], removed, added)
        trial_counts = apply_delta(trial_counts, delta)
        trial_blocks[block_idx].remove(removed)
        trial_blocks[block_idx].add(added)
        out_moves.append(simple_swap(move))

    metrics = metrics_from_counts(trial_counts, lam)
    return {
        "metrics": metrics,
        "counts": trial_counts,
        "moves": out_moves,
        "first": out_moves[0] if len(out_moves) > 0 else None,
        "second": out_moves[1] if len(out_moves) > 1 else None,
        "third": out_moves[2] if len(out_moves) > 2 else None,
    }


def apply_sequence(blocks, repair):
    for move in repair.get("moves", []):
        if not apply_swap_to_blocks(blocks, move):
            return False
    return True


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


def zero_protection_stats(v, old_counts, new_counts, lam):
    protected = 0
    damage = 0
    for d in range(1, v):
        if int(old_counts[d] - lam) == 0:
            protected += 1
            damage += abs(int(new_counts[d] - lam))
    return int(damage), int(protected)


def annotate_zero_damage(v, counts, lam, candidates):
    protected = None
    out = []
    for candidate in candidates:
        damage, protected = zero_protection_stats(v, counts, candidate["counts"], lam)
        candidate["zero_shift_damage"] = int(damage)
        candidate["protected_zero_shifts"] = int(protected)
        out.append(candidate)
    return out


def rank_candidates(v, counts, lam, candidates, rank_mode):
    candidates = annotate_zero_damage(v, counts, lam, candidates)
    if rank_mode == "score":
        key_fn = lambda item: (
            item["metrics"],
            item["zero_shift_damage"],
            item["block"],
            item["removed"],
            item["added"],
        )
    elif rank_mode == "l1":
        key_fn = lambda item: (
            item["metrics"][1],
            item["metrics"][0],
            item["metrics"][2],
            item["metrics"][3],
            item["zero_shift_damage"],
            item["block"],
            item["removed"],
            item["added"],
        )
    elif rank_mode == "zero_protect":
        key_fn = lambda item: (
            item["zero_shift_damage"],
            item["metrics"][3],
            item["metrics"][0],
            item["metrics"][1],
            item["metrics"][2],
            item["block"],
            item["removed"],
            item["added"],
        )
    elif rank_mode == "mixed":
        key_fn = lambda item: (
            item["zero_shift_damage"],
            item["metrics"][0],
            item["metrics"][1],
            item["metrics"][3],
            item["metrics"][2],
            item["block"],
            item["removed"],
            item["added"],
        )
    else:
        raise ValueError("unknown rank mode: {}".format(rank_mode))
    candidates.sort(key=key_fn)
    return candidates


def best_beam_repair(
    v, blocks, counts, lam, beam_width, depth, selected_moves, args, round_index
):
    all_swaps = all_one_swap_candidates(v, blocks, counts, lam)
    filtered_swaps, tabu_hits_skipped, tabu_enabled = filter_tabu_candidates(
        all_swaps, selected_moves, args, round_index
    )
    filtered_swaps = rank_candidates(v, counts, lam, filtered_swaps, args.rank_mode)
    one_swaps = filtered_swaps[: int(beam_width)]

    best = None
    evaluated = 0
    depth = int(depth)
    if depth == 1:
        iterator = ((idx,) for idx in range(len(one_swaps)))
    else:
        iterator = itertools.chain.from_iterable(
            itertools.permutations(combo)
            for combo in itertools.combinations(range(len(one_swaps)), depth)
        )

    for order in iterator:
        sequence = [one_swaps[idx] for idx in order]
        repair = evaluate_ordered_sequence(v, blocks, counts, lam, sequence)
        if repair is None:
            continue
        damage, protected = zero_protection_stats(v, counts, repair["counts"], lam)
        repair["zero_shift_damage"] = int(damage)
        repair["protected_zero_shifts"] = int(protected)
        evaluated += 1
        if best is None or tuple(repair["metrics"]) < tuple(best["metrics"]):
            best = repair

    return best, len(one_swaps), evaluated, tabu_hits_skipped, tabu_enabled


def swap_text(repair):
    if repair is None:
        return ""
    parts = []
    for move in repair.get("moves", []):
        parts.append(
            "B{}:{}->{}".format(move["block"], move["removed"], move["added"])
        )
    return ",".join(parts)


def make_row(
    round_index,
    one_swap_pool,
    evaluated_sequences,
    metrics,
    repair,
    accepted,
    elapsed,
    path,
    depth,
    rank_mode,
    zero_shift_damage,
    protected_zero_shifts,
    tabu_enabled=False,
    tabu_hits_skipped=0,
    selected_moves_count=0,
):
    return {
        "timestamp": timestamp(),
        "round": int(round_index),
        "depth": int(depth),
        "rank_mode": rank_mode,
        "one_swap_pool": int(one_swap_pool),
        "evaluated_sequences": int(evaluated_sequences),
        "score": int(metrics[0]),
        "l1_error": int(metrics[1]),
        "max_abs_error": int(metrics[2]),
        "nonzero_defect_count": int(metrics[3]),
        "zero_shift_damage": int(zero_shift_damage),
        "protected_zero_shifts": int(protected_zero_shifts),
        "best_repair": swap_text(repair),
        "accepted": bool(accepted),
        "tabu_enabled": bool(tabu_enabled),
        "tabu_hits_skipped": int(tabu_hits_skipped),
        "selected_moves_count": int(selected_moves_count),
        "elapsed_sec": float(elapsed),
        "path": path,
    }


def print_round(row):
    print(
        "round={round} depth={depth} one_swap_pool={one_swap_pool} "
        "rank_mode={rank_mode} evaluated_sequences={evaluated_sequences} score={score} "
        "l1_error={l1_error} max_abs_error={max_abs_error} "
        "nonzero_defect_count={nonzero_defect_count} "
        "zero_shift_damage={zero_shift_damage} "
        "protected_zero_shifts={protected_zero_shifts} best_repair={best_repair} "
        "accepted={accepted} tabu_enabled={tabu_enabled} "
        "tabu_hits_skipped={tabu_hits_skipped} "
        "elapsed_sec={elapsed_sec:.2f} path={path}".format(**row)
    )


def parse_args():
    parser = argparse.ArgumentParser(
        description="Repair an SDS near-hit by beam search over swap sequences."
    )
    parser.add_argument("json_path", help="Candidate or near-hit JSON path.")
    parser.add_argument(
        "--beam-width",
        type=int,
        default=200,
        help="Number of best 1-swap candidates used to form repair sequences.",
    )
    parser.add_argument(
        "--rounds",
        type=int,
        default=50,
        help="Maximum accepted beam repair rounds.",
    )
    parser.add_argument(
        "--depth",
        type=int,
        choices=[1, 2, 3],
        default=2,
        help="Depth of ordered beam repair combinations.",
    )
    parser.add_argument(
        "--rank-mode",
        choices=["score", "l1", "zero_protect", "mixed"],
        default="score",
        help="How to rank 1-swap candidates before forming the beam.",
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
        "--tabu-json",
        default=None,
        help="JSON containing selected_moves/selected_swaps whose reverse moves are tabu.",
    )
    parser.add_argument(
        "--tabu-tenure",
        type=int,
        default=1,
        help="Number of repair rounds for which the input tabu list applies.",
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


def repair_extra(args, data, evaluated_sequences, repair, selected_moves, tabu_hits):
    zero_shift_damage = 0
    protected_zero_shifts = 0
    if repair is not None:
        zero_shift_damage = int(repair.get("zero_shift_damage", 0))
        protected_zero_shifts = int(repair.get("protected_zero_shifts", 0))
    extra = {
        "beam_width": int(args.beam_width),
        "beam_depth": int(args.depth),
        "rank_mode": args.rank_mode,
        "evaluated_sequences": int(evaluated_sequences),
        "zero_shift_damage": int(zero_shift_damage),
        "protected_zero_shifts": int(protected_zero_shifts),
        "input_score": data.get("score"),
        "tabu_json": args.tabu_json,
        "tabu_selected_moves_count": int(len(selected_moves)),
        "tabu_no_reversal": bool(args.no_reversal),
        "tabu_touch_elements": bool(args.tabu_touch_elements),
        "tabu_tenure": int(args.tabu_tenure),
        "tabu_hits_skipped": int(tabu_hits),
    }
    if repair is not None:
        extra.update(
            {
                "moves": repair["moves"],
                "first_swap": repair["first"],
                "second_swap": repair["second"],
                "third_swap": repair["third"],
            }
        )
    return extra


def main():
    args = parse_args()
    tee, stamp = setup_logging("12_beam_two_swap_repair")
    csv_path = os.path.join(
        "outputs/logs", "12_beam_two_swap_repair_{}.csv".format(stamp)
    )
    csv_file = None
    try:
        if args.beam_width < 2:
            raise ValueError("--beam-width must be at least 2")
        if args.rounds < 1:
            raise ValueError("--rounds must be positive")

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
            "depth",
            "rank_mode",
            "one_swap_pool",
            "evaluated_sequences",
            "score",
            "l1_error",
            "max_abs_error",
            "nonzero_defect_count",
            "zero_shift_damage",
            "protected_zero_shifts",
            "best_repair",
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
            "beam_width={} depth={} rank_mode={} tabu_json={} no_reversal={} "
            "tabu_touch_elements={} tabu_tenure={} selected_moves_count={}".format(
                args.beam_width,
                args.depth,
                args.rank_mode,
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
                repair_extra(args, data, 0, None, selected_moves, 0),
            )
            return

        for round_index in range(1, args.rounds + 1):
            (
                repair,
                one_swap_pool,
                evaluated_sequences,
                tabu_hits_skipped,
                tabu_enabled,
            ) = best_beam_repair(
                v,
                blocks,
                counts,
                lam,
                args.beam_width,
                args.depth,
                selected_moves,
                args,
                round_index,
            )
            if repair is None or tuple(repair["metrics"]) >= tuple(metrics):
                zero_shift_damage = 0
                protected_zero_shifts = zero_protection_stats(
                    v, counts, counts, lam
                )[1]
                if repair is not None:
                    zero_shift_damage = int(repair.get("zero_shift_damage", 0))
                    protected_zero_shifts = int(
                        repair.get("protected_zero_shifts", protected_zero_shifts)
                    )
                row = make_row(
                    round_index,
                    one_swap_pool,
                    evaluated_sequences,
                    metrics,
                    repair,
                    False,
                    time.time() - start,
                    path,
                    args.depth,
                    args.rank_mode,
                    zero_shift_damage,
                    protected_zero_shifts,
                    tabu_enabled,
                    tabu_hits_skipped,
                    len(selected_moves),
                )
                csv_writer.writerow(row)
                print_round(row)
                print(
                    "STOP: no improving depth-{} repair found in beam".format(
                        args.depth
                    )
                )
                break

            ok = apply_sequence(blocks, repair)
            if not ok:
                raise RuntimeError("internal error: selected repair sequence is invalid")
            counts = repair["counts"]
            metrics = repair["metrics"]
            zero_shift_damage = int(repair.get("zero_shift_damage", 0))
            protected_zero_shifts = int(repair.get("protected_zero_shifts", 0))

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
                repair_extra(
                    args,
                    data,
                    evaluated_sequences,
                    repair,
                    selected_moves,
                    tabu_hits_skipped,
                ),
            )
            row = make_row(
                round_index,
                one_swap_pool,
                evaluated_sequences,
                metrics,
                repair,
                True,
                time.time() - start,
                path,
                args.depth,
                args.rank_mode,
                zero_shift_damage,
                protected_zero_shifts,
                tabu_enabled,
                tabu_hits_skipped,
                len(selected_moves),
            )
            csv_writer.writerow(row)
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
                    repair_extra(
                        args,
                        data,
                        evaluated_sequences,
                        repair,
                        selected_moves,
                        tabu_hits_skipped,
                    ),
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
