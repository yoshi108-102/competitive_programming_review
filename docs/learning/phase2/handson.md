# Phase 2 ハンズオン — S3 sandbox

## 前提条件

### AWS 認証・権限

- `aws configure` または環境変数（`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`）が設定済みであること
- IAM ユーザー / ロールに以下が付与されていること
  - `s3:*`（バケット作成・オブジェクト操作）
  - `kms:CreateKey` / `kms:ScheduleKeyDeletion` / `kms:Alias*`
  - `lambda:CreateFunction` / `lambda:AddPermission` など Lambda 系
  - `iam:CreateRole` / `iam:PutRolePolicy`
  - `cloudwatch:PutDashboard` / `cloudwatch:GetMetricStatistics`
  - `logs:CreateLogGroup` / `logs:PutLogEvents` / `logs:DescribeLogStreams`
- 動作確認済みの最低権限セット: `AdministratorAccess`（学習用 AWS アカウント推奨）

### リージョン

`ap-northeast-1`（東京）を使用。変更する場合は `variables.tf` の `aws_region` を上書き。

```bash
export AWS_DEFAULT_REGION=ap-northeast-1
```

### 課金開始の注意

`make sandbox-up-phase2` を実行した時点で実 AWS リソースへの課金が始まる。
特に **KMS カスタムキーは削除保留期間（7 日間）も課金継続**する。
学習が終わったら必ず `make sandbox-down-phase2` を実行すること。

### Phase 固有の前提

- Terraform 1.5 以上・AWS CLI v2 がインストール済みであること
- `uv` がインストール済みであること（`sandbox-test` で Python テストを実行する）
- 12 MB のランダムデータを生成するため `dd` コマンドが使えること（macOS / Linux 標準で OK）
- `curl` が使えること（presigned URL 動作確認用）

---

## 全体の流れ

| ステップ | コマンド | 内容 | 課金 |
|---|---|---|---|
| 1 | `make sandbox-test-phase2` | terraform validate（無料・無起動） | なし |
| 2 | `make sandbox-up-phase2` | terraform apply でリソース作成 | 開始 |
| 3 | `make sandbox-load-phase2` | load.sh：オブジェクト投入 + presigned URL | 微小 |
| 4 | `make sandbox-watch-phase2` | watch.sh：CloudWatch でメトリクス/ログ観測 | なし |
| 5 | `make sandbox-down-phase2` | terraform destroy でリソース削除 | 停止 |

---

## ステップ詳細

### ステップ 1: terraform validate（`make sandbox-test-phase2`）

**何が起きるか**

`backend/tests/sandboxes/phase2` にテストがある場合は moto pytest を実行し、その後 `terraform validate` を走らせる。
実 AWS には一切アクセスしない。プラグインキャッシュを活かして軽量。

**実行コマンド**

```bash
make sandbox-test-phase2
```

**期待される出力例**

```
==> phase2 に moto テストなし (validate のみ)
Initializing the backend...
Initializing provider plugins...

Terraform has been successfully initialized!

Success! The configuration is valid.
```

※ `backend/tests/sandboxes/phase2/` が存在する場合は pytest の出力が先に出る。

**所要時間**: 10〜30 秒（初回は provider ダウンロードで 1〜2 分）

---

### ステップ 2: terraform apply（`make sandbox-up-phase2`）

**何が起きるか**

以下のリソースを一括作成する。

| リソース名（Terraform） | 作成されるもの |
|---|---|
| `aws_kms_key.s3` | Phase2 S3 sandbox key（エイリアス: `alias/phase2-s3`） |
| `aws_s3_bucket.main` | メインバケット（名前: `sandbox-phase2-main-<account-id>`） |
| `aws_s3_bucket.logs` | アクセスログ用バケット（名前: `sandbox-phase2-logs-<account-id>`） |
| `aws_s3_bucket_metric.main_all` | CloudWatch リクエストメトリクス有効化（FilterId: AllRequests） |
| `aws_s3_bucket_lifecycle_configuration.main` | 30d→IA / 90d→GLACIER_IR / 365d→削除 |
| `aws_lambda_function.on_upload` | Python 3.12 関数（名前: `sandbox-phase2-on-upload`） |
| `aws_cloudwatch_log_group.lambda` | ロググループ `/aws/lambda/sandbox-phase2-on-upload`（保持 1 日） |
| `aws_cloudwatch_dashboard.phase2` | ダッシュボード `Phase2-S3` |

Lambda のソースコードは `backend/sandboxes/phase2/handler.py` を ZIP 化して deploy。

**実行コマンド**

