#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 識別子を terraform output から自動取得 (env があれば env を優先) ────────────
DIST_DOMAIN=${DIST_DOMAIN:-$(terraform -chdir="${SCRIPT_DIR}" output -raw cloudfront_domain_name)}
DIST_ID=${DIST_ID:-$(terraform -chdir="${SCRIPT_DIR}" output -raw cloudfront_distribution_id)}
ORIGIN_BUCKET=${ORIGIN_BUCKET:-$(terraform -chdir="${SCRIPT_DIR}" output -raw origin_bucket_name)}

echo "============================================================"
echo " Phase 5  CloudFront + WAF  ロードジェネレーター"
echo "============================================================"
echo " DistributionId : ${DIST_ID}"
echo " Domain         : https://${DIST_DOMAIN}"
echo " Origin S3      : s3://${ORIGIN_BUCKET}"
echo " Region         : us-east-1"
echo ""
echo "INFO: CloudFront メトリクスの反映には 3〜5 分かかります。"
echo "INFO: apply 直後は CloudFront 伝播待ち (最大 15 分) で curl が失敗することがあります。"
echo ""

# ── Step 0: index.html をオリジン S3 にアップロード ──────────────────────────
echo "------------------------------------------------------------"
echo " Step 0 / 6 : index.html を S3 オリジンにアップロード"
echo "------------------------------------------------------------"
TMP_HTML=$(mktemp /tmp/phase5-index-XXXXXX.html)
cat >"${TMP_HTML}" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="ja">
<head><meta charset="UTF-8"><title>Phase5 Sandbox</title></head>
<body><h1>CloudFront + WAF Sandbox (Phase 5)</h1></body>
</html>
HTMLEOF
aws s3 cp "${TMP_HTML}" "s3://${ORIGIN_BUCKET}/index.html" \
  --content-type "text/html" \
  --region us-east-1
rm -f "${TMP_HTML}"
echo "  [OK] uploaded: s3://${ORIGIN_BUCKET}/index.html"

# ── Step 1: 正常リクエスト群 (キャッシュ HIT/MISS を生成) ────────────────────
echo ""
echo "------------------------------------------------------------"
echo " Step 1 / 6 : 正常リクエスト 50 件 — MISS→HIT の遷移を観察"
echo "             [観点] 最初の数件は MISS (オリジン到達), 以降 HIT へ"
echo "------------------------------------------------------------"
HIT_COUNT=0; MISS_COUNT=0; ERR_COUNT=0
for i in $(seq 1 50); do
  CACHE_HDR=""
  BODY=$(curl -sS -o /dev/null \
    -D - \
    -H "Cache-Control: no-cache" \
    "https://${DIST_DOMAIN}/index.html" 2>&1 || true)
  CODE=$(printf '%s' "${BODY}" | grep -i "^HTTP/" | tail -1 | awk '{print $2}' || echo "000")
  X_CACHE=$(printf '%s' "${BODY}" | grep -i "^x-cache:" | awk '{print $2}' | tr -d '\r' || echo "?")
  if [[ "${CODE}" == "200" ]]; then
    if [[ "${X_CACHE}" == Hit* ]]; then
      HIT_COUNT=$((HIT_COUNT + 1))
      STATUS="HIT "
    else
      MISS_COUNT=$((MISS_COUNT + 1))
      STATUS="MISS"
    fi
  else
    ERR_COUNT=$((ERR_COUNT + 1))
    STATUS="ERR "
  fi
  printf "  [%02d/50] HTTP %s  X-Cache: %-8s  %s\n" "${i}" "${CODE}" "${X_CACHE}" "${STATUS}"
  sleep 0.2
done
echo ""
echo "  集計: HIT=${HIT_COUNT}  MISS=${MISS_COUNT}  ERR=${ERR_COUNT}"

# ── Step 2: 404 生成 (4xxErrorRate を上げる) ─────────────────────────────────
echo ""
echo "------------------------------------------------------------"
echo " Step 2 / 6 : 存在しない URL を 10 件リクエスト (404 生成)"
echo "             [観点] 4xxErrorRate が上昇するはず"
echo "------------------------------------------------------------"
for i in $(seq 1 10); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" \
    "https://${DIST_DOMAIN}/not-found-${i}.html" || true)
  printf "  [%02d/10] HTTP %s  /not-found-%d.html\n" "${i}" "${code}" "${i}"
  sleep 0.1
