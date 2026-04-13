#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/elastic_kibana_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== Elasticsearch + Kibana 8.x (Append-to-Secret Mode) ====="

############################################
# STATIC VARIABLES
############################################
SECRET_NAME="konnect/elasticsearch-kibana/dev"
FORCE_PASSWORD_ROTATION="${FORCE_PASSWORD_ROTATION:-false}"

############################################
# 1. SYSTEM TUNING
############################################
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >/etc/sysctl.d/99-elasticsearch.conf
sysctl --system

############################################
# 2. DEPENDENCIES
############################################
apt update -y
apt install -y curl gnupg jq unzip

############################################
# 3. AWS CLI (ENSURE PRESENT)
############################################
if command -v aws >/dev/null 2>&1; then
    echo "✅ AWS CLI already installed. Updating..."
    cd /tmp
    sudo ./aws/install --update || true
else
    echo "⬇️ Installing AWS CLI v2..."
    cd /tmp
    rm -rf aws awscliv2.zip
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
    unzip -q awscliv2.zip
    sudo ./aws/install
fi

echo "✅ AWS CLI ready."

############################################
# 4. AWS REGION (IMDSv2)
############################################
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

AWS_REGION=$(curl -s \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

############################################
# 5. READ EXISTING SECRET (MUST EXIST)
############################################
RAW_SECRET=$(
  aws secretsmanager get-secret-value \
    --region "$AWS_REGION" \
    --secret-id "$SECRET_NAME" \
    --query SecretString \
    --output text
)

CLUSTER_NAME=$(echo "$RAW_SECRET" | jq -r '.cluster_name')
NODE_NAME=$(echo "$RAW_SECRET" | jq -r '.node_name')

if [[ -z "$CLUSTER_NAME" || -z "$NODE_NAME" ]]; then
  echo "ERROR: cluster_name or node_name missing in secret"
  exit 1
fi

############################################
# 6. INSTALL ELASTICSEARCH
############################################
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
 | gpg --dearmor -o /usr/share/keyrings/elastic-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/elastic-keyring.gpg] \
https://artifacts.elastic.co/packages/8.x/apt stable main" \
> /etc/apt/sources.list.d/elastic-8.x.list

apt update -y
apt install -y elasticsearch

cat >/etc/elasticsearch/elasticsearch.yml <<EOF
cluster.name: ${CLUSTER_NAME}
node.name: ${NODE_NAME}
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: 0.0.0.0
http.port: 9200
discovery.type: single-node
xpack.security.enabled: true
xpack.security.autoconfiguration.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false
EOF

systemctl enable elasticsearch
systemctl start elasticsearch

echo "Waiting for Elasticsearch..."
for i in {1..40}; do
  if curl -s http://localhost:9200 >/dev/null; then break; fi
  sleep 3
done

############################################
# 7. ENSURE PASSWORD KEYS EXIST (APPEND ONLY)
############################################
ELASTIC_PASSWORD=$(echo "$RAW_SECRET" | jq -r '.elastic_password // empty')
KIBANA_PASSWORD=$(echo "$RAW_SECRET" | jq -r '.kibana_system_password // empty')

if [[ "$FORCE_PASSWORD_ROTATION" == "true" || -z "$ELASTIC_PASSWORD" || -z "$KIBANA_PASSWORD" ]]; then
  echo "🔐 Generating Elasticsearch credentials..."

  ELASTIC_PASSWORD=$(
    /usr/share/elasticsearch/bin/elasticsearch-reset-password \
      --batch -u elastic | awk '/New value/ {print $NF}'
  )

  KIBANA_PASSWORD=$(
    /usr/share/elasticsearch/bin/elasticsearch-reset-password \
      --batch -u kibana_system | awk '/New value/ {print $NF}'
  )

  UPDATED_SECRET=$(echo "$RAW_SECRET" | jq \
    --arg elastic "$ELASTIC_PASSWORD" \
    --arg kibana "$KIBANA_PASSWORD" \
    '. + {
      elastic_password: $elastic,
      kibana_system_password: $kibana
    }')

  aws secretsmanager put-secret-value \
    --region "$AWS_REGION" \
    --secret-id "$SECRET_NAME" \
    --secret-string "$UPDATED_SECRET"

  RAW_SECRET="$UPDATED_SECRET"
  echo "✅ Password keys added to existing secret"
else
  echo "✅ Passwords already present — skipping"
fi

############################################
# 8. INSTALL & CONFIGURE KIBANA
############################################
apt install -y kibana

cat >/etc/kibana/kibana.yml <<EOF
server.port: 5601
server.host: "0.0.0.0"
elasticsearch.hosts: ["http://localhost:9200"]
elasticsearch.username: kibana_system
elasticsearch.password: ${KIBANA_PASSWORD}
EOF

systemctl enable kibana
systemctl restart kibana

############################################
# DONE
############################################
PUBLIC_IP=$(curl -s https://checkip.amazonaws.com || true)

echo "======================================="
echo "SUCCESS"
echo "Elasticsearch : http://$PUBLIC_IP:9200"
echo "Kibana        : http://$PUBLIC_IP:5601"
echo "Secret        : $SECRET_NAME"
echo "======================================="
