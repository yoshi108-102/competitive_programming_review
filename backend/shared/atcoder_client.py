"""AtCoder Problems API クライアント。

公式 AtCoder には submission 一覧取得 API が無いため、コミュニティ運営の
AtCoder Problems API (kenkoooo.com) を経由する。
設計の根拠: docs/learning/phase1/task5/01-atcoder-problems-api.md
            docs/learning/phase1/task5/02-requests-and-requests-mock.md
"""

import requests

# v3 系。将来 v4 が出たらここを差し替える
# → docs/learning/phase1/task5/01-atcoder-problems-api.md §D
ATCODER_PROBLEMS_API = "https://kenkoooo.com/atcoder/atcoder-api/v3"


class AtCoderClient:
    """AtCoder Problems API への HTTP アクセスを集約するクライアント。

    Lambda タイムアウトより短い HTTP timeout を持つこと（デフォルト 30 秒）。
    """

    def __init__(self, timeout: int = 30):
        self._timeout = timeout

    def get_submissions(
        self,
        username: str,
        from_second: int = 0,
    ) -> list[dict]:
        """ユーザーの提出メタデータを取得する。

        Args:
            username: AtCoder ユーザー名（例: "chokudai"）
            from_second: この Unix epoch 秒以降の提出のみ取得（pagination 用）

        Returns:
            提出オブジェクトのリスト（最大 500 件）。
            500 件返ったら呼び出し側で from_second を進めてループする。

        Raises:
            requests.exceptions.HTTPError: API が 4xx/5xx を返したとき
            requests.exceptions.Timeout: タイムアウト
            requests.exceptions.ConnectionError: ネットワーク不通
        """
        resp = requests.get(
            f"{ATCODER_PROBLEMS_API}/user/submissions",
            params={"user": username, "from_second": from_second},
            timeout=self._timeout,
        )
        # 4xx/5xx を例外に変換（呼び出し側で握りつぶさないため）
        resp.raise_for_status()
        return resp.json()
