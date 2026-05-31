# Phase 10 Sandbox: SNS ファンアウト通知

## この Sandbox は何を作るか

Amazon SNS を核に「1 回の Publish → 複数コンシューマへの選択的配信」を体験する sandbox。
注文種別(standard / express / wholesale)ごとのフィルタポリシー付き SQS ファンアウトと、急ぎ注文(express)を即時処理する Lambda Notifier の 2 経路を同時に走らせ、CloudWatch でメトリクスを観測する。

主要な学習ポイント:
- SNS → SQS ファンアウト(フィルタポリシー / DLQ)
- SNS → Lambda 直接呼び出し(express のみ)
- FIFO トピック + FIFO SQS(順序保証の確認)
- SSE-KMS の二重壁(SNS/SQS 両サービスプリンシパルへの KMS 権限付与)
- CloudWatch Dashboard + DLQ アラームによる運用監視

---

## 構成リソース一覧

| 種別 | リソース名 | 備考 |
|---|---|---|
| KMS キー | `alias/phase10-sns` | SNS・SQS・Lambda 環境変数・CW Logs の SSE に共用 |
| SNS トピック(標準) | `phase10-orders` | ファンアウト用。トピックポリシーで Publish を publisher ロールのみに制限 |
| SNS トピック(FIFO) | `phase10-orders.fifo` | 順序保証デモ用。コンテンツベース重複除去有効 |
| SQS キュー(本体) | `phase10-fulfillment` / `phase10-analytics` / `phase10-wholesale` | 各キューにフィルタポリシー付き購読 |
| SQS キュー(FIFO) | `phase10-fifo-consumer.fifo` | FIFO トピック購読用 |
| SQS DLQ | `phase10-{name}-dlq` (3 本) | 14 日保持。購読レベルで DLQ を設定 |
| Lambda 関数 | `phase10-notifier` | express 注文のみ受信して CloudWatch Logs に記録 |
| CloudWatch Dashboard | `phase10-sns` | SNS/SQS/Lambda の主要メトリクスを一画面に集約 |
| CloudWatch アラーム | `phase10-{name}-dlq-not-empty` (3 本) | DLQ に 1 件でも来たら ALARM |
| IAM ロール | `phase10-publisher` / `phase10-subscriber-sqs` / `phase10-lambda-notifier` | 最小権限設計 |

ファイル構成:

```
terraform/sandboxes/phase10/
├── main.tf          # KMS / IAM / SNS / SQS / Lambda / CloudWatch を一枚岩で管理
├── providers.tf     # AWS provider + archive provider
├── variables.tf     # aws_region (default: ap-northeast-1)
├── outputs.tf       # topic ARN / queue URL / Lambda 名 / KMS ARN
├── load.sh          # ロード生成スクリプト(SNS Publish × 20件 + DLQ テスト)
└── watch.sh         # CloudWatch メトリクス観測スクリプト
```

Lambda ソース: `backend/sandboxes/phase10/handler.py`

---

## 使い方

```bash
# 1. 構築
make sandbox-up-phase10
# = terraform -chdir=terraform/sandboxes/phase10 init && apply -auto-approve

# 2. ロード生成(standard / express / wholesale / unknown / malformed の 5 シナリオ)
make sandbox-load-phase10
# = bash terraform/sandboxes/phase10/load.sh

# 3. 観測(load.sh 実行後 3〜5 分待ってから実行)
make sandbox-watch-phase10
# = bash terraform/sandboxes/phase10/watch.sh

# 4. 後片付け(必須)
make sandbox-down-phase10
# = terraform -chdir=terraform/sandboxes/phase10 destroy -auto-approve
```

手動で動かす場合:

```bash
cd terraform/sandboxes/phase10
terraform init
terraform apply -auto-approve
bash load.sh
# 3〜5 分後
bash watch.sh
terraform destroy -auto-approve
```

---

## コスト・destroy 注意事項

| 注意点 | 内容 |
|---|---|
| KMS キー削除保留 | `deletion_window_in_days = 7` のため、destroy 後も 7 日間は課金が続く($0.001/日程度)。コンソールで「削除保留中」になっていることを確認する |
| CloudWatch Logs 保持 | Lambda ログは `retention_in_days = 1` に設定済み。destroy 後のロググループ残存に注意 |
| DLQ の未読メッセージ | destroy 前に DLQ を確認・パージしておくと混乱を避けられる |
| メトリクス遅延 | SNS メトリクスは 1〜5 分の遅延がある。`watch.sh` は `load.sh` 実行後 3〜5 分後に実行すること |
| KMS タグフィルタ | コスト確認は Cost Explorer の `Sandbox=phase10` タグで絞ると発見しやすい |

---

## 関連リンク

- 設計書: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md` (行 10286〜11189)
- プレビュー教材: `docs/learning/phase10/preview-sns.md`
- AWS 公式: [Amazon SNS とは](https://docs.aws.amazon.com/sns/latest/dg/welcome.html)
- AWS 公式: [SNS メッセージフィルタリング](https://docs.aws.amazon.com/sns/latest/dg/sns-message-filtering.html)
