# DynamoDBモジュール実装の設計判断ログ

## 概要

Task 1 で `terraform/modules/dynamodb/` を一から書く過程で行った設計判断のまとめ。
「なぜこう書いたか」を残すことで、将来モジュールを変更するとき or 別モジュール（Lambda等）を書くときの判断材料にする。

## 解説

### Step 1: `variables.tf` の設計判断

#### 何を variable化するか

DynamoDB テーブルの設定項目のうち、**外から変えたくなる値だけ** variable にする。残りはハードコード。

| 設定項目 | variable化する？ | 理由 |
|---|---|---|
| テーブル名prefix (`project_name`) | ✅ する | dev/prod で分離、他プロジェクト再利用 |
| environment | ✅ する | 同一AWSアカウント内の環境別分離 |
| `billing_mode` | ❌ しない | PAY_PER_REQUEST 固定で良い。将来必要になったら追加 |
| ハッシュキー名 | ❌ しない | テーブル固有の設計判断、実装詳細 |
| GSI設定 | ❌ しない | 実装詳細 |
| region | ❌ しない | provider で指定、モジュールに inheritされる |

**原則**: YAGNI（使われない柔軟性は無駄なコスト）。

#### `default` の使い分け（ルート側は書く、モジュール側は書かない）

ルートとモジュールで `default` の扱いを変える:

**モジュール側 (`modules/dynamodb/variables.tf`) → `default` を書かない**

- モジュールは他プロジェクトで再利用する可能性のある**汎用部品**
- もし `default = "atcoder-review"` を書くと、他プロジェクトで使ったときに「何も渡さないと atcoder-review の名前で作られる」バグの温床
- 呼び出し側に**明示的に値を渡させる**方が安全（渡し忘れ時に `Error: Missing required argument` で気づける）

**ルート側 (`terraform/variables.tf`) → `default` を書く**

- ルートは**このプロジェクト固有の入り口**。再利用しない
- `project_name = "atcoder-review"` のような値は確定しているので、毎回 `-var project_name=...` を指定するのは煩雑
- 実行時の利便性のために default 提供でOK

値のフロー:

```
ルート: terraform/variables.tf (default あり)
  │
  ↓ var.project_name で参照
  │
modules.tf で module "dynamodb" に渡す
  │
  ↓ 明示的に project_name = var.project_name と渡す
  │
モジュール: modules/dynamodb/variables.tf (default なし)
```

原則: **ルート = アプリ固有の設定、モジュール = 汎用部品**、という役割分担で defaultの扱いを決める。

#### 最終形

```hcl
variable "project_name" {
  description = "Project name used as prefix for table names"
  type        = string
}

variable "environment" {
  description = "Environment name (prod, dev, stg)"
  type        = string
}
```

### Step 2: `main.tf` の設計判断

#### 共通ルール

- **`attribute` ブロックは「キーで使う属性だけ」書く**。非キー属性は書かない（スキーマレス）
- **`type` は `"S"` / `"N"` / `"B"` の3種のみ**（DynamoDB 自体の仕様）
- **`billing_mode = "PAY_PER_REQUEST"`**: 個人開発・小規模、トラフィック予測できない → オンデマンドが適切

#### users テーブル（最もシンプル）

PK のみ。1ユーザー = 1レコードの1対1構造。

```hcl
resource "aws_dynamodb_table" "users" {
  name         = "${var.project_name}-users-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"

  attribute {
    name = "user_id"
    type = "S"
  }
}
```

PK = Cognito sub（→ [05-user-id-identity.md](05-user-id-identity.md) 参照）。

#### submissions テーブル（PK + SK）

1ユーザーが複数 submission を持つ 1対多 構造。複合キー。

```hcl
resource "aws_dynamodb_table" "submissions" {
  name         = "${var.project_name}-submissions-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "submission_id"

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "submission_id"
    type = "S"
  }
}
```

