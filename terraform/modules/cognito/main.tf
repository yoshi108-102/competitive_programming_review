resource "aws_cognito_user_pool" "main" {
  name = "${var.project_name}-${var.environment}"

  # セルフサインアップを無効化（管理者のみユーザー作成可能）
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  # メールをユーザー名として使用
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # パスワードポリシー
  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }

  # メール設定（Cognito デフォルト）
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # スキーマ
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }

  # アカウント復旧設定
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_client" "main" {
  name         = "${var.project_name}-client"
  user_pool_id = aws_cognito_user_pool.main.id

  # SRP認証フロー
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # トークン有効期限
  access_token_validity  = 1  # 1時間
  id_token_validity      = 1  # 1時間
  refresh_token_validity = 30 # 30日

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # クライアントシークレットなし（SPA向け）
  generate_secret = false

  # コールバック等はHosted UIを使わないので不要
  supported_identity_providers = ["COGNITO"]
}
