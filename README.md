[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# OWASP WAFControl Installer

The **OWASP WAFControl** project provides a web-based dashboard and management interface for ModSecurity and the OWASP Core Rule Set (CRS).  
It simplifies installation, configuration, and operation of CRS and ModSecurity, enabling administrators and security engineers to deploy, monitor, and manage WAF rules more effectively.


## Easy Install

```bash
curl -fsSL https://raw.githubusercontent.com/aedkymish/install/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

Downloaded on its own, `install.sh` fetches the rest of the installer (`lib/`, `modules/`) from
`INSTALLER_URL` and runs it. From a checkout of this repository it uses the local files:

```bash
git clone https://github.com/aedkymish/install.git && cd install
sudo ./install.sh
```

The application is cloned from `REPO_URL` (default `https://github.com/aedkymish/wafcontrol.git`,
branch `REPO_BRANCH`, default `main`), or copied from a local checkout with `APP_SRC=/path/to/wafcontrol`.

### Unattended install

Every question can be answered from the environment; `--yes` takes the defaults for the rest:

```bash
sudo SERVER=nginx MODE=ip HTTP_PORT=7000 DB_NAME=wafcontrol DB_USER=wafcontrol_user \
     BASIC_AUTH_ENABLE=0 ./install.sh --yes
```

| Variable | Meaning | Default |
|---|---|---|
| `SERVER` | `nginx` or `apache` | detected / asked |
| `MODE` | `ip` or `domain` | `ip` |
| `HTTP_PORT` | panel port in `ip` mode | `7000` |
| `DOMAIN`, `SSL_ENABLE`, `CERTBOT_EMAIL` | `domain` mode, Let's Encrypt | |
| `DB_NAME`, `DB_USER`, `DB_PASS`, `PG_VERSION` | PostgreSQL | `wafcontrol`, `wafcontrol_user`, generated, `18` |
| `BASIC_AUTH_ENABLE`, `BASIC_AUTH_USER`, `BASIC_AUTH_PASS` | extra HTTP Basic Auth | off |
| `APP_DIR`, `APP_SRC`, `REPO_URL`, `REPO_BRANCH` | where the application comes from / goes | `/opt/WafControl` |

## Docker

The image runs nginx (or Apache) + ModSecurity + CRS and the panel (Gunicorn, Celery worker and beat)
under supervisord; PostgreSQL and Redis run in their own containers. It is built by the same
`install.sh` (`--docker` mode: installs everything, starts nothing).

```bash
git clone https://github.com/aedkymish/install.git && cd install
cp docker/.env.example .env        # set DB_PASS, the admin account and ALLOWED_HOSTS
docker compose up -d --build       # Apache: docker compose -f docker-compose.apache.yml up -d --build
```

- Panel: `http://<host>:7000/` (admin from `DJANGO_SUPERUSER_*` in `.env`, created on first start).
- Sites to protect: add their `server` blocks / virtual hosts from the panel; they are served on ports 80/443
  of the container. Upstreams in other containers are reached by service name (`proxy_pass http://app:8080;`).
- Persistent volumes: web server and ModSecurity/CRS configuration, logs (including the ModSecurity audit
  log), PostgreSQL, Redis, and `/var/lib/wafcontrol` (`SECRET_KEY`, generated migrations).
- Build the application from a local checkout instead of `REPO_URL`:
  `docker build -t wafcontrol --build-context app=../wafcontrol .`
- Requires a WafControl version where `CELERY_BROKER_URL` can be set from the environment.

## Upgrade 1.0.0 → 1.1.0

```bash
git clone https://github.com/aedkymish/install.git && cd install
sudo ./upgrade.sh            # --yes for no questions, --ref <tag|branch> for another version
```

1. Backs up the application (code, `.env`, migrations), the database (`pg_dump`) and the web server /
   ModSecurity configuration to `/var/backups/wafcontrol/<date>-from-<version>/`.
