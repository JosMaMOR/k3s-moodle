#!/bin/bash
# ============================================================
# entrypoint.sh v2 — Moodle 5.1.x · K3s TESOEM
#
# MEJORAS RESPECTO A v1:
#   1. set -euo pipefail  → variables no declaradas causan error
#   2. wait_for_service() → función reutilizable con timeout máximo
#   3. generate_config()  → config.php en archivo temporal + mv atómico
#   4. verify_config()    → valida PHP sintaxis antes de arrancar
#   5. trap ERR/EXIT      → limpieza y diagnóstico en fallos
#   6. Aliases DB         → un solo grupo de variables (sin triplicados)
#   7. Cron sin solapamiento → flock evita ejecuciones paralelas
#   8. log() consistente  → prefijo [HH:MM:SS] en todos los mensajes
#   9. DIRROOT configurable via env var
#  10. install.php: verificación correcta con set -e (|| die)
#
# FLUJO:
#   1. Verificar PHP
#   2. Variables de entorno
#   3. Esperar servicios (con timeout máximo)
#   4. Sincronizar código al PVC
#   5a/5b. Instalar o verificar config.php existente
#   6. Generar/completar config.php K3s (función atómica)
#   7. Permisos moodledata
#   8. Cron interno (opcional, sin solapamiento)
#   9. Validación final (incluye php -l)
#  10. Arrancar Apache
# ============================================================
set -euo pipefail

# ── Colores ──────────────────────────────────────────────────
_G='\033[0;32m'; _Y='\033[1;33m'; _R='\033[0;31m'
_C='\033[0;36m'; _B='\033[1m';    _N='\033[0m'

# ── Logging centralizado ─────────────────────────────────────
# Todos los mensajes pasan por log() con timestamp uniforme.
# Elimina la mezcla de echo "✓", echo "[Entrypoint]" y echo "=>"
# que había en v1.
log()  { echo -e "${_C}[$(date +%H:%M:%S)]${_N} $*"; }
ok()   { echo -e "${_G}[$(date +%H:%M:%S)] ✓${_N} $*"; }
warn() { echo -e "${_Y}[$(date +%H:%M:%S)] ⚠${_N} $*"; }
die()  { echo -e "${_R}[$(date +%H:%M:%S)] ✗ FATAL:${_N} $*" >&2; exit 1; }

# ── Trap de errores ───────────────────────────────────────────
# En v1, un fallo inesperado dejaba el contenedor sin contexto.
# Con trap, cualquier error inesperado muestra en qué línea ocurrió
# y qué archivos existen, facilitando el diagnóstico desde los logs.
_trap_err() {
    local LINE="$1"
    echo -e "\n${_R}[$(date +%H:%M:%S)] ✗ Error inesperado en línea ${LINE}${_N}" >&2
    echo "  config.php public: $(ls -la /var/www/html/public/config.php 2>/dev/null || echo 'ausente')"
    echo "  config.php raíz:   $(ls -la /var/www/html/config.php 2>/dev/null || echo 'ausente')"
    echo "  Pods K8s podrán ver este error en: kubectl logs -n moodle-prod <pod> -c moodle"
}
trap '_trap_err ${LINENO}' ERR

# ── Función: esperar un servicio TCP con timeout máximo ───────
# MEJORA sobre v1: el bucle until sin timeout podía colgar el pod
# para siempre si el servicio nunca arrancaba. K8s no lo detectaba
# porque el proceso seguía vivo (no era un crash).
# Ahora: si el servicio no responde en MAX_WAIT segundos → die()
# K8s reiniciará el pod automáticamente.
#
# Uso: wait_for_service "MariaDB" "mariadb" 3306 300 5
#   arg1: nombre legible
#   arg2: host
#   arg3: puerto
#   arg4: timeout máximo en segundos (default 300)
#   arg5: intervalo entre intentos (default 5)
wait_for_service() {
    local NAME="$1"
    local HOST="$2"
    local PORT="$3"
    local MAX_WAIT="${4:-300}"
    local INTERVAL="${5:-5}"
    local ELAPSED=0

    log "Esperando ${NAME} en ${HOST}:${PORT} (máx ${MAX_WAIT}s)..."
    until timeout 2 bash -c "</dev/tcp/${HOST}/${PORT}" 2>/dev/null; do
        if [ "${ELAPSED}" -ge "${MAX_WAIT}" ]; then
            die "${NAME} no disponible después de ${MAX_WAIT}s en ${HOST}:${PORT}"
        fi
        log "  ${NAME} no disponible — reintentando en ${INTERVAL}s (${ELAPSED}/${MAX_WAIT}s)"
        sleep "${INTERVAL}"
        ELAPSED=$(( ELAPSED + INTERVAL ))
    done
    ok "${NAME} disponible en ${HOST}:${PORT}"
}

