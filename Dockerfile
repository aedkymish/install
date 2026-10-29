# WafControl in one container: nginx (or Apache) + ModSecurity + CRS + the panel (Gunicorn,
# Celery worker and beat) under supervisord. PostgreSQL and Redis run in their own containers
# (see docker-compose.yml). The image is built by the same install.sh used on servers.
#
#   docker build -t wafcontrol .                                   # app from REPO_URL/REPO_BRANCH
#   docker build -t wafcontrol --build-arg SERVER=apache .          # Apache + ModSecurity2
#   docker build -t wafcontrol --build-context app=../wafcontrol .  # app from a local checkout
#   --build-arg BASE_IMAGE=debian:trixie-slim (or ubuntu:24.04)     # another supported distribution

ARG BASE_IMAGE=debian:bookworm-slim

# Empty unless overridden with --build-context app=<path>.
FROM scratch AS app

FROM ${BASE_IMAGE}

ARG SERVER=nginx
ARG REPO_URL=https://github.com/aedkymish/wafcontrol.git
ARG REPO_BRANCH=main
ARG HTTP_PORT=7000

ENV DEBIAN_FRONTEND=noninteractive \
    APP_DIR=/opt/WafControl \
    WAFCONTROL_SERVER=${SERVER} \
    WAFCONTROL_PANEL_PORT=${HTTP_PORT} \
    PYTHONUNBUFFERED=1

COPY . /opt/wafcontrol-installer
COPY --from=app . /usr/src/wafcontrol

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates git curl openssl; \
    if [ -f /usr/src/wafcontrol/manage.py ]; then export APP_SRC=/usr/src/wafcontrol; fi; \
    SERVER="$SERVER" HTTP_PORT="$HTTP_PORT" REPO_URL="$REPO_URL" REPO_BRANCH="$REPO_BRANCH" \
      bash /opt/wafcontrol-installer/install.sh --docker; \
    # Build leftovers: sources of the nginx connector/ModSecurity, caches.
    rm -rf /usr/src/wafcontrol /usr/local/src/nginx /usr/local/src/ModSecurity* \
           /root/.cache /var/lib/apt/lists/*; \
    install -m 0755 /opt/wafcontrol-installer/docker/entrypoint.sh /usr/local/bin/wafcontrol-entrypoint

# 7000: panel. 80/443: the sites you protect (add their server blocks from the panel).
EXPOSE 7000 80 443

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
  CMD code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost' http://127.0.0.1:${WAFCONTROL_PANEL_PORT}/)"; \
      [ "$code" != "000" ] && [ "$code" -lt 500 ]

ENTRYPOINT ["/usr/local/bin/wafcontrol-entrypoint"]
CMD ["supervisord", "-c", "/etc/supervisor/wafcontrol.conf"]