- PK = `user_id` でユーザー単位にパーティション集約
- SK = `submission_id` でパーティション内をソート/絞り込み
- 今後時系列ソートしたくなったら SK を `timestamp#submission_id` のような複合値にする選択肢あり（今回は単純化）

#### problems テーブル（PK + GSI）

問題検索のため GSI を追加。

```hcl
resource "aws_dynamodb_table" "problems" {
  name         = "${var.project_name}-problems-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "problem_id"

  attribute {
    name = "problem_id"
    type = "S"
  }
  attribute {
    name = "tag"
    type = "S"
  }
  attribute {
    name = "difficulty"
    type = "S"
  }

  global_secondary_index {
    name            = "TagDifficultyIndex"
    hash_key        = "tag"
    range_key       = "difficulty"
    projection_type = "ALL"
  }
}
```

##### GSI の役割

「別のキー構成で同じデータを参照できるサブテーブル」。

- メインの `problem_id` によるGet/Queryだけでは、「タグ＋難易度」での検索が全件スキャンになってしまう
- GSI を張ることで DynamoDB が裏で自動同期し、`tag=..., difficulty=...` での効率的な Query を可能にする

##### `projection_type = "ALL"` の判断

GSI から取れる属性の範囲:

| 値 | 意味 |
|---|---|
| `KEYS_ONLY` | PK/SK属性のみ |
| `INCLUDE` | KEYS_ONLY + 指定属性 |
| `ALL` | メインテーブルの全属性 |

今回 `ALL` を選んだ理由: タグ+難易度で検索したとき、一覧に問題タイトル/URL も表示したい → GSI から全情報取得で実装シンプル。ストレージコストは問題メタデータ規模なら無視できる。

##### `attribute` ブロックが3つになる理由

メインPK + GSI-PK + GSI-SK の3つが「キーとして使われる属性」だから。

### Step 3: `outputs.tf` の設計判断

#### 何を公開するか

モジュールの消費者は Lambda。Lambda に必要な値は:

| 値 | 用途 |
|---|---|
| テーブル名 (`name`) | Lambda環境変数 → boto3 で `Table(name)` |
| テーブルARN (`arn`) | IAM ポリシーの `Resource` 指定 |

3テーブル × 2値 = 6個の output。

#### `aws_dynamodb_table.users.name` の記法

```
<リソースタイプ>.<Terraform内の識別子>.<属性>
```

使える属性は Terraform provider のドキュメント "Attributes Reference" を参照。

#### ARN と name を両方出す理由

- **name**: アプリケーション層で使う（Lambda env → boto3）
- **ARN**: IAM 層で使う（Resource指定）

両方必要になることが確定している。**後から追加すると使う側も変更**になるので、先に両方公開しておく。

#### `description` を省略している判断

- output名が自己説明的（`users_table_arn` 等）
- 実装計画書に従って省略
- チーム開発なら書く流派もあり。今回は簡素化

### Step 4+5: ルート側への接続

#### modules.tf — モジュール呼び出し

```hcl
module "dynamodb" {
  source = "./modules/dynamodb"

  project_name = var.project_name
  environment  = var.environment
}
```

- `source = "./modules/dynamodb"` で相対パス指定（ローカルモジュール）
- Terraform Registry 公開モジュールを使う場合は `source = "terraform-aws-modules/dynamodb-table/aws"` 形式
- 依存解決は Terraform が自動で行う（モジュール間参照で自動的に作成順が決まる）

#### ルート outputs.tf — 外への公開

```hcl
output "dynamodb_users_table_name" {
  description = "DynamoDB users table name"
  value       = module.dynamodb.users_table_name
}
# ... submissions, problems も同様
```

##### なぜ ARN はルートに出さない？

ルートの output は **「`terraform apply` 実行者が CLI で見たい値」**。

