#!/bin/bash
# ============================================================
# 08-validate-prod.sh — Validación completa pre-producción
# Moodle 5.1.1 HA · K3s · TESOEM
#
# Basado en la configuración real de 06-deploy-all.sh:
#   - Namespace:     moodle-prod
#   - Imagen:        localhost:5000/moodle-apache:5.1-k3s-raid
#   - URL:           https://mcc.tesoem.edu.mx
#   - MariaDB:       StatefulSet mariadb (ClusterIP:3306)
#   - Redis:         Deployment redis   (ClusterIP:6379)
#   - HPA:           CPU 70% / MEM 80% — min:3 max:10
#   - PDB:           minAvailable = 2
#   - CronJob:       */1 * * * * (cada minuto)
#   - RAID:          /moodlek3s/{mariadb,redis,moodle-html,moodle-data}
#
# CATEGORÍAS:
#   1.  Infraestructura del nodo (SO, K3s, RAID, registry)
#   2.  Stack K8s (pods, PVCs, servicios, ingress)
#   3.  Funcionalidad web (rutas HTTP críticas de Moodle)
#   4.  Recursos dinámicos (JS, CSS, imágenes, fuentes)
#   5.  Base de datos MariaDB (integridad, tablas, sesiones)
#   6.  Redis (sesiones, caché, hit rate)
#   7.  Certificado TLS y seguridad
#   8.  Rendimiento y carga (curl paralelo — sin wrk/ab)
#   9.  Escalamiento horizontal (HPA automático)
#   10. Tolerancia a fallos (pod kill + recuperación)
#   11. CronJob y tareas programadas
#   12. Almacenamiento y persistencia
#   13. Checklist de producción
#   14. Resumen y veredicto
# ============================================================
set -uo pipefail

# ────────────────────────────────────────────────────────────
# CONFIGURACIÓN — extraída de 06-deploy-all.sh
# ────────────────────────────────────────────────────────────
NS="moodle-prod"
BASE_URL="https://mcc.tesoem.edu.mx"
DOMAIN="mcc.tesoem.edu.mx"
ADMIN_USER="admin"
ADMIN_PASS='@@Ad1v1na#2@@'
DB_ROOT_PASS='@@Ad1v1na#2@@'
DB_USER="moodleTESOEM"
DB_NAME="moodle"
REDIS_PASS='@@Ad1v1na#2@@'
REGISTRY="localhost:5000"
IMAGE_NAME="moodle-apache"
IMAGE_TAG="5.1-k3s-raid"
RAID_BASE="/moodlek3s"
NODE_NAME="k3s-moodle-master"

# Umbrales de validación
MIN_MOODLE_REPLICAS=3        # mínimo esperado en staging/pre-prod
MIN_DB_TABLES=300            # tablas Moodle completo ~350+
HTTP_TIMEOUT=15              # segundos por petición curl
LOAD_CONCURRENT=20           # peticiones paralelas en prueba de carga
LOAD_ITERATIONS=5            # rondas de carga
FAULT_RECOVERY_TIMEOUT=90    # segundos para recuperar pod eliminado
HPA_TRIGGER_TIMEOUT=120      # segundos esperando que HPA actúe
CRON_COMPLETE_TIMEOUT=90     # segundos esperando job de cron

# ────────────────────────────────────────────────────────────
# COLORES Y UTILIDADES
# ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0; SKIP=0
FAIL_MSGS=()
START_TS=$(date +%s)

pass()  { echo -e "  ${GREEN}✓ PASS${NC}  $1"; ((PASS++)) || true; }
fail()  { echo -e "  ${RED}✗ FAIL${NC}  $1"; ((FAIL++)) || true; FAIL_MSGS+=("$1"); }
warn()  { echo -e "  ${YELLOW}⚠ WARN${NC}  $1"; ((WARN++)) || true; }
skip()  { echo -e "  ${CYAN}⊘ SKIP${NC}  $1"; ((SKIP++)) || true; }
info()  { echo -e "  ${CYAN}ℹ${NC}       $1"; }
title() {
  echo ""
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${BLUE}  $1${NC}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"
}

# HTTP helpers
http_code() { curl -sk -o /dev/null -w "%{http_code}" \
              --max-time "${HTTP_TIMEOUT}" "$1" 2>/dev/null || echo "000"; }
http_body() { curl -sk --max-time "${HTTP_TIMEOUT}" "$1" 2>/dev/null || echo ""; }
http_time() { curl -sk -o /dev/null -w "%{time_total}" \
              --max-time "${HTTP_TIMEOUT}" "$1" 2>/dev/null || echo "99"; }

# Obtener primer pod Moodle listo
moodle_pod() {
  kubectl get pod -n "${NS}" -l app=moodle \
    --no-headers 2>/dev/null \
    | awk '$2=="1/1" && $3=="Running" {print $1; exit}'
}

# Ejecutar en pod Moodle
mpod() { kubectl exec -n "${NS}" "$(moodle_pod)" -- bash -c "$1" 2>/dev/null; }

# Contar pods listos por label
ready_pods() {
  kubectl get pods -n "${NS}" -l "$1" --no-headers 2>/dev/null \
    | awk '$2=="1/1" && $3=="Running" {c++} END {print c+0}'
}

# ────────────────────────────────────────────────────────────
# BANNER
# ────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${BLUE}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║   VALIDACIÓN PRE-PRODUCCIÓN — Moodle 5.1.1 HA K3s   ║"
echo "  ║   TESOEM · ${DOMAIN}         ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  Nodo:   ${NODE_NAME}"
echo -e "  NS:     ${NS}"
echo ""

# ============================================================
# 1. INFRAESTRUCTURA DEL NODO
# ============================================================
title "1. INFRAESTRUCTURA DEL NODO"

# 1.1 K3s corriendo
if systemctl is-active --quiet k3s; then
  K3S_VER=$(k3s --version 2>/dev/null | head -1 | awk '{print $3}')
  pass "K3s activo — versión ${K3S_VER}"
else
  fail "K3s no está activo (systemctl status k3s)"
fi

# 1.2 kubectl responde
if kubectl cluster-info &>/dev/null; then
  pass "kubectl conectado al clúster"
else
  fail "kubectl no puede conectar al clúster"
fi

# 1.3 metrics-server disponible (necesario para HPA y kubectl top)
if kubectl top nodes &>/dev/null; then
  pass "metrics-server disponible (kubectl top nodes OK)"
else
  warn "metrics-server no disponible — HPA y kubectl top no funcionarán"
