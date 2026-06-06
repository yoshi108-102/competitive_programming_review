# Phase 3 — SQS — 非同期キュー

> ルーティング: ブラウザ閲覧は [index.html](index.html) ／ テスト UI は [demo/index.html](demo/index.html)

SQS

## 教材

- [preview-sqs.md](preview-sqs.md) — Phase 3 プレビュー教材: SQS

## ハンズオン — 実 AWS sandbox

普段は無料で検証し、観測したい時だけ短時間 apply→観測→destroy する（apply から実課金）。

1. `make sandbox-test-phase3` — 無料検証（moto + terraform validate）
2. `make sandbox-up-phase3` — terraform apply（実課金開始）
3. `make sandbox-load-phase3` — メッセージを送信（一部は故意に失敗させ DLQ へ送る）
4. `make sandbox-watch-phase3` — キュー深さ / 滞留時間 / 送受信数 / DLQ（--period 300）（キュー系メトリクスは 5 分粒度 → load 後 5 分待ってから watch）
5. `make sandbox-down-phase3` — terraform destroy（課金停止）


