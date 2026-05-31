"""Phase 6 Bedrock invoker Lambda handler tests.

moto does not yet implement bedrock-runtime InvokeModel, so we patch boto3
at the module level to return a realistic Claude response shape.
All tests are self-contained and do not call real AWS endpoints.
"""

import io
import json
import os
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

# Set dummy credentials so boto3 does not complain
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("AWS_SECURITY_TOKEN", "testing")
os.environ.setdefault("AWS_SESSION_TOKEN", "testing")

MODEL_ID = "anthropic.claude-3-haiku-20240307-v1:0"
REGION = "us-east-1"


def _make_bedrock_response(text: str = "Hello! I am Claude.", input_tokens: int = 10, output_tokens: int = 8) -> dict:
    """Build a fake bedrock-runtime invoke_model response matching the Claude API shape."""
    body_bytes = json.dumps({
        "content": [{"type": "text", "text": text}],
        "usage": {"input_tokens": input_tokens, "output_tokens": output_tokens},
    }).encode()

    mock_resp = {
        "body": io.BytesIO(body_bytes),
        "contentType": "application/json",
    }
    return mock_resp


@pytest.fixture(autouse=True)
def lambda_env(monkeypatch):
    """Set environment variables expected by the handler."""
    monkeypatch.setenv("MODEL_ID", MODEL_ID)
    monkeypatch.setenv("REGION", REGION)


@pytest.fixture
def mock_bedrock_client():
    """Patch boto3.client to return a mock bedrock-runtime client."""
    mock_client = MagicMock()
    mock_client.invoke_model.return_value = _make_bedrock_response()

    with patch("boto3.client", return_value=mock_client) as mock_boto3:
        yield mock_client, mock_boto3


def test_handler_returns_200_with_text(mock_bedrock_client):
    """Happy path: handler returns statusCode 200 and the model response text."""
    from sandboxes.phase6.handler import handler

    mock_client, _ = mock_bedrock_client
    mock_client.invoke_model.return_value = _make_bedrock_response("Hello! I am Claude.")

    result = handler({"prompt": "Say hello in one sentence."}, None)

    assert result["statusCode"] == 200
    assert result["body"] == "Hello! I am Claude."


def test_handler_default_prompt_when_not_provided(mock_bedrock_client):
    """When no prompt key in event, handler falls back to the default prompt."""
    from sandboxes.phase6.handler import handler

    mock_client, _ = mock_bedrock_client
    mock_client.invoke_model.return_value = _make_bedrock_response("Default response.")

    result = handler({}, None)

    # Verify invoke_model was called
    mock_client.invoke_model.assert_called_once()
    call_kwargs = mock_client.invoke_model.call_args
    body = json.loads(call_kwargs.kwargs["body"])
    assert body["messages"][0]["content"] == "Say hello in one sentence."


def test_handler_uses_env_model_id(mock_bedrock_client):
    """Handler picks up MODEL_ID from env and passes it to invoke_model."""
    from sandboxes.phase6.handler import handler

    mock_client, _ = mock_bedrock_client
    mock_client.invoke_model.return_value = _make_bedrock_response("Test.")

    handler({"prompt": "Test prompt"}, None)

    call_kwargs = mock_client.invoke_model.call_args
    assert call_kwargs.kwargs["modelId"] == MODEL_ID


def test_handler_max_tokens_is_64(mock_bedrock_client):
    """max_tokens is capped at 64 to minimize token costs."""
    from sandboxes.phase6.handler import handler

    mock_client, _ = mock_bedrock_client
    mock_client.invoke_model.return_value = _make_bedrock_response("Short answer.")

    handler({"prompt": "What is AWS?"}, None)

    call_kwargs = mock_client.invoke_model.call_args
    body = json.loads(call_kwargs.kwargs["body"])
    assert body["max_tokens"] == 64


def test_handler_uses_messages_api_format(mock_bedrock_client):
    """Handler uses Anthropic Messages API format (anthropic_version + messages list)."""
    from sandboxes.phase6.handler import handler

    mock_client, _ = mock_bedrock_client
    mock_client.invoke_model.return_value = _make_bedrock_response("OK.")

    prompt = "Name one benefit of serverless."
    handler({"prompt": prompt}, None)

    call_kwargs = mock_client.invoke_model.call_args
    body = json.loads(call_kwargs.kwargs["body"])
    assert body["anthropic_version"] == "bedrock-2023-05-31"
    assert isinstance(body["messages"], list)
    assert body["messages"][0]["role"] == "user"
    assert body["messages"][0]["content"] == prompt


def test_handler_content_type_is_json(mock_bedrock_client):
    """Handler sets contentType=application/json for the Bedrock API call."""
    from sandboxes.phase6.handler import handler

    mock_client, _ = mock_bedrock_client
    mock_client.invoke_model.return_value = _make_bedrock_response("OK.")

    handler({"prompt": "Hello"}, None)

    call_kwargs = mock_client.invoke_model.call_args
    assert call_kwargs.kwargs["contentType"] == "application/json"
    assert call_kwargs.kwargs["accept"] == "application/json"


def test_handler_creates_bedrock_runtime_client_with_correct_region(mock_bedrock_client):
    """Handler creates a bedrock-runtime client pointing to the REGION env var."""
    from sandboxes.phase6.handler import handler

    mock_client, mock_boto3 = mock_bedrock_client
    mock_client.invoke_model.return_value = _make_bedrock_response("OK.")

    handler({"prompt": "Hello"}, None)

    mock_boto3.assert_called_once_with("bedrock-runtime", region_name=REGION)
