# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# KMS — CMK shared by Step Functions, Lambda, CloudWatch Logs, DynamoDB, SNS
# ---------------------------------------------------------------------------

resource "aws_kms_key" "phase8" {
  description             = "Phase8 Step Functions sandbox CMK"
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
        Sid    = "StepFunctionsLogs"
        Effect = "Allow"
        Principal = {
          Service = [
            "logs.${var.aws_region}.amazonaws.com",
            "states.${var.aws_region}.amazonaws.com"
          ]
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "phase8" {
  name          = "alias/phase8-sfn"
  target_key_id = aws_kms_key.phase8.key_id
}

# ---------------------------------------------------------------------------
# DynamoDB — orders table
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "orders" {
  name         = "phase8-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.phase8.arn
  }

  point_in_time_recovery {
    enabled = false
  }

  tags = { Name = "phase8-orders" }
}

# ---------------------------------------------------------------------------
# SNS — order notification topic + email subscription
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "order_notify" {
  name              = "phase8-order-notify"
  kms_master_key_id = aws_kms_key.phase8.arn
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.order_notify.arn
  protocol  = "email"
  endpoint  = var.notify_email
}

# ---------------------------------------------------------------------------
# IAM — Lambda execution role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "lambda_exec" {
  name = "phase8-lambda-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_exec" {
  name = "phase8-lambda-exec-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBOrders"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.orders.arn
      },
      {
        Sid      = "SNSNotify"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.order_notify.arn
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource = aws_kms_key.phase8.arn
      },
      {
        Sid    = "XRay"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_exec" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_exec.arn
}

# ---------------------------------------------------------------------------
# IAM — Step Functions execution role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "sfn_execution" {
  name = "phase8-sfn-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        ArnLike = {
          "aws:SourceArn" = "arn:aws:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:*"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "sfn_execution" {
  name = "phase8-sfn-execution-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeLambdas"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          aws_lambda_function.validate_order.arn,
          aws_lambda_function.charge_payment.arn,
          aws_lambda_function.update_inventory.arn,
          aws_lambda_function.notify_customer.arn,
          aws_lambda_function.compensate_order.arn,
          "${aws_lambda_function.validate_order.arn}:*",
          "${aws_lambda_function.charge_payment.arn}:*",
          "${aws_lambda_function.update_inventory.arn}:*",
          "${aws_lambda_function.notify_customer.arn}:*",
          "${aws_lambda_function.compensate_order.arn}:*",
        ]
      },
      {
        Sid    = "XRayTracing"
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
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      },
      {
        Sid    = "KMSForLogs"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.phase8.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "sfn_execution" {
  role       = aws_iam_role.sfn_execution.name
  policy_arn = aws_iam_policy.sfn_execution.arn
}

# ---------------------------------------------------------------------------
# Lambda — zip archive (single source_dir containing handler.py)
# ---------------------------------------------------------------------------

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.root}/../../../backend/sandboxes/phase8"
  output_path = "${path.module}/.terraform/handler.zip"
}

# ---------------------------------------------------------------------------
# CloudWatch Log Groups — Lambda (explicit, retention 1 day)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "validate_order" {
  name              = "/aws/lambda/phase8-validate-order"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.phase8.arn
}

resource "aws_cloudwatch_log_group" "charge_payment" {
  name              = "/aws/lambda/phase8-charge-payment"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.phase8.arn
}

resource "aws_cloudwatch_log_group" "update_inventory" {
  name              = "/aws/lambda/phase8-update-inventory"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.phase8.arn
}

resource "aws_cloudwatch_log_group" "notify_customer" {
  name              = "/aws/lambda/phase8-notify-customer"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.phase8.arn
}

resource "aws_cloudwatch_log_group" "compensate_order" {
  name              = "/aws/lambda/phase8-compensate-order"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.phase8.arn
}

# ---------------------------------------------------------------------------
# Lambda functions — 5 functions sharing the same zip
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "validate_order" {
  function_name    = "phase8-validate-order"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.validate_order_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      ORDERS_TABLE = aws_dynamodb_table.orders.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.validate_order]
}

resource "aws_lambda_function" "charge_payment" {
  function_name    = "phase8-charge-payment"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.charge_payment_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      ORDERS_TABLE = aws_dynamodb_table.orders.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.charge_payment]
}

