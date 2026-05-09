# Phase 1 / Task 5: Backend — `shared/atcoder_client.py` (AtCoder API クライアント)

## 概要

AtCoder のユーザー提出履歴を取得するクライアントを実装する。
AtCoder 公式には submission 一覧 API が無く、コミュニティが提供している **AtCoder Problems API** (kenkoooo.com) を使う。

主な学習ポイント:

- **AtCoder Problems API の仕様**: `/v3/user/submissions` エンドポイント、`from_second` ベースのページネーション、レート制限（>1 秒の sleep 推奨）
- **Python `requests` ライブラリ**: `get`, `params`, `raise_for_status`, `timeout` の必須事項
- **`requests-mock` による HTTP モックテスト**: 外部 API を叩かずにテストする
- **責任ある外部 API 利用**: コミュニティ提供 API なので過度なアクセスを避ける

## 目次

- [01. AtCoder Problems API](01-atcoder-problems-api.md) — `/v3/user/submissions` エンドポイント、`from_second` ページネーション、レート制限（>1 秒 sleep）
- [02. Python `requests` と `requests-mock`](02-requests-and-requests-mock.md) — `params` / `raise_for_status` / `timeout` の必須事項、HTTP モックテストの作法

## 振り返り

（Task 内の全 Topic クイズ完了後に生成）
