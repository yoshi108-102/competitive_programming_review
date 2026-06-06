# Phase 5 ハンズオン — CloudFront + WAF sandbox

## 前提条件

### AWS 認証・権限

- `aws configure` または環境変数 (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) で認証済みであること
- 必要な権限: `cloudfront:*`, `wafv2:*`, `s3:*`, `cloudwatch:*`, `logs:*`, `iam:CreateServiceLinkedRole`（CloudFront 初回のみ必要）
- Terraform バックエンドへの S3/DynamoDB アクセス権限

### リージョン

**us-east-1 のみ**。これは AWS の制約による必然的な設計です。

- WAF の `scope = "CLOUDFRONT"` は us-east-1 にしか作成できない
- CloudFront のメトリクス (`AWS/CloudFront` 名前空間) は us-east-1 の CloudWatch にしか送られない

`aws configure` のデフォルトリージョンが `ap-northeast-1` になっていても問題ありません。Terraform と各スクリプトが `--region us-east-1` を明示しています。

### 課金開始の注意

`make sandbox-up-phase5` を実行した時点で課金が始まります。特に:

- CloudFront ディストリビューションは**作成に 10〜15 分**かかります
- 削除 (`make sandbox-down-phase5`) は**30〜45 分**かかります。途中で Ctrl-C しないでください
- WAF Web ACL は時間課金です。使わない時間帯はこまめに destroy してください

### Phase 固有の前提

- `terraform`, `aws` CLI, `curl`, `python3` がインストールされていること
- `jq` は省略可（watch.sh は `python3` でフォールバックします）
- sandbox ディレクトリ: `terraform/sandboxes/phase5/`

---

## 全体の流れ

| ステップ | コマンド | 内容 | 所要時間 |
|---|---|---|---|
| 1 | `make sandbox-test-phase5` | init + validate（課金なし） | 1〜2 分 |
| 2 | `make sandbox-up-phase5` | apply（課金開始） | 10〜15 分 |
| 3 | `make sandbox-load-phase5` | index.html アップ + 6 シナリオ実行 | 3〜5 分 |
| 4 | `make sandbox-watch-phase5` | CloudWatch メトリクス確認（3 分待機含む） | 5〜8 分 |
| 5 | `make sandbox-down-phase5` | destroy（CF 削除に 30〜45 分） | 30〜45 分 |

---

## ステップ詳細

### ステップ 1: `make sandbox-test-phase5` — 構文検証

**何が起きるか**: `terraform init` と `terraform validate` を実行します。課金は一切発生しません。provider プラグインのダウンロードとモジュール解決のみ行います。

```bash
make sandbox-test-phase5
```

**期待される出力例**:

```
Initializing the backend...
Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 5.0"...
- Finding hashicorp/random versions matching "~> 3.0"...
- Installed hashicorp/aws v5.x.x ...
- Installed hashicorp/random v3.x.x ...

Terraform has been successfully initialized!

Success! The configuration is valid.
```

**所要時間**: 1〜2 分（プラグインキャッシュがあれば 10 秒程度）

---

### ステップ 2: `make sandbox-up-phase5` — リソース作成

**何が起きるか**: `terraform apply -auto-approve` を実行し、以下のリソースを順番に作成します。

| リソース | 名前（suffix はランダム 8 文字） |
|---|---|
| S3 バケット（オリジン） | `atcoder-phase5-origin-<suffix>` |
| S3 バケット（CF ログ） | `atcoder-phase5-cf-logs-<suffix>` |
| CloudFront OAC | `phase5-oac-<suffix>` |
| WAF Web ACL | `phase5-waf` |
| CloudWatch Log Group（WAF ログ） | `aws-waf-logs-phase5` |
| WAF ログ設定 | — |
| CloudFront Distribution | `*.cloudfront.net` ドメイン自動割当 |
| CloudWatch Dashboard | `phase5-dashboard` |
| CloudWatch Alarm | `phase5-cf-5xx-error-rate` |

```bash
make sandbox-up-phase5
```

**期待される出力例**:

