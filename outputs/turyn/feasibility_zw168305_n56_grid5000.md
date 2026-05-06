# Turyn Completion Feasibility Diagnostics

This is a reverse/necessary-condition diagnostic. It is not a proof of existence and not a Hadamard 668 construction.

## Input

- Z/W input: `outputs/turyn/hall_pair_targeted_n56_tuple_0_m18_m2_1_10x_seed6_seed6_step1049_pairmax168.305.json`
- n: `56`
- tuple: `[0, -18, -2, 1]`

## Target Profile

- score: `2844`
- l1: `322`
- max_abs: `18`
- roughness: `5088`
- histogram: `{'-14': 2, '-10': 3, '-6': 3, '-2': 16, '2': 9, '6': 9, '10': 11, '14': 1, '18': 1}`

## Fourier Required Profile

- grid: `5000`
- min_required: `-9.040949150703` at index `1361`
- max_required: `324.000000000000` at index `0`
- mean_required: `112.000000000000`
- std_required: `75.418830539859`
- negative_sample_count: `128`
- small_required_count_10: `122`

## Basic Necessary Checks

- absolute target bounds: `True`
- target parity even: `True`
- P/Q target multiple of 4: `True`
- Fourier sampled nonnegative: `False`

## P/Q Support Possibilities

- possible support splits: `20`
- P_support range: `9`..`47`

## Interpretation

- The fixed Z/W has sampled Fourier required-profile negatives; it is not suitable on this diagnostic grid.
- The required X/Y Fourier energy has near-zero samples, so X/Y completion may be phase-sensitive at those modes.
- P/Q support is not fixed by the tuple alone; the support split is an additional hidden basin parameter.
- These are necessary-condition and hardness diagnostics only. Exact success still requires Turyn/T-sequence/HH^T verification.
