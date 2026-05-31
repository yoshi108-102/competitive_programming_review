# ============================================================
# Data sources
# ============================================================

data "aws_caller_identity" "me" {}

# ============================================================
# KMS keys
# ============================================================

resource "aws_kms_key" "eb" {
  description             = "phase7 EventBridge bus key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRoot"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.me.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowEventBridgeService"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "eb" {
  name          = "alias/${var.prefix}-eventbridge"
  target_key_id = aws_kms_key.eb.key_id
}

resource "aws_kms_key" "lambda_env" {
  description             = "phase7 Lambda env vars key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

# ============================================================
# Custom EventBridge bus
# ============================================================

resource "aws_cloudwatch_event_bus" "main" {
  name               = "${var.prefix}-bus"
  kms_key_identifier = aws_kms_key.eb.arn
}

resource "aws_cloudwatch_event_bus_policy" "main" {
  event_bus_name = aws_cloudwatch_event_bus.main.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountPutEvents"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.me.account_id}:root"
        }
        Action   = "events:PutEvents"
        Resource = aws_cloudwatch_event_bus.main.arn
      }
    ]
  })
}

# ============================================================
# Archive & Replay (30 days retention)
# ============================================================

resource "aws_cloudwatch_event_archive" "main" {
  name             = "${var.prefix}-archive"
  event_source_arn = aws_cloudwatch_event_bus.main.arn
  retention_days   = 30
}

# ============================================================
# DLQ for failed EventBridge target invocations
# ============================================================

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.prefix}-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = "alias/aws/sqs"
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.dlq.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_cloudwatch_event_rule.processor.arn
        }
      }
    }]
  })
}

# ============================================================
# Lambda handler zip
# ============================================================

data "archive_file" "processor" {
  type        = "zip"
  source_dir  = "${path.root}/../../../backend/sandboxes/phase7"
  output_path = "${path.module}/.terraform/handler.zip"
}

# ============================================================
# Lambda function
# ============================================================

resource "aws_lambda_function" "processor" {
  function_name    = "${var.prefix}-processor"
  filename         = data.archive_file.processor.output_path
  source_code_hash = data.archive_file.processor.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda_exec.arn
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      LOG_LEVEL = "INFO"
      BUS_NAME  = aws_cloudwatch_event_bus.main.name
    }
  }

  kms_key_arn = aws_kms_key.lambda_env.arn

  tracing_config {
    mode = "Active"
  }
}

resource "aws_cloudwatch_log_group" "processor" {
  name              = "/aws/lambda/${aws_lambda_function.processor.function_name}"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.lambda_env.arn
}

# ============================================================
# IAM — Lambda execution role
# ============================================================

resource "aws_iam_role" "lambda_exec" {
  name = "${var.prefix}-lambda-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_exec" {
  name = "inline"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.processor.arn}:*"
      },
      {
        Sid      = "XRay"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
      {
        Sid      = "KMSEnvDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.lambda_env.arn
      }
    ]
  })
}

# ============================================================
# IAM — EventBridge Scheduler role
# ============================================================

resource "aws_iam_role" "scheduler" {
  name = "${var.prefix}-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.me.account_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "invoke-lambda"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.processor.arn
    }]
  })
}

# ============================================================
# EventBridge rule — custom event → Lambda
# ============================================================

resource "aws_cloudwatch_event_rule" "processor" {
  name           = "${var.prefix}-processor-rule"
  event_bus_name = aws_cloudwatch_event_bus.main.name
  description    = "Route order.created events to Lambda processor"

  event_pattern = jsonencode({
    source      = ["com.example.orders"]
    detail-type = ["order.created"]
  })

  state = "ENABLED"
}

resource "aws_cloudwatch_event_target" "processor_lambda" {
  rule           = aws_cloudwatch_event_rule.processor.name
  event_bus_name = aws_cloudwatch_event_bus.main.name
  target_id      = "ProcessorLambda"
  arn            = aws_lambda_function.processor.arn

  dead_letter_config {
    arn = aws_sqs_queue.dlq.arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 60
    maximum_retry_attempts       = 2
  }
}

resource "aws_lambda_permission" "allow_eb_processor" {
  statement_id  = "AllowEventBridgeInvokeProcessor"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.processor.arn
}

