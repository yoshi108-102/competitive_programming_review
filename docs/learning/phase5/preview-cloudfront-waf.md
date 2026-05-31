# Phase 5 プレビュー教材: CloudFront + WAF — エッジ配信とファイアウォール

> プレビュー教材: デモ体験のために先行生成しました。正式な lesson / 振り返りクイズ / 採点は Phase 5 到達時に実施します。

---

## このサービスは何か

### Amazon CloudFront

CloudFront は AWS が提供する **CDN（Content Delivery Network）** サービスです。  
世界 400 以上のエッジロケーション（PoP）にコンテンツをキャッシュし、ユーザーに最も近いエッジから応答することでレイテンシを削減します。  
HTTP/HTTPS リクエストを受け取り、バックエンド（オリジン）への通信回数・帯域を減らすプロキシ兼キャッシュ層として機能します。

### AWS WAF (Web Application Firewall)

WAF は HTTP/HTTPS トラフィックを検査し、**Web ACL（Access Control List）** に定義したルールに従って ALLOW / BLOCK / COUNT のいずれかのアクションを下すマネージドファイアウォールです。  
CloudFront、Application Load Balancer、API Gateway、AppSync などのリソースにアタッチして使います。

---

## いつ使うか・使わないか

### 使うケース

| ユースケース | 理由 |
|---|---|
| 静的アセット（JS/CSS/画像）の配信 | エッジキャッシュで高速化、オリジン負荷削減 |
| API レスポンスの一部をキャッシュしたい | `Cache-Control` ヘッダを調整してキャッシュ制御可能 |
| S3 バケットを直接公開したくない | OAC（Origin Access Control）で S3 → CloudFront 経由のみに制限 |
| HTTPS を強制したい / TLS 終端をエッジで行いたい | CloudFront で ACM 証明書を使い TLS 終端 |
| SQLi / XSS / ボット攻撃を防ぎたい | WAF マネージドルールグループで既知パターンを一括ブロック |
| 特定 IP や国からのアクセスを制限したい | WAF の IP セット / Geo ブロックルール |
| API へのブルートフォースや DDoS を軽減したい | WAF レートベースルール |

### 使わないケース

- レイテンシより一貫性（強整合性）が優先される API — キャッシュがあると古いデータを返す可能性
- オリジンが動的かつキャッシュキーを設計しにくい場合 — キャッシュヒット率が上がらず CloudFront のコストが無駄になりやすい
- 単純な内部サービス間通信 — エッジ経由は不要、ALB や直接通信で十分

---

## コアコンセプト

### CloudFront

#### ディストリビューション

CloudFront の設定単位。1 つのディストリビューションに複数の **オリジン** と **ビヘイビア（behavior）** を持てます。

- **オリジン**: リクエストを転送する先（S3 バケット、API Gateway、ALB、カスタム HTTP サーバーなど）
- **ビヘイビア**: URL パスパターン（例: `/api/*`, `/*.js`）ごとにキャッシュポリシーやオリジンを切り替える設定

#### キャッシュの仕組み

```
ブラウザ → CloudFront エッジ
           ├── HIT  → エッジのキャッシュから即返却（オリジン通信なし）
           └── MISS → オリジンへ転送 → レスポンスをキャッシュ → ブラウザへ返却
```

キャッシュの有効期間（TTL）は以下の優先順で決まります。

1. CloudFront のキャッシュポリシーに設定した `Min TTL` / `Max TTL` / `Default TTL`
2. オリジンが返す `Cache-Control: max-age=N` ヘッダ
3. `Expires` ヘッダ

#### キャッシュキー

デフォルトは **URL（パス + クエリ文字列の一部）** のみ。  
ヘッダ・Cookie・クエリ文字列をキャッシュキーに含めると細分化できますが、ヒット率が下がるトレードオフがあります。

#### Invalidation（無効化）

キャッシュを強制的に削除する操作。`/*` でディストリビューション全体、`/api/submissions/*` で特定パス以下を無効化できます。  
月に 1,000 パス分は無料、以降は有料です。

### WAF

#### Web ACL とルール評価順序

