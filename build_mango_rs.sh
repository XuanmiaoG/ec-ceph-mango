#!/bin/bash
set -euo pipefail

# ====================================================
# 用法:
#   sudo ./mongo_ycsb.sh server rs
#   sudo ./mongo_ycsb.sh server clay
#   sudo ./mongo_ycsb.sh server lrc
#   sudo ./mongo_ycsb.sh client
#
# 说明:
# - 本脚本不创建/修改 Ceph pools、profiles、RBD image
# - 假设你已经用“今天的脚本”在 node0 上完成：
#     /mnt/xfs_rs   (XFS on RBD on EC pool_rs)
#     /mnt/xfs_clay (XFS on RBD on EC pool_clay)
#     /mnt/xfs_lrc  (XFS on RBD on EC pool_lrc)
# - 本脚本只负责把 MongoDB data directory 放到对应 mount 上
# ====================================================

MODE="${1:-}"
SCHEME="${2:-}"   # only for server: rs|clay|lrc

# MongoDB data directory (system default)
MONGO_DATA_DIR="/var/lib/mongodb"

# Mount roots from today's setup
MNT_RS="/mnt/xfs_rs"
MNT_CLAY="/mnt/xfs_clay"
MNT_LRC="/mnt/xfs_lrc"

# Subdir inside mount for MongoDB data
SUBDIR_NAME="mongodb"

usage() {
  echo "用法:"
  echo "  sudo $0 server [rs|clay|lrc]"
  echo "  sudo $0 client"
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "请用 root 运行: sudo $0 ..."
    exit 1
  fi
}

pick_backend_path() {
  case "$SCHEME" in
    rs)   echo "${MNT_RS}/${SUBDIR_NAME}" ;;
    clay) echo "${MNT_CLAY}/${SUBDIR_NAME}" ;;
    lrc)  echo "${MNT_LRC}/${SUBDIR_NAME}" ;;
    *)    echo "" ;;
  esac
}

ensure_mount_ready() {
  local base="$1"  # e.g., /mnt/xfs_rs
  if [[ -z "$base" ]]; then
    echo "ERROR: mount base path is empty"
    exit 1
  fi
  if [[ ! -d "$base" ]]; then
    echo "ERROR: $base 不存在。你需要先完成今天的 RBD+XFS+mount 脚本。"
    exit 1
  fi
  if ! mountpoint -q "$base"; then
    echo "ERROR: $base 不是 mountpoint（没挂载成功）。请先 mount 好再跑。"
    exit 1
  fi
}

install_mongodb_6() {
  echo ">>> 安装 MongoDB 6.0 (Ubuntu jammy repo)..."
  if command -v mongod &>/dev/null; then
    echo " - mongod 已存在，跳过安装"
    return 0
  fi

  apt-get update
  apt-get install -y curl gnupg ca-certificates

  curl -fsSL https://pgp.mongodb.com/server-6.0.asc \
    | gpg --dearmor -o /usr/share/keyrings/mongodb-server-6.0.gpg

  echo "deb [ arch=amd64 signed-by=/usr/share/keyrings/mongodb-server-6.0.gpg ] \
https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" \
    > /etc/apt/sources.list.d/mongodb-org-6.0.list

  apt-get update
  apt-get install -y mongodb-org
}

configure_mongodb_bindip() {
  # 允许远程连接（YCSB 从 node1 打进来）
  if grep -q '^[[:space:]]*bindIp:' /etc/mongod.conf; then
    sed -i 's/^[[:space:]]*bindIp:.*/  bindIp: 0.0.0.0/' /etc/mongod.conf
  else
    # mongod.conf 格式一般含 net:，这里简单追加最小配置
    cat >> /etc/mongod.conf <<'EOF'

net:
  bindIp: 0.0.0.0
EOF
  fi
}

switch_mongo_datadir_to_backend() {
  local backend_dir="$1"  # e.g., /mnt/xfs_lrc/mongodb

  echo ">>> 切换 MongoDB 数据目录到: $backend_dir"
  systemctl stop mongod 2>/dev/null || true

  # 准备目标目录
  mkdir -p "$backend_dir"

  # 如果 /var/lib/mongodb 不是 symlink，且里面有数据，迁移一次
  if [[ -d "$MONGO_DATA_DIR" && ! -L "$MONGO_DATA_DIR" ]]; then
    if [[ "$(ls -A "$MONGO_DATA_DIR" 2>/dev/null || true)" != "" ]]; then
      echo " - 检测到 $MONGO_DATA_DIR 有旧数据，迁移到 $backend_dir ..."
      rsync -aHAX --delete "$MONGO_DATA_DIR/" "$backend_dir/"
    fi
  fi

  # 重新建立 symlink：/var/lib/mongodb -> backend_dir
  rm -rf "$MONGO_DATA_DIR"
  ln -s "$backend_dir" "$MONGO_DATA_DIR"

  # 权限
  chown -R mongodb:mongodb "$backend_dir"

  # 确保 mongod 配置中 dbPath 指向 /var/lib/mongodb（默认即可）
  # 如果你曾改过 dbPath，这里强制纠正为 /var/lib/mongodb
  if grep -q '^[[:space:]]*dbPath:' /etc/mongod.conf; then
    sed -i "s|^[[:space:]]*dbPath:.*|  dbPath: ${MONGO_DATA_DIR}|" /etc/mongod.conf
  fi

  systemctl daemon-reload
  systemctl enable mongod
  systemctl restart mongod
}

install_ycsb_client() {
  echo ">>> [Client] 安装 YCSB (mongodb binding)..."
  apt-get update
  apt-get install -y default-jdk maven git python3 python-is-python3

  if [[ ! -d YCSB ]]; then
    git clone https://github.com/brianfrankcooper/YCSB.git
  fi
  cd YCSB
  mvn -pl mongodb -am clean package -DskipTests

  echo ">>> [Client] 完成"
}

########################################
# 主入口
########################################
require_root

case "$MODE" in
  server)
    if [[ -z "$SCHEME" ]]; then
      echo "ERROR: server 模式必须指定 rs|clay|lrc"
      usage
    fi

    backend_dir="$(pick_backend_path)"
    if [[ -z "$backend_dir" ]]; then
      echo "ERROR: scheme 只能是 rs|clay|lrc"
      usage
    fi

    # 确认对应 mount 已经存在且已挂载
    case "$SCHEME" in
      rs)   ensure_mount_ready "$MNT_RS" ;;
      clay) ensure_mount_ready "$MNT_CLAY" ;;
      lrc)  ensure_mount_ready "$MNT_LRC" ;;
    esac

    install_mongodb_6
    configure_mongodb_bindip
    switch_mongo_datadir_to_backend "$backend_dir"

    echo "=============================================="
    echo ">>> [Server] 完成"
    echo "MongoDB 6 data dir -> $MONGO_DATA_DIR -> $backend_dir"
    echo "你可以在 node1 用 YCSB 连接 node0:27017"
    echo "=============================================="
    ;;
  client)
    install_ycsb_client
    ;;
  *)
    usage
    ;;
esac
