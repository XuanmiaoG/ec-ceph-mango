#!/bin/bash
set -euo pipefail

# ==============================================================================
#                   AI WORKFLOW BENCHMARK WITH OSD FAILURE
#                   Testing 4 EC Configurations: RS, Clay, LRC, OptLRC
# ==============================================================================

# 基础配置
OMPI_ALLOW_RUN_AS_ROOT=1
OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

# MLPerf 配置
MODEL="unet3d"
NUM_ACCELERATORS=2       # 减少到2张GPU加快测试（原4张）
ACCELERATOR_TYPE="a100"
CLIENT_MEMORY_GB=192     # 根据你的机器配置调整

# 数据集配置 - 优化后的快速测试版本
# 目标：数据量 > 内存，确保需要从 Ceph 读取
# 280GB 数据 ÷ 12 OSD ≈ 23GB/OSD，每个 OSD 都有足够数据
# 移除 1 个 OSD 会影响 8-10 个 OSD 的数据分布
# 每个文件约140MB，2000 个文件 ≈ 280GB
NUM_FILES_GENERATE=2000  # 约280GB，仍然 > 192GB 内存 (1.46x)
NUM_FILES_TEST=2000      # 全部读取以产生足够的内存压力

# 预计时间：
# - 数据生成：10-15 分钟
# - 单次 benchmark：20-30 分钟  
# - 总时间（4个配置）：约 2-2.5 小时

# 关键：启用 O_DIRECT 绕过 Page Cache
USE_ODIRECT=true

# OSD 故障配置
# 根据 MLPerf 文档建议：测试至少运行 30 分钟
# 在第 10 分钟注入故障，可以观察：
# - 前 10 分钟：正常性能基线
# - 10-30 分钟：故障后的降级性能
OSD_FAILURE_DELAY=600      # benchmark 运行 600 秒（10分钟）后注入故障
OSD_DOWN_OUT_INTERVAL=600  # 600秒后OSD自动标记为out

# 测试配置
TEST_CONFIGS=(
    "RS /mnt/xfs_rs pool_rs"
    "CLAY /mnt/xfs_clay pool_clay"
    "LRC /mnt/xfs_lrc pool_lrc"
)

# 结果目录
RESULTS_BASE="$HOME/mlperf_results"
METRICS_DIR="$HOME/metrics"
mkdir -p "$RESULTS_BASE" "$METRICS_DIR"

# ==============================================================================
#                           环境检查与安装
# ==============================================================================

echo ">>> [1/6] 检查并安装依赖..."

# 检查 MLPerf Storage 是否已安装
if ! command -v mlpstorage &> /dev/null; then
    echo "安装 MLPerf Storage..."
    
    # 安装系统依赖
    sudo apt-get update
    sudo apt-get install -y python3-pip python3-venv libopenmpi-dev openmpi-common git sysstat bc
    
    # 创建虚拟环境
    VENV_PATH="$HOME/.venvs/mlperf"
    if [ ! -d "$VENV_PATH" ]; then
        python3 -m venv "$VENV_PATH"
    fi
    source "$VENV_PATH/bin/activate"
    
    # 克隆并安装 MLPerf Storage
    STORAGE_DIR="$HOME/storage"
    if [ ! -d "$STORAGE_DIR" ]; then
        git clone -b v2.0 https://github.com/mlcommons/storage.git "$STORAGE_DIR"
    fi
    cd "$STORAGE_DIR"
    pip install --upgrade pip
    pip install -e .
else
    echo "MLPerf Storage 已安装"
    # 激活虚拟环境
    VENV_PATH="$HOME/.venvs/mlperf"
    if [ -d "$VENV_PATH" ]; then
        source "$VENV_PATH/bin/activate"
    fi
fi

# 检查 sar (sysstat)
if ! command -v sar &> /dev/null; then
    echo "安装 sysstat..."
    sudo apt-get install -y sysstat
    # 启用 sar 数据收集
    sudo sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat 2>/dev/null || true
fi

# ==============================================================================
#                           辅助函数
# ==============================================================================

# 启动性能监控
start_monitoring() {
    local ec_name=$1
    local csv_file="${METRICS_DIR}/metrics_${ec_name}.csv"
    local log_file="${METRICS_DIR}/sar_${ec_name}.log"
    
    echo "启动 sar 监控 -> $csv_file"
    
    # 使用 sar 替代 dstat（更稳定，无 Python 兼容性问题）
    # -n DEV: 网络统计
    # -u: CPU 使用率
    # -r: 内存使用
    # 1: 每秒采样一次
    sar -n DEV -u -r 1 > "$log_file" 2>&1 &
    local sar_pid=$!
    echo $sar_pid > "${METRICS_DIR}/sar_${ec_name}.pid"
    
    # 验证启动
    sleep 2
    if ps -p $sar_pid > /dev/null 2>&1; then
        echo "✓ sar 已启动 (PID: $sar_pid)"
    else
        echo "❌ sar 启动失败！查看: $log_file"
    fi
}

