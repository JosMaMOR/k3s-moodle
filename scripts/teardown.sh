#!/usr/bin/env bash
# ============================================================================
# 00-teardown.sh — Apagado, limpieza y desinstalación del cluster Moodle HA
# ----------------------------------------------------------------------------
# Unifica: 00-clean-stack.sh, 00-cleanup-all.sh, 00-clean-longhorn.sh,
#          00-cleanup-k3s.sh y node-cleanup.sh
#
# MODOS (exactamente uno, obligatorio):
#
#   --stack     Apaga y elimina el stack de aplicación (namespace moodle-prod,
#               releases de Helm, PVCs). Conserva: k3s, Longhorn, kube-vip,
#               imágenes, y los datos en /moodlek3s y en volúmenes Longhorn.
#               Objetivo: volver a correr 04-deploy-all.sh.
#
#   --data      Todo lo de --stack + borra los volúmenes Longhorn del stack,
#               el contenido de /moodlek3s/{mariadb,redis,moodle-html,
#               moodle-data,longhorn} y la caché (logs de pods, PVs Released).
#               Conserva: k3s, Longhorn instalado, kube-vip e IMÁGENES.
#               Objetivo: despliegue desde cero sin reinstalar k3s ni
#               reconstruir la imagen de Moodle ni la de garbd.
#
#   --node      Desconecta un nodo del cluster (cordon + drain + delete node,
#               lo que retira su miembro de etcd) y lo deja limpio para
#               re-unirse. Requiere --target <hostname>.
#
#   --purge     Todo lo de --data + desinstala k3s, borra imágenes de
#               containerd y Podman, interfaces de red residuales, kubeconfig
#               y entradas de /etc/hosts. Objetivo: instalación 100% limpia
#               desde 01-prepare-almalinux9.sh.
#
# OPCIONES:
#   --dry-run           Muestra qué haría, sin ejecutar nada.
#   --yes               Omite la confirmación escrita (para automatización).
#   --clean-volumes     Solo con --stack: además borra volúmenes Longhorn
#                       huérfanos/faulted (los sanos se conservan).
#   --keep-images       Solo con --purge: conserva las imágenes de Podman
#                       (las de containerd mueren con k3s de todas formas).
#   --target <host>     Solo con --node: hostname del nodo a desconectar.
#   --local-only        Solo con --node: omite la parte de cluster; asume que
#                       el nodo ya fue borrado desde el control-plane.
#   --force             Solo con --node: permite desconectar el nodo primario.
#
# EJEMPLOS:
#   sudo ./00-teardown.sh --stack
#   sudo ./00-teardown.sh --data --dry-run
#   sudo ./00-teardown.sh --node --target node-b-k3s-moodle    # desde nodo A
#   sudo ./00-teardown.sh --node --target node-b-k3s-moodle --local-only  # en B
#   sudo ./00-teardown.sh --purge --keep-images
# ============================================================================

set -uo pipefail

# sudo en AlmaLinux 9 usa un secure_path que excluye /usr/local/bin,
# donde viven k3s, kubectl, crictl y ctr.
export PATH="${PATH}:/usr/local/bin:/usr/bin"

# ── Configuración ─────────────────────────────────────────────────────────────
NAMESPACE="moodle-prod"
LONGHORN_NS="longhorn-system"
RAID_BASE="/moodlek3s"
PRIMARY_NODE="k3s-moodle-master"

# Subdirectorios de /moodlek3s que se vacían en --data / --purge.
RAID_SUBDIRS=("mariadb" "redis" "moodle-html" "moodle-data" "longhorn")

# PVCs del stack cuyos volúmenes gestiona Longhorn.
MOODLE_PVCS=("moodle-html-pvc" "moodle-data-pvc")

# Imágenes de Podman que se conservan en --purge --keep-images.
PODMAN_KEEP_PATTERN="galera-arbitrator|moodle-apache"

# ── Colores ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; NC=""
fi

log_step() { echo ""; echo "${BLUE}${BOLD}[$1]${NC} $2"; }
log_ok()   { echo "  ${GREEN}✓${NC} $1"; }
log_warn() { echo "  ${YELLOW}⚠${NC} $1"; }
log_skip() { echo "  ${CYAN}→${NC} $1 ${CYAN}(omitido)${NC}"; }
log_err()  { echo "  ${RED}✗${NC} $1"; }