```bash
make sandbox-up-phase2
```

**期待される出力例**

```
Initializing the backend...
...

Plan: 18 to add, 0 to change, 0 to destroy.

aws_kms_key.s3: Creating...
aws_s3_bucket.logs: Creating...
aws_s3_bucket.main: Creating...
aws_kms_alias.s3: Creating...
aws_s3_bucket_public_access_block.main: Creating...
...
aws_lambda_function.on_upload: Creating...
aws_cloudwatch_dashboard.phase2: Creating...

Apply complete! Resources: 18 added, 0 changed, 0 destroyed.

Outputs:

aws_region           = "ap-northeast-1"
dashboard_name       = "Phase2-S3"
kms_key_arn          = "arn:aws:kms:ap-northeast-1:123456789012:key/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
lambda_function_name = "sandbox-phase2-on-upload"
logs_bucket_name     = "sandbox-phase2-logs-123456789012"
main_bucket_name     = "sandbox-phase2-main-123456789012"
```

**所要時間**: 2〜4 分（KMS キー作成に時間がかかることがある）

---

### ステップ 3: テストデータ投入（`make sandbox-load-phase2`）

**何が起きるか**

`load.sh` が次の 6 フェーズを順に実行する。

1. 小オブジェクト 30 個の PutObject（`load-<timestamp>/small-1.txt` ～ `small-30.txt`）
2. 12 MB マルチパートオブジェクト 1 個の PutObject（`large-12mb.bin`、AWS CLI が 8 MB 超で自動マルチパート）
3. `small-1.txt` ～ `small-10.txt` の GetObject 10 回
4. バージョン確認（`list-object-versions` でバージョニングが有効か検証）
5. 存在しないキー `nonexistent.txt` への GetObject（404 確認）
6. `small-1.txt` のプリサインド URL を生成し `curl` で HTTP ステータスを確認

各 PutObject は ObjectCreated イベントを発火させ、Lambda `sandbox-phase2-on-upload` が呼ばれる。

**実行コマンド**

```bash
make sandbox-load-phase2
```

**期待される出力例**

```
=== Phase2 load start: bucket=sandbox-phase2-main-123456789012 ===
[+] 30 small objects uploaded
[+] 12 MB object uploaded (multipart)
[+] 10 GetObject done
[+] Versions in prefix: 31
[+] Expected 404 for nonexistent key
[+] Presigned URL HTTP status: 200

=== load.sh complete ===
S3 リクエストメトリクスは ~1min、Lambda は即時、BucketSizeBytes は翌日に反映。
```

`Versions in prefix: 31` は小オブジェクト 30 個 + 12 MB オブジェクト 1 個のバージョンが記録されたことを示す。
Presigned URL の HTTP status が `200` であればプリサインド URL（SigV4 署名）が正常動作している。

**所要時間**: 1〜2 分（12 MB オブジェクトのアップロードに依存）

---

### ステップ 4: CloudWatch 観測（`make sandbox-watch-phase2`）

**何が起きるか**

`watch.sh` が次の 5 項目を順に確認する。90 秒のウェイトを含む。

0. ダッシュボード `Phase2-S3` の存在確認
1. S3 `AllRequests` メトリクス（1 分粒度、過去 15 分間）
2. S3 `PutRequests` メトリクス（同上）
3. Lambda `Invocations` / `Errors` メトリクス（同上）
4. 直近の Lambda ログ最新 20 件
5. `BucketSizeBytes` メトリクス（日次粒度、過去 2 日間）
6. CloudWatch コンソールへのディープリンクを出力

**実行コマンド**

```bash
make sandbox-watch-phase2
```

**期待される出力例**

