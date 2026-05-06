# Hadamard Search for n = 668

This project sets up a SageMath-based search environment for a Hadamard
matrix of order `668 = 4 * 167`.

The working strategy is:

1. Search for supplementary difference sets (SDS) over `Z_167`.
2. Convert four SDS blocks into four circulant `+1/-1` matrices.
3. Build a Goethals-Seidel array of order `668`.
4. Accept a candidate only after SageMath verifies `H * H^T = 668 I`.

The project does not brute-force the full `+1/-1` matrix.

## Success Criteria

A candidate is successful only if all of the following hold:

- The candidate JSON contains `v = 167`, `n = 668`, four block sizes, `lambda`,
  and four blocks over `Z_167`.
- The SDS difference condition is verified for every nonzero shift.
- The Goethals-Seidel matrix is generated from those blocks.
- SageMath verifies `H * H.transpose() == 668 * identity_matrix(ZZ, 668)`.
- The JSON records `verify_sds = true`, `generated_hadamard = true`, and
  `hh_t = true`.

Unverified candidates are not treated as successes.

## Layout

```text
.
  README.md
  sage/
    00_baseline.sage
    01_sds_params.sage
    02_verify_sds.sage
    03_random_sds_search.sage
    04_build_gs_from_sds.sage
    05_validate_candidate_json.sage
    06_known_sds_regression.sage
    07_guided_sds_search_668.sage
    08_analyze_sds_candidate.sage
    09_summarize_search_logs.py
    10_skew_sds_search_668.sage
    11_steepest_swap_descent.sage
    12_beam_two_swap_repair.sage
    13_ilp_repair_from_near_hit.sage
  outputs/
    params/
    candidates/
      near_hits/
    logs/
```

## SageMath with Docker

From this directory:

```bash
docker run -it --rm \
  -v "$PWD":/work \
  -w /work \
  sagemath/sagemath:latest bash
```

Inside the container:

```bash
sage sage/00_baseline.sage
sage sage/01_sds_params.sage
sage sage/03_random_sds_search.sage --steps 200000 --seed 1
```

All scripts write logs under `outputs/logs`.

If local SageMath cannot write to `~/.sage`, point Sage's dot directory at a
writable temporary location:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/00_baseline.sage
```

## Scripts

### `sage/00_baseline.sage`

Checks SageMath's built-in Hadamard construction/existence reporting for known
and currently unresolved orders, then builds and verifies a known order:

```bash
sage sage/00_baseline.sage
```

### `sage/01_sds_params.sage`

Enumerates SDS parameter candidates for `v = 167, 179, 223` and writes JSON
files under `outputs/params`:

```bash
sage sage/01_sds_params.sage
sage sage/01_sds_params.sage --v 167 --v 179 --v 223
```

For `v = 167`, one default target used by the search script is:

```text
k = (71, 81, 82, 82), lambda = 149
```

### `sage/02_verify_sds.sage`

Verifies a candidate JSON, then builds and checks the Goethals-Seidel Hadamard
matrix unless `--skip-hadamard` is passed:

```bash
sage sage/02_verify_sds.sage outputs/candidates/candidate_sds_668.json
sage sage/02_verify_sds.sage outputs/candidates/candidate_sds_668.json --skip-hadamard
```

### `sage/03_random_sds_search.sage`

Runs a fixed-size random local search for SDS blocks. By default it targets
`v = 167`, `k = (71, 81, 82, 82)`, `lambda = 149`.

```bash
sage sage/03_random_sds_search.sage
sage sage/03_random_sds_search.sage --steps 500000 --seed 42
sage sage/03_random_sds_search.sage --ks 72,78,82,82 --lam 147 --seed 7
```

When a zero-score candidate is found, the script verifies the SDS condition,
constructs the Goethals-Seidel matrix, verifies `HH^T = 668I`, and writes the
candidate JSON to `outputs/candidates`.

### `sage/05_validate_candidate_json.sage`

Revalidates a candidate JSON as an SDS. This checks the JSON shape, parameter
equations, block sizes, duplicate/range errors, and all nonzero difference
shifts:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/05_validate_candidate_json.sage \
  outputs/candidates/candidate_sds_668.json
```

### `sage/04_build_gs_from_sds.sage`

Builds four `+1/-1` circulant matrices from the candidate blocks, assembles the
Goethals-Seidel array, and verifies the exact integer identity `HH^T = nI`:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/04_build_gs_from_sds.sage \
  outputs/candidates/candidate_sds_668.json
```

### `sage/06_known_sds_regression.sage`

Runs small known SDS regressions for orders `12`, `20`, and `28`. This is the
pre-search check that the JSON, SDS validation, Goethals-Seidel construction,
and exact Hadamard verification pipeline agree:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/06_known_sds_regression.sage
```

To keep the generated known-SDS JSON fixtures for separate `04`/`05` checks:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/06_known_sds_regression.sage \
  --fixture-dir outputs/candidates/known_regression
```

### `sage/07_guided_sds_search_668.sage`

Runs the main guided swap local search for `Z_167`. The default target is
`v = 167`, `n = 668`, `k = (71, 81, 82, 82)`, `lambda = 149`.

Single seed:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/07_guided_sds_search_668.sage \
  --steps 1000000 \
  --seed 1 \
  --ks 71,81,82,82 \
  --lam 149
```

Seed range:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/07_guided_sds_search_668.sage \
  --steps 1000000 \
  --seed-start 1 \
  --seed-end 20
```

All `v = 167` parameter candidates from `outputs/params`:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/07_guided_sds_search_668.sage \
  --all-params \
  --steps 1000000 \
  --seed-start 1 \
  --seed-end 10 \
  --restart-patience 50000
```

Longer run:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/07_guided_sds_search_668.sage \
  --steps 10000000 \
  --seed-start 1 \
  --seed-end 50 \
  --restart-patience 50000
