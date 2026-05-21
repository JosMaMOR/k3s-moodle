#!/bin/bash
# ============================================================================
# 05-build-image.sh
# Build de la imagen Moodle con Podman y push al registry local (localhost:5000)
#
# PROPÓSITO:
#   Construye la imagen Docker/OCI de Moodle usando Podman y la publica
#   en el registry privado local (localhost:5000). Desde ahí, K3s/containerd
#   la descarga directamente cuando crea los pods, sin depender de Docker Hub.
#
# FLUJO DE LA IMAGEN:
#   Dockerfile
#       │
#       ▼  podman build
#   localhost:5000/moodle-apache:5.1-k3s-raid  (en registry local)
#       │
#       ▼  containerd pull (automático al crear pods)
#   Pod moodle-xxx en K3s
#
# CAMBIOS RESPECTO A VERSIÓN ANTERIOR:
#   - Tag de imagen cambiado de "moodle-apache:5.1-k3s-raid"
#     a "localhost:5000/moodle-apache:5.1-k3s-raid"
#   - Se añade paso de push al registry local después del build
#   - Se verifica que el registry esté disponible antes de construir
#   - Se elimina el paso de importación manual a containerd
#     (ya no es necesario — K3s hace pull desde el registry)
#
# USO:
#   chmod +x 05-build-image.sh
#   ./05-build-image.sh
#
#   Variables de entorno opcionales:
#     BUILD_CONTEXT="/ruta/al/contexto"   # directorio con el Dockerfile
#     DOCKERFILE="Dockerfile.custom"       # nombre del Dockerfile
#     NO_CACHE=true                        # construir sin cache de capas
#
# REQUISITOS:
#   - Podman instalado
#   - Registry local corriendo en localhost:5000 (02-setup-registry.sh)
#   - Dockerfile y contexto de build disponibles
#   - Ejecutar como root
#
# AUTOR: Infraestructura TESOEM
# VERSIÓN: 2.0 (con registry local)
# ============================================================================

set -euo pipefail

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Variables configurables ───────────────────────────────────────────────────
REGISTRY_HOST="localhost"
REGISTRY_PORT="5000"
IMAGE_NAME="moodle-apache"
IMAGE_TAG="${IMAGE_TAG:-5.1-k3s-raid}"
# El nombre completo incluye el registry para que Podman sepa dónde hacer push
FULL_IMAGE="${REGISTRY_HOST}:${REGISTRY_PORT}/${IMAGE_NAME}:${IMAGE_TAG}"

# Directorio del contexto de build (donde está el Dockerfile)
BUILD_CONTEXT="${BUILD_CONTEXT:-/root/k3s-moodle/build}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"

# Opciones de build
NO_CACHE="${NO_CACHE:-false}"

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
echo "  ║     BUILD + PUSH — Imagen Moodle → Registry Local           ║"
echo "  ║     TESOEM — Plataforma Educativa K3s                       ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Imagen:    ${CYAN}${FULL_IMAGE}${NC}"
echo -e "  Contexto:  ${CYAN}${BUILD_CONTEXT}${NC}"
echo -e "  Dockerfile:${CYAN}${DOCKERFILE}${NC}"
echo -e "  Sin caché: ${CYAN}${NO_CACHE}${NC}"
echo ""

# ============================================================================
# PASO 1: VERIFICAR PREREQUISITOS
# ============================================================================
log_step "Paso 1 — Verificando prerequisitos"

# Verificar Podman
command -v podman &>/dev/null || die "Podman no está instalado. Ejecuta 01-prepare-almalinux9.sh"
log_ok "Podman: $(podman --version)"

# Verificar que el registry local está corriendo
log_info "Verificando registry en http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/ ..."
if ! curl -sf "http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/" > /dev/null 2>&1; then
    die "Registry local no disponible en localhost:${REGISTRY_PORT}.\n  Ejecuta primero: ./02-setup-registry.sh"
fi
log_ok "Registry local disponible en http://${REGISTRY_HOST}:${REGISTRY_PORT}"

# Verificar contexto de build
if [ ! -d "${BUILD_CONTEXT}" ]; then
    die "Directorio de build no encontrado: ${BUILD_CONTEXT}\n  Ajusta BUILD_CONTEXT o crea el directorio con el Dockerfile."
fi
log_ok "Directorio de build: ${BUILD_CONTEXT}"

if [ ! -f "${BUILD_CONTEXT}/${DOCKERFILE}" ]; then
    die "Dockerfile no encontrado: ${BUILD_CONTEXT}/${DOCKERFILE}"
fi
log_ok "Dockerfile encontrado: ${DOCKERFILE}"

# Mostrar contenido del directorio de build
echo ""
log_info "Contenido del contexto de build:"
ls -lh "${BUILD_CONTEXT}/" | head -20