# 停止性能监控
stop_monitoring() {
    local ec_name=$1
    local pid_file="${METRICS_DIR}/sar_${ec_name}.pid"
    local log_file="${METRICS_DIR}/sar_${ec_name}.log"
    local csv_file="${METRICS_DIR}/metrics_${ec_name}.csv"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        echo "停止 sar (PID: $pid)"
        kill $pid 2>/dev/null || true
        wait $pid 2>/dev/null || true
        rm -f "$pid_file"
        
        # 转换 sar 输出为 CSV
        if [ -f "$log_file" ]; then
            echo "转换 sar 数据为 CSV..."
            python3 -c "
import re
import sys

# 读取 sar 日志
with open('$log_file', 'r') as f:
    lines = f.readlines()

# 写入 CSV
with open('$csv_file', 'w') as f:
    f.write('time,net_recv_KB/s,net_send_KB/s,cpu_user,cpu_system,cpu_idle,mem_used_pct\n')
    
    current_time = None
    net_data = {}
    cpu_data = None
    mem_data = None
    
    for line in lines:
        # 提取时间戳
        time_match = re.match(r'^(\d{2}:\d{2}:\d{2})', line)
        if time_match:
            current_time = time_match.group(1)
        
        # 提取网络数据（只取第一个网络接口的接收/发送）
        if 'rxkB/s' in line and current_time and 'IFACE' not in line:
            parts = line.split()
            if len(parts) >= 6 and parts[1] != 'IFACE':
                iface = parts[1]
                if iface not in net_data:  # 只取第一个接口
                    net_data[current_time] = (parts[4], parts[5])  # rxkB/s, txkB/s
        
        # 提取 CPU 数据
        if '%user' in line and current_time and 'CPU' not in line:
            parts = line.split()
            if len(parts) >= 8:
                cpu_data = (current_time, parts[2], parts[4], parts[7])  # user, system, idle
        
        # 提取内存数据
        if 'kbmemused' in line and current_time:
            parts = line.split()
            if len(parts) >= 4 and parts[1] != 'kbmemfree':
                mem_pct = parts[3]  # %memused
                
                # 如果有完整数据，写入一行
                if current_time in net_data and cpu_data and cpu_data[0] == current_time:
                    recv, send = net_data[current_time]
                    f.write(f'{current_time},{recv},{send},{cpu_data[1]},{cpu_data[2]},{cpu_data[3]},{mem_pct}\n')
" 2>/dev/null || echo "⚠️  CSV 转换失败"
            
            local line_count=$(wc -l < "$csv_file" 2>/dev/null || echo 0)
            echo "CSV 文件行数: $line_count"
        fi
    fi
}

# 注入 OSD 故障
inject_osd_failure() {
    local pool_name=$1
    local delay=$2
    
    echo "将在 ${delay} 秒后注入 OSD 故障..."
    sleep "$delay"
    
    # 获取该pool使用的第一个OSD
    local osd_id=$(sudo cephadm shell -- ceph osd map "$pool_name" test_object --format json 2>/dev/null | \
                   python3 -c "import sys, json; print(json.load(sys.stdin)['up'][0])" 2>/dev/null || echo "0")
    
    echo ">>> 注入故障: 标记 OSD.$osd_id 为 OUT"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - OSD.$osd_id marked OUT" >> "${METRICS_DIR}/failure_events.log"
    
    sudo cephadm shell -- ceph osd out "$osd_id"
    
    # 记录故障时间戳
    echo "$osd_id,$(date +%s)" >> "${METRICS_DIR}/failure_timestamps.csv"
}

# 清理缓存
clear_caches() {
    echo "清理所有节点的缓存（Page Cache + Dentries + Inodes）..."
    
    # 本地节点
    sync
    echo 3 > /proc/sys/vm/drop_caches
    
    # 远程节点
    for i in {0..13}; do
        ssh -o StrictHostKeyChecking=no root@node$i.cephai.isu-cloud.emulab.net \
            "sync; echo 3 > /proc/sys/vm/drop_caches" > /dev/null 2>&1 || true
    done
    
    echo "等待缓存完全清空..."
    sleep 5
}

