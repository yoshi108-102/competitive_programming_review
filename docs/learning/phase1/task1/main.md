# Phase 1 / Task 1: Terraform DynamoDB モジュール — 学習ノート

## 解説

### このタスクの目的

DynamoDBのテーブルを3つ（users, submissions, problems）Terraformで定義する。

### なぜDynamoDBか

- **サーバーレス構成との相性**: Lambda + DynamoDBはどちらもマネージドで、接続プールの管理が不要。RDSだとLambdaからの同時接続数の管理が必要になる
- **コスト**: オンデマンドモードなら使った分だけ課金。個人利用で月$1-3で済む
- **スケーラビリティ**: テーブル設計さえ正しければ、データ量が増えても自動スケール

### DynamoDB設計で押さえるべきポイント

#### 1. キー設計が全て

RDBと違いDynamoDBにはJOINがないため、「どんなクエリを投げるか」から逆算してテーブルを設計する。

| テーブル | PK | SK | 主なクエリ |
|---|---|---|---|
| users | `user_id` | - | ユーザー情報の取得・更新 |
| submissions | `user_id` | `SUB#{submission_id}` | あるユーザーの提出一覧を取得 |
| problems | `PROBLEM#{problem_id}` | - | 問題情報の取得 |

#### 2. なぜ submissions に user_id を PK にするか

「あるユーザーの提出一覧」が最も頻繁なクエリパターン。PKが同じアイテムは物理的に近くに保存されるので、クエリが高速になる。

#### 3. GSI (Global Secondary Index)

problems テーブルに `TagDifficultyIndex` というGSIを設定。Phase 2以降でタグ+難易度でフィルタリングするためのもの。テーブル作成後にGSIを追加するとデータの再構築が走るため、最初から定義しておく。

#### 4. billing_mode = "PAY_PER_REQUEST"

オンデマンドモード。個人利用ではProvisioned Capacityより安い。

### Terraformモジュール分離の考え方

`terraform/modules/dynamodb/` として独立モジュールにすることで:
- DynamoDBテーブルの変更が他のリソース（Lambda等）に波及しない
- `outputs.tf` でテーブル名とARNを公開し、他モジュールから参照できる

---

## 質疑応答

### Q1: PKとSKとは何？

**PK（Partition Key）**: データの物理的な配置場所を決めるキー。PKの値がハッシュ関数に通され、どのパーティション（物理ストレージ）にデータを格納するかが決まる。

**SK（Sort Key）**: パーティション内でデータを並べ替えるキー。範囲検索が可能。

DynamoDBのプライマリキーは2種類:
- **シンプルキー**: PKのみ（例: usersテーブル）
- **複合キー**: PK + SK（例: submissionsテーブル）

```
users テーブル（シンプルキー）:
PK: user_id = "abc123"  →  { atcoder_username: "chokudai", ... }

submissions テーブル（複合キー）:
PK: user_id = "abc123", SK: "SUB#12345"  →  { problem_id: "abc300_a", ... }
PK: user_id = "abc123", SK: "SUB#12346"  →  { problem_id: "abc300_b", ... }
```

データ取得の基本操作:
- **GetItem**: PK(+SK)を指定して1件取得
- **Query**: PKを指定してそのグループ全件取得

### Q2: PKとSKを別にする理由は？

**「グループで取得」と「個別で取得」の両方を効率的にやるため。**

PKだけの設計（`submission_id` をPKにした場合）:
- 個別取得: `GetItem(PK="SUB#12345")` → できる
- ユーザーの提出一覧: 全件スキャン（Scan）が必要 → **遅い、高コスト**

PK + SK の設計（`user_id` をPK、`submission_id` をSKにした場合）:
- ユーザーの提出一覧: `Query(PK="abc123")` → **高速**
- 個別取得: `GetItem(PK="abc123", SK="SUB#12345")` → **高速**

物理的に同じPKのアイテムは同じパーティションに格納され、SKでソート済み。だからQueryが高速。

### Q3: アクセスパターンによってはPKとSKとさらにキーを増やすこともありうるか？

**はい。GSI（Global Secondary Index）を追加する。**

GSIは「別のPK+SKの組み合わせで検索できるようにする」もの。元テーブルとは独立したインデックスが内部的に作られる。

例: problemsテーブルのPKは `problem_id` だが、「全探索タグの問題を難易度順に取得」したい場合:

```
GSI "TagDifficultyIndex":
  GSI PK: tag → "全探索" で検索
  GSI SK: difficulty → 難易度順にソート
```

RDBとの対比:
| RDB | DynamoDB |
|---|---|
| `WHERE user_id = ?` | PK で設計 |
| `WHERE user_id = ? AND id = ?` | PK + SK で設計 |
| `WHERE tag = ? ORDER BY difficulty` | GSI を追加 |
| 任意のWHERE句 | その都度GSIが必要（または Scan） |

GSIの制約:
- 1テーブルあたり最大20個
- データのコピーが作られるため、ストレージとスループットのコストが増加
- 結果整合性（数ミリ秒の遅延あり）

---

## リファレンス

- [DynamoDB キー設計 vs RDB 比較リファレンス](reference/dynamodb-keys-vs-rdb.md) — PK/SK/GSIとRDBの主キー/インデックスの詳細比較、設計パターン、判断基準

---

## 振り返り

（Task 1 実装完了後に記入）
