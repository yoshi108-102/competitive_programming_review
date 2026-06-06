# Phase 2 教材: バージョニングと整合性モデル

> 対象: S3 バージョニング（有効化・バージョン ID・削除マーカー・MFA Delete）、強整合性モデル（2020 年以降）、レプリケーション（CRR/SRR）との関係、コストへの影響。

---

## このトピックは何か

S3 のバージョニングは、同一バケット内に同一キーのオブジェクトを複数世代にわたって保持する仕組みです。誤削除や上書きからのリカバリを可能にし、コンプライアンス要件を満たすデータ保持戦略の基盤になります。

整合性モデルは「データを書き込んだ直後に読み取ると何が返るか」を定義します。2020 年 12 月の変更により S3 は完全な強整合性（strong consistency）を保証するようになり、以前のような結果整合モデルの考慮が不要になりました。

両者は独立した機能ですが、**バージョニングが有効なバケットではオブジェクトの一意性がキー + バージョン ID の組み合わせで決まる**という点で整合性保証の適用対象が広がります。また、レプリケーション（CRR/SRR）の前提条件としてバージョニングの有効化が必須です。

---

## コアコンセプト

### 1. バージョニングの 3 状態

バケットは常に次の 3 つのうちいずれかの状態にあります。

| 状態 | 説明 |
|------|------|
| **Unversioned**（既定） | バージョニング無効。PUT で上書き、DELETE で完全削除 |
| **Versioning-enabled** | バージョニング有効。PUT ごとに新バージョン、DELETE は削除マーカーを挿入 |
| **Versioning-suspended** | バージョニング一時停止。新規 PUT は `null` バージョンとして書かれ、既存バージョンは保持 |

**一度有効化したバケットは Unversioned 状態に戻せません。** Suspended には戻せますが、既存の全バージョンは残り続けます。

### 2. バージョン ID

バージョニングを有効化すると、S3 は PUT されたオブジェクトごとに一意のバージョン ID（URL-safe な不透明文字列）を自動生成します。

```
キー: submissions/abc.json
  バージョン: "3sL4kqtJlcpXroDTDmJ+rmSpXd3dIbrHY+MTRCxf3vjVBH40Nr8X8gdRQBpUMLUo" (最新)
  バージョン: "YkistapxCMFLZhiqxMwWFEnbfnUFzfvQ"
  バージョン: null  ← バージョニング有効化前に存在していたオブジェクト
```

バージョニング有効化前から存在するオブジェクトのバージョン ID は `null` です。有効化後、そのオブジェクトを PUT/CopyObject で変更すると初めて一意な ID が付与されます。

### 3. 削除マーカー（Delete Marker）

バージョニング有効化バケットでバージョン ID を指定せずに DELETE すると、オブジェクトは物理削除されません。代わりに S3 は**削除マーカー**を最新バージョンとして挿入します。

```
DELETE submissions/abc.json  →  削除マーカー（バージョン ID: "xYz..."）が最新バージョンに

GET submissions/abc.json  →  404 Not Found（最新バージョンが削除マーカーのため）
GET submissions/abc.json?versionId=YkistapxCMFLZhiqxMwWFEnbfnUFzfvQ  →  旧バージョンを取得可能
```

完全に削除するには、削除マーカーそのものをバージョン ID 指定で DELETE する必要があります。

```python
import boto3
s3 = boto3.client("s3")

# 特定バージョンを完全削除（削除マーカーの削除にも同じ API を使う）
s3.delete_object(
    Bucket="atcoder-review-artifacts",
    Key="submissions/abc.json",
    VersionId="xYz...",  # 削除マーカーのバージョン ID
)
```

### 4. 強整合性モデル（2020 年 12 月以降）

S3 は PUT・DELETE・LIST の全操作で強整合性（strong read-after-write consistency）を保証します。

| 操作 | 保証される挙動 |
|------|---------------|
| PUT 後の GET | 必ず最新データが返る（古いデータは絶対に返らない） |
| DELETE 後の GET | 必ず 404 が返る |
| PUT 後の LIST | 新オブジェクトが必ずリストに現れる |
| DELETE 後の LIST | 削除したキーは必ずリストに現れない |

**更新の原子性**: 同一キーへの PUT は原子的（atomic）に扱われます。GET は「以前のデータ」か「新しいデータ」のいずれかを返し、中間状態の混在したデータは返しません。

