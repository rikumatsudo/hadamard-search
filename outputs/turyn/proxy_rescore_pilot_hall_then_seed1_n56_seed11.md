# Z/W Completion Proxy Diagnostics

This is a heuristic diagnostic for X/Y-completability of a fixed Turyn Z/W pair.
It is not a proof and not a Hadamard construction.

## Input

- path: `outputs/turyn/proxy_pilot_hall_then_completion_proxy_seed1_step808_pairmax175.654.json`
- n: `56`
- order: `668`
- tuple: `[0, -18, -2, 1]`

## Target Profile

- metrics: `{'score': 2940, 'l1_error': 314, 'max_abs_error': 22, 'nonzero_count': 55}`
- roughness: `6576`
- histogram: `{'-14': 1, '-10': 1, '-6': 9, '-2': 13, '2': 11, '6': 12, '10': 2, '14': 4, '18': 1, '22': 1}`

## Fourier and Hall

- min_required: `-17.012455174989384`
- max_required: `324.45598796067475`
- std_required: `76.68115805072325`
- negative_sample_count: `16`
- small_required_count_10: `42`
- near_zero_energy_penalty: `8.897698853735507`
- reciprocal_margin_penalty: `16000.017722714927`
- pair_max: `175.5062275874947`
- pair_excess: `88.36994460048615`
- pair_violation_count: `16`

## P/Q Relaxation Proxy

- support options evaluated: `6`
- best support option: `{'P_support': 31, 'P_positive': 11, 'P_negative': 20, 'Q_support': 25, 'Q_positive': 17, 'Q_negative': 8}`
- best residual metrics: `{'score': 2880, 'l1_error': 288, 'max_abs_error': 20, 'nonzero_count': 39, 'residual_histogram': {'-16': 3, '-12': 1, '-8': 6, '-4': 9, '0': 16, '4': 11, '8': 5, '12': 2, '16': 1, '20': 1}}`

## Completion Proxy Score

- hall_component: `16883.699446004863`
- negative_fourier_component: `160000.0`
- fourier_margin_component: `160445.06216983605`
- target_profile_component: `783.76`
- pq_relax_component: `2560.0`
- pq_component_source: `relaxed_pq`
- pq_component_metrics: `{'score': 2880, 'l1_error': 288, 'max_abs_error': 20, 'nonzero_count': 39, 'residual_histogram': {'-16': 3, '-12': 1, '-8': 6, '-4': 9, '0': 16, '4': 11, '8': 5, '12': 2, '16': 1, '20': 1}}`
- total: `340672.52161584096`
- formula: `10*pair_excess + 1000*pair_violations + 10000*negative_samples + 50*near_zero_energy_penalty + 10*reciprocal_margin_penalty + 0.10*target_score + l1 + 5*max_abs + 0.01*roughness + 0.25*pq_score + 5*pq_l1 + 20*pq_max_abs`

## Interpretation

- The sampled Fourier required profile has negative samples; this Z/W is unsuitable on this diagnostic grid.
- The P/Q relaxation residual is a cheap basin proxy only; low residual suggests X/Y-completability but does not prove it.
- The relaxation did not reach zero residual in the allotted budget.
- Exact success still requires Turyn type, T-sequence, and integer HH^T verification.
