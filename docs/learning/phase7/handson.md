# Phase 7 ハンズオン — EventBridge sandbox

## 前提条件

### AWS 認証・権限

- `aws sts get-caller-identity` が正常に返ること（プロファイル or 環境変数が設定済み）
- 必要な権限: `events:*` / `lambda:*` / `sqs:*` / `kms:*` / `cloudwatch:*` / `logs:*` / `scheduler:*` / `iam:CreateRole` / `iam:PutRolePolicy`
- リージョン: `ap-northeast-1`（環境変数 `AWS_DEFAULT_REGION=ap-northeast-1` を推奨）

### ツール

- Terraform >= 1.7
- AWS CLI v2
- GNU/BSD `date` コマンド（watch.sh が macOS/Linux 両対応で動作）

### 課金開始の注意

`make sandbox-up-phase7` を実行した瞬間から **rate(1 minute) ルールが有効になり、毎分 Lambda が起動し続けます**。観測が終わったら必ず `make sandbox-down-phase7` を実行してください。KMS キーは destroy 後も 7 日間は削除保留状態で残ります（追加課金は僅少）。

### Phase 固有の前提

- `backend/sandboxes/phase7/handler.py` が存在すること（Lambda zip の元ネタ）
- Terraform の `archive_file` が `.terraform/handler.zip` を自動生成するため、事前に zip 化は不要

---

## 全体の流れ

| ステップ | コマンド | 概要 |
|---|---|---|
| 1 | `make sandbox-test-phase7` | terraform validate（AWS 接続不要） |
| 2 | `make sandbox-up-phase7` | リソース全作成、rate ルール即有効化 |
| 3 | `make sandbox-load-phase7` | カスタムイベント 10 件 + ミスマッチ 3 件 + Lambda 直接 invoke |
| 4 | `make sandbox-watch-phase7` | CloudWatch メトリクス・ログを CLI で確認 |
| 5 | `make sandbox-down-phase7` | 全リソース destroy（必須） |

---

## ステップ詳細

### ステップ 1 — terraform validate（sandbox-test-phase7）

**何が起きるか**

Terraform が `main.tf` の構文と型チェックを実行します。AWS へのリクエストは一切発生しないため、認証情報がなくても実行できます。`archive_file` データソースが Lambda zip を生成する参照整合性もここで確認できます。

**実行コマンド**

```bash
make sandbox-test-phase7
```

**期待される出力例**

```
==> Validating phase7 sandbox...
Success! The configuration is valid.
```

**所要時間**: 約 5〜10 秒

---

### ステップ 2 — terraform apply（sandbox-up-phase7）

**何が起きるか**

以下のリソースが ap-northeast-1 に作成されます。

- KMS キー × 2（EventBridge バス用 + Lambda 環境変数用）
- カスタムイベントバス `phase7-bus`（KMS 暗号化）
- イベントアーカイブ `phase7-archive`（30 日保持）
- SQS DLQ `phase7-dlq`（14 日保持）
- EventBridge ルール: `phase7-processor-rule`（カスタムバス上、`com.example.orders` / `order.created` → Lambda）
- EventBridge ルール: `phase7-heartbeat-rule`（デフォルトバス、`rate(1 minute)` → Lambda）
- Lambda `phase7-processor`（Python 3.12、X-Ray Active、EMF カスタムメトリクス出力）
- EventBridge Scheduler グループ `phase7-group` + スケジュール `phase7-one-shot`（at(2099-01-01T00:00:00) プレースホルダー）
- CloudWatch ダッシュボード `phase7-dashboard`（5 ウィジェット）
- CloudWatch アラーム × 2

**実行コマンド**

```bash
make sandbox-up-phase7
```

**期待される出力例**

```
==> Applying phase7 sandbox...

Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  + create

Terraform will perform the following actions:
  ...（省略）...

Plan: 22 to add, 0 to change, 0 to destroy.

Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes

aws_kms_key.lambda_env: Creating...
aws_kms_key.eb: Creating...
...
Apply complete! Resources: 22 added, 0 changed, 0 destroyed.

Outputs:

archive_name  = "phase7-archive"
bus_arn       = "arn:aws:events:ap-northeast-1:123456789012:event-bus/phase7-bus"
bus_name      = "phase7-bus"
dashboard_url = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=phase7-dashboard"
dlq_url       = "https://sqs.ap-northeast-1.amazonaws.com/123456789012/phase7-dlq"
processor_name = "phase7-processor"
```

