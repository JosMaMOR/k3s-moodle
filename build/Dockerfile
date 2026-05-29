# ============================================================
# Moodle 5.1.1 para K3s — Apache HTTP only (sin SSL)
#
# ARQUITECTURA HTTPS:
#   Navegador → HTTPS:443 → Traefik (termina TLS) → HTTP:8080 → Este pod
#
# CAMBIOS RESPECTO A VERSIÓN ANTERIOR:
#   - Código Moodle copiado completo (moodle/) a /var/www/html-source
#     preservando estructura original del repositorio Moodle 5.1
#   - DocumentRoot cambiado a /var/www/html/public (Moodle 5.1)
#   - admin/cli/install.php puede subir 2 niveles y encontrar public/lib/
#   - Código Moodle en /var/www/html-source (no en /var/www/html)
#     El entrypoint copia html-source → html en primer arranque
#     Resuelve: PVC vacío sobreescribía el código de la imagen
#   - /var/www/html eliminado del VOLUME
#   - Eliminado mod_ssl y VirtualHost 8443
#   - Apache escucha solo en 8080 HTTP
#   - Eliminado /etc/apache2/ssl del VOLUME y de permisos
#   - El entrypoint ya no genera ni lee certificados
#   - HEALTHCHECK cambiado a HTTP en 8080
#   - Traefik inyecta X-Forwarded-Proto: https para que Moodle
#     genere URLs https:// correctamente
#   - Para cambiar certificado: solo actualizar Secret TLS en K8s
#     sin reconstruir esta imagen
#
# STAGE 1: Builder
# ============================================================
FROM debian:12-slim AS builder

ARG MOODLE_VERSION=5.1.1
WORKDIR /moodle-build

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        unzip \
        git \
        php8.2 \
        php8.2-mysql \
        php8.2-xml \
        php8.2-xmlrpc \
        php8.2-intl \
        php8.2-curl \
        php8.2-zip \
        php8.2-mbstring \
        php8.2-gd \
        php8.2-soap \
        php8.2-opcache \
        php8.2-readline \
        php8.2-cli \
        php8.2-ldap \
        php8.2-gmp \
        php8.2-bz2 \
        php8.2-pspell \
        php8.2-snmp \
        php8.2-xsl \
        php8.2-odbc \
        php-redis \
        redis-tools \
        ghostscript \
        openssl \
        netcat-traditional \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sS https://getcomposer.org/installer \
    | php -- --install-dir=/usr/local/bin --filename=composer

# Moodle 5.1 estructura real:
#   moodle/admin/cli/install.php  ← CLI de instalación (fuera de public/)
#   moodle/public/                ← DocumentRoot web (lib/, login/, etc.)
#   moodle/public/lib/            ← librerías PHP principales
#
# install.php hace: dirname(__DIR__, 2) . '/public/lib/'
# Es decir, sube 2 niveles desde admin/cli/ → busca public/lib/
# Para que esto funcione, la estructura de directorios debe
# preservarse EXACTAMENTE como en el repositorio:
#   /moodle-build/admin/cli/install.php
#   /moodle-build/public/lib/phpminimumversionlib.php
#
# Por eso copiamos TODO moodle/ completo sin reordenar nada.
# El DocumentRoot de Apache apuntará a /var/www/html/public/
COPY moodle /moodle-build/

RUN composer install \
        --no-dev \
        --no-interaction \
        --optimize-autoloader \
        --classmap-authoritative \
        --apcu-autoloader \
    && rm -rf /root/.composer/cache \
    && composer clear-cache

# ============================================================
# STAGE 2: Runtime
# ============================================================
FROM debian:12-slim

LABEL org.opencontainers.image.title="Moodle Apache PHP K3s RAID" \
      org.opencontainers.image.description="Moodle 5.1.1 para K3s HA — Apache HTTP, TLS en Traefik" \
      org.opencontainers.image.version="5.1.1-k3s-raid" \
      org.opencontainers.image.authors="MSCD. Gustavo Romero" \
      org.opencontainers.image.vendor="TESOEM"

