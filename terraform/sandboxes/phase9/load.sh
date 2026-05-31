#!/usr/bin/env bash
# load.sh — Phase9 X-Ray アクティビティ生成
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}"

# API GW URL を Terraform output から取得
API_URL=$(terraform -chdir="${TF_DIR}" output -raw api_url)
QUEUE_URL=$(terraform -chdir="${TF_DIR}" output -raw sqs_url)

echo "=== Phase9 ロード生成 ==="
echo "API_URL:   ${API_URL}"
echo "QUEUE_URL: ${QUEUE_URL}"
echo ""

# ── シナリオ1: 正常系 POST /items を20回 ──────────────────────────────────
echo "[1/4] 正常系: POST /items x20"
for i in $(seq 1 20); do
  curl -s -X POST "${API_URL}/items" \
    -H "Content-Type: application/json" \
    -d "{\"message\": \"load-test-${i}\"}" \
    -o /dev/null -w "  ${i}: HTTP %{http_code}\n"
  sleep 0.3
done

# ── シナリオ2: Lambda 直接 invoke (コールドスタート観測) ──────────────────
echo ""
echo "[2/4] コールドスタート誘発: 直接 Lambda invoke"
aws lambda invoke \
  --function-name phase9-producer \
  --payload '{"httpMethod":"POST","body":"{\"message\":\"cold-start-test\"}"}' \
  --cli-binary-format raw-in-base64-out \
  --region "${REGION}" \
  /tmp/phase9-invoke-out.json > /dev/null
python3 -m json.tool /tmp/phase9-invoke-out.json || true
echo ""

# ── シナリオ3: エラー誘発 (不正ペイロードで X-Ray にエラーセグメントを生成) ──
echo "[3/4] エラー誘発: 壊れた JSON でエラーセグメントを生成"
for i in $(seq 1 5); do
  curl -s -X POST "${API_URL}/items" \
    -H "Content-Type: application/json" \
    -d "NOT_JSON" \
    -o /dev/null -w "  error-${i}: HTTP %{http_code}\n"
  sleep 0.2
done

# ── シナリオ4: SQS 直接送信 (consumer Lambda のトレースも観測) ────────────
echo ""
echo "[4/4] SQS 直接送信 x5 (consumer Lambda のトレースを生成)"
for i in $(seq 1 5); do
  MSG_ID=$(aws sqs send-message \
    --queue-url "${QUEUE_URL}" \
    --message-body "{\"item_id\": \"manual-$(date +%s)-${i}\"}" \
    --region "${REGION}" \
    --query 'MessageId' --output text)
  echo "  sent: ${MSG_ID}"
  sleep 0.5
done

echo ""
echo "=== ロード完了。X-Ray にトレースが届くまで約 30-60 秒待機します ==="
echo "その間に watch.sh を別ターミナルで実行してください。"