**所要時間**: 約 2〜4 分（KMS キー作成が律速）

> この時点から `phase7-heartbeat-rule` が毎分 Lambda を起動します。長時間放置しないでください。

---

### ステップ 3 — イベント送信（sandbox-load-phase7）

**何が起きるか**

`load.sh` が 3 フェーズでイベントを送信します。

1. **カスタムイベント 10 件**: `aws events put-events` で `phase7-bus` へ `source=com.example.orders` / `DetailType=order.created` のイベントを 0.5 秒間隔で送信。ルール `phase7-processor-rule` にマッチし Lambda が invoke されます。
2. **パターン不一致イベント 3 件**: `source=com.example.inventory` / `DetailType=stock.updated` を送信。どのルールにもマッチしないため Lambda は起動しません（`MatchedRules=0` の観察用）。
3. **Lambda 直接 invoke**: EventBridge を経由せずに Lambda を直接呼び出し、コールドスタートのログ末尾 5 行を表示します。

**実行コマンド**

```bash
make sandbox-load-phase7
```

**期待される出力例**

```
=== Phase 7 load.sh: sending 10 custom events to phase7-bus ===
  [1/10] order-1748000000-1 sent OK (amount=3872)
  [2/10] order-1748000001-2 sent OK (amount=9041)
  [3/10] order-1748000002-3 sent OK (amount=521)
  ...
  [10/10] order-1748000009-10 sent OK (amount=7113)

=== Sending 3 events that won't match any rule (pattern mismatch demo) ===
  [no-match 1] sent
  [no-match 2] sent
  [no-match 3] sent

=== Direct invoke (bypass EventBridge) to observe cold start ===
START RequestId: abc12345-... Version: $LATEST
[INFO] EVENT: {"source":"load.sh","detail-type":"DirectInvoke","detail":{"test":true}}
[INFO] EventsProcessed: 1
END RequestId: abc12345-...
REPORT RequestId: abc12345-... Duration: 12.34 ms  Billed Duration: 13 ms ...

=== load.sh done. Wait 1-2 min, then run: make sandbox-watch-phase7 ===
=== REMINDER: rate(1 minute) heartbeat rule is ACTIVE ===
=== Run 'make sandbox-down-phase7' when you are done observing! ===
```

**所要時間**: 約 15〜20 秒（10 件 × 0.5 秒 + 直接 invoke）

> `FailedEntryCount=0` 以外が表示された場合はバスへのアクセス権限または KMS 権限を確認してください。

---

### ステップ 4 — メトリクス観測（sandbox-watch-phase7）

**何が起きるか**

`watch.sh` が以下の順番で CloudWatch を照会します。実行冒頭に **90 秒のウェイト**があります（Lambda メトリクスは 1〜3 分、EMF カスタムメトリクスは 2〜5 分の反映遅延があるため）。

0. ダッシュボード存在確認
1. 90 秒待機
2. Lambda: Invocations / Errors / Duration（最後 5 分間, period=300s）
3. EventBridge: FailedInvocations（`phase7-processor-rule`）
4. DLQ: `ApproximateNumberOfMessages`
5. CloudWatch Logs Insights: `@message like /EVENT/` を降順 10 件

最後にコンソールへの deep link（ダッシュボード / EventBridge ルール一覧 / アーカイブ / Lambda / DLQ / X-Ray）を出力します。

**実行コマンド**

```bash
make sandbox-watch-phase7
```

**期待される出力例**

