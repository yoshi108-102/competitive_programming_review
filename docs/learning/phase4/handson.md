# Phase 4 ハンズオン — CloudWatch sandbox

## 前提条件

### AWS 認証・権限

- `aws configure` または環境変数（`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`）で ap-northeast-1 に対して有効な認証情報が設定されていること
- 必要な IAM 権限: CloudWatch フルアクセス、Lambda フルアクセス、DynamoDB フルアクセス、IAM ロール作成、SNS、KMS（キー作成・削除・暗号化）、logs:*
- 権限が不足している場合は `AdministratorAccess` を持つロールで実行する

### ツール

- Terraform >= 1.7 (`terraform -version` で確認)
- AWS CLI v2 (`aws --version` で確認)
- `make` が使えること（`make sandbox` でヘルプ確認）
- Python 3.12（Lambda ランタイムと同じバージョンだとローカル確認しやすい）

### リージョン

このサンドボックスはすべて **ap-northeast-1（東京）** に作る。`AWS_REGION` 環境変数か `aws configure` のデフォルトリージョンを一致させておく。

### 課金開始の注意

`make sandbox-up-phase4` を実行した時点から AWS 課金が始まる。以下のリソースが生成される。

- KMS カスタムキー: 1 キーあたり $1.00/月（数時間なら数セント）
- Lambda Insights カスタムメトリクス: 合計数本、無料枠（10 メトリクス）内に収まる
- カスタムメトリクス `Phase4/Lambda` 名前空間: 3 本、同様に無料枠内

観測が終わったら **必ず** `make sandbox-down-phase4` を実行すること。

### Phase 固有の前提: SNS メール確認

`apply` 後に指定メールアドレス（デフォルト: `variables.tf` の `alert_email`）に AWS から確認メールが届く。メール内の **Confirm subscription** リンクをクリックしないとアラームが ALARM になっても通知が届かない。通知を受け取る必要がない場合はスキップしてよい。メールアドレスを変えるには apply 時に上書きする。

```bash
make sandbox-up-phase4 TF_VAR_alert_email=your@example.com
```

---

## 全体の流れ

```
sandbox-test-phase4  →  sandbox-up-phase4  →  sandbox-load-phase4  →  sandbox-watch-phase4  →  sandbox-down-phase4
(validate・無料)         (apply・課金開始)    (負荷生成・2〜3分)       (メトリクス・アラーム観測)   (destroy・課金停止)
```

---

## ステップ詳細

### ステップ 1: `make sandbox-test-phase4` — Terraform validate（無料）

**何が起きるか**

`backend/tests/sandboxes/phase4/` が存在しない場合は moto テストをスキップし、`terraform init -backend=false` → `terraform validate` を実行する。実リソースは何も作らない。

**実行コマンド**

```bash
make sandbox-test-phase4
```

**期待される出力例**

```
==> phase4 に moto テストなし (validate のみ)
==> terraform validate phase4
Success! The configuration is valid.
```

**所要時間**: 15〜30 秒（provider プラグインのキャッシュが温まっていれば短縮）

---

### ステップ 2: `make sandbox-up-phase4` — Terraform apply（課金開始）

**何が起きるか**

`terraform init` → `terraform apply -auto-approve` を実行する。以下のリソースが作られる。

| リソース | 名前 |
|---|---|
| KMS キー | `alias/phase4-cw-logs` |
| CloudWatch Log Group | `/aws/lambda/phase4-producer` |
| CloudWatch Log Group | `/aws/lambda/phase4-consumer` |
| CloudWatch Log Group | `/aws/lambda-insights` |
| IAM ロール | `phase4-lambda-producer` / `phase4-lambda-consumer` |
| DynamoDB テーブル | `phase4-events` |
| Lambda | `phase4-producer` |
| Lambda | `phase4-consumer` |
| Metric Filter (3 本) | `ProducerErrorCount` / `ConsumerErrorCount` / `ItemsWritten` |
| SNS トピック | `phase4-alerts` |
| SNS サブスクリプション | 指定メールアドレス |
| CloudWatch Alarm (2 本) | `phase4-producer-errors` / `phase4-producer-duration-high` |
| Composite Alarm | `phase4-critical` |
| CloudWatch Dashboard | `phase4-overview` |

**実行コマンド**

```bash
make sandbox-up-phase4
```

**期待される出力例**

```
Terraform will perform the following actions:
  # aws_kms_key.cw_logs will be created
  # aws_cloudwatch_log_group.producer_logs will be created
  # aws_lambda_function.producer will be created
  ...

Apply complete! Resources: 20 added, 0 changed, 0 destroyed.

Outputs:

consumer_function_name = "phase4-consumer"
dashboard_url          = "https://console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=phase4-overview"
dynamodb_table_name    = "phase4-events"
producer_function_name = "phase4-producer"
sns_topic_arn          = "arn:aws:sns:ap-northeast-1:123456789012:phase4-alerts"
```

