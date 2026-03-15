#!/bin/bash
set -euo pipefail

API_ROOT=/srv/www/obs/api
BACKEND_ROOT=/srv/obs
OBS_CONFIG_FILE=/etc/default/obs-server
SECRET_KEY_FILE="$API_ROOT/config/secret.key"
DB_CONFIG_FILE="$API_ROOT/config/database.yml"
DB_USER=obsapi
DB_PASSWORD=opensuse

if [ -f "$OBS_CONFIG_FILE" ]; then
  source "$OBS_CONFIG_FILE"
elif [ -f /etc/sysconfig/obs-server ]; then
  OBS_CONFIG_FILE=/etc/sysconfig/obs-server
  source "$OBS_CONFIG_FILE"
fi

if [ "${OBS_API_AUTOSETUP:-no}" != "yes" ]; then
  echo "OBS API autosetup is disabled in ${OBS_CONFIG_FILE}; skipping."
  exit 0
fi

if [ -n "${OBS_BASE_DIR:-}" ]; then
  BACKEND_ROOT="$OBS_BASE_DIR"
fi

ensure_secret_key() {
  if [ ! -s "$SECRET_KEY_FILE" ]; then
    sha256sum </dev/null | cut -d' ' -f1 > "$SECRET_KEY_FILE"
  fi

  if getent group www-data >/dev/null; then
    chgrp www-data "$SECRET_KEY_FILE"
    chmod 0640 "$SECRET_KEY_FILE"
  fi
}

ensure_database_access() {
  command -v mysql >/dev/null 2>&1 || return 0

  mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS api_production CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS api_development CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS api_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON api_production.* TO '$DB_USER'@'localhost';
GRANT ALL PRIVILEGES ON api_development.* TO '$DB_USER'@'localhost';
GRANT ALL PRIVILEGES ON api_test.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
}

ensure_database_config() {
  [ -f "$DB_CONFIG_FILE" ] || return 0
  sed -i \
    -e "s/^  username: .*/  username: $DB_USER/" \
    -e "s/^  password: .*/  password: $DB_PASSWORD/" \
    "$DB_CONFIG_FILE"

  if getent group www-data >/dev/null; then
    chgrp www-data "$DB_CONFIG_FILE"
    chmod 0640 "$DB_CONFIG_FILE"
  fi
}

mkdir -p \
  "$API_ROOT/config" \
  "$API_ROOT/db/sphinx/production" \
  "$API_ROOT/log" \
  "$API_ROOT/storage" \
  "$API_ROOT/tmp/home" \
  "$API_ROOT/tmp/pids"

ensure_secret_key
ensure_database_access
ensure_database_config

touch "$API_ROOT/log/production.log" "$API_ROOT/log/db_migrate.log"

if getent passwd www-data >/dev/null && getent group www-data >/dev/null; then
  chown -R www-data:www-data \
    "$API_ROOT/db/sphinx" \
    "$API_ROOT/log" \
    "$API_ROOT/storage" \
    "$API_ROOT/tmp"

  for path in \
    "$API_ROOT" \
    "$API_ROOT/config.ru" \
    "$API_ROOT/public"; do
    if [ -e "$path" ]; then
      chown www-data:www-data "$path"
    fi
  done
fi

if getent passwd obsrun >/dev/null && getent group obsrun >/dev/null; then
  chown obsrun:obsrun "$BACKEND_ROOT"
fi

cd "$API_ROOT"

export HOME="${HOME:-/root}"
export RAILS_ENV=production
export SAFETY_ASSURED=1

if bin/rails db:migrate:status >/dev/null 2>&1; then
  bin/rails db:migrate:with_data >> "$API_ROOT/log/db_migrate.log" 2>&1
else
  bin/rails db:setup writeconfiguration >> "$API_ROOT/log/db_migrate.log" 2>&1
fi
