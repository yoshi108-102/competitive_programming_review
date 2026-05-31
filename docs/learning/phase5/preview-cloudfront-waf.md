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
