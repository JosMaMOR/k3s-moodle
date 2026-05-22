# ============================================================
# DETENER Y ELIMINAR STACK COMPLETO — despliegue desde cero
# ============================================================

# 1. Escalar todo a 0 para liberar PVCs limpiamente
kubectl scale deployment moodle redis -n moodle-prod --replicas=0 2>/dev/null
kubectl scale statefulset mariadb -n moodle-prod --replicas=0 2>/dev/null
kubectl patch cronjob moodle-cron -n moodle-prod \
  -p '{"spec":{"suspend":true}}' 2>/dev/null

# Esperar que los pods terminen
kubectl wait --for=delete pod --all -n moodle-prod --timeout=60s 2>/dev/null
echo "✓ Pods detenidos"

# 2. Eliminar todos los recursos de Kubernetes
kubectl delete namespace moodle-prod --grace-period=0 --force 2>/dev/null
kubectl delete pv mariadb-pv redis-pv moodle-html-pv moodle-data-pv \
  --grace-period=0 --force 2>/dev/null
kubectl delete storageclass local-raid 2>/dev/null
echo "✓ Recursos Kubernetes eliminados"

# 3. Eliminar datos del RAID completamente
rm -rf /moodlek3s/mariadb/*
rm -rf /moodlek3s/redis/*
rm -rf /moodlek3s/moodle-html/*
rm -rf /moodlek3s/moodle-data/*
echo "✓ Datos del RAID eliminados"

# 4. Verificar que quedó limpio
echo ""
echo "=== Estado post-limpieza ==="
kubectl get all -n moodle-prod 2>/dev/null || echo "Namespace moodle-prod eliminado"
kubectl get pv 2>/dev/null | grep -E "mariadb|redis|moodle" || echo "Sin PVs residuales"
ls -la /moodlek3s/
echo ""
echo "✓ Sistema listo para redespliegue"
echo ""
echo "Siguiente paso:"
echo "  bash 06-deploy-all.sh"
