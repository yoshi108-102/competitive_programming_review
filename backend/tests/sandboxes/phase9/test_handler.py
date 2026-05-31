"""Phase 9 X-Ray sandbox — moto unit tests for producer and consumer handlers.

aws-xray-sdk is NOT installed in the test venv; both handlers fall back to
a no-op shim automatically.  All AWS calls are intercepted by moto mock_aws.
Tests are self-contained and do not call real AWS endpoints.
"""

import json
import os

import boto3
import pytest
from moto import mock_aws

# ── Dummy AWS credentials (required by moto) ─────────────────────────────────
os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("AWS_SECURITY_TOKEN", "testing")
os.environ.setdefault("AWS_SESSION_TOKEN", "testing")

TABLE_NAME = "phase9-items"
QUEUE_NAME = "phase9-main"
REGION = "ap-northeast-1"


# ── Fixtures ──────────────────────────────────────────────────────────────────


@pytest.fixture
def aws_resources(monkeypatch):
    """Spin up mocked DynamoDB table and SQS queue; patch env vars."""
    with mock_aws():
        # DynamoDB
        ddb = boto3.resource("dynamodb", region_name=REGION)
        table = ddb.create_table(
            TableName=TABLE_NAME,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )

        # SQS
        sqs = boto3.client("sqs", region_name=REGION)
        queue = sqs.create_queue(QueueName=QUEUE_NAME)
        queue_url = queue["QueueUrl"]

        # Env vars expected by handlers
        monkeypatch.setenv("TABLE_NAME", TABLE_NAME)
        monkeypatch.setenv("QUEUE_URL", queue_url)

        yield {
            "table": table,
            "sqs_client": sqs,
            "queue_url": queue_url,
        }


# ── Producer tests ────────────────────────────────────────────────────────────


def test_producer_returns_202(aws_resources):
    """producer.handler returns statusCode 202 on a normal event."""
    from sandboxes.phase9.producer import handler

    result = handler({"body": "{}"}, None)

    assert result["statusCode"] == 202


def test_producer_response_has_item_id(aws_resources):
    """Response body contains a non-empty item_id UUID."""
    from sandboxes.phase9.producer import handler

    result = handler({}, None)

    body = json.loads(result["body"])
    assert "item_id" in body
    assert len(body["item_id"]) == 36  # UUID4 canonical form


def test_producer_writes_to_dynamodb(aws_resources):
    """producer.handler puts an item with status='pending' into DynamoDB."""
    from sandboxes.phase9.producer import handler

    result = handler({}, None)

    item_id = json.loads(result["body"])["item_id"]
    table = aws_resources["table"]
    resp = table.get_item(Key={"id": item_id})
    assert "Item" in resp
    assert resp["Item"]["status"] == "pending"
    assert resp["Item"]["id"] == item_id


def test_producer_sends_sqs_message(aws_resources):
    """producer.handler enqueues exactly one SQS message containing the item_id."""
    from sandboxes.phase9.producer import handler

    result = handler({}, None)

    item_id = json.loads(result["body"])["item_id"]
    sqs_client = aws_resources["sqs_client"]
    queue_url = aws_resources["queue_url"]

    msgs = sqs_client.receive_message(
        QueueUrl=queue_url,
        MessageAttributeNames=["All"],
        MaxNumberOfMessages=10,
    )
    messages = msgs.get("Messages", [])
    assert len(messages) == 1
    body = json.loads(messages[0]["Body"])
    assert body["item_id"] == item_id


def test_producer_sqs_message_has_trace_attribute(aws_resources):
    """SQS message contains X-Amzn-Trace-Id message attribute for trace propagation."""
    from sandboxes.phase9.producer import handler

    handler({}, None)

    sqs_client = aws_resources["sqs_client"]
    queue_url = aws_resources["queue_url"]

    msgs = sqs_client.receive_message(
        QueueUrl=queue_url,
        MessageAttributeNames=["All"],
        MaxNumberOfMessages=1,
    )
    msg = msgs["Messages"][0]
    assert "X-Amzn-Trace-Id" in msg.get("MessageAttributes", {})


def test_producer_unique_item_ids(aws_resources):
    """Each invocation of producer.handler generates a distinct item_id."""
    from sandboxes.phase9.producer import handler

    result1 = handler({}, None)
    result2 = handler({}, None)

    id1 = json.loads(result1["body"])["item_id"]
    id2 = json.loads(result2["body"])["item_id"]
    assert id1 != id2


# ── Consumer tests ────────────────────────────────────────────────────────────


def _make_sqs_record(item_id: str, trace_id: str = "test-trace-001") -> dict:
    """Build a fake SQS record as Lambda would receive from the event source mapping."""
    return {
        "body": json.dumps({"item_id": item_id}),
        "messageAttributes": {
            "X-Amzn-Trace-Id": {
                "dataType": "String",
                "stringValue": trace_id,
            }
        },
        "receiptHandle": "dummy-receipt",
        "messageId": "dummy-message-id",
    }


def _put_item(table, item_id: str, status: str = "pending"):
    """Helper to pre-populate DynamoDB for consumer tests."""
    table.put_item(Item={"id": item_id, "status": status})


def test_consumer_updates_dynamodb_status(aws_resources):
    """consumer.handler updates item status to 'processed' in DynamoDB."""
    from sandboxes.phase9.consumer import handler

    item_id = "test-item-consumer-001"
    _put_item(aws_resources["table"], item_id)

    event = {"Records": [_make_sqs_record(item_id)]}
    handler(event, None)

    resp = aws_resources["table"].get_item(Key={"id": item_id})
    assert resp["Item"]["status"] == "processed"


def test_consumer_returns_processed_list(aws_resources):
    """consumer.handler returns a dict with 'processed' list of item_ids."""
    from sandboxes.phase9.consumer import handler

    item_id = "test-item-consumer-002"
    _put_item(aws_resources["table"], item_id)

    event = {"Records": [_make_sqs_record(item_id)]}
    result = handler(event, None)

    assert result["processed"] == [item_id]


def test_consumer_handles_multiple_records(aws_resources):
    """consumer.handler processes a batch of SQS records correctly."""
    from sandboxes.phase9.consumer import handler

    item_ids = [f"batch-item-{i}" for i in range(3)]
    for iid in item_ids:
        _put_item(aws_resources["table"], iid)

    records = [_make_sqs_record(iid) for iid in item_ids]
    result = handler({"Records": records}, None)

    assert set(result["processed"]) == set(item_ids)

    for iid in item_ids:
        resp = aws_resources["table"].get_item(Key={"id": iid})
        assert resp["Item"]["status"] == "processed"


def test_consumer_empty_event(aws_resources):
    """consumer.handler returns empty processed list when Records is absent."""
    from sandboxes.phase9.consumer import handler

    result = handler({}, None)

    assert result["processed"] == []


def test_consumer_tolerates_missing_trace_attribute(aws_resources):
    """consumer.handler does not raise when X-Amzn-Trace-Id attribute is absent."""
    from sandboxes.phase9.consumer import handler

    item_id = "test-item-no-trace"
    _put_item(aws_resources["table"], item_id)

    # Record without messageAttributes
    record = {"body": json.dumps({"item_id": item_id}), "messageAttributes": {}}
    result = handler({"Records": [record]}, None)

    assert item_id in result["processed"]
