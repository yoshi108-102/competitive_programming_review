# Phase 2 教材: セキュリティ（Block Public Access・暗号化・ポリシー）

> 対象範囲: Block Public Access の 4 フラグ、バケットポリシー vs ACL（ACL レガシー化）、SSE-S3 / SSE-KMS / DSSE-KMS の違いと Bucket Key、デフォルト暗号化、アクセスログ、VPC Gateway Endpoint、公開バケット流出インシデントの型と対策。

---

## このトピックは何か

S3 バケットに保存したデータが意図せず公開されたり、盗み見されたりしないための「防御層」を構成する設定群です。大きく 3 つの軸があります。

1. **アクセス制御** — 誰がバケットやオブジェクトを読み書きできるかを決める（Block Public Access・バケットポリシー・ACL）
2. **暗号化** — データを保存・転送する際に暗号化し、鍵を適切に管理する（SSE-S3 / SSE-KMS / DSSE-KMS）
3. **可視性・封じ込め** — アクセスを記録し、VPC 内に通信を閉じる（アクセスログ・CloudTrail・VPC Gateway Endpoint）

---

## コアコンセプト

### Block Public Access — 4 フラグの役割分担

Block Public Access（BPA）は、バケットポリシーや ACL が「うっかり公開設定」になっても上書きしてブロックするセーフガードです。アカウントレベルとバケットレベルの両方に設定でき、**より制限の強い方が適用**されます。2023 年以降、新規バケットはデフォルトで全フラグが有効です。

| フラグ名 | 効果 |
|---|---|
| `BlockPublicAcls` | 新規 PUT リクエストに public ACL が含まれていたらリジェクト（既存 ACL は変更しない） |
| `IgnorePublicAcls` | 既存・新規を問わず public ACL を無視して読み込みブロック（PUT 自体は通す） |
| `BlockPublicPolicy` | バケットポリシーの PUT でポリシーが public 判定されるとリジェクト |
| `RestrictPublicBuckets` | public ポリシーを持つバケットへのアクセスを同一アカウントの AWS プリンシパルのみに制限 |

`BlockPublicAcls` と `IgnorePublicAcls` はペアで使うと効果的です。前者は「これ以上 public ACL を付けさせない」、後者は「既に付いている public ACL を無効化する」という補完関係にあります。

> **「public」の定義**: AWS が定義する `AllUsers` / `AuthenticatedUsers` グループへの許可、または Principal `"*"` にワイルドカード・変数なしの固定条件がないポリシーが public 扱いされます。

### バケットポリシー vs ACL — ACL はレガシー

2023 年以降、新規バケットのデフォルトは `ObjectOwnership=BucketOwnerEnforced`（ACL 無効）です。AWS は公式にバケットポリシーへの一元化を推奨しており、ACL は後方互換のためだけに残っています。

| | バケットポリシー | ACL |
|---|---|---|
| 記述方式 | JSON（IAM と同じ言語） | XML（Grantee/Permission） |
| 最大サイズ | 20 KB | — |
| クロスアカウント制御 | Principal に別アカウント ID を指定 | Grant で grantee を指定 |
| CloudTrail の監査 | 一本化されて追跡しやすい | ACL 変更は別イベント |
| 推奨度 | **現在の標準** | レガシー |

### SSE-S3 / SSE-KMS / DSSE-KMS の違い

2023 年 1 月以降、S3 はすべての新規オブジェクトを **SSE-S3 で自動暗号化**します（追加料金なし）。より強い鍵管理が必要な場合は SSE-KMS か DSSE-KMS を選びます。

| | SSE-S3 | SSE-KMS | DSSE-KMS |
|---|---|---|---|
| 暗号化層数 | 1 層（AES-256） | 1 層（AES-256） | 2 層（AES-256 × 2） |
| 鍵管理 | AWS が完全管理 | AWS managed key または CMK | CMK（必須） |
| CloudTrail に復号ログ | なし | あり（`kms:Decrypt`） | あり |
| KMS API 課金 | なし | あり（$0.03/10k calls） | あり |
| Bucket Key 対応 | 非対応 | 対応（コスト ~99% 削減） | 対応 |
| クロスアカウント共有 | 可 | CMK のみ可（AWS managed key は不可） | CMK のみ可 |
| 主な用途 | 標準・汎用 | 監査要件・CMK 必要時 | 多層暗号化が必要な規制（DoD 等） |

