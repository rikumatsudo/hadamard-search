# Small-p Escapability Validation Summary

This is algorithm validation on small cyclic SDS cases, not a Hadamard 668 construction claim.

## Target

- p: `7`
- ks: `[1, 3, 3, 3]`
- lambda: `3`
- repo known exact for p: `True`

## Mode Summaries

```json
{
  "escapability_aware": {
    "best_low_score_escapable": 4,
    "best_score": 0,
    "false_basin_event_count": 0,
    "final_hard_basin_count": 0,
    "median_InitHardness": 7.2000000000000455,
    "median_Q_ratio": 1.6875,
    "median_success_step": 1,
    "mode": "escapability_aware",
    "run_count": 3,
    "success_count": 3,
    "success_rate": 1.0
  },
  "score_only": {
    "best_low_score_escapable": null,
    "best_score": 0,
    "false_basin_event_count": 0,
    "final_hard_basin_count": 0,
    "median_InitHardness": 43.200000000000045,
    "median_Q_ratio": null,
    "median_success_step": 1,
    "mode": "score_only",
    "run_count": 3,
    "success_count": 3,
    "success_rate": 1.0
  }
}
```

## Comparison

```json
{
  "escapability_aware": {
    "best_low_score_escapable": 4,
    "best_score": 0,
    "false_basin_event_count": 0,
    "final_hard_basin_count": 0,
    "median_InitHardness": 7.2000000000000455,
    "median_Q_ratio": 1.6875,
    "median_success_step": 1,
    "mode": "escapability_aware",
    "run_count": 3,
    "success_count": 3,
    "success_rate": 1.0
  },
  "score_only": {
    "best_low_score_escapable": null,
    "best_score": 0,
    "false_basin_event_count": 0,
    "final_hard_basin_count": 0,
    "median_InitHardness": 43.200000000000045,
    "median_Q_ratio": null,
    "median_success_step": 1,
    "mode": "score_only",
    "run_count": 3,
    "success_count": 3,
    "success_rate": 1.0
  }
}
```

## Required Answers

1. p=37 usable tuple was enumerated and selected as `[1, 3, 3, 3]`; repo-known exact target found: `True`.
2. If all modes reach score=0 quickly, p=37 is too easy for discrimination; otherwise the run is landscape/false-basin validation only.
3. Success rate and median steps are in `comparison_summary.json`; score=0 only is counted as success.
4. False basin hit rate is reported through `false_basin_event_count` and `final_hard_basin_count`.
5. Hardening diagnostics are saved in `hardening_events.jsonl`; this prototype samples those events sparsely.
6. Moment diagnostics are saved, but moments are not used as early-stage objective.
7. Any score=0 small-p candidate must still be checked with SDS and Goethals-Seidel HH^T verification.

## Safety

- This run does not solve Hadamard 668.
- score>0 candidates are diagnostic near-hits, not solutions.
- score=0 is not a Hadamard 668 claim; for small p it is only a small-case validation candidate until SDS/GS verification passes.