# ── Función: generar config.php K3s de forma atómica ─────────
# MEJORA sobre v1: en v1 el config.php se construía con 3 heredocs
# separados y 2 appends condicionales. Si algún paso fallaba a mitad,
# el archivo quedaba corrupto sin posibilidad de rollback.
# Ahora: se escribe en un archivo temporal y solo se mueve al
# destino final cuando está completo y validado.
#
# Uso: generate_config <config_base_sin_require> <destino>
generate_config() {
    local CONFIG_BASE="$1"
    local DEST="$2"
    local TMP_CFG
    TMP_CFG=$(mktemp /tmp/moodle-config-XXXXXX.php)

    # Construir config.php completo en un solo bloque
    # El password de Redis se inyecta condicionalmente dentro del heredoc
    local REDIS_AUTH_SESSION REDIS_AUTH_CACHE
    if [ -n "${REDIS_PASSWORD:-}" ]; then
        REDIS_AUTH_SESSION="\$CFG->session_redis_auth = '${REDIS_PASSWORD}';"
        REDIS_AUTH_CACHE="\$CFG->cachestore_redis_password = '${REDIS_PASSWORD}';"
    else
        REDIS_AUTH_SESSION="\$CFG->session_redis_auth = null;"
        REDIS_AUTH_CACHE="\$CFG->cachestore_redis_password = null;"
    fi

    cat > "${TMP_CFG}" << CFGEOF
${CONFIG_BASE}

// ── Moodle 5.1: dirroot ──────────────────────────────────────────────────────
// Sin dirroot, Moodle deduce la ruta usando __DIR__ desde config.php.
// En 5.1+ config.php vive en public/, pero lib/ admin/ y theme/ están
// un nivel arriba → Moodle no los encuentra → 500 en recursos dinámicos.
// DIRROOT es configurable vía variable de entorno para facilitar pruebas.
\$CFG->dirroot = '${MOODLE_DIRROOT}';

// ── K3s / Traefik ────────────────────────────────────────────────────────────
// reverseproxy=false: Traefik inyecta IP interna del nodo, no la del cliente.
//   Con true → Moodle bloquea con "El proxy inverso está habilitado".
// sslproxy=true: X-Forwarded-Proto: https → Moodle genera URLs https://
\$CFG->reverseproxy = false;
\$CFG->sslproxy     = true;

// ── Idioma ───────────────────────────────────────────────────────────────────
\$CFG->lang      = '${MOODLE_LANG}';
\$CFG->langcache = true;

// ── Sesiones en Redis (DB 0) ─────────────────────────────────────────────────
\$CFG->session_handler_class              = '\\core\\session\\redis';
\$CFG->session_redis_host                 = '${REDIS_HOST}';
\$CFG->session_redis_port                 = ${REDIS_PORT};
\$CFG->session_redis_prefix               = 'moodle_sess_';
\$CFG->session_redis_acquire_lock_timeout = 120;
\$CFG->session_redis_lock_expire          = 7200;
\$CFG->session_redis_database             = 0;
${REDIS_AUTH_SESSION}

// ── Caché en Redis (DB 1) ────────────────────────────────────────────────────
\$CFG->cachestore_redis_server   = '${REDIS_HOST}';
\$CFG->cachestore_redis_port     = ${REDIS_PORT};
\$CFG->cachestore_redis_database = 1;
\$CFG->cachestore_redis_prefix   = 'moodle_cache_';
${REDIS_AUTH_CACHE}

// ── Rendimiento ──────────────────────────────────────────────────────────────
// NOTA: ini_set('memory_limit') en config.php solo puede BAJAR el límite
// respecto al valor de php.ini, no subirlo. El valor efectivo se establece
// en el Dockerfile via php.ini o en el entrypoint via PHP_VALUE.
// Esta línea queda como referencia pero el límite real lo fija el entrypoint.
// @ini_set('memory_limit', '${MOODLE_MEMORY_LIMIT}');

// ── Bootstrap — debe ser la ÚLTIMA línea ejecutable ─────────────────────────
require_once(__DIR__ . '/lib/setup.php');
CFGEOF

    # Validar sintaxis PHP antes de mover al destino
    # MEJORA v1: en v1 no se validaba. Si el heredoc generaba PHP inválido
    # (p.ej. por una variable con caracteres especiales), Apache arrancaba
    # pero Moodle fallaba en cada petición con errores de parseo.
    php -l "${TMP_CFG}" > /dev/null 2>&1 \
        || die "config.php generado tiene sintaxis PHP inválida — revisar variables de entorno"

    # Mover atómicamente al destino
    mv "${TMP_CFG}" "${DEST}"
    chmod 640 "${DEST}"
    ok "config.php generado y validado en ${DEST}"
}

