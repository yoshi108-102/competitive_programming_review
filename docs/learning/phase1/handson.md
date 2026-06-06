# Phase 1 ハンズオン — Cognito / API GW / Lambda / DynamoDB(本番観測) sandbox

## 前提条件

### AWS 認証と権限

以下の権限を持つ IAM ユーザーまたはロールで `aws configure` 済みであること。

- `cloudwatch:PutDashboard` / `cloudwatch:GetDashboard` / `cloudwatch:DeleteDashboards`
- `cloudwatch:GetMetricStatistics`
- `lambda:GetFunction`（本番 Lambda の参照のみ）
- `apigateway:GET`（本番 API GW の参照のみ）
- `dynamodb:DescribeTable`
- `cognito-idp:DescribeUserPool` / `cognito-idp:ListUserPools`

sandbox が書き込むのは CloudWatch ダッシュボード 1 本のみ。本番リソースへの書き込みは一切行わない。

### リージョン

`ap-northeast-1`（東京）。`AWS_DEFAULT_REGION=ap-northeast-1` を設定しておくか、`~/.aws/config` で default region を指定する。

```bash
export AWS_DEFAULT_REGION=ap-northeast-1
```

### 本番スタックの apply 完了

この sandbox は本番スタック（Lambda / API Gateway / DynamoDB / Cognito）を `data` source で lookup するだけであり、本番スタックが apply 済みであることが前提。未デプロイの場合は `make sandbox-load-phase1` でエラーになる（後述のトラブルシュートを参照）。

### tfvars の準備

`terraform/sandboxes/phase1/terraform.tfvars` に本番リソース名を書く（`.gitignore` 済みなのでコミット不要）。

```hcl
# terraform/sandboxes/phase1/terraform.tfvars の例
lambda_function_names  = [
  "atcoder-review-save-user-prod",
  "atcoder-review-sync-submissions-prod",
  "atcoder-review-get-submissions-prod"
]
api_gw_rest_api_id     = "atcoder-review-api-prod"   # API Name または ID
api_gw_stage_name      = "prod"
dynamodb_table_name    = "atcoder-review-submissions-prod"
cognito_user_pool_id   = "ap-northeast-1_XXXXXXXXX"  # terraform output cognito_user_pool_id
```

本番 output から取得する場合:

```bash
cd terraform   # プロジェクトルートの terraform/ ディレクトリ
terraform output
```

### 課金開始の注意

`make sandbox-up-phase1`（Terraform apply）を実行した瞬間から、CloudWatch ダッシュボード 1 本分の課金が始まる。料金は **月 $3 / ダッシュボード**（ap-northeast-1）。数時間の観測なら日割りで数円以下。観測が終わったら必ず `make sandbox-down-phase1` で削除すること。

---

## 全体の流れ

```
test → up → load → watch → down
  ↑        ↑        ↑        ↑        ↑
validate  apply  リクエ  CLI で   destroy
（無課金） ダッシュ  スト生成  メトリクス
          ボード作成  (2〜5分) 確認
```

| ステップ | コマンド | 内容 |
|---|---|---|
| 1 | `make sandbox-test-phase1` | terraform validate / plan（課金なし） |
| 2 | `make sandbox-up-phase1` | dashboard apply（課金開始） |
| 3 | `make sandbox-load-phase1` | API に無認証・不正トークンリクエストを投げてメトリクスを生成 |
| 4 | `make sandbox-watch-phase1` | CLI で各メトリクスを取得＋コンソール deep link 表示 |
| 5 | `make sandbox-down-phase1` | dashboard destroy（課金終了） |

---

## ステップ詳細

### ステップ 1: `make sandbox-test-phase1` — validate & plan

**何が起きるか**: `terraform validate` と `terraform plan` を実行する。本番リソースへの書き込みはゼロ。課金は発生しない。`data` source の lookup が成功するかどうかも確認できる。

