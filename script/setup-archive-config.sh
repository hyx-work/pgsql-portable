#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "[$(date +%H:%M:%S)] ${GREEN}$1${NC}"; }
error_exit() { echo -e "[$(date +%H:%M:%S)] ${RED}错误: $1${NC}"; exit 1; }

# 1. 权限与大版本路径检查
if [ "$EUID" -ne 0 ]; then
    error_exit "此配置脚本必须以 root 权限执行（用于创建 /opt 路径与重启 systemd 服务）。"
fi

CONFIG_FILE="/opt/pgsql16/data/postgresql.conf"
ARCHIVE_DIR="/opt/pgsql16/archive_wals"
SERVICE_NAME="pgsql-16"

# 2. 核心防呆熔断
if [ ! -f "$CONFIG_FILE" ]; then
    error_exit "未在标准化目录找到配置文件: $CONFIG_FILE，请确认 PostgreSQL 16 已经正确部署。"
fi

log "1. 正在创建专门的规范化物理归档文件夹..."
mkdir -p "$ARCHIVE_DIR"
chown -R postgres:postgres "$ARCHIVE_DIR"

# 3. 检查是否已经注入过归档参数，防止重复追加
log "2. 正在校验并注入生产级 WAL 归档控制参数..."
if grep -q "archive_command = 'cp %p /opt/pgsql16/archive_wals/%f'" "$CONFIG_FILE"; then
    log "-> 检测到该配置文件此前已经成功注入过归档参数，跳过追加动作。"
else
    cat >> "$CONFIG_FILE" << 'CONF_EOF'

# ==========================================
# ������ 生产级 WAL 日志归档配置
# ==========================================
wal_level = replica
archive_mode = on
# 每写完一个 16MB 的 WAL 日志，自动极速拷贝到绿色归档目录中
archive_command = 'cp %p /opt/pgsql16/archive_wals/%f'
CONF_EOF
    log "-> 生产级物理归档配置参数成功织入完成。"
fi

# 4. 通过 systemd 重启服务让归档在内核中激活生效
log "3. 正在通过 systemd 优雅重启 [${SERVICE_NAME}] 服务以使归档生效..."
if systemctl restart ${SERVICE_NAME}.service; then
    log "✨ 恭喜！PostgreSQL 16 内置 WAL 物理归档引擎已全自动化成功激活！"
    log "   ������ 活动日志实时落盘区 : ${ARCHIVE_DIR}"
else
    error_exit "数据库重启失败，请速去查看 /opt/pgsql16/logfile 日志原因！"
fi
