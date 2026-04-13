#!/bin/bash
set -e

# ---------------- BASIC CONFIG ----------------
DATE=$(date +%F)                    # 2026-01-23
TIME=$(date +%H-%M)
RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)   # 20260123T002401Z
BACKUP_TYPE="Daily"

TMP_DIR="/tmp"
LOG_BASE_DIR="/root/postgres-backup/logs"
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
  echo "[$(date)] ❌ Environment tag not found" >> "$LOG_BASE_DIR/postgres-unknown.log"
  exit 1
fi

ENVIRONMENT=$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]')
LOG_FILE="$LOG_BASE_DIR/postgres-${ENVIRONMENT}.log"

echo "==================================================" >> "$LOG_FILE"
echo "[$(date)] Starting PostgreSQL DAILY backup (${ENVIRONMENT})" >> "$LOG_FILE"

# --------- SECRET ----------
SECRET_NAME="konnect/postgres/${ENVIRONMENT}"

SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text)

PG_USER=$(echo "$SECRET_JSON" | jq -r '.username')
PG_PASS=$(echo "$SECRET_JSON" | jq -r '.password')
PG_HOST=$(echo "$SECRET_JSON" | jq -r '.host')
PG_PORT=$(echo "$SECRET_JSON" | jq -r '.port')
PG_DB=$(echo "$SECRET_JSON" | jq -r '.dbname')

# --------- BACKUP ----------
BACKUP_NAME="postgres_daily_${ENVIRONMENT}_${DATE}_${TIME}"
BACKUP_FILE="${TMP_DIR}/${BACKUP_NAME}.dump"

export PGPASSWORD="$PG_PASS"

pg_dump \
  -h "$PG_HOST" \
  -p "$PG_PORT" \
  -U "$PG_USER" \
  -d "$PG_DB" \
  -F c \
  -f "$BACKUP_FILE" >> "$LOG_FILE" 2>&1

unset PGPASSWORD

tar -czf "${BACKUP_FILE}.tar.gz" -C "$TMP_DIR" "$(basename "$BACKUP_FILE")"

# --------- S3 PARTITIONED PATH ----------
S3_BASE="s3://konnect-db-backups/PostgreSQL/PostgreSQL-${ENVIRONMENT^^}/${BACKUP_TYPE}"
S3_PATH="${S3_BASE}/date=${DATE}/run=${RUN_TS}"

aws s3 cp \
  "${BACKUP_FILE}.tar.gz" \
  "${S3_PATH}/" >> "$LOG_FILE" 2>&1

# --------- CLEANUP ----------
rm -f "$BACKUP_FILE" "${BACKUP_FILE}.tar.gz"

echo "[$(date)] ✅ Backup uploaded successfully to ${S3_PATH}" >> "$LOG_FILE"
