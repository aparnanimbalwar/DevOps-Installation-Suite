#!/bin/bash
set -euo pipefail
LOG_FILE="/var/log/mongodb_kafka_setup.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "🟢 Starting MongoDB + Kafka EC2 Setup..."

#############################
# BASIC CONFIGURATION
#############################

USER_HOME="/home/ubuntu"
USER_NAME="ubuntu"
KAFKA_VERSION="3.6.1"
SCALA_VERSION="2.13"
KAFKA_HOME="/opt/kafka"

#############################
# 1️⃣ Install Dependencies
#############################
echo "📦 Installing system dependencies..."
sudo apt update -y
sudo apt install -y curl wget gnupg unzip jq openssl openjdk-17-jdk

#############################
# 2️⃣ Install AWS CLI v2
#############################
echo "📦 Installing AWS CLI v2..."
if ! command -v aws &> /dev/null; then
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    sudo ./aws/install
    rm -rf aws awscliv2.zip
    echo "✅ AWS CLI v2 installed"
else
    echo "✅ AWS CLI already installed"
fi

export PATH="/usr/local/bin:$PATH"
aws --version
java -version

#############################
# 3️⃣ Detect Environment from EC2 Tag
#############################
echo "🔍 Detecting environment from EC2 tags..."

TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)

INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)

REGION=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null)

PRIVATE_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  -s http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)

echo "🔹 Instance ID: $INSTANCE_ID"
echo "🔹 Region: $REGION"
echo "🔹 Private IP: $PRIVATE_IP"

if [ -n "$INSTANCE_ID" ] && [ -n "$REGION" ]; then
    ENVIRONMENT=$(aws ec2 describe-tags \
        --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Environment" \
        --region "$REGION" \
        --query "Tags[0].Value" \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$ENVIRONMENT" ] || [ "$ENVIRONMENT" = "None" ]; then
        echo "⚠️ No Environment tag found, defaulting to prod"
        ENVIRONMENT="prod"
    fi
else
    echo "⚠️ Failed to get instance metadata, defaulting to prod"
    ENVIRONMENT="prod"
fi

echo "🔹 Detected Environment: $ENVIRONMENT"

#############################
# 4️⃣ Check if Already Setup
#############################

MONGO_SETUP_MARKER="/var/lib/mongodb/.setup_complete"
KAFKA_SETUP_MARKER="/var/lib/kafka/.setup_complete"

if [ -f "$MONGO_SETUP_MARKER" ] && [ -f "$KAFKA_SETUP_MARKER" ]; then
    echo "⚠️  MongoDB and Kafka already setup on this instance"
    echo ""
    echo "To re-run setup:"
    echo "  sudo rm $MONGO_SETUP_MARKER $KAFKA_SETUP_MARKER"
    echo "  sudo systemctl stop mongod kafka zookeeper"
    echo "  sudo rm -rf /data/mongodb/* /var/lib/kafka/*"
    echo ""
    exit 0
fi

#############################
# PART 1: MONGODB SETUP
#############################

if [ ! -f "$MONGO_SETUP_MARKER" ]; then
    echo ""
    echo "=========================================="
    echo "🟢 PART 1: MongoDB Installation"
    echo "=========================================="
    echo ""

    MONGO_SECRET_NAME="konnect/mongodb/$ENVIRONMENT"
    
    # Check if Secret already exists
    EXISTING_SECRET=$(aws secretsmanager get-secret-value \
        --secret-id "$MONGO_SECRET_NAME" \
        --region "$REGION" \
        --query SecretString \
        --output text 2>/dev/null || echo "")

    if [ -n "$EXISTING_SECRET" ] && [ "$EXISTING_SECRET" != "{}" ]; then
        echo "⚠️  MongoDB secret already exists: $MONGO_SECRET_NAME"
        echo "Skipping MongoDB setup. Delete secret to reconfigure."
    else
        # Install MongoDB
        echo "📦 Installing MongoDB 7.0..."
        curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | \
            sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg

        echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | \
            sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list

        sudo apt update -y
        sudo apt install -y mongodb-org
        echo "✅ MongoDB 7.0 installed"

        # Generate credentials
        MONGO_ROOT_USERNAME="admin"
        MONGO_ROOT_PASSWORD=$(openssl rand -base64 32)
        MONGO_APP_USERNAME="app_user_$ENVIRONMENT"
        MONGO_APP_PASSWORD=$(openssl rand -base64 32)
        MONGO_DATABASE="konnect_$ENVIRONMENT"

        # Configure MongoDB
        MONGO_PORT=27017
        MONGO_DATA_DIR="/data/mongodb"
        MONGO_KEY_DIR="/data/mongodb/keyfile"
        MONGO_KEY_FILE="$MONGO_KEY_DIR/mongo-keyfile"

        sudo mkdir -p "$MONGO_DATA_DIR" "$MONGO_KEY_DIR" /var/log/mongodb
        sudo openssl rand -base64 756 | sudo tee "$MONGO_KEY_FILE" > /dev/null
        sudo chmod 600 "$MONGO_KEY_FILE"
        sudo chown -R mongodb:mongodb "$MONGO_DATA_DIR" /var/log/mongodb "$MONGO_KEY_DIR"

        # Initial config (no auth)
        sudo tee /etc/mongod.conf > /dev/null <<MONGO_CONFIG
