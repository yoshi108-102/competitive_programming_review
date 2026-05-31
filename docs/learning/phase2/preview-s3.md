# Phase 2 プレビュー教材: S3 — オブジェクトストレージを触ってみる

> プレビュー教材: デモ体験のために先行生成しました。正式な lesson / 振り返りクイズ / 採点は Phase 2 到達時に実施します。

---

## このサービスは何か

Amazon S3（Simple Storage Service）は、AWS のオブジェクトストレージサービスです。データを **オブジェクト** 単位で保存し、各オブジェクトは次の 3 要素で構成されます。

| 要素 | 内容 |
|------|------|
| **キー** | バケット内で一意な文字列（例: `submissions/2026/abc.json`） |
| **本体（データ）** | 最大 5 TB のバイト列 |
| **メタデータ** | Content-Type / ETag / ストレージクラス / Last-Modified など |

S3 はファイルシステム（POSIX）でも ブロックデバイス（EBS）でもありません。オブジェクトは **丸ごと PUT/GET** が基本操作であり、一部分だけを書き換える（部分更新）はできません（バイト範囲 GET による部分読み込みは可能）。

---

## いつ使うか・使わないか

### 使うべきケース
- 静的ファイル（HTML / JS / CSS / 画像）のホスティング
- Lambda や EC2 から参照するアーティファクト（ZIP / JSON / CSV）の保存
- ログ・バックアップ・データレイクの中間ストレージ
- CloudFront のオリジンとして CDN コンテンツを配信
- プリサインド URL による短期間の安全なファイル共有

### 使わないケース
- ミリ秒以下のレイテンシが必要なランダム I/O → EBS / ElastiCache
- トランザクションや SQL クエリが必要 → RDS / DynamoDB
- POSIX ファイルシステムが必要（`ls`, `chmod` など）→ EFS

---

## コアコンセプト

### 1. バケットとキー空間

S3 のキー空間は **フラット**（階層なし）です。スラッシュ `/` はキーの一部の文字列であり、ディレクトリではありません。

```
バケット: atcoder-review-artifacts
  └── キー: submissions/2026/abc.json   ← スラッシュは単なる文字
  └── キー: submissions/2026/def.json
  └── キー: exports/report.csv
```

マネジメントコンソールや SDK では `Prefix` パラメータを指定してスラッシュ手前までを「擬似フォルダ」として扱えますが、実体はすべて同一の平坦なキー空間に存在します。

### 2. 強整合性モデル（read-after-write）

2020 年末以降、S3 はすべての操作（PUT / DELETE / LIST）で **強整合性** を保証します。

- オブジェクトを PUT した直後に GET すると、必ず最新データが返る
- LIST も PUT 直後に反映される（以前の結果整合とは異なる）

キャッシュや再試行ループを設けなくてもデータの一貫性が担保されるため、ワークフローが簡素化されます。

### 3. プリサインド URL

S3 のオブジェクトに一時的にアクセスさせたい場合、IAM 認証情報を相手に渡す代わりに **署名付き URL（Presigned URL）** を発行します。

```
https://BUCKET.s3.amazonaws.com/KEY
  ?X-Amz-Algorithm=AWS4-HMAC-SHA256
  &X-Amz-Credential=...
  &X-Amz-Date=...
  &X-Amz-Expires=3600        ← TTL（秒）
  &X-Amz-Signature=...
```

- URL を知っている人だけが、指定した TTL の間だけアクセスできる
- 発行者の IAM 権限を超えたアクセスは許可されない
- PUT 用プリサインド URL も発行可能（フロントエンドから直接 S3 へアップロード）

### 4. ストレージクラス

| クラス | 用途 | 取り出しコスト | 取り出し時間 |
|--------|------|---------------|-------------|
| S3 Standard | 頻繁にアクセスするデータ | なし | ミリ秒 |
| S3 Standard-IA | 低頻度アクセス、長期保存 | あり（GB 単位） | ミリ秒 |
| S3 Glacier Instant Retrieval | アーカイブ、即時取り出し | あり（高め） | ミリ秒 |
| S3 Glacier Flexible Retrieval | アーカイブ | あり | 分〜時間 |
| S3 Glacier Deep Archive | 長期アーカイブ | あり（最高） | 12 時間〜 |

