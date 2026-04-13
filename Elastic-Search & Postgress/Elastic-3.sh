#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/elasticsearch_kibana_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "🟢 Elasticsearch + Kibana CLEAN INSTALL"

#################################
# System packages
#################################
apt update -y
apt install -y curl wget jq gnupg unzip

#################################
# AWS CLI
#################################
if ! command -v aws >/dev/null; then
  curl -s https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip
  unzip -q awscliv2.zip
  ./aws/install
fi

#################################
# EC2 Metadata
#################################
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

#################################
# Secrets
#################################
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id konnect/elasticsearch-kibana/dev \
  --region "$REGION" \
  --query SecretString \
  --output text)

ELASTIC_PASSWORD=$(jq -r .Elastic_Password <<<"$SECRET_JSON")
KIBANA_PASSWORD=$(jq -r .Kibana_Password <<<"$SECRET_JSON")
CLUSTER_NAME=$(jq -r .Cluster_Name <<<"$SECRET_JSON")
NODE_NAME=$(jq -r .Node_Name <<<"$SECRET_JSON")
NETWORK_HOST=$(jq -r .Network_Host <<<"$SECRET_JSON")

#################################
# Kernel tuning
#################################
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >/etc/sysctl.d/99-elasticsearch.conf
sysctl --system

#################################
# Elasticsearch repo
#################################
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
 | gpg --dearmor -o /usr/share/keyrings/elastic-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/elastic-keyring.gpg] \
https://artifacts.elastic.co/packages/8.x/apt stable main" \
> /etc/apt/sources.list.d/elastic-8.x.list

apt update -y
apt install -y elasticsearch

#################################
# Elasticsearch config (TLS OFF)
#################################
cat >/etc/elasticsearch/elasticsearch.yml <<EOF
cluster.name: ${CLUSTER_NAME}
node.name: ${NODE_NAME}
network.host: ${NETWORK_HOST}
http.port: 9200

discovery.type: single-node

xpack.security.enabled: true
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false
EOF

#################################
# Start Elasticsearch
#################################
systemctl daemon-reexec
systemctl enable elasticsearch
systemctl start elasticsearch

#################################
# Wait for ES
#################################
echo "⏳ Waiting for Elasticsearch..."
until curl -s http://localhost:9200 >/dev/null; do sleep 3; done

#################################
# Reset passwords
#################################
echo "$ELASTIC_PASSWORD" | \
/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -i

echo "$KIBANA_PASSWORD" | \
/usr/share/elasticsearch/bin/elasticsearch-reset-password -u kibana_system -i

#################################
# Install Kibana
#################################
apt install -y kibana

#################################
# Kibana config
#################################
cat >/etc/kibana/kibana.yml <<EOF
server.port: 5601
server.host: "0.0.0.0"

elasticsearch.hosts: ["http://localhost:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${KIBANA_PASSWORD}"
EOF

#################################
# Start Kibana
#################################
systemctl daemon-reexec
systemctl enable kibana
systemctl start kibana

#################################
# Final check
#################################
curl -u elastic:${ELASTIC_PASSWORD} http://localhost:9200

echo "=================================="
echo "✅ SETUP COMPLETE"
echo "Elasticsearch : http://<EC2-IP>:9200"
echo "Kibana        : http://<EC2-IP>:5601"
echo "=================================="
