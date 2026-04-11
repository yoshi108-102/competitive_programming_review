# Phase 1 / Task 1: Terraform DynamoDB モジュール — 学習ノート

## 概要

DynamoDBのテーブルを3つ（users, submissions, problems）Terraformで定義する。

## トピック別ノート

- [01. DynamoDB キー設計](01-dynamodb-keys.md) — PK/SK/GSIの概念、RDBとの比較、設計パターン
- [02. Terraform コード解説](02-terraform-code-walkthrough.md) — 既存コードのブロックごとの解説と質疑応答

## リファレンス

- [DynamoDB キー設計 vs RDB 比較リファレンス](reference/dynamodb-keys-vs-rdb.md) — 詳細比較、Web検索ソース付き
- [Terraform 基礎リファレンス](reference/terraform-basics.md) — HCL構文、variable/output/resource、backend、モジュール連携
- [AWS認証のベストプラクティス](reference/aws-authentication.md) — IAM Identity Center、IAMロール、アクセスキーの比較

## 振り返り

（Task 1 実装完了後に記入）