**実行コマンド**:

```bash
make sandbox-test-phase1
```

**期待される出力例**:

```
==> terraform validate
Success! The configuration is valid.

==> terraform plan
data.aws_lambda_function.fns["atcoder-review-get-submissions-prod"]: Reading...
data.aws_lambda_function.fns["atcoder-review-save-user-prod"]: Reading...
data.aws_lambda_function.fns["atcoder-review-sync-submissions-prod"]: Reading...
data.aws_api_gateway_rest_api.main: Reading...
data.aws_dynamodb_table.main: Reading...
data.aws_cognito_user_pools.main: Reading...
data.aws_cloudwatch_log_group.lambda_logs["atcoder-review-get-submissions-prod"]: Reading...
...
Plan: 1 to add, 0 to change, 0 to destroy.
```

`Plan: 1 to add` の 1 件は `aws_cloudwatch_dashboard.phase1` のみ。それ以外の追加が出た場合は tfvars の内容を見直す。

**所要時間**: 15〜30 秒

---

### ステップ 2: `make sandbox-up-phase1` — ダッシュボード作成

**何が起きるか**: `terraform apply` を実行し、`phase1-sandbox` という名前の CloudWatch ダッシュボードを作成する。ダッシュボードには以下の 5 ウィジェットが含まれる:

- API GW — Requests & Errors (Count / 4XXError / 5XXError)
- API GW — Latency (P50 / P90 / P99)
- Lambda — Invocations & Errors（全 3 関数を 1 グラフに）
- DynamoDB — Consumed Capacity (Read / Write)
- Cognito — SignIn Successes & Token Refreshes

**実行コマンド**:

```bash
make sandbox-up-phase1
```

**期待される出力例**:

```
aws_cloudwatch_dashboard.phase1: Creating...
aws_cloudwatch_dashboard.phase1: Creation complete after 1s [id=phase1-sandbox]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:

dashboard_name = "phase1-sandbox"
dashboard_url = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=phase1-sandbox"
dynamodb_table_arn = "arn:aws:dynamodb:ap-northeast-1:123456789012:table/atcoder-review-submissions-prod"
lambda_function_arns = {
  "atcoder-review-get-submissions-prod" = "arn:aws:lambda:ap-northeast-1:123456789012:function:atcoder-review-get-submissions-prod"
  "atcoder-review-save-user-prod" = "arn:aws:lambda:ap-northeast-1:123456789012:function:atcoder-review-save-user-prod"
  "atcoder-review-sync-submissions-prod" = "arn:aws:lambda:ap-northeast-1:123456789012:function:atcoder-review-sync-submissions-prod"
}
```

`dashboard_url` に表示された URL をブラウザで開くとダッシュボードが確認できる。この時点ではメトリクスはまだ空。

**所要時間**: 5〜10 秒

---

### ステップ 3: `make sandbox-load-phase1` — ロード生成

**何が起きるか**: `load.sh` が以下のシナリオを順番に実行し、CloudWatch にメトリクスデータを積む。

| フェーズ | 内容 | 目的 |
|---|---|---|
| [1] 無認証 GET x50 | Authorization ヘッダーなしで `/submissions?limit=10` | API GW の Count・4XXError (401) を積む |
| [2] 不正トークン x10 | `Authorization: Bearer invalid.token.N` で GET | 4XXError をさらに積み、Cognito Authorizer の拒否を確認 |
| [3] 認証あり（任意） | `TEST_PASSWORD` 設定時のみ: Cognito サインイン後に GET x30 + POST /users x10 | Lambda の Invocations・DynamoDB の ConsumedWriteCapacityUnits を出す |

`load.sh` は本番 terraform output から `API_URL` / `USER_POOL_ID` / `CLIENT_ID` を自動取得する。環境変数を明示した場合はそちらが優先される。

**実行コマンド（最小: 無認証トラフィックのみ）**:

