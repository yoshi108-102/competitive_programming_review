# Phase 1 / Task 4: Backend — `shared/db.py` (DynamoDB 操作ヘルパー)

## 概要

Lambda ハンドラから DynamoDB を操作するための共通ヘルパーを実装する。
**全 Lambda ハンドラで毎回書くボイラープレート**（Resource 取得、ページネーション、エラーハンドリング）を 1 箇所に集約し、ハンドラ側はビジネスロジックに集中できるようにする。

主な学習ポイント:

- **Boto3 Resource API vs Client API** の違いと使い分け（Resource は **メンテナンスモード**で新機能追加なし）
- **DynamoDB の 1 MB 制限** と `LastEvaluatedKey` / `ExclusiveStartKey` の手動ループ
- **Boto3 Paginators** による pagination の抽象化（Client API 専用）
- 環境変数経由のテーブル名解決（Task 3 の方針継続）

## 目次

- [01. Boto3 Resource API vs Client API](01-boto3-resource-vs-client.md) — 概念差、メンテナンスモード警告、スレッドセーフティ
- [02. DynamoDB の 1MB 制限 / LastEvaluatedKey / Boto3 Paginators](02-dynamodb-pagination-and-paginators.md) — pagination の必要性、ExclusiveStartKey、Paginator の Client 専用制約

## 振り返り

（Task 内の全 Topic クイズ完了後に生成）
