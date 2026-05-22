#!/bin/bash
# ============================================================================
# 01-prepare-almalinux9.sh
# Preparación completa de AlmaLinux 9 para despliegue de Moodle HA en K3s
#
# PROPÓSITO:
#   Configura desde cero un servidor AlmaLinux 9 para ejecutar K3s con
#   Moodle 5.1 en alta disponibilidad. El script realiza en un solo paso:
#
#     1. Validación de requisitos del sistema (RAM, CPU, disco)
#     2. Actualización del SO y repositorios base
#     3. Instalación de dependencias del sistema (git, curl, wget, jq, etc.)
#     4. Instalación y configuración de Podman (builder de imágenes)
#     5. Preparación del sistema para K3s:
#          - Deshabilitar swap
#          - Configurar parámetros del kernel (sysctl)
#          - Configurar módulos de kernel (br_netfilter, overlay)
#          - Ajustar límites del sistema (ulimits)
#          - Configurar SELinux en modo permisivo
#          - Configurar firewall (firewalld)
#     6. Instalación de K3s con containerd
#     7. Importación de la imagen Podman al namespace k8s.io de containerd
#     8. Preparación del almacenamiento RAID (/moodlek3s)
#     9. Instalación de herramientas de diagnóstico (stern, k9s)
#    10. Verificación completa del entorno
#
# USO:
#   chmod +x 01-prepare-almalinux9.sh
#   ./01-prepare-almalinux9.sh
#
#   Variables de entorno opcionales antes de ejecutar:
#     K3S_VERSION="v1.29.4+k3s1"   # versión específica de K3s
#     SKIP_FIREWALL=true            # si el firewall está gestionado externamente
#     MOODLE_IMAGE_TAG="5.1-k3s-raid"  # tag de la imagen Moodle
#
# FLUJO COMPLETO DEL PROYECTO:
#   00-cleanup-k3s.sh          ← limpieza (si se necesita)
#   01-prepare-almalinux9.sh   ← ESTE SCRIPT
#   02-build-context.sh        ← construir contexto Docker
#   03-build-image.sh          ← construir imagen con Podman (05-build-image.sh)
#   06-deploy-all.sh           ← despliegue completo
#   07-test.sh                 ← verificación
#
# REQUISITOS MÍNIMOS DEL SISTEMA:
#   - AlmaLinux 9.x (probado en 9.3 y 9.4)
#   - 4 GB RAM mínimo (8 GB recomendado para producción)
#   - 4 vCPU mínimo
#   - 100 GB disco (RAID en /moodlek3s o disco local)
#   - Acceso a internet para descargar K3s y paquetes
#   - Ejecutar como root
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
NC='\033[0m'

# ── Variables configurables ───────────────────────────────────────────────────
# Se pueden sobreescribir con variables de entorno antes de ejecutar el script
K3S_VERSION="${K3S_VERSION:-}"                      # vacío = última versión estable
MOODLE_IMAGE_TAG="${MOODLE_IMAGE_TAG:-5.1-k3s-raid}"
MOODLE_IMAGE_NAME="moodle-apache"
RAID_BASE="${RAID_BASE:-/moodlek3s}"
MANIFEST_DIR="/root/k3s-moodle/manifests"
SCRIPTS_DIR="/root/k3s-moodle/scripts"
NODE_NAME="${NODE_NAME:-k3s-moodle-master}"
SKIP_FIREWALL="${SKIP_FIREWALL:-false}"

# Requisitos mínimos del sistema
MIN_RAM_MB=3800      # ~4 GB (dejamos margen)
MIN_CPU=2
MIN_DISK_GB=50

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

# ── Banner inicial ────────────────────────────────────────────────────────────
show_banner() {
  echo ""
  echo -e "${BLUE}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║     PREPARACIÓN AlmaLinux 9 → K3s + Moodle HA               ║"
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

  log_sub "Habilitando repositorios EPEL y CRB..."
  # EPEL: Extra Packages for Enterprise Linux — necesario para herramientas adicionales
  # CRB (CodeReady Builder): dependencias de compilación
  dnf install -y epel-release 2>&1 | tail -3
  dnf config-manager --set-enabled crb 2>&1 | tail -3
  log_ok "Repositorios EPEL y CRB habilitados."
}

# ============================================================================
# PASO 2: INSTALACIÓN DE DEPENDENCIAS
# ============================================================================
install_dependencies() {
  log_step "Instalando dependencias del sistema"

  log_sub "Instalando herramientas base..."
  # Grupo de paquetes esenciales para administración y diagnóstico
  dnf install -y \
    curl \
    wget \
    git \
    vim \
    nano \
    bash-completion \
    jq \
    tar \
    gzip \
    unzip \
    zip \
    2>&1 | tail -5
  log_ok "Herramientas base instaladas."

  log_sub "Instalando herramientas de red y diagnóstico..."
  # Herramientas de red necesarias para troubleshooting de K3s y pods
  dnf install -y \
    net-tools \
    bind-utils \
    nmap-ncat \
    tcpdump \
    traceroute \
    iproute \
    iputils \
    telnet \
    socat \
    conntrack-tools \
    2>&1 | tail -5
  log_ok "Herramientas de red instaladas."

  log_sub "Instalando herramientas de sistema..."
  dnf install -y \
    htop \
    iotop \
    lsof \
    strace \
    rsync \
    bc \
    openssl \
    ca-certificates \
    2>&1 | tail -5
  log_ok "Herramientas de sistema instaladas."

  # Verificar que bash-completion esté cargado en la sesión actual
  [ -f /etc/bash_completion ] && source /etc/bash_completion 2>/dev/null || true
}

