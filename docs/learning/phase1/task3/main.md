# Phase 1 / Task 3: Backend — shared/response.py (APIレスポンスヘルパー)

## 概要

全 Lambda ハンドラーが共通で使う **API レスポンス整形ヘルパー** を実装する。
`{ data, meta }` 形式のレスポンスと、エラーレスポンスの2つの関数を `shared/response.py` に定義する。

Lambda + API Gateway 統合で必要となる「特殊な返り値の形」を理解するのが主題:

- statusCode / headers / body の3要素構造
- CORS ヘッダの意味と必要性
- `json.dumps(..., default=str)` の役割（Decimal対応）

## 目次

- [01. Lambda の HTTP レスポンス形式と CORS / SOP の関係](01-lambda-response-format-and-cors.md) — Lambda Proxy Integration = HTTP レスポンス、CORS/SOP、iframe、Clickjacking、CSRF、徳丸本との接続

## 振り返り

（Task 2 の振り返りと統合予定 — pytest を書くタイミングで）
