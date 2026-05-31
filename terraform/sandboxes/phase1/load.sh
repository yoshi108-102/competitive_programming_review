#!/usr/bin/env bash
# load.sh — Phase 1 load generation (Cognito / API GW / Lambda / DynamoDB)
set -euo pipefail

API_URL="${API_URL:?Please set API_URL, e.g. https://xxxxxxx.execute-api.ap-northeast-1.amazonaws.com/prod}"
USER_POOL_ID="${USER_POOL_ID:?Please set USER_POOL_ID}"
CLIENT_ID="${CLIENT_ID:?Please set CLIENT_ID}"
USERNAME="${TEST_USERNAME:-loadtest@example.com}"
PASSWORD="${TEST_PASSWORD:?Please set TEST_PASSWORD}"
REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"

echo "=== [1] Cognito sign-in (success + deliberate failures) ==="
# Normal sign-in — obtain ID Token
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=${USERNAME},PASSWORD=${PASSWORD}" \
  --client-id "${CLIENT_ID}" \
  --region "${REGION}" \
  --query 'AuthenticationResult.IdToken' --output text)

echo "Token OK (first 50 chars): ${TOKEN:0:50}..."

# Intentional auth failures x3 — generates Cognito 4xx/throttle metrics
for i in 1 2 3; do
  aws cognito-idp initiate-auth \
    --auth-flow USER_PASSWORD_AUTH \
    --auth-parameters "USERNAME=${USERNAME},PASSWORD=WrongPass${i}!" \
    --client-id "${CLIENT_ID}" \
    --region "${REGION}" 2>/dev/null || true
done

echo "=== [2] API GW + Lambda: normal requests x50 ==="
for i in $(seq 1 50); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer ${TOKEN}" \
    "${API_URL}/submissions?limit=10"
done

echo "=== [3] API GW + Lambda: invalid token -> 401 x10 ==="
for i in $(seq 1 10); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer invalidtoken" \
    "${API_URL}/submissions"
done

echo "=== [4] DynamoDB writes: save_user x20 ==="
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"loadtest_user_${i}\"}" \
    "${API_URL}/users"
done

echo "=== [5] sync_submissions: heavy batch trigger ==="
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"force_sync": true}' \
  "${API_URL}/sync"

echo ""
echo "Load generation complete. Wait 2-5 minutes for metrics to appear, then run watch.sh."
