#!/bin/bash
set -euo pipefail

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

# ---------- RBD metadata pool (replicated) ----------
META_POOL="rbd_meta"

# ---------- Replicated baseline pool (traditional 3x replication) ----------
POOL_REP="rbd_data"
REP_SIZE=3

# ---------- RBD images ----------
IMG_RS="xfs_img_rs"
IMG_CLAY="xfs_img_clay"
IMG_LRC="xfs_img_lrc"
IMG_REP="xfs_img_rep"

# ---------- Host mount points ----------
MNT_RS="/mnt/xfs_rs"
MNT_CLAY="/mnt/xfs_clay"
MNT_LRC="/mnt/xfs_lrc"
MNT_REP="/mnt/xfs_rep"

# ---------- Optional extra cleanup targets ----------
EXTRA_POOLS=("pool_optlrc")
EXTRA_PROFILES=("profile-optlrc")

########################################
echo ">>> [0/9] 预清理（宿主机）：umount & unmap（避免设备占用）..."
########################################

for mnt in "$MNT_REP" "$MNT_RS" "$MNT_CLAY" "$MNT_LRC"; do
  if mountpoint -q "$mnt"; then
    echo " - umount $mnt"
    umount "$mnt" || true
  fi
done

# unmap our images if mapped
if rbd showmapped >/dev/null 2>&1; then
  # EC-backed images live in META_POOL
  for img in "$IMG_RS" "$IMG_CLAY" "$IMG_LRC"; do
    dev="$(rbd showmapped 2>/dev/null | awk -v p="$META_POOL" -v i="$img" '$2==p && $4==i {print $6}')"
    if [[ -n "${dev:-}" ]]; then
      echo " - rbd unmap $dev (for $META_POOL/$img)"
      rbd unmap "$dev" || true
    fi
  done

  # Replicated baseline image lives in POOL_REP
  dev_rep="$(rbd showmapped 2>/dev/null | awk -v p="$POOL_REP" -v i="$IMG_REP" '$2==p && $4==i {print $6}')"
  if [[ -n "${dev_rep:-}" ]]; then
    echo " - rbd unmap $dev_rep (for $POOL_REP/$IMG_REP)"
    rbd unmap "$dev_rep" || true
  fi
fi

########################################
echo ">>> [1/9] 清理旧环境（Ceph侧）：删 pool / profile..."
########################################

# delete pools (⚠️ 会删 rbd_data / rbd_meta / 三个 EC pool)
for pool in "$POOL_RS" "$POOL_CLAY" "$POOL_LRC" "$META_POOL" "$POOL_REP" "${EXTRA_POOLS[@]}"; do
  sudo cephadm shell -- ceph osd pool delete "$pool" "$pool" \
    --yes-i-really-really-mean-it || true
done

# delete profiles
for profile in "$PROFILE_RS" "$PROFILE_CLAY" "$PROFILE_LRC" "${EXTRA_PROFILES[@]}"; do
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
echo ">>> [3/9] 创建 Replicated baseline pool (size=$REP_SIZE): $POOL_REP"
########################################

sudo cephadm shell -- ceph osd pool create "$POOL_REP" 64
sudo cephadm shell -- ceph osd pool set "$POOL_REP" size "$REP_SIZE"
sudo cephadm shell -- ceph osd pool application enable "$POOL_REP" rbd || true
sudo cephadm shell -- rbd pool init "$POOL_REP" || true

########################################
echo ">>> [4/9] 配置 RS EC Pool (k=6, m=4) -> $POOL_RS"
########################################

sudo cephadm shell -- ceph osd erasure-code-profile set "$PROFILE_RS" \
  plugin=jerasure \
  technique=reed_sol_van \
  k=6 m=4 \
  crush-failure-domain=host \
  --force

sudo cephadm shell -- ceph osd pool create "$POOL_RS" erasure "$PROFILE_RS"

########################################
echo ">>> [5/9] 配置 CLAY EC Pool (k=6, m=3, d=8) -> $POOL_CLAY"
########################################

sudo cephadm shell -- ceph osd erasure-code-profile set "$PROFILE_CLAY" \
  plugin=clay \
  k=6 m=3 d=8 \
  crush-failure-domain=host \
  --force

sudo cephadm shell -- ceph osd pool create "$POOL_CLAY" erasure "$PROFILE_CLAY"

########################################
echo ">>> [6/9] 配置 LRC EC Pool (k=6, m=2, l=4) -> $POOL_LRC"
########################################

sudo cephadm shell -- ceph osd erasure-code-profile set "$PROFILE_LRC" \
  plugin=lrc \
  k=6 m=2 l=4 \
  crush-failure-domain=host \
  --force

sudo cephadm shell -- ceph osd pool create "$POOL_LRC" erasure "$PROFILE_LRC"

########################################
echo ">>> [7/9] 启用 RBD-on-EC（必须）：allow_ec_overwrites + application rbd"
########################################