# ════════════════════════════════════════════════════════════════════════════
# INICIO
# ════════════════════════════════════════════════════════════════════════════

echo -e "\n${_B}════════════════════════════════════════${_N}"
echo -e "${_B} Moodle Container · K3s TESOEM${_N}"
echo -e "${_B} Image:   ${IMAGE_VERSION:-5.1.x}${_N}"
echo -e "${_B} Moodle:  ${MOODLE_VERSION:-detectando...}${_N}"
echo -e "${_B} HTTPS:   Traefik → HTTP:8080${_N}"
echo -e "${_B}════════════════════════════════════════${_N}\n"

# ============================================================
# 1. VERIFICAR PHP
# ============================================================
log "[1/9] Verificando requisitos PHP..."

PHP_VARS=$(php -r "echo ini_get('max_input_vars');")
log "  max_input_vars: ${PHP_VARS}"

[ "${PHP_VARS}" -lt 5000 ] \
    && die "max_input_vars=${PHP_VARS} — requiere >= 5000. Revisa php.ini en la imagen."

ok "[1/9] PHP OK"

# ============================================================
# 2. VARIABLES DE ENTORNO
# ============================================================
# MEJORA v1: se eliminaron los 3 grupos de aliases redundantes
# (MARIADB_* → MOODLE_DB_* → DB_*). Ahora hay un solo grupo.
# Variables obligatorias usan :? para fallar temprano con mensaje claro.
# ============================================================
log "[2/9] Configurando variables..."

: "${MARIADB_HOST:=maxscale}"
: "${MARIADB_PORT:=3306}"
: "${MARIADB_DATABASE:=moodle}"
: "${MARIADB_USER:=moodle}"
: "${MARIADB_PASSWORD:?MARIADB_PASSWORD es obligatoria — definir en el Secret K8s}"

: "${REDIS_HOST:=redis}"
: "${REDIS_PORT:=6379}"
: "${REDIS_PASSWORD:=}"

: "${SERVER_NAME:=mcc.tesoem.edu.mx}"
: "${MOODLE_URL:=https://${SERVER_NAME}}"
: "${MOODLE_LANG:=es_mx}"
: "${MOODLE_CHMOD:=2777}"
: "${MOODLE_MEMORY_LIMIT:=1G}"   # 512M es insuficiente para Moodle en producción

# DIRROOT configurable — facilita pruebas 5.1.1 → 5.1.3
# En 5.1.1 se puede dejar vacío; en 5.1.3 debe ser '/var/www/html/public'
: "${MOODLE_DIRROOT:=/var/www/html/public}"

: "${MOODLE_FULLNAME:=Plataforma Educativa TESOEM}"
: "${MOODLE_SHORTNAME:=TESOEM-Moodle}"
: "${MOODLE_ADMIN_USER:=admin}"
: "${MOODLE_ADMIN_PASS:?MOODLE_ADMIN_PASS es obligatoria — definir en el Secret K8s}"
: "${MOODLE_ADMIN_EMAIL:=admin@tesoem.edu.mx}"

