# Phase 8 — Step Functions (Order Saga Sandbox)

Step Functions を使った **Saga パターン**の学習用 sandbox。注文処理ワークフローを Standard ステートマシンで実装し、途中失敗時の**補償トランザクション**が実際に動く様子を観測する。X-Ray / CloudWatch Logs（KMS 暗号化）/ CloudWatch ダッシュボードをすべて有効化した構成。

---

## このサンドボックスが作るリソース

| リソース | 名前 | 備考 |
|---|---|---|
| Step Functions State Machine | `phase8-order-saga` | Standard / X-Ray / KMS 暗号化 / ALL ログ |
| Lambda（5 関数） | `phase8-{validate-order,charge-payment,update-inventory,notify-customer,compensate-order}` | Python 3.12 / X-Ray Active |
| DynamoDB | `phase8-orders` | PAY_PER_REQUEST / KMS SSE |
| SNS Topic | `phase8-order-notify` | KMS 暗号化 / email サブスクリプション |
| KMS CMK | `alias/phase8-sfn` | 全リソース共用 / key rotation 有効 / 削除猶予 7 日 |
| CloudWatch Log Groups | `/aws/lambda/phase8-*` + `/aws/states/phase8-order-saga` | retention 1 日 / KMS 暗号化 |
| CloudWatch Dashboard | `Phase8-StepFunctions` | SFN 実行数 / P99 / Lambda Errors |
| CloudWatch Alarm | `phase8-sfn-execution-failures` | 1 分で 3 件以上の失敗でアラート |

### ステートフロー

```
ValidateOrder → ChargePayment → UpdateInventory → NotifyCustomer → OrderSucceeded
     ↓ (fail)        ↓ (fail)         ↓ (fail)
  OrderFailed  ←── CompensateOrder ←─────────────────────────────
```

---

## クイックコマンド一覧

```bash
# 1. バリデーション（無料・ローカルのみ）
make sandbox-test-phase8

# 2. デプロイ（ここから課金）
make sandbox-up-phase8
#    → notify_email を上書きした場合は SNS 確認メールの承認を忘れずに

# 3. 負荷生成（正常系 10 件 / 補償パス 3 件 / 在庫失敗 2 件）
make sandbox-load-phase8

# 4. メトリクス観測（~2-3 分後に CloudWatch へ反映）
make sandbox-watch-phase8
#    → X-Ray / CW Dashboard URL もスクリプトが出力する

# 5. 後片付け（必須 — 放置すると継続課金）
make sandbox-down-phase8
```

`AWS_REGION` 環境変数でリージョンを上書きできる（デフォルト: `ap-northeast-1`）。
`notify_email` を自分のアドレスにする場合:

```bash
terraform -chdir=terraform/sandboxes/phase8 apply \
  -var="notify_email=your@email.com" -auto-approve
```

---

## 詳しい手順・観察ポイント・トラブルシュート

**→ [docs/learning/phase8/handson.md](../../../docs/learning/phase8/handson.md)**（Markdown）

または HTML 版:

**→ [docs/learning/phase8/handson.html](../../../docs/learning/phase8/handson.html)**

---

## コスト・Destroy 注意事項

| 項目 | 注意 |
|---|---|
| **KMS CMK** | `destroy` 後も **7 日間の削除猶予期間**中は課金が発生する（`deletion_window_in_days = 7`） |
| **Step Functions Standard** | 状態遷移数 × $0.025/1,000。1 回の sandbox 実行（15 件 × 約 4 遷移 = 60 遷移）は無料枠内 |
| **CloudWatch Logs** | `include_execution_data = true` で全入出力がログに書き込まれる。PII を含む入力は destroy 前に手動削除を検討 |
| **SNS email subscription** | apply 直後は PendingConfirmation。承認メールを放置しても購読料は発生しないが、通知が届かない |
| **X-Ray トレース** | sandbox では全実行をトレース（Active モード）。本番流用時は必ずサンプリング率を下げること |

destroy 後に KMS キーが「Pending deletion」状態になるのは正常。7 日後に自動削除される。

---

## ディレクトリ構成

```
terraform/sandboxes/phase8/
├── main.tf                        # KMS / DynamoDB / SNS / IAM / Lambda / SFN / CloudWatch
├── variables.tf                   # aws_region, notify_email
├── outputs.tf                     # state_machine_arn, dashboard_url, kms_key_arn 等
├── providers.tf
├── state_machine_definition.json  # ASL: Saga with Retry / Catch / Compensate
├── load.sh                        # 負荷生成（正常系 10 件 / 補償系 3 件 / 在庫失敗 2 件）
├── watch.sh                       # メトリクス取得 + コンソール Deep Link
└── .gitignore
```

Lambda ソースコードは `backend/sandboxes/phase8/handler.py`（5 ハンドラを 1 ファイルに集約）。
