#!/bin/bash
set -e
RAID_MOUNT="/moodledata"
NODE_NAME="k3s-moodle-master"
mkdir -p $RAID_MOUNT/{k3s-volumes,backups,logs}
mkdir -p $RAID_MOUNT/k3s-volumes/{moodle-html,moodle-data,mariadb,redis}
chown -R 1001:33 $RAID_MOUNT/k3s-volumes/moodle-html
chown -R 1001:33 $RAID_MOUNT/k3s-volumes/moodle-data
chown -R 999:999 $RAID_MOUNT/k3s-volumes/mariadb
chown -R 999:999 $RAID_MOUNT/k3s-volumes/redis
chmod 755 $RAID_MOUNT
chmod 2775 $RAID_MOUNT/k3s-volumes/moodle-html
chmod 2777 $RAID_MOUNT/k3s-volumes/moodle-data
chmod 750 $RAID_MOUNT/k3s-volumes/mariadb
chmod 750 $RAID_MOUNT/k3s-volumes/redis
chcon -Rt container_file_t $RAID_MOUNT 2>/dev/null || true
kubectl label node $NODE_NAME storage-type=raid-local --overwrite 2>/dev/null || true
(crontab -l 2>/dev/null; echo "0 2 * * * /root/k3s-moodle/scripts/09-backup.sh >> /moodledata/logs/backup.log 2>&1") | crontab -
echo "RAID preparado."
