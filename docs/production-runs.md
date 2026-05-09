# Production Runs

この手順は、public repoのstandard GitHub-hosted runnerでp167 tuple Aを
Rust探索エンジンにより並列探索し、score0候補だけSageMathで厳密検証する運用です。

## 前提

- repository secret `SLACK_WEBHOOK_URL` が設定済み。
- GitHub CLIは `env -u GITHUB_TOKEN gh ...` で使う。
- GitHub Proのstandard runnerでは40 concurrent jobsを上限の目安にする。
- larger runnerは有料なので、明示承認なしに使わない。

## 順番

1. local `N=1` smoke testを通す。
2. 変更をpushする。
3. `engine=rust` remote smokeを通す。
4. 20 shard fan-out smokeを通す。
5. 40 shard productionを起動する。

local smoke:

```bash
DOT_SAGE=${TMPDIR:-/tmp}/sage-dot \
sage sage/62_exactlike_guided_generator_validation.sage \
  --config configs/experiments/p167_tuple_A_actions_smoke.yaml \
  --out-dir "${TMPDIR:-/tmp}/hadamard-local-smoke" \
  --seeds 1 \
  --steps 1 \
  --snapshot-interval 1 \
  --candidates-per-family 1 \
  --selected-per-family 1 \
  --max-repair-candidates 0
```

## Dispatch helper

`scripts/dispatch_research_run.py` は、まずdry-runとして実行コマンドを表示します。
表示内容を確認してから `--execute` を付けます。

Rust remote smoke:

```bash
python3 scripts/dispatch_research_run.py \
  --preset rust-smoke \
  --ref main \
  --run-label p167-rust-smoke-YYYYMMDD
```

実行:

```bash
python3 scripts/dispatch_research_run.py \
  --preset rust-smoke \
  --ref main \
  --run-label p167-rust-smoke-YYYYMMDD \
  --execute
```

20 shard fan-out smoke:

```bash
python3 scripts/dispatch_research_run.py \
  --preset fanout-20 \
  --ref main \
  --run-label p167-rust-20x-smoke-YYYYMMDD \
  --total-seeds 40 \
  --steps 100 \
  --artifact-retention-days 14
```

40 shard production:

```bash
python3 scripts/dispatch_research_run.py \
  --preset production-40 \
  --ref main \
  --run-label p167-rust-40x-YYYYMMDD
```

1 shardだけ再実行:

```bash
python3 scripts/dispatch_research_run.py \
  --preset rerun-shard \
  --ref main \
  --run-label p167-rust-40x-YYYYMMDD-rerun-s00 \
  --shard-index 0
```

## 手動コマンド

helperを使わずに40 shard productionを起動する場合:

```bash
env -u GITHUB_TOKEN gh workflow run research.yml \
  --repo rikumatsudo/hadamard-search \
  --ref main \
  -f run_label=p167-rust-40x-YYYYMMDD \
  -f engine=rust \
  -f config=configs/experiments/p167_tuple_A_rust_production.yaml \
  -f total_seeds=400 \
  -f shard_count=40 \
  -f max_parallel=40 \
  -f steps=10000 \
  -f artifact_retention_days=30
```

## 結果確認

run完了後は、aggregate artifactを見る。

- `aggregate_summary.md`: 人間が読むsummary。
- `aggregate_summary.json`: 機械的に再集計しやすいsummary。
- `aggregate_slack_payload.json`: Slack通知payload。

各shard artifactには次が入る。

- `engine_summary.json`: Rust探索のbest score、score0数、seed partition。
- `candidates.jsonl`: seedごとのbest candidate。
- `score0_candidates.json`: Sage verifierへ渡したscore0 candidate一覧。
- `comparison_summary.json`: aggregateが読む共通summary。
- `verification_summary.json`: Sage verifierの厳密検証結果。

成功扱いできるのは、`verification_summary.json` で `hadamard_ok_count` が1以上、
かつ該当candidate JSONに `verify_sds=true`, `generated_hadamard=true`, `hh_t=true`
が記録されている場合だけです。
