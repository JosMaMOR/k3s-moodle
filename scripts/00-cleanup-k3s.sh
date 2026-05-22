#!/bin/bash
# ============================================================================
# 00-cleanup-k3s.sh
# Limpieza completa de K3s y entorno Moodle en AlmaLinux 9
#
# PROPÓSITO:
#   Elimina por completo una instalación previa de K3s, todos sus recursos
#   de Kubernetes, datos de Moodle/MariaDB/Redis del RAID, imágenes de
#   contenedores (containerd + podman) y configuraciones residuales.
#   Deja el sistema en estado limpio listo para una instalación fresca.
#
# USO:
#   chmod +x 00-cleanup-k3s.sh
#   ./00-cleanup-k3s.sh                    # limpieza estándar
#   ./00-cleanup-k3s.sh --keep-data        # conserva /moodlek3s (datos RAID)
#   ./00-cleanup-k3s.sh --keep-images      # conserva imágenes de podman
#   ./00-cleanup-k3s.sh --dry-run          # muestra qué haría sin ejecutar
#
# ADVERTENCIA:
#   Este script es DESTRUCTIVO. Elimina datos de MariaDB, archivos de Moodle
#   y toda la configuración de K3s. Úsalo solo en entornos de prueba o cuando
#   quieras empezar desde cero de forma intencionada.
#
# REQUISITOS:
#   - AlmaLinux 9
#   - Ejecutar como root
#   - K3s instalado previamente (si no está instalado, el script lo detecta)
#
# AUTOR: Infraestructura TESOEM
# VERSIÓN: 1.0
# ============================================================================

set -euo pipefail

# ── Colores para output ───────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Parámetros ────────────────────────────────────────────────────────────────
KEEP_DATA=false
KEEP_IMAGES=false
DRY_RUN=false
RAID_BASE="/moodlek3s"
NAMESPACE="moodle-prod"

for arg in "$@"; do
  case $arg in
    --keep-data)    KEEP_DATA=true ;;
    --keep-images)  KEEP_IMAGES=true ;;
    --dry-run)      DRY_RUN=true ;;
    --help)
      echo "Uso: $0 [--keep-data] [--keep-images] [--dry-run]"
      exit 0 ;;
    *)
      echo -e "${RED}Argumento desconocido: $arg${NC}"
      exit 1 ;;
  esac
done

# ── Funciones de utilidad ─────────────────────────────────────────────────────
log_step() { echo -e "\n${BLUE}${BOLD}[PASO]${NC} $1"; }
log_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
log_skip() { echo -e "  ${CYAN}→${NC} $1 ${CYAN}(omitido)${NC}"; }
log_err()  { echo -e "  ${RED}✗${NC} $1"; }

run() {
  # Ejecuta un comando o lo simula en dry-run
  if [ "$DRY_RUN" = true ]; then
    echo -e "  ${CYAN}[DRY-RUN]${NC} $*"
  else
    eval "$@" 2>/dev/null || true
  fi
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Este script debe ejecutarse como root.${NC}"
    exit 1
  fi
}

# ── Confirmación interactiva ──────────────────────────────────────────────────
confirm_execution() {
  echo ""
  echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}${BOLD}║          LIMPIEZA COMPLETA DE K3s + MOODLE                   ║${NC}"
  echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Este script ${RED}${BOLD}ELIMINARÁ${NC} de forma permanente:"
  echo ""
  echo -e "  ${RED}•${NC} K3s y todos sus binarios y servicios"
  echo -e "  ${RED}•${NC} Todos los recursos de Kubernetes (pods, PVs, PVCs, secrets...)"
  echo -e "  ${RED}•${NC} Imágenes de containerd (namespace k8s.io)"
  if [ "$KEEP_DATA" = false ]; then
    echo -e "  ${RED}•${NC} Datos de MariaDB en ${RAID_BASE}/mariadb"
    echo -e "  ${RED}•${NC} Datos de Redis en ${RAID_BASE}/redis"
    echo -e "  ${RED}•${NC} Archivos de Moodle en ${RAID_BASE}/moodle-html y moodle-data"
  else
    echo -e "  ${GREEN}•${NC} ${RAID_BASE}/ → CONSERVADO (--keep-data)"
  fi
  if [ "$KEEP_IMAGES" = false ]; then
    echo -e "  ${RED}•${NC} Imágenes de Podman del sistema"
  else
    echo -e "  ${GREEN}•${NC} Imágenes de Podman → CONSERVADAS (--keep-images)"
  fi
  echo ""
  if [ "$DRY_RUN" = true ]; then
    echo -e "  ${CYAN}MODO DRY-RUN: no se ejecutará nada, solo se mostrará.${NC}"
    echo ""
    return
  fi
  echo -ne "  ${YELLOW}${BOLD}¿Confirmas? Escribe 'LIMPIAR' para continuar: ${NC}"
  read -r CONFIRM
  if [ "$CONFIRM" != "LIMPIAR" ]; then
    echo -e "\n  ${GREEN}Operación cancelada.${NC}"
    exit 0
  fi
  echo ""
}

