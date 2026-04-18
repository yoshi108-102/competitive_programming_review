# DynamoDBのアイテム設計（スキーマレスの制約と自由度）

## 概要

DynamoDBは「スキーマレス」と呼ばれるが、完全に自由ではなく**キー属性には厳格なルール**がある。Terraformの `attribute` ブロックと、実行時のアイテム挿入の関係、およびスキーマレスゆえの落とし穴をまとめる。

## 解説

### キー属性の型（3種類のみ）

DynamoDB がキー（PK/SK/GSI/LSI の key）として認める型:

| 値 | 意味 |
|---|---|
| `"S"` | String |
| `"N"` | Number |
| `"B"` | Binary |

キー以外の属性（メール、日時、配列、オブジェクト等）は実行時に自由に入れられる。キーとしては使えない型（`SS`(String Set), `L`(List), `M`(Map), `BOOL` など）は、**ソート・比較ができないため**キーにできない。

### `attribute` ブロックの役割

Terraform の `aws_dynamodb_table` における `attribute` ブロックは、**「このテーブルの hash_key / range_key / GSI / LSI のどこかで使われている属性」を宣言する**もの。

- 使われている属性を書き忘れる → `terraform plan` でエラー
- 使われていない属性を書く → `terraform plan` でエラー

つまり `attribute` = キー定義の **"宣言"** パート、`hash_key` / `range_key` / `global_secondary_index.*` = **"使用"** パート。両者が一致しないと成立しない。

#### 例: submissions テーブル

```hcl
hash_key  = "user_id"         # ← 使用
range_key = "submission_id"   # ← 使用

attribute {                    # ← 宣言（使用している属性だけ）
  name = "user_id"
  type = "S"
}

attribute {
  name = "submission_id"
  type = "S"
}
```

`contest_id`, `submitted_at` などの非キー属性は書かない。スキーマレスなので、挿入時に自由に追加できる。

### スキーマレスの制約と自由度

#### 制約（必須）

| ルール | 内容 |
|---|---|
| キーは必須 | PutItem時、PK（あればSKも）は必ず指定 |
| キーの型は宣言通り | `type = "S"` で宣言 → 必ずstringで渡す。数値で渡すとエラー |

#### 自由（やりたい放題）

| 自由にできること | 例 |
|---|---|
| 非キー属性を何個でも追加 | `handle`, `email`, `created_at` ... |
| アイテムごとに属性が違ってもOK | アイテム1は `email` あり、アイテム2は `email` なし |
| ネストしたオブジェクト/配列もOK | `preferences: {theme: "dark", lang: "ja"}` |
| 属性の型は豊富 | `S`, `N`, `B`, `BOOL`, `L`(リスト), `M`(マップ), `SS`/`NS`/`BS`(Set), `NULL` |

### Python (boto3) でのイメージ

```python
import boto3
table = boto3.resource("dynamodb").Table("atcoder-review-users-prod")

# 最小: キーだけ
table.put_item(Item={"user_id": "abc123"})

# 好き放題属性を追加
table.put_item(Item={
    "user_id": "abc123",
    "handle": "tourist",
    "email": "t@example.com",
    "created_at": "2026-04-18T10:00:00Z",
    "preferences": {"theme": "dark", "notify": True},  # ネストOK
    "recent_contests": ["abc300", "abc301", "abc302"],  # リストOK
})

# 別ユーザーは全然違う構造でもOK
table.put_item(Item={
    "user_id": "xyz789",
    "display_name": "田中",  # handleじゃなくdisplay_name
    "tags": {"pro", "ACM"},   # Set型（boto3なら自動変換）
    # created_at なし、email なし
})
```

RDB でこれをやると「テーブル定義変更しないと」となるが、DynamoDB はいらない。

### スキーマレスの落とし穴

| 注意点 | 内容 |
|---|---|
| アプリ側のスキーマ管理が必須 | DBが守ってくれない分、**アプリ側でスキーマを明示管理する責務**が増える（Pydanticモデル等で） |
| アイテムサイズ上限 400KB | JSONサイズでなく、DynamoDB内部表現サイズ |
| 属性名も400KB制限に含まれる | 属性名は短くした方が効率的（`created_at` より `ca` 等の極限設計もある） |
| 予約語に注意 | `Name`, `Size`, `Status` などは予約語。Queryで使う際 `ExpressionAttributeNames` でエスケープ必要 |
| 空文字 `""` | 2020年から許可されたが、古い記事では "NG" と書かれていることも |

### Single Table Design（上級パターン）

DynamoDB の上級パターンとして、**1つのテーブルに異なる "種類" のアイテムを混在させる**手法がある。AWS re:Invent でも語られる有名テク。

例:

| user_id (PK) | submission_id (SK) | type | ... |
|---|---|---|---|
| `abc123` | `PROFILE#` | user | handle: tourist, email: ... |
| `abc123` | `SUB#v1.1719123456` | submission | problem_id: abc300_a, result: AC |
| `abc123` | `SUB#v1.1719123789` | submission | problem_id: abc300_b, result: WA |

スキーマレスだからこそできる芸当。本プロジェクトでは採用しないが、知識として。

## Q&A

**Q: `type=S` というのは確か string のことだったんだっけ？それで attribute が PK or SK のようなキー属性のものだけ使えると**

両方合っている。

- `type = "S"` = String。DynamoDB がキーに認める型は `S`(String) / `N`(Number) / `B`(Binary) の3種のみ
- `attribute` ブロックは**キーで使われている属性**だけ書く。非キー属性（email, created_at 等）は書かない。書き忘れもエラー、書きすぎもエラー

`attribute` = キー定義の "宣言" パート、`hash_key` / `range_key` / GSIの key = "使用" パート。両者が一致する必要がある。

**Q: スキーマレスだから、Pythonコードとかで追加するときにはキーさえ指定すればあとはやりたい放題ということ？**

ほぼその通り。

- **必須**: キー（PK、あればSK）は必ず指定、かつ宣言通りの型で渡す
- **自由**: 非キー属性は何個でも、型も何でも、ネストOK、アイテムごとに違ってもOK
- **落とし穴**: DBが守ってくれない分、アプリ側でPydanticなどスキーマ管理する責務が増える。アイテムサイズ400KB上限、予約語注意など
- **上級**: Single Table Design でスキーマレスを極限活用するパターンもあるが今回は採用しない

## 関連

- [01-dynamodb-keys.md](01-dynamodb-keys.md) - DynamoDBのキー設計（PK/SK/GSI）
- [03-module-design-patterns.md](03-module-design-patterns.md) - Terraformモジュール設計の流派
- [reference/dynamodb-keys-vs-rdb.md](reference/dynamodb-keys-vs-rdb.md) - DynamoDB vs RDB 詳細比較

---

_Saved at 2026-04-18 via /learning-flow:topic_
