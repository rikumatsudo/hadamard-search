# Z/W Completion Proxy Diagnostics

This is a heuristic diagnostic for X/Y-completability of a fixed Turyn Z/W pair.
It is not a proof and not a Hadamard construction.

## Input

- path: `outputs/turyn/xy_multi_flip_score296_worst7_beam220_score288.json`
- n: `56`
- order: `668`
- tuple: `[0, -18, -2, 1]`

## Target Profile

- metrics: `{'score': 2044, 'l1_error': 258, 'max_abs_error': 18, 'nonzero_count': 55}`
- roughness: `4144`
- histogram: `{'-14': 1, '-10': 1, '-6': 5, '-2': 11, '2': 21, '6': 9, '10': 4, '14': 2, '18': 1}`

## Fourier and Hall

- min_required: `0.31621670663184887`
- max_required: `324.0`
- std_required: `63.93746945258311`
- negative_sample_count: `0`
- small_required_count_10: `18`
- near_zero_energy_penalty: `0.7258013767570485`
- reciprocal_margin_penalty: `0.011425322139379192`
- pair_max: `166.84189164668408`
- pair_excess: `0.0`
- pair_violation_count: `0`

## Supplied X/Y

- P/Q support: `{'P_support': 23, 'P_positive': 7, 'P_negative': 16, 'P_sum': -18, 'Q_support': 33, 'Q_positive': 21, 'Q_negative': 12, 'Q_sum': 18}`
- P/Q residual metrics: `{'score': 1152, 'l1_error': 184, 'max_abs_error': 12, 'nonzero_count': 35, 'residual_histogram': {'-8': 3, '-4': 17, '0': 20, '4': 9, '8': 4, '12': 2}}`

## P/Q Relaxation Proxy

- support options evaluated: `8`
- best support option: `{'P_support': 29, 'P_positive': 10, 'P_negative': 19, 'Q_support': 27, 'Q_positive': 18, 'Q_negative': 9}`
- best residual metrics: `{'score': 2272, 'l1_error': 264, 'max_abs_error': 12, 'nonzero_count': 36, 'residual_histogram': {'-12': 3, '-8': 9, '-4': 6, '0': 19, '4': 8, '8': 5, '12': 5}}`

## Completion Proxy Score

- hall_component: `0.0`
- negative_fourier_component: `0.0`
- fourier_margin_component: `36.40432205924622`
- target_profile_component: `593.8399999999999`
- pq_relax_component: `1448.0`
- pq_component_source: `supplied_xy`
- pq_component_metrics: `{'score': 1152, 'l1_error': 184, 'max_abs_error': 12, 'nonzero_count': 35, 'residual_histogram': {'-8': 3, '-4': 17, '0': 20, '4': 9, '8': 4, '12': 2}}`
- total: `2078.244322059246`
- formula: `10*pair_excess + 1000*pair_violations + 10000*negative_samples + 50*near_zero_energy_penalty + 10*reciprocal_margin_penalty + 0.10*target_score + l1 + 5*max_abs + 0.01*roughness + 0.25*pq_score + 5*pq_l1 + 20*pq_max_abs`

## Interpretation

- The sampled Fourier required profile is nonnegative but has near-zero modes; completion is likely phase-sensitive.
- The P/Q relaxation residual is a cheap basin proxy only; low residual suggests X/Y-completability but does not prove it.
- The relaxation did not reach zero residual in the allotted budget.
- Exact success still requires Turyn type, T-sequence, and integer HH^T verification.