```

The search logs `score`, `l1_error`, `max_abs_error`,
`nonzero_defect_count`, best metrics, seed, restart count, plateau escape
count, last improvement step, active strategy, objective schedule, objective
tuple, targeted-swap probability, shake rate, current temperature, canonical
hash, and elapsed time to both `outputs/logs/*.log` and a CSV file.

Strategy options:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/07_guided_sds_search_668.sage \
  --steps 1000000 \
  --seed 1 \
  --strategy baseline

DOT_SAGE=/private/tmp/sage-dot sage sage/07_guided_sds_search_668.sage \
  --steps 1000000 \
  --seed 1 \
  --strategy greedy \
  --targeted-prob 0.3

DOT_SAGE=/private/tmp/sage-dot sage sage/07_guided_sds_search_668.sage \
  --steps 1000000 \
  --seed 1 \
  --strategy mixed \
  --mixed-period 1000 \
  --targeted-prob 0.3 \
  --plateau-escape \
  --shake-rate 0.03
```

`baseline` preserves the previous annealed move style. `greedy` accepts only
improving moves. `anneal` uses the configured temperature schedule. `mixed`
alternates between greedy and annealed phases. `--targeted-prob` enables
error-vector guided swaps that bias moves toward reducing overrepresented
shifts and filling underrepresented shifts. Candidate moves are ranked by
the active objective schedule. `--plateau-escape` uses a partial shake of the
current blocks instead of immediately discarding the state on a plateau.

Objective schedules control the lexicographic tuple used for move acceptance,
targeted proposal ranking, best near-hit updates, and saved near-hit
`objective_tuple` values. The raw `score`, `l1_error`, `max_abs_error`, and
`nonzero_defect_count` metrics are always saved unchanged.

Available schedules:

- `score_first`: `(score, l1_error, max_abs_error, nonzero_defect_count)`
- `l1_first`: `(l1_error, score, max_abs_error, nonzero_defect_count)`
- `nonzero_first`: `(nonzero_defect_count, l1_error, max_abs_error, score)`
- `maxabs_first`: `(max_abs_error, l1_error, score, nonzero_defect_count)`
- `soft_nonzero`: rank by `score + alpha*l1_error + beta*nonzero_defect_count + gamma*max_abs_error^2`
- `soft_l1_nonzero`: rank by `score + alpha*l1_error + beta*nonzero_defect_count + gamma*max_abs_error`
- `bounded_score_nonzero`: within `best_score_seen + score_slack`, rank by `(nonzero_defect_count, l1_error, max_abs_error, score)`; otherwise fall back to `score_first`
- `bounded_score_l1`: within `best_score_seen + score_slack`, rank by `(l1_error, nonzero_defect_count, max_abs_error, score)`; otherwise fall back to `score_first`
- `novelty_soft_l1`: with `--cluster-aware`, rank by the soft score objective minus `novelty_weight * dist_l1_to_cluster0`
- `novelty_score_first`: with `--cluster-aware`, rank by `score - novelty_weight * dist_l1_to_cluster0`
- `capped_novelty_soft_l1`: apply the novelty bonus only when `score`, `l1_error`, and `max_abs_error` are within configured caps; otherwise add a cap-violation penalty
- `capped_novelty_score_first`: keep score/l1/max_abs primary, and use cluster distance as a tie-break only inside the novelty caps

The soft schedules are controlled by `--soft-alpha`, `--soft-beta`, and
`--soft-gamma`. The bounded schedules are controlled by `--score-slack`.
The cluster-aware schedules require `--cluster-aware` and
`--cluster-medoids-json`. Capped novelty is additionally controlled by
`--novelty-score-cap`, `--novelty-l1-cap`, `--novelty-maxabs-cap`, and
`--cap-violation-penalty`. These schedules are heuristic basin-generation
tools only; they do not change the SDS or Hadamard success criteria.

Bucketed canonical frontiers keep their named primary metric order, and use
the active `objective_tuple` as a tie-break. Include `objective` in `--bucket`
to retain an additional bucket ranked directly by the active objective.

Short objective-schedule A/B run with actual plateau escapes:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/07_guided_sds_search_668.sage \
  --ks 73,78,79,81 \
  --lam 144 \
  --steps 30000 \
  --seed 101 \
  --strategy mixed \
  --objective-schedule nonzero_first \
  --targeted-prob 0.3 \
  --plateau-escape \
  --shake-rate 0.08 \
  --restart-patience 5000
```

Soft/bounded objective A/B examples:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/07_guided_sds_search_668.sage \
  --ks 73,78,79,81 \
  --lam 144 \
  --steps 30000 \
  --seed 101 \
  --strategy mixed \
  --objective-schedule soft_nonzero \
  --soft-alpha 0.1 \
  --soft-beta 0.5 \
  --soft-gamma 2.0 \
  --targeted-prob 0.3 \
  --plateau-escape \
  --shake-rate 0.08 \
  --restart-patience 5000

DOT_SAGE=/private/tmp/sage-dot sage sage/07_guided_sds_search_668.sage \
  --ks 73,76,83,83 \
  --lam 148 \
  --steps 30000 \
  --seed 101 \
  --strategy mixed \
  --objective-schedule bounded_score_nonzero \
  --score-slack 60 \
  --targeted-prob 0.3 \
  --plateau-escape \
  --shake-rate 0.08 \
  --restart-patience 5000
```

Cluster-aware capped novelty example:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/07_guided_sds_search_668.sage \
  --ks 73,78,79,81 \
  --lam 144 \
  --steps 30000 \
  --seed 202 \
  --strategy mixed \
  --objective-schedule capped_novelty_soft_l1 \
  --targeted-prob 0.3 \
  --plateau-escape \
  --shake-rate 0.08 \
  --restart-patience 5000 \
  --soft-alpha 0.1 \
  --soft-beta 0.5 \
  --soft-gamma 2.0 \
  --cluster-aware \
  --cluster-medoids-json outputs/explorations/20260505_1457_hadamard668_defect_cluster_lns/raw/defect_cluster_analysis.json \
  --avoid-cluster-id 0 \
  --novelty-weight 0.01 \
  --novelty-score-cap 240 \
  --novelty-l1-cap 140 \
  --novelty-maxabs-cap 3 \
  --cap-violation-penalty 10000 \
  --canonical-dedup \
  --save-top-k-per-bucket 30 \
  --bucket score,l1,nonzero,max_abs,objective,novelty,cluster_distance \
  --frontier-out outputs/candidates/near_hits/frontier/capped_novelty_example.json
```

The `novelty` and `cluster_distance` buckets prioritize candidates within
the novelty caps first, then rank by distance from the avoided cluster. This
prevents raw novelty from retaining only far-away but high-score diagnostic
states.

To resume from a saved candidate or near-hit:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/07_guided_sds_search_668.sage \
  --resume-json outputs/candidates/near_hits/near_hit_v167_score556_seed1_step925.json \
  --steps 1000000 \
  --seed 2
```

The resume JSON must match the active `v`, `ks`, and `lambda`. The script also
checks duplicate elements, range errors, and block sizes before continuing.

### `sage/08_analyze_sds_candidate.sage`

Analyzes a saved success candidate or near-hit JSON:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/08_analyze_sds_candidate.sage \
  outputs/candidates/near_hits/near_hit_v167_score123_seed7_step456789.json
```

The analysis recomputes the score from the blocks and prints worst shifts,
difference-count histograms, per-block difference summaries, densities,
duplicate/range checks, and overrepresented/underrepresented shifts.

### `sage/09_summarize_search_logs.py`

Summarizes search CSV logs from `07` and `10` so parameter candidates can be
compared without reading long log files:

```bash
python3 sage/09_summarize_search_logs.py
```

The main table is sorted by best `(score, l1_error, max_abs_error)` and includes:

```text
ks, lambda, seeds, total_steps, best_score, best_l1, best_max_abs_error, best_file
```

Optional output files:

```bash
python3 sage/09_summarize_search_logs.py \
  --out-json outputs/logs/search_summary.json \
  --out-csv outputs/logs/search_summary_by_seed.csv \
  --out-param-csv outputs/logs/search_summary_by_param.csv
```

### `sage/10_skew_sds_search_668.sage`

Runs a separate skew-constrained search. For each constrained `k = 83` block,
the block contains exactly one element from every pair `{x, -x}` in `Z_167`.
This may miss general SDS solutions, so it is a separate branch of the search,
not a replacement for `07`.

Default target:

```text
k = (73, 76, 83, 83), lambda = 148
```

The second target is:

```text
k = (74, 76, 79, 83), lambda = 145
```

Examples:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/10_skew_sds_search_668.sage \
  --steps 1000000 \
  --seed-start 1 \
  --seed-end 20

DOT_SAGE=/private/tmp/sage-dot sage sage/10_skew_sds_search_668.sage \
  --target one83 \
  --skew-blocks 3 \
  --steps 1000000 \
  --seed-start 1 \
  --seed-end 20
```

As with the unconstrained search, a skew near-hit is not a solution. A success
candidate is recorded only after SDS verification and exact integer
`HH^T = 668I` verification both pass.

### `sage/11_steepest_swap_descent.sage`

Performs complete steepest descent in the full 1-swap neighborhood of a saved
candidate or near-hit. Each round evaluates every move of the form `a in B_i`
removed and `b not in B_i` inserted, adopts the best lexicographic improvement,
and stops when no improving 1-swap exists.

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/11_steepest_swap_descent.sage \
  outputs/candidates/near_hits/near_hit_v167_score168_seed4_step36303.json
```

The repair history is written to `outputs/logs/11_steepest_swap_descent_*.csv`.
Improved near-hits are saved under `outputs/candidates/near_hits/`. If score
`0` is reached, the script runs the same exact SDS and Goethals-Seidel
Hadamard verification before writing a success candidate.

### `sage/12_beam_two_swap_repair.sage`

Performs a bounded 2-swap repair search. It first evaluates all 1-swaps,
keeps the best `--beam-width` moves, and evaluates ordered two-swap
combinations from that beam. This is intended for states that are already
1-swap local optima.

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/12_beam_two_swap_repair.sage \
  outputs/candidates/near_hits/<repaired-near-hit>.json \
  --beam-width 200 \
  --rounds 50
```

As with every other script, a 2-swap repair near-hit is not a solution.
Success requires exact SDS verification and exact integer `HH^T = 668I`.

### `sage/13_ilp_repair_from_near_hit.sage`

Builds a defect-driven move pool around a saved near-hit, then solves a small
0-1 ILP that selects a compatible set of swaps. The ILP minimizes a linear
repair objective over the current defect vector instead of searching the full
SDS space.

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/13_ilp_repair_from_near_hit.sage \
  outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json \
  --pool-size 400 \
  --pool-mode mixed \
  --max-moves 6 \
  --rounds 3 \
  --objective score_then_l1 \
  --time-limit 120
```

The move pool ranks swaps using defect alignment, absolute defect repair,
side-effect damage, repair of worst shifts, `d/-d` pair repair, and optional
zero-defect protection. Pool modes are `score`, `l1`, `max_abs`, `worst_shift`,
`zero_protect`, `low_nonzero`, `mixed`, and `diverse`. `mixed` combines score,
l1, max-abs, worst-over, worst-under, pair, alignment, zero-protect, and
low-nonzero categories. `diverse` adds random and per-block diversity.
Accepted ILP near-hit JSON files include `selected_moves`, recording the block
index, removed element, and added element for each chosen swap. These moves can
be used by later repair stages as tabu context.

The ILP enforces that selected swaps are compatible within each block, then
minimizes `score`, `score_then_l1`, `l1`, `max_then_l1`, or
`score_zero_protect`. The score objectives encode the small integer residual
values directly, so they optimize `sum residual^2` as an ILP over the local
move pool. `score_zero_protect` adds a `--zero-protect-weight` penalty for
turning currently correct shifts into nonzero defects. Any improved state is
saved as a near-hit. If score `0` is reached, the same exact SDS and
Goethals-Seidel verification is run before a success candidate is written.

For active-defect LNS diagnostics, use `--dry-run-pool-stats` before solving a
large model. It builds the move pool, applies `--active-top-k-shifts` and
`--greedy-prefilter`, writes JSON/Markdown pool statistics under
`outputs/logs`, and prints the estimated variable and constraint counts. Use
`--hard-time-limit` as a Python-side guard when the solver backend does not
honor `--time-limit`.

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/13_ilp_repair_from_near_hit.sage \
  outputs/candidates/near_hits/near_hit_v167_score176_seed101_step8576.json \
  --pool-mode active_defect_lns \
  --active-defects nonzero \
  --active-top-k-shifts 20 \
  --swap-pool 3000 \
  --max-swaps 6 \
  --objective l1_then_nonzero \
  --greedy-prefilter 300 \
  --time-limit 120 \
  --hard-time-limit 180 \
  --dry-run-pool-stats \
  --canonical-dedup
```

`l1_then_nonzero` is the preferred active-defect objective for bounded repair
experiments. `nonzero_then_l1` is available, but it is experimental and heavy;
use it only after a small dry run confirms the model size is acceptable.

When the ILP keeps selecting the zero-move solution, use force-move diagnostic
mode to leave the current basin under explicit damage limits. These outputs are
still near-hits, not success candidates. They are meant to be followed by
`11_steepest_swap_descent.sage` and `12_beam_two_swap_repair.sage`.

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/13_ilp_repair_from_near_hit.sage \
  outputs/candidates/near_hits/near_hit_v167_score176_seed101_step8576.json \
  --pool-mode active_defect_lns \
  --active-defects nonzero \
  --active-top-k-shifts 20 \
  --swap-pool 3000 \
  --max-swaps 2 \
  --min-moves 1 \
  --force-moves \
  --diagnostic-objective move_balanced \
  --greedy-prefilter 100 \
  --score-worsen-limit 40 \
  --l1-worsen-limit 20 \
  --maxabs-limit 4 \
  --time-limit 60 \
  --hard-time-limit 90 \
  --canonical-dedup
```

Diagnostic objectives are `move_l1_repair`, `move_nonzero_repair`,
`move_balanced`, and `move_escape`. Forced outputs record `force_moves`,
`min_moves`, `diagnostic_objective`, the damage limits, `selected_moves`, and
whether the result passed the configured worsen-limit checks.

For the low-nonzero branch:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/13_ilp_repair_from_near_hit.sage \
  outputs/candidates/near_hits/near_hit_v167_score184_ilp_repair_from_near_hit_round1_4.json \
  --pool-size 120 \
  --pool-mode zero_protect \
  --max-moves 5 \
  --rounds 1 \
  --objective score_zero_protect \
  --acceptance lex \
  --zero-protect-weight 100000
```

Near-hits can also be tracked as a Pareto frontier under
`(score, l1_error, max_abs_error, nonzero_defect_count)`:

```text
outputs/candidates/near_hits/frontier/frontier_index.json
```

The frontier is maintained per `(v, n, ks, lambda)`. Dominated entries are
removed from the frontier index, but the original near-hit JSON files are kept
as experiment logs.

### `sage/14_frontier_repair_batch.sage`

Runs a frontier-driven repair batch over the active Pareto near-hits. Each
loop applies `13_ilp_repair_from_near_hit.sage`, then runs 1-swap steepest
repair and bounded beam repair only when the ILP produces a changed state. The
frontier index is updated after each final near-hit.

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/14_frontier_repair_batch.sage \
  --loops 10 \
  --pool-size 40 \
  --pool-mode diverse \
  --max-moves 4 \
  --objective-plan score_then_l1:lex,l1:l1_then_score,max_then_l1:max_then_score \
  --residual-bound 8 \
  --beam-width 80 \
  --beam-depth 2 \
  --beam-rounds 1 \
  --steepest-max-rounds 10 \
  --extra-json outputs/candidates/near_hits/near_hit_v167_score172_seed6_step33709.json
```

To prevent an ILP move from being immediately reversed by local descent, pass
the ILP output JSON as a tabu source to the post-ILP repair stages:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/14_frontier_repair_batch.sage \
  --loops 5 \
  --pool-size 80 \
  --pool-mode diverse \
  --max-moves 5 \
  --objective-plan score_then_l1:lex,l1:l1_then_score,max_then_l1:max_then_score \
  --residual-bound 8 \
  --beam-width 120 \
  --beam-depth 2 \
  --beam-rank-mode score \
  --beam-rounds 2 \
  --steepest-max-rounds 10 \
  --post-ilp-order beam_then_steepest \
  --tabu-after-ilp \
  --no-reversal \
  --tabu-tenure 3
```

`--post-ilp-order beam_then_steepest` delays steepest descent until after beam
repair. `--tabu-after-ilp --no-reversal` forbids the exact reverse of each ILP
selected move during the configured `--tabu-tenure`. The optional
`--beam-depth 3` mode evaluates ordered 3-swap combinations from the beam
pool; keep the beam width small at first.

Low-nonzero branches can be prioritized directly:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/14_frontier_repair_batch.sage \
  --loops 5 \
  --pool-size 80 \
  --pool-mode zero_protect \
  --max-moves 5 \
  --objective-plan score_zero_protect:lex,l1:l1_then_score \
  --zero-protect-weight 100000 \
  --beam-width 80 \
  --beam-depth 3 \
  --beam-rank-mode zero_protect \
  --frontier-select best_nonzero \
  --post-ilp-order beam_then_steepest \
  --tabu-after-ilp \
  --no-reversal
```

This batch driver is for managing basins and near-hit repair experiments. It
does not change the success criterion: score `0` must still pass exact SDS
verification and exact integer Goethals-Seidel verification before being saved
as a success candidate.

### `sage/15_one_block_autocorrelation_completion_167.sage`

Experimental Constantine-route prototype for the `v=167`,
`ks=(76,76,77,80)`, `lambda=142` parameter set. It changes the search geometry:
three blocks are fixed and only one block, by default the size-80 block, is
searched as an autocorrelation completion problem. This is a heuristic
near-hit generator, not a proof of the Constantine construction.

Basic random fixed-block smoke:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/15_one_block_autocorrelation_completion_167.sage \
  --v 167 \
  --ks 76,76,77,80 \
  --lam 142 \
  --steps 1000 \
  --seed 1
```

Use an existing JSON with matching `v`, `ks`, and `lambda` to fix three blocks
and replace the completion block by a random size-80 block:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/15_one_block_autocorrelation_completion_167.sage \
  --from-json outputs/candidates/near_hits/example_76_76_77_80.json \
  --complete-index 3 \
  --steps 30000 \
  --seed 1 \
  --plateau-escape \
  --restart-patience 5000
```

Pass `--use-json-completion` to start from the JSON completion block instead of
randomizing it. By default, blocks are independently translated to contain `0`,
and `0` is kept fixed in the completion block; this removes translation
redundancy without changing difference counts. If score `0` is reached, the
script uses the same exact SDS verification and exact integer Goethals-Seidel
verification before saving a success candidate.

### `sage/20_defect_vector_analysis.py`

Analyzes saved near-hit JSON files as defect vectors. This is a diagnostic
tool for deciding which basins and repair routes deserve more compute; it is
not a success verifier.

```bash
python3 sage/20_defect_vector_analysis.py \
  --near-hit-glob "outputs/candidates/near_hits/**/*.json" \
  --out-dir outputs/explorations/$(date +%Y%m%d_%H%M)_hadamard668_defect_cluster_lns