Standard-IA は保存コストが安い反面、取り出しのたびに料金が発生します。取り出し頻度が月 1 回未満程度のデータに適しています。

---

## 主要な設定・API・パラメータ

### バケット作成時の主要パラメータ

| パラメータ | 説明 |
|-----------|------|
| `BucketName` | グローバル一意な名前（3〜63 文字、小文字） |
| `Region` | バケットのリージョン（後から変更不可） |
| `BlockPublicAccess` | パブリックアクセスのブロック設定（デフォルト: 全ブロック） |
| `Versioning` | オブジェクトのバージョン管理（有効化すると削除マーカーが付く） |
| `ServerSideEncryption` | 暗号化（SSE-S3 / SSE-KMS / SSE-C） |

### 主要 API（boto3 例）

```python
import boto3
s3 = boto3.client("s3")

# アップロード
s3.put_object(
    Bucket="atcoder-review-artifacts",
    Key="submissions/2026/abc.json",
    Body=b'{"status": "AC"}',
    ContentType="application/json",
    StorageClass="STANDARD",
)

# ダウンロード
response = s3.get_object(
    Bucket="atcoder-review-artifacts",
    Key="submissions/2026/abc.json",
)
data = response["Body"].read()

# プリサインド URL 発行
url = s3.generate_presigned_url(
    "get_object",
    Params={"Bucket": "atcoder-review-artifacts", "Key": "submissions/2026/abc.json"},
    ExpiresIn=3600,  # 秒
)

# プリフィックスで一覧
paginator = s3.get_paginator("list_objects_v2")
for page in paginator.paginate(Bucket="atcoder-review-artifacts", Prefix="submissions/2026/"):
    for obj in page.get("Contents", []):
        print(obj["Key"], obj["Size"])
```

### ListObjectsV2 vs ListObjects

`ListObjects`（v1）は非推奨です。常に `ListObjectsV2` を使用してください。大量オブジェクトがある場合は Paginator を使い、`ContinuationToken` を自動処理させます。

---

## よくある落とし穴・誤解

### 1. 「フォルダ」は存在しない

コンソール上でフォルダのように見えても、S3 に「ディレクトリ」の概念はありません。`submissions/` というキーのオブジェクトが存在しても、それは 0 バイトの「プレースホルダー」オブジェクトです。プリフィックスで絞り込む設計を意識してください。

### 2. バケット名はグローバル一意

バケット名は AWS 全アカウントを通じて一意です。自分のアカウントで削除した名前を他のアカウントが取得する可能性があります。機密情報をバケット名に含めないよう注意してください。

### 3. Standard-IA の最小保存期間

Standard-IA は **30 日未満** の保存でも 30 日分の料金が発生します。短命なデータに IA を使うと逆にコスト高になります。

### 4. プリサインド URL と ACL

バケットに `BlockPublicAccess` が有効でも、プリサインド URL は IAM ポリシーの許可があれば機能します。ただし URL の漏洩に注意が必要です。TTL は最小限に設定してください。

### 5. リージョン外通信コスト

Lambda と S3 が同一リージョンであればデータ転送料は無料です。クロスリージョンアクセスは転送コストが発生します。

---

## このプロジェクト（AtCoder 復習）での使いどころ

| ユースケース | キー設計例 |
|-------------|-----------|
| AC コードのアーカイブ | `codes/{user}/{contest}/{problem}.py` |
| 提出履歴の JSON スナップショット | `submissions/{user}/{date}.json` |
| 静的フロントエンドのホスティング | `index.html`, `_next/static/...` |
| Lambda デプロイパッケージの保存 | `lambda-artifacts/{function}/{version}.zip` |

