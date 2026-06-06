#!/usr/bin/env bash
# watch.sh — Phase 3 SQS メトリクス観測
# 使い方: bash watch.sh  (または make sandbox-watch-phase3)
# 前提: load.sh 実行後、最低 5 分待ってから実行すること (SQS は 5 分粒度)
set -euo pipefail

REGION="ap-northeast-1"

# ── terraform output からリソース識別子を自動取得 ──────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_CMD="terraform -chdir=${SCRIPT_DIR}"

echo "=== Phase 3 SQS 観測レポート ==="
echo "識別子を terraform output から取得中..."

MAIN_QUEUE_URL=${MAIN_QUEUE_URL:-$(${TF_CMD} output -raw main_queue_url)}
DLQ_URL=${DLQ_URL:-$(${TF_CMD} output -raw dlq_url)}
CONSUMER_FN=${CONSUMER_FN:-$(${TF_CMD} output -raw consumer_name)}
DASHBOARD=${DASHBOARD:-$(${TF_CMD} output -raw dashboard_name)}
DASHBOARD_URL=${DASHBOARD_URL:-$(${TF_CMD} output -raw dashboard_url)}

# キュー名 (URL の末尾) を抽出
MAIN_QUEUE="${MAIN_QUEUE:-${MAIN_QUEUE_URL##*/}}"
DLQ="${DLQ:-${DLQ_URL##*/}}"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
        date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)

echo ""
echo "┌─────────────────────────────────────────────────────────┐"
echo "│  Phase 3 SQS 観測構成                                    │"
echo "├─────────────────────────────────────────────────────────┤"
printf "│  Main Queue  : %-41s │\n" "${MAIN_QUEUE}"
printf "│  DLQ         : %-41s │\n" "${DLQ}"
printf "│  Consumer Fn : %-41s │\n" "${CONSUMER_FN}"
printf "│  Dashboard   : %-41s │\n" "${DASHBOARD}"
printf "│  観測ウィンドウ: %s ～                         │\n" "${START}"
printf "│               %s (UTC)                    │\n" "${NOW}"
echo "└─────────────────────────────────────────────────────────┘"
echo ""

# ── (1) ダッシュボード存在確認 (スモークテスト) ──────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[Smoke] CloudWatch ダッシュボード存在確認"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
DASH_CHECK=$(aws cloudwatch get-dashboard \
  --region "${REGION}" \
  --dashboard-name "${DASHBOARD}" \
  --query 'DashboardName' --output text 2>&1 || true)
if echo "${DASH_CHECK}" | grep -q "${DASHBOARD}"; then
  echo "  OK: ダッシュボード '${DASHBOARD}' が存在します"
else
  echo "  WARN: ダッシュボードが見つかりません (apply が必要かもしれません)"
  echo "  詳細: ${DASH_CHECK}"
fi
echo ""

# ── (2) SQS メトリクス反映待ち ───────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[待機] SQS メトリクス反映バッファ (30 秒)"
echo "  SQS キュー系は 5 分粒度。load.sh から 5 分以上経過してから"
echo "  watch.sh を実行してください。このバッファは最終調整用です。"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
sleep 30
echo "  待機完了。メトリクス取得を開始します..."
echo ""

# ── (3a) SQS キュー深さ: メインキュー ────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[SQS Main] ApproximateNumberOfMessagesVisible (キュー深さ)"
echo "  観察ポイント: load.sh 実行直後はメッセージが積まれるため"
echo "  値が増加。Consumer が処理すると減少する。"
echo "  5 分粒度のため、最大1ポイントしか見えない場合があります。"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
aws cloudwatch get-metric-statistics \
  --region "${REGION}" \
  --namespace AWS/SQS \
  --metric-name ApproximateNumberOfMessagesVisible \
  --dimensions Name=QueueName,Value="${MAIN_QUEUE}" \
  --start-time "${START}" --end-time "${NOW}" \
  --period 300 \
  --statistics Maximum \
  --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Max:Maximum}' \
  --output table || true
echo ""

# ── (3b) SQS キュー深さ: DLQ ─────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[SQS DLQ] ApproximateNumberOfMessagesVisible (DLQ 滞留)"
echo "  観察ポイント: maxReceiveCount=3 回失敗したメッセージが流入。"
echo "  load.sh のポイズンメッセージ (index=0,7,14) が Consumer に"
echo "  3 回受信された後にここへ転送されます (数分後に反映)。"
echo "  DLQ の値が増えていれば再試行 → 転送の仕組みが動いています。"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
aws cloudwatch get-metric-statistics \
  --region "${REGION}" \
  --namespace AWS/SQS \
  --metric-name ApproximateNumberOfMessagesVisible \
  --dimensions Name=QueueName,Value="${DLQ}" \
  --start-time "${START}" --end-time "${NOW}" \
  --period 300 \
  --statistics Maximum \
  --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Max:Maximum}' \
  --output table || true
