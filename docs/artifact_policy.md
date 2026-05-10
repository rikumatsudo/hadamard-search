# Artifact Policy for Stage 2/3 Runs

This repository treats Stage 2/3 p167 runs as diagnostic dataset runs, not
Hadamard 668 construction runs. Score `0` is only a candidate until Sage
validation confirms the SDS and Goethals-Seidel identities.

## Artifact Classes

Stage 2/3 workflows separate artifacts into two classes.

### Summary Artifact

The summary artifact is the primary audit surface. It should stay small enough
to download and inspect routinely.

Expected contents include:

- `run_config.json`
- `actual_effective_config.json`
- `stage2_artifact_manifest.json`
- run-level and trajectory-level records
- compact `snapshot_level_records.jsonl`
- `snapshot_summary_by_trajectory.jsonl`
- snapshot summaries by tuple, operator, and recommendation
- operator reward summaries and top-k/sample logs
- Stage 3 recommendations
- hypothesis, runtime, diagnostic, and artifact summaries

### Raw/Debug Artifact

The raw/debug artifact is optional and intended for failure analysis or detailed
trajectory replay. Full logs must be compressed.

Expected contents include:

- `raw_logs/snapshot_level_records.jsonl.gz`
- `raw_logs/operator_reward_log.jsonl.gz`

## Default Stage 3 Policy

Recommended defaults:

- `artifact_mode=summary_only`
- `upload_raw_logs=false`
- `compress_raw_logs=true`
- `snapshot_log_mode=summary_only`
- `operator_reward_log_mode=topk`
- `operator_reward_topk=50`
- `high_resolution_mode=triggered`
- `high_resolution_max_windows_per_trajectory=2`
- `high_resolution_window_accepted_moves=50`

Use `artifact_mode=summary_plus_raw` or `upload_raw_logs=true` only when a run
needs full debug logs.

## Audit Notes

Sampled diagnostics are not full certificates. The artifact manifest records
whether full snapshot and operator reward logs are available, and where they
were stored.
