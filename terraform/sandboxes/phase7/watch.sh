#!/usr/bin/env bash
# Phase 7 watch.sh — EventBridge / Lambda CloudWatch メトリクス スナップショット
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
SANDBOX_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 識別子の自動取得（env があれば env を優先）─────────────────────────────
FUNC_NAME="${PHASE7_FUNC_NAME:-$(terraform -chdir="$SANDBOX_DIR" output -raw processor_name)}"
DLQ_URL="${PHASE7_DLQ_URL:-$(terraform -chdir="$SANDBOX_DIR" output -raw dlq_url)}"
DASHBOARD_URL="${PHASE7_DASHBOARD_URL:-$(terraform -chdir="$SANDBOX_DIR" output -raw dashboard_url 2>/dev/null || echo '')}"

# PREFIX は processor_name の末尾 -processor を除いたもの
PREFIX="${FUNC_NAME%-processor}"
RULE_NAME="${PREFIX}-processor-rule"
HEARTBEAT_RULE="${PREFIX}-heartbeat-rule"
DASHBOARD_NAME="${PREFIX}-dashboard"
DLQ_NAME="${PREFIX}-dlq"

echo "============================================================"
echo "  Phase 7 watch.sh  —  EventBridge / Lambda メトリクス確認"
echo "============================================================"
echo "  Lambda 関数   : $FUNC_NAME"
echo "  ルール (custom): $RULE_NAME"
echo "  ルール (rate)  : $HEARTBEAT_RULE"
echo "  DLQ           : $DLQ_NAME"
echo "  ダッシュボード : $DASHBOARD_NAME"
echo "  リージョン    : $REGION"
echo "============================================================"
echo ""
echo "  [INFO] CloudWatch メトリクスの反映には 1〜3 分かかる"
echo "  [INFO] rate(1 minute) ハートビートの初回発火は最大 60 秒後"
echo "  [INFO] EMF カスタムメトリクスは 2〜5 分後に反映される場合あり"
echo ""

# ── 観察ポイント（このスクリプトで何が見えるか）────────────────────────────
echo "------------------------------------------------------------"
echo "  観察ポイント (期待する動き)"
echo "------------------------------------------------------------"
echo "  Lambda Invocations  : load.sh の COUNT + heartbeat 発火数 が加算されるはず"
echo "  Lambda Errors       : 0 なら正常。1 以上なら DLQ にメッセージが積まれる"
echo "  Lambda Duration     : 初回は コールドスタート で高め、以降は低下"
echo "  FailedInvocations   : EventBridge が Lambda 呼び出しに失敗した件数 (0 が正常)"
echo "  DLQ visible msgs    : 0 が正常。retry 上限を超えた失敗イベントがここに来る"
echo "  EMF EventsProcessed : Lambda 内で emit したカスタムメトリクス (反映遅延あり)"
echo "------------------------------------------------------------"
echo ""