```
リクエスト
  ↓
[ルール 1（優先度 0）] → BLOCK → 403 を返す  ←┐
  ↓ 一致しない                                    │ 優先度の数値が小さいほど先に評価
[ルール 2（優先度 1）] → COUNT → ログに記録のみ  │
  ↓ 一致しない                                    │
[ルール N（優先度 N-1）] ...                      │
  ↓ すべて一致しない                             │
デフォルトアクション（ALLOW or BLOCK）           ─┘
```

#### ルールタイプ

| ルールタイプ | 概要 |
|---|---|
| **マネージドルールグループ** | AWS または Marketplace ベンダーが管理する既知攻撃パターンのセット（AWSManagedRulesCommonRuleSet など） |
| **IP セットルール** | 指定 IP アドレス（CIDR）を ALLOW / BLOCK |
| **Geo マッチルール** | 国コードで ALLOW / BLOCK |
| **レートベースルール** | 5 分間（固定）ウィンドウ内のリクエスト数が閾値を超えた IP を自動ブロック |
| **正規表現パターンセット** | URL / ヘッダ / ボディを正規表現で検査 |
| **バイト一致ルール** | 特定文字列がフィールドに含まれるか検査（SQLi/XSS 検出に応用） |

#### スコープ

- **CLOUDFRONT**: us-east-1 に Web ACL を作成（グローバルエッジ向け）
- **REGIONAL**: リソースと同じリージョンに作成（ALB / API Gateway 向け）

---

## 主要な設定・API・パラメータ

### CloudFront ディストリビューション（主要フィールド）

| 設定項目 | 説明 |
|---|---|
| `Origins[].DomainName` | オリジンのドメイン（例: `myapi.execute-api.ap-northeast-1.amazonaws.com`） |
| `Origins[].OriginPath` | オリジンのベースパス（例: `/prod`） |
| `DefaultCacheBehavior.CachePolicyId` | キャッシュポリシーの ID。AWS 管理ポリシー `CachingOptimized` / `CachingDisabled` などが使える |
| `DefaultCacheBehavior.ViewerProtocolPolicy` | `redirect-to-https` / `https-only` / `allow-all` |
| `DefaultCacheBehavior.AllowedMethods` | `GET,HEAD` / `GET,HEAD,OPTIONS` / 全メソッド |
| `PriceClass` | 使用するエッジロケーションの範囲（`PriceClass_100`=米欧のみ安価、`PriceClass_All`=全世界） |
| `WebACLId` | アタッチする WAF Web ACL の ARN（スコープ CLOUDFRONT のみ） |

### WAF Web ACL（主要フィールド）

| 設定項目 | 説明 |
|---|---|
| `DefaultAction` | ルールに一致しなかった場合のデフォルト動作（`Allow` or `Block`） |
| `Rules[].Priority` | 評価順（0 が最優先） |
| `Rules[].Action` | `Allow` / `Block` / `Count` |
| `Rules[].Statement` | ルールの条件（`RateBasedStatement`, `IPSetReferenceStatement`, `GeoMatchStatement`, `ManagedRuleGroupStatement`, `ByteMatchStatement` など） |
| `VisibilityConfig.SampledRequestsEnabled` | サンプルリクエストのログ取得を有効化 |
| `VisibilityConfig.CloudWatchMetricsEnabled` | CloudWatch メトリクス出力 |

### レートベースルール ステートメント例

```json
{
  "RateBasedStatement": {
    "Limit": 100,
    "AggregateKeyType": "IP",
    "ScopeDownStatement": {
      "ByteMatchStatement": {
        "SearchString": "/api/",
        "FieldToMatch": { "UriPath": {} },
        "TextTransformations": [{ "Priority": 0, "Type": "NONE" }],
        "PositionalConstraint": "STARTS_WITH"
      }
    }
  }
}
```

`Limit` は 5 分間ウィンドウでの最大リクエスト数（最小値: 100）。

---

## よくある落とし穴・誤解

### CloudFront

**キャッシュが効かない**  
オリジンが `Cache-Control: no-store` や `no-cache` を返していると CloudFront はキャッシュしません。  
API Gateway はデフォルトで `Cache-Control: no-cache` を返す場合があるため、キャッシュしたい場合はビヘイビアの `CachingOptimized` ポリシーを使うか、レスポンスヘッダを明示的に制御します。

