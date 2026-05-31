"""Phase 10 SNS sandbox handler tests.

Uses moto mock_aws to provide self-contained SNS/SQS environments.
Tests confirm that the Lambda notifier correctly processes SNS records,
logs structured JSON, and raises ValueError for non-JSON payloads (DLQ path).
"""

import json
import logging
import os

import boto3
import pytest
from moto import mock_aws

# Dummy credentials — must be set before any boto3 import
os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("AWS_SECURITY_TOKEN", "testing")
os.environ.setdefault("AWS_SESSION_TOKEN", "testing")

REGION = "ap-northeast-1"
TOPIC_NAME = "phase10-orders"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _sns_event(message: str, subject: str = "New Order") -> dict:
    """Build a minimal SNS Lambda invocation payload."""
    return {
        "Records": [
            {
                "Sns": {
                    "Message": message,
                    "Subject": subject,
                    "TopicArn": f"arn:aws:sns:{REGION}:123456789012:{TOPIC_NAME}",
                }
            }
        ]
    }


def _sns_event_multi(messages: list[str]) -> dict:
    """Build an SNS event with multiple records."""
    return {
        "Records": [
            {
                "Sns": {
                    "Message": msg,
                    "Subject": "New Order",
                    "TopicArn": f"arn:aws:sns:{REGION}:123456789012:{TOPIC_NAME}",
                }
            }
            for msg in messages
        ]
    }


# ---------------------------------------------------------------------------
# Happy-path tests
# ---------------------------------------------------------------------------


def test_handler_returns_200_for_valid_json_message():
    """Valid JSON SNS message returns statusCode 200."""
    from sandboxes.phase10.handler import handler

    msg = json.dumps({"order_id": "ORD-001", "amount": 5000})
    result = handler(_sns_event(msg))
    assert result["statusCode"] == 200


def test_handler_returns_processed_count_single_record():
    """Single valid record returns processed=1."""
    from sandboxes.phase10.handler import handler

    msg = json.dumps({"order_id": "ORD-002", "amount": 3000})
    result = handler(_sns_event(msg))
    assert result["processed"] == 1


def test_handler_returns_processed_count_multiple_records():
    """Multiple valid records return correct processed count."""
    from sandboxes.phase10.handler import handler

    messages = [
        json.dumps({"order_id": f"ORD-{i:03d}", "amount": i * 100})
        for i in range(1, 4)
    ]
    result = handler(_sns_event_multi(messages))
    assert result["statusCode"] == 200
    assert result["processed"] == 3


def test_handler_empty_records_returns_200():
    """Empty Records list returns 200 with processed=0."""
    from sandboxes.phase10.handler import handler

    result = handler({"Records": []})
    assert result["statusCode"] == 200
    assert result["processed"] == 0


def test_handler_missing_records_key_returns_200():
    """Event without Records key returns 200 gracefully."""
    from sandboxes.phase10.handler import handler

    result = handler({})
    assert result["statusCode"] == 200
    assert result["processed"] == 0


def test_handler_preserves_order_id_in_log(caplog):
    """Handler logs the order_id from the SNS message as structured JSON."""
    from sandboxes.phase10.handler import handler

    msg = json.dumps({"order_id": "ORD-LOG-001", "amount": 9999})
    with caplog.at_level(logging.INFO):
        handler(_sns_event(msg))

    json_logs = []
    for record in caplog.records:
        try:
            parsed = json.loads(record.getMessage())
            json_logs.append(parsed)
        except (json.JSONDecodeError, ValueError):
            pass

    assert any(
        log.get("order_id") == "ORD-LOG-001" for log in json_logs
    ), f"Expected order_id in logs. Logs: {json_logs}"


def test_handler_logs_event_type_express_order_received(caplog):
    """Handler logs event=express_order_received for each record."""
    from sandboxes.phase10.handler import handler

    msg = json.dumps({"order_id": "ORD-EVT-001", "amount": 1234})
    with caplog.at_level(logging.INFO):
        handler(_sns_event(msg))

    info_logs = []
    for record in caplog.records:
        if record.levelno == logging.INFO:
            try:
                parsed = json.loads(record.getMessage())
                info_logs.append(parsed)
            except (json.JSONDecodeError, ValueError):
                pass

    assert any(
        log.get("event") == "express_order_received" for log in info_logs
    ), f"Expected event=express_order_received. Logs: {info_logs}"


