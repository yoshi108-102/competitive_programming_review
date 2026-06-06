# Phase 10 ハンズオン — SNS sandbox

## 前提条件

### AWS 認証・権限

- `aws configure` または環境変数（`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`）が設定済みであること
- 以下の権限が必要（最低限）: `sns:*`, `sqs:*`, `lambda:*`, `kms:*`, `iam:PassRole`, `cloudwatch:*`, `logs:*`
- IAM ユーザーではなく IAM ロールを使う場合は `sts:AssumeRole` も必要

### リージョン

- デフォルト: `ap-northeast-1`（東京）
- 変更する場合は環境変数 `AWS_REGION=<your-region>` を設定してから各 make コマンドを実行する

### ツール

- Terraform >= 1.7
- AWS CLI v2
- Python 3.12（Lambda ソースのビルドは Terraform の archive_file プロバイダが自動処理）
- `jq`（出力の確認を楽にするために推奨）

### 課金開始の注意

`make sandbox-up-phase10` を実行した瞬間から以下のリソースが課金対象になる。

| リソース | 課金の起点 |
|---|---|
| KMS キー | 作成直後から月額 $1（7日保留中も課金） |
| SNS | Publish 100万件/月まで無料。この sandbox は無料枠内 |
| SQS | 100万リクエスト/月まで無料。この sandbox は無料枠内 |
| Lambda | 100万回/月まで無料。この sandbox は無料枠内 |
| CloudWatch | メトリクス数は無料枠内 |

**必ず `make sandbox-down-phase10` でリソースを削除すること。** KMS のみ削除保留が 7 日残る。

### Phase 固有の前提

- メール購読は今回の sandbox では使わない（SQS + Lambda のみ）。将来メール購読を追加する場合は確認メールを承認しないと配信されない
- `backend/sandboxes/phase10/handler.py` が存在すること（Lambda ソース）。存在しない場合は apply が失敗する

---

## 全体の流れ

```
test → up → load → (3〜5分待つ) → watch → down
```

| ステップ | make コマンド | 目的 |
|---|---|---|
| test | `make sandbox-test-phase10` | terraform validate のみ（無課金・無起動） |
| up | `make sandbox-up-phase10` | terraform apply でリソース作成（課金開始） |
| load | `make sandbox-load-phase10` | SNS に 21 件の注文メッセージを Publish |
| watch | `make sandbox-watch-phase10` | CloudWatch メトリクスをターミナルで確認 |
| down | `make sandbox-down-phase10` | terraform destroy で全リソース削除（課金停止） |

---

## ステップ詳細

### ステップ 1 — test: terraform validate（無課金）

**何が起きるか**

`backend/tests/sandboxes/phase10/` があれば moto pytest を実行し、次に `terraform init -backend=false` + `terraform validate` を実行する。実際の AWS リソースは一切作成しない。

**実行コマンド**

```bash
make sandbox-test-phase10
```

**期待される出力例**

```
==> phase10 に moto テストなし (validate のみ)
==> terraform validate phase10
Success! The configuration is valid.
```

moto テストがあれば pytest の出力がその前に出る。

**所要時間**: 30 秒〜1 分（プラグインキャッシュがあれば数秒）

---

### ステップ 2 — up: terraform apply

**何が起きるか**

以下のリソースが一括で作成される:

- KMS キー（`alias/phase10-sns`）と SNS・SQS・Lambda への鍵ポリシー
- SNS トピック: `phase10-orders`（標準）、`phase10-orders.fifo`（FIFO）
- SQS キュー: `phase10-fulfillment`, `phase10-analytics`, `phase10-wholesale`（各キューに DLQ 付き）
- SQS キュー: `phase10-fifo-consumer.fifo`
- SNS → SQS 購読（フィルタポリシー付き）× 3 + SNS → Lambda 購読 × 1 + FIFO 購読 × 1
- Lambda 関数: `phase10-notifier`（Python 3.12）
- CloudWatch ダッシュボード: `phase10-sns`
- CloudWatch アラーム: `phase10-{fulfillment,analytics,wholesale}-dlq-not-empty` × 3
- IAM ロール: `phase10-publisher`, `phase10-subscriber-sqs`, `phase10-lambda-notifier`

**実行コマンド**

```bash
make sandbox-up-phase10
```

**期待される出力例**

