# Small-p Pipeline Framework Summary

This is a config-driven pipeline smoke run, not a Hadamard 668 construction run.

## Target

- p: `37`
- ks: `[13, 16, 18, 18]`
- lambda: `28`
- mode: `pipeline_smoke`

## Stage Outputs

- Stage 1 target registry: `target_registry.json`
- Stage 2 exact validation: `exact_validation.json`
- Stage 3 initialization: `initial_candidates.jsonl`, `initialization_summary.json`
- Stage 4 trajectories: `trajectory_runs.jsonl`
- Stage 5 diagnostics: `diagnostic_candidates.jsonl`
- Stage 6 labels: `candidate_labels.jsonl`, `false_basin_classifier_features.csv`
- Stage 7 repair hooks: `repair_attempts.jsonl`, `repair_summary.json`
- Stage 8 report: `comparison_summary.csv`, `comparison_summary.json`, this file

## Results

```json
{
  "diagnostic_candidate_count": 100,
  "initial_candidate_count": 140,
  "label_counts": {
    "exact": 1,
    "exact_derived": 17,
    "hard_basin": 2,
    "search_derived_false_basin": 36,
    "unknown": 44
  },
  "repair_attempt_count": 40,
  "score0_reached_in_smoke": false,
  "trajectory_run_count": 50
}
```

## Required Answers

1. p=37 exact は検証済みか: `True`.
2. pipeline は config-driven に動くか: `True`; CLI args select p/ks/lambda/exact/mode/seeds/steps/out-dir.
3. 各 stage の目的と出力は明確か: `True`; see `pipeline_design.md` and Stage Outputs above.
4. score-only / escapability-aware / energy-regularized / mixed-diversity の比較はできたか: `True`.
5. false basin classifier features は出たか: `100` rows.
6. repair hook は統一形式で呼べるか: `40` attempts written.
7. 今後 p=43/47/67/167 に拡張できるか: `True`; target registry and CLI are p/tuple driven, while exact-distance labels degrade to unknown when no exact is supplied.

## Interpretation

- score=0 only is counted as success.
- p=37 remains a validation target because exact and search-derived false basins can both be labeled.
- For 668, use the same outputs to choose tuple/family/mode by return-like dynamics before heavy LNS.

## Validation

- `sage sage/06_known_sds_regression.sage`: all known SDS regressions passed.
- `sage sage/08_analyze_sds_candidate.sage outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json`: computed score=0, l1=0, max_abs=0.
- `sage sage/05_validate_candidate_json.sage outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json`: SDS OK.
- `sage sage/04_build_gs_from_sds.sage outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json`: `HH^T = 148I`.