ARG MOODLE_VERSION=5.1.1

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    APACHE_RUN_USER=moodle \
    APACHE_RUN_GROUP=www-data \
    APACHE_PID_FILE=/tmp/apache2.pid \
    APACHE_LOG_DIR=/var/log/apache2 \
    APACHE_RUN_DIR=/tmp/apache2/run \
    K3S_MODE=false \
    TERM=xterm

# ============================================================
# Dependencias — sin openssl ni ssl libs de apache
# ============================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    locales \
    apache2 \
    libapache2-mod-php8.2 \
    php8.2 \
    php8.2-mysql \
    php8.2-xml \
    php8.2-xmlrpc \
    php8.2-intl \
    php8.2-curl \
    php8.2-zip \
    php8.2-mbstring \
    php8.2-gd \
    php8.2-soap \
    php8.2-opcache \
    php8.2-readline \
    php8.2-cli \
    php8.2-ldap \
    php8.2-gmp \
    php8.2-bz2 \
    php8.2-pspell \
    php8.2-snmp \
    php8.2-xsl \
    php8.2-odbc \
    php-redis \
    redis-tools \
    curl \
    rsync \
    ca-certificates \
    ghostscript \
    netcat-traditional \
    procps \
    && sed -i 's/# es_MX.UTF-8 UTF-8/es_MX.UTF-8 UTF-8/' /etc/locale.gen \
    && sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen \
    && update-locale LANG=en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ============================================================
# Configurar Apache — solo HTTP 8080, sin SSL
#
# Se habilitan los módulos necesarios para Moodle y para que
# Apache procese correctamente el header X-Forwarded-Proto que
# envía Traefik. Con ese header, Moodle sabe que la conexión
# original del usuario es HTTPS aunque Apache reciba HTTP.
# ============================================================
RUN a2enmod rewrite headers env mime dir setenvif \
    && a2dismod ssl 2>/dev/null || true \
    && a2dissite 000-default default-ssl 2>/dev/null || true \
    && sed -i \
        -e 's/Listen 80$/Listen 8080/' \
        -e '/Listen 443/d' \
        -e '/Listen 8443/d' \
        -e '/<IfModule ssl_module>/,/<\/IfModule>/d' \
        /etc/apache2/ports.conf \
    && mkdir -p /var/www/moodledata \
               /var/www/html \
               /var/run/apache2 \
               /etc/apache2/custom-conf \
    && chmod 777 /var/run/apache2 \
    && useradd -u 1001 -r -g www-data -d /var/www -s /usr/sbin/nologin moodle \
    && sed -i 's/^User www-data/User moodle/' /etc/apache2/apache2.conf \
    && sed -i 's/^Group www-data/Group www-data/' /etc/apache2/apache2.conf \
    && sed -i 's|^PidFile .*|PidFile /tmp/apache2.pid|' /etc/apache2/apache2.conf \
    && echo "IncludeOptional custom-conf/*.conf" >> /etc/apache2/apache2.conf

# ============================================================
# PHP
# ============================================================
RUN cat > /etc/php/8.2/moodle-php.ini << 'EOFPHP'
memory_limit = 512M
max_execution_time = 600
max_input_time = 300
max_input_vars = 5000
post_max_size = 512M
upload_max_filesize = 512M
max_file_uploads = 20
default_charset = "UTF-8"
mbstring.internal_encoding = UTF-8
mbstring.http_output = UTF-8
mbstring.encoding_translation = On
session.save_handler = files
session.save_path = /var/www/moodledata/sessions
session.gc_probability = 1
session.gc_divisor = 1000
session.gc_maxlifetime = 7200
opcache.enable = 1
opcache.enable_cli = 1
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 32
opcache.max_accelerated_files = 16000
opcache.revalidate_freq = 2
opcache.validate_timestamps = 0
opcache.save_comments = 1
opcache.fast_shutdown = 1
opcache.optimization_level = 0xFFFFFFFF
expose_php = Off
allow_url_fopen = Off
allow_url_include = Off
display_errors = Off
log_errors = On
error_log = /var/log/apache2/php_errors.log
date.timezone = America/Mexico_City
EOFPHP

RUN cp /etc/php/8.2/moodle-php.ini /etc/php/8.2/apache2/conf.d/99-moodle.ini \
    && cp /etc/php/8.2/moodle-php.ini /etc/php/8.2/cli/conf.d/99-moodle.ini \
    && rm /etc/php/8.2/moodle-php.ini

