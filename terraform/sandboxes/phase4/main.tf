# ─── Data sources ────────────────────────────────────────────
data "aws_caller_identity" "current" {}

# ─── Archive files for Lambda ────────────────────────────────
data "archive_file" "producer" {
  type        = "zip"
  source_dir  = "${path.root}/../../../backend/sandboxes/phase4"
  output_path = "${path.module}/.terraform/producer.zip"
  excludes    = ["consumer.py"]
}

data "archive_file" "consumer" {
  type        = "zip"
  source_dir  = "${path.root}/../../../backend/sandboxes/phase4"
  output_path = "${path.module}/.terraform/consumer.zip"
  excludes    = ["producer.py"]
}

# ─── KMS key for CloudWatch Logs encryption ──────────────────
resource "aws_kms_key" "cw_logs" {
  description             = "phase4 CloudWatch Logs encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRoot"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCWLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
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

resource "aws_kms_alias" "cw_logs" {
  name          = "alias/phase4-cw-logs"
  target_key_id = aws_kms_key.cw_logs.key_id
}

# ─── CloudWatch Log Groups ────────────────────────────────────
resource "aws_cloudwatch_log_group" "producer_logs" {
  name              = "/aws/lambda/phase4-producer"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.cw_logs.arn
}

resource "aws_cloudwatch_log_group" "consumer_logs" {
  name              = "/aws/lambda/phase4-consumer"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.cw_logs.arn
}

resource "aws_cloudwatch_log_group" "lambda_insights" {
  name              = "/aws/lambda-insights"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.cw_logs.arn
}

# ─── IAM: lambda assume role policy ──────────────────────────
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ─── IAM: producer role ───────────────────────────────────────
resource "aws_iam_role" "lambda_producer" {
  name               = "phase4-lambda-producer"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "producer_policy" {
  role = aws_iam_role.lambda_producer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.events.arn
      },
      {
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "${aws_cloudwatch_log_group.producer_logs.arn}:*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "LambdaInsights"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.cw_logs.arn
      }
    ]
  })
}

# ─── IAM: consumer role ───────────────────────────────────────
resource "aws_iam_role" "lambda_consumer" {
  name               = "phase4-lambda-consumer"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "consumer_policy" {
  role = aws_iam_role.lambda_consumer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.events.arn
      },
      {
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "${aws_cloudwatch_log_group.consumer_logs.arn}:*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "LambdaInsights"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.cw_logs.arn
      }
    ]
  })
}

# ─── DynamoDB table ───────────────────────────────────────────
resource "aws_dynamodb_table" "events" {
  name         = "phase4-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }
}

# ─── Lambda: producer ────────────────────────────────────────
resource "aws_lambda_function" "producer" {
  function_name    = "phase4-producer"
  role             = aws_iam_role.lambda_producer.arn
  runtime          = "python3.12"
  handler          = "producer.handler"
  filename         = data.archive_file.producer.output_path
  source_code_hash = data.archive_file.producer.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.events.name
    }
  }

  layers = [
    "arn:aws:lambda:${var.aws_region}:580247275435:layer:LambdaInsightsExtension:38"
  ]

  depends_on = [aws_cloudwatch_log_group.producer_logs]
}

# ─── Lambda: consumer ────────────────────────────────────────
resource "aws_lambda_function" "consumer" {
  function_name    = "phase4-consumer"
  role             = aws_iam_role.lambda_consumer.arn
  runtime          = "python3.12"
  handler          = "consumer.handler"
  filename         = data.archive_file.consumer.output_path
  source_code_hash = data.archive_file.consumer.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.events.name
    }
  }

  layers = [
    "arn:aws:lambda:${var.aws_region}:580247275435:layer:LambdaInsightsExtension:38"
  ]

  depends_on = [aws_cloudwatch_log_group.consumer_logs]
}

