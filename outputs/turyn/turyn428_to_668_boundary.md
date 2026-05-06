# 428 Method to 668: Boundary Notes

This note separates what transfers directly from the Kharaghani--Tayfeh-Rezaie
order-428 construction and what appears to become a 668-specific computational
barrier.

## What Transfers Directly

The 428 construction is based on Turyn type sequences of lengths

```text
36, 36, 36, 35
```

For Turyn length `m`, the induced T-sequence length is `3m - 1`, and the
Hadamard order is `4(3m - 1)`. Thus:

```text
m = 36  ->  4(3*36 - 1) = 428
m = 56  ->  4(3*56 - 1) = 668
```

So the direct 668 analogue is Turyn type sequences of lengths:

```text
56, 56, 56, 55
```

The same formal pipeline applies:

```text
Turyn type sequences
-> base sequences
-> T-sequences of length 167
-> Goethals-Seidel array
-> exact HH^T = 668I verification
```

The algebraic verifier and converter are implemented in:

```text
sage/30_turyn_type_sequences.sage
```

## What Still Applies as Pruning

For Turyn type sequences `X,Y,Z,W` of lengths `m,m,m,m-1`, the condition is:

```text
N_X(s) + N_Y(s) + 2N_Z(s) + 2N_W(s) = 0, s >= 1.
```

The sum identity transfers:

```text
x^2 + y^2 + 2z^2 + 2w^2 = 6m - 2
```

For the two relevant cases:

```text
m=36: RHS = 214, sum tuples = 216
m=56: RHS = 334, sum tuples = 336
```

This is not where the main explosion occurs. The 668 case has more sum
classes, but only by a moderate factor.

The Hall/Fourier pruning also transfers. The identity

```text
f_X(theta) + f_Y(theta) + 2f_Z(theta) + 2f_W(theta) = 6m - 2
```

implies the single-sequence bound:

```text
f_Z(theta) <= 3m - 1
f_W(theta) <= 3m - 1
f_Z(theta) + f_W(theta) <= 3m - 1
```

For the two cases:

```text
m=36: bound = 107
m=56: bound = 167
```

## Where 668 Starts Looking Harder

The first smoke diagnostics are in:

```text
outputs/turyn/turyn56_vs_36_pruning_smoke.json
outputs/turyn/turyn56_vs_36_pruning_40tuples.json
```

Naive random samples with the sum constraints rarely satisfy the Z/W Hall pair
bound in either case. But the best sampled relative gap was worse for `m=56`.

Example smoke:

```text
m=56: best sampled Z/W max ~= 227.220, bound 167, ratio ~= 1.36
m=36: best sampled Z/W max ~= 131.137, bound 107, ratio ~= 1.23
```

This suggests that the 668 analogue is not blocked at the sum identity stage.
The difficulty begins when trying to generate sufficiently structured Z/W
sequences that satisfy Hall bounds and endpoint compatibility.

## Likely Boundary Between 428 and 668

The order-428 paper reports retaining partial endpoint patterns and then using
backtracking. For `m=36`, fixing the first/last six positions leaves a central
region of length 24 in X/Y/Z and 23 in W. For `m=56`, the same endpoint width
leaves a central region of length 44 in X/Y/Z and 43 in W.

Thus the direct method transfers algebraically, but the middle-completion
backtracking problem grows sharply.

The current working hypothesis is:

```text
428 method transfers through:
  - Turyn identity
  - sum-square filtering
  - Hall/Fourier pruning
  - endpoint normalization idea
  - Turyn -> base -> T -> GS verification

668-specific barrier begins at:
  - generating enough Hall-admissible Z/W endpoint buckets
  - matching those buckets with X/Y completions
  - keeping the backtracking tree small enough after m increases 36 -> 56
```

## Next Concrete Step

The structured Turyn endpoint bucket generator is implemented in:

```text
sage/32_turyn_endpoint_bucket_generator.sage
```

It follows the next useful experiment:

