#!/bin/bash
# 06-deploy-all.sh - Despliegue completo de Moodle HA en K3s
# Ejecutar como root después de 05-build-image.sh
#
# INSTALACION DE LONGHORN WIP:
#   - WIP Instalacion de Longhorn despues de creacion del registry - l 110
#   - WIP Linea 281. Hacer algo para poder cambiar el numero de replicas de longhorn al ejecutar el script
#   - WIP Linea 471 - Tamaño de volumen para moodle. En prod deben ser 50Gi
#
# CORRECCIONES APLICADAS v6:
#   - Despliegue en 2 fases:
#     Fase 1: 1 réplica para instalación inicial (evita race condition)
#     Fase 2: escala a 3 réplicas HA tras config.php generado
#   - maxUnavailable: 0 durante instalación (no interrumpir el pod único)
#   - Verificación de config.php y tablas BD entre fases
#
# CORRECCIONES APLICADAS v5:
#   - Apache HTTP only puerto 8080, sin SSL en la imagen
#   - Eliminado volumeMount ssl-certs y Secret mcc-tesoem-tls
#   - Probes cambiadas de HTTPS:8443 a HTTP:8080
#   - Ingress apunta a puerto 8080 HTTP (Traefik termina TLS)
#   - serversscheme cambiado de https a http
#
# CORRECCIONES APLICADAS v4:
#   - Imagen Moodle cambiada de "moodle-apache:5.1-k3s-raid"
#     a "localhost:5000/moodle-apache:5.1-k3s-raid" (registry local)
#   - imagePullPolicy cambiado de IfNotPresent a Always para que K3s
#     siempre haga pull desde el registry local en lugar de buscar
#     la imagen en el cache local de containerd
#   - Añadida verificación de registry al inicio del script
#   - Añadida verificación de imagen en registry antes de desplegar
#   - CronJob actualizado con la nueva imagen del registry
#
# CORRECCIONES APLICADAS v3:
#   - PV moodle-html y moodle-data con label 'volume' diferenciadora
#     para evitar que ambos PVCs compitan por el mismo PV en el binding.
#   - PVC moodle-html-pvc y moodle-data-pvc con selector.matchLabels
#     que incluye 'volume: moodle-html' / 'volume: moodle-data'.
#   - Redis liveness/readiness probe incluye autenticación:
#     redis-cli -a $(REDIS_PASSWORD) ping  ← evita NOAUTH con --requirepass
#   - CronJob: moodle-html montado sin readOnly en volumes.pvc (el PVC
#     es ReadWriteMany) y con readOnly: true solo en volumeMount del
#     contenedor — separación correcta entre claim y mount.
#   - Todos los fixes de v2 se conservan intactos.
#
# CORRECCIONES APLICADAS v2:
#   - Añadidos PersistentVolumes (hostPath sobre RAID en /moodlek3s)
#   - Añadidos PersistentVolumeClaims para mariadb, redis, moodle-html, moodle-data
#   - mariadb: migrado de volumes.pvc → volumes + claimName (patrón correcto
#     para PVC estático con nombre fijo en single-node StatefulSet)
#   - moodle-html-pvc y moodle-data-pvc con ReadWriteMany (3 réplicas + CronJob)
#   - mariadb-pvc y redis-pvc con ReadWriteOnce (acceso exclusivo)
#   - MariaDB: 'command' reemplazado por 'args' — preserva docker-entrypoint.sh
#     y permite que mysql_install_db inicialice el directorio en primer arranque
#   - MariaDB probes usan mariadb-admin con -p${MARIADB_ROOT_PASSWORD}
#   - Redis liveness/readiness probe corregida (redis-cli ping, no incr)
#   - Orden de aplicación: StorageClass → PV → PVC → workloads
#   - nodeAffinity en PVs para garantizar scheduling en k3s-moodle-master

set -e

echo "=========================================="
echo "DESPLIEGUE MOODLE HA - K3s + RAID"
echo "=========================================="

NAMESPACE="moodle-prod"
NODE_NAME="k3s-moodle-master"
MANIFEST_DIR="/root/k3s-moodle/manifests"
# Ruta base en disco RAID donde vivirán los datos
RAID_BASE="/moodlek3s"
LONGHORN_NAMESPACE="longhorn-system"

# ── Registry local ────────────────────────────────────────────────────────────
# FIX v4: imagen con prefijo del registry local — K3s hace pull desde
# localhost:5000 en lugar de intentar resolver en Docker Hub (que causa
# ImagePullBackOff porque la imagen es local y no existe en internet).
REGISTRY_HOST="localhost"
REGISTRY_PORT="5000"
IMAGE_NAME="moodle-apache"
IMAGE_TAG="5.1-k3s-raid"
MOODLE_IMAGE="${REGISTRY_HOST}:${REGISTRY_PORT}/${IMAGE_NAME}:${IMAGE_TAG}"

# ── Verificar registry antes de continuar ────────────────────────────────────
echo "[*] Verificando registry local en ${REGISTRY_HOST}:${REGISTRY_PORT}..."
if ! curl -sf "http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/" > /dev/null 2>&1; then
  echo ""
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║  ERROR: Registry local no disponible en localhost:5000       ║"
  echo "  ║  Ejecuta primero: ./02-setup-registry.sh                     ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  exit 1
fi
echo "[*] Registry OK — http://localhost:${REGISTRY_PORT}/v2/"

# Verificar que la imagen Moodle está en el registry
echo "[*] Verificando imagen ${MOODLE_IMAGE} en el registry..."
if ! curl -sf "http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/${IMAGE_NAME}/tags/list" \
     | grep -q "${IMAGE_TAG}"; then
  echo ""
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║  ERROR: Imagen no encontrada en el registry local            ║"
  echo "  ║  Imagen esperada: ${MOODLE_IMAGE}"
  echo "  ║  Ejecuta primero: ./05-build-image.sh                        ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  exit 1