```

The script recomputes metrics from the blocks, extracts `r[d] = count[d] -
lambda`, builds metric correlations, Pareto frontiers, canonical-basin
summaries, simple defect-vector clusters, and repair-transition diagnostics.

### `sage/21_partial_membership_lns_repair.sage`

Experimental bounded active-defect LNS prototype. It opens a small remove/add
membership neighborhood around a near-hit, optimizes active defect L1 on a
small set of bad shifts, then exactly recomputes the resulting SDS metrics and
rejects outputs that violate score/max_abs/zero-damage bounds.

Dry-run model sizing:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/21_partial_membership_lns_repair.sage \
  outputs/candidates/near_hits/near_hit_v167_score176_seed101_step8576.json \
  --active-top-k-shifts 20 \
  --free-per-block 8 \
  --max-remove-per-block 3 \
  --max-add-per-block 3 \
  --score-slack 40 \
  --maxabs-bound 4 \
  --zero-damage-bound 40 \
  --objective active_l1 \
  --dry-run-model-stats
```

Solve the same bounded prototype:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/21_partial_membership_lns_repair.sage \
  outputs/candidates/near_hits/near_hit_v167_score176_seed101_step8576.json \
  --active-top-k-shifts 20 \
  --free-per-block 8 \
  --max-remove-per-block 3 \
  --max-add-per-block 3 \
  --score-slack 40 \
  --maxabs-bound 4 \
  --zero-damage-bound 40 \
  --objective active_l1 \
  --time-limit 120 \
  --hard-time-limit 180
