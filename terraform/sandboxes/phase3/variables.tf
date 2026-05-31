variable "aws_region" {
  description = "AWS region for Phase 3 SQS sandbox"
  type        = string
  default     = "ap-northeast-1"
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "phase3"
}
