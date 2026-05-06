# P/Q X/Y Completion Diagnostics

This is a diagnostic artifact. It is not a Turyn type sequence proof and not a Hadamard 668 construction.

## Input

- input: `outputs/turyn/xy_multi_flip_score296_worst7_beam220_score288.json`
- n: `56`
- tuple: `[0, -18, -2, 1]`

## X/Y Defect Metrics

- score: `288`
- l1_error: `92`
- max_abs_error: `6`
- nonzero_defect_count: `35`
- pq_identity_ok: `True`
- pq_defect_double_xy_ok: `True`

## P/Q Support

- P: support `23`, positive `7`, negative `16`, sum `-18`
- Q: support `33`, positive `21`, negative `12`, sum `18`

## Worst Shifts

| shift | xy_defect | pq_defect | same pairs | silent cross | P + | P - | Q + | Q - |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 35 | 6 | 12 | 6 | 15 | 1 | 2 | 3 | 0 |
| 44 | 6 | 12 | 8 | 4 | 0 | 2 | 3 | 3 |
| 6 | -4 | -8 | 29 | 21 | 8 | 3 | 7 | 11 |
| 11 | 4 | 8 | 19 | 26 | 4 | 2 | 7 | 6 |
| 20 | 4 | 8 | 23 | 13 | 4 | 3 | 9 | 7 |
| 26 | -4 | -8 | 21 | 9 | 3 | 4 | 7 | 7 |
| 46 | 4 | 8 | 7 | 3 | 1 | 1 | 4 | 1 |
| 49 | 4 | 8 | 3 | 4 | 0 | 0 | 3 | 0 |
| 51 | -4 | -8 | 3 | 2 | 0 | 0 | 2 | 1 |
| 3 | -2 | -4 | 32 | 21 | 6 | 6 | 11 | 9 |
| 4 | 2 | 4 | 32 | 20 | 4 | 8 | 13 | 7 |
| 8 | -2 | -4 | 18 | 30 | 2 | 4 | 7 | 5 |
| 9 | -2 | -4 | 20 | 27 | 5 | 2 | 6 | 7 |
| 12 | -2 | -4 | 18 | 26 | 6 | 0 | 6 | 6 |
| 13 | -2 | -4 | 18 | 25 | 2 | 4 | 7 | 5 |
| 14 | -2 | -4 | 18 | 24 | 1 | 5 | 4 | 8 |
| 17 | -2 | -4 | 18 | 21 | 2 | 3 | 6 | 7 |
| 18 | 2 | 4 | 20 | 18 | 4 | 2 | 9 | 5 |
| 19 | -2 | -4 | 16 | 21 | 4 | 0 | 6 | 6 |
| 21 | 2 | 4 | 20 | 15 | 3 | 2 | 7 | 8 |

## High-Pressure Positions

| pos | channel | sign | touch | active same-channel | silent cross-channel | shifts |
|---:|:---:|---:|---:|---:|---:|:---|
| 51 | Q | 1 | 50 | 38 | 12 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46, 49, 51] |
| 4 | Q | 1 | 50 | 32 | 18 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46, 49, 51] |
| 49 | Q | 1 | 50 | 32 | 18 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46, 49] |
| 6 | P | -1 | 50 | 28 | 22 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46, 49] |
| 11 | Q | 1 | 48 | 34 | 14 | [3, 4, 6, 8, 11, 20, 26, 35, 44] |
| 47 | Q | -1 | 48 | 26 | 22 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46] |
| 3 | Q | 1 | 48 | 24 | 24 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46, 49, 51] |
| 44 | Q | 1 | 48 | 24 | 24 | [3, 4, 6, 8, 11, 20, 26, 35, 44] |
| 8 | P | 1 | 48 | 22 | 26 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46] |
| 52 | P | -1 | 48 | 22 | 26 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46, 49, 51] |
| 46 | P | -1 | 48 | 20 | 28 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46] |
| 9 | P | -1 | 48 | 16 | 32 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46] |
| 2 | Q | 1 | 46 | 34 | 12 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46, 49, 51] |
| 5 | Q | -1 | 46 | 34 | 12 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46, 49] |
| 7 | Q | 1 | 46 | 34 | 12 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46] |
| 48 | Q | 1 | 46 | 34 | 12 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46] |
| 0 | Q | 1 | 46 | 26 | 20 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46, 49, 51] |
| 53 | Q | 1 | 46 | 26 | 20 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46, 49, 51] |
| 55 | Q | -1 | 46 | 26 | 20 | [3, 4, 6, 8, 11, 20, 26, 35, 44, 46, 49, 51] |
| 35 | P | -1 | 46 | 22 | 24 | [3, 4, 6, 8, 11, 20, 26, 35] |

## Move Semantics

- Flipping one `X` entry maps `(P,Q)` at that position to `(-Q,-P)`.
- Flipping one `Y` entry maps `(P,Q)` at that position to `(Q,P)`.
- A balanced `X` or `Y` move therefore swaps two positions between the P-channel and Q-channel while preserving the requested X/Y sums.
- P/Q autocorrelation receives contributions only from same-channel pairs; cross-channel pairs are silent.

## Safety

This report only rewrites and diagnoses the current X/Y near-hit. A success candidate still requires exact Turyn verification, T-sequence verification, and exact integer `HH^T = 668I`.
