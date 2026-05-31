# ---------------------------------------------------------------------------
# Phase 10: SNS — fan-out with SQS queues and Lambda notifier
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# KMS key for SNS/SQS SSE
# ---------------------------------------------------------------------------

resource "aws_kms_key" "phase10" {
  description             = "phase10 SNS/SQS SSE key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RootFullAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "SNSEncrypt"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource  = "*"
      },
      {
        Sid       = "SQSEncrypt"
        Effect    = "Allow"
        Principal = { Service = "sqs.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource  = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "phase10" {
  name          = "alias/phase10-sns"
  target_key_id = aws_kms_key.phase10.key_id
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Publisher role (sns:Publish only)
resource "aws_iam_role" "publisher" {
  name               = "phase10-publisher"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

resource "aws_iam_role_policy" "publisher_sns" {
  role = aws_iam_role.publisher.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.orders.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource = aws_kms_key.phase10.arn
      }
    ]
  })
}

# Subscriber SQS role (used in topic policy principal)
resource "aws_iam_role" "subscriber_sqs" {
  name               = "phase10-subscriber-sqs"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

# Lambda notifier role
resource "aws_iam_role" "lambda_notifier" {
  name               = "phase10-lambda-notifier"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_notifier.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_kms" {
  role = aws_iam_role.lambda_notifier.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = aws_kms_key.phase10.arn
    }]
  })
}

# ---------------------------------------------------------------------------
# SNS topics
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "sns_topic_orders" {
  statement {
    sid     = "AllowPublisherRole"
    effect  = "Allow"
    actions = ["sns:Publish"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.publisher.arn]
    }
    resources = ["*"]
  }
  statement {
    sid     = "AllowSQSSubscribe"
    effect  = "Allow"
    actions = ["sns:Subscribe"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.subscriber_sqs.arn]
    }
    resources = ["*"]
  }
}

resource "aws_sns_topic" "orders" {
  name              = "phase10-orders"
  kms_master_key_id = aws_kms_key.phase10.arn
  policy            = data.aws_iam_policy_document.sns_topic_orders.json
}

resource "aws_sns_topic" "orders_fifo" {
  name                        = "phase10-orders.fifo"
  fifo_topic                  = true
  content_based_deduplication = true
  kms_master_key_id           = aws_kms_key.phase10.arn
}

# ---------------------------------------------------------------------------
# SQS queues
# ---------------------------------------------------------------------------

locals {
  queues = {
    fulfillment = { filter_attr = "order_type", filter_vals = ["standard", "express"] }
    analytics   = { filter_attr = "order_type", filter_vals = ["standard", "express", "wholesale"] }
    wholesale   = { filter_attr = "order_type", filter_vals = ["wholesale"] }
  }
}

# DLQ (delivery failure receiver)
resource "aws_sqs_queue" "dlq" {
  for_each                  = local.queues
  name                      = "phase10-${each.key}-dlq"
  kms_master_key_id         = aws_kms_key.phase10.arn
  message_retention_seconds = 1209600 # 14 days
}

# Main queues
resource "aws_sqs_queue" "main" {
  for_each                   = local.queues
  name                       = "phase10-${each.key}"
  kms_master_key_id          = aws_kms_key.phase10.arn
  visibility_timeout_seconds = 30
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 3
  })
}

# SQS queue policy: allow SNS to send messages
resource "aws_sqs_queue_policy" "allow_sns" {
  for_each  = local.queues
  queue_url = aws_sqs_queue.main[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSNSPublish"
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.main[each.key].arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.orders.arn }
      }
    }]
  })
}

# FIFO consumer queue
resource "aws_sqs_queue" "fifo_consumer" {
  name                        = "phase10-fifo-consumer.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  kms_master_key_id           = aws_kms_key.phase10.arn
}

resource "aws_sqs_queue_policy" "fifo_allow_sns" {
  queue_url = aws_sqs_queue.fifo_consumer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.fifo_consumer.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.orders_fifo.arn } }
    }]
  })
}

