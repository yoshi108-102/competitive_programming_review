# Phase 4: CloudWatch Sandbox

Lambda 2 本(producer / consumer) + DynamoDB 1 本を動かしながら、
CloudWatch Logs / Metrics / Alarms / Dashboard を一気通貫で観測する学習用サンドボックス。

---

## 何を作るか

producer Lambda が DynamoDB にアイテムを書き込み、consumer Lambda が読み取る。
その活動ログ・メトリクスを CloudWatch で可視化し、アラームが SNS 経由でメール通知される
ところまでを Terraform でコード化する。

---

## 主要リソース

| 種別 | 名前 | 補足 |
|---|---|---|
| Lambda | `phase4-producer` | DynamoDB PutItem + EMF でカスタムメトリクス出力 |
| Lambda | `phase4-consumer` | DynamoDB Query + 10% 確率でエラー投入(アラーム検証用) |
| DynamoDB Table | `phase4-events` | PAY_PER_REQUEST / SSE 有効 / PITR 有効 |
| KMS Key | `alias/phase4-cw-logs` | CloudWatch Logs 暗号化 / キーローテーション有効 |
| Log Group x3 | `/aws/lambda/phase4-*` + `/aws/lambda-insights` | retention=1 日(課金残り防止) |
| Metric Filter x3 | `ProducerErrorCount` / `ConsumerErrorCount` / `ItemsWritten` | ログ → カスタムメトリクス変換 |
| Alarm (Metric) x2 | `phase4-producer-errors` / `phase4-producer-duration-high` | SNS 通知あり |
| Alarm (Composite) | `phase4-critical` | 上記 2 アラームの OR 集約 |
| SNS Topic | `phase4-alerts` | email サブスクリプション付き |
| Dashboard | `phase4-overview` | Invocations / Duration / カスタム / DDB / Alarm / ログウィジェット |

Lambda には `LambdaInsightsExtension` レイヤーを付加し、
`memory_utilization` や `init_duration` などを `LambdaInsights` Namespace に自動投入する。

---

## ファイル構成

```
terraform/sandboxes/phase4/
├── providers.tf      # Terraform / AWS provider 設定
├── variables.tf      # aws_region / alert_email
├── main.tf           # KMS / Log Groups / IAM / Lambda / DynamoDB / Filters / Alarms / Dashboard
├── outputs.tf        # 関数名・テーブル名・ダッシュボード URL など
├── load.sh           # ロード生成スクリプト(Lambda invoke を繰り返す)
├── watch.sh          # メトリクス確認 / アラーム状態確認 / Logs Insights クエリ
└── .terraform.lock.hcl  # コミット対象
```

Lambda のソースコードは `backend/sandboxes/phase4/` に置いてある(Terraform の `archive_file` が参照)。

---

## 使い方

```bash
# 1. Terraform apply でリソースを起動
make sandbox-up-phase4

# 2. SNS のメール確認リンクをクリック(メールボックスを確認)
#    confirm subscription しないとアラーム通知が届かない

# 3. ロード生成(デフォルト 20 ラウンド)
cd terraform/sandboxes/phase4 && ./load.sh 20

#    エラー多発シナリオ(consumer が 10% エラー → CompositeAlarm 検証)
./load.sh 50

# 4. メトリクス / アラーム / ログを観測(load.sh の 2〜3 分後に実行)
./watch.sh

# 5. 後片付け
make sandbox-down-phase4
```

`watch.sh` はターミナルに以下を出力する:
- Lambda 標準メトリクス(Invocations / Errors / Duration p99 / Throttles)
- カスタムメトリクス(ItemsWritten / ProducerErrorCount / ConsumerErrorCount)
- アラーム状態テーブル(Metric Alarms + Composite Alarm)
- Logs Insights クエリ結果(ERROR ログ抽出)
- ダッシュボード / Logs Insights / Alarms / Metrics のコンソール Deep Link

---

## 観測できるメトリクス一覧

| メトリクス名 | Namespace | 説明 |
|---|---|---|
| `Invocations` | AWS/Lambda | 呼び出し回数 |
| `Errors` | AWS/Lambda | Lambda 実行エラー数 |
| `Duration` (p99) | AWS/Lambda | レイテンシ 99 パーセンタイル |
| `Throttles` | AWS/Lambda | 同時実行上限超え |
| `ItemsWritten` | Phase4/Lambda | EMF 由来カスタム(producer が JSON ログに埋め込む) |
| `ProducerErrorCount` | Phase4/Lambda | Metric Filter 由来(ログ中の "ERROR" を計数) |
| `ConsumerErrorCount` | Phase4/Lambda | Metric Filter 由来 |
| `ConsumedReadCapacityUnits` | AWS/DynamoDB | DDB 読み取り消費 |
| `ConsumedWriteCapacityUnits` | AWS/DynamoDB | DDB 書き込み消費 |

---

## コスト・destroy の注意点

| 注意事項 | 詳細 |
|---|---|
| **KMS キーは 7 日間残る** | `terraform destroy` 後も KMS キーはペンディング削除状態で残る。`aws kms schedule-key-deletion --key-id <key-id> --pending-window-in-days 7` で確認可。最短 7 日で削除される |
| **SNS メールの unsubscribe** | `destroy` でサブスクリプションリソースは削除されるが、メールボックスに unsubscribe 確認が残る場合がある。メールのリンクから手動解除を推奨 |
| **カスタムメトリクスの課金** | `Phase4/Lambda` Namespace のカスタムメトリクス 3 本は合計 0.90 USD/月 程度。Sandbox なので数時間で破棄する限り数セント未満 |
| **Lambda Insights の追加課金** | LambdaInsights Namespace のメトリクス数本が追加で課金対象。同上で軽微 |
| **ロググループ retention=1 日** | 翌日には自動削除される。長期保存が必要なら destroy 前に S3 エクスポートを検討 |

---

## 参考リンク

- 設計書(Phase 4 節): `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md` L3664〜4798
- 学習教材(プレビュー): `docs/learning/phase4/preview-cloudwatch.md`
- CloudWatch 公式: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/WhatIsCloudWatch.html
- EMF 仕様: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Embedded_Metric_Format_Specification.html
- Lambda Insights: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Lambda-Insights.html
