#!/usr/bin/env bash
# load.sh — Phase 3 SQS ロード生成
# 使い方: bash load.sh [メッセージ数=50]
set -euo pipefail

REGION="ap-northeast-1"
COUNT=${1:-50}

# ── terraform output からリソース識別子を自動取得 ──────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_CMD="terraform -chdir=${SCRIPT_DIR}"

echo "=== Phase 3 SQS Load Generator ==="
echo "識別子を terraform output から取得中..."

PRODUCER_NAME=${PRODUCER_NAME:-$(${TF_CMD} output -raw producer_name)}
QUEUE_URL=${QUEUE_URL:-$(${TF_CMD} output -raw main_queue_url)}
DLQ_URL=${DLQ_URL:-$(${TF_CMD} output -raw dlq_url)}

echo ""
echo "┌─────────────────────────────────────────────────────────┐"
echo "│  Phase 3 SQS ロード構成                                  │"
echo "├─────────────────────────────────────────────────────────┤"
printf "│  Producer Lambda  : %-36s │\n" "${PRODUCER_NAME}"
printf "│  Main Queue URL   : %-36s │\n" "...${QUEUE_URL: -36}"
printf "│  DLQ URL          : %-36s │\n" "...${DLQ_URL: -36}"
printf "│  Messages/invoke  : %-36s │\n" "${COUNT}"
echo "└─────────────────────────────────────────────────────────┘"
echo ""

# ── シナリオ1: Producer Lambda 経由で一括 SendMessage ────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[Step 1/3] Producer Lambda 経由で ${COUNT} 件を一括送信"
echo "  目的: Lambda → SQS の SendMessage フローを確認"
echo "  期待: Invocations +1, メインキューの NumberOfMessagesSent +${COUNT}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
RESP_FILE=/tmp/phase3-producer-response.json
aws lambda invoke \
  --region "${REGION}" \
  --function-name "${PRODUCER_NAME}" \
  --payload "$(printf '{"count":%d}' "${COUNT}")" \
  --cli-binary-format raw-in-base64-out \
  "${RESP_FILE}" || true

if [[ -f "${RESP_FILE}" ]]; then
  STATUS=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get('statusCode', d.get('StatusCode','?')))
" "${RESP_FILE}" 2>/dev/null || echo "?")
  echo "  → Lambda 応答 statusCode: ${STATUS}"
  echo "  → レスポンス全文:"
  python3 -m json.tool "${RESP_FILE}" 2>/dev/null || cat "${RESP_FILE}"
fi
echo ""

# ── シナリオ2: CLI から直接 SendMessage (10件バースト) ───────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[Step 2/3] CLI 直接送信 (10件バースト)"
echo "  目的: AWS CLI → SQS SendMessage の直接フローを確認"
echo "  期待: メインキューの NumberOfMessagesSent にさらに +10"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SENT_CLI=0
for i in $(seq 1 10); do
  MSG_ID=$(aws sqs send-message \
    --region "${REGION}" \
    --queue-url "${QUEUE_URL}" \
    --message-body "{\"source\":\"cli\",\"index\":${i},\"ts\":$(date +%s)}" \
    --query 'MessageId' --output text 2>/dev/null || echo "FAILED")
  if [[ "${MSG_ID}" != "FAILED" ]]; then
    SENT_CLI=$((SENT_CLI + 1))
    printf "  [%2d/10] 送信完了 MessageId: %s\n" "${i}" "${MSG_ID}"
  else
    printf "  [%2d/10] 送信失敗 (スキップ)\n" "${i}"
  fi
done
echo "  → CLI 直接送信: ${SENT_CLI}/10 件成功"
echo ""

# ── シナリオ3: 意図的失敗メッセージ → DLQ 流入を確認 ────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[Step 3/3] ポイズンメッセージ送信 (DLQ 流入テスト)"
echo "  目的: Consumer が 3 回失敗すると DLQ に転送されることを確認"
echo "  期待: maxReceiveCount=3 を超えると DLQ の"
echo "        ApproximateNumberOfMessagesVisible が増加する"
echo "  ※ Consumer が 3 回 invoke されるまで数分かかります"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SENT_POISON=0
for idx in 0 7 14; do
  MSG_ID=$(aws sqs send-message \
    --region "${REGION}" \
    --queue-url "${QUEUE_URL}" \
    --message-body "{\"index\":${idx},\"ts\":$(date +%s),\"note\":\"intentional-failure\"}" \
    --query 'MessageId' --output text 2>/dev/null || echo "FAILED")
  if [[ "${MSG_ID}" != "FAILED" ]]; then
    SENT_POISON=$((SENT_POISON + 1))
    echo "  → ポイズン index=${idx} 送信完了 MessageId: ${MSG_ID}"
  else
    echo "  → ポイズン index=${idx} 送信失敗 (スキップ)"
  fi
done
echo "  → ポイズンメッセージ: ${SENT_POISON}/3 件送信"
echo ""

# ── 完了サマリ ────────────────────────────────────────────────────────────────
TOTAL_SENT=$((SENT_CLI + SENT_POISON + COUNT))
echo "╔═════════════════════════════════════════════════════════╗"
echo "║  ロード完了サマリ                                        ║"
echo "╠═════════════════════════════════════════════════════════╣"
printf "║  Lambda 経由 (Step1) : %-5s 件                          ║\n" "${COUNT}"
printf "║  CLI 直接   (Step2) : %-5s 件 (成功: %s/10)             ║\n" "10" "${SENT_CLI}"
printf "║  ポイズン   (Step3) : %-5s 件 (成功: %s/3)              ║\n" "3" "${SENT_POISON}"
printf "║  合計送信           : %-5s 件 (概算)                    ║\n" "${TOTAL_SENT}"
echo "╠═════════════════════════════════════════════════════════╣"
echo "║  !! SQS キュー系メトリクスは 5 分粒度で CW に反映 !!    ║"
echo "║  !! Lambda メトリクスは 1 分粒度で反映されます     !!    ║"
echo "╠═════════════════════════════════════════════════════════╣"
echo "║  5 分後に以下を実行してください:                        ║"
echo "║    make sandbox-watch-phase3                            ║"
echo "╚═════════════════════════════════════════════════════════╝"
