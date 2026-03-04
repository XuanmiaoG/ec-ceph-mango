#!/bin/bash
set -euo pipefail

# ================= 配置区域 =================
# YCSB 安装目录（按你现在的安装路径）
YCSB_HOME="/opt/ycsb/ycsb-0.17.0"
YCSB_BIN="${YCSB_HOME}/bin/ycsb.sh"

DB_TYPE="mongodb"
WORKLOAD="${YCSB_HOME}/workloads/workload_ceph_read"
#WORKLOAD="${YCSB_HOME}/workloads/workloada"
DB_URL="mongodb://10.10.1.1:27017/ycsb?w=1"

# 数据量配置
RECORD_COUNT=5000000      # 数据库里的总行数
OPERATION_COUNT=100000000 # 巨大数值，保证跑满时间
THREADS=8

# 时间控制 (20分钟 = 1200秒)
RUN_TIME_SEC=1200

# 输出文件（写到 root 当前目录，也可以改成固定目录）
LOG_FILE="/root/ycsb_run.log"
CSV_FILE="/root/result_rs_out1.csv"
# ===========================================

echo ">>> YCSB_BIN   : $YCSB_BIN"
echo ">>> WORKLOAD   : $WORKLOAD"
echo ">>> DB_URL     : $DB_URL"
echo ">>> LOG_FILE   : $LOG_FILE"
echo ">>> CSV_FILE   : $CSV_FILE"

# 基础检查：路径必须存在
if [[ ! -x "$YCSB_BIN" ]]; then
  echo "ERROR: 找不到或不可执行: $YCSB_BIN"
  exit 1
fi
if [[ ! -f "$WORKLOAD" ]]; then
  echo "ERROR: 找不到 workload 文件: $WORKLOAD"
  exit 1
fi

# 1. Load 阶段 (如果数据已经Load过可以注释掉这一段)
echo ">>> [1/3] Loading Data..."
"$YCSB_BIN" load "$DB_TYPE" \
  -s -P "$WORKLOAD" \
  -p mongodb.url="$DB_URL" \
  -p recordcount="$RECORD_COUNT" \
  -threads "$THREADS"

# 2. Run 阶段
echo ">>> [2/3] Running Benchmark (${RUN_TIME_SEC}s)..."
echo ">>> Log file: $LOG_FILE"

# 注意：这里只记录日志，避免解析拖慢压测
"$YCSB_BIN" run "$DB_TYPE" \
  -s -P "$WORKLOAD" \
  -p mongodb.url="$DB_URL" \
  -p recordcount="$RECORD_COUNT" \
  -p operationcount="$OPERATION_COUNT" \
  -p maxexecutiontime="$RUN_TIME_SEC" \
  -p status.interval=1 \
  -threads "$THREADS" \
  2>&1 | tee "$LOG_FILE"

# 3. 数据清洗 (解析 Throughput, Read Latency, Update Latency)
echo ">>> [3/3] Parsing logs to CSV ($CSV_FILE)..."

echo "Time_Sec,Throughput_Ops_Sec,Read_Lat_ms,Update_Lat_ms" > "$CSV_FILE"

awk '
/current ops\/sec/ {
    time=0; tps=0; read_lat=0; update_lat=0;

    # 1) 提取时间和吞吐
    for(i=1; i<=NF; i++){
        if($i == "sec:")    time=$(i-1);
        if($i == "current") tps=$(i-1);
    }

    # 2) READ Avg
    n = split($0, partsR, "READ:");
    if (n > 1) {
        split(partsR[2], statsR, ",");
        for(k in statsR) {
            if (statsR[k] ~ /Avg=/) {
                split(statsR[k], v, "=");
                read_lat = v[2] / 1000.0;  # YCSB 一般是 us，转 ms
            }
        }
    }

    # 3) UPDATE Avg
    n = split($0, partsU, "UPDATE:");
    if (n > 1) {
        split(partsU[2], statsU, ",");
        for(k in statsU) {
            if (statsU[k] ~ /Avg=/) {
                split(statsU[k], v, "=");
                update_lat = v[2] / 1000.0;
            }
        }
    }

    # 4) 输出
    if (time != 0) {
        printf "%s,%.2f,%.3f,%.3f\n", time, tps, read_lat, update_lat
    }
}' "$LOG_FILE" >> "$CSV_FILE"

echo ">>> Done! Data saved to $CSV_FILE"
echo ">>> Head of CSV data:"
head -n 5 "$CSV_FILE"
