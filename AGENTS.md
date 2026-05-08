# AGENTS.md

These rules apply to the whole repository.

## Research Workflow

- Treat `score = 0` as a lead only. A result is successful only after the SDS
  condition and the exact Goethals-Seidel Hadamard identity are verified by
  SageMath.
- Before pushing workflow or experiment changes, run the local `N=1` smoke test:

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

- If the local smoke test fails, stop and fix the local issue before pushing or
  dispatching GitHub Actions.
- After changing `.github/workflows/research.yml`, also run YAML validation and a
  remote smoke test before production runs.

## GitHub Actions Operation

- Use `env -u GITHUB_TOKEN gh ...` in this local environment so the GitHub CLI
  uses the authenticated keychain account instead of a stale environment token.
- Do not print or commit Slack webhook URLs, tokens, or other secrets.
- Store Slack notification webhooks only as the repository secret
  `SLACK_WEBHOOK_URL`.
- Use `configs/experiments/p167_tuple_A_actions_smoke.yaml` for fast remote
  workflow checks.
- Use unique `run_label` values for independent remote runs. The workflow
  concurrency group includes `run_label`, so reusing a label can serialize runs.

## Production Parallelism

- For production searches, run in this order:
  1. local `N=1` smoke test,
  2. push the reviewed change,
  3. remote smoke test,
  4. production fan-out.
- On public repositories using standard GitHub-hosted runners, parallelize
  independent production runs up to the current GitHub Actions concurrency limit
  for the account. For GitHub Free standard runners, use up to 20 concurrent jobs
  unless GitHub's current limits say otherwise.
- Verify current GitHub Actions limits before changing fan-out strategy. Do not
  use larger runners unless the user explicitly approves cost.
- Split production work by seeds, parameter tuples, or config files. Keep each
  shard independently reproducible and label artifacts clearly.
- Prefer many bounded runs over one very long run so failures lose less work and
  Slack/artifact feedback arrives sooner.

## Data Hygiene

- Do not commit bulk generated data: `outputs/artifacts/`, `outputs/logs/`,
  large JSONL/CSV diagnostics, caches, or temporary files.
- Commit source, configs, exact validation fixtures, and concise markdown/JSON
  summaries when they are useful for review.
- Keep local-only paths and machine-specific settings out of committed docs.
- Keep public-facing documentation concise; put operational detail in `docs/`.