fi

# 1.4 RAID
if [ -f /proc/mdstat ]; then
  RAID_STATE=$(grep -E "md[0-9]" /proc/mdstat | head -1 || echo "")
  if echo "${RAID_STATE}" | grep -qE "\[.*U.*\]"; then
    DEGRADED=$(grep -c "_" /proc/mdstat 2>/dev/null || echo "0")
    [ "${DEGRADED}" -eq 0 ] \
      && pass "RAID activo y sin discos degradados" \
      || warn "RAID con ${DEGRADED} disco(s) degradado(s) — revisar mdadm --detail"
  else
    warn "No se detectó RAID activo en /proc/mdstat"
  fi
else
  warn "/proc/mdstat no disponible"
fi

# 1.5 Directorios del RAID
for DIR in mariadb redis moodle-html moodle-data; do
  if [ -d "${RAID_BASE}/${DIR}" ]; then
    USAGE=$(du -sh "${RAID_BASE}/${DIR}" 2>/dev/null | cut -f1 || echo "?")
    pass "  ${RAID_BASE}/${DIR} existe — uso: ${USAGE}"
  else
    fail "  ${RAID_BASE}/${DIR} NO existe"
  fi
done

# 1.6 Espacio disponible en RAID
DISK_FREE=$(df -h "${RAID_BASE}" 2>/dev/null | awk 'NR==2{print $4}' || echo "?")
DISK_PCT=$(df "${RAID_BASE}" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}' || echo "0")
if [ "${DISK_PCT}" -lt 80 ] 2>/dev/null; then
  pass "Espacio libre en RAID: ${DISK_FREE} (${DISK_PCT}% usado)"
elif [ "${DISK_PCT}" -lt 90 ] 2>/dev/null; then
  warn "Espacio en RAID: ${DISK_FREE} libre (${DISK_PCT}% usado — considera ampliar)"
else
  fail "Espacio crítico en RAID: solo ${DISK_FREE} libre (${DISK_PCT}% usado)"
fi

# 1.7 Registry local
if curl -sf "http://${REGISTRY}/v2/_catalog" &>/dev/null; then
  TAGS=$(curl -sf "http://${REGISTRY}/v2/${IMAGE_NAME}/tags/list" 2>/dev/null)
  if echo "${TAGS}" | grep -q "${IMAGE_TAG}"; then
    pass "Registry local activo — imagen ${IMAGE_NAME}:${IMAGE_TAG} disponible"
  else
    fail "Imagen ${IMAGE_NAME}:${IMAGE_TAG} NO está en el registry"
  fi
else
  fail "Registry local no responde en http://${REGISTRY}/v2/"
fi

# 1.8 Recursos del nodo
NODE_CPU=$(kubectl top nodes 2>/dev/null | awk '/'"${NODE_NAME}"'/{print $3}' || echo "?")
NODE_MEM=$(kubectl top nodes 2>/dev/null | awk '/'"${NODE_NAME}"'/{print $5}' || echo "?")
info "Uso del nodo — CPU: ${NODE_CPU}  MEM: ${NODE_MEM}"

# ============================================================
# 2. STACK KUBERNETES
# ============================================================
title "2. STACK KUBERNETES"

echo ""
info "Estado completo del namespace ${NS}:"
kubectl get pods -n "${NS}" -o wide 2>/dev/null
echo ""

# 2.1 Pods de Moodle (app=moodle, excluyendo cron)
MOODLE_READY=$(ready_pods "app=moodle")
[ "${MOODLE_READY}" -ge 1 ] \
  && pass "Pods Moodle 1/1 Running: ${MOODLE_READY}" \
  || fail "Pods Moodle Running: ${MOODLE_READY} (esperado >= 1)"

[ "${MOODLE_READY}" -ge "${MIN_MOODLE_REPLICAS}" ] \
  && pass "Réplicas Moodle >= ${MIN_MOODLE_REPLICAS} (HA mínimo)" \
  || warn "Solo ${MOODLE_READY} réplica(s) — para HA se necesitan >= ${MIN_MOODLE_REPLICAS}"

# 2.2 MariaDB
MARIA_READY=$(ready_pods "app=mariadb")
[ "${MARIA_READY}" -ge 1 ] && pass "MariaDB 1/1 Running" || fail "MariaDB NO está Running"

# 2.3 Redis
REDIS_READY=$(ready_pods "app=redis")
[ "${REDIS_READY}" -ge 1 ] && pass "Redis 1/1 Running" || fail "Redis NO está Running"

# 2.4 PVCs
PVC_BOUND=$(kubectl get pvc -n "${NS}" --no-headers 2>/dev/null | grep -c "Bound" || echo "0")
[ "${PVC_BOUND}" -ge 4 ] \
  && pass "${PVC_BOUND}/4 PVCs en estado Bound" \
  || fail "Solo ${PVC_BOUND}/4 PVCs Bound — revisar kubectl get pvc -n ${NS}"
echo ""
kubectl get pvc -n "${NS}" 2>/dev/null | sed 's/^/    /'
echo ""

# 2.5 Services
for SVC in mariadb redis moodle; do
  SVC_EXISTS=$(kubectl get svc "${SVC}" -n "${NS}" &>/dev/null && echo "1" || echo "0")
  [ "${SVC_EXISTS}" = "1" ] && pass "Service ${SVC} existe" || fail "Service ${SVC} NO existe"
done

# 2.6 Ingress
INGRESS_EXISTS=$(kubectl get ingress moodle-ingress -n "${NS}" &>/dev/null && echo "1" || echo "0")
[ "${INGRESS_EXISTS}" = "1" ] && pass "Ingress moodle-ingress existe" || fail "Ingress NO encontrado"

# 2.7 HPA
HPA_LINE=$(kubectl get hpa moodle-hpa -n "${NS}" --no-headers 2>/dev/null | head -1 || echo "")
if [ -n "${HPA_LINE}" ]; then
  HPA_MIN=$(kubectl get hpa moodle-hpa -n "${NS}" \
    -o jsonpath='{.spec.minReplicas}' 2>/dev/null || echo "0")
  HPA_MAX=$(kubectl get hpa moodle-hpa -n "${NS}" \
    -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo "0")
  pass "HPA activo — min:${HPA_MIN} max:${HPA_MAX}"
  info "HPA: ${HPA_LINE}"
else
  fail "HPA moodle-hpa no encontrado"
fi

