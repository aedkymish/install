#!/usr/bin/env bash
# modules/modsecurity-nginx.sh - libmodsecurity v3 (>= MODSEC_MIN_VERSION) and the ModSecurity-nginx
# dynamic module built for the installed Nginx.
#
# Uses the distribution package only when it is recent enough; otherwise builds the release
# from source into /usr/local/modsecurity. Run by waf-nginx.sh, and by upgrade.sh to replace
# a vulnerable engine on an existing server (nginx configuration is not touched).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

trap 'err "Failed on line $LINENO"' ERR
require_root
export DEBIAN_FRONTEND=noninteractive
mkdir -p "$STATE_DIR"; touch "$STATE_FILE"

command -v nginx >/dev/null 2>&1 || { err "Nginx is not installed."; exit 1; }

apt update -y
apt install -y build-essential pkg-config libpcre2-dev zlib1g-dev libssl-dev git curl jq wget

modsec_pkgconfig_env
if ! modsec_version_ok; then
  # libmodsecurity-dev pulls in the matching runtime package, including the
  # libmodsecurity3t64 rename on Ubuntu 24.04 and Debian 13.
  CANDIDATE="$(apt-cache policy libmodsecurity-dev 2>/dev/null | awk '/Candidate:/ {print $2}')"
  CANDIDATE="${CANDIDATE#*:}"   # drop an epoch
  if [[ -n "$CANDIDATE" && "$CANDIDATE" != "(none)" ]] && \
     dpkg --compare-versions "${CANDIDATE%%-*}" ge "$MODSEC_MIN_VERSION"; then
    apt install -y libmodsecurity-dev
  else
    say "Packaged libmodsecurity (${CANDIDATE:-none}) is older than ${MODSEC_MIN_VERSION}, which has known CVEs: building ${MODSEC_MIN_VERSION}."
  fi
fi

if ! modsec_version_ok; then
  say "Building libmodsecurity v${MODSEC_MIN_VERSION} from source..."
  . /etc/os-release 2>/dev/null || true
  PCRE_PKGS="libpcre3 libpcre3-dev"
  XML2_PKGS="libxml2 libxml2-dev"
  if { [ "${ID:-}" = "debian" ] && [ "${VERSION_CODENAME:-}" = "trixie" ]; } || \
     { [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_CODENAME:-}" = "noble" ]; }; then
    PCRE_PKGS="libpcre2-dev"
  elif [ "${ID:-}" = "debian" ] && [ "${VERSION_CODENAME:-}" = "bookworm" ]; then
    PCRE_PKGS="libpcre3 libpcre3-dev libpcre2-dev"
  fi
  if { [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_CODENAME:-}" = "resolute" ]; }; then
    XML2_PKGS="libxml2-dev"
    PCRE_PKGS="libpcre2-dev"
  fi
  apt install -y make gcc autoconf automake libtool gettext pkg-config \
    libcurl4-openssl-dev liblua5.3-dev $PCRE_PKGS \
    $XML2_PKGS libyajl-dev doxygen libgeoip-dev libssl-dev \
    zlib1g-dev libxslt1-dev liblmdb-dev libgd-dev git uuid-dev

  # Use a release, so its configuration files can be retrieved by the same tag.
  MODSEC_SOURCE="/usr/local/src/ModSecurity-v${MODSEC_MIN_VERSION}"
  test -d "$MODSEC_SOURCE" || git clone --depth 1 --recursive -b "v${MODSEC_MIN_VERSION}" \
    https://github.com/owasp-modsecurity/ModSecurity.git "$MODSEC_SOURCE"
  cd "$MODSEC_SOURCE"
  git submodule sync --recursive
  git submodule update --init --recursive
  ./build.sh
  ./configure --prefix="$MODSEC_PREFIX"
  make -j"$(nproc)"
  make install
  # Found before the distribution's older libmodsecurity at run time.
  echo "$MODSEC_PREFIX/lib" > /etc/ld.so.conf.d/00-modsecurity.conf
  ldconfig
  modsec_pkgconfig_env
  state_append_array CREATED_FILES "$MODSEC_PREFIX"
  state_append_array CREATED_FILES /etc/ld.so.conf.d/00-modsecurity.conf
  say "libmodsecurity built and installed."
else
  say "libmodsecurity present via packages."
fi
modsec_version_ok || { err "libmodsecurity >= ${MODSEC_MIN_VERSION} is required."; exit 1; }

MODSEC_VERSION="$(pkg-config --modversion modsecurity)"
# Make the connector use the same library whose version selects the template.
export MODSECURITY_INC="$(pkg-config --variable=includedir modsecurity)"
export MODSECURITY_LIB="$(pkg-config --variable=libdir modsecurity)"
say "Using ModSecurity v${MODSEC_VERSION} (${MODSECURITY_LIB})."

test -d /usr/local/src/ModSecurity-nginx || git clone --depth 1 https://github.com/owasp-modsecurity/ModSecurity-nginx.git /usr/local/src/ModSecurity-nginx
NVER="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" || NVER=""
[[ -n "$NVER" ]] || { err "Cannot detect Nginx version."; exit 1; }

MOD_DIR="$(nginx_modules_dir)"
say "Using modules dir: $MOD_DIR"

mkdir -p /usr/local/src/nginx && cd /usr/local/src/nginx
if [[ ! -d "nginx-${NVER}" ]]; then
  say "Fetching nginx source: ${NVER}"
  wget -q "https://nginx.org/download/nginx-${NVER}.tar.gz"
  tar -xzf "nginx-${NVER}.tar.gz"
fi

apt-get build-dep -y nginx 2>/dev/null || true
cd "nginx-${NVER}"
make clean >/dev/null 2>&1 || true
./configure --with-compat --add-dynamic-module=/usr/local/src/ModSecurity-nginx
make modules

install -d -m 0755 "$MOD_DIR"
cp -f objs/ngx_http_modsecurity_module.so "$MOD_DIR/ngx_http_modsecurity_module.so"
state_append_array CREATED_FILES "$MOD_DIR/ngx_http_modsecurity_module.so"
say "Dynamic module built against ModSecurity v${MODSEC_VERSION}."
