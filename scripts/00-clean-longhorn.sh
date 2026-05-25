#!/usr/bin/env bash
# ============================================================================
# 00-clean-longhorn.sh
# Limpieza de volúmenes Longhorn del stack Moodle HA
# ----------------------------------------------------------------------------
# CONTEXTO:
#   El StorageClass longhorn-moodle usa reclaimPolicy: Retain. Esto significa
#   que al borrar un PVC, su volumen Longhorn NO se elimina automáticamente —
#   sobrevive para proteger los datos. La contraparte es que, entre corridas
#   de prueba, los volúmenes se acumulan (huérfanos, faulted) y consumen disco
#   hasta provocar fallos de aprovisionamiento.
#
#   Este script limpia esos volúmenes. Los demás scripts de limpieza
#   (00-cleanup-all.sh, 00-cleanup-k3s.sh) NO tocan Longhorn — esa es la razón
#   de existir de este script.
#
# MODOS (requiere uno explícito — sin argumentos solo muestra ayuda):
#   --unhealthy   Borra SOLO volúmenes en mal estado: faulted, unknown, o
#                 huérfanos (PV en estado Released, sin PVC dueño).
#                 Es seguro: no toca volúmenes sanos con un PVC vivo.
#                 No pide confirmación.
#
#   --nuke        Borra TODOS los volúmenes del stack Moodle (moodle-html-pvc
#                 y moodle-data-pvc), sanos o no. DESTRUCTIVO E IRREVERSIBLE.
#                 Respeta la política Retain exigiendo confirmación escrita.
#
# OPCIONES:
#   --dry-run     Muestra qué se borraría sin borrar nada. Combinable con
#                 cualquier modo: ./00-clean-longhorn.sh --nuke --dry-run
#
# USO:
#   ./00-clean-longhorn.sh                  # muestra ayuda, no borra nada
#   ./00-clean-longhorn.sh --unhealthy      # limpia basura (seguro)
#   ./00-clean-longhorn.sh --nuke           # borra todo lo de Moodle (pregunta)
#   ./00-clean-longhorn.sh --unhealthy --dry-run
# ============================================================================

set -uo pipefail

# ── Configuración ─────────────────────────────────────────────────────────────
LONGHORN_NAMESPACE="longhorn-system"
# PVCs del stack Moodle cuyos volúmenes gestiona Longhorn. Si en el futuro
# agregas más volúmenes Longhorn, añádelos aquí.
MOODLE_PVCS=("moodle-html-pvc" "moodle-data-pvc")

# ── Colores ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; NC=""
fi

# ── Flags ─────────────────────────────────────────────────────────────────────
MODE=""
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --unhealthy) MODE="unhealthy" ;;
    --nuke)      MODE="nuke" ;;
    --dry-run)   DRY_RUN=true ;;
    -h|--help)   MODE="" ;;  # cae al bloque de ayuda
    *) echo "${RED}Argumento desconocido: $arg${NC}"; MODE="invalid" ;;
  esac
done

# ── Ayuda (sin argumentos o argumento inválido) ───────────────────────────────
show_help() {
  echo ""
  echo "${BOLD}Limpieza de volúmenes Longhorn — stack Moodle HA${NC}"
  echo ""
  echo "Este script requiere un modo explícito. No borra nada por sí solo."
  echo ""
  echo "  ${GREEN}--unhealthy${NC}   Borra solo volúmenes en mal estado:"
  echo "                faulted, unknown, o huérfanos (Released sin dueño)."
  echo "                Seguro. No toca volúmenes sanos. No pide confirmación."
  echo ""
  echo "  ${RED}--nuke${NC}        Borra TODOS los volúmenes del stack Moodle,"
  echo "                sanos o no. ${RED}Destructivo e irreversible.${NC}"
  echo "                Pide confirmación escrita (respeta la política Retain)."
  echo ""
  echo "  ${CYAN}--dry-run${NC}     Muestra qué se borraría sin borrar. Combinable:"
  echo "                ./00-clean-longhorn.sh --nuke --dry-run"
  echo ""
  echo "Ejemplos:"
  echo "  ./00-clean-longhorn.sh --unhealthy            # limpieza rutinaria entre corridas"
  echo "  ./00-clean-longhorn.sh --nuke                 # wipe total de Moodle"
  echo ""
}

if [ -z "$MODE" ] || [ "$MODE" = "invalid" ]; then
  show_help
  exit 0
fi

# ── Verificar kubectl y acceso a Longhorn ─────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
  echo "${RED}kubectl no encontrado.${NC}"; exit 1
fi
if ! kubectl get namespace "$LONGHORN_NAMESPACE" &>/dev/null; then
  echo "${RED}El namespace ${LONGHORN_NAMESPACE} no existe — ¿Longhorn instalado?${NC}"
  exit 1
fi

# ── Helper: borrar un volumen Longhorn por nombre ─────────────────────────────
# Con reclaimPolicy Retain y volúmenes faulted, a veces los finalizers impiden
# el borrado normal. Se limpia el finalizer antes de borrar para evitar que
# el volumen quede colgado en estado Terminating.
delete_volume() {
  local vol="$1"
  local reason="$2"
  if [ "$DRY_RUN" = true ]; then
    echo "  ${CYAN}[DRY-RUN]${NC} borraría ${BOLD}${vol}${NC} (${reason})"
    return
  fi
  echo "  ${YELLOW}Borrando${NC} ${vol} (${reason})..."
  # Quitar finalizer para que no quede en Terminating si está faulted/huérfano.
  kubectl patch volumes.longhorn.io "$vol" -n "$LONGHORN_NAMESPACE" \
    --type=merge -p '{"metadata":{"finalizers":null}}' &>/dev/null || true
  kubectl delete volumes.longhorn.io "$vol" -n "$LONGHORN_NAMESPACE" \
    --ignore-not-found=true --timeout=30s &>/dev/null \
    && echo "    ${GREEN}✓${NC} eliminado" \
    || echo "    ${RED}✗${NC} no se pudo eliminar (revisa manualmente)"
}