2. Fetches the new code (`REPO_URL`, default `https://github.com/aedkymish/wafcontrol.git`, ref `main`),
   installs the Python requirements and runs `manage.py check`.
3. Generates and applies the migrations (IP/Geo lists, attack request details) and collects static files.
4. Replaces the global CRS exclusions of 1.0.0 (ids 1500010/1500011, which disabled the WAF on those paths
   for **every** site) with panel-only exclusions, and makes the ModSecurity audit log writable by nginx.
5. Restarts `wafcontrol`, `wafcontrol-celery-worker` and `wafcontrol-celery-beat` and checks them.

If something fails before the migrations, the previous code is restored automatically. After that point,
restore from the backup folder (`pg_restore --clean -d <db> db.dump`, `tar -xzf app.tar.gz -C /opt`).
Docker: rebuild instead (`docker compose up -d --build`); migrations run when the container starts.

## Nginx / ModSecurity compatibility

The Nginx installer uses the `modsecurity` pkg-config metadata to select the
library and downloads `modsecurity.conf-recommended` and `unicode.mapping` from
that exact v3 release. It installs `libmodsecurity-dev`, which resolves the
runtime package name on each distribution (including `libmodsecurity3t64` on
Ubuntu 24.04), and checks the configuration with Nginx before enabling it.

Earlier installers could copy an Apache/v2 or newer configuration into Nginx.
The error `Expecting a variable ... MULTIPART_DUPLICATE_PART_HEADER` means the
configuration refers to a variable the loaded engine does not recognize. The
variable was introduced in [ModSecurity v3.0.17](https://github.com/owasp-modsecurity/ModSecurity/releases/tag/v3.0.17);
Ubuntu 24.04 packages [v3.0.12](https://packages.ubuntu.com/en/noble/libs/libmodsecurity3t64).
The updated module backs up and repairs this diagnostic text on older engines,
while retaining multipart strict validation and existing local settings.

To repair this specific error on an already installed server without rerunning
the application/database installation:

```bash
sudo bash <<'BASH'
set -euo pipefail
conf=/etc/nginx/modsec/modsecurity.conf
backup="${conf}.bak.$(date +%s)"
cp -a -- "$conf" "$backup"
sed -i -E 's/DH[[:blank:]]+%\{MULTIPART_DUPLICATE_PART_HEADER\},[[:blank:]]*//g' "$conf"
if nginx -t; then
  systemctl reload nginx
else
  cp -a -- "$backup" "$conf"
  exit 1
fi
BASH
```

Run the offline regression checks with:

```bash
python3 -m unittest discover -s tests -v
```

## Uninstall

WAFControl provides an interactive and safe uninstallation process.

⚠️ IMPORTANT

If Nginx or PostgreSQL were already installed on your server before WAFControl, DO NOT remove them.
Removing Nginx or PostgreSQL may break other applications and cause irreversible data loss.
If you remove them anyway, the responsibility is entirely yours.

This BASH uninstall removes only the files and components added by WAFControl and does not modify NGINX or PostgreSQL (or any other system services).
If PostgreSQL already existed on your server or contains data you want to remove, you must handle/remove it manually if needed.
The OWASP WAFControl project and its contributors are not responsible for any data loss caused by manual or forced removal of system services.

```bash
curl -fsSL https://raw.githubusercontent.com/wafcontrol/install/refs/heads/main/uninstall.sh -o uninstall.sh
```

```bash
chmod +x uninstall.sh
```

```bash
sudo ./uninstall.sh
```


## WAFControl Resources
- [OWASP WAFControl Project Site](https://wafcontrol.org/)
- [OWASP WAFControl Project Page](https://owasp.org/www-project-wafcontrol/)  

## Documentation
- [OWASP WAFControl Docs](https://wafcontrol.org/docs)


## License

Copyright (c) 2025 OWASP WAFControl Project.  
All rights reserved.  

The OWASP WAFControl project is distributed under the Apache Software License (ASL) version 2.0.  
See the enclosed [LICENSE](./LICENSE) file for full details.