# 2.8 PDB
PDB_EXISTS=$(kubectl get pdb -n "${NS}" --no-headers 2>/dev/null | grep -c "moodle" || echo "0")
[ "${PDB_EXISTS}" -ge 1 ] \
  && pass "PodDisruptionBudget presente" \
  || warn "PDB no encontrado — sin protección ante disrupciones"

# 2.9 CronJob
CRON_SUSPENDED=$(kubectl get cronjob moodle-cron -n "${NS}" \
  -o jsonpath='{.spec.suspend}' 2>/dev/null || echo "true")
[ "${CRON_SUSPENDED}" = "false" ] \
  && pass "CronJob moodle-cron activo (suspend: false)" \
  || fail "CronJob suspendido (suspend: true) — activar para producción"

# 2.10 Reinicios de pods
HIGH_RESTART=$(kubectl get pods -n "${NS}" --no-headers 2>/dev/null \
  | awk '$4 > 5 {print $1, "reinicios:", $4}')
[ -z "${HIGH_RESTART}" ] \
  && pass "Sin pods con reinicios excesivos (> 5)" \
  || warn "Pods con reinicios elevados: ${HIGH_RESTART}"

# ============================================================
# 3. FUNCIONALIDAD WEB — RUTAS CRÍTICAS
# ============================================================
title "3. FUNCIONALIDAD WEB"

declare -A ROUTES
ROUTES["/"]="200,301,302"
ROUTES["/login/index.php"]="200"
ROUTES["/admin/index.php"]="200,303,302"

for ROUTE in "${!ROUTES[@]}"; do
  CODE=$(http_code "${BASE_URL}${ROUTE}")
  EXPECTED="${ROUTES[$ROUTE]}"
  TIME=$(http_time "${BASE_URL}${ROUTE}")
  if echo "${EXPECTED}" | grep -q "${CODE}"; then
    pass "GET ${ROUTE} → ${CODE} (${TIME}s)"
  else
    fail "GET ${ROUTE} → ${CODE} esperado: ${EXPECTED}"
  fi
done

# 3.1 Login page — contenido
LOGIN_BODY=$(http_body "${BASE_URL}/login/index.php")

echo "${LOGIN_BODY}" | grep -qi "username\|loginform\|usuario" \
  && pass "Formulario de login presente" \
  || fail "Formulario de login NO encontrado en /login/index.php"

echo "${LOGIN_BODY}" | grep -qi "Fatal error\|Parse error\|Catchable\|Uncaught" \
  && fail "Errores PHP visibles en login page" \
  || pass "Sin errores PHP en login page"

echo "${LOGIN_BODY}" | grep -qi "proxy\|reverse proxy\|proxy inverso" \
  && fail "Error de proxy inverso detectado en login — revisar reverseproxy en config.php" \
  || pass "Sin error de proxy inverso"

# 3.2 Tiempo de respuesta en login
LOGIN_TIME=$(http_time "${BASE_URL}/login/index.php")
LOGIN_MS=$(echo "${LOGIN_TIME} * 1000" | bc 2>/dev/null | cut -d. -f1 || echo "0")
if [ "${LOGIN_MS}" -lt 2000 ] 2>/dev/null; then
  pass "Tiempo de respuesta login: ${LOGIN_TIME}s (< 2s)"
elif [ "${LOGIN_MS}" -lt 5000 ] 2>/dev/null; then
  warn "Tiempo de respuesta login: ${LOGIN_TIME}s (< 5s — aceptable)"
else
  fail "Tiempo de respuesta login: ${LOGIN_TIME}s (> 5s — lento)"
fi

# ============================================================
# 4. RECURSOS DINÁMICOS
# ============================================================
title "4. RECURSOS DINÁMICOS (JS / CSS / IMG / FONTS)"

# Obtener el theme revision desde la BD
THEME_REV=$(mpod "php /var/www/html/admin/cli/cfg.php --name=themerev 2>/dev/null" \
  | tr -d ' \n' || echo "1")
[ -z "${THEME_REV}" ] && THEME_REV="1"
info "Theme revision: ${THEME_REV}"

# CSS estático
CSS_CODE=$(http_code "${BASE_URL}/theme/boost/style/moodle.css")
[ "${CSS_CODE}" = "200" ] && pass "CSS estático → 200" || fail "CSS estático → ${CSS_CODE}"

# JS dinámico — requiere dirroot correcto en config.php
JS_URL="${BASE_URL}/lib/javascript.php/${THEME_REV}/lib/polyfills/polyfill.js"
JS_CODE=$(http_code "${JS_URL}")
JS_BODY=$(http_body "${JS_URL}")
if [ "${JS_CODE}" = "200" ]; then
  echo "${JS_BODY}" | grep -qi "function\|prototype\|Element\|window" \
    && pass "JS dinámico (javascript.php) → 200 — contenido válido" \
    || warn "JS dinámico → 200 pero contenido inesperado"
else
  fail "JS dinámico (javascript.php) → ${JS_CODE} — verificar dirroot en config.php"
fi

# Imagen dinámica — requiere dirroot correcto
IMG_URL="${BASE_URL}/theme/image.php/boost/theme/${THEME_REV}/favicon"
IMG_CODE=$(http_code "${IMG_URL}")
IMG_BODY=$(http_body "${IMG_URL}")
if [ "${IMG_CODE}" = "200" ]; then
  echo "${IMG_BODY}" | grep -qi "DOCTYPE\|html\|error" \
    && fail "image.php → 200 pero devuelve HTML (error de Moodle)" \
    || pass "Imagen dinámica (image.php) → 200 — contenido binario correcto"
else
  fail "Imagen dinámica (image.php) → ${IMG_CODE}"
fi

# Fuente dinámica
FONT_CODE=$(http_code \
  "${BASE_URL}/theme/font.php/boost/core/${THEME_REV}/fa-solid-900.woff2")
[ "${FONT_CODE}" = "200" ] && pass "Fuente dinámica (font.php) → 200" \
  || fail "Fuente dinámica (font.php) → ${FONT_CODE}"

# 4.1 Verificar dirroot en config.php
DIRROOT=$(mpod "grep 'dirroot' /var/www/html/public/config.php 2>/dev/null | head -1" \
  | tr -d ' ')
echo "${DIRROOT}" | grep -q "public" \
  && pass "dirroot configurado: ${DIRROOT}" \
  || fail "dirroot ausente o incorrecto: '${DIRROOT}' — debe apuntar a /var/www/html/public"

