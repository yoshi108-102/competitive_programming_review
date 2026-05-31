# アカウント単位の月次コスト見張り。
# AWS Budgets API は us-east-1 エンドポイントで動くため region を固定する。
# 注: Budget はアカウントあたり 2 個まで無料。3 個目以降 $0.02/budget/日。
terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Sandbox   = "_budget"
      ManagedBy = "terraform"
    }
  }
}

resource "aws_budgets_budget" "monthly" {
  name         = "atcoder-sandbox-monthly"
  budget_type  = "COST"
  limit_amount = var.limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.notify_email]
  }
}