# ── Recolectar el estado de todos los volúmenes ───────────────────────────────
# Formato por línea: NOMBRE ROBUSTNESS STATE PVC_DUEÑO
# El PVC dueño sale de status.kubernetesStatus.pvcName; si está vacío, el
# volumen no tiene PVC asociado (huérfano).
mapfile -t VOL_LINES < <(
  kubectl get volumes.longhorn.io -n "$LONGHORN_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.robustness}{" "}{.status.state}{" "}{.status.kubernetesStatus.pvcName}{"\n"}{end}' 2>/dev/null
)

if [ "${#VOL_LINES[@]}" -eq 0 ] || [ -z "${VOL_LINES[0]}" ]; then
  echo "${GREEN}No hay volúmenes Longhorn. Nada que limpiar.${NC}"
  exit 0
fi

echo ""
echo "${BOLD}Volúmenes Longhorn detectados:${NC}"
printf "  %-44s %-10s %-10s %s\n" "NOMBRE" "ROBUSTNESS" "STATE" "PVC"
for line in "${VOL_LINES[@]}"; do
  [ -z "$line" ] && continue
  read -r name robustness state pvc <<< "$line"
  printf "  %-44s %-10s %-10s %s\n" "$name" "${robustness:-—}" "${state:-—}" "${pvc:-(huérfano)}"
done
echo ""

# ── Determinar qué volúmenes borrar según el modo ─────────────────────────────
TO_DELETE=()
declare -A DELETE_REASON

for line in "${VOL_LINES[@]}"; do
  [ -z "$line" ] && continue
  read -r name robustness state pvc <<< "$line"

  if [ "$MODE" = "unhealthy" ]; then
    # Borrar si robustness es faulted/unknown, o si no tiene PVC dueño (huérfano).
    if [ "$robustness" = "faulted" ]; then
      TO_DELETE+=("$name"); DELETE_REASON["$name"]="faulted"
    elif [ "$robustness" = "unknown" ]; then
      TO_DELETE+=("$name"); DELETE_REASON["$name"]="unknown"
    elif [ -z "$pvc" ]; then
      TO_DELETE+=("$name"); DELETE_REASON["$name"]="huérfano (sin PVC)"
    fi

  elif [ "$MODE" = "nuke" ]; then
    # Borrar si el PVC dueño es uno de los del stack Moodle, O si es huérfano
    # (porque un huérfano probablemente fue de Moodle en una corrida anterior).
    is_moodle=false
    for mpvc in "${MOODLE_PVCS[@]}"; do
      if [ "$pvc" = "$mpvc" ]; then is_moodle=true; break; fi
    done
    if [ "$is_moodle" = true ]; then
      TO_DELETE+=("$name"); DELETE_REASON["$name"]="PVC Moodle: $pvc"
    elif [ -z "$pvc" ]; then
      TO_DELETE+=("$name"); DELETE_REASON["$name"]="huérfano (probable Moodle)"
    fi
  fi
done

# ── Si no hay nada que borrar, salir ──────────────────────────────────────────
if [ "${#TO_DELETE[@]}" -eq 0 ]; then
  if [ "$MODE" = "unhealthy" ]; then
    echo "${GREEN}No hay volúmenes en mal estado. Todo limpio.${NC}"
  else
    echo "${GREEN}No hay volúmenes del stack Moodle que borrar.${NC}"
  fi
  exit 0
fi

# ── Mostrar plan ──────────────────────────────────────────────────────────────
echo "${BOLD}Modo: ${MODE}${NC} — se borrarán ${#TO_DELETE[@]} volumen(es):"
for vol in "${TO_DELETE[@]}"; do
  echo "  • $vol  (${DELETE_REASON[$vol]})"
done
echo ""

# ── Confirmación: solo --nuke la exige (--unhealthy borra basura, es seguro) ──
if [ "$MODE" = "nuke" ] && [ "$DRY_RUN" = false ]; then
  echo "${RED}${BOLD}ADVERTENCIA:${NC} --nuke borra volúmenes SANOS con datos."
  echo "${RED}Esto es irreversible y contradice temporalmente la política Retain.${NC}"
  echo -ne "Escribe ${BOLD}NUKE${NC} para confirmar: "
  read -r confirm
  if [ "$confirm" != "NUKE" ]; then
    echo "${GREEN}Cancelado. No se borró nada.${NC}"
    exit 0
  fi
  echo ""
fi

# ── Ejecutar borrado ──────────────────────────────────────────────────────────
for vol in "${TO_DELETE[@]}"; do
  delete_volume "$vol" "${DELETE_REASON[$vol]}"
done

echo ""
if [ "$DRY_RUN" = true ]; then
  echo "${CYAN}DRY-RUN completado. No se borró nada.${NC}"
else
  echo "${GREEN}${BOLD}Limpieza completada.${NC}"
  echo "Verifica con: kubectl get volumes.longhorn.io -n ${LONGHORN_NAMESPACE}"
fi