**所要時間**: 2〜4 分（IAM の伝播が遅い場合は Lambda の作成がやや時間がかかる）

apply 後: メールボックスを確認して **Confirm subscription** をクリックする。

---

### ステップ 3: `make sandbox-load-phase4` — 負荷生成

**何が起きるか**

`load.sh` が実行される。デフォルト 20 ラウンド、1 ラウンドごとに以下を行う。

1. `phase4-producer` を `{"count":10}` で invoke → DynamoDB に 10 アイテム書き込み、EMF ログ（`items_written`）を出力
2. `phase4-consumer` を invoke → DynamoDB を Scan し、約 10% の確率で `Simulated consumer error` を raise してエラーログを出力
3. 2 秒待機

20 ラウンドで producer が 200 アイテム書き込み、consumer が平均 2 回エラーを起こす。ラウンド数は引数で変更できる（エラーをより多く発生させたい場合は `./load.sh 50` を直接実行）。

**実行コマンド**

```bash
make sandbox-load-phase4
# または直接
cd terraform/sandboxes/phase4 && ./load.sh 20
# エラーを多発させて CompositeAlarm を確実に鳴らすなら
cd terraform/sandboxes/phase4 && ./load.sh 50
```

**期待される出力例**

```
=== Phase 4 load generation: 20 rounds ===
[1/20] Invoking producer (count=10)...
{"items_written": 10, "errors": 0}
[1/20] Invoking consumer...
{"read": 7}
[2/20] Invoking producer (count=10)...
{"items_written": 10, "errors": 0}
[2/20] Invoking consumer...
{"statusCode": 500, "body": "Simulated consumer error"}
...
[20/20] Invoking producer (count=10)...
{"items_written": 10, "errors": 0}
[20/20] Invoking consumer...
{"read": 10}

=== ロード完了。メトリクス反映まで 2〜3 分待ちます... ===
watch.sh を実行してください。
```

**所要時間**: 約 1 分 10 秒（20 ラウンド × 2 秒スリープ）

load 完了後 **2〜3 分待ってから** watch ステップに進む（CloudWatch の標準解像度メトリクスは 60 秒単位）。

---

### ステップ 4: `make sandbox-watch-phase4` — 観測

**何が起きるか**

`watch.sh` が実行される。以下の 6 セクションを順番に出力する。

| セクション | 内容 |
|---|---|
| [1] ダッシュボード確認 | `phase4-overview` ダッシュボードが存在するかを API で確認 |
| （待機 30 秒） | メトリクスの反映を待つ |
| [2] Lambda 標準メトリクス | producer / consumer それぞれの Invocations / Errors / Duration(p99) / Throttles を表形式で取得 |
| [3] カスタムメトリクス | `Phase4/Lambda` 名前空間の `ItemsWritten` / `ProducerErrorCount` / `ConsumerErrorCount` を取得 |
| [4] アラーム状態 | MetricAlarm 2 本 + CompositeAlarm 1 本の現在ステートを表示 |
| [5] Logs Insights クエリ | `/aws/lambda/phase4-producer` と `/aws/lambda/phase4-consumer` からエラーログを抽出（30 秒待機） |
| [6] コンソール Deep Link | ダッシュボード / Logs Insights / Alarms / Metrics の URL を出力 |

**実行コマンド**

```bash
make sandbox-watch-phase4
```

**期待される出力例（抜粋）**

