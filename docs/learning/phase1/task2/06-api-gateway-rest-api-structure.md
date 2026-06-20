# 01. API Gateway REST API のリソース構造

> 出典:
> - [API Gateway REST API - Terraform](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_rest_api)
> - [API Gateway resource / method / integration - AWS Docs](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-control-access-to-api.html)
> - [Set up Lambda Proxy Integration - AWS Docs](https://docs.aws.amazon.com/apigateway/latest/developerguide/set-up-lambda-proxy-integrations.html)
>
> 閲覧日 2026-05-09

## 概要

API Gateway REST API の Terraform は **5 種類のリソース**を組み合わせる:

```
RestApi
  └── Resource (パス)
        └── Method (HTTP メソッド)
              └── Integration (Lambda 等への接続)
              └── MethodResponse / IntegrationResponse (レスポンス仕様)
              ↓
            Deployment ─→ Stage (公開)
```

1 エンドポイント (例: `POST /users/me`) を作るために最低 4〜6 リソース書くことになる。冗長だが、各リソースの責務が明確に分かれているのが特徴。

## 公式 docs に沿った解説

### A. Resource (パス階層)

URL 階層を作る。`parent_id` で親を指定して入れ子にする。

```hcl
resource "aws_api_gateway_resource" "users" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id  # /
  path_part   = "users"
}

resource "aws_api_gateway_resource" "users_me" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "me"
}
# → 結果: /users/me
```

**path parameter** は `{}` で囲む:

```hcl
resource "aws_api_gateway_resource" "submission_detail" {
  parent_id = aws_api_gateway_resource.submissions.id
  path_part = "{submission_id}"
}
# → /submissions/{submission_id}
```

これが Lambda 側の `event["pathParameters"]["submission_id"]` に入る。

### B. Method — HTTP 仕様

「このリソースで POST/GET 等を受け付けて、認可はこれで」を宣言:

```hcl
resource "aws_api_gateway_method" "save_user_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_me.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}
```

`authorization` のオプション:
- `"NONE"` — 認可なし（公開エンドポイント。/health 用途）
- `"COGNITO_USER_POOLS"` + `authorizer_id` — JWT 検証
- `"AWS_IAM"` — IAM 認証
- `"CUSTOM"` — カスタム Lambda Authorizer

### C. Integration — どこに渡すか

Method と Lambda の橋渡し:

```hcl
resource "aws_api_gateway_integration" "save_user_post" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_me.id
  http_method = aws_api_gateway_method.save_user_post.http_method

  integration_http_method = "POST"     # Lambda 呼び出しは常に POST
  type                    = "AWS_PROXY"
  uri                     = var.lambda_invoke_arns["save_user"]
}
```

`type = "AWS_PROXY"` が **Lambda Proxy Integration**。これを指定すると:

- API Gateway は event を整形して Lambda に渡す（`statusCode/headers/body` の戻り値構造に変換）
- Lambda 側は Task 3 教材で扱った形式の戻り値を返せばよい
- これがこのプロジェクトの全 Lambda の前提

### D. CORS Preflight (OPTIONS)

ブラウザは `Authorization` ヘッダ付きの POST/PUT/DELETE などで preflight (`OPTIONS`) を送る（教材 Task 3 / 01 §B 再掲）。
これに API Gateway 側で 200 を返さないと**本リクエストが届かない**。

OPTIONS 専用の **MOCK 統合**で対応するのが定石:

```hcl
resource "aws_api_gateway_method" "users_me_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_me.id
  http_method   = "OPTIONS"
  authorization = "NONE"  # preflight は認可不要
}

resource "aws_api_gateway_integration" "users_me_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_me.id
  http_method = aws_api_gateway_method.users_me_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

# 200 レスポンスに CORS ヘッダを乗せる (Method/Integration 両方の Response が必要)
resource "aws_api_gateway_method_response" "users_me_options_200" { ... }
resource "aws_api_gateway_integration_response" "users_me_options_200" { ... }
```

> 補足（公式 docs には記載なし）: Lambda 側でも `success()` / `error()` が CORS ヘッダを返している（Task 3 / 03）。**OPTIONS は API Gateway 側 (MOCK)**, **本リクエストの応答ヘッダは Lambda 側**、と二系統で CORS ヘッダを揃える運用になる。MOCK 側で漏れると preflight 失敗 → 本リクエスト来ない。Lambda 側で漏れるとブラウザが応答を読めない。

### E. Deployment + Stage

API Gateway は **Resource/Method を編集しただけでは公開されない**。Deployment と Stage を作る必要がある:

```hcl
resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  # 編集を検知して再デプロイをトリガー
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.users_me.id,
      aws_api_gateway_method.save_user_post.id,
      aws_api_gateway_integration.save_user_post.id,
      # ... 関連リソースを全部含める
    ]))
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_api_gateway_stage" "main" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = var.environment
}
```

`triggers` の使い方が地味に重要。**ここに含めなかったリソースは編集しても再デプロイされない** → 「Terraform apply は成功したが古い API が動き続ける」謎現象が起きる。

### F. Lambda Permission との対応

API Gateway がここで Lambda を呼び出すためには、Lambda 側に **resource-based policy** が必要（Task 9 / `aws_lambda_permission`）。これがないと invoke 失敗で 5xx になる。

依存関係:
```
api_gateway モジュール  →  lambda モジュールの invoke_arn を参照
lambda モジュール       →  api_gateway モジュールの execution_arn を参照
```

**循環参照になりそうだが**、実際は `aws_api_gateway_rest_api` と `aws_lambda_function` は独立して作れる。execution_arn は REST API の作成時点で確定するので、lambda モジュールは api_gateway モジュールが「REST API だけ作った段階」で permission を作れる。Terraform の依存解決がうまく解いてくれる。

## 重要ポイント

- API Gateway の 1 エンドポイント = **Resource + Method + Integration + (Method/Integration)Response** の最低 4 リソース
- Path parameter は `path_part = "{name}"` で。Lambda 側の `event["pathParameters"]` に入る
- `type = "AWS_PROXY"` が Lambda Proxy Integration。event を Lambda に丸投げ
- **CORS preflight は OPTIONS + MOCK 統合**で 200 を返す。本リクエストの応答ヘッダは Lambda 側で
- Deployment の `triggers` に **編集対象リソースを全部入れる**。漏れると古いまま動く
- Lambda 側に `aws_lambda_permission` が必要 (Task 9)

## 関連

- 議論・Q&A: （`lesson` 中に発生したら `reference/` 配下にリンクが追加されます）
- 関連 Task: Task 9 (Lambda モジュール), Task 3 / 01 (CORS の再確認)

---

_Auto-generated at 2026-05-09 via /learning-flow:material（公式 docs 駆動）_
