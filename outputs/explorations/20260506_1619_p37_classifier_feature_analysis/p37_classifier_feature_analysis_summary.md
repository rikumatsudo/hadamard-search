# p37 Classifier Feature Analysis Summary

This analysis reads existing pipeline classifier rows only. No new SDS search was run.

## Input

- input_dir: `outputs/explorations/20260506_1557_p37_pipeline_framework`
- merged classifier rows: `100`
- labels: `{'exact': 1, 'search_derived_false_basin': 36, 'unknown': 44, 'hard_basin': 2, 'exact_derived': 17}`

## Missing / Derived Features

- Missing requested features with no values: `['kappa_q95']`
- Derived features: `h_min_over_S`, `near_improving_count_h_le_4/8/16` when source fields allowed it.
- `kappa_q95` was not present in the current diagnostic rows.

## Strongest Separators

```json
[
  {
    "auc_like_A_gt_B": 0.0,
    "auc_like_A_lt_B": 1.0,
    "count_a": 17,
    "count_b": 36,
    "effect_size": -4.9767129354632695,
    "exact_like_auc": 1.0,
    "exact_like_direction": "low",
    "feature": "h_min",
    "label_a": "exact_derived",
    "label_b": "search_derived_false_basin",
    "mean_a": -32.0,
    "mean_b": 3.2222222222222223,
    "mean_difference": -35.22222222222222,
    "median_a": -32.0,
    "median_b": 4.0,
    "median_difference": -36.0
  },
  {
    "auc_like_A_gt_B": 1.0,
    "auc_like_A_lt_B": 0.0,
    "count_a": 17,
    "count_b": 36,
    "effect_size": 4.1854957298236135,
    "exact_like_auc": 1.0,
    "exact_like_direction": "high",
    "feature": "P_16",
    "label_a": "exact_derived",
    "label_b": "search_derived_false_basin",
    "mean_a": 0.3340840840840841,
    "mean_b": 0.10629379379379379,
    "mean_difference": 0.2277902902902903,
    "median_a": 0.34459459459459457,
    "median_b": 0.10810810810810811,
    "median_difference": 0.23648648648648646
  },
  {
    "auc_like_A_gt_B": 1.0,
    "auc_like_A_lt_B": 0.0,
    "count_a": 17,
    "count_b": 36,
    "effect_size": 4.1854957298236135,
    "exact_like_auc": 1.0,
    "exact_like_direction": "high",
    "feature": "near_improving_count_h_le_16",
    "label_a": "exact_derived",
    "label_b": "search_derived_false_basin",
    "mean_a": 445.0,
    "mean_b": 141.58333333333334,
    "mean_difference": 303.41666666666663,
    "median_a": 458.99999999999994,
    "median_b": 144.0,
    "median_difference": 314.99999999999994
  },
  {
    "auc_like_A_gt_B": 1.0,
    "auc_like_A_lt_B": 0.0,
    "count_a": 17,
    "count_b": 36,
    "effect_size": 3.8313634961186582,
    "exact_like_auc": 1.0,
    "exact_like_direction": "high",
    "feature": "kappa_q99",
    "label_a": "exact_derived",
    "label_b": "search_derived_false_basin",
    "mean_a": 1.599953314659197,
    "mean_b": 0.5227623456790123,
    "mean_difference": 1.0771909689801848,
    "median_a": 1.6,
    "median_b": 0.5714285714285714,
    "median_difference": 1.0285714285714287
  },
  {
    "auc_like_A_gt_B": 1.0,
    "auc_like_A_lt_B": 0.0,
    "count_a": 17,
    "count_b": 36,
    "effect_size": 3.661923001799029,
    "exact_like_auc": 1.0,
    "exact_like_direction": "high",
    "feature": "kappa_q90",
    "label_a": "exact_derived",
    "label_b": "search_derived_false_basin",
    "mean_a": 0.9698391477803243,
    "mean_b": 0.3033810325476992,
    "mean_difference": 0.6664581152326251,
    "median_a": 1.0,
    "median_b": 0.3333333333333333,
    "median_difference": 0.6666666666666667
  },
  {
    "auc_like_A_gt_B": 0.0,
    "auc_like_A_lt_B": 1.0,
    "count_a": 17,
    "count_b": 36,
    "effect_size": -3.4155971813881085,
    "exact_like_auc": 1.0,
    "exact_like_direction": "low",
    "feature": "Q_ratio",
    "label_a": "exact_derived",
    "label_b": "search_derived_false_basin",
    "mean_a": 7.408604422884988,
    "mean_b": 54.464699074074076,
    "mean_difference": -47.056094651189085,
    "median_a": 5.510416666666667,
    "median_b": 38.60416666666667,
    "median_difference": -33.09375000000001
  },
  {
    "auc_like_A_gt_B": 1.0,
    "auc_like_A_lt_B": 0.0,
    "count_a": 17,
    "count_b": 36,
    "effect_size": 3.301255642187999,
    "exact_like_auc": 1.0,
    "exact_like_direction": "high",
    "feature": "P_8",
    "label_a": "exact_derived",
    "label_b": "search_derived_false_basin",
    "mean_a": 0.2063239710298534,
    "mean_b": 0.015098431765098431,
    "mean_difference": 0.19122553926475497,
    "median_a": 0.21621621621621623,
    "median_b": 0.014264264264264264,
    "median_difference": 0.20195195195195195
  },
  {
    "auc_like_A_gt_B": 1.0,
    "auc_like_A_lt_B": 0.0,
    "count_a": 17,
    "count_b": 36,
    "effect_size": 3.3012556421879986,
    "exact_like_auc": 1.0,
    "exact_like_direction": "high",
    "feature": "near_improving_count_h_le_8",
    "label_a": "exact_derived",
    "label_b": "search_derived_false_basin",
    "mean_a": 274.8235294117647,
    "mean_b": 20.11111111111111,
    "mean_difference": 254.71241830065358,
    "median_a": 288.0,
    "median_b": 19.0,
    "median_difference": 269.0
  }
]
```