```

The LNS model uses a linearized remove/add approximation, so every output is
post-validated by exact difference-count recomputation. A bounded LNS near-hit
is not a solution. If score `0` is reached, the script still requires exact
SDS verification and exact integer Goethals-Seidel verification before saving
a success candidate.

### Pair Profile / Correlation-First Route

The next route treats two-block autocorrelation profiles as first-class search
objects. For a block `B`, define

```text
A_B[d] = #{(x,y) in B x B : x != y and x-y=d mod 167}
```

For a split such as `[73,78] + [79,81]`, the matcher searches for pair
profiles `P_left` and `P_right` such that

```text
P_left[d] + P_right[d] = lambda
```

for every nonzero shift. This is a diagnostic and generation route; it does
not change the final success condition.

Extract pair profiles from existing near-hits:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/22_pair_profile_dataset.sage \
  --ks 73,78,79,81 \
  --lam 144 \
  --split 0,1:2,3 \
  --near-hit-glob "outputs/candidates/near_hits/**/*.json" \
  --out outputs/pair_profiles/dataset_73_78_79_81.json
```

Generate random two-block profile datasets:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/23_pair_profile_generator.sage \
  --v 167 \
  --sizes 73,78 \
  --samples 50000 \
  --seed 1 \
  --out outputs/pair_profiles/pairs_73_78_seed1.json

DOT_SAGE=/private/tmp/sage-dot sage sage/23_pair_profile_generator.sage \
  --v 167 \
  --sizes 79,81 \
  --samples 50000 \
  --seed 2 \
  --out outputs/pair_profiles/pairs_79_81_seed2.json