fi
echo "[*] Imagen ${MOODLE_IMAGE} disponible en el registry."

mkdir -p ${MANIFEST_DIR}
cd ${MANIFEST_DIR}

# ==========================================
# 1. INSTALACION LONGHORN
# Idea
# - Deberia agregar algo para poder poner argumentos para diferentes campos del script?
# ==========================================

echo "=========================================="
echo "INSTALACION DE LONGHORN"
echo "=========================================="

echo "[*] Verificando instalacion de Longhorn"

if kubectl get namespace longhorn-system >/dev/null 2>&1; then
    
    echo "[*] Longhorn ya existe con el namespace lonhorn-system. Omitiendo instalacion"
    
    else

    echo "[*] Instalando Longhorn version 1.11.2"

    kubectl annotate node ${NODE_NAME} node.longhorn.io/default-disks-config='[{"path":"/moodlek3s/longhorn","allowScheduling":true,"storageReserved":0,"tags":["storage"]}]' --overwrite
    
# ── Longhorn vía Kustomize: manager solo en nodos de almacenamiento ────────
    # Vendorizamos el manifiesto upstream (pin v1.11.2) y le superponemos parches
    # mínimos: nodeSelector del DaemonSet del manager + setting que rige a los
    # componentes gestionados por Longhorn (instance-manager, CSI, share-manager).
    # Ambos apuntan a la label tesoem.edu.mx/longhorn-node=true → sin esa label,
    # ningún componente de Longhorn se programa (la Pi nunca la recibe).
    LH_DIR="${MANIFEST_DIR}/longhorn"
    mkdir -p "${LH_DIR}"

    curl -sfL https://raw.githubusercontent.com/longhorn/longhorn/v1.11.2/deploy/longhorn.yaml \
      -o "${LH_DIR}/base.yaml" || { echo "ERROR: no se pudo descargar longhorn.yaml"; exit 1; }

    cat > "${LH_DIR}/patch-manager-nodeselector.yaml" <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: longhorn-manager
  namespace: longhorn-system
spec:
  template:
    spec:
      nodeSelector:
        tesoem.edu.mx/longhorn-node: "true"
EOF

    # El ConfigMap guarda los settings como UN string; el merge reemplaza el
    # valor completo, así que reproducimos los 2 defaults de v1.11.2 + el nuestro.
    cat > "${LH_DIR}/patch-system-managed-nodeselector.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: longhorn-default-setting
  namespace: longhorn-system
data:
  default-setting.yaml: |-
    priority-class: "longhorn-critical"
    disable-revision-counter: "{\"v1\":\"true\"}"
    system-managed-components-node-selector: "tesoem.edu.mx/longhorn-node:true"
EOF

    cat > "${LH_DIR}/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - base.yaml
patches:
  - path: patch-manager-nodeselector.yaml
  - path: patch-system-managed-nodeselector.yaml
EOF

    # CRÍTICO: la label en A va ANTES del apply. Si el manager tiene nodeSelector
    # y ningún nodo la tiene, el DaemonSet queda en desired=0 y el rollout
    # "pasaría" con cero pods → Longhorn no arrancaría.
    kubectl label node ${NODE_NAME} tesoem.edu.mx/longhorn-node=true --overwrite

    kubectl apply -k "${LH_DIR}/"

    echo "[*] Esperando a que el longhorn-manager este listo (hasta 300s)..."

    # Primero esperar a que el objeto DaemonSet EXISTA. Tras 'kubectl apply',
    # Kubernetes tarda unos segundos en crear el DaemonSet; si consultamos su
    # rollout antes de que exista, 'rollout status' falla al instante (no por
    # timeout real) y abortaría el script aunque Longhorn esté arrancando bien.
    RETRIES=0
    until kubectl get daemonset/longhorn-manager -n ${LONGHORN_NAMESPACE} >/dev/null 2>&1; do
      sleep 5
      RETRIES=$((RETRIES+1))
      if [ $RETRIES -ge 30 ]; then
        echo "  ERROR: el DaemonSet longhorn-manager no apareció en 60s"
        exit 1
      fi
    done

    echo "    → Esperando que los pods longhorn-manager bajen imágenes y arranquen..."
    echo "      (fresh install descarga imágenes; puede tardar 2-5 min)"
    echo "      Progreso en otra terminal: kubectl get pods -n ${LONGHORN_NAMESPACE} -w"

    # --for=condition=ready espera a que TODOS los contenedores del pod (2/2)
    # estén listos. Timeout amplio porque la descarga de imágenes en fresh
    # install es lo que realmente tarda.
    kubectl wait --for=condition=ready pod \
        -l app=longhorn-manager \
        -n ${LONGHORN_NAMESPACE} --timeout=600s 2>/dev/null || true

    # El rollout status confirma el estado final del DaemonSet. Timeout corto
    # porque a este punto las imágenes ya bajaron....
    if ! kubectl rollout status daemonset/longhorn-manager \
         -n ${LONGHORN_NAMESPACE} --timeout=120s; then
      echo ""
      echo "  ╔══════════════════════════════════════════════════════════════╗"
      echo "  ║  ERROR: longhorn-manager no completó el rollout              ║"
      echo "  ║  Revisa: kubectl get pods -n longhorn-system                 ║"
      echo "  ╚══════════════════════════════════════════════════════════════╝"
      exit 1
    fi
    echo "[*] ✓ longhorn-manager listo."
    
fi

echo "[*] Esperando a que los componentes de Longhorn estén listos..."
echo "    (La primera instalación descarga imágenes; puede tardar 1-5 min)"

