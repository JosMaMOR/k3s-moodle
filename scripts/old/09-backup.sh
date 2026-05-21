#!/bin/bash
# 09-backup.sh - Backup manual de Moodle
# Ejecutar cuando sea necesario

set -e

BACKUP_DIR="/moodledata/backups"
DATE=$(date +%Y%m%d-%H%M%S)
NAMESPACE="moodle-prod"

echo "=========================================="
echo "BACKUP MANUAL MOODLE"
echo "Fecha: $DATE"
echo "=========================================="

mkdir -p $BACKUP_DIR

# Backup de configuración Kubernetes
echo "[*] Backup de configuración..."
kubectl get namespace $NAMESPACE -o yaml > $BACKUP_DIR/namespace-$DATE.yaml 2>/dev/null || true
kubectl get all -n $NAMESPACE -o yaml > $BACKUP_DIR/resources-$DATE.yaml 2>/dev/null || true
kubectl get configmap -n $NAMESPACE -o yaml > $BACKUP_DIR/configmaps-$DATE.yaml 2>/dev/null || true

# Backup de base de datos
echo "[*] Backup de base de datos..."
MARIADB_POD=$(kubectl get pods -n $NAMESPACE -l app=mariadb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$MARIADB_POD" ]; then
    kubectl exec -n $NAMESPACE $MARIADB_POD -- \
        mysqldump -u root -p'@@Ad1v1na#2@@' --all-databases --single-transaction \
        > $BACKUP_DIR/mariadb-$DATE.sql 2>/dev/null || \
        echo "⚠ No se pudo hacer backup de BD (verificar contraseña)"
else
    echo "⚠ No se encontró pod de MariaDB"
fi

# Backup de archivos (si hay espacio)
echo "[*] Backup de archivos..."
if [ -d "/moodledata/k3s-volumes/moodle-data" ]; then
    tar czf $BACKUP_DIR/moodledata-$DATE.tar.gz -C /moodledata/k3s-volumes moodle-data 2>/dev/null || \
        echo "⚠ No se pudo comprimir moodledata (posiblemente muy grande)"
else
    echo "⚠ Directorio moodle-data no encontrado"
fi

# Limpiar backups antiguos (7 días)
echo "[*] Limpiando backups antiguos..."
find $BACKUP_DIR -name "*.yaml" -mtime +7 -delete 2>/dev/null || true
find $BACKUP_DIR -name "*.sql" -mtime +7 -delete 2>/dev/null || true
find $BACKUP_DIR -name "*.tar.gz" -mtime +7 -delete 2>/dev/null || true

echo ""
echo "=========================================="
echo "BACKUP COMPLETADO"
echo "=========================================="
echo ""
ls -lh $BACKUP_DIR/*-$DATE* 2>/dev/null || echo "No se encontraron archivos de backup"
echo ""
echo "Ubicación: $BACKUP_DIR"
