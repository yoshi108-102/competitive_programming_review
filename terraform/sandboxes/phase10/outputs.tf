output "orders_topic_arn" {
  description = "ARN of the standard SNS orders topic"
  value       = aws_sns_topic.orders.arn
}

output "orders_fifo_topic_arn" {
  description = "ARN of the FIFO SNS orders topic"
  value       = aws_sns_topic.orders_fifo.arn
}

output "fulfillment_queue_url" {
  description = "URL of the fulfillment SQS queue"
  value       = aws_sqs_queue.main["fulfillment"].url
}

output "analytics_queue_url" {
  description = "URL of the analytics SQS queue"
  value       = aws_sqs_queue.main["analytics"].url
}

output "wholesale_queue_url" {
  description = "URL of the wholesale SQS queue"
  value       = aws_sqs_queue.main["wholesale"].url
}

output "notifier_function_name" {
  description = "Name of the Lambda notifier function"
  value       = aws_lambda_function.notifier.function_name
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for SNS/SQS encryption"
  value       = aws_kms_key.phase10.arn
}
