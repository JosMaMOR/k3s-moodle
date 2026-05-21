#!/bin/bash
# 07-test.sh - Suite de pruebas básicas
# Ejecutar después de 06-deploy-all.sh

set -e

NAMESPACE="moodle-prod"

echo "=========================================="
echo "PRUEBAS BÁSICAS MOODLE HA"
echo "=========================================="

echo ""
echo "=== PODS ==="
kubectl get pods -n $NAMESPACE -o wide

echo ""
echo "=== SERVICIOS ==="
kubectl get svc -n $NAMESPACE

echo ""
echo "=== PVCs ==="
kubectl get pvc -n $NAMESPACE

echo ""
echo "=== INGRESS ==="
kubectl get ingress -n $NAMESPACE

echo ""
echo "=== PRUEBA DE CONECTIVIDAD INTERNA ==="
kubectl run test --image=curlimages/curl:latest --rm -i --restart=Never -n $NAMESPACE -- \
    -k -s https://moodle:8443/login/index.php \
    -w "HTTP Status: %{http_code}\nTiempo: %{time_total}s\n" \
    || echo "Prueba falló (puede ser normal si certificado no está listo)"

echo ""
echo "=== REPLICAS DE MOODLE ==="
kubectl get deployment moodle -n $NAMESPACE -o jsonpath='Ready: {.status.readyReplicas}/{.spec.replicas}'

echo ""
echo "=========================================="
echo "Pruebas completadas"
echo "Para monitoreo continuo: ./08-monitor.sh"
