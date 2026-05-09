# Phase 1 / Task 10: Terraform — API Gateway エンドポイント追加

## 概要

Task 9 で作った Lambda 関数 3 本を API Gateway のエンドポイントに紐付ける。

| エンドポイント | メソッド | Lambda | 認可 |
|---|---|---|---|
| `POST /users/me` | POST | save_user | Cognito 必須 |
| `POST /sync` | POST | sync_submissions | Cognito 必須 |
| `GET /submissions` | GET | get_submissions | Cognito 必須 |
| `GET /submissions/{submission_id}` | GET | get_submissions | Cognito 必須 |
| `OPTIONS /*` | OPTIONS | (mock) | なし | CORS preflight |

主な学習ポイント:

- **API Gateway リソースツリー**: `aws_api_gateway_resource` で `/users/me` のような階層を作る
- **Method + Integration の対**: Method (HTTP 仕様) と Integration (Lambda への接続) は別リソース
- **`AWS_PROXY` 統合**: Lambda Proxy Integration で event をそのまま Lambda に渡す
- **CORS preflight**: ブラウザの OPTIONS リクエストに **MOCK 統合**で 200 を返す
- **`triggers` で deployment 再実行**: 変更があるたびにステージを再デプロイ

## 目次

- [01. API Gateway REST API のリソース構造](01-api-gateway-resource-method-integration.md) — Resource / Method / Integration / Deployment / Stage の役割分担

## 振り返り

（Task 内の全 Topic クイズ完了後に生成）