done
echo "  [OK] 404 生成完了"

# ── Step 3: WAF ルールを踏むリクエスト (SQLi パターン) ───────────────────────
echo ""
echo "------------------------------------------------------------"
echo " Step 3 / 6 : WAF ブロック試験 — SQLi パターン"
echo "             [観点] WAF/BlockedRequests (CommonRuleSet) が増加するはず"
echo "             [期待] HTTP 403 (WAF ブロック)"
echo "------------------------------------------------------------"
SQLI_URL="https://${DIST_DOMAIN}/?id=1'%20OR%20'1'='1"
code=$(curl -sS -o /dev/null -w "%{http_code}" \
  "${SQLI_URL}" || true)
echo "  SQLi パターン: HTTP ${code}  (期待: 403)"

XSS_URL="https://${DIST_DOMAIN}/?q=<script>alert(1)</script>"
code=$(curl -sS -o /dev/null -w "%{http_code}" \
  "${XSS_URL}" || true)
echo "  XSS パターン : HTTP ${code}  (期待: 403)"

echo "  [OK] WAF ブロック試験完了"

# ── Step 4: レートリミット試験 (短時間大量リクエスト) ────────────────────────
echo ""
echo "------------------------------------------------------------"
echo " Step 4 / 6 : レートリミット試験 — 120 並列リクエスト"
echo "             [観点] WAF/BlockedRequests (RateLimit) が増加するはず"
echo "             [期待] 閾値(1000 req/5 min)に近づくほどブロック率が上昇"
echo "------------------------------------------------------------"
echo "  120 並列リクエストを送信中..."
PIDS=()
for i in $(seq 1 120); do
  curl -sS -o /dev/null \
    "https://${DIST_DOMAIN}/index.html" &
  PIDS+=($!)
done
wait "${PIDS[@]}" 2>/dev/null || true
echo "  [OK] 120 件のバースト完了"

# ── Step 5: Bot UA 試験 ────────────────────────────────────────────────────────
echo ""
echo "------------------------------------------------------------"
echo " Step 5 / 6 : Bot User-Agent 試験"
echo "             [観点] WAF が python-requests 等の Bot UA を識別"
echo "------------------------------------------------------------"
BOT_UAS=("python-requests/2.28.0" "Scrapy/2.7.0" "curl/7.79.1 (攻撃模倣)")
for ua in "${BOT_UAS[@]}"; do
  code=$(curl -sS -o /dev/null -w "%{http_code}" \
    -A "${ua}" \
    "https://${DIST_DOMAIN}/index.html" || true)
  printf "  UA: %-35s  HTTP %s\n" "${ua}" "${code}"
done
echo "  [OK] Bot UA 試験完了"

# ── Step 6: Invalidation ──────────────────────────────────────────────────────
echo ""
echo "------------------------------------------------------------"
echo " Step 6 / 6 : CloudFront Invalidation (/* — 1000 パス超は有料)"
echo "------------------------------------------------------------"
aws cloudfront create-invalidation \
  --region us-east-1 \
  --distribution-id "${DIST_ID}" \
  --paths "/*" \
  --output table || echo "  (Invalidation スキップ)"
echo "  [OK] Invalidation リクエスト送信完了"

# ── 完了メッセージ ────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " ロード完了!"
echo " 送信内訳:"
echo "   Step1: 正常リクエスト ×50 (HIT/MISS 混在)"
echo "   Step2: 404 エラー     ×10"
echo "   Step3: WAF SQLi/XSS  ×2"
echo "   Step4: バースト       ×120 (RateLimit 試験)"
echo "   Step5: Bot UA         ×3"
echo ""
echo " メトリクス反映まで 3〜5 分待ってから観察を開始してください。"
echo ""
echo " 次のステップ:"
echo "   make sandbox-watch-phase5"
echo "============================================================"
