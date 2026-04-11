# Phase 1: MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ログインして、AtCoderの提出履歴を取得・保存・一覧表示できるMVPを構築する

**Architecture:** Cognito認証済みユーザーがNext.jsフロントからAPI Gatewayを経由してLambda (Python) を呼び出す。sync_submissions LambdaがAtCoder Problems APIからメタデータを取得しDynamoDBに保存。get_submissions LambdaがDynamoDBからページネーション付きで一覧を返却する。

**Tech Stack:** Terraform, AWS (Cognito, API Gateway, Lambda, DynamoDB, Amplify Hosting), Python 3.12, Next.js 16 (App Router), TypeScript, Tailwind CSS

**Existing infrastructure:** Terraform backend (S3+DynamoDB), Cognito User Pool + Client, API Gateway REST API + Cognito Authorizer + /health endpoint, Next.js with Amplify UI auth flow

---

## File Structure

### Terraform (新規・修正)

| Path | Action | Responsibility |
|---|---|---|
| `terraform/modules/dynamodb/main.tf` | Create | users, submissions, problems テーブル定義 |
| `terraform/modules/dynamodb/variables.tf` | Create | モジュール入力変数 |
| `terraform/modules/dynamodb/outputs.tf` | Create | テーブル名、ARN出力 |
| `terraform/modules/lambda/main.tf` | Create | Lambda関数定義、IAMロール、API Gateway統合 |
| `terraform/modules/lambda/variables.tf` | Create | モジュール入力変数 |
| `terraform/modules/lambda/outputs.tf` | Create | Lambda ARN出力 |
| `terraform/modules/api_gateway/main.tf` | Modify | APIエンドポイント追加 (/users/me, /submissions, /submissions/sync) |
| `terraform/modules/api_gateway/variables.tf` | Modify | Lambda invoke ARN変数追加 |
| `terraform/modules/api_gateway/outputs.tf` | Modify | (変更なし) |
| `terraform/modules.tf` | Modify | dynamodb, lambda モジュール追加 |
| `terraform/outputs.tf` | Modify | DynamoDB テーブル名出力追加 |

### Backend (全て新規)

| Path | Responsibility |
|---|---|
| `backend/shared/__init__.py` | パッケージ初期化 |
| `backend/shared/db.py` | DynamoDB操作 (UserRepository, SubmissionRepository) |
| `backend/shared/atcoder_client.py` | AtCoder Problems API クライアント |
| `backend/shared/response.py` | APIレスポンスヘルパー |
| `backend/lambdas/__init__.py` | パッケージ初期化 |
| `backend/lambdas/save_user/handler.py` | POST /users/me ハンドラー |
| `backend/lambdas/sync_submissions/handler.py` | POST /submissions/sync ハンドラー |
| `backend/lambdas/get_submissions/handler.py` | GET /submissions ハンドラー |
| `backend/requirements.txt` | 本番依存 (boto3, requests) |
| `backend/requirements-dev.txt` | 開発依存 (pytest, moto) |
| `backend/tests/__init__.py` | テストパッケージ初期化 |
| `backend/tests/conftest.py` | pytest共通フィクスチャ |
| `backend/tests/test_db.py` | db.py のテスト |
| `backend/tests/test_atcoder_client.py` | atcoder_client.py のテスト |
| `backend/tests/test_save_user.py` | save_user ハンドラーのテスト |
| `backend/tests/test_sync_submissions.py` | sync_submissions ハンドラーのテスト |
| `backend/tests/test_get_submissions.py` | get_submissions ハンドラーのテスト |

### Frontend (新規・修正)

| Path | Action | Responsibility |
|---|---|---|
| `frontend/app/lib/api.ts` | Create | API Gateway クライアント (JWT付きfetch) |
| `frontend/app/lib/types.ts` | Create | 型定義 (User, Submission, APIレスポンス) |
| `frontend/app/components/Layout.tsx` | Create | 共通レイアウト (ヘッダー、ナビゲーション) |
| `frontend/app/page.tsx` | Modify | Layout使用、ダッシュボード内容 |
| `frontend/app/layout.tsx` | Modify | Layout統合 |
| `frontend/app/settings/page.tsx` | Create | AtCoderユーザー名登録 |
| `frontend/app/submissions/page.tsx` | Create | 提出一覧 + 同期ボタン |
| `frontend/app/submissions/[id]/page.tsx` | Create | 提出詳細 (ソースコード表示) |

---

## Task 1: Terraform — DynamoDB モジュール

**Files:**
- Create: `terraform/modules/dynamodb/main.tf`
- Create: `terraform/modules/dynamodb/variables.tf`
- Create: `terraform/modules/dynamodb/outputs.tf`
- Modify: `terraform/modules.tf`
- Modify: `terraform/outputs.tf`

- [ ] **Step 1: DynamoDB モジュールの variables.tf を作成**

```hcl
# terraform/modules/dynamodb/variables.tf
variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}
```

- [ ] **Step 2: DynamoDB モジュールの main.tf を作成**

```hcl
# terraform/modules/dynamodb/main.tf

# users テーブル
resource "aws_dynamodb_table" "users" {
  name         = "${var.project_name}-users-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"

  attribute {
    name = "user_id"
    type = "S"
  }
}

# submissions テーブル
resource "aws_dynamodb_table" "submissions" {
  name         = "${var.project_name}-submissions-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "submission_id"

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "submission_id"
    type = "S"
  }
}

# problems テーブル
resource "aws_dynamodb_table" "problems" {
  name         = "${var.project_name}-problems-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "problem_id"

  attribute {
    name = "problem_id"
    type = "S"
  }

  attribute {
    name = "tag"
    type = "S"
  }

  attribute {
    name = "difficulty"
    type = "S"
  }

  global_secondary_index {
    name            = "TagDifficultyIndex"
    hash_key        = "tag"
    range_key       = "difficulty"
    projection_type = "ALL"
  }
}
```

- [ ] **Step 3: DynamoDB モジュールの outputs.tf を作成**

```hcl
# terraform/modules/dynamodb/outputs.tf
output "users_table_name" {
  value = aws_dynamodb_table.users.name
}

output "users_table_arn" {
  value = aws_dynamodb_table.users.arn
}

output "submissions_table_name" {
  value = aws_dynamodb_table.submissions.name
}

output "submissions_table_arn" {
  value = aws_dynamodb_table.submissions.arn
}

output "problems_table_name" {
  value = aws_dynamodb_table.problems.name
}

output "problems_table_arn" {
  value = aws_dynamodb_table.problems.arn
}
```

- [ ] **Step 4: modules.tf に dynamodb モジュールを追加**

`terraform/modules.tf` の末尾に追加:

```hcl
module "dynamodb" {
  source = "./modules/dynamodb"

  project_name = var.project_name
  environment  = var.environment
}
```

- [ ] **Step 5: outputs.tf に DynamoDB テーブル名を追加**

`terraform/outputs.tf` の末尾に追加:

```hcl
output "dynamodb_users_table_name" {
  description = "DynamoDB users table name"
  value       = module.dynamodb.users_table_name
}

output "dynamodb_submissions_table_name" {
  description = "DynamoDB submissions table name"
  value       = module.dynamodb.submissions_table_name
}

output "dynamodb_problems_table_name" {
  description = "DynamoDB problems table name"
  value       = module.dynamodb.problems_table_name
}
```

- [ ] **Step 6: terraform validate で構文チェック**

Run: `cd terraform && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 7: コミット**

```bash
git add terraform/modules/dynamodb/ terraform/modules.tf terraform/outputs.tf
git commit -m "feat(terraform): add DynamoDB module with users, submissions, problems tables"
```

---

## Task 2: Backend — Python 環境セットアップ

**Files:**
- Create: `backend/requirements.txt`
- Create: `backend/requirements-dev.txt`
- Create: `backend/shared/__init__.py`
- Create: `backend/lambdas/__init__.py`
- Create: `backend/tests/__init__.py`
- Create: `backend/tests/conftest.py`

- [ ] **Step 1: requirements.txt を作成**

```text
boto3>=1.35.0
requests>=2.32.0
```

- [ ] **Step 2: requirements-dev.txt を作成**

```text
-r requirements.txt
pytest>=8.0.0
moto[dynamodb]>=5.0.0
requests-mock>=1.12.0
```

- [ ] **Step 3: パッケージ __init__.py を作成**

```bash
touch backend/shared/__init__.py
touch backend/lambdas/__init__.py
touch backend/tests/__init__.py
```

- [ ] **Step 4: conftest.py を作成（moto DynamoDB フィクスチャ）**

```python
# backend/tests/conftest.py
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
```

- [ ] **Step 5: venv を作成して依存をインストール**

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
```

- [ ] **Step 6: pytest が起動することを確認**

