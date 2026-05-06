# Run Log

```json
{
  "generated_at": "2026-05-04T22:30:45",
  "commands": [
    "DOT_SAGE=/private/tmp/sage-dot sage sage/07_guided_sds_search_668.sage --ks 73,76,83,83 --lam 148 --steps 20000 --seed 101 --strategy mixed --targeted-prob 0.3 --plateau-escape --shake-rate 0.05 --restart-patience 5000 --canonical-dedup --save-top-k-per-bucket 20 --bucket score,l1,nonzero,max_abs,lex_score_l1,lex_nonzero_l1 --frontier-out outputs/candidates/near_hits/frontier/guided_frontier_73_76_83_83_long_slice_seed101.json"
  ],
  "logs": [
    "outputs/logs/07_guided_sds_search_668_20260504_222557_pid76815.csv"
  ],
  "notes": [
    "Regression and low-nonzero analysis were run before the guided slice."
  ]
}
```