for pool in "$POOL_RS" "$POOL_CLAY" "$POOL_LRC"; do
  sudo cephadm shell -- ceph osd pool set "$pool" allow_ec_overwrites true
  sudo cephadm shell -- ceph osd pool application enable "$pool" rbd
done

########################################
echo ">>> [8/9] 创建 RBD images：EC 三张（metadata=$META_POOL, data-pool=EC pool） + Rep 一张（pool=$POOL_REP）"
########################################

# EC-backed images (metadata in META_POOL, data in EC pool)
sudo cephadm shell -- rbd create "$META_POOL/$IMG_RS" \
  --size 100G \
  --image-feature layering \
  --data-pool "$POOL_RS"

sudo cephadm shell -- rbd create "$META_POOL/$IMG_CLAY" \
  --size 100G \
  --image-feature layering \
  --data-pool "$POOL_CLAY"

sudo cephadm shell -- rbd create "$META_POOL/$IMG_LRC" \
  --size 100G \
  --image-feature layering \
  --data-pool "$POOL_LRC"

# Replicated baseline image (data also in POOL_REP)
sudo cephadm shell -- rbd create "$POOL_REP/$IMG_REP" \
  --size 100G \
  --image-feature layering

########################################
echo ">>> [9/9] 宿主机：map -> mkfs.xfs -> mount (REP + RS + CLAY + LRC)"
########################################

DEV_RS="$(rbd map "$META_POOL/$IMG_RS")"
DEV_CLAY="$(rbd map "$META_POOL/$IMG_CLAY")"
DEV_LRC="$(rbd map "$META_POOL/$IMG_LRC")"
DEV_REP="$(rbd map "$POOL_REP/$IMG_REP")"

echo " - mapped $META_POOL/$IMG_RS   -> $DEV_RS"
echo " - mapped $META_POOL/$IMG_CLAY -> $DEV_CLAY"
echo " - mapped $META_POOL/$IMG_LRC  -> $DEV_LRC"
echo " - mapped $POOL_REP/$IMG_REP   -> $DEV_REP"

# mkfs XFS (实验环境强制重建)
mkfs.xfs -f "$DEV_RS"
mkfs.xfs -f "$DEV_CLAY"
mkfs.xfs -f "$DEV_LRC"
mkfs.xfs -f "$DEV_REP"

mkdir -p "$MNT_RS" "$MNT_CLAY" "$MNT_LRC" "$MNT_REP"
mount "$DEV_RS" "$MNT_RS"
mount "$DEV_CLAY" "$MNT_CLAY"
mount "$DEV_LRC" "$MNT_LRC"
mount "$DEV_REP" "$MNT_REP"

########################################
echo "=============================================="
echo ">>> 部署完成！"
echo "RBD metadata pool : $META_POOL (replicated size=3)"
echo "REP  pool         : $POOL_REP (replicated size=$REP_SIZE) image=$POOL_REP/$IMG_REP   dev=$DEV_REP  mnt=$MNT_REP"
echo "RS   EC pool      : $POOL_RS   (6,4)   image=$META_POOL/$IMG_RS   dev=$DEV_RS   mnt=$MNT_RS"
echo "CLAY EC pool      : $POOL_CLAY (6,3,8) image=$META_POOL/$IMG_CLAY dev=$DEV_CLAY mnt=$MNT_CLAY"
echo "LRC  EC pool      : $POOL_LRC  (6,2,4) image=$META_POOL/$IMG_LRC  dev=$DEV_LRC  mnt=$MNT_LRC"
echo "=============================================="

echo ">>> ceph pools detail:"
sudo cephadm shell -- ceph osd pool ls detail | egrep "($META_POOL|$POOL_REP|$POOL_RS|$POOL_CLAY|$POOL_LRC)" || true

echo ">>> rbd images in $META_POOL:"
sudo cephadm shell -- rbd ls "$META_POOL" || true

echo ">>> rbd images in $POOL_REP:"
sudo cephadm shell -- rbd ls "$POOL_REP" || true

echo ">>> rbd info summary (EC images):"
sudo cephadm shell -- rbd info "$META_POOL/$IMG_RS"   | egrep "data_pool|features|size|order|block_name_prefix" || true
sudo cephadm shell -- rbd info "$META_POOL/$IMG_CLAY" | egrep "data_pool|features|size|order|block_name_prefix" || true
sudo cephadm shell -- rbd info "$META_POOL/$IMG_LRC"  | egrep "data_pool|features|size|order|block_name_prefix" || true

echo ">>> rbd info summary (REP image):"
sudo cephadm shell -- rbd info "$POOL_REP/$IMG_REP" | egrep "features|size|order|block_name_prefix" || true

echo ">>> host rbd showmapped:"
rbd showmapped || true

echo ">>> host mount | grep rbd:"
mount | grep rbd || true

echo ">>> host df -h (mount points):"
df -h "$MNT_REP" "$MNT_RS" "$MNT_CLAY" "$MNT_LRC" || true
