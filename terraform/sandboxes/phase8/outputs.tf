output "state_machine_arn" {
  description = "ARN of the Phase8 Order Saga state machine"
  value       = aws_sfn_state_machine.order_saga.arn
}

output "state_machine_name" {
  description = "Name of the Phase8 Order Saga state machine"
  value       = aws_sfn_state_machine.order_saga.name
}

output "dashboard_url" {
  description = "CloudWatch Dashboard URL"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.phase8.dashboard_name}"
}

output "orders_table_name" {
  description = "DynamoDB orders table name"
  value       = aws_dynamodb_table.orders.name
}

output "sns_topic_arn" {
  description = "SNS order notification topic ARN"
  value       = aws_sns_topic.order_notify.arn
}

output "kms_key_arn" {
  description = "KMS CMK ARN used for encryption"
  value       = aws_kms_key.phase8.arn
}
