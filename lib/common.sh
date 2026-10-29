#!/usr/bin/env bash
# install/lib/common.sh - helpers shared by install.sh, uninstall.sh and install/modules/*.
#
# Sourced, never executed. Every module works the same on a regular host (systemd)
# and inside a container (no init system: services are run by supervisord), so all
# service handling goes through the svc_* functions below.

is_tty=0; [ -t 1 ] && is_tty=1
if [ "$is_tty" -eq 1 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[1;34m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BLUE=''; NC=''
fi
say()  { printf "%b[+]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[!]%b %s\n" "$YELLOW" "$NC" "$*" >&2; }
err()  { printf "%b[x]%b %s\n" "$RED" "$NC" "$*" >&2; }
ok()   { printf "%b[OK]%b %s\n" "$GREEN" "$NC" "$*"; }
line() { local ch="${1:-=}"; local w="${2:-72}"; printf '%*s\n' "$w" '' | tr ' ' "$ch"; }
banner(){ local title="$1"; local ch="${2:-=}"; local w="${3:-72}"; line "$ch" "$w"; printf "%b%s%b\n" "$BLUE" "$title" "$NC"; line "$ch" "$w"; }
section(){ printf "\n== %s ==\n" "$1"; }

require_root() { [[ $EUID -eq 0 ]] || { err "Run as root (sudo)."; exit 1; }; }

# ---------- install target ----------
# INSTALL_TARGET=host   : regular server, services managed by systemd (default)
# INSTALL_TARGET=docker : image build, nothing is started; supervisord runs the services
INSTALL_TARGET="${INSTALL_TARGET:-host}"
is_docker_build() { [[ "$INSTALL_TARGET" == "docker" ]]; }

# NONINTERACTIVE=1 (or install.sh --yes): every prompt takes its environment value or default.
NONINTERACTIVE="${NONINTERACTIVE:-0}"
is_docker_build && NONINTERACTIVE=1

# ask VAR "Prompt" [default] : keeps a preset $VAR, otherwise prompts (or takes the default).
ask() {
  local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
  if [[ -n "${!__var:-}" ]]; then return 0; fi
  if [[ "$NONINTERACTIVE" == "1" ]]; then printf -v "$__var" '%s' "$__def"; return 0; fi
  read -rp "${__prompt}${__def:+ [${__def}]}: " __ans
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

# ask_secret VAR "Prompt" : like ask, without echo; empty stays empty.
ask_secret() {
  local __var="$1" __prompt="$2" __ans=""
  if [[ -n "${!__var:-}" || "$NONINTERACTIVE" == "1" ]]; then return 0; fi
  read -srp "${__prompt}: " __ans; echo
  printf -v "$__var" '%s' "$__ans"
}

# ask_yn "Question" [Y|N] : returns 0 for yes. Non-interactive runs take the default.
ask_yn() {
  local prompt="$1" def="${2:-N}" ans=""
  if [[ "$NONINTERACTIVE" == "1" ]]; then [[ "$def" == "Y" ]]; return; fi
  while :; do
    if [[ "$def" == "Y" ]]; then read -rp "${prompt} [Y/n]: " ans; ans="${ans:-Y}"
    else read -rp "${prompt} [y/N]: " ans; ans="${ans:-N}"; fi
    case "$ans" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

# ---------- installer state ----------
STATE_DIR="${STATE_DIR:-/var/lib/wafcontrol-installer}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/state.env}"

state_init() {
  mkdir -p "$STATE_DIR"
  if ! grep -q 'STATE_VERSION=' "$STATE_FILE" 2>/dev/null; then
    {
      echo 'STATE_VERSION=2'
      echo 'INSTALL_TIMESTAMP='"$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo 'APP_DIR_DEFAULT=/opt/WafControl'
      echo 'declare -a CREATED_FILES=()'
      echo 'declare -a CREATED_UNITS=()'
      echo 'declare -A BACKUPS=()'
      echo 'declare -a CRS_DIRS=()'
      echo 'declare -A FLAGS=()'
    } > "$STATE_FILE"
  fi
}
state_load()         { [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" 2>/dev/null || true; }
state_append_array() { printf '%s+=(%q)\n' "$1" "$2" >> "$STATE_FILE"; }
state_put_map()      { printf '%s[%q]=%q\n' "$1" "$2" "$3" >> "$STATE_FILE"; }
state_put_flag()     { state_put_map FLAGS "$1" "$2"; }

# ---------- services ----------
has_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }

# Native reload for when systemd is not managing the service (containers, supervisord).
_svc_native_reload() {
  case "$1" in
    nginx)        nginx -s reload 2>/dev/null || nginx ;;   # start it when not running
    apache2)      apache2ctl -k graceful ;;
    httpd)        httpd -k graceful ;;
    postgresql)   service postgresql reload 2>/dev/null || service postgresql start ;;
    *)            return 1 ;;
  esac
}

# svc_enable_now <unit>... : enable + start on systemd hosts; no-op in an image build.
svc_enable_now() {
  is_docker_build && return 0
  if has_systemd; then systemctl enable --now "$@"; return; fi
  local s
  for s in "$@"; do service "$s" start 2>/dev/null || warn "No systemd: start $s yourself."; done
}

# svc_reload <name> : reload a running service. Skipped in an image build (nothing runs yet).
svc_reload() {
  is_docker_build && return 0
  if has_systemd && systemctl is-active --quiet "$1"; then
    systemctl reload "$1" || systemctl restart "$1"
  else
    _svc_native_reload "$1"
  fi
}

# svc_restart <name> : restart (or start) a service.
svc_restart() {
  is_docker_build && return 0
  if has_systemd; then systemctl restart "$1"; else _svc_native_reload "$1"; fi
}

gen_pass() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 64 | tr -d '\n' | tr '/+=' '___' | tr -d "'" | cut -c1-50
  else
    LC_ALL=C tr -dc 'A-Za-z0-9_' </dev/urandom | head -c 50
  fi
}
