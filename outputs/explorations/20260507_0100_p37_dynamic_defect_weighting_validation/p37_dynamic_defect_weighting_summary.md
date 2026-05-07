# p37 Dynamic Defect Weighting Validation

This is a p=37 operator validation, not a Hadamard 668 construction run.

## Run

- parents: `24`
- steps: `250`
- restarts: `2`
- modes: `baseline_score_only_recheck, static_weighted_score, dynamic_weighting_basic, dynamic_weighting_stubborn, dynamic_weighting_breakout, dynamic_weighting_with_exactlike_guard`
- score=0 only is success

## Mode Summary

```json
[
  {
    "attempt_count": 48,
    "escaped_false_basin_count": 0,
    "escaped_false_basin_rate": 0.0,
    "exactlike_improved_count": 0,
    "exactlike_improved_rate": 0.0,
    "false_like_final_count": 20,
    "false_like_final_rate": 0.4166666666666667,
    "final_label_distribution": {
      "ambiguous": 12,
      "exact": 16,
      "false_like": 20
    },
    "median_best_D_min_ratio": 2.0,
    "median_best_P_8": 0.00825825825825826,
    "median_best_Q_ratio": 76.23958333333333,
    "median_best_kappa_max": 0.6333333333333333,
    "median_best_score": 4.0,
    "median_stubborn_count": 0.0,
    "median_weight_entropy": 3.583518938456111,
    "median_weight_max": 1.0,
    "mode": "baseline_score_only_recheck",
    "parent_label_distribution": {
      "ambiguous": 12,
      "exact_like": 18,
      "false_like": 18
    },
    "parent_score_distribution": {
      "12": 4,
      "16": 12,
      "4": 16,
      "8": 16
    },
    "score0_count": 16,
    "score0_rate": 0.3333333333333333,
    "score4_parent_count": 16,
    "score4_to_lower_count": 0,
    "score4_to_lower_rate": 0.0,
    "score_damage_count": 0,
    "score_damage_rate": 0.0,
    "score_improvement_count": 18,
    "score_improvement_rate": 0.375,
    "weighted_false_basin_risk_count": 0,
    "weighted_false_basin_risk_rate": 0.0
  },
  {
    "attempt_count": 48,
    "escaped_false_basin_count": 0,
    "escaped_false_basin_rate": 0.0,
    "exactlike_improved_count": 0,
    "exactlike_improved_rate": 0.0,
    "false_like_final_count": 19,
    "false_like_final_rate": 0.3958333333333333,
    "final_label_distribution": {
      "ambiguous": 12,
      "exact": 16,
      "exact_like": 1,
      "false_like": 19
    },
    "median_best_D_min_ratio": 2.0,
    "median_best_P_8": 0.00825825825825826,
    "median_best_Q_ratio": 76.23958333333333,
    "median_best_kappa_max": 0.6333333333333333,
    "median_best_score": 4.0,
    "median_stubborn_count": 0.0,
    "median_weight_entropy": 3.581664030237833,
    "median_weight_max": 1.1791000000000003,
    "mode": "dynamic_weighting_basic",
    "parent_label_distribution": {
      "ambiguous": 12,
      "exact_like": 18,
      "false_like": 18
    },
    "parent_score_distribution": {
      "12": 4,
      "16": 12,
      "4": 16,
      "8": 16
    },
    "score0_count": 16,
    "score0_rate": 0.3333333333333333,
    "score4_parent_count": 16,
    "score4_to_lower_count": 0,
    "score4_to_lower_rate": 0.0,
    "score_damage_count": 1,
    "score_damage_rate": 0.020833333333333332,
    "score_improvement_count": 18,
    "score_improvement_rate": 0.375,
    "weighted_false_basin_risk_count": 1,
    "weighted_false_basin_risk_rate": 0.020833333333333332
  },
  {
    "attempt_count": 48,
    "escaped_false_basin_count": 0,
    "escaped_false_basin_rate": 0.0,
    "exactlike_improved_count": 0,
    "exactlike_improved_rate": 0.0,
    "false_like_final_count": 0,
    "false_like_final_rate": 0.0,
    "final_label_distribution": {
      "ambiguous": 17,
      "exact": 16,
      "exact_like": 15
    },
    "median_best_D_min_ratio": 2.0,
    "median_best_P_8": 0.00825825825825826,
    "median_best_Q_ratio": 76.23958333333333,
    "median_best_kappa_max": 0.6333333333333333,
    "median_best_score": 4.0,
    "median_stubborn_count": 0.0,
    "median_weight_entropy": 3.517074283131568,
    "median_weight_max": 2.75,
    "mode": "dynamic_weighting_breakout",
    "parent_label_distribution": {
      "ambiguous": 12,
      "exact_like": 18,
      "false_like": 18
    },
    "parent_score_distribution": {
      "12": 4,
      "16": 12,
      "4": 16,
      "8": 16
    },
    "score0_count": 16,
    "score0_rate": 0.3333333333333333,
    "score4_parent_count": 16,
    "score4_to_lower_count": 0,
    "score4_to_lower_rate": 0.0,
    "score_damage_count": 23,
    "score_damage_rate": 0.4791666666666667,
    "score_improvement_count": 18,
    "score_improvement_rate": 0.375,
    "weighted_false_basin_risk_count": 23,
    "weighted_false_basin_risk_rate": 0.4791666666666667
  },
  {
    "attempt_count": 48,
    "escaped_false_basin_count": 0,
    "escaped_false_basin_rate": 0.0,
    "exactlike_improved_count": 0,
    "exactlike_improved_rate": 0.0,
    "false_like_final_count": 20,
    "false_like_final_rate": 0.4166666666666667,
    "final_label_distribution": {
      "ambiguous": 12,
      "exact": 16,
      "false_like": 20
    },
    "median_best_D_min_ratio": 2.0,
    "median_best_P_8": 0.00825825825825826,
    "median_best_Q_ratio": 76.23958333333333,
    "median_best_kappa_max": 0.6333333333333333,
    "median_best_score": 4.0,
    "median_stubborn_count": 0.0,
    "median_weight_entropy": 3.583518938456111,
    "median_weight_max": 0.9801,
    "mode": "dynamic_weighting_stubborn",
    "parent_label_distribution": {
      "ambiguous": 12,
      "exact_like": 18,
      "false_like": 18
    },
    "parent_score_distribution": {
      "12": 4,
      "16": 12,
      "4": 16,
      "8": 16
    },
    "score0_count": 16,
    "score0_rate": 0.3333333333333333,
    "score4_parent_count": 16,
    "score4_to_lower_count": 0,
    "score4_to_lower_rate": 0.0,
    "score_damage_count": 0,
    "score_damage_rate": 0.0,
    "score_improvement_count": 18,
    "score_improvement_rate": 0.375,
    "weighted_false_basin_risk_count": 0,
    "weighted_false_basin_risk_rate": 0.0
  },
  {
    "attempt_count": 48,
    "escaped_false_basin_count": 0,
    "escaped_false_basin_rate": 0.0,
    "exactlike_improved_count": 18,
    "exactlike_improved_rate": 0.375,
    "false_like_final_count": 17,
    "false_like_final_rate": 0.3541666666666667,
    "final_label_distribution": {
      "ambiguous": 10,
      "exact_like": 21,
      "false_like": 17
    },
    "median_best_D_min_ratio": 1.0,
    "median_best_P_8": 0.01539039039039039,
    "median_best_Q_ratio": 38.28645833333333,
    "median_best_kappa_max": 1.0,
    "median_best_score": 8.0,
    "median_stubborn_count": 0.0,
    "median_weight_entropy": 3.5732906681495797,
    "median_weight_max": 1.4495927804500002,
    "mode": "dynamic_weighting_with_exactlike_guard",
    "parent_label_distribution": {
      "ambiguous": 12,
      "exact_like": 18,
      "false_like": 18
    },
    "parent_score_distribution": {
      "12": 4,
      "16": 12,
      "4": 16,
      "8": 16
    },
    "score0_count": 0,
    "score0_rate": 0.0,
    "score4_parent_count": 16,
    "score4_to_lower_count": 0,
    "score4_to_lower_rate": 0.0,
    "score_damage_count": 4,
    "score_damage_rate": 0.08333333333333333,
    "score_improvement_count": 10,
    "score_improvement_rate": 0.20833333333333334,
    "weighted_false_basin_risk_count": 4,
    "weighted_false_basin_risk_rate": 0.08333333333333333
  },
  {
    "attempt_count": 48,
    "escaped_false_basin_count": 0,
    "escaped_false_basin_rate": 0.0,
    "exactlike_improved_count": 0,
    "exactlike_improved_rate": 0.0,
    "false_like_final_count": 19,
    "false_like_final_rate": 0.3958333333333333,
    "final_label_distribution": {
      "ambiguous": 12,
      "exact": 16,
      "exact_like": 1,
      "false_like": 19
    },
    "median_best_D_min_ratio": 2.0,
    "median_best_P_8": 0.007882882882882882,
    "median_best_Q_ratio": 76.23958333333333,
    "median_best_kappa_max": 0.6333333333333333,
    "median_best_score": 4.0,
    "median_stubborn_count": 0.0,
    "median_weight_entropy": 3.5566384328396974,
    "median_weight_max": 1.75,
    "mode": "static_weighted_score",
    "parent_label_distribution": {
      "ambiguous": 12,
      "exact_like": 18,
      "false_like": 18
    },
    "parent_score_distribution": {
      "12": 4,
      "16": 12,
      "4": 16,
      "8": 16
    },
    "score0_count": 16,
    "score0_rate": 0.3333333333333333,
    "score4_parent_count": 16,
    "score4_to_lower_count": 0,
    "score4_to_lower_rate": 0.0,
    "score_damage_count": 1,
    "score_damage_rate": 0.020833333333333332,
    "score_improvement_count": 18,
    "score_improvement_rate": 0.375,
    "weighted_false_basin_risk_count": 1,
    "weighted_false_basin_risk_rate": 0.020833333333333332
  }
]
```