```
Initializing the backend...
Initializing provider plugins...
- Reusing previous version of hashicorp/aws from the dependency lock file
- Reusing previous version of hashicorp/archive from the dependency lock file

Terraform has been successfully initialized!

...（省略）...

Plan: 32 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + analytics_queue_url    = (known after apply)
  + fulfillment_queue_url  = (known after apply)
  + kms_key_arn            = (known after apply)
  + notifier_function_name = "phase10-notifier"
  + orders_fifo_topic_arn  = (known after apply)
  + orders_topic_arn       = (known after apply)
  + wholesale_queue_url    = (known after apply)

aws_kms_key.phase10: Creating...
aws_kms_key.phase10: Creation complete after 1s [id=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx]
...
aws_cloudwatch_dashboard.phase10: Creation complete after 0s [id=phase10-sns]

Apply complete! Resources: 32 added, 0 changed, 0 destroyed.

Outputs:

analytics_queue_url    = "https://sqs.ap-northeast-1.amazonaws.com/123456789012/phase10-analytics"
fulfillment_queue_url  = "https://sqs.ap-northeast-1.amazonaws.com/123456789012/phase10-fulfillment"
kms_key_arn            = "arn:aws:kms:ap-northeast-1:123456789012:key/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
notifier_function_name = "phase10-notifier"
orders_fifo_topic_arn  = "arn:aws:sns:ap-northeast-1:123456789012:phase10-orders.fifo"
orders_topic_arn       = "arn:aws:sns:ap-northeast-1:123456789012:phase10-orders"
wholesale_queue_url    = "https://sqs.ap-northeast-1.amazonaws.com/123456789012/phase10-wholesale"
```

**所要時間**: 2〜3 分

---

### ステップ 3 — load: SNS メッセージ Publish

**何が起きるか**

`load.sh` が 5 つのシナリオで合計 21 件のメッセージを SNS トピック `phase10-orders` に Publish する。メッセージ属性 `order_type` の値によってフィルタポリシーが効き、各キュー・Lambda に振り分けられる。

| シナリオ | order_type | 件数 | 届く購読先 |
|---|---|---|---|
| [1/5] standard | `standard` | 10 件 | fulfillment + analytics |
| [2/5] express | `express` | 5 件 | fulfillment + analytics + Lambda notifier |
| [3/5] wholesale | `wholesale` | 3 件 | wholesale + analytics |
| [4/5] unknown | `unknown_type` | 2 件 | analytics のみ（他はフィルタで除外） |
| [5/5] malformed | `express`（本文が `NOT_JSON`） | 1 件 | Lambda が parse 失敗 → DLQ へ |

**実行コマンド**

```bash
make sandbox-load-phase10
```

**期待される出力例**

```
============================================================
  Phase 10 SNS Load Generator
============================================================
  Region    : ap-northeast-1
  Topic ARN : arn:aws:sns:ap-northeast-1:123456789012:phase10-orders
============================================================

[1/5] Publishing 10 standard orders
      宛先: fulfillment キュー + analytics キュー（filter: standard|express）
    [OK] order_id=ORD-23456789  type=standard  amount=4521  MessageId=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    [OK] order_id=ORD-34567890  type=standard  amount=7843  MessageId=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    ...（10行）
      → 計10件送信完了

[2/5] Publishing 5 express orders
      宛先: fulfillment + analytics + Lambda notifier（filter: express のみ）
    [OK] order_id=ORD-45678901  type=express  amount=2910  MessageId=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    ...（5行）
      → 計5件送信完了

[3/5] Publishing 3 wholesale orders
      宛先: wholesale + analytics キュー（filter: wholesale）
    [OK] order_id=ORD-56789012  type=wholesale  amount=8321  MessageId=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    ...（3行）
      → 計3件送信完了

[4/5] Publishing 2 UNKNOWN orders
      宛先: analytics キューのみ（他 subscription は filter で弾く）
      NumberOfNotificationsFilteredOut が上がるはず
    [OK] order_id=ORD-67890123  type=unknown_type  amount=5102  MessageId=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    ...（2行）
      → 計2件送信完了

[5/5] Publishing 1 malformed payload (DLQ test)
      Lambda notifier が JSON parse 失敗 → maxReceiveCount 超過で DLQ へ
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

============================================================
  送信完了サマリー
  成功: 21 件  失敗: 0 件
============================================================

  CloudWatch メトリクスの反映には 数分（最大 5 分）かかります。

  次のステップ:
    make sandbox-watch-phase10

  または 3〜5 分後に手動で:
    bash /Users/yoshi/competitive_programming_review/terraform/sandboxes/phase10/watch.sh
============================================================
```

