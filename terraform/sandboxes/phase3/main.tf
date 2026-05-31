# ── KMS カスタムキー (SSE-KMS) ──────────────────────────────────────────────
resource "aws_kms_key" "sqs" {
  description             = "CMK for SQS queues (phase3)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "sqs" {
  name          = "alias/${var.prefix}-sqs"
  target_key_id = aws_kms_key.sqs.key_id
}

# ── Dead Letter Queue ─────────────────────────────────────────────────────────
resource "aws_sqs_queue" "dlq" {
  name                       = "${var.prefix}-dlq"
  kms_master_key_id          = aws_kms_key.sqs.id
  message_retention_seconds  = 1209600 # 14日(最長)
  visibility_timeout_seconds = 30

  tags = {
    Role = "dlq"
  }
}

# ── メインキュー ─────────────────────────────────────────────────────────────
resource "aws_sqs_queue" "main" {
  name                       = "${var.prefix}-main"
  kms_master_key_id          = aws_kms_key.sqs.id
  visibility_timeout_seconds = 30     # Lambda タイムアウトの 6 倍が推奨
  message_retention_seconds  = 345600 # 4日

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Role = "main"
  }
}

# ── キューポリシー: producer/consumer ロールだけが操作できる ─────────────────
resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowProducerOnly"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.producer.arn }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.main.arn
      },
      {
        Sid       = "AllowConsumerOnly"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.consumer.arn }
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = aws_sqs_queue.main.arn
      }
    ]
  })
}