```bash
make sandbox-load-phase1
```

**実行コマンド（フル: 認証ありトラフィックも含む）**:

```bash
TEST_USERNAME=your@example.com TEST_PASSWORD=YourPass123! make sandbox-load-phase1
```

**期待される出力例（最小実行）**:

```
API_URL  = https://xxxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com/prod
REGION   = ap-northeast-1

=== [1] 無認証 GET /submissions x50 (Cognito Authorizer が 401 を返す) ===
  status: 401 401 401 401 401 401 401 401 401 401 401 401 401 401 401 ...
=== [2] 不正トークン GET /submissions x10 ===
  status: 401 401 401 401 401 401 401 401 401 401
=== [3] 認証ありトラフィックはスキップ (TEST_PASSWORD 未設定) ===
  handler Lambda の Invocations も出したい場合:
    TEST_USERNAME=you@example.com TEST_PASSWORD=... make sandbox-load-phase1

ロード生成 完了。メトリクス反映まで 2-5 分待ってから make sandbox-watch-phase1 を実行してください。
```

**期待される出力例（フル実行、認証成功時）**:

```
=== [3] Cognito 認証 -> 認証あり負荷 (USERNAME=your@example.com) ===
  サインイン成功。認証あり GET x30 + POST /users x10 を送信
200 200 200 200 200 ... （GET x30）
200 200 200 200 200 ... （POST /users x10）
```

**所要時間**: 約 1〜2 分（フルの場合は Cognito 認証が加わるため + 数十秒）

> メトリクス反映まで 2〜5 分待つこと。watch.sh は自動で 60 秒待機するが、その後さらにデータが増える場合もある。

---

### ステップ 4: `make sandbox-watch-phase1` — メトリクス観測

**何が起きるか**: `watch.sh` が以下の順で CLI 取得を実行し、最後にコンソール deep link を表示する。

1. `[0]` ダッシュボードの存在確認（`get-dashboard`）
2. 60 秒待機
3. `[1]` API Gateway: `5XXError` / `4XXError` / `Count` / `Latency` を直近 5 分で取得
4. `[2]` Lambda 全 3 関数: `Invocations` / `Errors` / `Duration` / `Throttles` / `ConcurrentExecutions`
5. `[3]` DynamoDB: `ConsumedReadCapacityUnits` / `ConsumedWriteCapacityUnits` / `SystemErrors` / `UserErrors` / `SuccessfulRequestLatency`
6. `[4]` Cognito: `SignInSuccesses` / `TokenRefreshSuccesses`

**実行コマンド**:

```bash
make sandbox-watch-phase1
```

**期待される出力例（抜粋）**:

```
INFO: CloudWatch メトリクスの反映には 1〜5 分かかります。
...
=== [0] Dashboard 存在確認 ===
phase1-sandbox
Dashboard OK

メトリクス反映まで最大 5 分かかります。60 秒待機します...

=== [1] API Gateway: 5XX / 4XX / Count / Latency ===
--- 4XXError ---
-----------------------------------------------------------------------
|                       GetMetricStatistics                           |
+----------+----------+----------+------------------+-----------------+
|  Average |  Maximum |    Sum   |    Timestamp     |    Unit         |
+----------+----------+----------+------------------+-----------------+
|  1.0     |  1.0     |  60.0    |  2026-06-06T...  |  Count          |
+----------+----------+----------+------------------+-----------------+
--- Count ---
...

=== [2] Lambda: Invocations / Errors / Duration / Throttles ===
--- Lambda: atcoder-review-get-submissions-prod ---
（TEST_PASSWORD 未設定の場合は Invocations が 0 または no data）
...

=== [3] DynamoDB: ConsumedReadCapacityUnits / ... ===
...

=== [4] Cognito: SignInSuccesses / TokenRefreshSuccesses ===
（Advanced Security 無効の場合は下記が出る）
SignInSuccesses: no data (Advanced Security may not be enabled)
TokenRefreshSuccesses: no data (Advanced Security may not be enabled)

=== Console Deep Links ===
CloudWatch Dashboard : https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=phase1-sandbox
API GW Metrics       : https://ap-northeast-1.console.aws.amazon.com/apigateway/main/apis/atcoder-review-api-prod/stages/prod/metrics
Lambda Monitoring    : https://ap-northeast-1.console.aws.amazon.com/lambda/home?region=ap-northeast-1#/functions
DynamoDB Metrics     : https://ap-northeast-1.console.aws.amazon.com/dynamodb/home?region=ap-northeast-1#tables:selected=atcoder-review-submissions-prod;tab=monitoring
Log Insights         : https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#logsV2:logs-insights

==========================================
観測が終わったら必ず: make sandbox-down-phase1
==========================================
```

