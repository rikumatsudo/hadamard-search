# p167 Broad Tuple Trajectory Dataset

Status: Stage 0 tuple registry, calibration script, workflow, and dispatch helper.

Scope: p=167, n=668, broad landscape sampling across the 10 row-sum absolute tuple classes.

This document defines the dataset contract for `p167 broad tuple trajectory dataset calibration`. Stage 0 is not a solver run. Its purpose is to make future p167 experiments comparable across tuple class, seed family, operator, and trajectory signature.

## Motivation

The current low-score p167 near-hit set, especially score164/176 around tuple `[73,78,79,81]`, is useful as a benchmark trap but is too narrow for deciding where Hadamard 668 search should go next.

The next research unit should sample the broader p167 landscape and answer:

- which tuple class produces exact-like trajectory signatures;
- which seed family avoids immediate hardening;
- which operator improves move-space metrics without damaging the state;
- which trajectories deserve deeper follow-up.

The success condition for Stage 0 is not score improvement. Success means that the dataset layers, labels, runtime, artifact size, and aggregation summaries are stable enough to support Stage 1.

## Tuple Class Registry

The fixed registry is:

```text
configs/fixtures/p167_tuple_classes.json
```

Tuple classes are defined by unordered absolute row sums.

```text
r_i = p - 2*k_i
sum_i r_i^2 = 4*p
```

For p=167, there are 10 unordered absolute row-sum classes.

Equivalence:

```text
block permutation is equivalent
block complement is a row-sum sign flip
tuple_class_id is determined by the absolute row-sum multiset
```

The representative tuple convention is:

```text
take all row sums positive
k_i = (167-r_i)/2
sort k_i ascending
```

## Benchmark Trap Set

The fixed score164/176 benchmark manifest is:

```text
configs/fixtures/benchmark_traps/p167_score164_176.jsonl
```

This is a manifest, not a duplicate of the heavy candidate payload. It points to rows in:

```text
configs/fixtures/p167_focused_nearhit_candidates.jsonl
```

Usage:

- score164: hard benchmark trap;
- score176: repair probe / operator response benchmark;
- not a primary deep-search target for Stage 0;
- useful for measuring whether a new operator reacts to known hard traps.

## Dataset Layers

The dataset has three layers.

### Run-Level

One row per configured trajectory task.

Required fields:

```text
run_id
task_id
tuple_class_id
abs_row_sums
ks
lambda
seed_family
operator
restart_id
shard_id
github_run_id
code_commit
config_hash
input_manifest_hash
diagnostic_type
diagnostic_sample_count
diagnostic_seed
diagnostic_budget
started_at
completed_at
wall_time_seconds
status
```

### Trajectory-Level

One row per completed trajectory.

Required fields:

```text
run_id
task_id
tuple_class_id
seed_family
operator
restart_id
initial_score
best_score
final_score
score_delta_from_start
best_exactlike_score
best_false_basin_score
best_closure_shell_score
best_alignment_to_minus_rho
damage_score
hardening_score
support_mixing_score
damage_seen
acceptance_rate
attempted_steps
accepted_moves
best_state_hash
final_state_hash
final_label
recommendation
runtime_seconds
artifact_bytes
```

Stage 0 labels are soft/rank labels, not mathematical success labels.

### Snapshot-Level

One row per logged state.

Required fields:

```text
run_id
task_id
snapshot_kind
attempted_steps
accepted_moves
acceptance_rate
S
best_S
score_delta_from_start
support_size
S_over_support
max_abs_rho
pm1_fraction
value_counts
D_min_ratio
P_8
P_16
P_32
P_thetaS_001
P_thetaS_005
P_thetaS_010
kappa_max
kappa_q90
kappa_q99
Q_ratio
closure_shell_score
closure_shell_delta
best_alignment_to_minus_rho
alignment_delta
best_alignment_move_deltaS
best_alignment_move_added_support_count
best_alignment_move_removed_support_count
defect_support_turnover
persistent_defect_fraction
new_defect_fraction
stubborn_defect_count
diagnostic_type
diagnostic_sample_count
diagnostic_seed
diagnostic_budget
```

## Soft Label Design

p167 does not have known exact targets, so hard labels like `exact_like` and `false_like` should not be primary fields.

Use continuous scores first:

```text
exactlike_score
false_basin_score
closure_shell_score
damage_score
hardening_score
support_mixing_score
```

Then derive rank labels during aggregation:

```text
top_decile_exactlike_candidate
bottom_decile_false_basin_candidate
high_closure_shell_candidate
damage_candidate
```

The rank reference should be explicit:

```text
within_run
within_tuple_class
within_score_band
within_operator
```

## Sampled Diagnostics

For p167, move-space diagnostics may be sampled.

Every diagnostic row must include:

```text
diagnostic_type = full or sampled
diagnostic_sample_count
diagnostic_seed
diagnostic_budget
```

If `diagnostic_type = sampled`, then `D_min/S`, `kappa`, and alignment are not full certificates.

All summaries must state:

```text
sampled diagnostics are not full certificates
```