# ============================================================================
# INICIO
# ============================================================================
require_root
confirm_execution

echo ""
echo -e "${BOLD}Iniciando limpieza — $(date '+%Y-%m-%d %H:%M:%S')${NC}"

# ── PASO 1: Eliminar recursos de Kubernetes antes de desinstalar k3s ──────────
log_step "Eliminando recursos de Kubernetes en namespace ${NAMESPACE}..."

if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then

  # Escalar deployments a 0 para liberar PVCs limpliamente
  log_ok "Escalando workloads a 0 réplicas..."
  run "kubectl scale deployment moodle redis -n ${NAMESPACE} --replicas=0 2>/dev/null"
  run "kubectl scale statefulset mariadb -n ${NAMESPACE} --replicas=0 2>/dev/null"
  run "kubectl patch cronjob moodle-cron -n ${NAMESPACE} -p '{\"spec\":{\"suspend\":true}}' 2>/dev/null"

  # Esperar a que los pods terminen
  log_ok "Esperando terminación de pods..."
  run "kubectl wait --for=delete pod -l app=moodle -n ${NAMESPACE} --timeout=60s 2>/dev/null"
  run "kubectl wait --for=delete pod -l app=mariadb -n ${NAMESPACE} --timeout=60s 2>/dev/null"
  run "kubectl wait --for=delete pod -l app=redis -n ${NAMESPACE} --timeout=60s 2>/dev/null"

  # Eliminar todos los recursos del namespace en orden seguro
  log_ok "Eliminando Ingress y Middleware..."
  run "kubectl delete ingress --all -n ${NAMESPACE} 2>/dev/null"
  run "kubectl delete middleware.traefik.io --all -n ${NAMESPACE} 2>/dev/null"

  log_ok "Eliminando HPA y PDB..."
  run "kubectl delete hpa --all -n ${NAMESPACE} 2>/dev/null"
  run "kubectl delete pdb --all -n ${NAMESPACE} 2>/dev/null"

  log_ok "Eliminando CronJobs y Jobs..."
  run "kubectl delete cronjob --all -n ${NAMESPACE} 2>/dev/null"
  run "kubectl delete jobs --all -n ${NAMESPACE} 2>/dev/null"

  log_ok "Eliminando Deployments y StatefulSets..."
  run "kubectl delete deployment --all -n ${NAMESPACE} 2>/dev/null"
  run "kubectl delete statefulset --all -n ${NAMESPACE} 2>/dev/null"

  log_ok "Eliminando Services..."
  run "kubectl delete service --all -n ${NAMESPACE} 2>/dev/null"

  log_ok "Eliminando Secrets y ConfigMaps..."
  run "kubectl delete secret --all -n ${NAMESPACE} 2>/dev/null"
  run "kubectl delete configmap --all -n ${NAMESPACE} 2>/dev/null"

  log_ok "Eliminando PVCs..."
  run "kubectl delete pvc --all -n ${NAMESPACE} 2>/dev/null"

  log_ok "Eliminando PVs (cluster-scoped)..."
  run "kubectl delete pv mariadb-pv redis-pv moodle-html-pv moodle-data-pv 2>/dev/null"

  log_ok "Eliminando StorageClass local-raid..."
  run "kubectl delete storageclass local-raid 2>/dev/null"

  log_ok "Eliminando namespace ${NAMESPACE}..."
  run "kubectl delete namespace ${NAMESPACE} --grace-period=0 --force 2>/dev/null"

  log_ok "Recursos de Kubernetes eliminados."
else
  log_warn "kubectl no disponible o cluster no accesible — omitiendo limpieza de recursos."
fi