Phase 1 では DynamoDB に提出データを保存しましたが、**コードの生文字列（数 KB〜数十 KB）** は DynamoDB の 400 KB アイテム制限に引っかかる恐れがあります。S3 にコード本体を置き、DynamoDB には S3 キーだけを持たせる **参照パターン** が自然な設計です。

また、フロントエンドを S3 + CloudFront で配信すれば API Gateway / Lambda の実行コストをゼロにできる部分もあります（静的アセット限定）。

---

## デモで体験したこと

`docs/learning/phase2/demo/index.html` のバケットエクスプローラでは、疑似ファイルを「アップロード」すると `submissions/2026/abc.json` のようなキーで一覧に追加されます。オブジェクトをクリックするとキー / サイズ / Content-Type / ETag / Last-Modified などのメタデータが表示され、S3 の「オブジェクト = キー + メタデータ + 本体」という構造を視覚的に確認できます。

プリフィックスの擬似フォルダ表示では、スラッシュ区切りのキーがフォルダのように見えても実体はフラットなキー空間であることが図示されており、「フォルダは存在しない」というコアコンセプトを直感的に理解できます。

プリサインド URL のデモでは TTL スライダーで有効期限を設定して URL を発行し、期限切れ後に「ダウンロード」を押すと 403 エラー（`.badge.err`）になることを確認できます。これにより、署名付き URL の「一時的な認可」という性質が体感できます。

ストレージクラスのトグルでは Standard / Standard-IA / Glacier を切り替えてコストと取り出し時間のトレードオフを比較表示で確認でき、ユースケースに応じたクラス選択の判断軸を養えます。

---

## 公式ドキュメント（出典）

