#!/bin/bash

# 定义颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "[$(date +%H:%M:%S)] ${GREEN}$1${NC}"
}

error_exit() {
    echo -e "[$(date +%H:%M:%S)] ${RED}错误: $1${NC}"
    # 发生错误时确保清理公共目录
    rm -rf /tmp/pg_test_env
    exit 1
}

# 1. 校验输入参数
if [ "$1" == "" -o "$2" == "" ]; then
    echo "使用方法: $0 <版本号> <架构>"
    echo "示例:     $0 16.15 x86_64"
    exit 1
fi

VERSION=$1
ARCH=$2

# 获取当前脚本所在绝对路径，用于精准定位便携包
BASE_DIR=$(readlink -f "$(dirname "$0")")
TARBALL="${BASE_DIR}/dist/host/${VERSION}/pgsql-${VERSION}-linux-${ARCH}.tar.xz"

if [ ! -f "$TARBALL" ]; then
    TARBALL=$(find "${BASE_DIR}/dist/" -name "pgsql-${VERSION}-linux-${ARCH}.tar.xz" | head -n 1)
fi

if [ -z "$TARBALL" -o ! -f "$TARBALL" ]; then
    error_exit "未找到目标便携包！请检查版本号 [${VERSION}] 和架构 [${ARCH}]。"
fi

# 【核心修复：在公共的 /tmp 下建立完全隔离、所有人均可访问的测试沙盒】
TEST_ENV="/tmp/pg_test_env"
log "1. 发现绿色便携包，正在公共目录 ${TEST_ENV} 中初始化降权沙盒..."
rm -rf "$TEST_ENV"
mkdir -p "$TEST_ENV"

# 解压到沙盒中
if ! tar -xf "$TARBALL" -C "$TEST_ENV/"; then
    error_exit "便携包解压失败！"
fi

TEST_DIR="${TEST_ENV}/pgsql"
cd "$TEST_DIR" || error_exit "解压目录结构异常。"

# 判断是否为 root 环境。如果是，自动将 /tmp 沙盒所属权移交给 nobody 突破 root 家目录封锁
RUN_AS=""
if [ "$EUID" -eq 0 ]; then
    log "⚠️ 检测到当前为 root 账户，正在公共沙盒中配置 nobody 用户的完全执行权限..."
    chown -R nobody:nobody "$TEST_ENV"
    # 使用绝对路径，确保 nobody 切换上下文后不会迷路
    RUN_AS="su -s /bin/bash nobody -c"
fi

log "2. 初始化独立的数据目录 (Data Cluster)..."
if [ -n "$RUN_AS" ]; then
    if ! $RUN_AS "${TEST_DIR}/bin/initdb -D ${TEST_DIR}/data -U postgres --locale=C >> ${TEST_DIR}/init.log 2>&1"; then
        cat init.log
        error_exit "降权初始化 (initdb) 失败！"
    fi
else
    if ! ./bin/initdb -D ./data -U postgres --locale=C >> init.log 2>&1; then
        cat init.log
        error_exit "数据库初始化 (initdb) 失败！"
    fi
fi

log "3. 正在自动修改数据库服务端口为 5416..."
sed -i 's/#port = 5432/port = 5416/g' ./data/postgresql.conf
sed -i 's/port = 5432/port = 5416/g' ./data/postgresql.conf

log "4. 绿色启动 PostgreSQL 服务 (监听端口: 5416)..."
if [ -n "$RUN_AS" ]; then
    if ! $RUN_AS "${TEST_DIR}/bin/pg_ctl -D ${TEST_DIR}/data -l ${TEST_DIR}/logfile start"; then
        cat ./logfile
        error_exit "降权启动 PostgreSQL 服务失败！"
    fi
else
    if ! ./bin/pg_ctl -D ./data -l ./logfile start; then
        cat ./logfile
        error_exit "PostgreSQL 启动服务失败！"
    fi
fi

# 等待确保服务完全就绪
sleep 2

log "5. 尝试通过 5416 端口进行本地连接与 SQL 测试..."
if ! ./bin/psql -h 127.0.0.1 -p 5416 -U postgres -d postgres -c "SELECT version(); SELECT '参数化沙盒降权 5416 端口测试成功!' AS status;"; then
    cat ./logfile
    if [ -n "$RUN_AS" ]; then $RUN_AS "${TEST_DIR}/bin/pg_ctl -D ${TEST_DIR}/data stop >/dev/null 2>&1"; else ./bin/pg_ctl -D ./data stop >/dev/null 2>&1; fi
    error_exit "数据库连接测试失败！"
fi

log "6. 测试完毕，正在安全关闭 PostgreSQL 服务..."
if [ -n "$RUN_AS" ]; then
    $RUN_AS "${TEST_DIR}/bin/pg_ctl -D ${TEST_DIR}/data stop"
else
    ./bin/pg_ctl -D ./data stop
fi

log "7. 深度清理公共临时沙盒环境..."
#rm -rf "$TEST_ENV"

log "✨ 恭喜！版本号 ${VERSION} [${ARCH}] 在 5416 端口的安全沙盒全自动测试圆满完成！"
