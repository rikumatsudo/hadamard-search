#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def load_json(path):
    if not path.exists():
        return None
    with path.open() as f:
        return json.load(f)


def fmt_value(value):
    if value is None:
        return "n/a"
    return str(value)


def best_score(mode_rows):
    values = []
    for row in mode_rows:
        value = row.get("best_score_overall")
        if isinstance(value, (int, float)):
            values.append(value)
    return min(values) if values else None


def verification_counts(comparison):
    verification = comparison.get("verification", {}) if comparison else {}
    return (
        verification.get("sds_ok_count"),
        verification.get("hadamard_ok_count"),
    )


def build_summary(args, comparison):
    mode_rows = comparison.get("mode_summary", []) if comparison else []
    score0_paths = comparison.get("score0_candidate_paths", []) if comparison else []
    sds_ok, hadamard_ok = verification_counts(comparison)
    summary_path = Path(args.out_dir) / "experiment_summary.md"

    lines = [
        "# Research Experiment",
        "",
        "- status: `{}`".format(args.status),
        "- label: `{}`".format(args.run_label),
        "- engine: `{}`".format(args.engine),
        "- config: `{}`".format(args.config),
        "- run: {}".format(args.run_url),
        "- output: `{}`".format(args.out_dir),
        "- score0 candidates: `{}`".format(len(score0_paths)),
        "- Sage verified SDS: `{}`".format(fmt_value(sds_ok)),
        "- Sage verified Hadamard: `{}`".format(fmt_value(hadamard_ok)),
        "- best score overall: `{}`".format(fmt_value(best_score(mode_rows))),
    ]
    if summary_path.exists():
        lines.append("- summary: `{}`".format(summary_path))
    else:
        lines.append("- summary: `not generated`")
    if not comparison:
        lines.append("- warning: `comparison_summary.json was not generated`")
    return "\n".join(lines) + "\n"


def build_slack_payload(args, comparison):
    mode_rows = comparison.get("mode_summary", []) if comparison else []
    score0_paths = comparison.get("score0_candidate_paths", []) if comparison else []
    sds_ok, hadamard_ok = verification_counts(comparison)
    best = fmt_value(best_score(mode_rows))
    status = args.status.upper()
    text = "Research experiment {}: {} ({})".format(status, args.run_label, args.config)

    fields = [
        {"type": "mrkdwn", "text": "*Status*\n{}".format(status)},
        {"type": "mrkdwn", "text": "*Label*\n{}".format(args.run_label)},
        {"type": "mrkdwn", "text": "*Engine*\n{}".format(args.engine)},
        {"type": "mrkdwn", "text": "*Score0 candidates*\n{}".format(len(score0_paths))},
        {"type": "mrkdwn", "text": "*Sage verified*\nSDS {} / HH^T {}".format(fmt_value(sds_ok), fmt_value(hadamard_ok))},
        {"type": "mrkdwn", "text": "*Best score*\n{}".format(best)},
        {"type": "mrkdwn", "text": "*Config*\n`{}`".format(args.config)},
        {"type": "mrkdwn", "text": "*Output*\n`{}`".format(args.out_dir)},
    ]
    blocks = [
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*Hadamard research experiment* <{}|GitHub Actions run>".format(args.run_url),
            },
        },
        {"type": "section", "fields": fields},
    ]
    if not comparison:
        blocks.append(
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": ":warning: `comparison_summary.json` was not generated. Check `runner.log` in the artifact.",
                },
            }
        )
    return {"text": text, "blocks": blocks}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--run-label", required=True)
    parser.add_argument("--run-url", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--engine", default="sage")
    parser.add_argument("--payload", required=True)
    parser.add_argument("--github-summary", default=None)
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    comparison = load_json(out_dir / "comparison_summary.json")

    summary = build_summary(args, comparison)
    payload = build_slack_payload(args, comparison)

    Path(args.payload).write_text(json.dumps(payload, indent=2) + "\n")
    (out_dir / "actions_summary.md").write_text(summary)
    (out_dir / "actions_metadata.json").write_text(
        json.dumps(
            {
                "status": args.status,
                "engine": args.engine,
                "config": args.config,
                "run_label": args.run_label,
                "run_url": args.run_url,
                "out_dir": args.out_dir,
            },
            indent=2,
        )
        + "\n"
    )

    if args.github_summary:
        with Path(args.github_summary).open("a") as f:
            f.write(summary)
    print(summary)


if __name__ == "__main__":
    main()