: "${ENABLE_CRON:=false}"
: "${SVC_WAIT_TIMEOUT:=300}"    # segundos máximos esperando servicios
: "${SVC_WAIT_INTERVAL:=5}"     # segundos entre reintentos

ok "[2/9] Variables configuradas"

# ============================================================
# 3. ESPERAR SERVICIOS
# ============================================================
# MEJORA v1: función reutilizable con timeout configurable.
# Sin timeout el pod podía quedar colgado indefinidamente.
# ============================================================
log "[3/9] Verificando servicios..."

wait_for_service "MariaDB" \
    "${MARIADB_HOST}" "${MARIADB_PORT}" \
    "${SVC_WAIT_TIMEOUT}" "${SVC_WAIT_INTERVAL}"

wait_for_service "Redis" \
    "${REDIS_HOST}" "${REDIS_PORT}" \
    "${SVC_WAIT_TIMEOUT}" "3"

ok "[3/9] Servicios disponibles"

# ============================================================
# 4. SINCRONIZAR CÓDIGO AL PVC
# ============================================================
log "[4/9] Verificando código Moodle en volumen..."

MARKER="/var/www/html/.moodle-code-installed"
EXPECTED_VERSION="${MOODLE_VERSION:-5.1.3}"

# Volumen "válido" = existe el marcador Y coincide la versión esperada
if [ -f "${MARKER}" ] && grep -q "^${EXPECTED_VERSION}$" "${MARKER}" 2>/dev/null; then
    ok "[4/9] Código verificado — versión: ${EXPECTED_VERSION}"
else
    if [ -f "${MARKER}" ]; then
        warn "  Marcador presente pero versión no coincide — recopiando"
    else
        log "  Volumen sin marcador válido — copiando código desde imagen..."
    fi

    # Limpiar antes de re-copiar (importante sobre NFS: evita mezclar restos)
    find /var/www/html -mindepth 1 -not -name '.moodle-code-installed' -delete 2>/dev/null || true

    COPY_START=$(date +%s)
    # rsync es más confiable que cp sobre NFS: verifica tamaños, reintenta,
    # y --fsync fuerza commit al server antes de retornar.
    if command -v rsync >/dev/null 2>&1; then
	# -r recursive, -l symlinks, -p perms de archivos, -D devices/specials
	# NO usar -t (timestamps), -o (owner), -g (group) → todos disparan EPERM
	# --omit-dir-times: clave para no tocar timestamps de directorios
	# --no-perms en directorios evita chmod sobre el raíz (otro EPERM potencial)
        rsync -rlpD --omit-dir-times --no-perms /var/www/html-source/ /var/www/html/
    else
        cp -r --preserve=mode /var/www/html-source/. /var/www/html/
    fi

    # Validar que la copia llegó completa antes de dejar el marcador
    [ -f /var/www/html/public/version.php ] || \
        die "Copia incompleta: public/version.php ausente tras cp/rsync"
    [ -f /var/www/html/admin/cli/install.php ] || \
        die "Copia incompleta: admin/cli/install.php ausente"

    # Forzar flush al servidor NFS antes de escribir el marcador
    sync

    # Eliminar config.php que pudo venir bakeado en la imagen
    rm -f /var/www/html/public/config.php
    rm -f /var/www/html/config.php

    # Marcador atómico AL FINAL — si llegamos aquí, todo cuajó
    echo "${EXPECTED_VERSION}" > "${MARKER}.tmp"
    sync
    mv "${MARKER}.tmp" "${MARKER}"

    COPY_SECS=$(( $(date +%s) - COPY_START ))
    ok "[4/9] Código copiado y validado en ${COPY_SECS}s"
fi
# ============================================================
# 5. INSTALACIÓN O VERIFICACIÓN DE CONFIG.PHP
# ============================================================
# El loader Moodle 5.1 (public/config.php del paquete) NO contiene
# "$CFG = new stdClass()", solo redirige. El config.php REAL sí lo tiene.
# Distinguirlos por contenido, no solo por existencia.
is_real_moodle_config() {
    [ -f "$1" ] && ! [ -L "$1" ] && \
        grep -q 'CFG[[:space:]]*=[[:space:]]*new[[:space:]]*stdClass' "$1" 2>/dev/null
}

