#!/bin/bash
# ==========================================================
# plugin.pg_cron.sh - pg_cron 插件编译脚本
# ==========================================================
# 目录结构:
#   deps/   - 编译依赖库 (openssl, zlib, icu, ncurses, libedit)
#   dist/   - 最终产物目录 (PostgreSQL + 插件)，只读
#   build/  - 编译工作目录，每次清理重建
#   cache/  - 源代码包缓存，避免重复下载
#
# 依赖 plugin.common.sh:
#   log_info / log_warn / log_error / log_success / log_section
#   run_or_die / verify_file / download / extract_source
#   detect_jobs / detect_arch / get_version
#   init_plugin_dirs / require_pg_config
#   analyze_dir / strip_package
#
# 打包流程: 下载 → 编译 → 安装 → strip → 依赖分析 → 打包
# ==========================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/plugin.common.sh"

# ==========================================================
# 默认版本 (可通过参数或环境变量覆盖)
# ==========================================================
DEFAULT_PG_CRON_VERSION="1.6.7"

# ==========================================================
# 插件元信息 (info 模式)
# ==========================================================
plugin_info() {
    local plugin_version="${1:-$DEFAULT_PG_CRON_VERSION}"

    cat << EOF
{
  "name": "pg_cron",
  "version": "${plugin_version}",
  "preload": true,
  "config": {
    "cron.database_name": "postgres"
  },
  "description": "定时任务调度器"
}
EOF
}

# ==========================================================
# 使用说明
# ==========================================================
show_usage() {
    cat << EOF
用法: $0 {info|build} [参数...]

模式:
  info [版本]                        - 返回插件元信息 (JSON格式)
  build <triple> <PG版本> [插件版本] [选项]  - 编译打包插件

选项:
  --jobs <n>                         - 并行编译数 (默认: CPU核心数)
  --no-strict                        - 依赖分析只报告不失败 (默认严格)

示例:
  $0 info                            # 使用默认版本 ${DEFAULT_PG_CRON_VERSION}
  $0 info 1.6.0                      # 指定版本 1.6.0
  $0 build host 16.15                # 使用默认版本 ${DEFAULT_PG_CRON_VERSION}
  $0 build host 16.15 1.6.0          # 指定版本 1.6.0
  $0 build host 16.15 --jobs 8       # 指定并行数
  $0 build x86_64-linux-gnu 16.15    # 交叉编译 x86_64
  $0 build aarch64-linux-gnu 16.15   # 交叉编译 ARM64
EOF
}

# ==========================================================
# 主入口: 模式分发
# ==========================================================
if [ "${1:-}" == "info" ]; then
    shift
    plugin_version=$(get_version "${1:-}" "PG_CRON_VERSION" "$DEFAULT_PG_CRON_VERSION")
    plugin_info "$plugin_version"
    exit 0
fi

if [ "${1:-}" == "build" ]; then
    shift
else
    if [ "${1:-}" == "" ] || [ "${1:-}" == "-h" ] || [ "${1:-}" == "--help" ]; then
        show_usage
        exit 1
    fi
fi

# ==========================================================
# build 模式: 参数解析
# ==========================================================
if [ "${1:-}" == "" ] || [ "${2:-}" == "" ]; then
    echo "错误: build 模式需要 <triple> 和 <PG版本>" >&2
    echo "" >&2
    show_usage
    exit 1
fi

triple=$1
version=$2
shift 2

# 可选插件版本 (三段式 x.y.z)
if [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pg_cron_version="$1"
    shift
else
    pg_cron_version=$(get_version "" "PG_CRON_VERSION" "$DEFAULT_PG_CRON_VERSION")
fi

# 其余选项
while [[ $# -gt 0 ]]; do
    case "$1" in
        --jobs)
            if [ -z "${2:-}" ]; then
                echo "错误: --jobs 需要一个参数" >&2
                exit 1
            fi
            JOBS="$2"
            shift 2
            ;;
        --no-strict)
            ANALYZE_STRICT=0
            shift
            ;;
        *)
            echo "错误: 未知选项: $1" >&2
            exit 1
            ;;
    esac
