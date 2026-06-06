# Phase 6: Bedrock (Claude) Sandbox

Lambda 経由で Amazon Bedrock (Claude 3 Haiku) を呼び出し、CloudWatch でトークン使用量・レイテンシ・スロットリングを観測する sandbox。CMK 暗号化・最小権限 IAM・呼出ログの S3/CloudWatch 二重保存をコアに設計している。

詳しい手順は **[handson.md](../../../docs/learning/phase6/handson.md)** を参照。

---

## この sandbox が作るもの

| リソース | 名前 | 目的 |
|---|---|---|
| KMS CMK | `alias/phase6-bedrock` | S3・CloudWatch Logs・Lambda 環境変数を暗号化（7日削除猶予） |
| S3 バケット | `bedrock-sandbox-invocation-logs-<accountId>` | Bedrock 呼出ログ保存（Block Public Access 全オン・SSE-KMS・7日 Lifecycle） |
| IAM ロール (Lambda 用) | `bedrock-sandbox-invoker-lambda` | `bedrock:InvokeModel` をモデル ARN 単位で許可する最小権限ロール |
| IAM ロール (Bedrock ログ用) | `bedrock-sandbox-bedrock-logging` | Bedrock サービスが S3/CloudWatch にログを書くためのロール |
| Lambda 関数 | `bedrock-sandbox-invoker` | Bedrock InvokeModel をラップ。環境変数を CMK で暗号化済み |
| CloudWatch Log Group | `/aws/lambda/bedrock-sandbox-invoker` | Lambda ログ（保存 1 日・CMK 暗号化） |
| CloudWatch Log Group | `/aws/bedrock/invocations` | Bedrock 呼出ログ（保存 1 日・CMK 暗号化） |
| Bedrock 呼出ログ設定 | `aws_bedrock_model_invocation_logging_configuration` | テキスト呼出ログを S3 + CloudWatch Logs に送る（1 アカウント 1 リージョンに 1 つ） |
| CloudWatch Dashboard | `phase6-bedrock` | InvocationCount / InvocationLatency / Token カウント / Lambda Duration・Errors を 4 グラフ表示 |

---

## 前提: モデルアクセスの有効化（apply 前に必須）

```
AWS Console → Amazon Bedrock → Model access → Manage model access
→ "Claude 3 Haiku" にチェック → Request access
→ ステータスが "Access granted" になるまで待つ
```

**有効化前は InvokeModel が `403 AccessDeniedException` を返す。このとき CloudWatch の Bedrock メトリクスは一切出ない。**

---

## クイックコマンド一覧

```bash
# 1. 無料検証（moto pytest + terraform validate）
make sandbox-test-phase6

# 2. リソース作成（実課金開始）
make sandbox-up-phase6

# リージョン変更する場合
TF_VAR_aws_region=ap-northeast-1 make sandbox-up-phase6

# 3. 負荷生成（Lambda → Bedrock を 3 回呼び出す）
make sandbox-load-phase6

# 4. メトリクス観測（120 秒待機 → CloudWatch 取得）
make sandbox-watch-phase6

# 5. リソース破棄（必ず実行する）
make sandbox-down-phase6
```

---

## コスト・destroy の注意

| 項目 | 詳細 |
|---|---|
| **KMS CMK** | `terraform destroy` 後も **7日間は削除保留状態**で課金継続（月 $0.03 程度） |
| **Bedrock トークン** | load.sh 固定 3 回 + 短プロンプトで 1 円未満。意図せずループに組み込まないよう注意 |
| **S3** | `force_destroy = true` でオブジェクトごと削除。7日 Lifecycle でも自動削除されるが destroy を先に実行で即消去 |
| **呼出ログ設定** | `aws_bedrock_model_invocation_logging_configuration` は destroy で削除されるが、残った場合は他プロジェクトのログが流れ続ける |
| **cross-region inference profile** | `TF_VAR_model_id` に ARN を渡す場合、`watch.sh` の `MODEL_ID` 変数もプロファイル ARN に変えないと CloudWatch のメトリクスが取れない（ディメンション値が変わるため） |

---

## 参考

- **詳しいハンズオン手順**: [`docs/learning/phase6/handson.md`](../../../docs/learning/phase6/handson.md)
- **HTML 版**: [`docs/learning/phase6/handson.html`](../../../docs/learning/phase6/handson.html)
- [Amazon Bedrock モデルアクセス](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html)
- [Bedrock モデル呼び出しログ](https://docs.aws.amazon.com/bedrock/latest/userguide/model-invocation-logging.html)
- [AWS/Bedrock CloudWatch メトリクス一覧](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring-cw.html)
