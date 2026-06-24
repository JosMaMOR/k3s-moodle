#!/bin/bash
# ======================================================
# 08-form-HA-cluster.sh 
# Formacion de alta disponibilidad en el cluster
#
# PROPOSITO:
#   Activar funciones de alta disponibilidad y generar
# replicas

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

# ── Cargar configuración de red del clúster ───────────────────────────────────
# cluster.env define VIP, IPs de nodos y dominio. Permite override por entorno.
# ademas de definir version exacta de k3s.
CLUSTER_ENV="./cluster.env"
if [ -f "${CLUSTER_ENV}" ]; then
  source "${CLUSTER_ENV}"
  log_info "cluster.env cargado: VIP=${CLUSTER_VIP}, nodo=${NODE_A_IP}"
else
  log_err "No se encontró ${CLUSTER_ENV} — requerido para configurar la red del clúster."
  exit 1
fi

# ── Banner inicial ────────────────────────────────────────────────────────────
show_banner() {
  echo ""
  echo -e "${BLUE}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║     FORMACIÓN DE ALTA DISPONIBILIDAD EN EL CLUSTER           ║"
  echo "  ║     TESOEM — Plataforma Educativa                            ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  Fecha:   $(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "  Host:    $(hostname -f 2>/dev/null || hostname)"
  echo -e "  IP:      $(hostname -I | awk '{print $1}')"
  echo -e "  SO:      $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
  echo -e "  Kernel:  $(uname -r)"
  echo ""
}

# ── Verificar membresía del clúster y quórum etcd ─────────────────────────────
# Estar "Ready" en K8s NO implica ser miembro votante de etcd. Comprobamos ambas:
# (a) los 3 nodos Ready, (b) los 3 etiquetados como miembros de etcd.
verify_etcd_members() {
  log_sub "Verificando membresía del clúster y quórum etcd"
  local expected=3
  local ready etcd_members

  ready=$(kubectl get nodes --no-headers 2>/dev/null \
    | awk '$2=="Ready"{c++} END{print c+0}' || echo 0)
  [ "${ready}" -eq "${expected}" ] \
    || die "Se esperaban ${expected} nodos Ready, hay ${ready}. Revisa que los 3 nodos se hayan unido al clúster."
  log_ok "${ready}/${expected} nodos en estado Ready"

  etcd_members=$(kubectl get nodes -l node-role.kubernetes.io/etcd=true \
    --no-headers 2>/dev/null | wc -l || echo 0)
  [ "${etcd_members}" -eq "${expected}" ] \
    || die "Se esperaban ${expected} miembros de etcd, hay ${etcd_members}. Algún nodo se unió como worker, no como server/control-plane."
  log_ok "${etcd_members}/${expected} nodos son miembros del quórum etcd"
}