```text
1. choose sum tuple (x,y,z,w)
2. generate Z and W with target sums
3. apply Hall grid pruning
4. bucket by first/last six entries
5. measure bucket sizes and compare to m=36
6. only then attempt X/Y completion
```

This isolates the point where 668 diverges from the 428 route.

## Endpoint Bucket Smoke Results

Files:

```text
outputs/turyn/turyn56_endpoint_buckets_smoke.json
outputs/turyn/turyn56_endpoint_buckets_smoke.md
outputs/turyn/turyn56_endpoint_buckets_tuple_0_m18_m2_1_3k.json
outputs/turyn/turyn36_endpoint_buckets_tuple_m14_m4_0_m1_3k.json
```

Small sweep, 500 random Z and W samples per tuple:

```text
n=56:
  best tuple [0,-18,-2,1]
  Z pass 4/500, W pass 7/500, pair pass 0/28
  best pair max 199.862, bound 167

n=36:
  best tuple [-14,-4,0,-1]
  Z pass 24/500, W pass 34/500, pair pass 0/816
  best pair max 112.683, bound 107
```

Focused 3000-sample runs:

```text
n=56, tuple [0,-18,-2,1]:
  Z pass 33/3000 = 1.10%
  W pass 48/3000 = 1.60%
  endpoint buckets: 33 Z, 48 W
  pair pass 0/1584
  best pair max 200.472, bound 167

n=36, tuple [-14,-4,0,-1]:
  Z pass 140/3000 = 4.67%
  W pass 204/3000 = 6.80%
  endpoint buckets: 136 Z, 194 W
  pair pass 0/28560
  best pair max 112.123, bound 107
```

These are random-sampling diagnostics, not exhaustive results. They suggest:

```text
1. Z/W single Hall-admissible samples are much rarer for m=56.
2. The Z/W pair Hall bound is the first serious bottleneck.
3. m=36 random samples can get close to the pair bound; m=56 remains much farther away.
4. X/Y completion should not start until the Z/W pair bucket generator produces at least some pair-Hall-admissible buckets.
```

## Hall-Pair-Aware Annealer

The pair-aware generator is implemented in:

```text
sage/33_hall_pair_bucket_annealer.sage
```

Unlike the single-sequence Hall filter used as a direct analogue of the 428
method, this script treats `(Z,W)` as a joint object and minimizes:

```text
max_theta (f_Z(theta) + f_W(theta))
```

while preserving the target row sums of `Z` and `W`.

Smoke results:

```text
n=56, tuple [0,-18,-2,1], bound 167
  seed 1, 3000 steps:
    initial pair max 452.057
    best pair max 170.635
    excess over bound 3.635
    pass false

  seed 2, 5000 steps:
    initial pair max 557.000
    best pair max 170.420
    excess over bound 6.678
    pass false

n=36, tuple [-14,-4,0,-1], bound 107
  seed 1, 3000 steps:
    initial pair max 223.334
    best pair max 107.459
    excess over bound 0.516
    pass false

Targeted worst-theta mixed moves:

n=36, tuple [-14,-4,0,-1], bound 107
  seed 3, 2173 steps:
    initial pair max 331.680
    best pair max 102.025
    excess over bound 0.000
    pass true

n=56, tuple [0,-18,-2,1], bound 167
  seed 3, 8000 steps:
    initial pair max 340.443
    best pair max 168.113
    excess over bound 2.280
    pass false
```

Interpretation:

```text
1. Pair-aware annealing is much stronger than random Hall-pruned generation.
2. Worst-theta targeted moves pass the Hall pair bound for the 428 analogue.
3. The same targeted move class improves the 668 analogue to pair_max 168.113, just above the bound 167.
4. This supports the hypothesis that the Z/W pair Hall stage is a genuine 668 bottleneck, but not an obviously impossible one.
5. The next new idea should target the last one or two units of pair-max excess, not start X/Y completion yet.
```

No Hadamard 668 construction has been produced by these diagnostics. These are
search-structure notes only.