# 1) Pods CSI Running — AQUÍ se va el tiempo (descarga de imágenes la 1ra vez)
echo "    → Esperando pods longhorn-csi-plugin..."
if kubectl wait --for=condition=ready pod \
        -l app=longhorn-csi-plugin \
        -n "${LONGHORN_NAMESPACE}" --timeout=600s 2>/dev/null; then
    echo "    ✓ Pods CSI listos"
else
    echo "    ⚠ Los pods CSI tardaron más de 600s — revisa 'kubectl get pods -n ${LONGHORN_NAMESPACE}'"
fi

# 2) El driver-deployer es quien registra el csidriver
echo "    → Esperando longhorn-driver-deployer..."
kubectl rollout status deployment/longhorn-driver-deployer \
    -n "${LONGHORN_NAMESPACE}" --timeout=300s 2>/dev/null || true

# 3) Confirmación final del csidriver (a estas alturas ya debe existir casi al instante)
echo "    → Verificando registro del CSI driver..."
RETRIES=0
until kubectl get csidriver driver.longhorn.io >/dev/null 2>&1; do
    sleep 5
    RETRIES=$((RETRIES+1))
    [ $RETRIES -ge 24 ] && { echo "  ERROR: CSI driver no se registró tras esperar componentes"; exit 1; }
done
echo "[*] ✓ Longhorn instalado y CSI driver registrado."

# ── CAMBIO LONGHORN: desmarcar el StorageClass default de K3s ──────────────────
# K3s incluye 'local-path' marcado como StorageClass default. Si se queda como
# default, un PVC sin storageClassName explícito lo usaría en lugar de Longhorn.
# Lo desmarcamos para que NINGÚN StorageClass sea default y todo sea explícito.
if kubectl get storageclass local-path >/dev/null 2>&1; then
  echo "[*] Desmarcando 'local-path' como StorageClass default de K3s..."
  kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true
fi

# ── CAMBIO LONGHORN: etiquetar este nodo para almacenamiento ──────────────────
# El StorageClass longhorn-moodle usa nodeSelector: "storage". Sin este tag,
# Longhorn no colocaría réplicas en el nodo. Para un solo nodo basta con
# etiquetar el master. (Con más nodos: etiquetar cada nodo de datos; ver nota
# al final.) El árbitro Raspberry Pi NUNCA se etiqueta → no almacena réplicas.
echo "[*] Etiquetando nodo ${NODE_NAME} con tag de almacenamiento Longhorn..."
kubectl annotate node ${NODE_NAME} node.longhorn.io/default-node-tags='["storage"]' --overwrite >/dev/null 2>&1 || true

# Crear directorios base en el RAID si no existen
# ── CAMBIO LONGHORN: moodle-html y moodle-data YA NO se crean aquí ────────────
# Longhorn gestiona el ciclo de vida de esos volúmenes (creación, permisos vía
# fsGroup del pod). Solo MariaDB y Redis siguen necesitando directorios locales.
echo "[*] Preparando directorios en RAID (solo MariaDB y Redis)..."
mkdir -p ${RAID_BASE}/mariadb
mkdir -p ${RAID_BASE}/redis

# ── Detección de inicialización incompleta de MariaDB ─────────────────────────
# Si el directorio tiene archivos InnoDB pero NO tiene mysql/db.frm o mysql/db.MAD
# significa que una ejecución anterior falló a mitad de la inicialización.
# En ese caso es más seguro limpiar y dejar que MariaDB inicialice desde cero.
MARIADB_DIR="${RAID_BASE}/mariadb"
INNODB_FILE="${MARIADB_DIR}/ibdata1"
MYSQL_DB_FILE="${MARIADB_DIR}/mysql/db.MAD"

if [ -f "${INNODB_FILE}" ] && [ ! -f "${MYSQL_DB_FILE}" ]; then
  echo ""
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║  ADVERTENCIA: datos de MariaDB incompletos detectados        ║"
  echo "  ║  Se encontró ibdata1 pero faltan tablas del sistema mysql.*  ║"
  echo "  ║  Limpiando directorio para permitir inicialización limpia... ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  echo ""
  # Backup de seguridad del estado corrupto (por si acaso)
  BACKUP_DIR="${RAID_BASE}/mariadb-corrupted-$(date +%Y%m%d-%H%M%S)"
  mv "${MARIADB_DIR}" "${BACKUP_DIR}"
  mkdir -p "${MARIADB_DIR}"
  echo "  Estado anterior respaldado en: ${BACKUP_DIR}"
  echo "  Directorio limpio y listo para inicialización."
  echo ""
fi

# Permisos por servicio — cada imagen corre con un uid distinto:
#   uid 999  → mariadb:lts      (usuario interno: mysql) [Debian - auto-inicializa]
#   uid 999  → redis:7-alpine   (usuario interno: redis)
# ── CAMBIO LONGHORN: moodle-html y moodle-data ya no se chmodean aquí ─────────
# Sus permisos los resuelve el pod de Moodle vía securityContext.fsGroup: 1001
# sobre el volumen que Longhorn monta. El chown/chmod del host ya no aplica
# porque el volumen ya no es un directorio del RAID local.

chown -R 999:999  ${RAID_BASE}/mariadb
chmod -R 750      ${RAID_BASE}/mariadb

chown -R 999:999  ${RAID_BASE}/redis
chmod -R 750      ${RAID_BASE}/redis

echo "[*] Permisos de directorios:"
ls -la ${RAID_BASE}/

# ==========================================
# 1. NAMESPACE
# ==========================================
echo "[*] Creando namespace..."

cat > 00-namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: moodle-prod
  labels:
    app.kubernetes.io/name: moodle
    app.kubernetes.io/version: "5.1"
    environment: production
EOF

kubectl apply -f 00-namespace.yaml

