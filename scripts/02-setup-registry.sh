#!/bin/bash
# ============================================================================
# 02-setup-registry.sh
# Instalación y configuración de Registry privado local en el nodo K3s
#
# PROPÓSITO:
#   Despliega un container registry privado (Docker Registry v2) directamente
#   en el nodo k3s-moodle-master usando Podman. El registry escucha en
#   localhost:5000 y se configura como servicio systemd para que arranque
#   automáticamente con el sistema.
#
#   Una vez instalado, el flujo de imágenes queda así:
#
#     Podman build
#         │
#         ▼
#     podman push localhost:5000/moodle-apache:5.1-k3s-raid
#         │
#         ▼
#     Registry local (:5000)  ←── K3s configurado para confiar en él
#         │
#         ▼
#     containerd pull (pods moodle)
#
#   Esto elimina completamente la dependencia de Docker Hub y el error
#   ImagePullBackOff causado por intentar descargar una imagen local
#   desde internet.
#
# QUÉ HACE ESTE SCRIPT:
#   1. Despliega el contenedor registry:2 con Podman en localhost:5000
#   2. Crea un servicio systemd (podman-registry) para arranque automático
#   3. Configura K3s para confiar en localhost:5000 como registry inseguro
#      (registries.yaml en /etc/rancher/k3s/)
#   4. Reinicia K3s para aplicar la configuración del registry
#   5. Verifica que el registry responde y K3s lo reconoce
#
# USO:
#   chmod +x 02-setup-registry.sh
#   ./02-setup-registry.sh
#
# PUERTOS:
#   5000/tcp → Registry API (push/pull de imágenes)
#
# DATOS PERSISTENTES:
#   /moodlek3s/registry/data  → capas de imágenes almacenadas
#
# FLUJO COMPLETO DEL PROYECTO:
#   00-cleanup-k3s.sh          ← limpieza previa si se necesita
#   01-prepare-almalinux9.sh   ← preparación del SO y K3s
#   02-setup-registry.sh       ← ESTE SCRIPT
#   05-build-image.sh          ← build + push al registry
#   06-deploy-all.sh           ← despliegue (pull desde registry local)
#
# REQUISITOS:
#   - AlmaLinux 9 con K3s instalado (01-prepare-almalinux9.sh ejecutado)
#   - Podman instalado
#   - Ejecutar como root
#
# AUTOR: Infraestructura TESOEM
# VERSIÓN: 1.0
# ============================================================================

set -euo pipefail

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Variables ─────────────────────────────────────────────────────────────────
REGISTRY_HOST="localhost"
REGISTRY_PORT="5000"
REGISTRY_IMAGE="docker.io/library/registry:2"
REGISTRY_CONTAINER_NAME="local-registry"
REGISTRY_DATA_DIR="/moodlek3s/registry/data"
REGISTRY_SERVICE_NAME="podman-registry"
K3S_REGISTRIES_FILE="/etc/rancher/k3s/registries.yaml"
NODE_IP=$(hostname -I | awk '{print $1}')

log_step() { echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════════${NC}";
             echo -e "${BLUE}${BOLD}  $1${NC}";
             echo -e "${BLUE}${BOLD}══════════════════════════════════════════════${NC}"; }
log_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
log_info() { echo -e "  ${CYAN}ℹ${NC} $1"; }
die()      { echo -e "  ${RED}✗ ERROR:${NC} $1"; exit 1; }

[ "$EUID" -eq 0 ] || die "Ejecutar como root."

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║     INSTALACIÓN REGISTRY PRIVADO LOCAL — Puerto 5000         ║"
echo "  ║     TESOEM — Infraestructura K3s                             ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Registry URL: ${CYAN}${REGISTRY_HOST}:${REGISTRY_PORT}${NC}"
echo -e "  Datos:        ${CYAN}${REGISTRY_DATA_DIR}${NC}"
echo -e "  IP del nodo:  ${CYAN}${NODE_IP}${NC}"
echo ""

# ============================================================================
# PASO 1: PREPARAR DIRECTORIO DE DATOS
# ============================================================================
log_step "Paso 1 — Preparar almacenamiento del registry"

mkdir -p "${REGISTRY_DATA_DIR}"
chown -R root:root "${REGISTRY_DATA_DIR}"
chmod -R 755 "${REGISTRY_DATA_DIR}"
log_ok "Directorio creado: ${REGISTRY_DATA_DIR}"

