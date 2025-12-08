#!/bin/bash
set -e # 遇到错误立即退出

# ================= 0. 基础变量配置 =================
EXP_NAME="cephmango"
DOMAIN="${EXP_NAME}.isu-cloud.emulab.net"
NET_IFACE="eno4"   # ⚠️ 请确认这是您的真实网卡名称
CEPH_VER="quincy"
REPO_TAG="stable-7.0"

echo ">>> [1/11] 环境检查: 测试外网连接..."
if ping -c 2 galaxy.ansible.com > /dev/null 2>&1; then
    echo "Network OK."
else
    echo "警告: 无法连接到 galaxy.ansible.com，Galaxy 依赖安装可能会失败。"
fi

echo ">>> [2/11] 安装系统基础依赖..."
sudo apt update
sudo apt install -y python3 python3-pip git ansible
ansible --version

echo ">>> [3/11] 下载 Ceph-Ansible 代码库..."
if [ ! -d "ceph-ansible" ]; then
    git clone https://github.com/ceph/ceph-ansible.git
fi
cd ceph-ansible
git checkout $REPO_TAG

echo ">>> [4/11] 安装 Python 依赖和 Ansible Collections..."
pip3 install -r requirements.txt
# 忽略 Galaxy 错误以防网络问题中断
ansible-galaxy install -r requirements.yml || echo "警告: Galaxy 安装遇到问题，尝试继续..."
ansible-galaxy collection install ansible.posix
ansible-galaxy collection install community.general

echo ">>> [5/11] 初始化配置目录..."
mkdir -p inventory host_vars group_vars
cp site.yml.sample site.yml
cp group_vars/all.yml.sample group_vars/all.yml
cp group_vars/mons.yml.sample group_vars/mons.yml
cp group_vars/osds.yml.sample group_vars/osds.yml
cp group_vars/mgrs.yml.sample group_vars/mgrs.yml
cp group_vars/clients.yml.sample group_vars/clients.yml

echo ">>> [6/11] 生成 Inventory 文件 (12节点/10 OSD)..."
cat > inventory/hosts <<EOF
[mons]
node1.${DOMAIN} ansible_host=10.10.1.2

[mgrs]
node1.${DOMAIN} ansible_host=10.10.1.2

[osds]
EOF

# 自动生成 10 个 OSD 节点 (node2 - node11)
for i in {2..11}; do
    echo "node${i}.${DOMAIN} ansible_host=10.10.1.$((i+1))" >> inventory/hosts
done

cat >> inventory/hosts <<EOF

[clients]
# Node0 既是 Admin 也是 Client，使用 local 连接避免 SSH 问题
node0.${DOMAIN} ansible_host=10.10.1.1 ansible_connection=local

[monitoring]
node1.${DOMAIN} ansible_host=10.10.1.2

[ceph:children]
mons
osds
mgrs
clients
monitoring

[ceph:vars]
ansible_user=root
ansible_ssh_private_key_file=~/.ssh/id_rsa
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF

## ======================== 7/11: 修改 all.yml 添加 EC 配置 ========================

echo ">>> [7/11] 配置全局变量 (all.yml) 并添加 RS(6,4) 纠删码配置..."
cat > group_vars/all.yml <<EOF
---
ceph_origin: repository
ceph_repository: community
ceph_stable_release: ${CEPH_VER}
public_network: "10.10.1.0/24"
cluster_network: "10.10.1.0/24"
monitor_address_block: "10.10.1.0/24"
monitor_interface: ${NET_IFACE}
radosgw_interface: ${NET_IFACE}
fsid: "{{ ansible_date_time.epoch | to_uuid }}"
cephx: true
containerized_deployment: false
dashboard_enabled: true
dashboard_admin_user: admin
dashboard_admin_password: password
grafana_admin_user: admin
grafana_admin_password: admin
monitoring_stack_enabled: false
ansible_ssh_user: root
ansible_become: true
gather_facts: true

# 【关键修复】禁用 Handler 健康检查，防止首次部署时因 OSD 不足而死锁
handler_health_check: false

# 【关键修复】全局开启 Autoscaler
ceph_conf_overrides:
  global:
    osd_pool_default_pg_autoscale_mode: on

