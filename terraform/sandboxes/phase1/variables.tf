variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

# Production resource names: retrieve via `terraform output` or SSM, then write to tfvars.
variable "lambda_function_names" {
  type        = list(string)
  description = "List of production Lambda function names"
}

variable "api_gw_rest_api_id" {
  type        = string
  description = "REST API ID (or Name) of the production API Gateway"
}

variable "api_gw_stage_name" {
  type    = string
  default = "prod"
}

variable "dynamodb_table_name" {
  type        = string
  description = "Production DynamoDB table name"
}

variable "cognito_user_pool_id" {
  type        = string
  description = "Production Cognito User Pool ID"
}
