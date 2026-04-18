import os

import boto3
import pytest
from moto import mock_aws

os.environ["AWS_DEFAULT_REGION"] = "ap-northeast-1"
os.environ["AWS_ACCESS_KEY_ID"] = "testing"
os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"
os.environ["AWS_SECURITY_TOKEN"] = "testing"
os.environ["AWS_SESSION_TOKEN"] = "testing"

USERS_TABLE = "test-users"
SUBMISSIONS_TABLE = "test-submissions"
PROBLEMS_TABLE = "test-problems"


@pytest.fixture
def aws_env(monkeypatch):
    monkeypatch.setenv("USERS_TABLE", USERS_TABLE)
    monkeypatch.setenv("SUBMISSIONS_TABLE", SUBMISSIONS_TABLE)
    monkeypatch.setenv("PROBLEMS_TABLE", PROBLEMS_TABLE)


@pytest.fixture
def dynamodb_tables(aws_env):
    with mock_aws():
        client = boto3.client("dynamodb", region_name="ap-northeast-1")

        client.create_table(
            TableName=USERS_TABLE,
            KeySchema=[{"AttributeName": "user_id", "KeyType": "HASH"}],
            AttributeDefinitions=[
                {"AttributeName": "user_id", "AttributeType": "S"}
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        client.create_table(
            TableName=SUBMISSIONS_TABLE,
            KeySchema=[
                {"AttributeName": "user_id", "KeyType": "HASH"},
                {"AttributeName": "submission_id", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "user_id", "AttributeType": "S"},
                {"AttributeName": "submission_id", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        client.create_table(
            TableName=PROBLEMS_TABLE,
            KeySchema=[{"AttributeName": "problem_id", "KeyType": "HASH"}],
            AttributeDefinitions=[
                {"AttributeName": "problem_id", "AttributeType": "S"},
                {"AttributeName": "tag", "AttributeType": "S"},
                {"AttributeName": "difficulty", "AttributeType": "S"},
            ],
            GlobalSecondaryIndexes=[
                {
                    "IndexName": "TagDifficultyIndex",
                    "KeySchema": [
                        {"AttributeName": "tag", "KeyType": "HASH"},
                        {"AttributeName": "difficulty", "KeyType": "RANGE"},
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                }
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        yield client
