# Exact-Like Guided Generator Validation

This is a config-driven generator framework validation. It is not a Hadamard 668 construction run.

## Target

- p: `37`
- ks: `[13, 16, 18, 18]`
- lambda: `28`
- experiment: `p37_exactlike_guided_generator_medium`
- output: `outputs/explorations/20260507_0019_p37_exactlike_guided_generator_medium`

## Mode Summary

```json
[
  {
    "archived_false_like_count": 54,
    "best_score": 0,
    "best_score_overall": 0,
    "distinct_final_hashes": 39,
    "distinct_frontier_hashes": 23,
    "exact_like_final_rate": 0.24,
    "false_like_final_rate": 0.56,
    "final_ambiguous_count": 10,
    "final_exact_like_count": 12,
    "final_false_like_count": 28,
    "final_unknown_count": 0,
    "frontier_exact_like_count": 0,
    "frontier_false_like_count": 15,
    "median_D_min_ratio_final": 1.5,
    "median_ExactLikeScore_final": -2.529652284710549,
    "median_P_16_final": 0.10998498498498499,
    "median_P_4_final": 0.0022522522522522522,
    "median_P_8_final": 0.016141141141141138,
    "median_Q_ratio_final": 38.55034722222222,
    "median_best_score": 8.0,
    "median_final_score": 8.0,
    "median_kappa_max_final": 0.75,
    "mode": "exactlike_guided",
    "repair_attempt_count": 0,
    "repair_routed_count": 0,
    "repair_score0_count": 0,
    "repair_score_improvement_count": 0,
    "repair_success_rate": null,
    "run_count": 50,
    "score0_count": 12,
    "score0_rate": 0.24
  },
  {
    "archived_false_like_count": 54,
    "best_score": 0,
    "best_score_overall": 0,
    "distinct_final_hashes": 39,
    "distinct_frontier_hashes": 0,
    "exact_like_final_rate": 0.24,
    "false_like_final_rate": 0.56,
    "final_ambiguous_count": 10,
    "final_exact_like_count": 12,
    "final_false_like_count": 28,
    "final_unknown_count": 0,
    "frontier_exact_like_count": 0,
    "frontier_false_like_count": 0,
    "median_D_min_ratio_final": 1.5,
    "median_ExactLikeScore_final": -2.529652284710549,
    "median_P_16_final": 0.10998498498498499,
    "median_P_4_final": 0.0022522522522522522,
    "median_P_8_final": 0.016141141141141138,
    "median_Q_ratio_final": 38.55034722222222,
    "median_best_score": 8.0,
    "median_final_score": 8.0,
    "median_kappa_max_final": 0.75,
    "mode": "exactlike_guided_with_repair",
    "repair_attempt_count": 0,
    "repair_routed_count": 0,
    "repair_score0_count": 0,
    "repair_score_improvement_count": 0,
    "repair_success_rate": null,
    "run_count": 50,
    "score0_count": 12,
    "score0_rate": 0.24
  },
  {
    "archived_false_like_count": 14,
    "best_score": 0,
    "best_score_overall": 0,
    "distinct_final_hashes": 39,
    "distinct_frontier_hashes": 11,
    "exact_like_final_rate": 0.24,
    "false_like_final_rate": 0.14,
    "final_ambiguous_count": 31,
    "final_exact_like_count": 12,
    "final_false_like_count": 7,
    "final_unknown_count": 0,
    "frontier_exact_like_count": 0,
    "frontier_false_like_count": 3,
    "median_D_min_ratio_final": 1.0,
    "median_ExactLikeScore_final": -1.5394941844948296,
    "median_P_16_final": 0.14752252252252251,
    "median_P_4_final": 0.00975975975975976,
    "median_P_8_final": 0.03003003003003003,
    "median_Q_ratio_final": 25.62037037037037,
    "median_best_score": 12.0,
    "median_final_score": 12.0,
    "median_kappa_max_final": 1.0,
    "mode": "score_only",
    "repair_attempt_count": 0,
    "repair_routed_count": 0,
    "repair_score0_count": 0,
    "repair_score_improvement_count": 0,
    "repair_success_rate": null,
    "run_count": 50,
    "score0_count": 12,
    "score0_rate": 0.24
  },
  {
    "archived_false_like_count": 70,
    "best_score": 0,
    "best_score_overall": 0,
    "distinct_final_hashes": 39,
    "distinct_frontier_hashes": 20,
    "exact_like_final_rate": 0.24,
    "false_like_final_rate": 0.64,
    "final_ambiguous_count": 6,
    "final_exact_like_count": 12,
    "final_false_like_count": 32,
    "final_unknown_count": 0,
    "frontier_exact_like_count": 2,
    "frontier_false_like_count": 18,
    "median_D_min_ratio_final": 1.75,
    "median_ExactLikeScore_final": -2.604082044663695,
    "median_P_16_final": 0.08633633633633633,
    "median_P_4_final": 0.0015015015015015015,
    "median_P_8_final": 0.009009009009009009,
    "median_Q_ratio_final": 57.13368055555556,
    "median_best_score": 4.0,
    "median_final_score": 4.0,
    "median_kappa_max_final": 0.6666666666666666,
    "mode": "threshold_exactlike",
    "repair_attempt_count": 0,
    "repair_routed_count": 0,
    "repair_score0_count": 0,
    "repair_score_improvement_count": 0,
    "repair_success_rate": null,
    "run_count": 50,
    "score0_count": 12,
    "score0_rate": 0.24
  }
]
```

