# Run Log

- exploration_id: `20260504_2133_hadamard668_low_nonzero_shallow_repair`
- started_at: `2026-05-04T21:33:19`
- cwd: `<repo-root>`
- sage_bin: `sage`
- DOT_SAGE: `${TMPDIR:-/tmp}/sage-dot`
- suite: `all`
- .sage.py cleanup: pending

## 01_weight_sweep_low_nonzero_w3000

```bash
sage sage/14_frontier_repair_batch.sage --loops 2 --pool-size 40 --pool-mode low_nonzero --max-moves 6 --objective-plan l1:l1_then_score,score_zero_protect:lex,score_then_l1:lex --zero-protect-weight 3000 --beam-width 30 --beam-depth 3 --beam-rank-mode mixed --beam-rounds 1 --steepest-max-rounds 3 --frontier-select mixed --post-ilp-order beam_then_steepest --tabu-after-ilp --no-reversal --tabu-tenure 3 --residual-bound 8 --frontier-dir outputs/explorations/20260504_2133_hadamard668_low_nonzero_shallow_repair/raw/frontiers/01_weight_sweep_low_nonzero_w3000 --max-candidates-per-loop 2
```

- returncode: `0`
- elapsed_sec: `67.39`
- csv: `outputs/logs/11_steepest_swap_descent_20260504_213426_pid37459.csv`
- log: `outputs/logs/11_steepest_swap_descent_20260504_213426_pid37459.log`

## 02_weight_sweep_low_nonzero_w1000

```bash
sage sage/14_frontier_repair_batch.sage --loops 2 --pool-size 40 --pool-mode low_nonzero --max-moves 6 --objective-plan l1:l1_then_score,score_zero_protect:lex,score_then_l1:lex --zero-protect-weight 1000 --beam-width 30 --beam-depth 3 --beam-rank-mode mixed --beam-rounds 1 --steepest-max-rounds 3 --frontier-select mixed --post-ilp-order beam_then_steepest --tabu-after-ilp --no-reversal --tabu-tenure 3 --residual-bound 8 --frontier-dir outputs/explorations/20260504_2133_hadamard668_low_nonzero_shallow_repair/raw/frontiers/02_weight_sweep_low_nonzero_w1000 --max-candidates-per-loop 2
```

- returncode: `0`
- elapsed_sec: `74.52`
- csv: `outputs/logs/11_steepest_swap_descent_20260504_213540_pid38895.csv`
- log: `outputs/logs/11_steepest_swap_descent_20260504_213540_pid38895.log`

## 03_weight_sweep_low_nonzero_w300

```bash
sage sage/14_frontier_repair_batch.sage --loops 2 --pool-size 40 --pool-mode low_nonzero --max-moves 6 --objective-plan l1:l1_then_score,score_zero_protect:lex,score_then_l1:lex --zero-protect-weight 300 --beam-width 30 --beam-depth 3 --beam-rank-mode mixed --beam-rounds 1 --steepest-max-rounds 3 --frontier-select mixed --post-ilp-order beam_then_steepest --tabu-after-ilp --no-reversal --tabu-tenure 3 --residual-bound 8 --frontier-dir outputs/explorations/20260504_2133_hadamard668_low_nonzero_shallow_repair/raw/frontiers/03_weight_sweep_low_nonzero_w300 --max-candidates-per-loop 2
```

- returncode: `0`
- elapsed_sec: `76.98`
- csv: `outputs/logs/11_steepest_swap_descent_20260504_213657_pid40342.csv`
- log: `outputs/logs/11_steepest_swap_descent_20260504_213657_pid40342.log`

## 04_weight_sweep_low_nonzero_w100

```bash
sage sage/14_frontier_repair_batch.sage --loops 2 --pool-size 40 --pool-mode low_nonzero --max-moves 6 --objective-plan l1:l1_then_score,score_zero_protect:lex,score_then_l1:lex --zero-protect-weight 100 --beam-width 30 --beam-depth 3 --beam-rank-mode mixed --beam-rounds 1 --steepest-max-rounds 3 --frontier-select mixed --post-ilp-order beam_then_steepest --tabu-after-ilp --no-reversal --tabu-tenure 3 --residual-bound 8 --frontier-dir outputs/explorations/20260504_2133_hadamard668_low_nonzero_shallow_repair/raw/frontiers/04_weight_sweep_low_nonzero_w100 --max-candidates-per-loop 2
```