```
INFO: CloudWatch メトリクスの反映には 1〜5 分かかります。
INFO: SQS: load.sh 実行後 5 分待ってください (--period 300)
INFO: EventBridge: rate(1 minute) は初回発火まで最大 60 秒待ってください

============================================
 Phase 7 EventBridge — watch.sh
============================================

[0/5] Checking dashboard exists...
  Dashboard OK

[1/5] Waiting 90s for CloudWatch metrics propagation...
      (Lambda metrics ~1-3 min delay; EMF custom metrics ~2-5 min)

[2/5] Lambda Invocations & Errors (last 5 min, period=60s):
  Invocations (Sum): 12.0
  Errors (Sum): 0.0
  Duration (Average): 15.432

[3/5] EventBridge FailedInvocations (last 5 min):
None

[4/5] DLQ approximate message count:
0

[5/5] Recent Lambda log lines (Insights query):
2026-06-06T12:34:56.789Z  [INFO] EVENT: {"source":"com.example.orders",...}
2026-06-06T12:34:57.123Z  [INFO] EVENT: {"source":"com.example.orders",...}
...

============================================
 Console deep links:
  Dashboard : https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?...
  EventBridge rules   : https://ap-northeast-1.console.aws.amazon.com/events/home?...
  EventBridge archive : https://ap-northeast-1.console.aws.amazon.com/events/home?...
  Lambda              : https://ap-northeast-1.console.aws.amazon.com/lambda/home?...
  DLQ (SQS console)   : https://ap-northeast-1.console.aws.amazon.com/sqs/v3/home?...
  X-Ray traces        : https://ap-northeast-1.console.aws.amazon.com/xray/home?...
============================================

!!! IMPORTANT: rate(1 minute) heartbeat rule is STILL ACTIVE !!!
!!! Run 'make sandbox-down-phase7' NOW to avoid continuous Lambda billing !!!
============================================
```

**所要時間**: 約 2〜3 分（90 秒の待機 + API 照会 5〜10 秒）

---

### ステップ 5 — リソース削除（sandbox-down-phase7）

**何が起きるか**

`terraform destroy` が全 22 リソースを削除します。KMS キーは即時削除ではなく **7 日間の削除保留**に入ります。

**実行コマンド**

```bash
make sandbox-down-phase7
```

**期待される出力例**

```
==> Destroying phase7 sandbox...

Terraform will destroy all your managed infrastructure, as shown above.
  There is no undo. Only 'yes' will be accepted to confirm.

  Enter a value: yes

...
Destroy complete! Resources: 22 destroyed.
```

**所要時間**: 約 1〜2 分

---

## 観察ポイント（チェックリスト）

### Lambda メトリクス — `AWS/Lambda` 名前空間

- [ ] `Invocations (Sum)` が load.sh 送信数（10 件）+ heartbeat 発火数 + 直接 invoke 分だけ増加している
- [ ] `Errors (Sum)` が 0 のまま（Lambda がエラーなく処理できた）
- [ ] `Duration (Average)` が初回 invoke（コールドスタート）で高くなり、以降は低下している
  - ダッシュボードの **「Lambda Invocations & Errors」** ウィジェット（左上）で確認

### EMF カスタムメトリクス — `Phase7/EventBridge` 名前空間

- [ ] `EventsProcessed {Source=com.example.orders}` が 10（load.sh で送った件数）を示している
  - ダッシュボードの **「Custom: EventsProcessed (EMF)」** ウィジェット（中央上）で確認
  - 反映まで最大 5 分かかるため、出なければ少し待つ

### EventBridge — `AWS/Events` 名前空間

- [ ] `FailedInvocations {RuleName=phase7-processor-rule}` が 0 のまま
  - ダッシュボードの **「EventBridge FailedInvocations」** ウィジェット（右下）で確認
- [ ] heartbeat ルール（`phase7-heartbeat-rule`）が 1 分ごとに Lambda を起動しているため、Invocations が定期的に増え続けることを確認

### DLQ — `AWS/SQS` 名前空間

- [ ] `ApproximateNumberOfMessagesVisible {QueueName=phase7-dlq}` が 0 のまま（失敗なし）
  - ダッシュボードの **「DLQ Messages」** ウィジェットで確認
- [ ] DLQ にメッセージが入った場合、CloudWatch アラーム `phase7-dlq-messages` が ALARM 状態になる

### Logs Insights

- [ ] `SOURCE '/aws/lambda/phase7-processor'` のログに `EVENT:` を含む行が 10 件以上表示される
  - ダッシュボードの **「Processor Lambda Logs」** ウィジェット（ログパネル）で確認

### X-Ray トレース

- [ ] Lambda 設定の `tracing_config { mode = "Active" }` により、X-Ray コンソールでトレースが確認できる
  - watch.sh が出力するリンク `https://ap-northeast-1.console.aws.amazon.com/xray/home?...` から確認

