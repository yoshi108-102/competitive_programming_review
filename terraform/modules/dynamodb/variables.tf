# DynamoDB モジュールの入力変数
# → docs/learning/phase1/task1/reference/terraform-basics.md

variable "project_name" {
  description = "Project name used as prefix for table names"
  type        = string
}

variable "environment" {
  description = "Environment name (prod, dev, stg)"
  type        = string
}
