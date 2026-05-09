# Hadamard Search for n = 668

このリポジトリは、位数 `668 = 4 * 167` のHadamard行列を探すための
SageMathスクリプト、実験config、GitHub Actions自動実行基盤をまとめたものです。

全ての `+1/-1` 行列を総当たりするのではなく、補助差集合
SDS、supplementary difference sets を探索します。

## 探索方針

1. `Z_167` 上で4つのSDSブロックを探す。
2. 各ブロックから4つの巡回 `+1/-1` 行列を作る。
3. Goethals-Seidel配列で位数668の行列を組む。
4. SageMathで次の厳密な恒等式を確認できた場合だけ成功とする。

```python
H * H.transpose() == 668 * identity_matrix(ZZ, 668)
```

near-hitや低スコア候補は研究用の途中成果です。検証前の候補は成功扱いしません。

## リポジトリ構成

```text
.
  .github/workflows/research.yml       GitHub Actionsのremote実行workflow
  configs/experiments/                 実験config
  docs/remote-research.md              remote実行とSlack通知の手順
  docs/optimization-roadmap.md          探索基盤の最適化roadmap
  docs/rust-search-engine.md           Rust探索エンジンMVPの説明
  engines/rust-search/                 高速探索エンジンMVP
  sage/                                SageMath/Pythonの研究スクリプト
  sage/64_verify_score0_candidates.sage Rust score0候補のSage厳密検証
  scripts/rust_candidates_to_sage.py   Rust出力のscore0候補をSage検証用JSONへ変換
  scripts/actions_summary.py           Actions artifactとSlack通知のsummary生成
  scripts/actions_aggregate.py         shard artifactの集約summary生成
  scripts/actions_shard_matrix.py      Actions matrixのshard生成
  outputs/                             軽量summaryと、git管理外の実行生成物
```

ログ、大きなJSONL/CSV、Actions artifact、cache類はgit管理しません。
remote実行の結果はGitHub Actionsのartifactから確認します。

## 必要なもの

- local実行用のSageMath `10.8`
- 補助スクリプト用のPython 3
- remote実行用のGitHub CLI `gh`
- GitHub ActionsのSage環境をlocalで再現したい場合のみDocker

GitHub Actionsでは `sagemath/sagemath:10.8` を使います。

## Local Smoke Test

workflowや実験configをpushする前、本番remote実行を始める前に、
必ずlocalで最小の `N=1` smoke testを通します。

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

このテストでは、config、import、Sage環境、出力処理、summary生成の入力が
壊れていないことを確認します。主な出力は一時ディレクトリに出ます。
`outputs/logs/` にもログが出ることがありますが、そこは `.gitignore` 対象です。

## GitHub ActionsでのRemote実行

remote実験は `workflow_dispatch` で手動起動します。

```bash
env -u GITHUB_TOKEN gh workflow run research.yml \
  -f run_label=p167-actions-smoke \
  -f engine=sage \
  -f config=configs/experiments/p167_tuple_A_actions_smoke.yaml \
  -f seeds=1 \
  -f steps=1 \
  -f snapshot_interval=1 \
  -f candidates_per_family=1 \
  -f selected_per_family=1 \
  -f max_repair_candidates=0
```

実行状況を見る:

```bash
env -u GITHUB_TOKEN gh run watch
```

Slack通知、artifact、production runの詳しい手順は
[docs/remote-research.md](docs/remote-research.md) にあります。

## 本番実行ルール

本番探索は次の順番で行います。

1. local `N=1` smoke testを通す。
2. 変更をpushする。
3. remote smoke testを通す。
4. 本番runをfan-outする。

リポジトリがpublicで、standard GitHub-hosted runnerを使う場合は、
GitHub Actionsの現在の並列上限まで独立runを並列化します。
GitHub Freeのstandard runnerでは、現時点では20並列が目安です。

Proの場合は40並列が目安です。本番runはseedを20等分または40等分し、
`shard_count` と `max_parallel` を指定して1つのworkflow run内でfan-outします。

各runには別々の `run_label` を付けます。同じ `run_label` を使うと、
workflowのconcurrency groupにより独立runが直列化される可能性があります。

larger runnerはコストが発生するため、明示的な承認なしには使いません。

探索基盤の最適化方針は
[docs/optimization-roadmap.md](docs/optimization-roadmap.md) にあります。

## 成功条件

候補が成功と見なされるのは、次の全てを満たした場合だけです。

- candidate JSONに `v = 167`, `n = 668`, 4つのblock size, `lambda`,
  `Z_167` 上の4つのblockが入っている。
- 全ての非ゼロshiftについてSDS差条件が検証されている。
- そのblockからGoethals-Seidel行列が生成されている。
- SageMathが `H * H.transpose() == 668 * identity_matrix(ZZ, 668)` を確認している。
- JSONに `verify_sds = true`, `generated_hadamard = true`, `hh_t = true` が記録されている。

## 主要スクリプト

- `sage/04_build_gs_from_sds.sage`: candidate JSONからGoethals-Seidel行列を構築して検証する。
- `sage/05_validate_candidate_json.sage`: SDS JSONの形式と差条件を検証する。
- `sage/06_known_sds_regression.sage`: 小さい既知SDSで回帰テストを行う。
- `sage/07_guided_sds_search_668.sage`: `Z_167` 上のguided local search。
- `sage/62_exactlike_guided_generator_validation.sage`: GitHub Actionsで使うconfig駆動の探索スクリプト。
- `sage/64_verify_score0_candidates.sage`: Rust engineのscore0候補をSageMathで厳密検証する。
- `sage/sds_repair_utils.py`: 検証、metric、repair用の共通helper。
- `engines/rust-search`: SageMathから探索カーネルを切り出すためのRust MVP。

## データ管理方針

public repoには、ソースコード、config、軽量summary、厳密検証fixtureだけを置きます。
大きな実行結果はGitHub Actions artifact、release、または外部研究ストレージで管理します。
