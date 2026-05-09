# AGENTS.md

このルールはリポジトリ全体に適用します。

## 研究ワークフロー

- `score = 0` はあくまで有力候補です。SDS条件とGoethals-Seidel Hadamard恒等式を
  SageMathで厳密に検証できた場合だけ成功とします。
- workflowや実験configをpushする前に、必ずlocal `N=1` smoke testを実行します。

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

- local smokeが失敗した場合は、pushやGitHub Actions dispatchを行わず、localの問題を先に直します。
- `.github/workflows/research.yml` を変更した場合は、YAML検証とremote smoke testも行います。

## GitHub Actions運用

- このlocal環境では `env -u GITHUB_TOKEN gh ...` を使います。
  これにより、古い環境変数tokenではなく、keychain上の認証済みGitHub CLIアカウントを使えます。
- Slack webhook URL、token、secret類は表示・commitしません。
- Slack通知用webhookは、repository secret `SLACK_WEBHOOK_URL` にだけ保存します。
- 速いremote確認には `configs/experiments/p167_tuple_A_actions_smoke.yaml` を使います。
- 独立したremote runには別々の `run_label` を使います。
  workflowのconcurrency groupには `run_label` が含まれるため、同じlabelを使うと直列化される可能性があります。

## 本番runの並列化

本番探索は必ず次の順番で進めます。

1. local `N=1` smoke test
2. 変更をpush
3. remote smoke test
4. production fan-out

public repositoryでstandard GitHub-hosted runnerを使う場合は、独立したproduction runを
GitHub Actionsの現在の並列上限まで並列化します。GitHub Freeのstandard runnerでは、
GitHubの現在の制限が変わっていない限り、20 concurrent jobsを上限の目安にします。
GitHub Proでは40 concurrent jobsを上限の目安にします。

fan-out戦略を変える前には、GitHub Actionsの現在のlimitを確認します。
larger runnerはコストが発生するため、ユーザーの明示承認なしに使いません。

production workはseed、parameter tuple、config file単位で分割します。
各shardは再現可能にし、artifact名と `run_label` で内容が分かるようにします。
seed分割では `total_seeds`, `shard_index`, `shard_count` を使い、
20等分または40等分のように均等なshardへ分割します。
複数shardをまとめて起動できる場合は、個別に40回dispatchするのではなく、
`shard_count` と `max_parallel` によるmatrix fan-outを優先します。
Slack通知はaggregate jobから1回だけ送ります。
本番runのdispatchは、まず `scripts/dispatch_research_run.py` のdry-run出力を確認し、
内容が正しい場合だけ `--execute` を付けて起動します。

1つの長大なrunよりも、時間上限のあるrunを複数並べる方を優先します。
その方が失敗時の損失が小さく、Slack通知とartifact確認も早くなります。

## データ管理

- bulk生成物はcommitしません。
  例: `outputs/artifacts/`, `outputs/logs/`, 大きなJSONL/CSV diagnostics, cache, temp file。
- source、config、厳密検証fixture、reviewしやすい短いmarkdown/JSON summaryはcommitしてよいです。
- local pathやマシン固有設定をdocsに残しません。
- public向けREADMEは短く保ち、運用詳細は `docs/` に置きます。
