variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

# 本番リソース名のデフォルトは命名規則から導出してある:
#   ${project_name}-...-${environment}  (本番は project_name="atcoder-review", environment="prod")
# 本番を別名でデプロイした場合だけ -var か *.auto.tfvars で上書きすればよい。
# 取得: terraform -chdir=terraform output / aws ... describe-*

variable "lambda_function_names" {
  type        = list(string)
  description = "本番 Lambda 関数名の一覧"
  default = [
    "atcoder-review-save-user-prod",
    "atcoder-review-sync-submissions-prod",
    "atcoder-review-get-submissions-prod",
  ]
}

variable "api_gw_rest_api_id" {
  type        = string
  description = "本番 API Gateway の名前 (data lookup は name で行う)"
  default     = "atcoder-review-api-prod"
}

variable "api_gw_stage_name" {
  type    = string
  default = "prod"
}

variable "dynamodb_table_name" {
  type        = string
  description = "本番 DynamoDB テーブル名 (既定は submissions テーブル)"
  default     = "atcoder-review-submissions-prod"
}

variable "cognito_user_pool_id" {
  type        = string
  description = "本番 Cognito User Pool 名 (data lookup は name で行う)"
  default     = "atcoder-review-prod"
}