Run: `cd backend && source .venv/bin/activate && python -m pytest tests/ -v --co`
Expected: `no tests ran` (テストファイルが空のため正常)

- [ ] **Step 7: コミット**

```bash
git add backend/requirements.txt backend/requirements-dev.txt \
  backend/shared/__init__.py backend/lambdas/__init__.py \
  backend/tests/__init__.py backend/tests/conftest.py
git commit -m "feat(backend): set up Python environment with pytest and moto fixtures"
```

---

## Task 3: Backend — shared/response.py (APIレスポンスヘルパー)

**Files:**
- Create: `backend/shared/response.py`

- [ ] **Step 1: response.py を作成**

APIレスポンスを統一形式 `{ data, meta }` で返すヘルパー。

```python
# backend/shared/response.py
import json
from typing import Any


def success(data: Any, meta: dict | None = None, status_code: int = 200) -> dict:
    body: dict[str, Any] = {"data": data}
    if meta:
        body["meta"] = meta
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
            "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
        },
        "body": json.dumps(body, default=str),
    }


def error(code: str, message: str, status_code: int = 400) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
            "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
        },
        "body": json.dumps({"error": {"code": code, "message": message}}),
    }
```

- [ ] **Step 2: コミット**

```bash
git add backend/shared/response.py
git commit -m "feat(backend): add unified API response helpers"
```

---

## Task 4: Backend — shared/db.py (DynamoDB操作)

**Files:**
- Create: `backend/shared/db.py`
- Create: `backend/tests/test_db.py`

- [ ] **Step 1: テストを先に書く**

```python
# backend/tests/test_db.py
import json
from shared.db import UserRepository, SubmissionRepository


class TestUserRepository:
    def test_save_and_get_user(self, dynamodb_tables):
        repo = UserRepository()
        repo.save_user("user-123", "chokudai")

        user = repo.get_user("user-123")
        assert user is not None
        assert user["atcoder_username"] == "chokudai"
        assert user["user_id"] == "user-123"
        assert "created_at" in user
        assert "updated_at" in user

    def test_get_user_not_found(self, dynamodb_tables):
        repo = UserRepository()
        user = repo.get_user("nonexistent")
        assert user is None

    def test_save_user_updates_existing(self, dynamodb_tables):
        repo = UserRepository()
        repo.save_user("user-123", "chokudai")
        repo.save_user("user-123", "tourist")

        user = repo.get_user("user-123")
        assert user["atcoder_username"] == "tourist"


class TestSubmissionRepository:
    def test_save_and_get_submissions(self, dynamodb_tables):
        repo = SubmissionRepository()
        submissions = [
            {
                "id": 12345,
                "problem_id": "abc300_a",
                "contest_id": "abc300",
                "language": "Python (CPython 3.11.4)",
                "result": "AC",
                "point": 100.0,
                "length": 150,
                "execution_time": 30,
                "epoch_second": 1700000000,
            },
            {
                "id": 12346,
                "problem_id": "abc300_b",
                "contest_id": "abc300",
                "language": "Python (CPython 3.11.4)",
                "result": "WA",
                "point": 0.0,
                "length": 200,
                "execution_time": 50,
                "epoch_second": 1700000060,
            },
        ]
        repo.save_submissions("user-123", submissions)

        result = repo.get_submissions("user-123", limit=10)
        assert len(result["items"]) == 2
        assert result["next_token"] is None

    def test_get_submissions_pagination(self, dynamodb_tables):
        repo = SubmissionRepository()
        submissions = [
            {
                "id": i,
                "problem_id": f"abc300_{chr(97 + i)}",
                "contest_id": "abc300",
                "language": "Python",
                "result": "AC",
                "point": 100.0,
                "length": 100,
                "execution_time": 30,
                "epoch_second": 1700000000 + i,
            }
            for i in range(5)
        ]
        repo.save_submissions("user-123", submissions)

        page1 = repo.get_submissions("user-123", limit=2)
        assert len(page1["items"]) == 2
        assert page1["next_token"] is not None

        page2 = repo.get_submissions(
            "user-123", limit=2, next_token=page1["next_token"]
        )
        assert len(page2["items"]) == 2
        assert page2["next_token"] is not None

        page3 = repo.get_submissions(
            "user-123", limit=2, next_token=page2["next_token"]
        )
        assert len(page3["items"]) == 1
        assert page3["next_token"] is None

    def test_get_submissions_empty(self, dynamodb_tables):
        repo = SubmissionRepository()
        result = repo.get_submissions("user-123", limit=10)
        assert len(result["items"]) == 0
        assert result["next_token"] is None

    def test_get_submission_by_id(self, dynamodb_tables):
        repo = SubmissionRepository()
        submissions = [
            {
                "id": 99999,
                "problem_id": "abc300_a",
                "contest_id": "abc300",
                "language": "Python",
                "result": "AC",
                "point": 100.0,
                "length": 150,
                "execution_time": 30,
                "epoch_second": 1700000000,
            }
        ]
        repo.save_submissions("user-123", submissions)

        item = repo.get_submission("user-123", "SUB#99999")
        assert item is not None
        assert item["problem_id"] == "abc300_a"

    def test_get_submission_not_found(self, dynamodb_tables):
        repo = SubmissionRepository()
        item = repo.get_submission("user-123", "SUB#99999")
        assert item is None
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `cd backend && source .venv/bin/activate && python -m pytest tests/test_db.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'shared.db'`

- [ ] **Step 3: shared/db.py を実装**

```python
# backend/shared/db.py
import os
import json
import base64
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.types import TypeDeserializer

_deserializer = TypeDeserializer()


def _get_table(table_env_var: str):
    table_name = os.environ[table_env_var]
    dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_DEFAULT_REGION", "ap-northeast-1"))
    return dynamodb.Table(table_name)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class UserRepository:
    def __init__(self):
        self._table = _get_table("USERS_TABLE")

    def save_user(self, user_id: str, atcoder_username: str) -> dict:
        now = _now_iso()
        item = {
            "user_id": user_id,
            "atcoder_username": atcoder_username,
            "updated_at": now,
        }
        # created_at は初回のみ設定
        self._table.update_item(
            Key={"user_id": user_id},
            UpdateExpression=(
                "SET atcoder_username = :username, updated_at = :now"
                ", created_at = if_not_exists(created_at, :now)"
            ),
            ExpressionAttributeValues={
                ":username": atcoder_username,
                ":now": now,
            },
        )
        return self.get_user(user_id)

    def get_user(self, user_id: str) -> dict | None:
        resp = self._table.get_item(Key={"user_id": user_id})
        return resp.get("Item")

    def update_last_sync(self, user_id: str, epoch_second: int):
        self._table.update_item(
            Key={"user_id": user_id},
            UpdateExpression="SET last_sync_epoch = :epoch, updated_at = :now",
            ExpressionAttributeValues={
                ":epoch": epoch_second,
                ":now": _now_iso(),
            },
        )


class SubmissionRepository:
    def __init__(self):
        self._table = _get_table("SUBMISSIONS_TABLE")

    def save_submissions(self, user_id: str, submissions: list[dict]):
        with self._table.batch_writer() as batch:
            for sub in submissions:
                batch.put_item(
                    Item={
                        "user_id": user_id,
                        "submission_id": f"SUB#{sub['id']}",
                        "problem_id": sub["problem_id"],
                        "contest_id": sub["contest_id"],
                        "language": sub.get("language", ""),
                        "result": sub["result"],
                        "score": str(sub.get("point", 0)),
                        "code_length": sub.get("length", 0),
                        "execution_time": sub.get("execution_time", 0),
                        "submitted_at": sub.get("epoch_second", 0),
                    }
                )

    def get_submissions(
        self, user_id: str, limit: int = 50, next_token: str | None = None
    ) -> dict:
        kwargs = {
            "KeyConditionExpression": boto3.dynamodb.conditions.Key("user_id").eq(user_id),
            "Limit": limit,
            "ScanIndexForward": False,
        }
        if next_token:
            kwargs["ExclusiveStartKey"] = json.loads(
                base64.b64decode(next_token).decode()
            )

        resp = self._table.query(**kwargs)

        encoded_token = None
        if "LastEvaluatedKey" in resp:
            encoded_token = base64.b64encode(
                json.dumps(resp["LastEvaluatedKey"], default=str).encode()
            ).decode()

        return {
            "items": resp["Items"],
            "next_token": encoded_token,
        }

    def get_submission(self, user_id: str, submission_id: str) -> dict | None:
        resp = self._table.get_item(
            Key={"user_id": user_id, "submission_id": submission_id}
        )
        return resp.get("Item")
