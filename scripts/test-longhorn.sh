#!/usr/bin/env bash
# ============================================================================
# test-longhorn.sh
# ----------------------------------------------------------------------------
# Verifica que un nodo está correctamente preparado para Longhorn y que
# Longhorn funciona de punta a punta en el clúster.
#
# El script trabaja en TRES FASES:
#   FASE 1 — Prerrequisitos del nodo (lo que instala 01-prepareAlma9k3s.sh):
#            paquetes, módulos del kernel, daemon iscsid. Esta fase es LOCAL:
#            verifica el nodo donde se ejecuta el script.
#   FASE 2 — Estado de Longhorn en el clúster: namespace, pods, StorageClass,
#            nodos disponibles para almacenamiento. Esta fase consulta al
#            clúster vía kubectl, así que se puede correr desde cualquier nodo
#            con acceso al kubeconfig.
#   FASE 3 — Prueba E2E: crea un PVC real contra el StorageClass de Longhorn,
#            espera a que llegue a estado Bound, y lo borra al terminar.
#            Esto confirma que el aprovisionamiento dinámico realmente funciona.
#
# USO:
#   sudo ./test-longhorn.sh                    # ejecuta las tres fases
#   sudo ./test-longhorn.sh --skip-prereqs     # omite FASE 1 (solo clúster)
#   sudo ./test-longhorn.sh --no-e2e           # omite FASE 3 (no crea PVC)
#   STORAGE_CLASS=longhorn ./test-longhorn.sh  # usa otro StorageClass
#
# CÓDIGO DE SALIDA:
#   0 = todas las verificaciones ejecutadas pasaron
#   1 = al menos una verificación crítica falló
# ============================================================================

set -uo pipefail

# ── Configuración (sobreescribible por variables de entorno) ────────────────
# StorageClass a probar en la FASE 3. Por defecto el de este proyecto.
STORAGE_CLASS="${STORAGE_CLASS:-longhorn-moodle}"
# Namespace donde Longhorn instala sus componentes (estándar del proyecto).
LONGHORN_NAMESPACE="${LONGHORN_NAMESPACE:-longhorn-system}"
# Tamaño del PVC de prueba en la FASE 3. Pequeño para no consumir espacio.
TEST_PVC_SIZE="${TEST_PVC_SIZE:-1Gi}"
# Segundos máximos a esperar a que el PVC de prueba llegue a Bound.
TEST_PVC_TIMEOUT="${TEST_PVC_TIMEOUT:-60}"

# ── Flags ───────────────────────────────────────────────────────────────────
SKIP_PREREQS=false
RUN_E2E=true
for arg in "$@"; do
  case "$arg" in
    --skip-prereqs) SKIP_PREREQS=true ;;
    --no-e2e)       RUN_E2E=false ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -32
      exit 0
      ;;
    *) echo "Argumento desconocido: $arg (usa --help)"; exit 1 ;;
  esac
done

# ── Colores y helpers de log ────────────────────────────────────────────────
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; NC=""
fi

# Contadores globales de resultados
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

