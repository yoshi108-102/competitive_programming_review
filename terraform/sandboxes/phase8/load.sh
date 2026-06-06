#!/usr/bin/env bash
# load.sh — Phase8 Step Functions load generator
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-1}"
TF_DIR="/Users/yoshi/competitive_programming_review/terraform/sandboxes/phase8"

# ---------------------------------------------------------------------------
# 識別子の自動取得（env 優先、なければ terraform output から取得）
# ---------------------------------------------------------------------------
echo "===================================================================="
echo " Phase8 Step Functions — Load Generator"
echo "===================================================================="
echo ""
echo "[1/3] terraform output から State Machine ARN を取得..."
SFN_ARN="${SFN_ARN:-$(terraform -chdir="$TF_DIR" output -raw state_machine_arn 2>/dev/null)}"

if [[ -z "$SFN_ARN" ]]; then
  echo "ERROR: state_machine_arn を取得できませんでした。" >&2
  echo "       terraform apply が完了しているか確認してください: make sandbox-up-phase8" >&2
  exit 1
fi

SM_NAME=$(terraform -chdir="$TF_DIR" output -raw state_machine_name 2>/dev/null || echo "phase8-order-saga")
echo "    State Machine : $SM_NAME"
echo "    ARN           : $SFN_ARN"
echo "    Region        : $REGION"
echo ""

# ---------------------------------------------------------------------------
# シナリオ別カウント管理
# ---------------------------------------------------------------------------
TOTAL=0
HAPPY_COUNT=10
FAIL_COUNT=3
INV_COUNT=2

echo "[2/3] 実行を送信します（合計 $((HAPPY_COUNT + FAIL_COUNT + INV_COUNT)) 件）..."
echo ""

# --- Scenario 1: Happy path ------------------------------------------------
echo "  [Scenario 1] Happy path — 正常注文 ($HAPPY_COUNT 件)"
echo "    amount: 1000〜9999, customer_id: cust-001, items: SKU-A x2"
echo "    期待動作: ValidateOrder → ChargePayment → UpdateInventory → NotifyCustomer → SUCCEEDED"
echo ""
for i in $(seq 1 $HAPPY_COUNT); do
  ORDER_ID="order-$(date +%s)-${i}"
  AMOUNT=$(( (RANDOM % 9000) + 1000 ))
  INPUT=$(printf '{"order_id":"%s","amount":%d,"customer_id":"cust-001","items":[{"sku":"SKU-A","qty":2}]}' \
    "$ORDER_ID" "$AMOUNT")
  EXEC_ARN=$(aws stepfunctions start-execution \
    --state-machine-arn "$SFN_ARN" \
    --name "happy-${ORDER_ID}" \
    --input "$INPUT" \
    --region "$REGION" \
    --query "executionArn" \
    --output text) || true
  TOTAL=$(( TOTAL + 1 ))
  printf "    [%2d/%2d] %-40s amount=%d  arn=...%s\n" \
    "$TOTAL" "$((HAPPY_COUNT + FAIL_COUNT + INV_COUNT))" \
    "happy-${ORDER_ID}" "$AMOUNT" "${EXEC_ARN: -20}" || true
  sleep 0.3
done
echo "    Scenario 1 完了: ${HAPPY_COUNT} 件送信"
echo ""

# --- Scenario 2: Compensation path ----------------------------------------
echo "  [Scenario 2] Compensation path — amount=0 で validate_order 失敗 ($FAIL_COUNT 件)"
echo "    期待動作: ValidateOrder が FAILED → CompensateOrder が起動 → 補償完了"
echo ""
for i in $(seq 1 $FAIL_COUNT); do
  ORDER_ID="fail-$(date +%s)-${i}"
  INPUT=$(printf '{"order_id":"%s","amount":0,"customer_id":"cust-bad","items":[]}' "$ORDER_ID")
  EXEC_ARN=$(aws stepfunctions start-execution \
    --state-machine-arn "$SFN_ARN" \
    --name "fail-${ORDER_ID}" \
    --input "$INPUT" \
    --region "$REGION" \
    --query "executionArn" \
    --output text) || true
  TOTAL=$(( TOTAL + 1 ))
  printf "    [%2d/%2d] %-40s amount=0    arn=...%s\n" \
    "$TOTAL" "$((HAPPY_COUNT + FAIL_COUNT + INV_COUNT))" \
    "fail-${ORDER_ID}" "${EXEC_ARN: -20}" || true
  sleep 0.3
done
echo "    Scenario 2 完了: ${FAIL_COUNT} 件送信"
echo ""

# --- Scenario 3: Inventory shortage ----------------------------------------
echo "  [Scenario 3] Inventory shortage — qty=9999 で update_inventory 失敗 ($INV_COUNT 件)"
echo "    期待動作: UpdateInventory が FAILED → CompensateOrder が起動 → 在庫補償"
echo ""
for i in $(seq 1 $INV_COUNT); do
  ORDER_ID="inv-$(date +%s)-${i}"
  INPUT=$(printf '{"order_id":"%s","amount":5000,"customer_id":"cust-002","items":[{"sku":"SKU-RARE","qty":9999}]}' \
    "$ORDER_ID")
  EXEC_ARN=$(aws stepfunctions start-execution \
    --state-machine-arn "$SFN_ARN" \
    --name "inv-${ORDER_ID}" \
    --input "$INPUT" \
    --region "$REGION" \
    --query "executionArn" \
    --output text) || true
  TOTAL=$(( TOTAL + 1 ))
  printf "    [%2d/%2d] %-40s qty=9999   arn=...%s\n" \
    "$TOTAL" "$((HAPPY_COUNT + FAIL_COUNT + INV_COUNT))" \
    "inv-${ORDER_ID}" "${EXEC_ARN: -20}" || true
  sleep 0.3
done
echo "    Scenario 3 完了: ${INV_COUNT} 件送信"
echo ""

# ---------------------------------------------------------------------------
# 送信直後の実行一覧（SFN API 直接）
# ---------------------------------------------------------------------------
echo "[3/3] 送信直後の実行状況を確認（SFN API から直接取得）..."
echo ""
aws stepfunctions list-executions \
  --state-machine-arn "$SFN_ARN" \
  --region "$REGION" \
  --max-results 20 \
  --query "executions[*].{Name:name,Status:status,Started:startDate}" \
  --output table || true

echo ""
echo "===================================================================="
echo " 送信完了: 合計 ${TOTAL} 件"
echo "   - Happy path  : ${HAPPY_COUNT} 件 (SUCCEEDED 期待)"
echo "   - Comp. path  : ${FAIL_COUNT} 件 (FAILED + CompensateOrder 期待)"
echo "   - Inventory   : ${INV_COUNT} 件 (FAILED + CompensateOrder 期待)"
echo ""
echo " CloudWatch メトリクスの反映には 1〜2 分かかります。"
echo " 次のコマンドで観察してください:"
echo ""
echo "   make sandbox-watch-phase8"
echo "===================================================================="
