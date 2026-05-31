output "main_queue_url" {
  description = "SQS メインキュー URL"
  value       = aws_sqs_queue.main.id
}

output "dlq_url" {
  description = "SQS DLQ URL"
  value       = aws_sqs_queue.dlq.id
}

output "producer_name" {
  description = "Producer Lambda 関数名"
  value       = aws_lambda_function.producer.function_name
}

output "consumer_name" {
  description = "Consumer Lambda 関数名"
  value       = aws_lambda_function.consumer.function_name
}

output "dashboard_name" {
  description = "CloudWatch ダッシュボード名"
  value       = aws_cloudwatch_dashboard.phase3.dashboard_name
}

output "dashboard_url" {
  description = "CloudWatch ダッシュボード URL"
  value       = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=${aws_cloudwatch_dashboard.phase3.dashboard_name}"
}
