# Phase 8 — Step Functions (Order Saga Sandbox)

## このサンドボックスは何を作るか

AWS Step Functions を使った **Saga パターン**の学習用サンドボックス。
注文処理ワークフロー（注文検証 → 決済 → 在庫更新 → 顧客通知）を Standard ステートマシンで実装し、
途中失敗時の **補償トランザクション**（Catch → CompensateOrder）が実際に動く様子を観測する。
X-Ray トレース・CloudWatch Logs（KMS 暗号化）・CloudWatch ダッシュボードをすべて有効化した
本番品質の構成になっている。

---

## 主要リソース

| リソース | 名前 | 備考 |
|---|---|---|
| Step Functions State Machine | `phase8-order-saga` | Standard / X-Ray / KMS暗号化 / ALL ログ |
| Lambda (5関数) | `phase8-{validate-order,charge-payment,update-inventory,notify-customer,compensate-order}` | Python 3.12, 共有 zip, X-Ray Active |
| DynamoDB | `phase8-orders` | PAY_PER_REQUEST, KMS SSE |
| SNS Topic | `phase8-order-notify` | KMS 暗号化, email サブスクリプション |
| KMS CMK | `alias/phase8-sfn` | 全リソース共用, key rotation 有効, 削除猶予 7 日 |
| CloudWatch Log Groups | `/aws/lambda/phase8-*` + `/aws/states/phase8-order-saga` | retention 1 日, KMS 暗号化 |
| CloudWatch Dashboard | `Phase8-StepFunctions` | SFN 実行数 / P99 / Lambda Errors |
| CloudWatch Alarm | `phase8-sfn-execution-failures` | 1 分で 3 件以上の失敗でアラート |

### ステートフロー

```
ValidateOrder → ChargePayment → UpdateInventory → NotifyCustomer → OrderSucceeded
     ↓ (fail)        ↓ (fail)       ↓ (fail)
 OrderFailed  ← CompensateOrder ←──────────────────
```

---

## ディレクトリ構成

```
terraform/sandboxes/phase8/
├── main.tf                      # KMS / DynamoDB / SNS / IAM / Lambda / SFN / CloudWatch
├── variables.tf                 # aws_region, notify_email
├── outputs.tf                   # state_machine_arn, dashboard_url, kms_key_arn 等
├── providers.tf                 # provider "aws" + required_providers
├── state_machine_definition.json  # ASL: Saga with Retry / Catch / Compensate
├── load.sh                      # 負荷生成 (正常系10件, 補償系3件, 在庫失敗2件)
├── watch.sh                     # メトリクス取得 + コンソール Deep Link
└── .gitignore
```

Lambda ソースコードは `backend/sandboxes/phase8/handler.py`（5ハンドラを 1 ファイルに集約）。
Terraform は `archive_file` で `backend/sandboxes/phase8/` ディレクトリを丸ごと zip する。

---

## 使い方

```bash
# 1. バリデーション (無料・ローカルのみ)
make sandbox-test-phase8

# 2. デプロイ (ここから課金あり)
make sandbox-up-phase8
#    → SNS email 確認メールへの承認を忘れずに

# 3. 負荷生成 (正常系 / 補償パス / 在庫失敗 の3シナリオ)
make sandbox-load-phase8

# 4. メトリクス観測 (~2-3分後に CloudWatch へ反映)
make sandbox-watch-phase8
#    → X-Ray コンソール / CW Dashboard URL もスクリプトが出力する

# 5. 後片付け (必須 — 放置すると継続課金)
make sandbox-down-phase8
```

手動で動かしたい場合は `./load.sh` / `./watch.sh` を直接実行できる（`AWS_REGION` 環境変数で上書き可）。

---

## コスト・Destroy 注意事項

| 項目 | 注意 |
|---|---|
| **KMS CMK** | `destroy` 後も **7 日間の削除猶予期間**中は課金が発生する（`deletion_window_in_days = 7`） |
| **Step Functions Standard** | 状態遷移数 × $0.025/1000。Map/Distributed Map を使うと遷移数が急増するので注意 |
| **CloudWatch Logs** | `include_execution_data = true` で全入出力がログに書き込まれる。PII を含む入力は destroy 前に手動削除を検討 |
| **SNS email subscription** | apply 直後は Pending。承認メールを放置しても購読料は発生しないが、通知が届かないまま混乱する |
| **X-Ray トレース** | sandbox では `fixed_rate = 1.0`(100%) サンプリング設定。本番流用時は必ず `0.05` 程度に下げること |

---

## 参考リンク

- 設計書: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md`（行 7874〜9150）
- プレビュー教材: `docs/learning/phase8/preview-step-functions.md`
- [AWS Step Functions Developer Guide](https://docs.aws.amazon.com/step-functions/latest/dg/welcome.html)
- [Amazon States Language Reference](https://docs.aws.amazon.com/step-functions/latest/dg/concepts-amazon-states-language.html)
