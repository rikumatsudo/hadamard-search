# Z/W Completion Proxy Diagnostics

This is a heuristic diagnostic for X/Y-completability of a fixed Turyn Z/W pair.
It is not a proof and not a Hadamard construction.

## Input

- path: `outputs/turyn/hall_pair_targeted_n36_tuple_m14_m4_0_m1_seed3_step2173_pairmax102.025.json`
- n: `36`
- order: `428`
- tuple: `[-14, -4, 0, -1]`

## Target Profile

- metrics: `{'score': 908, 'l1_error': 150, 'max_abs_error': 10, 'nonzero_count': 35}`
- roughness: `1360`
- histogram: `{'-10': 1, '-6': 2, '-2': 9, '2': 10, '6': 10, '10': 3}`

## Fourier and Hall

- min_required: `6.089439815559359`
- max_required: `212.0`
- std_required: `42.61455150532502`
- negative_sample_count: `0`
- small_required_count_10: `10`
- near_zero_energy_penalty: `0.06904185870369836`
- reciprocal_margin_penalty: `0.0013226433463819933`
- pair_max: `103.95528009222032`
- pair_excess: `0.0`
- pair_violation_count: `0`

## P/Q Relaxation Proxy

- support options evaluated: `8`
- best support option: `{'P_support': 15, 'P_positive': 3, 'P_negative': 12, 'Q_support': 21, 'Q_positive': 8, 'Q_negative': 13}`
- best residual metrics: `{'score': 672, 'l1_error': 96, 'max_abs_error': 12, 'nonzero_count': 17, 'residual_histogram': {'-8': 3, '-4': 6, '0': 18, '4': 6, '12': 2}}`

## Completion Proxy Score

- hall_component: `0.0`
- negative_fourier_component: `0.0`
- fourier_margin_component: `3.465319368648738`
- target_profile_component: `304.40000000000003`
- pq_relax_component: `888.0`
- total: `1195.8653193686487`
- formula: `10*pair_excess + 1000*pair_violations + 10000*negative_samples + 50*near_zero_energy_penalty + 10*reciprocal_margin_penalty + 0.10*target_score + l1 + 5*max_abs + 0.01*roughness + 0.25*pq_score + 5*pq_l1 + 20*pq_max_abs`

## Interpretation

- The sampled Fourier required profile has positive margin on this grid.
- The P/Q relaxation residual is a cheap basin proxy only; low residual suggests X/Y-completability but does not prove it.
- The relaxation did not reach zero residual in the allotted budget.
- Exact success still requires Turyn type, T-sequence, and integer HH^T verification.
