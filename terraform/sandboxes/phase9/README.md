# Phase 9: X-Ray Distributed Tracing Sandbox

AWS X-Ray による分散トレーシングを体験する sandbox。
`API Gateway → Lambda (Producer) → DynamoDB + SQS → Lambda (Consumer)` の
非同期チェーンを KMS 暗号化・最小権限 IAM 込みの本番品質構成でトレースし、
CloudWatch ServiceLens で Service Map を観察する。

## この sandbox が作るもの

単一リクエストが複数 AWS サービスを跨ぐ様子を X-Ray でエンドツーエンド可視化する。
Producer Lambda がアイテムを DynamoDB に書いて SQS に enqueue し、Consumer Lambda が
それを非同期で処理する。SQS 経由のトレース ID 手動伝播・カスタム Annotation・
コールドスタートの可視化、という X-Ray 固有の体験に焦点を当てる。

## 主要リソース

| リソース | 名前 / 識別子 | 用途 |
|---|---|---|
| KMS CMK | `alias/phase9-xray` | X-Ray トレース・CWLogs・DynamoDB・SQS を一括暗号化 |
| X-Ray Encryption Config | — | KMS CMK でトレースデータを保護 |
| X-Ray Sampling Rule | `phase9-high-priority` | `/api/*` を reservoir=5/s + 10% サンプリング |
| X-Ray Sampling Rule | `phase9-health-check` | `/health` を 1% に間引き（ノイズ抑制） |
| DynamoDB | `phase9-items` | Producer: PutItem / Consumer: UpdateItem |
| SQS | `phase9-main` | 非同期メッセージキュー（visibility=60s） |
| SQS DLQ | `phase9-main-dlq` | 3回受信失敗でデッドレター |
| Lambda | `phase9-producer` | API GW からリクエスト受付 → DynamoDB put + SQS send |
| Lambda | `phase9-consumer` | SQS トリガー → DynamoDB update（status=processed） |
| API Gateway HTTP API | `phase9-api` | `POST /v1/items` エンドポイント（CORS 付き） |
| CloudWatch Dashboard | `phase9-xray-sandbox` | Lambda/SQS メトリクス + X-Ray コンソールへのディープリンク |
| IAM ロール×2 | `phase9-lambda-producer/consumer-role` | X-Ray Write・DynamoDB・SQS・KMS・Logs の最小権限 |
| CloudWatch Log Groups×3 | `/aws/lambda/phase9-*` `/aws/apigateway/phase9` | KMS 暗号化・retention=1d |

Lambda ソースは `src/producer.py` / `src/consumer.py`（aws-xray-sdk 使用）。
`patch_all()` で boto3 クライアントを自動パッチし、DynamoDB/SQS 呼び出しがサブセグメントになる。

## 使い方

```bash
# 1. リソース作成 (~3分)
make sandbox-up-phase9

# 2. ロード生成 (POST 20回・エラー5回・SQS 直送5件)
make sandbox-load-phase9
# または直接:
bash terraform/sandboxes/phase9/load.sh

# 3. メトリクス確認 + X-Ray コンソールへのリンク表示 (別ターミナル推奨)
make sandbox-watch-phase9
# または直接:
bash terraform/sandboxes/phase9/watch.sh

# 4. リソース破棄 (必ず実行)
make sandbox-down-phase9
```

### X-Ray で確認すべきポイント

1. **Service Map** (`CloudWatch > ServiceLens > Service Map`)
   ノード依存グラフに producer → DynamoDB / SQS が描画されているか
2. **Traces タイムライン** (`X-Ray > Traces`)
   DynamoDB/SQS サブセグメントのウォーターフォール展開
3. **Annotation フィルタ**
   コンソール検索式: `annotation.function = "producer"` / `annotation.item_id = "xxx"`
4. **コールドスタート**
   `Initialization` サブセグメントの有無（load.sh のシナリオ2で誘発）
5. **Consumer の孤立トレース**
   SQS を挟むとトレースが分断される様子 → `upstream_trace_id` Annotation で突合

## コスト・destroy 注意事項

| 注意点 | 詳細 |
|---|---|
| **KMS 削除保留** | `deletion_window_in_days = 7` のため destroy 後も 7 日間は CMK が残り課金される（$0.03/月）。緊急削除が必要なら AWS コンソールから手動キャンセル。 |
| **X-Ray トレース保存** | 30 日固定保存。destroy 後もトレースデータは 30 日残る（読み取り課金なし）。 |
| **Lambda Provisioned Concurrency** | EC-3（extra-credit）を apply した場合は `sandbox-down` で必ず destroy。放置すると常時課金。 |
| **DynamoDB PITR** | `point_in_time_recovery = true` は apply 中のみ課金。destroy で停止。 |

## 参照リンク

- 設計書（Phase 9 節）: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md` L9151–10284
- プレビュー教材（X-Ray 基礎 + 発展3節）: `docs/learning/phase9/preview-xray.md`
- 公式 Developer Guide: https://docs.aws.amazon.com/xray/latest/devguide/aws-xray.html
- CloudWatch ServiceLens: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ServiceLens.html
- Application Signals: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Application-Signals.html