- [Amazon S3 とは — ユーザーガイド](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html)（閲覧日 2026-05-31）
- [プリサインド URL を使用したオブジェクトの共有](https://docs.aws.amazon.com/AmazonS3/latest/userguide/ShareObjectPreSignedURL.html)（閲覧日 2026-05-31）
- [S3 ストレージクラスの使用](https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html)（閲覧日 2026-05-31）
- [Amazon S3 強整合性モデル](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel)（閲覧日 2026-05-31）

---

## 🧭 関連・発展サービス

### S3 Event Notification の 4 経路と使い分け

ObjectCreated をトリガーにする方法は Lambda への直接通知だけではない。「失敗時の挙動」と「ファンアウト可否」で経路を選ぶ。

```
ObjectCreated
      │
      ├─(1)─→ Lambda              — 最速、非同期呼び出し（失敗時 S3 は再試行しない）
      ├─(2)─→ SQS Standard Queue  — バッファあり。Lambda の DLQ と組み合わせて再処理
      ├─(3)─→ SNS Topic           — ファンアウト。SNS→SQS×複数 や SNS→Lambda×複数
      └─(4)─→ EventBridge         — ルール/フィルタ/アーカイブ/リプレイが使える
```

**Lambda 直接通知のつまずき**: S3 は非同期でイベントを送るため、Lambda がエラーを返しても S3 は「成功」として扱う。大量 PUT が短時間に集中すると Lambda が詰まり、古いイベントは **最大 6 時間後** にリトライされる。ワーカー数が重要なユースケースでは SQS を間に挟んで `VisibilityTimeout` でフロー制御するべき。

**EventBridge を選ぶ理由**: バケット側の通知設定を変えなくても **アカウント内全バケットのイベントを受け取れる**（CloudTrail S3 データイベントと連携）。EventBridge ルールでキーの prefix/suffix や metadata でフィルタし、複数ターゲットに並列配信できる。Step Functions のターゲット指定も可能で、ワークフローオーケストレーションに直結できる。

---

### S3 Object Lambda — GetObject をインターセプトして変換

通常の S3 バケットの前に Lambda を挟み、クライアントには S3 の URL のまま変換後データを返すサービス。

```
クライアント
  → S3 Object Lambda Access Point
    → Lambda（PII マスキング / 画像リサイズ / CSV→JSON 変換など）
      → 元バケット（SSE-KMS）
```

元データを書き換えずに、利用者ごとに異なるビューを提供できる。社内データレイクに PII が混在しているとき、Analytics チームには自動マスキングした行を返す Access Point を発行する、というのが典型的なユースケース。バケットを複製せずに済むのでコスト効率がよい。

---

### S3 Select / Athena — オブジェクト内を SQL で絞り込む

| | S3 Select | Athena |
|---|---|---|
| 対象 | 単一オブジェクト内の SQL | 複数オブジェクト（Glue カタログ） |
| フォーマット | CSV / JSON / Parquet | Parquet / ORC / JSON / CSV など |
| コスト | スキャンバイト課金 | スキャン $5/TB |
| 主な使い所 | Lambda 内で大きな CSV の一部を取得 | データレイク分析 |

**Athena のつまずき**: `CREATE TABLE` で `LOCATION` を s3:// にする際、**末尾スラッシュが必須**。`s3://bucket/prefix/` ← これがないと全バケットをスキャンしてコストが爆発することがある。パーティション射影（Partition Projection）を使うと Glue Crawler のクロールコストが消え、クエリ応答速度も上がる。

---

### S3 Access Points — チーム・アプリごとにバケットアクセスを分離

バケットポリシーに全チームの許可をまとめて書くとポリシーが肥大化する。Access Points を使うと、チームやアプリごとに別個のエンドポイントと IAM ポリシーを管理できる。

```hcl
resource "aws_s3_access_point" "analytics" {
  name   = "analytics-ap"
  bucket = aws_s3_bucket.main.id
  public_access_block_configuration {
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }
}
```

VPC 限定 Access Point（VPC Origin）にすると VPC 外からのアクセスを完全にブロックでき、インターネット経由アクセスを禁止したい本番ワークロードに有効。

---

### ライフサイクル設計の実務パターン

```
Day 0    STANDARD              — 高アクセス。読み書きコスト最小
Day 30   STANDARD_IA           — アクセス頻度が落ちたら。取り出しコストが発生することに注意
Day 90   GLACIER_IR            — 数ミリ秒で取り出せるアーカイブ
Day 180  GLACIER               — 数時間かかるが安い。バックアップ/コンプライアンス保管
Day 365  DEEP_ARCHIVE / 削除   — 最安（$0.00099/GB/月）。7 年保管の規制要件向け
```

**Intelligent-Tiering を選ぶ場面**: アクセスパターンが予測不能なユーザー生成コンテンツ向け。監視コスト $0.0025/1,000 objects/月で、アクセス頻度に応じて Frequent/Infrequent/Archive を自動切替する。ただし 128KB 未満の小オブジェクトは常に Frequent に留まるため、ログの断片など小オブジェクトが大量にある場合は不向き。

---

### Cross-Region Replication (CRR) — DR とデータ主権

DR・レイテンシ低減・データ主権対応。ソースとデスティネーションの両方で Versioning が必須。

```hcl
resource "aws_s3_bucket_replication_configuration" "main" {
  role   = aws_iam_role.replication.arn
  bucket = aws_s3_bucket.main.id
  rule {
    id     = "replicate-all"
    status = "Enabled"
    destination {
      bucket        = aws_s3_bucket.replica.arn
      storage_class = "STANDARD_IA"  # DR バケットはコスト最適に
    }
  }
}
```

**つまずき**: CRR は **設定後の PUT だけが対象**。既存オブジェクトは複製されない。既存を複製するには `aws s3 sync` か S3 Batch Operations で `CopyObject` を走らせる。SSE-KMS バケットを複製する場合、デスティネーションリージョン用 KMS キーを別途作り、IAM ロールに `kms:ReplicateKey` 権限を付与する必要がある。

---

## 🛡 セキュリティ課題と対策

### Block Public Access の 4 フラグを正しく理解する

「Block Public Access を全部有効にした」で安心するのは早計。フラグごとに守れる範囲が違う。

| フラグ | 効果 |
|---|---|
| `block_public_acls` | 新規 ACL での public 付与をブロック |
| `ignore_public_acls` | 既存の public ACL を無視（既に public でも読ませない） |
| `block_public_policy` | `aws:PrincipalOrgID` なしの public バケットポリシーをブロック |
| `restrict_public_buckets` | 既存の public ポリシーを持つバケットへの匿名アクセスを制限 |

**全部 true でも防げないもの**: クロスアカウントの IAM ロールからのアクセスは Block Public Access の対象外。バケットポリシーで別アカウントの Principal を許可していれば普通に通る。これが実際のインシデントで多い誤解のパターン。

---

### バケットポリシー vs ACL — ACL は 2023 年以降レガシー

AWS は 2023 年以降、新規バケットのデフォルトを `ObjectOwnership=BucketOwnerEnforced`（ACL 無効）にした。バケットポリシーに一元化することで CloudTrail の監査ログが一本化され、インシデント調査が楽になる。

**公開バケット流出インシデントの典型パターン**

1. **設定ドリフト**: Terraform 管理外で手動変更 → Block Public Access が外れる
2. **プリサインド URL のログ漏洩**: `--debug` モードで URL がログに出力され、CloudWatch Logs Insights から誰でも検索できてしまう
3. **ワイルドカード Principal の Condition 誤記**: `Principal: "*"` に `Condition` で制限するつもりが Condition の `StringEquals` の演算子をミスして全公開になる
4. **古い SDK の ACL コード**: `ACL: public-read` を指定したコードが CI でそのままデプロイされ続ける

---

### SSE-S3 vs SSE-KMS vs CSE の選択基準

| | SSE-S3 | SSE-KMS | CSE（クライアント側） |
|---|---|---|---|
| 鍵管理 | AWS が管理 | CMK（ユーザー管理） | ユーザーが完全管理 |
| CloudTrail に復号ログ | No | Yes（`kms:Decrypt` が記録される） | N/A |
| コスト | 無料 | KMS API 課金（$0.03/10k calls） | ライブラリコスト |
| Bucket Key 対応 | 非対応 | 対応（API コール ~99% 削減） | N/A |
| 規制要件（PCI/HIPAA） | 多くは OK | 監査証跡が強い | 最強だが運用が重い |

**Bucket Key の重要性**: SSE-KMS 有効バケットで大量 PUT すると KMS API コールが爆発し、デフォルトクォータ（10,000 req/s/リージョン）に達してスロットリングされることがある。`bucket_key_enabled = true` は必須設定と覚えておく。本 sandbox の `main.tf` でも設定済み。

---

### アクセスログ vs CloudTrail データイベント — 目的で使い分ける

**S3 アクセスログ**

- S3 が独自フォーマットで別バケットに書く。到達に数分〜数時間の遅延。ベストエフォート（消える可能性あり）
- Athena でクエリ可能。コストは追加 0（配信先バケットの保存コストのみ）
- 分析・統計・ビリング調査向き

**CloudTrail データイベント**

- イベント単位で確実に記録。EventBridge と連携してリアルタイムアラートを作れる
- コスト $0.10/100k イベント
- インシデント対応・コンプライアンス監査向き

```hcl
# CloudTrail でデータイベントを有効化する場合
resource "aws_cloudtrail" "s3_data" {
  name           = "phase2-s3-data-events"
  s3_bucket_name = aws_s3_bucket.logs.id

  event_selector {
    read_write_type           = "All"
    include_management_events = false  # データイベントだけに絞る（コスト節約）

    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.main.arn}/"]
    }
  }
}
```

---

### VPC Gateway Endpoint — NAT Gateway コストとインターネット経由を排除

Lambda や EC2 が VPC 内にある場合、S3 へのアクセスは Internet Gateway → NAT Gateway 経由になりがち。NAT Gateway のデータ処理コストは **$0.045/GB**（東京リージョン）で、大量転送があると馬鹿にならない。S3 用の Gateway Endpoint は **無料**で使えるので入れない理由がない。

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"  # S3/DynamoDB は Gateway 型（無料）

  route_table_ids = [aws_route_table.private.id]
}
```

Gateway Endpoint を経由させた上でバケットポリシーに `aws:sourceVpce` 条件を付けると、VPC エンドポイント経由以外のアクセスをバケット側で拒否できる。

```json
{
  "Condition": {
    "StringEquals": {
      "aws:sourceVpce": "vpce-xxxxxxxxxxxxxxxxx"
    }
  }
}
```

**つまずき**: Lambda が複数サブネットにまたがる場合、**全サブネットのルートテーブル** に Gateway Endpoint エントリを追加しないと、サブネットによって動いたり動かなかったりする。Terraform の `route_table_ids` に配列で渡すのを忘れずに。

---

### プリサインド URL の期限と漏洩対策

プリサインド URL は署名した IAM エンティティの権限で動く。**IAM ロールで署名した場合の有効期限は最大 1 時間**（STS 一時認証情報の制限）。IAM ユーザーで署名すると最大 7 日だが、IAM ユーザーを削除しても署名済み URL は期限まで使えてしまう。

**漏洩対策の実務パターン**

1. 有効期限は用途に応じて最短に（ダウンロードリンクは 5 分など）
2. Lambda で URL 生成する際、ログに URL 本体を出力しない（`--debug` も禁止）
3. CloudFront + Signed URL/Cookies に置き換えると CloudFront ディストリビューション側で即時無効化できる
4. アクセスログを Athena でクエリして「どの IP が URL を使ったか」を追跡できるようにしておく

---

## 🏗 インフラ応用パターン

### 静的サイト + CloudFront OAC（Origin Access Control）

S3 の静的ウェブサイトホスティングをバケット直公開するのは最もやってはいけない構成。現在の標準は **CloudFront + OAC**。

```
クライアント
  → CloudFront（HTTPS、WAF 統合可）
    → OAC（署名付きリクエスト）
      → S3 バケット（Block Public Access 有効のまま）
