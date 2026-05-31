#!/usr/bin/env bash
# load.sh — Phase 1 ロード生成 (Cognito / API GW / Lambda / DynamoDB)
# 無入力で動く: 本番スタックの terraform output から API URL 等を自動取得し、
# まず「無認証トラフィック」で API GW(Count/4XXError/Latency)+Cognito Authorizer を稼働させる。
# 認証ありの負荷(handler Lambda の Invocations)も出したい場合のみ TEST_PASSWORD を渡す。
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
# repo の本番 terraform/ ディレクトリ (このスクリプトから 3 つ上 + /terraform)
PROD_TF="$(cd "$(dirname "$0")/../../.." && pwd)/terraform"

# --- 本番 output から自動取得 (env が優先、無ければ output、それも無ければ空) ---
api_out=$(terraform -chdir="$PROD_TF" output -raw api_gateway_url 2>/dev/null || true)
pool_out=$(terraform -chdir="$PROD_TF" output -raw cognito_user_pool_id 2>/dev/null || true)
client_out=$(terraform -chdir="$PROD_TF" output -raw cognito_user_pool_client_id 2>/dev/null || true)

API_URL="${API_URL:-$api_out}"
USER_POOL_ID="${USER_POOL_ID:-$pool_out}"
CLIENT_ID="${CLIENT_ID:-$client_out}"

if [ -z "$API_URL" ]; then
  echo "ERROR: API_URL を特定できませんでした。" >&2
  echo "  本番スタックを apply 済みか確認するか、API_URL=https://xxxx.execute-api.${REGION}.amazonaws.com/prod を渡してください。" >&2
  echo "  例: API_URL=... make sandbox-load-phase1" >&2
  exit 1
fi
echo "API_URL  = $API_URL"
echo "REGION   = $REGION"
echo

# --- [1] 無認証リクエスト (ユーザー不要。401/4XX で API GW メトリクスを稼働) ---
echo "=== [1] 無認証 GET /submissions x50 (Cognito Authorizer が 401 を返す) ==="
codes=""
for i in $(seq 1 50); do
  c=$(curl -s -o /dev/null -w "%{http_code}" "${API_URL}/submissions?limit=10" || echo "ERR")
  codes="$codes $c"
done
echo "  status:${codes}"

echo "=== [2] 不正トークン GET /submissions x10 ==="
codes=""
for i in $(seq 1 10); do
  c=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer invalid.token.${i}" "${API_URL}/submissions" || echo "ERR")
  codes="$codes $c"
done
echo "  status:${codes}"

# --- [3] (任意) 認証ありトラフィック: TEST_PASSWORD を渡したときだけ ---
if [ -n "${TEST_PASSWORD:-}" ] && [ -n "$CLIENT_ID" ]; then
  USERNAME="${TEST_USERNAME:-loadtest@example.com}"
  echo "=== [3] Cognito 認証 -> 認証あり負荷 (USERNAME=${USERNAME}) ==="
  TOKEN=$(aws cognito-idp initiate-auth \
    --auth-flow USER_PASSWORD_AUTH \
    --auth-parameters "USERNAME=${USERNAME},PASSWORD=${TEST_PASSWORD}" \
    --client-id "${CLIENT_ID}" --region "${REGION}" \
    --query 'AuthenticationResult.IdToken' --output text 2>/dev/null || true)
  if [ -n "$TOKEN" ] && [ "$TOKEN" != "None" ]; then
    echo "  サインイン成功。認証あり GET x30 + POST /users x10 を送信"
    for i in $(seq 1 30); do
      curl -s -o /dev/null -w "%{http_code} " -H "Authorization: Bearer ${TOKEN}" "${API_URL}/submissions?limit=10" || true
    done; echo
    for i in $(seq 1 10); do
      curl -s -o /dev/null -w "%{http_code} " -X POST \
        -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
        -d "{\"username\":\"loadtest_user_${i}\"}" "${API_URL}/users" || true
    done; echo
  else
    echo "  (認証スキップ) サインインに失敗。TEST_USERNAME/TEST_PASSWORD と該当ユーザーの存在を確認してください。"
  fi
else
  echo "=== [3] 認証ありトラフィックはスキップ (TEST_PASSWORD 未設定) ==="
  echo "  handler Lambda の Invocations も出したい場合:"
  echo "    TEST_USERNAME=you@example.com TEST_PASSWORD=... make sandbox-load-phase1"
fi

echo
echo "ロード生成 完了。メトリクス反映まで 2-5 分待ってから make sandbox-watch-phase1 を実行してください。"
