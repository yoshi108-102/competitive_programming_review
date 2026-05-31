"""Phase 7 EventBridge Lambda handler tests.

Uses moto to mock the AWS Events service. All tests are self-contained
and do not call real AWS endpoints.

Handler contract:
  - Accepts any dict event with optional keys: source, detail-type, detail
  - Returns dict with statusCode=200, source, and detail-type fields
  - Prints an EMF JSON record to stdout for CloudWatch custom metrics
"""

import json
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
BUS_NAME = "phase7-bus"


@pytest.fixture(autouse=True)
def lambda_env(monkeypatch):
    """Set environment variables expected by the handler."""
    monkeypatch.setenv("LOG_LEVEL", "INFO")
    monkeypatch.setenv("BUS_NAME", BUS_NAME)


@pytest.fixture
def events_client():
    """Mocked EventBridge client with a custom bus pre-created."""
    with mock_aws():
        client = boto3.client("events", region_name=REGION)
        client.create_event_bus(Name=BUS_NAME)
        yield client


# ─── Handler return value tests ──────────────────────────────────────────────


def test_handler_returns_200_for_order_event(events_client):
    """Happy path: order.created event yields statusCode 200."""
    from sandboxes.phase7.handler import lambda_handler

    event = {
        "source": "com.example.orders",
        "detail-type": "order.created",
        "detail": {"orderId": "order-001", "amount": 5000},
    }
    result = lambda_handler(event, None)

    assert result["statusCode"] == 200


def test_handler_echoes_source_in_response(events_client):
    """Handler returns the source field from the incoming event."""
    from sandboxes.phase7.handler import lambda_handler

    event = {
        "source": "com.example.orders",
        "detail-type": "order.created",
        "detail": {},
    }
    result = lambda_handler(event, None)

    assert result["source"] == "com.example.orders"


def test_handler_echoes_detail_type_in_response(events_client):
    """Handler returns the detail-type field from the incoming event."""
    from sandboxes.phase7.handler import lambda_handler

    event = {
        "source": "com.example.orders",
        "detail-type": "order.created",
        "detail": {},
    }
    result = lambda_handler(event, None)

    assert result["detail-type"] == "order.created"


def test_handler_defaults_source_to_scheduled(events_client):
    """When source is absent, handler defaults to 'scheduled'."""
    from sandboxes.phase7.handler import lambda_handler

    result = lambda_handler({}, None)

    assert result["source"] == "scheduled"


def test_handler_defaults_detail_type_to_unknown(events_client):
    """When detail-type is absent, handler defaults to 'unknown'."""
    from sandboxes.phase7.handler import lambda_handler

    result = lambda_handler({}, None)

    assert result["detail-type"] == "unknown"


# ─── EMF metric output tests ─────────────────────────────────────────────────


def test_handler_prints_emf_json(events_client, capsys):
    """Handler prints a JSON line containing CloudWatchMetrics (EMF format)."""
    from sandboxes.phase7.handler import lambda_handler

    lambda_handler({"source": "com.example.orders", "detail-type": "order.created", "detail": {}}, None)

    captured = capsys.readouterr()
    emf = json.loads(captured.out.strip())
    assert "_aws" in emf
    assert "CloudWatchMetrics" in emf["_aws"]


def test_handler_emf_namespace_is_phase7(events_client, capsys):
    """EMF record uses namespace 'Phase7/EventBridge'."""
    from sandboxes.phase7.handler import lambda_handler

    lambda_handler({"source": "scheduler.demo", "detail-type": "ScheduledOneShot", "detail": {}}, None)

    captured = capsys.readouterr()
    emf = json.loads(captured.out.strip())
    namespace = emf["_aws"]["CloudWatchMetrics"][0]["Namespace"]
    assert namespace == "Phase7/EventBridge"


def test_handler_emf_events_processed_is_1(events_client, capsys):
    """EMF record sets EventsProcessed=1 per invocation."""
    from sandboxes.phase7.handler import lambda_handler

    lambda_handler({}, None)

    captured = capsys.readouterr()
    emf = json.loads(captured.out.strip())
    assert emf["EventsProcessed"] == 1


def test_handler_emf_source_dimension_matches_event(events_client, capsys):
    """EMF Source dimension reflects the event source field."""
    from sandboxes.phase7.handler import lambda_handler

    lambda_handler({"source": "load.sh", "detail-type": "DirectInvoke", "detail": {}}, None)

    captured = capsys.readouterr()
    emf = json.loads(captured.out.strip())
    assert emf["Source"] == "load.sh"


def test_handler_emf_timestamp_is_positive_int(events_client, capsys):
    """EMF Timestamp is a positive integer (milliseconds since epoch)."""
    from sandboxes.phase7.handler import lambda_handler

    lambda_handler({}, None)

    captured = capsys.readouterr()
    emf = json.loads(captured.out.strip())
    ts = emf["_aws"]["Timestamp"]
    assert isinstance(ts, int)
    assert ts > 0


# ─── moto EventBridge integration ────────────────────────────────────────────


def test_put_events_to_custom_bus_succeeds(events_client):
    """put-events to the custom bus returns FailedEntryCount=0."""
    response = events_client.put_events(
        Entries=[
            {
                "EventBusName": BUS_NAME,
                "Source": "com.example.orders",
                "DetailType": "order.created",
                "Detail": json.dumps({"orderId": "order-test", "amount": 9999}),
            }
        ]
    )
    assert response["FailedEntryCount"] == 0


def test_custom_bus_exists_after_creation(events_client):
    """Custom event bus is present in list-event-buses response."""
    response = events_client.list_event_buses(NamePrefix=BUS_NAME)
    names = [bus["Name"] for bus in response["EventBuses"]]
    assert BUS_NAME in names