```

- [ ] **Step 4: テストが通ることを確認**

Run: `cd backend && source .venv/bin/activate && python -m pytest tests/test_db.py -v`
Expected: All 7 tests PASS

- [ ] **Step 5: コミット**

```bash
git add backend/shared/db.py backend/tests/test_db.py
git commit -m "feat(backend): add UserRepository and SubmissionRepository with DynamoDB"
```

---

## Task 5: Backend — shared/atcoder_client.py (AtCoder APIクライアント)

**Files:**
- Create: `backend/shared/atcoder_client.py`
- Create: `backend/tests/test_atcoder_client.py`

- [ ] **Step 1: テストを先に書く**

```python
# backend/tests/test_atcoder_client.py
import requests_mock

from shared.atcoder_client import AtCoderClient


class TestAtCoderClient:
    def test_get_submissions_returns_list(self):
        client = AtCoderClient()
        mock_data = [
            {
                "id": 12345,
                "epoch_second": 1700000000,
                "problem_id": "abc300_a",
                "contest_id": "abc300",
                "user_id": "testuser",
                "language": "Python (CPython 3.11.4)",
                "point": 100.0,
                "length": 150,
                "result": "AC",
                "execution_time": 30,
            },
            {
                "id": 12346,
                "epoch_second": 1700000060,
                "problem_id": "abc300_b",
                "contest_id": "abc300",
                "user_id": "testuser",
                "language": "Python (CPython 3.11.4)",
                "point": 200.0,
                "length": 200,
                "result": "WA",
                "execution_time": 50,
            },
        ]

        with requests_mock.Mocker() as m:
            m.get(
                "https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions",
                json=mock_data,
            )
            result = client.get_submissions("testuser", from_second=0)

        assert len(result) == 2
        assert result[0]["id"] == 12345
        assert result[1]["result"] == "WA"

    def test_get_submissions_with_from_second(self):
        client = AtCoderClient()

        with requests_mock.Mocker() as m:
            m.get(
                "https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions",
                json=[],
            )
            result = client.get_submissions("testuser", from_second=1700000000)

        assert result == []
        assert "from_second=1700000000" in m.last_request.url

    def test_get_submissions_empty(self):
        client = AtCoderClient()

        with requests_mock.Mocker() as m:
            m.get(
                "https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions",
                json=[],
            )
            result = client.get_submissions("testuser")

        assert result == []

    def test_get_submissions_api_error_raises(self):
        client = AtCoderClient()

        with requests_mock.Mocker() as m:
            m.get(
                "https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions",
                status_code=500,
            )
            try:
                client.get_submissions("testuser")
                assert False, "Should have raised"
            except Exception:
                pass
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `cd backend && source .venv/bin/activate && python -m pytest tests/test_atcoder_client.py -v`
Expected: FAIL — `ModuleNotFoundError`

- [ ] **Step 3: atcoder_client.py を実装**

```python
# backend/shared/atcoder_client.py
import requests

ATCODER_PROBLEMS_API = "https://kenkoooo.com/atcoder/atcoder-api/v3"


class AtCoderClient:
    def __init__(self, timeout: int = 30):
        self._timeout = timeout

    def get_submissions(
        self, username: str, from_second: int = 0
    ) -> list[dict]:
        """AtCoder Problems API から提出メタデータを取得する。

        Args:
            username: AtCoderユーザー名
            from_second: この Unix epoch 以降の提出のみ取得

        Returns:
            提出メタデータのリスト
        """
        url = f"{ATCODER_PROBLEMS_API}/user/submissions"
        params = {"user": username, "from_second": from_second}

        resp = requests.get(url, params=params, timeout=self._timeout)
        resp.raise_for_status()
        return resp.json()
```

- [ ] **Step 4: テストが通ることを確認**

Run: `cd backend && source .venv/bin/activate && python -m pytest tests/test_atcoder_client.py -v`
Expected: All 4 tests PASS

- [ ] **Step 5: コミット**

```bash
git add backend/shared/atcoder_client.py backend/tests/test_atcoder_client.py
git commit -m "feat(backend): add AtCoder Problems API client"
```

---

## Task 6: Backend — Lambda: save_user ハンドラー

**Files:**
- Create: `backend/lambdas/save_user/handler.py`
- Create: `backend/tests/test_save_user.py`

- [ ] **Step 1: テストを先に書く**

```python
# backend/tests/test_save_user.py
import json

from lambdas.save_user.handler import handler


class TestSaveUser:
    def _make_event(self, user_id: str, body: dict) -> dict:
        return {
            "requestContext": {
                "authorizer": {"claims": {"sub": user_id}}
            },
            "body": json.dumps(body),
        }

    def test_save_user_success(self, dynamodb_tables):
        event = self._make_event("user-123", {"atcoder_username": "chokudai"})
        result = handler(event, None)

        assert result["statusCode"] == 200
        body = json.loads(result["body"])
        assert body["data"]["atcoder_username"] == "chokudai"
        assert body["data"]["user_id"] == "user-123"

    def test_save_user_missing_username(self, dynamodb_tables):
        event = self._make_event("user-123", {})
        result = handler(event, None)

        assert result["statusCode"] == 400
        body = json.loads(result["body"])
        assert body["error"]["code"] == "MISSING_FIELD"

    def test_save_user_empty_username(self, dynamodb_tables):
        event = self._make_event("user-123", {"atcoder_username": ""})
        result = handler(event, None)

        assert result["statusCode"] == 400

    def test_save_user_updates_existing(self, dynamodb_tables):
        event1 = self._make_event("user-123", {"atcoder_username": "chokudai"})
        handler(event1, None)

        event2 = self._make_event("user-123", {"atcoder_username": "tourist"})
        result = handler(event2, None)

        body = json.loads(result["body"])
        assert body["data"]["atcoder_username"] == "tourist"
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `cd backend && source .venv/bin/activate && python -m pytest tests/test_save_user.py -v`
Expected: FAIL

- [ ] **Step 3: handler を実装**

```python
# backend/lambdas/save_user/handler.py
import json

from shared.db import UserRepository
from shared.response import success, error


def handler(event, context):
    user_id = event["requestContext"]["authorizer"]["claims"]["sub"]

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return error("INVALID_JSON", "リクエストボディが不正です")

    atcoder_username = body.get("atcoder_username", "").strip()
    if not atcoder_username:
        return error("MISSING_FIELD", "atcoder_username は必須です")

    repo = UserRepository()
    user = repo.save_user(user_id, atcoder_username)
    return success(user)
```

- [ ] **Step 4: テストが通ることを確認**

Run: `cd backend && source .venv/bin/activate && python -m pytest tests/test_save_user.py -v`
Expected: All 4 tests PASS

- [ ] **Step 5: コミット**

```bash
git add backend/lambdas/save_user/handler.py backend/tests/test_save_user.py
git commit -m "feat(backend): add save_user Lambda handler"
```

---

## Task 7: Backend — Lambda: sync_submissions ハンドラー

**Files:**
- Create: `backend/lambdas/sync_submissions/handler.py`
- Create: `backend/tests/test_sync_submissions.py`

- [ ] **Step 1: テストを先に書く**

```python
# backend/tests/test_sync_submissions.py
import json
import requests_mock

from lambdas.sync_submissions.handler import handler
from shared.db import UserRepository


MOCK_SUBMISSIONS = [
    {
        "id": 12345,
        "epoch_second": 1700000000,
        "problem_id": "abc300_a",
        "contest_id": "abc300",
        "user_id": "testuser",
        "language": "Python (CPython 3.11.4)",
        "point": 100.0,
        "length": 150,
        "result": "AC",
        "execution_time": 30,
    },
    {
        "id": 12346,
        "epoch_second": 1700000060,
        "problem_id": "abc300_b",
        "contest_id": "abc300",
        "user_id": "testuser",
        "language": "Python (CPython 3.11.4)",
        "point": 200.0,
        "length": 200,
        "result": "WA",
        "execution_time": 50,
    },
]


def _make_event(user_id: str) -> dict:
    return {
        "requestContext": {
            "authorizer": {"claims": {"sub": user_id}}
        },
        "body": None,
    }


class TestSyncSubmissions:
    def test_sync_success(self, dynamodb_tables):
        # ユーザーを先に作成
        repo = UserRepository()
        repo.save_user("user-123", "testuser")

        with requests_mock.Mocker() as m:
            m.get(
                "https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions",
                json=MOCK_SUBMISSIONS,
            )
            result = handler(_make_event("user-123"), None)

        assert result["statusCode"] == 200
        body = json.loads(result["body"])
        assert body["data"]["synced_count"] == 2

    def test_sync_user_not_found(self, dynamodb_tables):
        result = handler(_make_event("user-123"), None)

        assert result["statusCode"] == 400
        body = json.loads(result["body"])
        assert body["error"]["code"] == "USER_NOT_CONFIGURED"

    def test_sync_incremental(self, dynamodb_tables):
        repo = UserRepository()
        repo.save_user("user-123", "testuser")
        # last_sync_epoch を設定
        repo.update_last_sync("user-123", 1700000050)

        with requests_mock.Mocker() as m:
            m.get(
                "https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions",
                json=[MOCK_SUBMISSIONS[1]],  # 2件目のみ返る
            )
            result = handler(_make_event("user-123"), None)

        body = json.loads(result["body"])
        assert body["data"]["synced_count"] == 1
        # from_second パラメータが送られていることを確認
        assert "from_second=1700000050" in m.last_request.url
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `cd backend && source .venv/bin/activate && python -m pytest tests/test_sync_submissions.py -v`
Expected: FAIL

