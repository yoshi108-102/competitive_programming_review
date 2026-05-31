output "dashboard_name" {
  description = "CloudWatch Dashboard name"
  value       = aws_cloudwatch_dashboard.phase1.dashboard_name
}

output "dashboard_url" {
  description = "CloudWatch Dashboard console URL"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.phase1.dashboard_name}"
}

output "lambda_function_arns" {
  description = "ARNs of the looked-up Lambda functions"
  value       = { for k, v in data.aws_lambda_function.fns : k => v.arn }
}

output "dynamodb_table_arn" {
  description = "ARN of the looked-up DynamoDB table"
  value       = data.aws_dynamodb_table.main.arn
}
