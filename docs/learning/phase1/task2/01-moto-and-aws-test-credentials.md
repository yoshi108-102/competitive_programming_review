# moto と AWS テスト用ダミー認証情報

## 概要

AWS Lambda に乗せる Python コードを「**AWS に繋がずに** ローカルでテストする」ための2つの仕組みを整理する。

- **moto**: AWSサービスをローカルプロセス内で完全エミュレーションするライブラリ。boto3 の HTTP 通信をインターセプトして、実際の AWS と同じ振る舞いをメモリ上で返す
- **`AWS_ACCESS_KEY_ID="testing"` のダミー認証情報**: boto3 の認証チェックを回避する + 万一 moto が効いていなくても本物の AWS を誤って叩かないようにする安全装置

この2つは **セットで使う**。moto だけでは「boto3 が認証情報を探しに行く動作」は止められないので、環境変数で偽のクレデンシャルを埋めて「どこを探しても本物が見つからない」状態にする。

## 解説

### Lambda コードのテスト戦略、3つの選択肢

AtCoder復習ツールで書くような Lambda コード:

```python
def handler(event, context):
    user_id = event["user_id"]
    
    table = boto3.resource("dynamodb").Table("atcoder-review-submissions")
    response = table.query(
        KeyConditionExpression=Key("user_id").eq(user_id)
    )
    
    return {"statusCode": 200, "body": json.dumps(response["Items"])}
```

このコードをテストする方法は3つ:

| 選択肢 | コスト | 欠点 |
|---|---|---|
| 実AWSに繋ぐ | 高（課金、遅い） | テスト間でデータが混ざる、CI環境から権限必要 |
| `boto3.client()` を `unittest.mock.patch` で差し替える | 低 | **DynamoDBの振る舞いを自分で模倣**しないといけない（Queryの結果、Conditional Expression のマッチ etc） |
| **moto を使う** | 低 | ほぼなし（後述の境界あり） |

moto は「中身をフル実装で再現」してくれるので、`mock.patch` のように自分で模倣を書かなくていい。

### moto の動作原理

```python
from moto import mock_aws
import boto3

@mock_aws  # ← このデコレータの中では AWS SDK が全部ローカルで動く
def test_dynamodb():
    client = boto3.client("dynamodb", region_name="ap-northeast-1")
    
    # 実際にテーブルを作る（メモリ上に）
    client.create_table(
        TableName="users",
        KeySchema=[{"AttributeName": "user_id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "user_id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    
    # 書き込み・読み込みも普通にできる
    client.put_item(
        TableName="users",
        Item={"user_id": {"S": "abc"}, "name": {"S": "太郎"}},
    )
    response = client.get_item(
        TableName="users",
        Key={"user_id": {"S": "abc"}},
    )
    
    assert response["Item"]["name"]["S"] == "太郎"
```

**ポイント**: `boto3` のコードは本番と完全に同じ。`@mock_aws` を付けるだけで **AWS の接続先がメモリ上のエミュレータにすり替わる**。本番コードに「テスト時は `if env == test` みたいな分岐」を一切入れなくて済む。

### moto v5 の `@mock_aws`

`requirements-dev.txt` に `moto[dynamodb]>=5.0.0` と書く理由:

- **moto v4 まで**: サービスごとに別デコレータ（`@mock_dynamodb`, `@mock_s3`, `@mock_lambda`…）
- **moto v5 から**: **`@mock_aws` 一つで全サービス一括**

ネットの古い記事は `@mock_dynamodb` を使っているが、現代は `@mock_aws` が推奨。

### どこまで忠実にエミュレートするか

moto は「DynamoDB の **API 仕様**」を忠実に再現するが、「分散システムとしての物理挙動」は再現しない。

