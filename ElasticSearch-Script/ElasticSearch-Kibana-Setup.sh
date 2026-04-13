#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/elastic_kibana_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== Elasticsearch + Kibana 8.x (Tag-Based Secrets | Append Mode) ====="

############################################
# STATIC FLAGS
############################################
FORCE_PASSWORD_ROTATION="${FORCE_PASSWORD_ROTATION:-false}"

############################################
# 1️⃣ SYSTEM TUNING
############################################
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >/etc/sysctl.d/99-elasticsearch.conf
sysctl --system

############################################
# 2️⃣ DEPENDENCIES
############################################
apt update -y
apt install -y curl gnupg jq unzip

############################################
# 3️⃣ AWS CLI (ENSURE PRESENT)
############################################
if command -v aws >/dev/null 2>&1; then
    echo "✅ AWS CLI already installed"
else
    echo "⬇️ Installing AWS CLI v2..."
    cd /tmp
    rm -rf aws awscliv2.zip
    curl -s https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip
    unzip -q awscliv2.zip
    ./aws/install
fi

############################################
# 4️⃣ EC2 METADATA (IMDSv2)
############################################
echo "🔍 Detecting EC2 metadata..."

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

############################################
# 5️⃣ ENVIRONMENT FROM EC2 TAG
############################################
ENVIRONMENT=$(aws ec2 describe-tags \
  --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Environment" \
  --region "$AWS_REGION" \
  --query "Tags[0].Value" \
  --output text 2>/dev/null || true)

if [[ -z "$ENVIRONMENT" || "$ENVIRONMENT" == "None" ]]; then
  echo "❌ ERROR: EC2 tag 'Environment' is missing."
  echo "👉 Please add tag: Environment=dev|qa|prod"
  exit 1
fi  

echo "🔹 Region      : $AWS_REGION"
echo "🔹 Environment : $ENVIRONMENT"

############################################
# 6️⃣ FETCH SECRETS
############################################
SECRET_NAME="konnect/elasticsearch-kibana/$ENVIRONMENT"
echo "🔐 Fetching secret: $SECRET_NAME"

RAW_SECRET=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$SECRET_NAME" \
  --query SecretString \
  --output text)

############################################
# 7️⃣ READ REQUIRED VARIABLES (EXISTING KEYS)
############################################
CLUSTER_NAME=$(echo "$RAW_SECRET" | jq -r '.cluster_name')
NODE_NAME=$(echo "$RAW_SECRET" | jq -r '.node_name')
ELASTIC_PASSWORD=$(echo "$RAW_SECRET" | jq -r '.elastic_password // empty')
KIBANA_PASSWORD=$(echo "$RAW_SECRET" | jq -r '.kibana_system_password // empty')

############################################
# 8️⃣ VALIDATE CORE VALUES
############################################
for VAR in CLUSTER_NAME NODE_NAME
do
  if [[ -z "${!VAR}" || "${!VAR}" == "null" ]]; then
    echo "❌ ERROR: $VAR missing in Secrets Manager"
    exit 1
  fi
done

echo "✅ Secrets validation passed"

############################################
# 9️⃣ INSTALL ELASTICSEARCH
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

############################################
# 🔄 WAIT FOR ELASTICSEARCH
############################################
echo "⏳ Waiting for Elasticsearch..."
for i in {1..40}; do
  if curl -s http://localhost:9200 >/dev/null; then break; fi
  sleep 10
done

############################################
# 🔐 PASSWORD GENERATION (ALWAYS ROTATE)
############################################
echo "🔐 Resetting Elasticsearch passwords (authoritative mode)..."

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
  --arg rotated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '. + {
    elastic_password: $elastic,
    kibana_system_password: $kibana,
    last_rotated_at: $rotated_at
  }')

aws secretsmanager put-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$SECRET_NAME" \
  --secret-string "$UPDATED_SECRET"

echo "✅ Passwords rotated and stored in Secrets Manager"

sleep 10
echo "✅ Elasticsearch is up and running"


echo "############################################"


echo "Next Step is Setting up Kibana"
############################################
# 🔍 INSTALL & CONFIGURE KIBANA
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

sleep 10
echo "✅ Kibana is up and running"

############################################
# ✅ DONE
############################################
PUBLIC_IP=$(curl -s https://checkip.amazonaws.com || true)

echo "======================================="
echo "SUCCESS"
echo "Elasticsearch : http://$PUBLIC_IP:9200"
echo "Kibana        : http://$PUBLIC_IP:5601"
echo "Secret        : $SECRET_NAME"
echo "======================================="
