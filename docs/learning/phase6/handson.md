# Phase 6 ハンズオン — Bedrock (Claude) sandbox

---

## 前提条件

### AWS 認証・権限

| チェック項目 | 確認方法 |
|---|---|
| AWS CLI が設定済み | `aws sts get-caller-identity` でアカウント ID が返ること |
| `bedrock:InvokeModel` を呼べる IAM ユーザー/ロール | Terraform apply にも `iam:*` / `lambda:*` / `kms:*` / `s3:*` / `cloudwatch:*` が必要 |
| デフォルトリージョンが Bedrock 提供リージョン | `us-east-1`（デフォルト）推奨。`AWS_REGION` 環境変数か `TF_VAR_aws_region` で変更可 |

### モデルアクセスの有効化（必須・apply 前に行う）

**これを忘れると InvokeModel が `403 AccessDeniedException` を返し、CloudWatch に Bedrock メトリクスが一切出ない。** ダッシュボードが空白でも「まだデプロイ前？」と誤解しやすいので、apply より前に必ず完了させる。

```
AWS Console → Amazon Bedrock → Model access → Manage model access
→ "Claude 3 Haiku" (anthropic.claude-3-haiku-20240307-v1:0) にチェック
→ "Request access" ボタン
→ ステータスが "Access granted" になるまで待つ（数分〜数十分）
```

### 課金の注意

- **KMS CMK**: apply すると月 $1（$0.03/月 + API コール）の課金が始まる。destroy 後も **7日間の削除猶予期間中は課金継続**。
- **Bedrock トークン**: load.sh の 3 回 × 短プロンプトで 1 円未満。ループや大量呼び出しをしなければ問題ない。
- **S3**: 7日 Lifecycle 設定済み。destroy で即消去される（`force_destroy = true`）。

---

## 全体の流れ

```
test → up → load → watch → down
```

| ステップ | コマンド | 内容 |
|---|---|---|
| test | `make sandbox-test-phase6` | moto pytest + terraform validate（無料・無起動） |
| up | `make sandbox-up-phase6` | terraform apply でリソース作成 |
| load | `make sandbox-load-phase6` | Lambda 経由で Bedrock を 3 回呼び出す |
| watch | `make sandbox-watch-phase6` | CloudWatch メトリクスを取得・表形式で表示 |
| down | `make sandbox-down-phase6` | terraform destroy で全リソース削除 |

---

## ステップ詳細

### 1. test — 無料検証

**何が起きるか**: moto を使った pytest（`backend/tests/sandboxes/phase6/` があれば）と `terraform validate` を実行する。実 AWS リソースは作成しない。

```bash
make sandbox-test-phase6
```

**期待される出力例:**

```
==> phase6 に moto テストなし (validate のみ)
==> terraform validate phase6
Success! The configuration is valid.
```

**所要時間**: 30 秒〜1 分（terraform init + validate）

---

### 2. up — リソース作成

**何が起きるか**: Terraform が以下のリソースを作成する。

| リソース | 名前 |
|---|---|
| KMS CMK | `alias/phase6-bedrock` |
| S3 バケット | `bedrock-sandbox-invocation-logs-<accountId>` |
| IAM ロール (Lambda 用) | `bedrock-sandbox-invoker-lambda` |
| IAM ロール (Bedrock ログ用) | `bedrock-sandbox-bedrock-logging` |
| Lambda 関数 | `bedrock-sandbox-invoker` |
| CloudWatch Log Group | `/aws/lambda/bedrock-sandbox-invoker` |
| CloudWatch Log Group | `/aws/bedrock/invocations` |
| Bedrock 呼出ログ設定 | テキスト呼出ログ → S3 + CloudWatch |
| CloudWatch Dashboard | `phase6-bedrock` |

```bash
make sandbox-up-phase6
```

リージョンを変える場合:

```bash
TF_VAR_aws_region=ap-northeast-1 make sandbox-up-phase6
```

**期待される出力例:**

```
Apply complete! Resources: 14 added, 0 changed, 0 destroyed.

Outputs:

bedrock_log_group_name = "/aws/bedrock/invocations"
cloudwatch_dashboard_url = "https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=phase6-bedrock"
kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
lambda_function_arn = "arn:aws:lambda:us-east-1:123456789012:function:bedrock-sandbox-invoker"
lambda_function_name = "bedrock-sandbox-invoker"
s3_invocation_logs_bucket = "bedrock-sandbox-invocation-logs-123456789012"
```

**所要時間**: 2〜4 分

---

### 3. load — 負荷生成

**何が起きるか**: `load.sh` が以下の順序で動く。

1. **モデルアクセス確認** (probe): `{"prompt":"ping"}` を Lambda に投げ、レスポンスに `AccessDeniedException` や `403` が含まれていれば即終了してエラーを案内する。
2. **3 回の Lambda 呼び出し**: 固定プロンプト 3 本を順番に投げ、各レスポンスを JSON 整形して表示する。
3. **エラーチェック**: `FunctionError` / `errorMessage` が含まれていれば終了コード 1 で停止。
4. 完了後、「メトリクスは 2〜5 分後に CloudWatch に出る」と案内する。

