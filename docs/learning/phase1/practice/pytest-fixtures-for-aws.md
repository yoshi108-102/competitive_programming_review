# pytest fixtures for AWS — Lambda + moto のテスト設計パターン

## 概要

Task 2 の `conftest.py` が採用している **2段階 fixture 設計**（`aws_env` → `dynamodb_tables`）を読み解く。Lambda + DynamoDB + moto の組み合わせでは**ほぼ定石**のパターンで、以下の3つを同時に実現する:

1. **テーブル名を環境変数経由で渡す** — 本番/ステージング/テストで別の値を使えるようにする
2. **`monkeypatch` でテスト後に自動ロールバック** — テスト間の環境変数汚染を防ぐ
3. **fixture を2段階に分ける** — 必要最低限の準備だけを要求できる

また、moto が Terraform や実 AWS とは**完全に独立した「空のAWS」**を提供することから生じる**スキーマ二重管理問題**と、その対処方針（このプロジェクトでは手動同期を容認）も整理する。

## 解説

### moto は Terraform も実 AWS も読まない

重要な前提: moto が立ち上がった瞬間は**何もない真っ白なAWS**。

```
pytest 起動
  ↓
conftest.py が読まれる
  ↓
@mock_aws で moto が有効化
  ↓
「空のAWS」がメモリ上に生成される
  - テーブル 0個
  - S3 バケット 0個
  - Lambda 関数 0個
```

Terraform で定義した `atcoder-review-users` も、本物の AWS にある Cognito User Pool も、**一切知らない**。

### スキーマ二重管理問題

スキーマは `conftest.py` で **手書き**する必要がある:

```python
client.create_table(
    TableName=SUBMISSIONS_TABLE,
    KeySchema=[
        {"AttributeName": "user_id", "KeyType": "HASH"},
        {"AttributeName": "submission_id", "KeyType": "RANGE"},
    ],
    ...
)
```

結果として、**同じ情報が Terraform HCL と Python で二重に記述**される。

| シナリオ | 結果 |
|---|---|
| Terraform でGSIを追加したのに conftest.py を更新し忘れ | テストでGSIクエリが通らない |
| Terraform のPKを変えたのに conftest.py を直し忘れ | **テストは古いスキーマで通る → 本番デプロイで壊れる** |

#### 業界で使われている対処法

| 選択肢 | 内容 | メリット/デメリット |
|---|---|---|
| 手動同期（本プロジェクトの方針） | Terraform 変更時に conftest.py も手で合わせる | シンプル / ズレ事故リスク |
| Terraform output → JSON → Python で読む | `terraform output -json` の結果を conftest.py で読む | 単一ソース / 複雑、CI で terraform 必要 |
| LocalStack に Terraform apply | Docker で LocalStack、Terraform をそこに向けて実行 | 二重管理不要 / Docker 必須、起動遅い |
| 諦めて受け入れ + CI統合テスト | シンプルに保ち、実AWSで最後に確認 | 現実解 / 末端での検出 |

**本プロジェクトの判断**: 「テストライブラリに外部依存があるのは設計として変」というユーザー判断で、**手動同期**で進める。

### conftest.py の fixture は2段階構造

```python
@pytest.fixture
def aws_env(monkeypatch):
    monkeypatch.setenv("USERS_TABLE", USERS_TABLE)
    monkeypatch.setenv("SUBMISSIONS_TABLE", SUBMISSIONS_TABLE)
    monkeypatch.setenv("PROBLEMS_TABLE", PROBLEMS_TABLE)


@pytest.fixture
def dynamodb_tables(aws_env):     # ← aws_env に依存
    with mock_aws():
        client = boto3.client("dynamodb", region_name="ap-northeast-1")
        client.create_table(...)   # 3テーブル作成
        yield client
```

### 段階1: `aws_env` — 環境変数だけ注入

**目的**: Lambda 本番コードが `os.environ["USERS_TABLE"]` で読む値を、テスト時に差し替える。

#### Lambda 本番コードの書き方

```python
# backend/lambdas/get_submissions.py
import os

def handler(event, context):
    table_name = os.environ["SUBMISSIONS_TABLE"]
    table = boto3.resource("dynamodb").Table(table_name)
    ...
```

**絶対に避ける書き方**:

```python
# ❌ テーブル名ハードコード
table = boto3.resource("dynamodb").Table("atcoder-review-submissions-prod")
```

理由:

- 本番 / ステージング / テストで別のテーブル名を使いたい
- Terraform が output で吐いたテーブル名を **Lambda の環境変数経由で渡す**（Task 9 で出てくる構造）
- ハードコードすると環境を切り替えるたびにコード改変が必要