- テーブル名 → 人が Lambda 環境変数に手動設定するとき等に使う
- ARN → モジュール間参照（`module.lambda → module.dynamodb.users_table_arn`）でしか使わない

モジュール間でしか使わない値はルートまで露出させない。

### Step 6: terraform validate

構文・参照・必須引数をオフラインでチェック。AWS に繋がず無料・高速。

```bash
terraform validate
# → Success! The configuration is valid.
```

検証**されない**: AWS API の受諾可否、認証情報、実リソースの作成。

### 設計判断の裏で働いた原則

| 原則 | 適用例 |
|---|---|
| YAGNI | `billing_mode` を variable化しない、default書かない |
| 明示性 > 暗黙のデフォルト | モジュール側で default を書かず呼び出し側に明示させる |
| 公開は最小に | ARN はモジュール間参照のみ、ルートには出さない |
| 将来の変更を予測 | name + ARN の両方を先に output として出す |
| コードとコメントで意図を残す | `user_id = Cognito sub` のコメント、学習ノートへのリンク |

## Q&A

**Q: `variables.tf` / `main.tf` / `outputs.tf` に分けるのはなぜ？**

Terraform はディレクトリ単位で `.tf` を全部まとめて読むので、ファイル分割は**人間のための慣習**（構文的には1ファイルでも動く）。関数アナロジーで `variables.tf` = 引数、`main.tf` = 関数本体、`outputs.tf` = 戻り値。分けると変更差分・検索効率・モジュール契約の明確さが向上する。

**Q: default とは？なぜモジュール側には書かない？**

`variable` に既定値を設定するもの（関数のデフォルト引数に相当）。モジュール側で `default` を書くと、呼び出し側が渡し忘れてもサイレントに既定値が使われバグの温床になる。モジュールは汎用部品として使うので、呼び出し側に明示させるほうが安全。ルート（呼び出し側）には書いてOK。

**Q: `type=S` は string のこと？ `attribute` は PK/SK のようなキー属性だけ？**

両方合っている。`S`(String) / `N`(Number) / `B`(Binary) の3種のみキーに使える。`attribute` ブロックはキーで使われている属性だけを宣言し、使用側（`hash_key` / `range_key` / GSI key）と一致する必要がある。非キー属性は書かない。

**Q: スキーマレスだから Python 等でキーさえ指定すればやりたい放題？**

ほぼその通り。キー（PK, SK）は必須で型も宣言通りに渡す必要があるが、非キー属性は何個でも・型も自由・ネストOK・アイテムごとに違ってOK。落とし穴はアプリ側でスキーマ管理する責務が増えること（Pydantic等）、アイテムサイズ400KB上限、予約語注意、等。

**Q: ARN って何？**

AWS リソースを一意に識別する絶対的なID（URL/物理住所のようなもの）。形式は `arn:aws:<service>:<region>:<account>:<path>`。IAM ポリシーで対象リソースを指定するときや、サービス間連携で使う。テーブル名は AWS アカウント・リージョン内で一意なだけで、ARN はグローバルに一意。

## 関連

- [01-dynamodb-keys.md](01-dynamodb-keys.md) - DynamoDBのキー設計（PK/SK/GSI）
- [03-module-design-patterns.md](03-module-design-patterns.md) - モジュール分割の流派
- [04-dynamodb-item-design.md](04-dynamodb-item-design.md) - スキーマレスとアイテム設計
- [05-user-id-identity.md](05-user-id-identity.md) - user_id = Cognito sub の区別
- [reference/terraform-basics.md](reference/terraform-basics.md) - Terraform基礎リファレンス
- [reference/iam-overview.md](reference/iam-overview.md) - IAM/ARN詳細
- [reference/terraform-defaults-vs-python-defaults.md](reference/terraform-defaults-vs-python-defaults.md) - `default` をルートに書きモジュールに書かない理由、Python の default 引数との比較

---

_Saved at 2026-04-18 via /learning-flow:topic_
