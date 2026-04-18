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

## 7. PK + SK で一意性が足りない場合の対処法

PK + SK の2キーだけで、あらゆるデータの一意性と検索要件を満たせるわけではない。

### 問題の例

```
PK=user_id, SK=problem_id の場合:

PK: "abc123", SK: "abc300_a" → 1回目のAC提出
PK: "abc123", SK: "abc300_a" → 2回目のWA提出  ← 重複！上書きされる
```

DynamoDBではPK+SKが同じアイテムは上書きされるため、この設計では同じ問題への複数提出を保存できない。

### 対処法1: SKに一意な値を含める

```
PK: "abc123", SK: "SUB#12345" → abc300_a へのAC提出
PK: "abc123", SK: "SUB#12346" → abc300_a へのWA提出  ← 別アイテム、OK
```

### 対処法2: SKを階層化して深い構造を表現する

提出の中にテストケースごとの結果がある場合:

```
PK: "abc123", SK: "SUB#12345"            → 提出のメタデータ
PK: "abc123", SK: "SUB#12345#TC#01"      → テストケース1の結果
PK: "abc123", SK: "SUB#12345#TC#02"      → テストケース2の結果
PK: "abc123", SK: "SUB#12345#TC#03"      → テストケース3の結果
```

SKの前方一致検索（`begins_with`）を活用:
- `begins_with "SUB#12345"` → 提出メタデータ + 全テストケース
- `begins_with "SUB#12345#TC#"` → テストケースだけ
- `= "SUB#12345#TC#03"` → テストケース3だけ

### 対処法3: アイテム内にリストで持つ（ネスト構造）

```json
{
  "PK": "abc123",
  "SK": "SUB#12345",
  "problem_id": "abc300_a",
  "test_cases": [
    { "id": 1, "result": "AC", "time": 10 },
    { "id": 2, "result": "AC", "time": 15 },
    { "id": 3, "result": "WA", "time": 20 }
  ]
}
```

DynamoDBはJSON的なネスト構造を1アイテム内に持てる。テストケース個別の検索が不要ならこちらがシンプル。

### 対処法の比較

| | SK階層化 | リストで持つ | テーブル分割 |
|---|---|---|---|
| 個別検索 | できる | できない | できる |
| 個別更新 | できる | アイテムごと書き換え | できる |
| 取得効率 | 複数アイテム取得 | 1アイテムで全部 | 複数テーブルに問い合わせ |
| 適するケース | 個別操作が必要 | まとめて取得すればOK | 完全に独立したデータ |

---

## 8. DynamoDBがこの構造を採用している理由

### RDBの限界: スケールの壁

RDBはデータ量が増えると問題が出る:

```
100万行:   インデックスがあれば高速（数ms）
1億行:     JOINが遅くなり、サーバー増強が必要（垂直スケール）
100億行:   1台のサーバーでは限界、シャーディングを自前で設計・運用する必要がある
```

### DynamoDBの戦略: 最初から分散する

PKのハッシュ値でデータを最初から複数のサーバーに分散配置する:

```
PKの値 → ハッシュ関数 → どのサーバーに置くか決まる

サーバーA: user_id="abc123" のデータ全部
サーバーB: user_id="def456" のデータ全部
サーバーC: user_id="ghi789" のデータ全部
```

この構造により:
- `Query(PK="abc123")` → サーバーAだけ見ればいい
- 他のサーバーのデータ量は関係ない
- **テーブルが100行でも100億行でも、常に数ミリ秒で返る**
- データが増えたらサーバーを足すだけ（水平スケール）

### 制約は代償ではなく設計の根幹

| RDB | DynamoDB |
|---|---|
| 任意のカラムで検索できる | PKでしか高速検索できない |
| → 全データを知っているサーバーが必要 | → 該当サーバーだけ見ればいい |
| → スケールしにくい | → 無限にスケールする |

「PKでしか検索できない」のは、**「どのサーバーに聞けばいいか一発でわかる」ための仕組み**。任意のカラムで検索を許すと「どのサーバーにデータがあるかわからない」→「全サーバーに聞く」→ 分散の意味がなくなる。

