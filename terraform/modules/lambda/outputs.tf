output "function_arns" {
  description = "Map of function key → ARN, for API Gateway integration"
  value = {
    for k, fn in aws_lambda_function.fn : k => fn.arn
  }
}

output "function_names" {
  description = "Map of function key → name"
  value = {
    for k, fn in aws_lambda_function.fn : k => fn.function_name
  }
}

output "function_invoke_arns" {
  description = "Map of function key → invoke ARN (used by API Gateway aws_proxy integration)"
  value = {
    for k, fn in aws_lambda_function.fn : k => fn.invoke_arn
  }
}

output "exec_role_arn" {
  description = "IAM execution role ARN (shared across functions)"
  value       = aws_iam_role.lambda_exec.arn
}
