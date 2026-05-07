# Guided Long Run Config

```json
{
  "requested_full_command": "DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/07_guided_sds_search_668.sage --ks 73,76,83,83 --lam 148 --steps 1000000 --seed-start 101 --seed-end 150 --strategy mixed --targeted-prob 0.3 --plateau-escape --shake-rate 0.05 --restart-patience 50000 --canonical-dedup --save-top-k-per-bucket 50 --bucket score,l1,nonzero,max_abs,lex_score_l1,lex_nonzero_l1 --frontier-out outputs/candidates/near_hits/frontier/guided_frontier_73_76_83_83_long.json",
  "executed_slice_command": "DOT_SAGE=${TMPDIR:-/tmp}/sage-dot sage sage/07_guided_sds_search_668.sage --ks 73,76,83,83 --lam 148 --steps 20000 --seed 101 --strategy mixed --targeted-prob 0.3 --plateau-escape --shake-rate 0.05 --restart-patience 5000 --canonical-dedup --save-top-k-per-bucket 20 --bucket score,l1,nonzero,max_abs,lex_score_l1,lex_nonzero_l1 --frontier-out outputs/candidates/near_hits/frontier/guided_frontier_73_76_83_83_long_slice_seed101.json",
  "reason_full_not_completed": "Full canonical guided run is expected to be long-running; the executed slice took about 127 seconds for one seed and 20,000 steps."
}
```
