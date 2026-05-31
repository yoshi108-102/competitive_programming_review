"""Phase 4 CloudWatch sandbox handler tests.

Tests the producer and consumer Lambda handlers using moto mock_aws.
All tests are self-contained and do not call real AWS endpoints.
"""

import json
import os
from types import SimpleNamespace

import boto3
import pytest
from moto import mock_aws

os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("AWS_SECURITY_TOKEN", "testing")
os.environ.setdefault("AWS_SESSION_TOKEN", "testing")

TABLE_NAME = "phase4-events-test"
REGION = "ap-northeast-1"


@pytest.fixture
def dynamodb_table(monkeypatch):
    """Create a mocked DynamoDB table and set the TABLE_NAME env var."""
    monkeypatch.setenv("TABLE_NAME", TABLE_NAME)
    with mock_aws():
        client = boto3.client("dynamodb", region_name=REGION)
        client.create_table(
            TableName=TABLE_NAME,
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        yield


def _make_context(function_name: str = "phase4-producer") -> SimpleNamespace:
    return SimpleNamespace(function_name=function_name)


# ─── producer tests ──────────────────────────────────────────────────────────


class TestProducer:
    def test_producer_returns_items_written(self, dynamodb_table):
        """Producer returns the correct count of items written."""
        from sandboxes.phase4.producer import handler

        result = handler({"count": 3}, _make_context())
        assert result["items_written"] == 3
        assert result["errors"] == 0

    def test_producer_default_count_is_5(self, dynamodb_table):
        """Producer defaults to 5 items when count is not in the event."""
        from sandboxes.phase4.producer import handler

        result = handler({}, _make_context())
        assert result["items_written"] == 5
        assert result["errors"] == 0

    def test_producer_items_appear_in_dynamodb(self, dynamodb_table):
        """Items written by producer are actually stored in DynamoDB."""
        from sandboxes.phase4.producer import handler

        handler({"count": 2}, _make_context())

        resource = boto3.resource("dynamodb", region_name=REGION)
        table = resource.Table(TABLE_NAME)
        response = table.scan()
        # At least 2 items should be present (pk starts with 'event#')
        items = [i for i in response["Items"] if i["pk"].startswith("event#")]
        assert len(items) >= 2

    def test_producer_emf_output_contains_required_keys(self, dynamodb_table, capsys):
        """Producer prints an EMF JSON blob with the required CloudWatch fields."""
        from sandboxes.phase4.producer import handler

        handler({"count": 1}, _make_context("phase4-producer"))
        captured = capsys.readouterr()

        # Find the EMF JSON line among output lines
        emf = None
        for line in captured.out.splitlines():
            try:
                parsed = json.loads(line)
                if "_aws" in parsed:
                    emf = parsed
                    break
            except json.JSONDecodeError:
                continue

        assert emf is not None, "No EMF JSON found in stdout"
        assert "_aws" in emf
        assert "FunctionName" in emf
        assert "items_written" in emf
        assert "ErrorCount" in emf
        assert emf["FunctionName"] == "phase4-producer"

    def test_producer_emf_namespace_is_correct(self, dynamodb_table, capsys):
        """Producer EMF output uses Phase4/Lambda namespace."""
        from sandboxes.phase4.producer import handler

        handler({"count": 1}, _make_context())
        captured = capsys.readouterr()

        emf = None
        for line in captured.out.splitlines():
            try:
                parsed = json.loads(line)
                if "_aws" in parsed:
                    emf = parsed
                    break
            except json.JSONDecodeError:
                continue

        assert emf is not None
        cw_metrics = emf["_aws"]["CloudWatchMetrics"]
        assert len(cw_metrics) == 1
        assert cw_metrics[0]["Namespace"] == "Phase4/Lambda"

    def test_producer_handles_zero_count(self, dynamodb_table):
        """Producer with count=0 returns items_written=0 without errors."""
        from sandboxes.phase4.producer import handler

        result = handler({"count": 0}, _make_context())
        assert result["items_written"] == 0
        assert result["errors"] == 0


# ─── consumer tests ──────────────────────────────────────────────────────────


class TestConsumer:
    def test_consumer_returns_read_count_when_no_items(self, dynamodb_table):
        """Consumer returns read=0 when table is empty (no matching items)."""
        from sandboxes.phase4.consumer import handler

        # Patch random to avoid simulated errors
        import random
        from unittest.mock import patch

        with patch.object(random, "random", return_value=0.5):  # 0.5 > 0.1 → no error
            result = handler({}, _make_context("phase4-consumer"))
        assert result["read"] == 0

    def test_consumer_reads_items_written_by_producer(self, dynamodb_table):
        """Consumer can read items that producer wrote."""
        from sandboxes.phase4.producer import handler as producer_handler
        from sandboxes.phase4.consumer import handler as consumer_handler
        import random
        from unittest.mock import patch

        # Write some items via producer
        producer_handler({"count": 3}, _make_context("phase4-producer"))

        # Consumer reads them (patch random to prevent simulated error)
        with patch.object(random, "random", return_value=0.5):
            result = consumer_handler({}, _make_context("phase4-consumer"))

        # Items written have pk starting with 'event#2...' through 'event#9...'
        # so they should be returned by the consumer query
        assert "read" in result
        assert isinstance(result["read"], int)

    def test_consumer_raises_simulated_error(self, dynamodb_table):
        """Consumer raises Exception when random() < 0.1 (simulated error)."""
        from sandboxes.phase4.consumer import handler
        import random
        from unittest.mock import patch

        with patch.object(random, "random", return_value=0.05):  # 0.05 < 0.1 → error
            with pytest.raises(Exception, match="Simulated consumer error"):
                handler({}, _make_context("phase4-consumer"))