**所要時間**: 60 秒待機 + メトリクス取得で合計 2〜3 分

---

### ステップ 5: `make sandbox-down-phase1` — ダッシュボード削除

**何が起きるか**: `terraform destroy` で `phase1-sandbox` ダッシュボードを削除する。data source で lookup した本番リソースには一切触れない。

**実行コマンド**:

```bash
make sandbox-down-phase1
```

**期待される出力例**:

```
aws_cloudwatch_dashboard.phase1: Destroying... [id=phase1-sandbox]
aws_cloudwatch_dashboard.phase1: Destruction complete after 0s

Destroy complete! Resources: 1 destroyed.
```

**所要時間**: 5〜10 秒。ダッシュボードは即時削除される（KMS 保留や CloudFront 伝播のような長時間待ちは発生しない）。

---

## 観察ポイント（チェックリスト）

CloudWatch コンソールで `phase1-sandbox` ダッシュボードを開き、以下を確認する。

### API Gateway ウィジェット

- [ ] `API GW - Requests & Errors` グラフで `Count`（青）が 50 以上立ち上がっている
- [ ] `4XXError`（橙）が `Count` とほぼ同数（ほぼ全リクエストが 401）になっている
- [ ] `5XXError`（赤）は 0 のまま（Lambda が直接エラーを返していないことの確認）
- [ ] `API GW - Latency (P50/P90/P99)` グラフで P50 < P90 < P99 の順に値が大きい

### Lambda ウィジェット

- [ ] `Lambda - Invocations & Errors` グラフで、TEST_PASSWORD 未設定時は Invocations が 0 または "no data" になっている（Cognito Authorizer が Lambda を呼ぶ前に 401 を返すため）
- [ ] TEST_PASSWORD 設定時は `atcoder-review-get-submissions-prod` と `atcoder-review-save-user-prod` の Invocations がそれぞれ立ち上がっている
- [ ] Errors が Invocations より小さい（あるいは 0）

### DynamoDB ウィジェット

- [ ] `DynamoDB - Consumed Capacity` グラフで、TEST_PASSWORD 設定時は `ConsumedWriteCapacityUnits`（POST /users 経由）が立ち上がっている
- [ ] PAY_PER_REQUEST モードでも `ConsumedReadCapacityUnits` と `ConsumedWriteCapacityUnits` はきちんと出ることを確認

### Cognito ウィジェット

- [ ] `Cognito - SignIn Successes & Token Refreshes` グラフで、Advanced Security (`ENFORCED`) が有効なら `SignInSuccesses` が立ち上がっている
- [ ] Advanced Security 無効の場合はグラフが空になる（CLI の出力に "no data" と出る）

### CLI 出力（`watch.sh`）

- [ ] `[0] Dashboard 存在確認` で `phase1-sandbox` と表示される
- [ ] `[1] API Gateway 4XXError` の Sum が 50 以上
- [ ] `[2] Lambda` の各関数でデータが返ってくる（または意図的に空であることを確認）
- [ ] `[3] DynamoDB` で `SystemErrors` が 0 のまま
- [ ] コンソール deep link が 5 本すべて表示される

