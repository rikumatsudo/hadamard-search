# Hadamard order 668 SDS search progress report

Date: 2026-05-04

This note summarizes the current computational status of the search for a
Hadamard matrix of order 668 via supplementary difference sets over `Z_167`.
No construction has been found yet. All files referenced below are in the
project directory `<repo-root>`.

## 1. Mathematical target

The target order is

```text
668 = 4 * 167.
```

The search is for four blocks

```text
X_1, X_2, X_3, X_4 subset Z_167
```

with sizes `k_1, k_2, k_3, k_4` and parameter `lambda`, satisfying the SDS
condition

```text
sum_i #{(x,y) in X_i x X_i : x != y and x - y = d mod 167} = lambda
```

for every nonzero `d in Z_167`.

Given such an SDS, the pipeline constructs four `+1/-1` circulant matrices by
putting `-1` on block positions and `+1` elsewhere, inserts them into the
Goethals-Seidel array, and verifies exactly over integer matrices that

```text
H * H^T = 668 I.
```

The project treats a result as successful only if both conditions hold:

1. the SDS difference condition is exactly true;
2. the Goethals-Seidel matrix satisfies `H * H^T = 668 I` over `ZZ`.

Near-hits are not treated as solutions.

## 2. Verification pipeline status

The verification infrastructure is implemented and has passed small known
SDS regressions.

Main scripts:

```text
sage/04_build_gs_from_sds.sage
sage/05_validate_candidate_json.sage
sage/06_known_sds_regression.sage
sage/07_guided_sds_search_668.sage
sage/08_analyze_sds_candidate.sage
sage/09_summarize_search_logs.py
```

Known SDS regression results:

```text
v=3, n=12, ks=[0,1,1,1], lambda=0: SDS OK, HH^T = 12I
v=5, n=20, ks=[1,1,2,2], lambda=1: SDS OK, HH^T = 20I
v=7, n=28, ks=[1,3,3,3], lambda=3: SDS OK, HH^T = 28I
```

Relevant logs:

```text
outputs/logs/06_known_sds_regression_20260504_024133.log
outputs/logs/04_build_gs_from_sds_20260504_020721.log
outputs/logs/05_validate_candidate_json_20260504_020721.log
```

## 3. SDS parameter candidates for v=167

The following ten parameter candidates satisfy the SDS parameter equation.

| ks | lambda |
|---:|---:|
| `(71,81,82,82)` | 149 |
| `(72,78,82,82)` | 147 |
| `(72,79,80,82)` | 146 |
| `(73,76,83,83)` | 148 |
| `(73,77,80,82)` | 145 |
| `(73,78,79,81)` | 144 |
| `(74,75,82,82)` | 146 |
| `(74,76,79,83)` | 145 |
| `(75,75,79,82)` | 144 |
| `(76,76,77,80)` | 142 |

Source:

```text
outputs/params/sds_params_v167_n668.json
outputs/logs/01_sds_params_20260504_015619.log
```

## 4. Screening run

The latest all-parameter screening used the guided local search engine:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/07_guided_sds_search_668.sage \
  --all-params \
  --steps 100000 \
  --seed-start 1 \
  --seed-end 20 \
  --restart-patience 20000
