# Phase 2 — S3 — オブジェクトストレージ

> ルーティング: ブラウザ閲覧は [index.html](index.html) ／ テスト UI は [demo/index.html](demo/index.html)

S3

## 教材

- [handson.md](handson.md) — Phase 2 ハンズオン — S3 sandbox
- [preview-s3.md](preview-s3.md) — Phase 2 プレビュー教材: S3 — オブジェクトストレージを触ってみる

## ハンズオン — 実 AWS sandbox

普段は無料で検証し、観測したい時だけ短時間 apply→観測→destroy する（apply から実課金）。

1. `make sandbox-test-phase2` — 無料検証（moto + terraform validate）
2. `make sandbox-up-phase2` — terraform apply（実課金開始）
3. `make sandbox-load-phase2` — オブジェクトを put（ObjectCreated→Lambda が発火）
4. `make sandbox-watch-phase2` — Lambda Invocations（即時）。S3 ストレージ系メトリクスは日次（Lambda は数分、ストレージ系は翌日）
5. `make sandbox-down-phase2` — terraform destroy（課金停止）

詳しい手順・期待出力・観察チェックリスト・トラブルシュート → [handson.html](handson.html) ／ [handson.md](handson.md)

> ⚠ バケットは force_destroy 済みなのでオブジェクトが残っていても destroy できる。
