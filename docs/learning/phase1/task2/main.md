# Phase 1 / Task 2: Backend — Python 環境セットアップ

## 概要

Lambda で動かす Python バックエンドの開発環境を準備する。実装するアプリコードはまだ少なく、**テスト基盤と依存管理**が主目的:

- `requirements.txt` / `requirements-dev.txt` で本番依存とテスト依存を分離
- `moto` で DynamoDB をローカルモック化し、AWS 実接続なしで単体テスト
- `pytest fixture` で「テーブルを作る → 使う → 後片付け」を自動化
- `venv` で Python 環境をプロジェクトに隔離

## 目次

- [01. moto と AWS テスト用ダミー認証情報](01-moto-and-aws-test-credentials.md) — AWS を丸ごとローカルでエミュレート、`AWS_ACCESS_KEY_ID="testing"` の正体、性能計測以外の全機能テストに使える

## 振り返り

（Task完了時に記入）
