data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# KMS CMK — Bedrock invocation logs / Lambda env vars / S3 encryption
# ---------------------------------------------------------------------------
resource "aws_kms_key" "phase6" {
  description             = "Phase6 Bedrock sandbox CMK"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootAdmin"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action   = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "phase6" {
  name          = "alias/phase6-bedrock"
  target_key_id = aws_kms_key.phase6.id
}

# ---------------------------------------------------------------------------
# S3 — Bedrock invocation log storage
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "invocation_logs" {
  bucket        = "${var.project}-invocation-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "invocation_logs" {
  bucket                  = aws_s3_bucket.invocation_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "invocation_logs" {
  bucket = aws_s3_bucket.invocation_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.phase6.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "invocation_logs" {
  bucket = aws_s3_bucket.invocation_logs.id
  rule {
    id     = "expire7d"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
  }
}

resource "aws_s3_bucket_policy" "invocation_logs" {
  bucket     = aws_s3_bucket.invocation_logs.id
  depends_on = [aws_s3_bucket_public_access_block.invocation_logs]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "BedrockLogging"
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = ["s3:PutObject"]
      Resource  = "${aws_s3_bucket.invocation_logs.arn}/AWSLogs/*"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# IAM — Lambda invoker role (minimum privilege)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "invoker_lambda" {
  name = "${var.project}-invoker-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "invoker_lambda_inline" {
  role = aws_iam_role.invoker_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.model_id}"
        ]
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.invoker_lambda.arn}:*"
      },
      {
        Sid      = "KmsDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.phase6.arn
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# CloudWatch Log Groups
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "invoker_lambda" {
  name              = "/aws/lambda/${var.project}-invoker"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.phase6.arn
}

resource "aws_cloudwatch_log_group" "bedrock_invocation" {
  name              = "/aws/bedrock/invocations"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.phase6.arn
}

# ---------------------------------------------------------------------------
# Lambda — Bedrock invoker
# ---------------------------------------------------------------------------
data "archive_file" "invoker" {
  type        = "zip"
  source_dir  = "${path.root}/../../../backend/sandboxes/phase6"
  output_path = "${path.module}/.terraform/handler.zip"
}

resource "aws_lambda_function" "invoker" {
  function_name    = "${var.project}-invoker"
  filename         = data.archive_file.invoker.output_path
  source_code_hash = data.archive_file.invoker.output_base64sha256
  role             = aws_iam_role.invoker_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30

  environment {
    variables = {
      MODEL_ID = var.model_id
      REGION   = var.aws_region
    }
  }

  kms_key_arn = aws_kms_key.phase6.arn

  depends_on = [aws_cloudwatch_log_group.invoker_lambda]
}

# ---------------------------------------------------------------------------
# IAM — Bedrock logging role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "bedrock_logging" {
  name = "${var.project}-bedrock-logging"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "bedrock_logging_inline" {
  role = aws_iam_role.bedrock_logging.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups"
        ]
        Resource = "${aws_cloudwatch_log_group.bedrock_invocation.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.invocation_logs.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.phase6.arn
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Bedrock Model Invocation Logging
# NOTE: Only one per account/region is allowed
# ---------------------------------------------------------------------------
resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  logging_config {
    embedding_data_delivery_enabled = false
    image_data_delivery_enabled     = false
    text_data_delivery_enabled      = true

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.bedrock_invocation.name
      role_arn       = aws_iam_role.bedrock_logging.arn
    }
    s3_config {
      bucket_name = aws_s3_bucket.invocation_logs.id
      key_prefix  = "AWSLogs"
    }
  }
}

# ---------------------------------------------------------------------------
# CloudWatch Dashboard
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "phase6" {
  dashboard_name = "phase6-bedrock"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Bedrock InvocationCount"
          region  = var.aws_region
          metrics = [["AWS/Bedrock", "InvocationCount", "ModelId", var.model_id]]
          period  = 60
          stat    = "Sum"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Bedrock InvocationLatency (avg ms)"
          region  = var.aws_region
          metrics = [["AWS/Bedrock", "InvocationLatency", "ModelId", var.model_id]]
          period  = 60
          stat    = "Average"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Bedrock InputTokenCount / OutputTokenCount"
          region = var.aws_region
          metrics = [
            ["AWS/Bedrock", "InputTokenCount", "ModelId", var.model_id],
            ["AWS/Bedrock", "OutputTokenCount", "ModelId", var.model_id]
          ]
          period = 60
          stat   = "Sum"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Lambda Invoker: Duration / Errors"
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", "${var.project}-invoker"],
            ["AWS/Lambda", "Errors", "FunctionName", "${var.project}-invoker"],
            ["AWS/Lambda", "Invocations", "FunctionName", "${var.project}-invoker"]
          ]
          period = 60
          stat   = "Sum"
          view   = "timeSeries"
        }
      }
    ]
  })
}
