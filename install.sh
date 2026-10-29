#!/usr/bin/env bash
# install.sh - OWASP WafControl installer (Debian/Ubuntu).
#
#   sudo ./install.sh             guided install on this server (systemd)
#   sudo ./install.sh --yes       same, unattended: answers come from the environment
#   ./install.sh --docker         image build (used by the Dockerfile): installs the application,
#                                 the web server and the WAF, starts nothing
#
# The application comes from APP_SRC (a local checkout) when set, otherwise it is cloned from
# REPO_URL (branch REPO_BRANCH). Downloaded on its own, this script first fetches the rest of
# the installer (INSTALLER_URL) and runs that copy. Every prompt can be preset in the environment.
set -euo pipefail

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'TXT'
Options:
  -y, --yes               non-interactive (NONINTERACTIVE=1)
      --docker            image build mode (INSTALL_TARGET=docker, implies --yes)
      --server NAME       nginx | apache (SERVER)
  -h, --help              this help
TXT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)   export NONINTERACTIVE=1 ;;
    --docker)   export INSTALL_TARGET=docker ;;
    --server)   export SERVER="${2:?--server needs nginx or apache}"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

APP_DIR="${APP_DIR:-/opt/WafControl}"
APP_SRC="${APP_SRC:-}"
REPO_URL="${REPO_URL:-https://github.com/aedkymish/wafcontrol.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
INSTALLER_URL="${INSTALLER_URL:-https://github.com/aedkymish/install.git}"
INSTALLER_BRANCH="${INSTALLER_BRANCH:-main}"

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [[ ! -f "$SELF_DIR/lib/common.sh" ]]; then
  # Standalone download (curl ... -o install.sh): fetch the full installer, then run it.
  [[ $EUID -eq 0 ]] || { echo "[x] Run as root (sudo)." >&2; exit 1; }
  command -v git >/dev/null 2>&1 || { apt-get update -y && apt-get install -y --no-install-recommends git ca-certificates; }
  INSTALLER_DIR="$(mktemp -d -t wafcontrol-installer-XXXXXX)"
  echo "[+] Fetching installer ${INSTALLER_URL} (${INSTALLER_BRANCH})..."
  git clone --depth 1 --branch "$INSTALLER_BRANCH" "$INSTALLER_URL" "$INSTALLER_DIR"
  exec bash "$INSTALLER_DIR/install.sh" "$@"
fi

source "$SELF_DIR/lib/common.sh"
trap 'err "Failed on line $LINENO"' ERR
require_root
export DEBIAN_FRONTEND=noninteractive

run_module() {
  local mod="${1:?module name required}"
  banner "Running module: ${mod}"
  bash "$SELF_DIR/modules/$mod"
}

detect_os() { . /etc/os-release 2>/dev/null || true; echo "${ID:-}"; }
detect_codename() { . /etc/os-release 2>/dev/null || true; echo "${VERSION_CODENAME:-}"; }
detect_ubuntu() { [ "$(detect_os)" = "ubuntu" ]; }

ensure_debian_sources() {
  local codename; codename="$(detect_codename)"
  local sources="/etc/apt/sources.list"
  # Recent Debian images use deb822 sources; only fill in a missing classic list.
  [[ -s "$sources" || -n "$(ls /etc/apt/sources.list.d/*.sources 2>/dev/null)" ]] && return 0
  case "$codename" in
    bullseye)
      cat > "$sources" <<'EOF'
deb http://security.debian.org/debian-security bullseye-security main contrib non-free
deb-src http://security.debian.org/debian-security bullseye-security main contrib

deb http://deb.debian.org/debian bullseye main contrib non-free
deb-src http://deb.debian.org/debian bullseye main
deb http://deb.debian.org/debian bullseye-updates main contrib non-free
deb-src http://deb.debian.org/debian bullseye-updates main
deb http://deb.debian.org/debian bullseye-backports main
deb-src http://deb.debian.org/debian bullseye-backports main
EOF
      say "Created /etc/apt/sources.list for Debian 11 (bullseye)."
      ;;
    trixie)
      cat > "$sources" <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
      say "Created /etc/apt/sources.list for Debian 13 (trixie)."
      ;;
    *) : ;;
  esac
}