- returncode: `0`
- elapsed_sec: `440.25`
- csv: `outputs/logs/11_steepest_swap_descent_20260504_214417_pid45205.csv`
- log: `outputs/logs/11_steepest_swap_descent_20260504_214417_pid45205.log`

## 05_weight_sweep_low_nonzero_w0

```bash
sage sage/14_frontier_repair_batch.sage --loops 2 --pool-size 40 --pool-mode low_nonzero --max-moves 6 --objective-plan l1:l1_then_score,score_zero_protect:lex,score_then_l1:lex --zero-protect-weight 0 --beam-width 30 --beam-depth 3 --beam-rank-mode mixed --beam-rounds 1 --steepest-max-rounds 3 --frontier-select mixed --post-ilp-order beam_then_steepest --tabu-after-ilp --no-reversal --tabu-tenure 3 --residual-bound 8 --frontier-dir outputs/explorations/20260504_2133_hadamard668_low_nonzero_shallow_repair/raw/frontiers/05_weight_sweep_low_nonzero_w0 --max-candidates-per-loop 2
```

- returncode: `0`
- elapsed_sec: `101.11`
- csv: `outputs/logs/11_steepest_swap_descent_20260504_214558_pid47231.csv`
- log: `outputs/logs/11_steepest_swap_descent_20260504_214558_pid47231.log`

## 06_pool_comparison_low_nonzero_w1000

```bash
sage sage/14_frontier_repair_batch.sage --loops 2 --pool-size 40 --pool-mode low_nonzero --max-moves 6 --objective-plan l1:l1_then_score,score_then_l1:lex --zero-protect-weight 1000 --beam-width 30 --beam-depth 3 --beam-rank-mode mixed --beam-rounds 1 --steepest-max-rounds 3 --frontier-select mixed --post-ilp-order beam_then_steepest --tabu-after-ilp --no-reversal --tabu-tenure 3 --residual-bound 8 --frontier-dir outputs/explorations/20260504_2133_hadamard668_low_nonzero_shallow_repair/raw/frontiers/06_pool_comparison_low_nonzero_w1000 --max-candidates-per-loop 2
```

- returncode: `0`
- elapsed_sec: `91.64`
- csv: `outputs/logs/11_steepest_swap_descent_20260504_214730_pid48879.csv`
- log: `outputs/logs/11_steepest_swap_descent_20260504_214730_pid48879.log`

## 07_pool_comparison_low_nonzero_w300

```bash
sage sage/14_frontier_repair_batch.sage --loops 2 --pool-size 40 --pool-mode low_nonzero --max-moves 6 --objective-plan l1:l1_then_score,score_then_l1:lex --zero-protect-weight 300 --beam-width 30 --beam-depth 3 --beam-rank-mode mixed --beam-rounds 1 --steepest-max-rounds 3 --frontier-select mixed --post-ilp-order beam_then_steepest --tabu-after-ilp --no-reversal --tabu-tenure 3 --residual-bound 8 --frontier-dir outputs/explorations/20260504_2133_hadamard668_low_nonzero_shallow_repair/raw/frontiers/07_pool_comparison_low_nonzero_w300 --max-candidates-per-loop 2
```

- returncode: `0`
- elapsed_sec: `97.74`
- csv: `outputs/logs/11_steepest_swap_descent_20260504_214908_pid50937.csv`
- log: `outputs/logs/11_steepest_swap_descent_20260504_214908_pid50937.log`

## 08_pool_comparison_low_nonzero_w100

```bash
sage sage/14_frontier_repair_batch.sage --loops 2 --pool-size 40 --pool-mode low_nonzero --max-moves 6 --objective-plan l1:l1_then_score,score_then_l1:lex --zero-protect-weight 100 --beam-width 30 --beam-depth 3 --beam-rank-mode mixed --beam-rounds 1 --steepest-max-rounds 3 --frontier-select mixed --post-ilp-order beam_then_steepest --tabu-after-ilp --no-reversal --tabu-tenure 3 --residual-bound 8 --frontier-dir outputs/explorations/20260504_2133_hadamard668_low_nonzero_shallow_repair/raw/frontiers/08_pool_comparison_low_nonzero_w100 --max-candidates-per-loop 2
```