# ============================================================================
# PASO 2: BUILD DE LA IMAGEN CON PODMAN
# ============================================================================
log_step "Paso 2 — Construyendo imagen con Podman"

log_info "Iniciando build — esto puede tardar 5-15 minutos en el primer build..."
log_info "Las capas en cache se reutilizan en builds posteriores."
echo ""

# Construir opciones de build
BUILD_OPTS="--format=docker"  # formato Docker para máxima compatibilidad con registry v2
[ "${NO_CACHE}" = "true" ] && BUILD_OPTS="${BUILD_OPTS} --no-cache"

# El tag incluye el registry (localhost:5000/) para que podman push
# sepa automáticamente a dónde enviar la imagen
BUILD_START=$(date +%s)

podman build \
    ${BUILD_OPTS} \
    -t "${FULL_IMAGE}" \
    -f "${BUILD_CONTEXT}/${DOCKERFILE}" \
    "${BUILD_CONTEXT}"

BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))

echo ""
log_ok "Build completado en ${BUILD_DURATION} segundos."

# Mostrar información de la imagen construida
echo ""
log_info "Imagen construida:"
podman images "${REGISTRY_HOST}:${REGISTRY_PORT}/${IMAGE_NAME}" \
    --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.Created}}"

# ============================================================================
# PASO 3: PUSH AL REGISTRY LOCAL
# ============================================================================
log_step "Paso 3 — Publicando imagen en el registry local"

log_info "Enviando ${FULL_IMAGE} a localhost:${REGISTRY_PORT}..."
log_info "Esto transfiere las capas al registry — puede tardar 1-3 minutos..."
echo ""

# --tls-verify=false: el registry local usa HTTP (sin TLS)
# Podman ya tiene configurado el registry como inseguro en registries.conf,
# pero el flag explícito evita warnings y asegura el comportamiento correcto
PUSH_START=$(date +%s)

podman push \
    --tls-verify=false \
    "${FULL_IMAGE}"

PUSH_END=$(date +%s)
PUSH_DURATION=$((PUSH_END - PUSH_START))

echo ""
log_ok "Push completado en ${PUSH_DURATION} segundos."

# ============================================================================
# PASO 4: VERIFICAR QUE LA IMAGEN ESTÁ EN EL REGISTRY
# ============================================================================
log_step "Paso 4 — Verificando imagen en el registry"

# Verificar catálogo del registry
log_info "Catálogo del registry:"
CATALOG=$(curl -sf "http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/_catalog" 2>/dev/null)
echo "  ${CATALOG}"

# Verificar tags de la imagen específica
log_info "Tags disponibles para ${IMAGE_NAME}:"
TAGS=$(curl -sf "http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/${IMAGE_NAME}/tags/list" 2>/dev/null)
echo "  ${TAGS}"

if echo "${TAGS}" | grep -q "${IMAGE_TAG}"; then
    log_ok "Imagen ${FULL_IMAGE} disponible en el registry."
else
    log_warn "La imagen no aparece en el catálogo — puede tardar unos segundos."
fi

# ============================================================================
# PASO 5: VERIFICAR QUE K3S PUEDE RESOLVER LA IMAGEN
# ============================================================================
log_step "Paso 5 — Verificando acceso desde containerd (K3s)"

# Intentar hacer pull desde containerd directamente para confirmar
# que K3s puede acceder al registry antes de desplegar
log_info "Probando pull desde containerd (k8s.io)..."

if ctr -n k8s.io images pull \
    --plain-http \
    "${FULL_IMAGE}" > /dev/null 2>&1; then
    log_ok "containerd puede descargar la imagen desde el registry local."
    ctr -n k8s.io images ls | grep "${IMAGE_NAME}" | head -3
else
    log_warn "Pull de prueba falló — verifica que K3s tenga registries.yaml configurado."
    log_info "  cat /etc/rancher/k3s/registries.yaml"
    log_info "  systemctl restart k3s"
fi

# ── Resumen final ─────────────────────────────────────────────────────────────
TOTAL_DURATION=$((BUILD_DURATION + PUSH_DURATION))

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║       BUILD Y PUSH COMPLETADOS                               ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Imagen publicada:${NC}"
echo -e "    ${CYAN}${FULL_IMAGE}${NC}"
echo ""
echo -e "  ${BOLD}Tiempo total:${NC}  ${TOTAL_DURATION}s (build: ${BUILD_DURATION}s, push: ${PUSH_DURATION}s)"
echo ""
echo -e "  ${BOLD}Verificar registry:${NC}"
echo -e "    ${CYAN}curl http://localhost:5000/v2/_catalog${NC}"
echo -e "    ${CYAN}curl http://localhost:5000/v2/moodle-apache/tags/list${NC}"
echo ""
echo -e "  ${BOLD}Próximo paso — desplegar Moodle:${NC}"
echo -e "    ${CYAN}./06-deploy-all.sh${NC}"
echo ""
echo -e "  Completado — $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