```

This corresponds to `10 parameter sets x 20 seeds x 100000 steps`, i.e.
20,000,000 local-search steps in the latest screening run. The cumulative
summary also includes earlier smoke/resume runs, which is why `(71,81,82,82)`
shows 21 seeds in the aggregate table.

The search score is

```text
score = sum_{d != 0} (count[d] - lambda)^2
l1_error = sum_{d != 0} |count[d] - lambda|
max_abs_error = max_{d != 0} |count[d] - lambda|
```

No run reached `score=0`.

## 5. Aggregate ranking by parameter set

Source:

```text
outputs/logs/search_summary_by_param.csv
```

| rank | ks | lambda | seeds | total steps | best score | best l1 | best max abs | best seed | best file |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | `(73,78,79,81)` | 144 | 20 | 2,000,000 | 168 | 120 | 3 | 4 | `outputs/candidates/near_hits/near_hit_v167_score168_seed4_step36303.json` |
| 2 | `(73,76,83,83)` | 148 | 20 | 2,000,000 | 172 | 128 | 2 | 6 | `outputs/candidates/near_hits/near_hit_v167_score172_seed6_step33709.json` |
| 3 | `(72,78,82,82)` | 147 | 20 | 2,000,000 | 180 | 116 | 3 | 1 | `outputs/candidates/near_hits/near_hit_v167_score180_seed1_step84966.json` |
| 4 | `(74,76,79,83)` | 145 | 20 | 2,000,000 | 184 | 132 | 3 | 18 | `outputs/candidates/near_hits/near_hit_v167_score184_seed18_step53224.json` |
| 5 | `(75,75,79,82)` | 144 | 20 | 2,000,000 | 188 | 132 | 2 | 13 | `outputs/candidates/near_hits/near_hit_v167_score188_seed13_step73381.json` |
| 6 | `(71,81,82,82)` | 149 | 21 | 2,000,003 | 188 | 136 | 2 | 13 | `outputs/candidates/near_hits/near_hit_v167_score188_seed13_step41614.json` |
| 7 | `(73,77,80,82)` | 145 | 20 | 2,000,000 | 192 | 140 | 3 | 15 | `outputs/candidates/near_hits/near_hit_v167_score192_seed15_step36342.json` |
| 8 | `(74,75,82,82)` | 146 | 20 | 2,000,000 | 200 | 140 | 3 | 4 | `outputs/candidates/near_hits/near_hit_v167_score200_seed4_step44369.json` |
| 9 | `(72,79,80,82)` | 146 | 20 | 2,000,000 | 208 | 132 | 3 | 5 | `outputs/candidates/near_hits/near_hit_v167_score208_seed5_step22664.json` |
| 10 | `(76,76,77,80)` | 142 | 20 | 2,000,000 | 208 | 136 | 3 | 4 | `outputs/candidates/near_hits/near_hit_v167_score208_seed4_step72074.json` |

## 6. Current best near-hit

Best current near-hit:

```text
outputs/candidates/near_hits/near_hit_v167_score168_seed4_step36303.json
```

Parameters:

```text
v = 167
n = 668
ks = [73, 78, 79, 81]
lambda = 144
seed = 4
step = 36303
strategy = baseline
```

Metrics:

```text
score = 168
l1_error = 120
max_abs_error = 3
verify_sds = false
generated_hadamard = false
hh_t = false
```

The JSON was re-analyzed with

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/08_analyze_sds_candidate.sage \
  outputs/candidates/near_hits/near_hit_v167_score168_seed4_step36303.json
```

The stored score and recomputed score agree. Duplicate checks, range checks,
and block-size checks all pass. The candidate is nevertheless not an SDS.

Defect histogram for `count[d] - lambda`:

| defect | number of nonzero shifts |
|---:|---:|
| -2 | 10 |
| -1 | 40 |
| 0 | 68 |
| 1 | 38 |
| 2 | 8 |
| 3 | 2 |

Equivalently, the difference-count histogram is:

| count[d] | number of nonzero shifts |
|---:|---:|
| 142 | 10 |
| 143 | 40 |
| 144 | 68 |
| 145 | 38 |
| 146 | 8 |
| 147 | 2 |

Worst overrepresented shifts:

```text
d = 50, 117 have count[d] = 147, defect = +3.
```

Worst underrepresented shifts:

```text
d = 25, 31, 35, 51, 70, 97, 116, 132, 136, 142
have count[d] = 142, defect = -2.
```

Because the difference counts are symmetric under `d <-> -d`, these defects
occur in opposite-shift pairs.

## 7. Interpretation

The computational pipeline is now reproducible:

1. enumerate SDS parameters;
2. run local search and save near-hit JSON;
3. re-analyze JSON and recompute all difference counts;
4. if `score=0`, validate the SDS exactly;
5. build the Goethals-Seidel matrix;
6. verify `H * H^T = 668 I` over integer matrices.

At present the project has not produced an SDS for `v=167`, hence has not
produced a Hadamard matrix of order 668. The best object is a near-hit with
all nonzero difference counts within 3 of the target, but 98 of 166 shifts
still have nonzero defect.

The most promising parameter sets from this screening are:

```text
(73,78,79,81), lambda=144
(73,76,83,83), lambda=148
(72,78,82,82), lambda=147
```

The second parameter set is also interesting because it reached
`max_abs_error=2`.

## 8. Suggested next computations

First, concentrate longer runs on the current top parameter set:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/07_guided_sds_search_668.sage \
  --steps 10000000 \
  --seed-start 1 \
  --seed-end 50 \
  --ks 73,78,79,81 \
  --lam 144 \
  --restart-patience 50000
```

Resume from the current best near-hit with fresh seeds:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/07_guided_sds_search_668.sage \
  --resume-json outputs/candidates/near_hits/near_hit_v167_score168_seed4_step36303.json \
  --steps 10000000 \
  --seed 21 \
  --restart-patience 100000
```

Also run focused tests on the next two parameter sets:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/07_guided_sds_search_668.sage \
  --steps 10000000 \
  --seed-start 1 \
  --seed-end 50 \
  --ks 73,76,83,83 \
  --lam 148 \
  --restart-patience 50000