### GSIが「コピー」である理由もここにある

GSIは別のPKで分散し直したコピー:

```
元テーブル: user_id で分散
  サーバーA: user_id="abc123" → [提出1, 提出2, 提出3]
  サーバーB: user_id="def456" → [提出4, 提出5]

GSI: problem_id で分散（コピー）
  サーバーX: problem_id="abc300_a" → [提出1, 提出4]
  サーバーY: problem_id="abc300_b" → [提出2, 提出5]
```

「別の切り口で検索」=「別の基準で分散配置し直す」= データのコピーが必要 → コスト増。

### DynamoDB誕生の背景

Amazon.comのショッピングカートという、何億人ものユーザーが同時にアクセスするシステムのために生まれた。柔軟性よりも「絶対に遅くならないこと」が最優先だった。

```
RDBの考え方:
  「何でも検索できるようにして、遅くなったらチューニングする」
  → 柔軟だが、規模が大きくなると限界がくる

DynamoDBの考え方:
  「検索方法を制限する代わりに、どんな規模でも同じ速度を保証する」
  → 制約があるが、規模に関係なく数ミリ秒で応答する
```

---

## 9. DynamoDBのデメリット（RDBと比較しての弱点）

セクション8までは DynamoDB の設計思想と強みを説明してきたが、その裏返しとして明確な弱点もある。ここでは「どういう場面で DynamoDB が向かないか」を具体的に洗い出す。

### 9.1 アクセスパターンを「事前に」全部決める必要がある

RDB なら「とりあえずテーブル作って、検索要件は後から考える」で何とかなる。DynamoDB では設計時点でアクセスパターンを読み切れないと致命傷。

```
設計時:    user_id で引く、problem_id で引く、tag+difficulty で引く、の3パターン
         ↓
実装後:  「やっぱり result=AC だけを日付順で一覧したい」
         ↓
対応:    GSI 追加 → 既存データの再構築 + 追加コスト
```

RDB なら `CREATE INDEX` 一発で済む話が、DynamoDB では設計見直し・GSI追加・非正規化の作り直し、という大きな手戻りになる。

### 9.2 JOINがない → 非正規化の代償

```
RDB:
  users と submissions を JOIN
  → ユーザー名が変わったら users.name を1箇所更新すれば全クエリに反映

DynamoDB:
  submissions の中に username を埋め込む（非正規化）
  → ユーザー名が変わったら、その人の全 submissions を更新しないといけない
```

**書き込み時の整合性維持がアプリ側の責任**になる。「更新忘れ → データ不整合」のバグが出やすい。

### 9.3 集計・分析クエリが壊滅的に苦手

SQL なら1行で書けるものが、DynamoDB では大仕事。

| やりたいこと | RDB | DynamoDB |
|---|---|---|
| 全ユーザー数 | `SELECT COUNT(*) FROM users` | 全件 Scan（高コスト・遅い） |
| 問題ごとのAC率 | `GROUP BY problem_id` | GSI 取得 → **アプリ側で集計** |
| 平均提出時間 | `AVG(time)` | 全件取ってアプリで計算 |
| 月次レポート | SQL 一発 | DynamoDB Streams → S3 → Athena の別パイプライン |

**BIツール・分析用途には不向き**。本格的な分析が必要なら DynamoDB Streams で S3 に流して Athena で SQL を叩く、といった別系統の仕組みを組む。

### 9.4 トランザクションの制約

`TransactWriteItems` はあるが、制約が多い:

- **最大100アイテム / 4MB** まで
- **書き込みコストが通常の2倍**
- クロスリージョン不可
- 複雑な分岐ロジック（条件 → 更新 or ロールバック）は組みにくい

銀行の勘定系のような厳密なトランザクション要件には不向き。

### 9.5 結果整合性（Eventual Consistency）の罠

```
書き込み:
  サーバーA に書き込み
  → サーバーB, C にレプリカ複製（数ms〜数十ms）
  → その隙間に B から読むと「古いデータ」が返る
```