```
=== Phase2 CloudWatch 観測 ===
観測時刻: 2026-06-06T10:00:00Z
バケット: sandbox-phase2-main-123456789012 / Lambda: sandbox-phase2-on-upload

--- [0] Dashboard smoke check ---
Phase2-S3
[OK] Dashboard exists

--- [1] S3 AllRequests (1min 粒度) ---
NOTE: load.sh 実行直後は反映に最大 1-2 分かかります
(90 秒ウェイト中...)
-------------------------------------------------------------------------------------------
|                                   GetMetricStatistics                                   |
+------------------+----------+-----------------------------------------------------------+
|    Average       |  Maximum | Timestamp                                                 |
+------------------+----------+-----------------------------------------------------------+
|  42.0            |  42.0    | 2026-06-06T09:58:00+00:00                                 |
+------------------+----------+-----------------------------------------------------------+

--- [2] S3 PutRequests ---
...（同形式のテーブル、Sum が 31 前後）

--- [3] Lambda Invocations ---
...（Sum が 31 前後: 小 30 + large 1）

--- [3b] Lambda Errors ---
...（Sum が 0 であれば正常）

--- [4] Lambda 最新ログ (直近 20 件) ---
START RequestId: xxxxxxxx-...
{"bucket": "sandbox-phase2-main-123456789012", "key": "load-1717660800/small-30.txt", "size_bytes": 47}
END RequestId: xxxxxxxx-...
REPORT RequestId: xxxxxxxx-... Duration: 3.45 ms  Billed Duration: 4 ms  ...

--- [5] BucketSizeBytes (日次・遅延大) ---
NOTE: オブジェクト投入当日はまだ 0 のことが多い。翌日に確認を推奨。
...（当日は空テーブルまたは 0 のことが多い）

=== コンソール Deep Link ===
CloudWatch Dashboard :
  https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=Phase2-S3
S3 バケット :
  https://s3.console.aws.amazon.com/s3/buckets/sandbox-phase2-main-123456789012?region=ap-northeast-1&tab=metrics
Lambda ログ :
  https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#logsV2:log-groups/log-group/%2Faws%2Flambda%2Fsandbox-phase2-on-upload

==========================================================
観測が終わったら: make sandbox-down-phase2  を忘れずに！
==========================================================
```

**所要時間**: 3〜4 分（90 秒ウェイト込み）

---

### ステップ 5: リソース削除（`make sandbox-down-phase2`）

**何が起きるか**

`terraform destroy -auto-approve` で全リソースを削除。
メインバケット・ログバケットはともに `force_destroy = true` のためオブジェクトが入っていても削除できる。
KMS キーは削除ではなく「削除保留（pending deletion）」状態になり、7 日後に完全削除される。
この 7 日間は KMS の日割り料金（$1/月 = 約 $0.03/日）が継続する。

**実行コマンド**

```bash
make sandbox-down-phase2
```

**期待される出力例**

```
aws_s3_bucket_notification.main: Destroying...
aws_lambda_permission.s3_invoke: Destroying...
aws_cloudwatch_dashboard.phase2: Destroying...
aws_s3_bucket_lifecycle_configuration.main: Destroying...
aws_lambda_function.on_upload: Destroying...
...
aws_kms_key.s3: Destroying...
aws_kms_key.s3: Destruction complete after 0s (pending deletion in 7 days)

Destroy complete! Resources: 18 destroyed.
```

**所要時間**: 1〜3 分

---

## 観察ポイント（チェックリスト）

### ダッシュボード `Phase2-S3`

CloudWatch コンソール → ダッシュボード → `Phase2-S3` を開く。

- [ ] ウィジェット「S3 AllRequests (1min)」に値が出ている（load.sh 実行後 1〜2 分で反映）
- [ ] ウィジェット「S3 PutRequests (1min)」の Sum が 31 前後（小オブジェクト 30 + large 1）
- [ ] ウィジェット「Lambda Invocations & Errors」の Invocations が 31 前後、Errors が 0
- [ ] ウィジェット「BucketSizeBytes (日次・遅延あり)」は当日は 0 または空。翌日に数値が出る

### S3 コンソール

S3 → バケット `sandbox-phase2-main-<account-id>` → メトリクスタブ

- [ ] 「リクエストメトリクス」に `AllRequests` フィルター `AllRequests` が表示されている
- [ ] バケットプロパティ → 暗号化が「AWS KMS」、キーが `alias/phase2-s3` になっている
- [ ] バケットプロパティ → サーバーアクセスのログ記録が「有効」でログ先が `sandbox-phase2-logs-<account-id>` になっている
- [ ] バケットプロパティ → バージョニングが「有効」になっている
- [ ] 「パブリックアクセスをブロック」がすべて有効（4 項目とも ON）

### Lambda コンソール

Lambda → 関数 `sandbox-phase2-on-upload` → モニタリングタブ

- [ ] 「呼び出し回数」グラフに load.sh 実行時のスパイクが見える
- [ ] 「エラー数と成功率」がエラー 0%

### Lambda ログ（CloudWatch Logs）

CloudWatch → ロググループ `/aws/lambda/sandbox-phase2-on-upload`

- [ ] 各ログイベントが `{"bucket": "...", "key": "...", "size_bytes": ...}` の JSON 形式になっている
- [ ] 12 MB オブジェクトの `size_bytes` が `12582912`（= 12 × 1024 × 1024）前後

### プリサインド URL

load.sh の出力行 `[+] Presigned URL HTTP status: 200` を確認。

