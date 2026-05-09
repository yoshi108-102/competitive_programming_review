variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN for the authorizer"
  type        = string
}

# Lambda invoke ARN (function key → invoke_arn の map)
# → docs/learning/phase1/task10/01-api-gateway-resource-method-integration.md §C
variable "lambda_invoke_arns" {
  description = "Map of lambda function key to its invoke ARN (for AWS_PROXY integration)"
  type        = map(string)
}