- **GSIは常に結果整合性のみ**（強整合性を選べない）
- ベーステーブルは `ConsistentRead=true` で強整合性にできるが、RCU コストが2倍

「書いた直後に読んだのに、反映されてない?」という挙動に初心者はハマりやすい。

### 9.6 ホットパーティション問題

```
PK = "status" (値は "active" or "inactive" の2種類)
  → ほぼ全データが "active" のパーティションに集中
  → そのパーティションだけスループット上限（3000 RCU / 1000 WCU）に張り付く
  → 他のパーティションは暇なのに、全体として遅くなる → スロットリング
```

PK 設計のミスが**性能的な爆弾**になる。RDB なら「インデックス効いてないけど動く」で済むが、DynamoDB はスロットリングで**エラーが返る**。

### 9.7 アイテムサイズ 400KB 上限

1アイテムは最大 **400KB**。

- 画像・PDF・長いソースコードの丸ごと保存は不可 → S3 に置いて ARN だけ DynamoDB に保存する二段構え
- JSON ネスト構造を富豪的に持つと上限に引っかかる
- 対処法3（リストで持つ）も大量データでは限界

### 9.8 クエリ柔軟性の欠如

DynamoDB 単体ではできないこと:

- `LIKE "%キーワード%"` の部分一致検索 → OpenSearch などに流す必要あり
- 複数条件の `OR`（GSI で別々にクエリして自分でマージ）
- 非キー属性でのフィルタは「取得後にフィルタ」なので読み込み量は変わらない（= RCU コスト発生）

**「動的な検索条件を受け付ける管理画面や全文検索」は DynamoDB 単体では作れない。**

### 9.9 コスト予測の難しさ

| RDB (RDS) | DynamoDB |
|---|---|
| インスタンス代（固定）+ ストレージ | RCU/WCU × クエリ数 × アイテムサイズ |
| 使わなくても固定費 | 使った分だけ課金（オンデマンド） |
| 見積もりしやすい | **使い方で桁が変わる** |

GSI は「1テーブル分のコピー」相当なので、GSI 3つ = ストレージ4倍 + 書き込みコストも4倍。アクセスパターン追加＝コスト急増に直結する。

### 9.10 スキーマレスゆえの混乱

DynamoDB 自体はスキーマを強制しない。結果として:

- アプリのバージョン違いで属性名が混在（`userId` と `user_id` が両方存在、など）しても止まらない
- **バリデーションは 100% アプリ側の責任**
- 「このテーブルに何の属性が入り得るか」を別途ドキュメントで管理する必要がある

RDB なら `NOT NULL` や型制約が守ってくれるが、DynamoDB はノーガード。

### 9.11 ツール・エコシステムの弱さ

- SQL が使えないので、既存の BI ツール（Tableau, Redash, Metabase 等）が直接繋がらない
- ORM（SQLAlchemy, Prisma 等）の SQL 前提設計と相性が悪い
- アドホック分析は AWS コンソールだけでは厳しく、NoSQL Workbench 等の専用ツールが必要

### 9.12 学習コストと「常識の違い」

SQL の常識（JOIN、正規化、インデックスは後で追加）は**全部捨てる必要**がある。Single Table Design、非正規化、アクセスパターン駆動設計、という別の思考体系を学び直す必要がある。

チームに NoSQL 経験者がいないと、**RDB 風に設計してしまって性能もコストも両方失敗する**という典型的な事故が起きやすい。

### 9.13 デメリットが顕在化しやすいケース（まとめ）

| シチュエーション | なぜ DynamoDB が合わないか |
|---|---|
| アクセスパターンが固まっていない（プロトタイプ） | スキーマ変更コストが高い |
| 自由な検索機能を提供したい（管理画面・検索UI） | クエリ柔軟性が無い |
| 集計・レポートが中心 | 集計機能が無い |
| チームに SQL 経験者しかいない | 学習コストが高い |
| 厳密なトランザクションが必要（金融系） | トランザクションの制約が多い |
| データ量が中規模以下で頭打ち | スケール性能を活かせず RDB の方が楽 |

---

## 10. 判断基準: いつDynamoDBを選ぶか

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