# ── Flags ─────────────────────────────────────────────────────────────────────
MODE=""
DRY_RUN=false
ASSUME_YES=false
CLEAN_VOLUMES=false
KEEP_IMAGES=false
LOCAL_ONLY=false
FORCE=false
TARGET_NODE=""

usage() {
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

set_mode() {
  if [ -n "$MODE" ]; then
    echo "${RED}Error: --stack, --data, --node y --purge son mutuamente excluyentes.${NC}" >&2
    exit 1
  fi
  MODE="$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --stack)         set_mode stack ;;
    --data)          set_mode data ;;
    --node)          set_mode node ;;
    --purge)         set_mode purge ;;
    --dry-run)       DRY_RUN=true ;;
    --yes|-y)        ASSUME_YES=true ;;
    --clean-volumes) CLEAN_VOLUMES=true ;;
    --keep-images)   KEEP_IMAGES=true ;;
    --local-only)    LOCAL_ONLY=true ;;
    --force)         FORCE=true ;;
    --target)        shift; TARGET_NODE="${1:-}" ;;
    -h|--help)       usage 0 ;;
    *) echo "${RED}Argumento desconocido: $1${NC}" >&2; usage 1 ;;
  esac
  shift
done

[ -z "$MODE" ] && usage 0

if [ "$MODE" = "node" ] && [ -z "$TARGET_NODE" ]; then
  echo "${RED}El modo --node requiere --target <hostname>.${NC}" >&2
  exit 1
fi

[ "$EUID" -eq 0 ] || { echo "${RED}Este script debe ejecutarse como root.${NC}" >&2; exit 1; }

# ── Ejecución con soporte de dry-run ──────────────────────────────────────────
# run: comando con argumentos, sin shell.  sh_run: cadena evaluada por el shell
# (para pipes y redirecciones).  Ambos son best-effort: nunca abortan el script.
run() {
  if [ "$DRY_RUN" = true ]; then
    echo "  ${CYAN}[DRY-RUN]${NC} $*"
  else
    "$@" >/dev/null 2>&1 || true
  fi
}

sh_run() {
  if [ "$DRY_RUN" = true ]; then
    echo "  ${CYAN}[DRY-RUN]${NC} $*"
  else
    bash -c "$*" >/dev/null 2>&1 || true
  fi
}

k8s_up() {
  command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1
}

# ── Confirmación ──────────────────────────────────────────────────────────────
declare -A MODE_DESC=(
  [stack]="Elimina el stack de aplicación. Conserva datos, volúmenes, k3s e imágenes."
  [data]="Elimina el stack, los volúmenes Longhorn y TODOS los datos de ${RAID_BASE}."
  [node]="Desconecta el nodo '${TARGET_NODE}' del cluster y desinstala k3s en él."
  [purge]="Elimina TODO: stack, datos, k3s, imágenes y configuración residual."
)
declare -A MODE_WORD=([stack]="STACK" [data]="DATA" [node]="NODE" [purge]="PURGE")

confirm() {
  echo ""
  echo "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo "${BOLD}  TEARDOWN — modo: ${MODE_WORD[$MODE]}${NC}"
  echo "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo "  ${MODE_DESC[$MODE]}"
  echo ""

  case "$MODE" in
    stack)
      echo "  ${GREEN}Conserva:${NC} ${RAID_BASE}, volúmenes Longhorn, k3s, kube-vip, imágenes"
      [ "$CLEAN_VOLUMES" = true ] && \
        echo "  ${YELLOW}Además:${NC} borra volúmenes Longhorn faulted/huérfanos (--clean-volumes)"
      ;;
    data)
      echo "  ${RED}Destruye:${NC} volúmenes Longhorn del stack + contenido de ${RAID_BASE}"
      echo "  ${GREEN}Conserva:${NC} k3s, Longhorn instalado, kube-vip, imágenes de containerd/Podman"
      ;;
    node)
      echo "  ${RED}Destruye:${NC} k3s en '${TARGET_NODE}' y su membresía de etcd"
      [ "$LOCAL_ONLY" = true ] && echo "  ${CYAN}Modo:${NC} solo limpieza local (sin tocar el cluster)"
      ;;
    purge)
      echo "  ${RED}Destruye:${NC} k3s, etcd, ${RAID_BASE}, imágenes containerd"
      if [ "$KEEP_IMAGES" = true ]; then
        echo "  ${GREEN}Conserva:${NC} imágenes de Podman (${PODMAN_KEEP_PATTERN})"
      else
        echo "  ${RED}Destruye:${NC} también las imágenes de Podman"
      fi
      ;;
  esac
  echo ""

  if [ "$DRY_RUN" = true ]; then
    echo "  ${CYAN}MODO DRY-RUN: no se ejecutará nada.${NC}"
    echo ""
    return
  fi
  if [ "$ASSUME_YES" = true ]; then
    log_warn "Confirmación omitida (--yes)."
    echo ""
    return
  fi

  echo -ne "  Escribe ${BOLD}${MODE_WORD[$MODE]}${NC} para continuar: "
  read -r reply
  if [ "$reply" != "${MODE_WORD[$MODE]}" ]; then
    echo ""
    echo "  ${GREEN}Cancelado. No se modificó nada.${NC}"
    exit 0
  fi
  echo ""
}