```
=== [1] ダッシュボード存在スモーク ===
phase4-overview
dashboard OK

メトリクスは最大 2〜3 分遅延します。load.sh 実行後に待ってから watch.sh を実行してください。
(高解像度メトリクスなら 1 分以内だが、今回は標準解像度=60s)

=== [2] Lambda 標準メトリクス: Invocations / Errors (過去 10 分) ===
--- phase4-producer / Invocations (Sum) ---
-------------------------------------------------------
|             GetMetricStatistics                     |
+--------------------+--------+---------------------+
|     Timestamp      |  Sum   |        Unit         |
+--------------------+--------+---------------------+
|  2026-06-06T10:30Z |  20.0  |  Count              |
+--------------------+--------+---------------------+
--- phase4-consumer / Errors (Sum) ---
-------------------------------------------------------
|             GetMetricStatistics                     |
+--------------------+-------+---------------------+
|     Timestamp      |  Sum  |        Unit         |
+--------------------+-------+---------------------+
|  2026-06-06T10:30Z |  2.0  |  Count              |
+--------------------+-------+---------------------+

=== [3] カスタムメトリクス: Phase4/Lambda ===
--- ItemsWritten ---
-------------------------------------------------------
|             GetMetricStatistics                     |
+--------------------+--------+---------------------+
|     Timestamp      |  Sum   |        Unit         |
+--------------------+--------+---------------------+
|  2026-06-06T10:30Z |  200.0 |  Count              |
+--------------------+--------+---------------------+
--- ProducerErrorCount ---
(データなし)
--- ConsumerErrorCount ---
-------------------------------------------------------
|             GetMetricStatistics                     |
+--------------------+-------+---------------------+
|     Timestamp      |  Sum  |        Unit         |
+--------------------+-------+---------------------+
|  2026-06-06T10:30Z |  2.0  |  Count              |
+--------------------+-------+---------------------+

=== [4] Alarm 状態確認 ===
---------------------------------------------------------------------------
|                          DescribeAlarms                                 |
+--------------------------------+----------+----------------------------+
|              Name              |  State   |          Reason            |
+--------------------------------+----------+----------------------------+
|  phase4-producer-errors        |  ALARM   |  Threshold Crossed: 2...  |
|  phase4-producer-duration-high |  OK      |  Threshold Not Crossed    |
+--------------------------------+----------+----------------------------+
-----------------------------------------------
|       DescribeAlarms (Composite)            |
+------------------------+-------------------+
|         Name           |       State       |
+------------------------+-------------------+
|  phase4-critical       |  ALARM            |
+------------------------+-------------------+

=== [5] Logs Insights クエリ(エラーログ抽出) ===
  Query ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (30 秒後に結果取得)...
[
    [
        {"field": "@timestamp", "value": "2026-06-06 10:31:05.123"},
        {"field": "@message",   "value": "ERROR: Simulated consumer error"}
    ],
    ...
]

=== [6] コンソール Deep Link ===
  Dashboard:    https://console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=phase4-overview
  Log Insights: https://console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#logsV2:logs-insights
  Alarms:       https://console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#alarmsV2:
  Metrics:      https://console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#metricsV2:graph=~()

========================================================
観測が終わったら: make sandbox-down-phase4  を忘れずに！
========================================================
```

**所要時間**: 約 2 分（30 秒待機 × 2 回 + API 呼び出し）

---

### ステップ 5: `make sandbox-down-phase4` — 後片付け

**何が起きるか**

`terraform destroy -auto-approve` を実行する。作成したリソースがすべて削除される。ただし KMS キーは削除保留状態（7 日間）に移行する。

**実行コマンド**

```bash
make sandbox-down-phase4
```

**期待される出力例**

```
...
Destroy complete! Resources: 20 destroyed.
```

**所要時間**: 2〜4 分

---

## 観察ポイント（チェックリスト）

### ダッシュボード `phase4-overview`

- [ ] 「Lambda Invocations & Errors」ウィジェットで `phase4-producer` と `phase4-consumer` の Invocations が load ラウンド数分（デフォルト 20）カウントされている
- [ ] 「Lambda Invocations & Errors」ウィジェットで `phase4-consumer` の Errors が 0 以上になっている（consumer は 10% の確率でエラー）
- [ ] 「Lambda Duration p50/p99」ウィジェットで Duration の折れ線が描かれている（p50 < p99 であることを確認）
- [ ] 「Custom: ItemsWritten & ErrorCount」ウィジェットで `ItemsWritten` が 200（20 ラウンド × 10 件）付近になっている
- [ ] 「Custom: ItemsWritten & ErrorCount」ウィジェットで `ConsumerErrorCount` が 1 以上になっている
- [ ] 「DynamoDB Consumed Capacity Units」ウィジェットで `phase4-events` テーブルの `ConsumedWriteCapacityUnits` が増えている
- [ ] 「Active Alarms」ウィジェットに `phase4-producer-errors` または `phase4-critical` が ALARM 表示されている
- [ ] 「Producer ERROR ログ」ウィジェット（Logs ウィジェット）に `ERROR` メッセージが表示されている

### アラーム

- [ ] `phase4-producer-errors` が `ALARM` または `OK` 状態になっている（`INSUFFICIENT_DATA` でなければ評価は機能している）
- [ ] `phase4-critical`（Composite Alarm）が、子アラームの OR で正しくステートを集約している
- [ ] メールアドレスを確認した場合、ALARM 遷移時にメール通知が届いている

### カスタムメトリクス

- [ ] `Phase4/Lambda` 名前空間が CloudWatch コンソール（Metrics → All metrics）に表示されている
- [ ] `ItemsWritten` メトリクスが Metric Filter 経由で記録されている（producer の EMF ログ `{ $.items_written > 0 }` から抽出）
- [ ] `ProducerErrorCount` / `ConsumerErrorCount` が Metric Filter 経由で記録されている（ログの `ERROR` 文字列を計数）

