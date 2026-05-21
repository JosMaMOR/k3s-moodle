#!/bin/bash
# 08-monitor.sh - Monitoreo continuo
# Ejecutar en terminal separada

NAMESPACE="moodle-prod"

clear
echo "=========================================="
echo "MONITOREO MOODLE HA - K3s + RAID"
echo "Presionar Ctrl+C para salir"
echo "=========================================="

while true; do
    clear
    echo "=========================================="
    echo "$(date '+%Y-%m-%d %H:%M:%S')"
    echo "=========================================="
    
    echo ""
    echo "--- PODS ---"
    kubectl get pods -n $NAMESPACE -o wide 2>/dev/null || echo "No se pudo obtener pods"
    
    echo ""
    echo "--- RECURSOS (si metrics-server disponible) ---"
    kubectl top pods -n $NAMESPACE 2>/dev/null || echo "metrics-server no disponible"
    
    echo ""
    echo "--- SERVICIOS ---"
    kubectl get svc -n $NAMESPACE 2>/dev/null || true
    
    echo ""
    echo "--- EVENTOS RECIENTES ---"
    kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | tail -5 2>/dev/null || true
    
    echo ""
    echo "--- USO DEL RAID ---"
    df -h /moodledata 2>/dev/null | tail -1 || echo "No disponible"
    
    sleep 5
done
