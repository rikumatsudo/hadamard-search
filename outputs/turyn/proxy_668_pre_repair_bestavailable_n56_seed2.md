# Z/W Completion Proxy Diagnostics

This is a heuristic diagnostic for X/Y-completability of a fixed Turyn Z/W pair.
It is not a proof and not a Hadamard construction.

## Input

- path: `outputs/turyn/hall_pair_targeted_n56_tuple_0_m18_m2_1_10x_seed6_seed6_step1049_pairmax168.305.json`
- n: `56`
- order: `668`
- tuple: `[0, -18, -2, 1]`

## Target Profile

- metrics: `{'score': 2844, 'l1_error': 322, 'max_abs_error': 18, 'nonzero_count': 55}`
- roughness: `5088`
- histogram: `{'-14': 2, '-10': 3, '-6': 3, '-2': 16, '2': 9, '6': 9, '10': 11, '14': 1, '18': 1}`

## Fourier and Hall

- min_required: `-8.929762557881418`
- max_required: `324.0`
- std_required: `75.41883053985923`
- negative_sample_count: `24`
- small_required_count_10: `28`
- near_zero_energy_penalty: `5.954085332649805`
- reciprocal_margin_penalty: `24000.023346401143`
- pair_max: `171.4648812789407`
- pair_excess: `50.606201014065874`
- pair_violation_count: `24`

## P/Q Relaxation Proxy

- support options evaluated: `8`
- best support option: `{'P_support': 21, 'P_positive': 6, 'P_negative': 15, 'Q_support': 35, 'Q_positive': 22, 'Q_negative': 13}`
- best residual metrics: `{'score': 2464, 'l1_error': 240, 'max_abs_error': 24, 'nonzero_count': 31, 'residual_histogram': {'-16': 1, '-12': 1, '-8': 9, '-4': 5, '0': 24, '4': 8, '8': 2, '12': 4, '24': 1}}`

## Completion Proxy Score

- hall_component: `24506.06201014066`
- negative_fourier_component: `240000.0`
- fourier_margin_component: `240297.93773064393`
- target_profile_component: `747.2800000000001`
- pq_relax_component: `2296.0`
- pq_component_source: `relaxed_pq`
- pq_component_metrics: `{'score': 2464, 'l1_error': 240, 'max_abs_error': 24, 'nonzero_count': 31, 'residual_histogram': {'-16': 1, '-12': 1, '-8': 9, '-4': 5, '0': 24, '4': 8, '8': 2, '12': 4, '24': 1}}`
- total: `507847.27974078467`
- formula: `10*pair_excess + 1000*pair_violations + 10000*negative_samples + 50*near_zero_energy_penalty + 10*reciprocal_margin_penalty + 0.10*target_score + l1 + 5*max_abs + 0.01*roughness + 0.25*pq_score + 5*pq_l1 + 20*pq_max_abs`

## Interpretation

- The sampled Fourier required profile has negative samples; this Z/W is unsuitable on this diagnostic grid.
- The P/Q relaxation residual is a cheap basin proxy only; low residual suggests X/Y-completability but does not prove it.
- The relaxation did not reach zero residual in the allotted budget.
- Exact success still requires Turyn type, T-sequence, and integer HH^T verification.
