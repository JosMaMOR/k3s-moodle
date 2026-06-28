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
RAID_BASE="${RAID_BASE:-/moodlek3s}"
ARCH=$(uname -m)   # x86_64 o aarch64
NODE_NAME="node-b-k3s-moodle"
MANIFEST_DIR="/root/k3s-moodle/manifests"
SCRIPTS_DIR="/root/k3s-moodle/scripts"

# STORAGE_NODE: indica si este nodo forma parte del PLANO DE DATOS
#   (réplicas de Longhorn y/o nodo de datos de Galera).
#     true  → servidores físicos A y B (x86_64): guardan datos.
#     false → Raspberry Pi (aarch64): árbitro puro (etcd + garbd), SIN datos.
#   La Pi se EXCLUYE de Longhorn: la supervivencia del dato la dan las réplicas
#   en A y B, no el longhorn-manager. Por eso la Pi no necesita iscsi/nfs, ni
#   módulos iSCSI, ni discos de BD — y libera CPU para garbd/Galera/MaxScale.
STORAGE_NODE=true

if [ "${ARCH}" = "aarch64" ]; then
    NODE_NAME="raspberry-k3s-moodle"
    STORAGE_NODE=false
fi

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
  echo -e "  Rol:     STORAGE_NODE=${STORAGE_NODE} (true=plano de datos / false=árbitro)"
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
  if [ "${ROOT_DISK_GB}" -lt "${MIN_DISK_GB}" ]; then
    log_warn "Espacio en / puede ser insuficiente: ${ROOT_DISK_GB} GB (recomendado: ${MIN_DISK_GB}+ GB)"
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

prepare_storage() {
  log_step "Preparando almacenamiento en ${RAID_BASE}"

  # Las carpetas de datos locales (MariaDB/Redis) y la preparación del disco
  # SOLO aplican a nodos del plano de datos. La Pi (árbitro) no guarda datos.
  if [ "${STORAGE_NODE}" = "true" ]; then
    # Crear el directorio base si no existe
    # Si /moodlek3s es un punto de montaje de RAID, los directorios se crean dentro.
    # Si es un directorio local (lab/pruebas), también funciona.
    if ! mountpoint -q "${RAID_BASE}" 2>/dev/null; then
      log_warn "${RAID_BASE} no es un punto de montaje — usando directorio local."
      log_info "Para producción, monta tu RAID en ${RAID_BASE} antes de ejecutar este script."
    else
      log_ok "${RAID_BASE} es un punto de montaje activo."
      RAID_INFO=$(df -h "${RAID_BASE}" | awk 'NR==2')
      log_info "Info del RAID: ${RAID_INFO}"
    fi

    # Crear estructura de directorios
    log_sub "Creando estructura de directorios..."
    mkdir -p "${RAID_BASE}/galera"
    mkdir -p "${RAID_BASE}/redis"
    log_ok "Directorios creados en ${RAID_BASE}/"

    # Permisos — deben coincidir con los UIDs de los contenedores:
    #   uid 999 → mariadb:lts (usuario mysql dentro del contenedor)
    #   uid 999 → redis:7-alpine (usuario redis dentro del contenedor)
    #   uid 1001 → moodle-apache (usuario www-data dentro del contenedor)
    log_sub "Configurando permisos..."
    chmod -R 750       "${RAID_BASE}/galera"

    chown -R 999:999   "${RAID_BASE}/redis"
    chmod -R 750       "${RAID_BASE}/redis"

    log_ok "Permisos configurados."
    ls -la "${RAID_BASE}/"
  else
    log_info "Nodo árbitro (${NODE_NAME}): se omiten carpetas de datos locales."
    log_info "garbd no almacena datos — solo vota en el quórum de Galera."
  fi
}