# ---------------------------------------------------------------------------
# SNS subscriptions
# ---------------------------------------------------------------------------

resource "aws_sns_topic_subscription" "fulfillment" {
  topic_arn = aws_sns_topic.orders.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.main["fulfillment"].arn

  filter_policy = jsonencode({
    order_type = ["standard", "express"]
  })

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq["fulfillment"].arn
  })
}

resource "aws_sns_topic_subscription" "analytics" {
  topic_arn = aws_sns_topic.orders.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.main["analytics"].arn
  # analytics receives all order types — no filter

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq["analytics"].arn
  })
}

resource "aws_sns_topic_subscription" "wholesale" {
  topic_arn = aws_sns_topic.orders.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.main["wholesale"].arn

  filter_policy = jsonencode({
    order_type = ["wholesale"]
  })

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq["wholesale"].arn
  })
}

resource "aws_sns_topic_subscription" "lambda_notifier" {
  topic_arn = aws_sns_topic.orders.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.notifier.arn

  filter_policy = jsonencode({
    order_type = ["express"]
  })

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq["fulfillment"].arn
  })
}

resource "aws_sns_topic_subscription" "fifo_to_sqs" {
  topic_arn = aws_sns_topic.orders_fifo.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.fifo_consumer.arn
}

# ---------------------------------------------------------------------------
# Lambda permission for SNS to invoke the notifier
# ---------------------------------------------------------------------------

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.orders.arn
}

# ---------------------------------------------------------------------------
# Lambda function
# ---------------------------------------------------------------------------

data "archive_file" "notifier" {
  type        = "zip"
  source_dir  = "${path.root}/../../../backend/sandboxes/phase10"
  output_path = "${path.module}/.terraform/handler.zip"
}

resource "aws_lambda_function" "notifier" {
  function_name    = "phase10-notifier"
  filename         = data.archive_file.notifier.output_path
  source_code_hash = data.archive_file.notifier.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.handler"
  role             = aws_iam_role.lambda_notifier.arn
  timeout          = 10

  environment {
    variables = {
      LOG_LEVEL = "INFO"
    }
  }

  kms_key_arn = aws_kms_key.phase10.arn
}

resource "aws_cloudwatch_log_group" "notifier" {
  name              = "/aws/lambda/${aws_lambda_function.notifier.function_name}"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.phase10.arn
}

# ---------------------------------------------------------------------------
# CloudWatch Dashboard
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "phase10" {
  dashboard_name = "phase10-sns"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "SNS Publish & Delivery"
          region = var.aws_region
          metrics = [
            ["AWS/SNS", "NumberOfMessagesPublished", "TopicName", "phase10-orders"],
            ["AWS/SNS", "NumberOfNotificationsDelivered", "TopicName", "phase10-orders"],
            ["AWS/SNS", "NumberOfNotificationsFailed", "TopicName", "phase10-orders"],
            ["AWS/SNS", "NumberOfNotificationsFilteredOut", "TopicName", "phase10-orders"],
          ]
          period = 60
          stat   = "Sum"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "SQS Queue Depth (per queue)"
          region = var.aws_region
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "phase10-fulfillment"],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "phase10-analytics"],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "phase10-wholesale"],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "phase10-fulfillment-dlq"],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "phase10-analytics-dlq"],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "phase10-wholesale-dlq"],
          ]
          period = 60
          stat   = "Maximum"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "Lambda Notifier: Invocations / Errors / Duration"
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", "phase10-notifier"],
            ["AWS/Lambda", "Errors", "FunctionName", "phase10-notifier"],
            ["AWS/Lambda", "Duration", "FunctionName", "phase10-notifier"],
          ]
          period = 60
          stat   = "Sum"
          view   = "timeSeries"
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# CloudWatch Alarms — DLQ not empty
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dlq_alert" {
  for_each            = local.queues
  alarm_name          = "phase10-${each.key}-dlq-not-empty"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = "phase10-${each.key}-dlq" }
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 1
  period              = 60
  statistic           = "Maximum"
  alarm_description   = "DLQ for ${each.key} has messages — investigate failures"
}
