# Run Log

- exploration_id: `20260504_2114_hadamard668_low_nonzero_shallow_repair`
- started_at: `2026-05-04T21:14:56`
- cwd: `/Users/matsudouriku/Desktop/hadmard`
- sage_bin: `sage`
- DOT_SAGE: `/private/tmp/sage-dot`
- suite: `all`
- .sage.py cleanup: pending

## 01_weight_sweep_low_nonzero_w3000

```bash
sage sage/14_frontier_repair_batch.sage --loops 2 --pool-size 160 --pool-mode low_nonzero --max-moves 6 --objective-plan l1:l1_then_score,score_zero_protect:lex,score_then_l1:lex --zero-protect-weight 3000 --beam-width 80 --beam-depth 3 --beam-rank-mode mixed --beam-rounds 1 --steepest-max-rounds 3 --frontier-select mixed --post-ilp-order beam_then_steepest --tabu-after-ilp --no-reversal --tabu-tenure 3 --residual-bound 8 --frontier-dir outputs/explorations/20260504_2114_hadamard668_low_nonzero_shallow_repair/raw/frontiers/01_weight_sweep_low_nonzero_w3000 --max-candidates-per-loop 2
```