ensure_python_ubuntu() {
  . /etc/os-release
  apt-get update -y
  apt-get install -y --no-install-recommends python3 python3-venv python3-dev python3-pip || true
  local ver
  ver="$(python3 -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo 0)"
  case "${VERSION_CODENAME:-}" in
    jammy|lunar|mantic|noble) : ;;
    focal)
      case "$ver" in
        3.10|3.11|3.12) : ;;
        *)
          apt-get install -y --no-install-recommends software-properties-common
          add-apt-repository -y ppa:deadsnakes/ppa
          apt-get update -y
          apt-get install -y --no-install-recommends python3.10 python3.10-venv python3.10-dev || \
          apt-get install -y --no-install-recommends python3.11 python3.11-venv python3.11-dev
          update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 2 || true
          update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 || true
          ;;
      esac
      ;;
    *) : ;;
  esac
}

detect_webserver_choice() {
  local have_nginx=0 have_apache=0
  command -v nginx >/dev/null 2>&1 && have_nginx=1
  command -v apache2ctl >/dev/null 2>&1 && have_apache=1
  if [ $have_nginx -eq 1 ] && [ $have_apache -eq 0 ]; then
    echo "nginx"
  elif [ $have_nginx -eq 0 ] && [ $have_apache -eq 1 ]; then
    echo "apache"
  else
    echo ""
  fi
}

find_postgresql_conf() {
  local v="${1:-}"
  if [ -n "$v" ]; then
    local p
    p=$(find "/etc/postgresql/${v}" -maxdepth 3 -name postgresql.conf 2>/dev/null | head -n1 || true)
    [ -n "$p" ] && { echo "$p"; return; }
  fi
  local any
  any=$(find /etc/postgresql -maxdepth 4 -name postgresql.conf 2>/dev/null | head -n1 || true)
  [ -n "$any" ] && { echo "$any"; return; }
  echo ""
}

extract_port_from_conf() {
  local conf="$1"
  [ -r "$conf" ] || { echo ""; return; }
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*port[[:space:]]*=/ {
      gsub(/[[:space:]]+/,"")
      sub(/port=/,"")
      sub(/#.*/,"")
      print; found=$0
    }
  END{ if (found) print found }' "$conf" | tail -n1 | tr -d '[:space:]'
}

dbname_is_valid() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
dbuser_is_valid() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

# ---------- Inputs (all can be preset in the environment) ----------
APP_USER="${APP_USER:-wafcontrol}"
VENV_DIR="${VENV_DIR:-$APP_DIR/venv}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/wafcontrol}"

SERVER="${SERVER:-}"
MODE="${MODE:-}"
DOMAIN="${DOMAIN:-}"
HTTP_PORT="${HTTP_PORT:-}"
SSL_ENABLE="${SSL_ENABLE:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"

DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASS="${DB_PASS:-}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
PG_VERSION="${PG_VERSION:-}"
DEFAULT_PG_VER="${DEFAULT_PG_VER:-18}"

BASIC_AUTH_ENABLE="${BASIC_AUTH_ENABLE:-}"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-}"
BASIC_AUTH_PASS="${BASIC_AUTH_PASS:-}"

banner "WafControl Installer (Debian/Ubuntu)" "=" 72
if is_docker_build; then
  cat <<'TXT'
Image build: application (Django, Gunicorn, Celery) + web server + WAF.
PostgreSQL and Redis are separate containers; services start with the container.
TXT
else
  cat <<'TXT'
This guided installer will set up:
  • WafControl application (Django, Gunicorn, Celery)
  • PostgreSQL database (reuse existing if found)
  • Your chosen web server (Nginx or Apache)
  • WAF layer:
      - Nginx: ModSecurity v3 (built against your exact Nginx version) + latest CRS
      - Apache: libapache2-mod-security2 + latest CRS
TXT
fi
line "-" 72

section "Web server selection"
if [[ -z "$SERVER" ]]; then
  SERVER="$(detect_webserver_choice || true)"
  [[ -n "$SERVER" ]] && say "Detected web server: $SERVER (auto-selected)."
fi
if [[ -z "$SERVER" ]]; then
  echo "Type 'nginx' to build ModSecurity v3 for your Nginx and apply latest CRS."
  echo "Type 'apache' to enable ModSecurity2 and apply latest CRS."
  ask SERVER "Choose [nginx/apache]" "nginx"
fi
[[ "$SERVER" =~ ^(nginx|apache)$ ]] || { err "Invalid server: $SERVER"; exit 1; }

