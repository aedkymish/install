#!/usr/bin/env bash
set -euo pipefail

is_tty=0; [ -t 1 ] && is_tty=1
if [ "$is_tty" -eq 1 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[1;34m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BLUE=''; NC=''
fi
say()  { printf "%b[+]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[!]%b %s\n" "$YELLOW" "$NC" "$*" >&2; }
err()  { printf "%b[x]%b %s\n" "$RED" "$NC" "$*" >&2; }
line() { local ch="${1:-=}"; local w="${2:-72}"; printf '%*s\n' "$w" '' | tr ' ' "$ch"; }
banner(){ local title="$1"; local ch="${2:-=}"; local w="${3:-72}"; line "$ch" "$w"; printf "%b%s%b\n" "$BLUE" "$title" "$NC"; line "$ch" "$w"; }

trap 'err "Failed on line $LINENO"' ERR
[[ $EUID -eq 0 ]] || { err "Run as root (sudo)."; exit 1; }

STATE_DIR="${STATE_DIR:-/var/lib/wafcontrol-installer}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/state.env}"
APP_DIR_DEFAULT="/opt/WafControl"

ask_yn() {
  local prompt="$1"
  local def="${2:-N}"
  local ans=""
  while :; do
    if [[ "$def" == "Y" ]]; then
      read -rp "${prompt} [Y/n]: " ans
      ans="${ans:-Y}"
    else
      read -rp "${prompt} [y/N]: " ans
      ans="${ans:-N}"
    fi
    case "$ans" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

nginx_modules_path() {
  command -v nginx >/dev/null 2>&1 || { echo ""; return 0; }
  nginx -V 2>&1 | sed -n 's/.*--modules-path=\([^ ]*\).*/\1/p' | tail -n1
}

remove_systemd_units() {
  local units=(wafcontrol.service wafcontrol-celery-worker.service wafcontrol-celery-beat.service)

  if ask_yn "Stop and disable WAFControl systemd services?" "Y"; then
    for u in "${units[@]}"; do
      systemctl disable --now "$u" >/dev/null 2>&1 || true
    done
    say "Services stopped/disabled."
  fi

  if ask_yn "Remove WAFControl systemd unit files?" "Y"; then
    rm -f /etc/systemd/system/wafcontrol.service \
          /etc/systemd/system/wafcontrol-celery-worker.service \
          /etc/systemd/system/wafcontrol-celery-beat.service || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    say "Unit files removed."
  fi
}

remove_runtime() {
  if [[ -d /run/wafcontrol ]]; then
    if ask_yn "Remove runtime directory /run/wafcontrol ?" "Y"; then
      rm -rf /run/wafcontrol
      say "Removed: /run/wafcontrol"
    fi
  fi
}

remove_nginx_wafcontrol_only() {
  command -v nginx >/dev/null 2>&1 || { warn "Nginx not detected. Skipping Nginx cleanup."; return 0; }

  local nginx_conf="/etc/nginx/nginx.conf"
  local so_name="ngx_http_modsecurity_module.so"
  local mp
  mp="$(nginx_modules_path || true)"

  if [[ -f /etc/nginx/conf.d/wafcontrol.conf ]]; then
    if ask_yn "Remove WAFControl vhost /etc/nginx/conf.d/wafcontrol.conf ?" "Y"; then
      rm -f /etc/nginx/conf.d/wafcontrol.conf
      say "Removed: /etc/nginx/conf.d/wafcontrol.conf"
    fi
  fi

  if [[ -d /etc/nginx/modsec ]]; then
    if ask_yn "Remove WAFControl ModSecurity/CRS directory /etc/nginx/modsec ?" "Y"; then
      rm -rf /etc/nginx/modsec
      say "Removed: /etc/nginx/modsec"
    fi
  fi

  if [[ -f "$nginx_conf" ]]; then
    if ask_yn "Remove WAFControl injected lines from /etc/nginx/nginx.conf (load_module + WAFCONTROL block)?" "Y"; then
      sed -i "/^[[:space:]]*load_module[[:space:]]\\+.*${so_name}[[:space:]]*;[[:space:]]*$/d" "$nginx_conf" || true
      sed -i '/# WAFCONTROL-BEGIN/,/# WAFCONTROL-END/d' "$nginx_conf" || true
      say "Removed WAFControl injections from nginx.conf"
    fi
  else
    warn "nginx.conf not found at $nginx_conf"
  fi

  if [[ -n "$mp" && -d "$mp" ]]; then
    if ask_yn "Remove WAFControl-built nginx dynamic module (${mp}/${so_name})?" "Y"; then
      rm -f "${mp}/${so_name}" || true
      say "Removed: ${mp}/${so_name}"
    fi
  else
    if ask_yn "nginx --modules-path not detected. Try removing module from common paths?" "Y"; then
      for p in /usr/lib/nginx/modules /usr/share/nginx/modules /etc/nginx/modules; do
        rm -f "${p}/${so_name}" 2>/dev/null || true
      done
      say "Attempted module removal from common module directories."
    fi
  fi

  if ask_yn "Test and reload Nginx configuration now?" "Y"; then
    if nginx -t >/dev/null 2>&1; then
      if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^nginx\.service'; then
        if systemctl is-active --quiet nginx; then
          systemctl reload nginx || true
          say "Reloaded nginx."
        else
          warn "nginx.service not active; skipping reload."
        fi
      else
        nginx -s reload >/dev/null 2>&1 || true
        say "Reloaded nginx (direct)."
      fi
    else
      warn "nginx -t failed after changes. Please review /etc/nginx/nginx.conf."
    fi
  fi
}

remove_app_dir() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  if [[ -d "$app_dir" ]]; then
    if ask_yn "Remove application directory ${app_dir}? This deletes project files and .env" "N"; then
      rm -rf "$app_dir"
      say "Removed: $app_dir"
    else
      say "Kept: $app_dir"
    fi
  else
    warn "App directory not found: $app_dir"
  fi
}

remove_state() {
  if [[ -f "$STATE_FILE" ]]; then
    if ask_yn "Remove installer state file ${STATE_FILE} ?" "N"; then
      rm -f "$STATE_FILE"
      say "Removed: $STATE_FILE"
    else
      say "Kept: $STATE_FILE"
    fi
  else
    warn "State file not found: $STATE_FILE"
  fi
}

banner "WAFControl Uninstaller (Safe)" "=" 72

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE" 2>/dev/null || true
  say "Loaded state: $STATE_FILE"
else
  warn "State file not found. Proceeding with best-effort cleanup."
fi

warn "This uninstaller removes ONLY WAFControl components."
warn "It will NOT remove Nginx packages, PostgreSQL packages, or any databases."
line "-" 72

remove_systemd_units
remove_runtime

if ask_yn "Perform Nginx cleanup for WAFControl (no package removal)?" "Y"; then
  remove_nginx_wafcontrol_only
fi

remove_app_dir
remove_state

line "=" 72
say "Uninstall completed."
