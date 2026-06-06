# Phase 2 教材: バケット・オブジェクト・フラットなキー空間

---

## このトピックは何か

Amazon S3 のデータモデルの土台を理解するトピックです。S3 には「ファイルシステム」や「データベース」のような階層構造は存在しません。代わりに **バケット（Bucket）** と **オブジェクト（Object）** という 2 層のシンプルなモデルだけがあります。この構造を正確に把握することが、S3 を正しく設計・操作するための第一歩です。

---

## コアコンセプト

### 1. バケット — オブジェクトのコンテナ

バケットはオブジェクトを格納するコンテナです。バケットを作成するとき、**名前** と **AWS リージョン** を指定します。作成後に名前もリージョンも変更できません。

```
バケット: atcoder-review-artifacts   (ap-northeast-1 に固定)
  ├── submissions/2026/abc.json
  ├── submissions/2026/def.json
  └── exports/report.csv
```

バケット自体はリージョン単位のリソースですが、バケット名はパーティション内のグローバル名前空間で一意でなければなりません（後述）。バケット内に格納できるオブジェクト数に上限はありません。

### 2. オブジェクト — キー＋メタデータ＋本体

オブジェクトは S3 に保存される基本エンティティです。すべてのオブジェクトは次の 3 要素で構成されます。

| 要素 | 内容 |
|------|------|
| **キー（Key）** | バケット内で一意な文字列（オブジェクトの識別子） |
| **メタデータ** | name-value ペアの集合。`Content-Type` / `ETag` / `Last-Modified` などシステムメタデータと、ユーザー定義メタデータがある |
| **本体（データ）** | バイト列。最大 5 TB（単一 PUT は最大 5 GB、それ以上はマルチパート） |

> 公式ドキュメントの定義: *"Objects consist of object data and metadata."* — [Amazon S3 objects overview](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingObjects.html)

オブジェクトはバケットとキーで一意に特定されます。バージョニングが有効な場合はさらに Version ID が加わります。

### 3. フラットなキー空間

S3 のデータモデルは **フラット（平坦）** です。サブバケットもサブフォルダも存在しません。すべてのオブジェクトが同一の平坦なキー空間に並んでいます。

```
【実際の構造 — キーの一覧】
  submissions/2026/abc.json    ← スラッシュは単なる文字
  submissions/2026/def.json
  exports/report.csv
  README.md

【ファイルシステムのように見えるが、階層は存在しない】
```

> 公式ドキュメント: *"The Amazon S3 data model is a flat structure: You create a bucket, and the bucket stores objects. There is no hierarchy of subbuckets or subfolders."* — [Naming Amazon S3 objects](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-keys.html)

### 4. プリフィックスと擬似フォルダ

スラッシュ `/` はキー名の一部の文字であり、ディレクトリ区切り文字としての特別な意味を持ちません。しかし `ListObjectsV2` API に `Prefix` と `Delimiter` パラメータを渡すことで、階層的なブラウズが可能になります。

```
Prefix='submissions/2026/' かつ Delimiter='/'
→ CommonPrefixes に submissions/2026/ がまとめられる
→ その配下のキーだけが Contents に返る
```

`Delimiter` を使うと、S3 は指定した区切り文字でキーをグループ化し、共通プリフィックスを `CommonPrefixes` として返します。これがコンソール上の「フォルダ」表示の実体です。

```xml
<!-- ListObjectsV2 のレスポンス例 (Delimiter='/', Prefix='') -->
<ListBucketResult>
  <Contents>
    <Key>README.md</Key>          <!-- ルート直下のオブジェクト -->
  </Contents>
  <CommonPrefixes>
    <Prefix>exports/</Prefix>     <!-- 擬似フォルダ -->
    <Prefix>submissions/</Prefix>
  </CommonPrefixes>
</ListBucketResult>
```

コンソールが「フォルダ作成」を行うとき、S3 は `folder-name/` というキー名で 0 バイトのオブジェクトを PUT します。このオブジェクトはコンソール上では見えませんが、REST API や CLI からは参照・削除できます。

### 5. 丸ごと PUT / GET — 部分更新不可

S3 のオブジェクト操作は **原子的（atomic）な単位 PUT / GET** が基本です。

