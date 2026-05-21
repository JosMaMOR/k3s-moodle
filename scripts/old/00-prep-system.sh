#!/bin/bash
set -e
echo "Preparando AlmaLinux 9.7..."
dnf update -y
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
systemctl stop firewalld && systemctl disable firewalld
dnf install -y curl wget vim net-tools bind-utils bash-completion iscsi-initiator-utils nfs-utils cryptsetup device-mapper util-linux jq ipset ipvsadm mdadm smartmontools hdparm tree
systemctl enable --now iscsid
cat > /etc/modules-load.d/k3s.conf << 'EOF'
overlay
br_netfilter
raid1
EOF
modprobe overlay br_netfilter raid1
cat > /etc/sysctl.d/99-k3s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
fs.file-max = 2097152
vm.max_map_count = 262144
EOF
sysctl --system
swapoff -a && sed -i '/swap/d' /etc/fstab
hostnamectl set-hostname k3s-moodle-master
cat >> /etc/hosts << 'EOF'
127.0.0.1 k3s-moodle-master
127.0.0.1 mcc.tesoem.edu.mx
EOF
mkdir -p /root/k3s-moodle/{manifests,scripts,storage,backup}
echo "Preparación completada. Reiniciar si es necesario."
