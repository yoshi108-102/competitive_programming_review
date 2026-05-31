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
