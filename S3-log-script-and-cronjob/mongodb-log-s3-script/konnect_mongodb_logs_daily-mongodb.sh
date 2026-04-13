#!/bin/bash
set -euo pipefail

############################################
# CONFIG
############################################
LOG_FILE="/var/log/mongodb/mongod.log"
LOG_DIR="/var/log/mongodb"
S3_BASE="s3://konnect-central-logs/dev/Konnect-DEV-MongoDB/Daily"

DATE=$(date +%F)
RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)

############################################
# FETCH INSTANCE ID (IMDSv2)
############################################
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

S3_DEST="${S3_BASE}/date=${DATE}/run=${RUN_TS}/instance=${INSTANCE_ID}"

echo "📅 Daily mongodb log compression & upload"
echo "➡ Destination: $S3_DEST"

############################################
# VALIDATE LOG FILE
############################################
if [ ! -f "$LOG_FILE" ]; then
  echo "❌ mongodb log file not found: $LOG_FILE"
  exit 1
fi

############################################
# CREATE COMPRESSED COPY (SAFE)
############################################
TMP_GZ="${LOG_DIR}/mongod.log.${RUN_TS}.gz"

echo "🗜️ Compressing mongod.log..."
gzip -c "$LOG_FILE" > "$TMP_GZ"

############################################
# UPLOAD TO S3
############################################
echo "☁️ Uploading to S3..."
aws s3 cp "$TMP_GZ" "$S3_DEST/$(basename "$TMP_GZ")" --only-show-errors

############################################
# CLEANUP LOCAL TEMP FILE
############################################
rm -f "$TMP_GZ"

echo "✅ Mongodb log uploaded successfully"