```bash
make sandbox-load-phase6
```

**期待される出力例:**

```
=== Phase6 Bedrock load.sh ===
[1/4] Checking model access...
  Model access OK
[2/4] Invoking Lambda -> Bedrock 3 times...
  Call 1: prompt='Say hello in one sentence.'
{
    "statusCode": 200,
    "body": "Hello! It's great to meet you.",
    "model_id": "anthropic.claude-3-haiku-20240307-v1:0",
    "input_tokens": 14,
    "output_tokens": 12
}

  Call 2: prompt='What is AWS Bedrock? Answer in 10 words.'
{
    "statusCode": 200,
    "body": "AWS Bedrock is a managed service for foundation AI models.",
    "model_id": "anthropic.claude-3-haiku-20240307-v1:0",
    "input_tokens": 18,
    "output_tokens": 11
}

  Call 3: prompt='Name one benefit of serverless. Answer in one sentence.'
{
    "statusCode": 200,
    "body": "Serverless eliminates infrastructure management, letting you focus on code.",
    "model_id": "anthropic.claude-3-haiku-20240307-v1:0",
    "input_tokens": 16,
    "output_tokens": 13
}

[3/4] Checking for errors...
[4/4] Done. Metrics appear in CloudWatch in approximately 2-5 minutes.
      Run watch.sh to observe metrics.

NOTE: Remember to run 'make sandbox-down-phase6' when finished.
      (S3/KMS charges continue until destroyed)
```

**所要時間**: 30 秒〜1 分（Bedrock の応答待ち含む）

---

### 4. watch — メトリクス観測

**何が起きるか**: `watch.sh` が以下の順序で動く。

0. **ダッシュボード存在確認**: `phase6-bedrock` ダッシュボードが取得できるか確認。
1. **120 秒待機**: Bedrock メトリクスの伝播には 2〜5 分かかる。待機後に過去 10 分間のデータを取得する。
2. **InvocationCount** を `AWS/Bedrock` ネームスペースから取得・表示。
3. **InputTokenCount / OutputTokenCount** を取得・表示。
4. **InvocationLatency** (平均 ms) を取得・表示。
5. **Lambda Errors / Duration / Invocations** を取得・表示。
   最後に CloudWatch コンソールへの Deep Link を出力する。

```bash
make sandbox-watch-phase6
```

**期待される出力例:**

```
=== Phase6 Bedrock watch.sh ===
[0/5] Checking dashboard existence...
  Dashboard 'phase6-bedrock' exists
[1/5] Waiting 120 seconds for Bedrock metrics to propagate...
      Bedrock metrics can take 2-5 minutes after invocation.
[2/5] Bedrock InvocationCount (last 10 min, period=60s)...
---------------------------------------------------------
|               GetMetricStatistics                     |
+-------------------------+-----------+------------------+
|           Time          |    Sum    |                  |
+-------------------------+-----------+------------------+
|  2026-06-06T10:23:00Z   |  3.0      |                  |
+-------------------------+-----------+------------------+
[3/5] Bedrock InputTokenCount / OutputTokenCount...
  InputTokenCount:
  ...（表形式）
  OutputTokenCount:
  ...（表形式）
[4/5] Bedrock InvocationLatency (avg ms)...
  ...（Avg 列に平均レイテンシ ms）
[5/5] Lambda Errors / Duration / Invocations...
  Lambda Errors:
  ...（エラー 0 が期待値）
  Lambda Duration:
  ...
  Lambda Invocations:
  ...

=== CloudWatch Console Deep Links ===
Dashboard:
  https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=phase6-bedrock
Bedrock metrics:
  https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#metricsV2:graph=~();namespace=AWS/Bedrock
Lambda logs:
  https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:log-groups/log-group/%2Faws%2Flambda%2Fbedrock-sandbox-invoker
Bedrock invocation logs:
  https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:log-groups/log-group/%2Faws%2Fbedrock%2Finvocations

WARNING: When you are done observing, run:
    make sandbox-down-phase6
    (S3/KMS charges continue until destroyed)
```

**所要時間**: 約 3〜4 分（2 分待機 + メトリクス取得）

---

### 5. down — リソース破棄

**何が起きるか**: `terraform destroy -auto-approve` が全リソースを削除する。KMS CMK は destroy 後も **7日間は削除保留状態**で少額の課金が続く（月 $0.03 程度）。

```bash
make sandbox-down-phase6
```

**期待される出力例:**

```
Destroy complete! Resources: 14 destroyed.
```

**所要時間**: 1〜3 分

---

## 観察ポイント（チェックリスト）

CloudWatch ダッシュボード `phase6-bedrock` を開き、以下を確認する。