# ==========================================
# 2. STORAGECLASS LOCAL (local-raid + longhorn-moodle
# ==========================================
# ── CAMBIO LONGHORN: ahora hay DOS StorageClasses ─────────────────────────────
#   local-raid      → MariaDB y Redis (almacenamiento local en RAID, sin cambios)
#   longhorn-moodle → moodle-html y moodle-data (RWX replicado por Longhorn)
echo "[*] Creando StorageClass..."

cat > 01-storageclass.yaml << 'EOF'
# ── StorageClass 1: local-raid (MariaDB + Redis) — SIN CAMBIOS ───────────────
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-raid
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: kubernetes.io/no-provisioner
# Immediate: el PV se vincula al PVC en el momento de su creación,
# sin esperar a que un Pod lo consuma. Necesario para que el loop
# de verificación "Bound" del script funcione correctamente.
volumeBindingMode: Immediate
reclaimPolicy: Retain
---
# ── StorageClass 2: longhorn-moodle (moodle-html + moodle-data) ──────────────
# driver.longhorn.io aprovisiona dinámicamente: no hay que declarar PVs a mano.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-moodle
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: Immediate
parameters:
  # numberOfReplicas viene de la variable LONGHORN_REPLICAS (1 en un nodo).
  numberOfReplicas: "2"
  staleReplicaTimeout: "30"
  fsType: "ext4"
  # nodeSelector: solo nodos con el tag "storage" reciben réplicas.
  # La Raspberry Pi (árbitro) nunca lleva este tag → queda excluida.
  nodeSelector: "storage"
EOF

kubectl apply -f 01-storageclass.yaml

# ==========================================
# 3. PERSISTENT VOLUMES (hostPath → RAID)
# ==========================================
# ── CAMBIO LONGHORN: solo quedan MariaDB y Redis ─────────────────────────────
# Los PVs de moodle-html y moodle-data DESAPARECEN: Longhorn los aprovisiona
# dinámicamente al aplicar sus PVCs. Ya no se declaran a mano.
# MariaDB y Redis siguen con PVs hostPath estáticos sobre el RAID local.

echo "[*] Creando PersistentVolumes..."

cat > 02-persistent-volumes.yaml << 'EOF'
# ── PV: MariaDB ──────────────────────────────────────────────────────────────
apiVersion: v1
kind: PersistentVolume
metadata:
  name: mariadb-pv
  labels:
    app: mariadb
    tier: database
spec:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteOnce           # Solo un pod a la vez (StatefulSet 1 réplica)
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-raid
  volumeMode: Filesystem
  local:
    path: /moodlek3s/mariadb
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k3s-moodle-master
---
# ── PV: Redis ─────────────────────────────────────────────────────────────────
apiVersion: v1
kind: PersistentVolume
metadata:
  name: redis-pv
  labels:
    app: redis
    tier: cache
spec:
  capacity:
    storage: 2Gi
  accessModes:
    - ReadWriteOnce           # Solo un pod (Deployment 1 réplica)
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-raid
  volumeMode: Filesystem
  local:
    path: /moodlek3s/redis
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k3s-moodle-master
EOF

kubectl apply -f 02-persistent-volumes.yaml

# ==========================================
# 4. PERSISTENT VOLUME CLAIMS
# ==========================================
# Los PVCs usan selector.matchLabels para vincularse al PV correcto.
# storageClassName: local-raid debe coincidir con el PV.
# El binding es estático (no hay provisioner automático).
#
# FIX v3: moodle-html-pvc y moodle-data-pvc incluyen 'volume: moodle-html'
# / 'volume: moodle-data' en matchLabels para binding determinístico.
echo "[*] Creando PersistentVolumeClaims..."

cat > 03-persistent-volume-claims.yaml << 'EOF'
# ============================================================================
# PersistentVolumeClaims
# ============================================================================
# MariaDB y Redis: reclaman PVs locales estáticos (storageClassName: local-raid)
#   mediante un selector de labels, igual que antes.
# Moodle (html y data): reclaman almacenamiento a Longhorn, que lo aprovisiona
#   dinámicamente. SIN selector — no hay PV preexistente que emparejar.
# ----------------------------------------------------------------------------

# ── PVC: MariaDB ──────────────────────────────────────────────────────────────
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mariadb-pvc
  namespace: moodle-prod
  labels:
    app: mariadb
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-raid
  resources:
    requests:
      storage: 20Gi
  selector:
    matchLabels:
      app: mariadb
---
# ── PVC: Redis ────────────────────────────────────────────────────────────────
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-pvc
  namespace: moodle-prod
  labels:
    app: redis
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-raid
  resources:
    requests:
      storage: 2Gi
  selector:
    matchLabels:
      app: redis
---
# ── PVC: Moodle HTML ──────────────────────────────────────────────────────────
# FIX v3: matchLabels incluye 'volume: moodle-html' → binding determinístico
# al PV correcto (10Gi, /moodlek3s/moodle-html), no al de 50Gi de moodle-data.
# CAMBIO: ahora reclama a Longhorn (longhorn-moodle), no a local-raid.
# Longhorn crea un volumen RWX de 10Gi a la medida. Sin selector: no hay un PV
# preexistente que emparejar, Longhorn aprovisiona uno nuevo dinámicamente.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: moodle-html-pvc
  namespace: moodle-prod
  labels:
    app: moodle
    volume: moodle-html
spec:
  accessModes:
    - ReadWriteMany          # RWX real entre nodos (Longhorn vía NFS interno)
  storageClassName: longhorn-moodle
  resources:
    requests:
      storage: 10Gi