# ── PASO 2: Desinstalar K3s ───────────────────────────────────────────────────
log_step "Desinstalando K3s..."

if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
  log_ok "Ejecutando k3s-uninstall.sh..."
  run "/usr/local/bin/k3s-uninstall.sh"
  log_ok "K3s desinstalado."
elif [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
  log_ok "Ejecutando k3s-agent-uninstall.sh..."
  run "/usr/local/bin/k3s-agent-uninstall.sh"
  log_ok "K3s agent desinstalado."
else
  log_warn "Script de desinstalación de K3s no encontrado — limpieza manual..."

  # Detener y deshabilitar servicio
  run "systemctl stop k3s 2>/dev/null"
  run "systemctl disable k3s 2>/dev/null"
  run "rm -f /etc/systemd/system/k3s.service"
  run "systemctl daemon-reload"

  # Eliminar binarios
  run "rm -f /usr/local/bin/k3s"
  run "rm -f /usr/local/bin/kubectl"
  run "rm -f /usr/local/bin/crictl"
  run "rm -f /usr/local/bin/ctr"
  run "rm -f /usr/local/bin/k3s-uninstall.sh"
  run "rm -f /usr/local/bin/k3s-killall.sh"

  log_ok "Limpieza manual de K3s completada."
fi

# ── PASO 3: Limpiar directorios de K3s ───────────────────────────────────────
log_step "Limpiando directorios y configuraciones de K3s..."

K3S_DIRS=(
  "/etc/rancher"
  "/var/lib/rancher"
  "/var/lib/kubelet"
  "/var/log/pods"
  "/var/log/containers"
  "/run/k3s"
  "/run/flannel"
  "/tmp/k3s*"
)

for dir in "${K3S_DIRS[@]}"; do
  if [ -e "$dir" ] || ls $dir 2>/dev/null | grep -q .; then
    run "rm -rf $dir"
    log_ok "Eliminado: $dir"
  else
    log_skip "$dir no existe"
  fi
done

# Limpiar kubeconfig
run "rm -f /root/.kube/config"
run "rm -f /home/*/.kube/config 2>/dev/null"
log_ok "kubeconfig eliminado."

# ── PASO 4: Limpiar imágenes de containerd (namespace k8s.io) ────────────────
log_step "Limpiando imágenes de containerd (namespace k8s.io)..."

if command -v ctr &>/dev/null; then
  # Listar y eliminar todas las imágenes del namespace k8s.io
  IMAGES=$(ctr -n k8s.io images ls -q 2>/dev/null || true)
  if [ -n "$IMAGES" ]; then
    echo "$IMAGES" | while read -r img; do
      run "ctr -n k8s.io images rm '$img' 2>/dev/null"
      log_ok "Imagen eliminada: $img"
    done
  else
    log_warn "No se encontraron imágenes en containerd k8s.io"
  fi
else
  log_warn "ctr no disponible — omitiendo limpieza de imágenes containerd."
fi

# ── PASO 5: Limpiar imágenes de Podman ───────────────────────────────────────
log_step "Limpiando imágenes de Podman..."

if [ "$KEEP_IMAGES" = true ]; then
  log_skip "Imágenes de Podman conservadas (--keep-images)"
else
  if command -v podman &>/dev/null; then
    # Eliminar solo la imagen del proyecto si existe
    if podman images | grep -q "moodle-apache"; then
      run "podman rmi moodle-apache:5.1-k3s-raid --force 2>/dev/null"
      log_ok "Imagen moodle-apache:5.1-k3s-raid eliminada de Podman."
    else
      log_warn "Imagen moodle-apache:5.1-k3s-raid no encontrada en Podman."
    fi
    # Limpiar imágenes huérfanas (dangling)
    run "podman image prune -f 2>/dev/null"
    log_ok "Imágenes huérfanas de Podman eliminadas."
  else
    log_warn "Podman no instalado — omitiendo."
  fi
fi

# ── PASO 6: Eliminar datos del RAID ──────────────────────────────────────────
log_step "Limpiando datos de aplicación en ${RAID_BASE}..."

if [ "$KEEP_DATA" = true ]; then
  log_skip "Datos en ${RAID_BASE} conservados (--keep-data)"
else
  if [ -d "${RAID_BASE}" ]; then
    # Mostrar tamaño antes de borrar
    TOTAL_SIZE=$(du -sh "${RAID_BASE}" 2>/dev/null | cut -f1 || echo "desconocido")
    log_warn "Eliminando ${RAID_BASE} (tamaño: ${TOTAL_SIZE})..."
    run "rm -rf ${RAID_BASE}/mariadb"
    run "rm -rf ${RAID_BASE}/redis"
    run "rm -rf ${RAID_BASE}/moodle-html"
    run "rm -rf ${RAID_BASE}/moodle-data"
    # Conservar el directorio raíz pero vacío, no borrar el mount point
    log_ok "Datos de aplicación eliminados."
  else
    log_warn "${RAID_BASE} no existe — omitiendo."
  fi
fi

# ── PASO 7: Limpiar manifiestos generados ────────────────────────────────────
log_step "Limpiando manifiestos YAML generados..."

MANIFEST_DIR="/root/k3s-moodle/manifests"
if [ -d "${MANIFEST_DIR}" ]; then
  run "rm -rf ${MANIFEST_DIR}"
  log_ok "Directorio de manifiestos eliminado: ${MANIFEST_DIR}"
else
  log_skip "${MANIFEST_DIR} no existe"
fi

# ── PASO 8: Limpiar interfaces de red residuales ─────────────────────────────
log_step "Limpiando interfaces de red de K3s/flannel..."

# K3s crea interfaces de red que pueden quedar residuales
for iface in flannel.1 cni0 vxlan.calico tunl0; do
  if ip link show "$iface" &>/dev/null 2>&1; then
    run "ip link delete $iface 2>/dev/null"
    log_ok "Interfaz eliminada: $iface"
  fi
done

# Limpiar reglas de iptables de CNI
run "iptables -F FORWARD 2>/dev/null"
run "iptables -t nat -F 2>/dev/null"
log_ok "Reglas iptables de CNI limpiadas."

# ── PASO 9: Limpiar entradas de /etc/hosts si se añadieron ───────────────────
log_step "Revisando /etc/hosts..."

if grep -q "mcc.tesoem.edu.mx" /etc/hosts 2>/dev/null; then
  run "sed -i '/mcc.tesoem.edu.mx/d' /etc/hosts"
  log_ok "Entradas de mcc.tesoem.edu.mx eliminadas de /etc/hosts."
else
  log_skip "No hay entradas de moodle en /etc/hosts."
fi

# ── PASO 10: Verificación final ───────────────────────────────────────────────
log_step "Verificación del estado post-limpieza..."

echo ""
echo -e "  ${BOLD}Servicios:${NC}"
systemctl is-active k3s &>/dev/null     && log_err "k3s todavía activo" || log_ok "k3s detenido"
systemctl is-enabled k3s &>/dev/null    && log_warn "k3s todavía habilitado en systemd" || log_ok "k3s deshabilitado en systemd"

echo ""
echo -e "  ${BOLD}Binarios:${NC}"
[ -f /usr/local/bin/k3s ]    && log_warn "Binario k3s todavía presente" || log_ok "/usr/local/bin/k3s eliminado"
[ -f /usr/local/bin/kubectl ] && log_warn "kubectl todavía presente"    || log_ok "/usr/local/bin/kubectl eliminado"

echo ""
echo -e "  ${BOLD}Directorios:${NC}"
[ -d /etc/rancher ]     && log_warn "/etc/rancher todavía existe"    || log_ok "/etc/rancher eliminado"
[ -d /var/lib/rancher ] && log_warn "/var/lib/rancher todavía existe" || log_ok "/var/lib/rancher eliminado"

echo ""
echo -e "  ${BOLD}Datos RAID:${NC}"
if [ "$KEEP_DATA" = true ]; then
  log_skip "Verificación de datos omitida (--keep-data)"
else
  [ -d "${RAID_BASE}/mariadb" ]    && log_warn "${RAID_BASE}/mariadb todavía existe"    || log_ok "${RAID_BASE}/mariadb eliminado"
  [ -d "${RAID_BASE}/moodle-html" ] && log_warn "${RAID_BASE}/moodle-html todavía existe" || log_ok "${RAID_BASE}/moodle-html eliminado"
fi

# ── Resumen final ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║              LIMPIEZA COMPLETADA                             ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Sistema listo para instalación limpia."
echo -e "  Siguiente paso: ${BOLD}./01-prepare-almalinux9.sh${NC}"
echo ""
echo -e "  Completado — $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
