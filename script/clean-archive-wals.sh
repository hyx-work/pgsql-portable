#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "[$(date +%H:%M:%S)] ${GREEN}$1${NC}"; }
error_exit() { echo -e "[$(date +%H:%M:%S)] ${RED}错误: $1${NC}"; exit 1; }

# 1. 权限断言：为了安全调用 su 降权，此脚本由 root 的 crontab 定时触发
if [ "$EUID" -ne 0 ]; then
    error_exit "此运维清理脚本必须以 root 权限运行（用于通过 crontab 安全触发）。"
fi

# 2. 定义标准规范路径
INSTALL_DIR="/opt/pgsql16"
DATA_DIR="${INSTALL_DIR}/data"
ARCHIVE_DIR="${INSTALL_DIR}/archive_wals"
CLEANUP_TOOL="${INSTALL_DIR}/bin/pg_archivecleanup"

log "������ 开始执行 PostgreSQL 16 归档日志安全清理检查..."

# 3. 核心安全熔断：确保清理工具和数据目录真实存在，防止误抹盘
if [ ! -x "$CLEANUP_TOOL" ]; then
    error_exit "未找到核心清理工具: $CLEANUP_TOOL"
fi
if [ ! -d "$DATA_DIR" ]; then
    error_exit "未找到数据库数据目录: $DATA_DIR"
fi

# 4. ⚡【核心高阶动作】切换至 postgres 用户，寻找当前数据库最后落盘的、最安全的检查点 WAL 文件名
#    pg_archivecleanup 会以这个文件为分界线，向前斩首历史旧日志，向后完好保留。
SU_CMD="su -s /bin/bash postgres -c"
RESTART_WAL=$($SU_CMD "find ${DATA_DIR}/pg_wal -type f -not -name '*.history' -printf '%P\n' | sort | head -n 1")

if [ -z "$RESTART_WAL" ]; then
    error_exit "未能从当前活动运行的 pg_wal 中提取出有效的基准文件名，放弃清理以保安全。"
fi

log "⏱️ 当前活跃检查点基准线文件锁定为: ${RESTART_WAL}"
log "⏱️ 正在安全抹除此基准线之前的历史历史冗余归档日志..."

# 5. 执行安全斩首清理动作
if ! $SU_CMD "${CLEANUP_TOOL} ${ARCHIVE_DIR} ${RESTART_WAL}"; then
    error_exit "调用 pg_archivecleanup 执行物理清理时发生底层未知错误！"
fi

log "✨ 恭喜！当前基准线之前的旧归档日志已全部物理释放，磁盘空间已成功回收！"
