#!/bin/bash
set -e
cd /root/k3s-moodle/manifests
cat > 00-storageclass.yaml << 'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-raid
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF
kubectl apply -f 00-storageclass.yaml
for name in moodle-html moodle-data mariadb redis; do
  size=50Gi && mode=ReadWriteMany
  [ "$name" = "moodle-data" ] && size=800Gi
  [ "$name" = "mariadb" ] && size=30Gi && mode=ReadWriteOnce
  [ "$name" = "redis" ] && size=10Gi && mode=ReadWriteOnce
  path="/moodledata/k3s-volumes/$name"
  [ "$name" = "moodle-html" ] && path="/moodledata/k3s-volumes/moodle-html"
  [ "$name" = "moodle-data" ] && path="/moodledata/k3s-volumes/moodle-data"
  [ "$name" = "mariadb" ] && path="/moodledata/k3s-volumes/mariadb"
  [ "$name" = "redis" ] && path="/moodledata/k3s-volumes/redis"
  
  cat > 01-pv-$name.yaml << EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $name-pv
spec:
  capacity:
    storage: $size
  accessModes:
    - $mode
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-raid
  local:
    path: $path
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k3s-moodle-master
EOF
  cat > 02-pvc-$name.yaml << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $name-pvc
  namespace: moodle-prod
spec:
  accessModes:
    - $mode
  storageClassName: local-raid
  resources:
    requests:
      storage: $size
  volumeName: $name-pv
EOF
done
kubectl create namespace moodle-prod --dry-run=client -o yaml | kubectl apply -f -
for f in 01-pv-*.yaml 02-pvc-*.yaml; do kubectl apply -f $f; done
sleep 5
kubectl get pv
kubectl get pvc -n moodle-prod
echo "Storage configurado."
