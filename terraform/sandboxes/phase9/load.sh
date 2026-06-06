#!/usr/bin/env bash
# load.sh — Phase9 X-Ray アクティビティ生成
# 無入力で動く: 識別子は terraform output から自動取得
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}"

echo "================================================================"
echo "  Phase9 ロード生成 — X-Ray トレースを作成します"
echo "================================================================"
echo ""
echo "  サービス : X-Ray / ServiceLens"
echo "  リージョン: ${REGION}"
echo ""

# ── terraform output から識別子を自動取得 ─────────────────────────────────
echo ">>> terraform output から識別子を取得中..."

API_URL="${API_URL:-$(terraform -chdir="${TF_DIR}" output -raw api_url)}"
QUEUE_URL="${QUEUE_URL:-$(terraform -chdir="${TF_DIR}" output -raw sqs_url)}"
PRODUCER_FN="${PRODUCER_FN:-$(terraform -chdir="${TF_DIR}" output -raw producer_function_name)}"

echo ""
echo "  API_URL      : ${API_URL}"
echo "  QUEUE_URL    : ${QUEUE_URL}"
echo "  PRODUCER_FN  : ${PRODUCER_FN}"
echo ""

# ── シナリオ1: 正常系 POST /items を 20回 ──────────────────────────────────
echo "----------------------------------------------------------------"
echo " [1/4]  正常系: POST /items  x20"
echo "        狙い: producer → DynamoDB/SQS のトレースチェーンを生成"
echo "----------------------------------------------------------------"
OK_COUNT=0
ERR_COUNT=0
for i in $(seq 1 20); do
  STATUS=$(curl -s -X POST "${API_URL}/items" \
    -H "Content-Type: application/json" \
    -d "{\"message\": \"load-test-${i}\"}" \
    -o /dev/null -w "%{http_code}" || echo "000")
  if [ "${STATUS}" = "200" ] || [ "${STATUS}" = "201" ]; then
    printf "  %2d/%d  HTTP %s  ✓\n" "${i}" 20 "${STATUS}"
    OK_COUNT=$((OK_COUNT + 1))
  else
    printf "  %2d/%d  HTTP %s  !\n" "${i}" 20 "${STATUS}"
    ERR_COUNT=$((ERR_COUNT + 1))
  fi
  sleep 0.3
done
echo ""
echo "  >>> 正常系完了: 成功=${OK_COUNT}  失敗/その他=${ERR_COUNT}"
echo ""

# ── シナリオ2: Lambda 直接 invoke (コールドスタート観測) ──────────────────
echo "----------------------------------------------------------------"
echo " [2/4]  コールドスタート誘発: Lambda 直接 invoke"
echo "        狙い: Init Duration セグメントを X-Ray に出す"
echo "----------------------------------------------------------------"
aws lambda invoke \
  --function-name "${PRODUCER_FN}" \
  --payload '{"httpMethod":"POST","body":"{\"message\":\"cold-start-test\"}","headers":{"Content-Type":"application/json"}}' \
  --cli-binary-format raw-in-base64-out \
  --region "${REGION}" \
  /tmp/phase9-invoke-out.json > /dev/null || true
echo "  invoke レスポンス:"
python3 -m json.tool /tmp/phase9-invoke-out.json 2>/dev/null \
  | sed 's/^/    /' || cat /tmp/phase9-invoke-out.json | sed 's/^/    /'
echo ""

# ── シナリオ3: エラー誘発 (不正ペイロードで X-Ray にエラーセグメントを生成) ──
echo "----------------------------------------------------------------"
echo " [3/4]  エラー誘発: 壊れた JSON  x5"
echo "        狙い: X-Ray のエラーセグメント (Fault/Error) を生成"
echo "              ServiceLens でエラーレートが色付き表示される"
echo "----------------------------------------------------------------"
for i in $(seq 1 5); do
  STATUS=$(curl -s -X POST "${API_URL}/items" \
    -H "Content-Type: application/json" \
    -d "NOT_VALID_JSON" \
    -o /dev/null -w "%{http_code}" || echo "000")
  printf "  error-%d: HTTP %s\n" "${i}" "${STATUS}"
  sleep 0.2
done
echo ""
echo "  >>> エラー誘発完了 (4xx/5xx が X-Ray Fault として記録されます)"
echo ""

# ── シナリオ4: SQS 直接送信 (consumer Lambda のトレースも観測) ────────────
echo "----------------------------------------------------------------"
echo " [4/4]  SQS 直接送信  x5  (consumer Lambda のトレースを生成)"
echo "        狙い: SQS → consumer の非同期トレース伝播を確認"
echo "----------------------------------------------------------------"
SQS_COUNT=0
for i in $(seq 1 5); do
  MSG_ID=$(aws sqs send-message \
    --queue-url "${QUEUE_URL}" \
    --message-body "{\"item_id\": \"manual-$(date +%s)-${i}\"}" \
    --region "${REGION}" \
    --query 'MessageId' --output text 2>/dev/null || echo "ERROR")
  if [ "${MSG_ID}" != "ERROR" ]; then
    echo "  sent [${i}/5]: MessageId = ${MSG_ID}"
    SQS_COUNT=$((SQS_COUNT + 1))
  else
    echo "  sent [${i}/5]: 送信失敗"
  fi
  sleep 0.5
done
echo ""
echo "  >>> SQS 送信完了: ${SQS_COUNT}/5 件"
echo ""

# ── 完了サマリ ──────────────────────────────────────────────────────────────
echo "================================================================"
echo "  ロード完了サマリ"
echo "================================================================"
echo ""
echo "  シナリオ1 (正常系 POST)  : ${OK_COUNT}/20 件 成功"
echo "  シナリオ2 (コールドスタート): Lambda invoke 1 回"
echo "  シナリオ3 (エラー誘発)   :  5 件"
echo "  シナリオ4 (SQS 直送)    : ${SQS_COUNT}/5 件 送信"
echo ""
echo "  X-Ray にトレースが届くまで 1-3 分かかります。"
echo "  consumer Lambda の SQS 処理もその後 30-60 秒以内に完了します。"
echo ""
echo "  *** メトリクス反映を待ってから以下を実行してください ***"
echo ""
echo "      make sandbox-watch-phase9"
echo ""
echo "================================================================"
