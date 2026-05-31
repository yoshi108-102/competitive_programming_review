# Phase 7 — EventBridge Sandbox

EventBridge のコアパターンを手を動かして体験するサンドボックス。
カスタムイベントバス・ルール・DLQ・Archive & Replay・Scheduler・EMF カスタムメトリクスを一気通貫で構築する。

---

## このサンドボックスで作るもの

```
load.sh (put-events)
  └─► カスタムバス phase7-bus [KMS 暗号化]
       ├─► ルール: order.created → Lambda processor
       │    ├─► 成功: EMF → Phase7/EventBridge/EventsProcessed (カスタムメトリクス)
       │    └─► 失敗 (retry x2) → DLQ (SQS, KMS 暗号化)
       └─► Archive: 全イベントを 30 日保持 → Replay 可能

rate(1 minute) [デフォルトバス]
  └─► Lambda processor (heartbeat — 必ず destroy すること!)

EventBridge Scheduler [one-shot, Asia/Tokyo TZ]
  └─► Lambda processor (at(2099-01-01T00:00:00) プレースホルダー)

CloudWatch Dashboard
  └─► Lambda / EventBridge / SQS(DLQ) / EMF メトリクスを 1 画面で可視化
```

---

## 主要リソース一覧

| リソース | 名前 |
|---|---|
| KMS キー (EventBridge バス用) | `alias/phase7-eventbridge` |
| KMS キー (Lambda 環境変数用) | *(alias なし、ARN で参照)* |
| カスタムイベントバス | `phase7-bus` |
| イベントアーカイブ | `phase7-archive` (30 日保持) |
| DLQ | `phase7-dlq` (14 日保持) |
| ルール: カスタムイベント | `phase7-processor-rule` |
| ルール: heartbeat (1 分) | `phase7-heartbeat-rule` |
| Lambda | `phase7-processor` (Python 3.12, X-Ray Active) |
| Scheduler グループ | `phase7-group` |
| Scheduler スケジュール | `phase7-one-shot` |
| CloudWatch ダッシュボード | `phase7-dashboard` |
| Lambda エラーアラーム | `phase7-lambda-errors` |
| DLQ メッセージアラーム | `phase7-dlq-messages` |

Terraform ファイル構成: `main.tf` (全リソース統合) / `providers.tf` / `variables.tf` / `outputs.tf`
Lambda ソース: `backend/sandboxes/phase7/handler.py` (monorepo 相対パスで zip 化)

---

## 使い方

```bash
# 1. terraform validate (ローカル完結、AWS 認証不要)
make sandbox-test-phase7

# 2. AWS へデプロイ
make sandbox-up-phase7

# 3. カスタムイベントをバースト送信 (10件 + パターン不一致 3件 + Lambda 直接 invoke)
make sandbox-load-phase7

# 4. CloudWatch でメトリクスを観測 (~1-2 分待機が必要)
make sandbox-watch-phase7

# 5. 必ず destroy (rate ルールが毎分 Lambda を起動し続ける)
make sandbox-down-phase7
```

`watch.sh` はコンソール deep-link も出力する。ダッシュボード URL は `terraform output dashboard_url` で確認できる。

---

## コスト・destroy 注意事項

| 注意点 | 詳細 |
|---|---|
| **rate(1 minute) ルール** | destroy 忘れで毎分 Lambda が起動し続ける。sandbox 観測後は即 `sandbox-down-phase7` |
| **KMS キー削除保留** | `terraform destroy` 後も 7 日間はキーが保留状態で残る。再 apply で名前衝突が起きる場合は AWS コンソールから削除をキャンセルするか prefix を変える |
| **EMF カスタムメトリクス** | 初回出現まで 2-5 分かかる。`watch.sh` の `sleep 90` はこのバッファ |
| **Scheduler プレースホルダー** | `at(2099-01-01T00:00:00)` は実際には発火しない。テストしたい場合は apply 前に `+2分` の時刻へ書き換える |
| **Archive** | destroy すると 30 日保持のアーカイブも削除される。Replay テストをする場合は destroy 前に実施 |

---

## 参照

- 設計書: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md` (Phase 7 節: 行 6742〜7873)
- プレビュー教材: `docs/learning/phase7/preview-eventbridge.md`
- 公式: https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-what-is.html
- 公式(Scheduler): https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html