if is_docker_build; then
  # Domain names, TLS and the database belong to the container's runtime configuration.
  MODE="ip"; HTTP_PORT="${HTTP_PORT:-7000}"; SSL_ENABLE=0
  BASIC_AUTH_ENABLE=0; BASIC_AUTH_USER=""; BASIC_AUTH_PASS=""
else
  section "Run mode selection"
  echo "'ip' mode: best for local/direct IP testing (relaxed CSRF/SESSION secure flags)."
  echo "'domain' mode: use if you have a valid domain pointed to this host."
  ask MODE "Choose [ip/domain]" "ip"
  [[ "$MODE" =~ ^(ip|domain)$ ]] || { err "Invalid mode: $MODE"; exit 1; }

  if [[ "$MODE" == "domain" ]]; then
    ask DOMAIN "Enter domain (e.g. waf.example.com)"
    [[ -n "$DOMAIN" ]] || { err "Domain is required for domain mode."; exit 1; }
    say "In domain mode the service will bind to :80 and optionally :443."
    if [[ -z "$SSL_ENABLE" ]]; then
      if ask_yn "Enable SSL with Let's Encrypt?" "N"; then SSL_ENABLE=1; else SSL_ENABLE=0; fi
    fi
  else
    SSL_ENABLE=0
    echo
    echo "HTTP listen port for the dashboard (default: 7000)."
    ask HTTP_PORT "Port" "7000"
    [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || { err "Invalid port: $HTTP_PORT"; exit 1; }
  fi

  section "PostgreSQL detection"
  if command -v psql >/dev/null 2>&1; then
    INSTALLED_MAJOR="$(psql -V | awk '{print $3}' | cut -d. -f1)"
    PG_VERSION="${INSTALLED_MAJOR}"
    say "PostgreSQL detected: version ${PG_VERSION} (will be reused)."

    conf_path="$(find_postgresql_conf "$PG_VERSION")"
    if [ -n "$conf_path" ]; then
      det_port="$(extract_port_from_conf "$conf_path")"
      if [[ -n "$det_port" && "$det_port" =~ ^[0-9]+$ ]]; then
        DB_PORT="$det_port"
        say "Detected PostgreSQL port from config: ${DB_PORT}"
      else
        say "Could not detect custom port from config. Using default ${DB_PORT}."
      fi
    else
      say "postgresql.conf not found for auto-port detection. Using default ${DB_PORT}."
    fi
  else
    echo "PostgreSQL not detected."
    echo "Enter the major version to install, for example: 17, 18, or any version you want."
    while :; do
      ask PG_VERSION "PostgreSQL major version to install" "$DEFAULT_PG_VER"
      [[ "$PG_VERSION" =~ ^[0-9]+$ ]] && break
      [[ "$NONINTERACTIVE" == "1" ]] && { err "Invalid PG_VERSION: $PG_VERSION"; exit 1; }
      warn "Invalid PG_VERSION. Enter a number like 14, 15, 16, 17, 18."
      PG_VERSION=""
    done
    say "Selected PostgreSQL major version: ${PG_VERSION}"
  fi

  section "Database configuration (fresh install)"
  while :; do
    ask DB_NAME "Database name" "wafcontrol"
    dbname_is_valid "$DB_NAME" && break
    [[ "$NONINTERACTIVE" == "1" ]] && { err "Invalid DB_NAME: $DB_NAME"; exit 1; }
    warn "Invalid database name. Use letters/numbers/underscore and start with a letter or underscore."
    DB_NAME=""
  done
  while :; do
    ask DB_USER "Database user" "wafcontrol_user"
    dbuser_is_valid "$DB_USER" && break
    [[ "$NONINTERACTIVE" == "1" ]] && { err "Invalid DB_USER: $DB_USER"; exit 1; }
    warn "Invalid database user. Use letters/numbers/underscore and start with a letter or underscore."
    DB_USER=""
  done
  ask_secret DB_PASS "Database password [auto-generate if empty]"

  section "Database availability check"
  if command -v psql >/dev/null 2>&1 && [[ "$DB_HOST" == "127.0.0.1" || "$DB_HOST" == "localhost" ]]; then
    if command -v sudo >/dev/null 2>&1; then
      pg_query() { sudo -u postgres psql -tAc "$1" 2>/dev/null || true; }
    else
      pg_query() { su -s /bin/bash postgres -c "psql -tAc \"$1\"" 2>/dev/null || true; }
    fi

    while :; do
      db_exists="$(pg_query "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}';" | tr -d '[:space:]')"
      role_exists="$(pg_query "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}';" | tr -d '[:space:]')"

      if [[ "$db_exists" == "1" || "$role_exists" == "1" ]]; then
        warn "Conflicting objects detected:"
        [[ "$db_exists" == "1" ]] && warn "  - Database exists: ${DB_NAME}"
        [[ "$role_exists" == "1" ]] && warn "  - Role exists:     ${DB_USER}"
        [[ "$NONINTERACTIVE" == "1" ]] && { err "Choose another DB_NAME/DB_USER."; exit 1; }
        warn "Please enter NEW names to avoid conflicts."

        while :; do
          read -rp "New database name: " DB_NAME
          [[ -n "$DB_NAME" ]] || { warn "Database name cannot be empty."; continue; }
          dbname_is_valid "$DB_NAME" || { warn "Invalid database name format."; continue; }
          db_exists="$(pg_query "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}';" | tr -d '[:space:]')"
          [[ "$db_exists" == "1" ]] && { warn "Database exists: ${DB_NAME}"; continue; }
          break
        done

        while :; do
          read -rp "New database user: " DB_USER
          [[ -n "$DB_USER" ]] || { warn "User cannot be empty."; continue; }
          dbuser_is_valid "$DB_USER" || { warn "Invalid user format."; continue; }
          role_exists="$(pg_query "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}';" | tr -d '[:space:]')"
          [[ "$role_exists" == "1" ]] && { warn "Role exists: ${DB_USER}"; continue; }
          break
        done

        DB_PASS=""
        read -srp "Database password [auto-generate if empty]: " DB_PASS; echo
        continue
      fi

      say "No conflicts detected for DB_NAME/DB_USER."
      break
    done
  else
    warn "Skipping DB availability check (psql missing or DB_HOST not local)."
  fi

  if [[ -z "${DB_PASS:-}" ]]; then
    DB_PASS="$(gen_pass)"
    say "Generated DB password for ${DB_USER}."
  fi

  if [[ "$MODE" == "domain" && "$SSL_ENABLE" == "1" ]]; then
    ask CERTBOT_EMAIL "Email for Let's Encrypt notifications" "admin@${DOMAIN}"
  fi

  section "Optional HTTP Basic Auth (extra layer before login)"
  if [[ -z "$BASIC_AUTH_ENABLE" ]]; then
    if ask_yn "Enable HTTP Basic Auth for dashboard?" "N"; then BASIC_AUTH_ENABLE=1; else BASIC_AUTH_ENABLE=0; fi
  fi
  if [[ "$BASIC_AUTH_ENABLE" == "1" ]]; then
    while :; do
      ask BASIC_AUTH_USER "Basic Auth username"
      [[ -n "$BASIC_AUTH_USER" && "$BASIC_AUTH_USER" != *:* ]] && break
      [[ "$NONINTERACTIVE" == "1" ]] && { err "BASIC_AUTH_USER is empty or contains ':'."; exit 1; }
      warn "Username cannot be empty or contain ':'."
      BASIC_AUTH_USER=""
    done
    while :; do
      ask_secret BASIC_AUTH_PASS "Basic Auth password"
      [[ -n "$BASIC_AUTH_PASS" ]] && break
      [[ "$NONINTERACTIVE" == "1" ]] && { err "BASIC_AUTH_PASS is required."; exit 1; }
      warn "Password cannot be empty."
    done
    say "HTTP Basic Auth will be applied at web server level (separate from Django login)."
  else
    BASIC_AUTH_ENABLE=0; BASIC_AUTH_USER=""; BASIC_AUTH_PASS=""
  fi