## Rule Evaluation

```json
[
  {
    "ExactLikeScore_ambiguous_margin": 1.7965393713240227,
    "ExactLikeScore_exact_median": 4.114585017008181,
    "ExactLikeScore_false_median": -3.0715724682879104,
    "ExactLikeScore_threshold": 0.5215062743601351,
    "P_4_median": 0.011636636636636636,
    "P_8_median": 0.036036036036036036,
    "accuracy": 1.0,
    "evaluated_count": 55,
    "fn_exact_like": 0,
    "fp_exact_like": 0,
    "missing_count": 1,
    "precision_exact_like": 1.0,
    "precision_false_like": 1.0,
    "recall_exact_like": 1.0,
    "recall_false_like": 1.0,
    "rule_name": "D_min_ratio_rule",
    "tn_false_like": 38,
    "tp_exact_like": 17
  },
  {
    "ExactLikeScore_ambiguous_margin": 1.7965393713240227,
    "ExactLikeScore_exact_median": 4.114585017008181,
    "ExactLikeScore_false_median": -3.0715724682879104,
    "ExactLikeScore_threshold": 0.5215062743601351,
    "P_4_median": 0.011636636636636636,
    "P_8_median": 0.036036036036036036,
    "accuracy": 0.7857142857142857,
    "evaluated_count": 56,
    "fn_exact_like": 1,
    "fp_exact_like": 11,
    "missing_count": 0,
    "precision_exact_like": 0.6071428571428571,
    "precision_false_like": 0.9642857142857143,
    "recall_exact_like": 0.9444444444444444,
    "recall_false_like": 0.7105263157894737,
    "rule_name": "kappa_rule",
    "tn_false_like": 27,
    "tp_exact_like": 17
  },
  {
    "ExactLikeScore_ambiguous_margin": 1.7965393713240227,
    "ExactLikeScore_exact_median": 4.114585017008181,
    "ExactLikeScore_false_median": -3.0715724682879104,
    "ExactLikeScore_threshold": 0.5215062743601351,
    "P_4_median": 0.011636636636636636,
    "P_8_median": 0.036036036036036036,
    "accuracy": 0.9821428571428571,
    "evaluated_count": 56,
    "fn_exact_like": 1,
    "fp_exact_like": 0,
    "missing_count": 0,
    "precision_exact_like": 1.0,
    "precision_false_like": 0.9743589743589743,
    "recall_exact_like": 0.9444444444444444,
    "recall_false_like": 1.0,
    "rule_name": "P_tau_rule",
    "tn_false_like": 38,
    "tp_exact_like": 17
  },
  {
    "ExactLikeScore_ambiguous_margin": 1.7965393713240227,
    "ExactLikeScore_exact_median": 4.114585017008181,
    "ExactLikeScore_false_median": -3.0715724682879104,
    "ExactLikeScore_threshold": 0.5215062743601351,
    "P_4_median": 0.011636636636636636,
    "P_8_median": 0.036036036036036036,
    "accuracy": 0.9821428571428571,
    "evaluated_count": 56,
    "fn_exact_like": 1,
    "fp_exact_like": 0,
    "missing_count": 0,
    "precision_exact_like": 1.0,
    "precision_false_like": 0.9743589743589743,
    "recall_exact_like": 0.9444444444444444,
    "recall_false_like": 1.0,
    "rule_name": "composite_rule",
    "tn_false_like": 38,
    "tp_exact_like": 17
  }
]
```

## Unknown Relabel Suggestions

```json
{
  "unknown_ambiguous": 11,
  "unknown_exact_like": 16,
  "unknown_false_like": 17
}
```

## Required Answers

1. exact_derived と search_derived_false_basin は、score 以外の特徴量で分かれたか: `yes`。ただし p=37 pipeline の heuristic label 上での初期検証であり、確定分類器ではない。
2. 最も効いた feature は何か: `h_min, P_16, near_improving_count_h_le_16, kappa_q99, kappa_q90`.
3. D_min_ratio は primary classifier として有効か: median exact_derived `0.4375`, false_basin `1.50000000000000`, exact-like AUC `1.0`。
4. P_tau は local entropy feature として有効か: P_4 AUC `1.0`, P_8 AUC `1.0`。
5. kappa_max は g/q separation feature として有効か: median exact_derived `2.3333333333333335`, false_basin `0.775000000000000`, exact-like AUC `1.0`。
6. Q_ratio / InitHardness は primary か secondary か: Q_ratio effect `-3.4155971813881085`, InitHardness effect `1.1638621277987231`。現段階では secondary と扱う。
7. unknown candidates は exact-like と false-like に再分類できそうか: `{'unknown_false_like': 17, 'unknown_ambiguous': 11, 'unknown_exact_like': 16}`。
8. p=37 で得た classifier を 668 に使う場合の注意点: label は heuristic で、p=37 exact distance proxy に依存する。668 では exact がないため absolute threshold ではなく rank / trajectory / repair response として使うべき。
9. 次に Codex で検証すべき feature / trajectory 実験: D_min_ratio, P_4/P_8, kappa_max の composite score を trajectory frontier selection に入れ、p=43/47 と 668 low-score rows で同じ feature table を比較する。