# ============================================================================
# BLOQUE 1 — Derribo del stack de aplicación
# ============================================================================
teardown_stack() {
  log_step "1" "Derribando el stack en el namespace ${NAMESPACE}..."

  if ! k8s_up; then
    log_warn "Cluster no accesible — se omite el derribo de recursos Kubernetes."
    return
  fi
  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    log_skip "El namespace ${NAMESPACE} no existe"
    return
  fi

  # Suspender el cronjob primero: evita que nazcan pods durante el derribo.
  run kubectl patch cronjob moodle-cron -n "$NAMESPACE" -p '{"spec":{"suspend":true}}'
  log_ok "CronJob moodle-cron suspendido."

  # Escalar a 0 antes de borrar: libera los PVCs de forma ordenada y evita
  # que Longhorn marque volúmenes como faulted por desmontaje abrupto.
  sh_run "kubectl get deployment -n ${NAMESPACE} -o name | xargs -r kubectl scale -n ${NAMESPACE} --replicas=0"
  sh_run "kubectl get statefulset -n ${NAMESPACE} -o name | xargs -r kubectl scale -n ${NAMESPACE} --replicas=0"
  log_ok "Deployments y StatefulSets escalados a 0."

  log_ok "Esperando terminación de pods (máx 120s)..."
  run kubectl wait --for=delete pod --all -n "$NAMESPACE" --timeout=120s

  # Helm primero: si borras el namespace antes, la release queda huérfana en
  # el secret de Helm y un `helm install` posterior falla por nombre en uso.
  if command -v helm &>/dev/null; then
    local releases
    releases="$(helm list -n "$NAMESPACE" -q 2>/dev/null || true)"
    if [ -n "$releases" ]; then
      while read -r rel; do
        [ -z "$rel" ] && continue
        run helm uninstall "$rel" -n "$NAMESPACE" --wait --timeout 120s
        log_ok "Release de Helm desinstalada: ${rel}"
      done <<< "$releases"
    else
      log_skip "No hay releases de Helm en ${NAMESPACE}"
    fi
  else
    log_warn "helm no encontrado — las releases no se desinstalaron limpiamente."
  fi

  log_ok "Eliminando Ingress, Middleware, HPA y PDB..."
  run kubectl delete ingress --all -n "$NAMESPACE" --ignore-not-found=true
  run kubectl delete middleware.traefik.io --all -n "$NAMESPACE" --ignore-not-found=true
  run kubectl delete hpa --all -n "$NAMESPACE" --ignore-not-found=true
  run kubectl delete pdb --all -n "$NAMESPACE" --ignore-not-found=true

  log_ok "Eliminando CronJobs, Jobs, Deployments y StatefulSets..."
  run kubectl delete cronjob --all -n "$NAMESPACE" --ignore-not-found=true
  run kubectl delete job --all -n "$NAMESPACE" --ignore-not-found=true
  run kubectl delete deployment --all -n "$NAMESPACE" --ignore-not-found=true
  run kubectl delete statefulset --all -n "$NAMESPACE" --ignore-not-found=true

  log_ok "Eliminando Services, ConfigMaps y Secrets..."
  run kubectl delete service --all -n "$NAMESPACE" --ignore-not-found=true
  run kubectl delete configmap --all -n "$NAMESPACE" --ignore-not-found=true
  run kubectl delete secret --all -n "$NAMESPACE" --ignore-not-found=true

  # PVCs: los finalizers de Longhorn los dejan en Terminating si el pod que
  # los montaba murió mal. Se parchea el finalizer antes de borrar.
  log_ok "Eliminando PersistentVolumeClaims..."
  local pvcs
  pvcs="$(kubectl get pvc -n "$NAMESPACE" -o name 2>/dev/null || true)"
  if [ -n "$pvcs" ]; then
    while read -r pvc; do
      [ -z "$pvc" ] && continue
      run kubectl patch "$pvc" -n "$NAMESPACE" --type=merge -p '{"metadata":{"finalizers":null}}'
      run kubectl delete "$pvc" -n "$NAMESPACE" --ignore-not-found=true --timeout=30s
      log_ok "  ${pvc}"
    done <<< "$pvcs"
  else
    log_skip "No hay PVCs"
  fi

  log_ok "Eliminando namespace ${NAMESPACE}..."
  run kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --timeout=90s

  # Un namespace atascado en Terminating casi siempre es un finalizer de un
  # recurso custom (Longhorn, Traefik) que ya no tiene controlador.
  if [ "$DRY_RUN" = false ]; then
    local retries=0
    while kubectl get namespace "$NAMESPACE" &>/dev/null; do
      sleep 3
      retries=$((retries + 1))
      if [ "$retries" -ge 20 ]; then
        log_warn "Namespace atascado en Terminating — forzando finalizers."
        kubectl get namespace "$NAMESPACE" -o json 2>/dev/null \
          | sed 's/"kubernetes"//' \
          | kubectl replace --raw "/api/v1/namespaces/${NAMESPACE}/finalize" -f - &>/dev/null || true
        break
      fi
    done
  fi
  log_ok "Stack derribado."
}

