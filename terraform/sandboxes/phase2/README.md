# Phase 2 Sandbox — S3 本番品質バケット + Lambda + CloudWatch

S3 バケットを **Block Public Access / SSE-KMS / アクセスログ / リクエストメトリクス** 付きで構築し、
ObjectCreated イベントで Lambda を起動して CloudWatch でシグナルを観測する sandbox。
「最小構成だが本番で通用するセキュリティ設定」を一通り手を動かして体感できる。

詳しい手順・期待出力・トラブルシュートは
**[docs/learning/phase2/handson.md](../../../docs/learning/phase2/handson.md)** を参照。

---

## この sandbox が作るもの

| リソース（Terraform） | 名前 / 設定 | 役割 |
|---|---|---|
| `aws_kms_key.s3` | エイリアス `alias/phase2-s3`、削除保留 7 日 | S3 SSE-KMS 用カスタム CMK。復号ログが CloudTrail に残る |
| `aws_s3_bucket.main` | `<prefix>-phase2-main-<account-id>` | メインバケット。Versioning / SSE-KMS / ライフサイクル付き |
| `aws_s3_bucket.logs` | `<prefix>-phase2-logs-<account-id>` | アクセスログ受け口。SSE-S3(AES256) |
| `aws_s3_bucket_metric.main_all` | FilterId: `AllRequests` | CloudWatch S3 リクエストメトリクスの有効化（必須） |
| `aws_s3_bucket_lifecycle_configuration.main` | 30d→IA / 90d→GLACIER_IR / 365d→削除 | ストレージコスト自動最適化 |
| `aws_lambda_function.on_upload` | `<prefix>-phase2-on-upload` / Python 3.12 | ObjectCreated を受けてバケット/キー/サイズを JSON ログ出力 |
| `aws_cloudwatch_log_group.lambda` | 保持 1 日 | destroy 後に課金ログが残らない最短設定 |
| `aws_cloudwatch_dashboard.phase2` | `Phase2-S3` | AllRequests / PutRequests / Lambda Invocations & Errors / BucketSizeBytes を表示 |

Lambda ソース: `backend/sandboxes/phase2/handler.py`（`archive_file` で ZIP 化して deploy）

---

## クイックコマンド

```bash
# 1. 構文検証のみ（実 AWS 不要・無料）
make sandbox-test-phase2

# 2. 実リソースを作成（課金開始）
make sandbox-up-phase2

# 3. テストデータを投入
#    小オブジェクト 30 個 + 12 MB マルチパート + presigned URL 動作確認
make sandbox-load-phase2

# 4. CloudWatch でメトリクス / Lambda ログを確認
#    watch.sh は 90 秒ウェイト後にメトリクスを取得し、コンソール Deep Link も出力する
make sandbox-watch-phase2

# 5. リソース削除（課金停止）
make sandbox-down-phase2
```

---

## コスト・destroy 時の注意

| 項目 | 内容 |
|---|---|
| **KMS キー削除保留** | `deletion_window_in_days = 7` のため destroy 後 7 日間は課金が続く（≒ $0.03/日） |
| **CloudWatch ダッシュボード** | $3.00/月（≒ $0.10/日）。destroy で即削除される |
| **BucketSizeBytes** | 日次メトリクスのため当日は 0 が返ることが多い。翌日 UTC に確認 |
| **S3 リクエストメトリクス** | `load.sh` 直後は最大 1〜2 分の反映遅延がある |
| **ログバケットの残留** | `force_destroy = true` で destroy 時に自動削除。ただしログの遅延配信分が残ることがある |
| **アクセスログの遅延** | S3 アクセスログはベストエフォート（数分〜数時間の遅延）。リアルタイム監査は CloudTrail データイベントで |

---

## 関連ドキュメント

- ハンズオン手順（期待出力・トラブルシュート込み）: `docs/learning/phase2/handson.md`
- HTML 版: `docs/learning/phase2/handson.html`
- 設計書: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md`（Phase 2 節: 行 1379〜）
- プレビュー教材: `docs/learning/phase2/preview-s3.md`
