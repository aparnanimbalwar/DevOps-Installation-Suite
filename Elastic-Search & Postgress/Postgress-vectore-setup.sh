#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/postgres_pgvector_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "🟢 Starting PostgreSQL + pgvector EC2 Setup"

#############################
# BASIC CONFIG
#############################

PG_DATA_DIR="/data/postgresql"
SETUP_MARKER="/var/lib/postgresql/.setup_complete"

#############################
# 1️⃣ System Dependencies
#############################

echo "📦 Installing system dependencies..."
apt update -y
apt install -y curl wget gnupg lsb-release jq ufw unzip

#############################
# 2️⃣ AWS CLI (if missing)
#############################

if ! command -v aws &>/dev/null; then
  echo "📦 Installing AWS CLI..."
  curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip
  unzip -q awscliv2.zip
  ./aws/install
  rm -rf aws awscliv2.zip
fi

#############################
# 3️⃣ EC2 Metadata (IMDSv2)
#############################

echo "🔍 Detecting EC2 metadata..."

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

ENVIRONMENT=$(aws ec2 describe-tags \
  --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Environment" \
  --region "$REGION" \
  --query "Tags[0].Value" \
  --output text 2>/dev/null || true)

[ -z "$ENVIRONMENT" ] || [ "$ENVIRONMENT" = "None" ] && ENVIRONMENT="prod"

echo "🔹 Environment: $ENVIRONMENT"
echo "🔹 Private IP: $PRIVATE_IP"

#############################
# 4️⃣ Fetch Secret
#############################

SECRET_NAME="konnect/postgres/$ENVIRONMENT"
echo "🔐 Fetching secret: $SECRET_NAME"

SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --region "$REGION" \
  --query SecretString \
  --output text)

PG_USER=$(echo "$SECRET_JSON" | jq -r .username)
PG_PASSWORD=$(echo "$SECRET_JSON" | jq -r .password)
PG_DB=$(echo "$SECRET_JSON" | jq -r .dbname)
PG_PORT=$(echo "$SECRET_JSON" | jq -r .port)

#############################
# 5️⃣ Idempotency Check
#############################

if [ -f "$SETUP_MARKER" ]; then
  echo "⚠️ PostgreSQL already configured — exiting"
  exit 0
fi

#############################
# 6️⃣ PostgreSQL Repository
#############################

echo "📦 Preparing PostgreSQL repository..."

if [ ! -f /usr/share/keyrings/postgresql.gpg ]; then
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
    gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
fi

echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
> /etc/apt/sources.list.d/pgdg.list

apt update -y

#############################
# 7️⃣ Install PostgreSQL Server (IMPORTANT FIX)
#############################

echo "📦 Installing PostgreSQL server..."
apt install -y postgresql

#############################
# 8️⃣ Detect PostgreSQL Version (AFTER install)
#############################

POSTGRES_VERSION=$(pg_lsclusters --no-header | awk '{print $1}' | sort -V | tail -n1)

if [ -z "$POSTGRES_VERSION" ]; then
  echo "❌ PostgreSQL cluster not found"
  exit 1
fi

echo "🔍 Detected PostgreSQL version: $POSTGRES_VERSION"

#############################
# 9️⃣ Install pgvector
#############################

echo "📦 Installing pgvector..."
apt install -y \
  postgresql-contrib-$POSTGRES_VERSION \
  postgresql-$POSTGRES_VERSION-pgvector

PG_CONF_DIR="/etc/postgresql/$POSTGRES_VERSION/main"

#############################
# 🔟 PostgreSQL Configuration
#############################

echo "⚙️ Configuring PostgreSQL..."

systemctl stop postgresql

mkdir -p "$PG_DATA_DIR"
chown postgres:postgres "$PG_DATA_DIR"

sed -i "s|^#data_directory.*|data_directory = '$PG_DATA_DIR'|" \
  "$PG_CONF_DIR/postgresql.conf"

sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" \
  "$PG_CONF_DIR/postgresql.conf"

grep -q "0.0.0.0/0" "$PG_CONF_DIR/pg_hba.conf" || \
echo "host all all 0.0.0.0/0 md5" >> "$PG_CONF_DIR/pg_hba.conf"

systemctl start postgresql
sleep 5

#############################
# ⓫ Create DB, User & pgvector
#############################

echo "🧠 Creating database, user & pgvector..."

if ! sudo -u postgres psql -tAc \
  "SELECT 1 FROM pg_database WHERE datname='$PG_DB'" | grep -q 1; then
  sudo -u postgres createdb "$PG_DB"
fi

sudo -u postgres psql <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$PG_USER') THEN
    CREATE USER $PG_USER WITH PASSWORD '$PG_PASSWORD';
  ELSE
    ALTER USER $PG_USER WITH PASSWORD '$PG_PASSWORD';
  END IF;
END
\$\$;

GRANT ALL PRIVILEGES ON DATABASE $PG_DB TO $PG_USER;
EOF

sudo -u postgres psql -d "$PG_DB" <<EOF
CREATE EXTENSION IF NOT EXISTS vector;
EOF

#############################
# ⓬ Firewall
#############################

echo "🔥 Configuring firewall..."
ufw --force enable
ufw allow 22/tcp
ufw allow "$PG_PORT"/tcp comment 'PostgreSQL'
ufw reload

#############################
# ⓭ Marker
#############################

mkdir -p /var/lib/postgresql
touch "$SETUP_MARKER"
chown postgres:postgres "$SETUP_MARKER"

#############################
# 🎉 Done
#############################

echo ""
echo "=========================================="
echo "🎉 PostgreSQL + pgvector Setup Complete!"
echo "=========================================="
echo "Environment : $ENVIRONMENT"
echo "Postgres    : $POSTGRES_VERSION"
echo "Database    : $PG_DB"
echo "User        : $PG_USER"
echo "Port        : $PG_PORT"
echo "pgvector    : ENABLED"
echo "=========================================="
