# Swap-cost Landscape Diagnostics

This is a hardness diagnostic for low-score near-hits. It is not a Hadamard 668 construction claim.

## Identity Checks

| candidate | score | sum_g ok | Q formula ok | sum_h ok | score delta mismatches |
|---|---:|---:|---:|---:|---:|
| `score164` | 164 | True | True | True | 0 |
| `score176` | 176 | True | True | True | 0 |
| `score284_moment006` | 284 | True | True | True | 0 |
| `score424_moment000` | 424 | True | True | True | 0 |
| `428_exact` | 0 | True | True | True | 0 |
| `428_distance1_best_score48` | 48 | True | True | True | 0 |
| `428_distance2_best_nonzero_score80` | 80 | True | True | True | 0 |

## 668 Hardness

| candidate | score | min_h | improving swaps | Q_ratio | D_min_ratio | max_alpha | max_alpha_minus_threshold |
|---|---:|---:|---:|---:|---:|---:|---:|
| `score164` | 164 | 4 | 0 | 41.555135 | 1.024390 | 0.434982 | -0.013593 |
| `score176` | 176 | 8 | 0 | 38.727889 | 1.045455 | 0.418718 | -0.026650 |
| `score284_moment006` | 284 | -68 | 30 | 24.005706 | 0.760563 | 0.521567 | 0.170512 |
| `score424_moment000` | 424 | -72 | 112 | 16.080473 | 0.830189 | 0.435070 | 0.150732 |

## 428 Comparison

| candidate | p | score | min_h | improving swaps | Q_ratio | D_min_ratio | interpretation |
|---|---:|---:|---:|---:|---:|---:|---|
| `428_exact` | 107 | 0 | 48 | 0 | NA | NA | exact SDS; ratios with score denominator are not defined |
| `428_distance1_best_score48` | 107 | 48 | -48 | 1 | 57.541667 | 0.000000 | has a one-swap return/improvement to exact or lower score |
| `428_distance2_best_nonzero_score80` | 107 | 80 | -80 | 12 | 34.507075 | 0.000000 | has a one-swap return/improvement to exact or lower score |

## Block-level Notes

- `score164` largest Q contribution: block `3` k `81` Q `1143356` ratio `0.2527` E `260613` AP `3191`.
- `score176` largest Q contribution: block `3` k `81` Q `1142984` ratio `0.2525` E `260569` AP `3189`.

## Moment-change Relation

- `score164`: low-moment improving swaps `24663`; best h among them `4`; median h `160.0`. Higher-moment improving swaps `6068`; best h `4`; median h `160.0`.
- `score176`: low-moment improving swaps `2619`; best h among them `36`; median h `156.0`. Higher-moment improving swaps `8000`; best h `8`; median h `160.0`.

## Required Answers

1. `Q_tot` formula versus direct `sum_q`: see Identity Checks; mismatches are explicit if any.
2. `sum_g = -2(p-1)S`: see Identity Checks.
3. `score164` Q_ratio: `41.555135174845724`.
3. `score176` Q_ratio: `38.72788882803943`.
4. `score164` and `score176` have positive `min_h` and zero improving 1-swaps if the table above reports that, meaning they are true 1-swap local minima.
5. The block-level section identifies which block contributes most to movement cost.
6. 428 perturbations differ if they have `D_min_1=0` or negative `min_h`; that means a one-swap return direction exists, unlike a false basin with positive `min_h`.
7. Moment-improving swaps are reported separately; if their median h is positive, moment improvement is not aligned with score descent.
8. If 668 minima have no downhill one-swap but 428 perturbations do, the next mechanism should be coherent multi-swap / pair-level repair rather than more score-only 1-swap repair.

## Safety

- No score-nonzero candidate is a solution.
- `T2/T4/T6=0` remains a necessary diagnostic, not a success condition.
- This is not a nonexistence proof; filtered 2/3-swap results remain separate from this full 1-swap certificate.
