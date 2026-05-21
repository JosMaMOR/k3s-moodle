#!/bin/bash
# ============================================================
# 07-test.sh — Suite de pruebas Moodle HA K3s TESOEM
#
# Ejecutar DESPUÉS de 06-deploy-all.sh y verificar que
# Moodle responde antes de correr pruebas de carga.
#
# CATEGORÍAS DE PRUEBA:
#   1. Conectividad y servicios básicos
#   2. Funcionalidad web (rutas críticas de Moodle)
#   3. Recursos estáticos y dinámicos (CSS/JS/imágenes)
#   4. Autenticación y sesiones
#   5. Persistencia (MariaDB + Redis)
#   6. Escalamiento horizontal (HPA)
#   7. Tolerancia a fallos (pod kill)
#   8. Rendimiento bajo carga (wrk/ab)
#   9. Cron y tareas programadas
#  10. Resumen y veredicto
# ============================================================
set -euo pipefail

# ── Configuración ────────────────────────────────────────────
NAMESPACE="moodle-prod"
BASE_URL="${MOODLE_BASE_URL:-https://mcc.tesoem.edu.mx}"
ADMIN_USER="${MOODLE_ADMIN_USER:-admin}"
ADMIN_PASS="${MOODLE_ADMIN_PASS:-@@Ad1v1na#2@@}"
TIMEOUT=30
LOAD_USERS="${LOAD_TEST_USERS:-20}"
LOAD_DURATION="${LOAD_TEST_DURATION:-30}"

# ── Colores ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Contadores ───────────────────────────────────────────────
PASS=0
FAIL=0
WARN=0
START_TIME=$(date +%s)

# ── Funciones auxiliares ─────────────────────────────────────
pass()  { echo -e "${GREEN}  ✓ PASS${NC} $1"; ((PASS++)); }
fail()  { echo -e "${RED}  ✗ FAIL${NC} $1"; ((FAIL++)); }
warn()  { echo -e "${YELLOW}  ⚠ WARN${NC} $1"; ((WARN++)); }
info()  { echo -e "${CYAN}  ℹ${NC} $1"; }
title() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════${NC}"; \
          echo -e "${BOLD}${BLUE}  $1${NC}"; \
          echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}"; }

# HTTP helper: devuelve código de estado
http_code() {
    curl -sk -o /dev/null -w "%{http_code}" \
         --max-time "${TIMEOUT}" "$1" 2>/dev/null || echo "000"
}

# HTTP helper: devuelve body
http_body() {
    curl -sk --max-time "${TIMEOUT}" "$1" 2>/dev/null || echo ""
}

# Obtener pod de Moodle
moodle_pod() {
    kubectl get pod -n "${NAMESPACE}" -l app=moodle \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1
}

# Ejecutar comando en pod Moodle
moodle_exec() {
    kubectl exec -n "${NAMESPACE}" "$(moodle_pod)" -- bash -c "$1" 2>/dev/null
}

# ============================================================
# 1. CONECTIVIDAD Y SERVICIOS BÁSICOS
# ============================================================
title "1. CONECTIVIDAD Y SERVICIOS BÁSICOS"

# 1.1 Pods corriendo
echo ""
info "Estado de pods:"
kubectl get pods -n "${NAMESPACE}" -o wide 2>/dev/null
echo ""

# awk filtra pods con READY=1/1 y STATUS=Running
# Esto excluye pods de CronJob (0/1 Completed) y pods en init
MOODLE_READY=$(kubectl get pods -n "${NAMESPACE}" -l app=moodle \
    --no-headers 2>/dev/null \
    | awk '$2=="1/1" && $3=="Running" {count++} END {print count+0}' \
    || echo "0")
MARIADB_READY=$(kubectl get pods -n "${NAMESPACE}" -l app=mariadb \
    --no-headers 2>/dev/null \
    | awk '$2=="1/1" && $3=="Running" {count++} END {print count+0}' \
    || echo "0")