### ダッシュボード 左上ウィジェット: Bedrock InvocationCount

- [ ] `AWS/Bedrock` ネームスペース / `InvocationCount` / `ModelId=anthropic.claude-3-haiku-20240307-v1:0` に Sum=3 のデータポイントが現れる
- [ ] load.sh 実行から 2〜5 分後にグラフが更新される（即時反映はされない）

### ダッシュボード 右上ウィジェット: Bedrock InvocationLatency (avg ms)

- [ ] 平均レイテンシが数百〜数千 ms の範囲に収まっている（Claude 3 Haiku は比較的高速）
- [ ] 3 回分のデータポイントが確認できる

### ダッシュボード 左下ウィジェット: InputTokenCount / OutputTokenCount

- [ ] `InputTokenCount` の Sum が概ね 45〜60 トークン程度（3 プロンプト合計）
- [ ] `OutputTokenCount` の Sum が概ね 30〜50 トークン程度

### ダッシュボード 右下ウィジェット: Lambda Invoker: Duration / Errors

- [ ] `Invocations` = 4（probe 1 回 + 本呼び出し 3 回）
- [ ] `Errors` = 0
- [ ] `Duration` が 1000〜5000 ms 程度（Bedrock 応答待ちを含む）

### CloudWatch Logs — Bedrock 呼出ログ

- [ ] `/aws/bedrock/invocations` ロググループにログストリームが作成されている
- [ ] ログイベントに `inputTokenCount` / `outputTokenCount` / `modelId` が含まれている

### S3 — 呼出ログ

- [ ] `bedrock-sandbox-invocation-logs-<accountId>` バケットに `AWSLogs/` プレフィックスでオブジェクトが書き込まれている（数分後）

---

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| `AccessDeniedException` / `403` が load.sh で出る | モデルアクセスが未有効化 | AWS Console → Bedrock → Model access → 対象モデルを "Access granted" にしてから再実行 |
| CloudWatch に Bedrock メトリクスが出ない | ① モデルアクセス未有効化 ② 呼び出し直後（伝播待ち） | ① 上記対処 ② load 後 2〜5 分待ってから watch を再実行 |
| `ModelId` ディメンションのメトリクスが出ない（cross-region inference profile を使った場合） | `MODEL_ID` 変数がプロファイル ARN になっていない | `watch.sh` の `MODEL_ID` 変数をプロファイル ARN に変更して実行。ARN 例: `arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-haiku-20240307-v1:0` |
| Lambda が `ResourceNotFoundException` | Lambda 関数が存在しない（apply 未実行 or 別リージョン） | `make sandbox-up-phase6` を実行、またはリージョンを揃える |
| `terraform destroy` が KMS エラーで失敗 | CloudWatch Logs が KMS キーを参照中 | ログ保存期間 1 日設定済みだが、即時解消が必要な場合は AWS コンソールからロググループを手動削除後に destroy |
| S3 バケット削除失敗 | オブジェクトが残っている（force_destroy あるが稀に競合） | `aws s3 rm s3://bedrock-sandbox-invocation-logs-<accountId> --recursive` してから destroy |

---

## コスト目安

| 項目 | 単価 | load.sh 3 回実行での見積もり |
|---|---|---|
| Bedrock InvokeModel (Claude 3 Haiku) | 入力 $0.00025/1K トークン、出力 $0.00125/1K トークン | 入力 ~60 トークン: $0.000015 / 出力 ~50 トークン: $0.0000625 → **計 1 円未満** |
| KMS CMK | $1/月（+ API コール $0.03/10K） | apply からの経過時間に比例。1 時間で $0.001 程度 |
| S3 ストレージ | $0.023/GB/月 | ログサイズは数 KB → 無視できる |
| Lambda | 無料枠 (1M リクエスト/月) 内 | 4 回呼び出し → $0 |
| CloudWatch | ダッシュボード $3/月、メトリクス数百件まで無料 | sandbox 期間中: $3/月以下 |

**destroy を忘れると KMS の課金が続くので注意する。**

---

## 後片付けの確認

`make sandbox-down-phase6` 実行後、以下を確認する。

- [ ] `Destroy complete! Resources: 14 destroyed.` が表示されている
- [ ] AWS Console → Lambda → `bedrock-sandbox-invoker` が存在しない
- [ ] AWS Console → S3 → `bedrock-sandbox-invocation-logs-<accountId>` が存在しない
- [ ] AWS Console → KMS → `alias/phase6-bedrock` がスケジュール削除状態（削除保留 7日）になっている（7日後に消える・課金は継続）
- [ ] AWS Console → CloudWatch → ダッシュボード一覧に `phase6-bedrock` が存在しない
- [ ] タグ `Sandbox=phase6` のリソースが残存しないこと（Resource Groups → Tag Editor で確認）
- [ ] 1 時間後に Cost Explorer → サービス別 → Bedrock / KMS / S3 の当日費用が期待値以下であること
