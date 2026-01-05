#!/bin/bash
set -euo pipefail

# ====================================================
# 用法:
#   sudo ./mongo_ycsb.sh server rep
#   sudo ./mongo_ycsb.sh server rs
#   sudo ./mongo_ycsb.sh server clay
#   sudo ./mongo_ycsb.sh server lrc
#   sudo ./mongo_ycsb.sh client
#
# 说明:
# - 本脚本不创建/修改 Ceph pools、profiles、RBD image
# - 假设你已经在 node0 上完成：
#     /mnt/xfs_rep   (XFS on RBD, replicated pool)
#     /mnt/xfs_rs    (XFS on RBD on EC pool_rs)
#     /mnt/xfs_clay  (XFS on RBD on EC pool_clay)
#     /mnt/xfs_lrc   (XFS on RBD on EC pool_lrc)
# - 本脚本只负责：
#     1) 安装 MongoDB / YCSB
#     2) 切换 MongoDB data directory 到指定 backend
# ====================================================

MODE="${1:-}"
SCHEME="${2:-}"   # server 模式下：rep|rs|clay|lrc

########################################
# MongoDB & paths
########################################

MONGO_DATA_DIR="/var/lib/mongodb"
SUBDIR_NAME="mongodb"

# Mount points
MNT_REP="/mnt/xfs_rep"
MNT_RS="/mnt/xfs_rs"
MNT_CLAY="/mnt/xfs_clay"
MNT_LRC="/mnt/xfs_lrc"

########################################
# Utils
########################################

usage() {
  echo "用法:"
  echo "  sudo $0 server [rep|rs|clay|lrc]"
  echo "  sudo $0 client"
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: 请用 root 运行: sudo $0 ..."
    exit 1
  fi
}

pick_backend_path() {
  case "$SCHEME" in
    rep)  echo "${MNT_REP}/${SUBDIR_NAME}" ;;
    rs)   echo "${MNT_RS}/${SUBDIR_NAME}" ;;
    clay) echo "${MNT_CLAY}/${SUBDIR_NAME}" ;;
    lrc)  echo "${MNT_LRC}/${SUBDIR_NAME}" ;;
    *)    echo "" ;;
  esac
}

ensure_mount_ready() {
  local base="$1"
  if [[ -z "$base" ]]; then
    echo "ERROR: mount base path is empty"
    exit 1
  fi
  if [[ ! -d "$base" ]]; then
    echo "ERROR: $base 不存在，请先完成 RBD + XFS + mount"
    exit 1
  fi
  if ! mountpoint -q "$base"; then
    echo "ERROR: $base 不是 mountpoint（尚未挂载）"
    exit 1
  fi
}

########################################
# MongoDB install / config
########################################

install_mongodb_6() {
  echo ">>> 安装 MongoDB 6.0 (Ubuntu 22.04 / jammy)..."
  if command -v mongod &>/dev/null; then
    echo " - mongod 已存在，跳过安装"
    return
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
  echo ">>> 配置 MongoDB 允许远程访问 (bindIp=0.0.0.0)"
  if grep -q '^[[:space:]]*bindIp:' /etc/mongod.conf; then
    sed -i 's/^[[:space:]]*bindIp:.*/  bindIp: 0.0.0.0/' /etc/mongod.conf
  else
    cat >> /etc/mongod.conf <<'EOF'

net:
  bindIp: 0.0.0.0
EOF
  fi
}

switch_mongo_datadir() {
  local backend_dir="$1"

  echo ">>> 切换 MongoDB 数据目录到: $backend_dir"

  systemctl stop mongod 2>/dev/null || true
  mkdir -p "$backend_dir"

  # 如果原来有数据，迁移一次
  if [[ -d "$MONGO_DATA_DIR" && ! -L "$MONGO_DATA_DIR" ]]; then
    if [[ "$(ls -A "$MONGO_DATA_DIR" 2>/dev/null || true)" != "" ]]; then
      echo " - 迁移旧数据到 $backend_dir"
      rsync -aHAX --delete "$MONGO_DATA_DIR/" "$backend_dir/"
    fi
  fi

  rm -rf "$MONGO_DATA_DIR"
  ln -s "$backend_dir" "$MONGO_DATA_DIR"

  chown -R mongodb:mongodb "$backend_dir"

  # 强制 dbPath 正确
  if grep -q '^[[:space:]]*dbPath:' /etc/mongod.conf; then
    sed -i "s|^[[:space:]]*dbPath:.*|  dbPath: ${MONGO_DATA_DIR}|" /etc/mongod.conf
  fi

  systemctl daemon-reload
  systemctl enable mongod
  systemctl restart mongod
}

########################################
# YCSB client install
########################################

install_ycsb_client() {
  echo ">>> [Client] 安装 YCSB (MongoDB binding)..."

  apt-get update
  apt-get install -y default-jdk maven git python3 python-is-python3

  if [[ ! -d YCSB ]]; then
    git clone https://github.com/brianfrankcooper/YCSB.git
  fi

  cd YCSB
  mvn -pl mongodb -am clean package -DskipTests

  echo ">>> [Client] YCSB 安装完成"
}

########################################
# Main
########################################

require_root

case "$MODE" in
  server)
    [[ -z "$SCHEME" ]] && usage

    backend_dir="$(pick_backend_path)"
    [[ -z "$backend_dir" ]] && usage

    case "$SCHEME" in
      rep)  ensure_mount_ready "$MNT_REP" ;;
      rs)   ensure_mount_ready "$MNT_RS" ;;
      clay) ensure_mount_ready "$MNT_CLAY" ;;
      lrc)  ensure_mount_ready "$MNT_LRC" ;;
    esac

    install_mongodb_6
    configure_mongodb_bindip
    switch_mongo_datadir "$backend_dir"

    echo "=============================================="
    echo ">>> [Server] 完成"
    echo "Backend : $SCHEME"
    echo "MongoDB : /var/lib/mongodb -> $backend_dir"
    echo "Listen  : 0.0.0.0:27017"
    echo "=============================================="
    ;;
  client)
    install_ycsb_client
    ;;
  *)
    usage
    ;;
esac
