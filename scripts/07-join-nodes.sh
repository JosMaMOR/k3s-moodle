#!/bin/bash
# ======================================================
# 07-join-nodes.sh
# Preparacion de los nodos que van a ingresar al cluster
#
# PROPOSITO:
#   Abrir los puertos necesarios para la conexion al
#   cluster

set -euo pipefail

# Requisitos mínimos del sistema
MIN_RAM_MB=3600      # ~4 GB (dejamos margen)
MIN_CPU=2
MIN_DISK_GB=100
ARCH=$(uname -m)   # x86_64 o aarch64

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
  echo "  ║     PREPARACIÓN DE NODOS PARA INGRESAR AL CLUSTER            ║"
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

# ============================================================================
# PASO 0: VALIDACIÓN DE REQUISITOS
# ============================================================================
validate_requirements() {
  log_step "Validando requisitos del sistema"

  local ERRORS=0

  # Sistema operativo
  log_sub "Verificando SO..."
  if grep -qi "almalinux" /etc/os-release; then
    OS_VERSION=$(grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '"')
    log_ok "AlmaLinux detectado — versión: ${OS_VERSION}"
    if [[ "${OS_VERSION%%.*}" -lt 9 ]]; then
      log_warn "Se recomienda AlmaLinux 9.x — versión actual: ${OS_VERSION}"
    fi
  else
    log_warn "No es AlmaLinux — continuar bajo tu responsabilidad."
  fi

  # RAM
  log_sub "Verificando RAM..."
  TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
  if [ "${TOTAL_RAM_MB}" -ge "${MIN_RAM_MB}" ]; then
    log_ok "RAM disponible: ${TOTAL_RAM_MB} MB (mínimo: ${MIN_RAM_MB} MB)"
  else
    log_err "RAM insuficiente: ${TOTAL_RAM_MB} MB (mínimo: ${MIN_RAM_MB} MB)"
    ERRORS=$((ERRORS + 1))
  fi

  # CPU
  log_sub "Verificando CPU..."
  TOTAL_CPU=$(nproc)
  if [ "${TOTAL_CPU}" -ge "${MIN_CPU}" ]; then
    log_ok "CPUs disponibles: ${TOTAL_CPU} (mínimo: ${MIN_CPU})"
  else
    log_warn "CPUs disponibles: ${TOTAL_CPU} (recomendado: ${MIN_CPU}+)"
  fi

  # Espacio en disco
  log_sub "Verificando espacio en disco..."
  # Verificar tanto / como /moodlek3s si existe el mount point
  ROOT_DISK_GB=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
  log_ok "Espacio disponible en /: ${ROOT_DISK_GB} GB"
  if [ -d "${RAID_BASE}" ] || mountpoint -q "${RAID_BASE}" 2>/dev/null; then
    RAID_DISK_GB=$(df -BG "${RAID_BASE}" | awk 'NR==2{print $4}' | tr -d 'G')
    log_ok "Espacio disponible en ${RAID_BASE}: ${RAID_DISK_GB} GB"
  else
    log_info "${RAID_BASE} no montado aún — se creará como directorio local."
    if [ "${ROOT_DISK_GB}" -lt "${MIN_DISK_GB}" ]; then
      log_warn "Espacio en / puede ser insuficiente: ${ROOT_DISK_GB} GB (recomendado: ${MIN_DISK_GB}+ GB)"
    fi
  fi

  # Conectividad a internet
  log_sub "Verificando conectividad..."
  if curl -s --connect-timeout 5 https://get.k3s.io > /dev/null 2>&1; then
    log_ok "Acceso a internet disponible."
  else
    log_err "Sin acceso a https://get.k3s.io — necesario para instalar K3s."
    ERRORS=$((ERRORS + 1))
  fi

  if [ "${ERRORS}" -gt 0 ]; then
    die "Se encontraron ${ERRORS} error(es) críticos. Corrige los problemas antes de continuar."
  fi

  log_ok "Validación de requisitos completada."
}

# ============================================================================
# PASO 1: ACTUALIZACIÓN DEL SISTEMA
# ============================================================================
update_system() {
  log_step "Actualizando sistema operativo"

  log_sub "Actualizando repositorios y paquetes base..."
  # Actualización completa del sistema
  dnf update -y --nobest 2>&1 | tail -5
  log_ok "Sistema actualizado."
}

