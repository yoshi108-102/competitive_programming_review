# Phase 5: CloudFront + WAF Sandbox

## 概要

CloudFront (CDN) と WAF v2 を組み合わせた静的コンテンツ配信サンドボックス。

- **全リソースを us-east-1 に統一** (WAF scope=CLOUDFRONT と CloudFront メトリクスは us-east-1 のみ対応)
- S3 オリジン + OAC (Origin Access Control) によるセキュアなアクセス制御
- WAF: AWSManagedRulesCommonRuleSet + Rate-based ルール
- CloudWatch Dashboard でメトリクスを可視化

## リソース一覧

| リソース | 目的 |
|---|---|
| `aws_s3_bucket.origin` | 静的コンテンツ配信元 |
| `aws_s3_bucket.cf_logs` | CloudFront アクセスログ格納 |
| `aws_cloudfront_origin_access_control` | OAC (SigV4 署名) |
| `aws_cloudfront_distribution` | CDN 本体 (PriceClass_100) |
| `aws_wafv2_web_acl` | WAF ルールセット |
| `aws_cloudwatch_log_group.waf` | WAF ログ (aws-waf-logs-phase5) |
| `aws_wafv2_logging_configuration` | WAF → CloudWatch Logs |
| `aws_cloudwatch_dashboard` | phase5-dashboard |
| `aws_cloudwatch_metric_alarm` | 5xxErrorRate > 5% で ALARM |

## 使い方

```bash
# 1. Terraform 初期化 + 構文検証 (無料)
make sandbox-test-phase5

# 2. リソース作成 (課金あり — CF 作成に 10〜15 分かかります)
make sandbox-up-phase5

# 3. index.html をアップロード & リクエスト生成
make sandbox-load-phase5

# 4. メトリクス確認 (load 後 3〜5 分待つ)
make sandbox-watch-phase5

# 5. リソース削除 (CF 削除に 30〜45 分かかります)
make sandbox-down-phase5
```

## 注意事項

- CloudFront の作成・削除は最大 **30〜45 分** かかります。途中で Ctrl-C しないこと。
- CloudFront メトリクスは **us-east-1 のみ** に存在します。東京コンソールでは表示されません。
- WAF ロググループ名は `aws-waf-logs-` プレフィックスが必須 (AWS 仕様)。
- `sandbox-down-all` 実行前に Phase 5 を先に個別 destroy することを推奨します。
