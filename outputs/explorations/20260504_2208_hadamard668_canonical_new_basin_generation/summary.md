## Final Summary

1. 今回は Hadamard 668 SDS 探索に canonical hash / canonical dedup layer を追加し、guided search の near-hit を canonical bucket ごとに保存できるようにした。
2. 前回までの frontier は9本で、best score は 164、low-nonzero branch は score=184, l1=112, max_abs=3, nonzero=80。どちらも near-hit であり、解ではない。
3. canonical hash は、blockごとの平行移動正規化、全 unit multiplier、同サイズblockのみに限った permutation sorting で定義した。complement と異サイズblock permutation は入れていない。
4. canonical validation は通過した。既知SDS v=3,5,7 と既存near-hitで metrics が保存され、既存 frontier 9本は canonical class 9個に分かれた。
5. guided new-basin generation は primary branch [73,76,83,83], lambda=148 で smoke 実行した。フルの 1,000,000 steps x seeds 101-150 は未実行。
6. primary smoke の best は score=220, l1=140, max_abs=3, nonzero=104。既存 frontier は更新していない。
7. comparator [73,78,79,81] と optional [72,78,82,82] の guided run はまだ実行していない。
8. bucketed frontier smoke は6 bucketを保存した。canonical class count は16で、新しいcanonical candidate管理は動作している。
9. active-defect repair の entry point を 13_ilp_repair_from_near_hit.sage に実装した。pool-mode active_defect_lns、objective l1_then_nonzero / nonzero_then_l1、--swap-pool / --max-swaps を追加した。
10. active-defect smoke では score=220 の guided near-hit から score=192, l1=124, max_abs=3, nonzero=92 へ改善した。ただし既存 frontier に支配されるため frontier update ではない。
11. 好転サインとして、canonical bucket保存と active-defect LNS が no-op ではなく selected_moves=3 で動いた点は確認できた。
12. 悪いサインとして、smoke run の best は既存 frontier より弱く、active-defect output も既存 frontier に支配された。
13. route verdict は open_pending_guided_long_run。canonical dedup基盤は有効だが、探索成果の評価には長めの primary/comparator run が必要。
14. refined next candidates は、primary [73,76,83,83] の canonical guided long run、new basinへの active-defect repair、score=164 branchのactive-defect repair、Constantine one-block completion の順。
15. 今回の未解決点は、n=668 のSDS構成、success candidate生成、既存 frontier を超えるcanonical basin の発見。
16. 次に一点集中すべき探索候補は、[73,76,83,83], lambda=148 の canonical guided generation を seed 101-150 で本実行し、bucket上位だけを active-defect repair に回すこと。

今回は Hadamard 668 SDS の canonical-dedup new-basin generation を行った。
n=668 の Hadamard 行列構成には成功していない。
成功候補は、SDS検証と Goethals-Seidel HH^T=668I 検証を通った場合のみである。
near-hit / frontier / canonical basin は研究ログであり、解ではない。
得られたものは、canonical重複除去、新basin生成結果、bucketed frontier、次の active-defect repair 方針である。
