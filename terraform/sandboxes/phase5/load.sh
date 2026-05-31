#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIST_DOMAIN=$(terraform -chdir="${SCRIPT_DIR}" output -raw cloudfront_domain_name)
DIST_ID=$(terraform -chdir="${SCRIPT_DIR}" output -raw cloudfront_distribution_id)
ORIGIN_BUCKET=$(terraform -chdir="${SCRIPT_DIR}" output -raw origin_bucket_name)

echo "INFO: CloudFront メトリクスの反映には 3〜5 分かかります。"
echo "Target: https://${DIST_DOMAIN}"

# ── Step 0: index.html をオリジン S3 にアップロード ──────────────────────────
echo ""
echo "=== Step 0: index.html を S3 オリジンにアップロード ==="
TMP_HTML=$(mktemp /tmp/phase5-index-XXXXXX.html)
cat >"${TMP_HTML}" <<'EOF'
<!DOCTYPE html>
<html lang="ja">
<head><meta charset="UTF-8"><title>Phase5 Sandbox</title></head>
<body><h1>CloudFront + WAF Sandbox (Phase 5)</h1></body>
</html>
EOF
aws s3 cp "${TMP_HTML}" "s3://${ORIGIN_BUCKET}/index.html" \
  --content-type "text/html" \
  --region us-east-1
rm -f "${TMP_HTML}"
echo "  uploaded: s3://${ORIGIN_BUCKET}/index.html"

echo ""
echo "INFO: CF ディストリビューションが反映されるまで最大 15 分かかります。"
echo "INFO: apply 直後は curl が NoSuchDistribution になる場合があります。"

# ── Step 1: 正常リクエスト群 (キャッシュ HIT/MISS を生成) ────────────────────
echo ""
echo "=== Step 1: 正常リクエスト (200 系) — 50 回 ==="
for i in $(seq 1 50); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" \
    -H "Cache-Control: no-cache" \
    "https://${DIST_DOMAIN}/index.html" || true)
  echo "  [${i}] ${code}"
  sleep 0.2
done

# ── Step 2: 404 生成 (4xxErrorRate を上げる) ─────────────────────────────────
echo ""
echo "=== Step 2: 404 生成 ==="
for i in $(seq 1 10); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" \
    "https://${DIST_DOMAIN}/not-found-${i}.html" || true)
  echo "  [${i}] ${code}"
  sleep 0.1
done

# ── Step 3: WAF ルールを踏むリクエスト (SQLi パターン) ───────────────────────
echo ""
echo "=== Step 3: WAF Block 試験 (SQLi) ==="
code=$(curl -sS -o /dev/null -w "%{http_code}" \
  "https://${DIST_DOMAIN}/?id=1'%20OR%20'1'='1" || true)
echo "  SQLi: ${code}"

# ── Step 4: レートリミット試験 (短時間大量リクエスト) ────────────────────────
echo ""
echo "=== Step 4: レートリミット試験 (120 並列) ==="
for i in $(seq 1 120); do
  curl -sS -o /dev/null \
    "https://${DIST_DOMAIN}/index.html" &
done
wait
echo "  rate-limit burst done"

# ── Step 5: Bot UA 試験 ────────────────────────────────────────────────────────
echo ""
echo "=== Step 5: Bot UA 試験 ==="
code=$(curl -sS -o /dev/null -w "%{http_code}" \
  -A "python-requests/2.28.0" \
  "https://${DIST_DOMAIN}/index.html" || true)
echo "  BotUA: ${code}"

# ── Step 6: Invalidation (任意) ──────────────────────────────────────────────
echo ""
echo "=== Step 6: CF Invalidation (/* — 1000 パス超は有料) ==="
aws cloudfront create-invalidation \
  --region us-east-1 \
  --distribution-id "${DIST_ID}" \
  --paths "/*" \
  --output table || echo "  (Invalidation スキップ)"

echo ""
echo "ロード完了。メトリクス反映まで 3〜5 分待つ。"
echo "watch.sh または以下で確認:"
echo "  aws cloudwatch get-metric-statistics --region us-east-1 \\"
echo "    --namespace AWS/CloudFront --metric-name Requests \\"
echo "    --dimensions Name=DistributionId,Value=${DIST_ID} Name=Region,Value=Global \\"
echo "    --start-time \$(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ') \\"
echo "    --end-time \$(date -u '+%Y-%m-%dT%H:%M:%SZ') \\"
echo "    --period 300 --statistics Sum"
