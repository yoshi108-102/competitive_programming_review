# ── Data Sources ────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

# ── Archive: shared source_dir for producer + consumer ────────────────────
data "archive_file" "handlers" {
  type        = "zip"
  source_dir  = "${path.root}/../../../backend/sandboxes/phase9"
  output_path = "${path.module}/.terraform/handler.zip"
}

# ── KMS: X-Ray暗号化 + CloudWatch Logs暗号化用 ──────────────────────────────
resource "aws_kms_key" "phase9" {
  description             = "phase9 X-Ray + CWLogs encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RootAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "XRayEncryption"
        Effect    = "Allow"
        Principal = { Service = "xray.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
        Resource  = "*"
      },
      {
        Sid       = "CloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })
}

resource "aws_kms_alias" "phase9" {
  name          = "alias/phase9-xray"
  target_key_id = aws_kms_key.phase9.key_id
}

# ── X-Ray 暗号化設定 ─────────────────────────────────────────────────────────
resource "aws_xray_encryption_config" "phase9" {
  type   = "KMS"
  key_id = aws_kms_key.phase9.arn
}

# ── X-Ray サンプリングルール ──────────────────────────────────────────────────
resource "aws_xray_sampling_rule" "phase9_high_priority" {
  rule_name      = "phase9-high-priority"
  priority       = 100
  version        = 1
  reservoir_size = 5
  fixed_rate     = 0.10
  url_path       = "/api/*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = "phase9-*"
  resource_arn   = "*"

  attributes = {
    Environment = "sandbox"
  }
}

resource "aws_xray_sampling_rule" "phase9_health" {
  rule_name      = "phase9-health-check"
  priority       = 50
  version        = 1
  reservoir_size = 0
  fixed_rate     = 0.01
  url_path       = "/health"
  host           = "*"
  http_method    = "GET"
  service_type   = "*"
  service_name   = "*"
  resource_arn   = "*"
}

# ── DynamoDB(X-Ray統合確認用) ────────────────────────────────────────────────
resource "aws_dynamodb_table" "phase9" {
  name         = "phase9-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.phase9.arn
  }
}

# ── SQS(非同期トレース伝播の実験用) ─────────────────────────────────────────
resource "aws_sqs_queue" "phase9_dlq" {
  name                      = "phase9-main-dlq"
  kms_master_key_id         = aws_kms_key.phase9.id
  message_retention_seconds = 86400
}

resource "aws_sqs_queue" "phase9" {
  name                       = "phase9-main"
  kms_master_key_id          = aws_kms_key.phase9.id
  visibility_timeout_seconds = 60

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.phase9_dlq.arn
    maxReceiveCount     = 3
  })
}

# ── IAM: Lambda Producer ──────────────────────────────────────────────────
resource "aws_iam_role" "lambda_producer" {
  name = "phase9-lambda-producer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_producer" {
  name = "phase9-producer-policy"
  role = aws_iam_role.lambda_producer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "XRayWrite"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets"
        ]
        Resource = "*"
      },
      {
        Sid    = "DynamoDBAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem"
        ]
        Resource = aws_dynamodb_table.phase9.arn
      },
      {
        Sid      = "SQSSend"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.phase9.arn
      },
      {
        Sid      = "KMSUse"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
        Resource = aws_kms_key.phase9.arn
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.producer.arn}:*"
      }
    ]
  })
}

# ── IAM: Lambda Consumer ──────────────────────────────────────────────────
resource "aws_iam_role" "lambda_consumer" {
  name = "phase9-lambda-consumer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_consumer" {
  name = "phase9-consumer-policy"
  role = aws_iam_role.lambda_consumer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "XRayWrite"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets"
        ]
        Resource = "*"
      },
      {
        Sid      = "DynamoDBAccess"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.phase9.arn
      },
      {
        Sid    = "SQSConsume"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.phase9.arn
      },
      {
        Sid      = "KMSUse"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
        Resource = aws_kms_key.phase9.arn
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.consumer.arn}:*"
      }
    ]
  })
}

# ── CloudWatch Log Groups ─────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "producer" {
  name              = "/aws/lambda/phase9-producer"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.phase9.arn
}

resource "aws_cloudwatch_log_group" "consumer" {
  name              = "/aws/lambda/phase9-consumer"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.phase9.arn
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/phase9"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.phase9.arn
}