---
# ── PVC: Moodle Data ──────────────────────────────────────────────────────────
# FIX v3: matchLabels incluye 'volume: moodle-data' → binding determinístico
# al PV correcto (50Gi, /moodlek3s/moodle-data), no al de 10Gi de moodle-html.
# CAMBIO: ahora reclama a Longhorn (longhorn-moodle), no a local-raid.
# Volumen RWX de 50Gi para moodledata, compartido entre todas las réplicas.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: moodle-data-pvc
  namespace: moodle-prod
  labels:
    app: moodle
    volume: moodle-data
spec:
  accessModes:
    - ReadWriteMany          # RWX real entre nodos (Longhorn vía NFS interno)
  storageClassName: longhorn-moodle
  resources:
    requests:
      storage: 10Gi
EOF

kubectl apply -f 03-persistent-volume-claims.yaml

# Verificar que los PVCs queden en estado Bound antes de continuar
echo "[*] Esperando que los PVCs queden en estado Bound..."
for PVC in mariadb-pvc redis-pvc moodle-html-pvc moodle-data-pvc; do
  echo -n "    Esperando $PVC..."
  RETRIES=0
  until kubectl get pvc "$PVC" -n moodle-prod -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Bound"; do
    sleep 3
    RETRIES=$((RETRIES+1))
    if [ $RETRIES -ge 80 ]; then
      echo " ERROR: $PVC no llegó a Bound en 240s"
      kubectl describe pvc "$PVC" -n moodle-prod
      exit 1
    fi
    echo -n "."
  done
  echo " OK"
done

# ==========================================
# 5. CONFIGMAP
# ==========================================
echo "[*] Creando ConfigMap..."

cat > 10-configmap.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: moodle-config
  namespace: moodle-prod
data:
  IMAGE_VERSION: "5.1"
  MOODLE_VERSION: "5.1.3"

  # MariaDB
  MARIADB_HOST: "mariadb"
  MARIADB_PORT: "3306"
  MARIADB_DATABASE: "moodle"
  MARIADB_USER: "moodleTESOEM"
  MARIADB_CHARACTER_SET: "utf8mb4"
  MARIADB_COLLATE: "utf8mb4_unicode_ci"

  # Moodle DB
  MOODLE_DB_HOST: "mariadb"
  MOODLE_DB_PORT: "3306"
  MOODLE_DB_NAME: "moodle"
  MOODLE_DB_USER: "moodleTESOEM"

  # Redis
  REDIS_HOST: "redis"
  REDIS_PORT: "6379"

  # Moodle
  MOODLE_URL: "https://mcc.tesoem.edu.mx"
  MOODLE_LANG: "es_mx"
  MOODLE_CHMOD: "2777"
  MOODLE_FULLNAME: "Plataforma Educativa TESOEM"
  MOODLE_SHORTNAME: "TESOEM-Moodle"
  MOODLE_ADMIN_USER: "admin"
  MOODLE_ADMIN_EMAIL: "admin@tesoem.edu.mx"
  #MOODLE_DIRROOT: "/var/www/html/public"
  # DB install
  DB_TYPE: "mariadb"
  DB_HOST: "mariadb"
  DB_PORT: "3306"
  DB_NAME: "moodle"
  DB_USER: "moodleTESOEM"

  # K3s
  ENABLE_CRON: "false"
  K3S_MODE: "true"

  # SSL
  SERVER_NAME: "mcc.tesoem.edu.mx"
  SSL_DIR: "/etc/apache2/ssl"
  SSL_COUNTRY: "MX"
  SSL_STATE: "Mexico"
  SSL_CITY: "Tecamachalco"
  SSL_ORG: "TESOEM"
  SSL_OU: "SISTEMAS"
  SSL_DAYS: "365"
  SSL_SAN: "DNS:mcc.tesoem.edu.mx,DNS:localhost,IP:127.0.0.1"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mariadb-config
  namespace: moodle-prod
data:
  MARIADB_DATABASE: "moodle"
  MARIADB_USER: "moodleTESOEM"
  MARIADB_CHARACTER_SET: "utf8mb4"
  MARIADB_COLLATE: "utf8mb4_unicode_ci"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-config
  namespace: moodle-prod
data:
  REDIS_HOST: "redis"
  REDIS_PORT: "6379"
EOF

kubectl apply -f 10-configmap.yaml

# ==========================================
# 6. SECRETS
# ==========================================
echo "[*] Creando Secrets..."

cat > 11-secrets.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: moodle-secrets
  namespace: moodle-prod
type: Opaque
stringData:
  MARIADB_ROOT_PASSWORD: "@@Ad1v1na#2@@"
  MARIADB_PASSWORD: "@@Ad1v1na#2@@"
  MOODLE_DB_PASS: "@@Ad1v1na#2@@"
  DB_PASS: "@@Ad1v1na#2@@"
  REDIS_PASSWORD: "@@Ad1v1na#2@@"
  MOODLE_ADMIN_PASS: "@@Ad1v1na#2@@"
---
apiVersion: v1
kind: Secret
metadata:
  name: mariadb-secrets
  namespace: moodle-prod
type: Opaque
stringData:
  MARIADB_ROOT_PASSWORD: "@@Ad1v1na#2@@"
  MARIADB_PASSWORD: "@@Ad1v1na#2@@"
---
apiVersion: v1
kind: Secret
metadata:
  name: redis-secrets
  namespace: moodle-prod
type: Opaque
stringData:
  REDIS_PASSWORD: "@@Ad1v1na#2@@"
EOF

kubectl apply -f 11-secrets.yaml

# ==========================================
# 7. MARIADB STATEFULSET
# ==========================================
# CAMBIO CLAVE (v2): Se usa 'args' en lugar de 'command'.
# 'command' sobreescribe docker-entrypoint.sh completo → MariaDB nunca
# ejecuta mysql_install_db y el directorio vacío nunca se inicializa.
# 'args' pasa los flags directamente al entrypoint que sí inicializa primero.
#
# Se usa volumes + claimName: mariadb-pvc (PVC estático con nombre fijo).
# Más predecible que volumeClaimTemplates en single-node con PVs manuales.
echo "[*] Desplegando MariaDB..."

