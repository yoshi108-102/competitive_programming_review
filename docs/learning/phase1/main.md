# Phase 1: MVP — AWS 学習トピック

## 目的

AtCoder 復習支援ツールの MVP を構築する過程で、Phase 1 で扱う AWS サービス群（Cognito / API Gateway / Lambda / DynamoDB / Amplify Hosting）の中核概念を学ぶ。

Phase 1 全体は 18 の実装 Task に分かれているが、**学習ノートはタスクの実装手順ではなく AWS の概念単位**で組み直してある。実装の細部に関する Q&A は `practice/` 以下で個別に扱う。

## AWS 学習トピック

| # | トピック | 内容 |
|---|---|---|
| 1 | [task1/](task1/) | DynamoDB キー設計、Terraform 基礎、IAM、Bootstrap、設計原則（**完了・採点済み**） |
| 2 | [Lambda Proxy Integration と CORS](task2/02-lambda-proxy-integration-and-cors.md) | Lambda の戻り値三要素、`body=str` 制約、CORS / SOP / Clickjacking / CSRF |
| 3 | [Boto3 Resource API vs Client API](task2/03-boto3-resource-vs-client.md) | 2 系統の SDK、Resource はメンテナンスモード、スレッドセーフティ |
| 4 | [DynamoDB Decimal とページネーション](task2/04-dynamodb-decimal-and-pagination.md) | Number = Decimal の理由、1MB 制限、LastEvaluatedKey、Boto3 Paginators |
| 5 | [Lambda 実行ロールとデプロイパッケージ](task2/05-lambda-execution-role-and-deployment.md) | IAM Trust/Permission、CloudWatch Logs、aws_lambda_permission、ZIP の中身 |
| 6 | [API Gateway REST API 構造](task2/06-api-gateway-rest-api-structure.md) | Resource/Method/Integration/Deployment/Stage、AWS_PROXY、CORS preflight |
| 7 | [Cognito と API Gateway Authorizer](task2/07-cognito-and-api-gateway-authorizer.md) | User Pool/Client、JWT (idToken vs accessToken)、Cognito Authorizer 連携 |

## 実装 Q&A・参考メモ

`practice/` 配下に、Phase 1 の実装過程で出た **AWS の主題ではない** Q&A・設計ノート・参考メモを置く。
将来の質疑応答もここに追記していく。

主な内容（[practice/README.md](practice/README.md) も参照）:

- `shared/response.py` の設計判断（API レスポンスヘルパー）
- `shared/db.py` / `shared/atcoder_client.py` の実装パターン
- Python テスト基盤（moto / pytest fixtures / requests-mock）
- Lambda ハンドラ骨格パターン
- Frontend (Next.js + Amplify) ページ実装
- Terraform apply / Frontend 結合テストの手順
- CORS 関連の Q&A ログ（`practice/reference/`）

## 保留中の振り返りクイズ（MVP 動作確認後に採点）

Task 2 + Task 3 統合のまとめクイズを 6 問生成済み（採点保留）。
MVP（実 AWS デプロイ + フロント結合）が動いた後に `/learning-flow:grade --summary` で採点する方針。

クイズ本体は下記 §振り返り に保持。

---

## 振り返り（Task 2 + 3 統合 まとめクイズ — 採点保留）

実装 Task のうち Task 2（Python 環境 + moto/pytest 基盤）と Task 3（`shared/response.py` + 最小ハンドラ）を**横断する**論点。
回答は各問の `**回答**:` 行の下に記入してください。
全問記入後に `/learning-flow:grade --summary` を実行すると、Claude が採点して進捗を更新します。

---

### Q1. 2 段階 fixture (`aws_env` → `dynamodb_tables`) の役割分担

`backend/tests/conftest.py` では fixture を 2 段階に分けている:

- `aws_env`: `monkeypatch.setenv` で `USERS_TABLE` 等の環境変数を注入
- `dynamodb_tables(aws_env)`: `with mock_aws()` で moto を起動し、テーブルを `create_table` してから `yield`

(a) なぜこれを 1 つの fixture（環境変数注入と moto 起動を同じ関数に書く）にせず、2 段階に分けているのか。役割分担の意図を答えよ。
(b) 環境変数だけ欲しい（moto は要らない）テストを書く時、2 段階構造のメリットは何か。具体例を挙げよ。

