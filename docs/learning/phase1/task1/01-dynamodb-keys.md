# DynamoDB キー設計

## 解説

### なぜDynamoDBか

- **サーバーレス構成との相性**: Lambda + DynamoDBはどちらもマネージドで、接続プールの管理が不要。RDSだとLambdaからの同時接続数の管理が必要になる
- **コスト**: オンデマンドモードなら使った分だけ課金。個人利用で月$1-3で済む
- **スケーラビリティ**: テーブル設計さえ正しければ、データ量が増えても自動スケール

### キー設計が全て

RDBと違いDynamoDBにはJOINがないため、「どんなクエリを投げるか」から逆算してテーブルを設計する。

| テーブル | PK | SK | 主なクエリ |
|---|---|---|---|
| users | `user_id` | - | ユーザー情報の取得・更新 |
| submissions | `user_id` | `SUB#{submission_id}` | あるユーザーの提出一覧を取得 |
| problems | `PROBLEM#{problem_id}` | - | 問題情報の取得 |

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

### Q4: GSIがあればPK/SKはいらないのでは？

**GSIだけでは駄目。** GSIは元テーブルのコピーであり、本体ではない。

- 書き込みは元テーブルのPK/SKに対してのみ行う。GSIに直接書き込むことはできない
- GSIは結果整合性のみ（書き込み直後に古いデータが返る可能性がある）
- GSIを1つ追加するごとに書き込みコストが倍増する（元テーブル + GSI分）

PK/SKは「データの住所」として必ず必要。GSIは「別の検索窓口」。

### Q5: PK + SKだけで一意性が保てない場合はどうする？

**SKの設計で工夫する。** 例えば同じ問題に複数回提出する場合:

- `PK=user_id, SK=problem_id` → 上書きされるのでNG
- `PK=user_id, SK=SUB#{submission_id}` → submission_idがユニークなのでOK

さらに深い階層（提出の中のテストケースごと等）が必要な場合は:
1. **SK階層化**: `SUB#12345#TC#01` のように文字列で階層を表現
2. **ネスト構造**: 1アイテム内にリストとして持つ
3. **テーブル分割**: 完全に独立したデータなら別テーブル

→ 詳細は [リファレンス: 7. PK + SK で一意性が足りない場合の対処法](reference/dynamodb-keys-vs-rdb.md) 参照

### Q6: そもそもDynamoDBはなぜこんな構造にしているのか？

**「どんなデータ量でも同じ速度を保証するため」。**

RDBは柔軟にクエリできるが、データが増えると遅くなる（垂直スケールの限界）。DynamoDBはPKのハッシュ値でデータを最初から複数サーバーに分散配置する。`Query(PK="abc123")` は該当サーバーだけ見ればいいので、テーブルが100行でも100億行でも数ミリ秒で返る。

「PKでしか検索できない」のは制限ではなく、「どのサーバーに聞けばいいか一発でわかる」ための設計。Amazon.comのショッピングカートという何億人規模のシステムのために生まれたDB。

→ 詳細は [リファレンス: 8. DynamoDBがこの構造を採用している理由](reference/dynamodb-keys-vs-rdb.md) 参照

### Q7: GSIはたくさん作ったらコストが爆発するのか？

**はい。GSIは実質的に別テーブルを自動作成しているのと同じ。**

物理的には元テーブルとGSIは別のストレージに存在する。「自分でテーブルを複数作って手動同期する」のと「1テーブル + GSI」の違いは、DynamoDBが同期を自動でやってくれるという点だけ。

コストの増え方:
- 書き込み: GSI 0個=1 WCU、GSI 5個=6 WCU（6倍）、GSI 20個(上限)=21 WCU（21倍）
- ストレージ: 射影設定（ALL/KEYS_ONLY/INCLUDE）で制御可能だが、ALLなら丸ごとコピー

個人利用では誤差レベルだが、大規模サービスではGSIの数がそのままコストに直結する。だから「GSIは最小限に」がベストプラクティス。

検討の優先順位:
1. PK/SKの設計で解決できないか（追加コストなし）
2. SK階層化やネスト構造で対応できないか（追加コストなし）
3. GSIを追加する（Projection最小限で）（コスト増）
4. 別テーブルに分ける（管理コスト増）

### Q8: GSIの詳細 — 内部の仕組み、設定項目、制約

GSIは元テーブルにアイテムを書くと、DynamoDBが裏でGSI用のストレージにデータをコピーしてGSIのPK/SKで再配置する。

GSIで指定する3つの設定:
1. **キー（PK + SK）**: 元テーブルのどの属性でもOK
2. **射影（Projection）**: コピーする属性の範囲（ALL/KEYS_ONLY/INCLUDE）。コストに直結
3. **キャパシティ**: 元テーブルとは独立したスループット

GSIの制約:
- 数の上限: 1テーブルあたり20個
- 一貫性: 結果整合性のみ（強い整合性は不可）
- 書き込み: GSIに直接書き込めない（元テーブル経由で自動同期）
- ユニーク制約: なし（GSIのPK+SKは重複してもOK）
- スロットリング: GSIのスループットが足りないと元テーブルの書き込みまで遅くなる

### Q9: DBの基本 — 主キーとは何か

データベースは表（テーブル）にデータを保存するもの。データが増えると「特定の1行を確実に見つける手段」が必要になり、それが主キー（Primary Key）。

RDBでもDynamoDBでも主キーは必須だが、違いは:
- **RDB**: 主キーは「住所」で、それ以外のカラムでも自由に検索できる
- **DynamoDB**: PK（とSK）が唯一の高速な検索手段。それ以外にはGSIが必要

PK/SKはDynamoDB独自の用語だが、やっていることは「主キーの指定」。DynamoDBでは主キーの重要性がRDBより遥かに高いため、専用の名前で強調されている。

## 関連

- [04-dynamodb-item-design.md](04-dynamodb-item-design.md) - スキーマレスとアイテム設計（attribute宣言、Python例、Single Table Design）
- [05-user-id-identity.md](05-user-id-identity.md) - user_id = Cognito sub の区別
- [06-dynamodb-module-implementation.md](06-dynamodb-module-implementation.md) - Task 1 実装の設計判断ログ
- [reference/dynamodb-keys-vs-rdb.md](reference/dynamodb-keys-vs-rdb.md) - DynamoDB vs RDB 詳細比較（Web検索ソース付き）
