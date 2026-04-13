#!/bin/bash

LOG_DIR="/var/log/kibana"
S3_BASE="s3://konnect-central-logs/dev/Konnect-DEV-Kibana/Monthly"

DATE=$(date +%F)
RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)

# Fetch instance ID (IMDSv2)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

S3_DEST="${S3_BASE}/date=${DATE}/run=${RUN_TS}/instance=${INSTANCE_ID}"

echo "🗓 Monthly Kibana log upload"
echo "➡ Destination: $S3_DEST"

# Find rotated logs from last 30 days
FILES=$(find "$LOG_DIR" -type f -name "*.gz" -mtime -30)

if [ -z "$FILES" ]; then
  echo "⚠️ No rotated Kibana logs found in last 30 days. Exiting."
  exit 0
fi

for file in $FILES; do
  aws s3 cp "$file" "$S3_DEST/$(basename "$file")" --only-show-errors
done

echo "✅ Uploaded $(echo "$FILES" | wc -l) files"
