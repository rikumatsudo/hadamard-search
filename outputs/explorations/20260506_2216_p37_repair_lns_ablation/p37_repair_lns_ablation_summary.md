# p37 Repair/LNS Ablation Summary

This run compares p=37 repair/LNS modes on low-score candidates. It is not a Hadamard 668 construction run.

## Run

- p: `37`
- ks: `[13, 16, 18, 18]`
- lambda: `28`
- parent candidates: `50`
- score=0 only is success.

## Mode Summary

```json
[
  {
    "attempt_count": 50,
    "best_score_after": 4,
    "escaped_false_basin_count": 0,
    "escaped_false_basin_rate": 0.0,
    "median_D_min_ratio_after": 0.75,
    "median_P_8_after": 0.03716216216216216,
    "median_kappa_max_after": 1.2,
    "median_score_after": 12.0,
    "median_score_delta": 0.0,
    "mode": "baseline_no_repair",
    "score0_count": 0,
    "score_improvement_count": 0,
    "score_improvement_rate": 0.0
  },
  {
    "attempt_count": 50,
    "best_score_after": 12,
    "escaped_false_basin_count": 22,
    "escaped_false_basin_rate": 0.44,
    "median_D_min_ratio_after": 0.45454545454545453,
    "median_P_8_after": 0.1794294294294294,
    "median_kappa_max_after": 2.0,
    "median_score_after": 42.0,
    "median_score_delta": 30.0,
    "mode": "exact_joint_rswap_lns",
    "score0_count": 0,
    "score_improvement_count": 0,
    "score_improvement_rate": 0.0
  },
  {
    "attempt_count": 50,
    "best_score_after": 8,
    "escaped_false_basin_count": 22,
    "escaped_false_basin_rate": 0.44,
    "median_D_min_ratio_after": 0.4444444444444444,
    "median_P_8_after": 0.14714714714714716,
    "median_kappa_max_after": 2.0,
    "median_score_after": 36.0,
    "median_score_delta": 24.0,
    "mode": "hybrid_repair",
    "score0_count": 0,
    "score_improvement_count": 1,
    "score_improvement_rate": 0.02
  },
  {
    "attempt_count": 50,
    "best_score_after": 0,
    "escaped_false_basin_count": 16,
    "escaped_false_basin_rate": 0.32,
    "median_D_min_ratio_after": 0.75,
    "median_P_8_after": 0.022897897897897895,
    "median_kappa_max_after": 1.0,
    "median_score_after": 8.0,
    "median_score_delta": -4.0,
    "mode": "moment_late_repair",
    "score0_count": 19,
    "score_improvement_count": 27,
    "score_improvement_rate": 0.54
  },
  {
    "attempt_count": 50,
    "best_score_after": 4,
    "escaped_false_basin_count": 4,
    "escaped_false_basin_rate": 0.08,
    "median_D_min_ratio_after": 1.0,
    "median_P_8_after": 0.022897897897897895,
    "median_kappa_max_after": 1.0,
    "median_score_after": 8.0,
    "median_score_delta": -4.0,
    "mode": "negative_cross_pair_search",
    "score0_count": 0,
    "score_improvement_count": 28,
    "score_improvement_rate": 0.56
  },
  {
    "attempt_count": 50,
    "best_score_after": 0,
    "escaped_false_basin_count": 10,
    "escaped_false_basin_rate": 0.2,
    "median_D_min_ratio_after": 1.0,
    "median_P_8_after": 0.015765765765765764,
    "median_kappa_max_after": 0.75,
    "median_score_after": 8.0,
    "median_score_delta": -8.0,
    "mode": "pair_level_partial_defect_repair",
    "score0_count": 19,
    "score_improvement_count": 34,
    "score_improvement_rate": 0.68
  },
  {
    "attempt_count": 50,
    "best_score_after": 0,
    "escaped_false_basin_count": 7,
    "escaped_false_basin_rate": 0.14,
    "median_D_min_ratio_after": 1.0,
    "median_P_8_after": 0.016516516516516516,
    "median_kappa_max_after": 0.75,
    "median_score_after": 8.0,
    "median_score_delta": -8.0,
    "mode": "sparse_vector_cancellation_beam",
    "score0_count": 19,
    "score_improvement_count": 35,
    "score_improvement_rate": 0.7
  },
  {
    "attempt_count": 50,
    "best_score_after": 0,
    "escaped_false_basin_count": 9,
    "escaped_false_basin_rate": 0.18,
    "median_D_min_ratio_after": 1.0,
    "median_P_8_after": 0.018018018018018018,
    "median_kappa_max_after": 0.8166666666666667,
    "median_score_after": 8.0,
    "median_score_delta": -4.0,
    "mode": "threshold_accepting_repair",
    "score0_count": 11,
    "score_improvement_count": 33,
    "score_improvement_rate": 0.66
  }
]
```

