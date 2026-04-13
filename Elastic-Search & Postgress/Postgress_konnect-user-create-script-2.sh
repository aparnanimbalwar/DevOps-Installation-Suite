#!/bin/bash
set -euo pipefail

echo "🔐 PostgreSQL User & Permission Bootstrap (STRICT MODE)"

########################################
# Variables
########################################

DB_NAME="konnect_postgress_dev"

RO_USER="konnect_dev_ro"
RW_USER="konnect_dev_rw"
APP_USER="app_user_dev"

# ⚠️ Recommended: move these to AWS Secrets Manager later
RO_PASS="Konnect-ro-123"
RW_PASS="Konnect-rw-admin-123"

########################################
# 1️⃣ Validate database exists
########################################

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  echo "❌ ERROR: Database ${DB_NAME} does NOT exist"
  echo "👉 Aborting. Database must be created by infra script."
  exit 1
fi

echo "✅ Database ${DB_NAME} exists"

########################################
# 2️⃣ Create / update roles
########################################

sudo -u postgres psql <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${RO_USER}') THEN
    CREATE ROLE ${RO_USER} LOGIN PASSWORD '${RO_PASS}';
  ELSE
    ALTER ROLE ${RO_USER} WITH PASSWORD '${RO_PASS}';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${RW_USER}') THEN
    CREATE ROLE ${RW_USER} LOGIN PASSWORD '${RW_PASS}';
  ELSE
    ALTER ROLE ${RW_USER} WITH PASSWORD '${RW_PASS}';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${APP_USER}') THEN
    CREATE ROLE ${APP_USER} LOGIN;
  END IF;
END
\$\$;
EOF

########################################
# 3️⃣ Grant permissions
########################################

sudo -u postgres psql -d "${DB_NAME}" <<EOF
-- Database access
GRANT CONNECT ON DATABASE ${DB_NAME} TO ${RO_USER}, ${RW_USER}, ${APP_USER};

-- Schema access
GRANT USAGE ON SCHEMA public TO ${RO_USER}, ${RW_USER}, ${APP_USER};

----------------------------------------
-- Read-only user
----------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${RO_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT SELECT ON TABLES TO ${RO_USER};

----------------------------------------
-- Read-write admin user
----------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${RW_USER};
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO ${RW_USER};

ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${RW_USER};

ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT ALL ON SEQUENCES TO ${RW_USER};

----------------------------------------
-- Application user (FULL ACCESS)
----------------------------------------
GRANT ALL ON SCHEMA public TO ${APP_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${APP_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${APP_USER};

ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT ALL ON TABLES TO ${APP_USER};

ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT ALL ON SEQUENCES TO ${APP_USER};
EOF

########################################
# DONE
########################################

echo "=========================================="
echo "✅ PostgreSQL configuration completed"
echo "=========================================="
echo "Database       : ${DB_NAME}"
echo "RO User        : ${RO_USER}"
echo "RW User        : ${RW_USER}"
echo "App User       : ${APP_USER}"
echo "=========================================="
