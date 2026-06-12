#!/bin/bash
# ======================================================
# cleanup-node.sh
# Limpia una instalacion de K3s en un nodo (server o agent)
# para dejarlo listo para re-unirse al cluster desde cero.
#
# USO: ejecutar como root EN EL NODO que se quiere limpiar
#      (NO en el nodo A / control-plane principal).
# ======================================================

set -uo pipefail   # nota: sin -e; queremos continuar aunque algo no exista

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_ok()   { echo -e "  ${GREEN}\u2713${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}\u26a0${NC}  $1"; }
log_info() { echo -e "  ${CYAN}\u2139${NC} $1"; }

[ "$EUID" -eq 0 ] || { echo -e "${RED}Debe ejecutarse como root.${NC}"; exit 1; }

echo ""
echo -e "${CYAN}=== Limpieza de nodo K3s ===${NC}"
echo ""

# ── Salvaguarda: no correr esto en el control-plane principal ──────────────────
# Si existe el directorio de etcd, este nodo es un server con datos de cluster.
# Avisamos para evitar destruir el nodo A por accidente.
if [ -d /var/lib/rancher/k3s/server/db/etcd ]; then
  log_warn "Este nodo tiene datos de etcd (es un control-plane con estado)."
  log_warn "Si es el NODO A principal, NO continues — perderias el cluster."
  read -r -p "  ¿Seguro que quieres limpiar este nodo? (escribe 'si'): " CONFIRM
  [ "${CONFIRM}" = "si" ] || { echo "  Cancelado."; exit 0; }
fi

# ── 1. Ejecutar el uninstaller oficial de K3s (si existe) ──────────────────────
# K3s instala uno u otro segun haya sido server o agent.
log_info "Buscando uninstaller de K3s..."
if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
  log_info "Ejecutando k3s-uninstall.sh (nodo server)..."
  /usr/local/bin/k3s-uninstall.sh && log_ok "K3s server desinstalado."
elif [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then
  log_info "Ejecutando k3s-agent-uninstall.sh (nodo agent)..."
  /usr/local/bin/k3s-agent-uninstall.sh && log_ok "K3s agent desinstalado."
else
  log_warn "No se encontro uninstaller de K3s — quizas no estaba instalado."
fi

# ── 2. Quitar paquetes SELinux que el instalador agrega ────────────────────────
# El instalador de K3s instala k3s-selinux (y este arrastra container-selinux).
log_info "Removiendo paquetes SELinux de K3s..."
for pkg in k3s-selinux container-selinux; do
  if rpm -q "${pkg}" &>/dev/null; then
    dnf remove -y "${pkg}" &>/dev/null && log_ok "${pkg} removido." \
      || log_warn "No se pudo remover ${pkg} (¿lo usa otra cosa?)."
  else
    log_info "${pkg} no estaba instalado."
  fi
done

# ── 3. Limpiar restos de configuracion y datos ─────────────────────────────────
# El uninstaller suele borrar la mayoria, pero por si quedan restos:
log_info "Limpiando directorios residuales..."
for dir in /etc/rancher/k3s /var/lib/rancher/k3s /var/lib/kubelet /run/k3s /run/flannel; do
  if [ -e "${dir}" ]; then
    rm -rf "${dir}" && log_ok "Eliminado: ${dir}"
  fi
done

# ── 4. Verificacion final ──────────────────────────────────────────────────────
echo ""
if command -v k3s &>/dev/null; then
  log_warn "El binario 'k3s' aun existe en el PATH — revisa manualmente."
else
  log_ok "K3s ya no esta presente. Nodo limpio."
fi

# Mostrar paquetes selinux restantes para verificar
echo ""
log_info "Paquetes *-selinux restantes:"
rpm -qa | grep -iE "k3s-selinux|container-selinux" || echo "    (ninguno)"

echo ""
echo -e "${GREEN}=== Limpieza completada ===${NC}"
echo "  El nodo esta listo para re-ejecutar 07-join-nodes.sh"
echo ""
