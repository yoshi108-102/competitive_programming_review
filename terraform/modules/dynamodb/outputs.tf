# DynamoDB モジュールの出力値
# 他のモジュール（Lambda等）がテーブル名・ARNを参照するために使う
# → docs/learning/phase1/task1/reference/terraform-basics.md

output "users_table_name" {
  value = aws_dynamodb_table.users.name
}

output "users_table_arn" {
  value = aws_dynamodb_table.users.arn
}

output "submissions_table_name" {
  value = aws_dynamodb_table.submissions.name
}

output "submissions_table_arn" {
  value = aws_dynamodb_table.submissions.arn
}

output "problems_table_name" {
  value = aws_dynamodb_table.problems.name
}

output "problems_table_arn" {
  value = aws_dynamodb_table.problems.arn
}