# ── 0. Dashboard スモークテスト ─────────────────────────────────────────────
echo "[0/5] ダッシュボードの存在確認..."
DASH_STATUS=$(aws cloudwatch get-dashboard \
  --dashboard-name "$DASHBOARD_NAME" \
  --region "$REGION" \
  --query 'DashboardName' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$DASH_STATUS" = "$DASHBOARD_NAME" ]; then
  echo "  OK: ダッシュボード '$DASHBOARD_NAME' が存在する"
else
  echo "  WARN: ダッシュボードが見つからない — make sandbox-up-phase7 で作成してください"
fi
echo ""

# ── 時刻ウィンドウ（直近 5 分）──────────────────────────────────────────────
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# macOS (BSD date) と Linux (GNU date) の両方に対応
START_TIME=$(date -u -v-5M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -d "5 minutes ago" +"%Y-%m-%dT%H:%M:%SZ")
EPOCH_START=$(date -u -v-5M +%s 2>/dev/null || date -u -d "5 minutes ago" +%s)
EPOCH_END=$(date -u +%s)

echo "  計測ウィンドウ: $START_TIME 〜 $END_TIME (--period 300)"
echo ""

# ── 1. Lambda メトリクス ──────────────────────────────────────────────────
echo "[1/5] Lambda Invocations / Errors / Duration (直近 5 分):"
for metric in Invocations Errors Duration; do
  STAT="Sum"
  [ "$metric" = "Duration" ] && STAT="Average"
  VAL=$(aws cloudwatch get-metric-statistics \
    --region "$REGION" \
    --namespace AWS/Lambda \
    --metric-name "$metric" \
    --dimensions Name=FunctionName,Value="$FUNC_NAME" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --period 300 \
    --statistics "$STAT" \
    --query 'sort_by(Datapoints, &Timestamp)[-1].'"$STAT" \
    --output text 2>/dev/null || echo "N/A")
  printf "  %-20s (%s): %s\n" "$metric" "$STAT" "$VAL"
done
echo ""

# ── 2. EventBridge FailedInvocations ─────────────────────────────────────
echo "[2/5] EventBridge FailedInvocations (ルール: $RULE_NAME):"
FAILED_INV=$(aws cloudwatch get-metric-statistics \
  --region "$REGION" \
  --namespace AWS/Events \
  --metric-name FailedInvocations \
  --dimensions Name=RuleName,Value="$RULE_NAME" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 300 \
  --statistics Sum \
  --query 'sort_by(Datapoints, &Timestamp)[-1].Sum' \
  --output text 2>/dev/null || echo "N/A")
printf "  %-20s (Sum): %s\n" "FailedInvocations" "$FAILED_INV"

# MatchedRules (ThrottledRules は別namespace なので省略可。ここでは AWS/Events のみ)
THROTTLED=$(aws cloudwatch get-metric-statistics \
  --region "$REGION" \
  --namespace AWS/Events \
  --metric-name ThrottledRules \
  --dimensions Name=RuleName,Value="$RULE_NAME" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 300 \
  --statistics Sum \
  --query 'sort_by(Datapoints, &Timestamp)[-1].Sum' \
  --output text 2>/dev/null || echo "N/A")
printf "  %-20s (Sum): %s\n" "ThrottledRules" "$THROTTLED"
echo ""

# ── 3. EMF カスタムメトリクス ────────────────────────────────────────────
echo "[3/5] EMF カスタムメトリクス Phase7/EventBridge::EventsProcessed:"
echo "      (Lambda 内で structured logging した値 — 反映に 2〜5 分かかる場合あり)"
for source_dim in "com.example.orders" "scheduler.demo"; do
  EMF_VAL=$(aws cloudwatch get-metric-statistics \
    --region "$REGION" \
    --namespace "Phase7/EventBridge" \
    --metric-name "EventsProcessed" \
    --dimensions Name=Source,Value="$source_dim" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --period 300 \
    --statistics Sum \
    --query 'sort_by(Datapoints, &Timestamp)[-1].Sum' \
    --output text 2>/dev/null || echo "N/A")
  printf "  Source=%-30s Sum: %s\n" "$source_dim" "$EMF_VAL"
done
echo ""

# ── 4. DLQ メッセージ数 ──────────────────────────────────────────────────
echo "[4/5] DLQ 滞留メッセージ数 ($DLQ_NAME):"
DLQ_COUNT=$(aws sqs get-queue-attributes \
  --region "$REGION" \
  --queue-url "$DLQ_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' \
  --output text 2>/dev/null || echo "N/A")
printf "  ApproximateNumberOfMessages: %s\n" "$DLQ_COUNT"
if [ "$DLQ_COUNT" != "0" ] && [ "$DLQ_COUNT" != "N/A" ]; then
  echo "  ** DLQ にメッセージあり — Lambda エラーかリトライ上限超え **"
fi
echo ""

# ── 5. CloudWatch Logs Insights ─────────────────────────────────────────
echo "[5/5] Lambda ログ (Insights — 直近 5 分 / EVENT 含む行):"
QUERY_ID=$(aws logs start-query \
  --region "$REGION" \
  --log-group-name "/aws/lambda/$FUNC_NAME" \
  --start-time "$EPOCH_START" \
  --end-time "$EPOCH_END" \
  --query-string 'fields @timestamp, @message | filter @message like /EVENT/ | sort @timestamp desc | limit 10' \
  --query 'queryId' \
  --output text 2>/dev/null || echo "")

if [ -n "$QUERY_ID" ]; then
  sleep 5
  aws logs get-query-results \
    --region "$REGION" \
    --query-id "$QUERY_ID" \
    --query 'results[*][?field==`@message`].value' \
    --output text 2>/dev/null || true
else
  echo "  (Insights クエリ開始に失敗。ログ未反映の可能性あり)"
fi
echo ""

# ── コンソール deep link ─────────────────────────────────────────────────
echo "============================================================"
echo "  Console deep links"
echo "------------------------------------------------------------"
echo "  Dashboard     : ${DASHBOARD_URL:-https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD_NAME}}"
echo "  EventBridge   : https://${REGION}.console.aws.amazon.com/events/home?region=${REGION}#/rules"
echo "  Archive       : https://${REGION}.console.aws.amazon.com/events/home?region=${REGION}#/archives"
echo "  Lambda        : https://${REGION}.console.aws.amazon.com/lambda/home?region=${REGION}#/functions/${FUNC_NAME}"
echo "  DLQ (SQS)     : https://${REGION}.console.aws.amazon.com/sqs/v3/home?region=${REGION}"
echo "  X-Ray traces  : https://${REGION}.console.aws.amazon.com/xray/home?region=${REGION}#/traces"
echo "============================================================"
echo ""
echo "############################################################"
echo "#                                                          #"
echo "#  IMPORTANT: rate(1 min) ハートビートは課金中です!         #"
echo "#                                                          #"
echo "#  観測が終わったら必ず実行:                                  #"
echo "#    make sandbox-down-phase7                              #"
echo "#                                                          #"
echo "############################################################"
