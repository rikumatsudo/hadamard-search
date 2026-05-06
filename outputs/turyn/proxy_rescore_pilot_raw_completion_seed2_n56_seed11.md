# Z/W Completion Proxy Diagnostics

This is a heuristic diagnostic for X/Y-completability of a fixed Turyn Z/W pair.
It is not a proof and not a Hadamard construction.

## Input

- path: `outputs/turyn/proxy_pilot_completion_proxy_seed2_step124_pairmax194.494.json`
- n: `56`
- order: `668`
- tuple: `[0, -18, -2, 1]`

## Target Profile

- metrics: `{'score': 2620, 'l1_error': 306, 'max_abs_error': 22, 'nonzero_count': 55}`
- roughness: `4992`
- histogram: `{'-10': 2, '-6': 9, '-2': 13, '2': 11, '6': 9, '10': 8, '14': 2, '22': 1}`

## Fourier and Hall

- min_required: `-56.75994788969615`
- max_required: `324.0`
- std_required: `72.38784428341542`
- negative_sample_count: `36`
- small_required_count_10: `16`
- near_zero_energy_penalty: `57.47561325302275`
- reciprocal_margin_penalty: `36000.00247757922`
- pair_max: `195.37997394484808`
- pair_excess: `468.4612700540995`
- pair_violation_count: `36`

## P/Q Relaxation Proxy

- support options evaluated: `6`
- best support option: `{'P_support': 27, 'P_positive': 9, 'P_negative': 18, 'Q_support': 29, 'Q_positive': 19, 'Q_negative': 10}`
- best residual metrics: `{'score': 3168, 'l1_error': 288, 'max_abs_error': 20, 'nonzero_count': 34, 'residual_histogram': {'-12': 5, '-8': 7, '-4': 7, '0': 21, '4': 5, '8': 5, '12': 2, '20': 3}}`

## Completion Proxy Score

- hall_component: `40684.612700540994`
- negative_fourier_component: `360000.0`
- fourier_margin_component: `362873.8054384433`
- target_profile_component: `727.92`
- pq_relax_component: `2632.0`
- pq_component_source: `relaxed_pq`
- pq_component_metrics: `{'score': 3168, 'l1_error': 288, 'max_abs_error': 20, 'nonzero_count': 34, 'residual_histogram': {'-12': 5, '-8': 7, '-4': 7, '0': 21, '4': 5, '8': 5, '12': 2, '20': 3}}`
- total: `766918.3381389844`
- formula: `10*pair_excess + 1000*pair_violations + 10000*negative_samples + 50*near_zero_energy_penalty + 10*reciprocal_margin_penalty + 0.10*target_score + l1 + 5*max_abs + 0.01*roughness + 0.25*pq_score + 5*pq_l1 + 20*pq_max_abs`

## Interpretation

- The sampled Fourier required profile has negative samples; this Z/W is unsuitable on this diagnostic grid.
- The P/Q relaxation residual is a cheap basin proxy only; low residual suggests X/Y-completability but does not prove it.
- The relaxation did not reach zero residual in the allotted budget.
- Exact success still requires Turyn type, T-sequence, and integer HH^T verification.