# ============================================================================
# PASO 3: INSTALACIÓN DE PODMAN
# ============================================================================
install_podman() {
  log_step "Instalando y configurando Podman"

  # Podman es el builder de imágenes de contenedores para este proyecto.
  # Reemplaza a Docker sin demonio, más seguro en entornos de producción.

  log_sub "Instalando Podman y herramientas de contenedores..."
  dnf install -y \
    podman \
    podman-docker \
    buildah \
    skopeo \
    containers-common \
    2>&1 | tail -5
  log_ok "Podman instalado: $(podman --version)"

  log_sub "Configurando almacenamiento de Podman..."
  # Crear directorio de configuración de contenedores
  mkdir -p /etc/containers

  # registries.conf: define los registros de búsqueda de imágenes
  # Orden: registro local (no-pull) → Docker Hub → Quay
  cat > /etc/containers/registries.conf << 'EOF'
# Registros de búsqueda de imágenes para Podman
# Este orden determina dónde busca Podman cuando el nombre de imagen
# no incluye registro explícito (ej: "mariadb:lts" → busca en docker.io)
[registries.search]
registries = ['docker.io', 'quay.io', 'registry.access.redhat.com']

[registries.insecure]
registries = []

[registries.block]
registries = []
EOF
  log_ok "registries.conf configurado."

  # policy.json: política de confianza de imágenes
  # insecureAcceptAnything: acepta cualquier imagen sin verificación de firma
  # Apropiado para entornos de laboratorio/prueba
  cat > /etc/containers/policy.json << 'EOF'
{
  "default": [
    {
      "type": "insecureAcceptAnything"
    }
  ],
  "transports": {
    "docker-daemon": {
      "": [{"type": "insecureAcceptAnything"}]
    }
  }
}
EOF
  log_ok "policy.json configurado."

  log_sub "Verificando Podman..."
  podman info --format "Storage driver: {{.Store.GraphDriverName}}" 2>/dev/null \
    && log_ok "Podman operativo." \
    || log_warn "Podman instalado pero verificación incompleta."
}

# ============================================================================
# PASO 4: PREPARACIÓN DEL KERNEL Y SISTEMA PARA K3S
# ============================================================================
prepare_kernel() {
  log_step "Configurando kernel y sistema para K3s"

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

  # ── 4.2: Módulos del kernel ─────────────────────────────────────────────────
  log_sub "Cargando módulos del kernel..."
  # br_netfilter: permite que iptables vea tráfico de puentes de red
  #               necesario para que K3s/flannel gestione el tráfico entre pods
  # overlay: sistema de archivos en capas usado por containerd para imágenes
  cat > /etc/modules-load.d/k3s.conf << 'EOF'
# Módulos requeridos por K3s / containerd
# br_netfilter: tráfico de red de pods a través de puentes
# overlay: filesystem de contenedores (imágenes en capas)
br_netfilter
overlay
EOF

  modprobe br_netfilter 2>/dev/null && log_ok "Módulo br_netfilter cargado." || log_warn "br_netfilter no se pudo cargar."
  modprobe overlay       2>/dev/null && log_ok "Módulo overlay cargado."       || log_warn "overlay no se pudo cargar."

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

  if [ "${SKIP_FIREWALL}" = "true" ]; then
    log_info "Configuración de firewall omitida (SKIP_FIREWALL=true)."
    return
  fi

  if systemctl is-active --quiet firewalld; then
    # Puerto 6443: API server de K3s (kubectl)
    # Puerto 10250: kubelet API (métricas, logs de pods)
    # Puerto 8472/udp: VXLAN de flannel (tráfico entre pods)
    # Puerto 51820/udp: WireGuard (si se usa cifrado de red de pods)
    # Puerto 80/443: tráfico HTTP/HTTPS hacia Moodle vía Traefik
    # Puerto 8080/8443: puertos directos de la aplicación Moodle
    # Puerto 30000-32767: NodePort de Kubernetes

    firewall-cmd --permanent --add-port=6443/tcp    # K3s API
    firewall-cmd --permanent --add-port=10250/tcp   # kubelet
    firewall-cmd --permanent --add-port=8472/udp    # flannel VXLAN
    firewall-cmd --permanent --add-port=51820/udp   # WireGuard (opcional)
    firewall-cmd --permanent --add-port=80/tcp      # HTTP
    firewall-cmd --permanent --add-port=443/tcp     # HTTPS
    firewall-cmd --permanent --add-port=8080/tcp    # Moodle HTTP directo
    firewall-cmd --permanent --add-port=8443/tcp    # Moodle HTTPS directo
    firewall-cmd --permanent --add-port=30000-32767/tcp  # NodePorts
    firewall-cmd --permanent --add-masquerade       # NAT para pods

    # Zona de confianza para la interfaz de loopback y red interna de pods
    firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16  # pods
    firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16  # services
    firewall-cmd --permanent --zone=trusted --add-interface=lo

    firewall-cmd --reload
    log_ok "Firewall configurado con puertos de K3s y Moodle."
  else
    log_warn "firewalld no está activo — omitiendo configuración de firewall."
    log_info "Si usas nftables o iptables directamente, abre los puertos: 6443/tcp, 80/tcp, 443/tcp, 8080/tcp, 8443/tcp"
  fi
}