#### 環境変数はどこから来るか

| 環境 | 環境変数の供給源 |
|---|---|
| 本番 Lambda | **Terraform が Lambda リソース定義に埋め込む**（`environment { variables = {...} }`） |
| ローカルテスト | **pytest の `monkeypatch` で差し替え**（`aws_env` fixture） |
| AWS CLI からローカル実行 | `.env` ファイル or シェルで `export` |

Lambda コードから見ると「誰が環境変数を設定したか」は透明。`aws_env` fixture は**本番環境変数のローカル再現**をやっている。

### `monkeypatch` を使う理由

```python
monkeypatch.setenv("USERS_TABLE", "test-users")
```

これは `os.environ["USERS_TABLE"] = "test-users"` とほぼ同じだが、**テスト終了時に自動で元に戻る**点が違う。

#### `monkeypatch` を使わない場合の事故

```python
# ❌ 手動で setenv するテスト
def test_broken():
    os.environ["USERS_TABLE"] = "test-users"
    # ... テスト処理
    # ← 元に戻していない

def test_after():
    # os.environ["USERS_TABLE"] に前テストの値が残り続ける
    # 他のテストに影響
```

`monkeypatch` は **fixture のスコープ（デフォルト = 関数単位）が終わると自動でロールバック**。テスト間の汚染を防ぐ。

AWS テストでは特に重要: `AWS_REGION`, `AWS_PROFILE`, `USERS_TABLE` 等を頻繁に差し替えるため、残留すると「このテストだけ通らない」「CIで落ちるがローカルでは通る」型のデバッグ困難バグを生む。

### 段階2: `dynamodb_tables` — `with mock_aws()` + `yield` パターン

```python
@pytest.fixture
def dynamodb_tables(aws_env):
    with mock_aws():
        client = boto3.client("dynamodb", region_name="ap-northeast-1")
        client.create_table(...)
        yield client
```

#### `with mock_aws()` の必然性

moto v5 の `@mock_aws` はデコレータ or コンテキストマネージャで使う:

```python
# 関数デコレータ形式（単発テスト向き）
@mock_aws
def test_something():
    ...

# コンテキストマネージャ形式（fixture 向き）
with mock_aws():
    yield client
# ← ここで with が終わると、モックが解除されて「空のAWS」もメモリから消える
```

fixture で使うときは `with` じゃないと、いつモックを解除すればいいかわからない。

#### `yield client` の意味

pytest fixture の `yield` は「**ここまでがテスト前処理、ここから下がテスト後処理**」を表す境界。

```python
@pytest.fixture
def dynamodb_tables(aws_env):
    # ========== テスト前処理 ==========
    with mock_aws():
        client = boto3.client("dynamodb", ...)
        client.create_table(...)
        client.create_table(...)
        client.create_table(...)
        
        yield client   # ← テストに client を渡して制御を移す
        
        # ========== テスト後処理 ==========
        # with mock_aws() のブロックが終わることで
        # メモリ上のAWS全体が自動破棄される
```

実行順序:

```
1. テスト関数が dynamodb_tables fixture を要求
2. fixture 内で create_table が3回走る
3. yield client で client オブジェクトがテスト関数に渡る
4. テスト関数が client を使って put_item / query / etc を実行
5. テスト関数終了
6. fixture の続きが実行される（yield の後）
7. with mock_aws() が終了 → moto の仮想AWSがメモリから消える
```

この順序により、**テストごとにフレッシュなDynamoDB状態**が保証される。

### 実際のテストはどう書くか

```python
# backend/tests/test_db.py
def test_put_and_get_user(dynamodb_tables):
    from backend.shared.db import put_user, get_user  # ← 本番コードをそのまま import
    
    put_user(user_id="abc", atcoder_handle="taro")
    result = get_user(user_id="abc")
    
    assert result["atcoder_handle"] == "taro"
```

**綺麗に繋がる設計**:

- `put_user` / `get_user` は**本番コード**。テスト用の分岐は一切無い
- moto のおかげで AWS には繋がらない
- `aws_env` fixture が先に走るので `USERS_TABLE` 環境変数が `"test-users"` になっている
- `dynamodb_tables` fixture で `"test-users"` という名前のテーブルが moto 上に作られている
- 本番コードが `os.environ["USERS_TABLE"]` を読んだ結果が `"test-users"` になり、moto 上の同名テーブルにアクセスできる

### fixture の依存チェーンが示すもの

```
test_function
    ↓ 依存
dynamodb_tables (fixture)
    ↓ 依存
aws_env (fixture)
    ↓ 依存
monkeypatch (pytest 組み込み fixture)
```