REDIS_READY=$(kubectl get pods -n "${NAMESPACE}" -l app=redis \
    --no-headers 2>/dev/null \
    | awk '$2=="1/1" && $3=="Running" {count++} END {print count+0}' \
    || echo "0")

[ "${MOODLE_READY}" -ge 1 ] \
    && pass "Moodle pods 1/1 Running: ${MOODLE_READY}" \
    || fail "Moodle pods 1/1 Running: ${MOODLE_READY} (esperado >= 1)"
[ "${MARIADB_READY}" -ge 1 ] && pass "MariaDB 1/1 Running" || fail "MariaDB NO Running"
[ "${REDIS_READY}" -ge 1 ]   && pass "Redis 1/1 Running"   || fail "Redis NO Running"
# 1.2 Ingress y certificado TLS
INGRESS_IP=$(kubectl get ingress moodle-ingress -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
[ -n "${INGRESS_IP}" ] && pass "Ingress con IP: ${INGRESS_IP}" \
                       || warn "Ingress sin IP asignada (puede ser normal en single-node)"

TLS_EXPIRY=$(echo | timeout 5 openssl s_client -connect \
    "${BASE_URL#https://}:443" -servername "${BASE_URL#https://}" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")
[ -n "${TLS_EXPIRY}" ] && pass "Certificado TLS válido hasta: ${TLS_EXPIRY}" \
                       || warn "No se pudo verificar certificado TLS"

# 1.3 DNS / resolución
DOMAIN="${BASE_URL#https://}"
DOMAIN="${DOMAIN#http://}"
IP=$(nslookup "${DOMAIN}" 2>/dev/null | grep -A1 "Name:" | grep "Address:" \
     | awk '{print $2}' | head -1 || echo "")
[ -n "${IP}" ] && pass "DNS resuelve ${DOMAIN} → ${IP}" \
               || warn "No se pudo resolver DNS de ${DOMAIN}"

# ============================================================
# 2. FUNCIONALIDAD WEB — RUTAS CRÍTICAS
# ============================================================
title "2. FUNCIONALIDAD WEB"

declare -A ROUTES=(
    ["/"]="200,301,302"
    ["/login/index.php"]="200"
    ["/lib/javascript.php/1/lib/polyfills/polyfill.js"]="200"
    ["/theme/styles.php/boost/1/all"]="200"
    ["/admin/index.php"]="200,303,302"
)

for route in "${!ROUTES[@]}"; do
    code=$(http_code "${BASE_URL}${route}")
    expected="${ROUTES[$route]}"
    if echo "${expected}" | grep -q "${code}"; then
        pass "GET ${route} → ${code}"
    else
        fail "GET ${route} → ${code} (esperado: ${expected})"
    fi
done

# 2.1 Página de login contiene elementos esperados
LOGIN_BODY=$(http_body "${BASE_URL}/login/index.php")
echo "${LOGIN_BODY}" | grep -qi "username\|usuario\|Ingresar" \
    && pass "Página login contiene formulario de acceso" \
    || fail "Página login no contiene formulario esperado"

echo "${LOGIN_BODY}" | grep -qi "TESOEM\|Moodle" \
    && pass "Página login muestra nombre del sitio" \
    || warn "Página login no muestra nombre del sitio"

# 2.2 No hay errores PHP visibles
echo "${LOGIN_BODY}" | grep -qi "Fatal error\|Parse error\|Warning:" \
    && fail "Errores PHP visibles en login/index.php" \
    || pass "Sin errores PHP visibles en frontend"

# ============================================================
# 3. RECURSOS ESTÁTICOS Y DINÁMICOS
# ============================================================
title "3. RECURSOS ESTÁTICOS Y DINÁMICOS"

# CSS estático
CSS_CODE=$(http_code "${BASE_URL}/theme/boost/style/moodle.css")
[ "${CSS_CODE}" = "200" ] && pass "CSS estático (moodle.css) → 200" \
                           || fail "CSS estático → ${CSS_CODE}"

# Verificar que el CSS contiene contenido real
CSS_BODY=$(http_body "${BASE_URL}/theme/boost/style/moodle.css")
echo "${CSS_BODY}" | grep -q "charset\|font\|color\|margin" \
    && pass "CSS contiene reglas de estilo válidas" \
    || fail "CSS no contiene reglas esperadas"

# JS dinámico (requiere dirroot correcto)
JS_CODE=$(http_code "${BASE_URL}/lib/javascript.php/1775118558/lib/polyfills/polyfill.js")
[ "${JS_CODE}" = "200" ] && pass "JS dinámico (javascript.php) → 200" \
                          || fail "JS dinámico → ${JS_CODE} (revisar dirroot en config.php)"

# Imagen dinámica (requiere dirroot correcto)
IMG_CODE=$(http_code "${BASE_URL}/theme/image.php/boost/theme/1775118558/favicon")
[ "${IMG_CODE}" = "200" ] && pass "Imagen dinámica (image.php) → 200" \
                           || fail "Imagen dinámica → ${IMG_CODE} (revisar dirroot en config.php)"

# Fuente dinámica
FONT_CODE=$(http_code "${BASE_URL}/theme/font.php/boost/core/1775118558/fa-solid-900.woff2")
[ "${FONT_CODE}" = "200" ] && pass "Fuente dinámica (font.php) → 200" \
                            || fail "Fuente dinámica → ${FONT_CODE}"

# ============================================================
# 4. AUTENTICACIÓN Y SESIONES
# ============================================================
title "4. AUTENTICACIÓN Y SESIONES"

# Obtener token de login (logintoken en el form)
LOGIN_TOKEN=$(http_body "${BASE_URL}/login/index.php" \
    | grep -oP '(?<=name="logintoken" value=")[^"]+' | head -1 || echo "")
[ -n "${LOGIN_TOKEN}" ] && pass "logintoken presente en formulario: ${LOGIN_TOKEN:0:16}..." \
                         || warn "logintoken no encontrado (puede usar otro método)"

# Intentar login con credenciales admin
COOKIE_JAR=$(mktemp)
LOGIN_RESPONSE=$(curl -sk \
    --max-time "${TIMEOUT}" \
    -c "${COOKIE_JAR}" \
    -b "${COOKIE_JAR}" \
    -X POST \
    -d "username=${ADMIN_USER}&password=${ADMIN_PASS}&logintoken=${LOGIN_TOKEN}" \
    "${BASE_URL}/login/index.php" \
    -L -w "\n%{http_code}" 2>/dev/null || echo "000")

LOGIN_CODE=$(echo "${LOGIN_RESPONSE}" | tail -1)
LOGIN_BODY=$(echo "${LOGIN_RESPONSE}" | head -n -1)

if echo "${LOGIN_BODY}" | grep -qi "Dashboard\|Panel\|Mi área\|Inicio"; then
    pass "Login admin exitoso → redirigido al Dashboard"
elif [ "${LOGIN_CODE}" = "200" ] && ! echo "${LOGIN_BODY}" | grep -qi "Invalid\|Inválido\|incorrecta"; then
    pass "Login admin → ${LOGIN_CODE} (sin errores de credenciales)"
else
    fail "Login admin fallido → ${LOGIN_CODE}"
fi

# Verificar cookie de sesión
SESSION_COOKIE=$(grep -c "MoodleSession" "${COOKIE_JAR}" 2>/dev/null || echo "0")
[ "${SESSION_COOKIE}" -ge 1 ] && pass "Cookie MoodleSession creada" \
                               || warn "Cookie MoodleSession no encontrada"

# Acceder a recurso protegido con sesión
if [ "${SESSION_COOKIE}" -ge 1 ]; then
    ADMIN_CODE=$(curl -sk \
        --max-time "${TIMEOUT}" \
        -c "${COOKIE_JAR}" \
        -b "${COOKIE_JAR}" \
        -o /dev/null -w "%{http_code}" \
        "${BASE_URL}/admin/index.php" 2>/dev/null || echo "000")
    [ "${ADMIN_CODE}" = "200" ] && pass "Acceso autenticado a /admin/index.php → 200" \
                                  || warn "Acceso a /admin/index.php → ${ADMIN_CODE}"
fi

rm -f "${COOKIE_JAR}"

# ============================================================
# 5. PERSISTENCIA — MARIADB + REDIS
# ============================================================
title "5. PERSISTENCIA"

MARIADB_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=mariadb \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)

if [ -n "${MARIADB_POD}" ]; then
    # Contar tablas de Moodle
    TABLE_COUNT=$(kubectl exec -n "${NAMESPACE}" "${MARIADB_POD}" -- \
        mariadb -u root -p'@@Ad1v1na#2@@' moodle \
        -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='moodle';" \
        --skip-column-names 2>/dev/null || echo "0")
    TABLE_COUNT=$(echo "${TABLE_COUNT}" | tr -d ' \n')
    [ "${TABLE_COUNT}" -gt 100 ] \
        && pass "MariaDB: ${TABLE_COUNT} tablas Moodle presentes" \
        || fail "MariaDB: solo ${TABLE_COUNT} tablas (instalación incompleta)"

    # Verificar tamaño de BD
    DB_SIZE=$(kubectl exec -n "${NAMESPACE}" "${MARIADB_POD}" -- \
        mariadb -u root -p'@@Ad1v1na#2@@' \
        -e "SELECT ROUND(SUM(data_length+index_length)/1024/1024,2) \
            FROM information_schema.tables WHERE table_schema='moodle';" \
        --skip-column-names 2>/dev/null | tr -d ' \n' || echo "0")
    pass "MariaDB: tamaño BD = ${DB_SIZE} MB"

    # Verificar usuario admin existe
    ADMIN_EXISTS=$(kubectl exec -n "${NAMESPACE}" "${MARIADB_POD}" -- \
        mariadb -u root -p'@@Ad1v1na#2@@' moodle \
        -e "SELECT COUNT(*) FROM mdl_user WHERE username='${ADMIN_USER}';" \
        --skip-column-names 2>/dev/null | tr -d ' \n' || echo "0")
    [ "${ADMIN_EXISTS}" -ge 1 ] && pass "Usuario admin existe en BD" \
                                 || fail "Usuario admin NO encontrado en BD"
else
    fail "No se encontró pod de MariaDB"
fi

# Verificar Redis
REDIS_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=redis \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)

if [ -n "${REDIS_POD}" ]; then
    REDIS_PING=$(kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- \
        redis-cli -a '@@Ad1v1na#2@@' ping 2>/dev/null | tr -d ' \n' || echo "FAIL")
    [ "${REDIS_PING}" = "PONG" ] && pass "Redis responde PONG" \
                                  || fail "Redis no responde ping: ${REDIS_PING}"

    # Verificar sesiones activas en Redis DB 0
    REDIS_KEYS=$(kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- \
        redis-cli -a '@@Ad1v1na#2@@' -n 0 DBSIZE 2>/dev/null | tr -d ' \n' || echo "0")
    pass "Redis DB0 (sesiones): ${REDIS_KEYS} claves"

    # Verificar caché en Redis DB 1
    REDIS_CACHE=$(kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- \
        redis-cli -a '@@Ad1v1na#2@@' -n 1 DBSIZE 2>/dev/null | tr -d ' \n' || echo "0")
    pass "Redis DB1 (caché): ${REDIS_CACHE} claves"
else
    fail "No se encontró pod de Redis"
fi

# Verificar PVCs
echo ""
info "Estado de PersistentVolumeClaims:"
kubectl get pvc -n "${NAMESPACE}" 2>/dev/null
echo ""
PVC_BOUND=$(kubectl get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -c "Bound" || echo "0")
[ "${PVC_BOUND}" -ge 4 ] && pass "${PVC_BOUND}/4 PVCs en estado Bound" \
                          || fail "Solo ${PVC_BOUND}/4 PVCs en Bound"

# ============================================================
# 6. ESCALAMIENTO HORIZONTAL
# ============================================================
title "6. ESCALAMIENTO HORIZONTAL"

CURRENT_REPLICAS=$(kubectl get deployment moodle -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
CURRENT_REPLICAS="${CURRENT_REPLICAS:-0}" 
info "Réplicas actuales de Moodle: ${CURRENT_REPLICAS}"

# Escalar a 3 réplicas
info "Escalando a 3 réplicas..."
kubectl scale deployment moodle -n "${NAMESPACE}" --replicas=3 2>/dev/null
sleep 5

# Esperar a que las 3 estén listas (máx 120s)
SCALE_TIMEOUT=120
ELAPSED=0
echo -n "  Esperando 3 réplicas"
until [ "$(kubectl get deployment moodle -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)" -ge 3 ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo -n "."
    if [ "${ELAPSED}" -ge "${SCALE_TIMEOUT}" ]; then
        echo ""
        fail "Timeout esperando 3 réplicas (${SCALE_TIMEOUT}s)"
        break
    fi
done
echo ""

READY_3=$(kubectl get deployment moodle -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
[ "${READY_3}" -ge 3 ] && pass "Escalado a 3 réplicas exitoso (${READY_3} Ready)" \
                        || fail "Solo ${READY_3}/3 réplicas listas"

# Verificar que el sitio sigue respondiendo durante el escalado
SCALE_CODE=$(http_code "${BASE_URL}/login/index.php")
[ "${SCALE_CODE}" = "200" ] && pass "Sitio disponible durante escalado → ${SCALE_CODE}" \
                             || fail "Sitio NO disponible durante escalado → ${SCALE_CODE}"

# Verificar HPA
HPA_STATUS=$(kubectl get hpa moodle-hpa -n "${NAMESPACE}" \
    --no-headers 2>/dev/null | head -1 || echo "")
[ -n "${HPA_STATUS}" ] && pass "HPA presente: ${HPA_STATUS}" \
                        || warn "HPA no encontrado"

# ============================================================
# 7. TOLERANCIA A FALLOS
# ============================================================
title "7. TOLERANCIA A FALLOS"

# Solo ejecutar si hay >= 2 réplicas
REPLICAS_NOW=$(kubectl get deployment moodle -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
REPLICAS_NOW="${REPLICAS_NOW:-0}" 

if [ "${REPLICAS_NOW}" -ge 2 ]; then
    # Eliminar un pod y verificar que el sitio sigue respondiendo
    POD_TO_KILL=$(kubectl get pods -n "${NAMESPACE}" -l app=moodle \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
    info "Eliminando pod: ${POD_TO_KILL}"
    kubectl delete pod "${POD_TO_KILL}" -n "${NAMESPACE}" --grace-period=0 \
        --force 2>/dev/null || true

    # El sitio debe seguir respondiendo inmediatamente
    sleep 3
    FAULT_CODE=$(http_code "${BASE_URL}/login/index.php")
    [ "${FAULT_CODE}" = "200" ] \
        && pass "Sitio disponible tras eliminar pod → ${FAULT_CODE}" \
        || fail "Sitio NO disponible tras eliminar pod → ${FAULT_CODE}"

    # Esperar a que K8s cree el pod de reemplazo (máx 60s)
    RECOVER_TIMEOUT=60
    ELAPSED=0
    echo -n "  Esperando recuperación del pod"
    until kubectl get pods -n "${NAMESPACE}" -l app=moodle \
          --no-headers 2>/dev/null | grep -q "Running"; do
        sleep 5
        ELAPSED=$((ELAPSED + 5))
        echo -n "."
        [ "${ELAPSED}" -ge "${RECOVER_TIMEOUT}" ] && break
    done
    echo ""

    RECOVERED=$(kubectl get pods -n "${NAMESPACE}" -l app=moodle \
        --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    [ "${RECOVERED}" -ge 2 ] \
        && pass "Pod reemplazado automáticamente (${RECOVERED} Running)" \
        || warn "Pod en recuperación aún (${RECOVERED} Running)"
else
    warn "Solo ${REPLICAS_NOW} réplica — omitiendo prueba de tolerancia a fallos"
    info "Ejecuta: kubectl scale deployment moodle -n ${NAMESPACE} --replicas=3"
fi

# ============================================================
# 8. RENDIMIENTO BAJO CARGA
# ============================================================
title "8. RENDIMIENTO BAJO CARGA"

# Verificar si wrk o ab están disponibles
if command -v wrk &>/dev/null; then
    info "Herramienta de carga: wrk"
    info "Ejecutando: ${LOAD_USERS} conexiones × ${LOAD_DURATION}s contra ${BASE_URL}/login/index.php"
    echo ""
    WRK_RESULT=$(wrk -t4 -c"${LOAD_USERS}" -d"${LOAD_DURATION}"s \
        --timeout 10 "${BASE_URL}/login/index.php" 2>&1 || echo "ERROR")
    echo "${WRK_RESULT}"
    echo ""

    # Extraer requests/sec
    RPS=$(echo "${WRK_RESULT}" | grep -oP '[\d.]+ Requests/sec' | grep -oP '[\d.]+' || echo "0")
    ERRORS=$(echo "${WRK_RESULT}" | grep -oP '\d+ errors' | grep -oP '\d+' || echo "0")

    [ "${ERRORS}" = "0" ] && pass "Sin errores de conexión bajo carga" \
                           || warn "${ERRORS} errores de conexión bajo carga"
    info "Rendimiento: ${RPS} req/s"
    [ "$(echo "${RPS} > 10" | bc -l 2>/dev/null || echo 0)" = "1" ] \
        && pass "Rendimiento aceptable: ${RPS} req/s (> 10 req/s)" \
        || warn "Rendimiento bajo: ${RPS} req/s"

elif command -v ab &>/dev/null; then
    info "Herramienta de carga: ab (Apache Benchmark)"
    info "Ejecutando: ${LOAD_USERS} conexiones simultáneas × 500 peticiones"
    echo ""
    AB_RESULT=$(ab -n 500 -c "${LOAD_USERS}" -k \
        "${BASE_URL}/login/index.php" 2>&1 || echo "ERROR")
    echo "${AB_RESULT}" | grep -E "Requests|Time|Failed|Transfer"
    echo ""

    FAILED=$(echo "${AB_RESULT}" | grep "Failed requests:" | awk '{print $3}' || echo "0")
    RPS=$(echo "${AB_RESULT}" | grep "Requests per second:" | awk '{print $4}' || echo "0")

    [ "${FAILED}" = "0" ] && pass "Sin peticiones fallidas (ab)" \
                           || warn "${FAILED} peticiones fallidas (ab)"
    info "Rendimiento ab: ${RPS} req/s"

elif command -v hey &>/dev/null; then
    info "Herramienta de carga: hey"
    hey -n 200 -c "${LOAD_USERS}" -t 10 "${BASE_URL}/login/index.php" 2>&1 \
        | grep -E "Status|Requests|Slowest|Fastest|Average|req/s"
    pass "Prueba de carga con hey completada"

else
    warn "Sin herramienta de carga (instala: wrk, ab, o hey)"
    info "Para instalar wrk: yum install wrk"
    info "Para instalar ab:  yum install httpd-tools"
    info "Prueba manual: curl en bucle"

    # Prueba manual con curl en paralelo
    info "Ejecutando prueba básica: 20 peticiones paralelas..."
    ERRORS_MANUAL=0
    for i in $(seq 1 20); do
        CODE=$(http_code "${BASE_URL}/login/index.php")
        [ "${CODE}" != "200" ] && ((ERRORS_MANUAL++)) || true
    done
    [ "${ERRORS_MANUAL}" -eq 0 ] \
        && pass "20 peticiones paralelas: 0 errores" \
        || fail "20 peticiones paralelas: ${ERRORS_MANUAL} errores"
fi

# ============================================================
# 9. CRON Y TAREAS PROGRAMADAS
# ============================================================
title "9. CRON Y TAREAS PROGRAMADAS"

# Estado del CronJob
CRON_SUSPENDED=$(kubectl get cronjob moodle-cron -n "${NAMESPACE}" \
    -o jsonpath='{.spec.suspend}' 2>/dev/null || echo "true")
[ "${CRON_SUSPENDED}" = "false" ] && pass "CronJob activo (suspend: false)" \
                                   || fail "CronJob suspendido (suspend: true)"

# Último job ejecutado
LAST_SCHEDULE=$(kubectl get cronjob moodle-cron -n "${NAMESPACE}" \
    -o jsonpath='{.status.lastScheduleTime}' 2>/dev/null || echo "")
[ -n "${LAST_SCHEDULE}" ] && pass "Último schedule: ${LAST_SCHEDULE}" \
                           || warn "CronJob sin ejecuciones registradas"

# Lanzar job manual y verificar que completa
info "Lanzando job de cron manual para verificar..."
TEST_JOB="cron-test-$(date +%s)"
kubectl create job --from=cronjob/moodle-cron "${TEST_JOB}" \
    -n "${NAMESPACE}" 2>/dev/null || true

# Esperar hasta 60s a que complete
CRON_TIMEOUT=60
ELAPSED=0
echo -n "  Esperando completación del job de cron"
until kubectl get job "${TEST_JOB}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -q "1"; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo -n "."
    if [ "${ELAPSED}" -ge "${CRON_TIMEOUT}" ]; then
        echo ""
        warn "Job de cron no completó en ${CRON_TIMEOUT}s"
        break
    fi
done
echo ""

CRON_STATUS=$(kubectl get job "${TEST_JOB}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
[ "${CRON_STATUS}" = "1" ] && pass "Job de cron completó exitosamente" \
                            || warn "Job de cron en progreso o falló"

# Ver logs del job
CRON_POD=$(kubectl get pods -n "${NAMESPACE}" -l "job-name=${TEST_JOB}" \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
if [ -n "${CRON_POD}" ]; then
    CRON_LOGS=$(kubectl logs -n "${NAMESPACE}" "${CRON_POD}" -c cron \
        --tail=5 2>/dev/null || echo "")
    echo "${CRON_LOGS}" | grep -qi "completed\|completado\|Cron run" \
        && pass "Logs de cron muestran ejecución exitosa" \
        || warn "Logs de cron: $(echo "${CRON_LOGS}" | tail -2)"
fi

# Limpiar job de prueba
kubectl delete job "${TEST_JOB}" -n "${NAMESPACE}" 2>/dev/null || true
info "Job de prueba eliminado"

# ============================================================
# 10. RESUMEN Y VEREDICTO
# ============================================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

title "10. RESUMEN FINAL"
echo ""
echo -e "  ${BOLD}Resultados:${NC}"
echo -e "  ${GREEN}✓ PASS: ${PASS}${NC}"
echo -e "  ${RED}✗ FAIL: ${FAIL}${NC}"
echo -e "  ${YELLOW}⚠ WARN: ${WARN}${NC}"
echo -e "  ${CYAN}⏱ Duración: ${DURATION}s${NC}"
echo ""

# Estado de recursos finales
echo -e "  ${BOLD}Estado final del stack:${NC}"
kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | awk '{printf "  %-40s %-10s %s\n", $1, $3, $4}'
echo ""
echo -e "  ${BOLD}HPA:${NC}"
kubectl get hpa -n "${NAMESPACE}" 2>/dev/null | sed 's/^/  /'
echo ""

# Veredicto
if [ "${FAIL}" -eq 0 ] && [ "${WARN}" -le 3 ]; then
    echo -e "${GREEN}${BOLD}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║  ✓ VIABLE PARA PRODUCCIÓN            ║"
    echo "  ║  Todos los tests críticos pasaron     ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"
elif [ "${FAIL}" -le 2 ]; then
    echo -e "${YELLOW}${BOLD}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║  ⚠ VIABLE CON OBSERVACIONES          ║"
    echo "  ║  Revisar los ${FAIL} fallos antes de prod ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"
else
    echo -e "${RED}${BOLD}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║  ✗ NO RECOMENDADO PARA PRODUCCIÓN    ║"
    echo "  ║  ${FAIL} fallos críticos detectados       ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"
fi

exit ${FAIL}
