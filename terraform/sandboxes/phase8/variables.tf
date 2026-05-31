variable "aws_region" {
  description = "AWS region for the sandbox"
  type        = string
  default     = "ap-northeast-1"
}

variable "notify_email" {
  description = "Email address for order notification SNS subscription"
  type        = string
  default     = "sandbox@example.com"
}
