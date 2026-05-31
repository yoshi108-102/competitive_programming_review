output "lambda_function_name" {
  description = "Name of the Bedrock invoker Lambda function"
  value       = aws_lambda_function.invoker.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Bedrock invoker Lambda function"
  value       = aws_lambda_function.invoker.arn
}

output "s3_invocation_logs_bucket" {
  description = "S3 bucket name for Bedrock invocation logs"
  value       = aws_s3_bucket.invocation_logs.id
}

output "kms_key_arn" {
  description = "ARN of the KMS CMK used for encryption"
  value       = aws_kms_key.phase6.arn
}

output "cloudwatch_dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.phase6.dashboard_name}"
}

output "bedrock_log_group_name" {
  description = "CloudWatch log group name for Bedrock invocation logs"
  value       = aws_cloudwatch_log_group.bedrock_invocation.name
}