```
aws_s3_bucket.cf_logs: Creating...
aws_s3_bucket.origin: Creating...
aws_wafv2_web_acl.main: Creating...
aws_cloudwatch_log_group.waf: Creating...
...
aws_cloudfront_distribution.main: Creating...
aws_cloudfront_distribution.main: Still creating... [10s elapsed]
aws_cloudfront_distribution.main: Still creating... [1m0s elapsed]
...（10〜15 分）...
aws_cloudfront_distribution.main: Creation complete after 12m34s

Apply complete! Resources: 12 added, 0 changed, 0 destroyed.

Outputs:

cloudfront_distribution_id = "E1ABCDEF12345"
cloudfront_domain_name     = "d1234abcdef.cloudfront.net"
cf_logs_bucket_name        = "atcoder-phase5-cf-logs-a1b2c3d4"
dashboard_url              = "https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=phase5-dashboard"
origin_bucket_name         = "atcoder-phase5-origin-a1b2c3d4"
waf_web_acl_arn            = "arn:aws:wafv2:us-east-1:123456789012:global/webacl/phase5-waf/..."
waf_web_acl_name           = "phase5-waf"
```

**所要時間**: 10〜15 分（ほとんどが CloudFront ディストリビューションの作成待ち）

> apply 直後は CloudFront の DNS が浸透しておらず、curl で `NoSuchDistribution` が返ることがあります。5 分ほど待つと解消します。

---

### ステップ 3: `make sandbox-load-phase5` — リクエスト生成

**何が起きるか**: `load.sh` を実行し、6 つのシナリオでリクエストを生成します。

```bash
make sandbox-load-phase5
```

#### Step 0: index.html をオリジン S3 にアップロード

一時ファイルを生成して S3 に PUT します。これがないと CloudFront が 403 を返します。

**期待される出力例**:

```
INFO: CloudFront メトリクスの反映には 3〜5 分かかります。
Target: https://d1234abcdef.cloudfront.net

=== Step 0: index.html を S3 オリジンにアップロード ===
  uploaded: s3://atcoder-phase5-origin-a1b2c3d4/index.html
```

#### Step 1: 正常リクエスト 50 回（キャッシュ HIT/MISS 生成）

`Cache-Control: no-cache` ヘッダ付きで 50 回リクエストします。`CacheHitRate` メトリクスを観測するためのベースラインです。

**期待される出力例**:

```
=== Step 1: 正常リクエスト (200 系) — 50 回 ===
  [1] 200
  [2] 200
  [3] 200
  ...
  [50] 200
```

#### Step 2: 404 生成 10 回（4xxErrorRate を上昇させる）

存在しないパス (`/not-found-1.html` 〜 `/not-found-10.html`) にリクエストします。

**期待される出力例**:

```
=== Step 2: 404 生成 ===
  [1] 404
  [2] 404
  ...
  [10] 404
```

#### Step 3: WAF ブロック試験（SQLi パターン）

`AWSManagedRulesCommonRuleSet` の `SQLi_QUERYARGUMENTS` ルールが評価されます。WAF がブロックすると 403 が返ります。

**期待される出力例**:

```
=== Step 3: WAF Block 試験 (SQLi) ===
  SQLi: 403
```

> 403 はWAFがブロックした証拠です。200 が返った場合はルールが `count` モードになっています。

#### Step 4: レートリミット試験（120 並列リクエスト）

120 リクエストをバックグラウンド並列実行します。WAF の `RateLimit` ルール（5 分間に同一 IP から 1000 リクエスト超でブロック）をトリガーするための負荷です。CloudWatch の `BlockedRequests / RateLimit` ディメンジョンで確認できます。

**期待される出力例**:

```
=== Step 4: レートリミット試験 (120 並列) ===
  rate-limit burst done
```

#### Step 5: Bot UA 試験

`User-Agent: python-requests/2.28.0` でリクエストします。標準の `AWSManagedRulesCommonRuleSet` では通常 ALLOW されます（Bot Control は別途 extra-credit）。

**期待される出力例**:

```
=== Step 5: Bot UA 試験 ===
  BotUA: 200
```

#### Step 6: CloudFront Invalidation

キャッシュ全体を無効化します（`/*` — 1000 パス以内は無料）。

**期待される出力例**:

```
=== Step 6: CF Invalidation (/* — 1000 パス超は有料) ===
|  CreateInvalidation  |
|  ...                 |
```

ロード完了後の案内:

