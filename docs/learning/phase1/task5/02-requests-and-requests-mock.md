# 02. Python `requests` ライブラリと `requests-mock` テスト

> 出典:
> - [Requests: Quickstart - Read the Docs](https://requests.readthedocs.io/en/latest/user/quickstart/)（閲覧日 2026-05-09）
> - [requests-mock documentation](https://requests-mock.readthedocs.io/en/latest/)（閲覧日 2026-05-09）
>
> このノートは公式ドキュメントの該当章を起点に、Claude が自動生成した教材です。

## 概要

Lambda から外部 API（AtCoder Problems）を叩くために `requests` を使う。本ノートでは:

- `requests` の最低限の作法（`get`, `params`, `raise_for_status`, `timeout`）
- `requests-mock` で外部 API を叩かずにテストする方法

を扱う。HTTP クライアントの責務として **タイムアウト必須** と **異常系のテスト**を強調する。

## 公式 docs に沿った解説

### A. リクエストを作る（`requests.get`）

最小例:

```python
import requests

r = requests.get("https://api.example.com/users")
```

公式 docs より:

> Making a request with Requests is very simple.

戻り値は `Response` オブジェクト。中身は以下のプロパティで取り出す:

| プロパティ / メソッド | 用途 |
|---|---|
| `r.status_code` | HTTP ステータス（200, 404, 500 など） |
| `r.text` | 本文（文字列、自動デコード） |
| `r.json()` | JSON をパース。失敗時は `JSONDecodeError` |
| `r.headers` | レスポンスヘッダ（dict-like、case-insensitive） |
| `r.raise_for_status()` | 4xx/5xx で `HTTPError` を raise |

### B. クエリパラメータの渡し方（`params=`）

URL に `?key=value&...` を手で書かず、`params` キーワードで dict を渡す:

```python
payload = {"user": "chokudai", "from_second": 0}
r = requests.get("https://kenkoooo.com/.../user/submissions", params=payload)
print(r.url)
# https://kenkoooo.com/.../user/submissions?user=chokudai&from_second=0
```

公式 docs より:

> Requests allows you to provide these arguments as a dictionary of strings, using the `params` keyword argument.

メリット:
- **URL エンコードを自動でやってくれる**（日本語ユーザー名や記号でも安全）
- 値が `None` のキーは **自動で省略**される（オプショナルパラメータ管理が楽）
- 値にリストを渡すと `?k=v1&k=v2` のような複数値も自動展開

### C. JSON レスポンスの取得（`r.json()`）

```python
r = requests.get(url)
data = r.json()  # dict or list を返す
```

公式 docs より、**重要な注意**:

> It should be noted that the success of the call to `r.json()` does **not** indicate the success of the response. Some servers may return a JSON object in a failed response (e.g. error details with HTTP 500). Such JSON will be decoded and returned. To check that a request is successful, use `r.raise_for_status()` or check `r.status_code` is what you expect.

つまり「**`r.json()` 成功 = リクエスト成功」ではない**。500 エラーでも JSON が返ってくれば parse は成功する。**`raise_for_status()` を先に呼ぶか、`status_code` を別途チェック**する。

### D. `raise_for_status()` — 異常系の早期検出

```python
r = requests.get(url)
r.raise_for_status()  # 4xx/5xx なら HTTPError 例外
data = r.json()
```

公式 docs:

> If we made a bad request (a 4XX client error or 5XX server error response), we can raise it with `Response.raise_for_status()`.

**呼ばないと**: 200 OK でも 500 Internal Server Error でも黙って `r.json()` の結果を進めてしまう → バグの温床。
**呼ぶと**: 4xx/5xx なら `requests.exceptions.HTTPError` が飛び、`try/except` で拾える or 上に伝播して Lambda が失敗扱いになる。

### E. `timeout` — 必ず指定すること

```python
r = requests.get(url, timeout=30)  # 30 秒以内に最初のバイトが来なかったら Timeout 例外
```

公式 docs（**強い警告**）:

> Nearly all production code should use this parameter in nearly all requests. Failure to do so can cause your program to hang indefinitely.
>
> If no timeout is specified explicitly, requests do not time out.

つまり **`timeout` 未指定だと無限に待つ**。Lambda の場合:
- Lambda の実行時間制限（最大 15 分）まで何もせず待ってしまう
- Lambda は最終的にタイムアウトして料金は満額発生 + リクエストは失敗
- 同期処理の場合、上流（API Gateway）も巻き込んで遅延

**Lambda では `timeout` 必須**。Lambda 関数自身のタイムアウトより**短い値**を指定する（例: Lambda が 30 秒なら `requests.get(..., timeout=20)`）。

### F. 例外階層

公式 docs より:

| 例外 | 発生条件 |
|---|---|
| `requests.exceptions.ConnectionError` | DNS 解決失敗、接続拒否 |
| `requests.exceptions.Timeout` | タイムアウト |
| `requests.exceptions.HTTPError` | `raise_for_status()` 経由で 4xx/5xx |
| `requests.exceptions.TooManyRedirects` | リダイレクトしすぎ |

すべて `requests.exceptions.RequestException` を継承しているので、まとめて捕まえたい時はこれをキャッチする。

### G. `requests-mock` で HTTP モックテスト

外部 API への実アクセスを伴わないテストのため、`requests-mock` を使う。`requests` ライブラリの呼び出しをインターセプトして、事前登録したレスポンスを返す。

#### 基本パターン（コンテキストマネージャ）

```python
import requests
import requests_mock


def test_get_submissions_returns_list():
    with requests_mock.Mocker() as m:
        # 「このURLが叩かれたらこの JSON を返す」と事前登録
        m.get(
            "https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions",
            json=[{"id": 1, "result": "AC"}],
        )

        # 実装側を呼ぶ（内部で requests.get が呼ばれるが、モックが応答する）
        r = requests.get(
            "https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions",
            params={"user": "testuser"},
        )

        assert r.json() == [{"id": 1, "result": "AC"}]
```

#### 異常系のモック

```python
with requests_mock.Mocker() as m:
    m.get(url, status_code=500)
    # raise_for_status() を呼ぶ実装なら HTTPError が飛ぶことを確認
    with pytest.raises(requests.exceptions.HTTPError):
        client.get_submissions("testuser")
```

#### 呼ばれた URL の検証

`m.last_request` で最後にインターセプトされたリクエストを取得できる:

```python
with requests_mock.Mocker() as m:
    m.get(url, json=[])
    client.get_submissions("testuser", from_second=1700000000)

    assert "from_second=1700000000" in m.last_request.url
    assert "user=testuser" in m.last_request.url
```

これで「正しいパラメータで呼ばれたか」を検証できる。

#### モック対象の見え方

`requests-mock` は `requests` ライブラリの **トランスポート層** に介入する。`requests.adapters.HTTPAdapter` を差し替える形なので、テスト対象コードを**改変せずに**モックできる（依存性注入を組まなくてよい）。

> 補足（公式 docs には記載なし）: pytest 専用 fixture 版（`requests_mock` を関数引数として受け取る）も使える。本プロジェクトのテストでは context manager 形式を採用（既存 conftest.py との整合上シンプル）。

## 重要ポイント

- `requests.get(url, params=dict, timeout=int)` の **3 点セット**を必ず守る
- **`r.json()` 成功 ≠ リクエスト成功**。`raise_for_status()` を先に呼ぶか `status_code` を確認
- **`timeout` 未指定 = 無限待機**。Lambda では絶対指定。Lambda 関数自身のタイムアウトより短く
- 例外は `requests.exceptions.RequestException` を頂点とした階層
- `requests-mock` の `Mocker()` で外部 API を叩かずにテスト
- `m.get(url, json=...)` / `m.get(url, status_code=500)` で正常・異常を作り分け
- `m.last_request.url` で「正しい URL/パラメータで呼ばれたか」を検証

## コード例（このプロジェクトの想定）

`shared/atcoder_client.py`:

```python
import requests

ATCODER_PROBLEMS_API = "https://kenkoooo.com/atcoder/atcoder-api/v3"


class AtCoderClient:
    def __init__(self, timeout: int = 30):
        self._timeout = timeout

    def get_submissions(self, username: str, from_second: int = 0) -> list[dict]:
        resp = requests.get(
            f"{ATCODER_PROBLEMS_API}/user/submissions",
            params={"user": username, "from_second": from_second},
            timeout=self._timeout,
        )
        resp.raise_for_status()  # 4xx/5xx は例外に変換
        return resp.json()
```

テスト（`tests/test_atcoder_client.py`）:

```python
import pytest
import requests
import requests_mock

from shared.atcoder_client import AtCoderClient


def test_get_submissions_returns_list():
    client = AtCoderClient()
    with requests_mock.Mocker() as m:
        m.get(
            "https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions",
            json=[{"id": 1, "result": "AC"}],
        )
        result = client.get_submissions("testuser")
    assert result == [{"id": 1, "result": "AC"}]


def test_get_submissions_raises_on_5xx():
    client = AtCoderClient()
    with requests_mock.Mocker() as m:
        m.get(
            "https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions",
            status_code=500,
        )
        with pytest.raises(requests.exceptions.HTTPError):
            client.get_submissions("testuser")
```

## 関連

- 議論・Q&A: （`lesson` 中に発生したら `reference/` 配下にリンクが追加されます）
- 前の教材: [01-atcoder-problems-api.md](01-atcoder-problems-api.md) — AtCoder Problems API の仕様
- 関連 Task: Task 7 (`sync_submissions` で実際にこのクライアントを使う)

---

_Auto-generated at 2026-05-09 via /learning-flow:material（公式 docs 駆動）_