cat > 20-mariadb.yaml << 'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mariadb
  namespace: moodle-prod
  labels:
    app: mariadb
    tier: database
spec:
  serviceName: mariadb
  replicas: 1
  selector:
    matchLabels:
      app: mariadb
  template:
    metadata:
      labels:
        app: mariadb
        tier: database
    spec:
      nodeSelector:
        kubernetes.io/hostname: k3s-moodle-master
      terminationGracePeriodSeconds: 60
      containers:
      - name: mariadb
        image: mariadb:lts
        ports:
        - containerPort: 3306
          name: mysql
        envFrom:
        - configMapRef:
            name: mariadb-config
        - secretRef:
            name: mariadb-secrets
        env:
        - name: MARIADB_HOST
          value: "localhost"
        # IMPORTANTE: usar 'args' en lugar de 'command'
        # 'command' sobreescribe docker-entrypoint.sh completo → MariaDB nunca
        # ejecuta mysql_install_db y el directorio vacío nunca se inicializa.
        # 'args' pasa los flags directamente al entrypoint que sí inicializa primero.
        args:
        - --character-set-server=utf8mb4
        - --collation-server=utf8mb4_unicode_ci
        - --init-connect=SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci
        - --skip-character-set-client-handshake
        - --innodb_file_per_table=1
        - --innodb_buffer_pool_size=1G
        - --innodb_log_file_size=256M
        - --max_connections=200
        volumeMounts:
        - name: mariadb-data
          mountPath: /var/lib/mysql
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        livenessProbe:
          exec:
            command:
            - sh
            - -c
            - "mariadb-admin ping -h localhost -u root -p${MARIADB_ROOT_PASSWORD}"
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          exec:
            command:
            - sh
            - -c
            - "mariadb-admin ping -h localhost -u root -p${MARIADB_ROOT_PASSWORD}"
          initialDelaySeconds: 15
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
      # Usar volumes + claimName para PVC estático con nombre fijo
      # (más predecible que volumeClaimTemplates en single-node)
      volumes:
      - name: mariadb-data
        persistentVolumeClaim:
          claimName: mariadb-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: mariadb
  namespace: moodle-prod
  labels:
    app: mariadb
spec:
  type: ClusterIP
  ports:
  - port: 3306
    targetPort: 3306
    protocol: TCP
    name: mysql
  selector:
    app: mariadb
EOF

kubectl apply -f 20-mariadb.yaml

echo "[*] Esperando MariaDB (hasta 300s)..."
kubectl rollout status statefulset/mariadb -n moodle-prod --timeout=300s

# ==========================================
# 8. REDIS DEPLOYMENT
# ==========================================
# FIX v3: liveness y readiness probe incluyen autenticación.
# Con --requirepass activo, 'redis-cli ping' sin credenciales devuelve
# "NOAUTH Authentication required" (exit code 1) y la probe falla
# aunque Redis esté perfectamente saludable.
# Solución: sh -c con variable de entorno expandida en tiempo de ejecución.
echo "[*] Desplegando Redis..."

cat > 21-redis.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: moodle-prod
  labels:
    app: redis
    tier: cache
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
        tier: cache
    spec:
      nodeSelector:
        kubernetes.io/hostname: k3s-moodle-master
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
          name: redis
        command:
        - redis-server
        - --appendonly
        - "yes"
        - --requirepass
        - $(REDIS_PASSWORD)
        - --maxmemory
        - "256mb"
        - --maxmemory-policy
        - "allkeys-lru"
        - --bind
        - "0.0.0.0"
        envFrom:
        - secretRef:
            name: redis-secrets
        volumeMounts:
        - name: redis-data
          mountPath: /data
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          exec:
            # FIX v3: incluir autenticación — sin -a la probe falla con NOAUTH
            # cuando --requirepass está activo.
            command:
            - sh
            - -c
            - "redis-cli -a ${REDIS_PASSWORD} ping | grep -q PONG"
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 3
        readinessProbe:
          exec:
            command:
            - sh
            - -c
            - "redis-cli -a ${REDIS_PASSWORD} ping | grep -q PONG"
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
      volumes:
      - name: redis-data
        persistentVolumeClaim:
          claimName: redis-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: moodle-prod
  labels:
    app: redis
spec:
  type: ClusterIP
  ports:
  - port: 6379
    targetPort: 6379
    protocol: TCP
    name: redis
  selector:
    app: redis
EOF

kubectl apply -f 21-redis.yaml

echo "[*] Esperando Redis (hasta 120s)..."
kubectl rollout status deployment/redis -n moodle-prod --timeout=120s

# ==========================================
# 9. MOODLE DEPLOYMENT (3 RÉPLICAS)
# ==========================================
echo "[*] Desplegando Moodle (1 réplica — instalación inicial)..."

cat > 30-moodle.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: moodle
  namespace: moodle-prod
  labels:
    app: moodle
    tier: frontend
