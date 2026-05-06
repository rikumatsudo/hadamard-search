# Run Log

Generated at `2026-05-04T22:15:36` by `18_canonical_frontier_report.sage`.

Additional commands executed:

```bash
DOT_SAGE=/private/tmp/sage-dot sage sage/18_canonical_frontier_report.sage --outdir outputs/explorations/20260504_2208_hadamard668_canonical_new_basin_generation --guided-frontier outputs/candidates/near_hits/frontier/guided_frontier_73_76_83_83_smoke.json --near-hit outputs/candidates/near_hits/near_hit_v167_score184_ilp_repair_from_near_hit_round1_4.json --near-hit outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json
DOT_SAGE=/private/tmp/sage-dot sage sage/13_ilp_repair_from_near_hit.sage outputs/candidates/near_hits/near_hit_v167_score220_seed102_step3725.json --pool-mode active_defect_lns --swap-pool 120 --max-swaps 4 --rounds 1 --objective l1_then_nonzero --acceptance l1_then_nonzero --time-limit 120 --canonical-dedup
```

Generated logs:

- `outputs/logs/13_ilp_repair_from_near_hit_20260504_221544_pid72620.log`
- `outputs/logs/13_ilp_repair_from_near_hit_20260504_221544_pid72620.csv`

Cleanup status: generated `.sage.py` files were removed.
