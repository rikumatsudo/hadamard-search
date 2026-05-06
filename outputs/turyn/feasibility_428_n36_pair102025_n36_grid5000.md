# Turyn Completion Feasibility Diagnostics

This is a reverse/necessary-condition diagnostic. It is not a proof of existence and not a Hadamard 668 construction.

## Input

- Z/W input: `outputs/turyn/hall_pair_targeted_n36_tuple_m14_m4_0_m1_seed3_step2173_pairmax102.025.json`
- n: `36`
- tuple: `[-14, -4, 0, -1]`

## Target Profile

- score: `908`
- l1: `150`
- max_abs: `10`
- roughness: `1360`
- histogram: `{'-10': 1, '-6': 2, '-2': 9, '2': 10, '6': 10, '10': 3}`

## Fourier Required Profile

- grid: `5000`
- min_required: `6.087676086790` at index `4864`
- max_required: `212.000000000000` at index `0`
- mean_required: `72.000000000000`
- std_required: `42.614551505325`
- negative_sample_count: `0`
- small_required_count_10: `44`

## Basic Necessary Checks

- absolute target bounds: `True`
- target parity even: `True`
- P/Q target multiple of 4: `True`
- Fourier sampled nonnegative: `True`

## P/Q Support Possibilities

- possible support splits: `12`
- P_support range: `9`..`31`

## Interpretation

- The fixed Z/W passes the sampled Fourier nonnegativity diagnostic on this grid.
- The required X/Y Fourier energy has near-zero samples, so X/Y completion may be phase-sensitive at those modes.
- P/Q support is not fixed by the tuple alone; the support split is an additional hidden basin parameter.
- These are necessary-condition and hardness diagnostics only. Exact success still requires Turyn/T-sequence/HH^T verification.