spec:
  # INSTALACIÓN INICIAL: 1 réplica para evitar que múltiples pods
  # ejecuten admin/cli/install.php simultáneamente y se corrompan.
  # El script escala a 3 réplicas HA automáticamente tras la instalación.
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: moodle
  template:
    metadata:
      labels:
        app: moodle
        tier: frontend
    spec:
      nodeSelector:
        kubernetes.io/hostname: k3s-moodle-master
      securityContext:
        fsGroup: 1001
      initContainers:
      - name: wait-for-db
        image: busybox:1.36
        command:
        - sh
        - -c
        - |
          echo "Esperando MariaDB..."
          until nc -z mariadb 3306; do
            sleep 5
          done
          echo "MariaDB OK"
          echo "Esperando Redis..."
          until nc -z redis 6379; do
            sleep 3
          done
          echo "Redis OK"
        resources:
          requests:
            memory: "32Mi"
            cpu: "50m"
      containers:
      - name: moodle
        image: localhost:5000/moodle-apache:5.1-k3s-raid
        # FIX v4: Always → K3s hace pull desde registry local en cada pod.
        # Con IfNotPresent buscaba en cache local de containerd (vacío),
        # fallaba, e intentaba Docker Hub donde la imagen no existe.
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: http
          protocol: TCP
        envFrom:
        - configMapRef:
            name: moodle-config
        - secretRef:
            name: moodle-secrets
        volumeMounts:
        - name: moodle-html
          mountPath: /var/www/html
        - name: moodle-data
          mountPath: /var/www/moodledata

        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /login/index.php
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /login/index.php
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        startupProbe:
          httpGet:
            path: /login/index.php
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 30
      volumes:
      - name: moodle-html
        persistentVolumeClaim:
          claimName: moodle-html-pvc
      - name: moodle-data
        persistentVolumeClaim:
          claimName: moodle-data-pvc

      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - moodle
              topologyKey: kubernetes.io/hostname
---
apiVersion: v1
kind: Service
metadata:
  name: moodle
  namespace: moodle-prod
  labels:
    app: moodle
  annotations:
    traefik.ingress.kubernetes.io/service.serversscheme: http
spec:
  type: ClusterIP
  ports:
  - port: 8080
    targetPort: 8080
    protocol: TCP
    name: http
  selector:
    app: moodle
EOF

kubectl apply -f 30-moodle.yaml

# ==========================================
# 10. CRONJOB
# ==========================================
# FIX v3: moodle-html se monta con readOnly: true en el volumeMount
# del contenedor cron (cron.php no necesita escribir en html/).
# La sección volumes.pvc no lleva readOnly — eso va solo en volumeMount.
# Si cron.php necesitara escribir en html/ (cachés, etc.) se debe
# quitar readOnly del volumeMount, no del PVC.
echo "[*] Desplegando CronJob..."

cat > 31-cronjob.yaml << 'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: moodle-cron
  namespace: moodle-prod
  labels:
    app: moodle-cron
spec:
  schedule: "*/1 * * * *"
  # INSTALACIÓN: CronJob arranca SUSPENDIDO para evitar ejecuciones
  # durante la instalación de Moodle. El script lo activa en Fase 2
  # una vez confirmado que config.php existe y la BD está lista.
  # Sin esto, el cron falla con "Cron is disabled" o "config.php not found"
  # porque Moodle aún no terminó de instalarse.
  suspend: true
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  startingDeadlineSeconds: 60
  jobTemplate:
    spec:
      activeDeadlineSeconds: 300
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          nodeSelector:
            kubernetes.io/hostname: k3s-moodle-master
          initContainers:
          - name: wait-for-db
            image: busybox:1.36
            command:
            - sh
            - -c
            - "until nc -z mariadb 3306 && nc -z redis 6379; do sleep 5; done"
          containers:
          - name: cron
            image: localhost:5000/moodle-apache:5.1-k3s-raid
            # FIX v4: Always → pull desde registry local, no desde Docker Hub
            imagePullPolicy: Always
            command:
            - /bin/bash
            - -c
            - |
              # Moodle 5.1: config.php vive en public/
              # cron.php hace require('../../config.php') desde admin/cli/
              # subiendo 2 niveles llega a /var/www/html/ donde está el symlink
              # El symlink public/config.php → config.php debe existir
              if [ ! -f /var/www/html/config.php ] && [ -f /var/www/html/public/config.php ]; then
                ln -sf /var/www/html/public/config.php /var/www/html/config.php
              fi
              exec /usr/bin/php /var/www/html/admin/cli/cron.php --force
            envFrom:
            - configMapRef:
                name: moodle-config
            - secretRef:
                name: moodle-secrets
            volumeMounts:
            # FIX v3: readOnly: true en el mount del contenedor (no en el PVC).
            # cron.php solo lee código PHP de html/, no necesita escribir aquí.
            - name: moodle-html
              mountPath: /var/www/html
              readOnly: true
            # moodle-data sí necesita escritura: cachés, sesiones, temp files
            - name: moodle-data
              mountPath: /var/www/moodledata
          volumes:
          - name: moodle-html
            persistentVolumeClaim:
              claimName: moodle-html-pvc
              # readOnly NO va aquí — va en volumeMount del contenedor
          - name: moodle-data
            persistentVolumeClaim:
              claimName: moodle-data-pvc
EOF

kubectl apply -f 31-cronjob.yaml

# ==========================================
# 11. HPA (HORIZONTAL POD AUTOSCALER)
# ==========================================
echo "[*] Desplegando HPA..."

cat > 40-hpa.yaml << 'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: moodle-hpa
  namespace: moodle-prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: moodle
  # INSTALACIÓN: HPA arranca con minReplicas: 1 para que no escale
  # automáticamente durante la instalación inicial. El script lo
  # ajusta a 3 en Fase 2, después de confirmar que Moodle instaló.
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 100
        periodSeconds: 60
      - type: Pods
        value: 4
        periodSeconds: 60
      selectPolicy: Max
EOF

kubectl apply -f 40-hpa.yaml

# ==========================================
# 12. PDB (POD DISRUPTION BUDGET)
# ==========================================
echo "[*] Desplegando PDB..."

cat > 41-pdb.yaml << 'EOF'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: moodle-pdb
  namespace: moodle-prod
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: moodle
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: mariadb-pdb
  namespace: moodle-prod
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: mariadb
EOF

kubectl apply -f 41-pdb.yaml