# ============================================================================
# PASO 4: PREPARACIÓN DEL SISTEMA PARA UNIRSE A LOS NODOS
# ============================================================================
prepare_node() {

  # ── Dependencias de Longhorn — SOLO en nodos de almacenamiento ──────────────
  # La Pi se excluye de Longhorn, así que no necesita iscsi/nfs ni sus módulos.
  if [ "${STORAGE_NODE}" = "true" ]; then
    log_sub "Instalando dependencias de Longhorn..."
    # iscsi-initiator-utils: daemon y cliente iSCSI. Longhorn monta sus volúmenes
    #   de bloque vía iSCSI en cada nodo worker. Sin esto los PVCs no pueden montarse.
    # nfs-utils: cliente NFS requerido para volúmenes RWX (ReadWriteMany).
    #   Longhorn implementa RWX internamente con NFS. Moodle lo necesita para que
    #   múltiples pods lean y escriban el mismo volumen simultáneamente.
    # cryptsetup: herramienta de cifrado LUKS/dm-crypt. El instalador de Longhorn
    #   la requiere aunque no uses cifrado activamente en los volúmenes.
    # device-mapper: framework del kernel para volúmenes lógicos y mapeo de
    #   dispositivos. Generalmente ya viene en AlmaLinux 9, pero lo aseguramos.
    # util-linux: provee blkid, lsblk, findmnt — comandos que Longhorn Manager
    #   ejecuta para inspeccionar discos y puntos de montaje del nodo.
    dnf install -y \
      iscsi-initiator-utils \
      nfs-utils \
      cryptsetup \
      device-mapper \
      util-linux \
      2>&1 | tail -5
    log_ok "Dependencias de Longhorn instaladas."
  else
    log_sub "Nodo árbitro (${NODE_NAME}): se OMITEN dependencias de Longhorn"
    log_info "La Pi se excluye de Longhorn (iscsi/nfs no necesarios)."
    log_info "Los datos siguen vivos por las réplicas en A y B; la Pi aporta el voto etcd."
  fi

    # ── Set Hostname ────────────────────────────────────────────────────────────────
  log_sub "Configurando hostname..."
  CURRENT_HOSTNAME=$(hostname)
  if [ "${CURRENT_HOSTNAME}" != "${NODE_NAME}" ]; then
    hostnamectl set-hostname "${NODE_NAME}"
    log_ok "Hostname configurado: ${NODE_NAME}"
    log_info "Era: ${CURRENT_HOSTNAME} → Ahora: ${NODE_NAME}"
    log_info "Reinicio manual necesario para aplicar cambios en el hostname."
    exit 0
  else
    log_ok "Hostname ya es correcto: ${NODE_NAME}"
  fi

  # Asegurar que el hostname resuelve localmente
  if ! grep -q "${NODE_NAME}" /etc/hosts; then
    echo "127.0.0.1  ${NODE_NAME}" >> /etc/hosts
    log_ok "Hostname añadido a /etc/hosts."
  fi

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

  # ── 4.2b: Módulos requeridos por Longhorn — SOLO en nodos de almacenamiento ─
  # La Pi no corre Longhorn, así que no necesita estos módulos ni iscsid.
  if [ "${STORAGE_NODE}" = "true" ]; then
    # iscsi_tcp: implementa iSCSI sobre TCP en el kernel.
    #   Longhorn monta cada volumen de bloque en los nodos vía iSCSI.
    #   Sin este módulo, los pods que pidan un PVC de Longhorn no pueden arrancar.
    # dm_crypt: cifrado de dispositivos de bloque.
    #   Lo requiere cryptsetup y el propio Longhorn para encriptación de volúmenes.
    cat >> /etc/modules-load.d/k3s.conf << 'EOF'
# Módulos requeridos por Longhorn
# iscsi_tcp: iSCSI sobre TCP para montaje de volúmenes de bloque
# dm_crypt:  cifrado de dispositivos de bloque
iscsi_tcp
dm_crypt
EOF

    modprobe iscsi_tcp 2>/dev/null && log_ok "Módulo iscsi_tcp cargado." || log_warn "iscsi_tcp no se pudo cargar — puede estar integrado en el kernel."
    modprobe dm_crypt  2>/dev/null && log_ok "Módulo dm_crypt cargado."  || log_warn "dm_crypt no se pudo cargar — puede estar integrado en el kernel."

    # iscsid: daemon que gestiona las sesiones iSCSI activas en el nodo.
    # Debe estar corriendo antes de que Longhorn intente montar cualquier volumen.
    systemctl enable --now iscsid 2>/dev/null \
      && log_ok "iscsid habilitado y activo." \
      || log_warn "iscsid no se pudo iniciar — verifica con: systemctl status iscsid"
  else
    log_info "Nodo árbitro: se omiten módulos iSCSI (iscsi_tcp/dm_crypt) e iscsid."
  fi

  # ── 4.3: Parámetros sysctl para Kubernetes ──────────────────────────────────
  log_sub "Configurando parámetros del kernel (sysctl)..."
  cat > /etc/sysctl.d/99-k3s.conf << 'EOF'
# ── Parámetros del kernel para K3s / Kubernetes ──────────────────────────────
#
# net.bridge.bridge-nf-call-iptables = 1
#   Los puentes de red envían tráfico a iptables para inspección.
#   Necesario para las políticas de red de Kubernetes (NetworkPolicy).
#
# net.bridge.bridge-nf-call-ip6tables = 1
#   Lo mismo para IPv6 (necesario aunque no uses IPv6, evita warnings).
#
# net.ipv4.ip_forward = 1
#   Habilita el reenvío de paquetes IP entre interfaces.
#   Necesario para que los pods puedan comunicarse con el exterior.
#
# fs.inotify.max_user_watches = 524288
#   Máximo de archivos que inotify puede monitorear por usuario.
#   K3s y los pods usan inotify para detectar cambios en ConfigMaps/Secrets.
#
# fs.inotify.max_user_instances = 512
#   Máximo de instancias inotify por usuario.
#
# vm.max_map_count = 262144
#   Máximo de áreas de memoria mapeadas por proceso.
#   Requerido por Elasticsearch y algunas aplicaciones Java; Moodle no lo
#   necesita estrictamente pero evita warnings en el sistema.
#
# kernel.panic = 10
#   Reinicia automáticamente el sistema 10 segundos después de un kernel panic.
#   Importante en producción para recuperación automática.
#
# kernel.panic_on_oops = 1
#   Genera kernel panic ante errores graves del kernel (oops).

net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv6.conf.all.forwarding        = 1
fs.inotify.max_user_watches         = 524288
fs.inotify.max_user_instances       = 512
fs.file-max                         = 1048576
vm.max_map_count                    = 262144
kernel.panic                        = 10
kernel.panic_on_oops                = 1
EOF

  sysctl --system 2>&1 | grep -E "Applying|net\.|fs\.|vm\.|kernel\." | tail -15
  log_ok "Parámetros sysctl aplicados."

  # ── 4.4: Límites del sistema (ulimits) ──────────────────────────────────────
  log_sub "Configurando límites del sistema..."
  # K3s y los pods de Moodle/MariaDB necesitan muchos archivos abiertos
  # simultáneamente. Los límites por defecto de AlmaLinux son demasiado bajos.
  cat > /etc/security/limits.d/99-k3s.conf << 'EOF'
# Límites del sistema para K3s / contenedores
# Formato: <dominio> <tipo> <ítem> <valor>
#   *     = aplica a todos los usuarios
#   soft  = límite suave (advertencia, puede aumentarse hasta hard)
#   hard  = límite duro (máximo absoluto)
#   nofile = número máximo de archivos abiertos por proceso
#   nproc  = número máximo de procesos por usuario
#   memlock = memoria bloqueada en RAM (bytes), unlimited para EBPF de K3s

*         soft    nofile    1048576
*         hard    nofile    1048576
*         soft    nproc     65536
*         hard    nproc     65536
root      soft    nofile    1048576
root      hard    nofile    1048576
root      soft    nproc     unlimited
root      hard    nproc     unlimited
*         soft    memlock   unlimited
*         hard    memlock   unlimited
EOF
  log_ok "Límites del sistema configurados."

  # Aplicar límites a la sesión actual
  ulimit -n 1048576 2>/dev/null || true


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

    # Puertos de Longhorn — SOLO en nodos de almacenamiento (la Pi no sirve Longhorn)
    # 9500-9503/tcp: Longhorn Manager (API interna) + Engine (por volumen)
    # 2049/tcp:      NFS — Longhorn lo usa internamente para volúmenes RWX
    # 111/tcp:       RPC portmapper, requerido por NFS
    # 20048/tcp:     mountd de NFS
    # NOTA: verifica el rango de puertos del instance-manager para TU versión de
    #       Longhorn — varía entre versiones y, si se queda corto, la réplica
    #       entre A y B podría fallar (que es justo tu HA de almacenamiento).
    if [ "${STORAGE_NODE}" = "true" ]; then
      firewall-cmd --permanent --add-port=9500-9503/tcp  # Longhorn Manager + Engine
      firewall-cmd --permanent --add-port=2049/tcp        # NFS (RWX)
      firewall-cmd --permanent --add-port=111/tcp         # RPC portmapper
      firewall-cmd --permanent --add-port=20048/tcp       # NFS mountd
    else
      log_info "Nodo árbitro: se omiten los puertos de Longhorn/NFS en el firewall."
    fi

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
	# En Raspberry Pi (incluido AlmaLinux para Pi), el arranque usa cmdline.txt,
	# no GRUB. Hay que habilitar el cgroup de memoria que K3s requiere.
	CMDLINE="/boot/cmdline.txt"
	[ -f "${CMDLINE}" ] || CMDLINE="/boot/firmware/cmdline.txt"

	NEEDS_REBOOT=0
	if [ -f "${CMDLINE}" ]; then
	    cp "${CMDLINE}" "${CMDLINE}.bak"
	    # Quitar disable si existe
	    if grep -q "cgroup_disable=memory" "${CMDLINE}"; then
		sed -i 's/cgroup_disable=memory//' "${CMDLINE}"
		NEEDS_REBOOT=1
	    fi
	    # Añadir enable si falta
	    if ! grep -q "cgroup_enable=memory" "${CMDLINE}"; then
		sed -i 's/$/ cgroup_enable=memory cgroup_memory=1/' "${CMDLINE}"
		NEEDS_REBOOT=1
	    fi
	    if [ "${NEEDS_REBOOT}" -eq 1 ]; then
		log_warn "cgroups de memoria ajustados en ${CMDLINE} — REQUIERE REINICIO."
		log_warn "Reinicia la Pi y vuelve a correr el script."
		exit 0
	    fi
	    log_ok "cgroups de memoria ya habilitados."
	else
	    log_warn "No se encontró cmdline.txt — verifica manualmente los cgroups."
	fi
    fi

    # Inicializa la conexion como control-pane
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
  sh -s - server
}

