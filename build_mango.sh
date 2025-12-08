#!/bin/bash
set -e

# ================= 配置区域 =================
# 运行模式: server (Node0) 或 client (Node1)
MODE=$1

# Ceph 配置
POOL_NAME="rbd"
IMAGE_NAME="mongo-disk-500g"
IMAGE_SIZE="512000" # 500GB in MB
MOUNT_POINT="/var/lib/mongodb"

# ================= 帮助函数 =================
usage() {
    echo "用法: sudo ./setup.sh [server|client]"
    echo "  server: 在 Node0 上运行 (配置 Ceph RBD + 安装 MongoDB + 开启远程连接)"
    echo "  client: 在 Node1 上运行 (安装 YCSB 并修复编译错误)"
    exit 1
}

if [ -z "$MODE" ]; then
    usage
fi

# ================= 服务端逻辑 (Node 0) =================
install_server() {
    echo ">>> [Server] 正在配置 MongoDB 服务端..."

    # 1. 创建 Ceph RBD 存储池 (修复 'pool not found' 错误)
    echo ">>> [1/5] 检查 Ceph 存储池..."
    if ! sudo ceph osd pool ls | grep -q "^${POOL_NAME}$"; then
        echo "创建存储池 '${POOL_NAME}'..."
        sudo ceph osd pool create ${POOL_NAME} 32
        sudo rbd pool init ${POOL_NAME}
        sudo ceph osd pool application enable ${POOL_NAME} rbd
    else
        echo "存储池 '${POOL_NAME}' 已存在。"
    fi

    # 2. 创建 RBD 镜像
    echo ">>> [2/5] 检查 RBD 镜像..."
    if ! sudo rbd info ${IMAGE_NAME} --pool ${POOL_NAME} >/dev/null 2>&1; then
        echo "创建 500GB 虚拟盘..."
        sudo rbd create ${IMAGE_NAME} --size ${IMAGE_SIZE} --pool ${POOL_NAME}
    else
        echo "镜像 '${IMAGE_NAME}' 已存在。"
    fi

    # 3. 映射、格式化与挂载
    echo ">>> [3/5] 挂载磁盘..."
    # 映射
    if ! sudo rbd showmapped | grep -q "${IMAGE_NAME}"; then
        sudo rbd map ${IMAGE_NAME} --pool ${POOL_NAME}
    fi
    RBD_DEV=$(sudo rbd showmapped | grep "${IMAGE_NAME}" | awk '{print $5}')
    
    # 格式化 XFS
    if ! sudo blkid ${RBD_DEV} | grep -q "xfs"; then
        sudo mkfs.xfs ${RBD_DEV}
    fi
    
    # 挂载
    sudo systemctl stop mongod 2>/dev/null || true
    sudo mkdir -p ${MOUNT_POINT}
    if ! mount | grep -q "${RBD_DEV}"; then
        sudo mount ${RBD_DEV} ${MOUNT_POINT}
    fi
    # 写入 fstab
    if ! grep -q "${RBD_DEV}" /etc/fstab; then
        echo "${RBD_DEV} ${MOUNT_POINT} xfs defaults,_netdev 0 0" | sudo tee -a /etc/fstab
    fi

    # 4. 安装 MongoDB (4.4 版本)
    echo ">>> [4/5] 安装 MongoDB 4.4..."
    if ! command -v mongod &> /dev/null; then
        # 安装 libssl1.1 依赖
        wget -q http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2_amd64.deb
        sudo dpkg -i libssl1.1_1.1.1f-1ubuntu2_amd64.deb || sudo apt-get install -f -y
        
        # 添加源
        curl -fsSL https://www.mongodb.org/static/pgp/server-4.4.asc | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-4.4.gpg --yes
        echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-4.4.gpg ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/4.4 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-4.4.list
        
        sudo apt update
        sudo apt install -y mongodb-org
    fi

    # 修复权限
    sudo chown -R mongodb:mongodb ${MOUNT_POINT}

    # 5. 修改 IP 绑定 (修复 'Connection Refused' 错误)
    echo ">>> [5/5] 配置网络绑定 (0.0.0.0)..."
    sudo sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/' /etc/mongod.conf
    
    # 重启服务
    sudo systemctl daemon-reload
    sudo systemctl restart mongod
    sudo systemctl enable mongod

    echo ">>> [Server] 完成！"
    echo "    - 存储: 500GB Ceph RBD 已挂载"
    echo "    - 网络: 已允许外部连接 (0.0.0.0:27017)"
    echo "    - 验证: sudo rbd -p rbd du ${IMAGE_NAME}"
}

# ================= 客户端逻辑 (Node 1) =================
install_client() {
    echo ">>> [Client] 正在配置 YCSB 客户端..."

    # 1. 安装依赖
    echo ">>> [1/3] 安装 Java 和 Maven..."
    sudo apt update
    sudo apt install -y default-jdk maven git python3 python-is-python3

    # 2. 下载 YCSB
    echo ">>> [2/3] 下载 YCSB..."
    if [ ! -d "YCSB" ]; then
        git clone https://github.com/brianfrankcooper/YCSB.git
    else
        echo "YCSB 目录已存在，跳过下载。"
    fi
    
    # 3. 极速编译 (修复 Maven 报错)
    echo ">>> [3/3] 编译 YCSB (只编译 MongoDB 模块)..."
    cd YCSB
    # 关键命令：-pl mongodb 只编译 mongo，-am 编译依赖，-DskipTests 跳过测试
    mvn -pl mongodb -am clean package -DskipTests

    echo ">>> [Client] 完成！"
    echo "    - YCSB 安装路径: $(pwd)"
    echo "    - 运行测试命令示例:"
    echo "      ./bin/ycsb load mongodb -s -P workloads/workloada -p mongodb.url='mongodb://10.10.1.1:27017/ycsb?w=0'"
}

# ================= 主流程 =================
case "$MODE" in
    server)
        install_server
        ;;
    client)
        install_client
        ;;
    *)
        usage
        ;;
esac