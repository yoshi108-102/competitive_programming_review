# Phase 1 / Task 3: Backend — shared/response.py (APIレスポンスヘルパー)

## 概要

全 Lambda ハンドラーが共通で使う **API レスポンス整形ヘルパー** を実装する。
`{ data, meta }` 形式のレスポンスと、エラーレスポンスの2つの関数を `shared/response.py` に定義する。

Lambda + API Gateway 統合で必要となる「特殊な返り値の形」を理解するのが主題:

- statusCode / headers / body の3要素構造
- CORS ヘッダの意味と必要性
- `json.dumps(..., default=str)` の役割（Decimal対応）

## 目次

- [01. Lambda の HTTP レスポンス形式と CORS / SOP の関係](01-lambda-response-format-and-cors.md) — Lambda Proxy Integration = HTTP レスポンス、CORS/SOP、iframe、Clickjacking、CSRF、徳丸本との接続 [done][quiz][graded]
- [02. json.dumps の default パラメータと DynamoDB Decimal 問題](02-json-dumps-default-and-decimal.md) — `default=str` 慣用句、Python→JSON 型対応、Boto3 Decimal の素性、JSONEncoder サブクラス化との比較 [done][quiz]
- [03. `shared/response.py` の設計ノート](03-shared-response-helper-design.md) — `success()` / `error()` が吸収する 4 つの責務、ハンドラ側のビフォーアフター [done]

## 振り返り（Task 2 + 3 統合 まとめクイズ）

Task 2（Python 環境 + moto/pytest 基盤）と Task 3（`shared/response.py` + 最小ハンドラ）を**横断する**論点のみ出題。
個別 Topic の事実問題（教材 01/02 で扱った CORS や json.dumps の細部）は再出題しない。

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

**関連ノート**: [phase1/task2/](../task2/)（Task 2 の Python 環境セットアップ）

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

**関連ノート**: [02-json-dumps-default-and-decimal.md](02-json-dumps-default-and-decimal.md)

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

**関連ノート**: [03-shared-response-helper-design.md](03-shared-response-helper-design.md) §テスト観点

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

Task 3 / Topic 1 のクイズで「わからない」だった論点の再出題。

このプロジェクトでは Cognito JWT を `Authorization: Bearer ...` で送る。

(a) Cookie 認証と比較して、この方式が CSRF に**構造的に強い**理由を一言で。
(b) この方式だと、ブラウザは本リクエストの前に必ず `OPTIONS` プリフライトを送ることになる。それはなぜか（Simple Request の条件を踏まえて）。
(c) サーバが許可しないオリジンからの POST に対し、preflight が起きる方式と起きない方式（form 送信など）で「どこで止まるか」がどう違うか。

**参考**:
- [CORS preflight - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS#preflighted_requests)
- [Simple requests - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS#simple_requests)
- [CSRF Prevention - OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html)

**関連ノート**: [01-lambda-response-format-and-cors.md](01-lambda-response-format-and-cors.md), [reference/cors-only-blocks-reads-not-writes.md](reference/cors-only-blocks-reads-not-writes.md), [reference/preflight-bypass-via-simple-post.md](reference/preflight-bypass-via-simple-post.md)

**回答**:
