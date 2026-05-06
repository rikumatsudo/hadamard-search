# Defect-Targeted LNS Validation Summary

This is small-p algorithm validation for cyclic 4-block SDS repair, not a Hadamard 668 construction run.

## Target

- p: `37`
- ks: `[13, 16, 18, 18]`
- lambda: `28`
- exact imported p=37 solution excluded from repair seeds: `true`

## Previous Baseline

```json
{
  "energy_regularized_init": {
    "final_hard_basin": "5/10"
  },
  "escapability_aware": {
    "best_low_score_escapable": 8,
    "best_score": 4,
    "final_hard_basin": "15/20"
  },
  "mixed_diversity": {
    "final_hard_basin": "4/10"
  },
  "score_only": {
    "best_score": 4,
    "final_hard_basin": "17/20"
  }
}
```

## Current Aggregate

```json
{
  "best_score_seen": 4,
  "defect_targeted_retained_count": 39,
  "hard_score4_input_count": 2,
  "input_count": 3,
  "interaction_gap_max_norm": 144,
  "interaction_gap_nonzero_count": 22,
  "interaction_score_gap_values": [
    -144,
    -112,
    -80,
    -68,
    -36,
    -32,
    -24,
    -16,
    -8,
    -4,
    0,
    4
  ],
  "negative_cross_true_improvement_seen": false,
  "pair_level_global_score_decrease_seen": true,
  "retained_count": 174,
  "score0_seen": false,
  "score_lt_4_seen": false,
  "sparse_beam_true_improvement_seen": true,
  "threshold_hmin_negative_seen": true
}
```

## Mode Notes

- threshold_accepting_lns rows: `135`
- negative_cross_pair_search rows: `3`
- sparse_vector_cancellation_beam rows: `6`
- exact_joint_rswap_lns rows: `12`
- pair_level_partial_defect_repair rows: `18`
- interaction_gap_audit rows: `131`

## Required Answers

1. p=37 score=4 hard basin から score<4 は出たか: `False`.
2. score=0 は出たか: `False`.
3. threshold accepting は h_min<0 の状態を作れたか: `True`.
4. negative cross pair は true score 改善につながったか: `False`.
5. sparse vector cancellation は true recomputation でも有効だったか: `True`.
6. exact joint update と linearized update の mismatch は `22` 件、最大 interaction_norm `144`.
7. pair-level partial defect repair は score を下げたか: `True`.
8. defect-targeted scoring は h/kappa だけより有効だったか: hard score=4 では未確認。score=8 から score=4 への改善は h=-4/kappa=1.5 の単発 defect-targeted move で、h/kappa だけでも拾える範囲だった。
9. moment diagnostics は改善と揃ったか、それとも独立だったか: best score frontiers の moment_zero_count_6 は主に 0/1 で、今回の改善とは強く揃っていない。late-stage diagnostic としては保存したが objective にはしない。
10. 前回 baseline と比べて今回 repair は改善したか: score=0 は出ておらず success 改善なし。score=8 から score=4 への true repair と threshold 後の h_min<0 状態は出たが、前回 best score=4 の壁は破っていない。
11. この方針を 668 に戻す価値はあるか: weak positive。exact-joint mismatch と score=8 repair は有用だが、score=4 hard basin を閉じていないため、668 では主探索ではなく late-stage repair/audit として戻すのが妥当。

## Safety

- score=0 以外を success とは呼ばない。
- same-block multi-swap retained candidates are audited by exact joint update and full recomputation.
- moments were recorded as late-stage diagnostics, not early objective.