## Hypotheses

```json
{
  "H18_exact_joint_more_reliable_than_linearized": {
    "linearized_improvement_but_true_not_count": 1,
    "mismatch_count": 69,
    "verdict": "supported"
  },
  "H19_defect_targeted_mid_score_but_weak_final_closure": {
    "score4_to_score0_seen": false,
    "score_8_12_16_improvement_seen": true,
    "verdict": "supported"
  },
  "H20_negative_cross_pair_search_weak_alone": {
    "negative_cross_summary": {
      "attempt_count": 50,
      "best_score_after": 4,
      "escaped_false_basin_count": 4,
      "escaped_false_basin_rate": 0.08,
      "median_D_min_ratio_after": 1.0,
      "median_P_8_after": 0.022897897897897895,
      "median_kappa_max_after": 1.0,
      "median_score_after": 8.0,
      "median_score_delta": -4.0,
      "mode": "negative_cross_pair_search",
      "score0_count": 0,
      "score_improvement_count": 28,
      "score_improvement_rate": 0.56
    },
    "verdict": "not_supported"
  },
  "H21_pair_level_better_than_block_level": {
    "block_level_summary": {
      "attempt_count": 50,
      "best_score_after": 12,
      "escaped_false_basin_count": 22,
      "escaped_false_basin_rate": 0.44,
      "median_D_min_ratio_after": 0.45454545454545453,
      "median_P_8_after": 0.1794294294294294,
      "median_kappa_max_after": 2.0,
      "median_score_after": 42.0,
      "median_score_delta": 30.0,
      "mode": "exact_joint_rswap_lns",
      "score0_count": 0,
      "score_improvement_count": 0,
      "score_improvement_rate": 0.0
    },
    "pair_level_summary": {
      "attempt_count": 50,
      "best_score_after": 0,
      "escaped_false_basin_count": 10,
      "escaped_false_basin_rate": 0.2,
      "median_D_min_ratio_after": 1.0,
      "median_P_8_after": 0.015765765765765764,
      "median_kappa_max_after": 0.75,
      "median_score_after": 8.0,
      "median_score_delta": -8.0,
      "mode": "pair_level_partial_defect_repair",
      "score0_count": 19,
      "score_improvement_count": 34,
      "score_improvement_rate": 0.68
    },
    "verdict": "supported"
  },
  "score0_candidate_paths": [
    "outputs/explorations/20260506_2216_p37_repair_lns_ablation/score0_candidate_threshold_accepting_repair_5f50c5e7835e.json",
    "outputs/explorations/20260506_2216_p37_repair_lns_ablation/score0_candidate_sparse_vector_cancellation_beam_5f50c5e7835e.json",
    "outputs/explorations/20260506_2216_p37_repair_lns_ablation/score0_candidate_pair_level_partial_defect_repair_5f50c5e7835e.json",
    "outputs/explorations/20260506_2216_p37_repair_lns_ablation/score0_candidate_moment_late_repair_5f50c5e7835e.json"
  ]
}
```

## Required Answers

1. score=4 parent から score=0 は出たか: `False`.
2. score=4 parent から score<4 は出たか: `False`.
3. score=8/12/16 parent から score 改善は出たか: `True`.
4. どの repair mode が最も score improvement rate が高かったか: `sparse_vector_cancellation_beam` rate `0.7`.
5. どの repair mode が最も escaped_false_basin rate が高かったか: `exact_joint_rswap_lns` rate `0.44`.
6. negative_cross_pair_search は true improvement に繋がったか: `True`.
7. sparse_vector_cancellation_beam は true recomputation でも有効だったか: `True`.
8. exact_joint_rswap_lns は block-level repair として有効だったか: `False`.
9. pair_level_partial_defect_repair は H21 を支持したか: `supported`.
10. moment_late_repair は score と揃ったか、それとも conflict したか: score_improvement_rate `0.54`; moment objective is late-stage only.
11. exact joint vs linearized mismatch はどの程度あったか: mismatch_count `69`, linearized improvement but true not `1`.
12. H18, H19, H20, H21 の判定: H18 `supported`, H19 `supported`, H20 `not_supported`, H21 `supported`.
13. 668 に戻す場合、repair/LNS を主探索に使うべきか、late-stage audit に使うべきか: use as late-stage audit/repair, not primary search, unless exact-like trajectory signatures are present.