- [ ] **Step 3: handler を実装**

```python
# backend/lambdas/sync_submissions/handler.py
from shared.db import UserRepository, SubmissionRepository
from shared.atcoder_client import AtCoderClient
from shared.response import success, error


def handler(event, context):
    user_id = event["requestContext"]["authorizer"]["claims"]["sub"]

    user_repo = UserRepository()
    user = user_repo.get_user(user_id)

    if not user or not user.get("atcoder_username"):
        return error(
            "USER_NOT_CONFIGURED",
            "先に /users/me でAtCoderユーザー名を登録してください",
        )

    atcoder_username = user["atcoder_username"]
    from_second = int(user.get("last_sync_epoch", 0))

    client = AtCoderClient()
    submissions = client.get_submissions(atcoder_username, from_second=from_second)

    if submissions:
        sub_repo = SubmissionRepository()
        sub_repo.save_submissions(user_id, submissions)

        # 最新の提出時刻で last_sync_epoch を更新
        max_epoch = max(s["epoch_second"] for s in submissions)
        user_repo.update_last_sync(user_id, max_epoch)

    return success({
        "synced_count": len(submissions),
        "from_second": from_second,
    })
```

- [ ] **Step 4: テストが通ることを確認**

Run: `cd backend && source .venv/bin/activate && python -m pytest tests/test_sync_submissions.py -v`
Expected: All 3 tests PASS

- [ ] **Step 5: コミット**

```bash
git add backend/lambdas/sync_submissions/handler.py backend/tests/test_sync_submissions.py
git commit -m "feat(backend): add sync_submissions Lambda handler with incremental sync"
```

---

## Task 8: Backend — Lambda: get_submissions ハンドラー

**Files:**
- Create: `backend/lambdas/get_submissions/handler.py`
- Create: `backend/tests/test_get_submissions.py`

- [ ] **Step 1: テストを先に書く**

```python
# backend/tests/test_get_submissions.py
import json

from lambdas.get_submissions.handler import handler
from shared.db import SubmissionRepository


SAMPLE_SUBMISSIONS = [
    {
        "id": i,
        "problem_id": f"abc300_{chr(97 + i)}",
        "contest_id": "abc300",
        "language": "Python",
        "result": "AC",
        "point": 100.0,
        "length": 100,
        "execution_time": 30,
        "epoch_second": 1700000000 + i,
    }
    for i in range(5)
]


def _make_event(
    user_id: str,
    query_params: dict | None = None,
    path_params: dict | None = None,
) -> dict:
    return {
        "requestContext": {
            "authorizer": {"claims": {"sub": user_id}}
        },
        "queryStringParameters": query_params,
        "pathParameters": path_params,
    }


class TestGetSubmissions:
    def test_get_submissions_list(self, dynamodb_tables):
        repo = SubmissionRepository()
        repo.save_submissions("user-123", SAMPLE_SUBMISSIONS)

        result = handler(_make_event("user-123"), None)

        assert result["statusCode"] == 200
        body = json.loads(result["body"])
        assert len(body["data"]) == 5
        assert body["meta"]["nextToken"] is None

    def test_get_submissions_with_limit(self, dynamodb_tables):
        repo = SubmissionRepository()
        repo.save_submissions("user-123", SAMPLE_SUBMISSIONS)

        result = handler(
            _make_event("user-123", query_params={"limit": "2"}), None
        )

        body = json.loads(result["body"])
        assert len(body["data"]) == 2
        assert body["meta"]["nextToken"] is not None

    def test_get_submissions_pagination(self, dynamodb_tables):
        repo = SubmissionRepository()
        repo.save_submissions("user-123", SAMPLE_SUBMISSIONS)

        # Page 1
        result1 = handler(
            _make_event("user-123", query_params={"limit": "3"}), None
        )
        body1 = json.loads(result1["body"])
        token = body1["meta"]["nextToken"]

        # Page 2
        result2 = handler(
            _make_event(
                "user-123", query_params={"limit": "3", "nextToken": token}
            ),
            None,
        )
        body2 = json.loads(result2["body"])
        assert len(body2["data"]) == 2
        assert body2["meta"]["nextToken"] is None

    def test_get_submissions_empty(self, dynamodb_tables):
        result = handler(_make_event("user-123"), None)

        body = json.loads(result["body"])
        assert body["data"] == []

    def test_get_single_submission(self, dynamodb_tables):
        repo = SubmissionRepository()
        repo.save_submissions("user-123", [SAMPLE_SUBMISSIONS[0]])

        result = handler(
            _make_event(
                "user-123",
                path_params={"submission_id": "SUB#0"},
            ),
            None,
        )

        assert result["statusCode"] == 200
        body = json.loads(result["body"])
        assert body["data"]["problem_id"] == "abc300_a"

    def test_get_single_submission_not_found(self, dynamodb_tables):
        result = handler(
            _make_event(
                "user-123",
                path_params={"submission_id": "SUB#99999"},
            ),
            None,
        )

        assert result["statusCode"] == 404
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `cd backend && source .venv/bin/activate && python -m pytest tests/test_get_submissions.py -v`
Expected: FAIL

- [ ] **Step 3: handler を実装**

```python
# backend/lambdas/get_submissions/handler.py
from shared.db import SubmissionRepository
from shared.response import success, error


def handler(event, context):
    user_id = event["requestContext"]["authorizer"]["claims"]["sub"]
    repo = SubmissionRepository()

    # 個別取得: pathParameters に submission_id がある場合
    path_params = event.get("pathParameters") or {}
    if "submission_id" in path_params:
        submission_id = path_params["submission_id"]
        item = repo.get_submission(user_id, submission_id)
        if item is None:
            return error("NOT_FOUND", "提出が見つかりません", status_code=404)
        return success(item)

    # 一覧取得
    query_params = event.get("queryStringParameters") or {}
    limit = int(query_params.get("limit", "50"))
    next_token = query_params.get("nextToken")

    result = repo.get_submissions(user_id, limit=limit, next_token=next_token)

    return success(
        result["items"],
        meta={"nextToken": result["next_token"]},
    )
```

- [ ] **Step 4: テストが通ることを確認**

Run: `cd backend && source .venv/bin/activate && python -m pytest tests/test_get_submissions.py -v`
Expected: All 6 tests PASS

- [ ] **Step 5: 全テストをまとめて実行**

Run: `cd backend && source .venv/bin/activate && python -m pytest tests/ -v`
Expected: All 20 tests PASS

- [ ] **Step 6: コミット**

```bash
git add backend/lambdas/get_submissions/handler.py backend/tests/test_get_submissions.py
git commit -m "feat(backend): add get_submissions Lambda handler with pagination"
```

---

## Task 9: Terraform — Lambda モジュール

**Files:**
- Create: `terraform/modules/lambda/main.tf`
- Create: `terraform/modules/lambda/variables.tf`
- Create: `terraform/modules/lambda/outputs.tf`
- Modify: `terraform/modules.tf`

- [ ] **Step 1: Lambda モジュール variables.tf を作成**

```hcl
# terraform/modules/lambda/variables.tf
variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "users_table_name" {
  description = "DynamoDB users table name"
  type        = string
}

variable "users_table_arn" {
  description = "DynamoDB users table ARN"
  type        = string
}

variable "submissions_table_name" {
  description = "DynamoDB submissions table name"
  type        = string
}

variable "submissions_table_arn" {
  description = "DynamoDB submissions table ARN"
  type        = string
}

variable "problems_table_name" {
  description = "DynamoDB problems table name"
  type        = string
}

variable "problems_table_arn" {
  description = "DynamoDB problems table ARN"
  type        = string
}

variable "api_gateway_execution_arn" {
  description = "API Gateway execution ARN for Lambda permissions"
  type        = string
}
```

- [ ] **Step 2: Lambda モジュール main.tf を作成**

```hcl
# terraform/modules/lambda/main.tf

# =============================================
# IAM Roles
# =============================================

