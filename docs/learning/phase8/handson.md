# Phase 8 ハンズオン — Step Functions sandbox

## 前提条件

### AWS 認証・権限

- AWS CLI が設定済みであること（`aws sts get-caller-identity` でアカウント ID が返ること）
- 以下のサービスへの権限が必要:
  - `states:*`（Step Functions）
  - `lambda:*`
  - `dynamodb:*`
  - `sns:*`
  - `kms:*`
  - `logs:*`
  - `xray:*`
  - `cloudwatch:*`
  - `iam:CreateRole`, `iam:AttachRolePolicy` など
- 管理者権限または相当の IAM ポリシーを持つプロファイルを使うこと

### リージョン

デフォルトは `ap-northeast-1`（東京）。別リージョンで動かす場合は `AWS_REGION` 環境変数で上書きする。

```bash
export AWS_REGION=ap-northeast-1   # デフォルト。変更する場合のみ指定
```

### 課金開始の注意

`make sandbox-up-phase8`（terraform apply）を実行した時点から課金が始まる。
KMS CMK は `destroy` 後も 7 日間の削除猶予期間（`deletion_window_in_days = 7`）が続くため、その間も KMS の費用が発生する。
sandbox の目的外利用を防ぐため、観測が終わったら速やかに `make sandbox-down-phase8` を実行すること。

### Phase 固有の前提

- SNS email 通知を受け取る場合は `notify_email` 変数を自分のアドレスに変更し、apply 後に届く確認メールの「Confirm subscription」リンクをクリックする。
  デフォルト（`sandbox@example.com`）のままでも動作するが、通知メールは届かない。
  ```bash
  # notify_email を上書きして apply する場合
  terraform -chdir=terraform/sandboxes/phase8 apply \
    -var="notify_email=your@email.com" -auto-approve
  ```
- Python 3.12 が Lambda ランタイムとして使われる。ソースコードは `backend/sandboxes/phase8/handler.py`（5 ハンドラを 1 ファイルに集約）。

---

## 全体の流れ

| ステップ | コマンド | 内容 |
|---|---|---|
| 1. バリデーション | `make sandbox-test-phase8` | terraform validate（無料・ローカルのみ） |
| 2. デプロイ | `make sandbox-up-phase8` | terraform apply（ここから課金） |
| 3. 負荷生成 | `make sandbox-load-phase8` | 3 シナリオ 15 件の SFN 実行を投入 |
| 4. メトリクス観測 | `make sandbox-watch-phase8` | CloudWatch 集計・コンソール URL 表示 |
| 5. 後片付け | `make sandbox-down-phase8` | terraform destroy（課金停止） |

---

## ステップ詳細

### Step 1: バリデーション（`make sandbox-test-phase8`）

**何が起きるか**

`terraform init -backend=false` + `terraform validate` をローカルで実行する。
AWS への通信は発生しない。`backend/tests/sandboxes/phase8` ディレクトリが存在すれば moto pytest も先に走る。

**実行コマンド**

```bash
make sandbox-test-phase8
```

**期待される出力例**

```
==> phase8 に moto テストなし (validate のみ)
==> terraform validate phase8
Success! The configuration is valid.
```

または moto テストがある場合:

```
==> moto pytest phase8
collected 5 items

tests/sandboxes/phase8/test_handler.py::test_validate_order_happy PASSED
tests/sandboxes/phase8/test_handler.py::test_validate_order_invalid_amount PASSED
...
==> terraform validate phase8
Success! The configuration is valid.
```

**所要時間**: 10〜30 秒

---

### Step 2: デプロイ（`make sandbox-up-phase8`）

**何が起きるか**

`terraform apply -auto-approve` を実行し、以下のリソースを作成する:

