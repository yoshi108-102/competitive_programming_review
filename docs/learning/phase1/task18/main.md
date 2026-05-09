# Phase 1 / Task 18: Frontend 環境変数設定 & 結合テスト

## 概要

Task 17 の `terraform output` から得た値を Frontend の `.env.local` に設定し、ローカルで `next dev` を起動して end-to-end 動作を確認する。

主な学習ポイント:
- **環境変数の二段階注入**: Terraform output → `.env.local` → Next.js プロセス
- **`NEXT_PUBLIC_*` の境界**: クライアントに露出する値 / しない値
- **CORS の最終確認**: ローカル `http://localhost:3000` から本番 API Gateway を叩く

## 目次

- [01. Frontend 結合テスト手順](01-frontend-integration-test.md) — env 設定 / 起動 / E2E 動作確認

## 振り返り

（Task 内の全 Topic クイズ完了後に生成）
