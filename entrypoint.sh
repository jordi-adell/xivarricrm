#!/bin/bash
set -euo pipefail

: "${DB_HOST:?}" "${DB_NAME:?}" "${DB_USER:?}" "${DB_PASSWORD:?}"
: "${SUITECRM_ADMIN_USER:?}" "${SUITECRM_ADMIN_PASSWORD:?}" "${SITE_URL:?}"
DEMO_DATA="${DEMO_DATA:-no}"

CONFIG_FILE=/apps/public/legacy/config.php
IMAGE_VERSION=$(cat /suitecrm-version 2>/dev/null || echo "")

echo "Waiting for database at ${DB_HOST}..."
until php -r "
    \$mysqli = @mysqli_connect('${DB_HOST}', '${DB_USER}', '${DB_PASSWORD}', '${DB_NAME}');
    exit(\$mysqli ? 0 : 1);
"; do
    sleep 2
done
echo "Database is up."

upgrade_suitecrm() {
    local version="$1"
    local zip_url="https://github.com/SuiteCRM/SuiteCRM-Core/releases/download/v${version}/SuiteCRM-${version}.zip"
    local zip_path="/tmp/suitecrm-upgrade.zip"

    echo "Downloading SuiteCRM ${version} upgrade package..."
    curl -fsSL -o "${zip_path}" "${zip_url}"

    echo "Starting temporary Apache instance for upgrade self-checks..."
    apache2ctl start
    until php -r "exit(@file_get_contents('http://localhost:8888/') === false ? 1 : 0);" >/dev/null 2>&1; do
        sleep 1
    done

    echo "Waiting for ${SITE_URL} to be reachable through the reverse proxy..."
    until php -r "exit(@file_get_contents('${SITE_URL}/') === false ? 1 : 0);" >/dev/null 2>&1; do
        sleep 1
    done

    echo "Running SuiteCRM upgrade to ${version}..."
    php bin/console suitecrm:app:upgrade -p "${zip_path}"
    php bin/console suitecrm:app:upgrade-finalize

    apache2ctl stop
    sleep 1
    rm -f "${zip_path}"
}

install_suitecrm() {
    echo "Starting temporary Apache instance for installer self-checks..."
    apache2ctl start
    until php -r "exit(@file_get_contents('http://localhost:8888/') === false ? 1 : 0);" >/dev/null 2>&1; do
        sleep 1
    done

    echo "Waiting for ${SITE_URL} to be reachable through the reverse proxy..."
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
    if [ -n "${IMAGE_VERSION}" ] && [ "${1:-}" = "apache2-foreground" ]; then
        INSTALLED_VERSION=$(cat /apps/VERSION 2>/dev/null || echo "")
        if [ -n "${INSTALLED_VERSION}" ] && [ "${IMAGE_VERSION}" != "${INSTALLED_VERSION}" ]; then
            image_series=$(echo "${IMAGE_VERSION}" | cut -d. -f1,2)
            installed_series=$(echo "${INSTALLED_VERSION}" | cut -d. -f1,2)
            if [ "${image_series}" = "${installed_series}" ]; then
                echo "Upgrading SuiteCRM from ${INSTALLED_VERSION} to ${IMAGE_VERSION}..."
                upgrade_suitecrm "${IMAGE_VERSION}"
            else
                echo "Minor/major version change detected (${INSTALLED_VERSION} -> ${IMAGE_VERSION}). Skipping automatic upgrade — run manually."
            fi
        else
            echo "SuiteCRM ${INSTALLED_VERSION} is current, skipping upgrade."
        fi
    else
        echo "SuiteCRM already installed, skipping installer."
    fi
fi

chown -R www-data:www-data /apps

exec "$@"
