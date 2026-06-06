#!/usr/bin/env bash
# watch.sh — Phase 1 メトリクス観測 (Cognito / API GW / Lambda / DynamoDB)
set -euo pipefail

# --- カラー定義 ---
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

sep()  { echo -e "${CYAN}──────────────────────────────────────────${RESET}"; }
note() { echo -e "  ${YELLOW}[観察]${RESET} $*"; }

REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
SANDBOX_TF="$(cd "$(dirname "$0")" && pwd)"
PROD_TF="$(cd "$(dirname "$0")/../../.." && pwd)/terraform"

# --- sandbox 自身の output から自動取得 ---
DASHBOARD_NAME="${DASHBOARD_NAME:-$(terraform -chdir="$SANDBOX_TF" output -raw dashboard_name 2>/dev/null || echo "phase1-sandbox")}"
DASHBOARD_URL="${DASHBOARD_URL:-$(terraform -chdir="$SANDBOX_TF" output -raw dashboard_url 2>/dev/null || echo "")}"

# 本番スタックの output から識別子を取得 (env が優先)
api_out=$(terraform -chdir="$PROD_TF" output -raw api_gateway_url 2>/dev/null || true)
pool_out=$(terraform -chdir="$PROD_TF" output -raw cognito_user_pool_id 2>/dev/null || true)

STAGE="${API_GW_STAGE:-prod}"
API_GW_ID="${API_GW_ID:-atcoder-review-api-prod}"
LAMBDA_FUNCTION_NAMES="${LAMBDA_FUNCTION_NAMES:-atcoder-review-save-user-prod atcoder-review-sync-submissions-prod atcoder-review-get-submissions-prod}"
DYNAMODB_TABLE_NAME="${DYNAMODB_TABLE_NAME:-atcoder-review-submissions-prod}"
USER_POOL_ID="${USER_POOL_ID:-${pool_out:-atcoder-review-prod}}"

echo -e "${BOLD}Phase 1 メトリクス観測スクリプト${RESET}"
echo -e "  リージョン     : ${REGION}"
echo -e "  ダッシュボード : ${DASHBOARD_NAME}"
echo -e "  API GW 名      : ${API_GW_ID} (Stage=${STAGE})"
echo -e "  DynamoDB       : ${DYNAMODB_TABLE_NAME}"
echo -e "  Cognito Pool   : ${USER_POOL_ID}"
sep

echo -e "${YELLOW}INFO: CloudWatch メトリクスの反映には 2〜5 分かかります。${RESET}"
echo -e "${YELLOW}INFO: load.sh 実行直後に watch.sh を走らせた場合、データが 0 の場合があります。${RESET}"
echo -e "${YELLOW}INFO: その場合は 2〜3 分待って再実行してください。${RESET}"

# ─── [0] Dashboard スモーク確認 ───────────────────────────────────────────────
sep
echo -e "${BOLD}[0/4] Dashboard 存在確認${RESET}"
aws cloudwatch get-dashboard \
  --dashboard-name "${DASHBOARD_NAME}" \
  --region "${REGION}" \
  --query 'DashboardName' \
  --output text 2>/dev/null \
  && echo -e "  ${GREEN}Dashboard OK${RESET}" \
  || { echo -e "  ${RED}Dashboard が見つかりません。make sandbox-up-phase1 を先に実行してください。${RESET}"; exit 1; }

# 反映待機
echo
echo -e "  メトリクス反映のため ${YELLOW}60 秒${RESET} 待機します..."
sleep 60

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FIVE_MIN_AGO=$(date -u -v-5M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -d '5 minutes ago' +"%Y-%m-%dT%H:%M:%SZ")
TEN_MIN_AGO=$(date -u -v-10M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -d '10 minutes ago' +"%Y-%m-%dT%H:%M:%SZ")

echo -e "  観測ウィンドウ : ${FIVE_MIN_AGO} 〜 ${NOW}"

# ─── [1] API Gateway ──────────────────────────────────────────────────────────
sep
echo -e "${BOLD}[1/4] API Gateway: Count / 4XXError / 5XXError / Latency${RESET}"
note "Count が上昇: load.sh の無認証リクエストが API GW まで届いている証拠"
note "4XXError が Count とほぼ同数: Cognito Authorizer が 401/403 を正常に返している"
note "5XXError が 0: バックエンド Lambda に例外がない (あれば Lambda Errors と連動)"
note "Latency p99: Authorizer の処理時間込み。通常 < 500ms が健全"
echo
for metric in Count 4XXError 5XXError Latency; do
  echo -e "  --- ${CYAN}${metric}${RESET} ---"
  aws cloudwatch get-metric-statistics \
    --namespace "AWS/ApiGateway" \
    --metric-name "${metric}" \
    --dimensions \
      "Name=ApiName,Value=${API_GW_ID}" \
      "Name=Stage,Value=${STAGE}" \
    --start-time "${FIVE_MIN_AGO}" \
    --end-time "${NOW}" \
    --period 60 \
    --statistics Sum Average Maximum \
    --region "${REGION}" \
    --output table 2>/dev/null || true
done

