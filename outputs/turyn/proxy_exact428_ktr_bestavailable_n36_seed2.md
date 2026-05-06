# Z/W Completion Proxy Diagnostics

This is a heuristic diagnostic for X/Y-completability of a fixed Turyn Z/W pair.
It is not a proof and not a Hadamard construction.

## Input

- path: `outputs/turyn/exact_428_kharaghani_tayfeh_rezaie.json`
- n: `36`
- order: `428`
- tuple: `[0, 6, 8, 5]`

## Target Profile

- metrics: `{'score': 1004, 'l1_error': 146, 'max_abs_error': 14, 'nonzero_count': 35}`
- roughness: `1440`
- histogram: `{'-14': 2, '-10': 1, '-6': 3, '-2': 13, '2': 9, '6': 6, '10': 1}`

## Fourier and Hall

- min_required: `4.51666556306634`
- max_required: `178.71406887046393`
- std_required: `44.81071300481616`
- negative_sample_count: `0`
- small_required_count_10: `28`
- near_zero_energy_penalty: `0.313180734644334`
- reciprocal_margin_penalty: `0.004197595414778201`
- pair_max: `104.74166721846683`
- pair_excess: `0.0`
- pair_violation_count: `0`

## Supplied X/Y

- P/Q support: `{'P_support': 19, 'P_positive': 11, 'P_negative': 8, 'P_sum': 6, 'Q_support': 17, 'Q_positive': 7, 'Q_negative': 10, 'Q_sum': -6}`
- P/Q residual metrics: `{'score': 0, 'l1_error': 0, 'max_abs_error': 0, 'nonzero_count': 0, 'residual_histogram': {'0': 35}}`

## P/Q Relaxation Proxy

- support options evaluated: `8`
- best support option: `{'P_support': 13, 'P_positive': 8, 'P_negative': 5, 'Q_support': 23, 'Q_positive': 10, 'Q_negative': 13}`
- best residual metrics: `{'score': 512, 'l1_error': 88, 'max_abs_error': 8, 'nonzero_count': 17, 'residual_histogram': {'-8': 3, '-4': 5, '0': 18, '4': 7, '8': 2}}`

## Completion Proxy Score

- hall_component: `0.0`
- negative_fourier_component: `0.0`
- fourier_margin_component: `15.701012686364482`
- target_profile_component: `330.79999999999995`
- pq_relax_component: `0.0`
- pq_component_source: `supplied_xy`
- pq_component_metrics: `{'score': 0, 'l1_error': 0, 'max_abs_error': 0, 'nonzero_count': 0, 'residual_histogram': {'0': 35}}`
- total: `346.50101268636445`
- formula: `10*pair_excess + 1000*pair_violations + 10000*negative_samples + 50*near_zero_energy_penalty + 10*reciprocal_margin_penalty + 0.10*target_score + l1 + 5*max_abs + 0.01*roughness + 0.25*pq_score + 5*pq_l1 + 20*pq_max_abs`

## Interpretation

- The supplied X/Y realizes the Z/W target exactly; this is a positive-control completion.
- The sampled Fourier required profile has positive margin on this grid.
- The P/Q relaxation residual is a cheap basin proxy only; low residual suggests X/Y-completability but does not prove it.
- The relaxation did not reach zero residual in the allotted budget.
- Exact success still requires Turyn type, T-sequence, and integer HH^T verification.