```

OAC は旧 OAI（Origin Access Identity）の後継で、**SSE-KMS バケットにも対応**している（OAI は SSE-KMS 未対応）。CloudFront が `s3:GetObject` を KMS で復号するには、CloudFront のサービスプリンシパルを KMS キーポリシーに追加する必要がある。

```hcl
resource "aws_cloudfront_distribution" "frontend" {
  origin {
    domain_name              = aws_s3_bucket.main.bucket_regional_domain_name
    origin_id                = "S3Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3Origin"
    viewer_protocol_policy = "redirect-to-https"
    # ... forwarded_values ...
  }
  # ...
}

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "phase2-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
```

**つまずき**: OAC のバケットポリシーは `Principal: { Service: "cloudfront.amazonaws.com" }` に加えて `Condition: aws:SourceArn: <distribution ARN>` の組み合わせが必須。Distribution ARN は `arn:aws:cloudfront::ACCOUNT:distribution/DISTID` の形式。ARN を省くと他アカウントの CloudFront からもアクセスできてしまう。

**CloudFront の destroy 注意**: `terraform destroy` を実行しても CloudFront ディストリビューションの無効化（Disable）が完了するまで 15〜30 分かかることがある。destroy がタイムアウトしたように見えても待つのが正解。

---

### データレイク構成（Bronze / Silver / Gold）

```
Raw（Bronze）バケット
  → Glue Crawler → Glue Data Catalog
  → Glue ETL Job / Athena CTAS
  → Curated（Silver）バケット（Parquet + 日付パーティション）
  → Aggregated（Gold）バケット（Parquet、Redshift Spectrum 可）
