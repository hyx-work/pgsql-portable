#!/bin/bash

# ==========================================================
# 缓存文件完整性验证脚本
# 用法: ./verify_cache.sh [--fix]
#   --fix  自动删除损坏文件
# ==========================================================

CACHE_DIR="/root/pgsql-portable/cache"
AUTO_FIX=false

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 解析参数
if [ "$1" == "--fix" ]; then
    AUTO_FIX=true
fi

# 检查目录
if [ ! -d "$CACHE_DIR" ]; then
    echo -e "${RED}错误: 缓存目录不存在: $CACHE_DIR${NC}"
    exit 1
fi

cd "$CACHE_DIR" || exit 1

echo ""
echo "=========================================="
echo "������ 缓存文件完整性验证"
echo "   目录: $CACHE_DIR"
if [ "$AUTO_FIX" = true ]; then
    echo -e "   ${YELLOW}模式: 自动修复 (损坏文件将被删除)${NC}"
else
    echo "   模式: 仅检查"
fi
echo "=========================================="
echo ""

# 统计变量
total=0
valid=0
corrupt=0
skip=0

# 测试函数
test_file() {
    local file="$1"
    
    # 检查文件是否存在且非空
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        return 2
    fi
    
    case "$file" in
        *.tar.gz|*.tgz)
            tar -tzf "$file" >/dev/null 2>&1
            return $?
            ;;
        *.tar.bz2|*.tbz2)
            tar -tjf "$file" >/dev/null 2>&1
            return $?
            ;;
        *.tar.xz|*.txz)
            tar -tJf "$file" >/dev/null 2>&1
            return $?
            ;;
        *)
            return 3  # 未知格式
            ;;
    esac
}

# 遍历所有文件（按名称排序）
for file in $(ls -1); do
    # 只处理文件，跳过目录
    [ -f "$file" ] || continue
    
    # 只处理压缩文件
    case "$file" in
        *.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.txz)
            ;;
        *)
            continue
            ;;
    esac
    
    total=$((total + 1))
    size=$(du -h "$file" 2>/dev/null | cut -f1)
    
    # 测试文件
    test_file "$file"
    result=$?
    
    case $result in
        0)
            count=$(tar -tf "$file" 2>/dev/null | wc -l)
            echo -e "${GREEN}✅ 完整${NC}  $file  ($size, $count 个文件)"
            valid=$((valid + 1))
            ;;
        2)
            echo -e "${RED}❌ 损坏${NC}  $file  ($size) - 文件为空或不存在"
            corrupt=$((corrupt + 1))
            if [ "$AUTO_FIX" = true ]; then
                echo -e "   ${YELLOW}→ 已删除${NC}"
                rm -f "$file"
            fi
            ;;
        3)
            echo -e "${YELLOW}⚠️ 跳过${NC}  $file  ($size) - 未知格式"
            skip=$((skip + 1))
            ;;
        *)
            echo -e "${RED}❌ 损坏${NC}  $file  ($size)"
            corrupt=$((corrupt + 1))
            if [ "$AUTO_FIX" = true ]; then
                echo -e "   ${YELLOW}→ 已删除${NC}"
                rm -f "$file"
            fi
            ;;
    esac
done

# ==========================================================
# 最终总结
# ==========================================================
echo ""
echo "=========================================="
echo "������ 验证结果汇总"
echo "=========================================="
echo -e "  ${BLUE}总文件数${NC}:  $total"
echo -e "  ${GREEN}完整${NC}:     $valid"
echo -e "  ${RED}损坏${NC}:     $corrupt"
echo -e "  ${YELLOW}跳过${NC}:     $skip"
echo "=========================================="

if [ $corrupt -eq 0 ] && [ $valid -gt 0 ]; then
    echo -e "${GREEN}✅ 所有文件完整，可以开始编译！${NC}"
    echo ""
    echo "编译命令:"
    echo "  ./plugin.postgis.sh build host 16.15 --with-gdal"
elif [ $valid -eq 0 ] && [ $total -eq 0 ]; then
    echo -e "${YELLOW}⚠️ 缓存目录为空，需要下载依赖${NC}"
    echo ""
    echo "下载命令:"
    echo "  ./plugin.postgis.sh build host 16.15 --with-gdal"
else
    echo -e "${RED}❌ 发现 $corrupt 个损坏文件${NC}"
    if [ "$AUTO_FIX" = true ]; then
        echo -e "${YELLOW}已自动删除损坏文件，请重新运行脚本下载${NC}"
        echo ""
        echo "重新下载命令:"
        echo "  ./plugin.postgis.sh build host 16.15 --with-gdal"
    else
        echo ""
        echo "修复方法:"
        echo "  1. 自动修复: $0 --fix"
        echo "  2. 手动删除: rm -f <损坏文件名>"
    fi
fi
echo "=========================================="
echo ""
