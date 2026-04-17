output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = module.cognito.user_pool_id
}

output "cognito_user_pool_client_id" {
  description = "Cognito User Pool Client ID"
  value       = module.cognito.user_pool_client_id
}

output "api_gateway_url" {
  description = "API Gateway invoke URL"
  value       = module.api_gateway.api_url
}

output "dynamodb_users_table_name" {
  description = "DynamoDB users table name"
  value       = module.dynamodb.users_table_name
}

output "dynamodb_submissions_table_name" {
  description = "DynamoDB submissions table name"
  value       = module.dynamodb.submissions_table_name
}

output "dynamodb_problems_table_name" {
  description = "DynamoDB problems table name"
  value       = module.dynamodb.problems_table_name
}