## Basin Probe Triage

The basin-probe driver is implemented in:

```text
sage/34_hall_pair_basin_probe.sage
```

Purpose:

```text
1. Run many seeds for a short probe horizon.
2. Score whether the early trajectory looks like a promising basin.
3. Save the best early Z/W states.
4. Generate promotion commands that resume from those saved states.
```

The basin score is diagnostic. It is not a mathematical condition. The current
default score combines:

```text
best pair max
best excess over the Hall bound
number of violating theta grid points
pair flatness
early improvement speed
best update count
```

Small n=56 probe:

```text
tuple [0,-18,-2,1], bound 167
seeds 1..10
probe steps 1000
candidate trials 16
move mode mixed

rank 1: seed 1
  basin score 165.482
  best pair max 168.392
  excess 3.331
  violating theta count 3
  best step 265

rank 2: seed 2
  basin score 173.676
  best pair max 173.533
  excess 13.182
  violating theta count 3
  best step 685

rank 3: seed 4
  basin score 178.432
  best pair max 171.463
  excess 15.973
  violating theta count 6
  best step 318
```

Interpretation:

```text
1. Good basins can appear within the first 1000 steps.
2. The best probe state, seed 1, reached pair_max 168.392 quickly.
3. The right promotion unit is the saved Z/W state, not only the seed number.
4. Promotion should resume from probe-best JSON via --resume-pair-json.
5. This turns "find the answer" into a two-stage search: find promising basins, then repair/promote only those.
```

Promotion smoke:

```text
input:
  outputs/turyn/basin_probe_n56_seed1_10_1k/probe_best_rank1_seed1_pairmax168.392.json

pair_max 168.392
violating theta count 3
excess 3.331

16k-step pair_max promotion:
  no improvement

late-stage excess_then_violations greedy smoke:
  no improvement after 3k steps

diagnostic:
  rank-1 probe state is already close, but appears one-swap hard under the current move generator.
```

Comparison of best known close Hall-pair states:

```text
seed 3 targeted:
  pair_max 168.113
  violating theta count 3
  excess 2.280

seed 6 targeted:
  pair_max 168.305
  violating theta count 1
  excess 1.305

probe rank 1:
  pair_max 168.392
  violating theta count 3
  excess 3.331
```

Current implication:

```text
1. Basin probing can find close states quickly.
2. Promotion from a close state is not enough by itself.
3. The most attractive current state is arguably seed 6, because only one theta grid point violates the bound.
4. The next local move should be a spike-specific repair around the single violating theta, likely allowing coordinated two-sequence moves rather than one balanced flip in only Z or W.
```

## Single-Spike Coordinated Repair

The single-spike repair prototype is implemented in:

```text
sage/35_single_spike_hall_pair_repair.sage
```

Target:

```text
input:
  outputs/turyn/hall_pair_targeted_n56_tuple_0_m18_m2_1_10x_seed6_seed6_step1049_pairmax168.305.json

metrics:
  pair_max 168.304952
  bound 167
  violating theta count 1
  excess 1.304952
  unique violating theta 60
```

Coordinated repair test:

```text
objective pair_max
target theta 60
position pool all
flip pool 2000
rounds 1

checked coordinated candidates:
  593487

result:
  no improving coordinated Z-one-balanced-flip + W-one-balanced-flip move
```

Additional diagnostic:

```text
target_then_pair_max can reduce pressure on theta 60, but immediately creates
large spikes elsewhere, e.g. pair_max around 325 in the smoke run. This confirms
that the last spike is coupled to other Fourier modes; it is not an isolated
single-coordinate repair problem.
```

Implication:

```text
The seed-6 state is not merely hard for a biased candidate generator. It is hard
for exhaustive coordinated 1+1 balanced flips. The next local model must allow a
larger neighborhood, such as two balanced flips in Z and one in W, or a small
bounded Fourier-LNS model over several positions simultaneously.
```

## Multi-Flip Beam Repair

