# Phase 9 — X-Ray — 分散トレース

> ルーティング: ブラウザ閲覧は [index.html](index.html) ／ テスト UI は [demo/index.html](demo/index.html)

X-Ray

## 教材

- [handson.md](handson.md) — Phase 9 ハンズオン — X-Ray sandbox
- [preview-xray.md](preview-xray.md) — Phase 9 プレビュー教材: X-Ray — 分散トレースを読む

## ハンズオン — 実 AWS sandbox

普段は無料で検証し、観測したい時だけ短時間 apply→観測→destroy する（apply から実課金）。

1. `make sandbox-test-phase9` — 無料検証（moto + terraform validate）
2. `make sandbox-up-phase9` — terraform apply（実課金開始）
3. `make sandbox-load-phase9` — トレース有効 Lambda を呼ぶ
4. `make sandbox-watch-phase9` — X-Ray / CloudWatch ServiceLens コンソールのサービスマップ＋ Lambda の通常メトリクス（トレース反映 数分）
5. `make sandbox-down-phase9` — terraform destroy（課金停止）

詳しい手順・期待出力・観察チェックリスト・トラブルシュート → [handson.html](handson.html) ／ [handson.md](handson.md)

> ⚠ 観測は CloudWatch メトリクスではなく X-Ray コンソール側が主（watch.sh が deep link を出力）。