done

jobs=$(detect_jobs)

# ==========================================================
# 架构映射
# ==========================================================
arch=$(detect_arch "$triple") || {
    echo "错误: 不支持的目标平台: $triple" >&2
    exit 1
}

# ==========================================================
# 目录初始化 + PostgreSQL 检查
# ==========================================================
init_plugin_dirs "$SCRIPT_DIR" "$triple" "$version"
require_pg_config "$triple"

pg_cron_tar="pg_cron-${pg_cron_version}.tar.gz"

# ==========================================================
# 下载 pg_cron 源代码包
# ==========================================================
download_pg_cron() {
    download "$pg_cron_tar" \
        "https://github.com/citusdata/pg_cron/archive/refs/tags/v${pg_cron_version}.tar.gz"
}

# ==========================================================
# 解析 PostgreSQL 编译环境 (PG_CONFIG / PGXS / 头文件路径)
# ==========================================================
# 导出: PG_CONFIG_BIN PGXS_FILE PG_CPPFLAGS
resolve_pg_env() {
    PG_CONFIG_BIN="$DIST_DIR/bin/pg_config"

    if [ ! -x "$PG_CONFIG_BIN" ]; then
        log_error "pg_config 不可执行: $PG_CONFIG_BIN"
        exit 1
    fi

    local pg_include="$DIST_DIR/include"
    local pg_server_include="$DIST_DIR/include/postgresql/server"

    PGXS_FILE=$(find "$DIST_DIR" -name "pgxs.mk" 2>/dev/null | head -1)
    if [ -z "$PGXS_FILE" ]; then
        log_error "找不到 pgxs.mk (在 $DIST_DIR 下)"
        exit 1
    fi

    export PATH="$DIST_DIR/bin:$PATH"

    if [ "$triple" != "host" ]; then
        export CC="$triple-gcc"
        export STRIP="$triple-strip"
    else
        export CC="gcc"
        export STRIP="strip"
    fi

    PG_CPPFLAGS="-I$pg_include -I$pg_server_include -Iinclude"
    if [ -d "$DEPS_DIR/usr/include" ]; then
        PG_CPPFLAGS="$PG_CPPFLAGS -I$DEPS_DIR/usr/include"
    fi

    log_info "   PG_CONFIG:   $PG_CONFIG_BIN"
    log_info "   PGXS:        $PGXS_FILE"
    log_info "   PG_CPPFLAGS: $PG_CPPFLAGS"
}

# ==========================================================
# 编译 pg_cron
# ==========================================================
build_pg_cron() {
    local log="$BUILD_DIR/pg_cron.log"
    : >"$log"

    log_section "编译 pg_cron v${pg_cron_version}"

    local src_dir="$BUILD_DIR/pg_cron_v${pg_cron_version}"
    rm -rf "$src_dir"

    extract_source "$CACHE_DIR/$pg_cron_tar" "$src_dir" 1 \
        || { log_error "pg_cron 解压失败!"; exit 1; }

    cd "$src_dir"
    log_info "构建目录: $(pwd)"

    resolve_pg_env

    log_info "编译中: pg_cron v${pg_cron_version}"

    run_or_die "pg_cron make" "$log" \
        make USE_PGXS=1 \
            PG_CONFIG="$PG_CONFIG_BIN" \
            PGXS="$PGXS_FILE" \
            PG_CPPFLAGS="$PG_CPPFLAGS" \
            -j"$jobs"

    log_success "pg_cron 编译成功!"
}

