#!/usr/bin/env bash
# docker/entrypoint.sh - prepares the WafControl container, then runs the CMD (supervisord).
#
# Required: DB_NAME DB_USER DB_PASS DB_HOST (the PostgreSQL container).
# Optional: SECRET_KEY (generated once and kept in /var/lib/wafcontrol), DB_PORT,
#           CELERY_BROKER_URL, DJANGO_SUPERUSER_USERNAME/PASSWORD/EMAIL (admin created on first start).
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/WafControl}"
PY="$APP_DIR/venv/bin/python"
DATA_DIR=/var/lib/wafcontrol
log() { echo "[entrypoint] $*"; }

mkdir -p "$DATA_DIR" /run/wafcontrol

: "${DB_NAME:?DB_NAME is required}" "${DB_USER:?DB_USER is required}" "${DB_PASS:?DB_PASS is required}"
export DB_HOST="${DB_HOST:-db}" DB_PORT="${DB_PORT:-5432}"

if [[ -z "${SECRET_KEY:-}" ]]; then
  if [[ ! -s "$DATA_DIR/secret_key" ]]; then
    (umask 077; openssl rand -base64 48 | tr -d '\n' > "$DATA_DIR/secret_key")
    log "Generated SECRET_KEY in $DATA_DIR/secret_key"
  fi
  export SECRET_KEY="$(cat "$DATA_DIR/secret_key")"
fi
# Settings also read $APP_DIR/.env: keep the key there so `docker exec ... manage.py` works too.
if ! grep -q '^SECRET_KEY=' "$APP_DIR/.env" 2>/dev/null; then
  (umask 077; echo "SECRET_KEY=${SECRET_KEY}" >> "$APP_DIR/.env")
fi

# Volumes mounted over /var/log start empty on some setups: recreate what the web server writes.
if [[ "${WAFCONTROL_SERVER:-nginx}" == "nginx" ]]; then
  mkdir -p /var/log/nginx
  WEB_USER="$(awk '/^[[:space:]]*user[[:space:]]+/ {gsub(/;/, "", $2); print $2; exit}' /etc/nginx/nginx.conf 2>/dev/null)"
  MODSEC_CONF=/etc/nginx/modsec/modsecurity.conf
else
  mkdir -p /var/log/apache2 /var/cache/modsecurity
  WEB_USER=www-data
  MODSEC_CONF=/etc/modsecurity/modsecurity.conf
fi
AUDIT="$(awk '/^[[:space:]]*SecAuditLog[[:space:]]+/ {gsub(/"/, "", $2); print $2; exit}' "$MODSEC_CONF" 2>/dev/null || true)"
if [[ -n "$AUDIT" ]]; then
  mkdir -p "$(dirname "$AUDIT")"; touch "$AUDIT"
  [[ -n "${WEB_USER:-}" ]] && chown "$WEB_USER" "$AUDIT" 2>/dev/null || true
  chmod 640 "$AUDIT"
fi

log "Waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}..."
for i in $(seq 1 60); do
  if PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc 'select 1' >/dev/null 2>&1; then
    break
  fi
  [[ $i -eq 60 ]] && { log "PostgreSQL is not reachable."; exit 1; }
  sleep 2
done

# The project does not ship migrations: they are generated from the models. Keep them in the
# data volume so later images only add new migrations on top of the ones already applied.
MIG="$APP_DIR/wafinstaller/migrations"
mkdir -p "$DATA_DIR/migrations"
touch "$DATA_DIR/migrations/__init__.py"
if [[ ! -L "$MIG" ]]; then
  [[ -d "$MIG" ]] && cp -an "$MIG/." "$DATA_DIR/migrations/" && rm -rf "$MIG"
  ln -s "$DATA_DIR/migrations" "$MIG"
fi

cd "$APP_DIR"
"$PY" manage.py makemigrations wafinstaller --noinput
"$PY" manage.py migrate --noinput

if [[ -n "${DJANGO_SUPERUSER_USERNAME:-}" && -n "${DJANGO_SUPERUSER_PASSWORD:-}" ]]; then
  "$PY" manage.py shell -c "
import os
from django.contrib.auth import get_user_model
U = get_user_model(); name = os.environ['DJANGO_SUPERUSER_USERNAME']
if not U.objects.filter(username=name).exists():
    U.objects.create_superuser(name, os.environ.get('DJANGO_SUPERUSER_EMAIL', ''), os.environ['DJANGO_SUPERUSER_PASSWORD'])
    print('[entrypoint] Created admin user', name)
"
fi

exec "$@"