### Logs Insights

- [ ] `/aws/lambda/phase4-consumer` のログに `Simulated consumer error` のメッセージが含まれている
- [ ] Logs Insights クエリ（`filter @message like /ERROR/`）がエラーログを正しく返している

### Lambda Insights

- [ ] CloudWatch コンソールの Lambda Insights（Lambda > Monitoring > Lambda Insights）で `phase4-producer` / `phase4-consumer` の `memory_utilization` や `init_duration` が表示されている（`/aws/lambda-insights` ロググループに記録される）

---

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| アラームが `INSUFFICIENT_DATA` のまま変わらない | 評価期間（60 秒）分のデータポイントがまだ溜まっていない | load.sh 完了後、2〜3 分待ってから watch.sh を実行する。`evaluation_periods=1`、`period=60` なので最低 1 分間分のデータが必要 |
| `ProducerErrorCount` が `(データなし)` で返る | consumer エラーが 0 回だった（確率的） | `./load.sh 50` で試行回数を増やしてリトライ |
| `ItemsWritten` が `(データなし)` で返る | EMF ログが Metric Filter パターン `{ $.items_written > 0 }` にマッチしなかった | `aws logs filter-log-events --log-group-name /aws/lambda/phase4-producer` で実際のログを確認する |
| `apply` 時に `AccessDeniedException` が出る | IAM 権限が不足している（特に KMS キー作成） | `AdministratorAccess` ポリシーを持つロールで実行する |
| SNS メールが届かない | サブスクリプション未確認、またはスパムフィルターに引っかかった | AWS コンソール > SNS > `phase4-alerts` > Subscriptions で Pending confirmation を確認し、メールを探す |
| `destroy` 後に KMS キーが残っている | KMS は最短 7 日の削除保留期間が必須 | 正常動作。コンソールで「Pending deletion」ステートを確認する。7 日後に自動削除される |
| `watch.sh` の Logs Insights クエリが空配列を返す | ログが出力されてから Insights のインデックスが構築されるまで 1〜2 分かかる | 30 秒後に再度 watch.sh を実行する |
| `dashboard not found` と表示される | apply がまだ完了していない、またはリージョンが違う | `terraform output dashboard_url` でリージョンを確認する |

---

## コスト目安

| リソース | 料金 | 数時間の sandbox での実費 |
|---|---|---|
| KMS カスタムキー | $1.00/月/キー | < $0.01（数時間で destroy） |
| CloudWatch カスタムメトリクス（3 本） | $0.30/メトリクス/月 | < $0.01 |
| Lambda Invocations（20〜50 回） | 無料枠（100 万回/月）内 | $0.00 |
| CloudWatch Logs 取り込み | $0.76/GB | 数 KB なので $0.00 |
| DynamoDB（PAY_PER_REQUEST） | 無料枠内（25 GB / 25 WCU） | $0.00 |
| SNS メール通知 | 無料枠（1000 件/月） | $0.00 |
| **合計目安** | | **< $0.05** |

カスタムメトリクスは無料枠が 10 メトリクス/月なので、Phase4/Lambda の 3 本（`ItemsWritten` / `ProducerErrorCount` / `ConsumerErrorCount`）は無料枠に収まる。LambdaInsights 名前空間のメトリクス数本を合わせても通常は無料枠内。

---

## 後片付けの確認

- [ ] `make sandbox-down-phase4` が `Destroy complete!` を表示して正常終了した
- [ ] AWS コンソール > Lambda でファンクション `phase4-producer` / `phase4-consumer` が存在しない
- [ ] AWS コンソール > DynamoDB でテーブル `phase4-events` が存在しない
- [ ] AWS コンソール > CloudWatch > Dashboards で `phase4-overview` が存在しない
- [ ] AWS コンソール > CloudWatch > Alarms で `phase4-producer-errors` / `phase4-producer-duration-high` / `phase4-critical` が存在しない
- [ ] AWS コンソール > SNS > Topics で `phase4-alerts` が存在しない
- [ ] AWS コンソール > IAM > Roles で `phase4-lambda-producer` / `phase4-lambda-consumer` が存在しない
- [ ] AWS コンソール > KMS で `alias/phase4-cw-logs` が「Pending deletion」ステートになっている（7 日後に完全削除される）
- [ ] タグ `Sandbox=phase4` のリソースが（KMS 以外）残存していない（`aws resourcegroupstaggingapi get-resources --tag-filters Key=Sandbox,Values=phase4` で確認）
