# Phase 6: Bedrock (Claude) Sandbox

Lambda 経由で Amazon Bedrock (Claude 3 Haiku) を呼び出し、CloudWatch でトークン使用量・レイテンシ・スロットリングを観測する sandbox。
セキュリティ面では CMK 暗号化・最小権限 IAM・呼出ログの S3/CloudWatch 二重保存をコアに設計している。

---

## この sandbox が作るもの

| リソース | 目的 |
|---|---|
| Lambda `bedrock-sandbox-invoker` | Bedrock InvokeModel をラップ。環境変数を CMK で暗号化済み |
| IAM role `bedrock-sandbox-invoker-lambda` | `bedrock:InvokeModel` をモデル ARN 単位で許可する最小権限ロール |
| KMS CMK `alias/phase6-bedrock` | S3・CloudWatch Logs・Lambda 環境変数を暗号化する CMK (7日削除猶予) |
| S3 `bedrock-sandbox-invocation-logs-<accountId>` | Bedrock 呼出ログ保存先 (Block Public Access 全オン・SSE-KMS・7日 Lifecycle) |
| IAM role `bedrock-sandbox-bedrock-logging` | Bedrock サービスが S3/CloudWatch にログを書くためのロール |
| `aws_bedrock_model_invocation_logging_configuration` | テキスト呼出ログを S3 + CloudWatch Logs に送る設定 (1 アカウント 1 リージョン 1 つ) |
| CloudWatch Log Groups `/aws/lambda/...` `/aws/bedrock/invocations` | Lambda・Bedrock ともに保存期間 1 日・CMK 暗号化 |
| CloudWatch Dashboard `phase6-bedrock` | InvocationCount / InvocationLatency / Token カウント / Lambda Duration・Errors を 4 グラフ表示 |

---

## 前提: モデルアクセスの有効化

**terraform apply より前に必ずコンソールで有効化する。**

```
AWS Console -> Amazon Bedrock -> Model access -> Manage model access
-> "Claude 3 Haiku" にチェック -> Request access
-> ステータスが "Access granted" になるまで待つ
```

有効化前は InvokeModel が `403 AccessDeniedException` を返す。
このとき **CloudWatch の Bedrock メトリクスは一切出ない**ため「まだデプロイ前？」と誤解しやすい。

---

## 使い方

### 1. 環境立ち上げ

```bash
make sandbox-up-phase6
```

デフォルトリージョンは `us-east-1`。変更する場合:

```bash
TF_VAR_aws_region=ap-northeast-1 make sandbox-up-phase6
```

モデルを Sonnet に変える場合 (コスト注意: Haiku 比 5 倍程度):

```bash
TF_VAR_model_id=anthropic.claude-3-5-sonnet-20241022-v2:0 make sandbox-up-phase6
```

### 2. ロード生成

```bash
make sandbox-load-phase6
# または直接:
bash terraform/sandboxes/phase6/load.sh
```

load.sh はモデルアクセスを先に 1 回テスト呼出で確認し、403 なら即終了する。
問題なければ短プロンプト 3 回分だけ Lambda を呼ぶ（課金は数セント以下）。

### 3. メトリクス観測

```bash
make sandbox-watch-phase6
# または:
bash terraform/sandboxes/phase6/watch.sh
```

watch.sh は 120 秒待機してから `get-metric-statistics` を実行し、
InvocationCount / InvocationLatency / Token カウント / Lambda Errors を表形式で表示する。
CloudWatch ダッシュボードの Deep Link も末尾に出力される。

### 4. 環境破棄

```bash
make sandbox-down-phase6
```

---

## コスト・Destroy の注意事項

| 項目 | 詳細 |
|---|---|
| **KMS CMK** | `terraform destroy` 後も **7日間は削除保留状態**で課金継続 ($0.03/月 程度) |
| **S3** | `force_destroy = true` でオブジェクトごと削除される。7日 Lifecycle でも自動削除されるが destroy を先に実行で即消去 |
| **Bedrock トークン課金** | load.sh 固定 3 回 + `max_tokens=64` で 1 回数セント以下。意図せずループに組み込まないよう注意 |
| **呼出ログ設定** | `aws_bedrock_model_invocation_logging_configuration` は destroy で削除されるが、残った場合は他プロジェクトのログが流れ続ける |
| **確認手順** | destroy 後 1 時間後に Cost Explorer の Bedrock・KMS・S3 を確認してゼロを確かめる |

### cross-region inference profile を使う場合の注意

`TF_VAR_model_id` に ARN (`arn:aws:bedrock:us-east-1::foundation-model/...`) を渡す場合、
IAM の Resource も ARN 形式にする必要がある。また watch.sh の `MODEL_ID` 変数も
プロファイル ARN に変えないと CloudWatch のメトリクスが取れない（ディメンション値が変わるため）。

---

## 参考リンク

- 設計書: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md` (行 5790〜6741)
- プレビュー教材: `docs/learning/phase6/preview-bedrock.md`
- [Amazon Bedrock モデルアクセス](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html)
- [Bedrock モデル呼び出しログ](https://docs.aws.amazon.com/bedrock/latest/userguide/model-invocation-logging.html)
- [AWS/Bedrock CloudWatch メトリクス一覧](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring-cw.html)