# ============================================================================
# PASO 5: INSTALACIÓN DE K3S
# ============================================================================
install_k3s() {
  log_step "Instalando K3s"

  # K3s es una distribución ligera de Kubernetes optimizada para edge y
  # entornos con recursos limitados. Incluye: server (control plane + worker),
  # containerd, flannel (CNI), CoreDNS, Traefik (ingress), local-path-provisioner.

  # Asegurar que /usr/local/bin esté en el PATH (necesario para k3s y kubectl)
  export PATH="/usr/local/bin:/usr/local/sbin:$PATH"
  
  log_sub "Descargando e instalando K3s..."

  # Construir el comando de instalación
  # INSTALL_K3S_EXEC: flags adicionales para el servidor K3s
  #   --write-kubeconfig-mode 644: permite leer kubeconfig sin root
  #   --node-name: nombre explícito del nodo (debe coincidir con nodeSelector)
  #   --disable traefik: si quisieras usar otro ingress; aquí lo dejamos activo
  #   --container-runtime-endpoint: usa containerd (default en K3s)

  K3S_INSTALL_FLAGS="--write-kubeconfig-mode 644 --node-name ${NODE_NAME}"

  if [ -n "${K3S_VERSION}" ]; then
    log_info "Instalando K3s versión específica: ${K3S_VERSION}"
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_EXEC="${K3S_INSTALL_FLAGS}" \
    curl -sfL https://get.k3s.io | sh -
  else
    log_info "Instalando última versión estable de K3s..."
    INSTALL_K3S_EXEC="${K3S_INSTALL_FLAGS}" \
    curl -sfL https://get.k3s.io | sh -
  fi

  log_ok "K3s instalado: $(k3s --version | head -1)"

  # ── Configurar kubectl ──────────────────────────────────────────────────────
  log_sub "Configurando kubectl y kubeconfig..."

  # Copiar kubeconfig al directorio estándar de root
  mkdir -p /root/.kube
  cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
  chmod 600 /root/.kube/config

  # Exportar KUBECONFIG para la sesión actual
  export KUBECONFIG=/root/.kube/config

  # Añadir a .bashrc para sesiones futuras
  if ! grep -q "KUBECONFIG" /root/.bashrc; then
    echo "" >> /root/.bashrc
    echo "# K3s kubeconfig" >> /root/.bashrc
    echo "export KUBECONFIG=/root/.kube/config" >> /root/.bashrc
  fi

  # Añadir autocompletado de kubectl
  if ! grep -q "kubectl completion" /root/.bashrc; then
    echo "source <(kubectl completion bash)" >> /root/.bashrc
  fi

  log_ok "kubectl configurado."

  # ── Esperar a que K3s esté listo ────────────────────────────────────────────
  log_sub "Esperando a que K3s esté listo (hasta 120s)..."
  RETRIES=0
  until kubectl cluster-info &>/dev/null 2>&1; do
    sleep 5
    RETRIES=$((RETRIES + 1))
    if [ $RETRIES -ge 24 ]; then
      die "K3s no respondió en 120 segundos. Revisa: journalctl -u k3s -n 50"
    fi
    echo -n "."
  done
  echo ""
  log_ok "K3s API server disponible."

  # Esperar a que el nodo esté en estado Ready
  log_sub "Esperando nodo ${NODE_NAME} en estado Ready..."
  RETRIES=0
  until kubectl get node "${NODE_NAME}" --no-headers 2>/dev/null | grep -q " Ready"; do
    sleep 5
    RETRIES=$((RETRIES + 1))
    if [ $RETRIES -ge 24 ]; then
      log_warn "El nodo tardó más de 120s en estar Ready — continuando de todas formas."
      break
    fi
    echo -n "."
  done
  echo ""

  kubectl get nodes -o wide
  log_ok "K3s instalado y operativo."
}

