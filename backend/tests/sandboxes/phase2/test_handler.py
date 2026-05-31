"""Phase 2 S3 sandbox handler tests.

Uses moto mock_aws to provide a self-contained S3 environment.
Tests confirm that lambda_handler correctly parses S3 ObjectCreated
event records and returns the expected response.
"""

import json
import os

import boto3
import pytest
from moto import mock_aws

# Set dummy credentials before any boto3 calls
os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("AWS_SECURITY_TOKEN", "testing")
os.environ.setdefault("AWS_SESSION_TOKEN", "testing")

REGION = "ap-northeast-1"
TEST_BUCKET = "phase2-test-bucket"


def _make_s3_event(bucket: str, key: str, size: int = 1024) -> dict:
    """Build a minimal S3 ObjectCreated event payload."""
    return {
        "Records": [
            {
                "s3": {
                    "bucket": {"name": bucket},
                    "object": {"key": key, "size": size},
                }
            }
        ]
    }


def _make_multi_record_event(bucket: str, keys: list[str]) -> dict:
    """Build an S3 event with multiple records."""
    return {
        "Records": [
            {
                "s3": {
                    "bucket": {"name": bucket},
                    "object": {"key": k, "size": (i + 1) * 100},
                }
            }
            for i, k in enumerate(keys)
        ]
    }


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def clear_cloudwatch_namespace(monkeypatch):
    """Ensure CLOUDWATCH_NAMESPACE is unset so custom metric path is skipped."""
    monkeypatch.delenv("CLOUDWATCH_NAMESPACE", raising=False)


@pytest.fixture
def s3_bucket():
    """Create a real (mocked) S3 bucket for use in tests that need actual S3."""
    with mock_aws():
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(
            Bucket=TEST_BUCKET,
            CreateBucketConfiguration={"LocationConstraint": REGION},
        )
        yield s3


# ---------------------------------------------------------------------------
# Happy-path tests
# ---------------------------------------------------------------------------

def test_handler_returns_200_on_single_record():
    """Happy path: single S3 record returns statusCode 200."""
    from sandboxes.phase2.handler import lambda_handler

    event = _make_s3_event(TEST_BUCKET, "uploads/test.txt", size=512)
    result = lambda_handler(event, None)

    assert result["statusCode"] == 200


def test_handler_returns_processed_count_single():
    """Handler returns the number of processed records."""
    from sandboxes.phase2.handler import lambda_handler

    event = _make_s3_event(TEST_BUCKET, "uploads/test.txt")
    result = lambda_handler(event, None)

    assert result["processed"] == 1


def test_handler_returns_200_on_multiple_records():
    """Handler processes multiple records and returns 200."""
    from sandboxes.phase2.handler import lambda_handler

    event = _make_multi_record_event(TEST_BUCKET, ["a.txt", "b.txt", "c.txt"])
    result = lambda_handler(event, None)

    assert result["statusCode"] == 200
    assert result["processed"] == 3


def test_handler_empty_records_returns_200():
    """Empty Records list still returns 200 with 0 processed."""
    from sandboxes.phase2.handler import lambda_handler

    result = lambda_handler({"Records": []}, None)

    assert result["statusCode"] == 200
    assert result["processed"] == 0


def test_handler_missing_records_key_returns_200():
    """Event without Records key (edge case) returns 200 gracefully."""
    from sandboxes.phase2.handler import lambda_handler

    result = lambda_handler({}, None)

    assert result["statusCode"] == 200
    assert result["processed"] == 0


def test_handler_object_size_zero_is_accepted():
    """Size can be 0 (e.g. empty file) without causing an error."""
    from sandboxes.phase2.handler import lambda_handler

    event = _make_s3_event(TEST_BUCKET, "empty.txt", size=0)
    result = lambda_handler(event, None)

    assert result["statusCode"] == 200


def test_handler_key_with_spaces_and_special_chars():
    """Keys with URL-encoded chars or spaces are handled without errors."""
    from sandboxes.phase2.handler import lambda_handler

    event = _make_s3_event(TEST_BUCKET, "path/to/file with spaces.json", size=256)
    result = lambda_handler(event, None)

    assert result["statusCode"] == 200


# ---------------------------------------------------------------------------
# Logging / JSON output tests (verify log output is well-formed JSON)
# ---------------------------------------------------------------------------

def test_handler_logs_valid_json(caplog):
    """Each record produces a valid JSON log line."""
    import logging

    from sandboxes.phase2.handler import lambda_handler

    with caplog.at_level(logging.INFO):
        event = _make_s3_event(TEST_BUCKET, "data/file.csv", size=2048)
        lambda_handler(event, None)

    # Find lines that are valid JSON with expected keys
    json_logs = []
    for record in caplog.records:
        try:
            parsed = json.loads(record.getMessage())
            json_logs.append(parsed)
        except (json.JSONDecodeError, ValueError):
            pass

    assert len(json_logs) >= 1
    log_entry = json_logs[0]
    assert log_entry["bucket"] == TEST_BUCKET
    assert log_entry["key"] == "data/file.csv"
    assert log_entry["size_bytes"] == 2048


def test_handler_logs_size_bytes_as_number(caplog):
    """size_bytes in the log is an integer, not a string."""
    import logging

    from sandboxes.phase2.handler import lambda_handler

    with caplog.at_level(logging.INFO):
        event = _make_s3_event(TEST_BUCKET, "file.bin", size=999)
        lambda_handler(event, None)

    for record in caplog.records:
        try:
            parsed = json.loads(record.getMessage())
            if "size_bytes" in parsed:
                assert isinstance(parsed["size_bytes"], int)
        except (json.JSONDecodeError, ValueError):
            pass


# ---------------------------------------------------------------------------
# Custom metric path (optional, only when CLOUDWATCH_NAMESPACE is set)
# ---------------------------------------------------------------------------

@mock_aws
def test_handler_does_not_call_cloudwatch_when_namespace_unset():
    """When CLOUDWATCH_NAMESPACE is not set, CloudWatch put_metric_data is skipped."""
    import unittest.mock as mock

    from sandboxes.phase2 import handler as handler_module

    with mock.patch.object(handler_module, "boto3") as mock_boto3:
        # CLOUDWATCH_NAMESPACE is unset (fixture clears it)
        handler_module.CLOUDWATCH_NAMESPACE = ""
        event = _make_s3_event(TEST_BUCKET, "test.txt", size=100)
        handler_module.lambda_handler(event, None)
        # boto3.client should NOT have been called for cloudwatch
        mock_boto3.client.assert_not_called()


@mock_aws
def test_handler_calls_cloudwatch_when_namespace_set(monkeypatch):
    """When CLOUDWATCH_NAMESPACE is set, put_metric_data is called once per record."""
    import unittest.mock as mock

    from sandboxes.phase2 import handler as handler_module

    namespace = "Phase2/Custom"
    monkeypatch.setenv("CLOUDWATCH_NAMESPACE", namespace)
    handler_module.CLOUDWATCH_NAMESPACE = namespace

    mock_cw_client = mock.MagicMock()
    with mock.patch("boto3.client", return_value=mock_cw_client):
        event = _make_s3_event(TEST_BUCKET, "test.txt", size=1234)
        handler_module.lambda_handler(event, None)

    mock_cw_client.put_metric_data.assert_called_once()
    call_kwargs = mock_cw_client.put_metric_data.call_args
    assert call_kwargs.kwargs["Namespace"] == namespace
    metric = call_kwargs.kwargs["MetricData"][0]
    assert metric["MetricName"] == "ObjectSizeBytes"
    assert metric["Value"] == 1234.0