### Archive

- [ ] EventBridge コンソール → アーカイブ `phase7-archive` にイベント件数が記録されている（パターン不一致の 3 件も含む全件がアーカイブされる）

---

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| `put-events` で `FailedEntryCount=1` | カスタムバスへの権限不足 / KMS キーポリシー未反映 | `aws events put-events` のエラー本文を確認。apply 直後は KMS が数秒で有効化されるので 30 秒待って再試行 |
| watch.sh で Lambda Invocations が `N/A` | まだメトリクスが反映されていない | CloudWatch の反映遅延は最大 3 分。wait.sh 冒頭の 90 秒ウェイトを増やすか、手動で 1〜2 分待つ |
| EMF カスタムメトリクス `EventsProcessed` が見えない | EMF の初回反映遅延（最大 5 分） | `Phase7/EventBridge` 名前空間は Lambda が少なくとも 1 度 invoke されてから最大 5 分後に現れる。period を 300s にして再照会 |
| `rate(1 minute)` のメトリクスが 0 | heartbeat ルールの初回発火まで最大 60 秒かかる | apply 後 60〜90 秒待ってから watch.sh を実行する |
| DLQ にメッセージが溜まる | Lambda が `maximum_retry_attempts=2` 回失敗した | `/aws/lambda/phase7-processor` のログを確認し、エラー原因を特定。Lambda を修正して再 deploy |
| `aws cloudwatch get-dashboard` で NOT FOUND | apply が完了していない / リソース名の prefix が異なる | `terraform output` で `dashboard_url` を確認し、実際のダッシュボード名と一致しているか照合 |
| `terraform destroy` 後の再 apply で KMS エラー | KMS エイリアスが削除保留中のキーに紐づいている | AWS コンソールの KMS → Customer managed keys から削除をキャンセルするか、`variable "prefix"` を変更して別名で apply |
| Scheduler `phase7-one-shot` が意図せず発火 | `at(2099-01-01T00:00:00)` を書き換えた場合 | apply 前に time zone (Asia/Tokyo) を考慮した UTCオフセットを確認。テスト後は即 destroy |

---

## コスト目安

| リソース | 料金体系 | sandbox 1 回分（目安） |
|---|---|---|
| EventBridge カスタムイベント | $1.00 / 100 万件 | 13 件送信 → 実質 $0.00 |
| Lambda | 100 万リクエスト + GB-seconds 無料枠 | 無料枠内 |
| SQS DLQ | 100 万リクエスト無料枠 | 無料枠内 |
| KMS キー × 2 | $1.00 / キー / 月 | 数日で destroy → 日割り数セント |
| KMS API リクエスト | $0.03 / 10,000 件 | 数十件 → $0.00 |
| CloudWatch ダッシュボード | $3.00 / ダッシュボード / 月 | 数時間 destroy → 日割り数セント |
| CloudWatch Logs | 5 GB/月 無料枠 | ごく少量 → 無料枠内 |

**最大リスク**: `rate(1 minute)` ルールを destroy し忘れた場合、Lambda が毎分起動し続ける。100 万リクエスト無料枠を超えると課金が発生するが、通常の sandbox 利用時間（数時間）では無料枠内に収まる。

---

## 後片付けの確認

`make sandbox-down-phase7` を実行後、以下を確認してください。

- [ ] `terraform show` が空またはエラーになる（state が空）
- [ ] AWS コンソール → EventBridge → カスタムバス一覧に `phase7-bus` が存在しない
- [ ] AWS コンソール → EventBridge → ルール一覧（デフォルトバス）に `phase7-heartbeat-rule` が存在しない
- [ ] AWS コンソール → Lambda → `phase7-processor` が存在しない
- [ ] AWS コンソール → SQS → `phase7-dlq` が存在しない
- [ ] AWS コンソール → CloudWatch → ダッシュボード → `phase7-dashboard` が存在しない
- [ ] AWS コンソール → KMS → カスタマー管理キーに `alias/phase7-eventbridge` が「削除保留中」で残っている（正常。7 日後に自動削除）
- [ ] タグ `Sandbox=phase7` のリソースが残存していないこと: `aws resourcegroupstaggingapi get-resources --tag-filters Key=Sandbox,Values=phase7 --region ap-northeast-1` で結果が空
