# Phase 4: CloudWatch Sandbox

Lambda 2本(producer / consumer) + DynamoDB 1本 + CloudWatch Logs/Metrics/Alarms/Dashboard を一気通貫で観測するサンドボックス。

## リソース一覧

| リソース | 名前 |
|---|---|
| Lambda (producer) | phase4-producer |
| Lambda (consumer) | phase4-consumer |
| DynamoDB Table | phase4-events |
| CloudWatch Dashboard | phase4-overview |
| SNS Topic | phase4-alerts |
| Composite Alarm | phase4-critical |
| KMS Key | alias/phase4-cw-logs |

## 使い方

```bash
# 環境変数
export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"

# デプロイ
make sandbox-up-phase4

# ロード生成(20ラウンド)
cd terraform/sandboxes/phase4 && ./load.sh 20

# 観測
cd terraform/sandboxes/phase4 && ./watch.sh

# 後片付け
make sandbox-down-phase4
```

## 観測できるメトリクス

| メトリクス名 | Namespace | 説明 |
|---|---|---|
| `Invocations` | AWS/Lambda | 呼び出し回数 |
| `Errors` | AWS/Lambda | Lambda 実行エラー数 |
| `Duration` (p99) | AWS/Lambda | レイテンシ 99 パーセンタイル |
| `Throttles` | AWS/Lambda | 同時実行上限超え |
| `ItemsWritten` | Phase4/Lambda | EMF 由来カスタム |
| `ProducerErrorCount` | Phase4/Lambda | Metric Filter 由来 |
| `ConsumerErrorCount` | Phase4/Lambda | Metric Filter 由来 |
| `ConsumedWriteCapacityUnits` | AWS/DynamoDB | DDB 書き込み消費 |