fi

echo
banner "Summary" "=" 72
echo "• Target:       $INSTALL_TARGET"
echo "• Server:       $SERVER"
echo "• Source:       ${APP_SRC:-$REPO_URL ($REPO_BRANCH)}"
echo "• App Path:     $APP_DIR"
if is_docker_build; then
  echo "• HTTP Port:    $HTTP_PORT (panel)"
else
  if [[ "$MODE" == "domain" ]]; then
    echo "• Mode:         domain (domain=$DOMAIN)"
    echo "• HTTP/S:       80$( [[ $SSL_ENABLE -eq 1 ]] && echo ' and 443 (SSL enabled)' || echo ' only' )"
  else
    echo "• Mode:         ip"
    echo "• HTTP Port:    $HTTP_PORT"
  fi
  echo "• PostgreSQL:   $PG_VERSION  (db=$DB_NAME, user=$DB_USER, port=$DB_PORT)"
  echo "• Basic Auth:   $([[ $BASIC_AUTH_ENABLE -eq 1 ]] && echo "enabled (user=$BASIC_AUTH_USER)" || echo "disabled")"
fi
ask_yn "Proceed with installation?" "Y" || { warn "Aborted."; exit 0; }

if [ "$(detect_os)" = "debian" ]; then
  ensure_debian_sources