# ============================================================
# EventBridge rule — rate(1 minute) heartbeat (default bus)
# IMPORTANT: destroy after use to avoid continuous billing
# ============================================================

resource "aws_cloudwatch_event_rule" "heartbeat" {
  name                = "${var.prefix}-heartbeat-rule"
  description         = "SANDBOX ONLY: 1-min heartbeat. DESTROY after use!"
  schedule_expression = "rate(1 minute)"
  state               = "ENABLED"
  # rate/cron schedule expressions are only supported on the default event bus
}

resource "aws_cloudwatch_event_target" "heartbeat_lambda" {
  rule      = aws_cloudwatch_event_rule.heartbeat.name
  target_id = "HeartbeatLambda"
  arn       = aws_lambda_function.processor.arn

  dead_letter_config {
    arn = aws_sqs_queue.dlq.arn
  }
}

resource "aws_lambda_permission" "allow_eb_heartbeat" {
  statement_id  = "AllowEventBridgeInvokeHeartbeat"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.heartbeat.arn
}

# ============================================================
# EventBridge Scheduler — one-shot demo (far future date)
# ============================================================

resource "aws_scheduler_schedule_group" "main" {
  name = "${var.prefix}-group"
}

resource "aws_scheduler_schedule" "one_shot" {
  name       = "${var.prefix}-one-shot"
  group_name = aws_scheduler_schedule_group.main.name

  flexible_time_window {
    mode = "OFF"
  }

  # Placeholder far-future date; update before applying
  schedule_expression          = "at(2099-01-01T00:00:00)"
  schedule_expression_timezone = "Asia/Tokyo"

  target {
    arn      = aws_lambda_function.processor.arn
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      source      = "scheduler.demo"
      detail-type = "ScheduledOneShot"
      detail      = { message = "fired from Scheduler" }
    })

    retry_policy {
      maximum_event_age_in_seconds = 300
      maximum_retry_attempts       = 2
    }

    dead_letter_config {
      arn = aws_sqs_queue.dlq.arn
    }
  }
}

# ============================================================
# CloudWatch dashboard
# ============================================================

resource "aws_cloudwatch_dashboard" "phase7" {
  dashboard_name = "${var.prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          title  = "Lambda Invocations & Errors"
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", "${var.prefix}-processor"],
            ["AWS/Lambda", "Errors", "FunctionName", "${var.prefix}-processor", { color = "#d62728" }],
            ["AWS/Lambda", "Duration", "FunctionName", "${var.prefix}-processor", { stat = "p95", yAxis = "right" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type = "metric"
        properties = {
          title  = "Custom: EventsProcessed (EMF)"
          region = var.aws_region
          metrics = [
            ["Phase7/EventBridge", "EventsProcessed", "Source", "com.example.orders"],
            ["Phase7/EventBridge", "EventsProcessed", "Source", "scheduler.demo", { stat = "Sum" }]
          ]
          period = 60
        }
      },
      {
        type = "metric"
        properties = {
          title  = "DLQ Messages"
          region = var.aws_region
          metrics = [
            ["AWS/SQS", "NumberOfMessagesSent", "QueueName", "${var.prefix}-dlq"],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "${var.prefix}-dlq", { color = "#ff7f0e" }]
          ]
          period = 60
        }
      },
      {
        type = "metric"
        properties = {
          title  = "EventBridge FailedInvocations"
          region = var.aws_region
          metrics = [
            ["AWS/Events", "FailedInvocations", "RuleName", "${var.prefix}-processor-rule"],
            ["AWS/Events", "ThrottledRules", "RuleName", "${var.prefix}-processor-rule"]
          ]
          period = 60
        }
      },
      {
        type = "log"
        properties = {
          title  = "Processor Lambda Logs"
          region = var.aws_region
          query  = "SOURCE '/aws/lambda/${var.prefix}-processor' | fields @timestamp, @message | sort @timestamp desc | limit 50"
          view   = "table"
        }
      }
    ]
  })
}

# ============================================================
# CloudWatch alarms
# ============================================================

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.prefix}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Lambda processor errors detected"

  dimensions = {
    FunctionName = aws_lambda_function.processor.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${var.prefix}-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Messages landed in DLQ — investigate!"

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }
}
