# Phase 3 Sandbox — SQS (キュー → Lambda → DLQ)

「Producer Lambda → SQS メインキュー → Consumer Lambda → DLQ」の非同期処理スライスを、
本番品質のセキュリティ設定込みで一発構築する。

---

## この sandbox が作るもの

| リソース | 名前 | 概要 |
|---|---|---|
| KMS CMK | `alias/phase3-sqs` | キュー暗号化用 CMK（自動ローテーション有効、削除猶予 7日） |
| SQS メインキュー | `phase3-main` | SSE-KMS、保持 4日、visibility timeout 30秒 |
| SQS DLQ | `phase3-dlq` | SSE-KMS、保持 14日（最長）、maxReceiveCount=3 |
| IAM ロール | `phase3-producer-role` | SendMessage + kms:GenerateDataKey のみ許可 |
| IAM ロール | `phase3-consumer-role` | Receive/Delete/ChangeVisibility + kms:Decrypt のみ許可 |
| Lambda（Producer） | `phase3-producer` | Python 3.12。`count` 件のメッセージを一括送信 |
| Lambda（Consumer） | `phase3-consumer` | Python 3.12。`index % 7 == 0` で意図的例外 → DLQ 流入デモ |
| Lambda ESM | — | SQS → Consumer（batch_size=5、ReportBatchItemFailures） |
| CloudWatch ダッシュボード | `phase3-sqs-dashboard` | SQS 5種 + Lambda 4種メトリクスを 5 ウィジェットで可視化 |
| CloudWatch ロググループ | `/aws/lambda/phase3-{producer,consumer}` | retention 1日（destroy 不要で翌日自動消去） |

全リソースにタグ `Sandbox=phase3 / ManagedBy=terraform` が付く。

---

## クイックコマンド一覧

```bash
# 1. moto テスト(あれば) + terraform validate のみ — 無料・無起動
make sandbox-test-phase3

# 2. 実 AWS にリソースを作成（課金開始）
make sandbox-up-phase3

# 3. ロード生成（Producer 経由 50件 + CLI 直送 10件 + 毒メッセージ 3件）
make sandbox-load-phase3

# !! SQS メトリクスは 5分粒度。load から 5 分以上待ってから watch を実行すること
# 4. CloudWatch でメトリクスを観測
make sandbox-watch-phase3

# 5. 課金停止。必ず destroy する
make sandbox-down-phase3
```

---

## コスト・destroy 注意

| 項目 | 内容 |
|---|---|
| SQS | $0.40/百万リクエスト。sandbox 規模（〜60件）では無料枠内 |
| KMS CMK | $1/月（キー保持）。日割り約 $0.03/日 |
| KMS 削除保留 | `terraform destroy` 後 **7 日間**はペンディング削除状態。その間に同名エイリアスは再作成不可 |
| Lambda | sandbox 規模では無料枠内 |
| CloudWatch ダッシュボード | $3/ダッシュボード/月。destroy で即停止 |
| ログ自動消去 | `retention_in_days = 1` のため翌日に自動削除 |

destroy 前チェック:
- DLQ のメッセージは destroy と同時に消える。必要なら事前に redrive または保存
- ダッシュボードのスクリーンショットを取っておく場合はここで

---

## 詳しい手順・観察ポイント・トラブルシュート

[docs/learning/phase3/handson.md](../../../docs/learning/phase3/handson.md) を参照。

HTML 版（note 風）: [docs/learning/phase3/handson.html](../../../docs/learning/phase3/handson.html)

---

## 関連リンク

- 設計書（Phase 3 節）: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md` 行 2367〜3663
- preview 教材: `docs/learning/phase3/preview-sqs.md`
- SQS 公式ガイド: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html>
- Lambda × SQS イベントソースマッピング: <https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html>