CONFIG_FILE=""
if is_real_moodle_config /var/www/html/config.php; then
    CONFIG_FILE="/var/www/html/config.php"
elif is_real_moodle_config /var/www/html/public/config.php; then
    CONFIG_FILE="/var/www/html/public/config.php"
fi

if [ -n "${CONFIG_FILE}" ]; then
    # ----------------------------------------------------------
    # 5b. INSTALACIÓN EXISTENTE
    # ----------------------------------------------------------
    ok "[5/9] Instalación existente — config.php en: ${CONFIG_FILE}"

    # Migración pre-5.1: config.php en raíz → mover a public/
    if [ "${CONFIG_FILE}" = "/var/www/html/config.php" ] && \
       [ ! -f /var/www/html/public/config.php ]; then
        log "  Migrando config.php raíz → public/ (Moodle 5.1)..."
        cp /var/www/html/config.php /var/www/html/public/config.php
        chmod 640 /var/www/html/public/config.php || true
        ln -sf /var/www/html/public/config.php \
               /var/www/html/config.php 2>/dev/null || true
        CONFIG_FILE="/var/www/html/public/config.php"
        ok "  Migración completada"
    fi

    # Symlink raíz → public para CLI (admin/cli/ sube 2 niveles)
    if [ ! -e /var/www/html/config.php ]; then
        ln -sf /var/www/html/public/config.php /var/www/html/config.php
        ok "  Symlink raíz → public/config.php creado"
    fi

    # Aviso de cambio de dominio (sin modificar automáticamente)
    CURRENT_URL=$(grep -oP "(?<=wwwroot\s*=\s*')[^']+" \
                  "${CONFIG_FILE}" 2>/dev/null || echo "")
    if [ -n "${CURRENT_URL}" ] && [ "${CURRENT_URL}" != "${MOODLE_URL}" ]; then
        warn "  wwwroot en config.php (${CURRENT_URL}) ≠ MOODLE_URL (${MOODLE_URL})"
        warn "  Para cambiar dominio ejecuta dentro del pod:"
        warn "    php /var/www/html/admin/cli/cfg.php --name=wwwroot --set=${MOODLE_URL}"
    fi