The multi-flip beam repair prototype is implemented in:

```text
sage/36_multi_flip_hall_pair_repair.sage
```

It keeps target sums fixed by composing multiple balanced flips. The first
successful pattern was `ZZWW`, i.e. two balanced flips in `Z` and two balanced
flips in `W`, selected by a beam over exact Fourier objective evaluations.

Repair sequence from the seed-6 state:

```text
start:
  pair_max 168.304952
  grid 100
  violations 1

round 1, grid 100, patterns ZZW/ZWW/ZZWW:
  best pattern ZZWW
  pair_max 167.360680
  excess 0.575215
  violations 2

round 2, grid 100:
  best pattern ZZW
  pair_max 166.061693
  excess 0
  violations 0
  grid-100 pass true
```

However, grid refinement exposed a hidden spike:

```text
same Z/W after grid-100 repair:
  grid 250 pair_max 171.682385
  grid 500 pair_max 171.682385
```

Refined repair:

```text
grid 250 repair round 1:
  pair_max 169.120220

grid 250 repair round 2:
  pair_max 166.626516
  grid-250 pass true

grid 500 repair:
  pair_max 166.841892
  grid-500 pass true

dense-grid diagnostic:
  grid 1000 pair_max 166.841892
  grid 2000 pair_max 166.879340
  grid 5000 pair_max 166.882361
  grid 10000 pair_max 166.882361
  grid 50000 pair_max 166.882360524
  violations 0
```

Interpretation:

```text
1. The larger 2+2 neighborhood materially changed the search boundary.
2. A coarse grid pass is not reliable; grid refinement must be part of the loop.
3. After refinement, this Z/W pair passes a dense sampled Hall bound with margin about 0.1176.
4. This is still not a Turyn sequence and not a Hadamard 668 construction.
5. The next bottleneck is X/Y completion for this repaired Z/W pair.
```

## Fixed Z/W X/Y Completion

The first fixed-`Z/W` completion search is implemented in:

```text
sage/37_fixed_zw_xy_completion.sage
```

For fixed `Z,W`, the exact condition is:

```text
N_X(s) + N_Y(s) = -2N_Z(s) - 2N_W(s),  s=1,...,55.
```

The repaired dense-grid Hall-pair `Z/W` was used as input:

```text
outputs/turyn/multi_flip_pairmax_seed6_grid500_beam150_pairmax166.842.json
```

First search:

```text
steps 20000
seed 2
candidate trials 64
objective score
move mode mixed

initial:
  score 5248
  l1 400
  max_abs 26
  nonzero 50

best:
  score 360
  l1 104
  max_abs 8
  nonzero 38
  bad shifts 38/55
  zero shifts 17/55
```

Defect histogram for the current best:

```text
-6: 2
-4: 4
-2: 12
 0: 17
 2: 16
 4: 3
 8: 1
```

Worst shifts:

```text
shift 43: +8
shift 6:  -6
shift 15: -6
```

Verification:

```text
sage/30_turyn_type_sequences.sage:
  Turyn type OK false
  sum identity OK: 334 = 334
```

Interpretation:

```text
1. The X/Y completion search is active and reduces defect quickly.
2. The repaired Z/W pair does not make X/Y completion trivial.
3. The current X/Y local search stalls around score 360.
4. The next improvement should use a larger X/Y neighborhood or defect-targeted multi-flip repair, analogous to the Z/W multi-flip repair that succeeded.
```

## X/Y Multi-Flip Repair Update

The larger `X/Y` neighborhood was added in:

```text
sage/38_xy_multi_flip_completion_repair.sage
```

The first multi-flip pass started from the score-360 fixed-`Z/W` completion and
targeted the largest defect shifts. It found a better near-hit:

```text
input:
  outputs/turyn/fixed_zw_xy_completion_seed2_20k_seed2_step5191_score360.json

best:
  score 296
  l1 104
  max_abs 6
  nonzero 43
```

