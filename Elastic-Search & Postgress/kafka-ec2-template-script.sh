#!/bin/bash
set -e

# -----------------------------------
# Logging
# -----------------------------------
LOG_FILE="/var/log/ec2-userdata-kafka.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "🚀 EC2 User Data: Kafka (KRaft) Setup"
echo "=========================================="

# -----------------------------------
# Variables
# -----------------------------------
S3_BUCKET="konnect-scripts"
SCRIPT_NAME="kafka.sh"
WORK_DIR="/opt/konnect"
LOCAL_SCRIPT="${WORK_DIR}/${SCRIPT_NAME}"

# -----------------------------------
# Create working directory
# -----------------------------------
echo "📁 Creating working directory..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# -----------------------------------
# Install AWS CLI v2 (if missing)
# -----------------------------------
echo "📦 Checking AWS CLI..."

if ! command -v aws &>/dev/null; then
    echo "📦 Installing AWS CLI v2..."
    apt-get update -y
    apt-get install -y curl unzip

    curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip

    export PATH="/usr/local/bin:$PATH"
    echo "✅ AWS CLI installed"
else
    echo "✅ AWS CLI already present"
fi

aws --version

# -----------------------------------
# Download Kafka setup script from S3
# -----------------------------------
echo ""
echo "📥 Downloading Kafka setup script from S3"
echo "   s3://${S3_BUCKET}/${SCRIPT_NAME}"

aws s3 cp "s3://${S3_BUCKET}/${SCRIPT_NAME}" "$LOCAL_SCRIPT"

# -----------------------------------
# Make executable
# -----------------------------------
chmod +x "$LOCAL_SCRIPT"

# -----------------------------------
# Execute Kafka setup script
# -----------------------------------
echo ""
echo "🚀 Executing Kafka setup script..."
echo "------------------------------------------"

bash "$LOCAL_SCRIPT"
SETUP_STATUS=$?

# -----------------------------------
# Final status
# -----------------------------------
echo ""
echo "=========================================="
if [ $SETUP_STATUS -eq 0 ]; then
    echo "✅ Kafka setup SUCCESSFUL"
    echo "📄 Logs:"
    echo "   - User data log : $LOG_FILE"
    echo "   - Kafka service : systemctl status kafka"
else
    echo "❌ Kafka setup FAILED (exit code: $SETUP_STATUS)"
    echo "📄 Check logs:"
    echo "   - $LOG_FILE"
fi
echo "=========================================="
