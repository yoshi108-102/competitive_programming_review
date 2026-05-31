output "api_url" {
  description = "API Gateway HTTP API endpoint URL"
  value       = aws_apigatewayv2_stage.phase9.invoke_url
}

output "sqs_url" {
  description = "SQS main queue URL"
  value       = aws_sqs_queue.phase9.url
}

output "producer_function_name" {
  description = "Producer Lambda function name"
  value       = aws_lambda_function.producer.function_name
}

output "consumer_function_name" {
  description = "Consumer Lambda function name"
  value       = aws_lambda_function.consumer.function_name
}

output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.phase9.name
}

output "kms_key_arn" {
  description = "KMS CMK ARN used for encryption"
  value       = aws_kms_key.phase9.arn
}

output "dashboard_url" {
  description = "CloudWatch Dashboard URL"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.phase9.dashboard_name}"
}
