output "producer_function_name" {
  description = "Phase4 producer Lambda function name"
  value       = aws_lambda_function.producer.function_name
}

output "consumer_function_name" {
  description = "Phase4 consumer Lambda function name"
  value       = aws_lambda_function.consumer.function_name
}

output "dynamodb_table_name" {
  description = "Phase4 DynamoDB table name"
  value       = aws_dynamodb_table.events.name
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.phase4.dashboard_name}"
}

output "sns_topic_arn" {
  description = "SNS alert topic ARN"
  value       = aws_sns_topic.alerts.arn
}