**バケット設定の結果整合**: バージョニングの有効化などバケット設定の変更には**結果整合**が適用されます。バージョニングを有効化した直後は変更が全サーバーに伝播するまでの短い時間差があります。公式ドキュメントは「有効化後 15 分待ってから書き込みを開始する」ことを推奨しています。

---

## 主要な設定・API・パラメータ

### バージョニング設定（Terraform / boto3）

```hcl
# Terraform
resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration {
    status = "Enabled"  # Enabled | Suspended
  }
}
```

```python
# boto3: バージョニング有効化
s3.put_bucket_versioning(
    Bucket="atcoder-review-artifacts",
    VersioningConfiguration={"Status": "Enabled"},
)
```

### バージョン一覧の取得と操作

```python
# 全バージョンを一覧（削除マーカーを含む）
paginator = s3.get_paginator("list_object_versions")
for page in paginator.paginate(Bucket="atcoder-review-artifacts", Prefix="submissions/"):
    for ver in page.get("Versions", []):
        print(ver["Key"], ver["VersionId"], ver["LastModified"])
    for marker in page.get("DeleteMarkers", []):
        print(marker["Key"], marker["VersionId"], "DELETE_MARKER")

# 特定バージョンを取得
response = s3.get_object(
    Bucket="atcoder-review-artifacts",
    Key="submissions/abc.json",
    VersionId="YkistapxCMFLZhiqxMwWFEnbfnUFzfvQ",
)

# 全バージョンの一括削除（バケット削除前のクリーンアップ）
# 通常は Lifecycle の NoncurrentVersionExpiration で管理する
```

### MFA Delete

MFA Delete は、バージョニングと組み合わせてバケットの保護を強化するオプション機能です。

MFA Delete を有効化すると、次の操作に MFA 認証が必要になります。

- バケットのバージョニング状態の変更
- オブジェクトの特定バージョンの完全削除

```bash
# CLI での MFA Delete 有効化（root アカウントのみ実行可能）
aws s3api put-bucket-versioning \
  --bucket my-bucket \
  --versioning-configuration Status=Enabled,MFADelete=Enabled \
  --mfa "arn:aws:iam::123456789012:mfa/root-account-mfa-device 123456"
```

**MFA Delete の制限事項**

| 項目 | 内容 |
|------|------|
| 有効化できるのは | バケットオーナー（root アカウント）のみ |
| 設定手段 | CLI または API のみ（コンソール不可） |
| Lifecycle との共存 | Lifecycle 設定と MFA Delete は併用不可 |
| 仮想 MFA | ARN 形式で指定（例: `arn:aws:iam::ACCOUNT:mfa/DEVICE`） |

---

## バージョニングとレプリケーション（CRR/SRR）

S3 レプリケーションは**ソースとデスティネーション両方のバケットでバージョニングが必須**です。

### CRR と SRR の比較

| | Cross-Region Replication (CRR) | Same-Region Replication (SRR) |
|---|---|---|
| 対象 | 異なるリージョン間 | 同一リージョン内 |
| 主な用途 | DR・レイテンシ低減・データ主権 | ログ集約・本番/テスト同期 |
| バージョニング要件 | ソース・デスティネーション両方で必須 | 同左 |
| 既存オブジェクト | ライブレプリケーションの対象外 | 同左 |
| 削除マーカー | デフォルトでは複製されない（要設定） | 同左 |

### 削除マーカーのレプリケーション挙動

バージョン ID なしの DELETE（削除マーカーの挿入）は、デフォルトではデスティネーションに**複製されません**。誤削除のレプリカへの伝播を防ぐための設計です。

```hcl
# 削除マーカーをレプリカにも反映したい場合
resource "aws_s3_bucket_replication_configuration" "main" {
  role   = aws_iam_role.replication.arn
  bucket = aws_s3_bucket.main.id

  rule {
    id     = "replicate-all"
    status = "Enabled"

    delete_marker_replication {
      status = "Enabled"  # デフォルトは Disabled
    }

    destination {
      bucket        = aws_s3_bucket.replica.arn
      storage_class = "STANDARD_IA"
    }
  }
}
```

### 既存オブジェクトのレプリケーション

ライブレプリケーション（CRR/SRR）は**設定後に PUT されたオブジェクトのみ**を対象とします。設定前から存在するオブジェクトを複製するには S3 Batch Replication を使います。

```bash
# Batch Replication による既存オブジェクトの一括複製
aws s3control create-job \
  --account-id 123456789012 \
  --operation '{"S3ReplicateObject":{}}' \
  --manifest-generator '{...}'  # S3 Inventory またはマニフェスト CSV を指定
```