# ============================================================================
# PASO 2: DETENER REGISTRY ANTERIOR SI EXISTE
# ============================================================================
log_step "Paso 2 — Limpiar instancia anterior del registry"

if podman ps -a --format "{{.Names}}" | grep -q "^${REGISTRY_CONTAINER_NAME}$"; then
    log_warn "Contenedor ${REGISTRY_CONTAINER_NAME} ya existe — eliminando..."
    podman stop "${REGISTRY_CONTAINER_NAME}" 2>/dev/null || true
    podman rm   "${REGISTRY_CONTAINER_NAME}" 2>/dev/null || true
    log_ok "Contenedor anterior eliminado."
else
    log_ok "No hay instancia anterior del registry."
fi

# Detener servicio systemd anterior si existe
if systemctl is-active --quiet "${REGISTRY_SERVICE_NAME}" 2>/dev/null; then
    systemctl stop "${REGISTRY_SERVICE_NAME}" 2>/dev/null || true
    log_ok "Servicio ${REGISTRY_SERVICE_NAME} detenido."
fi

# ============================================================================
# PASO 3: DESCARGAR IMAGEN DEL REGISTRY
# ============================================================================
log_step "Paso 3 — Descargando imagen registry:2"

# registry:2 es la imagen oficial de Docker Registry v2
# Es la implementación de referencia del protocolo OCI Distribution Spec
if podman images | grep -q "registry.*2\|library/registry"; then
    log_ok "Imagen registry:2 ya presente en Podman."
else
    log_info "Descargando registry:2 desde Docker Hub..."
    podman pull "${REGISTRY_IMAGE}"
    log_ok "Imagen registry:2 descargada."
fi

# ============================================================================
# PASO 4: INICIAR EL REGISTRY CON PODMAN
# ============================================================================
log_step "Paso 4 — Iniciando el registry local"

# Parámetros del contenedor:
#   --name          → nombre para identificarlo y controlarlo
#   -p 5000:5000    → exponer puerto en localhost (bind solo a loopback para seguridad)
#   -v              → montar directorio de datos persistente
#   -e REGISTRY_*   → configuración del registry v2
#   --restart=always → reiniciar automáticamente si falla
podman run -d \
    --name "${REGISTRY_CONTAINER_NAME}" \
    -p 127.0.0.1:5000:5000 \
    -v "${REGISTRY_DATA_DIR}:/var/lib/registry:Z" \
    -e REGISTRY_STORAGE_DELETE_ENABLED=true \
    -e REGISTRY_LOG_LEVEL=warn \
    --restart=always \
    "${REGISTRY_IMAGE}"

log_ok "Contenedor ${REGISTRY_CONTAINER_NAME} iniciado."

# Esperar a que el registry responda
log_info "Esperando que el registry esté listo..."
RETRIES=0
until curl -sf "http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/" > /dev/null 2>&1; do
    sleep 2
    RETRIES=$((RETRIES + 1))
    [ $RETRIES -ge 15 ] && die "El registry no respondió en 30 segundos."
    echo -n "."
done
echo ""
log_ok "Registry respondiendo en http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/"

# ============================================================================
# PASO 5: CREAR SERVICIO SYSTEMD PARA ARRANQUE AUTOMÁTICO
# ============================================================================
log_step "Paso 5 — Configurando servicio systemd"

# Generar el unit file de systemd desde Podman
# Esto crea un servicio que gestiona el ciclo de vida del contenedor
SYSTEMD_DIR="/etc/systemd/system"

cat > "${SYSTEMD_DIR}/${REGISTRY_SERVICE_NAME}.service" << EOF
# ── Servicio: Registry privado local de K3s ──────────────────────────────────
# Gestiona el contenedor del registry de imágenes Docker/OCI en localhost:5000
# Generado por 02-setup-registry.sh — TESOEM Infraestructura

[Unit]
Description=Registry privado local para K3s (puerto 5000)
Documentation=https://docs.docker.com/registry/
# Arrancar después de la red y de Podman
After=network-online.target
Wants=network-online.target
# Arrancar antes de K3s para que las imágenes estén disponibles cuando K3s inicie
Before=k3s.service