```

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/07_guided_sds_search_668.sage \
  --steps 10000000 \
  --seed-start 1 \
  --seed-end 50 \
  --ks 72,78,82,82 \
  --lam 147 \
  --restart-patience 50000
```

For algorithmic comparison, run one smaller A/B test with targeted or mixed
strategy before committing large compute time:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/07_guided_sds_search_668.sage \
  --steps 1000000 \
  --seed-start 1 \
  --seed-end 10 \
  --ks 73,78,79,81 \
  --lam 144 \
  --strategy mixed \
  --targeted-prob 0.15 \
  --plateau-escape \
  --restart-patience 50000
```

## 9. Reproducibility commands

Re-run known SDS regression:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/06_known_sds_regression.sage
```

Validate a candidate JSON as an SDS:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/05_validate_candidate_json.sage <candidate.json>
```

Build the Goethals-Seidel matrix and verify Hadamard condition:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/04_build_gs_from_sds.sage <candidate.json>
```

Analyze a near-hit:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/08_analyze_sds_candidate.sage <near_hit.json>
```

Summarize logs:

```bash
python3 sage/09_summarize_search_logs.py \
  --out-json outputs/logs/search_summary.json \
  --out-csv outputs/logs/search_summary_by_seed.csv \
  --out-param-csv outputs/logs/search_summary_by_param.csv
```

## 10. Local repair update

After the all-parameter screening, the best near-hit

```text
outputs/candidates/near_hits/near_hit_v167_score168_seed4_step36303.json
```

was passed to a complete 1-swap steepest-descent repair:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/11_steepest_swap_descent.sage \
  outputs/candidates/near_hits/near_hit_v167_score168_seed4_step36303.json
```

This evaluated all 27,722 one-point swaps in each round. One improving move was
found:

```text
block 2: 160 -> 76
```

The resulting repaired near-hit is:

```text
outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json
```

Metrics improved as follows:

| stage | score | l1_error | max_abs_error | nonzero_defect_count |
|---|---:|---:|---:|---:|
| before 1-swap repair | 168 | 120 | 3 | 98 |
| after 1-swap repair | 164 | 116 | 3 | 96 |

The next complete 1-swap neighborhood check found no further improving
1-swap; the repaired near-hit is therefore a 1-swap local optimum under the
lexicographic metric

```text
(score, l1_error, max_abs_error, nonzero_defect_count).
```

The repaired near-hit was then tested with bounded 2-swap beam repair:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/12_beam_two_swap_repair.sage \
  outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json \
  --beam-width 200 \
  --rounds 50
```

In the first beam round, 200 best 1-swap candidates generated 37,738 valid
ordered 2-swap evaluations. No improving 2-swap was found in that beam.

The repaired near-hit was re-analyzed with:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/08_analyze_sds_candidate.sage \
  outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json \
  --no-defect-vector
```

Stored and recomputed metrics agree. Duplicate checks, range checks, and block
size checks all pass. It remains a near-hit, not a solution:

```text
verify_sds = false
generated_hadamard = false
hh_t = false
```

The repaired defect/count histogram is:

| count[d] | defect | number of nonzero shifts |
|---:|---:|---:|
| 141 | -3 | 2 |
| 142 | -2 | 6 |
| 143 | -1 | 40 |
| 144 | 0 | 70 |
| 145 | +1 | 40 |
| 146 | +2 | 6 |
| 147 | +3 | 2 |

Worst remaining shifts:

```text
underrepresented: d = 26, 141 have defect -3
overrepresented:  d = 79, 88 have defect +3
```

The immediate next repair experiment should either increase the 2-swap beam
width beyond 200 or move to a targeted/mixed run resumed from the repaired
near-hit.

## 11. Defect-driven ILP repair plan

The next repair step is to treat the current near-hit as a small local
optimization problem around its defect vector. For each candidate swap, compute
the integer vector by which it changes

```text
count[d] - lambda,  d = 1,...,166.
```

Then choose a compatible set of swaps by solving a small 0-1 ILP. The ILP does
not search the full SDS space. It only searches a defect-driven move pool near
the current near-hit.

The implemented script is:

```text
sage/13_ilp_repair_from_near_hit.sage
```

Example:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/13_ilp_repair_from_near_hit.sage \
  outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json \
  --pool-size 400 \
  --pool-mode mixed \
  --max-moves 6 \
  --rounds 3 \
  --objective score_then_l1
