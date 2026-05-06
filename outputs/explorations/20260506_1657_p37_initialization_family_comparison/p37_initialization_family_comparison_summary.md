# p37 Initialization Family Comparison Summary

This run compares p=37 initialization families with the same lightweight score-only trajectory budget. It is not a Hadamard 668 construction run.

## Run

- p: `37`
- ks: `[13, 16, 18, 18]`
- lambda: `28`
- families: `['pure_random', 'low_energy_random', 'score_biased_random', 'energy_regularized', 'AP_regularized', 'mixed_diversity', 'exact_perturbation', 'near_hit_perturbation']`
- candidates_per_family: `50`
- seeds_per_family: `20`
- steps: `1500`
- trajectory_mode: `score_only_with_diagnostics`
- score=0 only is success.

## AP Coefficients

For Q_X = C(p,k)+8E(X)+2(p-2k)AP(X), the p=37 tuple has AP coefficients `[22, 10, 2, 2]` for ks `[13, 16, 18, 18]`. All are positive, so AP_regularized penalizes positive AP excess.

## Family Summary

```json
[
  {
    "distinct_final_hashes": 20,
    "distinct_initial_hashes": 20,
    "escapable_final_count": 4,
    "escapable_rate": 0.2,
    "false_basin_final_count": 6,
    "false_basin_rate": 0.3,
    "family": "AP_regularized",
    "label_entropy": 1.4854752972273344,
    "median_best_score": 12.0,
    "median_final_D_min_ratio": 1.0,
    "median_final_P_8": 0.04091591591591592,
    "median_final_Q_ratio": 25.69212962962963,
    "median_final_kappa_max": 1.0,
    "median_final_score": 12.0,
    "median_initial_InitHardness": -677.8285714285666,
    "median_initial_P_8": 0.34684684684684686,
    "median_initial_Q_ratio": 2.9802350427350426,
    "median_initial_kappa_max": 3.0,
    "median_initial_score": 104.0,
    "median_initial_score_randnorm": 0.33072869343994254,
    "run_count": 20,
    "success_rate": 0.0,
    "success_score0_count": 0,
    "unknown_final_count": 10
  },
  {
    "distinct_final_hashes": 20,
    "distinct_initial_hashes": 20,
    "escapable_final_count": 3,
    "escapable_rate": 0.15,
    "false_basin_final_count": 2,
    "false_basin_rate": 0.1,
    "family": "energy_regularized",
    "label_entropy": 1.0540157730728,
    "median_best_score": 8.0,
    "median_final_D_min_ratio": 1.0,
    "median_final_P_8": 0.027777777777777776,
    "median_final_Q_ratio": 25.78472222222222,
    "median_final_kappa_max": 1.0,
    "median_final_score": 12.0,
    "median_initial_InitHardness": -633.8285714285666,
    "median_initial_P_8": 0.37274774774774777,
    "median_initial_Q_ratio": 2.569946545544432,
    "median_initial_kappa_max": 3.25,
    "median_initial_score": 120.0,
    "median_initial_score_randnorm": 0.38161003089224144,
    "run_count": 20,
    "success_rate": 0.0,
    "success_score0_count": 0,
    "unknown_final_count": 15
  },
  {
    "distinct_final_hashes": 20,
    "distinct_initial_hashes": 20,
    "escapable_final_count": 0,
    "escapable_rate": 0.0,
    "false_basin_final_count": 4,
    "false_basin_rate": 0.2,
    "family": "exact_perturbation",
    "label_entropy": 0.7219280948873623,
    "median_best_score": 12.0,
    "median_final_D_min_ratio": 1.0,
    "median_final_P_8": 0.029654654654654652,
    "median_final_Q_ratio": 25.73263888888889,
    "median_final_kappa_max": 1.0,
    "median_final_score": 12.0,
    "median_initial_InitHardness": -783.8285714285666,
    "median_initial_P_8": 0.1719219219219219,
    "median_initial_Q_ratio": 7.391445707070707,
    "median_initial_kappa_max": 2.0,
    "median_initial_score": 42.0,
    "median_initial_score_randnorm": 0.1335635108122845,
    "run_count": 20,
    "success_rate": 0.0,
    "success_score0_count": 0,
    "unknown_final_count": 16
  },
  {
    "distinct_final_hashes": 20,
    "distinct_initial_hashes": 20,
    "escapable_final_count": 2,
    "escapable_rate": 0.1,
    "false_basin_final_count": 4,
    "false_basin_rate": 0.2,
    "family": "low_energy_random",
    "label_entropy": 1.1567796494470395,
    "median_best_score": 8.0,
    "median_final_D_min_ratio": 1.0,
    "median_final_P_8": 0.03153153153153153,
    "median_final_Q_ratio": 25.623842592592595,
    "median_final_kappa_max": 1.0,
    "median_final_score": 12.0,
    "median_initial_InitHardness": -885.8285714285666,
    "median_initial_P_8": 0.41666666666666663,
    "median_initial_Q_ratio": 2.2278915732959854,
    "median_initial_kappa_max": 3.6333333333333333,
    "median_initial_score": 138.0,
    "median_initial_score_randnorm": 0.43885153552607764,
    "run_count": 20,
    "success_rate": 0.0,
    "success_score0_count": 0,
    "unknown_final_count": 14
  },
  {
    "distinct_final_hashes": 20,
    "distinct_initial_hashes": 20,
    "escapable_final_count": 3,
    "escapable_rate": 0.15,
    "false_basin_final_count": 3,
    "false_basin_rate": 0.15,
    "family": "mixed_diversity",
    "label_entropy": 1.1812908992306925,
    "median_best_score": 12.0,
    "median_final_D_min_ratio": 1.0,
    "median_final_P_8": 0.04016516516516516,
    "median_final_Q_ratio": 25.372685185185183,
    "median_final_kappa_max": 1.0,
    "median_final_score": 12.0,
    "median_initial_InitHardness": -657.8285714285666,
    "median_initial_P_8": 0.4722222222222222,
    "median_initial_Q_ratio": 1.795621549800329,
    "median_initial_kappa_max": 4.5,
    "median_initial_score": 174.0,
    "median_initial_score_randnorm": 0.5533345447937501,
    "run_count": 20,
    "success_rate": 0.0,
    "success_score0_count": 0,
    "unknown_final_count": 14
  },
  {
    "distinct_final_hashes": 20,
    "distinct_initial_hashes": 20,
    "escapable_final_count": 3,
    "escapable_rate": 0.15,
    "false_basin_final_count": 3,
    "false_basin_rate": 0.15,
    "family": "near_hit_perturbation",
    "label_entropy": 1.1812908992306925,
    "median_best_score": 12.0,
    "median_final_D_min_ratio": 1.0,
    "median_final_P_8": 0.03903903903903904,
    "median_final_Q_ratio": 25.570601851851855,
    "median_final_kappa_max": 1.0,
    "median_final_score": 12.0,
    "median_initial_InitHardness": -719.8285714285666,
    "median_initial_P_8": 0.22297297297297297,
    "median_initial_Q_ratio": 5.777758699633699,
    "median_initial_kappa_max": 2.2928571428571427,
    "median_initial_score": 54.0,
    "median_initial_score_randnorm": 0.17172451390150864,
    "run_count": 20,
    "success_rate": 0.0,
    "success_score0_count": 0,
    "unknown_final_count": 14
  },
  {
    "distinct_final_hashes": 20,
    "distinct_initial_hashes": 20,
    "escapable_final_count": 2,
    "escapable_rate": 0.1,
    "false_basin_final_count": 3,
    "false_basin_rate": 0.15,
    "family": "pure_random",
    "label_entropy": 1.0540157730728,
    "median_best_score": 12.0,
    "median_final_D_min_ratio": 1.0,
    "median_final_P_8": 0.043918918918918914,
    "median_final_Q_ratio": 22.45775462962963,
    "median_final_kappa_max": 1.0,
    "median_final_score": 14.0,
    "median_initial_InitHardness": -247.82857142856665,
    "median_initial_P_8": 0.5743243243243243,
    "median_initial_Q_ratio": 1.1172079882677708,
    "median_initial_kappa_max": 5.45,
    "median_initial_score": 278.0,
    "median_initial_score_randnorm": 0.8840632382336926,
    "run_count": 20,
    "success_rate": 0.0,
    "success_score0_count": 0,
    "unknown_final_count": 15
  },
  {
    "distinct_final_hashes": 20,
    "distinct_initial_hashes": 20,
    "escapable_final_count": 2,
    "escapable_rate": 0.1,
    "false_basin_final_count": 3,
    "false_basin_rate": 0.15,
    "family": "score_biased_random",
    "label_entropy": 1.0540157730728,
    "median_best_score": 12.0,
    "median_final_D_min_ratio": 1.0,
    "median_final_P_8": 0.03566066066066066,
    "median_final_Q_ratio": 25.71064814814815,
    "median_final_kappa_max": 1.0,
    "median_final_score": 12.0,
    "median_initial_InitHardness": -493.82857142856665,
    "median_initial_P_8": 0.3963963963963964,
    "median_initial_Q_ratio": 2.4807436342592593,
    "median_initial_kappa_max": 3.3666666666666667,
    "median_initial_score": 124.0,
    "median_initial_score_randnorm": 0.3943303652553162,
    "run_count": 20,
    "success_rate": 0.0,
    "success_score0_count": 0,
    "unknown_final_count": 15
  }
]
```

