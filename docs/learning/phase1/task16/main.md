# Phase 1 / Task 16: Lambda デプロイスクリプト

## 概要

`backend/` の Python コードと依存ライブラリを 1 つの ZIP にまとめて `backend/dist/lambda.zip` を生成するビルドスクリプト。
Terraform Lambda モジュール (Task 9) はこの ZIP を `filename` で参照する。

主な学習ポイント:
- **Lambda デプロイパッケージの構造**: ハンドラ識別子 (`lambdas.save_user.handler.lambda_handler`) と ZIP 内パスの対応
- **依存ライブラリの含め方**: `pip install --target` で平坦にインストール → ZIP 化
- **AWS Lambda Python runtime に同梱の boto3**: バージョンを揃えるため明示的に含める or 同梱版に任せる判断

## 目次

- [01. Lambda デプロイパッケージのビルド方法](01-lambda-zip-build.md) — ZIP 構造、依存ライブラリ、再現性

## 振り返り

（Task 内の全 Topic クイズ完了後に生成）