fi

state_init
state_put_flag "target" "$INSTALL_TARGET"
state_put_flag "server" "$SERVER"
state_put_flag "mode" "$MODE"
state_put_flag "domain" "${DOMAIN:-}"
state_put_flag "port" "${HTTP_PORT:-80}"
state_put_flag "ssl_enable" "$SSL_ENABLE"
state_put_flag "certbot_email" "${CERTBOT_EMAIL:-}"
state_put_flag "pg_version" "$PG_VERSION"
state_put_flag "app_dir" "$APP_DIR"
state_put_flag "venv_dir" "$VENV_DIR"
state_put_flag "runtime_dir" "$RUNTIME_DIR"
state_put_flag "basic_auth_enable" "$BASIC_AUTH_ENABLE"
state_put_flag "basic_auth_user" "$BASIC_AUTH_USER"

export BASIC_AUTH_ENABLE BASIC_AUTH_USER BASIC_AUTH_PASS
export SSL_ENABLE CERTBOT_EMAIL

banner "Installing base packages" "=" 72
apt-get update -y

if apt-cache show gnupg2 >/dev/null 2>&1; then GPG_PKG=gnupg2; else GPG_PKG=gnupg; fi

if detect_ubuntu; then
  ensure_python_ubuntu
else
  apt-get install -y --no-install-recommends python3 python3-venv python3-dev python3-pip || true
fi

BASE_PKGS=(curl "$GPG_PKG" ca-certificates lsb-release debian-archive-keyring
  build-essential git pkg-config jq wget tar sed grep procps libpq-dev openssl)
if is_docker_build; then
  BASE_PKGS+=(supervisor postgresql-client lsof net-tools iproute2)
else
  BASE_PKGS+=(redis-server)
fi
apt-get install -y --no-install-recommends "${BASE_PKGS[@]}"

banner "Preparing project and Python environment" "=" 72
if [[ -f "$APP_DIR/manage.py" ]]; then
  warn "Project already present at ${APP_DIR}. Keeping it."
elif [[ -n "$APP_SRC" ]]; then
  [[ -f "$APP_SRC/manage.py" ]] || { err "APP_SRC is not a WafControl checkout: $APP_SRC"; exit 1; }
  say "Copying WafControl from ${APP_SRC} into ${APP_DIR}..."
  mkdir -p "$APP_DIR"
  cp -a "$APP_SRC/." "$APP_DIR/"
  rm -rf "$APP_DIR/venv" "$APP_DIR/.env"
  state_append_array CREATED_FILES "$APP_DIR"
else
  say "Cloning ${REPO_URL} (${REPO_BRANCH}) into ${APP_DIR}..."
  git clone --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
  state_append_array CREATED_FILES "$APP_DIR"
fi

if [[ ! -d "$VENV_DIR" ]]; then
  say "Creating virtualenv..."
  python3 -m venv "$VENV_DIR"
  state_append_array CREATED_FILES "$VENV_DIR"
fi

source "${VENV_DIR}/bin/activate"
python -m pip install --upgrade pip wheel setuptools

REQ_FILE="${APP_DIR}/requirements.txt"
if [[ -f "$REQ_FILE" ]]; then
  say "Installing Python requirements..."
  pip install -r "$REQ_FILE"
else
  warn "requirements.txt not found. Installing minimal stack..."
  pip install "Django>=5" gunicorn celery
fi
pip install django-environ "psycopg[binary]>=3.1" || pip install psycopg2-binary

