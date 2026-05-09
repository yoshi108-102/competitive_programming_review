# Phase 1 / Task 17: Terraform apply & 動作確認

## 概要

Tasks 1〜10 の Terraform を実際に AWS にデプロイし、`/health` エンドポイント等で疎通確認する。
**実際の AWS 課金が発生する**ため、ユーザー判断で実行する。

主な学習ポイント:
- `terraform plan` で差分確認 → `apply` で適用
- API Gateway の動作確認 (curl + JWT)
- CloudWatch Logs での Lambda 実行ログ確認

## 目次

- [01. Terraform apply 手順と動作確認](01-terraform-apply-and-verify.md) — plan / apply / output / curl / CloudWatch

## 振り返り

（Task 内の全 Topic クイズ完了後に生成）
