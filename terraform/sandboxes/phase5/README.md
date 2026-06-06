# Phase 5: CloudFront + WAF Sandbox

CloudFront (CDN) と WAF v2 を組み合わせた静的コンテンツ配信環境を構築し、エッジキャッシュの動作・WAF ルール評価・CloudWatch メトリクス観測を体験する sandbox です。

**全リソースを us-east-1 に統一**しています。WAF の `scope=CLOUDFRONT` および CloudFront メトリクスは us-east-1 固定の AWS 制約によるものです。

---

## この Sandbox が作るもの

| リソース | 名前 | 目的 |
|---|---|---|
| `aws_s3_bucket` (origin) | `atcoder-phase5-origin-<suffix>` | 静的コンテンツ配信元（Block Public Access + OAC 経由のみ） |
| `aws_s3_bucket` (cf_logs) | `atcoder-phase5-cf-logs-<suffix>` | CloudFront 標準アクセスログ格納（ACL: log-delivery-write） |
| `aws_cloudfront_origin_access_control` | `phase5-oac-<suffix>` | OAC (SigV4 署名・OAI の後継推奨方式) |
| `aws_cloudfront_distribution` | `*.cloudfront.net` 自動割当 | CDN 本体。PriceClass_100（NA+EU）、HTTPS 強制、TLSv1.2_2021 |
| `aws_wafv2_web_acl` | `phase5-waf` | AWSManagedRulesCommonRuleSet + RateLimit（IP, 1000 req/5 min） |
| `aws_cloudwatch_log_group` | `aws-waf-logs-phase5` | WAF ログ（名前プレフィックス必須・保持 1 日） |
| `aws_wafv2_web_acl_logging_configuration` | — | WAF → CloudWatch Logs 連携 |
| `aws_cloudwatch_dashboard` | `phase5-dashboard` | CF Requests/Error Rates + WAF Allowed vs Blocked + WAF Block ログ |
| `aws_cloudwatch_metric_alarm` | `phase5-cf-5xx-error-rate` | 5xxErrorRate > 5% で ALARM |

S3 バケットポリシーは OAC + `AWS:SourceArn` 条件で Confused Deputy 攻撃を防ぐ構成です。

---

## クイックコマンド一覧

```bash
# 1. 構文検証（課金なし・1〜2 分）
make sandbox-test-phase5

# 2. リソース作成（課金開始・CloudFront 作成に 10〜15 分）
make sandbox-up-phase5

# 3. index.html アップロード + 6 シナリオのリクエスト生成（3〜5 分）
#    正常 50 回 / 404 × 10 / SQLi ブロック / レートバースト 120 並列 / Bot UA / Invalidation
make sandbox-load-phase5

# 4. CloudWatch メトリクス確認（3 分待機 + 取得）
make sandbox-watch-phase5

# 5. リソース削除（CloudFront 削除に 30〜45 分）
make sandbox-down-phase5
```

詳しい手順・期待される出力例・観察チェックリスト・トラブルシュートは:

**`../../../docs/learning/phase5/handson.md`** を参照してください。

---

## コスト・Destroy 注意事項

| 項目 | 補足 |
|---|---|
| CloudFront 作成 | **10〜15 分**かかります（apply 直後の curl は `NoSuchDistribution` になる場合あり） |
| CloudFront 削除 | **30〜45 分**かかります。Ctrl-C で中断すると手動削除が必要になります |
| WAF コスト | Web ACL $5/月 + ルール $1/本/月。1 時間以内に destroy すれば合計 **$0.02 未満** |
| CF メトリクスのリージョン | **us-east-1 のみ**。東京リージョンのコンソールでは表示されません |
| WAF ロググループ名 | `aws-waf-logs-` プレフィックスが **AWS 仕様で必須**。変えると apply エラー |
| 残存確認 | `aws resourcegroupstaggingapi get-resources --region us-east-1 --tag-filters Key=Sandbox,Values=phase5` |
| `sandbox-down-all` 実行前の注意 | CF の長い削除時間がブロッカーになるため Phase 5 を先に個別 destroy 推奨 |

---

## 設計書・学習教材

- ハンズオン詳細: `docs/learning/phase5/handson.md` / `handson.html`
- 設計書: `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md`（Phase 5 節: 行 4799〜5789）
- プレビュー教材: `docs/learning/phase5/preview-cloudfront-waf.md`（キャッシュ仕組み・WAF ルール評価順序・よくある落とし穴）
