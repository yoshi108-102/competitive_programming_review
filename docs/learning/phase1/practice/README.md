# Phase 1 / practice

Phase 1 の実装過程で発生した、**AWS の主題ではないが理解の助けになる**ノート群を置く場所。

主に以下を扱う:

- **設計判断のメモ**: なぜこのヘルパを作ったか、なぜこの責務分離か
- **Python ライブラリの使い方**: pytest fixtures, moto, requests, requests-mock
- **Frontend 実装パターン**: Next.js 16 client component の書き方、API クライアント
- **オペレーション手順**: terraform apply, 結合テスト手順
- **議論ログ (`reference/`)**: ユーザーとの Q&A から発生した深掘りメモ

## 命名規則

- **トピック単位の md** を直下に置く（連番なし、kebab-case）
- 議論・Q&A ログは `reference/` 配下に置く（CORS まわりのログを参照）

## 既存ファイル

| ファイル | 内容 |
|---|---|
| `shared-response-helper-design.md` | `shared/response.py` の設計判断（4 つの責務、API インターフェース） |
| `lambda-handler-skeleton.md` | Lambda ハンドラの 4 段階パターン (event → validate → logic → response) |
| `frontend-api-client.md` | Frontend の fetch ラッパー設計、JWT 取得、エラーハンドリング |
| `nextjs-client-pages.md` | Next.js 16 client component で書くページ実装パターン |
| `json-dumps-default-str.md` | `json.dumps(default=str)` の動作と JSONEncoder サブクラス化 |
| `python-requests-and-mock.md` | `requests` の基本（get, params, raise_for_status, timeout）と requests-mock |
| `atcoder-problems-api.md` | AtCoder Problems API の仕様メモ |
| `moto-and-aws-test-credentials.md` | moto の動作 + AWS_ACCESS_KEY_ID="testing" の役割 |
| `pytest-fixtures-for-aws.md` | conftest.py の 2 段階 fixture 設計 |
| `terraform-apply-walkthrough.md` | terraform apply 手順、CloudWatch Logs での確認方法 |
| `frontend-integration-test.md` | terraform output → .env.local → next dev での結合確認手順 |
| `reference/` | CORS / SOP / preflight に関する Q&A ログ |

## 新規追加の指針

セッション中に「実装の Q&A」が出たら、専用 md をここに追加する。
**AWS の中核概念**（Lambda / DynamoDB / API Gateway / Cognito / IAM など）が主題なら `phase1/` 直下の番号付き md を更新／追加する。
