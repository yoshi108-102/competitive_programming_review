terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Phase 5: CloudFront + WAF — 全リソースを us-east-1 に統一
# (WAF scope=CLOUDFRONT および CloudFront メトリクスは us-east-1 のみ)
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Sandbox   = "phase5"
      ManagedBy = "terraform"
    }
  }
}
