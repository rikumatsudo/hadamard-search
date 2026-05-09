# Rust Search Engine

`engines/rust-search` は、SageMathから探索カーネルを切り出すためのMVPです。

## 役割

- `configs/experiments/*.yaml` からtargetとrun設定を読む。
- seed rangeまたはseed shardを解決する。
- `Z_p` 上の4ブロックを生成し、one-swap改善探索を行う。
- `candidates.jsonl` と `engine_summary.json` を出力する。

このMVPは候補生成までを担当します。
SDS条件とGoethals-Seidel Hadamard条件の厳密検証は引き続きSageMathで行います。

## 実行例

```bash
cargo run --release --manifest-path engines/rust-search/Cargo.toml -- \
  --config configs/experiments/p167_tuple_A_actions_smoke.yaml \
  --out-dir /tmp/hadamard-rust-smoke \
  --seeds 1 \
  --steps 1
```

40 shardのうち1 shardだけ実行する例:

```bash
cargo run --release --manifest-path engines/rust-search/Cargo.toml -- \
  --config configs/experiments/p167_tuple_A_actions_smoke.yaml \
  --out-dir /tmp/hadamard-rust-s00 \
  --total-seeds 200 \
  --shard-count 40 \
  --shard-index 0 \
  --steps 10000
```

## 出力

- `candidates.jsonl`: seedごとのbest candidate。
- `engine_summary.json`: best score、score0数、seed partition。
- `engine_summary.md`: 人間が読むための短いsummary。
- `run_config.json`: 実行時に解決されたtarget/run情報。

`scripts/rust_candidates_to_sage.py` で `candidates.jsonl` からscore0候補だけを
Sage検証用candidate JSONへ変換できます。

```bash
python3 scripts/rust_candidates_to_sage.py \
  --candidates /tmp/hadamard-rust-smoke/candidates.jsonl \
  --out-dir /tmp/hadamard-rust-smoke/score0_candidates \
  --summary /tmp/hadamard-rust-smoke/score0_candidates.json
```

## 制限

- YAML parserはこのrepoのexperiment configに必要なキーだけを読む軽量実装です。
- exact-like scoring、repair、frontier管理はまだSage runner側にあります。
- score=0候補の厳密検証は、変換されたcandidate JSONをSage verifierへ渡して行います。
  workflow内での自動接続は次PRで行います。