```

The move pool ranks swaps using defect alignment, absolute defect repair,
side-effect damage, repair of worst shifts, and `d/-d` pair repair. Pool modes
are `score`, `l1`, `max_abs`, `worst_shift`, `mixed`, and `diverse`. The
`mixed` mode combines score, l1, max-abs, worst-over, worst-under, pair, and
alignment categories; `diverse` also adds random and per-block diversity.

The ILP enforces compatibility inside each block and optimizes `score`,
`score_then_l1`, `l1`, or `max_then_l1`. The score objectives encode the small
integer residual values directly, so they optimize `sum residual^2` over the
local move pool as an ILP. Any improved state is still saved only as a near-hit
unless exact SDS verification and exact integer Goethals-Seidel verification
both pass.

The script now also maintains a Pareto frontier under

```text
(score, l1_error, max_abs_error, nonzero_defect_count)
```

for each fixed `(v, n, ks, lambda)`. The frontier index is:

```text
outputs/candidates/near_hits/frontier/frontier_index.json
```

Dominated entries are removed from this index, but original near-hit JSONs are
kept as experiment logs.

## 12. First ILP repair results

The ILP repair was first run on the current score-best near-hit:

```text
outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json
```

With `pool-size=80`, `max-moves=4`, and objective `max_then_l1`, the ILP found
a two-swap combination that lowers `max_abs_error` from `3` to `2`, but worsens
the score:

| state | score | l1_error | max_abs_error | nonzero_defect_count |
|---|---:|---:|---:|---:|
| score-best input | 164 | 116 | 3 | 96 |
| ILP max-abs branch | 200 | 124 | 2 | 86 |

The selected swaps were:

```text
block 3: 15 -> 74
block 0: 145 -> 96
```

This branch was saved as:

```text
outputs/candidates/near_hits/near_hit_v167_score200_ilp_repair_from_near_hit_round1.json
```

Running complete 1-swap steepest descent from that branch improved it to:

```text
outputs/candidates/near_hits/near_hit_v167_score184_steepest_swap_descent_round1.json
```

with metrics:

| state | score | l1_error | max_abs_error | nonzero_defect_count |
|---|---:|---:|---:|---:|
| after 1-swap repair of max-abs branch | 184 | 124 | 2 | 94 |

This gives a same-parameter local branch with `max_abs_error=2`, although it is
worse than the score-best branch under the primary lexicographic metric.

A score-encoded ILP objective was also tested:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/13_ilp_repair_from_near_hit.sage \
  outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json \
  --pool-size 60 \
  --max-moves 4 \
  --rounds 1 \
  --objective score_then_l1 \
  --acceptance lex \
  --residual-bound 8
```

In this smaller score-directed pool, the ILP selected no swaps; the current
score-best near-hit remained unchanged:

```text
score = 164
l1_error = 116
max_abs_error = 3
nonzero_defect_count = 96
```

Thus the current picture is:

```text
score-best branch: score=164, max_abs=3
max-abs branch:    score=184, max_abs=2
```

Both remain near-hits, not SDS solutions.

## 13. Pool-mode and frontier update

The ILP repair script now supports explicit pool construction modes:

```text
score
l1
max_abs
worst_shift
mixed
diverse
```

The `mixed` pool combines score, l1, max-abs, worst-over, worst-under,
`d/-d` pair, and alignment categories. The `diverse` pool adds random and
per-block diversity. The ILP logs the pool mode, selected moves, objective, and
Pareto status for each output.

The Pareto frontier for the current parameter set is stored at:

```text
outputs/candidates/near_hits/frontier/frontier_index.json
```

After testing both main branches, the active frontier contains two non-dominated
near-hits:

| branch | score | l1_error | max_abs_error | nonzero_defect_count | source |
|---|---:|---:|---:|---:|---|
| score-best | 164 | 116 | 3 | 96 | `near_hit_v167_score164_steepest_swap_descent_round1.json` |
| max-abs | 184 | 124 | 2 | 94 | `near_hit_v167_score184_steepest_swap_descent_round1.json` |

Additional tests:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/13_ilp_repair_from_near_hit.sage \
  outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json \
  --pool-size 80 \
  --pool-mode mixed \
  --max-moves 5 \
  --rounds 1 \
  --objective score_then_l1 \
  --acceptance lex \
  --residual-bound 8
```

Result: no improving score-directed move set was selected from this pool.

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/13_ilp_repair_from_near_hit.sage \
  outputs/candidates/near_hits/near_hit_v167_score184_steepest_swap_descent_round1.json \
  --pool-size 80 \
  --pool-mode mixed \
  --max-moves 5 \
  --rounds 1 \
  --objective score_then_l1 \
  --acceptance lex \
  --residual-bound 8
```

Result: the ILP found a 3-swap move set from the max-abs branch back to metrics
`score=164, l1_error=116, max_abs_error=3, nonzero_defect_count=96`. This is
metric-equivalent to the score-best branch, so the frontier remains the two
branches listed above.

The latest regression check still passes:

```text
v=3, n=12: SDS OK, HH^T = 12I
v=5, n=20: SDS OK, HH^T = 20I
v=7, n=28: SDS OK, HH^T = 28I
```
