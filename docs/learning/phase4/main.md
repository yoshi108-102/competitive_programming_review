# Phase 4 — CloudWatch — メトリクス・ログ・アラーム

> ルーティング: ブラウザ閲覧は [index.html](index.html) ／ テスト UI は [demo/index.html](demo/index.html)

CloudWatch

## 教材

- [preview-cloudwatch.md](preview-cloudwatch.md) — Phase 4 プレビュー教材: CloudWatch — メトリクス・ログ・アラーム

## ハンズオン — 実 AWS sandbox

普段は無料で検証し、観測したい時だけ短時間 apply→観測→destroy する（apply から実課金）。

1. `make sandbox-test-phase4` — 無料検証（moto + terraform validate）
2. `make sandbox-up-phase4` — terraform apply（実課金開始）
3. `make sandbox-load-phase4` — Lambda を呼びカスタムメトリクスを発行
4. `make sandbox-watch-phase4` — カスタム指標・アラーム状態（OK/ALARM）・ダッシュボード（反映 1〜3 分）
5. `make sandbox-down-phase4` — terraform destroy（課金停止）

> ⚠ SNS メール購読は apply 後に届く確認メールの承認が必要（通知を受け取る場合）。
