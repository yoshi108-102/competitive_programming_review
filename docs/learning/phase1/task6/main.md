# Phase 1 / Task 6: Backend — Lambda: `save_user` ハンドラー

## 概要

ログイン中のユーザーの **AtCoder ユーザー名を保存** する Lambda ハンドラ。
Cognito JWT から内部 user_id を取得し、リクエストボディの `atcoder_username` を DynamoDB の `users` テーブルに upsert する。

主な学習ポイント:

- API Gateway Proxy Integration の **event 構造**（特に `body` の文字列化と JSON 再パース）
- 入力 validation パターン（境界での弾き方、`error()` 連携）
- DynamoDB `put_item` の **upsert 性質**（同一 PK の上書き）
- Task 3〜5 で作ったヘルパ（`shared/db`, `shared/response`）の組み合わせ

## 目次

- [01. Lambda ハンドラの構造パターン](01-lambda-handler-skeleton.md) — event 解析、validation、business logic、response の標準フロー（Task 7/8 でも参照）

## 振り返り

（Task 内の全 Topic クイズ完了後に生成）
