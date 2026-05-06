# p37 Score4 False Basin Anatomy Summary

This is a lightweight anatomy run for p=37 score=4 near-hits. It is not a Hadamard 668 construction run.

## Target

- p: `37`
- ks: `[13, 16, 18, 18]`
- lambda: `28`

## Aggregate

```json
{
  "defect_targeted_return_improvement_seen": false,
  "distance_proxy_note": "Distances are lightweight proxies. Global translation and equal-size block swap are considered; block-wise translation is an independent lower bound, not exact equivalence distance.",
  "exact_candidate_count": 1,
  "exact_perturbation_score4_count": 0,
  "return_improvement_seen": false,
  "return_score0_seen": false,
  "score4_pattern_type_count": 1,
  "search_score4_candidate_count": 15
}
```

## Required Answers

1. p=37 exact candidate は見つかったか。SDS/GS/HH^T 検証は通ったか: `True`。script 上の exact path は `outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json`。`08_analyze_sds_candidate`, `05_validate_candidate_json`, `04_build_gs_from_sds` で score=0 / SDS OK / `HH^T = 148I` を確認済み。
2. search-derived score=4 candidate は何個診断したか: `15`.
3. score=4 defect pattern は何種類あったか: `1`.
4. search-derived score=4 は exact から軽量距離でどのくらい離れていたか: global+18-swap proxy の min/median/max = `25/28/30`.
5. exact から r<=4 perturbation で score=4 は出たか: `0` 件。
6. exact-derived score=4 と search-derived score=4 は h_min / D_min / P_tau / Q_ratio で似ていたか: `no exact-derived score4 was sampled for r<=max_r, so metric similarity could not be established`.
7. direct return radius はどのくらいだったか: min/median/max = `25/28/30`.
8. truncated return r<=6 で score 改善または score=0 は出たか: improvement `False`, score0 `False`.
9. p=37 score=4 は true-neighborhood 型か、false-basin 型か: `false-basin type under lightweight exact-distance proxy`.
10. この知見を 668 の score164/176 にどう使うべきか: `Use exact-neighborhood distance/proxy return diagnostics before spending heavy LNS on 668 score164/176; low score alone is not evidence of exact-basin proximity.`.

## Safety

- score=4 is a near-hit, not a solution.
- Distances are lightweight proxies; equivalence is not exhaustively minimized.
- Block-wise translation is an independent lower bound, not an exact equivalence distance.

## Validation

- `sage sage/06_known_sds_regression.sage`: all known SDS regressions passed.
- `sage sage/08_analyze_sds_candidate.sage outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json`: computed score=0, l1=0, max_abs=0.
- `sage sage/05_validate_candidate_json.sage outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json`: SDS OK.
- `sage sage/04_build_gs_from_sds.sage outputs/candidates/small_p/exact_v37_djokovic_2009_g_matrices_order37.json`: `HH^T = 148I`.
- No new score=0 candidate was produced by this anatomy run.