# ── Generar y aplicar el RBAC de kube-vip ─────────────────────────────────────
# Va ANTES del DaemonSet: como se genera con --inCluster, kube-vip usa un
# ServiceAccount con permisos. Sin el RBAC aplicado, los pods entran en CrashLoop.
generate_rbac() {
  log_sub "Generando y aplicando RBAC para kube-vip"
  local rbac_file="${MANIFEST_DIR}/rbac-manifests.yaml"

  cat > "${rbac_file}" <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-vip
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  name: system:kube-vip-role
rules:
  - apiGroups: [""]
    resources: ["services", "services/status", "nodes", "endpoints"]
    verbs: ["list", "get", "watch", "update"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["list", "get", "watch", "update", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-vip-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-vip-role
subjects:
  - kind: ServiceAccount
    name: kube-vip
    namespace: kube-system
EOF

  log_ok "RBAC generado en ${rbac_file}"
  kubectl apply -f "${rbac_file}" || die "Falló al aplicar el RBAC de kube-vip."
  log_ok "RBAC aplicado en el clúster"
}

# ── Desplegar kube-vip como DaemonSet (modo ARP) ──────────────────────────────
deploy_kube_vip() {
  log_sub "Desplegando kube-vip (DaemonSet, modo ARP, VIP ${CLUSTER_VIP})"
  local ds_file="${MANIFEST_DIR}/kube-vip-daemonset.yaml"

  : "${KVVERSION:?KVVERSION no está definida en cluster.env}"
  : "${CLUSTER_VIP:?CLUSTER_VIP no está definida en cluster.env}"

  log_info "Descargando imagen ghcr.io/kube-vip/kube-vip:${KVVERSION}"
  # k3s trae su propio containerd; 'k3s ctr' ya apunta a su socket y namespace.
  k3s ctr image pull "ghcr.io/kube-vip/kube-vip:${KVVERSION}" \
    || die "No se pudo descargar la imagen de kube-vip."

  log_info "Generando manifiesto del DaemonSet en ${ds_file}"
  k3s ctr run --rm --net-host "ghcr.io/kube-vip/kube-vip:${KVVERSION}" vip \
    /kube-vip manifest daemonset \
      --interface "" \
      --address "${CLUSTER_VIP}" \
      --inCluster \
      --taint \
      --controlplane \
      --arp \
      --leaderElection \
    > "${ds_file}" || die "Falló la generación del manifiesto de kube-vip."

  # --- Corrección crítica del vip_interface ---
  # El generador a veces escribe `value: autodetect`, que en runtime (v1.2.0) se
  # toma como nombre LITERAL de interfaz y falla con "Link not found".
  # La autodetección real (cada nodo elige su interfaz por su ruta por defecto:
  # br0 en A, eth0 en B/Pi) se activa dejando el valor VACÍO. Lo forzamos aquí.
  if grep -qE 'value:[[:space:]]*autodetect' "${ds_file}"; then
    log_warn "vip_interface salió como 'autodetect' — corrigiendo a vacío"
    sed -i -E 's/(value:)[[:space:]]*autodetect/\1 ""/' "${ds_file}"
    log_ok 'vip_interface corregido a "" (autodetección por nodo)'
  else
    log_ok "vip_interface correcto (sin 'autodetect' literal)"
  fi

  kubectl apply -f "${ds_file}" || die "Falló al aplicar el DaemonSet de kube-vip."
  log_ok "DaemonSet de kube-vip aplicado"
}

# ── Verificar kube-vip operativo (bucle de reintento con timeout) ─────────────
# "Running" no es "funcionando". Validamos 3 cosas end-to-end y reintentamos,
# porque tras el apply hay una carrera entre el rollout del DaemonSet y la VIP:
#   (1) pods 1/1 Running (los 3 control-plane)
#   (2) líder electo (holderIdentity no vacío)
#   (3) API server responde por la VIP (401/200 = sano; 000/503 = no)
verify_kube_vip() {
  log_sub "Verificando que kube-vip esté operativo"
  local expected=3 timeout=120 interval=5 elapsed=0
  local ds_ready lease_holder http_code

  while true; do
    ds_ready=$(kubectl -n kube-system get pods \
      -l app.kubernetes.io/name=kube-vip-ds --no-headers 2>/dev/null \
      | awk '$2=="1/1" && $3=="Running"{c++} END{print c+0}' || echo 0)

    lease_holder=$(kubectl -n kube-system get lease plndr-cp-lock \
      -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || echo "")

    http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
      "https://${CLUSTER_VIP}:6443/livez" 2>/dev/null || echo "000")

    if [ "${ds_ready}" -eq "${expected}" ] && [ -n "${lease_holder}" ] \
       && { [ "${http_code}" = "401" ] || [ "${http_code}" = "200" ]; }; then
      log_ok "kube-vip operativo: ${ds_ready}/${expected} pods, líder='${lease_holder}', VIP HTTP ${http_code}"
      return 0
    fi

    if [ "${elapsed}" -ge "${timeout}" ]; then
      log_err "kube-vip no quedó operativo tras ${timeout}s."
      log_info "Estado final: pods=${ds_ready}/${expected}, líder='${lease_holder:-<vacío>}', VIP=${http_code}"
      die "Revisa: kubectl -n kube-system logs -l app.kubernetes.io/name=kube-vip-ds --tail=50"
    fi

    log_info "Esperando kube-vip... (pods=${ds_ready}/${expected}, líder='${lease_holder:-—}', VIP=${http_code}) [${elapsed}s/${timeout}s]"
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done
}

# ── 2. Asegurar HA de almacenamiento: cada volumen con 2 réplicas en A y B ─────
# Con el SC ya en 2, los volúmenes nacen queriendo 2 y Longhorn los sana al unir
# B. Aquí (a) reforzamos el deseo en cada volumen por idempotencia —no-op si ya
# es 2— y (b) ESPERAMOS la convergencia: robustness=healthy y réplicas en 2 nodos.
ensure_longhorn_ha() {
  log_sub "Asegurando 2 réplicas por volumen, distribuidas en A y B"
  local pvc vol robustness rep_nodes timeout=300 interval=10 elapsed

  for pvc in ${MOODLE_PVCS}; do
    vol=$(kubectl -n "${MOODLE_NS}" get pvc "${pvc}" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
    [ -n "${vol}" ] || die "No se pudo resolver el volumen del PVC ${pvc}."
    log_info "PVC ${pvc} → volumen ${vol}"

    # (a) Red de seguridad idempotente: fija numberOfReplicas=2 (no-op si ya está)
    kubectl -n longhorn-system patch volumes.longhorn.io "${vol}" \
      --type=merge -p '{"spec":{"numberOfReplicas":2}}' >/dev/null \
      || die "No se pudo fijar numberOfReplicas=2 en ${vol}."

    # (b) Esperar convergencia a healthy con réplicas en 2 nodos distintos
    elapsed=0
    while true; do
      robustness=$(kubectl -n longhorn-system get volumes.longhorn.io "${vol}" \
        -o jsonpath='{.status.robustness}' 2>/dev/null)
      rep_nodes=$(kubectl -n longhorn-system get replicas.longhorn.io \
        -l longhornvolume="${vol}" -o jsonpath='{range .items[*]}{.spec.nodeID}{"\n"}{end}' 2>/dev/null \
        | sort -u | grep -c .)

      if [ "${robustness}" = "healthy" ] && [ "${rep_nodes}" -eq 2 ]; then
        log_ok "${vol}: healthy, réplicas en ${rep_nodes} nodos (A y B)."
        break
      fi
      if [ "${elapsed}" -ge "${timeout}" ]; then
        die "${vol} no convergió a HA en ${timeout}s (robustness=${robustness:-?}, nodos=${rep_nodes}). Revisa: kubectl -n longhorn-system get volumes.longhorn.io ${vol}"
      fi
      log_info "Esperando reconstrucción de ${vol}... (robustness=${robustness:-—}, nodos=${rep_nodes}/2) [${elapsed}s/${timeout}s]"
      sleep "${interval}"; elapsed=$((elapsed + interval))
    done
  done
  log_ok "Almacenamiento en HA: todos los volúmenes con réplica en A y B."
}

# ── 3. Escalar Moodle a HA (HPA + réplicas) ───────────────────────────────────
# El orden importa: esto va DESPUÉS de ensure_longhorn_ha, porque los 3 pods de
# Moodle cuelgan del volumen RWX, que debe estar servido en HA antes de escalar.
scale_moodle() {
  log_sub "Escalando Moodle a ${MOODLE_TARGET_REPLICAS} réplicas (HA)"

  # El HPA ya existe (lo crea el 06 con minReplicas:1). Subimos el piso a 3.
  kubectl patch hpa "${MOODLE_HPA}" -n "${MOODLE_NS}" \
    --type=merge -p "{\"spec\":{\"minReplicas\":${MOODLE_TARGET_REPLICAS}}}" \
    || die "No se pudo patchear el HPA ${MOODLE_HPA}."
  log_ok "HPA: minReplicas=${MOODLE_TARGET_REPLICAS} (maxReplicas se respeta del manifiesto)."

  # scale da el arranque inmediato a 3; el HPA lo sostiene a partir de ahí.
  kubectl scale deployment "${MOODLE_DEPLOY}" -n "${MOODLE_NS}" \
    --replicas=${MOODLE_TARGET_REPLICAS} || die "Falló el scale del deployment."

  log_info "Esperando rollout de las ${MOODLE_TARGET_REPLICAS} réplicas (hasta 300s)..."
  kubectl rollout status deployment/"${MOODLE_DEPLOY}" -n "${MOODLE_NS}" --timeout=300s \
    || die "El rollout de Moodle no completó."

  # Verificación: 3 pods Running y en qué nodos cayeron (el podAntiAffinity
  # preferred reparte; con 2 nodos y 3 réplicas, una se dobla — es esperado).
  local running
  running=$(kubectl -n "${MOODLE_NS}" get pods -l app=moodle --no-headers 2>/dev/null \
    | awk '$3=="Running"{c++} END{print c+0}')
  [ "${running}" -eq "${MOODLE_TARGET_REPLICAS}" ] \
    || die "Se esperaban ${MOODLE_TARGET_REPLICAS} pods Running, hay ${running}."
  log_ok "${running} pods de Moodle Running. Distribución:"
  kubectl -n "${MOODLE_NS}" get pods -l app=moodle -o wide --no-headers | awk '{print "      "$1" → "$7}'
}

# ── Resumen final de HA: dónde quedó cada réplica y cada pod ───────────────────
# Solo lectura. Imprime, al cierre del script, la distribución real por nodo para
# que el output deje evidencia visible de que el almacenamiento y la app quedaron
# repartidos en A y B (y nada en la Pi).
show_ha_summary() {
  echo ""
  echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}${BOLD}  RESUMEN DE ALTA DISPONIBILIDAD — DISTRIBUCIÓN POR NODO${NC}"
  echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${NC}"

  # 1. Réplicas de almacenamiento (Longhorn): una por nodo, por volumen
  log_sub "Réplicas de almacenamiento (Longhorn)"
  local pvc vol
  for pvc in ${MOODLE_PVCS}; do
    vol=$(kubectl -n "${MOODLE_NS}" get pvc "${pvc}" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
    echo -e "  ${CYAN}${BOLD}${pvc}${NC}  (${vol})"
    kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume="${vol}" \
      -o custom-columns='  RÉPLICA:.metadata.name,NODO:.spec.nodeID,ESTADO:.status.currentState' \
      --no-headers 2>/dev/null | sed 's/^/    /'
  done

  # 2. Pods de Moodle: cada réplica y su nodo
  log_sub "Pods de Moodle"
  kubectl -n "${MOODLE_NS}" get pods -l app=moodle \
    -o custom-columns='  POD:.metadata.name,NODO:.spec.nodeName,ESTADO:.status.phase' \
    --no-headers 2>/dev/null | sed 's/^/    /'

  # 3. Vista compacta de salud de los volúmenes
  log_sub "Salud de los volúmenes"
  kubectl -n longhorn-system get volumes.longhorn.io \
    -o custom-columns='  VOLUMEN:.metadata.name,ESTADO:.status.state,ROBUSTEZ:.status.robustness,RÉPLICAS:.spec.numberOfReplicas' \
    --no-headers 2>/dev/null | sed 's/^/    /'

  echo ""
  log_ok "Distribución verificada. El clúster está en alta disponibilidad."

  echo ""
  echo "========================================================="
  echo "Próximo paso: Inicializar Galera y Maxscale"
  echo "Ejecute el script 09-galera-maxscale"
  echo "========================================================="
  echo ""
}

main(){
require_root
show_banner
verify_etcd_members
generate_rbac
deploy_kube_vip
verify_kube_vip
verify_storage_baseline
ensure_longhorn_ha
scale_moodle
show_ha_summary
}

main "$@"