```

**レイヤー別バケット設計**

- **Bronze**: 全データを raw のまま保持。lifecycle で 1 年後 Glacier に移行。絶対に消さない
- **Silver**: `year=YYYY/month=MM/day=DD/` 形式でパーティション。Parquet + Snappy で CSV 比 5〜10 倍の圧縮率
- **Gold**: チームごとに Access Points を発行。Athena ワークグループで課金を分離

**コスト設計のリアル**: Athena は $5/TB スキャン。Silver で Parquet + Snappy にすると CSV 比 1/5〜1/10 のスキャン量になり、パーティションプルーニングと組み合わせると 100 倍の節約も珍しくない。

---

### マルチパートアップロードの実運用と未完パーツの課金問題

S3 は 5GB を超えるオブジェクトには必ずマルチパートアップロードが必要（最大 5TB）。aws CLI はデフォルトで 8MB 以上のオブジェクトを自動的にマルチパートに切り替える。

**落とし穴**: アップロードに失敗して完了しなかったパーツが S3 に残り続けて課金される。大量アップロードシステムでは数百ドル規模の予期しない課金になることがある。lifecycle の `abort_incomplete_multipart_upload` で必ず自動クリーンアップを設定する。

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "main" {
  bucket = aws_s3_bucket.main.id
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7  # 7日で未完のパーツを自動削除
    }
  }
}
```

