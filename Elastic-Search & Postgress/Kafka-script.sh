#!/bin/bash
set -e

echo "========== Kafka Installation Started =========="

apt update -y
apt install -y openjdk-11-jdk jq wget curl unzip

# Install AWS CLI v2 (idempotent)
if ! command -v aws &> /dev/null; then
  echo "Installing AWS CLI v2..."
  cd /tmp
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip -q awscliv2.zip
  ./aws/install
else
  echo "AWS CLI already installed"
fi

# -------------------------------
# Fetch instance metadata (IMDSv2)
# -------------------------------
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/dynamic/instance-identity/document \
  | jq -r '.region')

PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

# -------------------------------
# Fetch Environment tag
# -------------------------------
ENVIRONMENT=$(aws ec2 describe-tags \
  --region "$REGION" \
  --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Environment" \
  --query "Tags[0].Value" \
  --output text)

if [[ -z "$ENVIRONMENT" || "$ENVIRONMENT" == "None" ]]; then
  echo "ERROR: Environment tag not found on EC2"
  exit 1
fi

echo "Environment detected: $ENVIRONMENT"

# -------------------------------
# Resolve Secret Name dynamically
# -------------------------------
SECRET_NAME="konnect/kafka-${ENVIRONMENT}/${ENVIRONMENT}"
echo "Using Secret: $SECRET_NAME"

# -------------------------------
# Fetch secrets
# -------------------------------
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --region "$REGION" \
  --query SecretString \
  --output text)

# -------------------------------
# Export variables from secret
# -------------------------------
KAFKA_VERSION=$(echo "$SECRET_JSON" | jq -r '.KAFKA_VERSION')
SCALA_VERSION=$(echo "$SECRET_JSON" | jq -r '.SCALA_VERSION')
KAFKA_USER=$(echo "$SECRET_JSON" | jq -r '.KAFKA_USER')
INSTALL_DIR=$(echo "$SECRET_JSON" | jq -r '.INSTALL_DIR')
DATA_DIR=$(echo "$SECRET_JSON" | jq -r '.DATA_DIR')
KAFKA_CLUSTER_ID=$(echo "$SECRET_JSON" | jq -r '.KAFKA_CLUSTER_ID')
KAFKA_BROKER_ID=$(echo "$PRIVATE_IP" | awk -F. '{print $4}')
KAFKA_LISTENERS=$(echo "$SECRET_JSON" | jq -r '.KAFKA_LISTENERS')
KAFKA_ADVERTISED_LISTENERS=$(echo "$SECRET_JSON" | jq -r '.KAFKA_ADVERTISED_LISTENERS')

# -------------------------------
# Replace PRIVATE IP placeholder
# -------------------------------
KAFKA_ADVERTISED_LISTENERS=$(echo "$KAFKA_ADVERTISED_LISTENERS" \
  | sed "s/__PRIVATE_IP__/$PRIVATE_IP/g")

echo "Secrets loaded successfully"
echo "Final advertised listeners: $KAFKA_ADVERTISED_LISTENERS"

# -------------------------------
# Create Kafka user
# -------------------------------
useradd -r -m -s /bin/bash "$KAFKA_USER" || true

# -------------------------------
# Download & Install Kafka
# -------------------------------
if [ ! -d "$INSTALL_DIR/bin" ]; then
  echo "Installing Kafka..."

  cd /tmp
  rm -rf kafka_${SCALA_VERSION}-${KAFKA_VERSION}*
  wget https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz
  tar -xzf kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz
  mv kafka_${SCALA_VERSION}-${KAFKA_VERSION} "$INSTALL_DIR"
else
  echo "Kafka already installed at $INSTALL_DIR — skipping download"
fi


# -------------------------------
# Create directories
# -------------------------------
mkdir -p "$DATA_DIR"
chown -R "$KAFKA_USER:$KAFKA_USER" "$INSTALL_DIR" "$DATA_DIR"

# -------------------------------
# Kafka configuration (KRaft)
# -------------------------------
CONFIG_FILE="$INSTALL_DIR/config/kraft/server.properties"

cat > "$CONFIG_FILE" <<EOF
process.roles=broker,controller
node.id=$KAFKA_BROKER_ID

controller.listener.names=CONTROLLER
controller.quorum.voters=$KAFKA_BROKER_ID@127.0.0.1:9093

listeners=$KAFKA_LISTENERS,CONTROLLER://127.0.0.1:9093
advertised.listeners=$KAFKA_ADVERTISED_LISTENERS

listener.security.protocol.map=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
inter.broker.listener.name=PLAINTEXT

log.dirs=$DATA_DIR
num.partitions=3
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
EOF


# -------------------------------
# Format Kafka storage (KRaft)
# -------------------------------
sudo -u "$KAFKA_USER" "$INSTALL_DIR/bin/kafka-storage.sh" format \
  -t "$KAFKA_CLUSTER_ID" \
  -c "$CONFIG_FILE"

# -------------------------------
# Systemd service
# -------------------------------
cat > /etc/systemd/system/kafka.service <<EOF
[Unit]
Description=Apache Kafka
After=network.target

[Service]
User=$KAFKA_USER
ExecStart=$INSTALL_DIR/bin/kafka-server-start.sh $CONFIG_FILE
ExecStop=$INSTALL_DIR/bin/kafka-server-stop.sh
Restart=always
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kafka
systemctl start kafka

echo "========== Kafka Installed Successfully =========="
