# p37 Trap Set Catalog Validation

This is a trap catalog validation, not a Hadamard 668 construction run.

## Counts

- p37 trap candidates: `190`
- p167 near-hit candidates: `0`
- top level1 trap type: `4|+pairs1_ -pairs1_ other0|10=-1;16=1`

## Hypotheses

```json
{
  "H_TRAP1": "not_supported",
  "H_TRAP2": "supported",
  "H_TRAP3": "inconclusive",
  "H_TRAP4": "supported",
  "exact_false_level2_overlap_count": 0,
  "exact_false_level2_separation_proxy": 1.0,
  "false_basin_count": 84,
  "false_top_trap_type_share": 0.08333333333333333,
  "nearhit_668_count": 0,
  "operator_response_rows": 302
}
```

## Required Answers

1. p=37 false basin は少数の trap type に分類できたか: `not_supported`; top share `0.08333333333333333`.
2. score=4 false basin は理論通り +1 on ±a, -1 on ±b の型だったか: `True`.
3. exact-derived と search-derived false basin は trap type 分布で分かれたか: `supported`; separation proxy `1.00000000000000`.
4. D_min/S, P_tau, kappa を加えると trap type の分離は強まったか: level2 separation proxy `1.00000000000000`; compare level1/level2 catalogs.
5. repair response を加えると trap type の意味は増したか: `302` operator response rows joined.
6. 同じ trap type が複数 run / 複数 source で再発していたか: top recurrence count `7`.
7. 668 score164/176 または p=167 near-hit は catalog に載せられたか: `0` candidates.
8. 668 near-hit は p=37 trap type と似ていたか: `inconclusive`.
9. trap type ごとに有効な operator の違いは見えたか: `supported`.
10. H-TRAP1, H-TRAP2, H-TRAP3, H-TRAP4 の判定はどうか: `{"H_TRAP1": "not_supported", "H_TRAP2": "supported", "H_TRAP3": "inconclusive", "H_TRAP4": "supported"}`.
11. 668 に戻す場合、trap catalog は archive / restart / repair routing のどこに使うべきか: use level2 signatures for early archive/restart; use level3 response only as repair routing hints after more p167 evidence.

## Validation

- `sage sage/06_known_sds_regression.sage`: OK
