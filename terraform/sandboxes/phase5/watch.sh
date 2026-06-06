#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REGION="us-east-1"
DASHBOARD="phase5-dashboard"

# ── 識別子を terraform output から自動取得 (env があれば env を優先) ────────────
DIST_ID=${DIST_ID:-$(terraform -chdir="${SCRIPT_DIR}" output -raw cloudfront_distribution_id)}
DIST_DOMAIN=${DIST_DOMAIN:-$(terraform -chdir="${SCRIPT_DIR}" output -raw cloudfront_domain_name)}
WAF_ACL_NAME=${WAF_ACL_NAME:-$(terraform -chdir="${SCRIPT_DIR}" output -raw waf_web_acl_name)}
WAF_ACL_ARN=${WAF_ACL_ARN:-$(terraform -chdir="${SCRIPT_DIR}" output -raw waf_web_acl_arn)}
DASHBOARD_URL=${DASHBOARD_URL:-$(terraform -chdir="${SCRIPT_DIR}" output -raw dashboard_url)}

echo "============================================================"
echo " Phase 5  CloudFront + WAF  メトリクスウォッチャー"
echo "============================================================"
echo " DistributionId : ${DIST_ID}"
echo " Domain         : https://${DIST_DOMAIN}"
echo " WAF ACL        : ${WAF_ACL_NAME}"
echo " Region         : ${REGION}"
echo ""

# ── 観察ポイントの事前説明 ─────────────────────────────────────────────────────
echo "============================================================"
echo " [観察ポイント一覧]"
echo ""
echo " 1. CF Requests (Sum)"
echo "    → load.sh が送った約 185 件が集計される"
echo "    → 最初のリクエストで MISS → 以降 HIT に切り替わる推移を確認"
echo ""
echo " 2. CacheHitRate (%)"
echo "    → 50 件の正常リクエストのうち MISS 後は HIT が続くので"
echo "      最終的に 70〜90% 程度に収束するはず"
echo ""
echo " 3. 4xxErrorRate (%)"
echo "    → Step2 (404 ×10) で上昇。総リクエストに対して数% が目安"
echo ""
echo " 4. WAF BlockedRequests (Sum)"
echo "    → Step3 SQLi/XSS でブロックが発生 (CommonRuleSet)"
echo "    → Step4 バースト後にレートリミット超過すれば RateLimit も増加"
echo ""
echo " 5. WAF AllowedRequests (Sum)"
echo "    → Blocked と合わせて全リクエスト数と一致するか確認"
echo "============================================================"
echo ""

# ── Step 0: ダッシュボード存在スモーク ───────────────────────────────────────
echo "=== Step 0: ダッシュボード存在確認 ==="
if aws cloudwatch get-dashboard \
    --region "${REGION}" \
    --dashboard-name "${DASHBOARD}" \
    --query 'DashboardName' \
    --output text 2>/dev/null | grep -q "${DASHBOARD}"; then
  echo "  [OK] ダッシュボード '${DASHBOARD}' を確認しました"
else
  echo "  [WARN] ダッシュボードが見つかりません。terraform apply 済みか確認してください。"
fi

# ── Step 1: メトリクス反映待ち ────────────────────────────────────────────────
echo ""
echo "=== Step 1: メトリクス反映待ち (3 分 / CloudFront は反映が遅い) ==="
WAIT_SECS=180
for elapsed in $(seq 0 10 $((WAIT_SECS - 1))); do
  remaining=$((WAIT_SECS - elapsed))
  printf "  待機中... あと %3d 秒\r" "${remaining}"
  sleep 10
done
echo "  [OK] 待機完了                    "
echo ""

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

echo "  集計範囲: ${START_1H}  〜  ${END_NOW}"

# ── Step 2: CloudFront リクエスト数 ───────────────────────────────────────────
echo ""
echo "=== Step 2: CF Requests (直近 1 時間 / Sum) ==="
echo "  [期待] load.sh で送った約 185 件が合計されて現れる"
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
  --output table || echo "  (データなし — メトリクス未反映の可能性)"

# ── Step 3: キャッシュヒット率 ────────────────────────────────────────────────
echo ""
echo "=== Step 3: CF CacheHitRate (直近 1 時間 / Average %) ==="
echo "  [期待] 50 件の繰り返しアクセスで HIT が増加 → 70〜90% 程度"
aws cloudwatch get-metric-statistics \
  --region "${REGION}" \
  --namespace "AWS/CloudFront" \
  --metric-name "CacheHitRate" \
  --dimensions \
    Name=DistributionId,Value="${DIST_ID}" \
    Name=Region,Value=Global \
  --start-time "${START_1H}" \
  --end-time "${END_NOW}" \
  --period 300 \
  --statistics Average \
  --output table || echo "  (データなし)"