---

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| `ERROR: API_URL を特定できませんでした。` | 本番スタックが未デプロイ、または `terraform output` が空 | `API_URL=https://xxxx.execute-api.ap-northeast-1.amazonaws.com/prod make sandbox-load-phase1` で直接渡す |
| `data.aws_lambda_function.fns: ... ResourceNotFoundException` | tfvars の `lambda_function_names` が本番の関数名と不一致 | `terraform -chdir=../../../terraform output` で正確な関数名を確認し tfvars を修正 |
| `data.aws_api_gateway_rest_api.main: ... NotFoundException` | `api_gw_rest_api_id` が不正 | AWS Console → API Gateway → APIs で正確な API 名を確認 |
| Cognito メトリクス (`SignInSuccesses`) が出ない | Cognito Advanced Security が `ENFORCED` でない | 出ないこと自体が正常（本番設定による）。CloudTrail → Event History → `InitiateAuth` で認証イベントを追う |
| `watch.sh` で全 Datapoints が空 | load.sh 直後にすぐ実行した | メトリクス反映に最大 5 分かかる。watch.sh は 60 秒待機するが足りない場合は再度 `make sandbox-watch-phase1` を実行 |
| `[3] 認証ありトラフィックはスキップ` が表示される | `TEST_PASSWORD` 未設定 | `TEST_USERNAME=xxx TEST_PASSWORD=yyy make sandbox-load-phase1` として再実行 |
| `サインインに失敗` と表示される | Cognito にテストユーザーが存在しない、またはパスワード不一致 | Cognito Console → User pools → ユーザーを確認する |
| Terraform apply が `Error: error creating CloudWatch Dashboard` | IAM に `cloudwatch:PutDashboard` 権限がない | IAM ポリシーを確認・追加 |

---

## コスト目安

| リソース | 料金 | 備考 |
|---|---|---|
| `aws_cloudwatch_dashboard` (phase1-sandbox) | ~$3 / 月 | ダッシュボード 1 本 (ap-northeast-1) |
| `cloudwatch:GetMetricStatistics`（`watch.sh`） | 無料枠内 | 1 万リクエスト / 月 無料 |
| API GW リクエスト（load.sh 経由） | 無料枠内 | 月 100 万リクエスト無料 |
| Lambda 実行（認証ありの場合） | 無料枠内 | 月 100 万リクエスト / 40 万 GB-秒 無料 |
| DynamoDB 書き込み（認証ありの場合） | 無料枠内 | 月 25 WCU（Provisioned）or 100 万書き込みリクエスト（PAY_PER_REQUEST）無料 |

数時間の観測であればダッシュボード料金の日割りで **数円以下**。

> destroy を忘れると翌月も課金が継続する。観測が終わったら直ちに `make sandbox-down-phase1` を実行すること。

---

## 後片付けの確認

`make sandbox-down-phase1` 実行後、以下をすべて確認してから終了すること。

- [ ] `terraform destroy` が `Destroy complete! Resources: 1 destroyed.` で終了している
- [ ] AWS Console → CloudWatch → Dashboards で `phase1-sandbox` が消えている
- [ ] タグ `Sandbox=phase1` が付いたリソースが残っていないこと（Console → Resource Groups & Tag Editor → タグ検索で確認）
- [ ] `terraform.tfstate` に `resources: []` 以外の残存リソースがないこと（`terraform show` で確認）
- [ ] Lambda ロググループ (`/aws/lambda/atcoder-review-*`) は **terraform destroy では消えない**。本番 Terraform 側で `retention_in_days` を設定して自動期限切れに任せること（sandbox 操作で意図せずログを消さないこと）
- [ ] KMS 保留や CloudFront 伝播など長時間待ちは本 sandbox では発生しない（ダッシュボードのみのため）
