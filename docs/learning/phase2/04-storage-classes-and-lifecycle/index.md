# Phase 2 教材: ストレージクラスとライフサイクル

## このトピックは何か

S3 に保存したオブジェクトは、すべてが常に同じ速度・同じコストで参照されるわけではない。アクセス頻度や取り出しレイテンシ要件に合わせて **ストレージクラス** を選ぶことで保存コストを最適化できる。さらに **ライフサイクルルール** を使うと、時間の経過に伴うクラス移行・有効期限切れ・未完マルチパートの掃除を S3 が自動で行う。

このトピックでは次の問いに答える。

- 7 種類のストレージクラスのどれを、いつ使うか
- ライフサイクルルールの設定単位と移行の制約
- 未完マルチパートアップロードが課金され続ける問題と対処

---

## コアコンセプト

### ストレージクラスの位置づけ

ストレージクラスはオブジェクト単位で指定するメタデータである。PUT 時に `StorageClass` パラメータで指定するか、ライフサイクルルールで後から自動移行する。クラスを変えると保存単価・最小保存期間・取り出しコスト・取り出し時間のトレードオフが変わる。

### ライフサイクルルール

ライフサイクルルールはバケットに設定し、次の 3 つのアクションを自動化する。

1. **Transition** — 指定日数後に別のストレージクラスへ移行する
2. **Expiration** — 指定日数後にオブジェクトを削除する（バージョニング有効時は削除マーカーを付ける）
3. **AbortIncompleteMultipartUpload** — 指定日数後に未完のマルチパートアップロードのパーツを削除する

ルールはバケット全体、Prefix、またはオブジェクトタグでスコープを絞ることができる。

### Intelligent-Tiering の自動最適化

Intelligent-Tiering はアクセスパターンを S3 が自動監視し、Frequent Access / Infrequent Access / Archive Instant Access の 3 段階を自動切替する。オプトインで Deep Archive Access 層も利用できる。監視コストとして **$0.0025/1,000 objects/月** がかかる。128 KB 未満のオブジェクトは常に Frequent Access に留まるため、小オブジェクトが大量にある場合は通常の Standard の方が安い。

---

## 主要な設定・API・パラメータ

### ストレージクラス比較表

| クラス | 用途 | 保存単価（目安） | 最小保存期間 | 取り出しコスト | 取り出し時間 |
|---|---|---|---|---|---|
| S3 Standard | 頻繁アクセス | 高 | なし | なし | ミリ秒 |
| S3 Intelligent-Tiering | アクセスパターン不明 | 中〜高（監視コストあり） | なし | なし（Frequent/IA） | ミリ秒 |
| S3 Standard-IA | 低頻度・長期保存 | 中 | **30 日** | あり（GB 単価） | ミリ秒 |
| S3 One Zone-IA | 低頻度・単一 AZ 可 | 低（Standard-IA の約 80%） | **30 日** | あり（GB 単価） | ミリ秒 |
| S3 Glacier Instant Retrieval | アーカイブ・即時取り出し | 低 | **90 日** | あり（高め） | ミリ秒 |
| S3 Glacier Flexible Retrieval | アーカイブ | 非常に低 | **90 日** | あり | 分〜12 時間 |
| S3 Glacier Deep Archive | 長期アーカイブ（7 年〜） | 最安（$0.00099/GB/月） | **180 日** | あり（最高） | 12〜48 時間 |

> **One Zone-IA の注意**: データは 1 つの AZ にのみ保存される。AZ 障害でデータが失われても問題ないケース（再生成可能なサムネイル・暫定キャッシュ等）に限定して使う。

### Glacier の取り出しオプション

Glacier Flexible Retrieval には 3 段階の取り出し速度があり、速いほど料金が高い。

| 取り出しオプション | 完了時間 |
|---|---|
| Expedited | 1〜5 分 |
| Standard | 3〜5 時間 |
| Bulk | 5〜12 時間 |

Glacier Deep Archive は Standard（12 時間以内）と Bulk（48 時間以内）の 2 段階。Expedited はない。

### PUT 時のストレージクラス指定（boto3）

```python
import boto3

s3 = boto3.client("s3")

# Standard-IA でアップロード
s3.put_object(
    Bucket="atcoder-review-artifacts",
    Key="archive/2025/abc300.json",
    Body=data,
    StorageClass="STANDARD_IA",
)

# Intelligent-Tiering でアップロード
s3.put_object(
    Bucket="atcoder-review-artifacts",
    Key="user-uploads/unknown-pattern.bin",
    Body=data,
    StorageClass="INTELLIGENT_TIERING",
)
```

`StorageClass` を省略すると `STANDARD` になる。

