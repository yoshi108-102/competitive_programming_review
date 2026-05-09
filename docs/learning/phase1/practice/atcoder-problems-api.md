# 01. AtCoder Problems API — User Submissions エンドポイントとアクセス指針

> 出典: [AtCoder Problems API Documentation - GitHub](https://github.com/kenkoooo/AtCoderProblems/blob/master/doc/api.md)（閲覧日 2026-05-09）
>
> このノートは公式ドキュメントの「User Submissions」と「Access Policy」を起点に、Claude が自動生成した教材です。

## 概要

AtCoder 公式には**ユーザーの提出一覧を取得する公開 API は存在しない**。代わりにコミュニティ運営の AtCoder Problems（kenkoooo.com）が提供する API を利用する。
このプロジェクトでは Lambda が定期的にこの API を叩いて submission データを DynamoDB に保存する設計（`sync_submissions` ハンドラ、Task 7）。

**重要**: コミュニティ提供 API なので、**1 秒以上のスリープ間隔を守る**こと。これは規約というよりエコシステム維持のための強い要請。

## 公式 docs に沿った解説

### A. User Submissions エンドポイント

URL 構造:

```
https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions?user={user_id}&from_second={unix_second}
```

クエリパラメータ:

| 名前 | 型 | 例 | 意味 |
|---|---|---|---|
| `user` | str | `chokudai` | AtCoder ユーザー ID |
| `from_second` | int (Unix epoch 秒) | `1560046356` | この時刻以降の提出のみ取得 |

レスポンス: 提出オブジェクトの **配列**。1 リクエストで最大 **500 件** まで返る。

公式 docs より:

> Up to 500 submissions after the specified time will be returned.

> 補足（公式 docs には記載なし）: 提出オブジェクトのスキーマは公式に明記されていないが、実物のレスポンスから観測すると以下のフィールドが含まれる:
>
> ```json
> {
>   "id": 12345,
>   "epoch_second": 1700000000,
>   "problem_id": "abc300_a",
>   "contest_id": "abc300",
>   "user_id": "testuser",
>   "language": "Python (CPython 3.11.4)",
>   "point": 100.0,
>   "length": 150,
>   "result": "AC",
>   "execution_time": 30
> }
> ```

### B. `from_second` ベースのページネーション

500 件を超える結果がある場合、**`from_second` を「最後に受け取った提出の `epoch_second`」に進めて再リクエスト**する形で続きを取得する。

具体的なループ:

```
1. from_second=0 で初回リクエスト → 500 件返る
2. 500 件のうち最大の epoch_second を取り出す（例: 1700000999）
3. from_second=1700000999 でリクエスト → 残りが返る
4. 受信件数が 500 未満になったら終了
```

DynamoDB の `LastEvaluatedKey`（Task 4 で扱った）と性質は似ているが、**「キー」ではなく「時刻」基準**で進める点が違う。
そして同じ `epoch_second` の提出が複数あると重複取得の可能性があるので、保存側で `id` を一意キーにして冪等にする必要がある（Task 7 で実装）。

### C. アクセス指針 — レート制限

公式 docs の表現:

> Please don't hit API so often. Please sleep for more than 1 second between accesses.

ポイント:

- **明示的な数値レート制限はない**が「1 秒以上 sleep」という強い要請
- 違反すると IP ブロックされる可能性（コミュニティ運営なので明文化された罰則はない）
- 大量取得が必要な場面では **キャッシュ（DynamoDB に保存）し、差分のみ更新**する設計が必須

このプロジェクトでは:
- `sync_submissions` Lambda は **1 日 1 回** EventBridge でトリガー（Phase 7）
- 毎回 `from_second=最後の同期時刻` で差分のみ取得
- 連続ページがある場合は 500 件ごとに `time.sleep(1.5)` を挟む

### D. バージョン非互換警告

公式 docs:

> We sometimes deprecate old APIs and replace them with new ones. Please carefully watch this repository and update your application to use the latest API.

> 補足（公式 docs には記載なし）: 現在は `v3`。`v2` 系は deprecated。バージョンが上がっても URL 切り替えで対応可能なよう、`shared/atcoder_client.py` の **基底 URL を定数化**しておく。

### E. 認証・認可

このエンドポイントは **公開 API** で認証不要。AtCoder ID は誰のものでも参照可能（誰でも `chokudai` の提出を見られる）。
プライバシー考慮としては、AtCoder アカウントの提出履歴は AtCoder 上でも公開設定なので、API 経由でも公開情報のみが返ると考えてよい。

## 重要ポイント

- AtCoder 公式 API には submission 一覧取得が無いので **kenkoooo.com の v3 API** を使う
- レスポンスは **最大 500 件**。それ以上は `from_second` を進めて再取得
- **1 秒以上のスリープ**を必ず挟むこと（破ると API 提供者に迷惑、IP ブロックの可能性）
- 同じ `epoch_second` の提出が複数あり得るので、保存側は `id` キーで重複排除する
- **公開 API**で認証不要だが、それゆえ責任ある利用が大事

## コード例（仕様の最小再現）

このプロジェクトで書く `shared/atcoder_client.py` の最小スケッチ（Task 5 実装で書く）:

```python
import requests

BASE = "https://kenkoooo.com/atcoder/atcoder-api/v3"


class AtCoderClient:
    def __init__(self, timeout: int = 30):
        self._timeout = timeout

    def get_submissions(self, username: str, from_second: int = 0) -> list[dict]:
        resp = requests.get(
            f"{BASE}/user/submissions",
            params={"user": username, "from_second": from_second},
            timeout=self._timeout,
        )
        resp.raise_for_status()
        return resp.json()
```

呼び出し側でループする例（Task 7 で書く `sync_submissions`）:

```python
import time

def fetch_all_submissions(client, username, from_second=0):
    all_items = []
    while True:
        page = client.get_submissions(username, from_second=from_second)
        if not page:
            break
        all_items.extend(page)
        if len(page) < 500:
            break
        from_second = max(s["epoch_second"] for s in page) + 1
        time.sleep(1.5)  # ← レート制限尊重
    return all_items
```

## 関連

- 議論・Q&A: （`lesson` 中に発生したら `reference/` 配下にリンクが追加されます）
- 次の教材: [02-requests-and-requests-mock.md](02-requests-and-requests-mock.md) — Python `requests` と `requests-mock` テスト
- 関連 Task: Task 7 (`sync_submissions` ハンドラで実際にループを回す)

---

_Auto-generated at 2026-05-09 via /learning-flow:material（公式 docs 駆動）_
