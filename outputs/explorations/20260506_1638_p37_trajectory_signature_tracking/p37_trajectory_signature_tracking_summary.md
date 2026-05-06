# p37 Trajectory Signature Tracking Summary

This run tracks trajectory signatures on p=37. It is not a Hadamard 668 construction run.

## Run

- p: `37`
- ks: `[13, 16, 18, 18]`
- lambda: `28`
- modes: `['score_only', 'threshold_accepting', 'mixed_diversity', 'exact_derived_return']`
- seeds: `20`
- steps: `3000`
- snapshot_interval: `100`

## Outcomes

```json
[
  {
    "escapable_final": 0,
    "false_basin_final": 0,
    "median_P_8_slope": -0.09001501501501502,
    "median_Q_ratio_slope": 2.260986658017908,
    "median_score_best": 0.0,
    "median_score_end": 0.0,
    "mode": "exact_derived_return",
    "run_count": 20,
    "success_score0": 20,
    "unknown_final": 0
  },
  {
    "escapable_final": 19,
    "false_basin_final": 0,
    "median_P_8_slope": -2.815315315315315e-05,
    "median_Q_ratio_slope": 0.0008243872407900307,
    "median_score_best": 12.0,
    "median_score_end": 24.0,
    "mode": "mixed_diversity",
    "run_count": 20,
    "success_score0": 0,
    "unknown_final": 1
  },
  {
    "escapable_final": 4,
    "false_basin_final": 4,
    "median_P_8_slope": -3.1637484258452005e-05,
    "median_Q_ratio_slope": 0.001595613914528625,
    "median_score_best": 8.0,
    "median_score_end": 12.0,
    "mode": "score_only",
    "run_count": 20,
    "success_score0": 0,
    "unknown_final": 12
  },
  {
    "escapable_final": 19,
    "false_basin_final": 0,
    "median_P_8_slope": -2.156137992831541e-05,
    "median_Q_ratio_slope": 0.00020607298613411476,
    "median_score_best": 10.0,
    "median_score_end": 30.0,
    "mode": "threshold_accepting",
    "run_count": 20,
    "success_score0": 0,
    "unknown_final": 1
  }
]
```

## Hypothesis Evaluation

```json
{
  "H15_score_only_Q_hardening": {
    "run_count": 20,
    "support_fraction": 0.85
  },
  "H16_false_basin_P_tau_declines": {
    "run_count": 4,
    "support_fraction": 1.0
  },
  "H17_false_basin_kappa_below_1": {
    "run_count": 4,
    "support_fraction": 1.0
  },
  "H4_false_basin_paths_disappear": {
    "run_count": 4,
    "support_fraction": 1.0
  },
  "H5_exact_paths_remain": {
    "run_count": 20,
    "support_fraction": 0.0
  },
  "H6_exact_basin_trap_like": {
    "run_count": 20,
    "support_fraction": 0.0
  },
  "mixed_diversity": {
    "distinct_final_hashes": 20,
    "median_P_8_slope": -2.815315315315315e-05,
    "median_Q_ratio_slope": 0.0008243872407900307,
    "run_count": 20
  },
  "threshold_accepting": {
    "escapable_final_count": 19,
    "false_basin_final_count": 0,
    "median_P_8_slope": -2.156137992831541e-05,
    "run_count": 20
  }
}
```

## Required Answers

1. false_basin_final trajectory は score が下がるほど D_min/S が悪化したか: `supported`.
2. false_basin_final trajectory は P_tau が低下したか: `supported`.
3. false_basin_final trajectory は kappa_max < 1 に閉じ込められたか: `supported`.
4. score-only は Q_ratio を悪化させやすかったか: `supported`.
5. threshold_accepting は false basin から抜ける兆候を作ったか: escapable_final `19`, false_basin_final `0`。
6. mixed_diversity は trajectory diversity を増やしたか: distinct final hashes `20` / runs `20`。
7. exact-derived または success trajectory は蟻地獄型だったか、それとも落とし穴型だったか: H5 `not_supported`, H6 `not_supported`。
8. H4, H5, H6, H15, H16, H17 の判定: H4 `supported`, H5 `not_supported`, H6 `not_supported`, H15 `supported`, H16 `supported`, H17 `supported`。
9. 次に p=43/47/668 へ拡張すべきか: `yes`, but use these as heuristic trajectory signatures, not absolute proof.
10. 668 の frontier / restart policy にどう反映すべきか: keep candidates with decreasing D_min/S and non-collapsing P_tau/kappa; restart or de-prioritize score drops with rising Q_ratio and vanishing P_tau.

## Validation

- `sage sage/06_known_sds_regression.sage`: all known SDS regressions passed.
- A representative score=0 candidate was saved at `outputs/explorations/20260506_1638_p37_trajectory_signature_tracking/score0_candidate_exact_derived_return_seed1.json`.
- `sage sage/08_analyze_sds_candidate.sage <score0_candidate>`: computed score=0, l1=0, max_abs=0.
- `sage sage/05_validate_candidate_json.sage <score0_candidate>`: SDS OK.
- `sage sage/04_build_gs_from_sds.sage <score0_candidate>`: `HH^T = 148I`.

## Notes

- `exact_derived_return` is a controlled return path using the known inverse perturbation moves. It is useful for H5/H6 calibration, but it is not evidence that unguided local search naturally finds the exact basin.
- H5 is marked `not_supported` because the controlled return path does not preserve high `P_tau` or increasing `kappa_max` all the way to score=0.
- H6 is marked `not_supported` because the exact-derived return path did not look locally dead immediately before closure under these diagnostics.
