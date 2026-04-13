#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/elastic_kibana_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "🟢 Elasticsearch + Kibana CLEAN INSTALL (8.x SAFE)"

############################################
# VARIABLES
############################################
CLUSTER_NAME="konnect-Elastic-Dev"
NODE_NAME="elastic-node-01"
NETWORK_HOST="0.0.0.0"

ELASTIC_PASSWORD="Elastic@123"
KIBANA_PASSWORD="Kibana@123"

############################################
# 1. FULL CLEANUP
############################################
echo "🧹 Cleaning previous installs"

systemctl stop elasticsearch kibana || true
systemctl disable elasticsearch kibana || true
systemctl mask elasticsearch || true

apt purge -y elasticsearch kibana || true

rm -rf \
 /etc/elasticsearch \
 /var/lib/elasticsearch \
 /var/log/elasticsearch \
 /etc/kibana \
 /var/lib/kibana \
 /var/log/kibana \
 /usr/share/elasticsearch \
 /usr/share/kibana \
 /etc/apt/sources.list.d/elastic-8.x.list \
 /usr/share/keyrings/elastic-keyring.gpg

systemctl daemon-reload
apt autoremove -y
apt autoclean -y

############################################
# 2. SYSTEM TUNING
############################################
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >/etc/sysctl.d/99-elasticsearch.conf
sysctl --system

############################################
# 3. DEPENDENCIES
############################################
apt update -y
apt install -y curl wget gnupg jq unzip

############################################
# 4. ADD ELASTIC REPO
############################################
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
 | gpg --dearmor -o /usr/share/keyrings/elastic-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/elastic-keyring.gpg] \
https://artifacts.elastic.co/packages/8.x/apt stable main" \
> /etc/apt/sources.list.d/elastic-8.x.list

apt update -y

############################################
# 5. INSTALL ELASTICSEARCH (NO AUTOSTART)
############################################
echo "📦 Installing Elasticsearch (service masked)"
systemctl mask elasticsearch
apt install -y elasticsearch

############################################
# 6. DISABLE AUTO SECURITY CLEANLY
############################################
rm -rf /etc/elasticsearch/certs
rm -f /etc/elasticsearch/elasticsearch.keystore

/usr/share/elasticsearch/bin/elasticsearch-keystore create
chown elasticsearch:elasticsearch /etc/elasticsearch/elasticsearch.keystore

############################################
# 7. CONFIGURE ELASTICSEARCH (VALID)
############################################
cat >/etc/elasticsearch/elasticsearch.yml <<EOF
cluster.name: ${CLUSTER_NAME}
node.name: ${NODE_NAME}
network.host: ${NETWORK_HOST}
http.port: 9200

discovery.type: single-node

xpack.security.enabled: true
xpack.security.autoconfiguration.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false
EOF

chown -R elasticsearch:elasticsearch /etc/elasticsearch

############################################
# 8. START ELASTICSEARCH PROPERLY
############################################
systemctl unmask elasticsearch
systemctl daemon-reexec
systemctl enable elasticsearch
systemctl start elasticsearch

echo "⏳ Waiting for Elasticsearch..."
for i in {1..30}; do
  if curl -s http://localhost:9200 >/dev/null; then break; fi
  sleep 2
done

############################################
# 9. RESET PASSWORDS
############################################
echo "$ELASTIC_PASSWORD" | \
/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -i

echo "$KIBANA_PASSWORD" | \
/usr/share/elasticsearch/bin/elasticsearch-reset-password -u kibana_system -i

############################################
# 10. INSTALL KIBANA
############################################
apt install -y kibana

cat >/etc/kibana/kibana.yml <<EOF
server.port: 5601
server.host: "0.0.0.0"

elasticsearch.hosts: ["http://localhost:9200"]
elasticsearch.username: kibana_system
elasticsearch.password: ${KIBANA_PASSWORD}
EOF

chown kibana:kibana /etc/kibana/kibana.yml
chmod 640 /etc/kibana/kibana.yml

systemctl enable kibana
systemctl restart kibana

############################################
# DONE
############################################
echo "======================================="
echo "🎉 SUCCESS – NO LOOPS – NO FAILURES"
echo "======================================="
echo "Elasticsearch : http://<EC2-IP>:9200"
echo "Kibana        : http://<EC2-IP>:5601"
echo "elastic user  : elastic / ${ELASTIC_PASSWORD}"
echo "======================================="
echo "Executing 5th Script"