#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "[$(date +%H:%M:%S)] ${GREEN}$1${NC}"; }
error_exit() { echo -e "[$(date +%H:%M:%S)] ${RED}错误: $1${NC}"; exit 1; }

# 1. 权限校验
if [ "$EUID" -ne 0 ]; then
    error_exit "此备份脚本必须以 root 权限运行（用于通过 crontab 触发与跨目录属权管理）。"
fi

# 2. 路径定义
INSTALL_DIR="/opt/pgsql16"
BACKUP_DIR="${INSTALL_DIR}/backup_bases"
NOW_TIME=$(date +%Y%m%d_%H%M%S)
TARGET_PORT=5416

log "������ 开始执行 PostgreSQL 16 生产在线物理全量备份..."

# 创建全量备份存放目录
mkdir -p "$BACKUP_DIR"
chown -R postgres:postgres "$BACKUP_DIR"

# 3. ⚡【核心动作】调用高级 pg_basebackup 工具，在数据库完全不中断业务的情况下执行流式备份
SU_CMD="su -s /bin/bash postgres -c"
log "⏱️ 正在通过端口 ${TARGET_PORT} 进行非交互式在线全量基础快照抓取..."

if ! $SU_CMD "${INSTALL_DIR}/bin/pg_basebackup -h 127.0.0.1 -p ${TARGET_PORT} -U postgres -D - -Ft -X fetch 2>>${INSTALL_DIR}/logfile | xz -z -6 > ${BACKUP_DIR}/pg_base_${NOW_TIME}.tar.xz"; then
    error_exit "在线全量基础快照抓取失败！请查看 ${INSTALL_DIR}/logfile"
fi

# 4. 固化权限，清理 7 天前的历史老物理全量包，防止吃满磁盘
chown postgres:postgres "${BACKUP_DIR}/pg_base_${NOW_TIME}.tar.xz"
find "$BACKUP_DIR" -name "pg_base_*.tar.xz" -mtime +7 -exec rm -f {} \;

log "✨ 恭喜！物理全量基础快照备份圆满成功！"
log "   ������ 压缩快照已存盘为: ${BACKUP_DIR}/pg_base_${NOW_TIME}.tar.xz (已自动配置7天滚动清理)"