**WAF は us-east-1 に作る必要がある（CloudFront アタッチ時）**  
CloudFront 用 Web ACL のスコープは `CLOUDFRONT` で、必ず `us-east-1` リージョンに作成します。他リージョンに作ると CloudFront にアタッチできません。

**Invalidation はリアルタイムではない**  
無効化リクエスト送信後、全エッジへの伝播に数秒〜数十秒かかります。即時反映が保証されるわけではありません。

**クエリ文字列をキャッシュキーに含め忘れる**  
デフォルトのキャッシュポリシーはクエリ文字列を無視します。`?page=1` と `?page=2` が同じキャッシュを返すバグが起きやすいです。

### WAF

**レートベースルールの最小閾値は 100**  
`Limit` に 100 未満は設定できません。非常に小さな閾値でのブロックは別の方法（例: Lambda@Edge）が必要です。

**COUNT は止めない**  
`Count` アクションはマッチしてもリクエストを通します。本番ブロック前のテスト用途で使いますが、COUNT のままにし忘れると防御できていない状態になります。

**マネージドルールグループの誤検知**  
`AWSManagedRulesCommonRuleSet` などは稀に正常リクエストを誤ブロックします。最初は全ルールを `Count` モードで稼働させてログを確認してから `Block` に切り替えるのが安全です。

**WAF のコスト構造を見落とす**  
Web ACL 自体の固定費（$5/月）+ ルール数（$1/ルール/月）+ リクエスト数（$0.60/100 万リクエスト）。小規模でもルールを多数作ると固定費が積み上がります。

---

## このプロジェクト（AtCoder 復習）での使いどころ

AtCoder 復習ツールは Phase 1 の MVP 時点で以下の構成です。

```
ブラウザ → API Gateway → Lambda → DynamoDB
                ↑
           S3（フロントエンド静的ファイル）
```

Phase 5 ではこの前段に CloudFront + WAF を追加します。

| コンポーネント | 役割 |
|---|---|
| CloudFront ディストリビューション | S3（静的フロントエンド）と API Gateway（動的 API）を 1 つのドメインで統合。パスパターン `/api/*` → API GW、それ以外 → S3 |
| S3 OAC | S3 バケットをパブリック公開せず CloudFront 経由のみに制限 |
| WAF Web ACL（CLOUDFRONT スコープ） | `/api/sync_submissions` など重い処理へのレートリミット、不正 IP ブロック |
| キャッシュポリシー | `/api/submissions`（GET）は短い TTL でキャッシュし、DynamoDB 読み取り回数を削減 |

実装上のポイント：

- `terraform/modules/cloudfront/` モジュールを新設し、既存の `api_gateway` / `lambda` モジュールとオリジンを接続
- WAF は `us-east-1` プロバイダを Terraform で別エイリアス定義して作成
- レートベースルールの閾値は sync_submissions の想定ユーザー数から逆算（例: 1 ユーザー 1 操作なら 100 req/5 min で十分）

---

## デモで体験したこと

デモページ（`docs/learning/phase5/demo/index.html`）は 2 枚のカードで構成されています。

**カード 1 — CDN キャッシュ体験**  
エッジロケーションを選んでオブジェクトをリクエストすると、初回は「MISS」と表示され、オリジンへ往復した分の遅延（大きめの ms 値）が見えます。同じリクエストを再度送ると「HIT」となり、エッジキャッシュから返るため応答が高速になる様子が確認できます。TTL カウントダウンがゼロになると再び MISS に戻り、「無効化」ボタンで即座に MISS 状態に強制リセットできます。これにより **TTL とキャッシュキーの関係**、および **Invalidation の効果** を体感できます。

**カード 2 — WAF ルール体験**  
リクエストビルダーで path / クエリ / IP / 送信レートを組み合わせ、各ルール（レート制限・IP 許可拒否・SQLi/XSS パターン・Geo ブロック）をトグルしながら「送信」すると、ALLOW / BLOCK バッジと一致したルール名がログに表示されます。連打するとレートベースルールが発火して自動ブロックされ、**WAF のルール評価順序と優先度** の仕組みを手を動かしながら確認できます。

---

## 公式ドキュメント（出典）

