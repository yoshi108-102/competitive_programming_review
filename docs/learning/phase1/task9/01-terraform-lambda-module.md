# 01. Terraform Lambda モジュールのパターン

> 出典:
> - [Terraform aws_lambda_function](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function)（閲覧日 2026-05-09）
> - [AWS Lambda IAM execution role](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html)（閲覧日 2026-05-09）
> - [aws_lambda_permission - Terraform](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission)（閲覧日 2026-05-09）

## 概要

Lambda 関数を Terraform で作るには、最低 4 つのリソースが必要:

1. **IAM 実行ロール** (`aws_iam_role`) + **policy** — Lambda が他 AWS リソース（DynamoDB, CloudWatch Logs 等）を呼ぶための権限
2. **CloudWatch Log Group** (`aws_cloudwatch_log_group`) — `/aws/lambda/<関数名>` の保持期間設定
3. **`aws_lambda_function`** — 関数本体（ランタイム、ハンドラ、ZIP、環境変数）
4. **`aws_lambda_permission`** — API Gateway から呼ばれることを許可する resource-based policy

## 公式 docs に沿った解説

### A. IAM 実行ロール（Trust + Permission）

Lambda Execution Role は **2 段階**で構成する:

#### Trust Policy (assume_role_policy) — 「誰がこのロールを引き受けられるか」

```hcl
resource "aws_iam_role" "lambda_exec" {
  name = "..."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}
```

**`Principal.Service = "lambda.amazonaws.com"`** が「このロールは Lambda サービスから引き受けられる」という宣言。これがないと Lambda はそのロールを名乗れない。

#### Permission Policy — 「このロールが何を出来るか」

inline policy をロールに添付する形が最小:

```hcl
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "dynamodb-access"
  role = aws_iam_role.lambda_exec.id
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query"]
      Resource = [var.users_table_arn, var.submissions_table_arn]
    }]
  })
}
```

**最小権限原則**:
- Action は必要なものだけ（read 系なら `GetItem`, `Query` のみ。write は不要）
- Resource はテーブル ARN まで絞り、`"*"` を避ける
- GSI を使うなら `<table_arn>/index/*` も追加

#### CloudWatch Logs 用の追加ポリシー

Lambda はログを CloudWatch に書くために `logs:CreateLogStream` と `logs:PutLogEvents` が必要。
AWS マネージドポリシー `AWSLambdaBasicExecutionRole` を attach するか、自前で書く:

```hcl
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
```

これがないと Lambda は実行できる **がログが出ない**。デバッグ不能になるので必須。

### B. CloudWatch Log Group の事前作成

Lambda は初回実行時に `/aws/lambda/<関数名>` という Log Group を**自動作成**するが:

- **保持期間がデフォルト「無期限」** → 課金が永遠に蓄積する
- Terraform で**先に作って保持期間を指定**するのがベストプラクティス

```hcl
resource "aws_cloudwatch_log_group" "lambda_save_user" {
  name              = "/aws/lambda/${aws_lambda_function.save_user.function_name}"
  retention_in_days = 14
}
```

> 補足（公式 docs には記載なし）: `aws_lambda_function` 作成と log group 作成の順番に依存性がある（log group 名は関数名から決まる）。Terraform の依存解決で大体うまくいくが、稀に競合するので `depends_on` を入れる場合もある。

### C. `aws_lambda_function`

```hcl
resource "aws_lambda_function" "save_user" {
  function_name    = "${var.project_name}-save-user-${var.environment}"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "lambdas.save_user.handler.lambda_handler"
  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      USERS_TABLE = var.users_table_name
    }
  }
}
```

注目ポイント:

- **`handler`** は `<モジュールパス>.<関数名>` 形式。Python なら `<dotted_path>.<func>`。`lambdas.save_user.handler.lambda_handler` = `lambdas/save_user/handler.py` の `lambda_handler` を指す
- **`source_code_hash`**: `filename` の中身が変わったら Terraform が再デプロイをトリガーする魔法。これがないと **同名 zip を差し替えても Lambda が更新されない**事故が起きる
- **`environment.variables`** で `USERS_TABLE` 等を注入。Task 4 で `os.environ["USERS_TABLE"]` を読む設計にしたのと**ここで対**になる

### D. `aws_lambda_permission` — API Gateway からの招待

Lambda は **resource-based policy**で「誰が私を invoke してよいか」を制御する。API Gateway が Lambda を呼ぶには明示的な許可が必要:

```hcl
resource "aws_lambda_permission" "api_gw_save_user" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.save_user.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${var.api_gateway_execution_arn}/*/*"
}
```

`source_arn` のフォーマット: `<execution_arn>/<stage>/<method>/<path>`。`*/*` で全 stage / 全メソッドからの invoke を許可（最小化したいなら絞る）。

これがないと API Gateway が 5xx で「Lambda invoke 失敗」と返してくる。**地味だが必須**。

### E. ZIP artifact の扱い

このプロジェクトでは**外部スクリプト**（Task 16 で書く）で `backend/` を zip 化 → S3 / ローカルパスに置く。Terraform はその artifact を `filename` で参照するだけ。

```hcl
variable "lambda_zip_path" {
  description = "Lambda deployment package (zip) path"
  type        = string
  default     = "../backend/dist/lambda.zip"
}
```

> 補足（公式 docs には記載なし）: Terraform 側で `archive_file` data source を使って zip を作る方法もあるが、依存ライブラリ（boto3 / requests）の管理が複雑になるため、外部ビルドスクリプト方式を採用。

## 重要ポイント

- IAM 実行ロールは **Trust (誰が引き受けるか) + Permission (何が出来るか)** の 2 段
- `Principal.Service = "lambda.amazonaws.com"` で Lambda サービスを信頼する
- 権限は **最小限**: Action / Resource を絞る、`"*"` を避ける
- CloudWatch Log Group は **Terraform で事前作成して `retention_in_days`** を指定
- `source_code_hash = filebase64sha256(...)` で zip 差し替え時の自動再デプロイを担保
- `aws_lambda_permission` で API Gateway からの invoke を明示許可

## 関連

- 議論・Q&A: （`lesson` 中に発生したら `reference/` 配下にリンクが追加されます）
- 関連 Task: Task 10 (API Gateway 経由で Lambda を呼ぶ), Task 16 (zip artifact ビルドスクリプト)

---

_Auto-generated at 2026-05-09 via /learning-flow:material（公式 docs 駆動）_