# sync 用 IAM ロール (DynamoDB読み書き)
resource "aws_iam_role" "lambda_sync" {
  name = "${var.project_name}-lambda-sync-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_sync_dynamodb" {
  name = "dynamodb-access"
  role = aws_iam_role.lambda_sync.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:Query",
        "dynamodb:BatchWriteItem",
      ]
      Resource = [
        var.users_table_arn,
        var.submissions_table_arn,
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_sync_logs" {
  role       = aws_iam_role.lambda_sync.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# get 用 IAM ロール (DynamoDB読み取りのみ)
resource "aws_iam_role" "lambda_get" {
  name = "${var.project_name}-lambda-get-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_get_dynamodb" {
  name = "dynamodb-read"
  role = aws_iam_role.lambda_get.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:Query",
      ]
      Resource = [
        var.users_table_arn,
        var.submissions_table_arn,
        var.problems_table_arn,
        "${var.problems_table_arn}/index/*",
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_get_logs" {
  role       = aws_iam_role.lambda_get.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# save_user 用 IAM ロール (users テーブルのみ)
resource "aws_iam_role" "lambda_save_user" {
  name = "${var.project_name}-lambda-save-user-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_save_user_dynamodb" {
  name = "dynamodb-users"
  role = aws_iam_role.lambda_save_user.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
      ]
      Resource = [var.users_table_arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_save_user_logs" {
  role       = aws_iam_role.lambda_save_user.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# =============================================
# Lambda Functions
# =============================================

# デプロイ用のダミー zip (初回用、後で CI/CD が上書き)
data "archive_file" "dummy" {
  type        = "zip"
  output_path = "${path.module}/dummy.zip"

  source {
    content  = "def handler(event, context): return {'statusCode': 200}"
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "save_user" {
  function_name = "${var.project_name}-save-user-${var.environment}"
  role          = aws_iam_role.lambda_save_user.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 128
  filename      = data.archive_file.dummy.output_path

  environment {
    variables = {
      USERS_TABLE       = var.users_table_name
      SUBMISSIONS_TABLE = var.submissions_table_name
      PROBLEMS_TABLE    = var.problems_table_name
    }
  }

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

resource "aws_lambda_function" "sync_submissions" {
  function_name = "${var.project_name}-sync-submissions-${var.environment}"
  role          = aws_iam_role.lambda_sync.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 300
  memory_size   = 256
  filename      = data.archive_file.dummy.output_path

  environment {
    variables = {
      USERS_TABLE       = var.users_table_name
      SUBMISSIONS_TABLE = var.submissions_table_name
      PROBLEMS_TABLE    = var.problems_table_name
    }
  }

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

resource "aws_lambda_function" "get_submissions" {
  function_name = "${var.project_name}-get-submissions-${var.environment}"
  role          = aws_iam_role.lambda_get.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 128
  filename      = data.archive_file.dummy.output_path

  environment {
    variables = {
      USERS_TABLE       = var.users_table_name
      SUBMISSIONS_TABLE = var.submissions_table_name
      PROBLEMS_TABLE    = var.problems_table_name
    }
  }

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

# =============================================
# API Gateway Lambda Permissions
# =============================================

resource "aws_lambda_permission" "save_user" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.save_user.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${var.api_gateway_execution_arn}/*/*"
}

resource "aws_lambda_permission" "sync_submissions" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sync_submissions.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${var.api_gateway_execution_arn}/*/*"
}

resource "aws_lambda_permission" "get_submissions" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_submissions.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${var.api_gateway_execution_arn}/*/*"
}
```

- [ ] **Step 3: Lambda モジュール outputs.tf を作成**

```hcl
# terraform/modules/lambda/outputs.tf
output "save_user_invoke_arn" {
  value = aws_lambda_function.save_user.invoke_arn
}

output "sync_submissions_invoke_arn" {
  value = aws_lambda_function.sync_submissions.invoke_arn
}

output "get_submissions_invoke_arn" {
  value = aws_lambda_function.get_submissions.invoke_arn
}
```

- [ ] **Step 4: modules.tf に lambda モジュールを追加**

`terraform/modules.tf` の末尾に追加:

```hcl
module "lambda" {
  source = "./modules/lambda"

  project_name = var.project_name
  environment  = var.environment

  users_table_name       = module.dynamodb.users_table_name
  users_table_arn        = module.dynamodb.users_table_arn
  submissions_table_name = module.dynamodb.submissions_table_name
  submissions_table_arn  = module.dynamodb.submissions_table_arn
  problems_table_name    = module.dynamodb.problems_table_name
  problems_table_arn     = module.dynamodb.problems_table_arn

  api_gateway_execution_arn = module.api_gateway.rest_api_execution_arn
}
```

- [ ] **Step 5: api_gateway outputs.tf に execution_arn を追加**

`terraform/modules/api_gateway/outputs.tf` に追加:

```hcl
output "rest_api_execution_arn" {
  description = "REST API execution ARN"
  value       = aws_api_gateway_rest_api.main.execution_arn
}
```

- [ ] **Step 6: terraform validate で構文チェック**

Run: `cd terraform && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 7: コミット**

```bash
git add terraform/modules/lambda/ terraform/modules.tf terraform/modules/api_gateway/outputs.tf
git commit -m "feat(terraform): add Lambda module with IAM roles per function"
```

---

## Task 10: Terraform — API Gateway エンドポイント追加

**Files:**
- Modify: `terraform/modules/api_gateway/main.tf`
- Modify: `terraform/modules/api_gateway/variables.tf`

- [ ] **Step 1: api_gateway variables.tf に Lambda invoke ARN を追加**

`terraform/modules/api_gateway/variables.tf` に追加:

```hcl
variable "save_user_invoke_arn" {
  description = "Lambda invoke ARN for save_user"
  type        = string
  default     = ""
}

variable "sync_submissions_invoke_arn" {
  description = "Lambda invoke ARN for sync_submissions"
  type        = string
  default     = ""
}

variable "get_submissions_invoke_arn" {
  description = "Lambda invoke ARN for get_submissions"
  type        = string
  default     = ""
}
```

- [ ] **Step 2: modules.tf の api_gateway モジュールに Lambda ARN を渡す**

`terraform/modules.tf` の `module "api_gateway"` を更新:

```hcl
module "api_gateway" {
  source = "./modules/api_gateway"

  project_name          = var.project_name
  environment           = var.environment
  cognito_user_pool_arn = module.cognito.user_pool_arn

  save_user_invoke_arn        = module.lambda.save_user_invoke_arn
  sync_submissions_invoke_arn = module.lambda.sync_submissions_invoke_arn
  get_submissions_invoke_arn  = module.lambda.get_submissions_invoke_arn
}
```

- [ ] **Step 3: api_gateway main.tf に API エンドポイントを追加**

`terraform/modules/api_gateway/main.tf` のデプロイメント定義の前に追加:

```hcl
# ========================================
# /users/me — POST (save_user)
# ========================================

resource "aws_api_gateway_resource" "users" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "users"
}

resource "aws_api_gateway_resource" "users_me" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "me"
}

resource "aws_api_gateway_method" "users_me_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_me.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "users_me_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.users_me.id
  http_method             = aws_api_gateway_method.users_me_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.save_user_invoke_arn
}

# CORS OPTIONS for /users/me
resource "aws_api_gateway_method" "users_me_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users_me.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "users_me_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_me.id
  http_method = aws_api_gateway_method.users_me_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "users_me_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_me.id
  http_method = aws_api_gateway_method.users_me_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "users_me_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.users_me.id
  http_method = aws_api_gateway_method.users_me_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

# ========================================
# /submissions — GET (get_submissions)
# ========================================

resource "aws_api_gateway_resource" "submissions" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "submissions"
}

resource "aws_api_gateway_method" "submissions_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.submissions.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "submissions_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.submissions.id
  http_method             = aws_api_gateway_method.submissions_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.get_submissions_invoke_arn
}

# CORS OPTIONS for /submissions
resource "aws_api_gateway_method" "submissions_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.submissions.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "submissions_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.submissions.id
  http_method = aws_api_gateway_method.submissions_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "submissions_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.submissions.id
  http_method = aws_api_gateway_method.submissions_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "submissions_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.submissions.id
  http_method = aws_api_gateway_method.submissions_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

# ========================================
# /submissions/sync — POST (sync_submissions)
# ========================================

resource "aws_api_gateway_resource" "submissions_sync" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.submissions.id
  path_part   = "sync"
}

resource "aws_api_gateway_method" "submissions_sync_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.submissions_sync.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "submissions_sync_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.submissions_sync.id
  http_method             = aws_api_gateway_method.submissions_sync_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.sync_submissions_invoke_arn
}

# CORS OPTIONS for /submissions/sync
resource "aws_api_gateway_method" "submissions_sync_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.submissions_sync.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "submissions_sync_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.submissions_sync.id
  http_method = aws_api_gateway_method.submissions_sync_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "submissions_sync_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.submissions_sync.id
  http_method = aws_api_gateway_method.submissions_sync_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "submissions_sync_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.submissions_sync.id
  http_method = aws_api_gateway_method.submissions_sync_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

# ========================================
# /submissions/{submission_id} — GET (get single submission)
# ========================================

resource "aws_api_gateway_resource" "submission_by_id" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.submissions.id
  path_part   = "{submission_id}"
}

resource "aws_api_gateway_method" "submission_by_id_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.submission_by_id.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id

  request_parameters = {
    "method.request.path.submission_id" = true
  }
}

resource "aws_api_gateway_integration" "submission_by_id_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.submission_by_id.id
  http_method             = aws_api_gateway_method.submission_by_id_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.get_submissions_invoke_arn
}

# CORS OPTIONS for /submissions/{submission_id}
resource "aws_api_gateway_method" "submission_by_id_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.submission_by_id.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "submission_by_id_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.submission_by_id.id
  http_method = aws_api_gateway_method.submission_by_id_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "submission_by_id_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.submission_by_id.id
  http_method = aws_api_gateway_method.submission_by_id_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "submission_by_id_options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.submission_by_id.id
  http_method = aws_api_gateway_method.submission_by_id_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}
```

- [ ] **Step 4: デプロイメントの triggers を全リソースに更新**

既存の `aws_api_gateway_deployment.main` の `triggers` を更新:

```hcl
resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.health,
      aws_api_gateway_method.health_get,
      aws_api_gateway_integration.health_get,
      aws_api_gateway_resource.users_me,
      aws_api_gateway_method.users_me_post,
      aws_api_gateway_integration.users_me_post,
      aws_api_gateway_resource.submissions,
      aws_api_gateway_method.submissions_get,
      aws_api_gateway_integration.submissions_get,
      aws_api_gateway_resource.submissions_sync,
      aws_api_gateway_method.submissions_sync_post,
      aws_api_gateway_integration.submissions_sync_post,
      aws_api_gateway_resource.submission_by_id,
      aws_api_gateway_method.submission_by_id_get,
      aws_api_gateway_integration.submission_by_id_get,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}
```

- [ ] **Step 5: terraform validate**

Run: `cd terraform && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: コミット**

```bash
git add terraform/modules/api_gateway/ terraform/modules.tf
git commit -m "feat(terraform): add API endpoints for users/me, submissions, submissions/sync"
```

---

## Task 11: Frontend — 型定義と API クライアント

**Files:**
- Create: `frontend/app/lib/types.ts`
- Create: `frontend/app/lib/api.ts`

- [ ] **Step 1: types.ts を作成**

```typescript
// frontend/app/lib/types.ts
export interface User {
  user_id: string;
  atcoder_username: string;
  created_at: string;
  updated_at: string;
  last_sync_epoch?: number;
}

export interface Submission {
  user_id: string;
  submission_id: string;
  problem_id: string;
  contest_id: string;
  language: string;
  result: string;
  score: string;
  code_length: number;
  execution_time: number;
  submitted_at: number;
  source_code?: string;
}

export interface ApiResponse<T> {
  data: T;
  meta?: {
    nextToken?: string | null;
  };
}

export interface ApiError {
  error: {
    code: string;
    message: string;
  };
}
```

- [ ] **Step 2: api.ts を作成**

```typescript
// frontend/app/lib/api.ts
import { fetchAuthSession } from "aws-amplify/auth";
import type { ApiResponse } from "./types";

const API_URL = process.env.NEXT_PUBLIC_API_GATEWAY_URL ?? "";

async function getAuthHeaders(): Promise<HeadersInit> {
  const session = await fetchAuthSession();
  const token = session.tokens?.idToken?.toString() ?? "";
  return {
    "Content-Type": "application/json",
    Authorization: token,
  };
}

async function request<T>(
  path: string,
  options: RequestInit = {}
): Promise<ApiResponse<T>> {
  const headers = await getAuthHeaders();
  const res = await fetch(`${API_URL}${path}`, {
    ...options,
    headers: { ...headers, ...options.headers },
  });

  const body = await res.json();

  if (!res.ok) {
    throw new Error(body.error?.message ?? `API error: ${res.status}`);
  }

  return body as ApiResponse<T>;
}

export const api = {
  saveUser(atcoderUsername: string) {
    return request<import("./types").User>("/users/me", {
      method: "POST",
      body: JSON.stringify({ atcoder_username: atcoderUsername }),
    });
  },

  syncSubmissions() {
    return request<{ synced_count: number; from_second: number }>(
      "/submissions/sync",
      { method: "POST" }
    );
  },

  getSubmissions(params?: { limit?: number; nextToken?: string }) {
    const query = new URLSearchParams();
    if (params?.limit) query.set("limit", String(params.limit));
    if (params?.nextToken) query.set("nextToken", params.nextToken);
    const qs = query.toString();
    return request<import("./types").Submission[]>(
      `/submissions${qs ? `?${qs}` : ""}`
    );
  },

  getSubmission(submissionId: string) {
    return request<import("./types").Submission>(
      `/submissions/${encodeURIComponent(submissionId)}`
    );
  },
};
```

- [ ] **Step 3: コミット**

```bash
git add frontend/app/lib/types.ts frontend/app/lib/api.ts
git commit -m "feat(frontend): add TypeScript types and API client with JWT auth"
```

---

## Task 12: Frontend — 共通レイアウト (ナビゲーション)

**Files:**
- Create: `frontend/app/components/Layout.tsx`
- Modify: `frontend/app/page.tsx`

- [ ] **Step 1: Layout.tsx を作成**

```tsx
// frontend/app/components/Layout.tsx
"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useAuthenticator } from "@aws-amplify/ui-react";

const navItems = [
  { href: "/", label: "ホーム" },
  { href: "/submissions", label: "提出一覧" },
  { href: "/settings", label: "設定" },
];

export default function Layout({ children }: { children: React.ReactNode }) {
  const { user, signOut } = useAuthenticator();
  const pathname = usePathname();

  return (
    <div className="flex flex-col flex-1 bg-zinc-50 font-sans dark:bg-zinc-950">
      <header className="border-b border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-6 py-4">
          <div className="flex items-center gap-8">
            <h1 className="text-lg font-semibold text-zinc-900 dark:text-zinc-50">
              AtCoder Review
            </h1>
            <nav className="flex gap-4">
              {navItems.map((item) => (
                <Link
                  key={item.href}
                  href={item.href}
                  className={`text-sm font-medium transition-colors ${
                    pathname === item.href
                      ? "text-zinc-900 dark:text-zinc-50"
                      : "text-zinc-500 hover:text-zinc-700 dark:text-zinc-400 dark:hover:text-zinc-300"
                  }`}
                >
                  {item.label}
                </Link>
              ))}
            </nav>
          </div>
          <div className="flex items-center gap-4">
            <span className="text-sm text-zinc-500 dark:text-zinc-400">
              {user?.signInDetails?.loginId}
            </span>
            <button
              onClick={signOut}
              className="rounded-md bg-zinc-100 px-3 py-1.5 text-sm font-medium text-zinc-700 transition-colors hover:bg-zinc-200 dark:bg-zinc-800 dark:text-zinc-300 dark:hover:bg-zinc-700"
            >
              ログアウト
            </button>
          </div>
        </div>
      </header>
      <main className="mx-auto w-full max-w-5xl flex-1 px-6 py-8">
        {children}
      </main>
    </div>
  );
}
```

- [ ] **Step 2: page.tsx を Layout を使うように更新**

```tsx
// frontend/app/page.tsx
"use client";

import Layout from "@/app/components/Layout";

export default function Home() {
  return (
    <Layout>
      <div className="rounded-lg border border-zinc-200 bg-white p-8 dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="text-xl font-semibold text-zinc-900 dark:text-zinc-50">
          ダッシュボード
        </h2>
        <p className="mt-2 text-zinc-600 dark:text-zinc-400">
          左のナビゲーションから提出一覧や設定にアクセスできます。
        </p>
      </div>
    </Layout>
  );
}
```

- [ ] **Step 3: npm run build でビルドエラーがないか確認**

Run: `cd frontend && npm run build`
Expected: Build succeeds (warnings are OK)

- [ ] **Step 4: コミット**

```bash
git add frontend/app/components/Layout.tsx frontend/app/page.tsx
git commit -m "feat(frontend): add shared layout with navigation"
```

---

## Task 13: Frontend — 設定ページ (AtCoderユーザー名登録)

**Files:**
- Create: `frontend/app/settings/page.tsx`

- [ ] **Step 1: settings/page.tsx を作成**

```tsx
// frontend/app/settings/page.tsx
"use client";

import { useState } from "react";
import Layout from "@/app/components/Layout";
import { api } from "@/app/lib/api";

export default function SettingsPage() {
  const [username, setUsername] = useState("");
  const [status, setStatus] = useState<"idle" | "saving" | "saved" | "error">(
    "idle"
  );
  const [errorMessage, setErrorMessage] = useState("");

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!username.trim()) return;

    setStatus("saving");
    setErrorMessage("");

    try {
      await api.saveUser(username.trim());
      setStatus("saved");
    } catch (err) {
      setStatus("error");
      setErrorMessage(err instanceof Error ? err.message : "保存に失敗しました");
    }
  };

  return (
    <Layout>
      <div className="rounded-lg border border-zinc-200 bg-white p-8 dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="text-xl font-semibold text-zinc-900 dark:text-zinc-50">
          設定
        </h2>
        <form onSubmit={handleSubmit} className="mt-6 max-w-md space-y-4">
          <div>
            <label
              htmlFor="atcoder-username"
              className="block text-sm font-medium text-zinc-700 dark:text-zinc-300"
            >
              AtCoder ユーザー名
            </label>
            <input
              id="atcoder-username"
              type="text"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              placeholder="例: chokudai"
              className="mt-1 block w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 placeholder-zinc-400 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-zinc-600 dark:bg-zinc-800 dark:text-zinc-100"
            />
          </div>
          <button
            type="submit"
            disabled={status === "saving" || !username.trim()}
            className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-blue-700 disabled:opacity-50"
          >
            {status === "saving" ? "保存中..." : "保存"}
          </button>
          {status === "saved" && (
            <p className="text-sm text-green-600">保存しました</p>
          )}
          {status === "error" && (
            <p className="text-sm text-red-600">{errorMessage}</p>
          )}
        </form>
      </div>
    </Layout>
  );
}
```

- [ ] **Step 2: npm run build で確認**

Run: `cd frontend && npm run build`
Expected: Build succeeds

- [ ] **Step 3: コミット**

```bash
git add frontend/app/settings/page.tsx
git commit -m "feat(frontend): add settings page for AtCoder username registration"
```

---

## Task 14: Frontend — 提出一覧ページ

**Files:**
- Create: `frontend/app/submissions/page.tsx`

- [ ] **Step 1: submissions/page.tsx を作成**

```tsx
// frontend/app/submissions/page.tsx
"use client";

import { useState } from "react";
import Link from "next/link";
import Layout from "@/app/components/Layout";
import { api } from "@/app/lib/api";
import type { Submission } from "@/app/lib/types";

function formatDate(epochSecond: number): string {
  return new Date(epochSecond * 1000).toLocaleString("ja-JP");
}

function resultColor(result: string): string {
  if (result === "AC") return "text-green-600 dark:text-green-400";
  if (result === "WA") return "text-yellow-600 dark:text-yellow-400";
  if (result === "TLE" || result === "MLE") return "text-orange-600 dark:text-orange-400";
  if (result === "RE" || result === "CE") return "text-red-600 dark:text-red-400";
  return "text-zinc-600 dark:text-zinc-400";
}

export default function SubmissionsPage() {
  const [submissions, setSubmissions] = useState<Submission[]>([]);
  const [nextToken, setNextToken] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [syncing, setSyncing] = useState(false);
  const [loading, setLoading] = useState(false);
  const [syncResult, setSyncResult] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState("");

  const loadSubmissions = async (token?: string) => {
    setLoading(true);
    setErrorMessage("");
    try {
      const res = await api.getSubmissions({
        limit: 50,
        nextToken: token ?? undefined,
      });
      if (token) {
        setSubmissions((prev) => [...prev, ...res.data]);
      } else {
        setSubmissions(res.data);
      }
      setNextToken(res.meta?.nextToken ?? null);
      setLoaded(true);
    } catch (err) {
      setErrorMessage(err instanceof Error ? err.message : "取得に失敗しました");
    } finally {
      setLoading(false);
    }
  };

  const handleSync = async () => {
    setSyncing(true);
    setSyncResult(null);
    setErrorMessage("");
    try {
      const res = await api.syncSubmissions();
      setSyncResult(`${res.data.synced_count} 件を同期しました`);
      // 同期後に一覧を再読み込み
      await loadSubmissions();
    } catch (err) {
      setErrorMessage(err instanceof Error ? err.message : "同期に失敗しました");
    } finally {
      setSyncing(false);
    }
  };

  return (
    <Layout>
      <div className="space-y-6">
        {/* Actions */}
        <div className="flex items-center gap-4">
          <button
            onClick={handleSync}
            disabled={syncing}
            className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-blue-700 disabled:opacity-50"
          >
            {syncing ? "同期中..." : "提出履歴を同期"}
          </button>
          {!loaded && (
            <button
              onClick={() => loadSubmissions()}
              disabled={loading}
              className="rounded-md bg-zinc-100 px-4 py-2 text-sm font-medium text-zinc-700 transition-colors hover:bg-zinc-200 dark:bg-zinc-800 dark:text-zinc-300 dark:hover:bg-zinc-700"
            >
              {loading ? "読み込み中..." : "一覧を読み込む"}
            </button>
          )}
          {syncResult && (
            <span className="text-sm text-green-600">{syncResult}</span>
          )}
          {errorMessage && (
            <span className="text-sm text-red-600">{errorMessage}</span>
          )}
        </div>

        {/* Table */}
        {loaded && (
          <div className="overflow-hidden rounded-lg border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
            <table className="min-w-full divide-y divide-zinc-200 dark:divide-zinc-800">
              <thead className="bg-zinc-50 dark:bg-zinc-800/50">
                <tr>
                  <th className="px-4 py-3 text-left text-xs font-medium uppercase text-zinc-500 dark:text-zinc-400">
                    問題
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium uppercase text-zinc-500 dark:text-zinc-400">
                    コンテスト
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium uppercase text-zinc-500 dark:text-zinc-400">
                    結果
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium uppercase text-zinc-500 dark:text-zinc-400">
                    言語
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium uppercase text-zinc-500 dark:text-zinc-400">
                    提出日時
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {submissions.map((sub) => (
                  <tr
                    key={sub.submission_id}
                    className="hover:bg-zinc-50 dark:hover:bg-zinc-800/30"
                  >
                    <td className="px-4 py-3 text-sm">
                      <Link
                        href={`/submissions/${encodeURIComponent(sub.submission_id)}`}
                        className="text-blue-600 hover:underline dark:text-blue-400"
                      >
                        {sub.problem_id}
                      </Link>
                    </td>
                    <td className="px-4 py-3 text-sm text-zinc-600 dark:text-zinc-400">
                      {sub.contest_id}
                    </td>
                    <td className={`px-4 py-3 text-sm font-medium ${resultColor(sub.result)}`}>
                      {sub.result}
                    </td>
                    <td className="px-4 py-3 text-sm text-zinc-600 dark:text-zinc-400">
                      {sub.language}
                    </td>
                    <td className="px-4 py-3 text-sm text-zinc-600 dark:text-zinc-400">
                      {formatDate(sub.submitted_at)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {submissions.length === 0 && (
              <p className="p-8 text-center text-sm text-zinc-500 dark:text-zinc-400">
                提出履歴がありません。「提出履歴を同期」ボタンで取得してください。
              </p>
            )}
          </div>
        )}

        {/* Load more */}
        {nextToken && (
          <div className="text-center">
            <button
              onClick={() => loadSubmissions(nextToken)}
              disabled={loading}
              className="rounded-md bg-zinc-100 px-4 py-2 text-sm font-medium text-zinc-700 transition-colors hover:bg-zinc-200 dark:bg-zinc-800 dark:text-zinc-300 dark:hover:bg-zinc-700"
            >
              {loading ? "読み込み中..." : "もっと読み込む"}
            </button>
          </div>
        )}
      </div>
    </Layout>
  );
}
```

- [ ] **Step 2: npm run build で確認**

Run: `cd frontend && npm run build`
Expected: Build succeeds

- [ ] **Step 3: コミット**

```bash
git add frontend/app/submissions/page.tsx
git commit -m "feat(frontend): add submissions list page with sync and pagination"
```

---

## Task 15: Frontend — 提出詳細ページ

**Files:**
- Create: `frontend/app/submissions/[id]/page.tsx`

- [ ] **Step 1: submissions/[id]/page.tsx を作成**

```tsx
// frontend/app/submissions/[id]/page.tsx
"use client";

import { useEffect, useState, use } from "react";
import Link from "next/link";
import Layout from "@/app/components/Layout";
import { api } from "@/app/lib/api";
import type { Submission } from "@/app/lib/types";

function formatDate(epochSecond: number): string {
  return new Date(epochSecond * 1000).toLocaleString("ja-JP");
}

export default function SubmissionDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = use(params);
  const [submission, setSubmission] = useState<Submission | null>(null);
  const [loading, setLoading] = useState(true);
  const [errorMessage, setErrorMessage] = useState("");

  useEffect(() => {
    const load = async () => {
      try {
        const res = await api.getSubmission(decodeURIComponent(id));
        setSubmission(res.data);
      } catch (err) {
        setErrorMessage(
          err instanceof Error ? err.message : "取得に失敗しました"
        );
      } finally {
        setLoading(false);
      }
    };
    load();
  }, [id]);

  return (
    <Layout>
      <div className="space-y-6">
        <Link
          href="/submissions"
          className="text-sm text-blue-600 hover:underline dark:text-blue-400"
        >
          &larr; 提出一覧に戻る
        </Link>

        {loading && (
          <p className="text-sm text-zinc-500 dark:text-zinc-400">
            読み込み中...
          </p>
        )}

        {errorMessage && (
          <p className="text-sm text-red-600">{errorMessage}</p>
        )}

        {submission && (
          <>
            <div className="rounded-lg border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
              <h2 className="text-xl font-semibold text-zinc-900 dark:text-zinc-50">
                {submission.problem_id}
              </h2>
              <dl className="mt-4 grid grid-cols-2 gap-4 text-sm sm:grid-cols-4">
                <div>
                  <dt className="text-zinc-500 dark:text-zinc-400">
                    コンテスト
                  </dt>
                  <dd className="mt-1 font-medium text-zinc-900 dark:text-zinc-50">
                    {submission.contest_id}
                  </dd>
                </div>
                <div>
                  <dt className="text-zinc-500 dark:text-zinc-400">結果</dt>
                  <dd className="mt-1 font-medium text-zinc-900 dark:text-zinc-50">
                    {submission.result}
                  </dd>
                </div>
                <div>
                  <dt className="text-zinc-500 dark:text-zinc-400">言語</dt>
                  <dd className="mt-1 font-medium text-zinc-900 dark:text-zinc-50">
                    {submission.language}
                  </dd>
                </div>
                <div>
                  <dt className="text-zinc-500 dark:text-zinc-400">
                    提出日時
                  </dt>
                  <dd className="mt-1 font-medium text-zinc-900 dark:text-zinc-50">
                    {formatDate(submission.submitted_at)}
                  </dd>
                </div>
                <div>
                  <dt className="text-zinc-500 dark:text-zinc-400">
                    実行時間
                  </dt>
                  <dd className="mt-1 font-medium text-zinc-900 dark:text-zinc-50">
                    {submission.execution_time} ms
                  </dd>
                </div>
                <div>
                  <dt className="text-zinc-500 dark:text-zinc-400">
                    コード長
                  </dt>
                  <dd className="mt-1 font-medium text-zinc-900 dark:text-zinc-50">
                    {submission.code_length} bytes
                  </dd>
                </div>
              </dl>
            </div>

            {submission.source_code && (
              <div className="rounded-lg border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
                <div className="border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
                  <h3 className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                    ソースコード
                  </h3>
                </div>
                <pre className="overflow-x-auto p-4 text-sm text-zinc-800 dark:text-zinc-200">
                  <code>{submission.source_code}</code>
                </pre>
              </div>
            )}
          </>
        )}
      </div>
    </Layout>
  );
}
```

- [ ] **Step 2: npm run build で確認**

Run: `cd frontend && npm run build`
Expected: Build succeeds

- [ ] **Step 3: コミット**

```bash
git add frontend/app/submissions/\[id\]/page.tsx
git commit -m "feat(frontend): add submission detail page"
```

---

## Task 16: Lambda デプロイスクリプト

**Files:**
- Create: `backend/scripts/package_lambda.sh`

Lambda を zip にパッケージングし、AWS CLIでデプロイするスクリプト。CI/CDの前に手動デプロイで動作確認するため。

- [ ] **Step 1: パッケージングスクリプトを作成**

```bash
#!/bin/bash
# backend/scripts/package_lambda.sh
# Usage: ./scripts/package_lambda.sh <lambda_name>
# Example: ./scripts/package_lambda.sh save_user

set -euo pipefail

LAMBDA_NAME=$1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$BACKEND_DIR/build/$LAMBDA_NAME"

echo "Packaging $LAMBDA_NAME..."

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Copy handler
cp "$BACKEND_DIR/lambdas/$LAMBDA_NAME/handler.py" "$BUILD_DIR/"

# Copy shared modules
cp -r "$BACKEND_DIR/shared" "$BUILD_DIR/"

# Install dependencies (excluding boto3 — already in Lambda runtime)
pip install requests -t "$BUILD_DIR" --quiet 2>/dev/null || true

# Create zip
cd "$BUILD_DIR"
zip -r "$BACKEND_DIR/build/$LAMBDA_NAME.zip" . -q

echo "Created: backend/build/$LAMBDA_NAME.zip"
```

- [ ] **Step 2: スクリプトに実行権限を付与**

```bash
chmod +x backend/scripts/package_lambda.sh
```

- [ ] **Step 3: 3つの Lambda をパッケージング**

```bash
cd backend
./scripts/package_lambda.sh save_user
./scripts/package_lambda.sh sync_submissions
./scripts/package_lambda.sh get_submissions
```

Expected: `backend/build/` に3つのzipファイルが生成される

- [ ] **Step 4: コミット**

```bash
git add backend/scripts/package_lambda.sh
git commit -m "feat(backend): add Lambda packaging script"
```

---

## Task 17: Terraform apply & 動作確認

このタスクは手動実行が必要。Terraformで全リソースをデプロイし、curlでAPIの動作を確認する。

- [ ] **Step 1: terraform plan で変更内容を確認**

```bash
cd terraform
terraform plan
```

Expected: DynamoDB 3テーブル、Lambda 3関数、API Gatewayリソース・メソッドの追加が表示される

- [ ] **Step 2: terraform apply でデプロイ**

```bash
cd terraform
terraform apply
```

Expected: Apply complete! で成功

- [ ] **Step 3: Lambda コードをデプロイ**

```bash
cd backend

# パッケージング
./scripts/package_lambda.sh save_user
./scripts/package_lambda.sh sync_submissions
./scripts/package_lambda.sh get_submissions

# デプロイ
aws lambda update-function-code \
  --function-name atcoder-review-save-user-prod \
  --zip-file fileb://build/save_user.zip

aws lambda update-function-code \
  --function-name atcoder-review-sync-submissions-prod \
  --zip-file fileb://build/sync_submissions.zip

aws lambda update-function-code \
  --function-name atcoder-review-get-submissions-prod \
  --zip-file fileb://build/get_submissions.zip
```

- [ ] **Step 4: API Gateway URL を取得して /health を確認**

```bash
API_URL=$(cd terraform && terraform output -raw api_gateway_url)
curl -s "$API_URL/health" | jq .
```

Expected: `{ "status": "ok" }`

- [ ] **Step 5: 認証付きで /users/me を確認**

(ブラウザのDevToolsからJWTトークンを取得して確認)

```bash
TOKEN="<JWT token from browser>"
curl -s -X POST "$API_URL/users/me" \
  -H "Authorization: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"atcoder_username":"your_username"}' | jq .
```

Expected: `{ "data": { "user_id": "...", "atcoder_username": "your_username", ... } }`

- [ ] **Step 6: コミット（.env等を含めないこと）**

```bash
git add -A
git status  # .env や credentials が含まれていないことを確認
git commit -m "chore: verify deployment and API integration"
```

---

## Task 18: Frontend 環境変数設定 & 結合テスト

- [ ] **Step 1: frontend/.env.local を作成**

```bash
# frontend/.env.local (gitignore対象)
NEXT_PUBLIC_COGNITO_USER_POOL_ID=<terraform output cognito_user_pool_id>
NEXT_PUBLIC_COGNITO_USER_POOL_CLIENT_ID=<terraform output cognito_user_pool_client_id>
NEXT_PUBLIC_API_GATEWAY_URL=<terraform output api_gateway_url>
```

Terraform outputから値を取得:
```bash
cd terraform
terraform output cognito_user_pool_id
terraform output cognito_user_pool_client_id
terraform output api_gateway_url
```

- [ ] **Step 2: ローカルで動作確認**

```bash
cd frontend
npm run dev
```

ブラウザで http://localhost:3000 を開いて:
1. ログインする
2. 「設定」ページでAtCoderユーザー名を登録
3. 「提出一覧」ページで「提出履歴を同期」を押す
4. 一覧が表示されることを確認
5. 提出をクリックして詳細が表示されることを確認

- [ ] **Step 3: 動作確認結果をコミットメッセージに記録**

```bash
git commit --allow-empty -m "milestone: Phase 1 MVP local integration test passed"
```
