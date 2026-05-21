#!/bin/bash
# 05-build-image.sh - Construcción de imagen Moodle para K3s
# Ejecutar como root después de los scripts 00-04

set -e

echo "=========================================="
echo "CONSTRUCCIÓN DE IMAGEN MOODLE K3s"
echo "=========================================="

BUILD_DIR="/root/k3s-moodle/build"
IMAGE_TAG="5.1-k3s-raid"
IMAGE_NAME="moodle-apache:${IMAGE_TAG}"

cd ${BUILD_DIR}

# ==========================================
# 1. VERIFICAR PREREQUISITOS
# ==========================================
echo "[*] Verificando prerequisitos..."

# Verificar código de Moodle
if [ ! -d "moodle" ] || [ ! -f "moodle/index.php" ]; then
    echo "✗ ERROR: No se encontró código de Moodle en ${BUILD_DIR}/moodle/"
    echo ""
    echo "Para descargar Moodle 5.1.1:"
    echo "  cd ${BUILD_DIR}"
    echo "  curl -L https://github.com/moodle/moodle/archive/refs/tags/v5.1.1.tar.gz | tar xz"
    echo "  mv moodle-5.1.1 moodle"
    echo ""
    exit 1
fi

echo "✓ Código de Moodle encontrado"

# Verificar Dockerfile
if [ ! -f "Dockerfile" ]; then
    echo "✗ ERROR: No se encontró Dockerfile en ${BUILD_DIR}/"
    exit 1
fi

echo "✓ Dockerfile encontrado"

# Verificar entrypoint.sh
if [ ! -f "entrypoint.sh" ]; then
    echo "✗ ERROR: No se encontró entrypoint.sh en ${BUILD_DIR}/"
    exit 1
fi

chmod +x entrypoint.sh
echo "✓ entrypoint.sh encontrado y ejecutable"

# Verificar K3s está corriendo
if ! systemctl is-active --quiet k3s; then
    echo "✗ ERROR: K3s no está corriendo"
    exit 1
fi

echo "✓ K3s está activo"

# ==========================================
# 2. DETECTAR CONTAINER RUNTIME
# ==========================================
echo "[*] Detectando container runtime..."

if command -v docker &> /dev/null && systemctl is-active --quiet docker 2>/dev/null; then
    RUNTIME="docker"
    echo "✓ Docker detectado y activo"
elif command -v podman &> /dev/null; then
    RUNTIME="podman"
    echo "✓ Podman detectado"
else
    echo "Instalando Docker..."
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io
    systemctl enable --now docker
    RUNTIME="docker"
    echo "✓ Docker instalado y activo"
fi

# ==========================================
# 3. CONSTRUIR IMAGEN
# ==========================================
echo "[*] Construyendo imagen ${IMAGE_NAME}..."

if [ "${RUNTIME}" = "docker" ]; then
    docker build -t ${IMAGE_NAME} .
elif [ "${RUNTIME}" = "podman" ]; then
    podman build -t ${IMAGE_NAME} .
fi

echo "✓ Imagen construida"

# ==========================================
# 4. EXPORTAR E IMPORTAR A K3s
# ==========================================
echo "[*] Importando imagen a K3s..."

if [ "${RUNTIME}" = "docker" ]; then
    docker save ${IMAGE_NAME} | k3s ctr images import -
elif [ "${RUNTIME}" = "podman" ]; then
    podman save ${IMAGE_NAME} | k3s ctr images import -
fi

echo "✓ Imagen importada a K3s"

# ==========================================
# 5. VERIFICAR IMPORTACIÓN
# ==========================================
echo "[*] Verificando imagen en K3s..."

if k3s ctr images list | grep -q "moodle-apache"; then
    echo "✓ Imagen disponible en K3s:"
    k3s ctr images list | grep "moodle-apache" | head -1
else
    echo "⚠ No se pudo verificar imagen, pero el proceso continuó"
fi

# ==========================================
# 6. EXPORTAR PARA BACKUP (OPCIONAL)
# ==========================================
echo "[*] Exportando imagen para backup..."

if [ "${RUNTIME}" = "docker" ]; then
    docker save ${IMAGE_NAME} -o /root/k3s-moodle/moodle-apache-${IMAGE_TAG}.tar
elif [ "${RUNTIME}" = "podman" ]; then
    podman save ${IMAGE_NAME} -o /root/k3s-moodle/moodle-apache-${IMAGE_TAG}.tar
fi

echo "✓ Imagen exportada: /root/k3s-moodle/moodle-apache-${IMAGE_TAG}.tar"

echo ""
echo "=========================================="
echo "IMAGEN CONSTRUIDA E IMPORTADA"
echo "=========================================="
echo ""
echo "Imagen: ${IMAGE_NAME}"
echo "Tag: ${IMAGE_TAG}"
echo ""
echo "Próximo paso: ./06-deploy-all.sh"
