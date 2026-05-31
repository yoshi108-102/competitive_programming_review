# --- data sources (read-only; no production state is touched) ---

data "aws_lambda_function" "fns" {
  for_each      = toset(var.lambda_function_names)
  function_name = each.key
}

data "aws_api_gateway_rest_api" "main" {
  name = var.api_gw_rest_api_id
}

data "aws_dynamodb_table" "main" {
  name = var.dynamodb_table_name
}

data "aws_cognito_user_pools" "main" {
  name = var.cognito_user_pool_id
}

data "aws_cloudwatch_log_group" "lambda_logs" {
  for_each = toset(var.lambda_function_names)
  name     = "/aws/lambda/${each.key}"
}

# --- Dashboard ---

locals {
  apigw_dims = [
    { Name = "ApiName", Value = var.api_gw_rest_api_id },
    { Name = "Stage", Value = var.api_gw_stage_name },
  ]

  # CloudWatch の metrics は「メトリクス配列のリスト」。flatten すると各メトリクス配列
  # まで平坦化されて1次元になり PutDashboard が不正になるため concat でリストを連結する。
  lambda_metrics = concat(
    [for fn in var.lambda_function_names : ["AWS/Lambda", "Invocations", "FunctionName", fn, { stat = "Sum" }]],
    [for fn in var.lambda_function_names : ["AWS/Lambda", "Errors", "FunctionName", fn, { stat = "Sum" }]],
  )

  dashboard_body = {
    widgets = [
      # --- Row 1: API Gateway requests & errors ---
      {
        type   = "metric"
        width  = 8
        height = 6
        properties = {
          title = "API GW - Requests & Errors"
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiName", var.api_gw_rest_api_id, "Stage", var.api_gw_stage_name, { stat = "Sum", color = "#1f77b4" }],
            ["AWS/ApiGateway", "4XXError", "ApiName", var.api_gw_rest_api_id, "Stage", var.api_gw_stage_name, { stat = "Sum", color = "#ff7f0e" }],
            ["AWS/ApiGateway", "5XXError", "ApiName", var.api_gw_rest_api_id, "Stage", var.api_gw_stage_name, { stat = "Sum", color = "#d62728" }],
          ]
          period = 60
          view   = "timeSeries"
          region = var.aws_region
        }
      },
      # --- Row 1: API Gateway latency ---
      {
        type   = "metric"
        width  = 8
        height = 6
        properties = {
          title = "API GW - Latency (P50/P90/P99)"
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiName", var.api_gw_rest_api_id, "Stage", var.api_gw_stage_name, { stat = "p50", label = "p50" }],
            ["AWS/ApiGateway", "Latency", "ApiName", var.api_gw_rest_api_id, "Stage", var.api_gw_stage_name, { stat = "p90", label = "p90" }],
            ["AWS/ApiGateway", "Latency", "ApiName", var.api_gw_rest_api_id, "Stage", var.api_gw_stage_name, { stat = "p99", label = "p99" }],
          ]
          period = 60
          view   = "timeSeries"
          region = var.aws_region
        }
      },
      # --- Row 2: Lambda invocations & errors (all functions) ---
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title   = "Lambda - Invocations & Errors (all functions)"
          metrics = local.lambda_metrics
          period  = 60
          view    = "timeSeries"
          region  = var.aws_region
        }
      },
      # --- Row 3: DynamoDB consumed capacity ---
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title = "DynamoDB - Consumed Capacity"
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", var.dynamodb_table_name, { stat = "Sum" }],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", var.dynamodb_table_name, { stat = "Sum" }],
          ]
          period = 60
          view   = "timeSeries"
          region = var.aws_region
        }
      },
      # --- Row 4: Cognito sign-ins ---
      {
        type   = "metric"
        width  = 8
        height = 6
        properties = {
          title = "Cognito - SignIn Successes & Token Refreshes"
          metrics = [
            ["AWS/Cognito", "SignInSuccesses", "UserPool", var.cognito_user_pool_id, { stat = "Sum" }],
            ["AWS/Cognito", "TokenRefreshSuccesses", "UserPool", var.cognito_user_pool_id, { stat = "Sum" }],
          ]
          period = 60
          view   = "timeSeries"
          region = var.aws_region
        }
      },
    ]
  }
}

resource "aws_cloudwatch_dashboard" "phase1" {
  dashboard_name = "phase1-sandbox"
  dashboard_body = jsonencode(local.dashboard_body)
}
