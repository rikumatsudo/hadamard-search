# Remote Research Runs

This repository can run SageMath experiments on GitHub Actions through
`.github/workflows/research.yml`.

## Local Smoke First

Before pushing workflow/config changes or dispatching a production run, run the
minimal local `N=1` smoke test:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot \
sage sage/62_exactlike_guided_generator_validation.sage \
  --config configs/experiments/p167_tuple_A_actions_smoke.yaml \
  --out-dir "${TMPDIR:-/tmp}/hadamard-local-smoke" \
  --seeds 1 \
  --steps 1 \
  --snapshot-interval 1 \
  --candidates-per-family 1 \
  --selected-per-family 1 \
  --max-repair-candidates 0
```

Do not push or dispatch heavier remote work until this passes.

## Start a Remote Smoke Run

```bash
env -u GITHUB_TOKEN gh workflow run research.yml \
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
env -u GITHUB_TOKEN gh run watch
```

Artifacts are uploaded as `research-<run_label>-<run_id>` and include the
experiment output directory, `runner.log`, `actions_summary.md`, and the Slack
payload used for notification.

## Slack Notification

Create a Slack incoming webhook and store it as a repository secret:

```bash
env -u GITHUB_TOKEN gh secret set SLACK_WEBHOOK_URL --repo rikumatsudo/hadamard-search
```

If `SLACK_WEBHOOK_URL` is not set, the workflow still runs and uploads artifacts;
only the Slack notification step is skipped.

## Production Runs

Use the workflow only after local and remote smoke tests pass.

Production run order:

1. Run the local `N=1` smoke test.
2. Push the reviewed change.
3. Run the remote smoke workflow.
4. Fan out production runs.

For production searches, split the work by seed ranges, parameter tuples, or
config files. Use unique `run_label` values for each shard because the workflow
concurrency group includes the label.

On public repositories with standard GitHub-hosted runners, use GitHub Actions
parallelism up to the current account limit. For GitHub Free standard runners,
that is currently 20 concurrent jobs. Verify the current limit before increasing
fan-out, and do not use larger runners unless cost has been approved.

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