| 仕様 | moto の対応 |
|---|---|
| PK/SK/GSI | ✅ 完全対応 |
| Conditional Expression (`attribute_not_exists` 等) | ✅ 対応 |
| Query / Scan / BatchGetItem | ✅ 対応 |
| トランザクション (`TransactWriteItems`) | ✅ 対応 |
| **パーティションの物理分散** | ❌ メモリ上の dict なので再現しない |
| **スループット制限（スロットリング）** | ❌ 再現しない |
| **結果整合性の遅延** | ❌ すべて即時反映 |
| 400KB アイテムサイズ制限 | ⚠️ 再現する（バージョンによる） |

Task 1 で学んだ「DynamoDB = 分散ハッシュテーブル」の視点で言うと、**ハッシュテーブル部分は再現、分散部分は再現せず**。

### moto のメリット

1. **AWSに繋がない** → オフライン開発OK、CI環境に AWS 権限不要
2. **高速** → 1テスト数ms、100件でも1秒
3. **分離** → テストごとにフレッシュなDynamoDB状態、並列実行可能
4. **本物の boto3 コードがそのまま使える** → 本番コードにテスト用の分岐を入れずに済む
5. **無料** → 実 AWS を叩くと月数百円〜

### moto のデメリット/注意点

1. **「実 AWS と完全一致」ではない**: 細かい挙動（エラーメッセージの文言、最新API機能）で差が出ることがある
2. **バージョン差**: 古い moto だと新しい DynamoDB 機能（Streams の細かい挙動等）に未対応
3. **統合テストは別途必要**: moto で単体テストが通っても、本物の AWS で動くかは別問題（CI/CD で `terraform apply` → 実機テストが推奨）
4. **複雑なサービス間連携**: Lambda → SNS → SQS → Lambda のような連携は moto でも動くが、本物のレースコンディションは再現されない

### `AWS_ACCESS_KEY_ID="testing"` の正体

`conftest.py` に書かれている、一見謎のコード:

```python
os.environ["AWS_DEFAULT_REGION"] = "ap-northeast-1"
os.environ["AWS_ACCESS_KEY_ID"] = "testing"
os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"
os.environ["AWS_SECURITY_TOKEN"] = "testing"
os.environ["AWS_SESSION_TOKEN"] = "testing"
```

#### boto3 の認証情報探索順序

`boto3.client("dynamodb")` を呼ぶと内部で認証情報を探しに行く:

```
1. 関数呼び出しで明示的に渡された値 (aws_access_key_id=...)
2. 環境変数 (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
3. ~/.aws/credentials ファイル
4. IAM Role (EC2/Lambda/ECS 実行時)
5. ↑ 全部なければエラー: NoCredentialsError
```

moto でモックされていても、**boto3 のクライアント生成時点でこの認証チェックは走る**。環境変数が空だと、`~/.aws/credentials` を探しに行き、本物の AWS認証情報を使ってしまう or エラーになる。

#### 設定する2つの理由

**理由1: boto3 のエラー回避**

何か設定されていれば boto3 は満足する（実際の値は moto が使わないので何でもいい）。「testing」は慣習として広まっている。

**理由2: 誤って実AWSを叩く事故防止（重要）**

`@mock_aws` を付け忘れたテストがあると:

```python
# @mock_aws を付け忘れたテスト
def test_broken():
    client = boto3.client("dynamodb")  # ← ~/.aws/credentials が読まれる
    client.delete_table(TableName="atcoder-review-users-prod")  # ← 😱 本番削除
```

開発者のローカルには `~/.aws/credentials` に本物のクレデンシャルが入っていることが多く、`@mock_aws` 付け忘れ → **本番を壊す事故** が実際に起きている。

`AWS_ACCESS_KEY_ID="testing"` を conftest.py で全テストに強制することで:

- 環境変数で上書きされているので `~/.aws/credentials` は読まれない
- 「testing」は本物として通用しない値 → 万が一 AWS に繋ごうとしても認証エラーで止まる
- → **テスト実行中は絶対に本物のAWSを叩けない保証**

