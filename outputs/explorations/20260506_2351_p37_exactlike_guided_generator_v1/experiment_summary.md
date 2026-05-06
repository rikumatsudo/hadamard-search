# Exact-Like Guided Generator Validation

This is a config-driven generator framework validation. It is not a Hadamard 668 construction run.

## Target

- p: `37`
- ks: `[13, 16, 18, 18]`
- lambda: `28`
- experiment: `p37_exactlike_guided_generator_v1`
- output: `outputs/explorations/20260506_2351_p37_exactlike_guided_generator_v1`

## Mode Summary

```json
[
  {
    "best_score": 0,
    "distinct_final_hashes": 5,
    "final_exact_like_count": 1,
    "final_false_like_count": 2,
    "median_best_score": 8,
    "median_final_score": 8,
    "mode": "exactlike_guided",
    "run_count": 5,
    "score0_count": 1
  },
  {
    "best_score": 0,
    "distinct_final_hashes": 5,
    "final_exact_like_count": 1,
    "final_false_like_count": 2,
    "median_best_score": 8,
    "median_final_score": 8,
    "mode": "exactlike_guided_with_repair",
    "run_count": 5,
    "score0_count": 1
  },
  {
    "best_score": 0,
    "distinct_final_hashes": 5,
    "final_exact_like_count": 1,
    "final_false_like_count": 1,
    "median_best_score": 12,
    "median_final_score": 12,
    "mode": "score_only",
    "run_count": 5,
    "score0_count": 1
  },
  {
    "best_score": 0,
    "distinct_final_hashes": 5,
    "final_exact_like_count": 1,
    "final_false_like_count": 3,
    "median_best_score": 8,
    "median_final_score": 8,
    "mode": "threshold_exactlike",
    "run_count": 5,
    "score0_count": 1
  }
]
```

## Repair Summary

```json
[
  {
    "attempt_count": 2,
    "best_score_after": 12,
    "repair_mode": "exact_joint_rswap_lns",
    "score0_count": 0,
    "score_improvement_count": 2,
    "score_improvement_rate": 1.0
  },
  {
    "attempt_count": 2,
    "best_score_after": 0,
    "repair_mode": "moment_late_repair",
    "score0_count": 2,
    "score_improvement_count": 2,
    "score_improvement_rate": 1.0
  },
  {
    "attempt_count": 2,
    "best_score_after": 0,
    "repair_mode": "pair_level_partial_defect_repair",
    "score0_count": 2,
    "score_improvement_count": 2,
    "score_improvement_rate": 1.0
  },
  {
    "attempt_count": 2,
    "best_score_after": 0,
    "repair_mode": "sparse_vector_cancellation_beam",
    "score0_count": 2,
    "score_improvement_count": 2,
    "score_improvement_rate": 1.0
  }
]
```

## Required Answers

1. config-driven runner は動いたか: `True`.
2. p=37 exact validation は通ったか: `True`.
3. score_only / exactlike_guided / threshold_exactlike / exactlike_guided_with_repair の比較はできたか: `True`.
4. exactlike_guided は score_only より false-like candidate を減らしたか: `False`.
5. exactlike_guided は score_only より exact-like frontier を増やしたか: `False`.
6. threshold_exactlike は shallow barrier を越えて escapable candidate を増やしたか: final_exact_like_count `1` vs score_only `1`.
7. repair routing は全候補ではなく exact-like low-score にだけ適用されたか: `2` routed candidates, `8` attempts.
8. score=0 は出たか。出た場合、08/05/04 検証を通ったか: score0_seen `True`; external validation is recorded in run_log after command execution.
9. p=167 に config だけ変えて拡張できる状態か: `True`; scaffold config uses rank features and no exact perturbation.
10. 次に p=43/47/167 のどれで検証すべきか: p=43 or p=47 smoke first, then p=167 rank-based smoke.

## Interpretation

- score=0 only is success.
- p=37 thresholds should not be copied directly to p=167; use ranks, trajectory response, and repair response there.
- Repair is routed to low-score exact-like candidates, not applied as a blanket pass.
