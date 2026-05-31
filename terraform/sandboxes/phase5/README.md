# Phase 5: CloudFront + WAF Sandbox

## この Sandbox は何を作るか

Amazon CloudFront (CDN) と AWS WAF v2 を組み合わせた静的コンテンツ配信環境を構築し、
エッジキャッシュの動作・WAF ルール評価・CloudWatch メトリクス観測を体験するための sandbox です。

**全リソースを us-east-1 に統一** しています。これは AWS の制約による必然的な設計です。

- WAF の `scope = "CLOUDFRONT"` は us-east-1 にしか作成できない
- CloudFront のメトリクス (`AWS/CloudFront` 名前空間) は us-east-1 の CloudWatch にしか送られない

---

## 主要リソース一覧

| リソース | 目的 | 主な設定 |
|---|---|---|
| `aws_s3_bucket.origin` | 静的コンテンツ配信元 | `force_destroy = true`、Block Public Access 全4項目 |
| `aws_s3_bucket.cf_logs` | CloudFront アクセスログ格納 | ACL `log-delivery-write` (CF 標準ログ配信要件) |
| `aws_cloudfront_origin_access_control` | OAC (SigV4 署名) | `signing_behavior = "always"`、OAI の後継・推奨方式 |
| `aws_cloudfront_distribution` | CDN 本体 | `PriceClass_100`（NA+EU のみ）、HTTPS 強制、TLSv1.2_2021 |
| `aws_wafv2_web_acl` | WAF ルールセット | AWSManagedRulesCommonRuleSet + Rate-based (IP, 1000 req/5 min) |
| `aws_cloudwatch_log_group.waf` | WAF ログ | 名前 `aws-waf-logs-phase5` 必須（AWS 仕様）、保持 1 日 |
| `aws_wafv2_web_acl_logging_configuration` | WAF → CloudWatch Logs 連携 | - |
| `aws_cloudwatch_dashboard.phase5` | メトリクス可視化 | CF Requests / Error Rates / WAF Allowed vs Blocked / WAF Block ログ |
| `aws_cloudwatch_metric_alarm.cf_5xx` | 5xx エラー率監視 | `5xxErrorRate > 5%` で ALARM、`treat_missing_data = "notBreaching"` |

S3 バケットポリシーは OAC 専用に設定されています。
`Principal.Service = "cloudfront.amazonaws.com"` と `Condition.StringEquals."AWS:SourceArn"` で
このディストリビューションの ARN を明示的に限定しているため、他の CloudFront 経由のアクセスも遮断されます
（Confused Deputy 攻撃への対策）。

---

## 使い方

```bash
# 1. Terraform 初期化 + 構文検証 (課金なし)
make sandbox-test-phase5

# 2. リソース作成 (課金開始 — CF 作成に 10〜15 分かかります)
make sandbox-up-phase5

# 3. index.html をアップロード & リクエスト群を生成 (WAF/CF メトリクスを発生させる)
#    SQLi パターン・レートバースト・Bot UA など複数シナリオを実行します
make sandbox-load-phase5

# 4. メトリクスを確認 (load 後 3〜5 分待ってから実行)
#    CF / WAF の CloudWatch メトリクスをコンソール Deep Link 付きで表示します
make sandbox-watch-phase5

# 5. リソース削除 (CF 削除に 30〜45 分かかります)
make sandbox-down-phase5
```

---

## コスト・Destroy 注意事項

| 項目 | 補足 |
|---|---|
| CloudFront の作成・削除 | 各 **10〜15 分 / 30〜45 分** かかります。途中で Ctrl-C しないこと |
| `sandbox-down-all` 実行前に Phase 5 を個別 destroy することを推奨 | CF の長い削除時間がブロックになるため |
| CloudFront メトリクス | **us-east-1 のみ**。東京リージョンのコンソールでは表示されません |
| WAF ロググループ名 | `aws-waf-logs-` プレフィックスが **AWS 仕様で必須**。変えると apply エラー |
| KMS キー（extra-credit） | SSE-KMS に切り替えた場合、KMS キー削除に **7 日間の待機期間**あり |
| WAF コスト構造 | Web ACL $5/月 + ルール $1/本/月 + $0.60/100 万 req。Bot Control は追加 $10/100 万 WCU |

---

## 設計書・学習教材へのリンク

- 設計書: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md` (Phase 5 節: 行 4799〜5789)
- プレビュー教材: `docs/learning/phase5/preview-cloudfront-waf.md`
  - コアコンセプト（キャッシュ仕組み、WAF ルール評価順序）
  - よくある落とし穴・誤解
  - 関連・発展サービス / セキュリティ課題と対策 / インフラ応用パターン（脱線3節）
