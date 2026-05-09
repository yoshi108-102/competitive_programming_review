# Lambda 関数モジュール
# 3 つのハンドラ (save_user / sync_submissions / get_submissions) を共通の
# IAM ロールでデプロイする。
# → docs/learning/phase1/task9/01-terraform-lambda-module.md

# =====================================================================
# IAM Execution Role
# 1 つのロールで 3 ハンドラ共通使用 (DynamoDB の users + submissions に
# Read/Write 必要なので最小権限の単位がほぼ同じ)
# =====================================================================

resource "aws_iam_role" "lambda_exec" {
  name = "${var.project_name}-lambda-exec-${var.environment}"

  # Trust policy: Lambda サービスがこのロールを引き受けられる
  # → docs/learning/phase1/task9/01-terraform-lambda-module.md §A
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# CloudWatch Logs 出力に必要な基本権限
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# DynamoDB アクセス用 inline policy (最小権限)
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "dynamodb-access"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:Query",
        "dynamodb:BatchWriteItem",
      ]
      Resource = [
        var.users_table_arn,
        var.submissions_table_arn,
      ]
    }]
  })
}

# =====================================================================
# 共通の関数定義 (locals で配列化)
# =====================================================================

locals {
  functions = {
    save_user = {
      handler = "lambdas.save_user.handler.lambda_handler"
      timeout = 10
    }
    sync_submissions = {
      handler = "lambdas.sync_submissions.handler.lambda_handler"
      # AtCoder API 呼び出し + batch write があるので長めに
      timeout = 60
    }
    get_submissions = {
      handler = "lambdas.get_submissions.handler.lambda_handler"
      timeout = 10
    }
  }
}

# =====================================================================
# Lambda 関数本体
# =====================================================================

resource "aws_lambda_function" "fn" {
  for_each = local.functions

  function_name = "${var.project_name}-${replace(each.key, "_", "-")}-${var.environment}"
  role          = aws_iam_role.lambda_exec.arn
  runtime       = "python3.12"
  handler       = each.value.handler

  # source_code_hash で zip の中身が変わったら Terraform が再デプロイをトリガー
  # → docs/learning/phase1/task9/01-terraform-lambda-module.md §C
  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)

  timeout     = each.value.timeout
  memory_size = 256

  environment {
    variables = {
      USERS_TABLE       = var.users_table_name
      SUBMISSIONS_TABLE = var.submissions_table_name
    }
  }
}

# =====================================================================
# CloudWatch Log Group (保持期間制御のため事前作成)
# → docs/learning/phase1/task9/01-terraform-lambda-module.md §B
# =====================================================================

resource "aws_cloudwatch_log_group" "fn" {
  for_each = local.functions

  name              = "/aws/lambda/${aws_lambda_function.fn[each.key].function_name}"
  retention_in_days = var.log_retention_days
}

# =====================================================================
# API Gateway からの invoke 許可 (resource-based policy)
# → docs/learning/phase1/task9/01-terraform-lambda-module.md §D
# =====================================================================

resource "aws_lambda_permission" "api_gw" {
  for_each = local.functions

  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  # */* で全 stage / 全 method からの invoke を許可
  source_arn = "${var.api_gateway_execution_arn}/*/*"
}