- [ ] HTTP ステータスが `200`（SigV4 署名が正しく機能している）
- [ ] `403` の場合は KMS キーポリシーまたはバケットポリシーを確認

---

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| S3 `AllRequests` / `PutRequests` が CloudWatch に出ない | `aws_s3_bucket_metric` が未作成、またはメトリクス反映待ち | `terraform state list` で `aws_s3_bucket_metric.main_all` があるか確認。load.sh 実行後 1〜2 分待つ |
| `BucketSizeBytes` が 0 または空 | 日次集計なので当日は出ない | 翌日（UTC）に再度 `make sandbox-watch-phase2` を実行して確認 |
| Lambda が呼ばれない（Invocations = 0） | S3 バケット通知または Lambda Permission が未設定 | `terraform state list` で `aws_s3_bucket_notification.main` と `aws_lambda_permission.s3_invoke` を確認。なければ `make sandbox-up-phase2` を再実行 |
| load.sh で `An error occurred (NoSuchBucket)` | `make sandbox-up-phase2` が未実行 | `terraform -chdir=terraform/sandboxes/phase2 output` でバケット名が出るか確認してから load を実行 |
| `[+] Expected 404 for nonexistent key` が出ずエラー終了 | `set -euo pipefail` と `2>/dev/null \|\| echo` の組み合わせ問題 | load.sh の該当行で `|| true` を追加（ただし通常は問題ない） |
| Presigned URL が `403` を返す | KMS バケットキー（`bucket_key_enabled`）が効いていない、または署名期限切れ | `--expires-in 60` なので 60 秒以内に curl を実行しているか確認。タイムゾーンずれにも注意 |
| `make sandbox-up-phase2` で `BucketAlreadyOwnedByYou` | 前回の destroy が途中で失敗しバケット名が残っている | AWS コンソールでバケットを手動削除してから再実行 |
| watch.sh の `describe-log-streams` で `ResourceNotFoundException` | load.sh を実行していないため Lambda がまだ一度も起動していない | `make sandbox-load-phase2` を先に実行してから `make sandbox-watch-phase2` を実行 |
| `alias/phase2-s3` がすでに存在するエラー | 前回の destroy 後にキーの削除保留が残っている | `aws kms list-aliases` で確認し、削除保留キーを `aws kms cancel-key-deletion` → `aws kms delete-alias` → 再 apply |

---

## コスト目安

| 項目 | 料金（概算） |
|---|---|
| S3 PUT リクエスト（31 回） | $0.000155（ほぼ無視できる） |
| S3 GET リクエスト（10 回） | $0.000004（ほぼ無視できる） |
| S3 ストレージ（12 MB 程度、数時間） | $0.001 未満 |
| S3 リクエストメトリクス（有効化） | $0.01 / 100 万リクエスト（無料枠内） |
| KMS カスタムキー（1 ヶ月） | $1.00/月（日割り = 約 $0.03/日）|
| KMS API コール（数十回） | $0.03 / 1 万回（無料枠内） |
| Lambda 実行（31 回、数 ms） | 無料枠内（月 100 万リクエスト・400,000 GB-s 以内） |
| CloudWatch ダッシュボード（1 個） | $3.00/月（日割り = 約 $0.10/日） |

**実質的なコスト**: KMS キーの削除保留 7 日間 ≒ $0.20、ダッシュボード 1 日 ≒ $0.10。
destroy 直後から数日は KMS キーの日割り料金のみ継続する。

---

## 後片付けの確認

`make sandbox-down-phase2` 実行後、以下を確認する。

- [ ] `terraform destroy` が `Destroy complete! Resources: 18 destroyed.` で終了している
- [ ] S3 バケット `sandbox-phase2-main-<account-id>` が AWS コンソールに存在しない
- [ ] S3 バケット `sandbox-phase2-logs-<account-id>` が AWS コンソールに存在しない
- [ ] Lambda 関数 `sandbox-phase2-on-upload` が存在しない
- [ ] CloudWatch ダッシュボード `Phase2-S3` が存在しない
- [ ] CloudWatch ロググループ `/aws/lambda/sandbox-phase2-on-upload` が存在しない（保持 1 日後に自動削除）
- [ ] KMS キー `alias/phase2-s3` が「削除保留中（Pending deletion）」状態である（7 日後に自動削除、この間は日割り課金が続く）
- [ ] タグ `Sandbox=phase2` のリソースが残っていないか Tag Editor で確認（AWS コンソール → Resource Groups & Tag Editor → ap-northeast-1 で検索）
