#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "[$(date +%H:%M:%S)] ${GREEN}$1${NC}"; }
warn() { echo -e "[$(date +%H:%M:%S)] ${YELLOW}⚠️ $1${NC}"; }
error_exit() { echo -e "[$(date +%H:%M:%S)] ${RED}❌ $1${NC}"; exit 1; }

# ==========================================
# 使用说明
# ==========================================
show_usage() {
    echo -e "${BLUE}========================================================================${NC}"
    echo -e "         PostgreSQL FULL 包 开箱即用部署脚本                            "
    echo -e "         包含完整配置、扩展和密码，解压即用                              "
    echo -e "${BLUE}========================================================================${NC}"
    echo -e "使用方法:"
    echo -e "  $0 <完整版本号> <架构> [-d <安装目录>]"
    echo -e ""
    echo -e "${GREEN}【选项】:${NC}"
    echo -e "  -d, --dir <目录>    指定安装目录 (默认: /opt/pgsql{大版本})"
    echo -e "  -h, --help          显示帮助"
    echo -e ""
    echo -e "${GREEN}【示例】:${NC}"
    echo -e "  $0 16.15 x86_64                              # 默认 /opt/pgsql16"
    echo -e "  $0 16.15 x86_64 -d /usr/local/pgsql16       # 指定目录"
    echo -e "  $0 16.15 aarch64 -d /opt/pgsql16"
    echo -e "  $0 15.8 x86_64 -d /data/pgsql15"
    echo -e ""
    echo -e "${GREEN}【部署行为】:${NC}"
    echo -e "  1. 解压 FULL 包到指定目录"
    echo -e "  2. data 目录已包含完整配置和扩展，无需 initdb"
    echo -e "  3. 密码已预生成，存储在 meta/password.txt"
    echo -e "  4. 自动创建 systemd 服务: pgsql-{大版本}"
    echo -e "  5. 自动设置 GDAL_DATA/PROJ_DATA 环境变量"
    echo -e "  6. 生成便携启动脚本 psql.sh"
    echo -e "  7. 检测到旧数据时交互式确认 (保留/清空)"
    echo -e "${BLUE}========================================================================${NC}"
}

# ==========================================
# 参数解析
# ==========================================
FULL_VERSION=""
ARCH=""
INSTALL_DIR=""

args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            warn "忽略未知选项: $1"
            shift
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done

