# ── Data Sources ──────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

# ── KMS ───────────────────────────────────────────────────────────────────────
# S3 用カスタム KMS キー。SSE-KMS にすることで CloudTrail に復号ログが残り監査可能。
resource "aws_kms_key" "s3" {
  description             = "Phase2 S3 sandbox key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "s3" {
  name          = "alias/phase2-s3"
  target_key_id = aws_kms_key.s3.key_id
}

# ── アクセスログ用バケット ─────────────────────────────────────────────────────
# メインバケットのアクセスログを別バケットに書く。
# ログバケット自身への access_logging は循環するので設定しない。
resource "aws_s3_bucket" "logs" {
  bucket        = "${var.prefix}-phase2-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # ログバケットは SSE-S3 で十分
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 Access Logging の配信元に s3.amazonaws.com を信頼するポリシー
resource "aws_s3_bucket_policy" "logs" {
  bucket     = aws_s3_bucket.logs.id
  depends_on = [aws_s3_bucket_public_access_block.logs]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "S3LogDelivery"
      Effect    = "Allow"
      Principal = { Service = "logging.s3.amazonaws.com" }
      Action    = ["s3:PutObject"]
      Resource  = "${aws_s3_bucket.logs.arn}/access-logs/*"
      Condition = {
        ArnLike = { "aws:SourceArn" = aws_s3_bucket.main.arn }
      }
    }]
  })
}

# ── メインバケット ─────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "main" {
  bucket        = "${var.prefix}-phase2-main-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # caveat: BucketNotEmpty を回避するため必須
}

resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true # KMS API コール削減。大量オブジェクトで効く
  }
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket                  = aws_s3_bucket.main.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "main" {
  bucket        = aws_s3_bucket.main.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "access-logs/"
}

# リクエストメトリクス有効化 — これが無いと PutObject/GetObject が CloudWatch に出ない
resource "aws_s3_bucket_metric" "main_all" {
  bucket = aws_s3_bucket.main.id
  name   = "AllRequests"
  # filter を省略すると全オブジェクトが対象
}

# ライフサイクル: 30d → IA, 90d → Glacier IR, 1y → 完全削除
resource "aws_s3_bucket_lifecycle_configuration" "main" {
  bucket = aws_s3_bucket.main.id
  rule {
    id     = "tier-down"
    status = "Enabled"
    filter {} # empty filter = apply to all objects in bucket
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = 365
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ── Lambda (S3 ObjectCreated トリガー) ─────────────────────────────────────────
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../../../backend/sandboxes/phase2"
  output_path = "${path.module}/.terraform/handler.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.prefix}-phase2-on-upload"
  retention_in_days = 1 # destroy 後に課金ログが残らないよう最短に
}

resource "aws_iam_role" "lambda" {
  name = "${var.prefix}-phase2-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_logs" {
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      },
      {
        # Lambda が SSE-KMS オブジェクトを GetObject する場合はこれも必要
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.s3.arn
      }
    ]
  })
}

resource "aws_lambda_function" "on_upload" {
  function_name    = "${var.prefix}-phase2-on-upload"
  role             = aws_iam_role.lambda.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"

  environment {
    variables = {
      LOG_LEVEL = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

resource "aws_lambda_permission" "s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.on_upload.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.main.arn
  # source_account で意図しないバケットからの呼び出しを防ぐ
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_s3_bucket_notification" "main" {
  bucket = aws_s3_bucket.main.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.on_upload.arn
    events              = ["s3:ObjectCreated:*"]
  }
  depends_on = [aws_lambda_permission.s3_invoke]
}

# ── CloudWatch ダッシュボード ───────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "phase2" {
  dashboard_name = "Phase2-S3"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          title  = "S3 AllRequests (1min)"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/S3", "AllRequests",
              "BucketName", aws_s3_bucket.main.id,
            "FilterId", "AllRequests"]
          ]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "S3 PutRequests (1min)"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/S3", "PutRequests",
              "BucketName", aws_s3_bucket.main.id,
            "FilterId", "AllRequests"]
          ]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "Lambda Invocations & Errors"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations",
            "FunctionName", aws_lambda_function.on_upload.function_name],
            ["AWS/Lambda", "Errors",
              "FunctionName", aws_lambda_function.on_upload.function_name,
            { color = "#d62728" }]
          ]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "BucketSizeBytes (日次・遅延あり)"
          period = 86400
          stat   = "Average"
          metrics = [
            ["AWS/S3", "BucketSizeBytes",
              "BucketName", aws_s3_bucket.main.id,
            "StorageType", "StandardStorage"]
          ]
        }
      }
    ]
  })
}