**参考**:
- [pytest fixtures - About fixtures](https://docs.pytest.org/en/stable/explanation/fixtures.html)
- [moto - Getting Started](https://docs.getmoto.org/en/latest/docs/getting_started.html)

**関連ノート**: [practice/pytest-fixtures-for-aws.md](practice/pytest-fixtures-for-aws.md), [practice/moto-and-aws-test-credentials.md](practice/moto-and-aws-test-credentials.md)

**回答**:

---

### Q2. 環境変数経由でテーブル名を渡す設計の本番 / テスト両対応

`get_submissions/handler.py` では `os.environ["SUBMISSIONS_TABLE"]` でテーブル名を取得している。

(a) 本番 Lambda 実行時、この環境変数は **誰が** いつ設定するか。
(b) ローカルテスト時、この環境変数は **誰が** いつ設定するか（`conftest.py` の該当箇所を踏まえて）。
(c) もしテーブル名をソース内にハードコードしていたら、本番／テストの両対応で何が壊れるか。

**参考**:
- [AWS Lambda - Configuring environment variables](https://docs.aws.amazon.com/lambda/latest/dg/configuration-envvars.html)
- [pytest monkeypatch.setenv](https://docs.pytest.org/en/stable/how-to/monkeypatch.html#monkeypatching-environment-variables)

**関連ノート**: 該当の最小ハンドラ実装は `backend/lambdas/get_submissions/handler.py`

**回答**:

---

### Q3. `Decimal` が「DynamoDB → Boto3 → Lambda → JSON → ブラウザ」を流れるとき各層で何が起きるか

数値属性（例: `score = 1500.5`）が DynamoDB に書かれた後、それをフロントの JS が `body.data.score` として読むまでに通過する各層で、データはどう表現されているかを順に答えよ。

通過する層: **DynamoDB 内部 → Boto3 (Python) → Lambda 戻り値の `body` 文字列 → ブラウザの JSON.parse 後**

各層での型 / 表現を埋めよ:

| 層 | 表現 |
|---|---|
| DynamoDB 内部 | ? |
| Boto3 が返す Python オブジェクト | ? |
| `json.dumps(..., default=str)` 後の文字列の中 | ? |
| ブラウザ `JSON.parse(body)` 後の JS 値 | ? |

また、もし `default=str` を**外した**ら、どの層で何が壊れるか。

**参考**:
- [Boto3 DynamoDB customization](https://docs.aws.amazon.com/boto3/latest/reference/customizations/dynamodb.html)
- [Python `json.dumps`](https://docs.python.org/3/library/json.html#json.dumps)

**関連ノート**: [04-dynamodb-decimal-and-pagination.md](task2/04-dynamodb-decimal-and-pagination.md), [practice/json-dumps-default-str.md](practice/json-dumps-default-str.md)

**回答**:

---

### Q4. `shared/response.py` のステートレス性テストが守っている不変条件

`tests/test_response.py::test_helper_is_stateless_no_mutation_of_module_constant` は

```python
snapshot = dict(_CORS_HEADERS)
success({"foo": 1})
error("X", "y")
assert _CORS_HEADERS == snapshot
```

を検証している。

(a) もし将来の変更で `success()` 内に `_CORS_HEADERS["X-Request-Id"] = generate_id()` のような行が紛れ込んだとしたら、何が起きるか（Lambda 実行環境のリクエスト間で）。
(b) Lambda の **実行環境再利用 (warm start)** を踏まえて、グローバル変数を mutate する危険性を説明せよ。

**参考**:
- [AWS Lambda - Execution environment lifecycle](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtime-environment.html)

**関連ノート**: [practice/shared-response-helper-design.md](practice/shared-response-helper-design.md) §テスト観点

**回答**:

---

### Q5. `test_response.py` (単体) と `test_get_submissions.py` (結合) のテスト粒度の違い

`shared/response.py` の単体テストと、`get_submissions/handler.py` の結合テスト（moto + DynamoDB を起動）は、それぞれ何を検証していて、何を検証していないか。

(a) 単体テストでカバーできない、結合テストでしか拾えない観点を 2 つ以上挙げよ。
(b) 逆に結合テストだけだと検証しにくく、単体テストの方が向いている観点を 1 つ以上挙げよ。
(c) もし結合テスト 1 種類だけで済ませたら、何が困るか（テスト失敗時のデバッグ可能性、実行速度など）。

**参考**:
- [Testing Pyramid - Martin Fowler](https://martinfowler.com/articles/practical-test-pyramid.html)
- [moto - Mock AWS services](https://docs.getmoto.org/en/latest/docs/getting_started.html)

**関連ノート**: `backend/tests/test_response.py`, `backend/tests/test_get_submissions.py`

**回答**:

---

### Q6. JWT (`Authorization: Bearer`) と CORS preflight の組み合わせ — 強化問題

Topic 2 のクイズで「わからない」だった論点の再出題。

このプロジェクトでは Cognito JWT を `Authorization: Bearer ...` で送る。

(a) Cookie 認証と比較して、この方式が CSRF に**構造的に強い**理由を一言で。
(b) この方式だと、ブラウザは本リクエストの前に必ず `OPTIONS` プリフライトを送ることになる。それはなぜか（Simple Request の条件を踏まえて）。
(c) サーバが許可しないオリジンからの POST に対し、preflight が起きる方式と起きない方式（form 送信など）で「どこで止まるか」がどう違うか。

**参考**:
- [CORS preflight - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS#preflighted_requests)
- [Simple requests - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS#simple_requests)
- [CSRF Prevention - OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html)

**関連ノート**: [02-lambda-proxy-integration-and-cors.md](task2/02-lambda-proxy-integration-and-cors.md), [practice/reference/cors-only-blocks-reads-not-writes.md](practice/reference/cors-only-blocks-reads-not-writes.md), [practice/reference/preflight-bypass-via-simple-post.md](practice/reference/preflight-bypass-via-simple-post.md)

**回答**:

---

> ルーティング: ブラウザ閲覧は [index.html](index.html) ／ テスト UI は [demo/index.html](demo/index.html)

## ハンズオン — 実 AWS sandbox

普段は無料で検証し、観測したい時だけ短時間 apply→観測→destroy する（apply から実課金）。

1. `make sandbox-test-phase1` — 無料検証（moto + terraform validate）
2. `make sandbox-up-phase1` — terraform apply（実課金開始）
3. `make sandbox-load-phase1` — 無認証トラフィックを生成（テストユーザー不要）。認証あり負荷は TEST_PASSWORD=... make sandbox-load-phase1
4. `make sandbox-watch-phase1` — API GW の Count / 4XXError / Latency、Lambda、DynamoDB、Cognito メトリクス（反映まで 2〜5 分）
5. `make sandbox-down-phase1` — terraform destroy（課金停止）

詳しい手順・期待出力・観察チェックリスト・トラブルシュート → [handson.html](handson.html) ／ [handson.md](handson.md)

> ⚠ phase1 は本番スタックを観測するダッシュボードのみ作成（本番アプリは別途デプロイ済みが前提）。