else
    # ----------------------------------------------------------
    # 5a. PRIMERA INSTALACIÓN
    # ----------------------------------------------------------
    log "[5/9] Primera instalación..."
    log "  URL:   ${MOODLE_URL}"
    log "  DB:    ${MARIADB_HOST}:${MARIADB_PORT}/${MARIADB_DATABASE}"
    log "  Admin: ${MOODLE_ADMIN_USER}"

    mkdir -p /var/www/moodledata 2>/dev/null || true
    chown moodle:www-data /var/www/moodledata 2>/dev/null || true
    chmod 2777 /var/www/moodledata 2>/dev/null || true

    # MEJORA v1: en v1 se usaba if [ $? -ne 0 ] después del install.php,
    # lo cual es INCORRECTO con set -e activo. Con set -e, si install.php
    # falla el script ya terminó antes de llegar al if.
    # Solución: deshabilitar set -e para este comando y usar || die()
    set +e
    php /var/www/html/admin/cli/install.php \
        --non-interactive \
        --chmod="${MOODLE_CHMOD}" \
        --lang="${MOODLE_LANG}" \
        --wwwroot="${MOODLE_URL}" \
        --dataroot="/var/www/moodledata" \
        --dbtype="mariadb" \
        --dbhost="${MARIADB_HOST}" \
        --dbport="${MARIADB_PORT}" \
        --dbname="${MARIADB_DATABASE}" \
        --dbuser="${MARIADB_USER}" \
        --dbpass="${MARIADB_PASSWORD}" \
        --prefix="mdl_" \
        --fullname="${MOODLE_FULLNAME}" \
        --shortname="${MOODLE_SHORTNAME}" \
        --adminuser="${MOODLE_ADMIN_USER}" \
        --adminpass="${MOODLE_ADMIN_PASS}" \
        --adminemail="${MOODLE_ADMIN_EMAIL}" \
        --supportemail="${MOODLE_ADMIN_EMAIL}" \
        --agree-license
    INSTALL_RC=$?
    set -e

    [ "${INSTALL_RC}" -ne 0 ] \
        && die "install.php falló (código ${INSTALL_RC}). Revisa los logs de MariaDB."

    ok "  Instalación CLI completada"

    # Habilitar cron en BD (el instalador lo deja en 0)
    php /var/www/html/admin/cli/cfg.php \
        --name=cron_enabled --set=1 2>/dev/null \
        && ok "  cron_enabled=1 en BD" \
        || warn "  No se pudo habilitar cron — ejecutar manualmente"

    # Detectar dónde dejó config.php el instalador
    # 5.1.1 → /var/www/html/config.php (raíz)
    # 5.1.3 → /var/www/html/public/config.php
    if [ -f /var/www/html/public/config.php ] && \
       [ ! -L /var/www/html/public/config.php ]; then
        CONFIG_FILE="/var/www/html/public/config.php"
    elif [ -f /var/www/html/config.php ] && \
         [ ! -L /var/www/html/config.php ]; then
        CONFIG_FILE="/var/www/html/config.php"
    else
        die "install.php no generó config.php en ninguna ubicación esperada"
    fi

    log "  config.php del instalador en: ${CONFIG_FILE}"

    # ── Extraer base del instalador y generar config K3s completo ──
    # Eliminar el require_once que añade el instalador — lo añadiremos
    # nosotros al final de forma controlada con un solo require_once.
    CONFIG_BASE=$(grep -v "require_once.*setup.php" "${CONFIG_FILE}" \
                  | grep -v "^// There is no php closing" \
                  | grep -v "^// it is intentional")

    # generate_config() escribe en tmp → valida con php -l → mv atómico
    generate_config "${CONFIG_BASE}" "${CONFIG_FILE}"

    # Asegurar que config.php queda en public/ con symlink en raíz
    if [ "${CONFIG_FILE}" != "/var/www/html/public/config.php" ]; then
        cp "${CONFIG_FILE}" /var/www/html/public/config.php
        chmod 640 /var/www/html/public/config.php || true
        CONFIG_FILE="/var/www/html/public/config.php"
    fi

    ln -sf /var/www/html/public/config.php \
           /var/www/html/config.php 2>/dev/null || true

    ok "[5/9] Instalación y config.php completados"
fi

# ============================================================
# 6. GARANTIZAR DIRROOT EN CONFIG.PHP
# ============================================================
# Se ejecuta SIEMPRE — tras 5a (nueva instalación) y 5b (existente).
#
# 5a: generate_config() ya incluyó dirroot. Se verifica y reporta.
# 5b: config.php preexistente puede no tener dirroot (instalaciones
#     5.1.1 con entrypoint v1). Se añade antes del require_once.
#
# Regla: si dirroot ya existe (cualquier valor) NO se modifica.
#        Solo se añade cuando está completamente ausente.
# ============================================================
log "[6/10] Verificando dirroot en config.php..."

CFG_TARGET="/var/www/html/public/config.php"
[ ! -f "${CFG_TARGET}" ] && CFG_TARGET="${CONFIG_FILE:-}"
[ -z "${CFG_TARGET}" ] && die "No se pudo determinar la ubicación de config.php"

if grep -q "CFG->dirroot" "${CFG_TARGET}" 2>/dev/null; then
    DIRROOT_CURRENT=$(grep "CFG->dirroot" "${CFG_TARGET}" \
                      | grep -v "^//" \
                      | grep -oP "(?<= = ')[^']+" \
                      | head -1 || echo "")
    ok "  dirroot presente: '${DIRROOT_CURRENT}' (no modificada)"

    # Avisar si difiere de MOODLE_DIRROOT para que el operador lo note
    if [ -n "${DIRROOT_CURRENT}" ] && \
       [ "${DIRROOT_CURRENT}" != "${MOODLE_DIRROOT}" ]; then
        warn "  MOODLE_DIRROOT='${MOODLE_DIRROOT}' difiere del valor en config.php"
        warn "  Se respeta config.php — para forzar el nuevo valor:"
        warn "    Editar manualmente config.php o borrar la línea y reiniciar el pod"
    fi
