# Phase 7 — EventBridge — スケジュール & イベントバス

> ルーティング: ブラウザ閲覧は [index.html](index.html) ／ テスト UI は [demo/index.html](demo/index.html)

EventBridge

## 教材

- [handson.md](handson.md) — Phase 7 ハンズオン — EventBridge sandbox
- [preview-eventbridge.md](preview-eventbridge.md) — Phase 7 プレビュー教材: EventBridge — スケジュール & イベントバス

## ハンズオン — 実 AWS sandbox

普段は無料で検証し、観測したい時だけ短時間 apply→観測→destroy する（apply から実課金）。

1. `make sandbox-test-phase7` — 無料検証（moto + terraform validate）
2. `make sandbox-up-phase7` — terraform apply（実課金開始）
3. `make sandbox-load-phase7` — put-events で即時発火（rate(1 minute) も併用）
4. `make sandbox-watch-phase7` — ルール発火数 / 失敗数 / ターゲット Lambda（rate は初回発火まで最大 60 秒）
5. `make sandbox-down-phase7` — terraform destroy（課金停止）

詳しい手順・期待出力・観察チェックリスト・トラブルシュート → [handson.html](handson.html) ／ [handson.md](handson.md)

> ⚠ rate(1 minute) ルールは放置で毎分課金。観測が終わったらすぐ destroy。