- KMS CMK（`alias/phase8-sfn`）+ ローテーション有効
- DynamoDB テーブル `phase8-orders`（KMS SSE / PAY_PER_REQUEST）
- SNS トピック `phase8-order-notify` + email サブスクリプション
- IAM ロール 2 つ（Lambda 用 / SFN 用）+ ポリシーアタッチ
- Lambda 5 関数（`phase8-validate-order` / `phase8-charge-payment` / `phase8-update-inventory` / `phase8-notify-customer` / `phase8-compensate-order`）
- CloudWatch Log Groups 6 つ（Lambda × 5 + SFN 実行ログ）
- Step Functions ステートマシン `phase8-order-saga`（Standard / X-Ray / KMS 暗号化 / ALL ログ）
- CloudWatch ダッシュボード `Phase8-StepFunctions`
- CloudWatch アラーム `phase8-sfn-execution-failures`（1 分に 3 件以上失敗でアラート）

**実行コマンド**

```bash
make sandbox-up-phase8
```

**期待される出力例**

```
Initializing the backend...
Initializing provider plugins...
...
Plan: 24 to add, 0 to change, 0 to destroy.
aws_kms_key.phase8: Creating...
aws_dynamodb_table.orders: Creating...
...
aws_sfn_state_machine.order_saga: Creation complete after 8s [id=arn:aws:states:ap-northeast-1:123456789012:stateMachine:phase8-order-saga]
aws_cloudwatch_dashboard.phase8: Creation complete after 2s

Apply complete! Resources: 24 added, 0 changed, 0 destroyed.

Outputs:

state_machine_arn = "arn:aws:states:ap-northeast-1:123456789012:stateMachine:phase8-order-saga"
state_machine_name = "phase8-order-saga"
dashboard_url = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=Phase8-StepFunctions"
orders_table_name = "phase8-orders"
sns_topic_arn = "arn:aws:sns:ap-northeast-1:123456789012:phase8-order-notify"
kms_key_arn = "arn:aws:kms:ap-northeast-1:123456789012:key/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

> SNS email を指定した場合、apply 完了後すぐに確認メールが届く。Subject が `AWS Notification - Subscription Confirmation` のメールの「Confirm subscription」リンクをクリックしないと通知が届かない。

**所要時間**: 2〜4 分

---

### Step 3: 負荷生成（`make sandbox-load-phase8`）

**何が起きるか**

`load.sh` が以下の 3 シナリオで Step Functions 実行を計 15 件投入する。

| シナリオ | 件数 | 入力の特徴 | 期待される結果 |
|---|---|---|---|
| 正常系（Happy path） | 10 件 | `amount` = 1000〜9999（ランダム）、`items` に `SKU-A` × 2 | `OrderSucceeded` |
| 補償パス（validate 失敗） | 3 件 | `amount=0` → `validate_order` が `ValueError` | `CompensateOrder` → `OrderFailed` |
| 在庫不足パス（inventory 失敗） | 2 件 | `qty=9999` / `SKU-RARE` → `update_inventory` が失敗 | `CompensateOrder` → `OrderFailed` |

各実行の `name` はユニーク（`happy-order-{timestamp}-{i}` など）なので重複衝突しない。

**実行コマンド**

```bash
make sandbox-load-phase8
```

**期待される出力例**

```
INFO: Looking up state machine ARN...
Target SFN: arn:aws:states:ap-northeast-1:123456789012:stateMachine:phase8-order-saga

=== Scenario 1: Happy path (10 executions) ===
arn:aws:states:ap-northeast-1:123456789012:execution:phase8-order-saga:happy-order-1748000000-1
arn:aws:states:ap-northeast-1:123456789012:execution:phase8-order-saga:happy-order-1748000000-2
...（10 行）

=== Scenario 2: Compensation path — amount=0 (3 executions) ===
arn:aws:states:ap-northeast-1:123456789012:execution:phase8-order-saga:fail-fail-1748000001-1
...（3 行）

=== Scenario 3: Inventory shortage path (2 executions) ===
arn:aws:states:ap-northeast-1:123456789012:execution:phase8-order-saga:inv-inv-1748000002-1
...（2 行）

All executions submitted. Wait ~30s then run: make sandbox-watch-phase8