# ── Lambda: Producer ──────────────────────────────────────────────────────
resource "aws_lambda_function" "producer" {
  function_name    = "phase9-producer"
  filename         = data.archive_file.handlers.output_path
  source_code_hash = data.archive_file.handlers.output_base64sha256
  role             = aws_iam_role.lambda_producer.arn
  handler          = "producer.handler"
  runtime          = "python3.12"
  timeout          = 15
  memory_size      = 256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.phase9.name
      QUEUE_URL  = aws_sqs_queue.phase9.url
    }
  }

  depends_on = [aws_cloudwatch_log_group.producer]
}

# ── Lambda: Consumer ──────────────────────────────────────────────────────
resource "aws_lambda_function" "consumer" {
  function_name    = "phase9-consumer"
  filename         = data.archive_file.handlers.output_path
  source_code_hash = data.archive_file.handlers.output_base64sha256
  role             = aws_iam_role.lambda_consumer.arn
  handler          = "consumer.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.phase9.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.consumer]
}

resource "aws_lambda_event_source_mapping" "phase9_sqs" {
  event_source_arn = aws_sqs_queue.phase9.arn
  function_name    = aws_lambda_function.consumer.arn
  batch_size       = 5
}

# ── API Gateway HTTP API ───────────────────────────────────────────────────
resource "aws_apigatewayv2_api" "phase9" {
  name          = "phase9-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["https://sandbox.example.com"]
    allow_methods = ["GET", "POST"]
    allow_headers = ["Content-Type", "X-Amzn-Trace-Id"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_stage" "phase9" {
  api_id      = aws_apigatewayv2_api.phase9.id
  name        = "v1"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 100
    throttling_rate_limit  = 50
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format          = jsonencode({ requestId = "$context.requestId", ip = "$context.identity.sourceIp", httpMethod = "$context.httpMethod", routeKey = "$context.routeKey", status = "$context.status", responseLength = "$context.responseLength" })
  }
}

resource "aws_apigatewayv2_integration" "producer" {
  api_id             = aws_apigatewayv2_api.phase9.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.producer.invoke_arn
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "post_item" {
  api_id    = aws_apigatewayv2_api.phase9.id
  route_key = "POST /items"
  target    = "integrations/${aws_apigatewayv2_integration.producer.id}"
}

resource "aws_lambda_permission" "apigw_producer" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.producer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.phase9.execution_arn}/*/*"
}

# ── CloudWatch Dashboard ──────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "phase9" {
  dashboard_name = "phase9-xray-sandbox"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          title  = "Lambda: Invocations"
          region = var.aws_region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", "phase9-producer"],
            ["AWS/Lambda", "Invocations", "FunctionName", "phase9-consumer"]
          ]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "Lambda: Duration (p99)"
          region = var.aws_region
          period = 60
          stat   = "p99"
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", "phase9-producer"],
            ["AWS/Lambda", "Duration", "FunctionName", "phase9-consumer"]
          ]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "Lambda: Errors & Throttles"
          region = var.aws_region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", "phase9-producer"],
            ["AWS/Lambda", "Throttles", "FunctionName", "phase9-producer"],
            ["AWS/Lambda", "Errors", "FunctionName", "phase9-consumer"],
            ["AWS/Lambda", "Throttles", "FunctionName", "phase9-consumer"]
          ]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "Lambda: ConcurrentExecutions"
          region = var.aws_region
          period = 60
          stat   = "Maximum"
          metrics = [
            ["AWS/Lambda", "ConcurrentExecutions", "FunctionName", "phase9-producer"],
            ["AWS/Lambda", "ConcurrentExecutions", "FunctionName", "phase9-consumer"]
          ]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "SQS: phase9-main キュー深度"
          region = var.aws_region
          period = 300
          stat   = "Maximum"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "phase9-main"],
            ["AWS/SQS", "NumberOfMessagesSent", "QueueName", "phase9-main"]
          ]
        }
      },
      {
        type = "text"
        properties = {
          markdown = "## X-Ray / ServiceLens\nトレース本体は CloudWatch ではなく **X-Ray コンソール**を参照してください。\n[Service Map を開く](https://console.aws.amazon.com/xray/home#/service-map)\n[Traces を開く](https://console.aws.amazon.com/xray/home#/traces)"
        }
      }
    ]
  })
}
