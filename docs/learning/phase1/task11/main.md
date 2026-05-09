# Phase 1 / Task 11: Frontend — 型定義と API クライアント

## 概要

Backend の API レスポンス型を TypeScript で定義し、Cognito JWT を `Authorization: Bearer` ヘッダで送る fetch クライアントを書く。

Task 12〜15 (各ページ) はこの API クライアントに依存する。

主な学習ポイント:

- **API レスポンス型のミラー**: Backend `success()` / `error()` の形を TypeScript で表現
- **Amplify v6 の認証セッション**: `fetchAuthSession()` で JWT を取得
- **fetch ラッパー**: 認証ヘッダ付与・error → 例外変換を 1 か所に集約
- **環境変数経由の API URL**: `NEXT_PUBLIC_API_URL` を Terraform output から流し込む

## 目次

- [01. Frontend API クライアントパターン](01-frontend-api-client.md) — Amplify セッション取得 + fetch ラッパー + エラーハンドリング

## 振り返り

（Task 内の全 Topic クイズ完了後に生成）