```
ロード完了。メトリクス反映まで 3〜5 分待つ。
watch.sh または以下で確認:
  aws cloudwatch get-metric-statistics --region us-east-1 \
    --namespace AWS/CloudFront --metric-name Requests \
    ...
```

**所要時間**: 3〜5 分（Step 4 の並列 curl 完了待ち + 各ステップの sleep 合計）

---

### ステップ 4: `make sandbox-watch-phase5` — メトリクス確認

**何が起きるか**: `watch.sh` を実行します。まず 3 分間のメトリクス反映待ち (`sleep 180`) を行ってから、CloudWatch の各メトリクスを取得・表示します。

```bash
make sandbox-watch-phase5
```

**Step 0: ダッシュボード存在確認**

```
=== ダッシュボード確認 ===
  OK: dashboard exists
```

**Step 1: 3 分待機**

```
=== メトリクス反映待ち (3 分) ===
（ここで 180 秒待ちます）
```

**Step 2: CF リクエスト数**

```
=== CF Requests (直近 1 時間) ===
------------------------------------------------------
|              GetMetricStatistics                   |
+------------+--------+--------+--------------------+
|  Average   |Maximum |Minimum |     Timestamp      |
+------------+--------+--------+--------------------+
|  180.0     |180.0   |180.0   | 2026-06-06T10:00:00Z |
+------------+--------+--------+--------------------+
```

**Step 3: エラー率（4xx / 5xx / Total）**

```
=== CF 4xx / 5xx / Total Error Rate ===
  --- 4xxErrorRate ---
  ...（テーブル形式）...
  --- 5xxErrorRate ---
  ...
  --- TotalErrorRate ---
  ...
```

**Step 4: WAF ブロック数**

```
=== WAF BlockedRequests ===
------------------------------------------------------
|              GetMetricStatistics                   |
+----------+--------+--------+---------------------+
|  Sum     |Maximum |Minimum |      Timestamp      |
+----------+--------+--------+---------------------+
|  3.0     |3.0     |3.0     | 2026-06-06T10:00:00Z |
+----------+--------+--------+---------------------+
```

**Step 5: WAF サンプリングリクエスト（直近 3 分）**

```
=== WAF Sampled Requests (直近 3 分) ===
{"Action": "BLOCK", "URI": "/?id=1' OR '1'='1"}
```

**Step 6: コンソール Deep Link**

```
=== コンソール Deep Link (us-east-1 固定) ===
CloudFront メトリクス:
  https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#metricsV2:...
WAF ダッシュボード:
  https://us-east-1.console.aws.amazon.com/wafv2/homev2/web-acls?region=us-east-1
ダッシュボード:
  https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=phase5-dashboard
```

**所要時間**: 3 分（待機）+ 1〜2 分（メトリクス取得）= 5〜8 分

---

### ステップ 5: `make sandbox-down-phase5` — リソース削除

**何が起きるか**: `terraform destroy -auto-approve` を実行します。CloudFront ディストリビューションの削除が最も時間がかかります。

```bash
make sandbox-down-phase5
```

**期待される出力例**:

```
aws_cloudwatch_metric_alarm.cf_5xx: Destroying...
aws_cloudwatch_dashboard.phase5: Destroying...
aws_wafv2_web_acl_logging_configuration.main: Destroying...
aws_cloudfront_distribution.main: Destroying...
aws_cloudfront_distribution.main: Still destroying... [1m0s elapsed]
...（30〜45 分）...
aws_cloudfront_distribution.main: Destruction complete after 38m12s
aws_s3_bucket.cf_logs: Destroying...
aws_s3_bucket.origin: Destroying...

Destroy complete! Resources: 12 destroyed.
```

**所要時間**: 30〜45 分

> Ctrl-C で中断すると CloudFront が「無効化中」のまま残り、その後の再 destroy も失敗しやすくなります。コンソールで手動削除が必要になる場合があります。

---

## 観察ポイント（チェックリスト）

### CloudWatch ダッシュボード (`phase5-dashboard`)

URL: `https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=phase5-dashboard`

**ウィジェット 1: CF Requests & Error Rates**（左上 12 列 × 6 行）