本 sandbox では `load.sh` の step 2 で `dd if=/dev/urandom bs=1M count=12` を `aws s3 cp` に渡し、CLI が自動マルチパートに切り替えることを実際に確認できる。

---

### S3 Inventory + S3 Batch Operations — 億単位のオブジェクト操作

**S3 Inventory**: バケット内の全オブジェクト一覧を日次/週次で CSV/Parquet として別バケットに出力する。`ListObjectsV2` をページネーションで叩くよりはるかに高速かつ低コスト。大規模データレイクの棚卸しや、暗号化状況の確認、ストレージクラスの集計に使う。

**S3 Batch Operations**: Inventory の出力を入力に、全オブジェクトへの `CopyObject`（SSE の変更）、`RestoreObject`（Glacier 取り出し）、Lambda 関数呼び出しを一括実行できる。数十億オブジェクトの一括処理が現実的なコストで可能。

```
S3 Inventory（Parquet）
  → Athena で対象を絞り込み
    → manifest CSV 出力
      → S3 Batch Operations（ジョブ定義）
        → 1 オブジェクトずつ Lambda を呼ぶ / CopyObject / RestoreObject
```

**CRR と組み合わせる場面**: 既存オブジェクトは CRR の対象外なので、CRR 設定前のオブジェクトを DR バケットに複製するときに Batch Operations の `CopyObject` を使う。

---

### S3 Transfer Acceleration — 大陸をまたぐアップロードを高速化

大陸をまたぐアップロードでレイテンシが問題になる場合、CloudFront のエッジロケーション経由でアップロードを高速化できる。エンドポイントが `BUCKET.s3-accelerate.amazonaws.com` になる。追加コストは $0.04/GB（加速した転送量）。

速度改善が保証されているわけではなく、エッジのキャパシティ次第では通常の S3 より遅いケースも稀にある。事前に [S3 Transfer Acceleration Speed Comparison Tool](https://s3-accelerate-speedtest.s3-accelerate.amazonaws.com/en/accelerate-speed-comparsion.html) で計測してから採用を判断するとよい。

---

## 追加の公式ドキュメント（発展節の出典）

- [S3 イベント通知 — サービス使用の設定](https://docs.aws.amazon.com/AmazonS3/latest/userguide/EventNotifications.html)（閲覧日 2026-05-31）
- [S3 Object Lambda を使用したデータの変換](https://docs.aws.amazon.com/AmazonS3/latest/userguide/transforming-objects.html)（閲覧日 2026-05-31）
- [Block Public Access を使用したパブリックアクセスのブロック](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html)（閲覧日 2026-05-31）
- [Amazon S3 Server-Side Encryption](https://docs.aws.amazon.com/AmazonS3/latest/userguide/serv-side-encryption.html)（閲覧日 2026-05-31）
- [Amazon CloudFront — Origin Access Control](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html)（閲覧日 2026-05-31）
- [S3 Batch Operations の使用](https://docs.aws.amazon.com/AmazonS3/latest/userguide/batch-ops.html)（閲覧日 2026-05-31）
- [VPC エンドポイント — Amazon S3 の Gateway エンドポイント](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html)（閲覧日 2026-05-31）