The continuation search script was then corrected so `37_fixed_zw_xy_completion`
can resume an existing `X/Y` state with `--resume-xy-json`; without that option,
the script deliberately randomizes `X/Y`.

Correct continuation from the score-296 state did not improve in 12000 steps:

```text
initial score 296
final best score 296
plateau shakes 4
Turyn type OK false
```

Retargeting `38_xy_multi_flip_completion_repair` at the new worst shifts from
the score-296 state produced another improvement:

```text
input:
  outputs/turyn/fixed_zw_xy_completion_after38_score296_seed3_12k_seed3_step0_score296.json

target shifts:
  8,43,10,15,28,31,45

best pattern:
  XYY

best:
  score 288
  l1 92
  max_abs 6
  nonzero 35

artifact:
  outputs/turyn/xy_multi_flip_score296_worst7_beam220_score288.json
```

Exact verification of the score-288 artifact:

```text
Turyn type OK false
sum square identity OK: 334 = 334
```

A second score-first multi-flip pass from score 288 and an `l1`-first pass from
the same state did not improve it. A short single-flip continuation also stayed
at score 288.

Interpretation:

```text
1. The X/Y completion bottleneck is not random initialization alone; there are hard local basins.
2. Defect-targeted multi-flip repair is useful: it moved score 360 -> 296 -> 288.
3. Ordinary single-flip continuation is weak after multi-flip repair.
4. The score-288 state is still a near-hit only. It is not a Turyn type sequence and not a Hadamard 668 construction.
5. The next useful experiment should either expand the X/Y neighborhood model or change the X/Y candidate generation, rather than only increasing single-flip annealing time.
```

## P/Q Coordinate Diagnostic

The next diagnostic changes coordinates from `X,Y` to:

```text
P = X + Y
Q = X - Y
```

Since `X,Y` are `±1`, the sequences `P,Q` are disjoint-support ternary
sequences with values in `{ -2, 0, 2 }`. The identity

```text
N_P(s) + N_Q(s) = 2(N_X(s) + N_Y(s))
```

was checked exactly by:

```text
sage/39_pq_xy_completion_diagnostics.sage
```

For the score-288 near-hit:

```text
P support 23
P sum -18
P positive 7
P negative 16

Q support 33
Q sum 18
Q positive 21
Q negative 12

P/Q disjoint support true
P/Q identity true
P/Q defect equals 2 * X/Y defect true
```

The diagnostic artifact is:

```text
outputs/turyn/pq_xy_score288_diagnostic_score288.md
outputs/turyn/pq_xy_score288_diagnostic_score288.json
```

Interpretation:

```text
1. X/Y completion can be viewed as splitting positions into P-channel and Q-channel signed support.
2. Same-channel signed pairs contribute to autocorrelation.
3. Cross-channel pairs are silent.
4. Flipping one X entry maps (P,Q) at that position to (-Q,-P).
5. Flipping one Y entry maps (P,Q) at that position to (Q,P).
6. Balanced X/Y flips are therefore channel-routing operations with signs, not just bit flips.
7. The next repair model should use this channel-routing view directly.
```

## P/Q Channel-Routing Repair

The first P/Q-aware repair beam is:

```text
sage/40_pq_channel_routing_repair.sage
```

It ranks atomic balanced `X`/`Y` flips using P/Q channel pressure on the active
bad shifts, then evaluates multi-flip patterns exactly against the fixed `Z/W`
completion objective.

Runs from the score-288 near-hit:

```text
input:
  outputs/turyn/xy_multi_flip_score296_worst7_beam220_score288.json

targets:
  35,44,6,11,20,26,46,49,51

raw P/Q target objective:
  target_l1 40 -> 2
  score 288 -> 776
  l1 92 -> 140
  max_abs 6 -> 12

bounded P/Q target objective:
  target_l1 40 -> 12
  score 288 -> 296
  l1 92 -> 104
  max_abs 6 -> 6

strict score cap:
  score 288 -> 288
  no improvement

damage-aware net objective:
  target_gain 10..24
  non_target_l1_increase 18..40
  zero_shift_damage 8..20
  net_routing_gain negative in tested patterns
  no improvement
```

