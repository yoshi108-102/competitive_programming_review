# Phase 4: CloudWatch Sandbox

Lambda 2 本（producer / consumer）と DynamoDB テーブルを動かしながら、CloudWatch Logs・Metrics・Alarms・Dashboard・Logs Insights を一気通貫で観測する学習サンドボックス。

---

## この sandbox が作るもの

| 種別 | 名前 | 補足 |
|---|---|---|
| Lambda | `phase4-producer` | DynamoDB PutItem + EMF でカスタムメトリクス自動出力 |
| Lambda | `phase4-consumer` | DynamoDB Scan + 10% 確率でエラー投入（アラーム検証用） |
| DynamoDB テーブル | `phase4-events` | PAY_PER_REQUEST / SSE 有効 / PITR 有効 |
| KMS キー | `alias/phase4-cw-logs` | CloudWatch Logs 暗号化・キーローテーション有効 |
| Log Group | `/aws/lambda/phase4-producer` | retention=1 日 |
| Log Group | `/aws/lambda/phase4-consumer` | retention=1 日 |
| Log Group | `/aws/lambda-insights` | Lambda Insights 用・retention=1 日 |
| Metric Filter | `phase4-producer-errors` → `Phase4/Lambda/ProducerErrorCount` | ログ中の ERROR を計数 |
| Metric Filter | `phase4-consumer-errors` → `Phase4/Lambda/ConsumerErrorCount` | 同上 |
| Metric Filter | `phase4-producer-items-written` → `Phase4/Lambda/ItemsWritten` | EMF ログから件数を抽出 |
| CloudWatch Alarm | `phase4-producer-errors` | ProducerErrorCount >= 1 で SNS 通知 |
| CloudWatch Alarm | `phase4-producer-duration-high` | Duration p99 > 5000 ms × 2 期間で SNS 通知 |
| Composite Alarm | `phase4-critical` | 上記 2 アラームの OR 集約 |
| SNS トピック | `phase4-alerts` | メールサブスクリプション付き |
| Dashboard | `phase4-overview` | Invocations / Duration / カスタム / DDB / Alarm / ログの 6 ウィジェット |

Lambda には `LambdaInsightsExtension:38` レイヤーを付加し、`LambdaInsights` 名前空間に `memory_utilization` / `init_duration` などを自動投入する。

---

## クイックコマンド一覧

```bash
# Terraform validate（無料・実リソースなし）
make sandbox-test-phase4

# リソース作成（課金開始）
make sandbox-up-phase4

# 通知を受け取る場合: apply 後にメールの Confirm subscription をクリック

# 負荷生成（デフォルト 20 ラウンド）
make sandbox-load-phase4
# ラウンド数を増やしたい場合は直接実行
cd terraform/sandboxes/phase4 && ./load.sh 50

# メトリクス・アラーム・ログ観測（load.sh 完了後 2〜3 分待ってから実行）
make sandbox-watch-phase4

# リソース削除（課金停止）
make sandbox-down-phase4
```

---

## 詳しい手順

ステップごとの解説・期待される出力例・観察チェックリスト・トラブルシュートは以下を参照。

**[docs/learning/phase4/handson.md](../../../docs/learning/phase4/handson.md)**（Markdown）
**[docs/learning/phase4/handson.html](../../../docs/learning/phase4/handson.html)**（ブラウザで読む場合）

---

## コスト・destroy の注意

| 注意事項 | 詳細 |
|---|---|
| **KMS キーは 7 日間残る** | `terraform destroy` 後も KMS キーは Pending deletion 状態で残る。最短 7 日で自動削除される |
| **カスタムメトリクス 3 本** | `Phase4/Lambda` 名前空間。無料枠（10 メトリクス/月）内に収まる。数時間なら実費 < $0.05 |
| **SNS の unsubscribe** | destroy でサブスクリプションリソースは消えるが、念のためメールのリンクから手動解除を推奨 |
| **Log Group retention=1 日** | 翌日には自動削除される。長期保存が必要なら destroy 前に S3 エクスポートを検討 |

destroy 後の確認コマンド:

```bash
# Sandbox=phase4 タグのリソースが残っていないことを確認（KMS は残るので要除外）
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Sandbox,Values=phase4 \
  --region ap-northeast-1
```