# ── Registrar el nodo como nodo de almacenamiento Longhorn ────────────────────
# Solo nodos STORAGE (A/B). La Pi (STORAGE_NODE=false) se salta esto entero →
# sin label = el manager nunca se le programa = árbitro limpio.
register_longhorn_node() {
  [ "${STORAGE_NODE}" = "true" ] || { log_info "Árbitro: no se registra en Longhorn."; return 0; }

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  log_sub "Esperando a que ${NODE_NAME} aparezca en el clúster..."
  local n=0
  until kubectl get node "${NODE_NAME}" >/dev/null 2>&1; do
    sleep 5; n=$((n+1))
    [ $n -ge 24 ] && die "El nodo ${NODE_NAME} no se registró en 120s."
  done

  # ORDEN IMPORTANTE: el disco y el tag van ANTES que la label.
  # La label dispara la programación del manager → al registrar el nodo, Longhorn
  # lee la anotación de disco. Si la label fuera primero, el manager registraría
  # el nodo SIN la config de disco (la anotación solo se lee en el 1er registro).
  log_sub "Registrando ${NODE_NAME} como nodo de almacenamiento Longhorn..."
  kubectl annotate node "${NODE_NAME}" \
    node.longhorn.io/default-disks-config='[{"path":"/moodlek3s/longhorn","allowScheduling":true,"storageReserved":0,"tags":["storage"]}]' --overwrite
  kubectl annotate node "${NODE_NAME}" \
    node.longhorn.io/default-node-tags='["storage"]' --overwrite
  kubectl label node "${NODE_NAME}" tesoem.edu.mx/longhorn-node=true --overwrite
  log_ok "${NODE_NAME} listo: el manager y las réplicas ya pueden programarse aquí."
}

main(){
    require_root
    show_banner
    validate_requirements
    update_system
    prepare_storage
    prepare_node
    node_join
    register_longhorn_node

echo ""
echo "========================================================="
echo "Próximo paso: Generar replicas de Longhorn y Moodle"
echo "Ejecute el script 06-form-HA-cluster.sh"
echo "========================================================="
echo ""
}

main "$@"