Interpretation:

```text
1. P/Q routing can strongly alter the target defect shifts.
2. Without a global cap, it simply moves defect mass elsewhere.
3. With a moderate cap, it finds nearby alternative states but not a better score.
4. With a strict score cap, the current score-288 basin remains hard.
5. Damage-aware scoring explains the failure: target_l1 improvement is paid for by non-target and zero-shift damage.
6. This suggests either a wider coordinated move that repairs target and non-target shifts together, or a nonmonotone route: use P/Q routing to escape, then delayed repair to recover score.
7. This is still only a near-hit diagnostic. No Turyn type sequence or Hadamard 668 construction has been found.
```

## Reverse Feasibility Diagnostic

The next pivot is to reason backward from necessary properties of an exact
completion. The diagnostic script is:

```text
sage/41_turyn_completion_feasibility_diagnostics.sage
```

It reports:

```text
1. fixed Z/W target profile for X/Y,
2. sampled required Fourier profile |Xhat|^2 + |Yhat|^2,
3. basic parity and absolute target bounds,
4. possible P/Q support splits from the requested X/Y sums,
5. optional supplied X/Y near-hit diagnostics.
```

For the repaired dense-grid Hall-pair `Z/W`:

```text
input:
  outputs/turyn/multi_flip_pairmax_seed6_grid500_beam150_pairmax166.842.json

with X/Y near-hit:
  outputs/turyn/xy_multi_flip_score296_worst7_beam220_score288.json

target profile:
  score 2044
  l1 258
  max_abs 18
  nonzero 55

sampled Fourier required profile, grid 5000:
  min_required 0.235278951436
  max_required 324
  mean_required 112
  std_required 63.937469452583
  negative_sample_count 0
  small_required_count_10 92

P/Q support possibilities from tuple:
  20 support splits
  P_support range 9..47

current X/Y near-hit:
  score 288
  l1 92
  max_abs 6
  nonzero 35
  P_support 23
  Q_support 33
```

For comparison, the pre-repair close Hall-pair state:

```text
input:
  outputs/turyn/hall_pair_targeted_n56_tuple_0_m18_m2_1_10x_seed6_seed6_step1049_pairmax168.305.json

pair_max 168.304951685
target score 2844
target l1 322
sampled Fourier min_required -9.040949150703
negative_sample_count 128
```

Interpretation:

```text
1. Z/W multi-flip repair made a real reverse-feasibility improvement: sampled Fourier required energy became nonnegative.
2. It also flattened the X/Y target profile from score 2844 to 2044.
3. The repaired Z/W is therefore not arbitrary; it has passed a meaningful necessary diagnostic.
4. However, min_required is only about 0.235 on the sampled grid, so X/Y must nearly cancel some Fourier modes.
5. This phase-sensitive low-energy requirement is a plausible reason fixed-Z/W X/Y completion is hard.
6. The next non-local strategy should generate Z/W pairs using X/Y-completability proxies, not Hall pair_max alone.
7. This remains diagnostic only, not proof or construction.
```

## 428 Analogue Reverse Diagnostic

The same reverse diagnostic was run on the existing `n=36` Hall-pair analogue
for order 428:

```text
input:
  outputs/turyn/hall_pair_targeted_n36_tuple_m14_m4_0_m1_seed3_step2173_pairmax102.025.json

tuple:
  [-14,-4,0,-1]

target order:
  428
```

Output:

```text
outputs/turyn/feasibility_428_n36_pair102025_n36_grid5000.md
outputs/turyn/feasibility_428_n36_pair102025_n36_grid5000.json
```

Comparison:

