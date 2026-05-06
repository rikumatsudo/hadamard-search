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
  "energy_regularized_init": {
    "best_low_score_escapable": null,
    "best_score": 8,
    "false_basin_event_count": 5,
    "final_hard_basin_count": 5,
    "median_InitHardness": -907.8285714285666,
    "median_Q_ratio": 38.48784722222222,
    "median_success_step": null,
    "mode": "energy_regularized_init",
    "run_count": 10,
    "success_count": 0,
    "success_rate": 0.0
  },
  "escapability_aware": {
    "best_low_score_escapable": 16,
    "best_score": 4,
    "false_basin_event_count": 6,
    "final_hard_basin_count": 6,
    "median_InitHardness": -1045.8285714285666,
    "median_Q_ratio": 38.42534722222222,
    "median_success_step": null,
    "mode": "escapability_aware",
    "run_count": 10,
    "success_count": 0,
    "success_rate": 0.0
  },
  "mixed_diversity": {
    "best_low_score_escapable": null,
    "best_score": 4,
    "false_basin_event_count": 4,
    "final_hard_basin_count": 4,
    "median_InitHardness": -1003.8285714285666,
    "median_Q_ratio": 38.435763888888886,
    "median_success_step": null,
    "mode": "mixed_diversity",
    "run_count": 10,
    "success_count": 0,
    "success_rate": 0.0
  },
  "score_only": {
    "best_low_score_escapable": null,
    "best_score": 8,
    "false_basin_event_count": 18,
    "final_hard_basin_count": 8,
    "median_InitHardness": -871.8285714285666,
    "median_Q_ratio": 38.55034722222222,
    "median_success_step": null,
    "mode": "score_only",
    "run_count": 10,
    "success_count": 0,
    "success_rate": 0.0
  }
}
```

## Comparison

```json
{
  "energy_regularized_init": {
    "best_low_score_escapable": null,
    "best_score": 8,
    "false_basin_event_count": 5,
    "final_hard_basin_count": 5,
    "median_InitHardness": -907.8285714285666,
    "median_Q_ratio": 38.48784722222222,
    "median_success_step": null,
    "mode": "energy_regularized_init",
    "run_count": 10,
    "success_count": 0,
    "success_rate": 0.0
  },
  "escapability_aware": {
    "best_low_score_escapable": 16,
    "best_score": 4,
    "false_basin_event_count": 6,
    "final_hard_basin_count": 6,
    "median_InitHardness": -1045.8285714285666,
    "median_Q_ratio": 38.42534722222222,
    "median_success_step": null,
    "mode": "escapability_aware",
    "run_count": 10,
    "success_count": 0,
    "success_rate": 0.0
  },
  "mixed_diversity": {
    "best_low_score_escapable": null,
    "best_score": 4,
    "false_basin_event_count": 4,
    "final_hard_basin_count": 4,
    "median_InitHardness": -1003.8285714285666,
    "median_Q_ratio": 38.435763888888886,
    "median_success_step": null,
    "mode": "mixed_diversity",
    "run_count": 10,
    "success_count": 0,
    "success_rate": 0.0
  },
  "score_only": {
    "best_low_score_escapable": null,
    "best_score": 8,
    "false_basin_event_count": 18,
    "final_hard_basin_count": 8,
    "median_InitHardness": -871.8285714285666,
    "median_Q_ratio": 38.55034722222222,
    "median_success_step": null,
    "mode": "score_only",
    "run_count": 10,
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

- This all-mode smoke used `10` seeds x `3000` steps on `p=37`, tuple `[13,16,18,18]`.
- No mode reached `score=0`.
- `score_only`: best `8`, false-basin events `18`, final hard basins `8/10`.
- `escapability_aware`: best `4`, false-basin events `6`, final hard basins `6/10`, and a low-score escapable candidate at `score=16`.
- `energy_regularized_init`: best `8`, false-basin events `5`, final hard basins `5/10`.
- `mixed_diversity`: best `4`, false-basin events `4`, final hard basins `4/10`.
- In this short run, energy/diversity policies reduced hard-basin incidence more clearly than raw score-only, but did not solve the selected tuple.
- This supports carrying `mixed_diversity` and energy/AP regularized initialization back into larger validation, not just the escapability frontier.

## Safety

- This run does not solve Hadamard 668.
- score>0 candidates are diagnostic near-hits, not solutions.
- score=0 is not a Hadamard 668 claim; for small p it is only a small-case validation candidate until SDS/GS verification passes.
