# 01. Terraform apply 手順と動作確認

> 出典:
> - [Terraform CLI - apply](https://developer.hashicorp.com/terraform/cli/commands/apply)
> - [API Gateway - test invoke](https://docs.aws.amazon.com/apigateway/latest/developerguide/how-to-test-method.html)
>
> 閲覧日 2026-05-09

## 概要

Phase 1 をデプロイする手順。**実 AWS 環境への適用**となるため、課金が発生する。

## 手順

### Step 1+2: Lambda ZIP build → terraform plan

ルートの `Makefile` で 1 コマンド:

```bash
make plan
```

→ `make build` が前提として走り `backend/dist/lambda.zip` (~16MB) を生成、その後 `terraform plan -out=tfplan`。
ZIP のソースに変更がなければ build はスキップ (Make の依存解決による)。

主な作成リソース:
- IAM ロール (Lambda execution)
- Lambda 関数 × 3 (save_user / sync_submissions / get_submissions)
- CloudWatch Log Group × 3
- API Gateway リソース・メソッド・統合 × 4 endpoints + OPTIONS × 4
- API Gateway Deployment / Stage

予想されるリソース数: 概ね 30〜40 個。意図しないリソースが出ていないか確認。

### Step 3: terraform apply

```bash
make apply
```

`make plan` で生成済みの `tfplan` を適用。完了まで通常 1〜2 分。

### Step 4: 出力値の確認

```bash
terraform output
```

返ってくる値:
- `api_gateway_url` (例: `https://abc123.execute-api.ap-northeast-1.amazonaws.com/prod`)
- `cognito_user_pool_id`, `cognito_user_pool_client_id`
- `dynamodb_*_table_name`

これを `frontend/.env.local` に設定 (Task 18 で使用)。

### Step 5: 公開エンドポイント (`/health`) で疎通確認

認証不要で叩ける `/health`:

```bash
curl "$(terraform output -raw api_gateway_url)/health"
# → {"status":"ok"}
```

これが返れば API Gateway / デプロイは成功している。

### Step 6: 認証付きエンドポイントで疎通確認

Cognito でユーザーを admin 経由で作成（self-signup を無効化しているため、`Task 17 §A` 参照）:

```bash
USER_POOL_ID=$(terraform output -raw cognito_user_pool_id)
aws cognito-idp admin-create-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "test@example.com" \
  --temporary-password "TempPass123!" \
  --message-action SUPPRESS

# 永続パスワードに変更
aws cognito-idp admin-set-user-password \
  --user-pool-id "$USER_POOL_ID" \
  --username "test@example.com" \
  --password "RealPass123!" \
  --permanent
```

JWT トークンを取得:

```bash
CLIENT_ID=$(terraform output -raw cognito_user_pool_client_id)
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id "$CLIENT_ID" \
  --auth-parameters USERNAME=test@example.com,PASSWORD=RealPass123! \
  --query 'AuthenticationResult.IdToken' \
  --output text)
```

> 補足（公式 docs には記載なし）: `USER_PASSWORD_AUTH` は Cognito client の `explicit_auth_flows` で許可されている必要がある。
> 現状 `terraform/modules/cognito/main.tf` は `ALLOW_USER_SRP_AUTH` のみ許可しているので、CLI からの動作確認には一時的に `ALLOW_USER_PASSWORD_AUTH` を追加するか、Frontend 経由でログインする。

API を叩く:

```bash
API_URL=$(terraform output -raw api_gateway_url)

# AtCoder ユーザー名を登録
curl -X POST "$API_URL/users/me" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"atcoder_username": "chokudai"}'

# 提出を同期
curl -X POST "$API_URL/sync" -H "Authorization: Bearer $TOKEN"

# 一覧
curl "$API_URL/submissions" -H "Authorization: Bearer $TOKEN"
```

### Step 7: CloudWatch Logs で実行ログ確認

何か 5xx が返ったら CloudWatch Logs を見る:

```bash
aws logs tail /aws/lambda/atcoder-review-save-user-prod --follow
```

`/aws/lambda/<関数名>` のロググループに stdout / stderr が流れる。Python の `print()` も CloudWatch に届く。

### Step 8: クリーンアップ (検証後、課金停止)

```bash
make destroy
```

削除順は Terraform が依存解決する（Lambda → API GW → IAM ロール → DynamoDB の順で消える）。

## デバッグの当たりどころ

| 症状 | 当たり |
|---|---|
| `/health` が 502 | API Gateway デプロイ漏れ。`triggers` に該当リソース入ってるか |
| `/users/me` が 401 | JWT 期限切れ or `Authorization: Bearer` ヘッダ未送信 |
| `/users/me` が 403 (Forbidden) | Cognito Authorizer の `provider_arns` ミス、または ID Token ではなく Access Token を送ってる |
| Lambda が 5xx (Internal Server Error) | CloudWatch Logs を見る。`Malformed Lambda proxy response` なら body を str 化忘れ (Task 3 の伏線) |
| `/submissions` が空 | sync 未実行 or `last_sync_epoch` が現在時刻まで進んでて差分ゼロ |

## 重要ポイント

- **apply 前に必ず `build_lambda.sh`** で ZIP を生成
- `terraform plan` の出力で想定外リソースが無いか確認
- `terraform output` で得られる値を Frontend `.env.local` に設定
- `/health` で疎通 → JWT 取得 → `/users/me` で End-to-End 確認の順で
- 検証完了後は **`terraform destroy` で課金停止**を忘れない

## 関連

- 議論・Q&A: （`lesson` 中に発生したら `reference/` 配下にリンクが追加されます）
- 関連 Task: Task 16 (build script), Task 18 (Frontend 結合)

---

_Auto-generated at 2026-05-09 via /learning-flow:material（公式 docs 駆動）_