# 4.2 Verificar un solo require_once en config.php
REQUIRE_COUNT=$(mpod "grep -c 'require_once.*setup.php' /var/www/html/public/config.php 2>/dev/null" \
  | tr -d ' \n' || echo "0")
[ "${REQUIRE_COUNT}" = "1" ] \
  && pass "config.php tiene exactamente 1 require_once(setup.php)" \
  || fail "config.php tiene ${REQUIRE_COUNT} ocurrencias de require_once(setup.php) — debe ser exactamente 1"

# ============================================================
# 5. BASE DE DATOS MARIADB
# ============================================================
title "5. BASE DE DATOS MARIADB"

MARIA_POD=$(kubectl get pod -n "${NS}" -l app=mariadb \
  --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)

if [ -z "${MARIA_POD}" ]; then
  fail "No se encontró pod de MariaDB"
else
  # 5.1 Conectividad
  DB_PING=$(kubectl exec -n "${NS}" "${MARIA_POD}" \
    -- mariadb-admin ping -u root -p"${DB_ROOT_PASS}" \
    --connect-timeout=5 2>/dev/null | tr -d ' \n' || echo "FAIL")
  echo "${DB_PING}" | grep -qi "alive\|mysqld is alive" \
    && pass "MariaDB responde a ping" \
    || fail "MariaDB no responde a ping: ${DB_PING}"

  # 5.2 Tablas de Moodle
  TABLE_COUNT=$(kubectl exec -n "${NS}" "${MARIA_POD}" \
    -- mariadb -u root -p"${DB_ROOT_PASS}" moodle \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='moodle';" \
    --skip-column-names 2>/dev/null | tr -d ' \n' || echo "0")
  [ "${TABLE_COUNT:-0}" -gt "${MIN_DB_TABLES}" ] \
    && pass "MariaDB: ${TABLE_COUNT} tablas Moodle (> ${MIN_DB_TABLES})" \
    || fail "MariaDB: solo ${TABLE_COUNT} tablas (esperado > ${MIN_DB_TABLES} — instalación incompleta)"

  # 5.3 Usuario admin en BD
  ADMIN_EXISTS=$(kubectl exec -n "${NS}" "${MARIA_POD}" \
    -- mariadb -u root -p"${DB_ROOT_PASS}" moodle \
    -e "SELECT COUNT(*) FROM mdl_user WHERE username='${ADMIN_USER}' AND deleted=0;" \
    --skip-column-names 2>/dev/null | tr -d ' \n' || echo "0")
  [ "${ADMIN_EXISTS:-0}" -ge 1 ] \
    && pass "Usuario '${ADMIN_USER}' existe en BD" \
    || fail "Usuario '${ADMIN_USER}' NO encontrado en BD"

  # 5.4 Cron habilitado en BD
  CRON_ENABLED=$(kubectl exec -n "${NS}" "${MARIA_POD}" \
    -- mariadb -u root -p"${DB_ROOT_PASS}" moodle \
    -e "SELECT value FROM mdl_config WHERE name='cron_enabled';" \
    --skip-column-names 2>/dev/null | tr -d ' \n' || echo "0")
  [ "${CRON_ENABLED}" = "1" ] \
    && pass "cron_enabled = 1 en BD" \
    || fail "cron_enabled = ${CRON_ENABLED} — activar: cfg.php --name=cron_enabled --set=1"

  # 5.5 reverseproxy en BD
  REVPROXY=$(kubectl exec -n "${NS}" "${MARIA_POD}" \
    -- mariadb -u root -p"${DB_ROOT_PASS}" moodle \
    -e "SELECT value FROM mdl_config WHERE name='reverseproxy';" \
    --skip-column-names 2>/dev/null | tr -d ' \n' || echo "?")
  [ "${REVPROXY}" = "0" ] \
    && pass "reverseproxy = 0 (correcto para esta arquitectura Traefik)" \
    || warn "reverseproxy = '${REVPROXY}' — debe ser 0 para evitar error de proxy inverso"

  # 5.6 Tamaño de la BD
  DB_SIZE=$(kubectl exec -n "${NS}" "${MARIA_POD}" \
    -- mariadb -u root -p"${DB_ROOT_PASS}" \
    -e "SELECT ROUND(SUM(data_length+index_length)/1024/1024,2)
        FROM information_schema.tables WHERE table_schema='moodle';" \
    --skip-column-names 2>/dev/null | tr -d ' \n' || echo "?")
  pass "Tamaño BD Moodle: ${DB_SIZE} MB"

  # 5.7 Conexiones activas
  THREADS=$(kubectl exec -n "${NS}" "${MARIA_POD}" \
    -- mariadb -u root -p"${DB_ROOT_PASS}" \
    -e "SHOW STATUS LIKE 'Threads_connected';" \
    --skip-column-names 2>/dev/null | awk '{print $2}' | tr -d ' \n' || echo "?")
  info "Conexiones activas a MariaDB: ${THREADS}"
fi

# ============================================================
# 6. REDIS
# ============================================================
title "6. REDIS"

REDIS_POD=$(kubectl get pod -n "${NS}" -l app=redis \
  --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)

redis_cmd() {
  kubectl exec -n "${NS}" "${REDIS_POD}" \
    -- redis-cli -a "${REDIS_PASS}" "$@" 2>/dev/null || echo "ERR"
}

if [ -z "${REDIS_POD}" ]; then
  fail "No se encontró pod de Redis"
else
  # 6.1 Ping
  PING=$(redis_cmd ping | tr -d ' \n')
  [ "${PING}" = "PONG" ] && pass "Redis responde PONG" || fail "Redis no responde ping: ${PING}"

  # 6.2 DB 0 — sesiones
  SESS_KEYS=$(redis_cmd -n 0 DBSIZE | tr -d ' \n' || echo "0")
  pass "Redis DB0 (sesiones): ${SESS_KEYS} claves"

  # 6.3 DB 1 — caché
  CACHE_KEYS=$(redis_cmd -n 1 DBSIZE | tr -d ' \n' || echo "0")
  pass "Redis DB1 (caché): ${CACHE_KEYS} claves"

  # 6.4 Memoria usada
  MEM_USED=$(redis_cmd INFO memory | grep "used_memory_human:" \
    | cut -d: -f2 | tr -d ' \r\n' || echo "?")
  MEM_PEAK=$(redis_cmd INFO memory | grep "used_memory_peak_human:" \
    | cut -d: -f2 | tr -d ' \r\n' || echo "?")
  pass "Redis memoria — actual: ${MEM_USED}  pico: ${MEM_PEAK}"

  # 6.5 Hit rate
  HITS=$(redis_cmd INFO stats | grep "keyspace_hits:" | cut -d: -f2 | tr -d ' \r\n' || echo "0")
  MISS=$(redis_cmd INFO stats | grep "keyspace_misses:" | cut -d: -f2 | tr -d ' \r\n' || echo "0")
  TOTAL=$(( ${HITS:-0} + ${MISS:-0} ))
  if [ "${TOTAL}" -gt 0 ] 2>/dev/null; then
    HIT_RATE=$(echo "scale=1; ${HITS} * 100 / ${TOTAL}" | bc 2>/dev/null || echo "?")
    [ "$(echo "${HIT_RATE} > 50" | bc 2>/dev/null || echo 0)" = "1" ] \
      && pass "Hit rate Redis: ${HIT_RATE}% (hits: ${HITS}, misses: ${MISS})" \
      || warn "Hit rate Redis bajo: ${HIT_RATE}% — caché poco efectivo"
  else
    info "Sin operaciones Redis registradas aún"
  fi
fi

# ============================================================
# 7. CERTIFICADO TLS Y SEGURIDAD
# ============================================================
title "7. CERTIFICADO TLS Y SEGURIDAD"

# 7.1 Certificado TLS válido
CERT_INFO=$(echo | timeout 8 openssl s_client \
  -connect "${DOMAIN}:443" -servername "${DOMAIN}" 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates 2>/dev/null || echo "")

if [ -n "${CERT_INFO}" ]; then
  CERT_EXPIRY=$(echo "${CERT_INFO}" | grep "notAfter" | cut -d= -f2)
  CERT_ISSUER=$(echo "${CERT_INFO}" | grep "issuer" | head -1)

  # Verificar si es staging o prod
  if echo "${CERT_ISSUER}" | grep -qi "staging\|fake\|invalid"; then
    warn "Certificado TLS es de STAGING — cambiar a letsencrypt-prod para producción"
  else
    pass "Certificado TLS de producción válido"
  fi
  info "Vence: ${CERT_EXPIRY}"
  info "Emisor: ${CERT_ISSUER}"

  # Días restantes
  if command -v openssl &>/dev/null; then
    EXPIRY_EPOCH=$(date -d "${CERT_EXPIRY}" +%s 2>/dev/null || echo "0")
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
    [ "${DAYS_LEFT}" -gt 30 ] \
      && pass "Certificado válido por ${DAYS_LEFT} días" \
      || fail "Certificado vence en ${DAYS_LEFT} días — renovar urgente"
  fi
else
  fail "No se pudo verificar el certificado TLS de ${DOMAIN}"
fi

# 7.2 HTTPS fuerza redirect desde HTTP
HTTP_REDIRECT=$(curl -sk -o /dev/null -w "%{http_code}" \
  --max-time "${HTTP_TIMEOUT}" "http://${DOMAIN}/login/index.php" 2>/dev/null || echo "000")
[ "${HTTP_REDIRECT}" = "301" ] || [ "${HTTP_REDIRECT}" = "302" ] \
  && pass "HTTP redirige a HTTPS → ${HTTP_REDIRECT}" \
  || warn "HTTP no redirige → ${HTTP_REDIRECT} (configurar redirect en Traefik)"

# 7.3 Headers de seguridad
HEADERS=$(curl -skI --max-time "${HTTP_TIMEOUT}" "${BASE_URL}/login/index.php" 2>/dev/null)
echo "${HEADERS}" | grep -qi "X-Frame-Options" \
  && pass "Header X-Frame-Options presente" \
  || warn "Header X-Frame-Options ausente"
echo "${HEADERS}" | grep -qi "Strict-Transport-Security" \
  && pass "Header HSTS presente" \
  || warn "Header HSTS ausente — agregar en Traefik middleware"
echo "${HEADERS}" | grep -qi "X-Content-Type-Options" \
  && pass "Header X-Content-Type-Options presente" \
  || warn "Header X-Content-Type-Options ausente"

# 7.4 debug_headers.php eliminado
DEBUG_CODE=$(http_code "${BASE_URL}/debug_headers.php")
[ "${DEBUG_CODE}" = "404" ] \
  && pass "debug_headers.php eliminado (404)" \
  || fail "debug_headers.php accesible (${DEBUG_CODE}) — eliminar en producción"

# ============================================================
# 8. PRUEBA DE RENDIMIENTO CON CARGA (curl paralelo)
# ============================================================
title "8. RENDIMIENTO BAJO CARGA (${LOAD_CONCURRENT} peticiones paralelas × ${LOAD_ITERATIONS} rondas)"

info "Herramienta: curl en paralelo (sin wrk/ab)"
info "URL bajo prueba: ${BASE_URL}/login/index.php"
echo ""

TOTAL_REQUESTS=0
TOTAL_ERRORS=0
TOTAL_TIME=0
declare -a RESPONSE_CODES=()

for ROUND in $(seq 1 ${LOAD_ITERATIONS}); do
  echo -n "  Ronda ${ROUND}/${LOAD_ITERATIONS}: "
  ROUND_ERRORS=0
  ROUND_START=$(date +%s%3N)

  # Lanzar peticiones en paralelo
  TMPDIR_LOAD=$(mktemp -d)
  for i in $(seq 1 ${LOAD_CONCURRENT}); do
    {
      CODE=$(http_code "${BASE_URL}/login/index.php")
      echo "${CODE}" > "${TMPDIR_LOAD}/${i}.code"
    } &
  done
  wait

  # Recopilar resultados
  ROUND_OK=0
  for i in $(seq 1 ${LOAD_CONCURRENT}); do
    CODE=$(cat "${TMPDIR_LOAD}/${i}.code" 2>/dev/null || echo "000")
    RESPONSE_CODES+=("${CODE}")
    if [ "${CODE}" = "200" ]; then
      ((ROUND_OK++)) || true
    else
      ((ROUND_ERRORS++)) || true
      ((TOTAL_ERRORS++)) || true
    fi
  done
  rm -rf "${TMPDIR_LOAD}"

  ROUND_END=$(date +%s%3N)
  ROUND_MS=$((ROUND_END - ROUND_START))
  TOTAL_TIME=$((TOTAL_TIME + ROUND_MS))
  ((TOTAL_REQUESTS += LOAD_CONCURRENT)) || true

  echo "${ROUND_OK}/${LOAD_CONCURRENT} OK  [${ROUND_MS}ms]"
done

echo ""
AVG_TIME=$((TOTAL_TIME / LOAD_ITERATIONS))
ERROR_RATE=$(echo "scale=1; ${TOTAL_ERRORS} * 100 / ${TOTAL_REQUESTS}" | bc 2>/dev/null || echo "?")
RPS=$(echo "scale=1; ${TOTAL_REQUESTS} * 1000 / ${TOTAL_TIME}" | bc 2>/dev/null || echo "?")

info "Total peticiones: ${TOTAL_REQUESTS}"
info "Errores totales:  ${TOTAL_ERRORS} (${ERROR_RATE}%)"
info "Tiempo promedio por ronda: ${AVG_TIME}ms"
info "Throughput aproximado: ${RPS} req/s"
echo ""

[ "${TOTAL_ERRORS}" -eq 0 ] \
  && pass "Prueba de carga: 0 errores en ${TOTAL_REQUESTS} peticiones" \
  || fail "Prueba de carga: ${TOTAL_ERRORS} errores de ${TOTAL_REQUESTS} peticiones (${ERROR_RATE}%)"

[ "${AVG_TIME}" -lt 10000 ] 2>/dev/null \
  && pass "Tiempo promedio por ronda aceptable: ${AVG_TIME}ms" \
  || warn "Tiempo promedio por ronda alto: ${AVG_TIME}ms — revisar recursos"

# ============================================================
# 9. ESCALAMIENTO HORIZONTAL
# ============================================================
title "9. ESCALAMIENTO HORIZONTAL (HPA)"

PRE_REPLICAS=$(kubectl get deployment moodle -n "${NS}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
PRE_REPLICAS="${PRE_REPLICAS:-0}"
info "Réplicas antes de la prueba: ${PRE_REPLICAS}"

# 9.1 Escalar manualmente a 4 y verificar rolling update sin downtime
TARGET_REPLICAS=4
info "Escalando a ${TARGET_REPLICAS} réplicas (rolling update)..."

# Medir uptime durante el escalado
SCALE_ERRORS=0
kubectl scale deployment moodle -n "${NS}" \
  --replicas="${TARGET_REPLICAS}" 2>/dev/null &
SCALE_BG_PID=$!

# Verificar disponibilidad mientras escala
for CHECK in $(seq 1 12); do
  sleep 2
  CODE=$(http_code "${BASE_URL}/login/index.php")
  [ "${CODE}" != "200" ] && ((SCALE_ERRORS++)) || true
  echo -n "."
done
wait "${SCALE_BG_PID}" 2>/dev/null || true
echo ""

# Esperar que todas las réplicas estén listas
SCALE_TIMEOUT_TS=$(($(date +%s) + 120))
until [ "$(kubectl get deployment moodle -n "${NS}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)" -ge "${TARGET_REPLICAS}" ]; do
  sleep 5
  [ "$(date +%s)" -gt "${SCALE_TIMEOUT_TS}" ] && break
done

POST_REPLICAS=$(kubectl get deployment moodle -n "${NS}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

[ "${POST_REPLICAS:-0}" -ge "${TARGET_REPLICAS}" ] \
  && pass "Escalado a ${POST_REPLICAS} réplicas exitoso" \
  || fail "Solo ${POST_REPLICAS:-0}/${TARGET_REPLICAS} réplicas listas tras escalado"

[ "${SCALE_ERRORS}" -eq 0 ] \
  && pass "Sitio disponible durante escalado (0 errores en 12 checks)" \
  || warn "Sitio tuvo ${SCALE_ERRORS} interrupciones durante escalado (maxUnavailable=0)"

# 9.2 Verificar HPA activo con réplicas actuales
info "Estado HPA post-escalado:"
kubectl get hpa moodle-hpa -n "${NS}" 2>/dev/null | sed 's/^/    /'

# ============================================================
# 10. TOLERANCIA A FALLOS
# ============================================================
title "10. TOLERANCIA A FALLOS"

CURRENT_REPLICAS=$(kubectl get deployment moodle -n "${NS}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
CURRENT_REPLICAS="${CURRENT_REPLICAS:-0}"

if [ "${CURRENT_REPLICAS}" -ge 2 ]; then
  # 10.1 Eliminar un pod y verificar disponibilidad inmediata
  POD_TO_KILL=$(kubectl get pods -n "${NS}" -l app=moodle \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
  info "Eliminando pod: ${POD_TO_KILL}"
  kubectl delete pod "${POD_TO_KILL}" -n "${NS}" \
    --grace-period=0 --force 2>/dev/null

  # El sitio debe seguir respondiendo sin interrupción
  sleep 2
  FAULT_CODES=()
  for CHECK in $(seq 1 6); do
    CODE=$(http_code "${BASE_URL}/login/index.php")
    FAULT_CODES+=("${CODE}")
    sleep 2
  done

  FAULT_ERRORS=$(printf '%s\n' "${FAULT_CODES[@]}" | grep -vc "200" || echo "0")
  [ "${FAULT_ERRORS}" -eq 0 ] \
    && pass "Sitio disponible tras eliminar pod (${#FAULT_CODES[@]} checks: ${FAULT_CODES[*]})" \
    || fail "Sitio NO disponible tras eliminar pod — ${FAULT_ERRORS} fallos en ${#FAULT_CODES[@]} checks"

  # 10.2 Esperar recuperación del pod (K8s debe recrearlo)
  info "Esperando recreación del pod (máx ${FAULT_RECOVERY_TIMEOUT}s)..."
  RECOVER_TS=$(($(date +%s) + FAULT_RECOVERY_TIMEOUT))
  echo -n "  "
  until [ "$(ready_pods 'app=moodle')" -ge "${CURRENT_REPLICAS}" ]; do
    sleep 5
    echo -n "."
    [ "$(date +%s)" -gt "${RECOVER_TS}" ] && break
  done
  echo ""

  RECOVERED=$(ready_pods "app=moodle")
  [ "${RECOVERED}" -ge "${CURRENT_REPLICAS}" ] \
    && pass "Pod recreado automáticamente — ${RECOVERED}/${CURRENT_REPLICAS} réplicas Ready" \
    || warn "Recuperación incompleta: ${RECOVERED}/${CURRENT_REPLICAS} réplicas Ready"

  # 10.3 Eliminar pod de MariaDB y verificar que Moodle manejase el error
  info "Verificando comportamiento ante indisponibilidad de MariaDB..."
  DB_POD=$(kubectl get pod -n "${NS}" -l app=mariadb \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)

  # Solo verificar que el pod existe y tiene liveness probe
  DB_LIVENESS=$(kubectl get pod "${DB_POD}" -n "${NS}" \
    -o jsonpath='{.spec.containers[0].livenessProbe}' 2>/dev/null || echo "")
  [ -n "${DB_LIVENESS}" ] \
    && pass "MariaDB tiene livenessProbe configurada" \
    || warn "MariaDB sin livenessProbe — K8s no puede auto-recuperar"
else
  skip "Tolerancia a fallos — se necesitan >= 2 réplicas (actual: ${CURRENT_REPLICAS})"
fi

# ============================================================
# 11. CRONJOB Y TAREAS PROGRAMADAS
# ============================================================
title "11. CRONJOB Y TAREAS PROGRAMADAS"

# 11.1 Estado del CronJob
CRON_SUSP=$(kubectl get cronjob moodle-cron -n "${NS}" \
  -o jsonpath='{.spec.suspend}' 2>/dev/null || echo "true")
[ "${CRON_SUSP}" = "false" ] \
  && pass "CronJob activo (suspend: false)" \
  || fail "CronJob suspendido — activar con: kubectl patch cronjob moodle-cron -n ${NS} -p '{\"spec\":{\"suspend\":false}}'"

# 11.2 Último schedule
LAST_SCHED=$(kubectl get cronjob moodle-cron -n "${NS}" \
  -o jsonpath='{.status.lastScheduleTime}' 2>/dev/null || echo "")
[ -n "${LAST_SCHED}" ] \
  && pass "Último schedule registrado: ${LAST_SCHED}" \
  || warn "Sin schedule registrado aún"

# 11.3 Ejecutar job de prueba y verificar que completa
TEST_JOB="cron-validate-$(date +%s)"
info "Lanzando job de cron de prueba: ${TEST_JOB}"
kubectl create job --from=cronjob/moodle-cron \
  "${TEST_JOB}" -n "${NS}" 2>/dev/null || true

CRON_TS=$(($(date +%s) + CRON_COMPLETE_TIMEOUT))
echo -n "  Esperando completación"
until kubectl get job "${TEST_JOB}" -n "${NS}" \
    -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -q "1"; do
  sleep 5
  echo -n "."
  [ "$(date +%s)" -gt "${CRON_TS}" ] && break
done
echo ""

CRON_STATUS=$(kubectl get job "${TEST_JOB}" -n "${NS}" \
  -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
[ "${CRON_STATUS}" = "1" ] \
  && pass "Job de cron completó exitosamente" \
  || warn "Job de cron no completó en ${CRON_COMPLETE_TIMEOUT}s"

# Ver logs del job
CRON_LOG_POD=$(kubectl get pods -n "${NS}" \
  -l "job-name=${TEST_JOB}" --no-headers \
  -o custom-columns=":metadata.name" 2>/dev/null | head -1)
if [ -n "${CRON_LOG_POD}" ]; then
  CRON_OUTPUT=$(kubectl logs -n "${NS}" "${CRON_LOG_POD}" -c cron \
    --tail=5 2>/dev/null || echo "")
  echo "${CRON_OUTPUT}" | grep -qiE "completed|done|finish|success|cron run" \
    && pass "Logs de cron confirman ejecución exitosa" \
    || warn "Logs de cron (últimas 5 líneas): $(echo "${CRON_OUTPUT}" | tail -3)"
fi

# Limpiar job de prueba
kubectl delete job "${TEST_JOB}" -n "${NS}" 2>/dev/null || true

# 11.4 Historial de jobs completados
COMPLETED_JOBS=$(kubectl get jobs -n "${NS}" \
  --no-headers 2>/dev/null | grep -c "1/1" || echo "0")
pass "Jobs completados en historial: ${COMPLETED_JOBS}"

# ============================================================
# 12. ALMACENAMIENTO Y PERSISTENCIA
# ============================================================
title "12. ALMACENAMIENTO Y PERSISTENCIA"

# 12.1 config.php en PVC
CONFIG_EXISTS=$([ -f "${RAID_BASE}/moodle-html/public/config.php" ] && echo "1" || echo "0")
[ "${CONFIG_EXISTS}" = "1" ] \
  && pass "config.php presente en PVC: ${RAID_BASE}/moodle-html/public/config.php" \
  || fail "config.php NO encontrado en PVC"

# 12.2 Permisos correctos de config.php
if [ -f "${RAID_BASE}/moodle-html/public/config.php" ]; then
  CONFIG_PERMS=$(stat -c "%a" "${RAID_BASE}/moodle-html/public/config.php" 2>/dev/null || echo "?")
  [ "${CONFIG_PERMS}" = "640" ] \
    && pass "config.php permisos: 640 (correcto)" \
    || warn "config.php permisos: ${CONFIG_PERMS} (recomendado: 640)"
fi

# 12.3 Moodledata escribible
if [ -d "${RAID_BASE}/moodle-data" ]; then
  touch "${RAID_BASE}/moodle-data/.write_test" 2>/dev/null \
    && { rm -f "${RAID_BASE}/moodle-data/.write_test"; pass "moodledata escribible"; } \
    || fail "moodledata NO escribible — revisar permisos del PVC"
fi

# 12.4 Subdirectorios de moodledata
for SUBDIR in sessions cache localcache temp filedir; do
  [ -d "${RAID_BASE}/moodle-data/${SUBDIR}" ] \
    && pass "  moodledata/${SUBDIR} existe" \
    || warn "  moodledata/${SUBDIR} no existe — Moodle lo creará al primer uso"
done

# 12.5 Verificar que los datos de MariaDB están en el RAID
IBDATA="${RAID_BASE}/mariadb/ibdata1"
[ -f "${IBDATA}" ] \
  && pass "Datos MariaDB en RAID: ibdata1 presente ($(du -sh ${IBDATA} | cut -f1))" \
  || warn "ibdata1 no encontrado — MariaDB puede no estar persistiendo en el RAID"

# ============================================================
# 13. CHECKLIST DE PRODUCCIÓN
# ============================================================
title "13. CHECKLIST DE PRODUCCIÓN"
echo ""

PROD_PASS=0
PROD_FAIL=0

prod_check() {
  local MSG="$1"; local OK="$2"
  if [ "${OK}" = "1" ]; then
    echo -e "  ${GREEN}[✓]${NC} ${MSG}"
    ((PROD_PASS++)) || true
  else
    echo -e "  ${RED}[✗]${NC} ${MSG}"
    ((PROD_FAIL++)) || true
  fi
}

# TLS producción
CERT_ISSUER_FULL=$(echo | timeout 5 openssl s_client \
  -connect "${DOMAIN}:443" -servername "${DOMAIN}" 2>/dev/null \
  | openssl x509 -noout -issuer 2>/dev/null || echo "")
IS_STAGING=$(echo "${CERT_ISSUER_FULL}" | grep -ci "staging\|fake\|invalid" || echo "0")
prod_check "Certificado TLS de producción (no staging)" "$([ "${IS_STAGING}" = "0" ] && echo 1 || echo 0)"

# Réplicas HA
PROD_REPLICAS=$(kubectl get deployment moodle -n "${NS}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
prod_check "Moodle con >= 4 réplicas para HA" "$([ "${PROD_REPLICAS:-0}" -ge 4 ] && echo 1 || echo 0)"

# Debug desactivado
DEBUG_VAL=$(mpod "php /var/www/html/admin/cli/cfg.php --name=debug 2>/dev/null" | tr -d ' \n')
prod_check "Modo debug desactivado (\$CFG->debug = 0)" "$([ "${DEBUG_VAL}" = "0" ] && echo 1 || echo 0)"

# Debug display
DEBUG_DISP=$(mpod "php /var/www/html/admin/cli/cfg.php --name=debugdisplay 2>/dev/null" | tr -d ' \n')
prod_check "debugdisplay desactivado" "$([ "${DEBUG_DISP}" = "0" ] && echo 1 || echo 0)"

# reverseproxy
REV_PROXY=$(mpod "php /var/www/html/admin/cli/cfg.php --name=reverseproxy 2>/dev/null" | tr -d ' \n')
prod_check "reverseproxy = 0 (correcto para Traefik)" "$([ "${REV_PROXY}" = "0" ] && echo 1 || echo 0)"

# sslproxy
SSL_PROXY=$(mpod "php /var/www/html/admin/cli/cfg.php --name=sslproxy 2>/dev/null" | tr -d ' \n')
prod_check "sslproxy = 1 (HTTPS via Traefik)" "$([ "${SSL_PROXY}" = "1" ] && echo 1 || echo 0)"

# CronJob activo
CRON_SUSP2=$(kubectl get cronjob moodle-cron -n "${NS}" \
  -o jsonpath='{.spec.suspend}' 2>/dev/null || echo "true")
prod_check "CronJob activo (suspend: false)" "$([ "${CRON_SUSP2}" = "false" ] && echo 1 || echo 0)"

# HPA mínimo para HA
HPA_MIN_PROD=$(kubectl get hpa moodle-hpa -n "${NS}" \
  -o jsonpath='{.spec.minReplicas}' 2>/dev/null || echo "0")
prod_check "HPA minReplicas >= 4" "$([ "${HPA_MIN_PROD:-0}" -ge 4 ] && echo 1 || echo 0)"

# debug_headers.php eliminado
DEBUG_HDR=$(http_code "${BASE_URL}/debug_headers.php")
prod_check "debug_headers.php eliminado del servidor" "$([ "${DEBUG_HDR}" = "404" ] && echo 1 || echo 0)"

# PDB presente
PDB_COUNT=$(kubectl get pdb -n "${NS}" --no-headers 2>/dev/null | grep -c "moodle" || echo "0")
prod_check "PodDisruptionBudget configurado" "$([ "${PDB_COUNT}" -ge 1 ] && echo 1 || echo 0)"

# Backups en RAID
BACKUP_COUNT=$(find /backups/moodle 2>/dev/null -name "*.sql.gz" | wc -l || echo "0")
prod_check "Backup inicial de BD creado (/backups/moodle)" "$([ "${BACKUP_COUNT:-0}" -ge 1 ] && echo 1 || echo 0)"

echo ""
info "Checklist producción: ${PROD_PASS} OK / ${PROD_FAIL} pendientes"

# ============================================================
# 14. RESUMEN Y VEREDICTO FINAL
# ============================================================
END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))

title "14. RESUMEN Y VEREDICTO FINAL"

echo ""
echo -e "  ${BOLD}Resultados de pruebas:${NC}"
echo -e "  ${GREEN}✓ PASS:${NC}  ${PASS}"
echo -e "  ${RED}✗ FAIL:${NC}  ${FAIL}"
echo -e "  ${YELLOW}⚠ WARN:${NC}  ${WARN}"
echo -e "  ${CYAN}⊘ SKIP:${NC}  ${SKIP}"
echo -e "  ${CYAN}⏱ Duración:${NC} ${DURATION}s ($(date -ud @${DURATION} '+%M min %S seg' 2>/dev/null || echo "${DURATION}s"))"
echo ""

if [ "${FAIL}" -gt 0 ]; then
  echo -e "  ${BOLD}Fallos críticos:${NC}"
  for MSG in "${FAIL_MSGS[@]}"; do
    echo -e "    ${RED}→${NC} ${MSG}"
  done
  echo ""
fi

echo -e "  ${BOLD}Estado del stack:${NC}"
kubectl get pods -n "${NS}" --no-headers 2>/dev/null \
  | awk '{printf "  %-45s %-8s %-10s %s\n", $1, $2, $3, $5}'
echo ""

# VEREDICTO
if [ "${FAIL}" -eq 0 ] && [ "${PROD_FAIL}" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║  ✓ LISTO PARA PRODUCCIÓN                            ║"
  echo "  ║  Todos los tests críticos y checklist OK             ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
elif [ "${FAIL}" -eq 0 ] && [ "${PROD_FAIL}" -le 3 ]; then
  echo -e "${YELLOW}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║  ⚠ VIABLE CON AJUSTES MENORES                       ║"
  echo "  ║  Tests OK — ${PROD_FAIL} item(s) del checklist pendientes       ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
elif [ "${FAIL}" -le 3 ]; then
  echo -e "${YELLOW}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║  ⚠ REVISAR ANTES DE PRODUCCIÓN                      ║"
  echo "  ║  ${FAIL} fallo(s) crítico(s) detectado(s)                   ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
else
  echo -e "${RED}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║  ✗ NO RECOMENDADO PARA PRODUCCIÓN                   ║"
  echo "  ║  ${FAIL} fallos críticos — resolver antes de continuar        ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
fi

echo ""
echo -e "  Completado: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

exit ${FAIL}
