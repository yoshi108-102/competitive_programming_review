# ユーザーIDの正体（Cognito sub vs AtCoder handle）

## 概要

このプロジェクトには「ユーザーID」的な値が **2種類** 登場する。users テーブルの PK である `user_id` は **Cognito sub** のことであり、AtCoder のハンドル名ではない。この区別が曖昧だと設計ミスにつながる。

## 解説

### 2つのユーザーIDの違い

| 種類 | 例 | 出所 | 役割 |
|---|---|---|---|
| **Cognito sub** | `abc123-def456-...` (UUID) | 認証基盤（Cognito） | このアプリの内部ユーザーID。PKとして使う |
| **AtCoder handle** | `tourist`, `yoshi108-102` | AtCoder の URL | AtCoder のハンドル名。ユーザーが「連携」で自分の手で入力する値 |

### なぜ Cognito sub を PK にするのか

#### 理由1: 認証基盤が source of truth

ユーザーがこのアプリにログインする際、Cognito で認証する → Cognito が JWT (IDトークン) の中に sub を入れて返す。アプリ側はユーザーが誰かを判別するのに Cognito sub を使う。AtCoder の handle は「アプリ内の属性」に過ぎない（ユーザーが申告した値）。

#### 理由2: sub は不変、handle は変わりうる

- **Cognito sub**: Cognito User Pool 内で一意・不変（ユーザー登録時に自動採番）
- **AtCoder handle**: AtCoder側で変更できる

PK を handle にすると、handle 変更時に「全submissionsのキーを書き換える」という悲劇が起きる。sub なら安定。

#### 理由3: 未連携ユーザーも扱える

ユーザーが「まずはこのアプリにサインアップしたが、AtCoder アカウントはまだ連携していない」状態もありうる。このとき handle はまだ存在しない。sub なら最初からある。

### users テーブルの実際のアイテムイメージ

```json
{
  "user_id": "abc123-def456-789",        // PK。Cognito sub。ユーザーが入力しない値
  "handle": "yoshi108-102",              // AtCoder のハンドル（ユーザー申告）
  "atcoder_linked_at": "2026-04-18T10:00:00Z",
  "created_at": "2026-04-18T09:55:00Z"
}
```

- PK = Cognito sub
- 非キー属性として handle を持つ
- アプリのフロー: 「ログイン → users テーブル取得 → handle を読む → AtCoder API 叩く」

### submissions テーブルの意味

```json
{
  "user_id": "abc123-def456-789",  // PK。Cognito sub（users.user_idと一致）
  "submission_id": "SUB#12345",    // SK。AtCoder側のsubmission ID
  "problem_id": "abc300_a",
  "result": "AC"
}
```

**submissions.user_id = users.user_id** で users テーブルと論理的に結合している（RDB の FK 的な発想。ただし DynamoDB は FK 制約を持たない）。

### 命名についての選択肢

| 命名 | メリット | デメリット |
|---|---|---|
| `user_id`（現状） | 短い、一般的 | AtCoder handle と混同しやすい |
| `cognito_sub` | 意図が明確 | 冗長、AWSサービス名が漏れる |
| `sub` | JWT の用語と一致 | 短すぎ、文脈ないと分からない |
| `internal_user_id` | 意図が明確 | 長い |

実装計画書は `user_id` を採用。**コード上のコメントで明記する**のが実用的。現状のコメント:

```hcl
# users テーブル: Cognito sub をキーに、ユーザーメタデータを保存
```

このコメントで「user_id = Cognito sub」の意図を補う設計判断。

## Q&A

**Q: `user_id` というのは、AtCoder の user_id のことという認識で良い？**

違う。`user_id` は **Cognito sub**（このアプリの内部ユーザーID）のこと。AtCoderのハンドル名ではない。

- **Cognito sub** = 認証基盤が発行する不変のUUID。ユーザーが入力しない
- **AtCoder handle** = ユーザーが連携時に申告する AtCoder のハンドル名

AtCoder のハンドルは users テーブルの**非キー属性** `handle` として格納する。

PK に Cognito sub を使う理由:
1. 認証基盤が source of truth（JWT に sub が入って返る）
2. sub は不変、handle は変更される可能性がある
3. 未連携ユーザー（サインアップしたが AtCoder連携していない）も扱える

## 関連

- [01-dynamodb-keys.md](01-dynamodb-keys.md) - DynamoDBのキー設計（PK/SK/GSI）
- [04-dynamodb-item-design.md](04-dynamodb-item-design.md) - DynamoDBのアイテム設計

---

_Saved at 2026-04-18 via /learning-flow:topic_
