# DynamoDB キー設計 vs RDB — 比較リファレンス

## 1. 設計思想の根本的な違い

| 観点 | RDB (リレーショナルDB) | DynamoDB (NoSQL) |
|---|---|---|
| 設計の出発点 | データの正規化（重複を排除） | アクセスパターン（どんなクエリを投げるか） |
| 設計の順序 | スキーマ設計 → あとからクエリ最適化 | **先にクエリパターンを決める** → それに合わせてスキーマ設計 |
| データの持ち方 | 正規化（テーブル分割、JOINで結合） | 非正規化（関連データをまとめて持つ） |
| 柔軟性 | 任意のWHERE句、JOIN、サブクエリ可 | 事前定義したキーでのアクセスのみ高速 |
| スケーラビリティ | 垂直スケール中心（サーバースペック増強） | 水平スケール（パーティション自動分散） |

> **重要**: RDBでは「まずデータを正規化し、あとからクエリを最適化」する。DynamoDBでは「先にアクセスパターンを全て洗い出し、それに基づいてキーを設計」する。順序が逆。

---

## 2. キーの概念比較

### RDBの主キーとインデックス

```sql
-- RDBでのテーブル定義
CREATE TABLE submissions (
    id          BIGINT PRIMARY KEY,        -- 主キー（1カラム）
    user_id     VARCHAR(255),
    problem_id  VARCHAR(255),
    result      VARCHAR(10),
    submitted_at TIMESTAMP
);

-- インデックスは後から自由に追加できる
CREATE INDEX idx_user_id ON submissions(user_id);
CREATE INDEX idx_problem ON submissions(problem_id, result);
```

RDBでは:
- 主キーは行を一意に特定するだけ
- WHERE句で任意のカラムを指定できる（インデックスがなくても動く、遅いだけ）
- インデックスは後から追加・削除が自由

### DynamoDBのPK / SK / GSI

```
DynamoDBでのテーブル定義（概念）:

submissions テーブル:
  PK (Partition Key): user_id     ← データのグループ化（物理配置を決定）
  SK (Sort Key):      submission_id ← グループ内の並び順・個別特定

  → Query(PK="user-123") で「user-123の全提出」を高速取得
  → GetItem(PK="user-123", SK="SUB#12345") で1件を特定
```

DynamoDBでは:
- PKはデータの**物理的な配置場所**を決める（ハッシュ関数で分散）
- SKはパーティション内の**ソート順**を決める
- PK以外での検索にはGSI（Global Secondary Index）が必要

---

## 3. PK（Partition Key）詳細

### 役割

PKの値をハッシュ関数に通して、データを格納する物理パーティションを決定する。

```
PK値 "user-123" → ハッシュ関数 → パーティション A に格納
PK値 "user-456" → ハッシュ関数 → パーティション B に格納
PK値 "user-789" → ハッシュ関数 → パーティション A に格納（ハッシュが同じ場合）
```

### 制約

- PKでの検索は**完全一致のみ**（`=` だけ、`LIKE` や `>=` は不可）
- PKの値は変更不可（変更したい場合はアイテムを削除→再作成）
- カーディナリティ（値の種類）が高い属性を選ぶべき

### 設計のコツ

| 良いPK | 悪いPK | 理由 |
|---|---|---|
| `user_id` | `status`（"active"/"inactive"） | statusは2値しかなく、データが偏る（ホットパーティション） |
| `order_id` | `country`（"JP"/"US"/...） | 特定の国にアクセスが集中する可能性 |
| `device_id` | `created_date` | 日付だと当日のパーティションにアクセス集中 |

---

## 4. SK（Sort Key）詳細

### 役割

同じPK内でデータを**ソート順に並べて格納**する。範囲クエリが可能。

```
パーティション PK="user-123" 内:

  SK: "SUB#00001"  →  { problem: "abc300_a", result: "AC",  submitted_at: 1700000000 }
  SK: "SUB#00002"  →  { problem: "abc300_b", result: "WA",  submitted_at: 1700000060 }
  SK: "SUB#00003"  →  { problem: "abc300_c", result: "AC",  submitted_at: 1700000120 }
  SK: "SUB#00004"  →  { problem: "abc301_a", result: "TLE", submitted_at: 1700001000 }
       ↑ ソート済み
```

### クエリの種類

| 操作 | 例 | RDB相当 |
|---|---|---|
| 完全一致 | `SK = "SUB#00002"` | `WHERE submission_id = 'SUB#00002'` |
| 前方一致 | `SK begins_with "SUB#"` | `WHERE submission_id LIKE 'SUB#%'` |
| 範囲 | `SK BETWEEN "SUB#00001" AND "SUB#00003"` | `WHERE submission_id BETWEEN ...` |
| 以上/以下 | `SK >= "SUB#00003"` | `WHERE submission_id >= 'SUB#00003'` |

### 複合ソートキーパターン

SKに複数の情報を埋め込むことで、より柔軟なクエリが可能:

```
SK: "2024-01-15#AC#abc300_a"
     日付      結果  問題ID

→ begins_with("2024-01") で2024年1月の提出のみ取得
→ begins_with("2024-01-15#AC") で特定日のAC提出のみ取得
```

---

## 5. GSI（Global Secondary Index）詳細

### RDBのインデックスとの違い

| 観点 | RDBのインデックス | DynamoDBのGSI |
|---|---|---|
| 作成タイミング | いつでも自由に追加・削除 | いつでも追加可（ただし既存データの再構築が発生） |
| ストレージ | 元データへのポインタ | **データのコピーが別途作成される** |
| コスト | ストレージのみ | ストレージ + スループット（読み書き両方） |
| 一貫性 | 常に最新（同一トランザクション） | **結果整合性**（数ミリ秒の遅延あり） |
| 上限 | 実質無制限 | 1テーブルあたり最大20個 |
| クエリ | 元テーブルと同じSQLで利用 | GSI用に別途Queryを実行 |