```

Generate pair profiles against a fixed residual target from the extracted
dataset. This ranks candidates by complement error instead of by standalone
flatness:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/23_pair_profile_generator.sage \
  --v 167 \
  --sizes 79,81 \
  --samples 50000 \
  --seed 3 \
  --rank-mode complement_l2 \
  --target-profile outputs/pair_profiles/dataset_73_78_79_81.json \
  --target-entry-index 0 \
  --target-key left_residual_target \
  --keep-top 5000 \
  --out outputs/pair_profiles/targeted_pairs_79_81_entry0_seed3.json
```

Fix one side of an existing near-hit and randomly complete the opposite side
by matching the residual pair profile:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/25_pair_profile_target_completion.sage \
  outputs/candidates/near_hits/frontier/near_hit_v167_score164_ilp_repair_from_near_hit_round1.json \
  --split 0,1:2,3 \
  --fixed-side left \
  --samples 50000 \
  --seed 31 \
  --keep-top 100 \
  --save-candidates 20 \
  --objective balanced \
  --out outputs/candidates/pair_target_completion_score164_left_fixed_seed31_50k.json
```

Search the opposite pair by local swaps against the fixed pair residual. This
keeps one two-block side from the input near-hit and directly minimizes
`generated_pair_profile - (lambda - fixed_pair_profile)`:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/26_pair_profile_target_search.sage \
  outputs/candidates/near_hits/frontier/near_hit_v167_score164_ilp_repair_from_near_hit_round1.json \
  --split 0,1:2,3 \
  --fixed-side left \
  --init input \
  --steps 100000 \
  --seed 51 \
  --candidate-trials 64 \
  --objective balanced \
  --strategy mixed \
  --temperature 20 \
  --plateau-escape \
  --restart-patience 10000 \
  --shake-rate 0.04 \
  --out-prefix outputs/candidates/near_hits/pair_target_search_score164_left
```

This is still a heuristic near-hit generator. It only saves a success
candidate if score `0` is followed by exact SDS verification and exact integer
Goethals-Seidel verification.

Alternate the two residual-pair searches as a coordinate descent:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/27_pair_profile_coordinate_descent.sage \
  outputs/candidates/near_hits/frontier/near_hit_v167_score164_ilp_repair_from_near_hit_round1.json \
  --split 0,1:2,3 \
  --rounds 5 \
  --steps-per-phase 10000 \
  --seed 71 \
  --candidate-trials 64 \
  --objective balanced \
  --strategy mixed \
  --temperature 20 \
  --plateau-escape \
  --restart-patience 3000 \
  --shake-rate 0.04 \
  --out-prefix outputs/candidates/near_hits/pair_coordinate_score164
```

This runs `left fixed -> right optimized`, then `right fixed -> left
optimized`, and repeats. Each phase is evaluated by exact four-block
difference counts before a near-hit is saved.

### Fourier Defect Route

The Fourier route treats the exact defect vector
`r[d] = count[d] - lambda` as a signal on `Z_167`. Fourier values are used only
as heuristic diagnostics and move-ranking scores. They are not used for final
Hadamard verification.

Analyze the dominant defect modes of a near-hit:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/28_fourier_defect_analysis.sage \
  outputs/candidates/near_hits/frontier/near_hit_v167_score164_ilp_repair_from_near_hit_round1.json \
  --top-modes 24 \
  --out outputs/fourier/score164_fourier_defect.json
```

Run a Fourier-targeted swap search. The script samples swap candidates,
scores them by their effect on the current dominant Fourier modes, then
recomputes exact integer difference-count metrics before saving any near-hit:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/29_fourier_targeted_search.sage \
  outputs/candidates/near_hits/frontier/near_hit_v167_score164_ilp_repair_from_near_hit_round1.json \
  --steps 30000 \
  --seed 81 \
  --top-modes 12 \
  --mode-refresh 5000 \
  --candidate-trials 64 \
  --objective fourier_then_score \
  --strategy mixed \
  --temperature 20 \
  --plateau-escape \
  --restart-patience 10000 \
  --shake-rate 0.04 \
  --out-prefix outputs/candidates/near_hits/fourier_score164
```

The raw `fourier_then_score` objective is diagnostic and can push the exact
defect score upward while reducing only the selected Fourier modes. To use
Fourier information as a bounded escape direction, keep the exact score inside a
cap and disperse energy across the selected modes instead:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/29_fourier_targeted_search.sage \
  outputs/candidates/near_hits/near_hit_v167_score176_seed101_step8576.json \
  --steps 5000 \
  --seed 92 \
  --top-modes 12 \
  --mode-refresh 1000 \
  --candidate-trials 32 \
  --objective score_capped_dispersion \
  --score-cap 220 \
  --l1-cap 140 \
  --maxabs-cap 4 \
  --cap-violation-penalty 100000 \
  --strategy mixed \
  --temperature 20 \
  --plateau-escape \
  --restart-patience 2000 \
  --shake-rate 0.04 \
  --out-prefix outputs/candidates/near_hits/fourier_capped_score176
```

`score_capped_dispersion` ranks cap-satisfying moves by the largest selected
mode energy and the selected-mode HHI, so it favors spreading defect energy
instead of moving it into a single dominant Fourier mode. The exact score, L1,
max-absolute defect, and nonzero-defect counts are still recomputed from integer
difference counts for every saved candidate.

If score `0` appears, the same exact SDS verification and exact integer
Goethals-Seidel verification are required before a success candidate is saved.

### Turyn 428-to-668 Route

The Kharaghani--Tayfeh-Rezaie order-428 construction uses Turyn type sequences
of lengths `36,36,36,35`. The direct order-668 analogue would use Turyn type
sequences of lengths `56,56,56,55`, since:

```text
4 * (3*36 - 1) = 428
4 * (3*56 - 1) = 668
```

Verify Turyn type sequences, convert them to base/T-sequences, and, if they are
exact, build the Goethals-Seidel Hadamard candidate:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/30_turyn_type_sequences.sage \
  --turyn-json outputs/turyn/example_turyn56.json
```

List the sum-square candidates for the 668 analogue:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/30_turyn_type_sequences.sage \
  --n 56 \
  --sum-candidates \
  --out outputs/turyn/turyn56_sum_candidates.json
```

Run a small diagnostic comparing the 428 and 668 Turyn pruning landscape:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/31_turyn56_search_prototype.sage \
  --n 56 \
  --samples 200 \
  --grid 100 \
  --seed 1 \
  --max-tuples 8 \
  --include-n36-comparison \
  --out outputs/turyn/turyn56_vs_36_pruning_smoke.json
```

Generate Hall-pruned `Z/W` endpoint buckets and compare the direct 668 analogue
with the 428 case:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/32_turyn_endpoint_bucket_generator.sage \
  --n 56 \
  --samples 3000 \
  --grid 100 \
  --seed 4 \
  --tuple 0,-18,-2,1 \
  --endpoint-width 6 \
  --max-keep 1000 \
  --max-pair-checks 200000 \
  --out outputs/turyn/turyn56_endpoint_buckets_tuple_0_m18_m2_1_3k.json \
  --summary-md outputs/turyn/turyn56_endpoint_buckets_tuple_0_m18_m2_1_3k.md
```