## Repair Summary

```json
[
  {
    "attempt_count": 5,
    "best_score_after": 8,
    "repair_mode": "exact_joint_rswap_lns",
    "score0_count": 0,
    "score_improvement_count": 2,
    "score_improvement_rate": 0.4
  },
  {
    "attempt_count": 5,
    "best_score_after": 0,
    "repair_mode": "moment_late_repair",
    "score0_count": 5,
    "score_improvement_count": 5,
    "score_improvement_rate": 1.0
  },
  {
    "attempt_count": 5,
    "best_score_after": 0,
    "repair_mode": "pair_level_partial_defect_repair",
    "score0_count": 5,
    "score_improvement_count": 5,
    "score_improvement_rate": 1.0
  },
  {
    "attempt_count": 5,
    "best_score_after": 0,
    "repair_mode": "sparse_vector_cancellation_beam",
    "score0_count": 5,
    "score_improvement_count": 5,
    "score_improvement_rate": 1.0
  }
]
```

## Required Answers

1. medium run は完走したか: `True`.
2. config-driven runner は今回も問題なく動作したか: `True`.
3. p37 exact validation は通ったか: `True`.
4. score_only / exactlike_guided / threshold_exactlike / exactlike_guided_with_repair の score0_rate はどう違ったか: `{"exactlike_guided": 0.24, "exactlike_guided_with_repair": 0.24, "score_only": 0.24, "threshold_exactlike": 0.24}`.
5. exactlike_guided は score_only より false-like final を減らしたか: `False`.
6. exactlike_guided は score_only より exact-like frontier を増やしたか: `False`.
7. threshold_exactlike は shallow barrier を越えて escapable / exact-like candidates を増やしたか: final_exact_like_count `12` vs score_only `12`; frontier_exact_like_count `2` vs score_only `0`.
8. exactlike_guided_with_repair は repair routing により score0_rate または score improvement を上げたか: `False`; mode summary 上は repair_score0_count `0`, repair_score_improvement_count `0`。global repair routing は initialization 由来の exact-like low-score 5 candidates にだけ実行され、trajectory mode 自体の score0_rate は改善しなかった。
9. archived false-like candidates は本当に false-like 指標を持っていたか: median D_min_ratio `1.5`, median kappa_max `0.75`, score<=16 archived `192`.
10. repair は exact-like low-score candidates に限定されていたか: parent labels `{'exact_like': 20}`。親 mode は `initialization` で、false-like への blanket repair は発生していない。
11. score=0 candidate は出たか。出た場合、08/05/04 検証を通ったか: `True`。保存された 4 JSON はすべて 08/05/04 を通過し、SDS OK / HH^T = 148I を確認した。
12. p37 の結果から、exactlike-guided generator は score-only より有望か: 今回の medium run では `not_supported`。score0_rate は全 mode 0.24 で同率、exactlike_guided は score_only より false_like_final_rate が高い (`0.56` vs `0.14`)。
13. 次に p43/p47 に進むべきか、それとも p37 で重み・accept rule を調整すべきか: p43/p47 へ進む前に p37 で ExactLikeScore weights と accept rule を調整するべき。
14. p167 へ戻すなら、どの設定を変えるべきか: use rank normalization, larger relative thresholds, fewer full diagnostics, and stricter repair routing percentiles.

## Interpretation

- score=0 only is success.
- p=37 thresholds should not be copied directly to p=167; use ranks, trajectory response, and repair response there.
- Repair is routed to low-score exact-like candidates, not applied as a blanket pass.
- The 12/50 score0 count in each mode is driven by the controlled `exact_perturbation` family and should not be read as unguided search success.
- This run is a negative result for the current exactlike-guided accept policy: the classifier features remain useful for audit/archive, but the generator policy currently over-selects low-score false-like trajectories.
