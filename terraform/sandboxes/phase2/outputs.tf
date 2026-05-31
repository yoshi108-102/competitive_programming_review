output "main_bucket_name" {
  description = "Name of the main S3 bucket"
  value       = aws_s3_bucket.main.id
}

output "logs_bucket_name" {
  description = "Name of the access logs S3 bucket"
  value       = aws_s3_bucket.logs.id
}

output "lambda_function_name" {
  description = "Name of the on-upload Lambda function"
  value       = aws_lambda_function.on_upload.function_name
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for S3 SSE"
  value       = aws_kms_key.s3.arn
}

output "dashboard_name" {
  description = "CloudWatch Dashboard name"
  value       = aws_cloudwatch_dashboard.phase2.dashboard_name
}

output "aws_region" {
  description = "AWS region used for this sandbox"
  value       = var.aws_region
}