## Hypotheses

```json
{
  "H_DW1": "not_supported",
  "H_DW2": "not_supported",
  "H_DW3": "supported_label_only",
  "H_DW4": "supported",
  "baseline_escape_rate": 0.0,
  "baseline_false_like_final_rate": 0.4166666666666667,
  "baseline_persistent_defect_fraction": 1.0,
  "baseline_score_improvement_rate": 0.375,
  "best_weighted_escape_rate": 0.0,
  "best_weighted_false_like_final_rate": 0.3541666666666667,
  "best_weighted_persistent_defect_fraction": 1.0,
  "best_weighted_score_improvement_rate": 0.375,
  "weighted_false_basin_risk_rate_max": 0.4791666666666667
}
```

## Required Answers

1. dynamic defect weighting は score-only baseline より score improvement を増やしたか: `False`.
2. score=4 false basin から score<4 は出たか: `False`.
3. score=4 false basin から score=0 は出たか: `False`. score0 は exact-like positive controls から出たもので、score=4 false basin 由来ではない。
4. D_min/S, P_tau, kappa は改善したか: best weighted escape rate `0.0` vs baseline `0.0`; see `weighting_by_mode_summary.csv`.
5. stubborn defect coordinate は減ったか: `not_supported` for dynamic modes. Static weighting changed support, but dynamic basic/stubborn/breakout/guard did not reduce median persistent support versus baseline.
6. weighting は S_w だけを改善して通常 S を悪化させたか: H-DW4 `supported`; breakout damage rate was `0.4791666666666667`.
7. どの weighting mode が最も有効だったか: none for score improvement. `dynamic_weighting_with_exactlike_guard` was the least harmful exactlike-oriented variant; `dynamic_weighting_breakout` reduced false-like final labels but mostly by moving to higher-score ambiguous/exact-like states.
8. exactlike guard は weighted false basin を防いだか: partially. Guard damage rate was `0.08333333333333333`, much lower than breakout `0.4791666666666667`, but it also missed several exact-like score0 closures.
9. H-DW1, H-DW2, H-DW3, H-DW4 の判定はどうか: `{"H_DW1": "not_supported", "H_DW2": "not_supported", "H_DW3": "supported_label_only", "H_DW4": "supported"}`.
10. 668 に戻すなら dynamic weighting を main descent, perturbation, repair preconditioner のどれとして使うべきか: not main descent. Treat it as a guarded perturbation / repair preconditioner candidate only; use exactlike guard and reject score-damaging breakout moves.

