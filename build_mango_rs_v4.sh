#!/bin/bash
set -euo pipefail

# ====================================================
# 用法:
#   sudo ./build_mango_rs_v4.sh server rep
#   sudo ./build_mango_rs_v4.sh server rs
#
#   sudo ./build_mango_rs_v4.sh server clay
#
#   sudo ./build_mango_rs_v4.sh server lrc
#   sudo ./build_mango_rs_v4.sh client
#
# 说明:
# - 本脚本不创建/修改 Ceph pools、profiles、RBD image
# - 假设你已经在 node0 上完成：
#     /mnt/xfs_rep
#     /mnt/xfs_rs
#     /mnt/xfs_clay
#     /mnt/xfs_lrc
# - Server:
#     - 安装 MongoDB 4.4 (针对不支持AVX指令集的老CPU)
#     - 切换 MongoDB 数据目录到指定 backend
# - Client:
#     - 安装 Java
#     - 下载【官方 YCSB binary release】
#     - 不编译、不修改源码
# ====================================================

MODE="${1:-}"
SCHEME="${2:-}"   # server 模式下：rep|rs|clay|lrc

########################################
# MongoDB & paths
########################################

MONGO_DATA_DIR="/var/lib/mongodb"
SUBDIR_NAME="mongodb"

MNT_REP="/mnt/xfs_rep"
MNT_RS="/mnt/xfs_rs"
MNT_CLAY="/mnt/xfs_clay"
MNT_LRC="/mnt/xfs_lrc"

########################################
# YCSB
########################################

YCSB_VERSION="0.17.0"
YCSB_TARBALL="ycsb-${YCSB_VERSION}.tar.gz"
YCSB_URL="https://github.com/brianfrankcooper/YCSB/releases/download/0.17.0/ycsb-0.17.0.tar.gz"
YCSB_INSTALL_DIR="/opt/ycsb"

########################################
# Utils
########################################

usage() {
  echo "用法:"
  echo "  sudo $0 server [rep|rs|clay|lrc]"
  echo "  $0 client"
  exit 1
}

require_root_server() {
  if [[ "$MODE" == "server" && "$(id -u)" -ne 0 ]]; then
    echo "ERROR: server 模式请用 root 运行"
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
  if [[ ! -d "$base" ]]; then
    echo "ERROR: $base 不存在"
    exit 1
  fi
  if ! mountpoint -q "$base"; then
    echo "ERROR: $base 不是 mountpoint"
    exit 1
  fi
}

########################################
# MongoDB install / config
########################################

install_mongodb_4() {
  if command -v mongod &>/dev/null; then
    echo ">>> MongoDB 已安装，跳过"
    return
  fi

  echo ">>> 安装 MongoDB 4.4 (针对老CPU指令集无AVX)"
  apt-get update
  apt-get install -y curl gnupg ca-certificates

  curl -fsSL https://www.mongodb.org/static/pgp/server-4.4.asc \
    | gpg --dearmor -o /usr/share/keyrings/mongodb-server-4.4.gpg

  echo "deb [ arch=amd64 signed-by=/usr/share/keyrings/mongodb-server-4.4.gpg ] \
https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/4.4 multiverse" \
    > /etc/apt/sources.list.d/mongodb-org-4.4.list

  apt-get update || true
  apt-get install -y mongodb-org
}

configure_mongodb_bindip() {
  echo ">>> 配置 MongoDB bindIp=0.0.0.0"
  if grep -q 'bindIp:' /etc/mongod.conf; then
    sed -i 's/^[[:space:]]*bindIp:.*/  bindIp: 0.0.0.0/' /etc/mongod.conf
  else
    cat >> /etc/mongod.conf <<EOF

net:
  bindIp: 0.0.0.0
EOF
  fi
}

switch_mongo_datadir() {
  local backend_dir="$1"

  echo ">>> MongoDB 数据目录 -> $backend_dir"
  systemctl stop mongod || true

  mkdir -p "$backend_dir"

  if [[ -d "$MONGO_DATA_DIR" && ! -L "$MONGO_DATA_DIR" ]]; then
    if [[ "$(ls -A "$MONGO_DATA_DIR" 2>/dev/null)" != "" ]]; then
      rsync -aHAX "$MONGO_DATA_DIR/" "$backend_dir/"
    fi
  fi

  rm -rf "$MONGO_DATA_DIR"
  ln -s "$backend_dir" "$MONGO_DATA_DIR"
  chown -R mongodb:mongodb "$backend_dir"

  sed -i "s|^[[:space:]]*dbPath:.*|  dbPath: ${MONGO_DATA_DIR}|" /etc/mongod.conf || true

  systemctl daemon-reload
  systemctl enable mongod
  systemctl restart mongod
}

########################################
# YCSB client (OFFICIAL RELEASE)
########################################

install_ycsb_client() {
  echo ">>> [Client] 安装 YCSB 官方发行包 (${YCSB_VERSION})"

  sudo apt-get update
  sudo apt-get install -y openjdk-17-jre-headless curl tar

  if [[ -d "${YCSB_INSTALL_DIR}/ycsb-${YCSB_VERSION}" ]]; then
    echo ">>> YCSB 已存在，跳过下载"
    return
  fi

  sudo mkdir -p "$YCSB_INSTALL_DIR"
  cd /tmp

  curl -LO "$YCSB_URL"
  sudo tar -xzf "$YCSB_TARBALL" -C "$YCSB_INSTALL_DIR"

  sudo ln -sf \
    "${YCSB_INSTALL_DIR}/ycsb-${YCSB_VERSION}/bin/ycsb" \
    /usr/local/bin/ycsb

  echo ">>> YCSB 安装完成:"
  echo "    $(which ycsb)"
  echo "    ycsb --version"
}

########################################
# Main
########################################

require_root_server

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

    install_mongodb_4
    configure_mongodb_bindip
    switch_mongo_datadir "$backend_dir"

    echo ">>> [Server] 完成 ($SCHEME)"
    ;;
  client)
    install_ycsb_client
    ;;
  *)
    usage
    ;;
esac
