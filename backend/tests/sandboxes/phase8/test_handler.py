"""Phase 8 Step Functions Lambda handler tests.

Uses moto to mock DynamoDB and SNS. All tests are self-contained
and do not call real AWS endpoints.

Handler contract:
  - validate_order: raises ValueError for invalid orders; writes VALIDATED status to DynamoDB
  - charge_payment: raises RuntimeError for amount > 50000; writes PAYMENT_CHARGED status
  - update_inventory: raises RuntimeError for qty > 100; writes INVENTORY_UPDATED status
  - notify_customer: publishes to SNS topic; returns notification_status=SENT
  - compensate_order: writes COMPENSATED status with error_info; returns compensation_status=DONE
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
ORDERS_TABLE = "phase8-orders"


@pytest.fixture(autouse=True)
def lambda_env(monkeypatch):
    """Set environment variables expected by the handler."""
    monkeypatch.setenv("ORDERS_TABLE", ORDERS_TABLE)
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)


@pytest.fixture
def dynamodb_table():
    """Mocked DynamoDB table for orders."""
    with mock_aws():
        dynamodb = boto3.resource("dynamodb", region_name=REGION)
        table = dynamodb.create_table(
            TableName=ORDERS_TABLE,
            KeySchema=[{"AttributeName": "order_id", "KeyType": "HASH"}],
            AttributeDefinitions=[
                {"AttributeName": "order_id", "AttributeType": "S"}
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        yield table


@pytest.fixture
def sns_topic(dynamodb_table):
    """Mocked SNS topic for order notifications (requires mock_aws context from dynamodb_table)."""
    sns = boto3.client("sns", region_name=REGION)
    response = sns.create_topic(Name="phase8-order-notify")
    topic_arn = response["TopicArn"]
    return topic_arn


# ---------------------------------------------------------------------------
# validate_order tests
# ---------------------------------------------------------------------------


def test_validate_order_happy_path_returns_validation_ok(dynamodb_table):
    """Valid order event returns validation_status=OK."""
    from sandboxes.phase8.handler import validate_order

    event = {
        "order_id": "order-001",
        "amount": 5000,
        "customer_id": "cust-001",
        "items": [{"sku": "SKU-A", "qty": 2}],
    }
    result = validate_order(event)
    assert result["validation_status"] == "OK"


def test_validate_order_preserves_original_event_fields(dynamodb_table):
    """validate_order returns all original event fields plus validation_status."""
    from sandboxes.phase8.handler import validate_order

    event = {
        "order_id": "order-002",
        "amount": 1000,
        "customer_id": "cust-002",
        "items": [{"sku": "SKU-B", "qty": 1}],
    }
    result = validate_order(event)
    assert result["order_id"] == "order-002"
    assert result["amount"] == 1000


def test_validate_order_writes_status_to_dynamodb(dynamodb_table):
    """validate_order writes VALIDATED status to DynamoDB."""
    from sandboxes.phase8.handler import validate_order

    event = {
        "order_id": "order-003",
        "amount": 2000,
        "customer_id": "cust-003",
        "items": [{"sku": "SKU-C", "qty": 3}],
    }
    validate_order(event)
    item = dynamodb_table.get_item(Key={"order_id": "order-003"})["Item"]
    assert item["status"] == "VALIDATED"


def test_validate_order_raises_for_zero_amount(dynamodb_table):
    """validate_order raises ValueError when amount <= 0."""
    from sandboxes.phase8.handler import validate_order

    event = {
        "order_id": "order-bad",
        "amount": 0,
        "customer_id": "cust-bad",
        "items": [],
    }
    with pytest.raises(ValueError, match="INVALID_ORDER"):
        validate_order(event)


def test_validate_order_raises_for_missing_order_id(dynamodb_table):
    """validate_order raises ValueError when order_id is missing."""
    from sandboxes.phase8.handler import validate_order

    event = {"amount": 1000, "customer_id": "cust-x", "items": [{"sku": "A", "qty": 1}]}
    with pytest.raises(ValueError, match="INVALID_ORDER"):
        validate_order(event)


def test_validate_order_raises_for_empty_items(dynamodb_table):
    """validate_order raises ValueError when items list is empty."""
    from sandboxes.phase8.handler import validate_order

    event = {"order_id": "order-no-items", "amount": 500, "customer_id": "cust-x", "items": []}
    with pytest.raises(ValueError, match="INVALID_ORDER"):
        validate_order(event)


# ---------------------------------------------------------------------------
# charge_payment tests
# ---------------------------------------------------------------------------


def test_charge_payment_happy_path_returns_charged(dynamodb_table):
    """Normal amount returns payment_status=CHARGED."""
    from sandboxes.phase8.handler import validate_order, charge_payment

    order_id = "order-pay-001"
    event = {"order_id": order_id, "amount": 5000, "customer_id": "cust-001",
             "items": [{"sku": "A", "qty": 1}]}
    validate_order(event)
    result = charge_payment(event)
    assert result["payment_status"] == "CHARGED"


def test_charge_payment_writes_status_to_dynamodb(dynamodb_table):
    """charge_payment writes PAYMENT_CHARGED status to DynamoDB."""
    from sandboxes.phase8.handler import validate_order, charge_payment

    order_id = "order-pay-002"
    event = {"order_id": order_id, "amount": 3000, "customer_id": "cust-001",
             "items": [{"sku": "B", "qty": 2}]}
    validate_order(event)
    charge_payment(event)
    item = dynamodb_table.get_item(Key={"order_id": order_id})["Item"]
    assert item["status"] == "PAYMENT_CHARGED"


def test_charge_payment_raises_for_high_amount(dynamodb_table):
    """charge_payment raises RuntimeError for amount > 50000."""
    from sandboxes.phase8.handler import validate_order, charge_payment

    order_id = "order-pay-big"
    event = {"order_id": order_id, "amount": 99999, "customer_id": "cust-001",
             "items": [{"sku": "C", "qty": 1}]}
    validate_order(event)
    with pytest.raises(RuntimeError, match="PAYMENT_DECLINED"):
        charge_payment(event)


# ---------------------------------------------------------------------------
# update_inventory tests
# ---------------------------------------------------------------------------


def test_update_inventory_happy_path_returns_updated(dynamodb_table):
    """Normal qty returns inventory_status=UPDATED."""
    from sandboxes.phase8.handler import validate_order, charge_payment, update_inventory

    order_id = "order-inv-001"
    event = {"order_id": order_id, "amount": 2000, "customer_id": "cust-001",
             "items": [{"sku": "SKU-A", "qty": 5}]}
    validate_order(event)
    charge_payment(event)
    result = update_inventory(event)
    assert result["inventory_status"] == "UPDATED"


def test_update_inventory_writes_status_to_dynamodb(dynamodb_table):
    """update_inventory writes INVENTORY_UPDATED status to DynamoDB."""
    from sandboxes.phase8.handler import validate_order, charge_payment, update_inventory

    order_id = "order-inv-002"
    event = {"order_id": order_id, "amount": 1500, "customer_id": "cust-001",
             "items": [{"sku": "SKU-B", "qty": 10}]}
    validate_order(event)
    charge_payment(event)
    update_inventory(event)
    item = dynamodb_table.get_item(Key={"order_id": order_id})["Item"]
    assert item["status"] == "INVENTORY_UPDATED"


def test_update_inventory_raises_for_large_qty(dynamodb_table):
    """update_inventory raises RuntimeError when qty > 100 (out of stock)."""
    from sandboxes.phase8.handler import validate_order, charge_payment, update_inventory

    order_id = "order-inv-rare"
    event = {"order_id": order_id, "amount": 5000, "customer_id": "cust-001",
             "items": [{"sku": "SKU-RARE", "qty": 9999}]}
    validate_order(event)
    charge_payment(event)
    with pytest.raises(RuntimeError, match="INVENTORY_SHORTAGE"):
        update_inventory(event)


# ---------------------------------------------------------------------------
# notify_customer tests
# ---------------------------------------------------------------------------


def test_notify_customer_returns_sent(dynamodb_table, sns_topic, monkeypatch):
    """notify_customer returns notification_status=SENT."""
    from sandboxes.phase8.handler import validate_order, charge_payment, update_inventory, notify_customer

    monkeypatch.setenv("SNS_TOPIC_ARN", sns_topic)

    order_id = "order-notify-001"
    event = {"order_id": order_id, "amount": 3000, "customer_id": "cust-001",
             "items": [{"sku": "SKU-A", "qty": 1}]}
    validate_order(event)
    charge_payment(event)
    update_inventory(event)
    result = notify_customer(event)
    assert result["notification_status"] == "SENT"


def test_notify_customer_without_sns_topic_still_returns_sent(dynamodb_table, monkeypatch):
    """notify_customer returns SENT even without SNS_TOPIC_ARN (skips publish)."""
    from sandboxes.phase8.handler import validate_order, notify_customer

    monkeypatch.setenv("SNS_TOPIC_ARN", "")

    order_id = "order-notify-002"
    event = {"order_id": order_id, "amount": 1000, "customer_id": "cust-001",
             "items": [{"sku": "SKU-A", "qty": 1}]}
    validate_order(event)
    result = notify_customer(event)
    assert result["notification_status"] == "SENT"


# ---------------------------------------------------------------------------
# compensate_order tests
# ---------------------------------------------------------------------------


def test_compensate_order_returns_done(dynamodb_table):
    """compensate_order returns compensation_status=DONE."""
    from sandboxes.phase8.handler import validate_order, compensate_order

    order_id = "order-comp-001"
    event = {"order_id": order_id, "amount": 1000, "customer_id": "cust-001",
             "items": [{"sku": "A", "qty": 1}], "error": {"Error": "ValidationError"}}
    validate_order(event)
    result = compensate_order(event)
    assert result["compensation_status"] == "DONE"


def test_compensate_order_writes_compensated_status(dynamodb_table):
    """compensate_order writes COMPENSATED status to DynamoDB."""
    from sandboxes.phase8.handler import validate_order, compensate_order

    order_id = "order-comp-002"
    event = {"order_id": order_id, "amount": 1000, "customer_id": "cust-001",
             "items": [{"sku": "A", "qty": 1}], "error": {"Error": "PaymentFailed"}}
    validate_order(event)
    compensate_order(event)
    item = dynamodb_table.get_item(Key={"order_id": order_id})["Item"]
    assert item["status"] == "COMPENSATED"


def test_compensate_order_stores_error_info(dynamodb_table):
    """compensate_order stores error_info in DynamoDB for auditability."""
    from sandboxes.phase8.handler import validate_order, compensate_order

    order_id = "order-comp-003"
    error_info = {"Error": "InventoryShortage", "Cause": "Out of stock"}
    event = {"order_id": order_id, "amount": 1000, "customer_id": "cust-001",
             "items": [{"sku": "A", "qty": 1}], "error": error_info}
    validate_order(event)
    compensate_order(event)
    item = dynamodb_table.get_item(Key={"order_id": order_id})["Item"]
    stored = json.loads(item["error_info"])
    assert stored["Error"] == "InventoryShortage"
