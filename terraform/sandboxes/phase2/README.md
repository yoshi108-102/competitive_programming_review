# Phase 2 Sandbox — S3 本番品質バケット + Lambda + CloudWatch

## この sandbox は何を作るか

S3 バケットを **Block Public Access / SSE-KMS / アクセスログ / リクエストメトリクス** 付きで構築し、
ObjectCreated イベントで Lambda を起動して CloudWatch でシグナルを観測する。
「最小構成だが本番で通用するセキュリティ設定」を一通り手を動かして体感するための sandbox。

---

## 主要リソース

| リソース | 役割 |
|---|---|
| `aws_kms_key.s3` | S3 用カスタム CMK。SSE-KMS で PUT/GET を CloudTrail に記録できる |
| `aws_s3_bucket.main` | メインバケット。Versioning / SSE-KMS / ライフサイクル付き |
| `aws_s3_bucket.logs` | アクセスログ受け口バケット。SSE-S3(AES256) で十分 |
| `aws_s3_bucket_metric.main_all` | CloudWatch S3 リクエストメトリクスの有効化（これがないと AllRequests が出ない） |
| `aws_lambda_function.on_upload` | Python 3.12。ObjectCreated を受けてバケット/キー/サイズを JSON ログ出力 |
| `aws_cloudwatch_log_group.lambda` | 保持期間 1 日（destroy 後に課金ログが残らない最短設定） |
| `aws_cloudwatch_dashboard.phase2` | S3 AllRequests / PutRequests / Lambda Invocations & Errors / BucketSizeBytes を表示 |

Lambda ソースは `backend/sandboxes/phase2/handler.py` を参照（`archive_file` で ZIP 化して deploy）。

---

## ライフサイクル設定

| 経過日数 | 移行先 |
|---|---|
| 0 日 | STANDARD |
| 30 日 | STANDARD_IA |
| 90 日 | GLACIER_IR |
| 365 日 | 削除（`expiration`） |
| noncurrent 30 日 | 旧バージョン削除 |

---

## 使い方

```bash
# 1. 構文検証のみ（実 AWS 不要・無料）
make sandbox-test-phase2

# 2. 実リソースを作成（課金開始）
make sandbox-up-phase2

# 3. テストデータを投入（小オブジェクト 30 個 + 12 MB マルチパート + presigned URL 動作確認）
make sandbox-load-phase2

# 4. CloudWatch でメトリクス / Lambda ログを確認
make sandbox-watch-phase2

# 5. リソース削除（課金停止）
make sandbox-down-phase2
```

`watch.sh` は CloudWatch コンソールへのディープリンクも出力するので、
ブラウザで Dashboard `Phase2-S3` を開きながら観測するとわかりやすい。

---

## コスト・destroy 時の注意

| 項目 | 内容 |
|---|---|
| **KMS キー削除保留** | `deletion_window_in_days = 7` のため destroy 後 7 日間は課金が続く（$1/月 程度） |
| **BucketSizeBytes** | 日次メトリクスのため当日は 0 が返ることが多い。翌日確認推奨 |
| **S3 リクエストメトリクス** | `load.sh` 直後は最大 1〜2 分の反映遅延がある |
| **ログバケットの残留** | `force_destroy = true` で destroy 時に自動削除されるが、ログの遅延配信分が残ることがある |
| **アクセスログの遅延** | S3 アクセスログはベストエフォート（数分〜数時間の遅延）。CloudTrail データイベントの代替はない |

---

## 関連ドキュメント

- 設計書: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md`（Phase 2 節: 行 1379〜2366）
- プレビュー教材: `docs/learning/phase2/preview-s3.md`（関連サービス / セキュリティ / インフラ応用を含む）