- returncode: `0`
- elapsed_sec: `88.34`
- csv: `outputs/logs/11_steepest_swap_descent_20260504_215036_pid53317.csv`
- log: `outputs/logs/11_steepest_swap_descent_20260504_215036_pid53317.log`

## 09_pool_comparison_low_nonzero_w0

```bash
sage sage/14_frontier_repair_batch.sage --loops 2 --pool-size 40 --pool-mode low_nonzero --max-moves 6 --objective-plan l1:l1_then_score,score_then_l1:lex --zero-protect-weight 0 --beam-width 30 --beam-depth 3 --beam-rank-mode mixed --beam-rounds 1 --steepest-max-rounds 3 --frontier-select mixed --post-ilp-order beam_then_steepest --tabu-after-ilp --no-reversal --tabu-tenure 3 --residual-bound 8 --frontier-dir outputs/explorations/20260504_2133_hadamard668_low_nonzero_shallow_repair/raw/frontiers/09_pool_comparison_low_nonzero_w0 --max-candidates-per-loop 2
```

- returncode: `0`
- elapsed_sec: `109.22`
- csv: `outputs/logs/11_steepest_swap_descent_20260504_215225_pid57554.csv`
- log: `outputs/logs/11_steepest_swap_descent_20260504_215225_pid57554.log`

## 10_pool_comparison_mixed_w1000

```bash
sage sage/14_frontier_repair_batch.sage --loops 2 --pool-size 40 --pool-mode mixed --max-moves 6 --objective-plan l1:l1_then_score,score_then_l1:lex --zero-protect-weight 1000 --beam-width 30 --beam-depth 3 --beam-rank-mode mixed --beam-rounds 1 --steepest-max-rounds 3 --frontier-select mixed --post-ilp-order beam_then_steepest --tabu-after-ilp --no-reversal --tabu-tenure 3 --residual-bound 8 --frontier-dir outputs/explorations/20260504_2133_hadamard668_low_nonzero_shallow_repair/raw/frontiers/10_pool_comparison_mixed_w1000 --max-candidates-per-loop 2
```

- returncode: `0`
- elapsed_sec: `82.78`
- csv: `outputs/logs/11_steepest_swap_descent_20260504_215348_pid59036.csv`
- log: `outputs/logs/11_steepest_swap_descent_20260504_215348_pid59036.log`

## 11_pool_comparison_mixed_w300

```bash
sage sage/14_frontier_repair_batch.sage --loops 2 --pool-size 40 --pool-mode mixed --max-moves 6 --objective-plan l1:l1_then_score,score_then_l1:lex --zero-protect-weight 300 --beam-width 30 --beam-depth 3 --beam-rank-mode mixed --beam-rounds 1 --steepest-max-rounds 3 --frontier-select mixed --post-ilp-order beam_then_steepest --tabu-after-ilp --no-reversal --tabu-tenure 3 --residual-bound 8 --frontier-dir outputs/explorations/20260504_2133_hadamard668_low_nonzero_shallow_repair/raw/frontiers/11_pool_comparison_mixed_w300 --max-candidates-per-loop 2
```

- returncode: `0`
- elapsed_sec: `81.33`
- csv: `outputs/logs/11_steepest_swap_descent_20260504_215509_pid61055.csv`
- log: `outputs/logs/11_steepest_swap_descent_20260504_215509_pid61055.log`

## 12_pool_comparison_mixed_w100

```bash
sage sage/14_frontier_repair_batch.sage --loops 2 --pool-size 40 --pool-mode mixed --max-moves 6 --objective-plan l1:l1_then_score,score_then_l1:lex --zero-protect-weight 100 --beam-width 30 --beam-depth 3 --beam-rank-mode mixed --beam-rounds 1 --steepest-max-rounds 3 --frontier-select mixed --post-ilp-order beam_then_steepest --tabu-after-ilp --no-reversal --tabu-tenure 3 --residual-bound 8 --frontier-dir outputs/explorations/20260504_2133_hadamard668_low_nonzero_shallow_repair/raw/frontiers/12_pool_comparison_mixed_w100 --max-candidates-per-loop 2
```