export APP_USER APP_DIR VENV_DIR RUNTIME_DIR
export SERVER MODE DOMAIN HTTP_PORT
export DB_NAME DB_USER DB_PASS DB_HOST DB_PORT PG_VERSION
export STATE_DIR STATE_FILE INSTALL_TARGET NONINTERACTIVE

if is_docker_build; then
  banner "Collecting static files" "=" 72
  # Settings need these at import time; the real values come from the container environment.
  SECRET_KEY=build DB_NAME=build DB_USER=build DB_PASS=build \
    "${VENV_DIR}/bin/python" "${APP_DIR}/manage.py" collectstatic --noinput
else
  run_module "postgres.sh"

  banner "Writing .env and preparing" "=" 72
  SECRET_KEY_VALUE="$(gen_pass)"
  CSRF_SEC=True; SESSION_SEC=True
  [[ "$MODE" == "ip" ]] && CSRF_SEC=False && SESSION_SEC=False
  ALLOWED_LIST="127.0.0.1,localhost"
  if [[ "$MODE" == "domain" ]]; then
    ALLOWED_LIST="${ALLOWED_LIST},${DOMAIN},www.${DOMAIN}"
  else
    IP=$(hostname -I | awk '{print $1}')
    [[ -n "$IP" ]] && ALLOWED_LIST="${ALLOWED_LIST},${IP}"
  fi

  cat > "${APP_DIR}/.env" <<EOF
SECRET_KEY=${SECRET_KEY_VALUE}
DEBUG=False
ALLOWED_HOSTS=${ALLOWED_LIST}

DB_ENGINE=django.db.backends.postgresql
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}

CSRF_COOKIE_SECURE=${CSRF_SEC}
SESSION_COOKIE_SECURE=${SESSION_SEC}
SECURE_BROWSER_XSS_FILTER=True
SECURE_CONTENT_TYPE_NOSNIFF=True
X_FRAME_OPTIONS=DENY
EOF
  chmod 600 "${APP_DIR}/.env"
  state_append_array CREATED_FILES "${APP_DIR}/.env"

  if [[ "$MODE" == "domain" && -n "${DOMAIN:-}" ]]; then
    {
      echo "CSRF_TRUSTED_ORIGINS=https://${DOMAIN},https://www.${DOMAIN}"
      echo "SECURE_PROXY_SSL_HEADER=HTTP_X_FORWARDED_PROTO,https"
      echo "USE_X_FORWARDED_HOST=True"
    } >> "${APP_DIR}/.env"
  fi

  banner "Verifying database connectivity" "=" 72
  if ! PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c 'select 1;' >/dev/null 2>&1; then
    err "Database auth failed. Check DB_USER/DB_PASS/DB_PORT/pg_hba.conf."
    exit 1
  fi

  banner "Applying migrations and collecting static files" "=" 72
  "${VENV_DIR}/bin/python" "${APP_DIR}/manage.py" makemigrations wafinstaller || true
  "${VENV_DIR}/bin/python" "${APP_DIR}/manage.py" migrate --noinput
  mkdir -p "${APP_DIR}/frontend"
  "${VENV_DIR}/bin/python" "${APP_DIR}/manage.py" collectstatic --noinput
fi

if [[ "$SERVER" == "nginx" ]]; then
  run_module "waf-nginx.sh"
else
  run_module "waf-apache.sh"
fi
run_module "services.sh"

if is_docker_build; then
  banner "Image build complete" "=" 72
  exit 0
fi

echo
banner "Create Wafcontrol Admin" "=" 72
if ask_yn "Create now?" "N"; then
  "${VENV_DIR}/bin/python" "${APP_DIR}/manage.py" createsuperuser || warn "createsuperuser skipped."
fi

TARGET_HOST="${DOMAIN:-$(hostname -I | awk '{print $1}')}"
banner "Installation complete" "=" 72
if [[ "$MODE" == "domain" ]]; then
  echo "Open: http://${TARGET_HOST}/ (SSL $( [[ $SSL_ENABLE -eq 1 ]] && echo 'enabled' || echo 'disabled' ))"
else
  echo "Open: http://${TARGET_HOST}:${HTTP_PORT}/"
fi
echo "Services:"
echo "  systemctl status wafcontrol"
echo "  systemctl status wafcontrol-celery-worker"
echo "  systemctl status wafcontrol-celery-beat"
line "=" 72
