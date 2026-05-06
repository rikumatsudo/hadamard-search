# Active-Defect Repair Plan

```json
{
  "status": "implemented entry points, not yet used as a success claim",
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
  "success_condition": "still requires score=0, SDS OK, and Goethals-Seidel HH^T=668I over ZZ"
}
```
