#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "[$(date +%H:%M:%S)] ${GREEN}$1${NC}"; }
warn() { echo -e "[$(date +%H:%M:%S)] ${YELLOW}警告: $1${NC}"; }
error_exit() { echo -e "[$(date +%H:%M:%S)] ${RED}错误: $1${NC}"; exit 1; }

# ==========================================
# ������ 多场景生产实战使用示例指南 (show_usage 函数)
# ==========================================
show_usage() {
    echo -e "${BLUE}========================================================================${NC}"
    echo -e "         PostgreSQL 绿色便携版大版本级全自动规范化部署脚本              "
    echo -e "${BLUE}========================================================================${NC}"
    echo -e "使用方法:"
    echo -e "  $0 <完整版本号> <架构>"
    echo -e ""
    echo -e "${GREEN}【使用场景示例说明】:${NC}"
    echo -e "  ������ 示例一：全新服务器首次安装部署（自动生成当前时间强密码）"
    echo -e "     命令: ./deploy-postgresql.sh 16.15 x86_64"
    echo -e "     结果: 部署至 /opt/pgsql16，注册系统自启服务 pgsql-16"
    echo -e ""
    echo -e "  ������ 示例二：【核心功能】保留现有老数据，仅无损升级/重装主程序"
    echo -e "     命令: ./deploy-postgresql.sh 16.15 x86_64"
    echo -e "     说明: 当检测到 /opt/pgsql16/data 存在时，在提示处【直接敲回车】。"
    echo -e "           系统会自动安全停机，保护老数据并纯净替换核心引擎，沿用老密码和所有库表！"
    echo -e ""
    echo -e "  ������ 示例三：已有老数据，但我不需要了，想要彻底清空进行“格盘干净重装”"
    echo -e "     命令: ./deploy-postgresql.sh 16.15 x86_64"
    echo -e "     说明: 在提示存在旧数据时，手动输入小写字母 【n】 并回车。"
    echo -e "           脚本会彻底抹除旧数据，重新 initdb 并生成一套全新时间戳密码。"
    echo -e ""
    echo -e "  ������ 示例四：针对信创国产化 ARM64 服务器（如鲲鹏、飞腾、麒麟系统）部署"
    echo -e "     命令: ./deploy-postgresql.sh 16.15 aarch64"
    echo -e "     说明: 自动在本地或 dist 归档中匹配 aarch64 后缀包，生成的服务名仍固定为 pgsql-16。"
    echo -e ""
    echo -e "  ������ 示例五：如何快速查阅过去已经部署成功的历史凭证与密码"
    echo -e "     说明: 脚本每次完工都会在当前同级生成独立带时间戳的部署凭证文件。"
    echo -e "           您可直接执行: ls -lh pgsql-deploy-16_*.txt 查看所有历史日志记录。"
    echo -e "${BLUE}========================================================================${NC}"
}

# 参数与权限断言
if [ "$1" == "" -o "$2" == "" -o "$1" == "-h" -o "$1" == "--help" ]; then
    show_usage
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    error_exit "必须以 root 权限执行此正式 system 部署脚本。"
fi

FULL_VERSION=$1
ARCH=$2
NOW_TIME=$(date +%Y%m%d_%H%M%S)
PG_PASSWORD=$(date +%Y%m%d%H%M%S)

# ==========================================
# ✂️ 【位置已调整修正】优先提取纯数字大版本号，彻底解决未定义先调用的 Bug
# ==========================================
if [[ "$FULL_VERSION" =~ ^([0-9]+)\. ]]; then
    MAJOR_VERSION="${BASH_REMATCH[1]}"
else
    error_exit "无法从参数 [${FULL_VERSION}] 中解析出有效的大版本号，请传入形如 16.15 或 17.0 的参数。"
fi

# 确保此时 MAJOR_VERSION 已经完全定义就位，后续路径与端口才能 100% 正确拼接，不再出现“16.”
TARGET_PORT="54${MAJOR_VERSION}"
INSTALL_DIR="/opt/pgsql${MAJOR_VERSION}"
DATA_DIR="${INSTALL_DIR}/data"
SERVICE_NAME="pgsql-${MAJOR_VERSION}"
TAR_NAME="pgsql-${FULL_VERSION}-linux-${ARCH}.tar.xz"

# ������ 【安全熔断】端口占用检查
if ss -tuln | grep -q ":${TARGET_PORT} "; then
    if ! systemctl is-active --quiet ${SERVICE_NAME}.service; then
        error_exit "端口 ${TARGET_PORT} 目前已被其他未知进程抢占！请先排查。"
    fi
