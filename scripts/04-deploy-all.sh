#!/bin/bash
# 06-deploy-all.sh - Despliegue completo de Moodle HA en K3s
# Ejecutar como root después de 05-build-image.sh
#

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
    create-default-disk-labeled-nodes: "true"
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
    kubectl label node ${NODE_NAME} tesoem.edu.mx/longhorn-node=true node.longhorn.io/create-default-disk=config --overwrite

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
      if [ $RETRIES -ge 90 ]; then
        echo "  ERROR: el DaemonSet longhorn-manager no apareció en 3min"
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
        -n ${LONGHORN_NAMESPACE} --timeout=1200s 2>/dev/null || true

    # El rollout status confirma el estado final del DaemonSet. Timeout corto
    # porque a este punto las imágenes ya bajaron....
    if ! kubectl rollout status daemonset/longhorn-manager \
         -n ${LONGHORN_NAMESPACE} --timeout=240s; then
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
        -n "${LONGHORN_NAMESPACE}" --timeout=1200s 2>/dev/null; then
    echo "    ✓ Pods CSI listos"
else
    echo "    ⚠ Los pods CSI tardaron más de 20min — revisa 'kubectl get pods -n ${LONGHORN_NAMESPACE}'"
fi

# 2) El driver-deployer es quien registra el csidriver
echo "    → Esperando longhorn-driver-deployer..."
kubectl rollout status deployment/longhorn-driver-deployer \
    -n "${LONGHORN_NAMESPACE}" --timeout=900s 2>/dev/null || true

# 3) Confirmación final del csidriver (a estas alturas ya debe existir casi al instante)
echo "    → Verificando registro del CSI driver..."
RETRIES=0
until kubectl get csidriver driver.longhorn.io >/dev/null 2>&1; do
    sleep 5
    RETRIES=$((RETRIES+1))
    [ $RETRIES -ge 72 ] && { echo "  ERROR: CSI driver no se registró tras esperar componentes"; exit 1; }
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
mkdir -p ${RAID_BASE}/galera
mkdir -p ${RAID_BASE}/redis
mkdir -p ${RAID_BASE}/longhorn

# Permisos por servicio — cada imagen corre con un uid distinto:
#   uid 999  → mariadb:lts      (usuario interno: mysql) [Debian - auto-inicializa]
#   uid 999  → redis:7-alpine   (usuario interno: redis)
# ── CAMBIO LONGHORN: moodle-html y moodle-data ya no se chmodean aquí ─────────
# Sus permisos los resuelve el pod de Moodle vía securityContext.fsGroup: 1001
# sobre el volumen que Longhorn monta. El chown/chmod del host ya no aplica
# porque el volumen ya no es un directorio del RAID local.

chmod -R 750      ${RAID_BASE}/galera

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

# Local-raid solo guardado por si acaso
# ── StorageClass 1: local-raid (Redis) ───────────────
#apiVersion: storage.k8s.io/v1
#kind: StorageClass
#metadata:
#  name: local-raid
#  annotations:
#    storageclass.kubernetes.io/is-default-class: "false"
#provisioner: kubernetes.io/no-provisioner
#volumeBindingMode: Immediate
#reclaimPolicy: Retain

echo "[*] Creando StorageClass..."

cat > 01-storageclass.yaml << 'EOF'
# ── StorageClass 2: local-galera (MariaDB + Galera) ───────────────
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-galera
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer   # ← la diferencia con local-raid
reclaimPolicy: Retain
---
# ── StorageClass 3: longhorn-moodle (moodle-html + moodle-data) ──────────────
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
  name: mariadb-galera-pv-a