# 验证内存压力
verify_memory_pressure() {
    local data_size_gb=$1
    local mem_size_gb=$2
    local ratio=$(echo "scale=2; $data_size_gb / $mem_size_gb" | bc)
    
    echo ">>> 内存压力验证:"
    echo "  数据集大小: ${data_size_gb}GB"
    echo "  系统内存: ${mem_size_gb}GB"
    echo "  比例: ${ratio}x"
    
    if (( $(echo "$ratio < 5" | bc -l) )); then
        echo "  ⚠️  警告: 数据集只有内存的 ${ratio}x，可能无法产生足够压力"
        echo "  建议: 数据集应该 ≥ 5x 内存 (${mem_size_gb}GB × 5 = $((mem_size_gb * 5))GB)"
    else
        echo "  ✓ 数据集足够大，可以产生内存压力"
    fi
}

# ==============================================================================
#                           主测试循环
# ==============================================================================

echo ""
echo "============================================================"
echo "开始 AI Workflow Benchmark 测试"
echo "模型: $MODEL"
echo "加速器: $NUM_ACCELERATORS × $ACCELERATOR_TYPE"
echo "测试配置: ${#TEST_CONFIGS[@]} 个 EC 编码"
echo "============================================================"
echo ""

# 初始化故障事件日志
echo "timestamp,event,osd_id" > "${METRICS_DIR}/failure_events.log"
echo "osd_id,timestamp" > "${METRICS_DIR}/failure_timestamps.csv"

