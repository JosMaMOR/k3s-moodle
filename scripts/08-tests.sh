#!/bin/bash
# ============================================================
# tests-07.sh — Suite de pruebas Moodle HA K3s TESOEM
#              (unificada: incluye las fases de test-longhorn.sh)
#
# Ejecutar DESPUÉS de 07-galera-maxscale.sh, con el clúster
# completo: A + B + Pi, kube-vip, Longhorn HA, Galera 2+garbd
# y MaxScale x2.
#
# USO:
#   sudo ./tests-07.sh                  # suite completa
#   sudo ./tests-07.sh --skip-prereqs   # omite prerrequisitos locales (7.0)
#   sudo ./tests-07.sh --no-e2e         # omite prueba E2E de Longhorn (7.5)
#
# CATEGORÍAS DE PRUEBA:
#   1. Topología del clúster (nodos, etcd, kube-vip)
#   2. Conectividad y servicios básicos
#   3. Funcionalidad web (rutas críticas de Moodle)
#   4. Recursos estáticos y dinámicos (CSS/JS/imágenes)
#   5. Autenticación y sesiones
#   6. Persistencia (Galera + Redis + PVCs)
#   7. Almacenamiento HA (Longhorn: prereqs, topología,
#      réplicas en A y B, y prueba E2E de aprovisionamiento)
#   8. Capa de acceso a datos (MaxScale + galeramon)
#   9. Escalamiento horizontal (HPA)
#  10. Tolerancia a fallos (pod kill)
#  11. Rendimiento bajo carga (wrk/ab)
#  12. Cron y tareas programadas
#  13. Resumen y veredicto
# ============================================================
set -euo pipefail

# ── Configuración ────────────────────────────────────────────
NAMESPACE="moodle-prod"
LONGHORN_NS="longhorn-system"
BASE_URL="${MOODLE_BASE_URL:-https://mcc.tesoem.edu.mx}"
ADMIN_USER="${MOODLE_ADMIN_USER:-admin}"
ADMIN_PASS="${MOODLE_ADMIN_PASS:-@@Ad1v1na#2@@}"
TIMEOUT=30
LOAD_USERS="${LOAD_TEST_USERS:-20}"
LOAD_DURATION="${LOAD_TEST_DURATION:-30}"

# ── Topología esperada (sobreescribible por cluster.env) ─────
# Si cluster.env está junto al script, se toma como fuente de verdad.
CLUSTER_ENV="./cluster.env"
[ -f "${CLUSTER_ENV}" ] && source "${CLUSTER_ENV}"

NODE_A="${NODE_A_NAME:-k3s-moodle-master}"
NODE_B="${NODE_B_NAME:-node-b-k3s-moodle}"
NODE_PI="${NODE_PI_NAME:-raspberry-k3s-moodle}"
CLUSTER_VIP="${CLUSTER_VIP:-192.168.10.200}"
EXPECTED_NODES=3
EXPECTED_ETCD=3
GALERA_EXPECTED_SIZE=3          # 2 nodos de datos + garbd (árbitro)
MAXSCALE_EXPECTED_REPLICAS=2
MOODLE_MIN_REPLICAS=2           # tras el 06 el HPA sostiene el piso
MOODLE_PVCS="moodle-html-pvc moodle-data-pvc"
EXPECTED_PVC_BOUND=5            # redis, html, data, data-mariadb-0, data-mariadb-1
EXPECTED_LH_NODES=2             # solo A y B guardan datos; la Pi queda fuera
STORAGE_CLASS="${STORAGE_CLASS:-longhorn-moodle}"
TEST_PVC_SIZE="${TEST_PVC_SIZE:-1Gi}"
TEST_PVC_TIMEOUT="${TEST_PVC_TIMEOUT:-60}"

# ── Flags (heredados de test-longhorn.sh al unificar) ────────
#   --skip-prereqs → omite la verificación local del nodo (7.0)
#   --no-e2e       → omite la prueba E2E de aprovisionamiento (7.5)
SKIP_PREREQS=false
RUN_E2E=true
for arg in "$@"; do
  case "$arg" in
    --skip-prereqs) SKIP_PREREQS=true ;;
    --no-e2e)       RUN_E2E=false ;;
    -h|--help)
      echo "Uso: $0 [--skip-prereqs] [--no-e2e]"
      echo "  --skip-prereqs  omite prerrequisitos locales de Longhorn (paquetes, módulos, iscsid)"
      echo "  --no-e2e        omite la prueba E2E de aprovisionamiento (no crea PVC de prueba)"
      exit 0
      ;;
    *) echo "Argumento desconocido: $arg (usa --help)"; exit 1 ;;
  esac
done

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
# NOTA: se usa VAR=$((VAR+1)) y no ((VAR++)) a propósito:
# con 'set -e', ((VAR++)) retorna estado 1 cuando VAR vale 0
# y abortaría el script en la primera invocación standalone.
pass()  { echo -e "${GREEN}  ✓ PASS${NC} $1"; PASS=$((PASS+1)); }
fail()  { echo -e "${RED}  ✗ FAIL${NC} $1"; FAIL=$((FAIL+1)); }
warn()  { echo -e "${YELLOW}  ⚠ WARN${NC} $1"; WARN=$((WARN+1)); }
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

# Password root de MariaDB desde el Secret (fuente de verdad, no hardcode)
mariadb_root_pw() {
    kubectl get secret mariadb-secrets -n "${NAMESPACE}" \
        -o jsonpath='{.data.mariadb-root-password}' 2>/dev/null | base64 -d
}

# SQL contra mariadb-0 (contenedor del chart Galera: mariadb-galera)
galera_sql() {
    kubectl exec -n "${NAMESPACE}" mariadb-0 -c mariadb-galera -- \
        mariadb -u root -p"$(mariadb_root_pw)" -N -e "$1" 2>/dev/null
}

# Nodo donde corre un pod
pod_node() {
    kubectl get pod "$1" -n "$2" -o jsonpath='{.spec.nodeName}' 2>/dev/null
}

