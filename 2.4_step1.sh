#!/bin/bash
set -e

# ================= 0. 基础变量配置 =================
EXP_NAME="cephai"
DOMAIN="${EXP_NAME}.isu-cloud.emulab.net"
BOOTSTRAP_IP="10.10.1.1"

echo ">>> [1/8] 环境准备 (Node0)..."
# 1. 本机安装依赖
sudo apt update && sudo apt install -y docker.io cephadm ceph-common psmisc

# 2. 深度清理 (保留这个好习惯，防止重跑报错)
echo "执行清理..."
sudo docker ps -a | grep ceph | awk '{print $1}' | xargs -r sudo docker rm -f || true
sudo fuser -k 3300/tcp 6789/tcp 8443/tcp 9283/tcp 8765/tcp || true
sudo killall -9 ceph-mon ceph-mgr ceph-osd 2>/dev/null || true
sudo rm -rf /etc/ceph/* /var/lib/ceph/* /var/log/ceph/*

echo ">>> [2/8] 执行 Bootstrap (引导首个节点)..."
sudo cephadm bootstrap \
    --mon-ip $BOOTSTRAP_IP \
    --initial-dashboard-password password \
    --dashboard-password-noupdate \
    --allow-fqdn-hostname \
    --allow-overwrite

echo ">>> [3/8] 分发 Cephadm 专用密钥..."
sudo cat /etc/ceph/ceph.pub > ~/cephadm.pub
for i in {1..13}; do
    node="node${i}.${DOMAIN}"
    # 分发密钥
    ssh-copy-id -f -i ~/cephadm.pub -o StrictHostKeyChecking=no root@$node
done

# 【关键修复步骤】
echo ">>> [4/8] 正在远程给所有节点安装 Docker..."
for i in {1..13}; do
    node="node${i}.${DOMAIN}"
    echo "正在为 $node 安装 Docker 和依赖..."
    # 远程执行安装命令：安装 docker, python3, lvm2 (OSD需要)
    ssh root@$node "apt-get update -qq && apt-get install -y -qq docker.io python3 lvm2 && systemctl enable --now docker"
done

echo ">>> [5/8] 添加主机到集群..."
for i in {1..13}; do
    node="node${i}.${DOMAIN}"
    node_ip="10.10.1.$((i+1))"
    echo "正在添加节点: $node ($node_ip)"
    sudo cephadm shell -- ceph orch host add $node $node_ip
done

echo ">>> [6/8] 部署控制平面 (Mon, Mgr, MDS)..."
sudo cephadm shell -- ceph orch apply mon --placement="3 node2.${DOMAIN} node3.${DOMAIN} node4.${DOMAIN}"
sudo cephadm shell -- ceph orch apply mgr --placement="1 node2.${DOMAIN}"
sudo cephadm shell -- ceph orch apply mds cephfs --placement="1 node2.${DOMAIN}"

echo ">>> [7/8] 部署 12 个 OSD..."
sudo cephadm shell -- ceph orch apply osd --all-available-devices

echo ">>> [8/8] 创建存储池 & 设置标签..."
echo "等待 OSD 就绪..."
sleep 30
sudo cephadm shell -- ceph osd pool create rbd_data 32 32 replicated
sudo cephadm shell -- ceph osd pool application enable rbd_data rbd
sudo cephadm shell -- ceph orch host label add node0.${DOMAIN} _admin
sudo cephadm shell -- ceph orch host label add node1.${DOMAIN} _admin

echo "=============================================="
echo ">>> 部署成功！"
echo ">>> 检查状态: sudo cephadm shell -- ceph -s"
echo "=============================================="