## Validation

- `sage sage/06_known_sds_regression.sage`: OK
- `sage sage/08_analyze_sds_candidate.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_baseline_score_only_recheck_r0_5f50c5e7835e.json`: OK
- `sage sage/05_validate_candidate_json.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_baseline_score_only_recheck_r0_5f50c5e7835e.json`: OK
- `sage sage/04_build_gs_from_sds.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_baseline_score_only_recheck_r0_5f50c5e7835e.json`: OK
- `sage sage/08_analyze_sds_candidate.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_baseline_score_only_recheck_r1_5f50c5e7835e.json`: OK
- `sage sage/05_validate_candidate_json.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_baseline_score_only_recheck_r1_5f50c5e7835e.json`: OK
- `sage sage/04_build_gs_from_sds.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_baseline_score_only_recheck_r1_5f50c5e7835e.json`: OK
- `sage sage/08_analyze_sds_candidate.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_static_weighted_score_r0_5f50c5e7835e.json`: OK
- `sage sage/05_validate_candidate_json.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_static_weighted_score_r0_5f50c5e7835e.json`: OK
- `sage sage/04_build_gs_from_sds.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_static_weighted_score_r0_5f50c5e7835e.json`: OK
- `sage sage/08_analyze_sds_candidate.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_static_weighted_score_r1_5f50c5e7835e.json`: OK
- `sage sage/05_validate_candidate_json.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_static_weighted_score_r1_5f50c5e7835e.json`: OK
- `sage sage/04_build_gs_from_sds.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_static_weighted_score_r1_5f50c5e7835e.json`: OK
- `sage sage/08_analyze_sds_candidate.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_basic_r0_5f50c5e7835e.json`: OK
- `sage sage/05_validate_candidate_json.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_basic_r0_5f50c5e7835e.json`: OK
- `sage sage/04_build_gs_from_sds.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_basic_r0_5f50c5e7835e.json`: OK
- `sage sage/08_analyze_sds_candidate.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_basic_r1_5f50c5e7835e.json`: OK
- `sage sage/05_validate_candidate_json.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_basic_r1_5f50c5e7835e.json`: OK
- `sage sage/04_build_gs_from_sds.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_basic_r1_5f50c5e7835e.json`: OK
- `sage sage/08_analyze_sds_candidate.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_stubborn_r0_5f50c5e7835e.json`: OK
- `sage sage/05_validate_candidate_json.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_stubborn_r0_5f50c5e7835e.json`: OK
- `sage sage/04_build_gs_from_sds.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_stubborn_r0_5f50c5e7835e.json`: OK
- `sage sage/08_analyze_sds_candidate.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_stubborn_r1_5f50c5e7835e.json`: OK
- `sage sage/05_validate_candidate_json.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_stubborn_r1_5f50c5e7835e.json`: OK
- `sage sage/04_build_gs_from_sds.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_stubborn_r1_5f50c5e7835e.json`: OK
- `sage sage/08_analyze_sds_candidate.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_breakout_r0_5f50c5e7835e.json`: OK
- `sage sage/05_validate_candidate_json.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_breakout_r0_5f50c5e7835e.json`: OK
- `sage sage/04_build_gs_from_sds.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_breakout_r0_5f50c5e7835e.json`: OK
- `sage sage/08_analyze_sds_candidate.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_breakout_r1_5f50c5e7835e.json`: OK
- `sage sage/05_validate_candidate_json.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_breakout_r1_5f50c5e7835e.json`: OK
- `sage sage/04_build_gs_from_sds.sage` `outputs/explorations/20260507_0100_p37_dynamic_defect_weighting_validation/score0_candidate_dynamic_weighting_breakout_r1_5f50c5e7835e.json`: OK
