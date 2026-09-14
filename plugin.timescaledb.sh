#!/bin/bash
# ==========================================================
# plugin.timescaledb.sh - TimescaleDB 插件编译脚本
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
# 打包流程: 下载 → cmake 配置 → cmake 编译 → DESTDIR 安装 → strip → 依赖分析 → 打包
#
# 注意: 使用 CMake，CMAKE_INSTALL_PREFIX=/ + DESTDIR 影子安装，
#       让内部路径 (lib/postgresql 等) 直接生成在临时目录顶层
# ==========================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/plugin.common.sh"

# ==========================================================
# 默认版本 (可通过参数或环境变量覆盖)
# ==========================================================
DEFAULT_TIMESCALEDB_VERSION="2.29.2"

# ==========================================================
# 插件元信息 (info 模式)
# ==========================================================
plugin_info() {
    local plugin_version="${1:-$DEFAULT_TIMESCALEDB_VERSION}"

    cat << EOF
{
  "name": "timescaledb",
  "version": "${plugin_version}",
  "preload": true,
  "config": {
    "timescaledb.max_background_workers": 8,
    "timescaledb.telemetry_level": "off"
  },
  "description": "时间序列数据优化的 PostgreSQL 扩展"
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
  $0 info                            # 使用默认版本 ${DEFAULT_TIMESCALEDB_VERSION}
  $0 info 2.16.0                     # 指定版本 2.16.0
  $0 build host 16.15                # 使用默认版本 ${DEFAULT_TIMESCALEDB_VERSION}
  $0 build host 16.15 2.16.0         # 指定版本 2.16.0
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
    plugin_version=$(get_version "${1:-}" "TIMESCALEDB_VERSION" "$DEFAULT_TIMESCALEDB_VERSION")
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
    timescaledb_version="$1"
    shift
else
    timescaledb_version=$(get_version "" "TIMESCALEDB_VERSION" "$DEFAULT_TIMESCALEDB_VERSION")
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

timescaledb_tar="timescaledb-${timescaledb_version}.tar.gz"

# ==========================================================
# 下载 TimescaleDB 源代码包
# ==========================================================
download_timescaledb() {
    download "$timescaledb_tar" \
        "https://github.com/timescale/timescaledb/archive/refs/tags/${timescaledb_version}.tar.gz"
}

# ==========================================================
# 检查 CMake 可用性
# ==========================================================
require_cmake() {
    if ! command -v cmake >/dev/null 2>&1; then
        log_error "编译 timescaledb 需要 cmake，但未找到"
        exit 1
    fi
    log_info "   cmake:       $(command -v cmake)"
    log_info "   cmake 版本:  $(cmake --version 2>/dev/null | head -1)"
}

# ==========================================================
# 解析 PostgreSQL 编译环境
# ==========================================================
# 导出: PG_CONFIG_BIN
resolve_pg_env() {
    PG_CONFIG_BIN="$DIST_DIR/bin/pg_config"

    if [ ! -x "$PG_CONFIG_BIN" ]; then
        log_error "pg_config 不可执行: $PG_CONFIG_BIN"
        exit 1
    fi

    export PATH="$DIST_DIR/bin:$PATH"

    if [ "$triple" != "host" ]; then
        export CC="${triple}-gcc"
        export CXX="${triple}-g++"
        export STRIP="${triple}-strip"
        export PKG_CONFIG_PATH="$DEPS_DIR/usr/lib/pkgconfig"
    else
        export CC="gcc"
        export CXX="g++"
        export STRIP="strip"
    fi

    log_info "   PG_CONFIG:   $PG_CONFIG_BIN"
    log_info "   CC:          $CC"
    log_info "   CXX:         $CXX"
}

# ==========================================================
# 编译 TimescaleDB
# ==========================================================
# 导出: TS_BUILD_DIR (CMake 构建目录)
build_timescaledb() {
    local log="$BUILD_DIR/timescaledb.log"
    : >"$log"

    log_section "编译 timescaledb v${timescaledb_version}"

    local src_dir="$BUILD_DIR/timescaledb_v${timescaledb_version}"
    rm -rf "$src_dir"

    extract_source "$CACHE_DIR/$timescaledb_tar" "$src_dir" 1 \
        || { log_error "timescaledb 解压失败!"; exit 1; }

    cd "$src_dir"
    log_info "构建目录: $(pwd)"

    require_cmake
    resolve_pg_env

    # ------------------------------------------------------
    # 交叉编译标志
    # ------------------------------------------------------
    local cmake_system_flag=""
    if [ "$triple" != "host" ]; then
        cmake_system_flag="-DCMAKE_SYSTEM_NAME=Linux"
    fi

    # ------------------------------------------------------
    # CMake 配置
    #   CMAKE_INSTALL_PREFIX=/ 让内部安装路径 (lib/postgresql 等)
    #   直接生成在 DESTDIR 顶层，方便后续打包
    # ------------------------------------------------------
    log_info "CMake 配置中..."

    run_or_die "timescaledb cmake configure" "$log" \
        cmake -B build \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=/ \
            -DPG_CONFIG="$PG_CONFIG_BIN" \
            -DCMAKE_PREFIX_PATH="$DEPS_DIR/usr" \
            -DUSE_OPENSSL=ON \
            -DUSE_ICU=ON \
            -DUSE_LZ4=OFF \
            -DUSE_ZSTD=OFF \
            -DSEND_TELEMETRY_DEFAULT=OFF \
            -DREGRESS_CHECKS=OFF \
            -DWARNINGS_AS_ERRORS=OFF \
            -DPG_LIBDIR="/lib/postgresql" \
            -DPG_PKGLIBDIR="/lib/postgresql" \
            -DPG_SHAREDIR="/share/postgresql" \
            -DPG_DATADIR="/share/postgresql" \
            $cmake_system_flag

    # ------------------------------------------------------
    # CMake 编译
    # ------------------------------------------------------
    log_info "编译中: timescaledb v${timescaledb_version}"

    run_or_die "timescaledb cmake build" "$log" \
        cmake --build build -j "$jobs"

    log_success "timescaledb 编译成功!"

    TS_BUILD_DIR="$src_dir/build"
}

# ==========================================================
# 打包 TimescaleDB
# ==========================================================
# 流程: cmake install (DESTDIR) → strip → 依赖分析 → 打包
package_timescaledb() {
    local pg_major
    pg_major=$(echo "$version" | cut -d. -f1)

    local pkg_name="timescaledb-v${timescaledb_version}-pg${pg_major}.${arch}.tar.gz"
    local pkg_path="$PLUGINS_DIR/$pkg_name"

    log_section "打包 timescaledb"
    log_info "目标: $pkg_path"

    if [ -z "${TS_BUILD_DIR:-}" ] || [ ! -d "$TS_BUILD_DIR" ]; then
        log_error "CMake 构建目录不存在: ${TS_BUILD_DIR:-<未设置>}"
        exit 1
    fi

    cd "$TS_BUILD_DIR"

    # ------------------------------------------------------
    # 1. DESTDIR 安装到临时目录
    # ------------------------------------------------------
    local tmp_dest="$BUILD_DIR/tmp_install"
    rm -rf "$tmp_dest"
    mkdir -p "$tmp_dest"

    log_info "安装中..."

    run_or_die "timescaledb cmake install" "$BUILD_DIR/timescaledb.log" \
        env DESTDIR="$tmp_dest" cmake --install .

    if [ ! -d "$tmp_dest" ] || [ -z "$(ls -A "$tmp_dest" 2>/dev/null)" ]; then
        log_error "安装目录为空: $tmp_dest"
        log_info "  当前目录内容:"
        ls -la "$tmp_dest" >&2
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
        log_info "  当前目录内容:"
        ls -la "$tmp_dest" >&2
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
    echo "完成! timescaledb v${timescaledb_version} 已打包" >&2
    echo "   包路径: $pkg_path" >&2
    echo "   包大小: $(du -h "$pkg_path" | cut -f1)" >&2
    echo "   包内容:" >&2
    tar -tzf "$pkg_path" >&2
    echo "==========================================" >&2
}

# ==========================================================
# build 模式: 主流程
# ==========================================================
log_section "开始构建 timescaledb v${timescaledb_version} (目标: $triple, PG: $version)"
log_info "并行编译数: $jobs"
log_info "依赖分析严格模式: ${ANALYZE_STRICT:-1}"

download_timescaledb

build_timescaledb

package_timescaledb