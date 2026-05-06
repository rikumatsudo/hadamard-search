# 428 Exact Basin Landscape Summary

This is a positive-control calibration around the known order-428 construction. It is not a Hadamard 668 construction claim.

## Exact Baseline

- exact candidate: `outputs/explorations/20260506_0310_hadamard428_positive_control_perturbation/exact_428_sds_candidate.json`
- score: `0`
- l1_error: `0`
- max_abs_error: `0`
- nonzero_defect_count: `0`
- moments: `{'T2': 0, 'T4': 0, 'T6': 0, 'T8': 0, 'T10': 0, 'T12': 0}`

## Run Scope

- distances: `1,2`
- samples_per_distance: `20`
- diagnostic_limit_per_distance: `10`
- descent_limit_per_distance: `3`

## Distance Summary

| distance | samples | diagnosed | score min | score median | h_min min | local min rate diagnosed | returned-to-score0 rate | false valleys |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 20 | 20 | 72 | 96.0 | -140 | 0.0000 | 1.0000 | 0 |
| 2 | 20 | 20 | 108 | 188.0 | -200 | 0.0000 | 1.0000 | 0 |

## False Valleys

- No nonexact 1-swap local minimum was found among the diagnosed perturbations.

## 428 vs 668 Comparison

| candidate | p | score | l1 | max | nonzero | h_min | improving swaps | D_min_ratio | Q_ratio | interpretation |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `428_exact` | 107 | 0 | 0 | 0 | 0 | 48 | 0 | NA | NA | known exact positive control |
| `668_score164` | 167 | 164 | 116 | 3 | 96 | 4 | 0 | 1.024390 | 41.555135 | 668 low-score 1-swap local minimum |
| `668_score176` | 167 | 176 | 112 | 3 | 86 | 8 | 0 | 1.045455 | 38.727889 | 668 low-score 1-swap local minimum |
| `668_score284` | 167 | 284 | 164 | 3 | 112 | -68 | 30 | 0.760563 | 24.005706 | 668 auxiliary comparison candidate |
| `668_score424` | 167 | 424 | 208 | 4 | 128 | -72 | 112 | 0.830189 | 16.080473 | 668 auxiliary comparison candidate |

## Required Answers

1. No diagnosed false valley was found in this run.
2. Nearest false-valley metrics are therefore unavailable for this run.
3. Distance-wise local-minimum rates are in the Distance Summary table; rates are among exactly diagnosed rows, not all random rows when diagnostic sampling is limited.
4. Returned-to-score0 rates from local descent are also in the Distance Summary table.
5. Compare 668 score164/score176 against the nearest 428 false valley above: positive h_min and D_min_ratio>1 indicate false-valley behavior, while D_min_ratio=0 indicates a direct return path.
6. Moment signatures remain diagnostics only; 428 perturbations can have low score while low-degree moments are nonzero.
7. `h_min` and `D_min_ratio` are the clearest local false-valley indicators; `Q_ratio` is a cost-background diagnostic.
8. If 428 false valleys resembling score164/176 occur only at larger distances, 668 score164/176 should be treated as false-basin candidates rather than immediate true-neighborhood candidates.

## Safety

- 428 exact is a known positive control, not a new result.
- No Hadamard 668 construction is claimed.
- Perturbed 428 candidates are calibration artifacts unless score=0 and validation passes.