storage:
  dbPath: $MONGO_DATA_DIR
  wiredTiger:
    engineConfig:
      cacheSizeGB: 2
systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true
net:
  port: $MONGO_PORT
  bindIp: 0.0.0.0
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
replication:
  replSetName: rs0
MONGO_CONFIG

        # Start MongoDB
        sudo systemctl enable mongod
        sudo systemctl restart mongod
        sleep 5

        # Initialize replica set
        mongosh --port $MONGO_PORT --eval "
        try {
            rs.initiate({
                _id: 'rs0',
                members: [{ _id: 0, host: '$PRIVATE_IP:$MONGO_PORT' }]
            });
            print('✅ Replica set initialized');
        } catch(e) {
            if (e.code !== 23) { print('❌ Error: ' + e); quit(1); }
        }"

        sleep 10

        # Create users
        mongosh --port $MONGO_PORT --eval "
        db = db.getSiblingDB('admin');
        db.createUser({
            user: '$MONGO_ROOT_USERNAME',
            pwd: '$MONGO_ROOT_PASSWORD',
            roles: [{ role: 'root', db: 'admin' }]
        });"

        mongosh --port $MONGO_PORT --eval "
        db = db.getSiblingDB('$MONGO_DATABASE');
        db.createUser({
            user: '$MONGO_APP_USERNAME',
            pwd: '$MONGO_APP_PASSWORD',
            roles: [
                { role: 'readWrite', db: '$MONGO_DATABASE' },
                { role: 'dbAdmin', db: '$MONGO_DATABASE' }
            ]
        });"

        # Enable authentication
        sudo tee /etc/mongod.conf > /dev/null <<MONGO_CONFIG_AUTH
storage:
  dbPath: $MONGO_DATA_DIR
  wiredTiger:
    engineConfig:
      cacheSizeGB: 2
systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true
  logRotate: reopen
net:
  port: $MONGO_PORT
  bindIp: 0.0.0.0
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
security:
  authorization: enabled
  keyFile: $MONGO_KEY_FILE
replication:
  replSetName: rs0
MONGO_CONFIG_AUTH

        sudo systemctl restart mongod
        sleep 5

        # Save to Secrets Manager
        MONGO_URI="mongodb://$MONGO_APP_USERNAME:$MONGO_APP_PASSWORD@$PRIVATE_IP:$MONGO_PORT/$MONGO_DATABASE?authSource=$MONGO_DATABASE&replicaSet=rs0"
        
        SECRET_VALUE=$(cat <<EOF
{
  "MONGO_ROOT_USERNAME": "$MONGO_ROOT_USERNAME",
  "MONGO_ROOT_PASSWORD": "$MONGO_ROOT_PASSWORD",
  "MONGO_APP_USERNAME": "$MONGO_APP_USERNAME",
  "MONGO_APP_PASSWORD": "$MONGO_APP_PASSWORD",
  "MONGO_DATABASE": "$MONGO_DATABASE",
  "MONGO_HOST": "$PRIVATE_IP",
  "MONGO_PORT": "$MONGO_PORT",
  "MONGO_URI": "$MONGO_URI"
}
EOF
)

        aws secretsmanager create-secret \
            --name "$MONGO_SECRET_NAME" \
            --secret-string "$SECRET_VALUE" \
            --region "$REGION" 2>/dev/null || \
        aws secretsmanager update-secret \
            --secret-id "$MONGO_SECRET_NAME" \
            --secret-string "$SECRET_VALUE" \
            --region "$REGION"

        echo "✅ MongoDB setup complete!"

        # Create marker
        sudo mkdir -p /var/lib/mongodb
        sudo touch "$MONGO_SETUP_MARKER"
        sudo chown mongodb:mongodb "$MONGO_SETUP_MARKER"
    fi