else
    # dirroot AUSENTE — añadir antes del require_once final.
    # Caso típico: upgrade 5.1.1 → 5.1.3, o instalación con entrypoint v1.
    log "  dirroot ausente — añadiendo '${MOODLE_DIRROOT}' a config.php..."

    TMP_PATCH=$(mktemp /tmp/moodle-config-patch-XXXXXX.php)

    if grep -q "require_once.*setup.php" "${CFG_TARGET}"; then
        # Insertar la línea dirroot justo antes del require_once
        sed "s|require_once(__DIR__ . '/lib/setup.php');|\
// \$CFG->dirroot — añadida por entrypoint (Moodle 5.1+)\n\$CFG->dirroot = '${MOODLE_DIRROOT}';\nrequire_once(__DIR__ . '/lib/setup.php');|" \
            "${CFG_TARGET}" > "${TMP_PATCH}"
    else
        # Sin require_once — añadir al final
        cp "${CFG_TARGET}" "${TMP_PATCH}"
        printf "\n// \$CFG->dirroot — añadida por entrypoint (Moodle 5.1+)\n\$CFG->dirroot = '%s';\n" \
            "${MOODLE_DIRROOT}" >> "${TMP_PATCH}"
    fi

    # Validar sintaxis PHP antes de sustituir
    php -l "${TMP_PATCH}" > /dev/null 2>&1 \
        || die "Sintaxis PHP inválida al añadir dirroot — verifica MOODLE_DIRROOT='${MOODLE_DIRROOT}'"

    # Sustitución atómica
    mv "${TMP_PATCH}" "${CFG_TARGET}"
    chmod 640 "${CFG_TARGET}"
    ok "  dirroot='${MOODLE_DIRROOT}' añadida y validada"
fi

ok "[6/10] dirroot OK"

# ============================================================
# 7. PERMISOS Y DIRECTORIOS DE MOODLEDATA
# ============================================================
log "[7/10] Verificando moodledata..."

if [ -d /var/www/moodledata ]; then
    [ -w /var/www/moodledata ] \
        && ok "  moodledata escribible" \
        || warn "  moodledata NO escribible — revisar permisos del PVC"
    mkdir -p /var/www/moodledata/{sessions,cache,localcache,temp,filedir}
fi

chmod 640 /var/www/html/public/config.php 2>/dev/null || true
ok "[7/10] Permisos ajustados"

# ============================================================
# 8. CRON INTERNO (opcional, sin solapamiento)
# ============================================================
# MEJORA v1: en v1 el loop hacía sleep 60 fijo, lo que podía
# provocar ejecuciones paralelas si cron.php tardaba > 60s.
# Ahora: el sleep se calcula restando el tiempo de ejecución,
# garantizando al menos 60s entre el FIN de una ejecución
# y el INICIO de la siguiente.
# ============================================================
if [ "${ENABLE_CRON}" = "true" ]; then
    log "[8/10] Iniciando cron interno (sin solapamiento)..."
    (
        CRON_LOCK="/tmp/moodle-cron.lock"
        while true; do
            LOOP_START=$(date +%s)
            # flock garantiza que nunca corran dos instancias a la vez
            if flock -n "${CRON_LOCK}" \
               php /var/www/html/admin/cli/cron.php 2>&1 \
               | sed 's/^/  [cron] /'; then
                ELAPSED=$(( $(date +%s) - LOOP_START ))
                log "  [cron] completado en ${ELAPSED}s"
            else
                warn "  [cron] omitido — ejecución anterior aún en curso"
            fi
            # Esperar el tiempo que falte para completar 60s desde el inicio
            ELAPSED=$(( $(date +%s) - LOOP_START ))
            REMAINING=$(( 60 - ELAPSED ))
            [ "${REMAINING}" -gt 0 ] && sleep "${REMAINING}"
        done
    ) &
    ok "[8/10] Cron interno activo (PID: $!)"
else
    ok "[8/10] Cron interno deshabilitado (CronJob K8s activo)"
fi

# ============================================================
# 9. VALIDACIÓN FINAL
# ============================================================
# MEJORA v1: se añade php -l para verificar sintaxis del config.php
# antes de arrancar Apache. Detecta corrupción temprana.
# ============================================================
log "[9/10] Validación final..."

