output "bus_name" {
  value = aws_cloudwatch_event_bus.main.name
}

output "bus_arn" {
  value = aws_cloudwatch_event_bus.main.arn
}

output "processor_name" {
  value = aws_lambda_function.processor.function_name
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.id
}

output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${var.prefix}-dashboard"
}

output "archive_name" {
  value = aws_cloudwatch_event_archive.main.name
}