**所要時間**: 約 1 分（publish 間に 0.2 秒スリープ）。**その後 3〜5 分待ってから watch を実行すること**（SNS メトリクスの反映遅延）。

---

### ステップ 4 — watch: CloudWatch 観測

**何が起きるか**

`watch.sh` が以下を順に実行する:

1. ダッシュボード `phase10-sns` の存在確認
2. 観察ポイントの解説（メトリクスの意味・期待値）を表示
3. `aws cloudwatch get-metric-statistics` で SNS / SQS / Lambda の主要メトリクスを過去 20 分分取得してターミナルに表示
4. AWS コンソールへの deep link を表示
5. `make sandbox-down-phase10` 実行を促すリマインダーを表示

**実行コマンド**

```bash
make sandbox-watch-phase10
```

**期待される出力例（抜粋）**

```
============================================================
  Phase 10 CloudWatch Observer
============================================================
  Region    : ap-northeast-1
  Topic     : phase10-orders
  Function  : phase10-notifier
  Window    : 2026-06-06T10:00:00Z → 2026-06-06T10:20:00Z
============================================================

[1/5] Dashboard smoke check
  [OK] phase10-sns は存在します (arn:aws:cloudwatch::123456789012:dashboard/phase10-sns)

[2/5] 観察ポイント（メトリクスが何を意味するか）
  ┌─────────────────────────────────────────────────────────────┐
  │ SNS                                                         │
  │  NumberOfMessagesPublished   : load.sh で送った総件数(21件想定) │
  │  NumberOfNotificationsDelivered : サブスクリプションへの配信成功数 │
  │    → 1メッセージが複数サブスクに届くと件数が増える            │
  │  NumberOfNotificationsFailed : 配信失敗数（DLQ 行きの根拠）    │
  │  NumberOfNotificationsFilteredOut : フィルタで弾かれた件数     │
  │    → unknown_type の2件は fulfilment/wholesale フィルタで弾かれる │
  ├─────────────────────────────────────────────────────────────┤
  │ SQS (ApproximateNumberOfMessagesVisible)                    │
  │  fulfillment : standard(10) + express(5) = 15 件想定        │
  │  analytics   : フィルタなし = 全20件（unknown含む）想定       │
  │  wholesale   : wholesale(3) のみ = 3 件想定                 │
  │  *-dlq       : malformed express が Lambda エラー → DLQ へ   │
  ├─────────────────────────────────────────────────────────────┤
  │ Lambda                                                      │
  │  Invocations : express(5) + malformed(1) = 6 件想定         │
  │  Errors      : malformed 1 件が JSON parse 失敗 → 1 件想定    │
  └─────────────────────────────────────────────────────────────┘

[3/5] メトリクス取得
  ※ SNS/SQS は反映まで最大 5 分かかります。

  [ SNS メトリクス: phase10-orders ]
  --- NumberOfMessagesPublished (送信数) ---
  -------------------------------------------------
  |            GetMetricStatistics                |
  +-------------------------+---------------------+
  |  2026-06-06T10:05:00Z   |         21.0        |
  +-------------------------+---------------------+

  --- NumberOfNotificationsDelivered (配信成功数) ---
  -------------------------------------------------
  |            GetMetricStatistics                |
  +-------------------------+---------------------+
  |  2026-06-06T10:05:00Z   |         47.0        |
  +-------------------------+---------------------+

  --- NumberOfNotificationsFilteredOut (フィルタ除外数) ---
  -------------------------------------------------
  |            GetMetricStatistics                |
  +-------------------------+---------------------+
  |  2026-06-06T10:05:00Z   |          4.0        |
  +-------------------------+---------------------+

  [ SQS キュー深さ: ApproximateNumberOfMessagesVisible ]
  --- phase10-fulfillment ---
  -------------------------------------------------
  |            GetMetricStatistics                |
  +-------------------------+---------------------+
  |  2026-06-06T10:05:00Z   |         15.0        |
  +-------------------------+---------------------+

  --- phase10-analytics ---
  ...（以下略）

[4/5] コンソール deep links
  SNS Topic:
    https://ap-northeast-1.console.aws.amazon.com/sns/v3/home?region=ap-northeast-1#/topic/arn:aws:sns:...

  CloudWatch Dashboard (phase10-sns):
    https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=phase10-sns

[5/5] 観測が終わったら必ずリソースを削除してください
  make sandbox-down-phase10
============================================================
```

