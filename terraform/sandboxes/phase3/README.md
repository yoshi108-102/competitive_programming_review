# Phase 3 Sandbox — SQS (キュー → Lambda → DLQ)

## この sandbox は何を作るか

「Producer Lambda → SQS メインキュー → Consumer Lambda → DLQ」の非同期処理スライスを、
本番品質のセキュリティ設定込みで一発構築する。

- SSE-KMS(CMK) によるキュー暗号化
- Producer / Consumer を分離した最小権限 IAM ロール
- キューポリシーによる二重アクセス制御
- DLQ + maxReceiveCount=3 による毒メッセージ自動退避
- ReportBatchItemFailures 対応のイベントソースマッピング
- CloudWatch ダッシュボード(SQS 5 種 + Lambda 4 種メトリクス)

---

## 主要リソース

| ファイル | 内容 |
|---|---|
| `main.tf` | KMS CMK、メインキュー、DLQ、キューポリシー |
| `iam.tf` | Producer ロール(SendMessage + kms:GenerateDataKey)、Consumer ロール(Receive/Delete + kms:Decrypt) |
| `lambda.tf` | Producer Lambda(10 件送信)、Consumer Lambda(index%7==0 で意図的失敗)、イベントソースマッピング |
| `cloudwatch.tf` | ロググループ(retention=1日)、5 ウィジェットのダッシュボード |
| `outputs.tf` | キュー URL、Lambda 名、ダッシュボード URL |
| `providers.tf` | AWS + archive プロバイダ、default_tags |
| `variables.tf` | aws_region / prefix |
| `load.sh` | 3 シナリオのロード生成(Producer 経由 / CLI 直送 / 毒メッセージ) |
| `watch.sh` | SQS・Lambda メトリクス取得 + コンソール deep link 表示 |

---

## 使い方

```bash
# 1. moto テスト(あれば) + terraform validate だけ。無料・無起動。
make sandbox-test-phase3

# 2. 実 AWS にリソースを作成(課金開始)
make sandbox-up-phase3

# 3. ロード生成(Producer 経由 + CLI 直送 + 毒メッセージ)
make sandbox-load-phase3

# 4. CloudWatch でメトリクスを観測
#    !! SQS メトリクスは 5 分粒度。load から 5 分以上待ってから実行すること。
make sandbox-watch-phase3

# 5. 課金停止。必ず destroy する。
make sandbox-down-phase3
```

### 観測のポイント

| メトリクス | Namespace | 粒度 | 確認内容 |
|---|---|---|---|
| `ApproximateNumberOfMessagesVisible` | AWS/SQS | **5分** | メインキューの積み上がり |
| `ApproximateNumberOfMessagesVisible` | AWS/SQS | **5分** | DLQ への流入(毒メッセージ) |
| `Invocations` / `Errors` | AWS/Lambda | 1分 | Consumer の起動・失敗回数 |
| `Duration` p50/p99 | AWS/Lambda | 1分 | 処理時間分布 |

---

## コスト・destroy 注意

| 項目 | 内容 |
|---|---|
| SQS | $0.40/百万リクエスト。sandbox 規模では数セント以下 |
| KMS CMK | $1/月(キー保持) + $0.03/10000 API コール |
| KMS 削除保留 | `terraform destroy` 後 **7 日間** はペンディング削除状態。その間に誤参照するとエラー |
| Lambda | 呼び出し回数・duration 従量。sandbox 規模では無料枠内 |
| CloudWatch Dashboard | $3/ダッシュボード/月。destroy すれば即停止 |
| ログ自動消去 | `retention_in_days = 1` のため destroy しなくても翌日に自動削除 |

destroy 前に確認すること:
- DLQ のメッセージは destroy 時に消える。redrive が必要なら事前に実施
- ダッシュボードのスクリーンショットを取っておく場合はここで

---

## 関連リンク

- 設計書(Phase 3 節): `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md` 行 2367〜3663
- preview 教材: `docs/learning/phase3/preview-sqs.md`
- SQS 公式ガイド: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html>
- Lambda × SQS イベントソースマッピング: <https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html>