log_phase() { echo ""; echo "${BOLD}${CYAN}══ $* ══${NC}"; }
# check_pass / check_fail / check_warn registran un resultado e imprimen línea.
check_pass() { echo "  ${GREEN}✔${NC} $*"; PASS_COUNT=$((PASS_COUNT+1)); }
check_fail() { echo "  ${RED}✘${NC} $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
check_warn() { echo "  ${YELLOW}!${NC} $*"; WARN_COUNT=$((WARN_COUNT+1)); }
info()       { echo "    ${CYAN}↳${NC} $*"; }

# ── Detección de kubectl ─────────────────────────────────────────────────────
# En K3s el binario suele ser 'kubectl' o el wrapper 'k3s kubectl'.
detect_kubectl() {
  if command -v kubectl &>/dev/null; then
    KUBECTL="kubectl"
  elif command -v k3s &>/dev/null; then
    KUBECTL="k3s kubectl"
  else
    KUBECTL=""
  fi
}

# ============================================================================
# FASE 1 — PRERREQUISITOS DEL NODO
# ============================================================================
# Verifica lo que el script de preparación dejó instalado en ESTE nodo.
# Si esta fase falla, Longhorn no podrá montar volúmenes aquí aunque el
# clúster esté sano.
phase_prereqs() {
  log_phase "FASE 1: Prerrequisitos del nodo ($(hostname))"

  # ── 1.1 Paquetes requeridos ────────────────────────────────────────────────
  # iscsi-initiator-utils provee iscsiadm; sin él, Longhorn no monta volúmenes.
  # nfs-utils provee mount.nfs; sin él, los volúmenes RWX no funcionan.
  # cryptsetup lo requiere el instalador de Longhorn.
  echo "  ${BOLD}Paquetes:${NC}"
  for cmd in iscsiadm mount.nfs cryptsetup; do
    if command -v "$cmd" &>/dev/null; then
      check_pass "comando '$cmd' disponible"
    else
      check_fail "comando '$cmd' NO encontrado — instala el paquete correspondiente"
    fi
  done

  # ── 1.2 Módulos del kernel ──────────────────────────────────────────────────
  # iscsi_tcp: necesario para el transporte iSCSI de Longhorn.
  # dm_crypt:  necesario para cifrado de volúmenes.
  # Pueden aparecer como módulo cargado (lsmod) o integrados en el kernel
  # (builtin). Verificamos ambos casos para no dar falsos negativos.
  echo "  ${BOLD}Módulos del kernel:${NC}"
  for mod in iscsi_tcp dm_crypt; do
    if lsmod 2>/dev/null | grep -q "^${mod}\b"; then
      check_pass "módulo '$mod' cargado"
    elif [ -d "/sys/module/${mod}" ]; then
      check_pass "módulo '$mod' presente (builtin o ya cargado)"
    else
      check_fail "módulo '$mod' no cargado — ejecuta: modprobe $mod"
    fi
  done

  # ── 1.3 Daemon iscsid ─────────────────────────────────────────────────────
  # iscsid debe estar activo ANTES de que Longhorn intente montar un volumen.
  echo "  ${BOLD}Servicio iscsid:${NC}"
  if systemctl is-active --quiet iscsid 2>/dev/null; then
    check_pass "iscsid está activo"
  else
    check_fail "iscsid NO está activo — ejecuta: systemctl enable --now iscsid"
  fi

  # ── 1.4 Punto de montaje multipath (informativo) ───────────────────────────
  # multipathd puede interferir con los dispositivos de Longhorn si no está
  # configurado para ignorarlos. Es un warning, no un fallo crítico.
  echo "  ${BOLD}Multipath (informativo):${NC}"
  if systemctl is-active --quiet multipathd 2>/dev/null; then
    check_warn "multipathd activo — verifica que /etc/multipath.conf excluya los discos de Longhorn"
    info "Longhorn recomienda añadir una blacklist para evitar conflictos."
  else
    check_pass "multipathd inactivo — sin riesgo de conflicto"
  fi
}

# ============================================================================
# FASE 2 — ESTADO DE LONGHORN EN EL CLÚSTER
# ============================================================================
# Consulta al clúster para confirmar que Longhorn está instalado y operativo.
phase_longhorn_status() {
  log_phase "FASE 2: Estado de Longhorn en el clúster"

  if [ -z "$KUBECTL" ]; then
    check_fail "No se encontró kubectl ni k3s — no se puede consultar el clúster"
    info "Esta fase requiere acceso al clúster. Ejecuta desde un nodo con kubeconfig."
    return
  fi

  # ── 2.1 Conectividad con el clúster ─────────────────────────────────────────
  if $KUBECTL get nodes &>/dev/null; then
    check_pass "kubectl puede comunicarse con el clúster"
  else
    check_fail "kubectl no responde — ¿está K3s activo y el kubeconfig accesible?"
    return
  fi

  # ── 2.2 Namespace de Longhorn ───────────────────────────────────────────────
  if $KUBECTL get namespace "$LONGHORN_NAMESPACE" &>/dev/null; then
    check_pass "namespace '$LONGHORN_NAMESPACE' existe"
  else
    check_fail "namespace '$LONGHORN_NAMESPACE' NO existe — Longhorn no está instalado"
    info "Instala Longhorn antes de continuar con las fases siguientes."
    return
  fi

  # ── 2.3 Pods de Longhorn ────────────────────────────────────────────────────
  # Verificamos que todos los pods del namespace estén en Running o Completed.
  # longhorn-manager corre como DaemonSet (uno por nodo); el resto son Deployments.
  echo "  ${BOLD}Pods de Longhorn:${NC}"
  local total not_ready
  total=$($KUBECTL get pods -n "$LONGHORN_NAMESPACE" --no-headers 2>/dev/null | wc -l)
  if [ "$total" -eq 0 ]; then
    check_fail "no hay pods en '$LONGHORN_NAMESPACE'"
  else
    # Contar pods que NO estén Running ni Completed.
    not_ready=$($KUBECTL get pods -n "$LONGHORN_NAMESPACE" --no-headers 2>/dev/null \
      | awk '$3 != "Running" && $3 != "Completed" {print}' | wc -l)
    if [ "$not_ready" -eq 0 ]; then
      check_pass "los $total pods de Longhorn están Running/Completed"
    else
      check_fail "$not_ready de $total pods NO están listos:"
      $KUBECTL get pods -n "$LONGHORN_NAMESPACE" --no-headers 2>/dev/null \
        | awk '$3 != "Running" && $3 != "Completed" {print "      - "$1" ("$3")"}'
    fi
  fi

  # ── 2.4 StorageClass ────────────────────────────────────────────────────────
  echo "  ${BOLD}StorageClass:${NC}"
  if $KUBECTL get storageclass "$STORAGE_CLASS" &>/dev/null; then
    local provisioner
    provisioner=$($KUBECTL get storageclass "$STORAGE_CLASS" \
      -o jsonpath='{.provisioner}' 2>/dev/null)
    if [ "$provisioner" = "driver.longhorn.io" ]; then
      check_pass "StorageClass '$STORAGE_CLASS' existe y usa driver.longhorn.io"
    else
      check_warn "StorageClass '$STORAGE_CLASS' existe pero su provisioner es '$provisioner'"
      info "Se esperaba driver.longhorn.io. ¿Es el StorageClass correcto?"
    fi
  else
    check_fail "StorageClass '$STORAGE_CLASS' NO existe"
    info "Aplica 01-storageclass.yaml o ajusta STORAGE_CLASS=<nombre>."
  fi

  # ── 2.5 Nodos disponibles para Longhorn ─────────────────────────────────────
  # Consulta el CRD 'nodes.longhorn.io' para ver cuántos nodos puede usar
  # Longhorn para almacenar réplicas. Recuerda: la Raspberry Pi se excluye
  # a propósito, así que es normal ver menos nodos de almacenamiento que
  # nodos totales del clúster.
  echo "  ${BOLD}Nodos de almacenamiento (CRD longhorn):${NC}"
  if $KUBECTL get nodes.longhorn.io -n "$LONGHORN_NAMESPACE" &>/dev/null; then
    local ln_total
    ln_total=$($KUBECTL get nodes.longhorn.io -n "$LONGHORN_NAMESPACE" \
      --no-headers 2>/dev/null | wc -l)
    check_pass "Longhorn reconoce $ln_total nodo(s)"
    info "Nota: la Raspberry Pi (árbitro) debe estar excluida del scheduling."
  else
    check_warn "no se pudo consultar nodes.longhorn.io — ¿CRDs aún inicializando?"
  fi
}

# ============================================================================
# FASE 3 — PRUEBA E2E DE APROVISIONAMIENTO
# ============================================================================
# Crea un PVC real contra el StorageClass de Longhorn y espera a que Longhorn
# lo aprovisione (estado Bound). Si llega a Bound, el aprovisionamiento
# dinámico funciona de punta a punta. El PVC se borra siempre al terminar.
phase_e2e() {
  log_phase "FASE 3: Prueba de aprovisionamiento E2E"

  if [ -z "$KUBECTL" ]; then
    check_fail "No se encontró kubectl — no se puede ejecutar la prueba E2E"
    return
  fi

  # Nombre único para no chocar con PVCs existentes (timestamp).
  local pvc_name="longhorn-test-pvc-$$-$(date +%s)"
  local test_ns="default"

  # Función de limpieza: se ejecuta SIEMPRE al salir de esta fase, incluso
  # si algo falla a mitad de camino. Así nunca dejamos basura en el clúster.
  cleanup_e2e() {
    info "Limpiando PVC de prueba '$pvc_name'..."
    $KUBECTL delete pvc "$pvc_name" -n "$test_ns" --ignore-not-found=true \
      --wait=true --timeout=30s &>/dev/null \
      && check_pass "PVC de prueba eliminado correctamente" \
      || check_warn "no se pudo confirmar la eliminación del PVC — revísalo a mano: kubectl get pvc -n $test_ns"
  }

  # Aplicar el PVC de prueba. Usamos un heredoc para no depender de un archivo.
  info "Creando PVC de prueba ($TEST_PVC_SIZE, StorageClass=$STORAGE_CLASS)..."
  if ! cat <<EOF | $KUBECTL apply -f - &>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $pvc_name
  namespace: $test_ns
  labels:
    test: longhorn-e2e
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $STORAGE_CLASS
  resources:
    requests:
      storage: $TEST_PVC_SIZE
EOF
  then
    check_fail "no se pudo crear el PVC de prueba (kubectl apply falló)"
    return
  fi
  check_pass "PVC de prueba creado"

  # Esperar a que el PVC llegue a Bound, sondeando cada 2 segundos.
  info "Esperando a que el PVC llegue a 'Bound' (máx ${TEST_PVC_TIMEOUT}s)..."
  local elapsed=0 phase=""
  while [ "$elapsed" -lt "$TEST_PVC_TIMEOUT" ]; do
    phase=$($KUBECTL get pvc "$pvc_name" -n "$test_ns" \
      -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$phase" = "Bound" ]; then
      check_pass "el PVC llegó a 'Bound' en ${elapsed}s — aprovisionamiento OK"
      # Mostrar el PV que Longhorn creó dinámicamente.
      local pv_name
      pv_name=$($KUBECTL get pvc "$pvc_name" -n "$test_ns" \
        -o jsonpath='{.spec.volumeName}' 2>/dev/null)
      info "Longhorn aprovisionó el volumen: $pv_name"
      cleanup_e2e
      return
    fi
    sleep 2
    elapsed=$((elapsed+2))
  done

  # Si salimos del loop sin Bound, diagnosticamos.
  check_fail "el PVC no llegó a 'Bound' en ${TEST_PVC_TIMEOUT}s (estado actual: ${phase:-desconocido})"
  info "Eventos del PVC (para diagnóstico):"
  $KUBECTL describe pvc "$pvc_name" -n "$test_ns" 2>/dev/null \
    | grep -A10 "Events:" | sed 's/^/      /'
  cleanup_e2e
}

# ============================================================================
# RESUMEN FINAL
# ============================================================================
print_summary() {
  log_phase "Resumen"
  echo "  ${GREEN}Pasaron:${NC}  $PASS_COUNT"
  echo "  ${YELLOW}Avisos:${NC}   $WARN_COUNT"
  echo "  ${RED}Fallaron:${NC} $FAIL_COUNT"
  echo ""
  if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "  ${GREEN}${BOLD}✔ Nodo y Longhorn verificados correctamente.${NC}"
    return 0
  else
    echo "  ${RED}${BOLD}✘ Hay $FAIL_COUNT verificación(es) fallida(s). Revisa arriba.${NC}"
    return 1
  fi
}

# ============================================================================
# MAIN
# ============================================================================
main() {
  echo "${BOLD}Verificación de Longhorn — $(date '+%Y-%m-%d %H:%M:%S')${NC}"
  echo "Nodo: $(hostname)  |  StorageClass objetivo: $STORAGE_CLASS"

  detect_kubectl

  if [ "$SKIP_PREREQS" = "false" ]; then
    phase_prereqs
  else
    log_phase "FASE 1 omitida (--skip-prereqs)"
  fi

  phase_longhorn_status

  if [ "$RUN_E2E" = "true" ]; then
    phase_e2e
  else
    log_phase "FASE 3 omitida (--no-e2e)"
  fi

  print_summary
}

main
