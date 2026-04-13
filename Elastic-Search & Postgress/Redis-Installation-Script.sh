#!/bin/bash
set -e

# -----------------------------------
# Variables
# -----------------------------------
LOG_FILE="/var/log/redis-install.log"
SECRET_NAME="konnect/redis-dev/dev"
AWS_REGION="ap-northeast-2"
REDIS_CONF="/etc/redis/redis.conf"

# -----------------------------------
# Logging
# -----------------------------------
exec > >(tee -a ${LOG_FILE}) 2>&1
echo "===== Redis Installation Started ====="

# -----------------------------------
# Install Dependencies
# -----------------------------------
echo "Installing dependencies..."
apt update -y
apt install -y unzip curl jq snapd redis-server
systemctl enable snapd
systemctl start snapd
snap install aws-cli --classic

# -----------------------------------
# Fetch Secrets from AWS Secrets Manager
# -----------------------------------
echo "Fetching Redis credentials from AWS Secrets Manager..."

SECRET_JSON=$(aws secretsmanager get-secret-value \
  --region ${AWS_REGION} \
  --secret-id ${SECRET_NAME} \
  --query SecretString \
  --output text)

REDIS_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.REDIS_PASSWORD')
REDIS_MAXMEMORY=$(echo "$SECRET_JSON" | jq -r '.REDIS_MAXMEMORY')
REDIS_PORT=$(echo "$SECRET_JSON" | jq -r '.REDIS_PORT')
REDIS_BIND=$(echo "$SECRET_JSON" | jq -r '.REDIS_BIND')

# -----------------------------------
# Redis Configuration
# -----------------------------------
echo "Configuring Redis..."

sed -i "s/^bind .*/bind ${REDIS_BIND}/" ${REDIS_CONF}
sed -i "s/^protected-mode yes/protected-mode no/" ${REDIS_CONF}
sed -i "s/^# requirepass .*/requirepass ${REDIS_PASSWORD}/" ${REDIS_CONF}
sed -i "s/^port .*/port ${REDIS_PORT}/" ${REDIS_CONF}

# Memory & Eviction Policy
echo "maxmemory ${REDIS_MAXMEMORY}" >> ${REDIS_CONF}
echo "maxmemory-policy allkeys-lru" >> ${REDIS_CONF}

# -----------------------------------
# Enable Redis to Start on Boot
# -----------------------------------
systemctl enable redis-server
systemctl restart redis-server

# -----------------------------------
# Validation
# -----------------------------------
echo "Validating Redis Service..."
systemctl status redis-server --no-pager

echo "===== Redis Installation Completed Successfully ====="
