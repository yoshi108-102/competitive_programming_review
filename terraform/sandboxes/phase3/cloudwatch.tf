# ── ロググループ明示定義 (retention 1日 = destroy で課金残り防止) ─────────────
resource "aws_cloudwatch_log_group" "producer" {
  name              = "/aws/lambda/${aws_lambda_function.producer.function_name}"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "consumer" {
  name              = "/aws/lambda/${aws_lambda_function.consumer.function_name}"
  retention_in_days = 1
}

# ── CloudWatch ダッシュボード ─────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "phase3" {
  dashboard_name = "${var.prefix}-sqs-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          title  = "SQS Main - Visible Messages (5min)"
          period = 300
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible",
            "QueueName", aws_sqs_queue.main.name]
          ]
          view   = "timeSeries"
          stat   = "Maximum"
          region = var.aws_region
        }
      },
      {
        type = "metric"
        properties = {
          title  = "SQS DLQ - Visible Messages (5min)"
          period = 300
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible",
            "QueueName", aws_sqs_queue.dlq.name]
          ]
          view   = "timeSeries"
          stat   = "Maximum"
          region = var.aws_region
        }
      },
      {
        type = "metric"
        properties = {
          title  = "Consumer Lambda - Invocations / Errors"
          period = 60
          metrics = [
            ["AWS/Lambda", "Invocations",
              "FunctionName", aws_lambda_function.consumer.function_name,
              { stat = "Sum" }
            ],
            ["AWS/Lambda", "Errors",
              "FunctionName", aws_lambda_function.consumer.function_name,
              { stat = "Sum", color = "#d62728" }
            ]
          ]
          view   = "timeSeries"
          region = var.aws_region
        }
      },
      {
        type = "metric"
        properties = {
          title  = "Consumer Lambda - Duration (p50/p99)"
          period = 60
          metrics = [
            ["AWS/Lambda", "Duration",
              "FunctionName", aws_lambda_function.consumer.function_name,
              { stat = "p50" }
            ],
            [".", ".", ".", ".",
              { stat = "p99", color = "#ff7f0e" }
            ]
          ]
          view   = "timeSeries"
          region = var.aws_region
        }
      },
      {
        type = "metric"
        properties = {
          title  = "SQS Main - Sent / Deleted / NotVisible (5min)"
          period = 300
          metrics = [
            ["AWS/SQS", "NumberOfMessagesSent",
              "QueueName", aws_sqs_queue.main.name, { stat = "Sum" }
            ],
            ["AWS/SQS", "NumberOfMessagesDeleted",
              "QueueName", aws_sqs_queue.main.name, { stat = "Sum" }
            ],
            ["AWS/SQS", "ApproximateNumberOfMessagesNotVisible",
              "QueueName", aws_sqs_queue.main.name, { stat = "Maximum" }
            ]
          ]
          view   = "timeSeries"
          region = var.aws_region
        }
      }
    ]
  })
}
