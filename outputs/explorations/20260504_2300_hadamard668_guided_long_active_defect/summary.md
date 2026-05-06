# Final Summary

## Final Summary

1. 今回は [73,76,83,83], lambda=148 の canonical guided long run の先頭スライスを実行した。
2. 前回までの状態は、既存frontier 9本、canonical class 9個、best score=164、best l1=112、best nonzero=80。
3. requested full run は 1,000,000 steps x seeds 101-150 だが、実行時間が大きいため seed=101, 20,000 steps の同設定スライスを実行した。
4. guided slice の best は score=224, l1=152, max_abs=3, nonzero=120。score=0 は出ていない。
5. canonical basin comparison では guided slice は新しいcanonical bucket entriesを生成したが、既存frontierを超えるものは出ていない。
6. bucketed frontier は score/l1/nonzero/max_abs/lex_score_l1/lex_nonzero_l1 の6 bucketで保存された。
7. repair target selection では strict/relaxed thresholds を満たす候補がなく、active-defect repair対象は選ばれなかった。
8. active-defect repair はこのsliceからは実行していない。前回のdiagnostic smokeでは動作確認済みだが、今回は新規qualified targetなし。
9. 成功候補は出ていない。score=0 も出ていない。
10. 好転サインは canonical bucket保存が安定して動いたこと。強い好転サインである score<164, l1<112, nonzero<80 は出ていない。
11. 悪いサインは、primary slice の best が既存frontierよりかなり弱いこと。
12. failure mode は guided search returns weak basins / no repair target qualified。
13. route verdict は existing_frontier_remains_dominant_on_executed_slice。
14. refined next candidates は comparator [73,78,79,81] long run、primary objective schedule変更、既存low-nonzero branch active-defect repair。
15. 未解決点は n=668 SDS、success candidate、既存frontierを超えるnew canonical basin。
16. 次に一点集中すべき探索候補は [73,78,79,81], lambda=144 の comparator canonical guided run、または [73,76,83,83] の nonzero/l1-first schedule である。

今回は Hadamard 668 SDS の canonical guided long run and active-defect repair を行った。
n=668 の Hadamard 行列構成には成功していない。
成功候補は、SDS検証と Goethals-Seidel HH^T=668I 検証を通った場合のみである。
near-hit / frontier / canonical basin は研究ログであり、解ではない。
得られたものは、canonical guided long run の結果、bucketed frontier、active-defect repair 結果、次の探索方針である。
