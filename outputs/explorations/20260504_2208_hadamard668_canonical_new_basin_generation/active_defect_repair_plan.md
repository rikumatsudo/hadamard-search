# Active-Defect Repair Plan

```json
{
  "status": "implemented entry points and smoke-tested as diagnostic repair, not used as a success claim",
  "script": "sage/13_ilp_repair_from_near_hit.sage",
  "pool_mode": "active_defect_lns",
  "objectives": [
    "l1_then_nonzero",
    "nonzero_then_l1"
  ],
  "aliases": [
    "--swap-pool",
    "--max-swaps"
  ],
  "selection": "prioritize swaps affecting nonzero defects while recording zero-shift damage",
  "smoke_input": "outputs/candidates/near_hits/near_hit_v167_score220_seed102_step3725.json",
  "smoke_output": "outputs/candidates/near_hits/near_hit_v167_score192_ilp_repair_from_near_hit_round1_8.json",
  "smoke_before": {
    "score": 220,
    "l1_error": 140,
    "max_abs_error": 3,
    "nonzero_defect_count": 104
  },
  "smoke_after": {
    "score": 192,
    "l1_error": 124,
    "max_abs_error": 3,
    "nonzero_defect_count": 92,
    "selected_moves_count": 3,
    "pareto_active": false
  },
  "success_condition": "still requires score=0, SDS OK, and Goethals-Seidel HH^T=668I over ZZ"
}
```
