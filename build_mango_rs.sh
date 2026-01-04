#!/bin/bash
set -e

# ====================================================
# 用法:
#   sudo ./setup.sh server   # Node0: Ceph + MongoDB
#   sudo ./setup.sh client   # Node1: YCSB
# ====================================================

MODE=$1

# ================= 基础配置 =================
# EC data pool
EC_POOL_NAME="rbd-ec-53"

# Replicated metadata pool
REP_POOL_NAME="rbd-rep-3"

IMAGE_NAME="mongo-disk-500g"
IMAGE_SIZE="512000"   # MB (~500GB)
MOUNT_POINT="/var/lib/mongodb"

# EC 参数 (RS 5+3)
EC_PROFILE="ec_5_3_profile"
EC_K=5
EC_M=3

# Replication 参数
REP_SIZE=3
REP_MIN_SIZE=2

# ================= 帮助 =================
usage() {
    echo "用法: sudo ./setup.sh [server|client]"
    exit 1
}

[ -z "$MODE" ] && usage

# ================= Server (Node0) =================
install_server() {
    echo ">>> [Server] Dual-pool RBD (Replicated metadata + EC data)"

    EC_SUCCESS=true

    # ------------------------------------------------
    # [1/6] 创建 EC Pool
    # ------------------------------------------------
    echo ">>> [1/6] 创建 EC Pool (RS ${EC_K}+${EC_M})"

    if ! ceph osd erasure-code-profile ls | grep -q "^${EC_PROFILE}$"; then
        ceph osd erasure-code-profile set \
            ${EC_PROFILE} k=${EC_K} m=${EC_M} --force || EC_SUCCESS=false
    fi

    if [ "$EC_SUCCESS" = true ]; then
        if ! ceph osd pool ls | grep -q "^${EC_POOL_NAME}$"; then
            ceph osd pool create ${EC_POOL_NAME} erasure ${EC_PROFILE} || EC_SUCCESS=false
        fi
    fi

    if [ "$EC_SUCCESS" = true ]; then
        ceph osd pool set ${EC_POOL_NAME} allow_ec_overwrites true || EC_SUCCESS=false
    fi

    # ------------------------------------------------
    # [2/6] 创建 replicated metadata pool
    # ------------------------------------------------
    echo ">>> [2/6] 创建 Replicated metadata pool"

    if ! ceph osd pool ls | grep -q "^${REP_POOL_NAME}$"; then
        ceph osd pool create ${REP_POOL_NAME}
        ceph osd pool set ${REP_POOL_NAME} size ${REP_SIZE}
        ceph osd pool set ${REP_POOL_NAME} min_size ${REP_MIN_SIZE}
    fi

    # ------------------------------------------------
    # [3/6] Pool 初始化
    # ------------------------------------------------
    echo ">>> [3/6] 初始化 pools"

    for p in ${REP_POOL_NAME} ${EC_POOL_NAME}; do
        ceph osd pool application enable $p rbd || true
        ceph osd pool set $p pg_autoscale_mode on || true
    done

    rbd pool init ${REP_POOL_NAME} || true

    if [ "$EC_SUCCESS" = true ]; then
        echo "✅ Dual-pool RBD 已启用"
        echo "   metadata pool : ${REP_POOL_NAME}"
        echo "   data pool     : ${EC_POOL_NAME}"
    else
        echo "⚠️ EC 不可用，仅使用 replication pool"
    fi

    # ------------------------------------------------
    # [4/6] 创建 RBD 镜像（dual-pool）
    # ------------------------------------------------
    echo ">>> [4/6] 创建 RBD 镜像"

    if ! rbd info ${REP_POOL_NAME}/${IMAGE_NAME} &>/dev/null; then
        if [ "$EC_SUCCESS" = true ]; then
            rbd create ${IMAGE_NAME} \
                --size ${IMAGE_SIZE} \
                --pool ${REP_POOL_NAME} \
                --data-pool ${EC_POOL_NAME}
        else
            rbd create ${IMAGE_NAME} \
                --size ${IMAGE_SIZE} \
                --pool ${REP_POOL_NAME}
        fi
    fi

    # ------------------------------------------------
    # [5/6] 映射 / 格式化 / 挂载
    # ------------------------------------------------
    echo ">>> [5/6] 映射 / 格式化 / 挂载"

    if ! rbd showmapped | grep -q "${REP_POOL_NAME}/${IMAGE_NAME}"; then
        rbd map ${REP_POOL_NAME}/${IMAGE_NAME}
    fi

    RBD_DEV=$(rbd showmapped | grep "${IMAGE_NAME}" | awk '{print $5}')

    if ! blkid ${RBD_DEV} | grep -q xfs; then
        mkfs.xfs -f ${RBD_DEV}
    fi

    systemctl stop mongod 2>/dev/null || true
    mkdir -p ${MOUNT_POINT}

    mount | grep -q "${MOUNT_POINT}" || mount ${RBD_DEV} ${MOUNT_POINT}

    if ! grep -q "${RBD_DEV}" /etc/fstab; then
        echo "${RBD_DEV} ${MOUNT_POINT} xfs defaults,_netdev 0 0" >> /etc/fstab
    fi

    # ------------------------------------------------
    # [6/6] 安装 MongoDB 6.0（Jammy 官方支持）
    # ------------------------------------------------
    echo ">>> [6/6] 安装 MongoDB 6.0"

    if ! command -v mongod &>/dev/null; then
        curl -fsSL https://pgp.mongodb.com/server-6.0.asc \
            | gpg --dearmor -o /usr/share/keyrings/mongodb-server-6.0.gpg

        echo "deb [ arch=amd64 signed-by=/usr/share/keyrings/mongodb-server-6.0.gpg ] \
https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" \
            > /etc/apt/sources.list.d/mongodb-org-6.0.list

        apt update
        apt install -y mongodb-org
    fi

    chown -R mongodb:mongodb ${MOUNT_POINT}
    sed -i 's/^ *bindIp:.*/bindIp: 0.0.0.0/' /etc/mongod.conf

    systemctl daemon-reload
    systemctl restart mongod
    systemctl enable mongod

    echo ">>> [Server] 完成"
}

# ================= Client (Node1) =================
install_client() {
    echo ">>> [Client] 安装 YCSB"

    apt update
    apt install -y default-jdk maven git python3 python-is-python3

    [ -d YCSB ] || git clone https://github.com/brianfrankcooper/YCSB.git
    cd YCSB
    mvn -pl mongodb -am clean package -DskipTests

    echo ">>> [Client] 完成"
}

# ================= 主入口 =================
case "$MODE" in
    server) install_server ;;
    client) install_client ;;
    *) usage ;;
esac