- [ ] `Requests` (Sum) が load.sh 実行後に 170 以上になっている（50 + 10 + 120 = 180 リクエスト想定）
- [ ] `4xxErrorRate` (Average) が 5〜10% 台に上昇している（Step 2 の 404 × 10 が原因）
- [ ] `5xxErrorRate` (Average) が 0% に近い（オリジン S3 は安定しているため）
- [ ] `CacheHitRate` (Average) が値を持つ（50 リクエスト以上打った後でないと NaN になる場合あり）

**ウィジェット 2: WAF Allowed vs Blocked**（右上 12 列 × 6 行）

- [ ] `AllowedRequests / Rule=ALL` が正常リクエスト分（150 前後）計上されている
- [ ] `BlockedRequests / Rule=ALL` が 1 以上になっている（Step 3 の SQLi ブロック分）
- [ ] `BlockedRequests / Rule=RateLimit` が 0 または 1（バースト 120 は 1000/5min を下回るので必ずしもブロックされない）
- [ ] `BlockedRequests / Rule=AWSManagedRulesCommonRuleSet` が 1 以上（SQLi ブロック）

**ウィジェット 3: WAF Block ログ**（下段 24 列 × 6 行、Log Insights テーブル）

- [ ] `action = 'BLOCK'` の行が存在する
- [ ] `httpRequest.uri` が `/?id=1' OR '1'='1` 相当のエントリを確認できる
- [ ] `@timestamp` が load.sh 実行時刻と一致する

### CloudWatch メトリクス（コンソール）

- [ ] `AWS/CloudFront` 名前空間で `DistributionId` ディメンジョンにより自分のディストリビューションを絞り込める
- [ ] `AWS/WAFV2` 名前空間の `Region = CloudFront`（`us-east-1` でなく文字列 `CloudFront`）ディメンジョンで WAF メトリクスを確認できる

### CloudWatch Alarm

- [ ] `phase5-cf-5xx-error-rate` アラームが `OK` 状態（5xxErrorRate が 5% 未満）
- [ ] もし `ALARM` 状態なら何らかのオリジンエラーが発生している

### WAF コンソール

- [ ] `https://us-east-1.console.aws.amazon.com/wafv2/homev2/web-acls?region=us-east-1` で `phase5-waf` が表示される
- [ ] Web ACL 詳細 → Rules で `AWSManagedRulesCommonRuleSet`（priority 1）と `RateLimit`（priority 2）が確認できる
- [ ] Sampled requests で SQLi パターンが BLOCK されているサンプルを確認できる

---

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| `apply` が `InvalidClientTokenId` で失敗 | 認証情報が期限切れ（MFA/AssumeRole） | `aws sts get-caller-identity` で確認、再認証 |
| `apply` が `WAFInvalidParameterException: AWS WAF couldn't retrieve the resource...` で失敗 | WAF の `scope=CLOUDFRONT` をリージョンが非 us-east-1 で実行 | provider の `region = "us-east-1"` を確認 |
| `aws_wafv2_web_acl_logging_configuration` が `WAFLogDestinationPermissionIssueException` | CloudWatch Logs へのリソースポリシーが未設定 | 初回のみ AWS コンソールで WAF ログを一度有効化する（リソースポリシーが自動作成される）か、`aws logs put-resource-policy` を手動実行する |
| `load.sh` の curl が `curl: (6) Could not resolve host` | CloudFront が未反映（apply 直後） | 5〜10 分待って再実行 |
| `load.sh` の curl が全リクエスト `403` | index.html が S3 にアップロードされていない、または OAC の S3 バケットポリシーが不整合 | `aws s3 ls s3://<origin_bucket>` で確認、なければ Step 0 だけ手動で再実行 |
| `watch.sh` が `CloudFront メトリクスが返らない` | load.sh 実行直後すぎる（5 分未満）か、`--period 60` を指定した | CF メトリクスの最小粒度は 5 分。`--period 300` に変更してから再実行 |
| WAF メトリクスの `Dimension Region` が見つからない | `Region=us-east-1` ではなく `Region=CloudFront` を指定すべき | `--dimensions Name=Region,Value=CloudFront` に修正 |
| `destroy` が 45 分以上かかる | CloudFront の無効化・削除が長い | 正常動作。Ctrl-C しないこと |
| `destroy` 後にバケットが残る | `force_destroy = true` が機能しなかった（オブジェクトが存在する場合でも自動削除）| 通常は起きないが、残った場合は `aws s3 rb s3://<name> --force` |
| `CacheHitRate` が NaN または 0.0 | リクエスト数が少なすぎる | 50 リクエスト以上打った後 5 分待ってから確認 |
| `get-sampled-requests` がエラー | `--time-window` に ISO 8601 を渡している | watch.sh では `date` コマンドで Unix 秒に変換済み。手動実行時は `date +%s` を使う |

