# Phase 10 Sandbox: SNS ファンアウト通知

SNS を核に「1 回の Publish → 複数コンシューマへの選択的配信」を体験する sandbox。
注文種別ごとのフィルタポリシー付き SQS ファンアウトと、急ぎ注文を即時処理する Lambda Notifier の 2 経路を同時に走らせ、CloudWatch でメトリクスを観測する。

詳しい手順・観察ポイント・トラブルシュートは **[handson.md](../../../docs/learning/phase10/handson.md)** を参照。

---

## 作成されるリソース

| 種別 | リソース名 | 備考 |
|---|---|---|
| KMS キー | `alias/phase10-sns` | SNS・SQS・Lambda・CW Logs の SSE に共用 |
| SNS トピック（標準） | `phase10-orders` | ファンアウト用。フィルタポリシー付き購読 × 3 |
| SNS トピック（FIFO） | `phase10-orders.fifo` | 順序保証デモ用。コンテンツベース重複除去有効 |
| SQS キュー（本体） | `phase10-fulfillment` / `phase10-analytics` / `phase10-wholesale` | 各キューに DLQ 付き（maxReceiveCount=3） |
| SQS キュー（FIFO） | `phase10-fifo-consumer.fifo` | FIFO トピック購読用 |
| SQS DLQ | `phase10-{name}-dlq`（3 本） | 14 日保持 |
| Lambda 関数 | `phase10-notifier` | Python 3.12。express 注文のみ受信 |
| CloudWatch Dashboard | `phase10-sns` | SNS / SQS / Lambda メトリクスを一画面に集約 |
| CloudWatch アラーム | `phase10-{name}-dlq-not-empty`（3 本） | DLQ に 1 件でも来たら ALARM |
| IAM ロール | `phase10-publisher` / `phase10-subscriber-sqs` / `phase10-lambda-notifier` | 最小権限設計 |

---

## クイックコマンド

```bash
# 1. validate（無課金・無起動）
make sandbox-test-phase10

# 2. リソース作成（課金開始）
make sandbox-up-phase10

# 3. ロード生成（5 シナリオ 21 件）
make sandbox-load-phase10

# 4. 観測（load.sh の 3〜5 分後に実行）
make sandbox-watch-phase10

# 5. 後片付け（必須）
make sandbox-down-phase10
```

### ロードシナリオ早見表

| シナリオ | order_type | 件数 | 届く購読先 |
|---|---|---|---|
| standard | `standard` | 10 | fulfillment + analytics |
| express | `express` | 5 | fulfillment + analytics + Lambda |
| wholesale | `wholesale` | 3 | wholesale + analytics |
| unknown | `unknown_type` | 2 | analytics のみ（フィルタ除外） |
| malformed | `express`（本文 NOT_JSON） | 1 | Lambda parse 失敗 → DLQ |

---

## コスト・destroy 注意事項

| 注意点 | 内容 |
|---|---|
| KMS キー削除保留 | `deletion_window_in_days = 7` のため、destroy 後も 7 日間は $0.007/日 課金が続く。コンソールで「削除保留中」を確認する |
| メトリクス遅延 | SNS メトリクスは 1〜5 分の遅延がある。`watch.sh` は `load.sh` 実行後 3〜5 分後に実行すること |
| DLQ の未読メッセージ | destroy 前に DLQ を確認・パージしておくと混乱を避けられる |
| Lambda ログ保持 | `retention_in_days = 1` 設定済み。destroy 後のロググループは翌日以降に自動削除 |
| コスト確認 | Cost Explorer の `Sandbox=phase10` タグで絞ると発見しやすい |

**全体コスト目安: ほぼ無料〜数セント（KMS 7 日保留 $0.007/日 が主なコスト）**

---

## 関連リンク

- ハンズオン詳細: [`docs/learning/phase10/handson.md`](../../../docs/learning/phase10/handson.md)
- HTML 版: [`docs/learning/phase10/handson.html`](../../../docs/learning/phase10/handson.html)
- 設計書: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md`（行 10286〜）
- Lambda ソース: `backend/sandboxes/phase10/handler.py`
- AWS 公式: [Amazon SNS とは](https://docs.aws.amazon.com/sns/latest/dg/welcome.html) / [SNS メッセージフィルタリング](https://docs.aws.amazon.com/sns/latest/dg/sns-message-filtering.html)
