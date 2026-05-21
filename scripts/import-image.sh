#!/bin/bash
# import-image.sh
# Importa la imagen Moodle de Podman al namespace k8s.io de containerd.
# Ejecutar después de 05-build-image.sh y antes de 06-deploy-all.sh
#
# Uso: ./import-image.sh [imagen:tag]
# Ejemplo: ./import-image.sh moodle-apache:5.1-k3s-raid

set -euo pipefail

IMAGE="${1:-moodle-apache:5.1-k3s-raid}"
echo "[*] Importando imagen ${IMAGE} a containerd k8s.io..."

if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${IMAGE}$"; then
  echo "[!] Imagen ${IMAGE} no encontrada en Podman."
  echo "    Construye primero con: ./05-build-image.sh"
  exit 1
fi

echo "[*] Tamaño de la imagen:"
podman images "${IMAGE%%:*}" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"

echo "[*] Exportando e importando (puede tardar varios minutos)..."
podman save "${IMAGE}" | ctr -n k8s.io images import -

echo "[*] Verificando en containerd:"
ctr -n k8s.io images ls | grep "${IMAGE%%:*}"

echo "[✓] Imagen disponible para K3s."