echo ""

# ── (3c) SQS 送受信スループット ──────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[SQS Main] 送受信スループット (5 分粒度 Sum)"
echo "  観察ポイント:"
echo "    NumberOfMessagesSent   → Producer が送った件数 (Load Step1+2 合計)"
echo "    NumberOfMessagesDeleted → Consumer が正常処理して削除した件数"
echo "  Sent > Deleted なら処理待ちが残っている。"
echo "  Sent ≒ Deleted なら Consumer がほぼリアルタイムで消化できている。"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for metric in NumberOfMessagesSent NumberOfMessagesDeleted; do
  echo "  ▶ ${metric}:"
  aws cloudwatch get-metric-statistics \
    --region "${REGION}" \
    --namespace AWS/SQS \
    --metric-name "${metric}" \
    --dimensions Name=QueueName,Value="${MAIN_QUEUE}" \
    --start-time "${START}" --end-time "${NOW}" \
    --period 300 --statistics Sum \
    --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Sum:Sum}' \
    --output table || true
  echo ""
done

# ── (4) Lambda Consumer メトリクス (1分粒度) ─────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[Lambda Consumer] Invocations / Errors (1 分粒度 Sum)"
echo "  観察ポイント:"
echo "    Invocations → SQS トリガーで Consumer が呼ばれた回数"
echo "    Errors      → 失敗回数。ポイズンメッセージは最大3回再試行"
echo "                  されるため Errors が複数カウントされます。"
echo "  Errors / Invocations の比率がエラー率 (高ければ DLQ に流入)。"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for metric in Invocations Errors; do
  echo "  ▶ ${metric}:"
  aws cloudwatch get-metric-statistics \
    --region "${REGION}" \
    --namespace AWS/Lambda \
    --metric-name "${metric}" \
    --dimensions Name=FunctionName,Value="${CONSUMER_FN}" \
    --start-time "${START}" --end-time "${NOW}" \
    --period 60 --statistics Sum \
    --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Sum:Sum}' \
    --output table || true
  echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[Lambda Consumer] Duration (1 分粒度)"
echo "  観察ポイント: p50 と p99 の乖離が大きければ処理時間のばらつき"
echo "  が大きい。visibility_timeout (30 秒) を超えると再受信されるため"
echo "  Duration が 30 秒に近づいていたら設定見直しのサイン。"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for stat in p50 p99; do
  echo "  ▶ Duration ${stat}:"
  aws cloudwatch get-metric-statistics \
    --region "${REGION}" \
    --namespace AWS/Lambda \
    --metric-name Duration \
    --dimensions Name=FunctionName,Value="${CONSUMER_FN}" \
    --start-time "${START}" --end-time "${NOW}" \
    --period 60 --statistics "${stat}" \
    --query "sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,${stat}:${stat}}" \
    --output table 2>/dev/null || true
  echo ""
done

# ── (5) コンソール deep link ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[Deep Link] コンソール直接リンク"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

MAIN_ENCODED=$(python3 -c \
  "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
  "${MAIN_QUEUE}" 2>/dev/null || echo "${MAIN_QUEUE}")
DLQ_ENCODED=$(python3 -c \
  "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
  "${DLQ}" 2>/dev/null || echo "${DLQ}")

echo "  CloudWatch ダッシュボード:"
echo "    ${DASHBOARD_URL}"
echo ""
echo "  SQS メインキュー (メッセージ数・In Flight を確認):"
echo "    https://ap-northeast-1.console.aws.amazon.com/sqs/v3/home?region=ap-northeast-1#/queues/${MAIN_ENCODED}"
echo ""
echo "  SQS DLQ (滞留メッセージを確認):"
echo "    https://ap-northeast-1.console.aws.amazon.com/sqs/v3/home?region=ap-northeast-1#/queues/${DLQ_ENCODED}"
echo ""
echo "  Lambda Consumer ログ (再試行ログを確認):"
echo "    https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#logsV2:log-groups/log-group/\$252Faws\$252Flambda\$252F${CONSUMER_FN}"
echo ""

# ── 末尾リマインダ ────────────────────────────────────────────────────────────
echo "╔═════════════════════════════════════════════════════════╗"
echo "║                                                         ║"
echo "║   !!  観測が終わったら必ず teardown してください  !!    ║"
echo "║                                                         ║"
echo "║      make sandbox-down-phase3                           ║"
echo "║                                                         ║"
echo "║   放置すると SQS / KMS / Lambda の待機コストが          ║"
echo "║   積み上がります。忘れずに実行してください。            ║"
echo "║                                                         ║"
echo "╚═════════════════════════════════════════════════════════╝"
