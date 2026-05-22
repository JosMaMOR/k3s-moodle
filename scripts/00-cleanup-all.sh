#!/bin/bash
# 00-cleanup-all.sh - Limpieza TOTAL del entorno Moodle HA en K3s
# Elimina: namespace, todos los recursos dentro de él, PVCs, PVs y StorageClass
# Ejecutar como root ANTES de volver a correr 06-deploy-all.sh
#
# USO:
#   bash 00-cleanup-all.sh              # limpia K8s, conserva datos en RAID
#   bash 00-cleanup-all.sh --wipe-data  # limpia K8s + borra datos físicos del RAID

set -e

NAMESPACE="moodle-prod"
RAID_BASE="/moodlek3s"
WIPE_DATA=false

# Procesar argumento opcional
if [[ "$1" == "--wipe-data" ]]; then
  WIPE_DATA=true
fi

echo "=========================================="
echo "  LIMPIEZA COMPLETA - MOODLE HA K3s"
echo "=========================================="
echo "  Namespace : $NAMESPACE"
echo "  Datos RAID: $RAID_BASE"
echo "  Borrar data física: $WIPE_DATA"
echo "=========================================="
echo ""
echo "ADVERTENCIA: Este script eliminará todos los recursos de Kubernetes"
echo "del namespace '$NAMESPACE' incluyendo PVCs y PVs."
if [ "$WIPE_DATA" = true ]; then
  echo "ADVERTENCIA CRÍTICA: --wipe-data eliminará TODOS los datos físicos en $RAID_BASE"
fi
echo ""
read -p "¿Continuar? (escribe 'SI' para confirmar): " CONFIRM
if [[ "$CONFIRM" != "SI" ]]; then
  echo "Operación cancelada."
  exit 0
fi

echo ""
echo "[1/8] Eliminando Ingress y Middleware Traefik..."
kubectl delete ingress --all -n ${NAMESPACE} --ignore-not-found=true
kubectl delete middleware.traefik.io --all -n ${NAMESPACE} --ignore-not-found=true 2>/dev/null || true

echo "[2/8] Eliminando HPA y PDB..."
kubectl delete hpa --all -n ${NAMESPACE} --ignore-not-found=true
kubectl delete pdb --all -n ${NAMESPACE} --ignore-not-found=true

echo "[3/8] Eliminando CronJobs..."
kubectl delete cronjob --all -n ${NAMESPACE} --ignore-not-found=true

echo "[4/8] Eliminando Deployments y StatefulSets..."
kubectl delete deployment --all -n ${NAMESPACE} --ignore-not-found=true
kubectl delete statefulset --all -n ${NAMESPACE} --ignore-not-found=true

echo "      Esperando que los pods terminen..."
kubectl wait --for=delete pod --all -n ${NAMESPACE} --timeout=120s 2>/dev/null || true

echo "[5/8] Eliminando Services, ConfigMaps y Secrets..."
kubectl delete service --all -n ${NAMESPACE} --ignore-not-found=true
kubectl delete configmap --all -n ${NAMESPACE} --ignore-not-found=true
kubectl delete secret --all -n ${NAMESPACE} --ignore-not-found=true

echo "[6/8] Eliminando PersistentVolumeClaims..."
# Forzar eliminación en caso de que estén en Terminating por finalizers
for PVC in mariadb-pvc redis-pvc moodle-html-pvc moodle-data-pvc; do
  if kubectl get pvc "$PVC" -n ${NAMESPACE} &>/dev/null; then
    echo "      Eliminando PVC: $PVC"
    kubectl patch pvc "$PVC" -n ${NAMESPACE} \
      -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    kubectl delete pvc "$PVC" -n ${NAMESPACE} --ignore-not-found=true
  fi
done

echo "[7/8] Eliminando PersistentVolumes y StorageClass..."
for PV in mariadb-pv redis-pv moodle-html-pv moodle-data-pv; do
  if kubectl get pv "$PV" &>/dev/null; then
    echo "      Eliminando PV: $PV"
    kubectl patch pv "$PV" \
      -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    kubectl delete pv "$PV" --ignore-not-found=true
  fi
done
kubectl delete storageclass local-raid --ignore-not-found=true

echo "[8/8] Eliminando Namespace..."
kubectl delete namespace ${NAMESPACE} --ignore-not-found=true

# Esperar a que el namespace desaparezca completamente
echo "      Esperando eliminación del namespace (máx 60s)..."
RETRIES=0
while kubectl get namespace ${NAMESPACE} &>/dev/null; do
  sleep 3
  RETRIES=$((RETRIES+1))
  if [ $RETRIES -ge 20 ]; then
    echo "      AVISO: El namespace tarda en eliminarse. Forzando..."
    kubectl patch namespace ${NAMESPACE} \
      -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    break
  fi
  echo -n "."
done
echo ""

# ==========================================
# LIMPIEZA FÍSICA DE DATOS (opcional)
# ==========================================
if [ "$WIPE_DATA" = true ]; then
  echo ""
  echo "[WIPE] Eliminando datos físicos en $RAID_BASE ..."
  echo "       Esto es IRREVERSIBLE."
  read -p "       Confirmar borrado físico (escribe 'BORRAR'): " WIPE_CONFIRM
  if [[ "$WIPE_CONFIRM" == "BORRAR" ]]; then
    rm -rf ${RAID_BASE}/mariadb/*
    rm -rf ${RAID_BASE}/redis/*
    rm -rf ${RAID_BASE}/moodle-html/*
    rm -rf ${RAID_BASE}/moodle-data/*
    echo "       Datos físicos eliminados."
  else
    echo "       Borrado físico cancelado. Los datos en RAID se conservaron."
  fi
else
  echo ""
  echo "NOTA: Los datos físicos en $RAID_BASE se CONSERVARON."
  echo "      Para borrarlos también, ejecuta: bash $0 --wipe-data"
fi

echo ""
echo "=========================================="
echo "  LIMPIEZA COMPLETADA"
echo "=========================================="
echo ""
echo "Verificación final:"
echo ""
kubectl get pv 2>/dev/null | grep -E "mariadb|redis|moodle" || echo "  PVs: ninguno (correcto)"
kubectl get namespace ${NAMESPACE} 2>/dev/null || echo "  Namespace $NAMESPACE: eliminado (correcto)"

echo ""
echo "Listo para volver a desplegar:"
echo "  bash 06-deploy-all.sh"
echo ""
