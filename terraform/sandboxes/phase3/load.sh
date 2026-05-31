#!/usr/bin/env bash
# load.sh — Phase 3 SQS ロード生成
# 使い方: bash load.sh [メッセージ数=50]
set -euo pipefail

REGION="ap-northeast-1"
COUNT=${1:-50}

# ── terraform output からリソース名を取得 ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCER_NAME=$(terraform -chdir="${SCRIPT_DIR}" output -raw producer_name)
QUEUE_URL=$(terraform -chdir="${SCRIPT_DIR}" output -raw main_queue_url)
DLQ_URL=$(terraform -chdir="${SCRIPT_DIR}" output -raw dlq_url)

echo "=== Phase 3 SQS Load Generator ==="
echo "Producer Lambda : ${PRODUCER_NAME}"
echo "Main Queue URL  : ${QUEUE_URL}"
echo "DLQ URL         : ${DLQ_URL}"
echo "Messages/invoke : ${COUNT}"

# ── シナリオ1: Producer Lambda 経由で一括 SendMessage ────────────────────────
echo ""
echo "[Step 1] Invoking producer Lambda (count=${COUNT})..."
aws lambda invoke \
  --region "${REGION}" \
  --function-name "${PRODUCER_NAME}" \
  --payload "$(printf '{"count":%d}' "${COUNT}")" \
  --cli-binary-format raw-in-base64-out \
  /tmp/phase3-producer-response.json
cat /tmp/phase3-producer-response.json
echo ""

# ── シナリオ2: CLI から直接 SendMessage (10件バースト) ───────────────────────
echo "[Step 2] Direct CLI send (10 messages burst)..."
for i in $(seq 1 10); do
  aws sqs send-message \
    --region "${REGION}" \
    --queue-url "${QUEUE_URL}" \
    --message-body "{\"source\":\"cli\",\"index\":${i},\"ts\":$(date +%s)}" \
    --query 'MessageId' --output text
done

# ── シナリオ3: 意図的失敗メッセージ → DLQ 流入を確認 ────────────────────────
echo ""
echo "[Step 3] Sending poison messages (index=0,7,14) to trigger DLQ..."
for idx in 0 7 14; do
  aws sqs send-message \
    --region "${REGION}" \
    --queue-url "${QUEUE_URL}" \
    --message-body "{\"index\":${idx},\"ts\":$(date +%s),\"note\":\"intentional-failure\"}" \
    --query 'MessageId' --output text
done

# ── !! 重要: SQS メトリクスは 5 分粒度 !! ─────────────────────────────────────
echo ""
echo "==========================================================="
echo "  !! SQS キュー系メトリクス(ApproximateNumberOfMessages*) は"
echo "  !! 5分粒度で CloudWatch に反映されます。"
echo "  !! watch.sh の実行は 5 分後以降にしてください。"
echo "==========================================================="
echo "  Lambda の Invocations/Errors は 1 分粒度で反映されます。"
echo "  DLQ への流入確認は maxReceiveCount=3 回失敗後なので"
echo "  consumer が 3 回 invoke されるまで数分かかります。"
echo "==========================================================="
echo ""
echo "5分後に ./watch.sh を実行してください。"