# ============================================================================
# BLOQUE 2 — Volúmenes Longhorn
# ----------------------------------------------------------------------------
# reclaimPolicy: Retain es una decisión de diseño: al borrar el PVC, el volumen
# sobrevive. La contraparte es que entre corridas se acumulan volúmenes
# huérfanos y faulted que consumen disco y rompen el aprovisionamiento.
#   $1 = "unhealthy" (solo faulted/unknown/huérfanos) | "nuke" (todos los de Moodle)
# ============================================================================
delete_longhorn_volume() {
  local vol="$1" reason="$2"
  if [ "$DRY_RUN" = true ]; then
    echo "  ${CYAN}[DRY-RUN]${NC} borraría ${BOLD}${vol}${NC} (${reason})"
    return
  fi
  # Sin quitar el finalizer, un volumen faulted queda colgado en Terminating.
  kubectl patch volumes.longhorn.io "$vol" -n "$LONGHORN_NS" \
    --type=merge -p '{"metadata":{"finalizers":null}}' &>/dev/null || true
  if kubectl delete volumes.longhorn.io "$vol" -n "$LONGHORN_NS" \
       --ignore-not-found=true --timeout=30s &>/dev/null; then
    log_ok "${vol} eliminado (${reason})"
  else
    log_err "${vol} no se pudo eliminar — revisa manualmente"
  fi
}