=== Recent executions (direct API) ===
------------------------------------------------------------------
|                        ListExecutions                          |
+-----------------------------------+------------+--------------+
|               name                |   status   |    start     |
+-----------------------------------+------------+--------------+
|  happy-order-1748000000-1        |  RUNNING   |  2026-06-06  |
|  happy-order-1748000000-2        |  SUCCEEDED |  2026-06-06  |
...
```

**所要時間**: 1〜2 分（スクリプト実行 + 各実行の処理自体は非同期）

---

### Step 4: メトリクス観測（`make sandbox-watch-phase8`）

**何が起きるか**

`watch.sh` が以下を順に実行する:

1. CloudWatch ダッシュボードの存在確認（`get-dashboard`）
2. **120 秒の待機**（CloudWatch メトリクスの反映遅延対応）
3. `ExecutionsStarted` / `ExecutionsSucceeded` / `ExecutionsFailed` / `ExecutionsTimedOut` を直近 10 分で集計
4. `ExecutionTime` の P99 を取得
5. Lambda 5 関数それぞれの `Errors` 件数を集計
6. CloudWatch Logs から `ExecutionFailed` イベントを直近 10 分でフィルタ
7. コンソール Deep Link（ステートマシン / ダッシュボード / X-Ray）を出力
8. 実行履歴テーブル（直近 20 件）を出力

**実行コマンド**

```bash
make sandbox-watch-phase8
```

**期待される出力例**

```
INFO: CloudWatch メトリクスの反映には 1〜5 分かかります。
...

=== [0] Dashboard smoke test ===
OK: dashboard exists

=== [1] メトリクス反映待ち (Step Functions は ~2-3 分遅延) ===
    60 秒 sleep します...
    さらに 60 秒...
    反映待ち完了。以下のメトリクスを取得します。

=== [2] ExecutionsStarted / Succeeded / Failed / TimedOut ===
  ExecutionsStarted:              15
  ExecutionsSucceeded:            10
  ExecutionsFailed:               5
  ExecutionsTimedOut:             0

=== [3] ExecutionTime P99 (ms) ===
-------------------------------------------
|      GetMetricStatistics                |
+-----------------------+-----------------+
|          p99          |      time       |
+-----------------------+-----------------+
|  3241.0               |  2026-06-06...  |
+-----------------------+-----------------+

=== [4] Lambda Errors 集計 ===
  phase8-validate-order:           Errors: 3
  phase8-charge-payment:           Errors: 0
  phase8-update-inventory:         Errors: 2
  phase8-notify-customer:          Errors: 0
  phase8-compensate-order:         Errors: 0

=== [5] CloudWatch Logs — SFN 実行失敗ログ (直近10分) ===
{"type":"ExecutionFailed","details":{"error":"OrderProcessingFailed",...}}
...

=== [6] Console Deep Links ===
  State Machine:
  https://ap-northeast-1.console.aws.amazon.com/states/home?region=ap-northeast-1#/statemachines/view/...

  CloudWatch Dashboard:
  https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=Phase8-StepFunctions

  X-Ray Service Map:
  https://ap-northeast-1.console.aws.amazon.com/xray/home?region=ap-northeast-1#/service-map

=== [7] Execution History (直近 20 件) ===
------------------------------------------------------
|                   ListExecutions                   |
+--------------------------+------------+------------+
|           Name           |  Status    |  Started   |
+--------------------------+------------+------------+
|  happy-order-...-1       |  SUCCEEDED |  2026-06-06|
|  fail-fail-...-1         |  FAILED    |  2026-06-06|
...
===================================================
 観測が終わったら必ず実行:
   make sandbox-down-phase8
===================================================
```

**所要時間**: 3〜4 分（うち 2 分は待機）

---

### Step 5: 後片付け（`make sandbox-down-phase8`）

**何が起きるか**

`terraform destroy -auto-approve` を実行し、作成した 24 リソースをすべて削除する。
KMS CMK は即時削除されず、7 日間の削除猶予期間に入る（この間も課金が継続）。

**実行コマンド**

```bash
make sandbox-down-phase8
```

**期待される出力例**

```
aws_cloudwatch_metric_alarm.sfn_failures: Destroying...
aws_cloudwatch_dashboard.phase8: Destroying...
...
aws_sfn_state_machine.order_saga: Destruction complete after 5s
aws_kms_key.phase8: Destroying...
aws_kms_key.phase8: Destruction complete after 0s [note: 7-day pending deletion]