# ==========================================================
# 打包 pg_cron
# ==========================================================
# 流程: make install → strip → 依赖分析 → 打包
package_pg_cron() {
    local pg_major
    pg_major=$(echo "$version" | cut -d. -f1)

    local pkg_name="pg_cron-v${pg_cron_version}-pg${pg_major}.${arch}.tar.gz"
    local pkg_path="$PLUGINS_DIR/$pkg_name"

    log_section "打包 pg_cron"
    log_info "目标: $pkg_path"

    resolve_pg_env

    # ------------------------------------------------------
    # 1. 安装到临时目录 (PGXS 标准布局)
    # ------------------------------------------------------
    local tmp_dest="$BUILD_DIR/tmp_install"
    rm -rf "$tmp_dest"
    mkdir -p "$tmp_dest"

    log_info "安装中..."

    run_or_die "pg_cron install" "$BUILD_DIR/pg_cron.log" \
        make USE_PGXS=1 \
            PG_CONFIG="$PG_CONFIG_BIN" \
            PGXS="$PGXS_FILE" \
            bindir="$tmp_dest/bin" \
            pkglibdir="$tmp_dest/lib/postgresql" \
            datadir="$tmp_dest/share/postgresql" \
            sharedir="$tmp_dest/share/postgresql" \
            includedir_server="$tmp_dest/include/postgresql/server" \
            install

    if [ ! -d "$tmp_dest" ] || [ -z "$(ls -A "$tmp_dest" 2>/dev/null)" ]; then
        log_error "安装目录为空: $tmp_dest"
        exit 1
    fi

    # ------------------------------------------------------
    # 2. strip 瘦身 (仅 .so)
    # ------------------------------------------------------
    if command -v strip >/dev/null 2>&1; then
        local so_count=0
        so_count=$(find "$tmp_dest/lib" -name "*.so*" -type f 2>/dev/null | wc -l)
        if [ "$so_count" -gt 0 ]; then
            log_info "strip 瘦身中 ($so_count 个 .so)..."
            find "$tmp_dest/lib" -name "*.so*" -type f \
                -exec strip --strip-unneeded {} \; 2>/dev/null || true
        fi
    else
        log_warn "strip 未找到，跳过瘦身"
    fi

    # ------------------------------------------------------
    # 3. 依赖分析 (打包之前, 严格模式)
    # ------------------------------------------------------
    
    # RPATH 修复
    fix_rpath "$tmp_dest" "lib/postgresql"
	
	log_info "依赖分析中..."
    if ! analyze_dir "$tmp_dest"; then
        log_error "依赖分析失败，放弃打包"
        exit 1
    fi

    # ------------------------------------------------------
    # 4. 进入安装目录打包
    # ------------------------------------------------------
    cd "$tmp_dest"

    local dirs=()
    for d in lib share bin include; do
        [ -d "$d" ] && dirs+=("$d")
    done

    if [ ${#dirs[@]} -eq 0 ]; then
        log_error "没有可打包的目录 (lib/share/bin/include 均不存在)"
        exit 1
    fi

    log_info "打包目录: ${dirs[*]}"

    tar -czf "$pkg_path" "${dirs[@]}"

    log_success "打包完成: $pkg_path"
    ls -lh "$pkg_path"

    # ------------------------------------------------------
    # 5. 完成信息
    # ------------------------------------------------------
    echo "" >&2
    echo "==========================================" >&2
    echo "完成! pg_cron v${pg_cron_version} 已打包" >&2
    echo "   包路径: $pkg_path" >&2
    echo "   包大小: $(du -h "$pkg_path" | cut -f1)" >&2
    echo "   包内容:" >&2
    tar -tzf "$pkg_path" >&2
    echo "==========================================" >&2
}

# ==========================================================
# build 模式: 主流程
# ==========================================================
log_section "开始构建 pg_cron v${pg_cron_version} (目标: $triple, PG: $version)"
log_info "并行编译数: $jobs"
log_info "依赖分析严格模式: ${ANALYZE_STRICT:-1}"

download_pg_cron

build_pg_cron

package_pg_cron