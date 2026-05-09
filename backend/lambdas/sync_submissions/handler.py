"""POST /sync — AtCoder Problems API から submission を取得して DynamoDB に保存。

差分同期: ユーザーごとに last_sync_epoch を保持し、それ以降の提出のみ取得する。
設計の根拠: docs/learning/phase1/task5/01-atcoder-problems-api.md
            docs/learning/phase1/task6/01-lambda-handler-skeleton.md
"""

from decimal import Decimal

from shared.atcoder_client import AtCoderClient
from shared.db import get_table
from shared.response import error, success


def _floats_to_decimal(obj):
    """Boto3 DynamoDB は float を受け付けないので Decimal に変換する。

    str 経由で変換することで IEEE 754 の精度欠落を避ける
    (Decimal(0.1) != Decimal("0.1") なので)。
    → docs/learning/phase1/task3/02-json-dumps-default-and-decimal.md
    """
    if isinstance(obj, float):
        return Decimal(str(obj))
    if isinstance(obj, dict):
        return {k: _floats_to_decimal(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_floats_to_decimal(v) for v in obj]
    return obj


def lambda_handler(event, context):
    # 1. 認証
    try:
        user_id = event["requestContext"]["authorizer"]["claims"]["sub"]
    except KeyError:
        return error("UNAUTHORIZED", "認証情報が見つかりません", status_code=401)

    # 2. user テーブルから AtCoder ユーザー名と前回同期時刻を取り出す
    users_table = get_table("USERS_TABLE")
    user = users_table.get_item(Key={"user_id": user_id}).get("Item")

    if not user or not user.get("atcoder_username"):
        return error(
            "USER_NOT_CONFIGURED",
            "先に /users/me で AtCoder ユーザー名を登録してください",
        )

    atcoder_username = user["atcoder_username"]
    from_second = int(user.get("last_sync_epoch", 0))

    # 3. AtCoder Problems API から差分取得
    #    MVP は単発呼び出しのみ。500 件超える場合の追加 pagination は将来対応
    #    (規約上 1 秒以上 sleep を挟む必要があるため、Step Functions / EventBridge と組み合わせる)
    client = AtCoderClient()
    submissions = client.get_submissions(atcoder_username, from_second=from_second)

    # 4. submission を DynamoDB に保存 + last_sync_epoch を更新
    if submissions:
        submissions_table = get_table("SUBMISSIONS_TABLE")
        # batch_writer は内部で BatchWriteItem (最大 25 件 / リクエスト) を自動分割する
        with submissions_table.batch_writer() as batch:
            for s in submissions:
                item = _floats_to_decimal({
                    "user_id": user_id,
                    "submission_id": str(s["id"]),
                    "epoch_second": s["epoch_second"],
                    "problem_id": s["problem_id"],
                    "contest_id": s["contest_id"],
                    "language": s["language"],
                    "point": s["point"],
                    "length": s["length"],
                    "result": s["result"],
                    "execution_time": s.get("execution_time"),
                })
                batch.put_item(Item=item)

        max_epoch = max(s["epoch_second"] for s in submissions)
        users_table.update_item(
            Key={"user_id": user_id},
            UpdateExpression="SET last_sync_epoch = :e",
            ExpressionAttributeValues={":e": max_epoch},
        )

    return success(data={
        "synced_count": len(submissions),
        "from_second": from_second,
    })
