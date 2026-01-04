#!/bin/bash
set -e

########################################
# 基本变量
########################################

POOL_LRC="pool_lrc"
PROFILE_LRC="profile-lrc"

POOL_CLAY="pool_clay"
PROFILE_CLAY="profile-clay"

# RBD Metadata Pool（replicated）
META_POOL="rbd_meta"

########################################
echo ">>> [1/5] 清理旧环境..."
########################################

for pool in $POOL_LRC $POOL_CLAY $META_POOL pool_optlrc; do
  sudo cephadm shell -- ceph osd pool delete $pool $pool \
    --yes-i-really-really-mean-it || true
done

for profile in $PROFILE_LRC $PROFILE_CLAY profile-optlrc; do
  sudo cephadm shell -- ceph osd erasure-code-profile rm $profile || true
done

########################################
echo ">>> [2/5] 创建 RBD Metadata Pool (replicated)..."
########################################

sudo cephadm shell -- ceph osd pool create $META_POOL 64
sudo cephadm shell -- ceph osd pool set $META_POOL size 3
sudo cephadm shell -- rbd pool init $META_POOL

########################################
echo ">>> [3/5] 配置 Clay EC Pool (k=6, m=3, d=8)..."
########################################

sudo cephadm shell -- ceph osd erasure-code-profile set $PROFILE_CLAY \
    plugin=clay \
    k=6 m=3 d=8 \
    crush-failure-domain=host \
    --force

sudo cephadm shell -- ceph osd pool create $POOL_CLAY erasure $PROFILE_CLAY

########################################
echo ">>> [4/5] 配置 LRC EC Pool (k=6, m=2, l=4)..."
########################################

sudo cephadm shell -- ceph osd erasure-code-profile set $PROFILE_LRC \
    plugin=lrc \
    k=6 m=2 l=4 \
    crush-failure-domain=host \
    --force

sudo cephadm shell -- ceph osd pool create $POOL_LRC erasure $PROFILE_LRC

########################################
echo ">>> [5/5] 启用 RBD-on-EC 并创建 RBD images..."
########################################

for pool in $POOL_CLAY $POOL_LRC; do
    sudo cephadm shell -- ceph osd pool set $pool allow_ec_overwrites true
    sudo cephadm shell -- ceph osd pool application enable $pool rbd
done

# 创建 RBD images（metadata 在 rbd_meta，data 在 EC pool）
sudo cephadm shell -- rbd create $META_POOL/xfs_img_clay \
  --size 100G \
  --image-feature layering \
  --data-pool $POOL_CLAY

sudo cephadm shell -- rbd create $META_POOL/xfs_img_lrc \
  --size 100G \
  --image-feature layering \
  --data-pool $POOL_LRC

########################################
echo "=============================================="
echo ">>> 部署完成！"
echo "RBD metadata pool : $META_POOL (replicated)"
echo "Clay EC pool      : $POOL_CLAY (6,3,8)"
echo "LRC  EC pool      : $POOL_LRC  (6,2,4)"
echo "=============================================="

sudo cephadm shell -- ceph osd pool ls detail
sudo cephadm shell -- rbd ls $META_POOL