# ============================================================
# 1. TOPOLOGÍA DEL CLÚSTER — NODOS, ETCD, KUBE-VIP
# ============================================================
# Verifica las adiciones del 05/06: B y la Pi unidos como
# control-planes (miembros de etcd) y la VIP flotante operativa.
title "1. TOPOLOGÍA DEL CLÚSTER"

echo ""
info "Nodos del clúster:"
kubectl get nodes -o wide 2>/dev/null
echo ""

# 1.1 Los tres nodos existen y están Ready
READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null \
    | awk '$2=="Ready"{c++} END{print c+0}')
[ "${READY_NODES}" -eq "${EXPECTED_NODES}" ] \
    && pass "${READY_NODES}/${EXPECTED_NODES} nodos en estado Ready" \
    || fail "${READY_NODES}/${EXPECTED_NODES} nodos Ready (esperados: A, B y Pi)"

for NODE in "${NODE_A}" "${NODE_B}" "${NODE_PI}"; do
    STATUS=$(kubectl get node "${NODE}" --no-headers 2>/dev/null \
        | awk '{print $2}' || echo "AUSENTE")
    [ "${STATUS}" = "Ready" ] \
        && pass "Nodo ${NODE}: Ready" \
        || fail "Nodo ${NODE}: ${STATUS}"
done

# 1.2 Membresía etcd — estar Ready NO implica ser votante de etcd.
# Los tres deben tener el rol; si alguno se unió como agent, el
# quórum queda cojo y la HA del control plane es ficticia.
ETCD_MEMBERS=$(kubectl get nodes -l node-role.kubernetes.io/etcd=true \
    --no-headers 2>/dev/null | wc -l)
[ "${ETCD_MEMBERS}" -eq "${EXPECTED_ETCD}" ] \
    && pass "${ETCD_MEMBERS}/${EXPECTED_ETCD} nodos son miembros del quórum etcd" \
    || fail "${ETCD_MEMBERS}/${EXPECTED_ETCD} miembros etcd — algún nodo se unió como worker"

for NODE in "${NODE_A}" "${NODE_B}" "${NODE_PI}"; do
    HAS_ETCD=$(kubectl get node "${NODE}" \
        -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/etcd}' 2>/dev/null || echo "")
    [ "${HAS_ETCD}" = "true" ] \
        && pass "  ${NODE} → miembro de etcd" \
        || fail "  ${NODE} → SIN rol etcd"
done

# 1.3 La Pi es el árbitro arm64 esperado
PI_ARCH=$(kubectl get node "${NODE_PI}" \
    -o jsonpath='{.status.nodeInfo.architecture}' 2>/dev/null || echo "")
[ "${PI_ARCH}" = "arm64" ] \
    && pass "Pi con arquitectura arm64 (árbitro)" \
    || warn "Arquitectura de la Pi: '${PI_ARCH}' (esperado arm64)"

# 1.4 kube-vip: DaemonSet en los 3 control-planes + líder + VIP viva
KV_READY=$(kubectl -n kube-system get pods \
    -l app.kubernetes.io/name=kube-vip-ds --no-headers 2>/dev/null \
    | awk '$2=="1/1" && $3=="Running"{c++} END{print c+0}')
[ "${KV_READY}" -eq "${EXPECTED_NODES}" ] \
    && pass "kube-vip: ${KV_READY}/${EXPECTED_NODES} pods Running" \
    || fail "kube-vip: ${KV_READY}/${EXPECTED_NODES} pods Running"

KV_LEADER=$(kubectl -n kube-system get lease plndr-cp-lock \
    -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || echo "")
[ -n "${KV_LEADER}" ] \
    && pass "kube-vip: líder electo → ${KV_LEADER}" \
    || fail "kube-vip: sin líder en el lease plndr-cp-lock"

VIP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    --max-time 5 "https://${CLUSTER_VIP}:6443/livez" 2>/dev/null || echo "000")
# 401 = API viva pidiendo auth (sano); 200 = livez abierto
if [ "${VIP_CODE}" = "401" ] || [ "${VIP_CODE}" = "200" ]; then
    pass "API server responde por la VIP ${CLUSTER_VIP} → HTTP ${VIP_CODE}"
else
    fail "VIP ${CLUSTER_VIP}:6443 no responde → HTTP ${VIP_CODE}"
fi

# ============================================================
# 2. CONECTIVIDAD Y SERVICIOS BÁSICOS
# ============================================================
title "2. CONECTIVIDAD Y SERVICIOS BÁSICOS"

echo ""
info "Estado de pods:"
kubectl get pods -n "${NAMESPACE}" -o wide 2>/dev/null
echo ""

# 2.1 Moodle: tras el 06, el HPA sostiene un piso de réplicas
MOODLE_READY=$(kubectl get pods -n "${NAMESPACE}" -l app=moodle \
    --no-headers 2>/dev/null \
    | awk '$2=="1/1" && $3=="Running" {count++} END {print count+0}')
[ "${MOODLE_READY}" -ge "${MOODLE_MIN_REPLICAS}" ] \
    && pass "Moodle pods 1/1 Running: ${MOODLE_READY} (mínimo ${MOODLE_MIN_REPLICAS})" \
    || fail "Moodle pods 1/1 Running: ${MOODLE_READY} (esperado >= ${MOODLE_MIN_REPLICAS})"

# 2.2 Galera: el chart Helm NO usa 'app=mariadb'; usa las labels
# estándar de Helm. Este era un falso negativo del test anterior.
MARIADB_READY=$(kubectl get pods -n "${NAMESPACE}" \
    -l app.kubernetes.io/instance=mariadb --no-headers 2>/dev/null \
    | awk '$2=="1/1" && $3=="Running" {count++} END {print count+0}')
[ "${MARIADB_READY}" -eq 2 ] \
    && pass "Galera: 2/2 pods de datos Running (mariadb-0, mariadb-1)" \
    || fail "Galera: ${MARIADB_READY}/2 pods Running"