if [ ${#args[@]} -ge 1 ]; then
    FULL_VERSION="${args[0]}"
fi
if [ ${#args[@]} -ge 2 ]; then
    ARCH="${args[1]}"
fi

if [ -z "$FULL_VERSION" ] || [ -z "$ARCH" ]; then
    show_usage
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    error_exit "必须以 root 权限执行此部署脚本"
fi

# ==========================================
# 解析大版本号
# ==========================================
if [[ "$FULL_VERSION" =~ ^([0-9]+)\. ]]; then
    MAJOR_VERSION="${BASH_REMATCH[1]}"
else
    error_exit "无法从参数 [${FULL_VERSION}] 中解析出有效的大版本号"
fi

TARGET_PORT="54${MAJOR_VERSION}"
SERVICE_NAME="pgsql-${MAJOR_VERSION}"
FULL_TAR_NAME="pgsql-full-${FULL_VERSION}-linux-${ARCH}.tar.xz"

# ==========================================
# 确定安装目录
# ==========================================
if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR="/opt/pgsql${MAJOR_VERSION}"
fi

DATA_DIR="${INSTALL_DIR}/data"
META_DIR="${INSTALL_DIR}/meta"
NOW_TIME=$(date +%Y%m%d_%H%M%S)

# ==========================================
# 查找 FULL 包
# ==========================================
BASE_DIR=$(readlink -f "$(dirname "$0")")
TARBALL=""

if [ -f "${BASE_DIR}/${FULL_TAR_NAME}" ]; then
    TARBALL="${BASE_DIR}/${FULL_TAR_NAME}"
    log "������ [第一优先级] 脚本同级目录: ${FULL_TAR_NAME}"
fi

if [ -z "$TARBALL" ]; then
    DIST_MATCH=$(find "${BASE_DIR}/dist/" -name "${FULL_TAR_NAME}" 2>/dev/null | head -n 1)
    if [ -n "$DIST_MATCH" -a -f "$DIST_MATCH" ]; then
        TARBALL="$DIST_MATCH"
        log "������ [第二优先级] dist 目录: ${TARBALL}"
    fi
fi

if [ -z "$TARBALL" -o ! -f "$TARBALL" ]; then
    error_exit "未找到 FULL 包 [${FULL_TAR_NAME}]！"
fi

# ==========================================
# 端口检查
# ==========================================
if ss -tuln | grep -q ":${TARGET_PORT} "; then
    if ! systemctl is-active --quiet ${SERVICE_NAME}.service 2>/dev/null; then
        error_exit "端口 ${TARGET_PORT} 已被其他进程占用！"
    fi
fi

# ==========================================
# 创建 postgres 用户
# ==========================================
log "1. 检查 postgres 用户..."
if ! id "postgres" >/dev/null 2>&1; then
    useradd -r -m -s /bin/bash postgres
    log "   ✅ 已创建 postgres 用户"
else
    log "   ✅ postgres 用户已存在"
fi

# ==========================================
# 数据目录处理 (交互式)
# ==========================================
NEED_EXTRACT=true

if [ -d "$DATA_DIR" ]; then
    warn "检测到已有数据目录: ${DATA_DIR}"
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    echo -e "【推荐】保留数据，仅更新程序 (FULL 包将覆盖 bin/lib/share) : 直接回车"
    echo -e "【清空】彻底删除旧数据，全新部署 (数据将永久丢失)           : 输入 n"
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    read -p "您的选择? (Y/n): " KEEP_DATA

    if [ "$KEEP_DATA" != "n" ] && [ "$KEEP_DATA" != "N" ]; then
        log "选择：保留数据，仅更新程序..."
        TMP_UNPACK="/tmp/pg_full_unpack_$$"
        mkdir -p "$TMP_UNPACK"

        log "   ⏳ 解压 FULL 包到临时目录..."
        if ! tar -xf "$TARBALL" -C "$TMP_UNPACK" --strip-components=1; then
            rm -rf "$TMP_UNPACK"
            error_exit "解压失败！"
        fi

        if systemctl is-active --quiet ${SERVICE_NAME}.service 2>/dev/null; then
            log "   ⏳ 停止服务 ${SERVICE_NAME}..."
            systemctl stop ${SERVICE_NAME}.service
        fi

        log "   ⏳ 覆盖程序文件 (保留 data 和 meta 目录)..."
        mkdir -p "$INSTALL_DIR"
        cp -rf "$TMP_UNPACK"/bin "$INSTALL_DIR"/
        cp -rf "$TMP_UNPACK"/lib "$INSTALL_DIR"/
        cp -rf "$TMP_UNPACK"/share "$INSTALL_DIR"/

        if [ -d "$TMP_UNPACK/meta" ]; then
            mkdir -p "$META_DIR"
            [ -f "$TMP_UNPACK/meta/README.md" ] && cp -f "$TMP_UNPACK/meta/README.md" "$META_DIR/"
            [ -f "$TMP_UNPACK/meta/manifest.json" ] && cp -f "$TMP_UNPACK/meta/manifest.json" "$META_DIR/"
            if [ ! -f "$META_DIR/password.txt" ] && [ -f "$TMP_UNPACK/meta/password.txt" ]; then
                cp -f "$TMP_UNPACK/meta/password.txt" "$META_DIR/"
            fi
        fi

        rm -rf "$TMP_UNPACK"
        NEED_EXTRACT=false
        log "   ✅ 程序更新完成，数据保留"
    else
        log "选择：彻底清空，全新部署..."
        systemctl stop ${SERVICE_NAME}.service 2>/dev/null
        rm -rf "$INSTALL_DIR"
        mkdir -p "$INSTALL_DIR"
    fi
fi

# ==========================================
# 解压 FULL 包 (全新安装)
# ==========================================
if [ "$NEED_EXTRACT" = true ]; then
    log "2. 解压 FULL 包到 ${INSTALL_DIR}..."
    mkdir -p "$INSTALL_DIR"
    if ! tar -xf "$TARBALL" -C "$INSTALL_DIR" --strip-components=1; then
        error_exit "解压 FULL 包失败！"
    fi
    log "   ✅ 解压完成"
fi

# ==========================================
# 设置目录权限
# ==========================================
log "3. 设置目录权限..."
chown -R postgres:postgres "$INSTALL_DIR"
log "   ✅ 权限设置完成"

# ==========================================
# 读取密码
# ==========================================
if [ -f "$META_DIR/password.txt" ]; then
    PG_PASSWORD=$(grep "^密码:" "$META_DIR/password.txt" | sed 's/密码: *//' | head -1)
    if [ -z "$PG_PASSWORD" ]; then
        PG_PASSWORD="[请查看 meta/password.txt]"
    fi
else
    PG_PASSWORD="[未找到密码文件，请查看 meta/password.txt]"
fi

# ==========================================
# 【新增】生成便携启动脚本 psql.sh
# ==========================================
log "4. 生成便携启动脚本 [psql.sh]..."

cat > "${INSTALL_DIR}/psql.sh" << 'PSQL_SH_EOF'
#!/bin/bash
# ==========================================================
# PostgreSQL 便携版启动脚本
# 自动设置 PROJ/GDAL 环境变量，无需手动配置
# ==========================================================
# 用法:
#   ./psql.sh start     启动
#   ./psql.sh stop      停止
#   ./psql.sh restart   重启
#   ./psql.sh status    查看状态
# ==========================================================

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PGDIR="$BASEDIR"

export GDAL_DATA="$PGDIR/share/gdal"
export PROJ_DATA="$PGDIR/share/proj"
export PROJ_LIB="$PGDIR/share/proj"
export LD_LIBRARY_PATH="$PGDIR/lib:$LD_LIBRARY_PATH"
export PATH="$PGDIR/bin:$PATH"

"$PGDIR/bin/pg_ctl" -D "$PGDIR/data" -l "$PGDIR/logfile" "$@"
PSQL_SH_EOF

chmod +x "${INSTALL_DIR}/psql.sh"
chown postgres:postgres "${INSTALL_DIR}/psql.sh"
log "   ✅ 便携启动脚本: ${INSTALL_DIR}/psql.sh"

# ==========================================
# 【修改】创建 systemd 服务（含 Environment 环境变量）
# ==========================================
log "5. 配置 systemd 服务 [${SERVICE_NAME}]..."

cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=PostgreSQL ${MAJOR_VERSION} FULL Edition Server (${INSTALL_DIR})
After=network.target

[Service]
Type=forking
User=postgres
Group=postgres

# ==========================================================
# 便携包环境变量（关键：让 GDAL/PROJ 找到数据）
# ==========================================================
Environment="GDAL_DATA=${INSTALL_DIR}/share/gdal"
Environment="PROJ_DATA=${INSTALL_DIR}/share/proj"
Environment="PROJ_LIB=${INSTALL_DIR}/share/proj"
Environment="LD_LIBRARY_PATH=${INSTALL_DIR}/lib"
Environment="PATH=${INSTALL_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

ExecStart=${INSTALL_DIR}/bin/pg_ctl -D ${DATA_DIR} -l ${INSTALL_DIR}/logfile start
ExecStop=${INSTALL_DIR}/bin/pg_ctl -D ${DATA_DIR} stop
ExecReload=${INSTALL_DIR}/bin/pg_ctl -D ${DATA_DIR} reload
TimeoutSec=300
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ${SERVICE_NAME}.service >/dev/null 2>&1
log "   ✅ systemd 服务配置完成 (含 GDAL/PROJ 环境变量)"

# ==========================================
# 启动服务
# ==========================================
log "6. 启动服务 [${SERVICE_NAME}]..."

if ! systemctl start ${SERVICE_NAME}.service; then
    cat "${INSTALL_DIR}/logfile" 2>/dev/null
    error_exit "服务启动失败！"
fi

sleep 2

if systemctl is-active --quiet ${SERVICE_NAME}.service; then
    log "   ✅ 服务启动成功 (端口: ${TARGET_PORT})"
else
    error_exit "服务启动后状态异常！"
fi

# ==========================================
# 生成部署报告
# ==========================================
log "7. 生成部署报告..."

if [ "$NEED_EXTRACT" = true ]; then
    # ---- 全新安装：写 /opt/pgsqlXX/deploy-info.txt ----
    LOCAL_INFO_FILE="${INSTALL_DIR}/deploy-info.txt"
else
    # ---- 原地更新：写 /opt/pgsqlXX/pgsql-full-deploy-XX_<时间戳>.txt ----
    LOCAL_INFO_FILE="${INSTALL_DIR}/pgsql-full-deploy-${MAJOR_VERSION}_${NOW_TIME}.txt"
fi

cat > "$LOCAL_INFO_FILE" << INFO_EOF
=========================================================
  FULL 包部署完成
=========================================================
 部署时间     : $(date "+%Y-%m-%d %H:%M:%S")
 安装目录     : ${INSTALL_DIR}
 数据目录     : ${DATA_DIR}
 元数据目录   : ${META_DIR}
 监听端口     : ${TARGET_PORT}
 Systemd 服务 : ${SERVICE_NAME}
 PostgreSQL   : ${FULL_VERSION}
 架构         : ${ARCH}
 超级用户     : postgres
 密码         : ${PG_PASSWORD}
 包类型       : FULL (开箱即用)
---------------------------------------------------------
 部署方式     : $([ "$NEED_EXTRACT" = true ] && echo "全新安装" || echo "原地更新(保留数据)")
---------------------------------------------------------
 [运维] 常用命令 (systemd):
  查看状态    : systemctl status ${SERVICE_NAME}
  停止服务    : systemctl stop ${SERVICE_NAME}
  重启服务    : systemctl restart ${SERVICE_NAME}
  查看日志    : tail -f ${INSTALL_DIR}/logfile
  查看密码    : cat ${META_DIR}/password.txt
  连接数据库  : ${INSTALL_DIR}/bin/psql -p ${TARGET_PORT} -U postgres -W
---------------------------------------------------------
 [便携] 启动脚本 (无 systemd 时使用):
  启动        : ${INSTALL_DIR}/psql.sh start
  停止        : ${INSTALL_DIR}/psql.sh stop
  重启        : ${INSTALL_DIR}/psql.sh restart
  查看状态    : ${INSTALL_DIR}/psql.sh status
---------------------------------------------------------
 [环境] systemd 自动设置的环境变量:
  GDAL_DATA       : ${INSTALL_DIR}/share/gdal
  PROJ_DATA       : ${INSTALL_DIR}/share/proj
  PROJ_LIB        : ${INSTALL_DIR}/share/proj
  LD_LIBRARY_PATH : ${INSTALL_DIR}/lib
---------------------------------------------------------
 [卸载] 完全移除:
  1. systemctl stop ${SERVICE_NAME}
  2. systemctl disable ${SERVICE_NAME}
  3. rm -f /etc/systemd/system/${SERVICE_NAME}.service
  4. systemctl daemon-reload
  5. rm -rf ${INSTALL_DIR}  (数据永久丢失)
=========================================================
INFO_EOF

chown postgres:postgres "$LOCAL_INFO_FILE"

# ==========================================
# 显示结果
# ==========================================
echo ""
echo -e "${BLUE}========================================================================${NC}"
echo -e "${GREEN}✨ FULL 包部署完成！${NC}"
echo -e "${BLUE}========================================================================${NC}"
echo -e "������ 安装目录: ${INSTALL_DIR}"
echo -e "������ 监听端口: ${TARGET_PORT}"
echo -e "������ 密码: ${PG_PASSWORD}"
echo -e "������ 密码文件: ${META_DIR}/password.txt"
echo -e "������ 部署报告: ${LOCAL_INFO_FILE}"
echo -e ""
echo -e "${GREEN}【快速验证】:${NC}"
echo -e "  systemctl status ${SERVICE_NAME}"
echo -e "  ${INSTALL_DIR}/bin/psql -p ${TARGET_PORT} -U postgres -W -c '\dx'"
echo -e ""
echo -e "${GREEN}【便携启动脚本】:${NC}"
echo -e "  启动: ${INSTALL_DIR}/psql.sh start"
echo -e "  停止: ${INSTALL_DIR}/psql.sh stop"
echo -e "${BLUE}========================================================================${NC}"

cat "$LOCAL_INFO_FILE"
