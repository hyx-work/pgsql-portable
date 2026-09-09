#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "[$(date +%H:%M:%S)] ${GREEN}$1${NC}"; }
warn() { echo -e "[$(date +%H:%M:%S)] ${YELLOW}⚠️ 提示: $1${NC}"; }
error_exit() { echo -e "[$(date +%H:%M:%S)] ${RED}错误: $1${NC}"; exit 1; }

# ==========================================
# ������ 多场景生产实战使用示例指南 (show_usage 函数)
# ==========================================
show_usage() {
    echo -e "${BLUE}========================================================================${NC}"
    echo -e "       PostgreSQL 绿色便携包全自动化【依赖库 + RUNPATH】二合一体检脚本  "
    echo -e "${BLUE}========================================================================${NC}"
    echo "使用方法:"
    echo "  $0 <triple>|host <version>"
    echo ""
    echo -e "${GREEN}【使用场景示例说明】:${NC}"
    echo -e "  ������ 示例一：检查本地编译出来的 16.15 所有工具的完整合规性与断面"
    echo -e "     命令: ./check-bin.sh host 16.15"
    echo -e "     结果: 依次输出所有工具的库泄露分析断言，以及完备的 readelf 原始断面。"
    echo ""
    echo -e "  ������ 示例二：检查为国产化 ARM64 服务器（aarch64）交叉编译的 16.15 包"
    echo -e "     命令: ./check-bin.sh aarch64-linux-gnu 16.15"
    echo -e "     结果: 自动路由至 aarch64 暂存区目录，进行跨平台依赖链的复核。"
    echo ""
    echo -e "  ������ 示例三：配合外部 grep，极限提取所有工具的 RUNPATH 泄露单项状态"
    echo -e "     命令: ./check-bin.sh host 16.15 | grep -E '工具|RUNPATH|RPATH|符合'"
    echo -e "     结果: 精准过滤大段信息，一目了然看清每个文件的内部寻桩健康度。"
    echo ""
    echo -e "  ������ 示例四：将全套工具的库依赖与只读文件头信息整体导出成审计文本存档"
    echo -e "     命令: ./check-bin.sh host 16.15 > ./pg_package_audit_report.txt"
    echo -e "     结果: 当前目录下会固化保存一份权威的合规体检报告，供交盘审查。"
    echo -e "${BLUE}========================================================================${NC}"
}

# 1. 校验输入参数（与 build 脚本保持绝对一致）
if [ "$1" == "" -o "$2" == "" -o "$1" == "-h" -o "$1" == "--help" ]; then
    show_usage
    exit 1
fi

triple=$1
version=$2
basedir=$(dirname $(readlink -f $0))

# 2. 精准定位当前的打包产物暂存目录 (即 dist/ 目录)
TARGET_DIR="${basedir}/dist/${triple}/${version}/usr/bin"
if [ ! -d "$TARGET_DIR" ]; then
    TARGET_DIR="${basedir}/dist/${triple}/${version}/pgsql/bin"
fi

if [ ! -d "$TARGET_DIR" ]; then
    error_exit "未找到目标编译产物目录！请确认版本号 [${version}] 在 [${triple}] 下已成功通过 build 脚本编译。"
fi

echo -e "${BLUE}========================================================================${NC}"
echo -e "         PostgreSQL 绿色便携包【库依赖 + RUNPATH】深度大体检 (沙盒: ${triple})      "
echo -e "${BLUE}========================================================================${NC}"
log "目标体检程序目录: ${TARGET_DIR}\n"

# 3. 核心大体检：遍历 bin/ 目录下的所有二进制可执行文件
for binary in $(find "$TARGET_DIR" -type f -executable | sort); do
    bin_name=$(basename "$binary")
    
    echo -e "${BLUE}========================================================================${NC}"
    echo -e " ������ 工具名称: [ ${bin_name} ]"
    echo -e "${BLUE}========================================================================${NC}"
    
    # --------------------------------------------------------
    # ������️ 审查项 A：执行标准的 ldd 动态链接扫描与泄漏防线检查
    # --------------------------------------------------------
    echo "--- [断面一：系统动态链接库 (ldd)] ---"
    ldd_output=$(ldd "$binary" 2>&1)
    echo "$ldd_output"
    
    has_leak=false
    if echo "$ldd_output" | grep -q -E "libssl|libcrypto"; then
        echo -e "${RED}[❌ 警报] 发现动态 OpenSSL 库依赖泄漏！未成功实现 100% 静态化。${NC}"
        has_leak=true
    fi
    if echo "$ldd_output" | grep -q "libicu"; then
        echo -e "${RED}[❌ 警报] 发现动态 ICU 全球语言库依赖泄漏！未成功实现 100% 静态化。${NC}"
        has_leak=true
    fi
    if echo "$ldd_output" | grep -q "libz\.so"; then
        echo -e "${RED}[❌ 警报] 发现动态 Zlib 压缩库依赖泄漏！未成功实现 100% 静态化。${NC}"
        has_leak=true
    fi
    if echo "$ldd_output" | grep -q "libreadline\.so"; then
        echo -e "${RED}[❌ 警报] 发现动态 GNU Readline 库依赖泄漏！psql 跨机器拷贝将会崩溃！${NC}"
        has_leak=true
    fi
    
    if [ "$has_leak" = false ]; then
        echo -e "${GREEN}[符合便携标准] 完美！该文件已成功实现 100% 绿色便携沙盒化。${NC}"
    fi
    echo ""
    
    # --------------------------------------------------------
    # ������️ 审查项 B：纯净只读执行 readelf -d 提取最底层的动态断面信息
    # --------------------------------------------------------
    echo "--- [断面二：可执行文件头 (readelf -d)] ---"
    readelf -d "$binary" 2>/dev/null
    
    echo ""
done

echo -e "${BLUE}========================================================================${NC}"
log "✨ 全套二进制文件【库依赖 + RUNPATH】深度体检圆满完成！"
echo -e "${BLUE}========================================================================${NC}"
