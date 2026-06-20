# Phase 5 — CloudFront + WAF — エッジ配信とファイアウォール

> ルーティング: ブラウザ閲覧は [index.html](index.html) ／ テスト UI は [demo/index.html](demo/index.html)

CloudFront / WAF

## 教材

- [Phase 5 ハンズオン — CloudFront + WAF sandbox](handson.md)
- [Phase 5 プレビュー教材: CloudFront + WAF — エッジ配信とファイアウォール](preview-cloudfront-waf.md)

## ハンズオン — 実 AWS sandbox

普段は無料で検証し、観測したい時だけ短時間 apply→観測→destroy する（apply から実課金）。

1. `make sandbox-test-phase5` — 無料検証（moto + terraform validate）
2. `make sandbox-up-phase5` — terraform apply（実課金開始）・（CloudFront の作成は 10〜15 分）
3. `make sandbox-load-phase5` — 配信 URL に curl（無害／攻撃パターン）
4. `make sandbox-watch-phase5` — リクエスト数 / キャッシュ率 / WAF ブロック（メトリクスは us-east-1）（反映 数分）
5. `make sandbox-down-phase5` — terraform destroy（課金停止）

詳しい手順・期待出力・観察チェックリスト・トラブルシュート → [handson.html](handson.html) ／ [handson.md](handson.md)

> ⚠ CloudFront は作成 10〜15 分・破棄 30〜45 分。sandbox-down-all の前に phase5 を個別 destroy 推奨。全リソース us-east-1。