# ── Step 4: エラー率 ───────────────────────────────────────────────────────────
echo ""
echo "=== Step 4: CF エラー率 (直近 1 時間 / Average %) ==="
echo "  [期待] 4xxErrorRate が数% 上昇 (404 ×10 の影響)"
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
    --output table || echo "  (データなし)"
done

# ── Step 5: WAF ブロック数 ──────────────────────────────────────────────────────
echo ""
echo "=== Step 5: WAF BlockedRequests (直近 1 時間 / Sum) ==="
echo "  [期待] Rule=CommonRuleSet で SQLi/XSS 分がブロック"
echo "         Rule=RateLimit   でバースト超過分がブロック"

for waf_rule in "ALL" "CommonRuleSet" "AWSManagedRulesCommonRuleSet" "RateLimit"; do
  echo "  --- Rule: ${waf_rule} ---"
  aws cloudwatch get-metric-statistics \
    --region "${REGION}" \
    --namespace "AWS/WAFV2" \
    --metric-name "BlockedRequests" \
    --dimensions \
      Name=WebACL,Value="${WAF_ACL_NAME}" \
      Name=Rule,Value="${waf_rule}" \
      Name=Region,Value=CloudFront \
    --start-time "${START_1H}" \
    --end-time "${END_NOW}" \
    --period 300 \
    --statistics Sum \
    --output table || true
done

# WAF AllowedRequests も表示
echo ""
echo "  --- AllowedRequests (Rule=ALL, 参考) ---"
aws cloudwatch get-metric-statistics \
  --region "${REGION}" \
  --namespace "AWS/WAFV2" \
  --metric-name "AllowedRequests" \
  --dimensions \
    Name=WebACL,Value="${WAF_ACL_NAME}" \
    Name=Rule,Value=ALL \
    Name=Region,Value=CloudFront \
  --start-time "${START_1H}" \
  --end-time "${END_NOW}" \
  --period 300 \
  --statistics Sum \
  --output table || true

# ── Step 6: WAF サンプリングリクエスト ────────────────────────────────────────
echo ""
echo "=== Step 6: WAF SampledRequests (直近 3 分 / CommonRuleSet) ==="
echo "  [期待] Action=BLOCK で SQLi/XSS パターンの URI が見える"
aws wafv2 get-sampled-requests \
  --region "${REGION}" \
  --web-acl-arn "${WAF_ACL_ARN}" \
  --rule-metric-name "CommonRuleSet" \
  --scope CLOUDFRONT \
  --time-window "StartTime=${START_3M_EPOCH},EndTime=${END_NOW_EPOCH}" \
  --max-items 10 \
  --output json 2>/dev/null \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
samples = data.get('SampledRequests', [])
if not samples:
    print('  (サンプルなし — load.sh を先に実行するか、3 分以上前の実行は範囲外)')
for r in samples:
    print(json.dumps({
        'Action': r.get('Action'),
        'URI':    r.get('Request', {}).get('URI'),
        'Method': r.get('Request', {}).get('Method'),
    }, ensure_ascii=False))
" || echo "  (SampledRequests の取得に失敗 — スコープまたは権限を確認)"

# ── Step 7: コンソール Deep Link ───────────────────────────────────────────────
echo ""
echo "=== Step 7: コンソール Deep Link ==="
echo ""
echo "  CloudWatch ダッシュボード:"
echo "    ${DASHBOARD_URL}"
echo ""
echo "  CloudFront メトリクス:"
echo "    https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#metricsV2:graph=~();namespace=AWS/CloudFront"
echo ""
echo "  WAF Web ACL:"
echo "    https://us-east-1.console.aws.amazon.com/wafv2/homev2/web-acls/${WAF_ACL_NAME}/overview?region=us-east-1"
echo ""
echo "  WAF ログ (CloudWatch Logs Insights):"
echo "    https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:log-groups/log-group/aws-waf-logs-phase5"

# ── 終了リマインダー ────────────────────────────────────────────────────────────
echo ""
echo "############################################################"
echo "#                                                          #"
echo "#  観測が終わったら必ず以下を実行してコストを止めてください  #"
echo "#                                                          #"
echo "#    make sandbox-down-phase5                             #"
echo "#                                                          #"
echo "#  ※ CloudFront 削除には 30〜45 分かかります              #"
echo "#                                                          #"
echo "############################################################"
