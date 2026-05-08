# Hadamard Search for n = 668

This repository contains SageMath scripts, experiment configs, and GitHub
Actions automation for searching for a Hadamard matrix of order `668 = 4 * 167`.

The search is based on supplementary difference sets (SDS), not a brute-force
search over all `+1/-1` matrices.

## Approach

1. Search for four SDS blocks over `Z_167`.
2. Convert the blocks into four circulant `+1/-1` matrices.
3. Build the Goethals-Seidel array of order `668`.
4. Accept a candidate only when SageMath verifies the exact identity
   `H * H.transpose() == 668 * identity_matrix(ZZ, 668)`.

Unverified near-hits are research artifacts, not successes.

## Repository Layout

```text
.
  .github/workflows/research.yml       GitHub Actions remote runner
  configs/experiments/                 Experiment configs
  docs/remote-research.md              Remote run and Slack notification guide
  sage/                                SageMath and Python research scripts
  scripts/actions_summary.py           Actions artifact and Slack summary builder
  outputs/                             Lightweight tracked summaries and ignored run data
```

Generated artifacts, logs, large JSONL/CSV files, and local caches are ignored by
git. Remote run outputs should be consumed from GitHub Actions artifacts.

## Requirements

- SageMath `10.8` for local runs
- Python 3 for helper scripts
- GitHub CLI `gh` for remote runs
- Docker only if you want to reproduce the GitHub Actions Sage environment

The GitHub Actions workflow uses `sagemath/sagemath:10.8`.

## Local Smoke Test

Run the minimal `N=1` smoke test locally before pushing workflow or experiment
changes and before dispatching production remote runs:

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

This checks that the current config, imports, Sage environment, output writing,
and summary inputs are still compatible. The command writes its main output under
the temporary directory and may write an ignored log under `outputs/logs/`.

## Remote GitHub Actions Runs

Remote SageMath experiments are launched manually with `workflow_dispatch`:

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

See [docs/remote-research.md](docs/remote-research.md) for Slack setup,
artifact layout, and production run guidance.

## Production Run Policy

For production searches, first pass the local `N=1` smoke test, then push the
change, then run a remote smoke test. Only after that should heavier production
runs be dispatched.

When the repository is public and standard GitHub-hosted runners are used,
parallelize independent runs up to the current GitHub Actions concurrency limit
for the account. On GitHub Free standard runners, that limit is currently 20
concurrent jobs. Use unique `run_label` values so the workflow concurrency group
does not serialize independent runs.

Do not use GitHub larger runners unless cost has been explicitly approved.

## Success Criteria

A candidate is successful only if all of the following hold:

- The candidate JSON contains `v = 167`, `n = 668`, four block sizes, `lambda`,
  and four blocks over `Z_167`.
- The SDS difference condition is verified for every nonzero shift.
- The Goethals-Seidel matrix is generated from those blocks.
- SageMath verifies `H * H.transpose() == 668 * identity_matrix(ZZ, 668)`.
- The JSON records `verify_sds = true`, `generated_hadamard = true`, and
  `hh_t = true`.

## Key Scripts

- `sage/04_build_gs_from_sds.sage`: build and verify a Goethals-Seidel matrix
  from a candidate JSON.
- `sage/05_validate_candidate_json.sage`: validate SDS JSON shape and
  difference conditions.
- `sage/06_known_sds_regression.sage`: small known-SDS regression checks.
- `sage/07_guided_sds_search_668.sage`: guided local search for `Z_167`.
- `sage/62_exactlike_guided_generator_validation.sage`: config-driven
  exact-like guided generator used by GitHub Actions.
- `sage/sds_repair_utils.py`: shared validation, metrics, and repair helpers.

## Data Hygiene

Keep the public repository focused on source code, configs, lightweight
summaries, and exact validation fixtures. Keep bulk run outputs in GitHub
Actions artifacts, releases, or external research storage.