spec:
  capacity: { storage: 20Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-galera
  volumeMode: Filesystem
  local:
    path: /moodlek3s/galera          # ← ruta nueva, dedicada
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values: [k3s-moodle-master]    # nodo A
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: mariadb-galera-pv-b
spec:
  capacity: { storage: 20Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-galera
  volumeMode: Filesystem
  local:
    path: /moodlek3s/galera
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values: [node-b-k3s-moodle]    # nodo B
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
for PVC in moodle-html-pvc moodle-data-pvc; do
  echo -n "    Esperando $PVC..."
  RETRIES=0
  until kubectl get pvc "$PVC" -n moodle-prod -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Bound"; do
    sleep 10
    RETRIES=$((RETRIES+1))
    if [ $RETRIES -ge 240 ]; then
      echo " ERROR: $PVC no llegó a Bound en 12min"
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
  MARIADB_HOST: "maxscale"
  MARIADB_PORT: "3306"
  MARIADB_DATABASE: "moodle"
  MARIADB_USER: "moodleTESOEM"
  MARIADB_CHARACTER_SET: "utf8mb4"
  MARIADB_COLLATE: "utf8mb4_unicode_ci"

  # Moodle DB
  MOODLE_DB_HOST: "maxscale"
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
  DB_HOST: "maxscale"
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
  mariadb-root-password: "@@Ad1v1na#2@@"
  mariadb-password: "@@Ad1v1na#2@@"
  mariadb-galera-mariabackup-password: "Ad1v1naGalera"
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
# 7. MARIADB GALERA (vía Helm)
# ==========================================
# Reemplaza la MariaDB plana por un clúster Galera (camino A).
# Arranca en 1 nodo; el 09 escala a 2 + garbd. Usa los PVs locales
# (local-galera) y el Secret mariadb-secrets ya aplicados arriba.
echo "[*] Desplegando MariaDB Galera vía Helm..."

# Helm: instalar si no está presente
if ! command -v helm >/dev/null 2>&1; then
  echo "[*] Helm no encontrado — instalando..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

cat > galera-values.yaml << 'EOF'
fullnameOverride: mariadb          # Service y pods quedan 'mariadb' → Moodle no cambia su host

# Imagen: el chart apunta por defecto a docker.io/bitnami/mariadb-galera, que
# desde el 28-ago-2025 dejó de estar en el tier gratis (se movió a bitnamilegacy).
# Apuntamos al repositorio legacy y habilitamos allowInsecureImages para que el
# chart acepte un repositorio que no es el oficial. (Stopgap: legacy no recibe
# parches; a futuro conviene mirror propio o Bitnami Secure Images.)
global:
  security:
    allowInsecureImages: true

image:
  repository: bitnamilegacy/mariadb-galera

existingSecret: mariadb-secrets

galera:
  name: moodle-galera
  mariabackup:
    user: mariabackup

db:
  name: moodle
  user: moodleTESOEM

replicaCount: 1                    # el 09 hace helm upgrade a 2

extraFlags: >-
  --character-set-server=utf8mb4
  --collation-server=utf8mb4_unicode_ci
  --skip-character-set-client-handshake
  --innodb_file_per_table=1
  --innodb_log_file_size=256M
  --max_connections=200

persistence:
  enabled: true
  storageClass: local-galera
  size: 20Gi
  accessModes:
    - ReadWriteOnce

podAntiAffinityPreset: hard
nodeSelector:
  tesoem.edu.mx/longhorn-node: "true"
EOF

helm upgrade --install mariadb oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
  --version 16.0.1 \
  --namespace moodle-prod \
  -f galera-values.yaml

echo "[*] Esperando que Galera quede listo (hasta 20min)..."
kubectl rollout status statefulset/mariadb -n moodle-prod --timeout=1200s

# ==========================================
# 7.5 MAXSCALE — CAPA DE ACCESO A DATOS
# ==========================================
# Se despliega DESPUÉS de que Galera está Ready y ANTES de Moodle,
# para que config.php nazca apuntando al endpoint definitivo (maxscale)
# y nunca haya reconfiguración de la aplicación.
#
# La topología completa (mariadb-0 y mariadb-1) se declara desde el día uno
# aunque mariadb-1 aún no exista: galeramon lo marcará Down y lo promoverá
# solo cuando el 07 escale Galera. Esta primera corrida ES la prueba de que
# MaxScale tolera un hostname irresoluble al arranque.
echo "[*] Desplegando MaxScale (capa de acceso a datos)..."

MAXSCALE_IMAGE="mariadb/maxscale:24.02"   # LTS; fija el patch exacto tras validar (ver nota)
MAXSCALE_USER="maxscale"
MAXSCALE_PASSWORD="@@Ad1v1na#2@@"         # mismo esquema de credenciales del proyecto

# ── 7.5.1 Usuario de MaxScale en Galera ──────────────────────────────────────
# DOS capas de permisos en el mismo usuario:
#   - REPLICA MONITOR → galeramon lee el estado de replicación/wsrep
#   - SELECT itemizado sobre mysql.* → readwritesplit construye su caché de
#     autenticación de usuarios (sin esto: "Authentication failed" a los clientes)
# Idempotente: IF NOT EXISTS + ALTER para fijar el password en re-ejecuciones.
echo "[*] Creando usuario '${MAXSCALE_USER}'@'%' en Galera..."

MARIADB_ROOT_PW=$(kubectl get secret mariadb-secrets -n moodle-prod \
  -o jsonpath='{.data.mariadb-root-password}' | base64 -d)

kubectl exec -i mariadb-0 -n moodle-prod -- \
  mariadb -u root -p"${MARIADB_ROOT_PW}" <<SQL
CREATE USER IF NOT EXISTS '${MAXSCALE_USER}'@'%' IDENTIFIED BY '${MAXSCALE_PASSWORD}';
ALTER USER '${MAXSCALE_USER}'@'%' IDENTIFIED BY '${MAXSCALE_PASSWORD}';
GRANT REPLICA MONITOR ON *.* TO '${MAXSCALE_USER}'@'%';
GRANT SHOW DATABASES ON *.* TO '${MAXSCALE_USER}'@'%';
GRANT SELECT ON mysql.user          TO '${MAXSCALE_USER}'@'%';
GRANT SELECT ON mysql.db            TO '${MAXSCALE_USER}'@'%';
GRANT SELECT ON mysql.tables_priv   TO '${MAXSCALE_USER}'@'%';
GRANT SELECT ON mysql.columns_priv  TO '${MAXSCALE_USER}'@'%';
GRANT SELECT ON mysql.procs_priv    TO '${MAXSCALE_USER}'@'%';
GRANT SELECT ON mysql.proxies_priv  TO '${MAXSCALE_USER}'@'%';
GRANT SELECT ON mysql.roles_mapping TO '${MAXSCALE_USER}'@'%';
FLUSH PRIVILEGES;
SQL

echo "[*] ✓ Usuario maxscale creado con grants de monitor + auth-cache."

# ── 7.5.2 Configuración de MaxScale (Secret, no ConfigMap) ───────────────────
# Va en Secret porque el .cnf contiene el password del monitor.
# NOTA heredoc SIN comillas: expande ${MAXSCALE_USER}/${MAXSCALE_PASSWORD}.
# Decisiones anotadas:
#   - disable_master_failback=true → cuando el master original se recupera,
#     NO se fuerza un switch de vuelta; se evita un evento de reconexión extra.
#   - available_when_donor=true → con solo 2 nodos de datos, durante un SST el
#     donante es el único nodo útil; mariabackup (el método del chart) no
#     bloquea al donante, así que es seguro seguir sirviendo desde él.
#   - master_reconnection=true → las sesiones sobreviven un cambio de master
#     reconectándose en lugar de cerrarse.
#   - log_info=true → verboso a propósito para la primera corrida: aquí se ve
#     exactamente cómo reporta el DNS irresoluble de mariadb-1. Bajar a false
#     cuando el comportamiento esté validado.
cat > 25-maxscale-config.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: maxscale-config
  namespace: moodle-prod
type: Opaque
stringData:
  maxscale.cnf: |
    [maxscale]
    threads=auto
    log_info=true

    [mariadb-0]
    type=server
    address=mariadb-0.mariadb-headless.moodle-prod.svc.cluster.local
    port=3306

    [mariadb-1]
    type=server
    address=mariadb-1.mariadb-headless.moodle-prod.svc.cluster.local
    port=3306

    [Galera-Monitor]
    type=monitor
    module=galeramon
    servers=mariadb-0,mariadb-1
    user=${MAXSCALE_USER}
    password=${MAXSCALE_PASSWORD}
    monitor_interval=2s
    disable_master_failback=true
    available_when_donor=true

    [RW-Service]
    type=service
    router=readwritesplit
    servers=mariadb-0,mariadb-1
    user=${MAXSCALE_USER}
    password=${MAXSCALE_PASSWORD}
    master_reconnection=true

    [RW-Listener]
    type=listener
    service=RW-Service
    protocol=MariaDBClient
    address=0.0.0.0
    port=3306
EOF

kubectl apply -f 25-maxscale-config.yaml

# ── 7.5.3 Deployment + Service ───────────────────────────────────────────────
# replicas: 1 en el 04 (todo el sistema es single-node en este punto).
# El 07 solo cambia replicas 1 → 2; por eso la anti-affinity YA está escrita
# (con 1 réplica se satisface trivialmente) y la nodeAffinity por arquitectura
# excluye la Pi de forma declarativa: expresa el POR QUÉ (arm64 sin imagen),
# no solo el dónde.
cat > 26-maxscale.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: maxscale
  namespace: moodle-prod
  labels:
    app: maxscale
    tier: data-access
spec:
  replicas: 1
  selector:
    matchLabels:
      app: maxscale
  template:
    metadata:
      labels:
        app: maxscale
        tier: data-access
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/arch
                    operator: In
                    values: ["amd64"]
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: maxscale
              topologyKey: kubernetes.io/hostname
      containers:
        - name: maxscale
          image: ${MAXSCALE_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 3306
              name: mariadb
            - containerPort: 8989
              name: admin
          volumeMounts:
            - name: config
              mountPath: /etc/maxscale.cnf
              subPath: maxscale.cnf
              readOnly: true
          readinessProbe:
            tcpSocket:
              port: 3306
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            tcpSocket:
              port: 3306
            initialDelaySeconds: 15
            periodSeconds: 10
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
      volumes:
        - name: config
          secret:
            secretName: maxscale-config
            defaultMode: 0444
---
apiVersion: v1
kind: Service
metadata:
  name: maxscale
  namespace: moodle-prod
  labels:
    app: maxscale
spec:
  type: ClusterIP
  selector:
    app: maxscale
  ports:
    - name: mariadb
      port: 3306
      targetPort: 3306
EOF

kubectl apply -f 26-maxscale.yaml

# ── 7.5.4 Verificación fuerte: esperar Master en galeramon ───────────────────
# Equivalente al patrón get_cluster_size: la readiness probe TCP solo dice que
# el listener abrió; ESTO confirma que galeramon ve a mariadb-0 como
# "Master, Synced, Running" antes de dejar pasar a Moodle.
echo -n "[*] Esperando que MaxScale marque mariadb-0 como Master"
MAXSCALE_TIMEOUT=360
ELAPSED=0
until kubectl exec deploy/maxscale -n moodle-prod -- \
        maxctrl list servers --tsv 2>/dev/null \
        | awk -F'\t' '$1=="mariadb-0"' | grep -q "Master"; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo -n "."
    if [ $ELAPSED -ge $MAXSCALE_TIMEOUT ]; then
        echo ""
        echo "  ╔══════════════════════════════════════════════════════════════╗"
        echo "  ║  TIMEOUT: MaxScale no marcó mariadb-0 como Master             ║"
        echo "  ║  Revisa: kubectl logs deploy/maxscale -n moodle-prod          ║"
        echo "  ║  Y:      kubectl exec deploy/maxscale -n moodle-prod --       ║"
        echo "  ║              maxctrl list servers                             ║"
        echo "  ╚══════════════════════════════════════════════════════════════╝"
        exit 1
    fi
done
echo " OK"

echo "[*] Estado de servidores según MaxScale:"
kubectl exec deploy/maxscale -n moodle-prod -- maxctrl list servers || true

# mariadb-1 debe aparecer Down (aún no existe) SIN impedir que mariadb-0 sea
# Master ni que el servicio arranque. Ese es el veredicto de la arquitectura:
# si MaxScale llegó aquí, tolera la topología declarada por adelantado.
echo "[*] ✓ MaxScale operativo — mariadb-1 en Down es lo ESPERADO hasta el 07."

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
kind: DaemonSet
metadata:
  name: redis
  namespace: moodle-prod
  labels:
    app: redis
    tier: cache
spec:
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
        tier: cache
    spec:
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
        emptyDir: {}
      tolerations:
      - operator: Exists
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
  internalTrafficPolicy: Local
  ports:
  - port: 6379
    targetPort: 6379
    protocol: TCP
    name: redis
  selector:
    app: redis
EOF

kubectl apply -f 21-redis.yaml

echo "[*] Esperando Redis Deamonset (hasta 4min)..."
kubectl rollout status daemonset/redis -n moodle-prod --timeout=240s

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
          failureThreshold: 420
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
INSTALL_TIMEOUT=4500
ELAPSED=0
INTERVAL=10
echo -n "[*] Esperando pod Ready"
until kubectl get pods -n moodle-prod -l app=moodle --no-headers 2>/dev/null | grep -q "1/1.*Running"; do
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
echo "=== GALERA STORAGE CLASS ==="
kubectl get storageclass local-galera

echo ""
echo "=== GALERA PVs ==="
kubectl get pv mariadb-galera-pv-a mariadb-galera-pv-b

echo ""
echo "=== GALERA PVCs ==="
kubectl get pvc -n moodle-prod
echo ""
kubectl get pvc data-mariadb-0 -n moodle-prod -o jsonpath='{.spec.volumeName}'; echo
echo ""
echo "Donde estan los pods de galera"
kubectl get pods -n moodle-prod -l app.kubernetes.io/instance=mariadb -o wide

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
echo "=== CLUSTER TOKEN ==="
cat /var/lib/rancher/k3s/server/node-token

echo ""
echo "========================================================="
echo "Próximo paso: Conectar nodos B y Pi"
echo "Paso 1: Preparar los nodos con script 05-join-nodes.sh"
echo "Paso 2: Ejecutar script 06-form-HA-cluster en nodo A para"
echo "        escalar conexion de nodos a Kube-VIP"
echo "========================================================="
echo ""
