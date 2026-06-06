#!/usr/bin/env bash
# load.sh — Phase 1 ロード生成 (Cognito / API GW / Lambda / DynamoDB)
# 無入力で動く: 本番スタックの terraform output から API URL 等を自動取得し、
# まず「無認証トラフィック」で API GW(Count/4XXError/Latency)+Cognito Authorizer を稼働させる。
# 認証ありの負荷(handler Lambda の Invocations)も出したい場合のみ TEST_PASSWORD を渡す。
set -euo pipefail

# --- カラー定義 ---
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

sep() { echo -e "${CYAN}──────────────────────────────────────────${RESET}"; }

REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
# repo の本番 terraform/ ディレクトリ (このスクリプトから 3 つ上 + /terraform)
PROD_TF="$(cd "$(dirname "$0")/../../.." && pwd)/terraform"
SANDBOX_TF="$(cd "$(dirname "$0")" && pwd)"

echo -e "${BOLD}Phase 1 ロード生成スクリプト${RESET}"
echo -e "  リージョン : ${REGION}"
echo -e "  本番 TF    : ${PROD_TF}"
echo -e "  Sandbox TF : ${SANDBOX_TF}"
sep

# --- 本番 output から自動取得 (env が優先、無ければ output、それも無ければ空) ---
echo -e "${CYAN}[識別子取得]${RESET} 本番 terraform output を参照中..."
api_out=$(terraform -chdir="$PROD_TF" output -raw api_gateway_url 2>/dev/null || true)
pool_out=$(terraform -chdir="$PROD_TF" output -raw cognito_user_pool_id 2>/dev/null || true)
client_out=$(terraform -chdir="$PROD_TF" output -raw cognito_user_pool_client_id 2>/dev/null || true)

API_URL="${API_URL:-$api_out}"
USER_POOL_ID="${USER_POOL_ID:-$pool_out}"
CLIENT_ID="${CLIENT_ID:-$client_out}"

if [ -z "$API_URL" ]; then
  echo -e "${RED}ERROR: API_URL を特定できませんでした。${RESET}" >&2
  echo "  本番スタックを apply 済みか確認するか、以下のように渡してください:" >&2
  echo "    API_URL=https://xxxx.execute-api.${REGION}.amazonaws.com/prod make sandbox-load-phase1" >&2
  exit 1
fi

echo -e "  ${GREEN}API_URL${RESET}       = ${API_URL}"
echo -e "  ${GREEN}USER_POOL_ID${RESET}  = ${USER_POOL_ID:-（未取得 — 認証ありスキップ）}"
echo -e "  ${GREEN}CLIENT_ID${RESET}     = ${CLIENT_ID:-（未取得 — 認証ありスキップ）}"
sep

# --- 進捗カウンタ helper ---
ok_count=0
err_count=0
count_req() {
  local code="$1"
  if [[ "$code" =~ ^[0-9]+$ ]] && [ "$code" -ge 100 ] 2>/dev/null; then
    ok_count=$((ok_count + 1))
  else
    err_count=$((err_count + 1))
  fi
}

# --- [1] 無認証リクエスト (ユーザー不要。401/4XX で API GW メトリクスを稼働) ---
echo -e "${BOLD}[1/3] 無認証 GET /submissions x50${RESET}"
echo -e "  目的: Cognito Authorizer が 401 を返す → API GW 4XXError / Count が上昇"
echo -n "  送信中 ["
codes=""
for i in $(seq 1 50); do
  c=$(curl -s -o /dev/null -w "%{http_code}" "${API_URL}/submissions?limit=10" || echo "ERR")
  codes="$codes $c"
  count_req "$c"
  # 10件ごとにドットを表示
  if [ $((i % 10)) -eq 0 ]; then printf "."; fi
done
echo "] 完了"
echo -e "  ステータス一覧:${codes}"
echo -e "  集計: OK(HTTP>=100)=${ok_count}件 / ERR=${err_count}件"
sep

# --- [2] 不正トークン ---
ok_count=0; err_count=0
echo -e "${BOLD}[2/3] 不正トークン GET /submissions x10${RESET}"
echo -e "  目的: Authorization ヘッダあり・無効 JWT → Authorizer が 403 を返す"
echo -n "  送信中["
codes=""
for i in $(seq 1 10); do
  c=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer invalid.token.${i}" \
    "${API_URL}/submissions" || echo "ERR")
  codes="$codes $c"
  count_req "$c"
  printf "."
done
echo "] 完了"
echo -e "  ステータス一覧:${codes}"
echo -e "  集計: OK(HTTP>=100)=${ok_count}件 / ERR=${err_count}件"
sep

# --- [3] (任意) 認証ありトラフィック: TEST_PASSWORD を渡したときだけ ---
ok_count=0; err_count=0
if [ -n "${TEST_PASSWORD:-}" ] && [ -n "$CLIENT_ID" ]; then
  USERNAME="${TEST_USERNAME:-loadtest@example.com}"
  echo -e "${BOLD}[3/3] Cognito 認証 -> 認証あり負荷 (USERNAME=${USERNAME})${RESET}"
  echo -e "  目的: サインイン成功 → Lambda Invocations・DynamoDB Read が上昇"
  TOKEN=$(aws cognito-idp initiate-auth \
    --auth-flow USER_PASSWORD_AUTH \
    --auth-parameters "USERNAME=${USERNAME},PASSWORD=${TEST_PASSWORD}" \
    --client-id "${CLIENT_ID}" \
    --region "${REGION}" \
    --query 'AuthenticationResult.IdToken' \
    --output text 2>/dev/null || true)
  if [ -n "$TOKEN" ] && [ "$TOKEN" != "None" ]; then
    echo -e "  ${GREEN}サインイン成功。${RESET} 認証あり GET x30 + POST /users x10 を送信"
    echo -n "  GET 送信中 ["
    for i in $(seq 1 30); do
      c=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${TOKEN}" \
        "${API_URL}/submissions?limit=10" || echo "ERR")
      count_req "$c"
      if [ $((i % 10)) -eq 0 ]; then printf "."; fi
    done
    echo "] 完了 (OK=${ok_count}/ERR=${err_count})"

    ok_count=0; err_count=0
    echo -n "  POST 送信中 ["
    for i in $(seq 1 10); do
      c=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"loadtest_user_${i}\"}" \
        "${API_URL}/users" || echo "ERR")
      count_req "$c"
      printf "."
    done
    echo "] 完了 (OK=${ok_count}/ERR=${err_count})"
  else
    echo -e "  ${YELLOW}(認証スキップ)${RESET} サインインに失敗。TEST_USERNAME/TEST_PASSWORD と該当ユーザーの存在を確認してください。"
  fi
else
  echo -e "${BOLD}[3/3] 認証ありトラフィックはスキップ (TEST_PASSWORD 未設定)${RESET}"
  echo -e "  handler Lambda の Invocations も記録したい場合:"
  echo -e "    ${CYAN}TEST_USERNAME=you@example.com TEST_PASSWORD=... make sandbox-load-phase1${RESET}"
fi

sep
echo
echo -e "${GREEN}${BOLD}ロード生成 完了。${RESET}"
echo -e "  メトリクスの CloudWatch への反映には ${YELLOW}2〜5 分${RESET} かかります。"
echo -e "  反映を待ってから以下を実行してください:"
echo
echo -e "    ${BOLD}make sandbox-watch-phase1${RESET}"
echo