def test_handler_logs_amount_from_message(caplog):
    """Handler logs the amount field from the SNS message."""
    from sandboxes.phase10.handler import handler

    msg = json.dumps({"order_id": "ORD-AMT-001", "amount": 7777})
    with caplog.at_level(logging.INFO):
        handler(_sns_event(msg))

    for record in caplog.records:
        try:
            parsed = json.loads(record.getMessage())
            if parsed.get("amount") == 7777:
                return
        except (json.JSONDecodeError, ValueError):
            pass

    pytest.fail("Expected amount=7777 in log output")


# ---------------------------------------------------------------------------
# DLQ / error path tests
# ---------------------------------------------------------------------------


def test_handler_raises_value_error_for_non_json_message():
    """Non-JSON SNS message raises ValueError (triggers DLQ path)."""
    from sandboxes.phase10.handler import handler

    with pytest.raises(ValueError, match="not valid JSON"):
        handler(_sns_event("NOT_JSON"))


def test_handler_raises_value_error_for_empty_string_message():
    """Empty string SNS message raises ValueError."""
    from sandboxes.phase10.handler import handler

    with pytest.raises(ValueError, match="not valid JSON"):
        handler(_sns_event(""))


def test_handler_raises_value_error_for_plain_text_message():
    """Plain text SNS message raises ValueError (not valid JSON)."""
    from sandboxes.phase10.handler import handler

    with pytest.raises(ValueError, match="not valid JSON"):
        handler(_sns_event("Hello this is a plain text message"))


def test_handler_logs_error_event_for_malformed_message(caplog):
    """Handler logs event=malformed_message before raising ValueError."""
    from sandboxes.phase10.handler import handler

    with caplog.at_level(logging.ERROR):
        with pytest.raises(ValueError):
            handler(_sns_event("BAD_PAYLOAD"))

    error_logs = []
    for record in caplog.records:
        if record.levelno == logging.ERROR:
            try:
                parsed = json.loads(record.getMessage())
                error_logs.append(parsed)
            except (json.JSONDecodeError, ValueError):
                pass

    assert any(
        log.get("event") == "malformed_message" for log in error_logs
    ), f"Expected event=malformed_message in error logs. Logs: {error_logs}"


# ---------------------------------------------------------------------------
# moto SNS integration tests — fan-out scenario
# ---------------------------------------------------------------------------


@mock_aws
def test_sns_publish_delivers_to_sqs_queue():
    """moto: publishing to SNS topic delivers to subscribed SQS queue."""
    sns = boto3.client("sns", region_name=REGION)
    sqs = boto3.client("sqs", region_name=REGION)

    topic_resp = sns.create_topic(Name=TOPIC_NAME)
    topic_arn = topic_resp["TopicArn"]

    queue_resp = sqs.create_queue(QueueName="phase10-test-analytics")
    queue_url = queue_resp["QueueUrl"]
    queue_attrs = sqs.get_queue_attributes(
        QueueUrl=queue_url, AttributeNames=["QueueArn"]
    )
    queue_arn = queue_attrs["Attributes"]["QueueArn"]

    # Allow SNS to send to SQS
    sqs.set_queue_attributes(
        QueueUrl=queue_url,
        Attributes={
            "Policy": json.dumps({
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"Service": "sns.amazonaws.com"},
                    "Action": "sqs:SendMessage",
                    "Resource": queue_arn,
                    "Condition": {"ArnEquals": {"aws:SourceArn": topic_arn}},
                }],
            })
        },
    )

    sns.subscribe(
        TopicArn=topic_arn,
        Protocol="sqs",
        Endpoint=queue_arn,
    )

    order = json.dumps({"order_id": "ORD-MOTO-001", "amount": 5000})
    sns.publish(
        TopicArn=topic_arn,
        Message=order,
        MessageAttributes={
            "order_type": {"DataType": "String", "StringValue": "analytics"}
        },
    )

    messages = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1)
    assert "Messages" in messages, "Expected at least one message in SQS queue"

    body = json.loads(messages["Messages"][0]["Body"])
    inner = json.loads(body["Message"])
    assert inner["order_id"] == "ORD-MOTO-001"