# ============================================================================
# PASO 6: PREPARACIÓN DEL ALMACENAMIENTO RAID
# ============================================================================
prepare_storage() {
  log_step "Preparando almacenamiento en ${RAID_BASE}"

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
  mkdir -p "${RAID_BASE}/mariadb"
  mkdir -p "${RAID_BASE}/redis"
  mkdir -p "${RAID_BASE}/moodle-html"
  mkdir -p "${RAID_BASE}/moodle-data"
  log_ok "Directorios creados en ${RAID_BASE}/"

  # Permisos — deben coincidir con los UIDs de los contenedores:
  #   uid 999 → mariadb:lts (usuario mysql dentro del contenedor)
  #   uid 999 → redis:7-alpine (usuario redis dentro del contenedor)
  #   uid 1001 → moodle-apache (usuario www-data dentro del contenedor)
  log_sub "Configurando permisos..."
  chown -R 999:999   "${RAID_BASE}/mariadb"
  chmod -R 750       "${RAID_BASE}/mariadb"

  chown -R 999:999   "${RAID_BASE}/redis"
  chmod -R 750       "${RAID_BASE}/redis"

  chown -R 1001:1001 "${RAID_BASE}/moodle-html"
  chmod -R 2777      "${RAID_BASE}/moodle-html"

  chown -R 1001:1001 "${RAID_BASE}/moodle-data"
  chmod -R 2777      "${RAID_BASE}/moodle-data"

  log_ok "Permisos configurados."
  ls -la "${RAID_BASE}/"

  # Crear directorios de trabajo del proyecto
  log_sub "Creando directorios del proyecto..."
  mkdir -p "${MANIFEST_DIR}"
  mkdir -p "${SCRIPTS_DIR}"
  log_ok "Directorios del proyecto creados en /root/k3s-moodle/"
}

# ============================================================================
# PASO 7: IMPORTAR IMAGEN DE PODMAN A CONTAINERD
# ============================================================================
import_moodle_image() {
  log_step "Importando imagen Moodle de Podman a containerd (k8s.io)"

  # Este es el paso crítico que resuelve el ImagePullBackOff.
  # K3s usa containerd con el namespace "k8s.io".
  # Podman usa su propio almacén de imágenes separado.
  # La imagen debe estar en containerd/k8s.io para que los pods la encuentren.

  FULL_IMAGE="${MOODLE_IMAGE_NAME}:${MOODLE_IMAGE_TAG}"

  log_sub "Verificando si la imagen existe en Podman..."
  if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${FULL_IMAGE}$"; then
    log_warn "Imagen ${FULL_IMAGE} NO encontrada en Podman."
    log_info "Debes construir la imagen primero con: ./05-build-image.sh"
    log_info "Después de construir, importa manualmente con:"
    echo ""
    echo -e "    ${CYAN}podman save ${FULL_IMAGE} | ctr -n k8s.io images import -${NC}"
    echo ""
    log_info "O re-ejecuta este script después de construir la imagen."
    return
  fi

  log_ok "Imagen ${FULL_IMAGE} encontrada en Podman."
  podman images "${MOODLE_IMAGE_NAME}" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.Created}}"

  log_sub "Verificando si ya está en containerd k8s.io..."
  if ctr -n k8s.io images ls 2>/dev/null | grep -q "${MOODLE_IMAGE_NAME}"; then
    log_ok "Imagen ya presente en containerd k8s.io — omitiendo importación."
    return
  fi

  log_sub "Exportando desde Podman e importando a containerd k8s.io..."
  log_info "Esto puede tardar 2-5 minutos dependiendo del tamaño de la imagen..."

  # Pipe directo: evita escribir el tar en disco (ahorra espacio)
  # El flag --platform fuerza amd64 si hay imágenes multi-arch
  if podman save "${FULL_IMAGE}" | ctr -n k8s.io images import -; then
    log_ok "Imagen importada exitosamente a containerd k8s.io."
  else
    log_warn "Error en la importación por pipe — intentando con archivo temporal..."
    TMPTAR="/tmp/${MOODLE_IMAGE_NAME}-${MOODLE_IMAGE_TAG}.tar"
    podman save "${FULL_IMAGE}" -o "${TMPTAR}"
    ctr -n k8s.io images import "${TMPTAR}"
    rm -f "${TMPTAR}"
    log_ok "Imagen importada desde archivo temporal."
  fi

  log_sub "Verificando imagen en containerd k8s.io..."
  if ctr -n k8s.io images ls | grep -q "${MOODLE_IMAGE_NAME}"; then
    log_ok "Imagen disponible para K3s:"
    ctr -n k8s.io images ls | grep "${MOODLE_IMAGE_NAME}"
  else
    log_warn "La imagen no aparece en containerd — verifica manualmente con:"
    log_info "  ctr -n k8s.io images ls | grep moodle"
  fi
}