---

## よくある落とし穴・誤解

### 1. バージョニング有効化の取り消しができない

「試しに有効化してみたが、やっぱりやめたい」は不可能です。Suspended にしても既存バージョンは残り続け、ストレージコストは発生し続けます。有効化は慎重に行うか、Lifecycle の `NoncurrentVersionExpiration` で不要バージョンの自動削除を設定してからにします。

### 2. 「削除したはずなのにコストが増えた」

バージョニング有効バケットで単純 DELETE すると削除マーカーが付くだけで旧バージョンは残ります。旧バージョンも課金対象です。`ListObjectVersions` で確認し、Lifecycle ルールで `NoncurrentVersionExpiration` を設定してください。

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "versions" {
  bucket = aws_s3_bucket.main.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30  # 最新でなくなってから 30 日で削除
    }

    expiration {
      expired_object_delete_marker = true  # 孤立した削除マーカーも削除
    }
  }
}
```

### 3. バージョニング有効化直後のタイミング問題

バージョニングを有効化した直後は、設定変更の伝播が完了していない場合があります。公式ドキュメントは有効化後 **15 分間**待ってから書き込みを開始することを推奨しています。

### 4. 強整合性が適用されない範囲

オブジェクト操作は強整合ですが、**バケット設定（バージョニング・CORS・ライフサイクル等）の変更は結果整合**です。バケット設定変更の直後にプログラムからその設定を確認しても、まだ古い値が返ることがあります。

### 5. コンカレントな PUT は last-writer-wins

同一キーへの複数スレッドからの同時 PUT は、タイムスタンプが最新のものが勝ちます。S3 はオブジェクトロック機能（Object Lock）を別途提供していますが、通常の Versioning とは独立した仕組みです。アプリ側でのロック制御が必要な場合は DynamoDB conditional writes などを併用します。

### 6. MFA Delete は Lifecycle と共存不可

MFA Delete を有効化したバケットでは、Lifecycle による自動バージョン削除が機能しません。コスト管理のための自動クリーンアップが止まる点に注意が必要です。

---

## コストへの影響

| 課金要素 | 内容 |
|---------|------|
| 全バージョンのストレージ | 「diff」ではなく各バージョンがオブジェクト全体。3 バージョン = 3 オブジェクト分 |
| 削除マーカー | 0 バイトオブジェクトとして保存されるが、管理費がかかる |
| PUT リクエスト | バージョンごとに PUT として課金 |
| CRR/SRR のデータ転送 | CRR は転送コストが発生。SRR は転送コストなし |

コスト最適化の基本パターンは Lifecycle との組み合わせです。

```
バージョン作成（PUT）
  ↓ 30 日後
  NoncurrentVersionExpiration で旧バージョン削除
  ↓（削除マーカーだけが残った場合）
  expired_object_delete_marker = true で孤立削除マーカーも自動削除
```

---

## このプロジェクト（AtCoder 復習）での使いどころ

| ユースケース | バージョニングの役割 |
|-------------|---------------------|
| AC コードのアーカイブ（`codes/{user}/{contest}/{problem}.py`） | 誤ったコードの上書きからリカバリ。旧バージョンと比較して改善の可視化 |
| 提出履歴 JSON の更新（`submissions/{user}/{date}.json`） | AtCoder API の取得結果を上書き保存しても旧バージョンを遡及確認可能 |
| CRR でのクロスリージョン DR 構成 | 両バケットのバージョニング有効化が前提。削除マーカーのレプリケーションは要件に応じて設定 |

強整合性の観点では、Lambda が AC コードを S3 に PUT した直後に別の Lambda が同一キーを GET しても、常に最新のコードを取得できます。以前のような「PUT したのに GET で旧データが返った」という現象は 2020 年以降発生しません。

---

## 公式ドキュメント（出典）

- [Retaining multiple versions of objects with S3 Versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html)（閲覧日 2026-05-31）
- [Amazon S3 data consistency model](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel)（閲覧日 2026-05-31）
- [Configuring MFA delete](https://docs.aws.amazon.com/AmazonS3/latest/userguide/MultiFactorAuthenticationDelete.html)（閲覧日 2026-05-31）
- [Replicating objects within and across Regions](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication.html)（閲覧日 2026-05-31）
- [What is Amazon S3? — Features of Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html)（閲覧日 2026-05-31）