clean_longhorn_volumes() {
  local strategy="$1"
  log_step "2" "Limpiando volúmenes Longhorn (estrategia: ${strategy})..."

  if ! k8s_up || ! kubectl get namespace "$LONGHORN_NS" &>/dev/null; then
    log_skip "Longhorn no disponible"
    return
  fi

  local vol_lines=()
  mapfile -t vol_lines < <(
    kubectl get volumes.longhorn.io -n "$LONGHORN_NS" \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.robustness}{" "}{.status.state}{" "}{.status.kubernetesStatus.pvcName}{"\n"}{end}' 2>/dev/null
  )

  if [ "${#vol_lines[@]}" -eq 0 ] || [ -z "${vol_lines[0]:-}" ]; then
    log_ok "No hay volúmenes Longhorn."
    return
  fi

  local to_delete=()
  declare -A reason=()

  local line name robustness state pvc mpvc is_moodle
  for line in "${vol_lines[@]}"; do
    [ -z "$line" ] && continue
    read -r name robustness state pvc <<< "$line"

    if [ "$strategy" = "unhealthy" ]; then
      if [ "${robustness:-}" = "faulted" ]; then
        to_delete+=("$name"); reason["$name"]="faulted"
      elif [ "${robustness:-}" = "unknown" ]; then
        to_delete+=("$name"); reason["$name"]="unknown"
      elif [ -z "${pvc:-}" ]; then
        to_delete+=("$name"); reason["$name"]="huérfano (sin PVC)"
      fi
    else  # nuke
      is_moodle=false
      for mpvc in "${MOODLE_PVCS[@]}"; do
        [ "${pvc:-}" = "$mpvc" ] && { is_moodle=true; break; }
      done
      if [ "$is_moodle" = true ]; then
        to_delete+=("$name"); reason["$name"]="PVC Moodle: ${pvc}"
      elif [ -z "${pvc:-}" ]; then
        to_delete+=("$name"); reason["$name"]="huérfano (probable Moodle)"
      fi
    fi
  done

  if [ "${#to_delete[@]}" -eq 0 ]; then
    log_ok "No hay volúmenes que borrar con esta estrategia."
    return
  fi

  local vol
  for vol in "${to_delete[@]}"; do
    delete_longhorn_volume "$vol" "${reason[$vol]}"
  done

  # PVs en Released: con Retain no se reciclan solos y ensucian `kubectl get pv`.
  log_ok "Eliminando PersistentVolumes en estado Released..."
  sh_run "kubectl get pv -o jsonpath='{range .items[?(@.status.phase==\"Released\")]}{.metadata.name}{\"\n\"}{end}' | xargs -r -n1 kubectl delete pv --ignore-not-found=true"
}

# ============================================================================
# BLOQUE 3 — Datos físicos y caché
# ============================================================================
wipe_raid() {
  log_step "3" "Borrando datos de aplicación en ${RAID_BASE}..."

  if [ ! -d "$RAID_BASE" ]; then
    log_warn "${RAID_BASE} no existe."
    return
  fi

  local size
  size="$(du -sh "$RAID_BASE" 2>/dev/null | cut -f1 || echo "?")"
  log_warn "Tamaño actual de ${RAID_BASE}: ${size}"

  # Se vacía el CONTENIDO de cada subdirectorio, no el subdirectorio en sí.
  # 05-join-nodes.sh y el registro de discos de Longhorn dependen de que
  # /moodlek3s/longhorn exista antes del `kubectl apply -k`; si el path no
  # existe, Longhorn descarta la anotación y registra cero discos.
  local sub
  for sub in "${RAID_SUBDIRS[@]}"; do
    if [ -d "${RAID_BASE}/${sub}" ]; then
      sh_run "rm -rf ${RAID_BASE:?}/${sub:?}/{*,.[!.]*}"
      log_ok "Vaciado: ${RAID_BASE}/${sub}"
    else
      run mkdir -p "${RAID_BASE}/${sub}"
      log_skip "${RAID_BASE}/${sub} no existía — creado vacío"
    fi
  done
}

clean_cache() {
  log_step "4" "Limpiando caché de runtime..."

  # NOTA DELIBERADA: aquí NO se hace `crictl rmi --prune`.
  # Tras borrar el namespace, localhost/galera-arbitrator:26.4.23 y la imagen
  # de Moodle quedan sin contenedor que las use, y el prune las eliminaría.
  # Como garbd usa imagePullPolicy: Never, el siguiente 07-galera-maxscale.sh
  # fallaría con ErrImageNeverPull. Las imágenes solo se tocan en --purge.
  log_skip "Imágenes de containerd (se conservan a propósito: garbd/Moodle usan imagePullPolicy Never)"

  sh_run "find /var/log/pods -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +"
  sh_run "find /var/log/containers -mindepth 1 -type l -delete"
  log_ok "Logs de pods y contenedores eliminados."

  # Contenedores muertos que containerd no recogió (pods en estado Unknown).
  if command -v crictl &>/dev/null; then
    sh_run "crictl rm --all --force"
    log_ok "Contenedores detenidos eliminados de containerd."
  fi

  sh_run "rm -rf /tmp/k3s*"
  log_ok "Temporales de k3s eliminados."
}

