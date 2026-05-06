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
    "best_low_score_escapable": 20,
    "best_score": 16,
    "false_basin_event_count": 0,
    "final_hard_basin_count": 0,
    "median_InitHardness": -1083.8285714285666,
    "median_Q_ratio": 17.26909722222222,
    "median_success_step": null,
    "mode": "escapability_aware",
    "run_count": 2,
    "success_count": 0,
    "success_rate": 0.0
  },
  "score_only": {
    "best_low_score_escapable": 12,
    "best_score": 12,
    "false_basin_event_count": 0,
    "final_hard_basin_count": 0,
    "median_InitHardness": -1031.8285714285666,
    "median_Q_ratio": 25.607638888888886,
    "median_success_step": null,
    "mode": "score_only",
    "run_count": 2,
    "success_count": 0,
    "success_rate": 0.0
  }
}
```

## Comparison

```json
{
  "escapability_aware": {
    "best_low_score_escapable": 20,
    "best_score": 16,
    "false_basin_event_count": 0,
    "final_hard_basin_count": 0,
    "median_InitHardness": -1083.8285714285666,
    "median_Q_ratio": 17.26909722222222,
    "median_success_step": null,
    "mode": "escapability_aware",
    "run_count": 2,
    "success_count": 0,
    "success_rate": 0.0
  },
  "score_only": {
    "best_low_score_escapable": 12,
    "best_score": 12,
    "false_basin_event_count": 0,
    "final_hard_basin_count": 0,
    "median_InitHardness": -1031.8285714285666,
    "median_Q_ratio": 25.607638888888886,
    "median_success_step": null,
    "mode": "score_only",
    "run_count": 2,
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

## Safety

- This run does not solve Hadamard 668.
- score>0 candidates are diagnostic near-hits, not solutions.
- score=0 is not a Hadamard 668 claim; for small p it is only a small-case validation candidate until SDS/GS verification passes.
