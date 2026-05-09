# Optimization Roadmap

このroadmapは、Hadamard探索基盤を「GitHub Actionsで動く」状態から、
「探索は高速言語、検証はSage、結果は自動集約」へ進めるための実装単位です。

## 方針

- SageMathは厳密検証に残す。
- 大量のswap探索、差分count更新、score計算は高速な探索エンジンへ切り出す。
- GitHub Actionsは1回のworkflow runで20/40 shardをfan-outし、最後に集約する。
- score=0候補だけをSage verifierへ渡し、SDS条件とGoethals-Seidel Hadamard条件を確認する。
- 本番runの前には必ずlocal smoke、remote smoke、小さなfan-out smokeを通す。

## PR分割

### PR 1: workflow fan-outと集約

- `shard_count` 指定だけでmatrix jobを作る。
- `max_parallel` で同時実行数を制御する。
- 各shardは個別artifactをuploadする。
- aggregate jobが全artifactを読み、best score、score0数、成功shard数を集約する。
- Slack通知はshardごとではなく、aggregate jobから1回だけ送る。

### PR 2: Sage runnerの軽量化

- configの `diagnostics` flagを実際の計算に反映する。
- smokeではone-swap全診断、構造量、momentなどを必要最小限にする。
- `run_trajectory` で毎stepの全count再計算を避け、swap deltaでincremental updateする。
- canonical hashの計算頻度を制御し、visited判定を軽量化する。
- p37/p167 smokeで既存出力形式を保つ。

### PR 3: Rust探索エンジンMVP

- `engines/rust-search` にCLIを追加する。
- 入力は既存のexperiment configと同じtarget/run/shard情報に寄せる。
- 出力は `candidates.jsonl`, `engine_summary.json`, `run_config.json` に固定する。
- Rust側は探索候補生成とscore計算までを担当する。
- score=0候補の厳密検証はSageに委譲する。

### PR 4: engine + Sage verifier連携

- workflow inputで `engine=sage|rust` を選べるようにする。
- Rust engine実行後、score=0候補だけSage verifierへ渡す。
- aggregate jobはSage/Rustどちらのsummaryも読めるようにする。
- p37 known SDSでRust出力とSage検証の一致テストを追加する。

実装メモ:

- `engine=rust` はRust探索、score0 candidate変換、Sage厳密検証を同一shard内で実行する。
- `sage/64_verify_score0_candidates.sage` が `comparison_summary.json` を生成するため、
  既存のartifact集約とSlack通知はSage/Rust共通で読める。
- Rust CIでは既知p37 exact candidateをRust風JSONLに変換し、Sage verifierで
  SDS条件と `HH^T = 148I` を確認する。

### PR 5: 本番運用チューニング

- p167向けのproduction configを整理する。
- 20 shard smoke、40 shard productionの推奨コマンドを固定する。
- artifact retention、summary粒度、Slack通知内容を本番向けに調整する。

## 言語選定

探索エンジンはRustを第一候補にする。

理由:

- 整数配列、swap、差分count、score更新のような処理で高速。
- 依存を小さくでき、GitHub Actionsでbuildしやすい。
- `serde` によるJSON入出力が安定している。
- C++よりメモリ安全性と保守性を取りやすい。
- JuliaよりCI起動と依存解決を軽くしやすい。

SageMathは次の用途に限定する。

- SDS差条件の厳密検証。
- Goethals-Seidel行列の構築。
- `H * H.transpose() == n * I` の確認。
- 小さい既知例による回帰テスト。

## 完了条件

- `shard_count=40` の1 workflow runで40 jobがfan-outされる。
- Slack通知はaggregate結果として1件だけ届く。
- local smokeとremote smokeが通る。
- Rust engineのp37 smokeがSage verifierと一致する。
- p167のproduction runでartifactからbest scoreとscore0数を即座に確認できる。
