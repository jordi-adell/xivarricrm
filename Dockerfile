FROM php:8.3-apache AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        unzip \
        libicu-dev \
        libzip-dev \
        libpng-dev \
        libjpeg62-turbo-dev \
        libfreetype6-dev \
        libonig-dev \
        libxml2-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        gd \
        intl \
        mbstring \
        mysqli \
        pdo_mysql \
        soap \
        zip \
    && rm -rf /var/lib/apt/lists/*

ADD https://suitecrm.com/download/168/suite810/568626/suitecrm-8-10-1.zip /suitecrm.zip
RUN unzip /suitecrm.zip -d /apps/ \
    && rm /suitecrm.zip \
    && find /apps -type d -exec chmod 2755 {} \; \
    && find /apps -type f -exec chmod 0644 {} \; \
    && chown -R www-data:www-data /apps \
    && chmod +x /apps/bin/console


FROM php:8.3-apache

RUN apt-get update && apt-get install -y --no-install-recommends \
        libicu76 \
        libzip5 \
        libpng16-16t64 \
        libjpeg62-turbo \
        libfreetype6 \
        libonig5 \
    && a2enmod rewrite \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=builder /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/
COPY --from=builder /apps /apps

RUN printf 'upload_max_filesize = 100M\npost_max_size = 100M\nmemory_limit = 256M\nmax_execution_time = 3600\nmax_input_vars = 5000\nerror_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT & ~E_NOTICE & ~E_WARNING\ndisplay_errors = Off\nlog_errors = On\n' \
        > /usr/local/etc/php/conf.d/suitecrm.ini

# Esplai Xivarri branding — logo assets derived from https://xivarri.org/ (see branding/ in this repo)
# company_logo.png is reused verbatim (same <img src>) in both the navy topbar and the
# white login-page background, so it's a navy-on-white "badge" rather than a flat navy
# cutout — that's what keeps it readable on both.
COPY --chown=www-data:www-data branding/logo-banner.png /apps/public/legacy/themes/default/images/company_logo.png
COPY --chown=www-data:www-data branding/logo-banner.png /apps/public/dist/themes/suite8/images/suitecrm_logo.png
COPY --chown=www-data:www-data branding/logo-login.png /apps/public/legacy/themes/suite8/images/p_login_logo.png
COPY --chown=www-data:www-data branding/logo-login.png /apps/public/legacy/themes/suite8/images/sidebar/modules/p_login_logo.png
COPY --chown=www-data:www-data branding/logo-login.svg /apps/public/legacy/themes/suite8/images/p_login_logo.svg
COPY --chown=www-data:www-data branding/logo-login.svg /apps/public/legacy/themes/suite8/images/icon_p_login_logo_32.svg
COPY --chown=www-data:www-data branding/logo-login.svg /apps/public/legacy/themes/suite8/images/sidebar/modules/p_login_logo.svg
COPY --chown=www-data:www-data branding/favicon.ico /apps/public/favicon.ico
COPY --chown=www-data:www-data branding/favicon.ico /apps/public/dist/themes/suite8/images/favicon.ico

# Recolor SuiteCRM's default palette to Esplai Xivarri's brand colors (taken from xivarri.org's
# own CSS: navy #003388, amber #f0bc00) across every compiled stylesheet that uses it — this
# covers the default Bootstrap "primary" blue family, the topbar's purple family, the login
# button's coral family, and one standalone bright-blue accent.
RUN find /apps/public/dist /apps/public/legacy/themes/suite8/css -type f -name '*.css' -print0 2>/dev/null \
    | xargs -0 -r sed -i \
        -e 's/007bff/003388/gI' \
        -e 's/0069d9/002b74/gI' \
        -e 's/0062cc/00296d/gI' \
        -e 's/005cbf/002666/gI' \
        -e 's/004085/001b47/gI' \
        -e 's/80bdff/8099c4/gI' \
        -e 's/b8daff/b8c6de/gI' \
        -e 's/cce5ff/ccd6e7/gI' \
        -e 's/268fff/26529a/gI' \
        -e 's/534d64/003388/gI' \
        -e 's/8d74cc/6584b7/gI' \
        -e 's/eb6657/f0bc00/gI' \
        -e 's/ee8776/f3c932/gI' \
        -e 's/f08377/f3c931/gI' \
        -e 's/f5aea6/f7dc78/gI'

RUN sed -ri -e 's!/var/www/html!/apps/public!g' \
        /etc/apache2/sites-available/*.conf \
        /etc/apache2/apache2.conf \
    && sed -ri -e 's/Listen 80/Listen 8888/' /etc/apache2/ports.conf \
    && sed -ri -e 's/:80>/:8888>/' /etc/apache2/sites-available/*.conf \
    && printf '<Directory /apps/public>\n\tAllowOverride All\n\tRequire all granted\n</Directory>\n' \
        > /etc/apache2/conf-available/suitecrm.conf \
    && a2enconf suitecrm

WORKDIR /apps

# Override the base php:8.3-apache image's inherited "EXPOSE 80" — Apache in this image
# actually listens on 8888 (see above), so 80 is stale/misleading metadata otherwise.
EXPOSE 8888

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["apache2-foreground"]
