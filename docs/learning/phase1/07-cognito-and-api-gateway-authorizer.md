# 07. Cognito User Pool と API Gateway Authorizer

> 出典:
> - [Amazon Cognito User Pools - Developer Guide](https://docs.aws.amazon.com/cognito/latest/developerguide/cognito-user-identity-pools.html)
> - [API Gateway - Control access using Cognito User Pools](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html)
> - [Using tokens with user pools (id token vs access token)](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-tokens-with-identity-providers.html)
> - [aws_cognito_user_pool - Terraform](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cognito_user_pool)
>
> 閲覧日 2026-05-09

## 概要

このプロジェクトは Cognito を「認証の入口」として使う。フロー:

```
[ブラウザ] → Cognito Hosted UI / Amplify SDK でログイン → JWT 取得
   ↓ Authorization: Bearer <idToken>
[API Gateway] ← Cognito Authorizer が JWT を検証 → 通れば Lambda へ
   ↓
[Lambda] event.requestContext.authorizer.claims.sub から user_id 取得
```

ここで押さえる学習トピック:

- User Pool / User Pool Client の責務分離
- JWT の 3 種類 (id / access / refresh) と「**どれが API Gateway で検証されるか**」
- API Gateway Cognito Authorizer の動作
- Self-signup / admin-create の運用判断

## 1. User Pool と User Pool Client

Cognito の「アカウント管理」は 2 段構成:

| リソース | 役割 |
|---|---|
| **User Pool** | ユーザーアカウントの集合体 (DB 相当)。パスワードポリシー、属性スキーマ、メール設定を持つ |
| **User Pool Client** | アプリケーション側からの接続点。認証フロー (SRP / PASSWORD)、トークン有効期限、コールバック URL を持つ |

1 User Pool に複数 Client がぶら下がる構造（モバイル用 / Web 用 / 管理者用 で別 Client を作るパターン）。

このプロジェクトの設定 (`terraform/modules/cognito/main.tf`):

```hcl
resource "aws_cognito_user_pool" "main" {
  admin_create_user_config {
    allow_admin_create_user_only = true   # ← セルフサインアップ無効
  }
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  password_policy { ... }
}

resource "aws_cognito_user_pool_client" "main" {
  user_pool_id = aws_cognito_user_pool.main.id
  generate_secret = false                  # ← SPA 向け (Cookie 不可)
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",                 # ← Secure Remote Password
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}
```

設計上の選択:

- **`generate_secret = false`**: SPA (ブラウザ JS) ではクライアントシークレットを安全に保管できないため、必ず無効化。サーバサイドアプリなら有効化 (false にしない)
- **`ALLOW_USER_SRP_AUTH`**: パスワードを生で送らない安全な認証フロー。CLI 検証では追加で `ALLOW_USER_PASSWORD_AUTH` が要るが、本番では SRP のみが望ましい
- **`allow_admin_create_user_only = true`**: 自己登録を禁止して招待制に。MVP 的には管理者が `aws cognito-idp admin-create-user` でユーザーを作る運用

## 2. JWT トークン 3 種類の使い分け

Cognito ログイン成功時、Client は **3 種類の JWT** を返す:

| トークン | 内容 | 主な用途 |
|---|---|---|
| **ID Token** | ユーザー属性 (`sub`, `email`, ...) を含む | アプリが「誰がログインしているか」を知るため |
| **Access Token** | スコープ情報 (OAuth リソース API を叩く時) | 主に Cognito 自身の API (`/userInfo` 等) や OAuth で保護されたリソース |
| **Refresh Token** | アクセス/ID トークンの再発行用 | 期限切れ時の再取得 |

### API Gateway の Cognito Authorizer は **どちらを検証するか？**

公式の挙動: Cognito Authorizer は **送られたトークンが ID Token か Access Token かを判別して**両方とも検証可能。
ただし **`sub` クレーム以外のユーザー情報** (`email`, `cognito:groups` 等) は **ID Token にしか入っていない**。

このプロジェクトでは `event.requestContext.authorizer.claims.sub` 等を Lambda で使うので、**ID Token を送る**のが望ましい:

```typescript
// frontend/app/lib/api.ts
const session = await fetchAuthSession();
const token = session.tokens?.idToken?.toString();   // ← idToken を選択
```

> 補足: Access Token を送って動くケースもあるが、`email` クレームが取れないなど挙動差が出る。**ID Token に寄せる**のが明確で安全。

### トークン有効期限

このプロジェクトの設定:
- ID / Access Token: 1 時間
- Refresh Token: 30 日

短い ID/Access の理由: **盗まれた時の被害時間を最小化**。Refresh Token は HttpOnly Cookie 等に保管して長めに持つ運用が一般的だが、Amplify は localStorage に保管する (XSS で盗まれるリスクと引き換えにシンプル)。

## 3. API Gateway Cognito Authorizer

API Gateway 側で JWT を検証して、検証 OK なら Lambda にルーティングする仕組み:

```hcl
resource "aws_api_gateway_authorizer" "cognito" {
  name            = "cognito-authorizer"
  rest_api_id     = aws_api_gateway_rest_api.main.id
  type            = "COGNITO_USER_POOLS"
  provider_arns   = [var.cognito_user_pool_arn]
  identity_source = "method.request.header.Authorization"
}
```

各 Method で `authorization = "COGNITO_USER_POOLS"` + `authorizer_id = aws_api_gateway_authorizer.cognito.id` を指定すると、そのエンドポイントに **JWT 検証ゲート**が掛かる。

### 検証フロー

1. クライアントが `Authorization: Bearer eyJ...` でリクエスト
2. API Gateway が Authorizer を呼び出す
3. Authorizer は **Cognito の JWKS エンドポイント** から公開鍵を取得して JWT 署名を検証
4. `iss` (issuer) クレームが期待値 (`https://cognito-idp.<region>.amazonaws.com/<user_pool_id>`) と一致するか
5. `exp` (expiration) クレームが現在時刻より未来か
6. すべて OK なら、デコード済みクレームを `event.requestContext.authorizer.claims` に乗せて Lambda に渡す

検証失敗時:
- トークン署名不正 → **401 Unauthorized**
- トークン期限切れ → **401 Unauthorized**
- `Authorization` ヘッダ無し → **401 Unauthorized**

### Lambda 側からのクレーム参照

```python
def lambda_handler(event, context):
    user_id = event["requestContext"]["authorizer"]["claims"]["sub"]
    email   = event["requestContext"]["authorizer"]["claims"].get("email")
    # ...
```

`sub` は **Cognito 内部で一意な UUID 形式の ID**（例: `12345678-1234-1234-1234-123456789012`）。
DB の主キーとして使うのに適している（メールアドレスは変更可能だが sub は不変）。

## 4. ユーザー作成の運用 (admin-create-user)

`allow_admin_create_user_only = true` 設定下では、ユーザーを作るには AWS CLI / SDK 経由:

```bash
aws cognito-idp admin-create-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "test@example.com" \
  --temporary-password "TempPass123!" \
  --message-action SUPPRESS

aws cognito-idp admin-set-user-password \
  --user-pool-id "$USER_POOL_ID" \
  --username "test@example.com" \
  --password "RealPass123!" \
  --permanent
```

`SUPPRESS` で確認メールを止め、`admin-set-user-password --permanent` で初回ログイン時のパスワード変更を不要にする（テスト用途）。

本番運用では:
- Phase 1 では admin-create のみ
- 後続 Phase でセルフサインアップ + 管理者承認制 や招待コード制 等への切り替えを検討

## 重要ポイント

- Cognito は **User Pool (アカウント DB) + User Pool Client (アプリ接続点)** の 2 段
- SPA (ブラウザ JS) では `generate_secret = false` 必須（ブラウザに secret を置けない）
- **JWT は 3 種類 (id/access/refresh)**。API Gateway での認可には **ID Token** を送る (sub 含む全ユーザークレームが乗る)
- API Gateway Cognito Authorizer は JWKS 経由で署名検証 + `iss`/`exp` チェック → 失敗で 401
- Lambda 側は `event.requestContext.authorizer.claims.sub` で内部 user_id を取得
- `sub` は不変 UUID なので DB の主キーに使える（メールアドレスは可変なので不適）
- `allow_admin_create_user_only = true` で招待制運用、`admin-create-user` + `admin-set-user-password --permanent` でユーザー作成

## 関連

- 実装: [practice/frontend-api-client.md](practice/frontend-api-client.md) (Amplify v6 で fetchAuthSession から idToken 取得), [practice/terraform-apply-walkthrough.md](practice/terraform-apply-walkthrough.md) (admin-create-user の手順)
- 関連トピック: [02-lambda-proxy-integration-and-cors.md](02-lambda-proxy-integration-and-cors.md) (`Authorization: Bearer` × CORS preflight の関係), [06-api-gateway-rest-api-structure.md](06-api-gateway-rest-api-structure.md) (Authorizer の REST API への組み込み)
