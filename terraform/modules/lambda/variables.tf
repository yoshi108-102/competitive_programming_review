variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., prod, dev)"
  type        = string
}

# DynamoDB 接続情報 (handler 内で os.environ から読む)
# → docs/learning/phase1/practice/lambda-handler-skeleton.md
variable "users_table_name" {
  description = "DynamoDB users table name"
  type        = string
}

variable "users_table_arn" {
  description = "DynamoDB users table ARN (for IAM policy resource)"
  type        = string
}

variable "submissions_table_name" {
  description = "DynamoDB submissions table name"
  type        = string
}

variable "submissions_table_arn" {
  description = "DynamoDB submissions table ARN"
  type        = string
}

# API Gateway 側からの invoke 許可用
# → docs/learning/phase1/05-lambda-execution-role-and-deployment.md §D
variable "api_gateway_execution_arn" {
  description = "API Gateway execution ARN for resource-based Lambda permission"
  type        = string
}

# デプロイ ZIP パス。Task 16 のビルドスクリプトが生成する
variable "lambda_zip_path" {
  description = "Path to the Lambda deployment ZIP artifact"
  type        = string
  default     = "../backend/dist/lambda.zip"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days"
  type        = number
  default     = 14
}
