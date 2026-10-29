#!/usr/bin/env bash
# upgrade.sh - upgrade an installed WafControl 1.0.0 to 1.1.0 (server installs made by install.sh).
#
#   sudo ./upgrade.sh                    upgrade /opt/WafControl to REPO_URL @ REPO_REF
#   sudo ./upgrade.sh --yes              no questions
#   sudo ./upgrade.sh --ref v1.1.0       a tag, branch or commit
#
# Steps: backup (code, .env, database, web server/ModSecurity config) -> new code -> Python
# requirements -> migrations -> static files -> panel-only WAF exclusions (removes the global
# exclusions of 1.0.0, which disabled the WAF on those paths for every site) -> restart -> checks.
# A failure before the database migration puts the previous code back automatically.
#
# Docker: rebuild the image instead (docker compose up -d --build); migrations run at start.
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/WafControl}"
REPO_URL="${REPO_URL:-https://github.com/aedkymish/wafcontrol.git}"
REPO_REF="${REPO_REF:-main}"
TARGET_VERSION="1.1.0"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/wafcontrol}"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)  export NONINTERACTIVE=1 ;;
    --ref)     REPO_REF="${2:?--ref needs a tag, branch or commit}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [[ ! -f "$SELF_DIR/lib/common.sh" ]]; then
  # Standalone download: fetch the full installer, then run its upgrade.sh.
  INSTALLER_DIR="$(mktemp -d -t wafcontrol-installer-XXXXXX)"
  git clone -q --depth 1 --branch "${INSTALLER_BRANCH:-main}" \
    "${INSTALLER_URL:-https://github.com/aedkymish/install.git}" "$INSTALLER_DIR"
  exec bash "$INSTALLER_DIR/upgrade.sh" "$@"
fi
source "$SELF_DIR/lib/common.sh"
trap 'err "Failed on line $LINENO"' ERR
require_root

if [[ -f /.dockerenv ]]; then
  err "Running inside a container: rebuild the image instead (docker compose up -d --build)."
  exit 1
fi

VENV_DIR="${VENV_DIR:-$APP_DIR/venv}"
PY="$VENV_DIR/bin/python"
[[ -f "$APP_DIR/manage.py" && -x "$PY" ]] || { err "No WafControl installation in $APP_DIR (set APP_DIR)."; exit 1; }
[[ -f "$APP_DIR/.env" ]] || { err "$APP_DIR/.env not found."; exit 1; }

installed_version() {  # 1.0.0 has no APP_VERSION setting
  local v
  v="$(sed -n "s/^APP_VERSION[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "$APP_DIR/WafControl/settings.py" 2>/dev/null | head -n1)"
  echo "${v:-1.0.0}"
}

detect_server() {
  if [[ -f /etc/nginx/modsec/main.conf ]]; then echo nginx
  elif [[ -f /etc/apache2/mods-enabled/security2.conf || -f /etc/modsecurity/modsecurity.conf ]]; then echo apache
  else echo none; fi
}

env_value() {  # env_value KEY : value from .env
  sed -n "s/^$1=//p" "$APP_DIR/.env" | tail -n1
}

FROM_VERSION="$(installed_version)"
SERVER="$(detect_server)"
UNITS=(wafcontrol.service wafcontrol-celery-worker.service wafcontrol-celery-beat.service)

banner "WafControl upgrade ${FROM_VERSION} -> ${TARGET_VERSION}" "=" 72
echo "• App:        $APP_DIR"
echo "• Source:     $REPO_URL @ $REPO_REF"
echo "• Web server: $SERVER"
echo "• Backups:    $BACKUP_ROOT"
case "$FROM_VERSION" in
  1.0.0) : ;;
  "$TARGET_VERSION") warn "Already on ${TARGET_VERSION}: the upgrade re-applies the code, migrations and fixes." ;;
  *) warn "Installed version ${FROM_VERSION} is not 1.0.0; continuing anyway." ;;
esac
ask_yn "Proceed?" "Y" || { warn "Aborted."; exit 0; }

# ---------- 1. Backup ----------
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$TS-from-$FROM_VERSION"
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR"
banner "Backup: $BACKUP_DIR" "-" 72

tar -C "$(dirname "$APP_DIR")" --exclude="$(basename "$APP_DIR")/venv" \
    -czf "$BACKUP_DIR/app.tar.gz" "$(basename "$APP_DIR")"
say "Application (code, .env, migrations): app.tar.gz"

DB_NAME="$(env_value DB_NAME)"; DB_USER="$(env_value DB_USER)"; DB_PASS="$(env_value DB_PASS)"
DB_HOST="$(env_value DB_HOST)"; DB_PORT="$(env_value DB_PORT)"
if PGPASSWORD="$DB_PASS" pg_dump -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-5432}" -U "$DB_USER" -Fc \
     -f "$BACKUP_DIR/db.dump" "$DB_NAME"; then
  say "Database: db.dump (restore: pg_restore --clean -d $DB_NAME db.dump)"
else
  err "Database backup failed; nothing was changed."
  exit 1
fi

case "$SERVER" in
  nginx)  tar -czf "$BACKUP_DIR/webserver.tar.gz" /etc/nginx 2>/dev/null ;;
  apache) tar -czf "$BACKUP_DIR/webserver.tar.gz" /etc/apache2 /etc/modsecurity 2>/dev/null ;;
