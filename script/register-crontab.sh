#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "[$(date +%H:%M:%S)] ${GREEN}$1${NC}"; }
error_exit() { echo -e "[$(date +%H:%M:%S)] ${RED}错误: $1${NC}"; exit 1; }

# 1. 权限断言与清理脚本寻桩
if [ "$EUID" -ne 0 ]; then
    error_exit "此注册脚本必须以 root 权限执行（用于将任务安全注入系统 crontab）。"
fi

BASE_DIR=$(readlink -f "$(dirname "$0")")
CLEAN_SCRIPT="${BASE_DIR}/clean-archive-wals.sh"

if [ ! -f "$CLEAN_SCRIPT" ]; then
    error_exit "未在同级目录下找到核心清理脚本 [clean-archive-wals.sh]！请先确认其存在。"
fi

log "1. 正在精准解析清理脚本的物理绝对路径..."
log "   -> 脚本绝对路径定格为: ${CLEAN_SCRIPT}"

# 2. 精准防重复注册检查：如果发现 crontab 里已经有了这个脚本的路径，则绝不重复写入
log "2. 正在对操作系统计划任务 (Crontab) 进行安全性扫描..."
if crontab -l 2>/dev/null | grep -q "${CLEAN_SCRIPT}"; then
    log "-> 该清理脚本此前已被注册过，放弃重复追加以保持系统计划任务整洁。"
else
    # 3. 安全注入：每天凌晨 02:00 准时由操作系统唤醒，执行高阶斩首式日志清理，输出日志重定向到绿色日志
    (crontab -l 2>/dev/null; echo "0 2 * * * ${CLEAN_SCRIPT} >> /opt/pgsql16/logfile 2>&1") | crontab -
    log "-> 自动化滚动计划任务安全注入完成。"
fi

log "������ 归档清理脚本已成功注册至系统 crontab 中，将在每日凌晨 02:00 滚动执行！"
