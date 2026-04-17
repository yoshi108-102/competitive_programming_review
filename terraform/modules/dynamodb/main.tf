# DynamoDB テーブル定義（users, submissions, problems）
# キー設計の解説 → docs/learning/phase1/task1/01-dynamodb-keys.md

# users テーブル
resource "aws_dynamodb_table" "users" {
  name         = "${var.project_name}-users-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"

  attribute {
    name = "user_id"
    type = "S"
  }
}

# submissions テーブル
resource "aws_dynamodb_table" "submissions" {
  name         = "${var.project_name}-submissions-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "submission_id"

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "submission_id"
    type = "S"
  }
}

# problems テーブル
resource "aws_dynamodb_table" "problems" {
  name         = "${var.project_name}-problems-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "problem_id"

  attribute {
    name = "problem_id"
    type = "S"
  }

  attribute {
    name = "tag"
    type = "S"
  }

  attribute {
    name = "difficulty"
    type = "S"
  }

  # タグと難易度で問題を検索するためのGSI
  # → docs/learning/phase1/task1/01-dynamodb-keys.md
  global_secondary_index {
    name            = "TagDifficultyIndex"
    hash_key        = "tag"
    range_key       = "difficulty"
    projection_type = "ALL"
  }
}
