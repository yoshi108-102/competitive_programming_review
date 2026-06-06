# Phase 6 — Bedrock — Claude を呼ぶ

> ルーティング: ブラウザ閲覧は [index.html](index.html) ／ テスト UI は [demo/index.html](demo/index.html)

Bedrock (Claude)

## 教材

- [handson.md](handson.md) — Phase 6 ハンズオン — Bedrock (Claude) sandbox
- [preview-bedrock.md](preview-bedrock.md) — Phase 6 プレビュー教材: Bedrock — Claude を呼ぶ Messages API 体験

## ハンズオン — 実 AWS sandbox

普段は無料で検証し、観測したい時だけ短時間 apply→観測→destroy する（apply から実課金）。

1. `make sandbox-test-phase6` — 無料検証（moto + terraform validate）
2. `make sandbox-up-phase6` — terraform apply（実課金開始）
3. `make sandbox-load-phase6` — InvokeModel を少数回・短プロンプトで実行
4. `make sandbox-watch-phase6` — AWS/Bedrock の Invocations / Latency（反映 2〜3 分）
5. `make sandbox-down-phase6` — terraform destroy（課金停止）

詳しい手順・期待出力・観察チェックリスト・トラブルシュート → [handson.html](handson.html) ／ [handson.md](handson.md)

> ⚠ 事前にコンソールで「モデルアクセス」を有効化すること。未有効だと InvokeModel が 403 になり load.sh が中断、CloudWatch にも何も出ない。トークン課金あり。