メトリクスがまだ反映されていない場合は `(データなし — まだ反映待ちの可能性があります)` と表示される。3〜5 分後に再実行する。

**所要時間**: 30 秒〜1 分

---

### ステップ 5 — down: terraform destroy

**何が起きるか**

apply で作ったリソースをすべて削除する。KMS キーは削除保留（7 日）に入るため、コンソールで「削除保留中」状態になる。

**実行コマンド**

```bash
make sandbox-down-phase10
```

**期待される出力例**

```
aws_cloudwatch_metric_alarm.dlq_alert["wholesale"]: Destroying...
aws_cloudwatch_metric_alarm.dlq_alert["analytics"]: Destroying...
aws_cloudwatch_metric_alarm.dlq_alert["fulfillment"]: Destroying...
...
aws_kms_key.phase10: Destroying...
aws_kms_key.phase10: Destruction complete after 0s

Destroy complete! Resources: 32 destroyed.
```

**所要時間**: 2〜3 分

---

## 観察ポイント（チェックリスト）

CloudWatch ダッシュボード `phase10-sns` を開き、以下の各ウィジェットで変化を確認する。
ダッシュボード URL: `https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=phase10-sns`

### ウィジェット 1: SNS Publish & Delivery

- [ ] `NumberOfMessagesPublished`（TopicName: `phase10-orders`）が **21** になっている
- [ ] `NumberOfNotificationsDelivered`（TopicName: `phase10-orders`）が **47 前後**になっている（1 通が複数サブスクに届くため Publish 数を上回る）
- [ ] `NumberOfNotificationsFailed`（TopicName: `phase10-orders`）が **1** になっている（malformed → Lambda エラー）
- [ ] `NumberOfNotificationsFilteredOut`（TopicName: `phase10-orders`）が **4** になっている（unknown_type × 2 が fulfillment + wholesale の 2 フィルタで弾かれる）

### ウィジェット 2: SQS Queue Depth (per queue)

- [ ] `ApproximateNumberOfMessagesVisible`（QueueName: `phase10-fulfillment`）が **15**（standard 10 + express 5）
- [ ] `ApproximateNumberOfMessagesVisible`（QueueName: `phase10-analytics`）が **20**（全 order_type、フィルタなし。malformed はメッセージ本文が届くが parse は consumers 側の責任）
- [ ] `ApproximateNumberOfMessagesVisible`（QueueName: `phase10-wholesale`）が **3**（wholesale のみ）
- [ ] `ApproximateNumberOfMessagesVisible`（QueueName: `phase10-fulfillment-dlq`）が **1**（malformed の Lambda エラーで DLQ へ）
- [ ] `ApproximateNumberOfMessagesVisible`（QueueName: `phase10-analytics-dlq`）が **0**
- [ ] `ApproximateNumberOfMessagesVisible`（QueueName: `phase10-wholesale-dlq`）が **0**

### ウィジェット 3: Lambda Notifier: Invocations / Errors / Duration

- [ ] `Invocations`（FunctionName: `phase10-notifier`）が **6**（express 5 + malformed 1）
- [ ] `Errors`（FunctionName: `phase10-notifier`）が **1**（malformed が JSON parse エラー）
- [ ] `Duration` のピーク値を確認し、コールドスタートの有無を推測できる

### CloudWatch アラーム

- [ ] `phase10-fulfillment-dlq-not-empty` が **ALARM** 状態になっている（DLQ に 1 件）
- [ ] `phase10-analytics-dlq-not-empty` が **OK** 状態
- [ ] `phase10-wholesale-dlq-not-empty` が **OK** 状態

### Lambda ログ

- [ ] `/aws/lambda/phase10-notifier` のロググループに express 注文の JSON が記録されている
- [ ] malformed メッセージに対する parse エラーログが残っている

