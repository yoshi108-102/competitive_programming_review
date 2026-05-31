#!/usr/bin/env bash
set -euo pipefail

BUCKET=$(terraform -chdir="$(dirname "$0")" output -raw main_bucket_name)
REGION=$(terraform -chdir="$(dirname "$0")" output -raw aws_region 2>/dev/null || echo "ap-northeast-1")
PREFIX="load-$(date +%s)"

echo "=== Phase2 load start: bucket=$BUCKET ==="

# 1) 小オブジェクトを大量 PutObject
for i in $(seq 1 30); do
  TMP=$(mktemp)
  echo "phase2 test object $i at $(date -u +%FT%TZ)" >"$TMP"
  aws s3 cp "$TMP" "s3://$BUCKET/$PREFIX/small-$i.txt" --region "$REGION" --quiet
  rm "$TMP"
done
echo "[+] 30 small objects uploaded"

# 2) 10 MB マルチパート相当オブジェクト(aws cli は 8MB 以上で自動マルチパート)
dd if=/dev/urandom bs=1M count=12 2>/dev/null |
  aws s3 cp - "s3://$BUCKET/$PREFIX/large-12mb.bin" \
    --region "$REGION" --expected-size $((12 * 1024 * 1024))
echo "[+] 12 MB object uploaded (multipart)"

# 3) GetObject ラウンドトリップ
for i in $(seq 1 10); do
  aws s3 cp "s3://$BUCKET/$PREFIX/small-$i.txt" /dev/null --region "$REGION" --quiet
done
echo "[+] 10 GetObject done"

# 4) バージョン確認 (versioning が効いているか)
VER_COUNT=$(aws s3api list-object-versions \
  --bucket "$BUCKET" --prefix "$PREFIX/" \
  --query 'length(Versions)' --output text --region "$REGION")
echo "[+] Versions in prefix: $VER_COUNT"

# 5) 存在しないキーを GetObject → 404 が AllRequests に含まれることを確認
aws s3 cp "s3://$BUCKET/$PREFIX/nonexistent.txt" /dev/null \
  --region "$REGION" 2>/dev/null || echo "[+] Expected 404 for nonexistent key"

# 6) プリサインド URL を生成して curl で取得(SigV4 署名 URL の動作確認)
PRESIGNED=$(aws s3 presign "s3://$BUCKET/$PREFIX/small-1.txt" \
  --expires-in 60 --region "$REGION")
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$PRESIGNED")
echo "[+] Presigned URL HTTP status: $HTTP_STATUS"

echo ""
echo "=== load.sh complete ==="
echo "S3 リクエストメトリクスは ~1min、Lambda は即時、BucketSizeBytes は翌日に反映。"