# ============================================================================
# BLOQUE 4 — Desconexión y limpieza de un nodo
# ============================================================================
node_detach() {
  log_step "1" "Desconectando '${TARGET_NODE}' del cluster..."

  if [ "$LOCAL_ONLY" = true ]; then
    log_skip "Parte de cluster omitida (--local-only)"
    return
  fi
  if ! k8s_up; then
    log_warn "Cluster no accesible — no se puede desconectar el nodo desde aquí."
    log_warn "Ejecuta este script con --local-only en el nodo, o borra el objeto"
    log_warn "Node desde un control-plane sano: kubectl delete node ${TARGET_NODE}"
    return
  fi
  if ! kubectl get node "$TARGET_NODE" &>/dev/null; then
    log_skip "El nodo ${TARGET_NODE} no existe en el cluster"
    return
  fi

  # Salvaguarda de quórum: los tres nodos son control-planes con etcd.
  # De 3 miembros se pueden perder 1 (quórum 2). Perder 2 rompe el cluster.
  local cp_count
  cp_count="$(kubectl get nodes -l node-role.kubernetes.io/control-plane=true --no-headers 2>/dev/null | wc -l)"
  log_ok "Control-planes actuales: ${cp_count}"
  if [ "$cp_count" -le 1 ]; then
    log_err "Es el único control-plane. Desconectarlo destruiría el cluster."
    exit 1
  fi
  if [ "$cp_count" -le 2 ]; then
    log_warn "Quedarán ${cp_count} nodos: se pierde tolerancia a fallos de etcd."
  fi

  if [ "$TARGET_NODE" = "$PRIMARY_NODE" ] && [ "$FORCE" = false ]; then
    log_err "${TARGET_NODE} es el nodo primario. Usa --force si es intencional."
    exit 1
  fi

  run kubectl cordon "$TARGET_NODE"
  log_ok "Nodo acordonado (no admite nuevos pods)."

  # --ignore-daemonsets: kube-vip, Longhorn y garbd corren como DaemonSet y no
  # pueden desalojarse; el drain fallaría sin este flag.
  run kubectl drain "$TARGET_NODE" \
    --ignore-daemonsets --delete-emptydir-data --force --timeout=180s
  log_ok "Nodo drenado."

  # Borrar el objeto Node hace que k3s retire el miembro de etcd. Debe ocurrir
  # ANTES de desinstalar k3s en el nodo, o el miembro queda huérfano en etcd.
  run kubectl delete node "$TARGET_NODE" --timeout=60s
  log_ok "Objeto Node eliminado — miembro de etcd retirado."

  if [ "$DRY_RUN" = false ]; then
    log_ok "Miembros de etcd restantes:"
    kubectl get nodes -o wide 2>/dev/null | sed 's/^/    /' || true
  fi
}

node_wipe_local() {
  log_step "2" "Limpieza local de k3s en $(hostname)..."

  if [ "$(hostname)" != "$TARGET_NODE" ]; then
    echo ""
    log_warn "Este host es '$(hostname)', no '${TARGET_NODE}'."
    log_warn "La limpieza local debe correrse EN el nodo objetivo:"
    echo ""
    echo "    ssh ${TARGET_NODE}"
    echo "    sudo ./00-teardown.sh --node --target ${TARGET_NODE} --local-only"
    echo ""
    return
  fi

  uninstall_k3s
  remove_selinux_pkgs
  clean_k3s_dirs
}

