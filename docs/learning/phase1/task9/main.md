# Phase 1 / Task 9: Terraform — Lambda モジュール

## 概要

Task 6〜8 で書いた Lambda ハンドラ 3 本（save_user / sync_submissions / get_submissions）を AWS にデプロイするための Terraform モジュール。

主な学習ポイント:

- **IAM 実行ロール (Lambda Execution Role)**: `lambda.amazonaws.com` を信頼するロール + 最小権限の inline policy
- **`aws_lambda_function`** リソース: ZIP artifact、ランタイム、ハンドラ識別子、環境変数、メモリ・タイムアウト
- **CloudWatch ログ**: `aws_cloudwatch_log_group` の保持期間
- **`aws_lambda_permission`**: API Gateway から Lambda を呼び出すための招待状

## 目次

- [01. Terraform Lambda モジュールのパターン](01-terraform-lambda-module.md) — IAM ロール / aws_lambda_function / log group / permission の構成

## 振り返り

（Task 内の全 Topic クイズ完了後に生成）
