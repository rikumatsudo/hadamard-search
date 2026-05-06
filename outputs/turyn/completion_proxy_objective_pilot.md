# Completion Proxy Objective Pilot

This is a heuristic Z/W-generation experiment for the Turyn route to order 668.
It is not a Turyn type sequence and not a Hadamard construction.

## Purpose

The goal was to test whether an in-loop `X/Y`-completability proxy can generate
better fixed `Z/W` basins than the existing `pair_max` Hall objective.

Objectives tested:

```text
pair_max
completion_proxy
completion_proxy_then_pair_max
hall_then_completion_proxy
pair_max_then_completion_proxy
```

The full P/Q relaxation is too expensive to run inside every Z/W move, so the
in-loop proxy uses:

```text
Hall/Fourier margin + Z/W target-profile terms
```

Saved candidates are then rescored by:

```text
sage/42_zw_completion_proxy_diagnostics.sage
```

## Short Random-Start Pilot

Configuration:

```text
n=56
tuple=[0,-18,-2,1]
steps=1000
grid=200
candidate_trials=16
move_mode=mixed
targeted_prob=0.7
```

Representative outputs:

| objective | seed | pair_max | pair_excess | violations | in-loop proxy | min_required | target score | verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| pair_max | 1 | 179.752 | 71.066 | 12 | n/a | n/a | n/a | better Hall than raw proxy |
| pair_max | 2 | 186.599 | 181.390 | 21 | n/a | n/a | n/a | weak |
| completion_proxy | 1 | 308.534 | 810.388 | 11 | 769168.893 | -283.067 | 4764 | bad: Hall/Fourier broken |
| completion_proxy | 2 | 194.494 | 92.117 | 7 | 431513.746 | -54.989 | 2620 | bad: Fourier negative |
| hall_then_completion_proxy | 1 | 175.654 | 18.348 | 3 | n/a in saved old file | n/a | n/a | healthier but still Hall-failing |
| hall_then_completion_proxy | 2 | 198.661 | 95.120 | 5 | n/a in saved old file | n/a | n/a | weak |

The raw `completion_proxy` objective is too permissive. It can reduce the
target-profile component while producing sampled negative required-Fourier
energy. This is not useful for X/Y completion.

## Rescoring by `42`

Representative `42` rescoring:

| input | pair_max | Fourier min_required | negative samples | target score | target l1 | relaxed P/Q l1 | proxy total |
|---|---:|---:|---:|---:|---:|---:|---:|
| pair_max seed1 pilot | 179.782 | -25.565 | 62 | 3132 | 338 | 280 | 1310463.562 |
| hall_then seed1 pilot | 175.506 | -17.012 | 16 | 2940 | 314 | 288 | 340672.522 |
| raw completion seed2 pilot | 195.380 | -56.760 | 36 | 2620 | 306 | 288 | 766918.338 |
| repaired Z/W baseline with supplied X/Y score 288 | 166.842 | 0.316 | 0 | 2044 | 258 | 184 | 2078.244 |

The short random-start pilot did not produce a better basin than the current
repaired Z/W baseline.

## Refinement From Current Best Z/W

Input:

```text
outputs/turyn/multi_flip_pairmax_seed6_grid500_beam150_pairmax166.842.json
```

Configuration:

```text
steps=1000
grid=500
candidate_trials=16
continue_after_hall_pass=true
```

Outputs:

| objective | best step | pair_max | pair_excess | violations | in-loop proxy | min_required | target score | target l1 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| hall_then_completion_proxy | 0 | 166.842 | 0.000 | 0 | 630.244 | 0.316 | 2044 | 258 |
| pair_max_then_completion_proxy | 0 | 166.842 | 0.000 | 0 | 630.244 | 0.316 | 2044 | 258 |

No single accepted move in this short run improved the current Hall-pass Z/W
state under these objectives.

## Interpretation

1. Raw `completion_proxy` is not safe as a direct in-loop objective.
2. A Hall-gated objective is required. Otherwise the search finds target-profile
   improvements that are Fourier-infeasible.
3. The existing repaired Z/W remains much better than short random-start proxy
   candidates after dense rescoring.
4. The current repaired Z/W appears locally hard: short proxy refinement from
   that state did not improve it.
5. The next version should treat Hall feasibility as a hard basin gate and
   allow nonmonotone multi-move changes within the Hall-feasible region, rather
   than single balanced flips.

## Next Suggested Experiment

Use a two-stage objective:

```text
Stage A: force sampled Hall/Fourier feasibility on a dense grid.
Stage B: within feasible or near-feasible states, optimize completion proxy.
```

Concretely:

```text
1. Continue using pair_max / multi-flip to reach pair_hall_pass.
2. Once pair_hall_pass is true, freeze a Hall slack budget.
3. Run multi-flip moves that may temporarily worsen pair_max up to bound+epsilon,
   but improve target profile and P/Q proxy.
4. Re-score with 42 before attempting X/Y completion.
```

This suggests extending `36_multi_flip_hall_pair_repair.sage` rather than
continuing with the single-flip annealer `33`.
