"""
教材用の最小サンプル。Task 3 の lesson 進行に合わせて段階的に肉付けしていく。
本実装は backend/shared/response.py に別途書く（このファイルは消してOK）。

今のステップ: B-2「CORS ヘッダ4種を追加」
  - Access-Control-Allow-Origin: どのオリジンからの読み取りを許可
  - Access-Control-Allow-Headers: どのカスタムヘッダを使ってよいか
  - Access-Control-Allow-Methods: どのメソッドを許可するか（preflight 用）
"""

import json


def handler_naive(event, context):
    """❌ 普通の dict をそのまま返す。
    statusCode が無いので API Gateway は 500 を返す（罠2）。"""
    submissions = [{"id": "SUB001", "result": "AC"}]
    return {"submissions": submissions}


def handler_wrong_body(event, context):
    """❌ body に dict を入れている。API Gateway がエラー（罠1）。"""
    submissions = [{"id": "SUB001", "result": "AC"}]
    return {
        "statusCode": 200,
        "body": {"data": submissions},
    }


def handler_no_cors(event, context):
    """⚠️ Lambda Proxy Integration の形は正しいが CORS ヘッダ無し。
    curl では動くが、ブラウザの fetch ではレスポンスを JS に渡してもらえない。"""
    submissions = [{"id": "SUB001", "result": "AC"}]
    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
        },
        "body": json.dumps({"data": submissions}),
    }


def handler_with_cors(event, context):
    """✅ CORS ヘッダ込み。SPA フロントから fetch しても JS に値が渡る。
    開発中は Access-Control-Allow-Origin: * で楽する。
    本番では自フロントのオリジンに限定する（Phase 5 で見直し）。"""
    submissions = [{"id": "SUB001", "result": "AC"}]
    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
            # 「どのオリジンから読み取ってよいか」
            "Access-Control-Allow-Origin": "*",
            # 「どのカスタムヘッダ付きリクエストを許可するか」
            # Authorization は Cognito JWT を Bearer で送るために必須
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
            # 「どのメソッドを許可するか」
            # OPTIONS が無いと preflight が通らない
            "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
        },
        "body": json.dumps({"data": submissions}),
    }


if __name__ == "__main__":
    print("=== handler_with_cors の返り値 ===")
    result = handler_with_cors(event={}, context=None)
    for key, value in result.items():
        print(f"{key}: {value}")
    # statusCode: 200
    # headers: {'Content-Type': 'application/json',
    #           'Access-Control-Allow-Origin': '*',
    #           'Access-Control-Allow-Headers': 'Content-Type,Authorization',
    #           'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE,OPTIONS'}
    # body: '{"data": [{"id": "SUB001", "result": "AC"}]}'
    #
    # API Gateway はこれを実際の HTTP レスポンスへ変換:
    #   HTTP/1.1 200 OK
    #   Content-Type: application/json
    #   Access-Control-Allow-Origin: *
    #   Access-Control-Allow-Headers: Content-Type,Authorization
    #   Access-Control-Allow-Methods: GET,POST,PUT,DELETE,OPTIONS
    #
    #   {"data": [{"id": "SUB001", "result": "AC"}]}