# 2.3 garbd (árbitro) Running y en la Pi
GARBD_POD=$(kubectl get pods -n "${NAMESPACE}" -l app=garbd \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
if [ -n "${GARBD_POD}" ]; then
    GARBD_STATUS=$(kubectl get pod "${GARBD_POD}" -n "${NAMESPACE}" \
        --no-headers 2>/dev/null | awk '{print $3}')
    [ "${GARBD_STATUS}" = "Running" ] \
        && pass "garbd Running (${GARBD_POD})" \
        || fail "garbd en estado ${GARBD_STATUS}"
    GARBD_NODE=$(pod_node "${GARBD_POD}" "${NAMESPACE}")
    [ "${GARBD_NODE}" = "${NODE_PI}" ] \
        && pass "garbd programado en la Pi (${GARBD_NODE})" \
        || fail "garbd en '${GARBD_NODE}' — debía estar en ${NODE_PI}"
else
    fail "No se encontró pod de garbd (label app=garbd)"
fi

# 2.4 Redis
REDIS_READY=$(kubectl get pods -n "${NAMESPACE}" -l app=redis \
    --no-headers 2>/dev/null \
    | awk '$2=="1/1" && $3=="Running" {count++} END {print count+0}')
[ "${REDIS_READY}" -ge 1 ] && pass "Redis 1/1 Running" || fail "Redis NO Running"

# 2.5 MaxScale (el detalle vive en la sección 8)
MAXSCALE_READY=$(kubectl get pods -n "${NAMESPACE}" -l app=maxscale \
    --no-headers 2>/dev/null \
    | awk '$2=="1/1" && $3=="Running" {count++} END {print count+0}')
[ "${MAXSCALE_READY}" -eq "${MAXSCALE_EXPECTED_REPLICAS}" ] \
    && pass "MaxScale: ${MAXSCALE_READY}/${MAXSCALE_EXPECTED_REPLICAS} réplicas Running" \
    || fail "MaxScale: ${MAXSCALE_READY}/${MAXSCALE_EXPECTED_REPLICAS} réplicas Running"

# 2.6 Ingress y certificado TLS
INGRESS_IP=$(kubectl get ingress moodle-ingress -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
[ -n "${INGRESS_IP}" ] && pass "Ingress con IP: ${INGRESS_IP}" \
                       || warn "Ingress sin IP asignada"

TLS_EXPIRY=$(echo | timeout 5 openssl s_client -connect \
    "${BASE_URL#https://}:443" -servername "${BASE_URL#https://}" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")
[ -n "${TLS_EXPIRY}" ] && pass "Certificado TLS válido hasta: ${TLS_EXPIRY}" \
                       || warn "No se pudo verificar certificado TLS"

# 2.7 DNS / resolución
DOMAIN="${BASE_URL#https://}"
DOMAIN="${DOMAIN#http://}"
IP=$(nslookup "${DOMAIN}" 2>/dev/null | grep -A1 "Name:" | grep "Address:" \
     | awk '{print $2}' | head -1 || echo "")
[ -n "${IP}" ] && pass "DNS resuelve ${DOMAIN} → ${IP}" \
               || warn "No se pudo resolver DNS de ${DOMAIN}"

# ============================================================
# 3. FUNCIONALIDAD WEB — RUTAS CRÍTICAS
# ============================================================
title "3. FUNCIONALIDAD WEB"

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

# 3.1 Página de login contiene elementos esperados
LOGIN_BODY=$(http_body "${BASE_URL}/login/index.php")
echo "${LOGIN_BODY}" | grep -qi "username\|usuario\|Ingresar" \
    && pass "Página login contiene formulario de acceso" \
    || fail "Página login no contiene formulario esperado"

echo "${LOGIN_BODY}" | grep -qi "TESOEM\|Moodle" \
    && pass "Página login muestra nombre del sitio" \
    || warn "Página login no muestra nombre del sitio"

# 3.2 No hay errores PHP visibles
echo "${LOGIN_BODY}" | grep -qi "Fatal error\|Parse error\|Warning:" \
    && fail "Errores PHP visibles en login/index.php" \
    || pass "Sin errores PHP visibles en frontend"

# ============================================================
# 4. RECURSOS ESTÁTICOS Y DINÁMICOS
# ============================================================
title "4. RECURSOS ESTÁTICOS Y DINÁMICOS"

CSS_CODE=$(http_code "${BASE_URL}/theme/boost/style/moodle.css")
[ "${CSS_CODE}" = "200" ] && pass "CSS estático (moodle.css) → 200" \
                           || fail "CSS estático → ${CSS_CODE}"

CSS_BODY=$(http_body "${BASE_URL}/theme/boost/style/moodle.css")
echo "${CSS_BODY}" | grep -q "charset\|font\|color\|margin" \
    && pass "CSS contiene reglas de estilo válidas" \
    || fail "CSS no contiene reglas esperadas"

JS_CODE=$(http_code "${BASE_URL}/lib/javascript.php/1775118558/lib/polyfills/polyfill.js")
[ "${JS_CODE}" = "200" ] && pass "JS dinámico (javascript.php) → 200" \
                          || fail "JS dinámico → ${JS_CODE} (revisar dirroot en config.php)"

IMG_CODE=$(http_code "${BASE_URL}/theme/image.php/boost/theme/1775118558/favicon")
[ "${IMG_CODE}" = "200" ] && pass "Imagen dinámica (image.php) → 200" \
                           || fail "Imagen dinámica → ${IMG_CODE} (revisar dirroot en config.php)"

FONT_CODE=$(http_code "${BASE_URL}/theme/font.php/boost/core/1775118558/fa-solid-900.woff2")
[ "${FONT_CODE}" = "200" ] && pass "Fuente dinámica (font.php) → 200" \
                            || fail "Fuente dinámica → ${FONT_CODE}"

# ============================================================
# 5. AUTENTICACIÓN Y SESIONES
# ============================================================
title "5. AUTENTICACIÓN Y SESIONES"

LOGIN_TOKEN=$(http_body "${BASE_URL}/login/index.php" \
    | grep -oP '(?<=name="logintoken" value=")[^"]+' | head -1 || echo "")
[ -n "${LOGIN_TOKEN}" ] && pass "logintoken presente en formulario: ${LOGIN_TOKEN:0:16}..." \
                         || warn "logintoken no encontrado (puede usar otro método)"

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

SESSION_COOKIE=$(grep -c "MoodleSession" "${COOKIE_JAR}" 2>/dev/null || echo "0")
[ "${SESSION_COOKIE}" -ge 1 ] && pass "Cookie MoodleSession creada" \
                               || warn "Cookie MoodleSession no encontrada"

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
# 6. PERSISTENCIA — GALERA + REDIS + PVCs
# ============================================================
title "6. PERSISTENCIA"

# 6.1 Clúster Galera: tamaño y estado wsrep.
# wsrep_cluster_size debe ser 3: mariadb-0 + mariadb-1 + garbd.
# Es LA métrica de que la replicación síncrona está formada.
CLUSTER_SIZE=$(galera_sql "SHOW STATUS LIKE 'wsrep_cluster_size';" \
    | awk '{print $2}' || echo "0")
[ "${CLUSTER_SIZE}" = "${GALERA_EXPECTED_SIZE}" ] \
    && pass "Galera: wsrep_cluster_size = ${CLUSTER_SIZE} (2 datos + árbitro)" \
    || fail "Galera: wsrep_cluster_size = ${CLUSTER_SIZE:-?} (esperado ${GALERA_EXPECTED_SIZE})"

WSREP_STATE=$(galera_sql "SHOW STATUS LIKE 'wsrep_local_state_comment';" \
    | awk '{print $2}' || echo "")
[ "${WSREP_STATE}" = "Synced" ] \
    && pass "Galera: mariadb-0 en estado Synced" \
    || fail "Galera: mariadb-0 en estado '${WSREP_STATE:-?}' (esperado Synced)"

WSREP_READY=$(galera_sql "SHOW STATUS LIKE 'wsrep_ready';" \
    | awk '{print $2}' || echo "")
[ "${WSREP_READY}" = "ON" ] \
    && pass "Galera: wsrep_ready = ON" \
    || fail "Galera: wsrep_ready = ${WSREP_READY:-?}"

# 6.2 Colocación de los pods de datos: uno en A y otro en B.
# El podAntiAffinityPreset hard + PVs locales garantizan esto;
# aquí se verifica que la garantía se cumplió de verdad.
M0_NODE=$(pod_node "mariadb-0" "${NAMESPACE}")
M1_NODE=$(pod_node "mariadb-1" "${NAMESPACE}")
info "mariadb-0 → ${M0_NODE:-?}   mariadb-1 → ${M1_NODE:-?}"
if [ -n "${M0_NODE}" ] && [ -n "${M1_NODE}" ] && [ "${M0_NODE}" != "${M1_NODE}" ]; then
    pass "Pods Galera en nodos distintos (anti-affinity cumplida)"
else
    fail "Pods Galera mal distribuidos (m0=${M0_NODE:-?}, m1=${M1_NODE:-?})"
fi
for N in "${M0_NODE}" "${M1_NODE}"; do
    if [ "${N}" = "${NODE_A}" ] || [ "${N}" = "${NODE_B}" ]; then
        pass "  Pod Galera en nodo de datos válido: ${N}"
    else
        fail "  Pod Galera en nodo NO válido: ${N:-?} (la Pi no lleva datos)"
    fi
done

# 6.3 PVs de Galera: cada PVC del StatefulSet debe estar ligado
# a su PV local (pv-a en A, pv-b en B) — el dato vive donde debe.
for IDX in 0 1; do
    PV_BOUND=$(kubectl get pvc "data-mariadb-${IDX}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")
    if [[ "${PV_BOUND}" == mariadb-galera-pv-* ]]; then
        PV_NODE=$(kubectl get pv "${PV_BOUND}" \
            -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' \
            2>/dev/null || echo "?")
        pass "data-mariadb-${IDX} → ${PV_BOUND} (anclado a ${PV_NODE})"
    else
        fail "data-mariadb-${IDX} ligado a '${PV_BOUND:-nada}' (esperado mariadb-galera-pv-*)"
    fi
done

# 6.4 Contenido de la BD, consultado VÍA MAXSCALE — la misma ruta
# que usa Moodle. Si esto pasa, la cadena app→maxscale→galera sirve.
MAXSCALE_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=maxscale \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
TABLE_COUNT=$(kubectl exec -n "${NAMESPACE}" mariadb-0 -c mariadb-galera -- \
    mariadb -u root -p"$(mariadb_root_pw)" -h maxscale.moodle-prod.svc.cluster.local -N \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='moodle';" \
    2>/dev/null | tr -d ' \n' || echo "0")
if [ "${TABLE_COUNT:-0}" -gt 100 ] 2>/dev/null; then
    pass "BD vía MaxScale: ${TABLE_COUNT} tablas Moodle presentes"
else
    # Reintento directo contra mariadb-0 para distinguir el fallo:
    # ¿es MaxScale o es la BD?
    DIRECT_COUNT=$(galera_sql \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='moodle';" \
        | tr -d ' \n' || echo "0")
    if [ "${DIRECT_COUNT:-0}" -gt 100 ] 2>/dev/null; then
        fail "BD directa OK (${DIRECT_COUNT} tablas) pero la ruta vía MaxScale falló"
    else
        fail "BD: solo ${DIRECT_COUNT} tablas (instalación incompleta)"
    fi
fi

ADMIN_EXISTS=$(galera_sql \
    "SELECT COUNT(*) FROM moodle.mdl_user WHERE username='${ADMIN_USER}';" \
    | tr -d ' \n' || echo "0")
[ "${ADMIN_EXISTS:-0}" -ge 1 ] 2>/dev/null \
    && pass "Usuario admin existe en BD" \
    || fail "Usuario admin NO encontrado en BD"

# 6.5 Redis
REDIS_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=redis \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)

if [ -n "${REDIS_POD}" ]; then
    REDIS_PING=$(kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- \
        redis-cli -a '@@Ad1v1na#2@@' ping 2>/dev/null | tr -d ' \n' || echo "FAIL")
    [ "${REDIS_PING}" = "PONG" ] && pass "Redis responde PONG" \
                                  || fail "Redis no responde ping: ${REDIS_PING}"

    REDIS_KEYS=$(kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- \
        redis-cli -a '@@Ad1v1na#2@@' -n 0 DBSIZE 2>/dev/null | tr -d ' \n' || echo "0")
    pass "Redis DB0 (sesiones): ${REDIS_KEYS} claves"

    REDIS_CACHE=$(kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- \
        redis-cli -a '@@Ad1v1na#2@@' -n 1 DBSIZE 2>/dev/null | tr -d ' \n' || echo "0")
    pass "Redis DB1 (caché): ${REDIS_CACHE} claves"
else
    fail "No se encontró pod de Redis"
fi

# 6.6 PVCs — ahora son 5: redis, html, data + los 2 del StatefulSet
echo ""
info "Estado de PersistentVolumeClaims:"
kubectl get pvc -n "${NAMESPACE}" 2>/dev/null
echo ""
PVC_BOUND=$(kubectl get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -c "Bound" || echo "0")
[ "${PVC_BOUND}" -ge "${EXPECTED_PVC_BOUND}" ] \
    && pass "${PVC_BOUND}/${EXPECTED_PVC_BOUND} PVCs en estado Bound" \
    || fail "Solo ${PVC_BOUND}/${EXPECTED_PVC_BOUND} PVCs en Bound"

# ============================================================
# 7. ALMACENAMIENTO HA — LONGHORN
# ============================================================
# Sección unificada (absorbe test-longhorn.sh):
#   7.0 Prerrequisitos locales del nodo   (--skip-prereqs la omite)
#   7.1 Estado de Longhorn en el clúster (namespace, pods, StorageClass)
#   7.2 Topología: A y B registrados, Pi excluida
#   7.3 HA del dato: cada volumen healthy con réplicas en A y B
#   7.4 share-managers (NFS de los RWX)
#   7.5 Prueba E2E de aprovisionamiento  (--no-e2e la omite)
title "7. ALMACENAMIENTO HA (LONGHORN)"

# ── 7.0 Prerrequisitos locales del nodo donde corre el script ──
# Si esto falla, Longhorn no puede montar volúmenes AQUÍ aunque
# el clúster esté sano. Verificación local, no de clúster.
if [ "${SKIP_PREREQS}" = "false" ]; then
    info "Prerrequisitos locales del nodo $(hostname):"

    # iscsiadm: transporte iSCSI | mount.nfs: RWX | cryptsetup: instalador
    for cmd in iscsiadm mount.nfs cryptsetup; do
        command -v "${cmd}" &>/dev/null \
            && pass "  comando '${cmd}' disponible" \
            || fail "  comando '${cmd}' NO encontrado — instala el paquete correspondiente"
    done

    # Módulos: cargados (lsmod) o builtin (/sys/module) — ambos valen
    for mod in iscsi_tcp dm_crypt; do
        if lsmod 2>/dev/null | grep -q "^${mod}\b"; then
            pass "  módulo '${mod}' cargado"
        elif [ -d "/sys/module/${mod}" ]; then
            pass "  módulo '${mod}' presente (builtin o ya cargado)"
        else
            fail "  módulo '${mod}' no cargado — ejecuta: modprobe ${mod}"
        fi
    done

    systemctl is-active --quiet iscsid 2>/dev/null \
        && pass "  iscsid está activo" \
        || fail "  iscsid NO está activo — ejecuta: systemctl enable --now iscsid"

    # multipathd puede secuestrar los dispositivos de Longhorn
    if systemctl is-active --quiet multipathd 2>/dev/null; then
        warn "  multipathd activo — verifica blacklist en /etc/multipath.conf"
    else
        pass "  multipathd inactivo — sin riesgo de conflicto"
    fi
else
    info "Prerrequisitos locales omitidos (--skip-prereqs)"
fi

# ── 7.1 Estado de Longhorn en el clúster ────────────────────────
if kubectl get namespace "${LONGHORN_NS}" &>/dev/null; then
    pass "namespace '${LONGHORN_NS}' existe"
else
    fail "namespace '${LONGHORN_NS}' NO existe — Longhorn no está instalado"
fi

LH_TOTAL=$(kubectl get pods -n "${LONGHORN_NS}" --no-headers 2>/dev/null | wc -l)
LH_NOT_READY=$(kubectl get pods -n "${LONGHORN_NS}" --no-headers 2>/dev/null \
    | awk '$3 != "Running" && $3 != "Completed" {print}' | wc -l)
if [ "${LH_TOTAL}" -eq 0 ]; then
    fail "no hay pods en '${LONGHORN_NS}'"
elif [ "${LH_NOT_READY}" -eq 0 ]; then
    pass "los ${LH_TOTAL} pods de Longhorn están Running/Completed"
else
    fail "${LH_NOT_READY} de ${LH_TOTAL} pods de Longhorn NO están listos:"
    kubectl get pods -n "${LONGHORN_NS}" --no-headers 2>/dev/null \
        | awk '$3 != "Running" && $3 != "Completed" {print "      - "$1" ("$3")"}'
fi

SC_PROVISIONER=$(kubectl get storageclass "${STORAGE_CLASS}" \
    -o jsonpath='{.provisioner}' 2>/dev/null || echo "")
if [ "${SC_PROVISIONER}" = "driver.longhorn.io" ]; then
    pass "StorageClass '${STORAGE_CLASS}' existe y usa driver.longhorn.io"
elif [ -n "${SC_PROVISIONER}" ]; then
    warn "StorageClass '${STORAGE_CLASS}' existe pero su provisioner es '${SC_PROVISIONER}'"
else
    fail "StorageClass '${STORAGE_CLASS}' NO existe"
fi

# ── 7.2 Topología: exactamente A y B; la Pi excluida ────────────
LH_NODES=$(kubectl -n "${LONGHORN_NS}" get nodes.longhorn.io \
    --no-headers 2>/dev/null | awk '{print $1}')
LH_COUNT=$(echo "${LH_NODES}" | grep -c . || echo "0")
[ "${LH_COUNT}" -eq "${EXPECTED_LH_NODES}" ] \
    && pass "Longhorn registra ${LH_COUNT} nodos de almacenamiento" \
    || fail "Longhorn registra ${LH_COUNT} nodos (esperados ${EXPECTED_LH_NODES}: A y B)"

for N in "${NODE_A}" "${NODE_B}"; do
    if echo "${LH_NODES}" | grep -qw "${N}"; then
        # Registrado no basta: debe estar Ready y Schedulable para réplicas
        LH_READY=$(kubectl get nodes.longhorn.io "${N}" -n "${LONGHORN_NS}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        LH_SCHED=$(kubectl get nodes.longhorn.io "${N}" -n "${LONGHORN_NS}" \
            -o jsonpath='{.status.conditions[?(@.type=="Schedulable")].status}' 2>/dev/null)
        if [ "${LH_READY}" = "True" ] && [ "${LH_SCHED}" = "True" ]; then
            pass "  ${N} registrado, Ready y Schedulable"
        else
            fail "  ${N} registrado pero Ready=${LH_READY:-?} Schedulable=${LH_SCHED:-?}"
        fi
    else
        fail "  ${N} NO está registrado en Longhorn"
    fi
done

echo "${LH_NODES}" | grep -qw "${NODE_PI}" \
    && fail "  La Pi se coló en Longhorn — el árbitro debía quedar fuera" \
    || pass "  Pi correctamente excluida de Longhorn"

# ── 7.3 Por cada volumen de Moodle: healthy + réplicas en A y B ─
for PVC in ${MOODLE_PVCS}; do
    VOL=$(kubectl -n "${NAMESPACE}" get pvc "${PVC}" \
        -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")
    if [ -z "${VOL}" ]; then
        fail "PVC ${PVC}: no se pudo resolver su volumen"
        continue
    fi
    info "PVC ${PVC} → volumen ${VOL}"

    ROBUSTNESS=$(kubectl -n "${LONGHORN_NS}" get volumes.longhorn.io "${VOL}" \
        -o jsonpath='{.status.robustness}' 2>/dev/null || echo "?")
    [ "${ROBUSTNESS}" = "healthy" ] \
        && pass "  ${VOL}: robustness=healthy" \
        || fail "  ${VOL}: robustness=${ROBUSTNESS} (esperado healthy)"

    REP_NODES=$(kubectl -n "${LONGHORN_NS}" get replicas.longhorn.io \
        -l longhornvolume="${VOL}" \
        -o jsonpath='{range .items[*]}{.spec.nodeID}{"\n"}{end}' 2>/dev/null \
        | sort -u | grep -c . || echo "0")
    [ "${REP_NODES}" -eq 2 ] \
        && pass "  ${VOL}: réplicas en 2 nodos distintos" \
        || fail "  ${VOL}: réplicas en ${REP_NODES} nodo(s) (esperado 2)"

    kubectl -n "${LONGHORN_NS}" get replicas.longhorn.io -l longhornvolume="${VOL}" \
        -o custom-columns='RÉPLICA:.metadata.name,NODO:.spec.nodeID,ESTADO:.status.currentState' \
        --no-headers 2>/dev/null | sed 's/^/      /'
done

# ── 7.4 share-managers (el NFS de los RWX) — uno por volumen ────
SM_RUNNING=$(kubectl get pods -n "${LONGHORN_NS}" --no-headers 2>/dev/null \
    | awk '/^share-manager/ && $3=="Running"{c++} END{print c+0}')
[ "${SM_RUNNING}" -ge 2 ] \
    && pass "share-managers Running: ${SM_RUNNING} (NFS de los RWX activo)" \
    || fail "share-managers Running: ${SM_RUNNING} (esperados >= 2)"

# ── 7.5 Prueba E2E: aprovisionamiento dinámico de punta a punta ─
# Crea un PVC real contra el StorageClass, espera Bound, y limpia
# SIEMPRE al salir. Si llega a Bound, la cadena CSI→engine→réplica
# funciona completa, no solo "los pods están verdes".
if [ "${RUN_E2E}" = "true" ]; then
    E2E_PVC="longhorn-test-pvc-$$-$(date +%s)"
    E2E_NS="default"
    info "Prueba E2E: creando PVC '${E2E_PVC}' (${TEST_PVC_SIZE}, SC=${STORAGE_CLASS})..."

    if cat <<PVCEOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${E2E_PVC}
  namespace: ${E2E_NS}
  labels:
    test: longhorn-e2e
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${TEST_PVC_SIZE}
PVCEOF
    then
        pass "PVC de prueba creado"

        E2E_ELAPSED=0
        E2E_PHASE=""
        while [ "${E2E_ELAPSED}" -lt "${TEST_PVC_TIMEOUT}" ]; do
            E2E_PHASE=$(kubectl get pvc "${E2E_PVC}" -n "${E2E_NS}" \
                -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            [ "${E2E_PHASE}" = "Bound" ] && break
            sleep 2
            E2E_ELAPSED=$((E2E_ELAPSED+2))
        done

        if [ "${E2E_PHASE}" = "Bound" ]; then
            E2E_PV=$(kubectl get pvc "${E2E_PVC}" -n "${E2E_NS}" \
                -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "?")
            pass "PVC llegó a Bound en ${E2E_ELAPSED}s — aprovisionó ${E2E_PV}"
        else
            fail "PVC no llegó a Bound en ${TEST_PVC_TIMEOUT}s (estado: ${E2E_PHASE:-desconocido})"
            kubectl describe pvc "${E2E_PVC}" -n "${E2E_NS}" 2>/dev/null \
                | grep -A10 "Events:" | sed 's/^/      /'
        fi

        # Limpieza incondicional: nunca dejar basura en el clúster.
        # OJO: el SC tiene reclaimPolicy=Retain (decisión de diseño),
        # así que al borrar el PVC el PV queda en Released — se borra
        # explícitamente para no acumular PVs huérfanos de prueba.
        info "Limpiando PVC de prueba..."
        kubectl delete pvc "${E2E_PVC}" -n "${E2E_NS}" --ignore-not-found=true \
            --wait=true --timeout=30s &>/dev/null \
            && pass "PVC de prueba eliminado" \
            || warn "no se confirmó la eliminación — revisa: kubectl get pvc -n ${E2E_NS}"
        if [ -n "${E2E_PV:-}" ] && [ "${E2E_PV}" != "?" ]; then
            kubectl delete pv "${E2E_PV}" --ignore-not-found=true \
                --wait=false &>/dev/null || true
            info "PV ${E2E_PV} marcado para eliminación (reclaimPolicy=Retain)"
        fi
    else
        fail "no se pudo crear el PVC de prueba (kubectl apply falló)"
    fi
else
    info "Prueba E2E omitida (--no-e2e)"
fi

# ============================================================
# 8. CAPA DE ACCESO A DATOS — MAXSCALE
# ============================================================
# Las 2 réplicas de MaxScale deben estar en nodos amd64 distintos
# (nunca la Pi), y galeramon en AMBAS debe converger a la misma
# vista: mariadb-0 y mariadb-1 Synced, exactamente un Master.
title "8. CAPA DE ACCESO A DATOS (MAXSCALE)"

MAXSCALE_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=maxscale \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
MS_COUNT=$(echo "${MAXSCALE_PODS}" | grep -c . || echo "0")
[ "${MS_COUNT}" -eq "${MAXSCALE_EXPECTED_REPLICAS}" ] \
    && pass "MaxScale: ${MS_COUNT} réplicas desplegadas" \
    || fail "MaxScale: ${MS_COUNT} réplicas (esperadas ${MAXSCALE_EXPECTED_REPLICAS})"

# 8.1 Distribución: nodos distintos, ninguno en la Pi
MS_NODES=""
for P in ${MAXSCALE_PODS}; do
    N=$(pod_node "${P}" "${NAMESPACE}")
    MS_NODES="${MS_NODES}${N}\n"
    [ "${N}" = "${NODE_PI}" ] \
        && fail "  ${P} en la Pi — la nodeAffinity amd64 no se cumplió" \
        || pass "  ${P} → ${N}"
done
MS_DISTINCT=$(echo -e "${MS_NODES}" | grep -c . | tr -d ' ')
MS_UNIQUE=$(echo -e "${MS_NODES}" | sort -u | grep -c . | tr -d ' ')
[ "${MS_UNIQUE}" -eq "${MS_DISTINCT}" ] && [ "${MS_DISTINCT}" -ge 2 ] \
    && pass "Réplicas MaxScale en nodos distintos (anti-affinity cumplida)" \
    || fail "Réplicas MaxScale co-ubicadas (${MS_UNIQUE} nodos únicos de ${MS_DISTINCT})"

# 8.2 Vista de galeramon en CADA réplica — deben converger solas
# al mismo Master (determinismo por wsrep_local_index más bajo).
for P in ${MAXSCALE_PODS}; do
    SERVERS_TSV=$(kubectl exec -n "${NAMESPACE}" "${P}" -- \
        maxctrl list servers --tsv 2>/dev/null || echo "")
    if [ -z "${SERVERS_TSV}" ]; then
        fail "  ${P}: maxctrl no respondió"
        continue
    fi
    M0_STATE=$(echo "${SERVERS_TSV}" | awk -F'\t' '$1=="mariadb-0"{print $5}')
    M1_STATE=$(echo "${SERVERS_TSV}" | awk -F'\t' '$1=="mariadb-1"{print $5}')

    echo "${M0_STATE}${M1_STATE}" | grep -q "Down" \
        && fail "  ${P}: algún servidor Down (m0='${M0_STATE}', m1='${M1_STATE}')" \
        || pass "  ${P}: ambos servidores arriba"

    MASTERS=$(echo "${SERVERS_TSV}" | awk -F'\t' '$5 ~ /Master/{c++} END{print c+0}')
    [ "${MASTERS}" -eq 1 ] \
        && pass "  ${P}: exactamente 1 Master ($(echo "${SERVERS_TSV}" \
             | awk -F'\t' '$5 ~ /Master/{print $1}'))" \
        || fail "  ${P}: ${MASTERS} Masters (esperado exactamente 1)"

    SYNCED=$(echo "${SERVERS_TSV}" | awk -F'\t' '$5 ~ /Synced/{c++} END{print c+0}')
    [ "${SYNCED}" -eq 2 ] \
        && pass "  ${P}: 2/2 servidores Synced" \
        || fail "  ${P}: ${SYNCED}/2 servidores Synced"
done

# 8.3 Ambas réplicas eligieron el MISMO Master (convergencia sin
# coordinación — el punto arquitectónico de galeramon)
MASTER_SET=$(for P in ${MAXSCALE_PODS}; do
    kubectl exec -n "${NAMESPACE}" "${P}" -- maxctrl list servers --tsv 2>/dev/null \
        | awk -F'\t' '$5 ~ /Master/{print $1}'
done | sort -u)
MASTER_UNIQ=$(echo "${MASTER_SET}" | grep -c . || echo "0")
[ "${MASTER_UNIQ}" -eq 1 ] \
    && pass "Ambas réplicas MaxScale convergen al mismo Master: ${MASTER_SET}" \
    || fail "Las réplicas MaxScale NO coinciden en el Master: [${MASTER_SET}]"

# 8.4 Moodle nació apuntando a maxscale (config write-once)
MOODLE_DBHOST=$(kubectl exec -n "${NAMESPACE}" "$(moodle_pod)" -c moodle -- \
    php -r 'define("CLI_SCRIPT", true); require "/var/www/html/config.php"; echo $CFG->dbhost;' \
    2>/dev/null || echo "")
[ "${MOODLE_DBHOST}" = "maxscale" ] \
    && pass "config.php de Moodle → dbhost=maxscale" \
    || fail "config.php de Moodle → dbhost='${MOODLE_DBHOST:-?}' (esperado maxscale)"

# ============================================================
# 9. ESCALAMIENTO HORIZONTAL
# ============================================================
title "9. ESCALAMIENTO HORIZONTAL"

CURRENT_REPLICAS=$(kubectl get deployment moodle -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
CURRENT_REPLICAS="${CURRENT_REPLICAS:-0}"
info "Réplicas actuales de Moodle: ${CURRENT_REPLICAS}"

info "Escalando a 3 réplicas..."
kubectl scale deployment moodle -n "${NAMESPACE}" --replicas=3 2>/dev/null
sleep 5

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
[ "${READY_3:-0}" -ge 3 ] && pass "Escalado a 3 réplicas exitoso (${READY_3} Ready)" \
                           || fail "Solo ${READY_3}/3 réplicas listas"

# Distribución de las réplicas por nodo (informativo: con
# nodeSelector fijo caerán todas en A; sin él, se reparten)
info "Distribución de pods de Moodle:"
kubectl get pods -n "${NAMESPACE}" -l app=moodle -o wide --no-headers 2>/dev/null \
    | awk '{print "      "$1" → "$7}'

SCALE_CODE=$(http_code "${BASE_URL}/login/index.php")
[ "${SCALE_CODE}" = "200" ] && pass "Sitio disponible durante escalado → ${SCALE_CODE}" \
                             || fail "Sitio NO disponible durante escalado → ${SCALE_CODE}"

HPA_STATUS=$(kubectl get hpa moodle-hpa -n "${NAMESPACE}" \
    --no-headers 2>/dev/null | head -1 || echo "")
[ -n "${HPA_STATUS}" ] && pass "HPA presente: ${HPA_STATUS}" \
                        || warn "HPA no encontrado"

# ============================================================
# 10. TOLERANCIA A FALLOS
# ============================================================
title "10. TOLERANCIA A FALLOS"

REPLICAS_NOW=$(kubectl get deployment moodle -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
REPLICAS_NOW="${REPLICAS_NOW:-0}"

if [ "${REPLICAS_NOW}" -ge 2 ]; then
    POD_TO_KILL=$(kubectl get pods -n "${NAMESPACE}" -l app=moodle \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
    info "Eliminando pod: ${POD_TO_KILL}"
    kubectl delete pod "${POD_TO_KILL}" -n "${NAMESPACE}" --grace-period=0 \
        --force 2>/dev/null || true

    sleep 3
    FAULT_CODE=$(http_code "${BASE_URL}/login/index.php")
    [ "${FAULT_CODE}" = "200" ] \
        && pass "Sitio disponible tras eliminar pod → ${FAULT_CODE}" \
        || fail "Sitio NO disponible tras eliminar pod → ${FAULT_CODE}"

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
# 11. RENDIMIENTO BAJO CARGA
# ============================================================
title "11. RENDIMIENTO BAJO CARGA"

if command -v wrk &>/dev/null; then
    info "Herramienta de carga: wrk"
    info "Ejecutando: ${LOAD_USERS} conexiones × ${LOAD_DURATION}s contra ${BASE_URL}/login/index.php"
    echo ""
    WRK_RESULT=$(wrk -t4 -c"${LOAD_USERS}" -d"${LOAD_DURATION}"s \
        --timeout 10 "${BASE_URL}/login/index.php" 2>&1 || echo "ERROR")
    echo "${WRK_RESULT}"
    echo ""

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

    info "Ejecutando prueba básica: 20 peticiones secuenciales..."
    ERRORS_MANUAL=0
    for i in $(seq 1 20); do
        CODE=$(http_code "${BASE_URL}/login/index.php")
        [ "${CODE}" != "200" ] && ERRORS_MANUAL=$((ERRORS_MANUAL+1)) || true
    done
    [ "${ERRORS_MANUAL}" -eq 0 ] \
        && pass "20 peticiones: 0 errores" \
        || fail "20 peticiones: ${ERRORS_MANUAL} errores"
fi

# ============================================================
# 12. CRON Y TAREAS PROGRAMADAS
# ============================================================
title "12. CRON Y TAREAS PROGRAMADAS"

CRON_SUSPENDED=$(kubectl get cronjob moodle-cron -n "${NAMESPACE}" \
    -o jsonpath='{.spec.suspend}' 2>/dev/null || echo "true")
[ "${CRON_SUSPENDED}" = "false" ] && pass "CronJob activo (suspend: false)" \
                                   || fail "CronJob suspendido (suspend: true)"

LAST_SCHEDULE=$(kubectl get cronjob moodle-cron -n "${NAMESPACE}" \
    -o jsonpath='{.status.lastScheduleTime}' 2>/dev/null || echo "")
[ -n "${LAST_SCHEDULE}" ] && pass "Último schedule: ${LAST_SCHEDULE}" \
                           || warn "CronJob sin ejecuciones registradas"

info "Lanzando job de cron manual para verificar..."
TEST_JOB="cron-test-$(date +%s)"
kubectl create job --from=cronjob/moodle-cron "${TEST_JOB}" \
    -n "${NAMESPACE}" 2>/dev/null || true

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

CRON_POD=$(kubectl get pods -n "${NAMESPACE}" -l "job-name=${TEST_JOB}" \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
if [ -n "${CRON_POD}" ]; then
    CRON_LOGS=$(kubectl logs -n "${NAMESPACE}" "${CRON_POD}" -c cron \
        --tail=5 2>/dev/null || echo "")
    echo "${CRON_LOGS}" | grep -qi "completed\|completado\|Cron run" \
        && pass "Logs de cron muestran ejecución exitosa" \
        || warn "Logs de cron: $(echo "${CRON_LOGS}" | tail -2)"
fi

kubectl delete job "${TEST_JOB}" -n "${NAMESPACE}" 2>/dev/null || true
info "Job de prueba eliminado"

# ============================================================
# 13. RESUMEN Y VEREDICTO
# ============================================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

title "13. RESUMEN FINAL"
echo ""
echo -e "  ${BOLD}Resultados:${NC}"
echo -e "  ${GREEN}✓ PASS: ${PASS}${NC}"
echo -e "  ${RED}✗ FAIL: ${FAIL}${NC}"
echo -e "  ${YELLOW}⚠ WARN: ${WARN}${NC}"
echo -e "  ${CYAN}⏱ Duración: ${DURATION}s${NC}"
echo ""

echo -e "  ${BOLD}Distribución final por nodo:${NC}"
kubectl get pods -n "${NAMESPACE}" -o wide --no-headers 2>/dev/null \
    | awk '{printf "  %-40s %-10s %s\n", $1, $3, $7}'
echo ""
echo -e "  ${BOLD}Volúmenes Longhorn:${NC}"
kubectl -n "${LONGHORN_NS}" get volumes.longhorn.io \
    -o custom-columns='VOLUMEN:.metadata.name,ESTADO:.status.state,ROBUSTEZ:.status.robustness,RÉPLICAS:.spec.numberOfReplicas' \
    --no-headers 2>/dev/null | sed 's/^/  /'
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
