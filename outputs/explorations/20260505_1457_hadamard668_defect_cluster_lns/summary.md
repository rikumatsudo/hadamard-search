# Final Summary

1. 今回は Hadamard 668 SDS の defect-vector clustering and bounded active-defect LNS prototype の分析基盤を作成した。
2. near-hit dataset を読み、保存metricsを差分カウントから再計算した。
3. metric correlation、Pareto frontier、canonical basin、defect cluster、repair transition を出力した。
4. partial membership LNS は `sage/21_partial_membership_lns_repair.sage` で実行する。
5. n=668 の Hadamard 行列構成には成功していない。
6. 成功候補は、SDS検証と Goethals-Seidel HH^T=668I 検証を通った場合のみである。
7. near-hit / frontier / defect cluster / LNS result は研究ログであり、解ではない。

## Partial Membership LNS Run Results

# Partial Membership LNS Results

- success_candidate_generated: `False`
- score_zero_reached: `False`

|input|before|after|solver|selected|accepted|reason|
|---|---|---|---|---|---|---|
|outputs/candidates/near_hits/near_hit_v167_score176_seed101_step8576.json|[176, 112, 3, 86]|[236, 144, 3, 104]|solved|2|False|score 236 exceeds before+slack 216|
|outputs/candidates/near_hits/near_hit_v167_score184_ilp_repair_from_near_hit_round1_4.json|[184, 112, 3, 80]|None|solver_error:CBC : The problem or its dual has been proven infeasible!|0|False|selected_count=0 or solver did not return a candidate|
|outputs/candidates/near_hits/near_hit_v167_score164_steepest_swap_descent_round1.json|[164, 116, 3, 96]|[240, 128, 4, 90]|solved|4|False|score 240 exceeds before+slack 204|

These are LNS diagnostics only. They are not SDS solutions and were not sent to Goethals-Seidel verification because score 0 was not reached.
