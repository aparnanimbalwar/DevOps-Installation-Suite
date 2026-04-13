#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

#############################################
# LOGGING
#############################################
LOG_FILE="/var/log/elasticsearch_kibana_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "🟢 Starting Elasticsearch + Kibana Setup..."

#############################################
# 1️⃣ System Dependencies
#############################################
echo "📦 Installing system dependencies..."
apt update -y
apt install -y curl wget gnupg jq unzip

#############################################
# 2️⃣ AWS CLI v2 (Non-interactive)
#############################################
if ! command -v aws >/dev/null 2>&1; then
  echo "📦 Installing AWS CLI v2..."
  rm -rf /tmp/aws /tmp/awscliv2.zip
  curl -s https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
  unzip -oq /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install --update
fi

aws --version

#############################################
# 3️⃣ EC2 Metadata (IMDSv2)
#############################################
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

#############################################
# 4️⃣ Environment (EC2 Tag)
#############################################
ENVIRONMENT=$(aws ec2 describe-tags \
  --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Environment" \
  --region "$REGION" \
  --query "Tags[0].Value" \
  --output text 2>/dev/null || true)

[ -z "$ENVIRONMENT" ] || [ "$ENVIRONMENT" = "None" ] && ENVIRONMENT="dev"

echo "🔹 Region      : $REGION"
echo "🔹 Environment : $ENVIRONMENT"

#############################################
# 5️⃣ Fetch Secrets
#############################################
SECRET_NAME="konnect/elasticsearch-kibana/$ENVIRONMENT"
echo "🔐 Fetching secret: $SECRET_NAME"

SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --region "$REGION" \
  --query SecretString \
  --output text)

#############################################
# 6️⃣ Read Secrets
#############################################
ELASTIC_PASSWORD=$(jq -r '.Elastic_Password' <<<"$SECRET_JSON")
KIBANA_PASSWORD=$(jq -r '.Kibana_Password' <<<"$SECRET_JSON")
CLUSTER_NAME=$(jq -r '.Cluster_Name' <<<"$SECRET_JSON")
NODE_NAME=$(jq -r '.Node_Name' <<<"$SECRET_JSON")
NETWORK_HOST=$(jq -r '.Network_Host' <<<"$SECRET_JSON")

#############################################
# 7️⃣ Validate Secrets
#############################################
for VAR in ELASTIC_PASSWORD KIBANA_PASSWORD CLUSTER_NAME NODE_NAME NETWORK_HOST; do
  if [[ -z "${!VAR}" || "${!VAR}" == "null" ]]; then
    echo "❌ ERROR: $VAR missing in Secrets Manager"
    exit 1
  fi
done

echo "✅ Secrets validation passed"

#############################################
# 8️⃣ Kernel Tuning
#############################################
echo "⚙️ Applying kernel tuning..."
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >/etc/sysctl.d/99-elasticsearch.conf
sysctl --system

#############################################
# 9️⃣ Elasticsearch Repository
#############################################
if [ ! -f /usr/share/keyrings/elastic-keyring.gpg ]; then
  curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
    gpg --dearmor -o /usr/share/keyrings/elastic-keyring.gpg
fi

if [ ! -f /etc/apt/sources.list.d/elastic-8.x.list ]; then
  echo "deb [signed-by=/usr/share/keyrings/elastic-keyring.gpg] \
https://artifacts.elastic.co/packages/8.x/apt stable main" \
> /etc/apt/sources.list.d/elastic-8.x.list
fi

apt update -y
apt install -y elasticsearch

#############################################
# 🔟 Prepare Directories
#############################################
mkdir -p /var/lib/elasticsearch /var/log/elasticsearch
chown -R elasticsearch:elasticsearch /var/lib/elasticsearch /var/log/elasticsearch
chmod 750 /var/lib/elasticsearch /var/log/elasticsearch

#############################################
# ⓫ Elasticsearch Configuration (TLS AUTO)
#############################################
cat >/etc/elasticsearch/elasticsearch.yml <<EOF
cluster.name: ${CLUSTER_NAME}
node.name: ${NODE_NAME}
network.host: ${NETWORK_HOST}
http.port: 9200

path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

xpack.security.enabled: true
discovery.type: single-node
EOF

chown -R elasticsearch:elasticsearch /etc/elasticsearch
chmod 750 /etc/elasticsearch

#############################################
# ⓬ Start Elasticsearch
#############################################
systemctl daemon-reexec
systemctl enable elasticsearch
systemctl start elasticsearch

#############################################
# ⓭ Wait for Elasticsearch
#############################################
echo "⏳ Waiting for Elasticsearch..."
for i in {1..40}; do
  if curl -sk https://localhost:9200 >/dev/null; then
    break
  fi
  sleep 3
done

#############################################
# ⓮ Reset Built-in Passwords (SAFE)
#############################################
echo "🔑 Resetting elastic password..."
echo "$ELASTIC_PASSWORD" | \
/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -i

echo "🔑 Resetting kibana_system password..."
echo "$KIBANA_PASSWORD" | \
/usr/share/elasticsearch/bin/elasticsearch-reset-password -u kibana_system -i

#############################################
# ⓯ Install Kibana
#############################################
apt install -y kibana

#############################################
# ⓰ Configure Kibana (CORRECT)
#############################################
cat >/etc/kibana/kibana.yml <<EOF
server.port: 5601
server.host: "0.0.0.0"

elasticsearch.hosts: ["https://localhost:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${KIBANA_PASSWORD}"

elasticsearch.ssl.verificationMode: none
EOF

chown kibana:kibana /etc/kibana/kibana.yml
chmod 640 /etc/kibana/kibana.yml

#############################################
# ⓱ Start Kibana
#############################################
systemctl daemon-reexec
systemctl enable kibana
systemctl restart kibana

#############################################
# ⓲ Verification
#############################################
echo "✅ Verifying Elasticsearch..."
curl -k -u "elastic:${ELASTIC_PASSWORD}" https://localhost:9200

echo ""
echo "=========================================="
echo "🎉 Elasticsearch + Kibana Setup COMPLETE!"
echo "=========================================="
echo "Environment   : $ENVIRONMENT"
echo "Cluster Name  : $CLUSTER_NAME"
echo "Elasticsearch : https://<EC2-IP>:9200"
echo "Kibana        : http://<EC2-IP>:5601"
echo "=========================================="
