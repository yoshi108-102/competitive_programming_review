"""Phase 3 SQS — producer / consumer Lambda handler tests.

すべて moto.mock_aws で自己完結。実 AWS エンドポイントは呼ばない。
producer は module-level で boto3.client("sqs") を初期化するため、
mock_aws コンテキスト内でモジュールを再ロードして SQS クライアントを
moto に向ける。
"""
import importlib
import json
import os
import sys

import boto3
import pytest
from moto import mock_aws

# ── Dummy credentials (moto 必須) ────────────────────────────────────────────
os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("AWS_SECURITY_TOKEN", "testing")
os.environ.setdefault("AWS_SESSION_TOKEN", "testing")

REGION = "ap-northeast-1"
QUEUE_NAME = "phase3-test-main"
DLQ_NAME = "phase3-test-dlq"


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def sqs_queues(monkeypatch):
    """moto で SQS キューを用意し、producer に QUEUE_URL を注入する。"""
    with mock_aws():
        client = boto3.client("sqs", region_name=REGION)

        dlq = client.create_queue(QueueName=DLQ_NAME)
        dlq_attrs = client.get_queue_attributes(
            QueueUrl=dlq["QueueUrl"],
            AttributeNames=["QueueArn"],
        )
        dlq_arn = dlq_attrs["Attributes"]["QueueArn"]

        main = client.create_queue(
            QueueName=QUEUE_NAME,
            Attributes={
                "RedrivePolicy": json.dumps({
                    "deadLetterTargetArn": dlq_arn,
                    "maxReceiveCount": "3",
                }),
            },
        )

        queue_url = main["QueueUrl"]
        monkeypatch.setenv("QUEUE_URL", queue_url)

        # producer.py は module-level で sqs client を生成するため再ロードが必要
        if "sandboxes.phase3.producer" in sys.modules:
            del sys.modules["sandboxes.phase3.producer"]

        yield client, queue_url, dlq["QueueUrl"]


# ── Producer テスト ───────────────────────────────────────────────────────────

def test_producer_sends_default_10_messages(sqs_queues):
    """count 省略時は 10 件送信し、返り値 sent=10 になる。"""
    client, queue_url, _ = sqs_queues

    from sandboxes.phase3 import producer as prod_mod
    result = prod_mod.handler({}, None)

    assert result["sent"] == 10

    resp = client.receive_message(
        QueueUrl=queue_url,
        MaxNumberOfMessages=10,
        WaitTimeSeconds=0,
    )
    # moto は receive_message で最大 10 件返す
    assert len(resp.get("Messages", [])) == 10


def test_producer_sends_custom_count(sqs_queues):
    """event["count"] を指定した件数だけ送信する。"""
    client, queue_url, _ = sqs_queues

    from sandboxes.phase3 import producer as prod_mod
    result = prod_mod.handler({"count": 3}, None)

    assert result["sent"] == 3

    resp = client.receive_message(
        QueueUrl=queue_url,
        MaxNumberOfMessages=10,
        WaitTimeSeconds=0,
    )
    assert len(resp.get("Messages", [])) == 3


def test_producer_message_body_contains_index(sqs_queues):
    """送信メッセージの body に index と ts が含まれる。"""
    client, queue_url, _ = sqs_queues

    from sandboxes.phase3 import producer as prod_mod
    prod_mod.handler({"count": 2}, None)

    resp = client.receive_message(
        QueueUrl=queue_url,
        MaxNumberOfMessages=2,
        WaitTimeSeconds=0,
    )
    msgs = resp.get("Messages", [])
    assert len(msgs) == 2
    for msg in msgs:
        body = json.loads(msg["Body"])
        assert "index" in body
        assert "ts" in body


# ── Consumer テスト ───────────────────────────────────────────────────────────

def _make_sqs_record(index: int, msg_id: str = "test-msg-id") -> dict:
    """Lambda SQS イベントレコードを生成するヘルパー。"""
    return {
        "messageId": msg_id,
        "receiptHandle": "test-receipt",
        "body": json.dumps({"index": index, "ts": 1234567890.0}),
        "attributes": {},
        "messageAttributes": {},
        "md5OfBody": "test",
        "eventSource": "aws:sqs",
        "eventSourceARN": f"arn:aws:sqs:{REGION}:123456789012:{QUEUE_NAME}",
        "awsRegion": REGION,
    }


def test_consumer_processes_normal_messages(capsys):
    """index が 7 の倍数でないメッセージは正常処理される。"""
    from sandboxes.phase3 import consumer as cons_mod

    event = {
        "Records": [
            _make_sqs_record(1, "msg-1"),
            _make_sqs_record(2, "msg-2"),
            _make_sqs_record(3, "msg-3"),
        ]
    }
    # 例外が発生しないことを確認
    cons_mod.handler(event, None)

    captured = capsys.readouterr()
    assert "Processing index=1" in captured.out
    assert "Processing index=2" in captured.out
    assert "Processing index=3" in captured.out


def test_consumer_raises_on_multiple_of_7():
    """index が 7 の倍数のメッセージは ValueError を投げる(DLQ 流入を模擬)。"""
    from sandboxes.phase3 import consumer as cons_mod

    event = {"Records": [_make_sqs_record(7, "msg-poison")]}

    with pytest.raises(ValueError, match="Intentional failure for index 7"):
        cons_mod.handler(event, None)


def test_consumer_raises_on_index_zero():
    """index=0 も 7 の倍数 (0 % 7 == 0) なので例外。"""
    from sandboxes.phase3 import consumer as cons_mod

    event = {"Records": [_make_sqs_record(0, "msg-zero")]}

    with pytest.raises(ValueError, match="Intentional failure for index 0"):
        cons_mod.handler(event, None)


def test_consumer_raises_on_index_14():
    """index=14 は 14 % 7 == 0 なので例外。"""
    from sandboxes.phase3 import consumer as cons_mod

    event = {"Records": [_make_sqs_record(14, "msg-14")]}

    with pytest.raises(ValueError, match="Intentional failure for index 14"):
        cons_mod.handler(event, None)


def test_consumer_fails_on_first_bad_record_in_batch():
    """バッチ内で最初に失敗した record で例外が伝播する。"""
    from sandboxes.phase3 import consumer as cons_mod

    event = {
        "Records": [
            _make_sqs_record(1, "msg-ok"),
            _make_sqs_record(7, "msg-bad"),  # ← ここで例外
            _make_sqs_record(2, "msg-ok2"),
        ]
    }
    with pytest.raises(ValueError):
        cons_mod.handler(event, None)
