#!/bin/bash
set -euo pipefail

: "${DB_HOST:?}" "${DB_NAME:?}" "${DB_USER:?}" "${DB_PASSWORD:?}"
: "${SUITECRM_ADMIN_USER:?}" "${SUITECRM_ADMIN_PASSWORD:?}" "${SITE_URL:?}"
DEMO_DATA="${DEMO_DATA:-no}"

CONFIG_FILE=/apps/public/legacy/config.php

echo "Waiting for database at ${DB_HOST}..."
until php -r "
    \$mysqli = @mysqli_connect('${DB_HOST}', '${DB_USER}', '${DB_PASSWORD}', '${DB_NAME}');
    exit(\$mysqli ? 0 : 1);
"; do
    sleep 2
done
echo "Database is up."

install_suitecrm() {
    echo "Starting temporary Apache instance for installer self-checks..."
    apache2ctl start
    until php -r "exit(@file_get_contents('${SITE_URL}/') === false ? 1 : 0);" >/dev/null 2>&1; do
        sleep 1
    done

    echo "Running SuiteCRM installer..."
    php bin/console suitecrm:app:install \
        -u "${SUITECRM_ADMIN_USER}" \
        -p "${SUITECRM_ADMIN_PASSWORD}" \
        -U "${DB_USER}" \
        -P "${DB_PASSWORD}" \
        -H "${DB_HOST}" \
        -N "${DB_NAME}" \
        -S "${SITE_URL}" \
        -d "${DEMO_DATA}"

    apache2ctl stop
    sleep 1
}

if [ ! -f "$CONFIG_FILE" ]; then
    if [ "${1:-}" = "apache2-foreground" ]; then
        install_suitecrm
    else
        echo "Waiting for the app container to finish installing SuiteCRM..."
        until [ -f "$CONFIG_FILE" ]; do
            sleep 2
        done
    fi
else
    echo "SuiteCRM already installed, skipping installer."
fi

chown -R www-data:www-data /apps

exec "$@"