fi

BASE_DIR=$(readlink -f "$(dirname "$0")")
TARBALL=""
if [ -f "${BASE_DIR}/${TAR_NAME}" ]; then
    TARBALL="${BASE_DIR}/${TAR_NAME}"
    log "������ [第一优先级] 在脚本同级目录成功匹配到便携包: ${TAR_NAME}"
fi
if [ -z "$TARBALL" ]; then
    DIST_MATCH=$(find "${BASE_DIR}/dist/" -name "${TAR_NAME}" 2>/dev/null | head -n 1)
    if [ -n "$DIST_MATCH" -a -f "$DIST_MATCH" ]; then
        TARBALL="$DIST_MATCH"
        log "������ [第二优先级] 未在同级找到，已在归档 dist 目录中匹配到: ${TARBALL}"
    fi
fi
if [ -z "$TARBALL" -o ! -f "$TARBALL" ]; then
    error_exit "未找到目标便携包 [${TAR_NAME}]！请确认文件位置。"
fi

log "1. 检查运行账户..."
if ! id "postgres" >/dev/null 2>&1; then
    useradd -r -m -s /bin/bash postgres
fi

# ������ 【数据安全与平滑更新切换逻辑】
NEED_INITDB=true

if [ -d "$DATA_DIR" ]; then
    warn "检测到标准化目录 ${DATA_DIR} 已存在旧的数据库数据文件！"
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    echo -e "������ 【推荐】极速原地更新主程序 (数据不动，仅覆程序): 直接敲【回车】(默认)"
    echo -e "������ 【格盘】彻底清空老数据重新安装                : 请输入【n】"
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    read -p "您的选择是? (Y/n): " KEEP_DATA
    
    if [ "$KEEP_DATA" != "n" ] && [ "$KEEP_DATA" != "N" ]; then
        log "【极速更新】选择：原地保护数据。正在建立临时解压沙盒..."
        TMP_UNPACK="/tmp/pg_unpack_$$"
        mkdir -p "$TMP_UNPACK"
        
        # 动作一：解压到临时目录
        log "  ⏱️ 解压 $TARBALL -> $TMP_UNPACK"
        if ! tar -xf "$TARBALL" -C "$TMP_UNPACK" --strip-components=1; then
            rm -rf "$TMP_UNPACK"
            error_exit "临时沙盒解压失败！"
        fi
        
        # 动作二：停止服务
        if systemctl is-active --quiet ${SERVICE_NAME}.service; then
            log "  ⏱️ 正在关闭当前服务 [${SERVICE_NAME}] 进行秒级切换..."
            systemctl stop ${SERVICE_NAME}.service
        fi
        
        log "  ⏱️ 正在执行纯二进制程序覆盖拷贝 (不触碰原有 data 目录)..."
        # 动作三：安全拷贝程序（原地保护 data，只覆盖 bin, lib, share）
        mkdir -p "$INSTALL_DIR"
        cp -rf "$TMP_UNPACK"/bin "$INSTALL_DIR"/
        cp -rf "$TMP_UNPACK"/lib "$INSTALL_DIR"/
        cp -rf "$TMP_UNPACK"/share "$INSTALL_DIR"/
        
        rm -rf "$TMP_UNPACK"
        NEED_INITDB=false
    else
        log "⚠️ 选择：彻底覆盖重装！正在安全关停并全盘抹除 ${INSTALL_DIR}..."
        systemctl stop ${SERVICE_NAME}.service >/dev/null 2>&1
        rm -rf "$INSTALL_DIR"
        mkdir -p "$INSTALL_DIR"
        tar -xf "$TARBALL" -C "$INSTALL_DIR" --strip-components=1
    fi
else
    mkdir -p "$INSTALL_DIR"
    tar -xf "$TARBALL" -C "$INSTALL_DIR" --strip-components=1
fi

# 统一更正安装目录属权给普通用户
chown -R postgres:postgres "$INSTALL_DIR"

