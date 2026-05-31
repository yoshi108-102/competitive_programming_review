# Phase 1 Sandbox — Cognito / API Gateway / Lambda / DynamoDB 観測

## このサンドボックスが作るもの

本番スタック(Lambda / API Gateway / DynamoDB / Cognito)を **data source で読み取り専用 lookup** し、
CloudWatch ダッシュボード 1 本(`phase1-sandbox`)だけを自分の state に作る。

本番 state・本番リソースには一切書き込まない。ダッシュボード以外のリソース作成ゼロ。

## 主要リソース構成

| 種類 | リソース名 | 詳細 |
|---|---|---|
| data source | `aws_lambda_function.fns` | 本番 Lambda 全関数を for_each で lookup |
| data source | `aws_api_gateway_rest_api.main` | 本番 REST API を lookup |
| data source | `aws_dynamodb_table.main` | 本番 DynamoDB テーブルを lookup |
| data source | `aws_cognito_user_pools.main` | 本番 User Pool を lookup |
| data source | `aws_cloudwatch_log_group.lambda_logs` | 本番 Lambda ロググループを lookup |
| **resource** | `aws_cloudwatch_dashboard.phase1` | ダッシュボード本体(唯一の管理リソース) |

ダッシュボードには以下のウィジェットが含まれる:

- API GW — Requests & Errors (Count / 4XXError / 5XXError)
- API GW — Latency (P50 / P90 / P99)
- Lambda — Invocations & Errors (全関数)
- DynamoDB — Consumed Capacity (Read / Write)
- Cognito — SignIn Successes & Token Refreshes

## 事前準備: tfvars を用意する

本番スタックのリソース名を `terraform output` で取得し、`terraform.tfvars` に書く。

```bash
# 本番スタックの output を確認する例
terraform -chdir=../../.. output
```

`terraform.tfvars` の例:

```hcl
lambda_function_names  = ["get_submissions", "save_user", "sync_submissions"]
api_gw_rest_api_id     = "xxxxxxxxxx"   # REST API ID または Name
api_gw_stage_name      = "prod"
dynamodb_table_name    = "atcoder-review-submissions"
cognito_user_pool_id   = "ap-northeast-1_XXXXXXXXX"
```

`terraform.tfvars` は `.gitignore` 済み。コミットしないこと。

## 使い方

```bash
# 1. validate のみ(無課金・本番に触れない)
make sandbox-test-phase1

# 2. ダッシュボードを作成(apply)
make sandbox-up-phase1

# 3. ロード生成(Cognito サインイン / API リクエスト / DynamoDB 書き込み)
#    事前に環境変数を設定すること:
#      export API_URL=https://xxxxxxx.execute-api.ap-northeast-1.amazonaws.com/prod
#      export USER_POOL_ID=ap-northeast-1_XXXXXXXXX
#      export CLIENT_ID=<Cognito App Client ID>
#      export TEST_PASSWORD=<テストユーザーのパスワード>
make sandbox-load-phase1

# 4. メトリクス観測(ロード後 2〜5 分待ってから実行)
#    事前に環境変数を設定すること:
#      export API_GW_ID=<REST API ID>
#      export LAMBDA_FUNCTION_NAMES="get_submissions save_user sync_submissions"
#      export DYNAMODB_TABLE_NAME=<テーブル名>
make sandbox-watch-phase1

# 5. ダッシュボードを削除(destroy)
make sandbox-down-phase1
```

`watch.sh` は終了時にコンソールの deep link を表示する。
ブラウザで CloudWatch → Dashboards → `phase1-sandbox` を開いても確認できる。

## ロード生成の内容 (load.sh)

| シナリオ | 目的 |
|---|---|
| Cognito 正常サインイン x1 + 意図的失敗 x3 | 4xx / SignInThrottle を出す |
| API GW 正常リクエスト x50 | Count / Latency を積む |
| 不正トークンで 401 x10 | 4XXError を意図的に積む |
| DynamoDB 書き込み x20 (save_user) | ConsumedWriteCapacityUnits を出す |
| sync_submissions 起動 x1 | Duration 分布を広げる(P99 が伸びる) |

## コスト・destroy 注意事項

- **課金リソースは `aws_cloudwatch_dashboard` のみ**。料金は月 3 ドル/ダッシュボード(ap-northeast-1)。
  観測が終わったら必ず `make sandbox-down-phase1` で削除すること。
- ダッシュボードは destroy で即時削除される。KMS 保留や CloudFront 伝播など長時間待ちは発生しない。
- Lambda ロググループ(`/aws/lambda/<function-name>`)は **terraform destroy では自動削除されない**。
  本番 Terraform 側で `retention_in_days = 1` を設定しておくことで、ログストレージ課金を抑える。
- Cognito の `SignInSuccesses` 等のメトリクスは `advanced_security_mode = "ENFORCED"` が有効でないと
  `AWS/Cognito` namespace に出ないことがある。その場合は CloudTrail Insights で `InitiateAuth` イベントを追う。
- メトリクス反映には最大 5 分かかる。`watch.sh` は 60 秒待機してから取得する。

## ファイル構成

```
terraform/sandboxes/phase1/
├── main.tf               # data sources + locals(dashboard body) + aws_cloudwatch_dashboard
├── variables.tf          # 本番リソース名を外から受け取る変数
├── outputs.tf            # dashboard_url / lambda_function_arns / dynamodb_table_arn
├── providers.tf          # aws ~> 5.0, required_version >= 1.7, default_tags
├── load.sh               # ロード生成スクリプト
├── watch.sh              # メトリクス観測 + console deep link
├── .terraform.lock.hcl   # 再現性のため git 管理対象
└── .gitignore            # *.tfstate* / .terraform/ / *.zip
```

## 関連ドキュメント

- 設計書: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md` (行 386〜782)
- 学習コンテキスト: `docs/LEARNING_CONTEXT.md`
- Makefile sandbox targets: `terraform/sandboxes/sandbox.mk`