### WAF ログエラー: リソースポリシー問題の詳細

WAF から CloudWatch Logs へのログ配信は、対象ロググループに `delivery.logs.amazonaws.com` が書き込めるリソースポリシーが必要です。Terraform の `aws_wafv2_web_acl_logging_configuration` はこのポリシーを自動作成しません。

初回 apply 後に以下のエラーが出た場合:

```
WAFLogDestinationPermissionIssueException: AWS WAF couldn't perform the operation
because your resource doesn't have the necessary permissions for the log delivery service.
```

対処コマンド:

```bash
aws logs put-resource-policy \
  --region us-east-1 \
  --policy-name "AWSWAFLogsPolicy" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "delivery.logs.amazonaws.com"},
      "Action": ["logs:CreateLogStream","logs:PutLogEvents"],
      "Resource": "arn:aws:logs:us-east-1:*:log-group:aws-waf-logs-*:*"
    }]
  }'
```

その後 `terraform apply` を再実行してください。

---

## コスト目安

| 項目 | 単価 | sandbox 1 回あたりの目安 |
|---|---|---|
| CloudFront リクエスト | $0.0075 / 10,000 req（NA + EU） | $0.001 未満（〜200 リクエスト） |
| CloudFront データ転送 | $0.085 / GB（NA） | $0.001 未満（HTML 数KB のみ） |
| WAF Web ACL | $5 / 月 = 約 $0.007 / 時間 | 1 時間以内なら $0.01 未満 |
| WAF ルール | $1 / ルール / 月 = 約 $0.0014 / 時間 × 2 ルール | $0.003 未満 |
| CloudWatch Logs（WAF ログ） | $0.50 / GB（取り込み） | 無視できる量（KB オーダー） |
| CloudWatch Alarm | $0.10 / アラーム / 月 | $0.001 未満 |
| S3 バケット | リクエスト課金のみ | $0.001 未満 |
| **合計** | | **$0.02 未満（1 時間以内に destroy すれば）** |

WAF の月額費用が相対的に大きいため、destroy を忘れると 1 日放置で $0.17 程度かかります。

---

## 後片付けの確認

`make sandbox-down-phase5` 完了後に以下を確認してください。

### destroy 完了確認

- [ ] `Destroy complete! Resources: 12 destroyed.` の出力を確認した
- [ ] `terraform state list` の出力が空（またはコマンドがエラーなし）

### AWS コンソールでの残存確認

- [ ] CloudFront コンソール（us-east-1）で `d1234abcdef.cloudfront.net` のディストリビューションが存在しない
- [ ] WAF コンソール（us-east-1）で `phase5-waf` Web ACL が存在しない
- [ ] S3 コンソールで `atcoder-phase5-origin-*` と `atcoder-phase5-cf-logs-*` バケットが存在しない
- [ ] CloudWatch コンソール（us-east-1）で `phase5-dashboard` ダッシュボードが存在しない
- [ ] CloudWatch Logs（us-east-1）で `aws-waf-logs-phase5` ロググループが存在しない
- [ ] CloudWatch Alarms（us-east-1）で `phase5-cf-5xx-error-rate` が存在しない

### タグによる残存リソース確認

この sandbox のリソースにはタグ `Sandbox=phase5` が付与されています。

```bash
aws resourcegroupstaggingapi get-resources \
  --region us-east-1 \
  --tag-filters Key=Sandbox,Values=phase5 \
  --output table
```

出力が空であれば全リソースが削除されています。

### KMS 7 日保留（extra-credit 実施者のみ）

SSE-KMS に切り替えた場合、KMS キーの削除には最低 7 日間の待機期間があります。

- [ ] KMS コンソールで `phase5-*` キーが「削除保留中」になっていることを確認した（これは正常）
- [ ] 7 日後に自動削除されることを把握している