if [ "$NEED_INITDB" = true ]; then
    log "2. 正在进行全新数据库群集安全初始化..."
    PW_FILE="${INSTALL_DIR}/.pgpass_init"
    echo "$PG_PASSWORD" > "$PW_FILE"
    chown postgres:postgres "$PW_FILE"
    chmod 600 "$PW_FILE"
    
    SU_CMD="su -s /bin/bash postgres -c"
    if ! $SU_CMD "${INSTALL_DIR}/bin/initdb -D ${DATA_DIR} -U postgres --locale=C --pwfile=${PW_FILE} -A scram-sha-256 >> ${INSTALL_DIR}/init.log 2>&1"; then
        cat "${INSTALL_DIR}/init.log"
        error_exit "数据库初始化失败！"
    fi
    rm -f "$PW_FILE"

    log "3. 正在配置生产参数..."
    sed -i "s/#port = 5432/port = ${TARGET_PORT}/g" "${DATA_DIR}/postgresql.conf"
    sed -i "s/port = 5432/port = ${TARGET_PORT}/g" "${DATA_DIR}/postgresql.conf"
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" "${DATA_DIR}/postgresql.conf"
    cat >> "${DATA_DIR}/pg_hba.conf" << 'EOL'
    host    all             all             0.0.0.0/0               scram-sha-256
    host    all             all             ::/0                    scram-sha-256
EOL
else
    # ==========================================================
    # ⚡ 严格按照您的标准执行，原地升级成功时打印原样提示
    # ==========================================================
    log "2. ������ 【原地无损更新成功】数据目录完好无损，跳过初始化，新版本引擎已成功就位！沿用您之前创建此库时的旧密码！"
    PG_PASSWORD="[沿用您之前创建此库时的旧密码]"
fi

log "4. 配置 systemd 管理服务 [${SERVICE_NAME}]..."
cat > /etc/systemd/system/${SERVICE_NAME}.service << EOL
[Unit]
Description=PostgreSQL ${MAJOR_VERSION} Standard Database Server
After=network.target

[Service]
Type=forking
User=postgres
Group=postgres
ExecStart=${INSTALL_DIR}/bin/pg_ctl -D ${DATA_DIR} -l ${INSTALL_DIR}/logfile start
ExecStop=${INSTALL_DIR}/bin/pg_ctl -D ${DATA_DIR} stop
ExecReload=${INSTALL_DIR}/bin/pg_ctl -D ${DATA_DIR} reload
TimeoutSec=300
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable ${SERVICE_NAME}.service >/dev/null 2>&1

# 动作四：重新拉起服务
log "5. 通过 systemd 重新拉起通用大版本服务 [${SERVICE_NAME}]..."
if ! systemctl start ${SERVICE_NAME}.service; then
    cat "${INSTALL_DIR}/logfile"
    error_exit "服务拉起失败！"
fi

sleep 2

log "6. 固化保存部署报告..."
LOCAL_INFO_FILE="${BASE_DIR}/pgsql-deploy-${MAJOR_VERSION}_${NOW_TIME}.txt"

cat > "$LOCAL_INFO_FILE" << INFO_EOF
--------------------------------------------------------
 部署/维护完成   : $(date "+%Y-%m-%d %H:%M:%S")
 安装与程序路径 : ${INSTALL_DIR}
 数据保存路径   : ${DATA_DIR}
 监听服务端口   : ${TARGET_PORT}
 Systemd 服务名 : ${SERVICE_NAME}
 运行主程序版本 : PostgreSQL ${FULL_VERSION}
 数据库超管账户 : postgres
 数据库连接密码 : ${PG_PASSWORD}
 维护状态类型   : $([ "$NEED_INITDB" = true ] && echo "全新整包安装" || echo "数据原地保持,仅覆程序平滑更新")
--------------------------------------------------------
������ 常用 systemd 管理运维指令 (保持大版本号不变)：
   查看服务状态: systemctl status ${SERVICE_NAME}
   停止数据库包: systemctl stop ${SERVICE_NAME}
   重启数据库包: systemctl restart ${SERVICE_NAME}
--------------------------------------------------------
⚠️ 如需完全移除该服务，请按顺序执行以下命令：
  1. 停止服务
  systemctl stop ${SERVICE_NAME}

  2. 禁用服务（开机不自启）
  systemctl disable ${SERVICE_NAME}

  3. 删除 systemd 服务文件
  rm -f /etc/systemd/system/${SERVICE_NAME}.service

  4. 重新加载 systemd 配置
  systemctl daemon-reload

  5. （可选）删除程序和数据目录（⚠️ 数据永久丢失，谨慎操作！）
  rm -rf ${INSTALL_DIR}
--------------------------------------------------------
INFO_EOF

# 保持原名拷贝
cp "$LOCAL_INFO_FILE" "${INSTALL_DIR}/"
chown postgres:postgres "${INSTALL_DIR}/$(basename "$LOCAL_INFO_FILE")"

cat "$LOCAL_INFO_FILE"