fi

#############################
# PART 2: KAFKA SETUP
#############################

if [ ! -f "$KAFKA_SETUP_MARKER" ]; then
    echo ""
    echo "=========================================="
    echo "🔴 PART 2: Kafka Installation"
    echo "=========================================="
    echo ""

    KAFKA_SECRET_NAME="konnect/kafka/$ENVIRONMENT"

    # Download Kafka
    echo "📥 Downloading Kafka ${KAFKA_VERSION}..."
    cd /tmp
    KAFKA_ARCHIVE="kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
    KAFKA_URL="https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/${KAFKA_ARCHIVE}"

    if [ ! -f "$KAFKA_ARCHIVE" ]; then
        wget -q "$KAFKA_URL" || {
            echo "❌ Failed to download Kafka"
            exit 1
        }
    fi

    # Install Kafka
    echo "📦 Installing Kafka..."
    sudo mkdir -p "$KAFKA_HOME"
    sudo tar -xzf "$KAFKA_ARCHIVE" -C /opt/
    sudo mv /opt/kafka_${SCALA_VERSION}-${KAFKA_VERSION}/* "$KAFKA_HOME/"
    sudo rm -rf /opt/kafka_${SCALA_VERSION}-${KAFKA_VERSION}

    # Create directories
    sudo mkdir -p /var/lib/kafka/data /var/lib/kafka/zookeeper /var/log/kafka

    # Create kafka user
    if ! id kafka &>/dev/null; then
        sudo useradd -r -s /bin/false kafka
    fi

    sudo chown -R kafka:kafka "$KAFKA_HOME" /var/lib/kafka /var/log/kafka

    # Configure Zookeeper
    sudo tee "$KAFKA_HOME/config/zookeeper.properties" > /dev/null <<ZOOKEEPER_CONFIG
dataDir=/var/lib/kafka/zookeeper
clientPort=2181
maxClientCnxns=0
admin.enableServer=false
tickTime=2000
initLimit=10
syncLimit=5
ZOOKEEPER_CONFIG

    # Configure Kafka
    case "$ENVIRONMENT" in
        dev) BROKER_ID=1 ;;
        prod) BROKER_ID=2 ;;
        test) BROKER_ID=3 ;;
        *) BROKER_ID=1 ;;
    esac

    sudo tee "$KAFKA_HOME/config/server.properties" > /dev/null <<KAFKA_CONFIG
broker.id=$BROKER_ID
listeners=PLAINTEXT://$PRIVATE_IP:9092
advertised.listeners=PLAINTEXT://$PRIVATE_IP:9092
num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
log.dirs=/var/lib/kafka/data
num.partitions=3
num.recovery.threads.per.data.dir=1
log.retention.hours=168
log.retention.check.interval.ms=300000
log.segment.bytes=1073741824
zookeeper.connect=localhost:2181
zookeeper.connection.timeout.ms=18000
group.initial.rebalance.delay.ms=0
compression.type=snappy
auto.create.topics.enable=false
delete.topic.enable=true
KAFKA_CONFIG

    # Create systemd services
    sudo tee /etc/systemd/system/zookeeper.service > /dev/null <<ZOOKEEPER_SERVICE
[Unit]
Description=Apache Zookeeper Server ($ENVIRONMENT)
Requires=network.target
After=network.target

[Service]
Type=simple
User=kafka
Group=kafka
Environment="KAFKA_HEAP_OPTS=-Xmx512M -Xms512M"
ExecStart=$KAFKA_HOME/bin/zookeeper-server-start.sh $KAFKA_HOME/config/zookeeper.properties
ExecStop=$KAFKA_HOME/bin/zookeeper-server-stop.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
ZOOKEEPER_SERVICE

    sudo tee /etc/systemd/system/kafka.service > /dev/null <<KAFKA_SERVICE
[Unit]
Description=Apache Kafka Server ($ENVIRONMENT)
Requires=zookeeper.service
After=zookeeper.service

[Service]
Type=simple
User=kafka
Group=kafka
Environment="KAFKA_HEAP_OPTS=-Xmx1G -Xms1G"
ExecStart=$KAFKA_HOME/bin/kafka-server-start.sh $KAFKA_HOME/config/server.properties
ExecStop=$KAFKA_HOME/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
KAFKA_SERVICE

    # Start services
    echo "🚀 Starting Zookeeper and Kafka..."
    sudo systemctl daemon-reload
    sudo systemctl enable zookeeper kafka
    sudo systemctl start zookeeper
    sleep 10
    sudo systemctl start kafka
    sleep 15

    # Verify
    if sudo systemctl is-active --quiet zookeeper && sudo systemctl is-active --quiet kafka; then
        echo "✅ Kafka and Zookeeper started successfully"
    else
        echo "❌ Failed to start Kafka services"
        exit 1
    fi

    # Save to Secrets Manager
    SECRET_VALUE=$(cat <<EOF
{
  "KAFKA_BROKERS": "$PRIVATE_IP:9092",
  "KAFKA_HOST": "$PRIVATE_IP",
  "KAFKA_PORT": "9092",
  "ZOOKEEPER_CONNECT": "$PRIVATE_IP:2181",
  "KAFKA_VERSION": "$KAFKA_VERSION",
  "BROKER_ID": "$BROKER_ID"
}
EOF
)

    aws secretsmanager create-secret \
        --name "$KAFKA_SECRET_NAME" \
        --secret-string "$SECRET_VALUE" \
        --region "$REGION" 2>/dev/null || \
    aws secretsmanager update-secret \
        --secret-id "$KAFKA_SECRET_NAME" \
        --secret-string "$SECRET_VALUE" \
        --region "$REGION"

    echo "✅ Kafka setup complete!"

    # Create marker
    sudo mkdir -p /var/lib/kafka
    sudo touch "$KAFKA_SETUP_MARKER"
    sudo chown kafka:kafka "$KAFKA_SETUP_MARKER"
fi

#############################
# Configure Firewall
#############################

echo "🔥 Configuring firewall..."
sudo ufw --force enable
sudo ufw allow 22/tcp
sudo ufw allow 27017/tcp comment 'MongoDB'
sudo ufw allow 9092/tcp comment 'Kafka'
sudo ufw allow 2181/tcp comment 'Zookeeper'
sudo ufw reload
echo "✅ Firewall configured"

#############################
# Create Management Scripts
#############################

# MongoDB monitor
cat > "$USER_HOME/mongo-monitor.sh" <<'MONGO_MONITOR'
#!/bin/bash
echo "📊 MongoDB Status"
sudo systemctl status mongod --no-pager | grep "Active:"
df -h /data/mongodb
MONGO_MONITOR

# Kafka management
cat > "$USER_HOME/kafka-manage.sh" <<'KAFKA_MANAGE'
#!/bin/bash
KAFKA_HOME="/opt/kafka"
case "$1" in
    status)
        sudo systemctl status zookeeper kafka --no-pager ;;
    topics)
        sudo -u kafka $KAFKA_HOME/bin/kafka-topics.sh --list --bootstrap-server localhost:9092 ;;
    create)
        sudo -u kafka $KAFKA_HOME/bin/kafka-topics.sh --create --bootstrap-server localhost:9092 --topic "$2" --partitions 3 --replication-factor 1 ;;
    *)
        echo "Usage: $0 {status|topics|create <topic-name>}" ;;
esac
KAFKA_MANAGE'

chmod +x "$USER_HOME/mongo-monitor.sh" "$USER_HOME/kafka-manage.sh"

#############################
# Final Summary
#############################

echo ""
echo "=========================================="
echo "🎉 Setup Complete!"
echo "=========================================="
echo ""
echo "📍 Environment: $ENVIRONMENT"
echo "🔹 Private IP: $PRIVATE_IP"
echo ""
echo "🟢 MongoDB:"
echo "   Port: 27017"
echo "   Secret: konnect/mongodb/$ENVIRONMENT"
echo ""
echo "🔴 Kafka:"
echo "   Broker: $PRIVATE_IP:9092"
echo "   Zookeeper: $PRIVATE_IP:2181"
echo "   Secret: konnect/kafka/$ENVIRONMENT"
echo ""
echo "📝 Management:"
echo "   $USER_HOME/mongo-monitor.sh"
echo "   $USER_HOME/kafka-manage.sh status"
echo "   $USER_HOME/kafka-manage.sh topics"
echo ""
echo "=========================================="