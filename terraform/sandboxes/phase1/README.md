# Phase 1 Sandbox — Cognito / API Gateway / Lambda / DynamoDB 観測

本番スタックの CloudWatch メトリクスを手軽に可視化するための **読み取り専用 sandbox**。
`data` source で本番リソースを lookup し、CloudWatch ダッシュボード 1 本だけを自分の state に作る。

---

## この sandbox が作るもの

| 種類 | リソース名 | 詳細 |
|---|---|---|
| data source | `aws_lambda_function.fns` | 本番 Lambda 全関数を for_each で lookup |
| data source | `aws_api_gateway_rest_api.main` | 本番 REST API を lookup |
| data source | `aws_dynamodb_table.main` | 本番 DynamoDB テーブルを lookup |
| data source | `aws_cognito_user_pools.main` | 本番 User Pool を lookup |
| data source | `aws_cloudwatch_log_group.lambda_logs` | 本番 Lambda ロググループを lookup |
| **resource** | `aws_cloudwatch_dashboard.phase1` | `phase1-sandbox`（唯一の管理リソース） |

ダッシュボードのウィジェット:

- API GW — Requests & Errors (Count / 4XXError / 5XXError)
- API GW — Latency (P50 / P90 / P99)
- Lambda — Invocations & Errors（全関数）
- DynamoDB — Consumed Capacity (Read / Write)
- Cognito — SignIn Successes & Token Refreshes

---

## クイックコマンド

```bash
# 1. validate + plan（課金なし・本番に触れない）
make sandbox-test-phase1

# 2. ダッシュボード作成（課金開始: ~$3/月）
make sandbox-up-phase1

# 3. メトリクス生成（無認証 x50 + 不正トークン x10）
make sandbox-load-phase1

# 3b. 認証ありメトリクスも出したい場合
TEST_USERNAME=your@example.com TEST_PASSWORD=YourPass123! make sandbox-load-phase1

# 4. CLI でメトリクス取得 + コンソール deep link 表示（load 後 2〜5 分待つ）
make sandbox-watch-phase1

# 5. ダッシュボード削除（課金終了）
make sandbox-down-phase1
```

事前に `terraform.tfvars` を用意すること（`.gitignore` 済み・コミット不要）:

```hcl
lambda_function_names  = [
  "atcoder-review-save-user-prod",
  "atcoder-review-sync-submissions-prod",
  "atcoder-review-get-submissions-prod"
]
api_gw_rest_api_id   = "atcoder-review-api-prod"
api_gw_stage_name    = "prod"
dynamodb_table_name  = "atcoder-review-submissions-prod"
cognito_user_pool_id = "ap-northeast-1_XXXXXXXXX"
```

本番 output から取得: `terraform -chdir=../../.. output`

---

## 詳しい手順

操作手順・期待出力・観察チェックリスト・トラブルシュートは handson ドキュメントを参照:

[docs/learning/phase1/handson.md](../../../docs/learning/phase1/handson.md)

---

## コスト・destroy 注意

- 課金リソースは `aws_cloudwatch_dashboard` のみ。**月 $3 / ダッシュボード**（ap-northeast-1）
- 観測が終わったら必ず `make sandbox-down-phase1` で削除すること
- ダッシュボードは destroy で即時削除（KMS 保留・長時間待ちは発生しない）
- Lambda ロググループ (`/aws/lambda/<function-name>`) は destroy では消えない。本番 Terraform 側で `retention_in_days` を設定して自動期限切れに任せること
- Cognito `SignInSuccesses` メトリクスは Advanced Security (`ENFORCED`) が有効でないと `AWS/Cognito` namespace に出ない。その場合は CloudTrail Insights で `InitiateAuth` イベントを追う

---

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

- ハンズオン詳細: `docs/learning/phase1/handson.md`
- 設計書: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md`（行 386〜782）
- 学習コンテキスト: `docs/LEARNING_CONTEXT.md`
- Makefile sandbox targets: `terraform/sandboxes/sandbox.mk`
