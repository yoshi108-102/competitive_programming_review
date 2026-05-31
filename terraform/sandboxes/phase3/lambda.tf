# ── Lambda コード (archive_file でファイル個別 zip) ──────────────────────────
data "archive_file" "producer" {
  type        = "zip"
  output_path = "${path.module}/.terraform/producer.zip"

  source {
    content  = file("${path.root}/../../../backend/sandboxes/phase3/producer.py")
    filename = "handler.py"
  }
}

data "archive_file" "consumer" {
  type        = "zip"
  output_path = "${path.module}/.terraform/consumer.zip"

  source {
    content  = file("${path.root}/../../../backend/sandboxes/phase3/consumer.py")
    filename = "handler.py"
  }
}

# ── Producer Lambda ───────────────────────────────────────────────────────────
resource "aws_lambda_function" "producer" {
  function_name    = "${var.prefix}-producer"
  filename         = data.archive_file.producer.output_path
  source_code_hash = data.archive_file.producer.output_base64sha256
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  role             = aws_iam_role.producer.arn

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.main.id
    }
  }
}

# ── Consumer Lambda ───────────────────────────────────────────────────────────
resource "aws_lambda_function" "consumer" {
  function_name    = "${var.prefix}-consumer"
  filename         = data.archive_file.consumer.output_path
  source_code_hash = data.archive_file.consumer.output_base64sha256
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  role             = aws_iam_role.consumer.arn
}

# ── イベントソースマッピング (SQS → Consumer) ─────────────────────────────────
resource "aws_lambda_event_source_mapping" "sqs_to_consumer" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.consumer.arn
  batch_size                         = 5
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}