**DSSE-KMS** は SSE-KMS と同じ KMS 統合ですが、S3 側が独自の第 2 暗号化層を追加します。FedRAMP HIGH や CNSSI 1253 などコンプライアンスで「2 層暗号化」が明示されている場合に使います。

### Bucket Key — KMS コストを最大 99% 削減

SSE-KMS は PutObject ごとに KMS API を呼び出します。大量 PUT 環境では KMS のデフォルトクォータ（10,000 req/s/リージョン）に到達してスロットリングが起きます。Bucket Key を有効にすると、バケットレベルの時間限定キーを使ってオブジェクト単位の data key を生成するため、KMS 呼び出し回数が激減します。

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true  # KMS API コールを ~99% 削減
  }
}
```

Bucket Key 有効時は暗号化コンテキストがオブジェクト ARN ではなくバケット ARN になります（CloudTrail ログでの確認に影響する点に注意）。

### デフォルト暗号化

バケットのデフォルト暗号化を変更しても、**既存オブジェクトの暗号化方式は変わりません**。既存オブジェクトを一括で再暗号化するには S3 Batch Operations の CopyObject アクションを使います。

---

## 主要な設定・API・パラメータ

### Block Public Access（Terraform）

```hcl
resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true  # 新規 public ACL をリジェクト
  ignore_public_acls      = true  # 既存 public ACL を無視
  block_public_policy     = true  # public ポリシーの PUT をリジェクト
  restrict_public_buckets = true  # public ポリシーバケットのアクセスを制限
}
```

### バケットポリシー: SSE-KMS を強制する例

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyNonSSEKMS",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:PutObject",
    "Resource": "arn:aws:s3:::my-bucket/*",
    "Condition": {
      "Null": {
        "s3:x-amz-server-side-encryption-aws-kms-key-id": "true"
      }
    }
  }]
}
```

### バケットポリシー: VPC Endpoint 経由のみ許可

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyNonVPCE",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": [
      "arn:aws:s3:::my-bucket",
      "arn:aws:s3:::my-bucket/*"
    ],
    "Condition": {
      "StringNotEquals": {
        "aws:sourceVpce": "vpce-xxxxxxxxxxxxxxxxx"
      }
    }
  }]
}
```

### VPC Gateway Endpoint（Terraform）

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"           # S3 / DynamoDB は Gateway 型（無料）

  route_table_ids = [
    aws_route_table.private_a.id,
    aws_route_table.private_b.id,         # 全サブネットのルートテーブルを列挙
  ]
}
```

### S3 アクセスログの有効化（Terraform）

```hcl
resource "aws_s3_bucket_logging" "main" {
  bucket        = aws_s3_bucket.main.id
  target_bucket = aws_s3_bucket.logs.id   # 配信先は別バケット（SSE-S3 必須）
  target_prefix = "s3-access-logs/"
}
```

> アクセスログ配信先バケットが SSE-KMS の場合、S3 がログオブジェクトを書けなくなります。配信先は必ず SSE-S3 を使ってください。

---

## よくある落とし穴・誤解

### 1. BPA を全部 true にしても「クロスアカウント IAM」は防げない

Block Public Access は「public アクセス」（`AllUsers` / `AuthenticatedUsers` グループや無条件 `*` Principal）をブロックする機能です。別 AWS アカウントの IAM ロールからのアクセスは「認証済みの特定プリンシパル」なので BPA の対象外です。バケットポリシーで明示的に許可していれば通ります。

### 2. `BlockPublicPolicy` はアカウントレベルで設定しないと意味が薄い

バケットレベルで `BlockPublicPolicy=true` にしても、バケットポリシーへの変更権限を持つ IAM ユーザーがバケットの BPA 設定ごと外すことができます。アカウントレベルに設定すれば、バケットポリシーで上書きできなくなります。

### 3. `IgnorePublicAcls` と `BlockPublicAcls` は独立している

