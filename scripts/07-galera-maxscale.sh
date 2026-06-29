#!/bin/bash
# ======================================================
# 09-galera-maxscale.sh 
# Despliegue de galera y maxscale
#
# PROPOSITO:
#   Activar distribucion para las bases de datos

set -euo pipefail

# Requisitos mínimos del sistema
RAID_BASE="${RAID_BASE:-/moodlek3s}"
ARCH=$(uname -m)   # x86_64 o aarch64
MANIFEST_DIR="/root/k3s-moodle/manifests"
SCRIPTS_DIR="/root/k3s-moodle/scripts"
# ── Config de la app (ajusta si cambian nombres) ──────────────────────────────
MOODLE_NS="moodle-prod"
MOODLE_PVCS="moodle-html-pvc moodle-data-pvc"
MOODLE_DEPLOY="moodle"
MOODLE_HPA="moodle-hpa"
MOODLE_TARGET_REPLICAS=3

# ── Colores para output ───────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Funciones de utilidad ─────────────────────────────────────────────────────
log_step()    { echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════════${NC}"; \
                echo -e "${BLUE}${BOLD}  PASO: $1${NC}"; \
                echo -e "${BLUE}${BOLD}══════════════════════════════════════════════${NC}"; }
log_sub()     { echo -e "\n  ${CYAN}${BOLD}▶ $1${NC}"; }
log_ok()      { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "  ${YELLOW}⚠${NC}  $1"; }
log_err()     { echo -e "  ${RED}✗ ERROR:${NC} $1"; }
log_info()    { echo -e "  ${CYAN}ℹ${NC} $1"; }

die() {
  log_err "$1"
  echo ""
  exit 1
}

require_root() {
  [ "$EUID" -eq 0 ] || die "Este script debe ejecutarse como root."
}

check_command() {
  command -v "$1" &>/dev/null
}

# ── Config Galera ─────────────────────────────────────────────────────────────
GALERA_RELEASE="mariadb"
GALERA_CHART="oci://registry-1.docker.io/bitnamicharts/mariadb-galera"
GALERA_CHART_VERSION="16.0.1"
NODE_B="node-b-k3s-moodle"
SST_TIMEOUT=900          # margen para el SST (la copia puede tardar minutos)

# ── Lee wsrep_cluster_size desde mariadb-0 (devuelve un número; 0 si falla) ────
get_cluster_size() {
  local pw size
  pw=$(kubectl get secret mariadb-secrets -n "$MOODLE_NS" \
        -o jsonpath='{.data.mariadb-root-password}' 2>/dev/null | base64 -d 2>/dev/null) || true
  size=$(kubectl exec "${GALERA_RELEASE}-0" -n "$MOODLE_NS" -- \
          mariadb -u root -p"${pw}" -N \
          -e "SHOW STATUS LIKE 'wsrep_cluster_size';" 2>/dev/null \
          | awk '{print $2}') || true
  echo "${size:-0}"
}

# ── Verificación del estado base antes de escalar ─────────────────────────────
verify_base() {
  log_sub "Verificando estado base antes de escalar..."

  # Nodo B unido y Ready
  local b_ready
  b_ready=$(kubectl get node "$NODE_B" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || true
  [ "$b_ready" = "True" ] || die "El nodo B ($NODE_B) no está Ready. Corre el 07 primero."
  log_ok "Nodo B unido y Ready."

  # B etiquetado para storage (sin el label, el nodeSelector no programaría mariadb-1 ahí)
  if ! kubectl get nodes -l tesoem.edu.mx/longhorn-node=true \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -qw "$NODE_B"; then
    die "El nodo B no tiene el label tesoem.edu.mx/longhorn-node=true; mariadb-1 no caería en él."
  fi
  log_ok "Nodo B etiquetado para storage."

  # mariadb-0 (el donante del SST) sano
  local m0_ready
  m0_ready=$(kubectl get pod "${GALERA_RELEASE}-0" -n "$MOODLE_NS" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || true
  [ "$m0_ready" = "True" ] || die "${GALERA_RELEASE}-0 no está Ready; no puede ser donante del SST."
  log_ok "${GALERA_RELEASE}-0 Ready (donante listo)."

  # PV de B disponible para reclamar
  local pvb
  pvb=$(kubectl get pv mariadb-galera-pv-b -o jsonpath='{.status.phase}' 2>/dev/null) || true
  case "$pvb" in
    Available|Bound) log_ok "PV de B listo (estado: $pvb)." ;;
    *) die "mariadb-galera-pv-b no está disponible (estado: ${pvb:-inexistente})." ;;
  esac
}

# ── Escalado: 1 → 2 réplicas vía helm upgrade ─────────────────────────────────
scale_galera() {
  log_sub "Escalando Galera a 2 réplicas (helm upgrade)..."
  helm upgrade "$GALERA_RELEASE" "$GALERA_CHART" \
    --version "$GALERA_CHART_VERSION" \
    --namespace "$MOODLE_NS" \
    --reuse-values \
    --set replicaCount=2
  log_ok "helm upgrade aplicado (replicaCount=2). El chart creará mariadb-1 y disparará el SST."
}

# ── Verificar que el clúster quedó en 2 (bucle con timeout) ───────────────────
verify_galera_cluster() {
  log_sub "Esperando wsrep_cluster_size = 2 (el SST puede tardar varios minutos)..."
  local retries=0 max=90 size   # 90 * 10s = 900s
  while true; do
    size=$(get_cluster_size)
    if [ "$size" = "2" ]; then
      log_ok "Clúster Galera sincronizado: wsrep_cluster_size = 2"
      return 0
    fi
    retries=$((retries+1))
    if [ "$retries" -ge "$max" ]; then
      die "wsrep_cluster_size no llegó a 2 (último valor: ${size}). Revisa: kubectl logs ${GALERA_RELEASE}-1 -n ${MOODLE_NS}"
    fi
    echo -n "."
    sleep 10
  done
}
GARBD_IMAGE="localhost/galera-arbitrator:${GALERA_VERSION}"
# ── garbd: árbitro en la Pi (voto impar para el quórum) ───────────────────────
deploy_garbd() {
  log_sub "Desplegando garbd (árbitro) en la Pi..."

  # El clúster debe estar sano en 2 antes de añadir el árbitro
  local size
  size=$(get_cluster_size)
  [ "$size" = "2" ] || die "El clúster debe estar en 2 antes de garbd (actual: ${size})."

  cat > garbd-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: garbd
  namespace: ${MOODLE_NS}
  labels: { app: garbd }
spec:
  replicas: 1
  selector:
    matchLabels: { app: garbd }
  template:
    metadata:
      labels: { app: garbd }
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${NODE_PI}
      containers:
        - name: garbd
          image: ${GARBD_IMAGE}
          imagePullPolicy: Never
          env:
            - name: GALERA_GROUP
              value: "${GALERA_CLUSTER_NAME}"
            - name: GALERA_ADDRESS
              value: "gcomm://mariadb-headless.${MOODLE_NS}.svc.cluster.local:4567"
          ports:
            - { containerPort: 4567, name: gcomm }
          resources:
            requests: { cpu: "50m", memory: "64Mi" }
            limits:   { cpu: "200m", memory: "128Mi" }
EOF

  kubectl apply -f garbd-deployment.yaml
  log_ok "Deployment de garbd aplicado."

  log_sub "Esperando a que garbd se una (wsrep_cluster_size = 3)..."
  local retries=0 max=30
  while true; do
    size=$(get_cluster_size)
    if [ "$size" = "3" ]; then
      log_ok "garbd unido: wsrep_cluster_size = 3 (2 datos + árbitro)."
      return 0
    fi
    retries=$((retries+1))
    [ "$retries" -ge "$max" ] && die "garbd no se unió (size: ${size}). ¿Construyó el 05 la imagen en la Pi? Revisa: kubectl describe pod -l app=garbd -n ${MOODLE_NS}"
    echo -n "."; sleep 5
  done
}

# ── Orquestación ──────────────────────────────────────────────────────────────
main() {
  require_root
  check_command kubectl || die "kubectl no encontrado."
  check_command helm    || die "helm no encontrado."

  log_step "Expandir Galera a 2 nodos (A + B)"
  verify_base
  scale_galera

  log_sub "Esperando a que mariadb-1 se cree y una (rollout + SST)..."
  kubectl rollout status statefulset/"$GALERA_RELEASE" -n "$MOODLE_NS" \
    --timeout="${SST_TIMEOUT}s" \
    || log_warn "rollout status expiró; verifico wsrep directamente por si sigue en Joining."

  verify_galera_cluster

  log_step "Galera de 2 nodos operativo"
  log_info "Siguiente: garbd (árbitro) en la Pi para el voto impar."
  deploy_garbd
}

main "$@"
