#!/usr/bin/env python3
import argparse
import csv
import glob
import json
import os
import sys


DEFAULT_PATTERN = "*_sds_search_668_*.csv"


def parse_int(value, default=0):
    if value is None or value == "":
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def is_valid_search_row(row):
    required = [
        "ks",
        "lambda",
        "seed",
        "best_score",
        "best_l1_error",
        "best_max_abs_error",
    ]
    for key in required:
        if row.get(key) in (None, "", "None"):
            return False
    try:
        int(row["lambda"])
        int(row["seed"])
        int(row["best_score"])
        int(row["best_l1_error"])
        int(row["best_max_abs_error"])
    except (TypeError, ValueError):
        return False
    return True


def metric_tuple(row):
    return (
        parse_int(row.get("best_score")),
        parse_int(row.get("best_l1_error")),
        parse_int(row.get("best_max_abs_error")),
    )


def row_steps(row):
    return parse_int(row.get("steps") or row.get("step"))


def better_row(candidate, current):
    if current is None:
        return True
    return metric_tuple(candidate) < metric_tuple(current)


def discover_csvs(logs_dir, pattern):
    path_pattern = os.path.join(logs_dir, pattern)
    return sorted(glob.glob(path_pattern))


def read_rows(paths):
    rows = []
    for path in paths:
        with open(path, newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                if not row or not is_valid_search_row(row):
                    continue
                row["_source_csv"] = path
                rows.append(row)
    return rows


def group_rows(rows):
    by_seed = {}
    for row in rows:
        key = (
            row.get("ks", ""),
            str(row.get("lambda", "")),
            str(row.get("seed", "")),
        )
        if better_row(row, by_seed.get(key)):
            by_seed[key] = row
    return by_seed


def seed_summary_rows(by_seed):
    out = []
    for (ks, lam, seed), row in by_seed.items():
        out.append(
            {
                "ks": ks,
                "lambda": parse_int(lam),
                "seed": parse_int(seed),
                "total_steps": row_steps(row),
                "best_score": parse_int(row.get("best_score")),
                "best_l1": parse_int(row.get("best_l1_error")),
                "best_max_abs_error": parse_int(row.get("best_max_abs_error")),
                "best_file": row.get("path", ""),
                "frontier_out": row.get("frontier_out", ""),
                "canonical_dedup": str(row.get("canonical_dedup", "")).lower()
                == "true",
                "found": str(row.get("found", "")).lower() == "true",
                "source_csv": row.get("_source_csv", ""),
                "timestamp": row.get("timestamp", ""),
            }
        )
    out.sort(
        key=lambda item: (
            item["best_score"],
            item["best_l1"],
            item["best_max_abs_error"],
            item["ks"],
            item["lambda"],
            item["seed"],
        )
    )
    return out


def parameter_summary(seed_rows):
    grouped = {}
    for row in seed_rows:
        key = (row["ks"], row["lambda"])
        item = grouped.setdefault(
            key,
            {
                "ks": row["ks"],
                "lambda": row["lambda"],
                "seeds": set(),
                "total_steps": 0,
                "best_score": None,
                "best_l1": None,
                "best_max_abs_error": None,
                "best_file": "",
                "best_seed": None,
                "found": False,
            },
        )
        item["seeds"].add(row["seed"])
        item["total_steps"] += row["total_steps"]
        item["found"] = item["found"] or row["found"]
        candidate = (row["best_score"], row["best_l1"], row["best_max_abs_error"])
        current = (
            item["best_score"],
            item["best_l1"],
            item["best_max_abs_error"],
        )
        if item["best_score"] is None or candidate < current:
            item["best_score"] = row["best_score"]
            item["best_l1"] = row["best_l1"]
            item["best_max_abs_error"] = row["best_max_abs_error"]
            item["best_file"] = row["best_file"]
            item["best_seed"] = row["seed"]

    out = []
    for item in grouped.values():
        item = dict(item)
        item["seeds"] = len(item["seeds"])
        out.append(item)
    out.sort(
        key=lambda item: (
            item["best_score"],
            item["best_l1"],
            item["best_max_abs_error"],
            item["ks"],
            item["lambda"],
        )
    )
    return out


def write_csv(path, rows):
    if not rows:
        return
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def write_json(path, payload):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)


def print_table(title, rows, columns, limit):
    print("\n{}".format(title))
    print("-" * len(title))
    if not rows:
        print("(none)")
        return

    selected = rows if limit is None else rows[:limit]
    widths = {}
    for col in columns:
        widths[col] = max(len(col), max(len(str(row.get(col, ""))) for row in selected))
    header = "  ".join(col.ljust(widths[col]) for col in columns)
    print(header)
    print("  ".join("-" * widths[col] for col in columns))
    for row in selected:
        print("  ".join(str(row.get(col, "")).ljust(widths[col]) for col in columns))


def parse_args():
    parser = argparse.ArgumentParser(
        description="Summarize guided SDS search CSV logs."
    )
    parser.add_argument("--logs-dir", default="outputs/logs")
    parser.add_argument("--pattern", default=DEFAULT_PATTERN)
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--out-json", default=None)
    parser.add_argument("--out-csv", default=None, help="Write per-seed summary CSV.")
    parser.add_argument(
        "--out-param-csv",
        default=None,
        help="Write ks/lambda aggregate summary CSV.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    paths = discover_csvs(args.logs_dir, args.pattern)
    if not paths:
        print(
            "No CSV logs matched {}/{}".format(args.logs_dir, args.pattern),
            file=sys.stderr,
        )
        raise SystemExit(1)

    rows = read_rows(paths)
    by_seed = group_rows(rows)
    seed_rows = seed_summary_rows(by_seed)
    param_rows = parameter_summary(seed_rows)

    print("Read {} rows from {} CSV files".format(len(rows), len(paths)))
    print_table(
        "Best by ks/lambda",
        param_rows,
        [
            "ks",
            "lambda",
            "seeds",
            "total_steps",
            "best_score",
            "best_l1",
            "best_max_abs_error",
            "best_seed",
            "best_file",
        ],
        args.limit,
    )
    print_table(
        "Best by ks/lambda/seed",
        seed_rows,
        [
            "ks",
            "lambda",
            "seed",
            "total_steps",
            "best_score",
            "best_l1",
            "best_max_abs_error",
            "best_file",
        ],
        args.limit,
    )

    if args.out_json:
        write_json(
            args.out_json,
            {
                "source_csvs": paths,
                "parameter_summary": param_rows,
                "seed_summary": seed_rows,
            },
        )
        print("\nWrote JSON:", args.out_json)
    if args.out_csv:
        write_csv(args.out_csv, seed_rows)
        print("Wrote seed CSV:", args.out_csv)
    if args.out_param_csv:
        write_csv(args.out_param_csv, param_rows)
        print("Wrote parameter CSV:", args.out_param_csv)


if __name__ == "__main__":
    main()
