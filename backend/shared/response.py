"""API Gateway Lambda Proxy Integration 用のレスポンス整形ヘルパー。

全 Lambda ハンドラはここを経由して戻り値を組み立てる。
設計の根拠: docs/learning/phase1/practice/shared-response-helper-design.md
"""

import json
from typing import Any

# CORS ヘッダはここに集約。Lambda ハンドラ側で個別指定しない。
# MVP段階では Allow-Origin を "*" にしておき、Phase 5 (CloudFront/WAF) で
# Cognito ドメインへ絞る。
# → docs/learning/phase1/02-lambda-proxy-integration-and-cors.md
_CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
    "Content-Type": "application/json",
}


def success(
    data: Any,
    meta: dict | None = None,
    status_code: int = 200,
) -> dict:
    """成功レスポンスを API Gateway Proxy 形式で返す。

    body は { "data": <data>, "meta": <meta or null> } の JSON 文字列。
    Decimal / datetime は default=str で文字列化される。
    → docs/learning/phase1/practice/json-dumps-default-str.md
    """
    body = {"data": data, "meta": meta}
    return {
        "statusCode": status_code,
        "headers": _CORS_HEADERS,
        "body": json.dumps(body, default=str),
    }


def error(
    code: str,
    message: str,
    status_code: int = 400,
) -> dict:
    """エラーレスポンスを API Gateway Proxy 形式で返す。

    body は { "error": { "code": <code>, "message": <message> } } の JSON 文字列。
    code はマシン可読な短い識別子 (例: "VALIDATION_ERROR")、
    message は人間可読 (フロントが画面表示にそのまま使える)。
    """
    body = {"error": {"code": code, "message": message}}
    return {
        "statusCode": status_code,
        "headers": _CORS_HEADERS,
        "body": json.dumps(body, default=str),
    }
