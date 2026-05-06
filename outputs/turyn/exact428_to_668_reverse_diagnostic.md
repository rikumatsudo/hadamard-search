# Exact 428 Reverse Diagnostic vs 668 Near-Hit

This note compares the published Kharaghani--Tayfeh-Rezaie order-428 Turyn
type sequence with the current order-668 Turyn-route near-hit diagnostics.

This is not a Hadamard 668 construction. The order-428 entry is an exact
positive control; the order-668 entry remains a near-hit only.

## Exact 428 Positive Control

Input:

```text
outputs/turyn/exact_428_kharaghani_tayfeh_rezaie.json
```

Verification:

```text
outputs/turyn/verify_exact_428_kharaghani_tayfeh_rezaie.json
```

Result:

```text
Turyn type OK: true
T-sequences OK: true
generated order: 428
HH^T check: true
tuple: [0, 6, 8, 5]
```

Reverse diagnostic:

```text
outputs/turyn/feasibility_exact428_ktr_n36_grid5000.json
outputs/turyn/feasibility_exact428_ktr_n36_grid5000.md
```

## Comparison Table

| case | n | order | tuple | target score | target l1 | target max_abs | target roughness | Fourier min_required | Fourier std | small_required_count_10 | X/Y score |
|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| exact 428 KTR | 36 | 428 | [0,6,8,5] | 1004 | 146 | 14 | 1440 | 4.474229069 | 44.810713005 | 146 | 0 |
| local 428 analogue | 36 | 428 | [-14,-4,0,-1] | 908 | 150 | 10 | 1360 | 6.087676087 | 42.614551505 | 44 | n/a |
| 668 repaired Z/W + X/Y near-hit | 56 | 668 | [0,-18,-2,1] | 2044 | 258 | 18 | 4144 | 0.235278951 | 63.937469453 | 92 | 288 |
| 668 pre-repair Z/W | 56 | 668 | [0,-18,-2,1] | 2844 | 322 | 18 | 5088 | -9.040949151 | 75.418830540 | 122 | n/a |

## Interpretation

1. The exact 428 sequence verifies the full local pipeline: Turyn type
   condition, T-sequence conversion, and exact integer `HH^T = 428I`.
2. The exact 428 `Z/W` target profile is not especially tiny. It has target
   score `1004` and max_abs `14`, so a small scalar target profile is not the
   reason the construction works.
3. The decisive difference is that the exact 428 `X/Y` phase/support pattern
   realizes the target exactly: supplied X/Y score `0`.
4. The current 668 repaired `Z/W` is sampled-Fourier feasible but has a much
   smaller minimum required Fourier energy, about `0.235`, so some modes demand
   near-cancellation from `X/Y`.
5. `small_required_count_10` is not a monotone hardness metric: exact 428 has
   more samples below 10 than the current 668 near-hit. The minimum margin and
   discrete P/Q support compatibility appear more informative.
6. The boundary is therefore not simply Hall pass/fail, nor target score alone.
   The hard part is matching a discrete X/Y support/sign channel to a fixed
   Z/W autocorrelation and Fourier profile.

## Consequence for 668

For 668, a better reverse objective should not only reduce Hall pair maximum or
target roughness. It should bias `Z/W` toward target profiles that admit
compatible `P=X+Y`, `Q=X-Y` support splits and avoid tiny required Fourier
energy at isolated modes.

The exact 428 positive control supports a pivot from scalar local repair to
inverse design of X/Y-completable Z/W profiles.

## Completion Proxy Prototype

The first implementation of this idea is:

```text
sage/42_zw_completion_proxy_diagnostics.sage
```

It scores a fixed `Z/W` pair using:

```text
Hall-pair excess
+ sampled required-Fourier margin penalty
+ Z/W target-profile penalty
+ lightweight P/Q support/sign relaxation residual
```

Diagnostic outputs from the first calibration run:

```text
outputs/turyn/proxy_exact428_ktr_bestavailable_n36_seed2.json
outputs/turyn/proxy_668_xy288_bestavailable_n56_seed2.json
outputs/turyn/proxy_668_pre_repair_bestavailable_n56_seed2.json
outputs/turyn/proxy_local428_analogue_n36_seed1.json
```

Summary:

| case | proxy total | P/Q source | P/Q l1 | Fourier min | negative samples |
|---|---:|---|---:|---:|---:|
| exact 428 KTR | 346.501 | supplied X/Y | 0 | 4.516666 | 0 |
| local 428 analogue | 1195.865 | relaxation only | n/a | 6.089440 | 0 |
| 668 repaired Z/W + X/Y score 288 | 2078.244 | supplied X/Y | 184 | 0.316217 | 0 |
| 668 pre-repair Z/W | 507847.280 | relaxation only | 240 | -8.929763 | 24 |

The absolute proxy value is heuristic, but this calibration has the desired
ordering for the positive control and the current 668 states: exact 428 is easy
under the best-available P/Q residual, repaired 668 is substantially harder,
and pre-repair 668 is penalized heavily for sampled negative required-Fourier
energy.

The Hall-pair annealer now also has an in-loop cheap version:

```text
--objective completion_proxy
--objective completion_proxy_then_pair_max
```

This in-loop version excludes the expensive P/Q relaxation and should be used
only to generate candidate Z/W basins. Saved candidates should then be rescored
with `42` before X/Y completion is attempted.