Anneal a `Z/W` pair directly against the Hall pair bound:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/33_hall_pair_bucket_annealer.sage \
  --n 56 \
  --tuple 0,-18,-2,1 \
  --steps 5000 \
  --seed 2 \
  --grid 100 \
  --candidate-trials 32 \
  --objective excess_then_pair_max \
  --strategy anneal \
  --temperature 5 \
  --restart-patience 1500 \
  --shake-rate 0.05 \
  --out-prefix outputs/turyn/hall_pair_anneal_n56_tuple_0_m18_m2_1
```

The annealer also supports worst-theta targeted moves. This keeps the target
row sums fixed while biasing candidate flips toward the Fourier grid points
where `f_Z(theta) + f_W(theta)` is currently largest:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/33_hall_pair_bucket_annealer.sage \
  --n 56 \
  --tuple 0,-18,-2,1 \
  --steps 8000 \
  --seed 3 \
  --grid 100 \
  --candidate-trials 32 \
  --objective pair_max \
  --strategy anneal \
  --temperature 5 \
  --restart-patience 2000 \
  --shake-rate 0.05 \
  --move-mode mixed \
  --targeted-prob 0.8 \
  --worst-theta-k 4 \
  --position-pool 24 \
  --out-prefix outputs/turyn/hall_pair_targeted_n56_tuple_0_m18_m2_1
```

Current targeted smoke results:

```text
n=36, tuple [-14,-4,0,-1], bound 107:
  best pair_max = 102.024943, pass true

n=56, tuple [0,-18,-2,1], bound 167:
  best pair_max = 168.112698, pass false
```

Run short basin probes before spending longer runs on a seed:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/34_hall_pair_basin_probe.sage \
  --n 56 \
  --tuple 0,-18,-2,1 \
  --seed-start 1 \
  --seed-end 100 \
  --probe-steps 1000 \
  --checkpoints 100,300,500,1000 \
  --grid 100 \
  --candidate-trials 16 \
  --search-objective pair_max \
  --strategy anneal \
  --temperature 5 \
  --restart-patience 700 \
  --shake-rate 0.05 \
  --move-mode mixed \
  --targeted-prob 0.8 \
  --worst-theta-k 4 \
  --position-pool 24 \
  --promote-top-k 10 \
  --promote-steps 16000 \
  --out-dir outputs/turyn/basin_probe_n56
```

The probe writes a ranked CSV/JSON summary plus promotion commands. Promotion
commands resume from the saved probe-best `Z/W` state using
`--resume-pair-json`, instead of merely rerunning the same seed from scratch.

Small n=56 probe result, `seed=1..10`, `1000` probe steps:

```text
rank 1: seed 1, pair_max=168.392, excess=3.331, violations=3
rank 2: seed 2, pair_max=173.533, excess=13.182, violations=3
rank 3: seed 4, pair_max=171.463, excess=15.973, violations=6
```

Late-stage objectives can be used when a promoted state is already close to the
Hall bound:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/33_hall_pair_bucket_annealer.sage \
  --n 56 \
  --tuple 0,-18,-2,1 \
  --steps 8000 \
  --seed 203 \
  --grid 100 \
  --candidate-trials 64 \
  --objective excess_then_violations \
  --strategy greedy \
  --restart-patience 0 \
  --move-mode mixed \
  --targeted-prob 0.8 \
  --worst-theta-k 4 \
  --position-pool 24 \
  --resume-pair-json outputs/turyn/basin_probe_n56_seed1_10_1k/probe_best_rank1_seed1_pairmax168.392.json \
  --out-prefix outputs/turyn/hall_pair_late_excess_n56_probe_rank1
```

In the current smoke, the rank-1 promoted state stayed fixed at `pair_max =
168.392`, so that state appears one-swap hard under the current candidate
generator.

Run a coordinated single-spike repair on a close Hall-pair state:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/35_single_spike_hall_pair_repair.sage \
  outputs/turyn/hall_pair_targeted_n56_tuple_0_m18_m2_1_10x_seed6_seed6_step1049_pairmax168.305.json \
  --n 56 \
  --tuple 0,-18,-2,1 \
  --grid 100 \
  --objective pair_max \
  --rounds 1 \
  --target-theta 60 \
  --position-pool 0 \
  --flip-pool 2000 \
  --out-prefix outputs/turyn/single_spike_pairmax_seed6_exhaustive_1plus1
```

The current seed-6 state has one violating grid point, `theta=60`, with
`pair_max=168.304952`. Exhaustive coordinated `Z` one-flip plus `W` one-flip
evaluation checked `593487` candidate combinations and found no improving move.

Use a larger multi-flip beam neighborhood when the 1+1 neighborhood is hard:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/36_multi_flip_hall_pair_repair.sage \
  outputs/turyn/hall_pair_targeted_n56_tuple_0_m18_m2_1_10x_seed6_seed6_step1049_pairmax168.305.json \
  --n 56 \
  --tuple 0,-18,-2,1 \
  --grid 100 \
  --objective pair_max \
  --atomic-objective pair_max \
  --patterns ZZW,ZWW,ZZWW \
  --target-theta 60 \
  --position-pool 0 \
  --atomic-pool 250 \
  --beam-width 250 \
  --out-prefix outputs/turyn/multi_flip_pairmax_seed6_beam250
```

Current multi-flip sequence:

```text
seed6 start, grid=100:
  pair_max=168.304952

2+2 beam, grid=100:
  pair_max=167.360680

second repair, grid=100:
  pair_max=166.061693
  grid=100 pass

grid refinement exposed hidden spike:
  grid=250 pair_max=171.682385

two grid=250 repairs:
  pair_max=166.626516
  grid=250 pass

grid=500 repair:
  pair_max=166.841892

dense diagnostic:
  grid=50000 pair_max=166.882360524
  violations=0
```

This is still only a `Z/W` Hall-pair diagnostic. It is not a Turyn type sequence
and not a Hadamard 668 construction. The next stage is `X/Y` completion against
this repaired `Z/W` pair.

Run a fixed-`Z/W` `X/Y` completion search:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/37_fixed_zw_xy_completion.sage \
  outputs/turyn/multi_flip_pairmax_seed6_grid500_beam150_pairmax166.842.json \
  --n 56 \
  --tuple 0,-18,-2,1 \
  --steps 20000 \
  --seed 2 \
  --candidate-trials 64 \
  --objective score \
  --strategy anneal \
  --temperature 5 \
  --restart-patience 4000 \
  --shake-rate 0.05 \
  --move-mode mixed \
  --targeted-prob 0.7 \
  --position-pool 28 \
  --out-prefix outputs/turyn/fixed_zw_xy_completion_seed2_20k
```

Current fixed-`Z/W` `X/Y` smoke:

```text
initial:
  score=5248
  l1=400
  max_abs=26
  nonzero=50

20k run:
  best score=360
  l1=104
  max_abs=8
  nonzero=38
  Turyn OK: false