[Service]
Type=simple
Restart=always
RestartSec=10
# Arrancar el contenedor si está parado, o iniciarlo si no existe
ExecStart=/usr/bin/podman start -a ${REGISTRY_CONTAINER_NAME}
ExecStop=/usr/bin/podman stop -t 10 ${REGISTRY_CONTAINER_NAME}
# Si el contenedor no existe, crearlo antes de arrancar
ExecStartPre=/bin/bash -c '\
    podman ps -a --format "{{.Names}}" | grep -q "^${REGISTRY_CONTAINER_NAME}$" || \
    podman run -d \
        --name ${REGISTRY_CONTAINER_NAME} \
        -p 127.0.0.1:5000:5000 \
        -v ${REGISTRY_DATA_DIR}:/var/lib/registry:Z \
        -e REGISTRY_STORAGE_DELETE_ENABLED=true \
        -e REGISTRY_LOG_LEVEL=warn \
        --restart=always \
        ${REGISTRY_IMAGE}'
# Registrar PID para gestión correcta
KillMode=none
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${REGISTRY_SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${REGISTRY_SERVICE_NAME}"
log_ok "Servicio ${REGISTRY_SERVICE_NAME} habilitado para arranque automático."

# ============================================================================
# PASO 6: CONFIGURAR K3S PARA CONFIAR EN EL REGISTRY LOCAL
# ============================================================================
log_step "Paso 6 — Configurando K3s para usar el registry local"

# registries.yaml es el archivo de configuración de K3s para registries privados.
# Define mirrors (espejos) y credenciales para cada registry.
#
# mirrors: define con qué URL local reemplazar un registry remoto.
#   En este caso configuramos dos entradas:
#   1. "localhost:5000"       → el registry local (acceso directo)
#   2. "docker.io"            → redirigir búsquedas en Docker Hub al registry local
#                               si la imagen existe ahí, evita el pull de internet
#
# configs: configura propiedades del endpoint (TLS, autenticación).
#   insecure_skip_verify: true → no verificar certificado TLS (registry usa HTTP)
#
# IMPORTANTE: K3s debe reiniciarse para leer este archivo.

mkdir -p /etc/rancher/k3s

cat > "${K3S_REGISTRIES_FILE}" << EOF
# ── Configuración de registries para K3s ─────────────────────────────────────
# Archivo: /etc/rancher/k3s/registries.yaml
# Documentación: https://docs.k3s.io/installation/private-registry
#
# Este archivo configura K3s (containerd) para usar el registry local
# en localhost:5000 como fuente primaria de imágenes, eliminando la
# dependencia de Docker Hub para imágenes del proyecto.
#
# CÓMO FUNCIONA:
#   Cuando un pod solicita la imagen "localhost:5000/moodle-apache:5.1-k3s-raid",
#   containerd busca el mirror configurado para "localhost:5000" y descarga
#   directamente desde http://localhost:5000.
#
#   Cuando un pod solicita "docker.io/library/mariadb:lts" (imagen pública),
#   containerd primero intenta el mirror local; si no está ahí, cae a Docker Hub.

mirrors:
  # Registry local — acceso directo sin mirror, el endpoint ES el registry
  "localhost:5000":
    endpoint:
      - "http://localhost:5000"
  # También registrar por IP del nodo por si algún componente usa la IP directa
  "${NODE_IP}:5000":
    endpoint:
      - "http://localhost:5000"

configs:
  # Configuración del endpoint local:
  # insecure_skip_verify: el registry usa HTTP (sin TLS) → no verificar cert
  "localhost:5000":
    tls:
      insecure_skip_verify: true
  "${NODE_IP}:5000":
    tls:
      insecure_skip_verify: true
EOF

log_ok "Archivo ${K3S_REGISTRIES_FILE} creado."
cat "${K3S_REGISTRIES_FILE}"

# ============================================================================
# PASO 7: CONFIGURAR PODMAN PARA USAR EL REGISTRY LOCAL
# ============================================================================
log_step "Paso 7 — Configurando Podman para el registry local"

# registries.conf: configura Podman para buscar imágenes en el registry local
# antes que en Docker Hub. Esto permite usar nombres cortos sin prefijo.
#
# [registries.insecure]: registries sin TLS que Podman debe aceptar para push/pull

cat > /etc/containers/registries.conf << EOF
# ── Configuración de registries para Podman ───────────────────────────────────
# Orden de búsqueda: registry local primero, luego Docker Hub y Quay

[registries.search]
registries = ['localhost:5000', 'docker.io', 'quay.io']

# Registry local sin TLS — Podman lo trata como inseguro (HTTP)
[registries.insecure]
registries = ['localhost:5000', '${NODE_IP}:5000']

[registries.block]
registries = []
EOF

log_ok "registries.conf de Podman actualizado."

# ============================================================================
# PASO 8: REINICIAR K3S PARA APLICAR CONFIGURACIÓN DEL REGISTRY
# ============================================================================
log_step "Paso 8 — Reiniciando K3s para aplicar la configuración del registry"

log_info "Reiniciando K3s (tardará ~30 segundos)..."
systemctl restart k3s

# Esperar a que K3s vuelva a estar disponible
RETRIES=0
until kubectl cluster-info &>/dev/null 2>&1; do
    sleep 5
    RETRIES=$((RETRIES + 1))
    [ $RETRIES -ge 24 ] && die "K3s no respondió tras el reinicio en 120s."
    echo -n "."
done
echo ""
log_ok "K3s reiniciado y API server disponible."

# Verificar que el nodo está Ready
kubectl wait --for=condition=Ready node --all --timeout=60s 2>/dev/null \
    && log_ok "Nodo en estado Ready." \
    || log_warn "El nodo tardó en estar Ready — puede necesitar unos segundos más."

# ============================================================================
# PASO 9: VERIFICACIÓN COMPLETA
# ============================================================================
log_step "Paso 9 — Verificación del registry"

echo ""
echo -e "  ${BOLD}Estado del contenedor registry:${NC}"
podman ps --filter "name=${REGISTRY_CONTAINER_NAME}" \
    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo -e "  ${BOLD}API del registry:${NC}"
REGISTRY_RESPONSE=$(curl -sf "http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/" 2>/dev/null && echo "OK" || echo "FAIL")
if [ "${REGISTRY_RESPONSE}" = "OK" ]; then
    log_ok "http://localhost:5000/v2/ → responde correctamente"
else
    log_warn "El registry no responde en http://localhost:5000/v2/"
fi

echo ""
echo -e "  ${BOLD}Imágenes en el registry (catálogo):${NC}"
CATALOG=$(curl -sf "http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/_catalog" 2>/dev/null || echo '{"repositories":[]}')
echo "  ${CATALOG}"
log_info "El catálogo estará vacío hasta que se haga el primer push."

echo ""
echo -e "  ${BOLD}Servicio systemd:${NC}"
systemctl is-active "${REGISTRY_SERVICE_NAME}" \
    && log_ok "Servicio ${REGISTRY_SERVICE_NAME}: activo" \
    || log_warn "Servicio ${REGISTRY_SERVICE_NAME}: inactivo"
systemctl is-enabled "${REGISTRY_SERVICE_NAME}" \
    && log_ok "Servicio ${REGISTRY_SERVICE_NAME}: habilitado en arranque" \
    || log_warn "Servicio ${REGISTRY_SERVICE_NAME}: no habilitado"

echo ""
echo -e "  ${BOLD}Configuración K3s registries:${NC}"
[ -f "${K3S_REGISTRIES_FILE}" ] \
    && log_ok "${K3S_REGISTRIES_FILE} presente" \
    || log_warn "${K3S_REGISTRIES_FILE} no encontrado"

# ── Resumen y próximos pasos ──────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║       REGISTRY LOCAL INSTALADO Y CONFIGURADO                 ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Registry URL:${NC}  http://localhost:5000"
echo -e "  ${BOLD}Catálogo:${NC}      http://localhost:5000/v2/_catalog"
echo -e "  ${BOLD}Datos:${NC}         ${REGISTRY_DATA_DIR}"
echo ""
echo -e "  ${BOLD}Próximo paso — construir y publicar la imagen:${NC}"
echo ""
echo -e "  ${CYAN}./05-build-image.sh${NC}"
echo ""
echo -e "  El script 05 hará:"
echo -e "    podman build -t localhost:5000/moodle-apache:5.1-k3s-raid ."
echo -e "    podman push  localhost:5000/moodle-apache:5.1-k3s-raid"
echo ""
echo -e "  Luego ejecutar el despliegue:"
echo -e "  ${CYAN}./06-deploy-all.sh${NC}"
echo ""
echo -e "  Completado — $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