RUN php -r "if (ini_get('max_input_vars') < 5000) { echo 'ERROR: max_input_vars < 5000\n'; exit(1); } else { echo 'OK: PHP configurado correctamente\n'; }"

# ============================================================
# Directorios temporales para Apache rootless
#
# PROBLEMA: Apache crea sockets en /var/run/apache2/ e intenta
# hacer chown sobre ellos. Como el contenedor corre sin root
# (usuario moodle uid 1001), ese chown falla con "Operation not
# permitted" y Apache no arranca.
#
# SOLUCIÓN COMPLETA: redirigir TODAS las rutas de runtime de
# Apache a /tmp/apache2/* donde el usuario moodle tiene permisos
# totales. Hay tres lugares donde Apache lee estas rutas:
#   1. apache2.conf  → directivas PidFile, Mutex, DefaultRuntimeDir
#   2. envvars       → variables APACHE_RUN_DIR, APACHE_LOCK_DIR
#   3. /var/run/apache2 → symlink al directorio real en /tmp
#
# Los tres deben apuntar a /tmp para evitar el error de chown.
# ============================================================
RUN mkdir -p /tmp/apache2/run /tmp/apache2/lock /tmp/apache2/logs \
    && chmod -R 777 /tmp/apache2 \
    \
    # 1. Redirigir rutas en apache2.conf
    && sed -i 's|/var/run/apache2|/tmp/apache2/run|g' /etc/apache2/apache2.conf \
    && sed -i 's|/var/lock/apache2|/tmp/apache2/lock|g' /etc/apache2/apache2.conf \
    \
    # 2. Redirigir TODAS las variables de runtime en envvars
    #    envvars es el archivo que Apache lee para sus variables
    #    internas — sin esto, los sockets se crean en /var/run/apache2
    #    donde root es el dueño y moodle no puede hacer chown
    && sed -i 's|/var/run/apache2|/tmp/apache2/run|g'  /etc/apache2/envvars \
    && sed -i 's|/var/lock/apache2|/tmp/apache2/lock|g' /etc/apache2/envvars \
    && sed -i 's|/var/log/apache2|/tmp/apache2/logs|g'  /etc/apache2/envvars \
    # Corregir usuario de www-data a moodle en envvars
    && sed -i 's|APACHE_RUN_USER=www-data|APACHE_RUN_USER=moodle|g' /etc/apache2/envvars \
    # Eliminar $SUFFIX que impide la correcta expansión de rutas
    && sed -i 's|\$SUFFIX||g' /etc/apache2/envvars \
    \
    # 3. Añadir directivas explícitas al final de apache2.conf
    #    (sobreescriben cualquier valor anterior en el archivo)
    && echo "" >> /etc/apache2/apache2.conf \
    && echo "# Rootless K3s — rutas en /tmp" >> /etc/apache2/apache2.conf \
    && echo "PidFile /tmp/apache2/run/apache2.pid" >> /etc/apache2/apache2.conf \
    && echo "Mutex file:/tmp/apache2/lock default" >> /etc/apache2/apache2.conf \
    && echo "DefaultRuntimeDir /tmp/apache2/run" >> /etc/apache2/apache2.conf \
    \
    # 4. Reemplazar /var/run/apache2 con symlink → /tmp/apache2/run
    #    para que cualquier referencia hardcodeada en módulos funcione
    && rm -rf /var/run/apache2 \
    && ln -sfn /tmp/apache2/run /var/run/apache2 \
    \
    # 5. Logs a /dev/stdout y /dev/stderr para kubectl logs
    && rm -rf /var/log/apache2 \
    && ln -sfn /tmp/apache2/logs /var/log/apache2 \
    && touch /tmp/apache2/logs/access.log \
              /tmp/apache2/logs/error.log \
              /tmp/apache2/logs/php_errors.log \
    && chmod 755 /tmp/apache2/logs \
    && ln -sf /dev/stdout /tmp/apache2/logs/access.log \
    && ln -sf /dev/stderr /tmp/apache2/logs/error.log \
    && ln -sf /dev/stderr /tmp/apache2/logs/php_errors.log