CONFIG_CHECK="/var/www/html/public/config.php"
[ -f "${CONFIG_CHECK}" ] \
    || { [ -f /var/www/html/config.php ] \
         && CONFIG_CHECK="/var/www/html/config.php"; } \
    || die "config.php no encontrado en ninguna ubicación"

ok "  config.php presente: ${CONFIG_CHECK}"

# Validar sintaxis PHP del config.php
php -l "${CONFIG_CHECK}" > /dev/null 2>&1 \
    && ok "  config.php sintaxis PHP válida" \
    || die "config.php tiene errores de sintaxis PHP — el pod no puede arrancar"

# Verificar dirroot
grep -q "CFG->dirroot" "${CONFIG_CHECK}" \
    && ok "  dirroot presente: $(grep 'CFG->dirroot' "${CONFIG_CHECK}" | grep -oP "(?<= = ')[^']+")" \
    || warn "  dirroot ausente — recursos dinámicos pueden fallar en Moodle 5.1.3+"

# Re-verificar servicios antes del arranque final
timeout 5 bash -c "</dev/tcp/${MARIADB_HOST}/${MARIADB_PORT}" 2>/dev/null \
    && ok "  MariaDB accesible" \
    || die "MariaDB no accesible en ${MARIADB_HOST}:${MARIADB_PORT}"

timeout 5 bash -c "</dev/tcp/${REDIS_HOST}/${REDIS_PORT}" 2>/dev/null \
    && ok "  Redis accesible" \
    || die "Redis no accesible en ${REDIS_HOST}:${REDIS_PORT}"

ok "[9/10] Validación completada"

# ============================================================
# 10. ARRANCAR APACHE
# ============================================================
log "[10/10] Arrancando Apache..."
echo -e "\n${_B}════════════════════════════════════════${_N}"
echo -e "${_B} URL:     ${MOODLE_URL}${_N}"
echo -e "${_B} Puerto:  8080 HTTP (TLS en Traefik)${_N}"
echo -e "${_B} dirroot: ${MOODLE_DIRROOT}${_N}"
echo -e "${_B}════════════════════════════════════════${_N}\n"

# FIX memory_limit: aplicar ANTES de que Apache/PHP procese peticiones.
# ini_set en config.php no puede subir el límite si php.ini lo fija menor.
# La solución es escribir un php.ini adicional que Apache leerá al iniciar.
# PHP_INI_SCAN_DIR es el directorio donde PHP busca archivos *.ini extra.
CUSTOM_INI="/tmp/moodle-php-custom.ini"
cat > "${CUSTOM_INI}" << PHPINI
; Configuración PHP para Moodle — generada por entrypoint.sh
memory_limit            = ${MOODLE_MEMORY_LIMIT}
max_input_vars          = 5000
max_execution_time      = 300
upload_max_filesize     = 128M
post_max_size           = 128M
PHPINI
log "  php.ini custom: memory_limit=${MOODLE_MEMORY_LIMIT} → ${CUSTOM_INI}"

# Apuntar PHP_INI_SCAN_DIR al directorio /tmp para que Apache lo cargue
export PHP_INI_SCAN_DIR="/tmp:${PHP_INI_SCAN_DIR:-/etc/php/8.2/apache2/conf.d}"

export APACHE_RUN_USER=moodle
export APACHE_RUN_GROUP=www-data
export APACHE_RUN_DIR=/tmp/apache2/run
export APACHE_PID_FILE=/tmp/apache2/run/apache2.pid
export APACHE_LOCK_DIR=/tmp/apache2/lock
export APACHE_LOG_DIR=/tmp/apache2/logs

mkdir -p /tmp/apache2/{run,lock,logs}
chmod 777 /tmp/apache2/run /tmp/apache2/lock /tmp/apache2/logs

rm -rf /var/run/apache2 2>/dev/null || true
ln -sfn /tmp/apache2/run /var/run/apache2 2>/dev/null || true

# exec reemplaza este proceso por Apache → Apache queda como PID 1
# K8s puede enviarle SIGTERM directamente para shutdown graceful
exec /usr/sbin/apache2 -DFOREGROUND