@mock_aws
def test_sns_filter_policy_blocks_non_matching_messages():
    """moto: messages not matching filter policy are NOT delivered to filtered queue."""
    sns = boto3.client("sns", region_name=REGION)
    sqs = boto3.client("sqs", region_name=REGION)

    topic_resp = sns.create_topic(Name=TOPIC_NAME)
    topic_arn = topic_resp["TopicArn"]

    queue_resp = sqs.create_queue(QueueName="phase10-test-wholesale")
    queue_url = queue_resp["QueueUrl"]
    queue_attrs = sqs.get_queue_attributes(
        QueueUrl=queue_url, AttributeNames=["QueueArn"]
    )
    queue_arn = queue_attrs["Attributes"]["QueueArn"]

    sqs.set_queue_attributes(
        QueueUrl=queue_url,
        Attributes={
            "Policy": json.dumps({
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"Service": "sns.amazonaws.com"},
                    "Action": "sqs:SendMessage",
                    "Resource": queue_arn,
                }],
            })
        },
    )

    # Subscribe with wholesale-only filter
    sns.subscribe(
        TopicArn=topic_arn,
        Protocol="sqs",
        Endpoint=queue_arn,
        Attributes={
            "FilterPolicy": json.dumps({"order_type": ["wholesale"]})
        },
    )

    # Publish a "standard" order — should NOT reach wholesale queue
    sns.publish(
        TopicArn=topic_arn,
        Message=json.dumps({"order_id": "ORD-STD-001", "amount": 1000}),
        MessageAttributes={
            "order_type": {"DataType": "String", "StringValue": "standard"}
        },
    )

    messages = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1)
    assert "Messages" not in messages, (
        "Standard order should NOT be delivered to wholesale queue"
    )


@mock_aws
def test_sns_filter_policy_delivers_matching_messages():
    """moto: messages matching filter policy ARE delivered to filtered queue."""
    sns = boto3.client("sns", region_name=REGION)
    sqs = boto3.client("sqs", region_name=REGION)

    topic_resp = sns.create_topic(Name=TOPIC_NAME)
    topic_arn = topic_resp["TopicArn"]

    queue_resp = sqs.create_queue(QueueName="phase10-test-wholesale-match")
    queue_url = queue_resp["QueueUrl"]
    queue_attrs = sqs.get_queue_attributes(
        QueueUrl=queue_url, AttributeNames=["QueueArn"]
    )
    queue_arn = queue_attrs["Attributes"]["QueueArn"]

    sqs.set_queue_attributes(
        QueueUrl=queue_url,
        Attributes={
            "Policy": json.dumps({
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"Service": "sns.amazonaws.com"},
                    "Action": "sqs:SendMessage",
                    "Resource": queue_arn,
                }],
            })
        },
    )

    sns.subscribe(
        TopicArn=topic_arn,
        Protocol="sqs",
        Endpoint=queue_arn,
        Attributes={
            "FilterPolicy": json.dumps({"order_type": ["wholesale"]})
        },
    )

    # Publish a "wholesale" order — should reach the queue
    sns.publish(
        TopicArn=topic_arn,
        Message=json.dumps({"order_id": "ORD-WHL-001", "amount": 99000}),
        MessageAttributes={
            "order_type": {"DataType": "String", "StringValue": "wholesale"}
        },
    )

    messages = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1)
    assert "Messages" in messages, "Wholesale order should be delivered to wholesale queue"
    body = json.loads(messages["Messages"][0]["Body"])
    inner = json.loads(body["Message"])
    assert inner["order_id"] == "ORD-WHL-001"