# ============================================================
# Moodle desde builder
# ============================================================
# ============================================================
# Moodle desde builder → /var/www/html-source
#
# RAZÓN CRÍTICA: el VOLUME /var/www/html se monta desde un PVC
# de Kubernetes que inicialmente está vacío. Si copiamos Moodle
# directamente a /var/www/html, el PVC vacío sobreescribe ese
# contenido en tiempo de ejecución y el pod arranca sin código.
#
# Solución: el código vive en /var/www/html-source dentro de la
# imagen. El entrypoint lo copia a /var/www/html (el PVC) en el
# primer arranque si detecta que el volumen está vacío.
# En arranques posteriores, el código ya está en el PVC y se
# omite la copia — arranque rápido sin trabajo extra.
# ============================================================
COPY --from=builder --chown=moodle:www-data /moodle-build /var/www/html-source

# ============================================================
# VirtualHost HTTP 8080 — único virtualhost
#
# SetEnvIf X-Forwarded-Proto https HTTPS=on
#   Le indica a PHP que la conexión original es HTTPS aunque
#   Apache reciba HTTP. Moodle usa $_SERVER['HTTPS'] para
#   decidir si generar URLs https:// — sin este flag genera
#   URLs http:// y rompe las redirecciones SSL de Traefik.
#
# Header always set Strict-Transport-Security
#   Fuerza al navegador a usar HTTPS. Traefik lo podría poner
#   también, pero incluirlo aquí garantiza que siempre esté.
# ============================================================
COPY <<'EOFVHOST' /etc/apache2/sites-available/moodle.conf
<VirtualHost *:8080>
    ServerAdmin admin@tesoem.edu.mx
    ServerName mcc.tesoem.edu.mx
    ServerAlias localhost

    # Moodle 5.1: DocumentRoot es public/ — los archivos web
    # (login/, index.php, etc.) viven en public/, mientras que
    # admin/cli/, lib/ etc. viven en la raíz del proyecto
    # un nivel arriba de public/
    DocumentRoot /var/www/html/public

    <Directory /var/www/html/public>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
        DirectoryIndex index.php
    </Directory>

    # ── Soporte X-Forwarded-Proto de Traefik ─────────────────────────────────
    # Traefik termina el TLS y reenvía la petición a este pod como HTTP.
    # Incluye el header X-Forwarded-Proto: https para indicar que el cliente
    # usó HTTPS. SetEnvIf lo convierte en la variable HTTPS=on que PHP lee
    # con $_SERVER['HTTPS'], permitiendo que Moodle genere URLs https://
    # correctamente sin que Apache gestione ningún certificado.
    SetEnvIf X-Forwarded-Proto "https" HTTPS=on
    SetEnvIf X-Forwarded-Proto "https" HTTP_X_FORWARDED_PROTO=https

    # Headers de seguridad
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"

    ErrorLog /var/log/apache2/error.log
    CustomLog /var/log/apache2/access.log combined
</VirtualHost>
EOFVHOST

RUN a2ensite moodle.conf

# ============================================================
# Entrypoint
# ============================================================
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

# ============================================================
# Permisos finales — sin /etc/apache2/ssl
# ============================================================
RUN chown -R moodle:www-data \
        /var/www/html-source \
        /var/www/moodledata \
        /etc/apache2/custom-conf \
        /tmp/apache2 \
    && chmod 2770 /var/www/moodledata \
    && chmod -R 777 /tmp/apache2 \
    && chmod 777 /tmp

# ============================================================
# Healthcheck — HTTP en 8080 (Traefik gestiona el HTTPS)
# ============================================================
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -f http://localhost:8080/login/index.php || exit 1

USER moodle
WORKDIR /var/www/html

EXPOSE 8080

# /etc/apache2/ssl eliminado del VOLUME — ya no se usa
# /var/www/html eliminado del VOLUME — el entrypoint copia
# el código de html-source al PVC montado en /var/www/html.
# Declararlo como VOLUME evitaría que el COPY del builder
# llegara a html-source en builds futuros con capas cacheadas.
VOLUME ["/var/www/moodledata", "/etc/apache2/custom-conf"]

ENTRYPOINT ["/entrypoint.sh"]
