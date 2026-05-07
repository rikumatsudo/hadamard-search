# Remote Research Runs

This repository can run SageMath experiments on GitHub Actions through
`.github/workflows/research.yml`.

## Start a Run

```bash
gh workflow run research.yml \
  -f run_label=p167-actions-smoke \
  -f config=configs/experiments/p167_tuple_A_actions_smoke.yaml \
  -f seeds=1 \
  -f steps=1 \
  -f snapshot_interval=1 \
  -f candidates_per_family=1 \
  -f selected_per_family=1 \
  -f max_repair_candidates=0
```

Watch the run:

```bash
gh run watch
```

Artifacts are uploaded as `research-<run_label>-<run_id>` and include the
experiment output directory, `runner.log`, `actions_summary.md`, and the Slack
payload used for notification.

## Slack Notification

Create a Slack incoming webhook and store it as a repository secret:

```bash
gh secret set SLACK_WEBHOOK_URL
```

If `SLACK_WEBHOOK_URL` is not set, the workflow still runs and uploads artifacts;
only the Slack notification step is skipped.

## Notes

- The workflow only accepts config paths under `configs/experiments/*.yaml`.
- Use `configs/experiments/p167_tuple_A_actions_smoke.yaml` for fast
  workflow checks. Use `configs/experiments/p167_tuple_A_exactlike_smoke.yaml`
  or larger configs when you intentionally want heavier diagnostics.
- The workflow pins the SageMath Docker image to `sagemath/sagemath:10.8`,
  matching the local SageMath version used in this repository.
- Large raw outputs remain ignored by git and should be consumed from Actions
  artifacts, releases, or external research storage.
- A `score=0` candidate is still only accepted when the existing Sage validation
  records the exact SDS and Hadamard checks as passing.