- [What is Amazon CloudFront? — Amazon CloudFront 開発者ガイド](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Introduction.html)（閲覧日 2026-05-31）
- [Cache hit ratio の概念 — Amazon CloudFront 開発者ガイド](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cache-hit-ratio-explained.html)（閲覧日 2026-05-31）
- [What is AWS WAF? — AWS WAF 開発者ガイド](https://docs.aws.amazon.com/waf/latest/developerguide/what-is-aws-waf.html)（閲覧日 2026-05-31）
- [Rate-based rule statement — AWS WAF 開発者ガイド](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-rate-based.html)（閲覧日 2026-05-31）

---

## 関連・発展サービス

### OAC vs OAI — なぜ OAI はもう使わないべきか

OAI (Origin Access Identity) は CloudFront の旧来の S3 アクセス制御機構です。
IAM Principal が `arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity XXXX` という独自形式になり、IAM の標準的な Condition 記法が使えません。

OAC (Origin Access Control) は 2022 年 GA の後継で、以下の点で優れています。

| 観点 | OAI | OAC |
|---|---|---|
| 署名方式 | CloudFront 独自 | SigV4（IAM 標準） |
| SSE-KMS 対応 | 不可（SSE-S3 のみ） | 可 |
| 対応オリジン | S3 のみ | S3, MediaStore, Lambda Function URL 等 |
| AWS 推奨状況 | 非推奨（新規作成廃止予定） | 推奨 |

Terraform での OAC 設定と S3 バケットポリシーのセットがこの sandbox のコアです。
バケットポリシーで `Condition.StringEquals."AWS:SourceArn"` にディストリビューション ARN を指定することで、
「他人の CloudFront ディストリビューションを使って同じ S3 バケットを読み取る」という Confused Deputy 攻撃を防ぎます。

```hcl
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "phase5-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
```

---

### AWS Shield Standard vs Shield Advanced

CloudFront には DDoS 保護として Shield Standard が自動適用（無料）されています。

| | Standard | Advanced |
|---|---|---|
| 費用 | 無料（全 AWS リソースに自動適用） | $3,000/月 + DRP サポート |
| 保護レイヤ | L3/L4（SYN Flood, UDP Reflection 等） | L3/L4 + L7（HTTP Flood 自動緩和） |
| DDoS コスト保護 | なし | DDoS 起因のスケールアウトコストを AWS が負担 |
| SRT 対応 | なし | 24/7 Shield Response Team |
| WAF 連携 | なし | 異常トラフィック検出時に WAF Rate-based ルールを自動生成 |

CloudFront + WAF + Shield Advanced を組み合わせると、
WAF がルールベースのブロック、Shield Advanced が機械学習で異常を検出して WAF ルールを自動挿入するという多層防御になります。
Sandbox では Standard で十分ですが、本番サービスで SLA が求められる場合は Advanced を検討します。

---

### Lambda@Edge と CloudFront Functions の使い分け

CloudFront にはエッジコンピューティング機能が 2 種類あり、混同しやすいです。

| 観点 | CloudFront Functions | Lambda@Edge |
|---|---|---|
| 実行フェーズ | Viewer Request / Response のみ | Viewer + Origin Request / Response |
| ランタイム | JavaScript (ES5.1 / cloudfront-js-2.0) | Node.js, Python |
| 最大実行時間 | 1 ms | Viewer: 5 秒、Origin: 30 秒 |
| メモリ | 2 MB | 128 MB 〜 10 GB |
| コスト | $0.1 / 100 万回 | $0.6 / 100 万回 + 実行時間 |
| デプロイ先 | 全 450+ エッジロケーション | 13 リージョン（エッジではなくリージョナル PoP） |
| 主なユースケース | URL リライト、ヘッダ付与、A/B テスト | JWT 検証、動的 OG 生成、オリジン選択ロジック |

**CloudFront Functions でセキュリティヘッダを付与する最小実装**（extra-credit）:

```javascript
// functions/security-headers.js
async function handler(event) {
  const response = event.response;
  const headers  = response.headers;
  headers['strict-transport-security']  = { value: 'max-age=63072000; includeSubDomains; preload' };
  headers['x-content-type-options']     = { value: 'nosniff' };
  headers['x-frame-options']            = { value: 'DENY' };
  headers['content-security-policy']    = { value: "default-src 'self'; script-src 'self'" };
  headers['referrer-policy']            = { value: 'strict-origin-when-cross-origin' };
  return response;
}
```

Terraform では `aws_cloudfront_function` + `function_association { event_type = "viewer-response" }` で紐付けます。
`viewer-response` フェーズで付与するため、オリジンが返したヘッダを上書きできます。
Mozilla Observatory（`https://observatory.mozilla.org/analyze/YOUR_CF_DOMAIN.cloudfront.net`）でスコアを確認できます。

---

### Route 53 + ACM でカスタムドメインを付ける

CloudFront にカスタムドメインを付ける場合、ACM 証明書は **us-east-1 に作成しないと CF から使えません**（CF 専用の制約）。

```hcl
resource "aws_acm_certificate" "main" {
  provider          = aws.us_east_1  # 明示的に us-east-1 プロバイダを使う
  domain_name       = "sandbox.example.com"
  validation_method = "DNS"
}

resource "aws_route53_record" "cf" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "sandbox.example.com"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}
```

つまずきポイント: `aws_acm_certificate_validation` + `aws_route53_record` を組み合わせると DNS 検証レコードを自動作成できます。証明書ステータスが `ISSUED` になるまで `terraform apply` がブロックされるため、初回は 5〜10 分待ちます。

---

### API Gateway 前段に CloudFront を置く理由

「なぜ動的 API に CDN を前置するのか」と疑問に思うかもしれません。主な理由は 4 つあります。

1. **WAF の適用**: `scope = "CLOUDFRONT"` の Web ACL は、IP ごとのレート集計をエッジ（全世界）で行うため、REGIONAL（API GW 直付け）より攻撃を早期に遮断できます。
2. **GET 系レスポンスのキャッシュ**: `Cache-Control` を調整すれば `/api/submissions` 等をエッジキャッシュし、API GW スロットリングや Lambda / DynamoDB コストを削減できます。
3. **TLS ターミネーションの地理的分散**: ユーザーに最も近いエッジで TLS ハンドシェイクを終端することで TTFB が改善します。
4. **バックエンド URL の隠蔽**: `execute-api.ap-northeast-1.amazonaws.com` のような内部 URL を露出させず、カスタムドメイン配下に統一できます。

設定のポイント: CF Origin を API GW の `execute-api` エンドポイントに設定し、Cache Policy は `CachingDisabled` がデフォルト安全設定です。
`X-Forwarded-For` は CF が自動付与しますが、API GW 側で IP 制限したい場合は Lambda Authorizer で `event.headers['x-forwarded-for']` を参照します。

---

## セキュリティ課題と対策

### WAF マネージドルールグループの選び方と False Positive 対策

AWS が提供するマネージドルールグループは現在 15 種以上ありますが、全部有効にすると正常なリクエストもブロックされます。
安全な導入手順は以下のとおりです。

**導入フロー**:

1. **まず全ルールを `count` モードで 2 週間様子見する**: `override_action { count {} }` に設定
2. CloudWatch Logs Insights で `filter action="COUNT"` のログを調査して誤検知（False Positive）を特定する
3. 誤検知ルールを `rule_action_override` で `count` のまま残し、残りを `block` に切り替える

```hcl
managed_rule_group_statement {
  name        = "AWSManagedRulesCommonRuleSet"
  vendor_name = "AWS"

  rule_action_override {
    name          = "SizeRestrictions_BODY"
    action_to_use { count {} }
    # ファイルアップロード API がある場合に body サイズ制限でブロックされるのを回避
  }
  rule_action_override {
    name          = "GenericRFI_BODY"
    action_to_use { count {} }
    # 一部の正規パラメータが RFI 判定される場合
  }
}
```

**よく使うマネージドルールグループと費用**:

| グループ名 | 目的 | 追加費用 |
|---|---|---|
| AWSManagedRulesCommonRuleSet | OWASP Top 10 全般（SQLi, XSS, LFI 等） | 無料 |
| AWSManagedRulesBotControlRuleSet | Bot 検知（Crawler, Scanner, 著名 Bot） | $10 / 100 万 WCU |
| AWSManagedRulesKnownBadInputsRuleSet | Log4Shell, Spring4Shell 等の既知 exploit | 無料 |
| AWSManagedRulesAmazonIpReputationList | AWS が把握している悪評 IP | 無料 |
| AWSManagedRulesAnonymousIpList | Tor, VPN, Proxy | 無料 |

**WCU (Web ACL Capacity Unit) の上限に注意**: Web ACL のデフォルト上限は 1,500 WCU。
CommonRuleSet は 700 WCU を消費するため、複数グループを同時有効化すると quota 超過エラーになることがあります。
上限緩和は Service Quotas から申請できますが、Sandbox では CommonRuleSet + rate-based のみで十分です。

---

### レートベースルールの粒度設計

`aggregate_key_type` によって「誰に対してレートを計算するか」が変わります。

| キー | 説明 | 注意点 |
|---|---|---|
| `IP` | 送信元 IP ごと | NAT 経由の企業ユーザーを誤ブロックしやすい |
| `FORWARDED_IP` | `X-Forwarded-For` の最初の IP | 偽装可能。信頼できるプロキシからのみ使う |
| `HTTP_HEADER` | カスタムヘッダ値ごと | API キーごとにレート制限したい場合 |
| `CUSTOM_KEYS` | 複数フィールドの組み合わせ | 「この API だけに厳しい制限」など |

`scope_down_statement` を使って特定パスにだけレートリミットを絞るのが実運用の常套手段です。

```hcl
rate_based_statement {
  limit              = 100  # 5 分で 100 リクエスト
  aggregate_key_type = "IP"
  scope_down_statement {
    byte_match_statement {
      field_to_match { uri_path {} }
      positional_constraint = "STARTS_WITH"
      search_string         = "/api/login"
      text_transformations { priority = 0; type = "LOWERCASE" }
    }
  }
}
```

`/api/login` への攻撃（クレデンシャルスタッフィング）は集中しやすく、かつ正規ユーザーの頻度は低いため、
全 URL に適用するよりも `/api/login` だけ閾値 100 に絞る方が誤ブロックを減らせます。

---

### 署名付き URL / 署名付き Cookie

プレミアムコンテンツや期限付きダウンロードリンクなど、S3 オブジェクトへの時限アクセスを付与したい場合に使います。

- **署名付き URL**: URL ごとに `Expires`（UNIX タイム）と `CloudFront-Signature` を付与。1 ファイルへの一時アクセスに適します。
- **署名付き Cookie**: `CloudFront-Policy`, `CloudFront-Signature`, `CloudFront-Key-Pair-Id` の 3 クッキーを Set-Cookie。HLS 動画配信など複数ファイルへのアクセスに向きます。

2022 年以降、ルートアカウントのキーペアは非推奨です。
`aws_cloudfront_key_group` + `aws_cloudfront_public_key` で管理し、Lambda で署名を生成するのが現代的な設計です。

```python
# Lambda で署名付き URL を生成する例（botocore 使用）
from botocore.signers import CloudFrontSigner
import rsa, datetime

def rsa_signer(message):
    private_key = get_private_key_from_secrets_manager()  # Secrets Manager から取得
    return rsa.sign(message, rsa.PrivateKey.load_pkcs1(private_key), 'SHA-1')

signer = CloudFrontSigner(key_id, rsa_signer)
url = signer.generate_presigned_url(
    f"https://{DIST_DOMAIN}/premium/video.mp4",
    date_less_than=datetime.datetime.utcnow() + datetime.timedelta(hours=1)
)
```

---

### TLS ポリシーの選定と PCI DSS 要件

CloudFront の `minimum_protocol_version` で選択できる主なポリシーです。

| ポリシー名 | 最小 TLS | 対応クライアント | 推奨用途 |
|---|---|---|---|
| TLSv1.2_2021 | TLS 1.2 | IE 11+, Android 5+ | **新規サービスの標準** |
| TLSv1.2_2019 | TLS 1.2 | 旧 Java 等 | 互換性が必要な場合 |
| TLSv1.2_2018 | TLS 1.2 | より広い旧クライアント | 移行期 |
| TLSv1_2016 | TLS 1.0 | 非常に古いクライアント | 非推奨 |

`TLSv1.2_2021` は Cipher Suite でも ECDHE のみ許可し、Forward Secrecy が弱い DHE を排除しています。
PCI DSS 準拠要件がある場合は `TLSv1.2_2021` 一択です。
この sandbox では `cloudfront_default_certificate = true` のためデフォルト証明書を使っており、
カスタムドメインで ACM 証明書を使う場合に初めてこのポリシーが適用可能になります。

---

### Geo ブロック: CF の `geo_restriction` vs WAF の `geo_match_statement`

CloudFront の `geo_restriction` ブロックは「完全ブロック」で、カスタムエラーページも返せません（403 固定）。

WAF の Geo Match Statement を使うと以下が可能です。

1. 特定国からのリクエストを `count` で監視しながらブロック（段階的な移行）
2. ヘッダに国コードを付与して Lambda でビジネスロジックに使う
3. 「この国からは `/api/*` だけ許可し、他はブロック」という細かい制御

```hcl
statement {
  geo_match_statement {
    country_codes = ["CN", "RU", "KP"]  # ISO 3166-1 alpha-2
  }
}
```

CloudFront は `CloudFront-Viewer-Country` ヘッダをオリジンに転送する機能もあります
（Origin Request Policy に `CloudFront-Viewer-Country` を追加）。
Lambda 側でも地理情報を参照したい場合はこれを使います。

---

## インフラ応用パターン

### キャッシュ戦略と HIT 率の最大化

CloudFront のキャッシュは `Cache-Control` ヘッダと CF の TTL 設定の小さい方が適用されます。
HIT 率を上げるカギは **キャッシュキーの設計**です。

デフォルトでは URL（Host + Path）がキャッシュキーですが、Query String や Cookie が違うと別キャッシュになります。
これを制御するのが **Cache Policy** です。

```hcl
resource "aws_cloudfront_cache_policy" "api_cache" {
  name        = "api-cache-policy"
  min_ttl     = 0
  default_ttl = 60
  max_ttl     = 300

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config    { cookie_behavior = "none" }      # Cookie はキャッシュキーに含めない
    headers_config    { header_behavior = "none" }      # ヘッダも含めない
    query_strings_config {
      query_string_behavior = "whitelist"
      query_strings { items = ["sort", "filter"] }      # この QS のみキャッシュキーに含める
    }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}
```

**HIT 率向上のチェックリスト**:

- 不要な Query String、Cookie を Cache Policy から除外する
- `compress = true` で Brotli/gzip 圧縮を有効化する
- ファイル名にコンテンツハッシュを埋め込む（`main.abc123.js`）。TTL を長期設定しても Invalidation 不要になる
- S3 のレスポンスヘッダに `Cache-Control: public, max-age=31536000, immutable` を設定する
- `CacheHitRate` メトリクスを継続監視する。60% 未満なら設計を見直す

**Invalidation を最小化する設計**:

1. **ファイル名にコンテンツハッシュ**: `main.abc123.js` → 更新のたびにファイル名が変わるため Invalidation 不要。`index.html` のみ短い TTL に設定。
2. **バージョンプレフィックス**: `/v1.2.3/app.js` → 新バージョンは新しいパスになる。
3. **S3 バージョニングとの組み合わせ**: バージョニング有効で rollback を容易にする。

Invalidation は月 1,000 パスまで無料ですが、`/*` を実行すると全エッジキャッシュが消去されオリジンへの負荷スパイクが発生します。
本番では `/updated-path/*` などに絞ることを推奨します。

---

### オリジンフェイルオーバー（Origin Failover）

CloudFront の Origin Group を使うと、プライマリオリジンが 5xx を返した場合にセカンダリに自動フェイルオーバーできます。

```hcl
resource "aws_cloudfront_distribution" "main" {
  origin {
    domain_name = "primary.example.com"
    origin_id   = "primary"
  }
  origin {
    domain_name = "secondary.example.com"
    origin_id   = "secondary"
  }

  origin_group {
    origin_id = "failover-group"
    failover_criteria {
      status_codes { items = [500, 502, 503, 504] }
    }
    member { origin_id = "primary" }
    member { origin_id = "secondary" }
  }

  default_cache_behavior {
    target_origin_id = "failover-group"
  }
}
```

**実運用の注意点**:

- フェイルオーバーは GET / HEAD の **キャッシュミス時のみ**発生します。POST 等の非べき等リクエストには効きません。
- フェイルオーバー先が同じリージョンにあると AZ 障害で両方落ちます。セカンダリは別リージョンか S3 静的エラーページを指定するのが常套手段です。

---

### マルチオリジン構成: パスベースルーティング

`ordered_cache_behavior` を使うと URL パスごとにオリジンを切り替えられます。
SPA + API を 1 ドメインで統一するための典型的パターンです。

```hcl
# /api/* → API Gateway（キャッシュ無効）
ordered_cache_behavior {
  path_pattern           = "/api/*"
  target_origin_id       = "api-gateway-origin"
  viewer_protocol_policy = "redirect-to-https"
  cache_policy_id        = data.aws_cloudfront_cache_policy.caching_disabled.id
  allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
  cached_methods         = ["GET", "HEAD"]
}

# /static/* → S3（長期キャッシュ）
ordered_cache_behavior {
  path_pattern     = "/static/*"
  target_origin_id = "s3-origin"
  cache_policy_id  = aws_cloudfront_cache_policy.long_cache.id
  allowed_methods  = ["GET", "HEAD"]
  cached_methods   = ["GET", "HEAD"]
}

# /* → S3 SPA（短期キャッシュ）
default_cache_behavior {
  target_origin_id = "s3-origin"
}
```

**つまずきポイント**:

1. **SPA の React Router で `/app/dashboard` にアクセスすると S3 が 403 を返す**
   → CF の `custom_error_response` で 403/404 を `index.html` に書き換える

   ```hcl
   custom_error_response {
     error_code            = 403
     response_code         = 200
     response_page_path    = "/index.html"
     error_caching_min_ttl = 10
   }
   ```

2. **API GW のオリジンに `Host` ヘッダを転送するとドメイン不一致エラー**
   → Origin Request Policy で `Host` ヘッダを除外する

---

### Real-Time Logs と Kinesis Firehose によるアクセス解析基盤

標準ログ（S3 への 5〜10 分遅延バッチ）では不十分な場合、Real-Time Logs を使います。

```
CloudFront → Kinesis Data Stream → Kinesis Firehose → S3 → Athena
                                                     → OpenSearch
```

```hcl
resource "aws_cloudfront_realtime_log_config" "main" {
  name          = "phase5-realtime"
  sampling_rate = 10  # 10% サンプリング（本番は 1〜5% で十分なことが多い）

  endpoint {
    kinesis_stream_config {
      role_arn   = aws_iam_role.cf_realtime_log.arn
      stream_arn = aws_kinesis_stream.cf_logs.arn
    }
    stream_type = "Kinesis"
  }

  fields = [
    "timestamp", "c-ip", "sc-status", "cs-uri-stem",
    "x-edge-location", "cs(User-Agent)", "x-host-header"
  ]
}
```

Athena でエッジロケーション別エラー数を集計するクエリ例:

```sql
SELECT
  date_trunc('hour', from_unixtime(timestamp)) AS hour,
  x_edge_location,
  COUNT(*) AS requests,
  SUM(CASE WHEN sc_status >= 500 THEN 1 ELSE 0 END) AS errors
FROM cf_logs
WHERE dt >= '2025-05-01'
GROUP BY 1, 2
ORDER BY 1, 3 DESC;
```

フィールドを絞るほど Kinesis のコストが下がります。全フィールドを有効にすると想定外のコストになるため注意してください。

---

### Terraform の state 管理と CF の apply / destroy 時間問題

CF のリソースは apply に 10〜15 分、destroy に 30〜45 分かかります。
`sandbox-down` でタイムアウトする原因になることがあるため、以下の手順を推奨します。

```bash
# destroy の安全な実行手順
cd terraform/sandboxes/phase5

# 1. destroy 開始（30〜45 分かかる。バックグラウンド実行を推奨）
terraform destroy -auto-approve &

# 2. 完了を確認
aws cloudfront wait distribution-deployed --region us-east-1 \
  --id $(terraform output -raw cloudfront_distribution_id 2>/dev/null || echo "ALREADY_DELETED")

# 3. WAF ロググループが残っていないか確認
aws logs describe-log-groups --region us-east-1 \
  --log-group-name-prefix "aws-waf-logs-phase5" \
  --query 'logGroups[].logGroupName'

# 4. KMS キー（extra-credit 使用時）は削除に 7 日の待機期間あり
aws kms list-keys --region us-east-1
```

CF を `enabled = false` に変更してから destroy すると若干速くなるという説もありますが、
実測値は変わらないことが多いです。潔く待つのが正解です。