## Hypothesis Evaluation

```json
{
  "ExactLikeScore_z_stats": {
    "D_min_ratio": {
      "mean": 0.7655471229063155,
      "std": 0.37663092386647884
    },
    "P_4": {
      "mean": 0.1661786786786787,
      "std": 0.18343127253710698
    },
    "P_8": {
      "mean": 0.202221753003003,
      "std": 0.19168166745677365
    },
    "Q_ratio": {
      "mean": 15.486181847877983,
      "std": 14.121855821358432
    },
    "kappa_max": {
      "mean": 2.3347643849206348,
      "std": 1.7439990716472542
    }
  },
  "H12_energy_AP_regularized_reduces_hard_basin": {
    "baseline_median_escapable_rate": 0.1,
    "baseline_median_false_basin_rate": 0.15,
    "regularized_median_escapable_rate": 0.15,
    "regularized_median_false_basin_rate": 0.2,
    "verdict": "not_supported"
  },
  "H13_mixed_diversity_increases_basin_diversity": {
    "mixed_summary": {
      "distinct_final_hashes": 20,
      "distinct_initial_hashes": 20,
      "escapable_final_count": 3,
      "escapable_rate": 0.15,
      "false_basin_final_count": 3,
      "false_basin_rate": 0.15,
      "family": "mixed_diversity",
      "label_entropy": 1.1812908992306925,
      "median_best_score": 12.0,
      "median_final_D_min_ratio": 1.0,
      "median_final_P_8": 0.04016516516516516,
      "median_final_Q_ratio": 25.372685185185183,
      "median_final_kappa_max": 1.0,
      "median_final_score": 12.0,
      "median_initial_InitHardness": -657.8285714285666,
      "median_initial_P_8": 0.4722222222222222,
      "median_initial_Q_ratio": 1.795621549800329,
      "median_initial_kappa_max": 4.5,
      "median_initial_score": 174.0,
      "median_initial_score_randnorm": 0.5533345447937501,
      "run_count": 20,
      "success_rate": 0.0,
      "success_score0_count": 0,
      "unknown_final_count": 14
    },
    "verdict": "supported"
  },
  "H14_good_init_rule_predicts_non_false_final": {
    "rule_summary": {
      "InitHardness_median": -671.8285714285666,
      "P_8_median": 0.3802552552552553,
      "accuracy_known": 0.5957446808510638,
      "bad_count": 157,
      "false_basin_rate_bad_known": 0.6,
      "false_basin_rate_good_known": 0.5,
      "fn": 18,
      "fp": 1,
      "good_count": 3,
      "precision_known": 0.5,
      "recall_known": 0.05263157894736842,
      "row_type": "summary",
      "score_randnorm_median": 0.38161003089224144,
      "tn": 27,
      "tp": 1,
      "unknown": 113
    },
    "verdict": "not_supported"
  },
  "best_family_by_high_escapable_rate": {
    "distinct_final_hashes": 20,
    "distinct_initial_hashes": 20,
    "escapable_final_count": 4,
    "escapable_rate": 0.2,
    "false_basin_final_count": 6,
    "false_basin_rate": 0.3,
    "family": "AP_regularized",
    "label_entropy": 1.4854752972273344,
    "median_best_score": 12.0,
    "median_final_D_min_ratio": 1.0,
    "median_final_P_8": 0.04091591591591592,
    "median_final_Q_ratio": 25.69212962962963,
    "median_final_kappa_max": 1.0,
    "median_final_score": 12.0,
    "median_initial_InitHardness": -677.8285714285666,
    "median_initial_P_8": 0.34684684684684686,
    "median_initial_Q_ratio": 2.9802350427350426,
    "median_initial_kappa_max": 3.0,
    "median_initial_score": 104.0,
    "median_initial_score_randnorm": 0.33072869343994254,
    "run_count": 20,
    "success_rate": 0.0,
    "success_score0_count": 0,
    "unknown_final_count": 10
  },
  "best_family_by_low_false_basin_rate": {
    "distinct_final_hashes": 20,
    "distinct_initial_hashes": 20,
    "escapable_final_count": 3,
    "escapable_rate": 0.15,
    "false_basin_final_count": 2,
    "false_basin_rate": 0.1,
    "family": "energy_regularized",
    "label_entropy": 1.0540157730728,
    "median_best_score": 8.0,
    "median_final_D_min_ratio": 1.0,
    "median_final_P_8": 0.027777777777777776,
    "median_final_Q_ratio": 25.78472222222222,
    "median_final_kappa_max": 1.0,
    "median_final_score": 12.0,
    "median_initial_InitHardness": -633.8285714285666,
    "median_initial_P_8": 0.37274774774774777,
    "median_initial_Q_ratio": 2.569946545544432,
    "median_initial_kappa_max": 3.25,
    "median_initial_score": 120.0,
    "median_initial_score_randnorm": 0.38161003089224144,
    "run_count": 20,
    "success_rate": 0.0,
    "success_score0_count": 0,
    "unknown_final_count": 15
  },
  "exact_perturbation_initial_ExactLikeScore_median": 0.9737750934104216,
  "false_final_initial_ExactLikeScore_median": 3.47835788335474,
  "skipped_families_or_attempts": []
}
```

