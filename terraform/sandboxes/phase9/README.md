# Phase 9: X-Ray Distributed Tracing Sandbox

AWS X-Ray による分散トレーシングを体験する sandbox。
API Gateway → Lambda (Producer) → DynamoDB + SQS → Lambda (Consumer) の
非同期チェーンをトレースし、CloudWatch ServiceLens で Service Map を観察する。

## 構成リソース

| リソース | 名前 | 用途 |
|---|---|---|
| KMS CMK | `alias/phase9-xray` | X-Ray + CWLogs + DynamoDB + SQS の暗号化 |
| X-Ray Encryption Config | — | KMS によるトレースデータ暗号化 |
| X-Ray Sampling Rule | `phase9-high-priority` | `/api/*` を 10% サンプリング |
| X-Ray Sampling Rule | `phase9-health-check` | `/health` を 1% サンプリング |
| DynamoDB | `phase9-items` | Producer/Consumer がアイテムを読み書き |
| SQS | `phase9-main` | Producer → Consumer 非同期伝播 |
| SQS (DLQ) | `phase9-main-dlq` | 3回失敗したメッセージをデッドレター |
| Lambda | `phase9-producer` | API GW → DynamoDB put + SQS send |
| Lambda | `phase9-consumer` | SQS → DynamoDB update (status=processed) |
| API Gateway HTTP API | `phase9-api` | `POST /items` エンドポイント |
| CloudWatch Dashboard | `phase9-xray-sandbox` | Lambda/SQS メトリクス + X-Ray ディープリンク |

## 使い方

```bash
# 1. apply
make sandbox-up-phase9

# 2. ロード生成
bash terraform/sandboxes/phase9/load.sh

# 3. 観測 (別ターミナル)
bash terraform/sandboxes/phase9/watch.sh

# 4. 後片付け (必ず実行)
make sandbox-down-phase9
```

## X-Ray 観測ポイント

- **Service Map**: `CloudWatch > ServiceLens > Service Map` でノード依存グラフを確認
- **Traces**: `X-Ray > Traces` で個別トレースのタイムライン(サブセグメント)を確認
- **Annotations**: `annotation.function = "producer"` でフィルタリング
- **コールドスタート**: `Initialization` サブセグメントの有無を確認

## 注意

- `aws-xray-sdk` は Lambda Layer から提供。`patch_all()` で boto3 クライアントを自動パッチ。
- SQS 経由のトレース伝播は手動: `X-Amzn-Trace-Id` メッセージ属性に trace ID を乗せる。
- X-Ray のトレースデータは CloudWatch メトリクスには存在しない。`watch.sh` は Lambda の
  通常メトリクスを `get-metric-statistics` で確認し、トレース本体は X-Ray コンソールへ案内。
