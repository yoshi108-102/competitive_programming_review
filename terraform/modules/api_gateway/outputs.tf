output "api_url" {
  description = "API Gateway invoke URL"
  value       = aws_api_gateway_stage.main.invoke_url
}

output "rest_api_id" {
  description = "REST API ID"
  value       = aws_api_gateway_rest_api.main.id
}

output "root_resource_id" {
  description = "Root resource ID"
  value       = aws_api_gateway_rest_api.main.root_resource_id
}

output "authorizer_id" {
  description = "Cognito Authorizer ID"
  value       = aws_api_gateway_authorizer.cognito.id
}
