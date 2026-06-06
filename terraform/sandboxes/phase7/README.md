# Phase 7 — EventBridge Sandbox

EventBridge のコアパターンを手を動かして体験するサンドボックス。
カスタムイベントバス・ルール・DLQ・Archive & Replay・Scheduler・EMF カスタムメトリクスを一気通貫で構築する。

**詳しい手順・出力例・観察ポイント・トラブルシュートは [handson.md](../../../docs/learning/phase7/handson.md) を参照。**

---

## このサンドボックスが作るもの

| リソース | 名前 | 備考 |
|---|---|---|
| KMS キー（EventBridge バス用） | `alias/phase7-eventbridge` | カスタムバスの暗号化 |
| KMS キー（Lambda 環境変数用） | *(alias なし)* | Lambda env vars の暗号化 |
| カスタムイベントバス | `phase7-bus` | KMS 暗号化・リソースポリシー付き |
| イベントアーカイブ | `phase7-archive` | 30 日保持・全イベント対象 |
| DLQ | `phase7-dlq` | 14 日保持・KMS 暗号化 |
| EventBridge ルール（カスタムバス） | `phase7-processor-rule` | `com.example.orders` / `order.created` → Lambda |
| EventBridge ルール（デフォルトバス） | `phase7-heartbeat-rule` | **rate(1 minute) — destroy 忘れ注意** |
| Lambda | `phase7-processor` | Python 3.12・X-Ray Active・EMF 出力 |
| Scheduler グループ | `phase7-group` | — |
| Scheduler スケジュール | `phase7-one-shot` | at(2099-01-01T00:00:00) プレースホルダー |
| CloudWatch ダッシュボード | `phase7-dashboard` | 5 ウィジェット（Lambda / EMF / DLQ / EB / Logs） |
| CloudWatch アラーム | `phase7-lambda-errors` / `phase7-dlq-messages` | — |

アーキテクチャ概略:

```
load.sh (put-events)
  └─► phase7-bus [KMS 暗号化]
       ├─► processor-rule: order.created → phase7-processor (Lambda)
       │    ├─► 成功: EMF → Phase7/EventBridge/EventsProcessed
       │    └─► 失敗 (retry x2) → phase7-dlq (SQS)
       └─► phase7-archive: 全イベントを 30 日保持

rate(1 minute) [デフォルトバス]
  └─► phase7-processor (heartbeat — 必ず destroy すること!)

EventBridge Scheduler → phase7-processor (at 2099 プレースホルダー)
```

---

## クイックコマンド一覧

```bash
# 1. 構文チェック（AWS 接続不要）
make sandbox-test-phase7

# 2. デプロイ（rate ルールが即有効化）
make sandbox-up-phase7

# 3. カスタムイベント送信（10 件 + ミスマッチ 3 件 + 直接 invoke）
make sandbox-load-phase7

# 4. CloudWatch メトリクス確認（90 秒待機 → CLI 照会 → deep link 出力）
make sandbox-watch-phase7

# 5. 全リソース削除（必須）
make sandbox-down-phase7
```

`terraform output` で各リソース名・URL を確認できます:

```bash
terraform -chdir=terraform/sandboxes/phase7 output
```

---

## コスト・destroy 注意事項

| 注意点 | 詳細 |
|---|---|
| **rate(1 minute) ルール** | destroy 忘れで毎分 Lambda が起動し続ける。観測後は即 `sandbox-down-phase7` |
| **KMS キー削除保留** | destroy 後も 7 日間キーが保留状態で残る。再 apply で名前衝突が起きた場合は AWS コンソールで削除キャンセルするか prefix を変える |
| **EMF カスタムメトリクス** | 初回出現まで最大 5 分かかる。watch.sh 冒頭の 90 秒ウェイトはこのバッファ |
| **Scheduler プレースホルダー** | `at(2099-01-01T00:00:00)` は実際には発火しない。テストする場合は apply 前に時刻を書き換える |

コスト目安: EventBridge カスタムイベント 13 件は無料枠内。KMS キー × 2 が数日分の日割りで数セント程度。

---

## 参照

- **詳細ハンズオン**: [`docs/learning/phase7/handson.md`](../../../docs/learning/phase7/handson.md)
- 設計書: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md`（Phase 7 節: 行 6742〜）
- 公式(EventBridge): https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-what-is.html
- 公式(Scheduler): https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html
