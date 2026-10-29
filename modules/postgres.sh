#!/usr/bin/env bash
# install/modules/postgres.sh - reuse or install PostgreSQL, then create the WafControl role + database.
# Inputs (environment): DB_NAME DB_USER DB_PASS [PG_VERSION DB_HOST DB_PORT]. Host installs only.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

trap 'err "Failed on line $LINENO"' ERR
require_root
export DEBIAN_FRONTEND=noninteractive
mkdir -p "$STATE_DIR"; touch "$STATE_FILE"

DB_NAME="${DB_NAME:?}"
DB_USER="${DB_USER:?}"
DB_PASS="${DB_PASS:?}"
PG_VERSION="${PG_VERSION:-}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"

banner "PostgreSQL setup"

pgdg_add_repo() {
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg
  . /etc/os-release
  echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  apt update -y
}

ensure_postgres() {
  local v="$1"
  apt install -y "postgresql-${v}" "postgresql-client-${v}" libpq-dev "postgresql-server-dev-${v}"
  svc_enable_now postgresql
  for _ in {1..60}; do pg_isready >/dev/null 2>&1 && break; sleep 1; done
}

find_pg_hba() {
  local v="$1" p
  p=$(find "/etc/postgresql/${v}" -maxdepth 3 -name pg_hba.conf 2>/dev/null | head -n1 || true)
  [[ -z "$p" ]] && p=$(find /etc/postgresql -maxdepth 4 -name pg_hba.conf 2>/dev/null | head -n1 || true)
  echo "$p"
}

find_postgresql_conf() {
  local v="$1" p
  p=$(find "/etc/postgresql/${v}" -maxdepth 3 -name postgresql.conf 2>/dev/null | head -n1 || true)
  [[ -z "$p" ]] && p=$(find /etc/postgresql -maxdepth 4 -name postgresql.conf 2>/dev/null | head -n1 || true)
  echo "$p"
}

extract_port_from_conf() {
  local conf="$1"
  [ -r "$conf" ] || { echo ""; return; }
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*port[[:space:]]*=/ {
      gsub(/#.*/,""); sub(/.*port[[:space:]]*=[[:space:]]*/,""); gsub(/[[:space:]]/,"");
      if ($0 ~ /^[0-9]+$/) p=$0
    }
    END{ if (p) print p }' "$conf"
}

line "-" 72
if command -v psql >/dev/null 2>&1; then
  INSTALLED_MAJOR="$(psql -V | awk '{print $3}' | cut -d. -f1)"
  PG_VERSION="${INSTALLED_MAJOR}"
  say "Detected PostgreSQL ${PG_VERSION} (reuse)."
  PG_CONF="$(find_postgresql_conf "$PG_VERSION")"
  if [ -n "$PG_CONF" ]; then
    det_port="$(extract_port_from_conf "$PG_CONF")"
    if [[ -n "$det_port" && "$det_port" =~ ^[0-9]+$ ]]; then
      DB_PORT="$det_port"
      say "Detected PostgreSQL port: ${DB_PORT}"
      state_put_flag "pg_port" "$DB_PORT"
    fi
  fi
else
  [[ -n "$PG_VERSION" ]] || { err "PG_VERSION is required."; exit 1; }
  say "Installing PostgreSQL ${PG_VERSION} from PGDG..."
  pgdg_add_repo
  if ! apt-cache show "postgresql-${PG_VERSION}" >/dev/null 2>&1; then
    warn "PostgreSQL ${PG_VERSION} not available; falling back to 17"
    PG_VERSION="17"
  fi
  ensure_postgres "$PG_VERSION"
  if command -v psql >/dev/null 2>&1; then
    PG_VERSION="$(psql -V | awk '{print $3}' | cut -d. -f1)"
  fi
fi

PG_HBA="$(find_pg_hba "$PG_VERSION")"
[[ -n "$PG_HBA" ]] || { err "pg_hba.conf not found for major ${PG_VERSION}"; exit 1; }

NEED_RESTORE=0
if ! sudo -u postgres psql -tAc "SELECT 1" >/dev/null 2>&1; then
  bak="${PG_HBA}.bak.$(date +%s)"
  cp -a "$PG_HBA" "$bak"
  state_put_map BACKUPS "$PG_HBA" "$bak"
  NEED_RESTORE=1
  sed -i -E 's/^(local[[:space:]]+all[[:space:]]+all[[:space:]]+).*/\1trust/' "$PG_HBA"
  sed -i -E 's/^(local[[:space:]]+all[[:space:]]+postgres[[:space:]]+).*/\1trust/' "$PG_HBA" || true
  svc_reload postgresql
  sudo -u postgres psql -tAc "SELECT 1" >/dev/null 2>&1 || { err "psql inaccessible even after temporary trust"; exit 1; }
fi
line "-" 72

say "Creating role and database if missing..."
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${DB_USER}') THEN
    EXECUTE format('CREATE USER %I WITH PASSWORD %L SUPERUSER', '${DB_USER}', '${DB_PASS}');
  END IF;
END
\$\$;
ALTER ROLE ${DB_USER} SET client_encoding TO 'utf8';
ALTER ROLE ${DB_USER} SET default_transaction_isolation TO 'read committed';
ALTER ROLE ${DB_USER} SET timezone TO 'UTC';
SQL

EXISTS_DB=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" || true)
[[ "$EXISTS_DB" == "1" ]] || sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}"
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"

if [[ $NEED_RESTORE -eq 1 ]]; then
  cp -f "${PG_HBA}.bak."* "$PG_HBA" 2>/dev/null || true
  sed -i -E 's/( scram-sha-256| trust)([[:space:]]|$)/ md5\2/g' "$PG_HBA" || true
  svc_reload postgresql
fi

state_put_flag "pg_major" "$PG_VERSION"
banner "PostgreSQL ${PG_VERSION} ready (db=${DB_NAME}, user=${DB_USER}, port=${DB_PORT})" "=" 72
