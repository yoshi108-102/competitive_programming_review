terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Terraformの状態ファイル(.tfstate)をS3に保存。dynamodb_tableは同時apply防止のロック。
  # → docs/learning/phase1/task1/reference/terraform-basics.md (Q2: backend "s3")
  backend "s3" {
    bucket         = "atcoder-review-tfstate"
    key            = "terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "atcoder-review-tflock"
    encrypt        = true
  }
}

# 認証情報はコードに書かず、~/.aws/credentials or IAM Identity Center(SSO)で管理する。
# → docs/learning/phase1/task1/reference/aws-authentication.md
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "atcoder-review"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
