module "cognito" {
  source = "./modules/cognito"

  project_name = var.project_name
  environment  = var.environment
}

module "dynamodb" {
  source = "./modules/dynamodb"

  project_name = var.project_name
  environment  = var.environment
}

module "lambda" {
  source = "./modules/lambda"

  project_name = var.project_name
  environment  = var.environment

  users_table_name       = module.dynamodb.users_table_name
  users_table_arn        = module.dynamodb.users_table_arn
  submissions_table_name = module.dynamodb.submissions_table_name
  submissions_table_arn  = module.dynamodb.submissions_table_arn

  api_gateway_execution_arn = module.api_gateway.execution_arn
}

module "api_gateway" {
  source = "./modules/api_gateway"

  project_name          = var.project_name
  environment           = var.environment
  cognito_user_pool_arn = module.cognito.user_pool_arn

  lambda_invoke_arns = module.lambda.function_invoke_arns
}