for test_case in "${TEST_CONFIGS[@]}"; do
    set -- $test_case
    EC_NAME=$1
    MOUNT_POINT=$2
    POOL_NAME=$3
    
    DATA_DIR="${MOUNT_POINT}/mlperf_data"
    RESULT_DIR="${RESULTS_BASE}/results_${EC_NAME}"
    
    echo ""
    echo "###########################################################"
    echo ">>> 测试配置: $EC_NAME"
    echo ">>> 挂载点: $MOUNT_POINT"
    echo ">>> 存储池: $POOL_NAME"
    echo ">>> 数据目录: $DATA_DIR"
    echo "###########################################################"
    
    # 检查挂载点
    if ! mountpoint -q "$MOUNT_POINT"; then
        echo "❌ 错误: $MOUNT_POINT 未挂载！"
        continue
    fi
    
    # ------------------------------------------------------------------
    # 阶段 1: 数据生成（如果需要）
    # ------------------------------------------------------------------
    
    echo ">>> [2/6] 检查数据集..."
    
    # 确保数据目录存在
    if [ ! -d "$DATA_DIR" ]; then
        echo "创建数据目录: $DATA_DIR"
        mkdir -p "$DATA_DIR" || {
            echo "❌ 无法创建目录 $DATA_DIR"
            continue
        }
    fi
    
    echo "数据目录: $DATA_DIR"
    echo "正在统计现有文件数..."
    
    # 使用更安全的方法统计文件（处理空目录的情况）
    CURRENT_FILES=0
    if [ -d "$DATA_DIR" ] && [ -r "$DATA_DIR" ]; then
        # 使用 bash 数组来安全地统计文件
        shopt -s nullglob
        files=("$DATA_DIR"/*.npz)
        CURRENT_FILES=${#files[@]}
        shopt -u nullglob
    fi
    
    echo "当前文件数: $CURRENT_FILES / $NUM_FILES_GENERATE"
    
    if [ "$CURRENT_FILES" -lt "$NUM_FILES_GENERATE" ]; then
        echo ">>> 需要生成 $((NUM_FILES_GENERATE - CURRENT_FILES)) 个文件..."
        echo ">>> 预计时间: 30-60 分钟（约 $((NUM_FILES_GENERATE * 140 / 1024))GB 数据）"
        echo ">>> 开始时间: $(date)"
        
        # 清理旧数据
        if [ -d "$DATA_DIR" ] && [ "$(ls -A $DATA_DIR)" ]; then
            echo "清理旧数据..."
            rm -rf "${DATA_DIR:?}"/*
        fi
        
        # 激活虚拟环境
        if [ -f "$HOME/.venvs/mlperf/bin/activate" ]; then
            source "$HOME/.venvs/mlperf/bin/activate"
        fi
        
        mlpstorage training datagen \
            --model "$MODEL" \
            --num-processes 32 \
            --data-dir "$DATA_DIR" \
            --results-dir "$RESULT_DIR" \
            --param dataset.num_files_train="$NUM_FILES_GENERATE" \
            --allow-run-as-root \
            --oversubscribe \
            --verbose || {
                echo "❌ 数据生成失败！"
                continue
            }
        
        echo ">>> 数据生成完成: $(date)"
    else
        echo ">>> [2/6] 数据已存在 ($CURRENT_FILES 文件)，跳过生成"
    fi
    
    # ------------------------------------------------------------------
    # 阶段 2: 验证内存压力
    # ------------------------------------------------------------------
    
    echo ">>> [3/6] 验证内存压力..."
    DATA_SIZE_GB=$(echo "scale=2; $NUM_FILES_GENERATE * 140 / 1024" | bc)
    verify_memory_pressure "$DATA_SIZE_GB" "$CLIENT_MEMORY_GB"
    
    # ------------------------------------------------------------------
    # 阶段 3: 清理缓存
    # ------------------------------------------------------------------
    
    echo ">>> [4/6] 清理缓存..."
    clear_caches
    sleep 10
    
    # ------------------------------------------------------------------
    # 阶段 4: 启动监控
    # ------------------------------------------------------------------
    
    echo ">>> [5/6] 启动性能监控..."
    start_monitoring "$EC_NAME"
    
    # ------------------------------------------------------------------
    # 阶段 5: 后台注入 OSD 故障
    # ------------------------------------------------------------------
    
    echo ">>> [6/6] 配置 OSD 故障注入 (${OSD_FAILURE_DELAY}秒后)..."
    inject_osd_failure "$POOL_NAME" "$OSD_FAILURE_DELAY" &
    FAILURE_PID=$!
    
    # ------------------------------------------------------------------
    # 阶段 6: 运行 Benchmark
    # ------------------------------------------------------------------
    
    echo ">>> [7/7] 运行 Benchmark (启用 O_DIRECT)..."
    echo "==================== BENCHMARK START ===================="
    echo "开始时间: $(date)"
    
    # 构建参数列表
    BENCHMARK_PARAMS=(
        --open
        --model "$MODEL"
        --num-client-hosts 1
        --client-host-memory-in-gb "$CLIENT_MEMORY_GB"
        --num-accelerators "$NUM_ACCELERATORS"
        --accelerator-type "$ACCELERATOR_TYPE"
        --data-dir "$DATA_DIR"
        --results-dir "$RESULT_DIR"
        --param dataset.num_files_train="$NUM_FILES_TEST"
        --param runner.epochs=1
        --allow-run-as-root
        --oversubscribe
    )
    
    # 如果启用 O_DIRECT，添加参数
    if [ "$USE_ODIRECT" = true ]; then
        echo "✓ 启用 O_DIRECT (绕过 Page Cache)"
        BENCHMARK_PARAMS+=(--param reader.odirect=True)
    fi
    
    mlpstorage training run "${BENCHMARK_PARAMS[@]}" || true
    
    echo "结束时间: $(date)"
    echo "==================== BENCHMARK END ======================"
    
    # ------------------------------------------------------------------
    # 清理
    # ------------------------------------------------------------------
    
    # 等待故障注入完成
    wait $FAILURE_PID 2>/dev/null || true
    
    # 停止监控
    stop_monitoring "$EC_NAME"
    
    # 恢复 OSD
    echo ">>> 恢复所有 OSD 为 IN 状态..."
    for osd_id in $(sudo cephadm shell -- ceph osd tree --format json 2>/dev/null | \
                    python3 -c "import sys, json; [print(x['id']) for x in json.load(sys.stdin)['nodes'] if x['type']=='osd']" 2>/dev/null); do
        sudo cephadm shell -- ceph osd in "$osd_id" 2>/dev/null || true
    done
    
    # 等待集群恢复
    echo ">>> 等待集群恢复健康状态..."
    for i in {1..30}; do
        health=$(sudo cephadm shell -- ceph health --format json 2>/dev/null | \
                 python3 -c "import sys, json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "UNKNOWN")
        echo "集群状态: $health"
        
        if [ "$health" = "HEALTH_OK" ]; then
            echo "✓ 集群已恢复"
            break
        fi
        sleep 10
    done
    
    echo ">>> 冷却 60 秒..."
    sleep 60
done

echo ""
echo "============================================================"
echo "🎉 所有测试完成！"
echo "============================================================"
echo ""
echo "结果位置:"
echo "  - Benchmark 结果: $RESULTS_BASE"
echo "  - 性能指标: $METRICS_DIR"
echo ""
echo "下一步: 运行绘图脚本分析结果"
echo "  python3 plot_results.py"
echo "============================================================"