`BlockPublicAcls=true` は新規 PUT の public ACL をリジェクトするだけで、**既存の public ACL は残ります**。過去に付けた public ACL を無効化するには `IgnorePublicAcls=true` が別途必要です。

### 4. AWS managed key（`aws/s3`）はクロスアカウント共有不可

SSE-KMS で AWS managed key を使っている場合、別アカウントから復号できません。クロスアカウントで S3 データを共有するには customer managed key（CMK）を作成し、相手アカウントの IAM プリンシパルをキーポリシーに追加します。

### 5. VPC Endpoint のルートテーブルはすべて列挙する

Gateway Endpoint はルートテーブルに静的エントリを追加する方式です。複数のプライベートサブネットがある場合、すべてのサブネットに対応するルートテーブルを `route_table_ids` に列挙しないと、サブネットごとにアクセスが通ったり通らなかったりします。

### 6. デフォルト暗号化変更では既存オブジェクトは再暗号化されない

バケットのデフォルト暗号化を SSE-KMS に変えても、変更前にアップロードされたオブジェクトは SSE-S3 のままです。一括再暗号化は S3 Batch Operations の CopyObject アクションで行います。

---

## 公開バケット流出インシデントの典型パターンと対策

### インシデントパターン

| パターン | 原因 | 対策 |
|---|---|---|
| 設定ドリフト | Terraform 管理外の手動変更で BPA が外れる | Terraform state drift 検知 + Config Rules |
| ワイルドカード Principal の Condition ミス | `Principal: "*"` に付けた `Condition` の演算子を誤り全公開 | `BlockPublicPolicy` をアカウントレベルで有効化 |
| 古い ACL コード | CI に `ACL: public-read` が残ったままデプロイ | `BucketOwnerEnforced`（ACL 無効）+ `BlockPublicAcls` |
| プリサインド URL のログ漏洩 | `--debug` モードで URL が CloudWatch Logs に出力される | Lambda ログで URL 本体を出力しない設計 |

### IAM Access Analyzer for S3

IAM Access Analyzer for S3 はバケットポリシー・ACL・アクセスポイントポリシーを継続的にスキャンし、外部から公開されているバケットをアラートします。コンソールからワンクリックでパブリックアクセスをブロックする機能もあります。

---

## このプロジェクト（AtCoder 復習）での使いどころ

| 設定 | 適用箇所 | 理由 |
|---|---|---|
| BPA 全フラグ有効 | 全バケット | AC コードや提出履歴データを誤公開しない |
| SSE-KMS + Bucket Key | メインデータバケット | KMS 監査証跡を残しつつコストを抑える |
| SSE-S3 | アクセスログ配信先バケット | KMS バケットへのログ配信は S3 側が書けないため |
| VPC Gateway Endpoint | Lambda → S3 通信 | NAT Gateway コスト（$0.045/GB）を回避 |
| バケットポリシーで `aws:sourceVpce` 条件 | データバケット | VPC 外からのアクセスをバケット側で二重ブロック |
| バケットポリシーで SSE-KMS 強制 | データバケット | KMS 暗号化なしの PutObject を拒否 |

---

## 公式ドキュメント（出典）

- [Amazon S3 のパブリックアクセスのブロック](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html)（閲覧日 2026-05-31）
- [SSE-KMS を使用したサーバー側の暗号化](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingKMSEncryption.html)（閲覧日 2026-05-31）
- [Amazon S3 バケットポリシー](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-policies.html)（閲覧日 2026-05-31）
- [サーバー側の暗号化でデータを保護する](https://docs.aws.amazon.com/AmazonS3/latest/userguide/serv-side-encryption.html)（閲覧日 2026-05-31）
- [Amazon S3 Bucket Keys による SSE-KMS のコスト削減](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-key.html)（閲覧日 2026-05-31）
- [VPC エンドポイント — Amazon S3 の Gateway エンドポイント](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html)（閲覧日 2026-05-31）
- [Amazon S3 サーバーアクセスログの有効化](https://docs.aws.amazon.com/AmazonS3/latest/userguide/enable-server-access-logging.html)（閲覧日 2026-05-31）
