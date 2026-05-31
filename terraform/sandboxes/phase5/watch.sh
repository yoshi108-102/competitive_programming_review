#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REGION="us-east-1"
DASHBOARD="phase5-dashboard"

echo "INFO: CloudWatch メトリクスの反映には 1〜5 分かかります。"
echo "INFO: SQS: load.sh 実行後 5 分待ってください (--period 300)"
echo "INFO: EventBridge: rate(1 minute) は初回発火まで最大 60 秒待ってください"
echo ""

DIST_ID=$(terraform -chdir="${SCRIPT_DIR}" output -raw cloudfront_distribution_id)
WAF_ACL_NAME=$(terraform -chdir="${SCRIPT_DIR}" output -raw waf_web_acl_name)
WAF_ACL_ARN=$(terraform -chdir="${SCRIPT_DIR}" output -raw waf_web_acl_arn)

# ── Step 0: ダッシュボード存在スモーク ───────────────────────────────────────
echo "=== ダッシュボード確認 ==="
aws cloudwatch get-dashboard \
  --region "${REGION}" \
  --dashboard-name "${DASHBOARD}" \
  --query 'DashboardName' \
  --output text \
  | grep -q "${DASHBOARD}" && echo "  OK: dashboard exists" \
  || { echo "ERROR: dashboard not found"; exit 1; }

# ── Step 1: メトリクス反映待ち ────────────────────────────────────────────────
echo ""
echo "=== メトリクス反映待ち (3 分) ==="
sleep 180

# macOS / Linux 互換の date ユーティリティ
if date --version >/dev/null 2>&1; then
  # GNU date (Linux)
  START_1H=$(date -u -d '-1 hour' '+%Y-%m-%dT%H:%M:%SZ')
  END_NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  START_3M_EPOCH=$(date -u -d '-3 minutes' '+%s')
  END_NOW_EPOCH=$(date -u '+%s')
else
  # BSD date (macOS)
  START_1H=$(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ')
  END_NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  START_3M_EPOCH=$(date -u -v-3M '+%s')
  END_NOW_EPOCH=$(date -u '+%s')
fi

# ── Step 2: CloudFront リクエスト数 ───────────────────────────────────────────
echo ""
echo "=== CF Requests (直近 1 時間) ==="
aws cloudwatch get-metric-statistics \
  --region "${REGION}" \
  --namespace "AWS/CloudFront" \
  --metric-name "Requests" \
  --dimensions \
    Name=DistributionId,Value="${DIST_ID}" \
    Name=Region,Value=Global \
  --start-time "${START_1H}" \
  --end-time "${END_NOW}" \
  --period 300 \
  --statistics Sum \
  --output table

# ── Step 3: エラー率 ───────────────────────────────────────────────────────────
echo ""
echo "=== CF 4xx / 5xx / Total Error Rate ==="
for metric in "4xxErrorRate" "5xxErrorRate" "TotalErrorRate"; do
  echo "  --- ${metric} ---"
  aws cloudwatch get-metric-statistics \
    --region "${REGION}" \
    --namespace "AWS/CloudFront" \
    --metric-name "${metric}" \
    --dimensions \
      Name=DistributionId,Value="${DIST_ID}" \
      Name=Region,Value=Global \
    --start-time "${START_1H}" \
    --end-time "${END_NOW}" \
    --period 300 \
    --statistics Average \
    --output table
done

# ── Step 4: WAF ブロック数 ──────────────────────────────────────────────────────
echo ""
echo "=== WAF BlockedRequests ==="
aws cloudwatch get-metric-statistics \
  --region "${REGION}" \
  --namespace "AWS/WAFV2" \
  --metric-name "BlockedRequests" \
  --dimensions \
    Name=WebACL,Value="${WAF_ACL_NAME}" \
    Name=Rule,Value=ALL \
    Name=Region,Value=CloudFront \
  --start-time "${START_1H}" \
  --end-time "${END_NOW}" \
  --period 300 \
  --statistics Sum \
  --output table

# ── Step 5: WAF サンプリングリクエスト ────────────────────────────────────────
echo ""
echo "=== WAF Sampled Requests (直近 3 分) ==="
aws wafv2 get-sampled-requests \
  --region "${REGION}" \
  --web-acl-arn "${WAF_ACL_ARN}" \
  --rule-metric-name "CommonRuleSet" \
  --scope CLOUDFRONT \
  --time-window "StartTime=${START_3M_EPOCH},EndTime=${END_NOW_EPOCH}" \
  --max-items 5 \
  --output json \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('SampledRequests', []):
    print(json.dumps({
        'Action': r.get('Action'),
        'URI': r.get('Request', {}).get('URI'),
    }))
" || echo "  (サンプルなし または jq 未インストール)"

# ── Step 6: コンソール Deep Link ───────────────────────────────────────────────
echo ""
echo "=== コンソール Deep Link (us-east-1 固定) ==="
echo "CloudFront メトリクス:"
echo "  https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#metricsV2:graph=~();namespace=AWS/CloudFront"
echo "WAF ダッシュボード:"
echo "  https://us-east-1.console.aws.amazon.com/wafv2/homev2/web-acls?region=us-east-1"
echo "ダッシュボード:"
echo "  https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=${DASHBOARD}"

echo ""
echo "観測完了。費用を抑えるため:"
echo "  make sandbox-down-phase5"
echo "を実行してください (CF 削除には 30〜45 分かかります)。"
