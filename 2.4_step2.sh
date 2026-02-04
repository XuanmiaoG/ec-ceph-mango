#!/bin/bash
set -euo pipefail

# 检查并安装 xfsprogs（mkfs.xfs 需要）
if ! command -v mkfs.xfs &> /dev/null; then
    echo ">>> 检测到缺少 mkfs.xfs，正在安装 xfsprogs..."
    sudo apt-get update && sudo apt-get install -y xfsprogs
fi

########################################
# 基本变量
########################################

# ---------- EC pools + profiles ----------
POOL_RS="pool_rs"
PROFILE_RS="profile-rs"

POOL_CLAY="pool_clay"
PROFILE_CLAY="profile-clay"

POOL_LRC="pool_lrc"
PROFILE_LRC="profile-lrc"

POOL_OPTLRC="pool_optlrc"
PROFILE_OPTLRC="profile-optlrc"

# ---------- RBD metadata pool (replicated) ----------
META_POOL="rbd_meta"

# ---------- RBD images ----------
IMG_RS="img_rs"
IMG_CLAY="img_clay"
IMG_LRC="img_lrc"
IMG_OPTLRC="img_optlrc"

# ---------- Host mount points ----------
MNT_RS="/mnt/xfs_rs"
MNT_CLAY="/mnt/xfs_clay"
MNT_LRC="/mnt/xfs_lrc"
MNT_OPTLRC="/mnt/xfs_optlrc"

########################################
echo ">>> [0/9] 预清理（宿主机）：umount & unmap（避免设备占用）..."
########################################

for mnt in "$MNT_RS" "$MNT_CLAY" "$MNT_LRC" "$MNT_OPTLRC"; do
  if mountpoint -q "$mnt"; then
    echo " - umount $mnt"
    umount "$mnt" || true
  fi
done

# unmap our images if mapped
if rbd showmapped >/dev/null 2>&1; then
  # All EC-backed images live in META_POOL
  for img in "$IMG_RS" "$IMG_CLAY" "$IMG_LRC" "$IMG_OPTLRC"; do
    dev="$(rbd showmapped 2>/dev/null | awk -v p="$META_POOL" -v i="$img" '$2==p && $4==i {print $6}')"
    if [[ -n "${dev:-}" ]]; then
      echo " - rbd unmap $dev (for $META_POOL/$img)"
      rbd unmap "$dev" || true
    fi
  done
fi

########################################
echo ">>> [1/9] 清理旧环境（Ceph侧）：删 pool / profile..."
########################################

# delete pools (⚠️ 会删 rbd_meta / 四个 EC pool)
for pool in "$POOL_RS" "$POOL_CLAY" "$POOL_LRC" "$POOL_OPTLRC" "$META_POOL"; do
  sudo cephadm shell -- ceph osd pool delete "$pool" "$pool" \
    --yes-i-really-really-mean-it || true
done

# delete profiles
for profile in "$PROFILE_RS" "$PROFILE_CLAY" "$PROFILE_LRC" "$PROFILE_OPTLRC"; do
  sudo cephadm shell -- ceph osd erasure-code-profile rm "$profile" || true
done

########################################
echo ">>> [2/9] 创建 RBD Metadata Pool (replicated): $META_POOL"
########################################

sudo cephadm shell -- ceph osd pool create "$META_POOL" 64
sudo cephadm shell -- ceph osd pool set "$META_POOL" size 3
sudo cephadm shell -- ceph osd pool application enable "$META_POOL" rbd || true
sudo cephadm shell -- rbd pool init "$META_POOL"

########################################
echo ">>> [3/9] 配置 OptLRC EC Pool (k=6, m=4, l=5) -> $POOL_OPTLRC"
########################################

sudo cephadm shell -- ceph osd erasure-code-profile set "$PROFILE_OPTLRC" \
  plugin=lrc \
  k=6 m=4 l=5 \
  crush-failure-domain=osd \
  --force

sudo cephadm shell -- ceph osd pool create "$POOL_OPTLRC" erasure "$PROFILE_OPTLRC"

########################################
echo ">>> [4/9] 配置 RS EC Pool (k=6, m=4) -> $POOL_RS"
########################################

sudo cephadm shell -- ceph osd erasure-code-profile set "$PROFILE_RS" \
  plugin=jerasure \
  technique=reed_sol_van \
  k=6 m=4 \
  crush-failure-domain=osd \
  --force

sudo cephadm shell -- ceph osd pool create "$POOL_RS" erasure "$PROFILE_RS"

########################################
echo ">>> [5/9] 配置 CLAY EC Pool (k=6, m=3, d=8) -> $POOL_CLAY"
########################################

sudo cephadm shell -- ceph osd erasure-code-profile set "$PROFILE_CLAY" \
  plugin=clay \
  k=6 m=3 d=8 \
  crush-failure-domain=osd \
  --force

sudo cephadm shell -- ceph osd pool create "$POOL_CLAY" erasure "$PROFILE_CLAY"

########################################
echo ">>> [6/9] 配置 LRC EC Pool (k=6, m=2, l=4) -> $POOL_LRC"
########################################

sudo cephadm shell -- ceph osd erasure-code-profile set "$PROFILE_LRC" \
  plugin=lrc \
  k=6 m=2 l=4 \
  crush-failure-domain=osd \
  --force