```

The current best has 17 exact zero shifts and 38 remaining bad shifts. It is a
near-hit for the fixed repaired `Z/W`, not a Turyn type sequence.

The next `X/Y` multi-flip repair stage is implemented in:

```text
sage/38_xy_multi_flip_completion_repair.sage
```

Starting from the score-360 fixed-`Z/W` completion, a score-first beam over
balanced multi-flips improved the current `X/Y` near-hit:

```text
score 360 -> 296:
  l1=104
  max_abs=6
  nonzero=43

score 296 -> 288:
  l1=92
  max_abs=6
  nonzero=35
```

The score-288 artifact is:

```text
outputs/turyn/xy_multi_flip_score296_worst7_beam220_score288.json
```

Exact verifier status:

```text
Turyn type OK: false
sum identity OK: 334 = 334
```

Single-flip continuation from score 288 and a second score/l1 multi-flip pass
did not improve this state. The current indication is that the repaired `Z/W`
pair is usable enough to make `X/Y` completion nontrivial but not easy; progress
comes from defect-targeted multi-flip neighborhoods, while ordinary single-flip
annealing quickly becomes stuck.

Diagnose the current `X/Y` near-hit in `P=X+Y`, `Q=X-Y` coordinates:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/39_pq_xy_completion_diagnostics.sage \
  outputs/turyn/xy_multi_flip_score296_worst7_beam220_score288.json \
  --n 56 \
  --tuple 0,-18,-2,1 \
  --top-shifts 20 \
  --pressure-shifts 12 \
  --top-positions 20 \
  --out-prefix outputs/turyn/pq_xy_score288_diagnostic
```

For the score-288 artifact, the P/Q transform checks passed exactly:

```text
P support=23, sum=-18
Q support=33, sum=18
P/Q disjoint support: true
N_P + N_Q = 2(N_X + N_Y): true
P/Q defect = 2 * X/Y defect: true
```

In this representation, only same-channel pairs contribute to autocorrelation;
cross-channel pairs are silent. The current bad shifts are therefore a channel
and sign-routing problem, not only a scalar score problem. The first diagnostic
report is:

```text
outputs/turyn/pq_xy_score288_diagnostic_score288.md
```

Run a P/Q-aware channel-routing repair beam:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/40_pq_channel_routing_repair.sage \
  outputs/turyn/xy_multi_flip_score296_worst7_beam220_score288.json \
  --n 56 \
  --tuple 0,-18,-2,1 \
  --objective capped_pq_target_then_score \
  --atomic-objective capped_pq_routing_then_score \
  --target-count 9 \
  --patterns XXY,XYY,XXYY,XYXY,XXXYY,XXYYY \
  --position-pool 0 \
  --atomic-pool 220 \
  --beam-width 220 \
  --score-slack 80 \
  --l1-slack 30 \
  --maxabs-bound 8 \
  --out-prefix outputs/turyn/pq_routing_score288_capped_beam220
```

Current P/Q routing observations:

```text
raw target objective:
  target_l1 40 -> 2
  score 288 -> 776

bounded target objective:
  target_l1 40 -> 12
  score 288 -> 296

strict score cap:
  no improvement

damage-aware net objective:
  target_gain 10..24
  non_target_l1_increase 18..40
  zero_shift_damage 8..20
  net_routing_gain < 0
  no improvement
```

So P/Q routing can move the defect mass very strongly, but a hard score-288 cap
still blocks improvement. The damage-aware objective confirms why raw
`target_l1` is unsafe: the target shifts improve, but the non-target and
previously-zero shifts absorb more defect than the target repair removes. This
is useful diagnostically: the next repair model should either use a wider
coordinated move that repairs target and non-target shifts together, or allow a
short bad-score excursion and then run a delayed repair.

Reverse feasibility diagnostics for fixed `Z/W` completion:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/41_turyn_completion_feasibility_diagnostics.sage \
  outputs/turyn/multi_flip_pairmax_seed6_grid500_beam150_pairmax166.842.json \
  --xy-json outputs/turyn/xy_multi_flip_score296_worst7_beam220_score288.json \
  --n 56 \
  --tuple 0,-18,-2,1 \
  --fourier-grid 5000 \
  --out-prefix outputs/turyn/feasibility_zw166842_xy288
```

This script works backward from necessary properties of any exact completion.
For the repaired `Z/W` pair:

```text
target profile:
  score=2044
  l1=258
  max_abs=18

sampled Fourier required profile:
  min_required=0.235278951436
  max_required=324
  mean_required=112
  negative samples=0
  small required samples <= 10: 92
```

For comparison, the pre-repair close Hall-pair state had:

```text
pair_max=168.304951685
min_required=-9.040949150703
negative samples=128
target score=2844
```

So the Z/W multi-flip repair did more than lower a Hall grid maximum: it moved
the fixed pair from sampled Fourier-infeasible to sampled Fourier-feasible and
made the target profile substantially flatter. The remaining problem is that
the repaired pair still asks X/Y to realize very small required Fourier energy
at some modes, which likely explains the hard completion basin.

The same reverse diagnostic was also run on the project-local `n=36` analogue
for order 428:

```text
outputs/turyn/feasibility_428_n36_pair102025_n36_grid5000.md
```

Comparison against the current repaired `n=56` pair:

```text
n=36 / order 428 analogue:
  target score=908
  target l1=150
  target max_abs=10
  target roughness=1360
  min_required=6.087676087
  small_required_count_10=44

n=56 / order 668 repaired Z/W:
  target score=2044
  target l1=258
  target max_abs=18
  target roughness=4144
  min_required=0.235278951
  small_required_count_10=92
```

The published Kharaghani--Tayfeh-Rezaie exact order-428 Turyn sequence was also
imported as a positive control:

```text
outputs/turyn/exact_428_kharaghani_tayfeh_rezaie.json
outputs/turyn/verify_exact_428_kharaghani_tayfeh_rezaie.json
outputs/turyn/feasibility_exact428_ktr_n36_grid5000.md
```

Local verification gives:

```text
Turyn type OK: true
T-sequences OK: true
generated order: 428
HH^T check: true
tuple: [0,6,8,5]
```

Reverse diagnostic comparison:

```text
published exact 428:
  target score=1004
  target l1=146
  target max_abs=14
  target roughness=1440
  min_required=4.474229069
  small_required_count_10=146
  supplied X/Y score=0

n=56 / order 668 repaired Z/W:
  target score=2044
  target l1=258
  target max_abs=18
  target roughness=4144
  min_required=0.235278951
  small_required_count_10=92
  supplied X/Y score=288
```

This changes the interpretation slightly. The exact 428 case is not easy merely
because its Z/W target score is tiny; its target score and max_abs are still
substantial, but the published X/Y support/sign pattern realizes the target
exactly. The current 668 near-hit asks X/Y to match a rougher profile and has a
sampled required Fourier minimum much closer to zero. So `small_required_count`
alone is not a reliable hardness metric; X/Y-completability of the discrete
P/Q support pattern is the more relevant bottleneck.

Detailed note:

```text
outputs/turyn/exact428_to_668_reverse_diagnostic.md
```