# ============================================================================
# PASO 7.5: PREREQUISITOS DE LONGHORN
# ============================================================================
install_longhorn_deps() {
  log_step "Instalando prerequisitos de Longhorn"
 
  # Longhorn es el sistema de almacenamiento distribuido del clúster HA.
  # Antes de instalar Longhorn en Kubernetes, cada nodo del clúster debe tener
  # las herramientas y módulos del kernel que Longhorn necesita para:
  #   - Montar volúmenes en los nodos (iSCSI)
  #   - Proveer acceso RWX compartido entre pods (NFS)
  #   - Encriptar volúmenes opcionalmente (dm_crypt / cryptsetup)
  #   - Inspeccionar el estado del disco y sistema de archivos (utilidades bash)
 
  # ── Paquetes requeridos ─────────────────────────────────────────────────────
  log_sub "Instalando paquetes requeridos por Longhorn..."
 
  # iscsi-initiator-utils:
  #   Proporciona el daemon iscsid y las herramientas de cliente iSCSI.
  #   Longhorn usa iSCSI para montar volúmenes de bloque en los nodos worker.
  #   Sin esto, los pods que pidan un PVC no pueden arrancar.
  #
  # nfs-utils:
  #   Cliente NFS necesario para volúmenes RWX (ReadWriteMany).
  #   Longhorn implementa RWX internamente con NFS sobre sus volúmenes RWO.
  #   Moodle necesita RWX para que múltiples pods lean/escriban el mismo volumen.
  #
  # cryptsetup:
  #   Herramienta para cifrado de dispositivos de bloque (LUKS/dm-crypt).
  #   El instalador de Longhorn la requiere aunque no uses cifrado activamente.
  #
  # device-mapper:
  #   Framework del kernel para volúmenes lógicos y mapeo de dispositivos.
  #   Generalmente ya viene en AlmaLinux 9, pero lo aseguramos explícitamente.
  #
  # util-linux:
  #   Provee blkid, lsblk, findmnt — comandos que Longhorn Manager ejecuta
  #   para inspeccionar los discos y puntos de montaje del nodo.
 
  dnf install -y \
    iscsi-initiator-utils \
    nfs-utils \
    cryptsetup \
    device-mapper \
    util-linux \
    2>&1 | tail -5
  log_ok "Paquetes de Longhorn instalados."
 
  # ── Módulos del kernel ──────────────────────────────────────────────────────
  log_sub "Cargando módulos del kernel requeridos por Longhorn..."
 
  # iscsi_tcp:
  #   Módulo del kernel que implementa iSCSI sobre TCP.
  #   Longhorn lo necesita en cada nodo para poder montar sus volúmenes.
  #   Se carga ahora (modprobe) y se persiste para el próximo boot (modules-load.d).
  #
  # dm_crypt:
  #   Módulo del kernel para cifrado de dispositivos de bloque.
  #   Lo requiere cryptsetup y el propio Longhorn para encriptación de volúmenes.
 
  cat > /etc/modules-load.d/longhorn.conf << 'EOF'
# Módulos del kernel requeridos por Longhorn
# iscsi_tcp: iSCSI sobre TCP para montaje de volúmenes de bloque
# dm_crypt:  cifrado de dispositivos de bloque (requerido por cryptsetup)
iscsi_tcp
dm_crypt
EOF
 
  modprobe iscsi_tcp 2>/dev/null \
    && log_ok "Módulo iscsi_tcp cargado." \
    || log_warn "iscsi_tcp no se pudo cargar — puede ya estar integrado en el kernel."
 
  modprobe dm_crypt 2>/dev/null \
    && log_ok "Módulo dm_crypt cargado." \
    || log_warn "dm_crypt no se pudo cargar — puede ya estar integrado en el kernel."
 
  # ── Servicio iscsid ─────────────────────────────────────────────────────────
  log_sub "Habilitando y arrancando el daemon iSCSI (iscsid)..."
 
  # iscsid es el daemon que gestiona las sesiones iSCSI activas en el nodo.
  # Debe estar corriendo ANTES de que Longhorn intente montar cualquier volumen.
  # enable --now: lo habilita para boot Y lo arranca en esta sesión.
 
  systemctl enable --now iscsid 2>/dev/null \
    && log_ok "iscsid habilitado y activo." \
    || log_warn "iscsid no se pudo iniciar — verifica con: systemctl status iscsid"
 
  # ── Puertos adicionales en el firewall ─────────────────────────────────────
  log_sub "Abriendo puertos de Longhorn en el firewall..."
 
  # Longhorn necesita comunicación entre nodos en estos puertos:
  #   9500/tcp  — Longhorn Manager (API interna del gestor de volúmenes)
  #   9501/tcp  — Longhorn Engine (proceso que maneja cada volumen individual)
  #   9502/tcp  — Longhorn Engine replica sync
  #   9503/tcp  — Longhorn Engine replica restore
  #   2049/tcp  — NFS (para volúmenes RWX)
  #   111/tcp   — RPC portmapper (requerido por NFS)
  #   20048/tcp — mountd de NFS
 
  if [ "${SKIP_FIREWALL}" = "true" ]; then
    log_info "SKIP_FIREWALL=true — omitiendo puertos de Longhorn."
  elif systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=9500-9503/tcp  # Longhorn Manager + Engine
    firewall-cmd --permanent --add-port=2049/tcp        # NFS (RWX)
    firewall-cmd --permanent --add-port=111/tcp         # RPC portmapper
    firewall-cmd --permanent --add-port=20048/tcp       # NFS mountd
    firewall-cmd --reload
    log_ok "Puertos de Longhorn abiertos en firewalld."
  else
    log_warn "firewalld no activo — abre manualmente: 9500-9503/tcp, 2049/tcp, 111/tcp, 20048/tcp"
  fi
 
  # ── Verificación con longhornctl (opcional) ─────────────────────────────────
  log_sub "Instalando longhornctl para diagnóstico de preflight..."
 
  # longhornctl es la CLI oficial de Longhorn. Su subcomando 'check preflight'
  # analiza el nodo y reporta exactamente qué prerequisitos faltan.
  # Es útil ejecutarlo después de este script para confirmar que todo está OK.
 
  LONGHORNCTL_VERSION="v1.7.2"
  ARCH=$(uname -m)
  case "${ARCH}" in
    x86_64)  LONGHORNCTL_ARCH="amd64" ;;
    aarch64) LONGHORNCTL_ARCH="arm64" ;;
    *)       LONGHORNCTL_ARCH="amd64" ;;
  esac
 
  if ! command -v longhornctl &>/dev/null; then
    curl -sL \
      "https://github.com/longhorn/cli/releases/download/${LONGHORNCTL_VERSION}/longhornctl-linux-${LONGHORNCTL_ARCH}" \
      -o /usr/local/bin/longhornctl 2>/dev/null \
    && chmod +x /usr/local/bin/longhornctl \
    && log_ok "longhornctl ${LONGHORNCTL_VERSION} instalado." \
    || log_warn "No se pudo descargar longhornctl — instálalo manualmente si necesitas diagnóstico."
  else
    log_ok "longhornctl ya instalado: $(longhornctl version --client-only 2>/dev/null || echo 'versión desconocida')"
  fi
 
  log_ok "Prerequisitos de Longhorn completados."
  echo ""
  log_info "Para verificar este nodo ejecuta (después de que K3s esté activo):"
  echo -e "    ${CYAN}longhornctl check preflight${NC}"
}