# ─── CloudWatch Metric Filters ────────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "producer_errors" {
  name           = "phase4-producer-errors"
  log_group_name = aws_cloudwatch_log_group.producer_logs.name
  pattern        = "ERROR"

  metric_transformation {
    name          = "ProducerErrorCount"
    namespace     = "Phase4/Lambda"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "consumer_errors" {
  name           = "phase4-consumer-errors"
  log_group_name = aws_cloudwatch_log_group.consumer_logs.name
  pattern        = "ERROR"

  metric_transformation {
    name          = "ConsumerErrorCount"
    namespace     = "Phase4/Lambda"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "producer_items" {
  name           = "phase4-producer-items-written"
  log_group_name = aws_cloudwatch_log_group.producer_logs.name
  pattern        = "{ $.items_written > 0 }"

  metric_transformation {
    name          = "ItemsWritten"
    namespace     = "Phase4/Lambda"
    value         = "$.items_written"
    default_value = "0"
    unit          = "Count"
  }
}

# ─── SNS topic for alarm notifications ───────────────────────
resource "aws_sns_topic" "alerts" {
  name              = "phase4-alerts"
  kms_master_key_id = aws_kms_key.cw_logs.arn
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ─── CloudWatch Alarms ────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "producer_error_alarm" {
  alarm_name          = "phase4-producer-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ProducerErrorCount"
  namespace           = "Phase4/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "phase4 producer が ERROR ログを出力しました"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "producer_duration" {
  alarm_name          = "phase4-producer-duration-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 60
  extended_statistic  = "p99"
  threshold           = 5000
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.producer.function_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ─── Composite Alarm ─────────────────────────────────────────
resource "aws_cloudwatch_composite_alarm" "phase4_critical" {
  alarm_name = "phase4-critical"
  alarm_rule = "ALARM(\"${aws_cloudwatch_metric_alarm.producer_error_alarm.alarm_name}\") OR ALARM(\"${aws_cloudwatch_metric_alarm.producer_duration.alarm_name}\")"

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ─── CloudWatch Dashboard ─────────────────────────────────────
resource "aws_cloudwatch_dashboard" "phase4" {
  dashboard_name = "phase4-overview"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          title  = "Lambda Invocations & Errors"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", "phase4-producer"],
            ["AWS/Lambda", "Errors", "FunctionName", "phase4-producer"],
            ["AWS/Lambda", "Invocations", "FunctionName", "phase4-consumer"],
            ["AWS/Lambda", "Errors", "FunctionName", "phase4-consumer"],
          ]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "Lambda Duration p50/p99"
          period = 60
          metrics = [
            [{ expression = "SEARCH('{AWS/Lambda,FunctionName} MetricName=\"Duration\"', 'p50', 60)", id = "e1" }],
            [{ expression = "SEARCH('{AWS/Lambda,FunctionName} MetricName=\"Duration\"', 'p99', 60)", id = "e2" }],
          ]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "Custom: ItemsWritten & ErrorCount"
          period = 60
          stat   = "Sum"
          metrics = [
            ["Phase4/Lambda", "ItemsWritten"],
            ["Phase4/Lambda", "ProducerErrorCount"],
            ["Phase4/Lambda", "ConsumerErrorCount"],
          ]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "DynamoDB Consumed Capacity Units"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", "phase4-events"],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", "phase4-events"],
          ]
        }
      },
      {
        type = "alarm"
        properties = {
          title = "Active Alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.producer_error_alarm.arn,
            aws_cloudwatch_metric_alarm.producer_duration.arn,
            aws_cloudwatch_composite_alarm.phase4_critical.arn,
          ]
        }
      },
      {
        type = "log"
        properties = {
          title  = "Producer ERROR ログ"
          query  = "SOURCE '/aws/lambda/phase4-producer' | filter @message like /ERROR/ | fields @timestamp, @message | sort @timestamp desc | limit 20"
          region = var.aws_region
          view   = "table"
        }
      }
    ]
  })
}
