# p37 Exact-Derived vs Search-Derived Low-Score Comparison

This run compares controlled exact perturbations against existing search-derived low-score candidates. It is not a heavy search and not a Hadamard 668 construction run.

## Run

- p: `37`
- ks: `[13, 16, 18, 18]`
- lambda: `28`
- exact_json: `outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json`
- search-derived low-score count: `90`
- exact-derived low-score count: `23`
- score=0 only is success.

## Hypotheses

```json
{
  "H1_low_score_does_not_imply_exact_proximity": {
    "exact_derived_median_return_radius_proxy": 1.0,
    "search_median_return_radius_proxy": 29.0,
    "verdict": "supported"
  },
  "H2_exact_vs_search_low_score_feature_separation": {
    "strong_auc_features": [
      "D_min_ratio",
      "P_4",
      "P_8",
      "kappa_max",
      "kappa_q90",
      "kappa_q99",
      "Q_ratio",
      "return_radius_proxy"
    ],
    "verdict": "supported"
  },
  "H3_score4_pattern_one_basin_type_not_one": {
    "exact_derived_score4_present": false,
    "note": "If exact-derived score=4 is not sampled, basin-type multiplicity at score=4 remains inconclusive in this run.",
    "score4_patterns_one": true,
    "search_derived_score4_present": true,
    "verdict": "inconclusive"
  }
}
```

## Required Answers

1. exact-derived low-score candidates は何件得られたか: `23`.
2. search-derived low-score candidates は何件得られたか: `90`.
3. exact-derived score=4 は出たか: `0` 件。
4. search-derived score=4 と exact-derived score=4 は比較できたか: `no`。
5. score=4 defect pattern は理論通り +1 on +/-a, -1 on +/-b だったか: `True`; signatures `['+pairs1_ -pairs1_ other0']`.
6. exact-derived と search-derived は D_min_ratio / P_tau / kappa で分離できたか: D_min AUC `0.990096618357488`, P8 AUC `0.757246376811594`, kappa AUC `0.989371980676328`.
7. return radius proxy は origin_type を分けたか: AUC `1.00000000000000`.
8. search-derived score=4 は exact から遠い false-basin type という見方を支持したか: `True`.
9. H1, H2, H3 は supported / not_supported / inconclusive のどれか: H1 `supported`, H2 `supported`, H3 `inconclusive`.
10. 668 に戻すとき、score164/176 をどう読むべきか: low score should be treated as defect-space proximity only; keep candidates whose D_min/S, P_tau, kappa, and return-like probes look exact-basin-like, and de-prioritize low-score points with collapsed local mobility.

## Notes

- Exact distance is a lightweight proxy, not a complete equivalence search.
- Exact-derived candidates are controlled perturbations, not unguided search successes.
- p=37 behavior should not be over-generalized to 668 without repeating the diagnostics.
