#!/usr/bin/env bash
# Phase 7 load generator — EventBridge / Lambda
# Usage: ./load.sh [count=10]
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
SANDBOX_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 識別子の自動取得（env があれば env を優先）─────────────────────────────
BUS_NAME="${PHASE7_BUS_NAME:-$(terraform -chdir="$SANDBOX_DIR" output -raw bus_name)}"
FUNC_NAME="${PHASE7_FUNC_NAME:-$(terraform -chdir="$SANDBOX_DIR" output -raw processor_name)}"
COUNT="${1:-10}"

# PREFIX は processor_name の末尾 -processor を除いたもの
PREFIX="${FUNC_NAME%-processor}"
RULE_NAME="${PREFIX}-processor-rule"
HEARTBEAT_RULE="${PREFIX}-heartbeat-rule"

echo "============================================================"
echo "  Phase 7 load.sh  —  EventBridge カスタムイベント送信"
echo "============================================================"
echo "  バス名      : $BUS_NAME"
echo "  Lambda 関数 : $FUNC_NAME"
echo "  ルール      : $RULE_NAME"
echo "  ハートビート: $HEARTBEAT_RULE (rate=1 min, default bus)"
echo "  リージョン  : $REGION"
echo "  送信件数    : $COUNT 件 (order.created) + 3 件 (no-match)"
echo "============================================================"
echo ""

# ── 1. カスタムイベント送信: order.created → ルールにマッチして Lambda 起動 ─
echo "[1/3] order.created イベントを $COUNT 件送信中..."
echo "      EventBridge はリクエスト単位で課金。バス側でルール評価が行われる。"
echo ""

SUCCESS=0
FAIL=0
for i in $(seq 1 "$COUNT"); do
  ORDER_ID="order-$(date +%s)-${i}"
  AMOUNT=$((RANDOM % 10000))
  FAILED_COUNT=$(aws events put-events \
    --region "$REGION" \
    --entries "[
      {
        \"EventBusName\": \"$BUS_NAME\",
        \"Source\": \"com.example.orders\",
        \"DetailType\": \"order.created\",
        \"Detail\": \"{\\\"orderId\\\": \\\"$ORDER_ID\\\", \\\"amount\\\": $AMOUNT}\",
        \"Resources\": []
      }
    ]" \
    --query 'FailedEntryCount' \
    --output text 2>/dev/null || echo "ERR")

  if [ "$FAILED_COUNT" = "0" ]; then
    echo "  [$i/$COUNT] OK  orderId=$ORDER_ID  amount=$AMOUNT 円"
    SUCCESS=$((SUCCESS + 1))
  else
    echo "  [$i/$COUNT] FAIL  orderId=$ORDER_ID  FailedEntryCount=$FAILED_COUNT"
    FAIL=$((FAIL + 1))
  fi
  sleep 0.5
done

echo ""
echo "  結果: 成功 $SUCCESS 件 / 失敗 $FAIL 件"
echo ""

# ── 2. ルールにマッチしないイベント（観察用: MatchedRules=0 の挙動確認）──
echo "[2/3] ルール不一致イベントを 3 件送信 (source=com.example.inventory)..."
echo "      これらは Lambda に届かない。EventBridge が静かに捨てるのを観察する。"
echo ""

for i in 1 2 3; do
  aws events put-events \
    --region "$REGION" \
    --entries "[
      {
        \"EventBusName\": \"$BUS_NAME\",
        \"Source\": \"com.example.inventory\",
        \"DetailType\": \"stock.updated\",
        \"Detail\": \"{\\\"sku\\\": \\\"SKU-$i\\\"}\"
      }
    ]" \
    --query 'FailedEntryCount' \
    --output text > /dev/null 2>&1 || true
  echo "  [no-match $i/3] sent  (detail-type=stock.updated, pattern 不一致)"
done

echo ""

# ── 3. Lambda 直接 invoke（EventBridge をバイパス。コールドスタート観察用）──
echo "[3/3] Lambda を直接 invoke (コールドスタート / ログ末尾を確認)..."
echo "      EventBridge 経由ではなく Lambda API を直接呼ぶ。"
echo ""

aws lambda invoke \
  --region "$REGION" \
  --function-name "$FUNC_NAME" \
  --payload '{"source":"load.sh","detail-type":"DirectInvoke","detail":{"test":true}}' \
  --log-type Tail \
  --query 'LogResult' \
  --output text \
  /dev/null 2>/dev/null \
  | base64 -d 2>/dev/null | tail -5 || true

echo ""
echo "============================================================"
echo "  load.sh 完了"
echo ""
echo "  次のステップ:"
echo "    rate(1 minute) ハートビートの初回発火には最大 60 秒かかる。"
echo "    CloudWatch メトリクスの反映には 1〜3 分かかる。"
echo ""
echo "  メトリクス確認:"
echo "    make sandbox-watch-phase7"
echo ""
echo "  REMINDER: ハートビートルールは課金が継続するため、"
echo "  観測が終わったら必ず make sandbox-down-phase7 を実行！"
echo "============================================================"