Destroy complete! Resources: 24 destroyed.
```

**所要時間**: 2〜3 分

---

## 観察ポイント（チェックリスト）

### CloudWatch ダッシュボード `Phase8-StepFunctions`

- [ ] **SFN Executions ウィジェット**（時系列グラフ）で `ExecutionsStarted=15`、`ExecutionsSucceeded=10`、`ExecutionsFailed=5` が立ち上がっているか
- [ ] **SFN Execution Duration (P99) ウィジェット**（`ExecutionTime` メトリクス）に値が表示されているか。正常系でも数秒（2000〜5000 ms 程度）かかることを確認する
- [ ] **Lambda Errors (all phase8 functions) ウィジェット**（`AWS/Lambda` namespace）で `phase8-validate-order` と `phase8-update-inventory` にエラーが計上されているか（補償パス・在庫失敗パスに対応）
- [ ] **Lambda Duration P99 ウィジェット**で `phase8-validate-order` と `phase8-charge-payment` の実行時間が確認できるか
- [ ] **SFN Execution Failures (last 20) ウィジェット**（Logs Insights クエリ）に `ExecutionFailed` イベントが表示されているか。`details.error` カラムで `OrderProcessingFailed` と読めること

### Step Functions コンソール

- [ ] ステートマシン `phase8-order-saga` の「Executions」タブで全 15 件が一覧表示されるか
- [ ] 正常系実行のグラフビューで `ValidateOrder → ChargePayment → UpdateInventory → NotifyCustomer → OrderSucceeded` のフローが緑色で表示されるか
- [ ] 補償パスの実行で `ValidateOrder（赤）→ OrderFailed` のショートサーキットが確認できるか
- [ ] 在庫失敗パスの実行で `UpdateInventory（赤）→ CompensateOrder（青）→ OrderFailed` の補償フローが確認できるか
- [ ] 任意の実行の「Execution input and output」タブで入力 JSON が `include_execution_data = true` によってログに記録されているか確認

### X-Ray サービスマップ

- [ ] X-Ray コンソールで `phase8-order-saga` → `phase8-validate-order` / `phase8-charge-payment` など Lambda ノードが接続されたサービスマップが表示されるか
- [ ] エラートレースを選択し、どのサブセグメントで例外が発生したかを確認できるか

### CloudWatch Logs

- [ ] `/aws/states/phase8-order-saga` に実行ログが書き込まれているか（`level = "ALL"` なので全ステートの入出力が記録される）
- [ ] `/aws/lambda/phase8-validate-order` のログに `INVALID_ORDER: amount must be positive` のエラーメッセージが含まれるか（補償パス実行分）
- [ ] ログが KMS 暗号化されていること（Log Group の「Encryption」列に CMK ARN が表示される）

### CloudWatch アラーム

- [ ] `phase8-sfn-execution-failures` アラームが `ALARM` 状態になっているか（1 分以内に 3 件以上の失敗が発生するため）

---

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| `make sandbox-up-phase8` が `Error: creating IAM Policy: EntityAlreadyExists` で失敗する | 前回の destroy が不完全でリソースが残っている | `aws iam delete-policy --policy-arn arn:aws:iam::ACCOUNT:policy/phase8-*` で手動削除後、再 apply |
| `load.sh` が `ERROR: state machine phase8-order-saga not found` で失敗する | apply が完了していない / リージョン不一致 | `make sandbox-up-phase8` が成功しているか確認。`AWS_REGION` が `ap-northeast-1` になっているか確認 |
| `watch.sh` の `[2]` でメトリクスが全部 `0` になる | CloudWatch の反映遅延（最大 5 分）。スクリプトは 2 分待機するが不十分な場合がある | `watch.sh` を再度実行するか、コンソールで直接ダッシュボードを確認する |
| Step Functions 実行が `RUNNING` のまま止まっている | Lambda の初回コールドスタート待ち / Lambda の実行エラーで Retry 中 | AWS コンソールのステートマシン実行詳細で現在のステートを確認。`ExecutionTime` が極端に長い場合は Retry が上限に達するまで待つ |
| `ExecutionsFailed` が期待より多い / 少ない | ASL の `Retry` 設定が影響している。`ValidateOrder` は `Lambda.ServiceException` に対して最大 3 回リトライする | コンソールの実行履歴で各実行の `Retry` 回数を確認。`Catch` に `States.ALL` を指定しているので最終的には必ず `OrderFailed` か `OrderSucceeded` に収束する |
| SNS 通知メールが届かない | サブスクリプションが `PendingConfirmation` 状態 | apply 後に届いた `AWS Notification - Subscription Confirmation` メールの「Confirm subscription」リンクをクリックする。SNS コンソールで購読の Status を確認 |
| `kms:GenerateDataKey` エラーで Lambda / SFN が失敗する | KMS キーポリシーが Lambda / SFN サービスプリンシパルの呼び出しを許可していない | `main.tf` の KMS ポリシーに `states.ap-northeast-1.amazonaws.com` と `logs.ap-northeast-1.amazonaws.com` が含まれているか確認。リージョンを変更した場合はポリシー内のリージョン部分も一致させる |
| `watch.sh [5]` で `(no ExecutionFailed events in log group)` と出る | ログの書き込み遅延か、KMS 復号権限の問題 | 1〜2 分待ってから `watch.sh` を再実行。ログ書き込みには `include_execution_data = true` の分だけ遅延がある |
| `terraform destroy` 後も KMS 課金が続く | 仕様。`deletion_window_in_days = 7` の間は削除保留 | 7 日後に自動削除される。KMS コンソールで「Pending deletion」のキーを確認できる |

---

## コスト目安

sandbox の 1 回あたり（apply → load 15 件 → watch → destroy）の概算。

| サービス | 内訳 | 概算 |
|---|---|---|
| **Step Functions Standard** | 15 実行 × 約 4 ステート = 60 遷移。無料枠 4,000 遷移/月以内 | **$0** |
| **Lambda** | 15 実行 × 5 関数、128 MB × 数百 ms。無料枠 100 万件/月以内 | **$0** |
| **DynamoDB** | PAY_PER_REQUEST、数十 read/write。無料枠あり | **$0** |
| **SNS** | 1 トピック、15 件以下のメッセージ。無料枠 100 万件/月以内 | **$0** |
| **CloudWatch Logs** | 実行データ込みでも数 KB〜数十 KB。無料枠 5 GB/月以内 | **$0** |
| **KMS CMK** | 1 キー × 月単位課金 $1/月。7 日保留期間分 = 約 $0.23 | **≈ $0.23** |
| **X-Ray** | 15 トレース。無料枠 100,000 トレース/月以内 | **$0** |
| **合計** | | **≈ $0.23**（KMS 保留期間分のみ） |

> `include_execution_data = true` を有効にすると実行データがすべてログに書き込まれる。個人情報（PII）を含むデータを投入した場合、destroy 前に手動でロググループを削除することを検討する。

---

## 後片付けの確認

`make sandbox-down-phase8` 実行後、以下を確認する。

- [ ] `terraform destroy` が `Destroy complete! Resources: 24 destroyed.` で終了したこと
- [ ] AWS コンソール（Step Functions）でステートマシン `phase8-order-saga` が存在しないこと
- [ ] AWS コンソール（Lambda）で `phase8-*` 関数が存在しないこと
- [ ] AWS コンソール（DynamoDB）でテーブル `phase8-orders` が存在しないこと
- [ ] AWS コンソール（CloudWatch）でダッシュボード `Phase8-StepFunctions` が削除されたこと
- [ ] AWS コンソール（CloudWatch > Log Groups）で `/aws/states/phase8-order-saga` と `/aws/lambda/phase8-*` が削除されたこと
- [ ] AWS コンソール（KMS）でキー `alias/phase8-sfn` が「Pending deletion（7 日）」状態になっていること（これは正常。7 日後に自動削除される）
- [ ] タグ `Sandbox=phase8` のリソースが残存していないことを Resource Groups & Tag Editor で確認すること（`make sandbox-down-all` で一括確認も可）