# ─── [2] Lambda ───────────────────────────────────────────────────────────────
sep
echo -e "${BOLD}[2/4] Lambda: Invocations / Errors / Duration / Throttles${RESET}"
note "無認証負荷のみ → Invocations は 0 が正常 (Authorizer が弾くためハンドラは呼ばれない)"
note "TEST_PASSWORD を渡した場合のみ Invocations が上昇"
note "Errors > 0: 実装バグ or 依存サービス(DynamoDB)の問題を示す"
note "Duration: コールドスタートがあると p99 が突出して高くなる"
echo
for fn in ${LAMBDA_FUNCTION_NAMES}; do
  echo -e "  --- ${CYAN}Lambda: ${fn}${RESET} ---"
  for metric in Invocations Errors Duration Throttles ConcurrentExecutions; do
    aws cloudwatch get-metric-statistics \
      --namespace "AWS/Lambda" \
      --metric-name "${metric}" \
      --dimensions "Name=FunctionName,Value=${fn}" \
      --start-time "${FIVE_MIN_AGO}" \
      --end-time "${NOW}" \
      --period 60 \
      --statistics Sum Average Maximum \
      --region "${REGION}" \
      --output table 2>/dev/null || true
  done
done

# ─── [3] DynamoDB ─────────────────────────────────────────────────────────────
sep
echo -e "${BOLD}[3/4] DynamoDB: Consumed Capacity / SystemErrors / Latency${RESET}"
note "ConsumedReadCapacityUnits/ConsumedWriteCapacityUnits: 認証あり負荷のときだけ上昇"
note "SystemErrors > 0: AWS 側の問題 (通常 0)"
note "UserErrors > 0: アプリの DynamoDB 呼び出しが不正 (存在しないキー等)"
note "SuccessfulRequestLatency: DynamoDB 自体の応答時間。通常 < 10ms"
echo
for metric in ConsumedReadCapacityUnits ConsumedWriteCapacityUnits SystemErrors UserErrors SuccessfulRequestLatency; do
  echo -e "  --- ${CYAN}${metric}${RESET} ---"
  aws cloudwatch get-metric-statistics \
    --namespace "AWS/DynamoDB" \
    --metric-name "${metric}" \
    --dimensions "Name=TableName,Value=${DYNAMODB_TABLE_NAME}" \
    --start-time "${TEN_MIN_AGO}" \
    --end-time "${NOW}" \
    --period 60 \
    --statistics Sum Average Maximum \
    --region "${REGION}" \
    --output table 2>/dev/null || true
done

# ─── [4] Cognito ──────────────────────────────────────────────────────────────
sep
echo -e "${BOLD}[4/4] Cognito: SignInSuccesses / TokenRefreshSuccesses${RESET}"
note "SignInSuccesses: TEST_PASSWORD を使った認証ありトラフィックがあれば上昇"
note "Advanced Security が無効の場合はデータが 0 または空になる (正常)"
note "SignInSuccesses が期待より少ない場合 → パスワード誤り or ユーザー未作成"
echo
for metric in SignInSuccesses TokenRefreshSuccesses; do
  echo -e "  --- ${CYAN}${metric}${RESET} ---"
  aws cloudwatch get-metric-statistics \
    --namespace "AWS/Cognito" \
    --metric-name "${metric}" \
    --dimensions "Name=UserPool,Value=${USER_POOL_ID}" \
    --start-time "${FIVE_MIN_AGO}" \
    --end-time "${NOW}" \
    --period 60 \
    --statistics Sum \
    --region "${REGION}" \
    --output table 2>/dev/null \
    || echo -e "    ${YELLOW}${metric}: データなし (Advanced Security 未有効または反映待ち)${RESET}"
done

# ─── コンソール Deep Links ────────────────────────────────────────────────────
sep
echo -e "${BOLD}コンソール Deep Links${RESET}"
BASE="https://${REGION}.console.aws.amazon.com"
if [ -n "$DASHBOARD_URL" ]; then
  echo -e "  ${GREEN}CloudWatch Dashboard${RESET} : ${DASHBOARD_URL}"
else
  echo -e "  ${GREEN}CloudWatch Dashboard${RESET} : ${BASE}/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD_NAME}"
fi
echo -e "  ${GREEN}API GW Metrics      ${RESET} : ${BASE}/apigateway/main/apis/${API_GW_ID}/stages/${STAGE}/metrics"
echo -e "  ${GREEN}Lambda Monitoring   ${RESET} : ${BASE}/lambda/home?region=${REGION}#/functions"
echo -e "  ${GREEN}DynamoDB Metrics    ${RESET} : ${BASE}/dynamodb/home?region=${REGION}#tables:selected=${DYNAMODB_TABLE_NAME};tab=monitoring"
echo -e "  ${GREEN}Log Insights        ${RESET} : ${BASE}/cloudwatch/home?region=${REGION}#logsV2:logs-insights"

# ─── 終了リマインダ ───────────────────────────────────────────────────────────
sep
echo
echo -e "${RED}${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${RESET}"
echo -e "${RED}${BOLD}  観測が終わったら必ず実行してください:     ${RESET}"
echo -e "${RED}${BOLD}    make sandbox-down-phase1               ${RESET}"
echo -e "${RED}${BOLD}  (リソースを残すと AWS 料金が発生します)  ${RESET}"
echo -e "${RED}${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${RESET}"
echo
