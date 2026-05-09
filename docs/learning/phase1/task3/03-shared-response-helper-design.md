# 03. `shared/response.py` の設計ノート — `success()` / `error()` が吸収する責務

> 出典: 本稿は **公式ドキュメントに直接対応する章を持たない設計ノート**。
> 設計の根拠となる一次資料は以下:
> - [Lambda Proxy Integration 戻り値仕様](https://docs.aws.amazon.com/apigateway/latest/developerguide/set-up-lambda-proxy-integrations.html#api-gateway-simple-proxy-for-lambda-output-format)（閲覧日 2026-05-09）
> - [CORS in API Gateway](https://docs.aws.amazon.com/apigateway/latest/developerguide/how-to-cors.html)（閲覧日 2026-05-09）
> - [Python `json.dumps` の `default` 引数](https://docs.python.org/3/library/json.html#json.dumps)（閲覧日 2026-05-09）
> - 関連教材: [01-lambda-response-format-and-cors.md](01-lambda-response-format-and-cors.md)、[02-json-dumps-default-and-decimal.md](02-json-dumps-default-and-decimal.md)
>
> このノートは Claude が自動生成した**設計教材**であり、公式 docs の写し取りではない（`> 補足（公式docsには記載なし）:` ブロックで一次資料との関係を明示する形で書いた）。

## 概要

このプロジェクトの全 Lambda ハンドラは API Gateway Proxy Integration を経由するため、戻り値が

1. `statusCode` / `headers` / `body` の **3 要素 dict** であること
2. `body` は **文字列**であること（dict 直渡しは 502 で落ちる）
3. CORS 用ヘッダ（`Access-Control-Allow-Origin` 等）が付いていること
4. body 内に `Decimal` や `datetime` が混じっても落ちないこと

を毎回満たさねばならない。これらを 4 行ベタ書きするとハンドラ毎に「書き忘れ」「微妙に違う形式」「CORS ヘッダ漏れ」が発生する。`shared/response.py` はこの 4 つを **1 関数呼び出しに集約**して、ハンドラ側の責務を「ビジネスロジックの成功 / 失敗を返す」だけに削ぐためのモジュール。

## 公式 docs に沿った前提（既習）

- **Lambda Proxy Integration の戻り値形式**: `{ statusCode, headers, body, isBase64Encoded? }` の dict。`body` は文字列必須。詳細は [01-lambda-response-format-and-cors.md §A](01-lambda-response-format-and-cors.md)
- **CORS ヘッダ**: ブラウザからのクロスオリジンアクセスを許可するために `Access-Control-Allow-Origin` 等を返す。詳細は [01-lambda-response-format-and-cors.md §B](01-lambda-response-format-and-cors.md)
- **`json.dumps(default=...)`**: 標準で JSON 化できない型（`Decimal` / `datetime` 等）に出会った時のフォールバック。詳細は [02-json-dumps-default-and-decimal.md](02-json-dumps-default-and-decimal.md)

## 設計目標

> 補足（公式 docs には記載なし）: 以下は本プロジェクト固有の設計判断。

| # | 目標 | 理由 |
|---|---|---|
| 1 | ハンドラ側で `json.dumps` を**書かせない** | `default=str` の付け忘れで Decimal が混入し 500 になる事故を構造的に防ぐ |
| 2 | CORS ヘッダを**毎回必ず付与** | ヘッダ漏れがあるとフロントは「謎の CORS エラー」だけ見えてサーバ側ログには痕跡が残らない（[reference/cors-error-server-side-visibility.md](reference/cors-error-server-side-visibility.md)） |
| 3 | 成功 / エラー応答の **形を 2 種類に統一** | フロント側で「成功は `data.foo`、失敗は `error.code` を見る」と一貫した分岐ロジックが書ける |
| 4 | 状態コードの **デフォルト値を持つ** | 成功は 200、エラーは 400/500 系を呼び出し側が選ぶだけで済む |
| 5 | テスト可能な純関数として書く | I/O を持たず、入力 → 出力が一対一。pytest で容易に検証できる |

## 関数インターフェース

### `success(data, meta=None, status_code=200)`

成功レスポンスを `{ statusCode, headers, body }` の dict として返す。`body` は

```json
{
  "data": <data>,
  "meta": <meta or null>
}
```

を `json.dumps(..., default=str)` した文字列。

**シグネチャ**:

```python
def success(
    data: Any,
    meta: dict | None = None,
    status_code: int = 200,
) -> dict:
    ...
```

**設計上の判断**:

- `data` の型は `Any`。`dict` / `list` / プリミティブのいずれでも受ける（API ごとに形が違うため）
- `meta` は `None` を許容。多くの API では使わない
- `meta=None` のとき `body` の `meta` フィールドを **省略**するか **`null` を入れる**かはプロジェクト判断:
  - 省略派 → JSON サイズが小さくなる
  - 入れる派 → クライアントが `body.meta` の存在を前提にできる
  - 本プロジェクトは「**`null` を明示的に入れる**」を採用（フロント側の `if (body.meta) ...` 分岐を不要にする）

### `error(code, message, status_code=400)`

エラーレスポンスを返す。`body` は

```json
{
  "error": {
    "code": <code>,
    "message": <message>
  }
}
```

**シグネチャ**:

```python
def error(
    code: str,
    message: str,
    status_code: int = 400,
) -> dict:
    ...
```

**設計上の判断**:

- `code` は `"VALIDATION_ERROR"` / `"NOT_FOUND"` のような **マシン可読な短い識別子**。フロントの分岐用
- `message` は **人間可読**。フロントが画面表示にそのまま使える日本語
- `status_code` のデフォルトは 400（クライアント起因が最頻）。500 系は呼び出し側で明示
- HTTP の statusCode と `body.error.code` は**両方持つ**。前者はミドルウェア（API Gateway / CloudFront 等）の判断に使われ、後者は意味論的なクライアント分岐に使う

## 内部で吸収する 4 つの責務（再掲）

1. **戻り値の三要素化**: `{ statusCode, headers, body }` を組み立てる
2. **`body` の文字列化**: `json.dumps(payload, default=str)` を必ず通す
3. **CORS ヘッダ付与**: `Access-Control-Allow-Origin` 等を常時 merge
4. **シリアライズ層の隠蔽**: `Decimal` / `datetime` を呼び出し側が意識しなくて良い

## ヘッダ部分の扱い

CORS ヘッダはモジュール定数として 1 箇所に集約する。例:

```python
_CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",          # MVP段階。後で Cognito ドメインに絞る
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
    "Content-Type": "application/json",
}
```

> 補足（公式 docs には記載なし）: `Access-Control-Allow-Origin: "*"` は MVP 用。本番では Cognito ドメインへ絞る運用が必要（[reference/cors-rules-are-universal-not-per-site.md](reference/cors-rules-are-universal-not-per-site.md)）。Phase 5（CloudFront / WAF）で固定化する予定。

## 想定実装スケッチ

> 補足（公式 docs には記載なし）: 以下はあくまで設計スケッチ。実装時は lesson でレビューしながら調整する。

```python
# backend/shared/response.py
import json
from typing import Any

# CORS ヘッダはここに集約。Lambda ハンドラ側で個別指定しない。
# → 設計理由: docs/learning/phase1/task3/03-shared-response-helper-design.md
_CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
    "Content-Type": "application/json",
}


def success(data: Any, meta: dict | None = None, status_code: int = 200) -> dict:
    body = {"data": data, "meta": meta}
    return {
        "statusCode": status_code,
        "headers": _CORS_HEADERS,
        # default=str は Decimal / datetime 等を文字列化するため必須
        # → 設計理由: docs/learning/phase1/task3/02-json-dumps-default-and-decimal.md
        "body": json.dumps(body, default=str),
    }


def error(code: str, message: str, status_code: int = 400) -> dict:
    body = {"error": {"code": code, "message": message}}
    return {
        "statusCode": status_code,
        "headers": _CORS_HEADERS,
        "body": json.dumps(body, default=str),
    }
```

## ハンドラ側の使い心地

### Before（ヘルパーなし）

```python
def lambda_handler(event, context):
    item = table.get_item(Key={"PK": "USER#1"})["Item"]
    return {
        "statusCode": 200,
        "headers": {
            "Access-Control-Allow-Origin": "*",
            "Content-Type": "application/json",
            # ↑ 書き忘れがちで CORS バグの温床
        },
        "body": json.dumps({"data": item}, default=str),
        # ↑ default=str を忘れて 500 になる事故が起きる
    }
```

### After（ヘルパーあり）

```python
from shared.response import success, error

def lambda_handler(event, context):
    item = table.get_item(Key={"PK": "USER#1"}).get("Item")
    if item is None:
        return error("NOT_FOUND", "ユーザーが見つかりません", status_code=404)
    return success(data=item)
```

ハンドラの読みやすさが「ビジネスロジックの分岐」だけに集中できる点に注目。

## テスト観点（pytest 視点）

> 補足（公式 docs には記載なし）: Task 4 で実際に書く想定の観点リスト。

- `success({"foo": 1})` の戻り値が `statusCode=200` であること
- `headers` に CORS 系 4 ヘッダがすべて含まれていること
- `body` をパースし直したら `{"data": {"foo": 1}, "meta": null}` になること
- `Decimal("1.5")` を含む dict を渡しても例外を出さず、`body` 内で `"1.5"` 文字列に変換されていること
- `error("VALIDATION_ERROR", "入力不正")` の `statusCode` がデフォルトで 400 であること
- `body.error.code` / `body.error.message` が正しく設定されていること
- 副作用がないこと（呼び出し前後で `_CORS_HEADERS` が変化していない）

## 重要ポイント

- `shared/response.py` は **API Gateway 側の制約 (3 要素 / body 文字列)、CORS ヘッダ運用、`json.dumps` のシリアライズ救済** を 1 関数呼び出しに統合するためのアダプタ
- ハンドラ側は「成功なら `success(...)`、失敗なら `error(...)`」の 2 択だけで済むようにする
- `default=str` は MVP 段階のシンプルな選択。後で型ごとに厳密に処理したくなったら `JSONEncoder` サブクラス化に差し替え可能（インターフェースを変えずに内部置換）
- CORS ヘッダはモジュール定数で集約し、ハンドラは個別指定しない（漏れ防止）
- 状態コードはキーワード引数で上書きでき、デフォルトは「成功 200 / エラー 400」

## 関連

- 前: [02-json-dumps-default-and-decimal.md](02-json-dumps-default-and-decimal.md) — `json.dumps(default=str)` の挙動と Decimal 問題
- Task 全体目次: [main.md](main.md)
- 議論・Q&A: （`lesson` 中に発生したら `reference/` 配下にリンクが追加されます）

---

_Auto-generated at 2026-05-09 via /learning-flow:material（設計ノート — 公式 docs の写し取りではない）_