## Snapshot Schedule

Default Stage 0 snapshots:

```text
attempted_steps: 0, 25, 50, 100, 200
accepted_moves: 0, 25, 50, 100
special states:
  best_score_state
  best_exactlike_state
  best_closure_shell_state
  best_alignment_state
  final_state
```

High-resolution logging can be enabled around promising states.

Triggers:

```text
closure_shell_score enters top 5% of current run
kappa_q99 improves by top decile
D_min_ratio improves by at least 20%
alignment_to_minus_rho improves by at least 0.15
best_score improves by score band
```

When triggered, log every accepted move for the next 50 accepted moves.

## Stage 0 Calibration Config

The default config is:

```text
configs/experiments/p167_broad_tuple_stage0_calibration.yaml
```

Default scope:

```text
tuples: 10
seed_families: pure_random, mixed_diversity
operators:
  baseline_score_only
  random_walk_score_guarded
  focused_plus_small_threshold
restarts: 1
steps: 200
sample_swaps: 100
diagnostic_sample_count: 100
shard_count: 40
```

Local execution policy:

```text
local runs are smoke-only
nontrivial calibration runs use GitHub Actions 40 shard fan-out
```

## Stage 0 Success Criteria

Stage 0 is successful if:

- all 10 tuple classes produce run-level rows;
- run-level, trajectory-level, and snapshot-level files are written;
- sampled diagnostic metadata is present;
- `code_commit`, `config_hash`, and `input_manifest_hash` are present;
- artifact size is measured;
- per-shard runtime is measured;
- aggregate summaries exist for tuple, seed family, operator, and trajectory label;
- no large bulk generated outputs are committed.

Score improvement is not required for Stage 0 success.

## Expected Output Files

Stage 0 implementation should write:

```text
run_level.jsonl
trajectory_level.jsonl
snapshot_level.jsonl
run_level_records.jsonl
trajectory_level_records.jsonl
snapshot_level_records.jsonl
tuple_summary.csv
tuple_summary.json
seed_family_summary.csv
seed_family_summary.json
operator_summary.csv
operator_summary.json
trajectory_label_summary.csv
trajectory_label_summary.json
trajectory_type_summary.csv
trajectory_type_summary.json
diagnostic_budget_summary.csv
diagnostic_budget_summary.json
shard_distribution_summary.csv
shard_distribution_summary.json
tuple_by_shard_matrix.csv
seed_family_by_shard_matrix.csv
operator_by_shard_matrix.csv
runtime_summary.csv
runtime_summary.json
artifact_size_summary.json
input_manifest.json
input_manifest_hash.txt
tuple_class_registry.json
hypothesis_evaluation.json
p167_broad_tuple_stage0_calibration_summary.md
p167_broad_tuple_trajectory_dataset_calibration_schema_patch_summary.md
```

Schema audit fields:

```text
closure_shell_rank_within_tuple / percentile
closure_shell_rank_within_score_band / percentile
closure_shell_percentile_within_run
D_min_ratio_rank_within_tuple / percentile
D_min_ratio_rank_within_score_band / percentile
kappa_q99_rank_within_tuple / percentile
kappa_q99_rank_within_score_band / percentile
alignment_rank_within_tuple / percentile
alignment_rank_within_score_band / percentile
damage_score and damage_score_component_*
```

Rank direction:

```text
closure_shell_score, kappa_q99, and alignment: higher is better
D_min_ratio: lower is better
rank 1 is best; percentile 1.0 is best
score_band = floor(S / 50) * 50
```

## Implementation Files

Tuple registry / benchmark manifest:

```text
configs/fixtures/p167_tuple_classes.json
configs/fixtures/benchmark_traps/p167_score164_176.jsonl
```

Config:

```text
configs/experiments/p167_broad_tuple_stage0_calibration.yaml
```

Calibration implementation:

```text
sage/73_p167_broad_tuple_trajectory_dataset_calibration.sage
.github/workflows/p167-broad-tuple-trajectory-calibration.yml
```

Dispatch helper:

```text
scripts/dispatch_p167_broad_stage0.py
```

The script consumes the tuple registry and Stage 0 config, produces the three dataset layers, uses shard assignment, and aggregates summaries without running a large local experiment.

## Dispatch Presets

The helper is dry-run by default.

Remote smoke:

```bash
python3 scripts/dispatch_p167_broad_stage0.py \
  --preset remote-smoke \
  --ref main \
  --run-label p167-broad-stage0-remote-smoke-YYYYMMDD
```

40 shard Stage 0:

```bash
python3 scripts/dispatch_p167_broad_stage0.py \
  --preset stage0-40 \
  --ref main \
  --run-label p167-broad-stage0-40x-YYYYMMDD
```

Short 40 shard calibration:

```bash
python3 scripts/dispatch_p167_broad_stage0.py \
  --preset stage0-lite-40 \
  --ref main \
  --run-label p167-broad-stage0-lite-40x-YYYYMMDD
```

Add `--execute` only after inspecting the printed `env -u GITHUB_TOKEN gh workflow run ...` command.
