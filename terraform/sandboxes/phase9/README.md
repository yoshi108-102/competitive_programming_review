# Phase 9: X-Ray Distributed Tracing Sandbox

AWS X-Ray による分散トレーシングを体験する sandbox。
`API Gateway → Lambda (Producer) → DynamoDB + SQS → Lambda (Consumer)` の
非同期チェーンを KMS 暗号化・最小権限 IAM 込みの本番品質構成でトレースし、
CloudWatch ServiceLens で Service Map を観察する。

詳しい手順は **[docs/learning/phase9/handson.md](../../../docs/learning/phase9/handson.md)** を参照。

---

## この sandbox が作るもの

| リソース | 名前 / 識別子 | 用途 |
|---|---|---|
| KMS CMK | `alias/phase9-xray` | X-Ray トレース・CWLogs・DynamoDB・SQS を一括暗号化 |
| X-Ray Encryption Config | — | KMS CMK でトレースデータを保護 |
| X-Ray Sampling Rule | `phase9-high-priority` | `/api/*` を reservoir=5/s + 10% サンプリング |
| X-Ray Sampling Rule | `phase9-health-check` | `/health` を 1% に間引き |
| DynamoDB | `phase9-items` | Producer: PutItem / Consumer: UpdateItem（PITR 有効） |
| SQS | `phase9-main` | 非同期メッセージキュー（visibility=60s） |
| SQS DLQ | `phase9-main-dlq` | 3 回受信失敗でデッドレター |
| Lambda | `phase9-producer` | API GW からリクエスト受付 → DynamoDB put + SQS send |
| Lambda | `phase9-consumer` | SQS トリガー → DynamoDB update（status=processed） |
| API Gateway HTTP API | `phase9-api` | `POST /v1/items` エンドポイント（CORS 付き） |
| CloudWatch Dashboard | `phase9-xray-sandbox` | Lambda/SQS メトリクス + X-Ray コンソールへの deep link |
| IAM ロール × 2 | `phase9-lambda-producer/consumer-role` | X-Ray Write・DynamoDB・SQS・KMS・Logs の最小権限 |
| CloudWatch Log Groups × 3 | `/aws/lambda/phase9-*` `/aws/apigateway/phase9` | KMS 暗号化・retention=1d |

---

## クイックコマンド

```bash
# 1. 構文チェック（無料・実リソース不要）
make sandbox-test-phase9

# 2. リソース作成（~3分・ここから課金開始）
make sandbox-up-phase9

# 3. トラフィック生成（POST 20回・エラー5回・SQS 直送5件）
make sandbox-load-phase9

# 4. メトリクス取得 + X-Ray/ServiceLens コンソール deep link 表示
make sandbox-watch-phase9

# 5. リソース破棄（必ず実行）
make sandbox-down-phase9
```

Terraform output に自動取得される識別子（`api_url` / `sqs_url` / `producer_function_name` / `consumer_function_name`）は、load.sh / watch.sh が内部で `terraform output -raw` を呼び出すため、手動設定不要。

---

## Phase 固有の前提

- **aws-xray-sdk は Lambda Layer 提供が必要**。IaC 側で Layer ARN を固定していないため、`make sandbox-up-phase9` の前に Layer の事前作成またはデプロイパッケージへの同梱が必要。
- Lambda ソースは `backend/sandboxes/phase9/producer.py` / `consumer.py`。`patch_all()` で boto3 を自動パッチし、DynamoDB/SQS 呼び出しがサブセグメントになる。
- 観測は CloudWatch Dashboard ではなく **X-Ray/ServiceLens コンソール** が主体（watch.sh が deep link を出力する）。

---

## コスト・destroy 注意

| 注意点 | 詳細 |
|---|---|
| **KMS 削除保留** | `deletion_window_in_days = 7` のため destroy 後も 7 日間 CMK が残り課金（$0.03/日）。即時削除は AWS コンソール > KMS から手動キャンセル。 |
| **X-Ray トレース保存** | 30 日固定保存。destroy 後もトレースデータは 30 日残る（読み取り課金なし）。 |
| **DynamoDB PITR** | apply 中のみ課金。destroy で停止。 |
| **コスト概算** | 数時間の利用なら $0.01〜$0.10 程度（KMS の日割りが支配的）。 |

destroy 後は タグ `Sandbox=phase9` のリソースが残存していないことをリソースグループで確認すること。

---

## 参照

- ハンズオン詳細: [`docs/learning/phase9/handson.md`](../../../docs/learning/phase9/handson.md)
- 設計書（Phase 9 節）: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md` L9151–10284
- プレビュー教材: [`docs/learning/phase9/preview-xray.md`](../../../docs/learning/phase9/preview-xray.md)
- 公式 Developer Guide: https://docs.aws.amazon.com/xray/latest/devguide/aws-xray.html
- CloudWatch ServiceLens: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ServiceLens.html