esac
[[ -f "$BACKUP_DIR/webserver.tar.gz" ]] && say "Web server + ModSecurity config: webserver.tar.gz"

# ---------- 2. Code ----------
banner "Updating code" "-" 72
cd "$APP_DIR"
command -v git >/dev/null 2>&1 || apt-get install -y git
if [[ ! -d .git ]]; then
  err "$APP_DIR is not a git checkout; restore from $BACKUP_DIR/app.tar.gz or reinstall."
  exit 1
fi
OLD_COMMIT="$(git rev-parse HEAD)"
rollback_code() {
  warn "Restoring the previous code ($OLD_COMMIT)..."
  git -C "$APP_DIR" remote remove wafcontrol-upgrade 2>/dev/null || true
  git -C "$APP_DIR" checkout -q -f "$OLD_COMMIT" || true
  "$VENV_DIR/bin/pip" install -q -r "$APP_DIR/requirements.txt" || true
  svc_restart_all || true
}
svc_restart_all() {
  if has_systemd; then systemctl restart "${UNITS[@]}"; else warn "No systemd: restart Gunicorn and Celery yourself."; fi
}
trap 'err "Failed on line $LINENO"; rollback_code; err "Upgrade failed. Backups: $BACKUP_DIR"' ERR

# Local edits to tracked files would block the checkout; they are in the backup.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  warn "Local changes to tracked files are discarded (saved in $BACKUP_DIR/app.tar.gz)."
  git diff > "$BACKUP_DIR/local-changes.diff" || true
fi
git remote remove wafcontrol-upgrade 2>/dev/null || true
git remote add wafcontrol-upgrade "$REPO_URL"
git fetch -q --tags wafcontrol-upgrade "$REPO_REF"
git checkout -q -f FETCH_HEAD
git remote remove wafcontrol-upgrade
say "Code: $(git rev-parse --short HEAD) ($REPO_REF), version $(installed_version)"
[[ "$(installed_version)" == "$TARGET_VERSION" ]] || warn "Fetched code reports version $(installed_version)."

banner "Python requirements" "-" 72
"$VENV_DIR/bin/pip" install -q --upgrade pip
"$VENV_DIR/bin/pip" install -q -r requirements.txt
"$PY" manage.py check

# ---------- 3. Database ----------
banner "Database migrations" "-" 72
"$PY" manage.py makemigrations wafinstaller --noinput
# From here the schema changes: a code rollback alone is no longer enough.
trap 'err "Failed on line $LINENO"; err "Upgrade failed after the migration step. Restore code and database from $BACKUP_DIR"' ERR
"$PY" manage.py migrate --noinput
"$PY" manage.py collectstatic --noinput >/dev/null
say "Migrations applied, static files collected."

# ---------- 4. Web server / WAF ----------
banner "WAF configuration" "-" 72
if [[ "$SERVER" == "none" ]]; then
  warn "No nginx/Apache WAF found: skipped."
else
  # 1.1.0: panel-only exclusions; removes the global REQUEST-900 ones (ids 1500010/1500011).
  bash "$APP_DIR/scripts/panel_waf_exclusions.sh"
  if [[ "$SERVER" == "nginx" ]]; then
    # 1.1.0 reads request details from the audit log: nginx workers must be able to write it.
    AUDIT="$(awk '/^[[:space:]]*SecAuditLog[[:space:]]+/ {gsub(/"/, "", $2); print $2; exit}' /etc/nginx/modsec/modsecurity.conf 2>/dev/null || true)"
    NGX_USER="$(awk '/^[[:space:]]*user[[:space:]]+/ {gsub(/;/, "", $2); print $2; exit}' /etc/nginx/nginx.conf 2>/dev/null || true)"
    if [[ -n "$AUDIT" && -n "$NGX_USER" ]]; then
      touch "$AUDIT"; chown "$NGX_USER" "$AUDIT" 2>/dev/null || true; chmod 640 "$AUDIT"
      say "Audit log $AUDIT writable by $NGX_USER."
    fi
  fi
fi

# ---------- 5. Restart + checks ----------
banner "Restarting services" "-" 72
svc_restart_all
sleep 3
FAILED=0
if has_systemd; then
  for u in "${UNITS[@]}"; do
    if systemctl is-active --quiet "$u"; then ok "$u"; else err "$u is not running (journalctl -u $u)"; FAILED=1; fi
  done
fi
case "$SERVER" in
  nginx)  nginx -t >/dev/null 2>&1 && ok "nginx -t" || { err "nginx -t failed"; FAILED=1; } ;;
  apache) apache2ctl configtest >/dev/null 2>&1 && ok "apache2ctl configtest" || { err "apache2ctl configtest failed"; FAILED=1; } ;;
esac

line "=" 72
if [[ $FAILED -eq 0 ]]; then
  say "WafControl upgraded: ${FROM_VERSION} -> $(installed_version)."
else
  warn "Upgrade finished with errors (see above). Backups: $BACKUP_DIR"
fi
echo "Backups: $BACKUP_DIR"
echo "New optional settings (.env): CELERY_BROKER_URL, GITHUB_TOKEN, HTTPS_PROXY - see env.example."
exit $FAILED