「踏まない地雷を大量に埋めておく」発想の、分散システムでよくある安全設計。

### 各環境変数の意味

| 環境変数 | 用途 |
|---|---|
| `AWS_DEFAULT_REGION` | boto3 がリージョン未指定で使うデフォルト（`client(region_name=...)` がなければこれ） |
| `AWS_ACCESS_KEY_ID` | IAMユーザーのアクセスキーID（本物は `AKIA...` で始まる） |
| `AWS_SECRET_ACCESS_KEY` | アクセスキーのシークレット |
| `AWS_SECURITY_TOKEN` | **一時的認証情報**のセッショントークン（STS経由のとき） |
| `AWS_SESSION_TOKEN` | 同上（新しい名前、moto はどちらもチェックする） |

`AWS_SECURITY_TOKEN` と `AWS_SESSION_TOKEN` は同じ意味で、歴史的事情で両方存在する（古い boto3 互換）。

## Q&A

**Q: moto ってどこまで本物の AWS を再現してるの? 使い物になる?**

DynamoDB の **API 仕様は忠実に再現**している（PK/SK/GSI、Conditional Expression、Query/Scan、トランザクション、etc）。ただし**分散システムとしての物理挙動は再現しない**（スループット制限、結果整合性の遅延、ホットパーティション、パーティション分散）。

**要するに、性能計測以外なら使えるテストライブラリ**。機能テスト・ロジックテスト・エッジケースの検証は全部 moto で OK。ただし「スロットリング時の挙動」「結果整合性が気になるコード」「並行書き込みのレースコンディション」といったシナリオは、実 AWS か LocalStack などの別手段が必要。

**Q: `@mock_aws` は moto v4 の `@mock_dynamodb` と何が違うの?**

moto v5 で導入された **全サービス統合版**のデコレータ。v4 まではサービスごとに別デコレータ（`@mock_dynamodb`, `@mock_s3`, `@mock_lambda`…）を使い分ける必要があったが、v5 からは `@mock_aws` 一つで全部まとめてモックできる。現代のコードは `@mock_aws` を使うのが推奨。古い記事で `@mock_dynamodb` を見たら v4 時代のもの。

**Q: なぜ conftest.py で `AWS_ACCESS_KEY_ID="testing"` なんて謎の値を環境変数に設定してるの?**

2つの理由:

1. **boto3 の認証チェックを通す**: boto3 は「認証情報を何らか発見」しないとクライアント生成時にエラーになる。moto は実際の値を使わないので、何かが入っていれば OK。「testing」は慣習的なダミー値。
2. **誤って本物の AWS を叩く事故防止**: `@mock_aws` を付け忘れたテストが走ると `~/.aws/credentials` の本物のクレデンシャルが読まれて本番を壊す危険がある。conftest.py で偽のクレデンシャルを強制セットしておけば、moto が効いていなくても「testing」という無効な値で認証失敗して止まる。「踏まない地雷を埋めておく」タイプの安全設計。

**Q: `AWS_SECURITY_TOKEN` と `AWS_SESSION_TOKEN`、両方書いてあるけど重複してない?**

同じ意味の環境変数の**旧名と新名**。歴史的に `AWS_SECURITY_TOKEN` が先にあり、後から `AWS_SESSION_TOKEN` が標準化された。古い boto3 は `SECURITY_TOKEN` を、新しい boto3 は両方をチェックする。moto 側も両方見るので、互換性のため両方設定しておく。実害はない。

## 関連

- 前 Task の接続: [../task1/09-dynamodb-as-hashtable.md](../task1/09-dynamodb-as-hashtable.md) — 「moto が再現しない部分」= 分散システムとしての物理挙動は、このDHTモデルで説明される
- 次のトピック候補（未作成）: pytest fixture の設計（`dynamodb_tables` fixture の読み解き）、monkeypatch の使い方

---

_Saved at 2026-04-18 via /learning-flow:topic_