# ============================================================================
# PASO 8: INSTALAR HERRAMIENTAS DE DIAGNÓSTICO
# ============================================================================
install_diagnostic_tools() {
  log_step "Instalando herramientas de diagnóstico de Kubernetes"

  # ── stern: tail de logs de múltiples pods simultáneamente ──────────────────
  log_sub "Instalando stern (multi-pod log tailing)..."
  STERN_VERSION="1.28.0"
  if ! check_command stern; then
    curl -sL "https://github.com/stern/stern/releases/download/v${STERN_VERSION}/stern_${STERN_VERSION}_linux_amd64.tar.gz" \
      -o /tmp/stern.tar.gz 2>/dev/null \
    && tar -xzf /tmp/stern.tar.gz -C /tmp stern 2>/dev/null \
    && mv /tmp/stern /usr/local/bin/stern \
    && chmod +x /usr/local/bin/stern \
    && rm -f /tmp/stern.tar.gz \
    && log_ok "stern ${STERN_VERSION} instalado." \
    || log_warn "No se pudo instalar stern — omitiendo."
  else
    log_ok "stern ya instalado: $(stern --version 2>/dev/null | head -1)"
  fi

  # ── k9s: dashboard TUI de Kubernetes ───────────────────────────────────────
  log_sub "Instalando k9s (Kubernetes TUI)..."
  K9S_VERSION="0.32.4"
  if ! check_command k9s; then
    curl -sL "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
      -o /tmp/k9s.tar.gz 2>/dev/null \
    && tar -xzf /tmp/k9s.tar.gz -C /tmp k9s 2>/dev/null \
    && mv /tmp/k9s /usr/local/bin/k9s \
    && chmod +x /usr/local/bin/k9s \
    && rm -f /tmp/k9s.tar.gz \
    && log_ok "k9s ${K9S_VERSION} instalado." \
    || log_warn "No se pudo instalar k9s — omitiendo."
  else
    log_ok "k9s ya instalado: $(k9s version --short 2>/dev/null | head -1)"
  fi

  # ── crictl: CLI de containerd para inspección de contenedores ──────────────
  log_sub "Verificando crictl..."
  if check_command crictl; then
    log_ok "crictl disponible: $(crictl --version 2>/dev/null)"
    # Configurar crictl para usar el socket de containerd de K3s
    cat > /etc/crictl.yaml << 'EOF'
# Configuración de crictl para K3s
# K3s usa un socket de containerd en una ruta no estándar
runtime-endpoint: unix:///run/k3s/containerd/containerd.sock
image-endpoint: unix:///run/k3s/containerd/containerd.sock
timeout: 10
debug: false
EOF
    log_ok "crictl.yaml configurado para socket de K3s."
  else
    log_warn "crictl no disponible — se instala con K3s normalmente."
  fi

  # ── watch: para monitoreo en tiempo real ───────────────────────────────────
  log_sub "Verificando watch..."
  check_command watch && log_ok "watch disponible." || dnf install -y procps-ng 2>/dev/null

  log_ok "Herramientas de diagnóstico instaladas."
}

