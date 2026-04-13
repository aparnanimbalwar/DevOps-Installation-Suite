#!/bin/bash
set -e

# ---------------- BASIC CONFIG ----------------
DATE=$(date +%F)                    # 2026-01-23
TIME=$(date +%H-%M)
RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)   # 20260123T002401Z
BACKUP_TYPE="Daily"

TMP_DIR="/tmp"
LOG_BASE_DIR="/root/mongodb-backup/logs"
mkdir -p "$LOG_BASE_DIR"
# ----------------------------------------------

# --------- IMDSv2 TOKEN ----------
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# --------- INSTANCE ID ----------
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

# --------- REGION ----------
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

# --------- ENV TAG ----------
ENVIRONMENT=$(aws ec2 describe-tags \
  --region "$AWS_REGION" \
  --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Environment" \
  --query "Tags[0].Value" \
  --output text)

if [[ -z "$ENVIRONMENT" || "$ENVIRONMENT" == "None" ]]; then
  echo "[$(date)] ❌ Environment tag not found" >> "$LOG_BASE_DIR/mongo-unknown.log"
  exit 1
fi

ENVIRONMENT=$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]')
LOG_FILE="$LOG_BASE_DIR/mongo-${ENVIRONMENT}.log"

echo "==================================================" >> "$LOG_FILE"
echo "[$(date)] Starting MongoDB DAILY backup (${ENVIRONMENT})" >> "$LOG_FILE"

# --------- SECRET ----------
SECRET_NAME="konnect/mongodb/${ENVIRONMENT}"

SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text)

MONGO_USER=$(echo "$SECRET_JSON" | jq -r '.MONGO_ROOT_USERNAME')
MONGO_PASS=$(echo "$SECRET_JSON" | jq -r '.MONGO_ROOT_PASSWORD')
MONGO_HOST=$(echo "$SECRET_JSON" | jq -r '.MONGO_HOST')
MONGO_PORT=$(echo "$SECRET_JSON" | jq -r '.MONGO_PORT')

# --------- BACKUP ----------
BACKUP_NAME="mongodb_daily_${ENVIRONMENT}_${DATE}_${TIME}"
BACKUP_DIR="${TMP_DIR}/${BACKUP_NAME}"

mongodump \
  --host "$MONGO_HOST" \
  --port "$MONGO_PORT" \
  --username "$MONGO_USER" \
  --password "$MONGO_PASS" \
  --authenticationDatabase admin \
  --out "$BACKUP_DIR" >> "$LOG_FILE" 2>&1

tar -czf "${TMP_DIR}/${BACKUP_NAME}.tar.gz" -C "$TMP_DIR" "$BACKUP_NAME"

# --------- S3 PARTITIONED PATH ----------
S3_BASE="s3://konnect-db-backups/MongoDB/MongoDB-${ENVIRONMENT^^}/${BACKUP_TYPE}"
S3_PATH="${S3_BASE}/date=${DATE}/run=${RUN_TS}"

aws s3 cp \
  "${TMP_DIR}/${BACKUP_NAME}.tar.gz" \
  "${S3_PATH}/" >> "$LOG_FILE" 2>&1

# --------- CLEANUP ----------
rm -rf "$BACKUP_DIR" "${TMP_DIR}/${BACKUP_NAME}.tar.gz"

echo "[$(date)] ✅ Backup uploaded to ${S3_PATH}" >> "$LOG_FILE"
