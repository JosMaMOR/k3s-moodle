#!/bin/bash
# ======================================================
# 09-galera-maxscale.sh 
# Despliegue de galera y maxscale
#
# PROPOSITO:
#   Activar distribucion para las bases de datos

set -euo pipefail

# Requisitos mínimos del sistema
RAID_BASE="${RAID_BASE:-/moodlek3s}"
ARCH=$(uname -m)   # x86_64 o aarch64
MANIFEST_DIR="/root/k3s-moodle/manifests"
SCRIPTS_DIR="/root/k3s-moodle/scripts"
# ── Config de la app (ajusta si cambian nombres) ──────────────────────────────
MOODLE_NS="moodle-prod"
MOODLE_PVCS="moodle-html-pvc moodle-data-pvc"
MOODLE_DEPLOY="moodle"
MOODLE_HPA="moodle-hpa"
MOODLE_TARGET_REPLICAS=3

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
