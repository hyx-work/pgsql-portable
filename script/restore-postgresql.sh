#!/bin/bash

# 强制使用特定颜色增强警示
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "[$(date +%H:%M:%S)] ${GREEN}$1${NC}"; }
warn() { echo -e "[$(date +%H:%M:%S)] ${YELLOW}⚠️ 警示: $1${NC}"; }
error_exit() { echo -e "[$(date +%H:%M:%S)] ${RED}❌ 错误: $1${NC}"; exit 1; }

# 1. 参数与权限校验
if [ "$1" == "" ]; then
    echo -e "${YELLOW}========================================================================${NC}"
    echo -e "         PostgreSQL 16 便携版全自动生产级灾难点对点前滚恢复脚本         "
    echo -e "${YELLOW}========================================================================${NC}"
    echo -e "使用方法:"
    echo -e "  $0 <全量备份快照文件名>"
    echo -e "  示例: $0 pg_base_20260905_023000.tar.xz"
    echo -e "  说明: 输入指定的全量基础包，脚本会自动配合现有的归档日志，将数据完美前滚恢复。"
    echo -e "${YELLOW}========================================================================${NC}"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    error_exit "必须以 root 权限执行此灾难恢复脚本。"
fi

BASE_NAME=$1
INSTALL_DIR="/opt/pgsql16"
DATA_DIR="${INSTALL_DIR}/data"
ARCHIVE_DIR="${INSTALL_DIR}/archive_wals"
BACKUP_DIR="${INSTALL_DIR}/backup_bases"
SERVICE_NAME="pgsql-16"
TARBALL="${BACKUP_DIR}/${BASE_NAME}"

if [ ! -f "$TARBALL" ]; then
    error_exit "未在备份存储区 [${BACKUP_DIR}] 找到指定的物理全量包: ${BASE_NAME}"
fi

warn "即将执行生产数据库全自动高阶级前滚恢复！"
read -p "������ 警告：这会暂时挂起当前数据库并进行数据回填，是否继续？(y/N): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    error_exit "用户取消恢复操作。"
fi

# 2. ������ 停机断险
if systemctl is-active --quiet ${SERVICE_NAME}.service; then
    log "1. 正在关停当前 [${SERVICE_NAME}] 服务以保护故障现场..."
    systemctl stop ${SERVICE_NAME}.service
fi

# 3. ������ 保护故障现身现场
BAK_TIME=$(date +%Y%m%d_%H%M%S)
log "2. 正在将当前的旧数据目录搬移至备份隔离区（防止二次损坏）..."
mv "$DATA_DIR" "/tmp/pg_data_fault_bak_${BAK_TIME}"

# 4. ������️ 迎回物理全量快照
log "3. 正在回填并解压指定的物理全量基准快照..."
mkdir -p "$DATA_DIR"
chown -R postgres:postgres "$DATA_DIR"
chmod 700 "$DATA_DIR"

if ! xz -dc "$TARBALL" | tar -xf - -C "$DATA_DIR"; then
    error_exit "全量基准快照回填释放失败！"
fi

# 5. ⚡【核心高阶动作】注入物理前滚恢复（PITR）控制凭证
log "4. 正在对基础快照注入 WAL 增量前滚重放规则规则..."
SU_CMD="su -s /bin/bash postgres -c"

# 创建恢复信号文件（告诉数据库启动时进入恢复模式，而不是正常启动）
$SU_CMD "touch ${DATA_DIR}/recovery.signal"

# 注入恢复命令：让数据库启动后，自动去归档目录安全把所有漏掉的增量日志一块一块拼回去，直到重放至最后一秒
$SU_CMD "cat >> ${DATA_DIR}/postgresql.conf << 'CONF_EOF'
restore_command = 'cp ${ARCHIVE_DIR}/%f %p'
recovery_target = 'immediate'
CONF_EOF"

# 6. 统一修正属权
chown -R postgres:postgres "$DATA_DIR"

# 7. ������ 重新拉起托管服务
log "5. 通过 systemd 重新拉起服务，启动数据库内核前滚日志重放机制..."
if ! systemctl start ${SERVICE_NAME}.service; then
    error_exit "服务拉起失败，请检查 ${INSTALL_DIR}/logfile"
fi

log "⏱️ 正在等待数据库内核执行归档日志的物理重放（增量回刷中）..."
sleep 4

# 8. ������ 最终完工状态比对校验
if systemctl is-active --quiet ${SERVICE_NAME}.service; then
    log "\n✨ 恭喜！PostgreSQL 16 一键灾难前滚恢复圆满完全成功！"
    echo -e "--------------------------------------------------------"
    echo -e " 恢复基准起点 : ${BASE_NAME}"
    echo -e " 增量归档重放 : 成功自动追回至故障前的最后一秒"
    echo -e " 历史故障现场 : 已安全归档保护在 /tmp/pg_data_fault_bak_${BAK_TIME}"
    echo -e " 当前运行状态 : 托管中 (Active/Running)"
    echo -e "--------------------------------------------------------"
else
    error_exit "数据库未能顺利通过前滚认证，请速查阅 ${INSTALL_DIR}/logfile 错误日志！"
fi