- **PUT**: オブジェクト全体を置き換える。一部分だけを書き換える操作は存在しない
- **GET**: デフォルトでオブジェクト全体を取得する
- **バイト範囲 GET**: `Range: bytes=0-1023` ヘッダーを付けることで部分読み込みが可能

```python
import boto3
s3 = boto3.client("s3")

# バイト範囲 GET — 先頭 1024 バイトだけ取得
response = s3.get_object(
    Bucket="atcoder-review-artifacts",
    Key="submissions/2026/abc.json",
    Range="bytes=0-1023",
)
partial_data = response["Body"].read()
```

> 公式ドキュメント: *"Updates to a single key are atomic."* — [Amazon S3 data consistency model](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel)

---

## 主要な設定・API・パラメータ

### バケット命名規則（一般用途バケット）

| 規則 | 内容 |
|------|------|
| 文字数 | 3〜63 文字 |
| 使用可能文字 | 小文字英字・数字・ハイフン（`-`）・ピリオド（`.`） |
| 先頭・末尾 | 英字または数字 |
| IP アドレス形式 | 禁止（例: `192.168.5.4`） |
| 連続ピリオド | 禁止（`my..bucket` は無効） |
| 禁止プリフィックス | `xn--` / `sthree-` / `amzn-s3-demo-` |
| 禁止サフィックス | `-s3alias` / `--ol-s3` / `.mrap` / `--x-s3` / `--table-s3` |
| 一意性スコープ | AWS パーティション内でグローバル一意 |
| 変更可否 | 作成後に名前・リージョンとも変更不可 |

> ピリオドを含むバケット名は HTTPS の仮想ホスト形式アドレッシングで証明書エラーが発生するため、静的ウェブサイトホスティング以外では推奨されません。

### オブジェクトキー命名規則

| 項目 | 内容 |
|------|------|
| 最大長 | 1,024 バイト（UTF-8 エンコード後） |
| 文字セット | 任意の UTF-8 文字 |
| 大小文字 | 区別あり（`ABC.json` と `abc.json` は別オブジェクト） |
| 安全な特殊文字 | `!` `-` `_` `.` `*` `'` `(` `)` |
| URL エンコードが必要な文字 | `&` `$` `@` `=` `;` `+` `:` `,` `?` スペース など |
| 避けるべき文字 | `\` `{` `}` `^` `%` `` ` `` `[` `]` `"` `>` `<` `#` `~` `|` |

### 主要 API（boto3）

```python
import boto3
s3 = boto3.client("s3")

# オブジェクトを PUT（丸ごと書き込み）
s3.put_object(
    Bucket="atcoder-review-artifacts",
    Key="submissions/2026/abc.json",
    Body=b'{"status": "AC", "score": 100}',
    ContentType="application/json",
)

# オブジェクトを GET（丸ごと読み込み）
response = s3.get_object(
    Bucket="atcoder-review-artifacts",
    Key="submissions/2026/abc.json",
)
data = response["Body"].read()

# バイト範囲 GET（部分読み込み）
response = s3.get_object(
    Bucket="atcoder-review-artifacts",
    Key="exports/report.csv",
    Range="bytes=0-4095",   # 先頭 4KB のみ
)

# プリフィックスで一覧（擬似フォルダ内を表示）
paginator = s3.get_paginator("list_objects_v2")
for page in paginator.paginate(
    Bucket="atcoder-review-artifacts",
    Prefix="submissions/2026/",
):
    for obj in page.get("Contents", []):
        print(obj["Key"], obj["Size"], obj["LastModified"])

# 擬似フォルダ構造を 1 階層だけ表示（Delimiter 利用）
response = s3.list_objects_v2(
    Bucket="atcoder-review-artifacts",
    Prefix="submissions/",
    Delimiter="/",
)
for cp in response.get("CommonPrefixes", []):
    print(cp["Prefix"])   # → submissions/2026/ など
```

### オブジェクト URL の形式

```
# 仮想ホスト形式（推奨）
https://{bucket}.s3.{region}.amazonaws.com/{key}

# 例
https://atcoder-review-artifacts.s3.ap-northeast-1.amazonaws.com/submissions/2026/abc.json
```

---

## よくある落とし穴・誤解

### 1. スラッシュはディレクトリ区切りではない