### ライフサイクルルール（Terraform）

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  # ルール 1: コード・提出データの段階的アーカイブ
  rule {
    id     = "archive-old-submissions"
    status = "Enabled"

    filter {
      prefix = "submissions/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"   # Glacier Instant Retrieval
    }

    transition {
      days          = 365
      storage_class = "DEEP_ARCHIVE"
    }

    expiration {
      days = 2555   # 7 年後に削除
    }
  }

  # ルール 2: 未完マルチパートの掃除（必須）
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}   # バケット全体

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
```

### ライフサイクルルール（AWS CLI / JSON）

```json
{
  "Rules": [
    {
      "ID": "archive-old-submissions",
      "Status": "Enabled",
      "Filter": { "Prefix": "submissions/" },
      "Transitions": [
        { "Days": 30,  "StorageClass": "STANDARD_IA" },
        { "Days": 90,  "StorageClass": "GLACIER_IR" },
        { "Days": 365, "StorageClass": "DEEP_ARCHIVE" }
      ],
      "Expiration": { "Days": 2555 }
    },
    {
      "ID": "abort-incomplete-multipart",
      "Status": "Enabled",
      "Filter": {},
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
```

```
aws s3api put-bucket-lifecycle-configuration \
  --bucket atcoder-review-artifacts \
  --lifecycle-configuration file://lifecycle.json
```

### クラス移行の方向制約

S3 のライフサイクルで移行できる方向は **「Standard 側 → Glacier 側」の一方向のみ**。

```
Standard
  ↓
Intelligent-Tiering / Standard-IA / One Zone-IA
  ↓
Glacier Instant Retrieval
  ↓
Glacier Flexible Retrieval
  ↓
Glacier Deep Archive
```

Glacier から Standard に戻すには `RestoreObject` API で一時コピーを取り出してから `CopyObject` でクラスを指定し直す必要がある。

---

## よくある落とし穴・誤解

### 最小保存期間による逆コスト

Standard-IA・One Zone-IA は **30 日未満の保存でも 30 日分**、Glacier 系は **90 日（Deep Archive は 180 日）分**の料金が発生する。作成 → 数日後に削除するような短命オブジェクトに IA を使うと Standard より高くなる。

**判断基準**: Standard-IA は「月 1 回未満しかアクセスしない & 30 日以上保持する」が揃って初めて Standard より安くなる。

### 未完マルチパートの無言課金

5 GB 超のオブジェクトや AWS CLI が自動で切り替える 8 MB 超のアップロードは、内部的にマルチパートになる。アップロードが途中で失敗してもパーツは S3 に残り続け、ListObjectsV2 には見えないのに課金される。大量アップロードシステムでは数か月で数百ドルの意図しない請求につながることがある。

**対処**: `AbortIncompleteMultipartUpload` のライフサイクルルールをバケット作成時に必ず設定する。S3 コンソールの「Multipart uploads」タブで現在の未完パーツを確認できる。

### Glacier からの取り出しはオブジェクトが直接戻るわけではない

`RestoreObject` を呼ぶと、Glacier から Standard（一時コピー）への復元リクエストが非同期で始まる。復元が完了するまでオブジェクトは読めない。完了を知るには S3 イベント通知（`s3:ObjectRestore:Completed`）か、`HeadObject` レスポンスの `Restore` ヘッダを確認する。

### Intelligent-Tiering の小オブジェクト問題

128 KB 未満のオブジェクトは Infrequent や Archive 層に降りないため、監視コスト（$0.0025/1,000 objects/月）だけが発生する。ログの断片・サムネイル・小 JSON が大量にある場合は Standard が安い。

### ライフサイクルルールの `filter {}` の必要性

AWS API v2（Terraform AWS Provider v4 以降）では `filter` ブロックを省略するとエラーになるか、バケット全体に適用されないことがある。バケット全体に適用したい場合は空の `filter {}` を明示する。

---

## このプロジェクト（AtCoder 復習）での使いどころ

AtCoder 復習ツールでは、提出データとコードファイルのアクセス頻度が時間経過で急減する傾向がある。以下のライフサイクル設計が自然にフィットする。

| データ種別 | Prefix 例 | 推奨クラス推移 |
|---|---|---|
| 最近の提出 JSON | `submissions/{user}/{date}.json` | Standard → 30 日後 Standard-IA → 365 日後 Deep Archive |
| AC コード（参照用） | `codes/{user}/{contest}/` | Standard → 60 日後 Glacier IR → 180 日後 Glacier Flexible |
| Lambda デプロイ ZIP | `lambda-artifacts/{version}.zip` | Standard（短命。Expiration で 90 日後削除） |
| 一時エクスポート CSV | `exports/tmp/` | Standard-IA（生成 → ダウンロード → 不要になるサイクル向き） |

コードの生文字列は DynamoDB の 400 KB アイテム制限に引っかかる可能性がある。コード本体は S3 に置き、DynamoDB には S3 キーだけを保持する**参照パターン**と、ライフサイクルによる自動アーカイブを組み合わせると、ストレージコストを長期間意識せず運用できる。

---

## 公式ドキュメント（出典）

- [Amazon S3 ストレージクラスの使用](https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html)（閲覧日 2026-05-31）
- [オブジェクトライフサイクル管理](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html)（閲覧日 2026-05-31）
- [ライフサイクルルールの設定要素](https://docs.aws.amazon.com/AmazonS3/latest/userguide/intro-lifecycle-rules.html)（閲覧日 2026-05-31）
- [S3 Glacier ストレージクラスを使用したオブジェクトの移行](https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html)（閲覧日 2026-05-31）
- [S3 Intelligent-Tiering を使用したストレージコストの最適化](https://docs.aws.amazon.com/AmazonS3/latest/userguide/intelligent-tiering.html)（閲覧日 2026-05-31）
- [マルチパートアップロードの概要](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html)（閲覧日 2026-05-31）
