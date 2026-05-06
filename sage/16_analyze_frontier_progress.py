#!/usr/bin/env python3
import argparse
import json
import os
from datetime import datetime


def read_json(path):
    with open(path) as f:
        return json.load(f)


def write_json(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def records_from(path):
    data = read_json(path)
    if isinstance(data, dict) and "records" in data:
        return data["records"]
    return data.get("records", [])


def metric_tuple(record):
    return (
        int(record["score"]),
        int(record["l1_error"]),
        int(record["max_abs_error"]),
        int(record["nonzero_defect_count"]),
    )


def record_key(record):
    return (
        tuple(int(k) for k in record.get("ks", [])),
        int(record.get("lambda", -1)),
        metric_tuple(record),
        os.path.normpath(record.get("source_path") or record.get("path", "")),
    )


def best(records, key):
    if not records:
        return None
    return min(records, key=key)


def compact(record):
    if record is None:
        return None
    return {
        "score": int(record["score"]),
        "l1_error": int(record["l1_error"]),
        "max_abs_error": int(record["max_abs_error"]),
        "nonzero_defect_count": int(record["nonzero_defect_count"]),
        "ks": [int(k) for k in record["ks"]],
        "lambda": int(record["lambda"]),
        "source_path": record.get("source_path", record.get("path", "")),
    }


def summarize(before_records, after_records):
    before_keys = {record_key(r): r for r in before_records}
    after_keys = {record_key(r): r for r in after_records}
    added = [after_keys[k] for k in sorted(set(after_keys) - set(before_keys))]
    removed = [before_keys[k] for k in sorted(set(before_keys) - set(after_keys))]
    out = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "before_count": len(before_records),
        "after_count": len(after_records),
        "added_count": len(added),
        "removed_count": len(removed),
        "added_entries": [compact(r) for r in sorted(added, key=metric_tuple)],
        "removed_entries": [compact(r) for r in sorted(removed, key=metric_tuple)],
        "best_score_before": compact(best(before_records, lambda r: metric_tuple(r))),
        "best_score_after": compact(best(after_records, lambda r: metric_tuple(r))),
        "best_l1_before": compact(best(before_records, lambda r: (int(r["l1_error"]), int(r["score"]), int(r["max_abs_error"]), int(r["nonzero_defect_count"])))),
        "best_l1_after": compact(best(after_records, lambda r: (int(r["l1_error"]), int(r["score"]), int(r["max_abs_error"]), int(r["nonzero_defect_count"])))),
        "best_max_abs_before": compact(best(before_records, lambda r: (int(r["max_abs_error"]), int(r["score"]), int(r["l1_error"]), int(r["nonzero_defect_count"])))),
        "best_max_abs_after": compact(best(after_records, lambda r: (int(r["max_abs_error"]), int(r["score"]), int(r["l1_error"]), int(r["nonzero_defect_count"])))),
        "best_nonzero_before": compact(best(before_records, lambda r: (int(r["nonzero_defect_count"]), int(r["l1_error"]), int(r["score"]), int(r["max_abs_error"])))),
        "best_nonzero_after": compact(best(after_records, lambda r: (int(r["nonzero_defect_count"]), int(r["l1_error"]), int(r["score"]), int(r["max_abs_error"])))),
    }
    return out


def md(summary):
    lines = [
        "# Frontier Update Analysis",
        "",
        "This is a near-hit Pareto frontier diagnostic, not a Hadamard construction certificate.",
        "",
        "- before_count: `{}`".format(summary["before_count"]),
        "- after_count: `{}`".format(summary["after_count"]),
        "- added_count: `{}`".format(summary["added_count"]),
        "- removed_count: `{}`".format(summary["removed_count"]),
        "",
        "## Best Metrics",
        "",
    ]
    for key in [
        "best_score_before",
        "best_score_after",
        "best_l1_before",
        "best_l1_after",
        "best_max_abs_before",
        "best_max_abs_after",
        "best_nonzero_before",
        "best_nonzero_after",
    ]:
        lines.append("- {}: `{}`".format(key, summary.get(key)))
    lines.extend(["", "## Added Entries", ""])
    for item in summary["added_entries"]:
        lines.append("- `{}`".format(item))
    if not summary["added_entries"]:
        lines.append("- none")
    lines.extend(["", "## Removed Entries", ""])
    for item in summary["removed_entries"]:
        lines.append("- `{}`".format(item))
    if not summary["removed_entries"]:
        lines.append("- none")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Compare before/after near-hit frontier indexes.")
    parser.add_argument("--before", default="")
    parser.add_argument("--frontier", required=True)
    parser.add_argument("--out-json", required=True)
    parser.add_argument("--out-md", required=True)
    args = parser.parse_args()

    before_records = records_from(args.before) if args.before else []
    after_records = records_from(args.frontier)
    summary = summarize(before_records, after_records)
    write_json(args.out_json, summary)
    write_text(args.out_md, md(summary))
    print("wrote", args.out_json)
    print("wrote", args.out_md)


if __name__ == "__main__":
    main()