# ============================================================================
# PASO 4: PREPARACIÓN DEL SISTEMA PARA UNIRSE A LOS NODOS
# ============================================================================
prepare_node() {
  # ── 4.1: Deshabilitar Swap ──────────────────────────────────────────────────
  log_sub "Deshabilitando swap..."
  # Kubernetes requiere que swap esté deshabilitado. Con swap activo,
  # el scheduler de K8s no puede garantizar los límites de memoria de los pods.
  swapoff -a
  # Persistir en fstab: comentar todas las líneas de swap
  sed -i '/\bswap\b/s/^/#/' /etc/fstab
  # Verificar
  if [ "$(swapon --show | wc -l)" -eq 0 ]; then
    log_ok "Swap deshabilitado correctamente."
  else
    log_warn "Swap todavía activo — revisa /etc/fstab manualmente."
  fi

  # ── 4.5: SELinux en modo permisivo ──────────────────────────────────────────
  log_sub "Configurando SELinux..."
  # SELinux en modo Enforcing puede bloquear operaciones legítimas de K3s
  # como el montaje de volúmenes hostPath y la comunicación entre contenedores.
  # Modo Permissive: registra las violaciones pero no las bloquea.
  # Para producción real se recomienda configurar políticas SELinux específicas,
  # pero para laboratorio y pruebas, Permissive es el equilibrio correcto.
  SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Disabled")
  if [ "${SELINUX_STATUS}" = "Enforcing" ]; then
    setenforce 0
    log_warn "SELinux cambiado de Enforcing a Permissive (activo en esta sesión)."
  else
    log_info "SELinux está en modo: ${SELINUX_STATUS}"
  fi

  # Persistir en /etc/selinux/config
  if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    sed -i 's/^SELINUX=disabled/SELINUX=permissive/' /etc/selinux/config
    log_ok "SELinux configurado como permissive de forma persistente."
  fi

  # ── 4.6: Firewall ───────────────────────────────────────────────────────────
  log_sub "Configurando firewall..."

  if systemctl is-active --quiet firewalld; then
     # 6443/tcp   → API server (Kubernetes)
     # 2379/tcp   → etcd cliente
     # 2380/tcp   → etcd peer (comunicación entre miembros etcd) ← CRÍTICO para HA
     # 8472/udp   → Flannel VXLAN (red de pods)
     # 10250/tcp  → kubelet (métricas, logs, exec)
     # 51820/udp  → Flannel Wireguard IPv4 (Opcional)

    firewall-cmd --permanent --add-port=6443/tcp    # K3s API
    firewall-cmd --permanent --add-port=2379/tcp    # etcd cliente
    firewall-cmd --permanent --add-port=2380/tcp    # etcd peer
    firewall-cmd --permanent --add-port=8472/udp    # Flannel VXLAN
    firewall-cmd --permanent --add-port=10250/tcp   # Kubelet
    firewall-cmd --permanent --add-port=51820/udp   # Flannel Wireguard
    firewall-cmd --permanent --add-masquerade       # NAT para pods

    # Zona de confianza para la interfaz de loopback y red interna de pods
    firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16  # pods
    firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16  # services
    firewall-cmd --permanent --zone=trusted --add-interface=lo

    # Puertos de Longhorn (comunicación entre nodos del clúster)
    # 9500-9503/tcp: Longhorn Manager (API interna) + Engine (por volumen)
    # 2049/tcp:      NFS — Longhorn lo usa internamente para volúmenes RWX
    # 111/tcp:       RPC portmapper, requerido por NFS
    # 20048/tcp:     mountd de NFS
    firewall-cmd --permanent --add-port=9500-9503/tcp  # Longhorn Manager + Engine
    firewall-cmd --permanent --add-port=2049/tcp        # NFS (RWX)
    firewall-cmd --permanent --add-port=111/tcp         # RPC portmapper
    firewall-cmd --permanent --add-port=20048/tcp       # NFS mountd
    
    firewall-cmd --reload
    log_ok "Firewall configurado con puertos de K3s, Moodle y Longhorn."
  else
    log_warn "firewalld no está activo — omitiendo configuración de firewall."
    log_info "Si usas nftables o iptables directamente, abre los puertos: 6443/tcp, 80/tcp, 443/tcp, 8080/tcp, 8443/tcp"
  fi
}

node_join(){
    mkdir -p /etc/rancher/k3s
    cat > /etc/rancher/k3s/config.yaml << EOF
# Generado por 07-join-nodes.sh — config del nodo que se une como control-plane
token: "${NODE_TOKEN}"
server: "https://${NODE_A_IP}:6443"
node-ip: "$(hostname -I | awk '{print $1}')"
tls-san:
  - "${CLUSTER_VIP}"
  - "${MOODLE_DOMAIN}"
EOF

    if [ "${ARCH}" = "aarch64" ]; then
	# Raspberry Pi OS no habilita cgroup de memoria por defecto; K3s lo requiere
	CMDLINE="/boot/firmware/cmdline.txt"
	[ -f "${CMDLINE}" ] || CMDLINE="/boot/cmdline.txt"   # ubicación varía por versión
	if ! grep -q "cgroup_memory=1" "${CMDLINE}"; then
	    sed -i 's/$/ cgroup_memory=1 cgroup_enable=memory/' "${CMDLINE}"
	    log_warn "cgroups habilitados en ${CMDLINE} — REQUIERE REINICIO antes de unir la Pi"
	    log_warn "Reinicia la Pi y vuelve a correr el script."
	    exit 0   # salir limpio; tras reboot se reanuda
	fi
    fi
    
    # Inicializa la conexion como control-pane
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
  sh -s - server
}



main(){
    require_root
    show_banner
    validate_requirements
    update_system
    prepare_node
    node_join
}

main "$@"
