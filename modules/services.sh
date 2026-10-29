#!/usr/bin/env bash
# modules/services.sh - run WafControl's processes: Gunicorn, Celery worker, Celery beat
# (and, in a container, the web server itself).
#
#   host + systemd   -> wafcontrol.service, wafcontrol-celery-worker.service, wafcontrol-celery-beat.service
#   INSTALL_TARGET=docker -> /etc/supervisor/conf.d/wafcontrol.conf (supervisord is the container's PID 1 child)
#
# Inputs (environment): APP_DIR VENV_DIR RUNTIME_DIR SERVER
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

trap 'err "Failed on line $LINENO"' ERR
require_root
mkdir -p "$STATE_DIR"; touch "$STATE_FILE"

APP_DIR="${APP_DIR:?}"
VENV_DIR="${VENV_DIR:?}"
RUNTIME_DIR="${RUNTIME_DIR:?}"
SERVER="${SERVER:?}"

# Gunicorn's socket must be reachable by the web server's group.
web_group() {
  if [[ "$SERVER" != "nginx" ]]; then echo "www-data"; return; fi
  local u
  u="$(grep -E '^[[:space:]]*user[[:space:]]+' /etc/nginx/nginx.conf 2>/dev/null | sed -E 's/#.*$//' | head -n1 \
       | sed -E 's/^[[:space:]]*user[[:space:]]+([^;[:space:]]+).*/\1/' || true)"
  [[ -n "$u" ]] || u="$(ps -o user= -C nginx 2>/dev/null | grep -v root | head -n1 || true)"
  [[ -n "$u" ]] || u="nginx"
  id -gn "$u" 2>/dev/null || echo "$u"
}
WEB_GROUP="$(web_group)"
say "Using web group: ${WEB_GROUP}"

gunicorn_cmd() {  # gunicorn_cmd <workers>
  echo "${VENV_DIR}/bin/gunicorn --workers $1 --timeout 120 --bind unix:${RUNTIME_DIR}/gunicorn.sock WafControl.wsgi:application"
}
WORKER_CMD="${VENV_DIR}/bin/celery -A WafControl worker -l INFO"
BEAT_CMD="${VENV_DIR}/bin/celery -A WafControl beat -l INFO"

write_supervisor() {
  # Standalone file (not conf.d): it carries its own [supervisord] section.
  local conf="/etc/supervisor/wafcontrol.conf" web
  if [[ "$SERVER" == "nginx" ]]; then
    web="nginx -g 'daemon off;'"
  else
    web="/usr/sbin/apache2ctl -D FOREGROUND"
  fi
  mkdir -p "$(dirname "$conf")"
  # Logs go to the container's stdout/stderr (docker logs).
  cat > "$conf" <<EOF
[supervisord]
nodaemon=true
user=root
logfile=/dev/null
logfile_maxbytes=0
pidfile=/run/supervisord.pid

[unix_http_server]
file=/run/supervisor.sock
chmod=0700

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///run/supervisor.sock

[program:webserver]
command=${web}
autorestart=true
priority=10
stopasgroup=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
redirect_stderr=true

[program:gunicorn]
command=/bin/sh -c "mkdir -p ${RUNTIME_DIR} && umask 0007 && exec $(gunicorn_cmd '${GUNICORN_WORKERS:-4}')"
directory=${APP_DIR}
user=root
group=${WEB_GROUP}
environment=DJANGO_SETTINGS_MODULE="WafControl.settings"
autorestart=true
priority=20
stopasgroup=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
redirect_stderr=true

[program:celery-worker]
command=${WORKER_CMD}
directory=${APP_DIR}
environment=DJANGO_SETTINGS_MODULE="WafControl.settings"
autorestart=true
priority=30
stopasgroup=true
stopwaitsecs=30
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
redirect_stderr=true

[program:celery-beat]
command=${BEAT_CMD} -s /var/lib/wafcontrol/celerybeat-schedule
directory=${APP_DIR}
environment=DJANGO_SETTINGS_MODULE="WafControl.settings"
autorestart=true
priority=40
stopasgroup=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
redirect_stderr=true
EOF
  mkdir -p /var/lib/wafcontrol
  state_append_array CREATED_FILES "$conf"
  say "Supervisor programs written: $conf"
}

write_unit() {  # write_unit <file> <description> <after> <exec> [extra lines]
  cat > "$1" <<EOF
[Unit]
Description=$2
After=network-online.target $3
Wants=network-online.target
[Service]
User=root
Group=${WEB_GROUP}
WorkingDirectory=${APP_DIR}
Environment="DJANGO_SETTINGS_MODULE=WafControl.settings"
${5:-}ExecStart=$4
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  state_append_array CREATED_UNITS "$1"
}

write_systemd() {
  banner "Creating and enabling systemd units" "=" 72
  write_unit /etc/systemd/system/wafcontrol.service "WafControl Gunicorn" "postgresql.service" \
    "$(gunicorn_cmd 4)" \
    $'RuntimeDirectory=wafcontrol\nRuntimeDirectoryMode=0755\nUMask=0007\nPrivateTmp=true\n'
  write_unit /etc/systemd/system/wafcontrol-celery-worker.service "WafControl Celery Worker" "redis-server.service" "$WORKER_CMD"
  write_unit /etc/systemd/system/wafcontrol-celery-beat.service "WafControl Celery Beat" "redis-server.service" "$BEAT_CMD"
  systemctl daemon-reload
  systemctl enable --now wafcontrol.service wafcontrol-celery-worker.service wafcontrol-celery-beat.service
}

if is_docker_build; then
  write_supervisor
elif has_systemd; then
  write_systemd
else
  warn "No systemd found: writing supervisord programs instead (start with: supervisord -c /etc/supervisor/wafcontrol.conf)."
  write_supervisor
fi