# ----------------------------------------------------
# 【新增】RS(K=6, M=4) 纠删码配置
# ----------------------------------------------------
ceph_crush_rules:
  # 定义一个名为 'ec_rule' 的 CRUSH 规则
  - rule_name: "ec_rule"
    type: "erasure"
    # 引用自定义的 profile
    profile: "rs_6_4_profile"

ceph_ec_profiles:
  # 定义一个名为 'rs_6_4_profile' 的 EC Profile
  - name: "rs_6_4_profile"
    # 使用 jerasure 插件
    plugin: "jerasure"
    # 数据块 K=6
    k: 6
    # 编码块 M=4
    m: 4
    # 失败域：osd（适用于您每个节点只有一个 OSD 的情况）
    crush_failure_domain: osd
EOF

echo ">>> [8/11] 配置角色变量 (mons, osds, mgrs)..."

# Mons 配置
cat > group_vars/mons.yml <<EOF
---
monitor_address_block: "10.10.1.0/24"
monitor_address: "{{ ansible_host }}"
ms_bind_msgr2: true
EOF

# OSDs 配置 (使用 /dev/sdb)
cat > group_vars/osds.yml <<EOF
---
osd_auto_discovery: false
osd_scenario: lvm
osd_objectstore: bluestore
devices:
  - /dev/sdb
ceph_osd_docker_memory_limit: 4294967296
EOF

# Mgrs 配置
cat > group_vars/mgrs.yml <<EOF
---
ceph_mgr_modules:
  - dashboard
  - prometheus
  - iostat
  - restful
ceph_mgr_dashboard_port: 8443
ceph_mgr_dashboard_server_addr: "0.0.0.0"
EOF

## ======================== 9/11: 修改 clients.yml 添加 EC 存储池 ========================

echo ">>> [9/11] 配置 Clients (clients.yml) 并创建 rbd-ec 纠删码存储池..."
cat > group_vars/clients.yml <<EOF
---
# 【关键修复】强制将 admin 密钥复制到 Client 节点 (Node0)
copy_admin_key: true

user_config: true
ceph_pools:
  # ----------------------------------------------------
  # 【新增】EC 存储池 RBD-EC (k=6, m=4)
  # ----------------------------------------------------
  - name: "rbd-ec"
    pg_num: 128            # EC Pool 推荐使用较大的 PG 数
    pg_autoscale_mode: on
    rule_name: "ec_rule"   # ⚠️ 使用自定义的 EC Rule
    type: 3                # ⚠️ type: 3 表示纠删码 (Erasure Code)
    application: "rbd"
    # size 字段在 EC 中表示 k+m，即总块数 (6+4=10)
    size: 10
    # min_size 推荐设置为 k，即必须存活的最小块数 (6)
    min_size: 6
  # ----------------------------------------------------
  # 默认的三副本存储池，可保留或注释掉
  # ----------------------------------------------------
  - name: "rbd"
    pg_num: 32
    pg_autoscale_mode: on
    rule_name: "replicated_rule"
    type: 1
    application: "rbd"
    size: 3
    min_size: 1
  - name: "cephfs_data"
    pg_num: 32
    pg_autoscale_mode: on
    rule_name: "replicated_rule"
    type: 1
    application: "cephfs"
    size: 3
    min_size: 1
  - name: "cephfs_metadata"
    pg_num: 16
    pg_autoscale_mode: on
    rule_name: "replicated_rule"
    type: 1
    application: "cephfs"
    size: 3
    min_size: 1

cephfs_data_pool:
  name: cephfs_data
cephfs_metadata_pool:
  name: cephfs_metadata
ceph_fs: cephfs
EOF

echo ">>> [10/11] 最终预检 (Ping & Disk)..."
# 检查连通性
ansible -i inventory/hosts all -m ping
# 检查 OSD 磁盘是否存在
ansible -i inventory/hosts osds -a "lsblk /dev/sdb"

echo ">>> [11/11] 开始部署..."
echo ">>> 即将运行 Playbook，已添加防止死锁参数..."
sleep 3

# 【关键修复】再次添加 -e "handler_health_check=false" 双重保险
ansible-playbook -i inventory/hosts site.yml -v -e "handler_health_check=false"

echo "=============================================="
echo ">>> 部署结束！"
echo ">>> 正在自动验证集群状态..."
sudo ceph -s
sudo ceph osd tree
echo "=============================================="
