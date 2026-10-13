FROM php:8.3-apache-bookworm@sha256:b79a53c3fb1dd4b9f350a8d99d84951512b6c21044e61bbecfee8af030b3722e

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libpq-dev \
    && docker-php-ext-install pdo_pgsql \
    && a2enmod headers \
    && sed -i 's/Listen 80/Listen 8080/' /etc/apache2/ports.conf \
    && sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' /etc/apache2/sites-available/000-default.conf \
    && rm -rf /var/lib/apt/lists/*

COPY apache-site.conf /etc/apache2/sites-available/000-default.conf
COPY apache-rootless.conf /etc/apache2/conf-available/rootless.conf
RUN a2enconf rootless && rm -f /var/www/html/index.html

WORKDIR /var/www/app
COPY config.php db_connect.php ./
COPY public/ /var/www/app/public/

ENV APACHE_RUN_DIR=/tmp \
    APACHE_LOCK_DIR=/tmp \
    APACHE_LOG_DIR=/tmp \
    APACHE_PID_FILE=/tmp/apache2.pid

USER www-data
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
    CMD ["php", "-r", "exit(@file_get_contents('http://127.0.0.1:8080/health.php') === false ? 1 : 0);"]
CMD ["apache2-foreground"]