`dynamodb_tables` は `aws_env` に依存しているので、pytest は**自動的に `aws_env` を先に実行**してから `dynamodb_tables` を走らせる。

もし「環境変数だけ欲しい、テーブル作成は不要」なテストなら:

```python
def test_env_only(aws_env):   # ← aws_env だけ使う
    assert os.environ["USERS_TABLE"] == "test-users"
```

**fixture の分離が、テストの「必要最低限の準備」を表現できる設計**になっている。

### 押さえるべき3つの設計判断

| 判断 | 理由 |
|---|---|
| テーブル名を**環境変数経由**で渡す | 本番/ステージング/テストで違う値を使える。Lambda 本番では Terraform が埋める |
| `monkeypatch` を使う（直接 `os.environ[...] = ` ではない） | テスト終了時の自動ロールバック、テスト間汚染防止 |
| fixture を `aws_env` と `dynamodb_tables` の**2段階**に分ける | 必要最低限の準備だけを要求できる |

Lambda + DynamoDB + moto の組み合わせで**ほぼ定石**のパターン。

## Q&A

**Q: moto は Terraform の情報とか読んで現在のキーの仕様を理解する感じなの?**

**No、moto は Terraform も実 AWS も一切読まない**。moto が立ち上がった瞬間は何もない「空のAWS」がメモリ上に生成されるだけ。テーブル定義は `conftest.py` で `create_table` を**手書き**する必要がある。

結果として**スキーマが Terraform と conftest.py に二重管理**される。業界でも決定版の解はなく、手動同期 / LocalStack / Terraform output を読む / CIで実AWS統合テスト、などの選択肢がある。このプロジェクトでは「テストライブラリに外部依存を持たせるのは設計として変」というユーザー判断で、**手動同期**で進める。

**Q: なぜ fixture が2段階（`aws_env` と `dynamodb_tables`）なの?**

「必要最低限の準備」を表現できるようにするため。環境変数だけで足りるテストは `aws_env` のみを要求し、テーブルまで欲しいテストは `dynamodb_tables` を要求する。

fixture の依存は `dynamodb_tables(aws_env)` と宣言すれば pytest が自動で `aws_env` を先に実行する。結果として、テスト側は欲しいものだけを fixture 引数に書けば必要な準備が全部揃う。

**Q: `monkeypatch.setenv(...)` と `os.environ[...] = ...` の違いは?**

動作はほぼ同じだが、`monkeypatch` は**テスト終了時に自動で元に戻る**。手動 setenv だと他のテストに環境変数が残留する事故が起きやすい。AWS テストでは `AWS_REGION`, `USERS_TABLE` 等を頻繁に差し替えるので、残留すると「このテストだけ通らない」「CIで落ちるがローカルでは通る」型のデバッグ困難バグを生む。

**Q: なぜ `with mock_aws()` と `yield` を組み合わせるの? `@mock_aws` デコレータじゃダメ?**

`@mock_aws` デコレータは単発テストには使えるが、fixture 内でテスト後処理（モック解除）を明示的に制御したい場合はコンテキストマネージャ形式が必要。`with mock_aws(): ... yield client` の形にすると、

1. fixture 呼び出し → `with` 開始 → `create_table` 実行
2. `yield` でテスト関数に制御を渡す
3. テスト関数が終わると fixture の続きが再開
4. `with` ブロックを抜ける → moto の仮想 AWS がメモリから消える

という流れで、**テストごとにフレッシュな AWS 状態**が保証される。

**Q: Lambda 本番コードにはテスト用の分岐が必要ないの?**

不要。`os.environ["USERS_TABLE"]` で環境変数を読む書き方にしておけば:

- 本番 Lambda → Terraform が `environment { variables = {...} }` で実テーブル名を注入
- ローカルテスト → `aws_env` fixture が `monkeypatch.setenv()` でテスト用テーブル名を注入

という具合に、**誰が環境変数を設定したかはコードから見て透明**。結果、本番コードを一切汚さずにテストできる。これが moto + 環境変数方式の設計上の美点。

## 関連

- 前のトピック: [01-moto-and-aws-test-credentials.md](01-moto-and-aws-test-credentials.md) — moto の基本と `AWS_ACCESS_KEY_ID="testing"` の正体
- 前提知識: [../task1/09-dynamodb-as-hashtable.md](../task1/09-dynamodb-as-hashtable.md) — moto が再現しない「分散システムとしての物理挙動」= DHT の分散部分
- 次のトピック候補（未作成）: Lambda 本番コードで環境変数経由にテーブル名を渡す設計（Task 9 の Terraform Lambda モジュールで接続）

---

_Saved at 2026-04-18 via /learning-flow:topic_