# ============================================================================
# BLOQUE 5 — Desinstalación de k3s
# ============================================================================
uninstall_k3s() {
  log_step "·" "Desinstalando k3s..."

  # k3s-killall.sh mata pods, contenedores y desmonta todo lo que k3s montó.
  # Sin él, el uninstaller puede dejar mounts colgados en /var/lib/kubelet.
  if [ -x /usr/local/bin/k3s-killall.sh ]; then
    run /usr/local/bin/k3s-killall.sh
    log_ok "k3s-killall.sh ejecutado."
  fi

  if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
    run /usr/local/bin/k3s-uninstall.sh
    log_ok "k3s (server) desinstalado."
  elif [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then
    run /usr/local/bin/k3s-agent-uninstall.sh
    log_ok "k3s (agent) desinstalado."
  else
    log_warn "Uninstaller no encontrado — limpieza manual."
    run systemctl stop k3s
    run systemctl disable k3s
    run rm -f /etc/systemd/system/k3s.service
    run systemctl daemon-reload
    local bin
    for bin in k3s kubectl crictl ctr k3s-uninstall.sh k3s-killall.sh; do
      run rm -f "/usr/local/bin/${bin}"
    done
    log_ok "Binarios y unidad systemd eliminados."
  fi
}

remove_selinux_pkgs() {
  log_step "·" "Removiendo paquetes SELinux instalados por k3s..."
  local pkg
  for pkg in k3s-selinux container-selinux; do
    if rpm -q "$pkg" &>/dev/null; then
      if [ "$DRY_RUN" = true ]; then
        echo "  ${CYAN}[DRY-RUN]${NC} dnf remove -y ${pkg}"
      elif dnf remove -y "$pkg" &>/dev/null; then
        log_ok "${pkg} removido."
      else
        log_warn "No se pudo remover ${pkg} (¿otra cosa depende de él?)."
      fi
    else
      log_skip "${pkg} no instalado"
    fi
  done
}

clean_k3s_dirs() {
  log_step "·" "Limpiando directorios y configuración residual..."

  local dir
  for dir in /etc/rancher /var/lib/rancher /var/lib/kubelet \
             /var/log/pods /var/log/containers /run/k3s /run/flannel; do
    if [ -e "$dir" ]; then
      run rm -rf "$dir"
      log_ok "Eliminado: ${dir}"
    else
      log_skip "${dir} no existe"
    fi
  done

  sh_run "rm -rf /tmp/k3s*"
  run rm -f /root/.kube/config
  sh_run "rm -f /home/*/.kube/config"
  log_ok "kubeconfig eliminado."
}

clean_network() {
  log_step "·" "Limpiando interfaces de red residuales..."
  local iface
  for iface in flannel.1 cni0 vxlan.calico tunl0 kube-ipvs0; do
    if ip link show "$iface" &>/dev/null; then
      run ip link delete "$iface"
      log_ok "Interfaz eliminada: ${iface}"
    fi
  done

  # k3s-killall.sh ya limpia iptables. Un `iptables -t nat -F` a ciegas borra
  # también reglas ajenas (libvirt, la VM del nodo B corre sobre el nodo A).
  # Por eso solo se limpian las cadenas propias de Kubernetes/flannel.
  local chain
  for chain in KUBE-SERVICES KUBE-NODEPORTS KUBE-POSTROUTING KUBE-FORWARD; do
    sh_run "iptables -F ${chain}"
    sh_run "iptables -t nat -F ${chain}"
  done
  log_ok "Cadenas KUBE-* vaciadas (reglas de libvirt intactas)."
}

clean_images() {
  log_step "·" "Limpiando imágenes de contenedores..."

  # containerd muere con k3s: su almacén vive en /var/lib/rancher/k3s/agent.
  # Se intenta el borrado explícito por si el uninstaller no corrió.
  if command -v ctr &>/dev/null; then
    sh_run "ctr -n k8s.io images ls -q | xargs -r -n1 ctr -n k8s.io images rm"
    log_ok "Imágenes de containerd (k8s.io) eliminadas."
  else
    log_skip "ctr no disponible (containerd ya eliminado con k3s)"
  fi

  if ! command -v podman &>/dev/null; then
    log_skip "Podman no instalado"
    return
  fi

  if [ "$KEEP_IMAGES" = true ]; then
    log_skip "Imágenes de Podman conservadas (--keep-images)"
    log_warn "Recuerda re-importarlas a containerd tras reinstalar k3s:"
    echo "      podman save --format docker-archive localhost/galera-arbitrator:26.4.23 \\"
    echo "        | k3s ctr images import -"
    return
  fi

  sh_run "podman rmi --all --force"
  run podman image prune -f
  log_ok "Imágenes de Podman eliminadas."
  log_warn "Deberás reconstruir moodle-apache y galera-arbitrator (arm64, en la Pi)."
}

clean_hosts() {
  log_step "·" "Revisando /etc/hosts..."
  if grep -q "mcc.tesoem.edu.mx" /etc/hosts 2>/dev/null; then
    run sed -i '/mcc.tesoem.edu.mx/d' /etc/hosts
    log_ok "Entradas de mcc.tesoem.edu.mx eliminadas."
  else
    log_skip "Sin entradas de Moodle en /etc/hosts"
  fi
}

# ============================================================================
# BLOQUE 6 — Verificación final
# ============================================================================
report() {
  echo ""
  echo "${BOLD}──────────── Verificación post-limpieza ────────────${NC}"

  case "$MODE" in
    stack|data)
      if k8s_up; then
        kubectl get namespace "$NAMESPACE" &>/dev/null \
          && log_warn "Namespace ${NAMESPACE} aún existe" \
          || log_ok "Namespace ${NAMESPACE} eliminado"
        local vols
        vols="$(kubectl get volumes.longhorn.io -n "$LONGHORN_NS" --no-headers 2>/dev/null | wc -l)"
        log_ok "Volúmenes Longhorn restantes: ${vols}"
        log_ok "Nodos: $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
      else
        log_warn "Cluster no accesible."
      fi
      if [ "$MODE" = "data" ]; then
        echo "  ${BOLD}Contenido de ${RAID_BASE}:${NC}"
        du -sh "${RAID_BASE}"/* 2>/dev/null | sed 's/^/    /' || echo "    (vacío)"
      fi
      ;;
    node)
      command -v k3s &>/dev/null \
        && log_warn "El binario k3s sigue en el PATH — revisa manualmente" \
        || log_ok "k3s ya no está presente en este host"
      rpm -qa 2>/dev/null | grep -qE "k3s-selinux" \
        && log_warn "k3s-selinux sigue instalado" \
        || log_ok "Sin paquetes k3s-selinux"
      ;;
    purge)
      systemctl is-active k3s &>/dev/null \
        && log_err "k3s todavía activo" || log_ok "k3s detenido"
      [ -f /usr/local/bin/k3s ] \
        && log_warn "Binario k3s presente" || log_ok "/usr/local/bin/k3s eliminado"
      [ -d /var/lib/rancher ] \
        && log_warn "/var/lib/rancher existe" || log_ok "/var/lib/rancher eliminado"
      [ -d /etc/rancher ] \
        && log_warn "/etc/rancher existe" || log_ok "/etc/rancher eliminado"
      ;;
  esac

  echo ""
  echo "${GREEN}${BOLD}════════════ LIMPIEZA COMPLETADA ════════════${NC}"
  echo ""
  case "$MODE" in
    stack) echo "  Siguiente paso: ${BOLD}bash 04-deploy-all.sh${NC}" ;;
    data)  echo "  Siguiente paso: ${BOLD}bash 04-deploy-all.sh${NC} (imágenes conservadas)" ;;
    node)  echo "  Siguiente paso: ${BOLD}bash 05-join-nodes.sh${NC} desde el nodo primario" ;;
    purge) echo "  Siguiente paso: ${BOLD}bash 01-prepare-almalinux9.sh${NC}" ;;
  esac
  [ "$DRY_RUN" = true ] && echo "  ${CYAN}(DRY-RUN: no se modificó nada)${NC}"
  echo ""
  echo "  Finalizado — $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
}

# ============================================================================
# ORQUESTACIÓN
# ============================================================================
confirm
echo "${BOLD}Iniciando — $(date '+%Y-%m-%d %H:%M:%S')${NC}"

case "$MODE" in
  stack)
    teardown_stack
    [ "$CLEAN_VOLUMES" = true ] && clean_longhorn_volumes "unhealthy"
    if [ "$CLEAN_VOLUMES" = false ]; then
      echo ""
      log_warn "Los volúmenes Longhorn se conservaron (reclaimPolicy: Retain)."
      log_warn "El redespliegue creará volúmenes nuevos; los viejos quedan huérfanos."
      log_warn "Para limpiarlos: ${BOLD}$0 --stack --clean-volumes${NC}"
    fi
    ;;

  data)
    teardown_stack
    clean_longhorn_volumes "nuke"
    wipe_raid
    clean_cache
    ;;

  node)
    node_detach
    node_wipe_local
    ;;

  purge)
    # El derribo ordenado antes de destruir k3s evita mounts colgados de
    # Longhorn en /var/lib/kubelet que impiden el rm -rf posterior.
    teardown_stack
    clean_longhorn_volumes "nuke"
    uninstall_k3s
    remove_selinux_pkgs
    clean_k3s_dirs
    clean_images
    clean_network
    clean_hosts
    wipe_raid
    ;;
esac

report
