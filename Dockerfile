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

RUN printf 'upload_max_filesize = 100M\npost_max_size = 100M\nmemory_limit = 256M\nmax_execution_time = 3600\nmax_input_vars = 5000\nerror_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT & ~E_NOTICE & ~E_WARNING\n' \
        > /usr/local/etc/php/conf.d/suitecrm.ini

RUN sed -ri -e 's!/var/www/html!/apps/public!g' \
        /etc/apache2/sites-available/*.conf \
        /etc/apache2/apache2.conf \
    && sed -ri -e 's/Listen 80/Listen 8080/' /etc/apache2/ports.conf \
    && sed -ri -e 's/:80>/:8080>/' /etc/apache2/sites-available/*.conf \
    && printf '<Directory /apps/public>\n\tAllowOverride All\n\tRequire all granted\n</Directory>\n' \
        > /etc/apache2/conf-available/suitecrm.conf \
    && a2enconf suitecrm

WORKDIR /apps

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["apache2-foreground"]
