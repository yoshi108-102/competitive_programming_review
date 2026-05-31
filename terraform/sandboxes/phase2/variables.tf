variable "aws_region" {
  description = "AWS region for Phase 2 S3 sandbox"
  type        = string
  default     = "ap-northeast-1"
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "sandbox"
}