resource "aws_lambda_function" "update_inventory" {
  function_name    = "phase8-update-inventory"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.update_inventory_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      ORDERS_TABLE = aws_dynamodb_table.orders.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.update_inventory]
}

resource "aws_lambda_function" "notify_customer" {
  function_name    = "phase8-notify-customer"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.notify_customer_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      ORDERS_TABLE  = aws_dynamodb_table.orders.name
      SNS_TOPIC_ARN = aws_sns_topic.order_notify.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.notify_customer]
}

resource "aws_lambda_function" "compensate_order" {
  function_name    = "phase8-compensate-order"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.compensate_order_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      ORDERS_TABLE = aws_dynamodb_table.orders.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.compensate_order]
}

# ---------------------------------------------------------------------------
# CloudWatch Log Group — Step Functions execution logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/phase8-order-saga"
  retention_in_days = 1
  kms_key_id        = aws_kms_key.phase8.arn
}

# ---------------------------------------------------------------------------
# Step Functions — Order Saga state machine
# ---------------------------------------------------------------------------

resource "aws_sfn_state_machine" "order_saga" {
  name     = "phase8-order-saga"
  role_arn = aws_iam_role.sfn_execution.arn
  type     = "STANDARD"

  definition = templatefile("${path.module}/state_machine_definition.json", {
    validate_order_arn   = aws_lambda_function.validate_order.arn
    charge_payment_arn   = aws_lambda_function.charge_payment.arn
    update_inventory_arn = aws_lambda_function.update_inventory.arn
    notify_customer_arn  = aws_lambda_function.notify_customer.arn
    compensate_order_arn = aws_lambda_function.compensate_order.arn
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  encryption_configuration {
    kms_key_id                        = aws_kms_key.phase8.arn
    type                              = "CUSTOMER_MANAGED_KMS_KEY"
    kms_data_key_reuse_period_seconds = 300
  }
}

# ---------------------------------------------------------------------------
# CloudWatch Dashboard
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "phase8" {
  dashboard_name = "Phase8-StepFunctions"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          title  = "SFN Executions"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/States", "ExecutionsStarted", "StateMachineArn", aws_sfn_state_machine.order_saga.arn],
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", aws_sfn_state_machine.order_saga.arn],
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", aws_sfn_state_machine.order_saga.arn],
            ["AWS/States", "ExecutionsTimedOut", "StateMachineArn", aws_sfn_state_machine.order_saga.arn]
          ]
          view = "timeSeries"
        }
      },
      {
        type = "metric"
        properties = {
          title  = "SFN Execution Duration (P99)"
          period = 60
          stat   = "p99"
          metrics = [
            ["AWS/States", "ExecutionTime", "StateMachineArn", aws_sfn_state_machine.order_saga.arn]
          ]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "Lambda Errors (all phase8 functions)"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", "phase8-validate-order"],
            ["AWS/Lambda", "Errors", "FunctionName", "phase8-charge-payment"],
            ["AWS/Lambda", "Errors", "FunctionName", "phase8-update-inventory"],
            ["AWS/Lambda", "Errors", "FunctionName", "phase8-notify-customer"],
            ["AWS/Lambda", "Errors", "FunctionName", "phase8-compensate-order"]
          ]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "Lambda Duration P99"
          period = 60
          stat   = "p99"
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", "phase8-validate-order"],
            ["AWS/Lambda", "Duration", "FunctionName", "phase8-charge-payment"]
          ]
        }
      },
      {
        type = "log"
        properties = {
          title  = "SFN Execution Failures (last 20)"
          query  = "SOURCE '/aws/states/phase8-order-saga' | fields @timestamp, type, details.error, details.cause | filter type = 'ExecutionFailed' | sort @timestamp desc | limit 20"
          region = var.aws_region
          view   = "table"
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# CloudWatch Metric Alarm — SFN execution failures
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "sfn_failures" {
  alarm_name          = "phase8-sfn-execution-failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 60
  statistic           = "Sum"
  threshold           = 3
  alarm_description   = "Phase8 SFN: 3+ failures in 1 min"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.order_saga.arn
  }
}