## Required Answers

1. どの initialization family が最も hard basin rate を下げたか: `energy_regularized` (false_basin_rate `0.1`).
2. energy_regularized / AP_regularized は H12 を支持したか: `not_supported`.
3. mixed_diversity は H13 を支持したか: `supported`; distinct_final_hashes `20`, label_entropy `1.1812908992306925`.
4. GoodInitRule は H14 を支持したか: `not_supported`; precision_known `0.5`, recall_known `0.05263157894736842`.
5. score_biased_random は低 score だが false basin に落ちやすかったか: false_basin_rate `0.15`, median_initial_score `124.000000000000`.
6. initial InitHardness / Q_ratio / P_tau / kappa は final outcome を予測したか: GoodInitRule と ExactLikeScore は初期仮説として `not_supported`; detailed rows are in exact_like_scores.jsonl.
7. exact_perturbation family はどのような signature を持ったか: false_basin_rate `0.2`, escapable_rate `0.0`, median_initial_P_8 `0.171921921921922`, median_initial_kappa_max `2.00000000000000`.
8. near_hit_perturbation family は false basin に戻りやすかったか: false_basin_rate `0.15`, escapable_rate `0.15`.
9. 次に p=43/47/668 へ拡張すべき初期化 family はどれか: prioritize families with low false_basin_rate and high escapable_rate in family_summary.csv; controlled exact_perturbation remains diagnostic only.
10. 668 の initialization policy にどう反映すべきか: use score as a filter, but retain candidates with low D_min/S, non-collapsing P_tau/kappa, and moderate InitHardness/Q_ratio; avoid over-selecting score-biased low-score candidates when their local entropy collapses.
