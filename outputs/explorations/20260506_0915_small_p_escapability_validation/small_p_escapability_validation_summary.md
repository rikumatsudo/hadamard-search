# Small-p Escapability Validation Summary

This is algorithm validation on small cyclic SDS cases, not a Hadamard 668 construction claim.

## Target

- p: `37`
- ks: `[13, 16, 18, 18]`
- lambda: `28`
- repo known exact for p: `False`

## Mode Summaries

```json
{
  "escapability_aware": {
    "best_low_score_escapable": 8,
    "best_score": 4,
    "false_basin_event_count": 15,
    "final_hard_basin_count": 15,
    "median_InitHardness": -907.8285714285666,
    "median_Q_ratio": 38.58159722222222,
    "median_success_step": null,
    "mode": "escapability_aware",
    "run_count": 20,
    "success_count": 0,
    "success_rate": 0.0
  },
  "score_only": {
    "best_low_score_escapable": null,
    "best_score": 4,
    "false_basin_event_count": 17,
    "final_hard_basin_count": 17,
    "median_InitHardness": -1075.8285714285666,
    "median_Q_ratio": 38.407986111111114,
    "median_success_step": null,
    "mode": "score_only",
    "run_count": 20,
    "success_count": 0,
    "success_rate": 0.0
  }
}
```

## Comparison

```json
{
  "escapability_aware": {
    "best_low_score_escapable": 8,
    "best_score": 4,
    "false_basin_event_count": 15,
    "final_hard_basin_count": 15,
    "median_InitHardness": -907.8285714285666,
    "median_Q_ratio": 38.58159722222222,
    "median_success_step": null,
    "mode": "escapability_aware",
    "run_count": 20,
    "success_count": 0,
    "success_rate": 0.0
  },
  "score_only": {
    "best_low_score_escapable": null,
    "best_score": 4,
    "false_basin_event_count": 17,
    "final_hard_basin_count": 17,
    "median_InitHardness": -1075.8285714285666,
    "median_Q_ratio": 38.407986111111114,
    "median_success_step": null,
    "mode": "score_only",
    "run_count": 20,
    "success_count": 0,
    "success_rate": 0.0
  }
}
```

## Required Answers

1. p=37 usable tuple was enumerated and selected as `[13, 16, 18, 18]`; repo-known exact target found: `False`.
2. If all modes reach score=0 quickly, p=37 is too easy for discrimination; otherwise the run is landscape/false-basin validation only.
3. Success rate and median steps are in `comparison_summary.json`; score=0 only is counted as success.
4. False basin hit rate is reported through `false_basin_event_count` and `final_hard_basin_count`.
5. Hardening diagnostics are saved in `hardening_events.jsonl`; this prototype samples those events sparsely.
6. Moment diagnostics are saved, but moments are not used as early-stage objective.
7. Any score=0 small-p candidate must still be checked with SDS and Goethals-Seidel HH^T verification.

## Codex Interpretation

- `p=37`, tuple `[13,16,18,18]`, `lambda=28` had no repo-known exact candidate, so this run is landscape/false-basin validation rather than success-to-exact benchmarking.
- `score_only` and `escapability_aware` both reached best `score=4`, but neither reached `score=0` in `20` seeds x `5000` steps.
- Low-score false basins are real even at `p=37`: `score_only` ended in hard basins in `17/20` runs, while `escapability_aware` ended in hard basins in `15/20` runs.
- `escapability_aware` did preserve a low-score escapable candidate at `score=8`; score-only did not preserve one in this run.
- This is a weak positive for escapability-aware frontiering as a diagnostic/frontier policy, but not yet a success-rate improvement.
- Because `p=37` reaches `score=4` very easily but does not close to `score=0`, it is a useful false-basin calibration case for the 668 route.

## Safety

- This run does not solve Hadamard 668.
- score>0 candidates are diagnostic near-hits, not solutions.
- score=0 is not a Hadamard 668 claim; for small p it is only a small-case validation candidate until SDS/GS verification passes.