```text
n=36 / order 428 analogue:
  pair_max 102.024942904
  target score 908
  target l1 150
  target max_abs 10
  target roughness 1360
  sampled Fourier min_required 6.087676087
  sampled Fourier max_required 212
  sampled Fourier std 42.614551505
  negative samples 0
  small_required_count_10 44
  P/Q support split options 12

n=56 / order 668 repaired Z/W:
  pair_max 166.841891647
  target score 2044
  target l1 258
  target max_abs 18
  target roughness 4144
  sampled Fourier min_required 0.235278951
  sampled Fourier max_required 324
  sampled Fourier std 63.937469453
  negative samples 0
  small_required_count_10 92
  P/Q support split options 20
```

Interpretation:

```text
1. The n=36 analogue is sampled-Fourier feasible with a much larger minimum required X/Y energy.
2. The n=56 repaired Z/W is also sampled-Fourier feasible, but much closer to zero at some modes.
3. The n=56 target profile is rougher and has larger spikes.
4. This supports the current hypothesis: 668 is not merely harder because it is larger; the fixed-Z/W completion target appears more phase-sensitive.
5. This comparison is not against the published exact 428 solution unless that exact sequence is imported separately. It is a project-local n=36 analogue.
```

## Published Exact 428 Reverse Diagnostic

The published Kharaghani--Tayfeh-Rezaie order-428 Turyn type sequence was then
imported as an exact positive control:

```text
outputs/turyn/exact_428_kharaghani_tayfeh_rezaie.json
```

Exact verification:

```text
outputs/turyn/verify_exact_428_kharaghani_tayfeh_rezaie.json

Turyn type OK true
T-sequences OK true
generated order 428
HH^T check true
tuple [0,6,8,5]
```

Reverse diagnostic:

```text
outputs/turyn/feasibility_exact428_ktr_n36_grid5000.md
outputs/turyn/feasibility_exact428_ktr_n36_grid5000.json
```

Comparison:

```text
published exact 428:
  tuple [0,6,8,5]
  target score 1004
  target l1 146
  target max_abs 14
  target roughness 1440
  sampled Fourier min_required 4.474229069
  sampled Fourier max_required 178.808289890
  sampled Fourier std 44.810713005
  negative samples 0
  small_required_count_10 146
  supplied X/Y score 0
  P/Q support split used: P_support 19, Q_support 17

n=56 / order 668 repaired Z/W + best X/Y near-hit:
  tuple [0,-18,-2,1]
  target score 2044
  target l1 258
  target max_abs 18
  target roughness 4144
  sampled Fourier min_required 0.235278951
  sampled Fourier max_required 324
  sampled Fourier std 63.937469453
  negative samples 0
  small_required_count_10 92
  supplied X/Y score 288
  P/Q support split used: P_support 23, Q_support 33
```

Additional interpretation:

```text
1. The exact 428 positive control shows that target score/max_abs alone are not decisive.
2. The exact 428 Z/W target profile has score 1004 and max_abs 14, yet X/Y completes it exactly.
3. The current 668 repaired Z/W profile is much rougher and has a sampled required Fourier minimum near zero.
4. small_required_count_10 is not monotone as a hardness metric; exact 428 has more samples below 10 than the current 668 near-hit.
5. The more useful distinction is X/Y-completability: the discrete P/Q support and signs must realize the Z/W target profile without moving defect mass elsewhere.
6. This supports using exact 428 as a positive-control inverse-design example for generating 668 Z/W profiles, not simply as a Hall-bound template.
```

Detailed comparison:

```text
outputs/turyn/exact428_to_668_reverse_diagnostic.md
```

The first completion-proxy implementation is:

```text
sage/42_zw_completion_proxy_diagnostics.sage
```

and `sage/33_hall_pair_bucket_annealer.sage` now accepts:

```text
--objective completion_proxy
--objective completion_proxy_then_pair_max
```

The in-loop objective is deliberately cheaper than the full diagnostic: it uses
Hall/Fourier margin and target-profile terms, while `42` adds the more expensive
P/Q support/sign relaxation. This keeps Z/W generation fast while still allowing
candidate basins to be filtered for X/Y-completability afterward.
