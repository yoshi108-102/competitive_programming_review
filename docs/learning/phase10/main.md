# Phase 10 — SNS — Pub/Sub ファンアウト通知

> ルーティング: ブラウザ閲覧は [index.html](index.html) ／ テスト UI は [demo/index.html](demo/index.html)

SNS

## 教材

- [Phase 10 ハンズオン — SNS sandbox](handson.md)
- [Phase 10 プレビュー教材: SNS — Pub/Sub ファンアウト通知](preview-sns.md)

## ハンズオン — 実 AWS sandbox

普段は無料で検証し、観測したい時だけ短時間 apply→観測→destroy する（apply から実課金）。

1. `make sandbox-test-phase10` — 無料検証（moto + terraform validate）
2. `make sandbox-up-phase10` — terraform apply（実課金開始）
3. `make sandbox-load-phase10` — topic に publish（属性付きでフィルタを試す）
4. `make sandbox-watch-phase10` — 発行 / 配信 / 失敗数、フィルタポリシーの効き（反映 数分）
5. `make sandbox-down-phase10` — terraform destroy（課金停止）

詳しい手順・期待出力・観察チェックリスト・トラブルシュート → [handson.html](handson.html) ／ [handson.md](handson.md)


