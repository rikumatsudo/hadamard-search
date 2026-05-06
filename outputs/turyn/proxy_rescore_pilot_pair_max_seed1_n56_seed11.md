# Z/W Completion Proxy Diagnostics

This is a heuristic diagnostic for X/Y-completability of a fixed Turyn Z/W pair.
It is not a proof and not a Hadamard construction.

## Input

- path: `outputs/turyn/proxy_pilot_pair_max_seed1_step676_pairmax179.752.json`
- n: `56`
- order: `668`
- tuple: `[0, -18, -2, 1]`

## Target Profile

- metrics: `{'score': 3132, 'l1_error': 338, 'max_abs_error': 18, 'nonzero_count': 55}`
- roughness: `5856`
- histogram: `{'-14': 2, '-10': 3, '-6': 7, '-2': 8, '2': 15, '6': 8, '10': 7, '14': 4, '18': 1}`

## Fourier and Hall

- min_required: `-25.564968201268982`
- max_required: `324.0`
- std_required: `79.14543574963753`
- negative_sample_count: `62`
- small_required_count_10: `22`
- near_zero_energy_penalty: `33.3535905476667`
- reciprocal_margin_penalty: `62000.00581548662`
- pair_max: `179.7824841006345`
- pair_excess: `358.0064399064609`
- pair_violation_count: `62`

## P/Q Relaxation Proxy

- support options evaluated: `6`
- best support option: `{'P_support': 25, 'P_positive': 8, 'P_negative': 17, 'Q_support': 31, 'Q_positive': 20, 'Q_negative': 11}`
- best residual metrics: `{'score': 2464, 'l1_error': 280, 'max_abs_error': 20, 'nonzero_count': 40, 'residual_histogram': {'-16': 1, '-12': 2, '-8': 7, '-4': 11, '0': 15, '4': 7, '8': 10, '12': 1, '20': 1}}`

## Completion Proxy Score

- hall_component: `65580.0643990646`
- negative_fourier_component: `620000.0`
- fourier_margin_component: `621667.7376822495`
- target_profile_component: `799.76`
- pq_relax_component: `2416.0`
- pq_component_source: `relaxed_pq`
- pq_component_metrics: `{'score': 2464, 'l1_error': 280, 'max_abs_error': 20, 'nonzero_count': 40, 'residual_histogram': {'-16': 1, '-12': 2, '-8': 7, '-4': 11, '0': 15, '4': 7, '8': 10, '12': 1, '20': 1}}`
- total: `1310463.5620813142`
- formula: `10*pair_excess + 1000*pair_violations + 10000*negative_samples + 50*near_zero_energy_penalty + 10*reciprocal_margin_penalty + 0.10*target_score + l1 + 5*max_abs + 0.01*roughness + 0.25*pq_score + 5*pq_l1 + 20*pq_max_abs`

## Interpretation

- The sampled Fourier required profile has negative samples; this Z/W is unsuitable on this diagnostic grid.
- The P/Q relaxation residual is a cheap basin proxy only; low residual suggests X/Y-completability but does not prove it.
- The relaxation did not reach zero residual in the allotted budget.
- Exact success still requires Turyn type, T-sequence, and integer HH^T verification.
