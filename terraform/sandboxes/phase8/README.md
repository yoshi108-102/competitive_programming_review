# Phase 8 — Step Functions (Order Saga)

## 概要

AWS Step Functions を使った Saga パターンのサンドボックス。

- **ステートマシン**: Standard / STANDARD type、X-Ray トレース有効
- **Lambda**: 5 関数 (validate_order, charge_payment, update_inventory, notify_customer, compensate_order)
- **DynamoDB**: orders テーブル (PAY_PER_REQUEST, KMS 暗号化)
- **SNS**: 注文通知トピック (KMS 暗号化)
- **KMS**: 全リソース共用 CMK (key rotation enabled)
- **CloudWatch**: ダッシュボード + 障害アラーム

## 使い方

```bash
# 1. バリデーション (無料)
make sandbox-test-phase8

# 2. デプロイ (課金あり)
make sandbox-up-phase8

# 3. 負荷生成
make sandbox-load-phase8

# 4. メトリクス観測
make sandbox-watch-phase8

# 5. 後片付け (必須)
make sandbox-down-phase8
```

## Saga フロー

```
ValidateOrder → ChargePayment → UpdateInventory → NotifyCustomer → OrderSucceeded
                    ↓                   ↓
               CompensateOrder ← CompensateOrder
                    ↓
               OrderFailed
```

## 注意事項

- KMS CMK は削除猶予期間 7 日。`destroy` 後も 7 日間は課金される。
- SNS email subscription は apply 後に確認メールへの承認が必要。
- Step Functions Standard は状態遷移数で課金 ($0.025/1000)。
- `include_execution_data = true` の設定のため、実行データが CloudWatch Logs に記録される。本番では機微データに注意。