# ============================================================================
# PASO 9: CONFIGURACIONES ADICIONALES DEL SISTEMA
# ============================================================================
configure_system() {
  log_step "Aplicando configuraciones adicionales del sistema"

  # ── Hostname ────────────────────────────────────────────────────────────────
  log_sub "Configurando hostname..."
  CURRENT_HOSTNAME=$(hostname)
  if [ "${CURRENT_HOSTNAME}" != "${NODE_NAME}" ]; then
    hostnamectl set-hostname "${NODE_NAME}"
    log_ok "Hostname configurado: ${NODE_NAME}"
    log_info "Era: ${CURRENT_HOSTNAME} → Ahora: ${NODE_NAME}"
  else
    log_ok "Hostname ya es correcto: ${NODE_NAME}"
  fi

  # Asegurar que el hostname resuelve localmente
  if ! grep -q "${NODE_NAME}" /etc/hosts; then
    echo "127.0.0.1  ${NODE_NAME}" >> /etc/hosts
    log_ok "Hostname añadido a /etc/hosts."
  fi

  # ── Zona horaria ────────────────────────────────────────────────────────────
  log_sub "Configurando zona horaria..."
  timedatectl set-timezone America/Mexico_City 2>/dev/null \
    && log_ok "Zona horaria: America/Mexico_City" \
    || log_warn "No se pudo configurar la zona horaria."

  # ── Sincronización de tiempo ────────────────────────────────────────────────
  log_sub "Configurando sincronización de tiempo (chrony)..."
  if ! check_command chronyd; then
    dnf install -y chrony 2>&1 | tail -3
  fi
  systemctl enable --now chronyd 2>/dev/null \
    && log_ok "chronyd activo." \
    || log_warn "chronyd no se pudo iniciar."

  # ── Script de conveniencia para importar imagen después del build ───────────
  log_sub "Creando script auxiliar import-image.sh..."
  cat > "${SCRIPTS_DIR}/import-image.sh" << IMPORT_EOF
#!/bin/bash
# import-image.sh
# Importa la imagen Moodle de Podman al namespace k8s.io de containerd.
# Ejecutar después de 05-build-image.sh y antes de 06-deploy-all.sh
#
# Uso: ./import-image.sh [imagen:tag]
# Ejemplo: ./import-image.sh moodle-apache:5.1-k3s-raid

set -euo pipefail

IMAGE="\${1:-moodle-apache:${MOODLE_IMAGE_TAG}}"
echo "[*] Importando imagen \${IMAGE} a containerd k8s.io..."

if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^\${IMAGE}$"; then
  echo "[!] Imagen \${IMAGE} no encontrada en Podman."
  echo "    Construye primero con: ./05-build-image.sh"
  exit 1
fi

echo "[*] Tamaño de la imagen:"
podman images "\${IMAGE%%:*}" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"

echo "[*] Exportando e importando (puede tardar varios minutos)..."
podman save "\${IMAGE}" | ctr -n k8s.io images import -

echo "[*] Verificando en containerd:"
ctr -n k8s.io images ls | grep "\${IMAGE%%:*}"

echo "[✓] Imagen disponible para K3s."
IMPORT_EOF

  chmod +x "${SCRIPTS_DIR}/import-image.sh"
  log_ok "Script import-image.sh creado en ${SCRIPTS_DIR}/"

  # ── Alias útiles para kubectl ───────────────────────────────────────────────
  log_sub "Configurando alias de kubectl..."
  if ! grep -q "alias k=" /root/.bashrc; then
    cat >> /root/.bashrc << 'ALIASES'

# ── Alias de Kubernetes ───────────────────────────────────────────────────────
alias k='kubectl'
alias kn='kubectl -n moodle-prod'
alias kgp='kubectl get pods -n moodle-prod -o wide'
alias kgs='kubectl get svc -n moodle-prod'
alias kge='kubectl get events -n moodle-prod --sort-by=.lastTimestamp'
alias klogs='kubectl logs -f -l app=moodle -n moodle-prod -c moodle --max-log-requests=3'
alias kwatch='watch -n 3 kubectl get pods -n moodle-prod -o wide'
ALIASES
    log_ok "Alias de kubectl añadidos a .bashrc"
  fi
}