sudo cephadm shell -- ceph osd pool create "$POOL_LRC" erasure "$PROFILE_LRC"

########################################
echo ">>> [7/9] 启用 RBD-on-EC（必须）：allow_ec_overwrites + application rbd"
########################################

for pool in "$POOL_RS" "$POOL_CLAY" "$POOL_LRC" "$POOL_OPTLRC"; do
  sudo cephadm shell -- ceph osd pool set "$pool" allow_ec_overwrites true
  sudo cephadm shell -- ceph osd pool application enable "$pool" rbd
done

########################################
echo ">>> [8/9] 创建 RBD images：4张 EC-backed images (metadata=$META_POOL, data-pool=EC pool)"
########################################

# EC-backed images (metadata in META_POOL, data in EC pool)
sudo cephadm shell -- rbd create "$META_POOL/$IMG_RS" \
  --size 2T \
  --image-feature layering \
  --data-pool "$POOL_RS"

sudo cephadm shell -- rbd create "$META_POOL/$IMG_CLAY" \
  --size 2T \
  --image-feature layering \
  --data-pool "$POOL_CLAY"

sudo cephadm shell -- rbd create "$META_POOL/$IMG_LRC" \
  --size 2T \
  --image-feature layering \
  --data-pool "$POOL_LRC"

sudo cephadm shell -- rbd create "$META_POOL/$IMG_OPTLRC" \
  --size 2T \
  --image-feature layering \
  --data-pool "$POOL_OPTLRC"

########################################
echo ">>> [9/9] 宿主机：map -> mkfs.xfs -> mount (RS + CLAY + LRC + OptLRC)"
########################################

DEV_RS="$(rbd map "$META_POOL/$IMG_RS")"
DEV_CLAY="$(rbd map "$META_POOL/$IMG_CLAY")"
DEV_LRC="$(rbd map "$META_POOL/$IMG_LRC")"
DEV_OPTLRC="$(rbd map "$META_POOL/$IMG_OPTLRC")"

echo " - mapped $META_POOL/$IMG_RS     -> $DEV_RS"
echo " - mapped $META_POOL/$IMG_CLAY   -> $DEV_CLAY"
echo " - mapped $META_POOL/$IMG_LRC    -> $DEV_LRC"
echo " - mapped $META_POOL/$IMG_OPTLRC -> $DEV_OPTLRC"

# mkfs XFS (实验环境强制重建)
mkfs.xfs -f -K "$DEV_RS"
mkfs.xfs -f -K "$DEV_CLAY"
mkfs.xfs -f -K "$DEV_LRC"
mkfs.xfs -f -K "$DEV_OPTLRC"

mkdir -p "$MNT_RS" "$MNT_CLAY" "$MNT_LRC" "$MNT_OPTLRC"
mount "$DEV_RS" "$MNT_RS"
mount "$DEV_CLAY" "$MNT_CLAY"
mount "$DEV_LRC" "$MNT_LRC"
mount "$DEV_OPTLRC" "$MNT_OPTLRC"

########################################
echo "=============================================="
echo ">>> 部署完成！"
echo "RBD metadata pool : $META_POOL (replicated size=3)"
echo "RS     EC pool    : $POOL_RS     (k=6,m=4)     image=$META_POOL/$IMG_RS     dev=$DEV_RS     mnt=$MNT_RS"
echo "CLAY   EC pool    : $POOL_CLAY   (k=6,m=3,d=8) image=$META_POOL/$IMG_CLAY   dev=$DEV_CLAY   mnt=$MNT_CLAY"
echo "LRC    EC pool    : $POOL_LRC    (k=6,m=2,l=4) image=$META_POOL/$IMG_LRC    dev=$DEV_LRC    mnt=$MNT_LRC"
echo "OptLRC EC pool    : $POOL_OPTLRC (k=6,m=4,l=5) image=$META_POOL/$IMG_OPTLRC dev=$DEV_OPTLRC mnt=$MNT_OPTLRC"
echo "=============================================="

echo ">>> ceph pools detail:"
sudo cephadm shell -- ceph osd pool ls detail | egrep "($META_POOL|$POOL_RS|$POOL_CLAY|$POOL_LRC|$POOL_OPTLRC)" || true

echo ">>> rbd images in $META_POOL:"
sudo cephadm shell -- rbd ls "$META_POOL" || true

echo ">>> rbd info summary (all EC images):"
sudo cephadm shell -- rbd info "$META_POOL/$IMG_RS"     | egrep "data_pool|features|size|order" || true
sudo cephadm shell -- rbd info "$META_POOL/$IMG_CLAY"   | egrep "data_pool|features|size|order" || true
sudo cephadm shell -- rbd info "$META_POOL/$IMG_LRC"    | egrep "data_pool|features|size|order" || true
sudo cephadm shell -- rbd info "$META_POOL/$IMG_OPTLRC" | egrep "data_pool|features|size|order" || true

echo ">>> host rbd showmapped:"
rbd showmapped || true

echo ">>> host mount | grep rbd:"
mount | grep rbd || true

echo ">>> host df -h (mount points):"
df -h "$MNT_RS" "$MNT_CLAY" "$MNT_LRC" "$MNT_OPTLRC" || true