# Turyn Completion Feasibility Diagnostics

This is a reverse/necessary-condition diagnostic. It is not a proof of existence and not a Hadamard 668 construction.

## Input

- Z/W input: `outputs/turyn/multi_flip_pairmax_seed6_grid500_beam150_pairmax166.842.json`
- X/Y input: `outputs/turyn/xy_multi_flip_score296_worst7_beam220_score288.json`
- n: `56`
- tuple: `[0, -18, -2, 1]`

## Target Profile

- score: `2044`
- l1: `258`
- max_abs: `18`
- roughness: `4144`
- histogram: `{'-14': 1, '-10': 1, '-6': 5, '-2': 11, '2': 21, '6': 9, '10': 4, '14': 2, '18': 1}`

## Fourier Required Profile

- grid: `5000`
- min_required: `0.235278951436` at index `1839`
- max_required: `324.000000000000` at index `0`
- mean_required: `112.000000000000`
- std_required: `63.937469452583`
- negative_sample_count: `0`
- small_required_count_10: `92`

## Basic Necessary Checks

- absolute target bounds: `True`
- target parity even: `True`
- P/Q target multiple of 4: `True`
- Fourier sampled nonnegative: `True`

## P/Q Support Possibilities

- possible support splits: `20`
- P_support range: `9`..`47`

## Supplied X/Y Near-Hit

- score: `288`
- l1: `92`
- max_abs: `6`
- nonzero: `35`
- P/Q support: `{'P_support': 23, 'P_positive': 7, 'P_negative': 16, 'P_sum': -18, 'Q_support': 33, 'Q_positive': 21, 'Q_negative': 12, 'Q_sum': 18}`

Worst supplied near-hit shifts:

| shift | defect | same-channel | silent-cross | same + | same - |
|---:|---:|---:|---:|---:|---:|
| 35 | 6 | 6 | 15 | 4 | 2 |
| 44 | 6 | 8 | 4 | 3 | 5 |
| 6 | -4 | 29 | 21 | 15 | 14 |
| 11 | 4 | 19 | 26 | 11 | 8 |
| 20 | 4 | 23 | 13 | 13 | 10 |
| 26 | -4 | 21 | 9 | 10 | 11 |
| 46 | 4 | 7 | 3 | 5 | 2 |
| 49 | 4 | 3 | 4 | 3 | 0 |
| 51 | -4 | 3 | 2 | 2 | 1 |
| 3 | -2 | 32 | 21 | 17 | 15 |
| 4 | 2 | 32 | 20 | 17 | 15 |
| 8 | -2 | 18 | 30 | 9 | 9 |

## Interpretation

- The fixed Z/W passes the sampled Fourier nonnegativity diagnostic on this grid.
- The required X/Y Fourier energy has near-zero samples, so X/Y completion may be phase-sensitive at those modes.
- P/Q support is not fixed by the tuple alone; the support split is an additional hidden basin parameter.
- These are necessary-condition and hardness diagnostics only. Exact success still requires Turyn/T-sequence/HH^T verification.
