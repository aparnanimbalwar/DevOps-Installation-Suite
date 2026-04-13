#!/bin/bash
set -e

# -----------------------------------
# Logging
# -----------------------------------
LOG_FILE="/var/log/ec2-userdata-elastic-kibana.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "🚀 EC2 User Data: Elasticsearch + Kibana"
echo "=========================================="

# -----------------------------------
# Variables
# -----------------------------------
S3_BUCKET="konnect-scripts"
SCRIPT_NAME="ElasticSearch-Kibana-Setup.sh"  
WORK_DIR="/opt/konnect"
LOCAL_SCRIPT="${WORK_DIR}/${SCRIPT_NAME}"

# -----------------------------------
# Create working directory
# -----------------------------------
echo "📁 Creating working directory: $WORK_DIR"
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
# Download Elastic + Kibana script
# -----------------------------------
echo ""
echo "📥 Downloading Elasticsearch + Kibana setup script from S3"
echo "   s3://${S3_BUCKET}/${SCRIPT_NAME}"

aws s3 cp "s3://${S3_BUCKET}/${SCRIPT_NAME}" "$LOCAL_SCRIPT"

# -----------------------------------
# Make executable
# -----------------------------------
chmod +x "$LOCAL_SCRIPT"

# -----------------------------------
# Execute setup script
# -----------------------------------
echo ""
echo "🚀 Executing Elasticsearch + Kibana setup script..."
echo "------------------------------------------"

bash "$LOCAL_SCRIPT"
SETUP_STATUS=$?

# -----------------------------------
# Final status
# -----------------------------------
echo ""
echo "=========================================="
if [ $SETUP_STATUS -eq 0 ]; then
    echo "✅ Elasticsearch + Kibana setup SUCCESSFUL"
    echo ""
    echo "📄 Logs:"
    echo "   - User data log : $LOG_FILE"
    echo "   - Setup log    : /var/log/elastic_kibana_install.log"
else
    echo "❌ Elasticsearch + Kibana setup FAILED (exit code: $SETUP_STATUS)"
    echo ""
    echo "📄 Check logs:"
    echo "   - $LOG_FILE"
    echo "   - /var/log/elastic_kibana_install.log"
fi
echo "=========================================="