# ============================================================================
# PASO 10: VERIFICACIÓN FINAL DEL ENTORNO
# ============================================================================
verify_environment() {
  log_step "Verificación final del entorno"

  local ERRORS=0
  local WARNINGS=0

  echo ""

  # K3s
  echo -e "  ${BOLD}K3s:${NC}"
  if systemctl is-active --quiet k3s; then
    log_ok "Servicio k3s activo."
  else
    log_err "Servicio k3s NO activo."
    ERRORS=$((ERRORS+1))
  fi

  if kubectl cluster-info &>/dev/null 2>&1; then
    log_ok "API server respondiendo."
    K3S_VER=$(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}')
    log_ok "Versión K3s: ${K3S_VER}"
  else
    log_err "API server no responde."
    ERRORS=$((ERRORS+1))
  fi

  # Nodo
  echo ""
  echo -e "  ${BOLD}Nodo:${NC}"
  NODE_STATUS=$(kubectl get node "${NODE_NAME}" --no-headers 2>/dev/null | awk '{print $2}' || echo "ERROR")
  if [ "${NODE_STATUS}" = "Ready" ]; then
    log_ok "Nodo ${NODE_NAME}: Ready"
  else
    log_err "Nodo ${NODE_NAME}: ${NODE_STATUS}"
    ERRORS=$((ERRORS+1))
  fi

  # containerd
  echo ""
  echo -e "  ${BOLD}Containerd:${NC}"
  if ctr -n k8s.io images ls &>/dev/null 2>&1; then
    log_ok "containerd operativo (namespace k8s.io accesible)."
    IMAGE_COUNT=$(ctr -n k8s.io images ls -q 2>/dev/null | wc -l)
    log_ok "Imágenes en k8s.io: ${IMAGE_COUNT}"
  else
    log_warn "containerd no responde o namespace k8s.io inaccesible."
    WARNINGS=$((WARNINGS+1))
  fi

  # Imagen Moodle
  echo ""
  echo -e "  ${BOLD}Imagen Moodle:${NC}"
  if ctr -n k8s.io images ls 2>/dev/null | grep -q "${MOODLE_IMAGE_NAME}"; then
    log_ok "Imagen ${MOODLE_IMAGE_NAME}:${MOODLE_IMAGE_TAG} disponible en containerd."
  else
    log_warn "Imagen ${MOODLE_IMAGE_NAME}:${MOODLE_IMAGE_TAG} NO está en containerd."
    log_info "  → Construye con: ./05-build-image.sh"
    log_info "  → Importa con:   ${SCRIPTS_DIR}/import-image.sh"
    WARNINGS=$((WARNINGS+1))
  fi

  # Almacenamiento
  echo ""
  echo -e "  ${BOLD}Almacenamiento:${NC}"
  for DIR in mariadb redis moodle-html moodle-data; do
    if [ -d "${RAID_BASE}/${DIR}" ]; then
      PERMS=$(stat -c "%U:%G %a" "${RAID_BASE}/${DIR}")
      log_ok "${RAID_BASE}/${DIR} — ${PERMS}"
    else
      log_err "${RAID_BASE}/${DIR} no existe."
      ERRORS=$((ERRORS+1))
    fi
  done

  # Podman
  echo ""
  echo -e "  ${BOLD}Podman:${NC}"
  if check_command podman; then
    log_ok "Podman: $(podman --version)"
    PODMAN_IMAGES=$(podman images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -v "<none>" | wc -l)
    log_ok "Imágenes en Podman: ${PODMAN_IMAGES}"
  else
    log_warn "Podman no disponible."
    WARNINGS=$((WARNINGS+1))
  fi

  # Kernel
  echo ""
  echo -e "  ${BOLD}Kernel:${NC}"
  sysctl net.ipv4.ip_forward 2>/dev/null | grep -q "= 1" \
    && log_ok "ip_forward habilitado." \
    || log_warn "ip_forward no habilitado."
  sysctl net.bridge.bridge-nf-call-iptables 2>/dev/null | grep -q "= 1" \
    && log_ok "bridge-nf-call-iptables habilitado." \
    || log_warn "bridge-nf-call-iptables no habilitado."
  [ "$(swapon --show | wc -l)" -eq 0 ] \
    && log_ok "Swap deshabilitado." \
    || log_warn "Swap activo — puede causar problemas."

  # SELinux
  echo ""
  echo -e "  ${BOLD}SELinux:${NC}"
  SELINUX_CURRENT=$(getenforce 2>/dev/null || echo "Disabled")
  if [ "${SELINUX_CURRENT}" = "Permissive" ] || [ "${SELINUX_CURRENT}" = "Disabled" ]; then
    log_ok "SELinux: ${SELINUX_CURRENT}"
  else
    log_warn "SELinux en modo ${SELINUX_CURRENT} — puede bloquear K3s."
    WARNINGS=$((WARNINGS+1))
  fi

  # Resumen
  echo ""
  echo -e "${BOLD}  Resumen de verificación:${NC}"
  echo -e "  Errores:    ${RED}${ERRORS}${NC}"
  echo -e "  Advertencias: ${YELLOW}${WARNINGS}${NC}"
  echo ""

  if [ "${ERRORS}" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║       ENTORNO PREPARADO CORRECTAMENTE                        ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GREEN}${BOLD}Próximos pasos:${NC}"
    echo ""
    echo -e "  1. Construir imagen Moodle:"
    echo -e "     ${CYAN}cd /root/k3s-moodle && ./scripts/05-build-image.sh${NC}"
    echo ""
    echo -e "  2. Importar imagen a containerd:"
    echo -e "     ${CYAN}${SCRIPTS_DIR}/import-image.sh${NC}"
    echo ""
    echo -e "  3. Desplegar Moodle:"
    echo -e "     ${CYAN}${SCRIPTS_DIR}/06-deploy-all.sh${NC}"
    echo ""
  else
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║   PREPARACIÓN COMPLETADA CON ERRORES — REVISAR ANTES DE     ║${NC}"
    echo -e "${RED}${BOLD}║   EJECUTAR 06-deploy-all.sh                                  ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  fi

  echo ""
  echo -e "  Completado — $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
}

# ============================================================================
# MAIN — SECUENCIA DE EJECUCIÓN
# ============================================================================
main() {
  show_banner
  require_root

  validate_requirements    # Paso 0: validar RAM, CPU, disco, red
  update_system            # Paso 1: dnf update + EPEL + CRB
  install_dependencies     # Paso 2: curl, git, jq, net-tools, etc.
  install_podman           # Paso 3: Podman + buildah + skopeo
  prepare_kernel           # Paso 4: swap, sysctl, módulos, SELinux, firewall
  install_k3s              # Paso 5: K3s + kubectl + kubeconfig
  prepare_storage          # Paso 6: /moodlek3s + permisos
  import_moodle_image      # Paso 7: Podman → containerd k8s.io
  install_longhorn_deps    # Paso 7.5: prerequisitos de Longhorn (iSCSI, NFS, módulos)
  install_diagnostic_tools # Paso 8: stern, k9s, crictl
  configure_system         # Paso 9: hostname, timezone, aliases
  verify_environment       # Paso 10: verificación final
}

main "$@"
