# Escapability-aware Guided Search Summary

This is an exploration-design diagnostic for Hadamard 668 SDS search. It is not a construction claim.

## Score-only Summary

```json
{
  "best_l1_error": 172,
  "best_max_abs_error": 3,
  "best_nonzero_defect_count": 106,
  "best_score": 352,
  "best_score_not_local_minimum": 508,
  "best_score_with_D_min_ratio_below_1": 508,
  "best_score_with_hmin_negative": 508,
  "diagnostic_count": 10,
  "hard_basin_archive_count": 0,
  "hard_basin_best_score": null,
  "hard_basin_count": 0,
  "highest_improving_swap_count": 791,
  "highest_near_improving_count_h_le_8": 1121,
  "lowest_D_min_ratio": 0.7900552486187845,
  "lowest_h_min": -152,
  "mode": "score_only",
  "saved_candidate_count": 10,
  "score164_like_count": 0,
  "score176_like_count": 0
}
```

## Escapability-aware Summary

```json
{
  "best_l1_error": 192,
  "best_max_abs_error": 3,
  "best_nonzero_defect_count": 112,
  "best_score": 348,
  "best_score_not_local_minimum": 576,
  "best_score_with_D_min_ratio_below_1": 576,
  "best_score_with_hmin_negative": 576,
  "diagnostic_count": 10,
  "hard_basin_archive_count": 0,
  "hard_basin_best_score": null,
  "hard_basin_count": 0,
  "highest_improving_swap_count": 716,
  "highest_near_improving_count_h_le_8": 1062,
  "lowest_D_min_ratio": 0.7928994082840237,
  "lowest_h_min": -144,
  "mode": "escapability_aware",
  "saved_candidate_count": 10,
  "score164_like_count": 0,
  "score176_like_count": 0
}
```

## Comparison

```json
{
  "best_score_delta_aware_minus_score_only": -4,
  "escapability_aware": {
    "best_l1_error": 192,
    "best_max_abs_error": 3,
    "best_nonzero_defect_count": 112,
    "best_score": 348,
    "best_score_not_local_minimum": 576,
    "best_score_with_D_min_ratio_below_1": 576,
    "best_score_with_hmin_negative": 576,
    "diagnostic_count": 10,
    "hard_basin_archive_count": 0,
    "hard_basin_best_score": null,
    "hard_basin_count": 0,
    "highest_improving_swap_count": 716,
    "highest_near_improving_count_h_le_8": 1062,
    "lowest_D_min_ratio": 0.7928994082840237,
    "lowest_h_min": -144,
    "mode": "escapability_aware",
    "saved_candidate_count": 10,
    "score164_like_count": 0,
    "score176_like_count": 0
  },
  "score_only": {
    "best_l1_error": 172,
    "best_max_abs_error": 3,
    "best_nonzero_defect_count": 106,
    "best_score": 352,
    "best_score_not_local_minimum": 508,
    "best_score_with_D_min_ratio_below_1": 508,
    "best_score_with_hmin_negative": 508,
    "diagnostic_count": 10,
    "hard_basin_archive_count": 0,
    "hard_basin_best_score": null,
    "hard_basin_count": 0,
    "highest_improving_swap_count": 791,
    "highest_near_improving_count_h_le_8": 1121,
    "lowest_D_min_ratio": 0.7900552486187845,
    "lowest_h_min": -152,
    "mode": "score_only",
    "saved_candidate_count": 10,
    "score164_like_count": 0,
    "score176_like_count": 0
  }
}
```

## Required Answers

1. Score-only best score: `352`; escapability-aware best score: `348`.
2. Hard-basin counts: score-only `0`, escapability-aware `0`.
3. score<=200 and h_min<0 best: score-only `508`, escapability-aware `576`.
4. score<=240 and D_min_ratio<1 best: score-only `508`, escapability-aware `576`.
5. Highest near-improving h<=8 count: score-only `1121`, escapability-aware `1062`.
6. score164/176-like hard basin counts are reported as `score164_like_count`.
7. Distinct frontier files preserve score-only and escapability-aware candidates for later inspection.
8. Next candidate selection should favor low score with `D_min_ratio < 1` or high near-improving counts over score-only hard minima.
9. This run supports expanding escapability-aware search only if it finds low-score escapable candidates not present in score-only.

## Safety

- score=0 is required before SDS/GS validation can produce a success candidate.
- Near-hits and frontier entries are research logs, not solutions.
