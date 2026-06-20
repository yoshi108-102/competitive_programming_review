# Phase 8 — Step Functions — ステートマシン

> ルーティング: ブラウザ閲覧は [index.html](index.html) ／ テスト UI は [demo/index.html](demo/index.html)

Step Functions

## 教材

- [Phase 8 ハンズオン — Step Functions sandbox](handson.md)
- [Phase 8 プレビュー教材: Step Functions](preview-step-functions.md)

## ハンズオン — 実 AWS sandbox

普段は無料で検証し、観測したい時だけ短時間 apply→観測→destroy する（apply から実課金）。

1. `make sandbox-test-phase8` — 無料検証（moto + terraform validate）
2. `make sandbox-up-phase8` — terraform apply（実課金開始）
3. `make sandbox-load-phase8` — start-execution で実行を開始
4. `make sandbox-watch-phase8` — 実行開始/成功/失敗数・所要時間＋コンソールのビジュアル実行（反映 1〜2 分）
5. `make sandbox-down-phase8` — terraform destroy（課金停止）

詳しい手順・期待出力・観察チェックリスト・トラブルシュート → [handson.html](handson.html) ／ [handson.md](handson.md)