### GSIの仕組み

GSIは「元テーブルのデータを、別のPK+SKの組み合わせでコピーしたもの」。

```
【元テーブル: problems】
PK: problem_id

problem_id         | title  | tag    | difficulty
PROBLEM#abc300_a   | A問題  | 全探索  | 200
PROBLEM#abc300_b   | B問題  | DP     | 500
PROBLEM#abc300_c   | C問題  | 全探索  | 800

↓ GSI "TagDifficultyIndex" が自動でコピーを作成

【GSI: TagDifficultyIndex】
GSI PK: tag,  GSI SK: difficulty

パーティション "全探索":
  difficulty=200 → { problem_id: "PROBLEM#abc300_a", title: "A問題" }
  difficulty=800 → { problem_id: "PROBLEM#abc300_c", title: "C問題" }

パーティション "DP":
  difficulty=500 → { problem_id: "PROBLEM#abc300_b", title: "B問題" }
```

### GSI設計のベストプラクティス

1. **必要最小限にする**: GSIはストレージとスループットのコストがかかる
2. **射影（Projection）を最適化する**: 全属性をコピー（ALL）するか、必要な属性のみ（INCLUDE）にするか
3. **ホットパーティションを避ける**: GSIのPKにもカーディナリティの高い属性を選ぶ
4. **スパースインデックスを活用する**: GSI PKに設定した属性が存在しないアイテムはGSIに含まれない → フィルタとして機能

### LSI（Local Secondary Index）との違い

| 観点 | GSI | LSI |
|---|---|---|
| PK | 元テーブルと異なるPKを指定可能 | 元テーブルと同じPK |
| SK | 自由に指定 | 元テーブルと異なるSKを指定 |
| 作成タイミング | いつでも | **テーブル作成時のみ** |
| 一貫性 | 結果整合性のみ | 強い整合性も選択可能 |
| 上限 | 20個/テーブル | 5個/テーブル |
| 用途 | 全く異なるアクセスパターン | 同じPKで別のソート順が欲しい場合 |

---

## 6. 実践: 同じデータをRDBとDynamoDBで設計比較

### ユースケース: 「ユーザーの提出一覧を取得」「特定の問題のAC率を計算」

#### RDB設計

```sql
-- 正規化されたテーブル
CREATE TABLE users (
    id VARCHAR(255) PRIMARY KEY,
    atcoder_username VARCHAR(255)
);

CREATE TABLE submissions (
    id BIGINT PRIMARY KEY,
    user_id VARCHAR(255) REFERENCES users(id),
    problem_id VARCHAR(255),
    result VARCHAR(10),
    submitted_at TIMESTAMP
);

-- クエリ1: ユーザーの提出一覧
SELECT * FROM submissions WHERE user_id = 'abc123' ORDER BY submitted_at DESC;

-- クエリ2: 問題のAC率
SELECT 
    problem_id,
    COUNT(*) AS total,
    SUM(CASE WHEN result = 'AC' THEN 1 ELSE 0 END) AS ac_count
FROM submissions
WHERE problem_id = 'abc300_a'
GROUP BY problem_id;
```

→ RDBではどちらのクエリもSQLで書ける。インデックスで最適化するだけ。

#### DynamoDB設計

```
submissions テーブル:
  PK: user_id,  SK: SUB#{submission_id}
  → クエリ1は Query(PK="abc123") で解決

  しかしクエリ2（problem_idで検索）はPKが user_id なのでできない
  → GSIが必要:

GSI "ProblemIndex":
  GSI PK: problem_id,  GSI SK: submission_id
  → Query(GSI, PK="abc300_a") でその問題の全提出を取得し、アプリ側でAC率を計算
```

→ DynamoDBではアクセスパターンごとにキーやGSIを設計する必要がある。

---

## 7. 判断基準: いつDynamoDBを選ぶか

| DynamoDBが向いている場合 | RDBが向いている場合 |
|---|---|
| アクセスパターンが事前に明確 | アドホックなクエリが多い |
| 高スループット・低レイテンシが必要 | 複雑なJOIN・集計が必要 |
| サーバーレス構成（Lambda連携） | トランザクションの厳密性が重要 |
| データ量が大きくスケールが必要 | データ量が小〜中規模 |
| キーバリュー/ドキュメント型のデータ | リレーショナルなデータ構造 |
| 運用負荷を下げたい（フルマネージド） | 既存のSQL資産を活かしたい |

---

## 参考資料

- [Core components of Amazon DynamoDB - AWS公式ドキュメント](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.CoreComponents.html)
- [DynamoDB Partition Key vs Sort Key: Complete Guide - Dynomate Blog](https://dynomate.io/blog/dynamodb-partition-key-vs-sort-key/)
- [NoSQL design for DynamoDB - AWS公式ドキュメント](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-general-nosql-design.html)
- [Choosing between relational (SQL) and NoSQL - AWS公式ドキュメント](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/SQLtoNoSQL.WhyDynamoDB.html)
- [Global Secondary Indexes (GSI) in DynamoDB: Complete Guide - Dynomate Blog](https://dynomate.io/blog/dynamodb-gsi/)
- [General guidelines for secondary indexes in DynamoDB - AWS公式ドキュメント](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-indexes-general.html)
- [Choosing the Right DynamoDB Partition Key - AWS Database Blog](https://aws.amazon.com/blogs/database/choosing-the-right-dynamodb-partition-key/)
- [DynamoDB Global Secondary Index - The Ultimate Guide - Dynobase](https://dynobase.dev/dynamodb-gsi/)
