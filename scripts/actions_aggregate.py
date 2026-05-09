#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def load_json(path):
    try:
        with path.open() as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except json.JSONDecodeError:
        return None


def best_score(mode_rows):
    values = []
    for row in mode_rows or []:
        value = row.get("best_score_overall")
        if isinstance(value, (int, float)):
            values.append(value)
    return min(values) if values else None


def fmt(value):
    return "n/a" if value is None else str(value)


def verification_counts(comparison):
    verification = comparison.get("verification", {}) if comparison else {}
    return (
        verification.get("sds_ok_count"),
        verification.get("hadamard_ok_count"),
    )


def discover_shards(artifacts_dir):
    shards = []
    for artifact_dir in sorted(Path(artifacts_dir).iterdir() if Path(artifacts_dir).exists() else []):
        if not artifact_dir.is_dir():
            continue
        comparison = load_json(artifact_dir / "comparison_summary.json")
        metadata = load_json(artifact_dir / "actions_metadata.json") or {}
        summary_path = artifact_dir / "actions_summary.md"
        mode_rows = comparison.get("mode_summary", []) if comparison else []
        score0_paths = comparison.get("score0_candidate_paths", []) if comparison else []
        sds_ok_count, hadamard_ok_count = verification_counts(comparison)
        shards.append(
            {
                "artifact": artifact_dir.name,
                "label": metadata.get("run_label") or artifact_dir.name,
                "engine": metadata.get("engine") or (comparison or {}).get("engine") or "unknown",
                "status": metadata.get("status") or ("success" if comparison else "missing_summary"),
                "config": metadata.get("config"),
                "output": metadata.get("out_dir"),
                "summary_present": summary_path.exists(),
                "comparison_present": comparison is not None,
                "score0_count": len(score0_paths),
                "sds_ok_count": sds_ok_count,
                "hadamard_ok_count": hadamard_ok_count,
                "best_score": best_score(mode_rows),
                "trajectory_run_count": None if not comparison else comparison.get("trajectory_run_count"),
                "frontier_count": None if not comparison else comparison.get("frontier_count"),
                "repair_attempt_count": None if not comparison else comparison.get("repair_attempt_count"),
            }
        )
    return shards


def build_markdown(args, shards):
    successful = sum(1 for shard in shards if shard["comparison_present"])
    score0_total = sum(int(shard["score0_count"]) for shard in shards)
    verified_total = sum(
        int(shard["hadamard_ok_count"])
        for shard in shards
        if isinstance(shard["hadamard_ok_count"], int)
    )
    best_values = [shard["best_score"] for shard in shards if isinstance(shard["best_score"], (int, float))]
    best = min(best_values) if best_values else None
    engines = sorted(set(shard["engine"] for shard in shards))
    lines = [
        "# Research Aggregate Summary",
        "",
        "- status: `{}`".format(args.status),
        "- label: `{}`".format(args.run_label),
        "- run: {}".format(args.run_url),
        "- engine(s): `{}`".format(", ".join(engines) if engines else "n/a"),
        "- fanout: `{}`".format(args.fanout),
        "- expected shards: `{}`".format(args.expected_shards),
        "- artifacts discovered: `{}`".format(len(shards)),
        "- shards with comparison summary: `{}`".format(successful),
        "- score0 candidates total: `{}`".format(score0_total),
        "- Sage verified Hadamard total: `{}`".format(verified_total),
        "- best score overall: `{}`".format(fmt(best)),
        "",
        "## Shards",
        "",
        "| artifact | label | engine | status | score0 | verified | best | trajectories | frontier | repairs |",
        "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for shard in shards:
        lines.append(
            "| `{}` | `{}` | `{}` | `{}` | {} | {} | {} | {} | {} | {} |".format(
                shard["artifact"],
                shard["label"],
                shard["engine"],
                shard["status"],
                shard["score0_count"],
                fmt(shard["hadamard_ok_count"]),
                fmt(shard["best_score"]),
                fmt(shard["trajectory_run_count"]),
                fmt(shard["frontier_count"]),
                fmt(shard["repair_attempt_count"]),
            )
        )
    if not shards:
        lines.append("| `none` | `n/a` | `n/a` | `missing` | 0 | 0 | n/a | n/a | n/a | n/a |")
    return "\n".join(lines) + "\n"


def build_slack_payload(args, shards):
    successful = sum(1 for shard in shards if shard["comparison_present"])
    score0_total = sum(int(shard["score0_count"]) for shard in shards)
    verified_total = sum(
        int(shard["hadamard_ok_count"])
        for shard in shards
        if isinstance(shard["hadamard_ok_count"], int)
    )
    best_values = [shard["best_score"] for shard in shards if isinstance(shard["best_score"], (int, float))]
    best = min(best_values) if best_values else None
    engines = sorted(set(shard["engine"] for shard in shards))
    engine_text = ", ".join(engines) if engines else "n/a"
    status = args.status.upper()
    text = "Research aggregate {}: {} ({} shards)".format(status, args.run_label, len(shards))
    fields = [
        {"type": "mrkdwn", "text": "*Status*\n{}".format(status)},
        {"type": "mrkdwn", "text": "*Label*\n{}".format(args.run_label)},
        {"type": "mrkdwn", "text": "*Engine(s)*\n{}".format(engine_text)},
        {"type": "mrkdwn", "text": "*Shards*\n{}/{}".format(successful, args.expected_shards)},
        {"type": "mrkdwn", "text": "*Score0 candidates*\n{}".format(score0_total)},
        {"type": "mrkdwn", "text": "*Sage verified*\n{}".format(verified_total)},
        {"type": "mrkdwn", "text": "*Best score*\n{}".format(fmt(best))},
        {"type": "mrkdwn", "text": "*Fanout*\n{}".format(args.fanout)},
    ]
    blocks = [
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*Hadamard research aggregate* <{}|GitHub Actions run>".format(args.run_url),
            },
        },
        {"type": "section", "fields": fields},
    ]
    missing = [shard for shard in shards if not shard["comparison_present"]]
    if missing:
        blocks.append(
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": ":warning: {} shard artifact(s) have no `comparison_summary.json`.".format(len(missing)),
                },
            }
        )
    return {"text": text, "blocks": blocks}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifacts-dir", required=True)
    parser.add_argument("--run-label", required=True)
    parser.add_argument("--run-url", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--expected-shards", type=int, required=True)
    parser.add_argument("--fanout", required=True)
    parser.add_argument("--payload", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--github-summary", default=None)
    args = parser.parse_args()

    shards = discover_shards(args.artifacts_dir)
    markdown = build_markdown(args, shards)
    payload = build_slack_payload(args, shards)

    Path(args.summary).write_text(markdown)
    Path(args.payload).write_text(json.dumps(payload, indent=2) + "\n")
    if args.github_summary:
        with Path(args.github_summary).open("a") as f:
            f.write(markdown)
    print(markdown)


if __name__ == "__main__":
    main()
