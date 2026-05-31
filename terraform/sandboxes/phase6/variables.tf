variable "aws_region" {
  description = "AWS region where Bedrock is enabled (must have model access granted)"
  type        = string
  default     = "us-east-1"
}

variable "model_id" {
  description = "Bedrock foundation model ID. Use cross-region inference profile ARN if needed."
  type        = string
  default     = "anthropic.claude-3-haiku-20240307-v1:0"
}

variable "project" {
  description = "Project name prefix used for resource naming"
  type        = string
  default     = "bedrock-sandbox"
}