# ==========================================
# 13. INGRESS (TRAEFIK)
# ==========================================
echo "[*] Desplegando Ingress..."

cat > 50-ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: moodle-ingress
  namespace: moodle-prod
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-staging"
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/service.serversscheme: http
    traefik.ingress.kubernetes.io/proxy-read-timeout: "300"
    traefik.ingress.kubernetes.io/proxy-write-timeout: "300"
    traefik.ingress.kubernetes.io/proxy-body-size: "512m"
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - mcc.tesoem.edu.mx
    secretName: mcc-tesoem-tls
  rules:
  - host: mcc.tesoem.edu.mx
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: moodle
            port:
              number: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: moodle-ingress-http
  namespace: moodle-prod
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
    traefik.ingress.kubernetes.io/router.middlewares: moodle-prod-redirect-https@kubernetescrd
spec:
  ingressClassName: traefik
  rules:
  - host: mcc.tesoem.edu.mx
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: moodle
            port:
              number: 8080
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
  namespace: moodle-prod
spec:
  redirectScheme:
    scheme: https
    permanent: true
EOF

kubectl apply -f 50-ingress.yaml

# ==========================================
# 14. FASE 1 — ESPERAR INSTALACIÓN (1 réplica)
# ==========================================
# Se espera que el pod único complete la instalación de Moodle
# y que Apache esté sirviendo correctamente antes de escalar.
# La instalación CLI puede tardar 3-8 minutos dependiendo del hardware.
echo ""
echo "[*] Fase 1: Esperando instalación de Moodle con 1 réplica..."
echo "    Esto puede tardar 3-8 minutos en el primer despliegue."
echo "    Sigue los logs en otra terminal con:"
echo "    kubectl logs -f -l app=moodle -n moodle-prod -c moodle"
echo ""

# Esperar a que el pod único esté Ready (la readiness probe pase)
INSTALL_TIMEOUT=600
ELAPSED=0
INTERVAL=5
echo -n "[*] Esperando pod Ready"
until kubectl get pods -n moodle-prod -l app=moodle       --no-headers 2>/dev/null | grep -q "1/1.*Running"; do
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    echo -n "."
    if [ $ELAPSED -ge $INSTALL_TIMEOUT ]; then
        echo ""
        echo ""
        echo "  ╔══════════════════════════════════════════════════════════════╗"
        echo "  ║  TIMEOUT: El pod no llegó a Ready en ${INSTALL_TIMEOUT}s               ║"
        echo "  ║  Revisa los logs:                                            ║"
        echo "  ║  kubectl logs -l app=moodle -n moodle-prod -c moodle        ║"
        echo "  ╚══════════════════════════════════════════════════════════════╝"
        exit 1
    fi
done
echo " OK"

# Verificar que config.php fue generado por el instalador CLI
MOODLE_POD=$(kubectl get pod -n moodle-prod -l app=moodle -o name | head -1)
if kubectl exec -n moodle-prod ${MOODLE_POD}    -- test -f /var/www/html/config.php 2>/dev/null; then
    echo "[*] ✓ config.php generado — instalación completada"
else
    echo "[*] ✗ config.php NO encontrado — instalación falló"
    echo "    Revisa: kubectl logs ${MOODLE_POD} -n moodle-prod -c moodle"
    exit 1
fi

# Verificar tablas en la BD
TABLE_COUNT=$(kubectl exec -n moodle-prod mariadb-0     -- mariadb -u root -p"\${MARIADB_ROOT_PASSWORD:-@@Ad1v1na#2@@}" moodle     -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='moodle';"     --skip-column-names 2>/dev/null || echo "0")
echo "[*] Tablas creadas en BD: ${TABLE_COUNT}"

if [ "${TABLE_COUNT}" -lt 100 ] 2>/dev/null; then
    echo "[*] ⚠ Pocas tablas detectadas (${TABLE_COUNT}) — verifica la instalación"
fi

# ==========================================
# 15. FASE 2 — ACTIVAR CRONJOB
# ==========================================
# Con la instalación completa y config.php presente:
#   - El CronJob se activa ahora que Moodle está instalado y
#     config.php existe en el PVC compartido
echo ""
echo "[*] Fase 2: Activando CronJob de Moodle..."
kubectl patch cronjob moodle-cron -n moodle-prod     -p '{"spec":{"suspend":false}}'
echo "[*] ✓ CronJob activado — primera ejecución en menos de 1 minuto"

# Pausa para que el primer job de cron arranque y confirme
# que config.php y la BD son accesibles antes de escalar
sleep 15

echo ""
echo "=========================================="
echo "DESPLIEGUE BASICO COMPLETADO"
echo "=========================================="

echo ""
echo "=== PERSISTENT VOLUMES ==="
kubectl get pv | grep -E "mariadb|redis|moodle"

echo ""
echo "=== PERSISTENT VOLUME CLAIMS ==="
kubectl get pvc -n moodle-prod

echo ""
echo "=== PODS ==="
kubectl get pods -n moodle-prod -o wide

echo ""
echo "=== SERVICIOS ==="
kubectl get svc -n moodle-prod

echo ""
echo "=== INGRESS ==="
kubectl get ingress -n moodle-prod

echo ""
echo "=== CERTIFICADO TLS ==="
kubectl get certificate -n moodle-prod 2>/dev/null || echo "Pendiente de emisión (normal, puede tardar 1-5 minutos)"

echo ""
echo "=== HPA ==="
kubectl get hpa -n moodle-prod

echo ""
echo "========================================================="
echo "Próximo paso: Conectar nodos B y Pi"
echo "Paso 1: Preparar los nodos con script 07-join-nodes.sh"
echo "Paso 2: Ejecutar script 08-form-HA-cluster en nodo A para"
echo "        escalar conexion de nodos a Kube-VIP"
echo "========================================================="
echo ""
