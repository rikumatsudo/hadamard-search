# Remote Research Runs

このリポジトリでは、`.github/workflows/research.yml` を使って
SageMath実験をGitHub Actions上で実行できます。

## まずLocal Smoke

workflowやconfigをpushする前、本番runをdispatchする前に、
最小のlocal `N=1` smoke testを実行します。

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

これが通るまでは、重いremote runを起動しません。

## Remote Smoke Runを起動する

```bash
env -u GITHUB_TOKEN gh workflow run research.yml \
  -f run_label=p167-actions-smoke \
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

artifactは `research-<run_label>-<run_id>` という名前でアップロードされます。
中には実験出力ディレクトリ、`runner.log`, `actions_summary.md`,
Slack通知payloadが含まれます。

## Slack通知

Slack incoming webhookを作成し、repository secretとして保存します。

```bash
env -u GITHUB_TOKEN gh secret set SLACK_WEBHOOK_URL --repo rikumatsudo/hadamard-search
```

`SLACK_WEBHOOK_URL` が未設定でもworkflowは実行され、artifactもuploadされます。
その場合、Slack通知stepだけskipされます。

## 本番run

GitHub Actionsで本番探索を走らせるのは、local smokeとremote smokeが通った後だけです。

本番runの順番:

1. local `N=1` smoke testを実行する。
2. レビュー済みの変更をpushする。
3. remote smoke workflowを実行する。
4. production runをfan-outする。

本番探索では、seed range、parameter tuple、config file単位でworkを分割します。
各shardには一意な `run_label` を付けます。workflowのconcurrency groupには
`run_label` が含まれるため、同じlabelを使うとrunが直列化される可能性があります。

public repositoryでstandard GitHub-hosted runnerを使う場合は、
GitHub Actionsの現在の並列上限まで並列化します。
GitHub Freeのstandard runnerでは、現時点では20 concurrent jobsが目安です。

fan-out数を増やす前には、GitHub Actionsの現在のlimitを確認します。
larger runnerはpublic repoでも有料なので、コスト承認なしには使いません。

## 注意

- workflowは `configs/experiments/*.yaml` 配下のconfigだけを受け付けます。
- 速い疎通確認には `configs/experiments/p167_tuple_A_actions_smoke.yaml` を使います。
- より重い診断を意図的に走らせる場合は、
  `configs/experiments/p167_tuple_A_exactlike_smoke.yaml` や大きめのconfigを使います。
- workflowのSageMath Docker imageは `sagemath/sagemath:10.8` に固定しています。
- 大きなraw outputはgitにcommitせず、Actions artifact、release、
  または外部研究ストレージで管理します。
- `score=0` 候補も、SDS検証とHadamard検証が通るまでは成功扱いしません。