`submissions/2026/abc.json` は **1 つのキー** です。`submissions/` や `submissions/2026/` というディレクトリは存在しません。コンソールで「フォルダ」に見えても、S3 はキーをプリフィックスでグループ化しているだけです。フォルダを「削除」するとその下のキーを持つオブジェクトがまとめて削除されるように見えますが、実際には個別オブジェクトが 1 件ずつ削除されています。

### 2. バケット名はパーティション内でグローバル一意

自分の AWS アカウントで削除したバケット名は、即座に他アカウントが取得できます。削除後しばらく経つと、別アカウントが同名バケットを作成できるようになります。機密情報や推測しやすい名前をバケット名に含めることは避けてください。バケット名は URL に含まれるため公開情報です。

> *"Don't include sensitive information in the bucket name. The bucket name is visible in the URLs that point to the objects in the bucket."* — 公式ドキュメント

### 3. 部分更新は存在しない

S3 には「ファイルの特定バイトを書き換える」操作がありません。既存オブジェクトを更新するには、新しい内容でオブジェクト全体を PUT し直す必要があります。このため DynamoDB の `UpdateItem`（属性単位の書き込み）と発想が異なります。

### 4. バイト範囲 GET は読み込み専用

`Range` ヘッダーによる部分取得（バイト範囲 GET）は **読み込みのみ** です。書き込み側に相当する「部分 PUT」は S3 には存在しません（マルチパートアップロードは大きなオブジェクトを分割して最終的に 1 つに結合する仕組みであり、既存オブジェクトの部分書き換えではありません）。

### 5. リージョンはバケット作成時に確定し、変更不可

バケットのリージョンは作成後に変更できません。オブジェクトはバケットが存在するリージョンに物理的に保存され、明示的に他リージョンへレプリケーションしない限りリージョンをまたいで移動することはありません。

### 6. `ListObjects`（v1）は非推奨

`ListObjects` API は非推奨です。常に `ListObjectsV2` を使用してください。大量のオブジェクトがある場合は Paginator を使い、`ContinuationToken` の処理を自動化します。

---

## このプロジェクト（AtCoder 復習）での使いどころ

### キー設計の指針

S3 のキー空間はフラットなので、プリフィックスを使った設計が重要です。このプロジェクトでは以下のようなキー設計が自然です。

| ユースケース | キー設計例 |
|-------------|-----------|
| AC コードのアーカイブ | `codes/{user}/{contest}/{problem}.py` |
| 提出履歴 JSON スナップショット | `submissions/{user}/{year}/{date}.json` |
| Lambda デプロイパッケージ | `lambda-artifacts/{function}/{version}.zip` |
| 静的フロントエンド | `index.html` / `_next/static/...` |

### DynamoDB との役割分担

Phase 1 では提出データを DynamoDB に保存しました。DynamoDB のアイテムサイズ上限は 400 KB です。コードの生文字列（数 KB〜数十 KB）は DynamoDB に保存すると上限に近づくリスクがあります。

推奨パターン: **S3 にコード本体を置き、DynamoDB には S3 キーだけを保存**

```python
# DynamoDB に保存するアイテム
{
    "user_id": "user_123",
    "contest_id": "abc300",
    "problem_id": "a",
    "status": "AC",
    "code_s3_key": "codes/user_123/abc300/a.py",  # S3 キーへの参照
    "submitted_at": "2026-06-06T12:00:00Z",
}
```

コードを取得するときは DynamoDB からキーを引き、S3 から本体を GET します。これにより DynamoDB はメタデータの高速クエリに専念でき、コード本体の大きなバイト列は S3 が担当します。

---

## 公式ドキュメント（出典）

- [What is Amazon S3? — How Amazon S3 works (Buckets / Objects / Keys / Regions)](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html)（閲覧日 2026-05-31）
- [General purpose buckets overview](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingBucket.html)（閲覧日 2026-05-31）
- [General purpose bucket naming rules](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html)（閲覧日 2026-05-31）
- [Naming Amazon S3 objects (object key naming rules)](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-keys.html)（閲覧日 2026-05-31）
- [Organizing objects using prefixes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-prefixes.html)（閲覧日 2026-05-31）
- [Amazon S3 data consistency model](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel)（閲覧日 2026-05-31）
