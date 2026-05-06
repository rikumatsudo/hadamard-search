# Turyn Completion Feasibility Diagnostics

This is a reverse/necessary-condition diagnostic. It is not a proof of existence and not a Hadamard 668 construction.

## Input

- Z/W input: `outputs/turyn/exact_428_kharaghani_tayfeh_rezaie.json`
- n: `36`
- tuple: `[0, 6, 8, 5]`

## Target Profile

- score: `1004`
- l1: `146`
- max_abs: `14`
- roughness: `1440`
- histogram: `{'-14': 2, '-10': 1, '-6': 3, '-2': 13, '2': 9, '6': 6, '10': 1}`

## Fourier Required Profile

- grid: `5000`
- min_required: `4.474229068600` at index `92`
- max_required: `178.808289890424` at index `547`
- mean_required: `72.000000000000`
- std_required: `44.810713004816`
- negative_sample_count: `0`
- small_required_count_10: `146`

## Basic Necessary Checks

- absolute target bounds: `True`
- target parity even: `True`
- P/Q target multiple of 4: `True`
- Fourier sampled nonnegative: `True`

## P/Q Support Possibilities

- possible support splits: `16`
- P_support range: `3`..`33`

## Supplied X/Y Near-Hit

- score: `0`
- l1: `0`
- max_abs: `0`
- nonzero: `0`
- P/Q support: `{'P_support': 19, 'P_positive': 11, 'P_negative': 8, 'P_sum': 6, 'Q_support': 17, 'Q_positive': 7, 'Q_negative': 10, 'Q_sum': -6}`

Worst supplied near-hit shifts:

| shift | defect | same-channel | silent-cross | same + | same - |
|---:|---:|---:|---:|---:|---:|

## Interpretation

- The fixed Z/W passes the sampled Fourier nonnegativity diagnostic on this grid.
- The required X/Y Fourier energy has near-zero samples, so X/Y completion may be phase-sensitive at those modes.
- P/Q support is not fixed by the tuple alone; the support split is an additional hidden basin parameter.
- These are necessary-condition and hardness diagnostics only. Exact success still requires Turyn/T-sequence/HH^T verification.
