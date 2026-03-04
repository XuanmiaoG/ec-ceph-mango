#!/bin/bash
set -e

# ================= 0. 基础变量配置 =================
EXP_NAME="cephmango"
DOMAIN="${EXP_NAME}.isu-cloud.emulab.net"
BOOTSTRAP_IP="10.10.1.1"

echo "=================================================="
echo "   Ceph 自动部署脚本 (Target: OSD on Node 2-13)"
echo "=================================================="

echo ">>> [1/8] 环境准备 (Node0 清理与依赖)..."
# 1. 本机安装依赖
sudo apt-get update -qq && sudo apt-get install -y -qq docker.io cephadm ceph-common psmisc

# 2. 深度清理
echo "正在执行深度清理..."
sudo docker ps -a | grep ceph | awk '{print $1}' | xargs -r sudo docker rm -f || true
sudo fuser -k 3300/tcp 6789/tcp 8443/tcp 9283/tcp 8765/tcp || true
sudo killall -9 ceph-mon ceph-mgr ceph-osd 2>/dev/null || true
sudo rm -rf /etc/ceph/* /var/lib/ceph/* /var/log/ceph/*
# 清理以前的公钥防止冲突
rm -f ~/cephadm.pub

echo ">>> [2/8] 执行 Bootstrap (引导首个节点)..."
sudo cephadm bootstrap \
    --mon-ip $BOOTSTRAP_IP \
    --initial-dashboard-password password \
    --dashboard-password-noupdate \
    --allow-fqdn-hostname \
    --allow-overwrite

echo ">>> [3/8] 分发 Cephadm 专用密钥..."
sudo cat /etc/ceph/ceph.pub > ~/cephadm.pub
# 遍历 Node 1 到 13
for i in {1..13}; do
    node="node${i}.${DOMAIN}"
    echo " -> 分发密钥至 $node"
    # 使用 StrictHostKeyChecking=no 避免第一次连接的 yes/no 询问
    ssh-copy-id -f -i ~/cephadm.pub -o StrictHostKeyChecking=no root@$node > /dev/null 2>&1
done

echo ">>> [4/8] 远程安装依赖 (Docker, Python3, LVM2)..."
for i in {1..13}; do
    node="node${i}.${DOMAIN}"
    echo " -> [串行安装] 正在处理 $node ..."
    
    # 逻辑解释：
    # 1. -o Acquire::ForceIPv4=true : 强制使用 IPv4，解决 Network unreachable 问题
    # 2. 去掉了 '&' : 串行执行，防止拥堵
    # 3. || : 如果失败尝试第二次
    ssh root@$node "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -o Acquire::ForceIPv4=true -qq || apt-get update -o Acquire::ForceIPv4=true -qq
        apt-get install -y -qq -o Acquire::ForceIPv4=true docker.io python3 lvm2
        systemctl enable --now docker
    "
done
echo "所有节点依赖安装完成。"

echo ">>> [5/8] 添加主机并打标签 (OSD 仅限 Node 2-13)..."
for i in {1..13}; do
    node="node${i}.${DOMAIN}"
    node_ip="10.10.1.$((i+1))" # Node1=1.2, Node2=1.3 ...
    
    echo "正在添加节点: $node ($node_ip)"
    sudo cephadm shell -- ceph orch host add $node $node_ip
    
    # 【关键逻辑】只给 Node 2 到 13 打上存储标签
    if [ $i -ge 2 ]; then
        echo "   -> 标记 $node 为存储节点 (osd-node)"
        sudo cephadm shell -- ceph orch host label add $node osd-node
    else
        echo "   -> 标记 $node 为管理节点 (_admin)"
        sudo cephadm shell -- ceph orch host label add $node _admin
    fi
done

# 确保 Node0 也有 admin 标签
sudo cephadm shell -- ceph orch host label add node0.${DOMAIN} _admin

sleep 60

echo ">>> [6/8] 部署控制平面 (Mon, Mgr, MDS)..."
# 维持原定策略：控制节点放在 Node 2,3,4 (即使它们也是OSD节点，这在小规模集群很常见)
sudo cephadm shell -- ceph orch apply mon --placement="3 node2.${DOMAIN} node3.${DOMAIN} node4.${DOMAIN}"
sudo cephadm shell -- ceph orch apply mgr --placement="1 node2.${DOMAIN}"
sudo cephadm shell -- ceph orch apply mds cephfs --placement="1 node2.${DOMAIN}"

sleep 10

echo ">>> [7/8] 部署 OSD (Target: 24 OSDs on Node 2-13)..."

# 1. 生成 OSD 部署规范文件 (YAML)
# 这告诉 Ceph: 在所有带 'osd-node' 标签的主机上，使用所有可用硬盘
cat <<EOF > osd_spec.yaml
service_type: osd
service_id: all_osds
placement:
  label: "osd-node"
spec:
  data_devices:
    all: true
EOF

echo " -> 正在应用 OSD 规范..."
# 2. 将 YAML 文件内容通过管道传给 cephadm shell 进行应用
cat osd_spec.yaml | sudo cephadm shell -- ceph orch apply -i -

echo " -> OSD 规范已提交，后台将开始创建 OSD。"
rm osd_spec.yaml

echo ">>> [8/8] 后续配置 (Pool & Application)..."
echo "等待 OSD 初始化 (休眠 60秒)..."
sleep 60

sudo cephadm shell -- ceph osd pool create rbd_data 32 32 replicated
sudo cephadm shell -- ceph osd pool application enable rbd_data rbd

echo "=============================================="
echo ">>> 部署完成！"
echo ">>> 验证 OSD 数量 (应为 24):"
echo "    sudo cephadm shell -- ceph osd stat"
echo ">>> 查看 OSD 树形图:"
echo "    sudo cephadm shell -- ceph osd tree"
echo "=============================================="