---

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| `KMS.KMSDisabledException` または SQS キューにメッセージが届かない | KMS キーポリシーに SNS サービスプリンシパルが不足 | `main.tf` の KMS ポリシーに `SNSEncrypt` ステートメントが含まれているか確認。apply をやり直す |
| フィルタが効かず全メッセージが全キューに届く | SNS 購読の `filter_policy` が未設定 | `aws sns get-subscription-attributes` で `FilterPolicy` を確認。Terraform の `aws_sns_topic_subscription` リソースを確認 |
| analytics キューに unexpected_type のメッセージが届かない | analytics 購読にフィルタが設定されている | `analytics` 購読は意図的にフィルタなし。`aws sns get-subscription-attributes --subscription-arn <ARN> --query Attributes.FilterPolicy` が `{}` か空であることを確認 |
| Lambda が一切呼ばれない（Invocations = 0） | SNS → Lambda の `aws_lambda_permission` が未作成 | `aws lambda get-policy --function-name phase10-notifier` でリソースポリシーを確認。`AllowSNSInvoke` ステートメントが存在するか |
| DLQ にメッセージが来ない（malformed を送ったのに） | Lambda の maxReceiveCount 到達に時間がかかる | SQS の visibility_timeout（30 秒）× maxReceiveCount（3 回）= 最大 90 秒後に DLQ へ移動。watch.sh を 2〜3 分後に再実行 |
| `watch.sh` で `(データなし)` が表示される | SNS/SQS メトリクスの反映遅延（最大 5 分） | `load.sh` 実行後 5 分待ってから `make sandbox-watch-phase10` を再実行 |
| `Dashboard phase10-sns が見つかりません` | terraform apply が未実行 or 失敗している | `make sandbox-up-phase10` を確認。`terraform -chdir=terraform/sandboxes/phase10 show` でリソース状態を確認 |
| terraform apply が `Error: creating SNS Topic` で失敗する | FIFO トピック名が `.fifo` で終わっていない | `main.tf` の `aws_sns_topic.orders_fifo` の `name` が `phase10-orders.fifo` であることを確認 |
| `publish failed` が多発する | AWS CLI の credentials が期限切れ | `aws sts get-caller-identity` で認証を確認。SSO の場合は `aws sso login` を再実行 |

---

## コスト目安

| リソース | 課金単位 | この sandbox での推定 |
|---|---|---|
| KMS キー | $1.00/月（キー存在中） + $0.03/10,000 APIコール | 約 $0.03〜$0.10（数時間の利用）+ KMS 7日保留中 $0.007/日 |
| SNS Publish | 100万件/月まで無料 | 21 件 → 無料 |
| SQS リクエスト | 100万件/月まで無料 | 数十件 → 無料 |
| Lambda | 100万回/月まで無料 | 6 回 → 無料 |
| CloudWatch ダッシュボード | $3.00/ダッシュボード/月 | 数時間で destroy すれば $0.01 未満 |
| CloudWatch アラーム | $0.10/アラーム/月 × 3 | $0.30/月相当、数時間なら $0.001 未満 |

**合計目安: ほぼ無料〜数セント。KMS の 7 日保留期間分（$0.007/日）が最大のコスト。**

---

## 後片付けの確認

destroy 後に以下のチェックリストを確認する。

- [ ] `make sandbox-down-phase10` が `Destroy complete! Resources: 32 destroyed.` で終了している
- [ ] AWS コンソール → SNS → トピック で `phase10-orders` および `phase10-orders.fifo` が存在しない
- [ ] AWS コンソール → SQS で `phase10-` プレフィックスのキューが存在しない
- [ ] AWS コンソール → Lambda で `phase10-notifier` が存在しない
- [ ] AWS コンソール → KMS → カスタマー管理キー で `alias/phase10-sns` が **削除保留中（7 日）** になっている（これは正常。7 日後に自動削除される）
- [ ] AWS コンソール → CloudWatch → ダッシュボード で `phase10-sns` が存在しない
- [ ] AWS コンソール → CloudWatch → アラーム で `phase10-*-dlq-not-empty` が存在しない
- [ ] AWS コンソール → CloudWatch → ロググループ で `/aws/lambda/phase10-notifier` が存在しない（`retention_in_days = 1` なので翌日以降に自動削除されるが、手動削除でもよい）
- [ ] Cost Explorer で `Sandbox=phase10` タグでフィルタし、想定外の課金がないことを確認する