To turn this into an actionable objective, `42` scores a fixed `Z/W` pair by
cheap X/Y-completability proxies:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/42_zw_completion_proxy_diagnostics.sage \
  outputs/turyn/exact_428_kharaghani_tayfeh_rezaie.json \
  --n 36 \
  --tuple 0,6,8,5 \
  --fourier-grid 1000 \
  --support-limit 8 \
  --pq-relax-steps 300 \
  --pq-relax-restarts 2 \
  --pq-relax-candidate-trials 24 \
  --out-prefix outputs/turyn/proxy_exact428_ktr
```

The proxy combines Hall-pair excess, sampled required-Fourier margin, Z/W target
profile roughness, and a lightweight P/Q support/sign relaxation residual. If
an input contains supplied `X/Y`, the supplied P/Q residual is also reported and
used as the best-available positive-control residual. The proxy is a heuristic
basin-ranking tool only.

The Hall-pair annealer also accepts a cheap in-loop version:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/33_hall_pair_bucket_annealer.sage \
  --n 56 \
  --tuple 0,-18,-2,1 \
  --steps 50000 \
  --seed 1 \
  --grid 300 \
  --candidate-trials 32 \
  --objective completion_proxy \
  --move-mode mixed \
  --targeted-prob 0.7 \
  --out-prefix outputs/turyn/hall_pair_completion_proxy
```

The in-loop objective omits the expensive P/Q relaxation and uses Hall/Fourier
margin plus target-profile terms. Saved candidates include
`completion_proxy_metrics` and should be re-scored by `42` before attempting
fixed-`Z/W` X/Y completion.

Initial pilot results are summarized in:

```text
outputs/turyn/completion_proxy_objective_pilot.md
```

The first raw `completion_proxy` objective was too permissive: it could improve
target-profile terms while producing sampled negative required-Fourier energy.
The safer direction is Hall-gated or multi-flip proxy refinement from an already
Hall-feasible `Z/W` state.

The current boundary note is:

```text
outputs/turyn/turyn428_to_668_boundary.md
```

This route is exploratory. A Turyn near-hit or pruning diagnostic is not a
Hadamard construction. A success candidate still requires exact Turyn/T-sequence
checks and exact `HH^T = 668I` verification.

Match two profile datasets and save top four-block near-hits:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/24_pair_profile_match.sage \
  --left outputs/pair_profiles/pairs_73_78_seed1.json \
  --right outputs/pair_profiles/pairs_79_81_seed2.json \
  --lam 144 \
  --top-k 100 \
  --out outputs/candidates/pair_matched_73_78_79_81.json
```

`24_pair_profile_match.sage` prunes very large inputs by default to the best
`2000` profiles per side by pair-profile flatness before comparing them. Use
`--max-left 0 --max-right 0` only for deliberately small datasets or when the
full Cartesian comparison is intended. If a match reaches score `0`, it still
must pass exact SDS verification and exact integer Goethals-Seidel
verification before being written as a success candidate.

## Near-Hits vs Success Candidates

Near-hits are saved under `outputs/candidates/near_hits/` whenever the guided
search improves its best metric tuple. They are research artifacts, not
solutions. A near-hit JSON normally records:

```json
{
  "verify_sds": false,
  "generated_hadamard": false,
  "hh_t": false
}
```

A success candidate is saved under `outputs/candidates/` only when the search
reaches score `0`, then rechecks the SDS condition and verifies the exact
integer identity:

```text
H * H.transpose() == 668 * identity_matrix(ZZ, 668)
```

Until both SDS verification and `HH^T = 668I` pass, the artifact is only a
candidate or near-hit.

## p-adic Moment Basin Diagnostics

For a near-hit defect vector

```text
rho(d) = sum_i n_i(d) - lambda
```

an exact SDS over `Z_167` must satisfy the low-degree p-adic shadow

```text
sum_d rho(d) d^2 == 0 mod 167
sum_d rho(d) d^4 == 0 mod 167
sum_d rho(d) d^6 == 0 mod 167
```

These are necessary conditions, not success certificates. They are used to
classify basins: a low-score near-hit can still be a poor target if its
`T2/T4/T6` moment signature is nonzero.

Analyze all saved near-hits:

```bash
python3 sage/43_padic_moment_basin_diagnostics.py \
  --near-hit-glob "outputs/candidates/near_hits/**/*.json"
```

Guided search also records p-adic moment diagnostics in saved JSON and canonical
frontier records. To retain moment-aware buckets:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/07_guided_sds_search_668.sage \
  --ks 73,78,79,81 \
  --lam 144 \
  --steps 30000 \
  --seed 101 \
  --strategy mixed \
  --objective-schedule moment_score_cap \
  --moment-score-cap 220 \
  --canonical-dedup \
  --save-top-k-per-bucket 30 \
  --bucket score,l1,nonzero,max_abs,moment,moment_then_score \
  --frontier-out outputs/candidates/near_hits/frontier/moment_frontier_example.json
```

`moment_score_cap` keeps the usual score gate, then prioritizes candidates with
more zero low-degree moments. A moment-zero near-hit is still not a solution
unless exact SDS verification and exact Goethals-Seidel `HH^T = 668I`
verification pass.

### Moment-balanced multi-swap repair

`sage/44_moment_balanced_multiswap_repair.sage` is a diagnostic repair
prototype for the p-adic moment route. It does not continue ordinary local
descent. Instead, it builds a pool of one-swap moves, records each move's
`Delta T2/Delta T4/Delta T6`, then uses a small beam search to combine several
swaps so selected moments remain zero while target moments are driven toward
zero.

Example: start from a `T2=0` near-hit and try to keep `T2` locked while making
`T4` or `T6` zero:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/44_moment_balanced_multiswap_repair.sage \
  outputs/candidates/near_hits/near_hit_v167_score216_seed411_step63.json \
  --lock-powers 2 \
  --target-powers 4,6 \
  --score-cap 300 \
  --candidate-pool 300 \
  --prefilter 160 \
  --beam-width 120 \
  --max-moves 3 \
  --evaluate-top 80 \
  --rank-mode cap_first
```

Example: start from a `T2=T4=0` near-hit and try to make `T6=0`:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/44_moment_balanced_multiswap_repair.sage \
  outputs/candidates/near_hits/near_hit_v167_score284_moment_balanced_multiswap_repair_round2.json \
  --lock-powers 2,4 \
  --target-powers 6 \
  --score-cap 420 \
  --candidate-pool 420 \
  --prefilter 220 \
  --beam-width 180 \
  --max-moves 4 \
  --evaluate-top 100 \
  --rank-mode moment_first
```

The script may save near-hits with more p-adic moment zeros but worse
`score/l1/max_abs`. These are diagnostic artifacts. They are not success
candidates unless score reaches `0` and the explicit SDS and Goethals-Seidel
integer checks pass.

## Candidate JSON Shape

```json
{
  "v": 167,
  "n": 668,
  "ks": [71, 81, 82, 82],
  "lambda": 149,
  "blocks": [[...], [...], [...], [...]],
  "verify_sds": true,
  "generated_hadamard": true,
  "hh_t": true,
  "construction": "Goethals-Seidel",
  "seed": 1,
  "steps": 12345
}
```
