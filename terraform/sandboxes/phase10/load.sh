#!/usr/bin/env bash
# load.sh — Phase 10 SNS load generator
set -euo pipefail

REGION=${AWS_REGION:-ap-northeast-1}
TF_DIR=/Users/yoshi/competitive_programming_review/terraform/sandboxes/phase10

# 識別子を terraform output から自動取得（env があれば優先）
TOPIC_ARN=${TOPIC_ARN:-$(terraform -chdir="$TF_DIR" output -raw orders_topic_arn)}

echo "============================================================"
echo "  Phase 10 SNS Load Generator"
echo "============================================================"
echo "  Region    : $REGION"
echo "  Topic ARN : $TOPIC_ARN"
echo "============================================================"
echo ""

TOTAL=0
FAILED=0

publish() {
  local order_type=$1
  local order_id="ORD-$(date +%s%N | tail -c 8)"
  local amount=$(( RANDOM % 9000 + 1000 ))
  local msg_id
  msg_id=$(aws sns publish \
    --region "$REGION" \
    --topic-arn "$TOPIC_ARN" \
    --message "{\"order_id\":\"$order_id\",\"amount\":$amount}" \
    --message-attributes "{
      \"order_type\":{\"DataType\":\"String\",\"StringValue\":\"$order_type\"}
    }" \
    --subject "New Order" \
    --query 'MessageId' --output text 2>/dev/null) || { FAILED=$(( FAILED + 1 )); echo "    [WARN] publish failed (order_type=$order_type)"; return; }
  TOTAL=$(( TOTAL + 1 ))
  echo "    [OK] order_id=$order_id  type=$order_type  amount=$amount  MessageId=$msg_id"
}

# ------------------------------------------------------------------
# (1) standard x10 → fulfillment + analytics キューに届く
# ------------------------------------------------------------------
echo "[1/5] Publishing 10 standard orders"
echo "      宛先: fulfillment キュー + analytics キュー（filter: standard|express）"
for i in $(seq 1 10); do
  publish "standard"
  sleep 0.2
done
echo "      → 計10件送信完了"
echo ""

# ------------------------------------------------------------------
# (2) express x5 → fulfillment + analytics + Lambda notifier に届く
# ------------------------------------------------------------------
echo "[2/5] Publishing 5 express orders"
echo "      宛先: fulfillment + analytics + Lambda notifier（filter: express のみ）"
for i in $(seq 1 5); do
  publish "express"
  sleep 0.2
done
echo "      → 計5件送信完了"
echo ""

# ------------------------------------------------------------------
# (3) wholesale x3 → analytics + wholesale キューに届く
# ------------------------------------------------------------------
echo "[3/5] Publishing 3 wholesale orders"
echo "      宛先: wholesale + analytics キュー（filter: wholesale）"
for i in $(seq 1 3); do
  publish "wholesale"
  sleep 0.2
done
echo "      → 計3件送信完了"
echo ""

# ------------------------------------------------------------------
# (4) unknown_type x2 → analytics キューのみ（filter なし subscription）
# ------------------------------------------------------------------
echo "[4/5] Publishing 2 UNKNOWN orders"
echo "      宛先: analytics キューのみ（他 subscription は filter で弾く）"
echo "      NumberOfNotificationsFilteredOut が上がるはず"
for i in $(seq 1 2); do
  publish "unknown_type"
  sleep 0.2
done
echo "      → 計2件送信完了"
echo ""

# ------------------------------------------------------------------
# (5) malformed payload → Lambda が JSON parse エラー → DLQ 行き
# ------------------------------------------------------------------
echo "[5/5] Publishing 1 malformed payload (DLQ test)"
echo "      Lambda notifier が JSON parse 失敗 → maxReceiveCount 超過で DLQ へ"
aws sns publish \
  --region "$REGION" \
  --topic-arn "$TOPIC_ARN" \
  --message "NOT_JSON" \
  --message-attributes "{
    \"order_type\":{\"DataType\":\"String\",\"StringValue\":\"express\"}
  }" \
  --query 'MessageId' --output text \
  && TOTAL=$(( TOTAL + 1 )) \
  || { FAILED=$(( FAILED + 1 )); echo "    [WARN] malformed publish failed"; true; }
echo ""

# ------------------------------------------------------------------
# 結果サマリー
# ------------------------------------------------------------------
echo "============================================================"
echo "  送信完了サマリー"
echo "  成功: $TOTAL 件  失敗: $FAILED 件"
echo "============================================================"
echo ""
echo "  CloudWatch メトリクスの反映には 数分（最大 5 分）かかります。"
echo ""
echo "  次のステップ:"
echo "    make sandbox-watch-phase10"
echo ""
echo "  または 3〜5 分後に手動で:"
echo "    bash $TF_DIR/watch.sh"
echo "============================================================"
