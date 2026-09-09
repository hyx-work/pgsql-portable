#!/bin/bash

# ==========================================================
# ⚙️ 目录结构说明
# ==========================================================
# deps/   - 编译依赖库 (openssl, zlib, icu, ncurses, libedit)
#          重要性: timescaledb 需要这些库的头文件和静态库
#
# dist/   - 最终产物目录 (PostgreSQL + 插件)
#          重要性: 包含已编译的 PostgreSQL，提供 pg_config 和头文件
#          注意: 只读，不写入，仅用于获取编译参数
#
# build/  - 编译工作目录
#          重要性: 存放 timescaledb 源代码和编译中间文件
#          每次编译会清理重建
#
# cache/  - 源代码包缓存
#          重要性: 避免重复下载，加速编译
# ==========================================================

# ==========================================================
# 默认版本 (可通过参数覆盖)
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
    echo "用法: $0 {info|build} [参数...]"
    echo ""
    echo "模式:"
    echo "  info [版本]                - 返回插件元信息 (JSON格式)"
    echo "  build <triple> <PG版本> [插件版本]  - 编译打包插件"
    echo ""
    echo "示例:"
    echo "  $0 info                    # 使用默认版本 ${DEFAULT_TIMESCALEDB_VERSION}"
    echo "  $0 info 2.16.0             # 指定版本 2.16.0"
    echo "  $0 build host 16.15        # 使用默认版本 ${DEFAULT_TIMESCALEDB_VERSION}"
    echo "  $0 build host 16.15 2.16.0 # 指定版本 2.16.0"
    echo "  $0 build x86_64-linux-gnu 16.15  # 交叉编译 x86_64"
    echo "  $0 build aarch64-linux-gnu 16.15 # 交叉编译 ARM64"
}

# ==========================================================
# 获取版本号 (优先级: 参数 > 环境变量 > 默认值)
# ==========================================================
get_version() {
    local version="${1:-}"
    if [ -n "$version" ]; then
        echo "$version"
    elif [ -n "$TIMESCALEDB_VERSION" ]; then
        echo "$TIMESCALEDB_VERSION"
    else
        echo "$DEFAULT_TIMESCALEDB_VERSION"
    fi
}

# ==========================================================
# 主入口: 模式分发
# ==========================================================
if [ "$1" == "info" ]; then
    shift
    plugin_version=$(get_version "$1")
    plugin_info "$plugin_version"
    exit 0
fi

if [ "$1" == "build" ]; then
    shift
else
    if [ "$1" == "" ] || [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
        show_usage
        exit 1
    fi
fi

# ==========================================================
# build 模式: 参数解析
# ==========================================================
if [ "$1" == "" ] || [ "$2" == "" ]; then
    echo "错误: build 模式需要 <triple> 和 <PG版本>"
    echo ""
    show_usage
    exit 1
fi

triple=$1
version=$2
timescaledb_version=$(get_version "$3")

numcpus=$(nproc --all)

# ==========================================================
# 架构映射
# ==========================================================
case $triple in
    x86_64-*linux*)
        arch=x86_64
        ;;
    aarch64-*linux*)
        arch=aarch64
        ;;
    s390x-*linux*)
        arch=s390x
        ;;
    arm-*linux*)
        arch=armv7l
        ;;
    host)
        arch=$(uname -m)
        ;;
    *)
        echo "错误: 不支持的目标平台: $triple"
        exit 1
        ;;
esac

basedir=$(dirname $(readlink -f $0))

timescaledb_tar="timescaledb-${timescaledb_version}.tar.gz"

deps="$basedir/deps/$triple"
dist="$basedir/dist/$triple/$version/pgsql"
build="$basedir/build/$triple/$version/timescaledb_v${timescaledb_version}"
cache="$basedir/cache"
plugins_dir="$basedir/dist/$triple/$version/plugins"

mkdir -p "$build" "$cache" "$plugins_dir"

if [ ! -f "$dist/bin/pg_config" ]; then
    echo "错误: 找不到 pg_config: $dist/bin/pg_config"
    echo "请先为 $triple 编译安装 PostgreSQL"
    exit 1
fi

log_with_time() {
    echo "[$(date +%H:%M:%S.%03N)] $1" >&2
}

# ==========================================================
# 通用下载函数
# ==========================================================
download() {
    if [ -f "$cache/$1" ]; then
        log_with_time "缓存命中: $1"
    else
        log_with_time "下载中: $1"
        log_with_time "目标 URL: $2"
        if ! curl -L -o "$cache/$1" "$2" --connect-timeout 60 --max-time 300 --retry 3 --retry-delay 2 --progress-bar; then
            log_with_time "下载失败: $1!"
            exit 1
        fi
        log_with_time "下载完成: $1"
    fi
}

# ==========================================================
# 下载 timescaledb 源代码包
# ==========================================================
download_timescaledb() {
    download "$timescaledb_tar" "https://github.com/timescale/timescaledb/archive/refs/tags/${timescaledb_version}.tar.gz"
}

# ==========================================================
# 编译 timescaledb (影子路径模式)
# ==========================================================
build_timescaledb() {
    log="$build/timescaledb.log"
    rm -f "$log"
    
    cd "$basedir/build/$triple/$version"
    rm -rf "timescaledb_v${timescaledb_version}"
    mkdir -p "timescaledb_v${timescaledb_version}"
    tar xf "$cache/$timescaledb_tar" -C "timescaledb_v${timescaledb_version}" --strip-components 1
    cd "timescaledb_v${timescaledb_version}"

    log_with_time "配置编译环境: timescaledb v${timescaledb_version}"
    log_with_time "   构建目录: $(pwd)"
    
    # 检查 CMake
    if ! command -v cmake &> /dev/null; then
        log_with_time "错误: 编译 timescaledb 需要宿主机安装 cmake ������️"
        exit 1
    fi

    log_with_time "当前 PATH: $PATH"
    log_with_time "cmake 路径: $(which cmake 2>/dev/null || echo 'not found')"
    log_with_time "cmake 版本: $(cmake --version 2>/dev/null | head -1 || echo 'not found')"
    
    PG_CONFIG_BIN="$dist/bin/pg_config"
    export PATH="$dist/bin:$PATH"

    # 设置交叉编译环境变量 (与 pgsql-build.sh 风格一致)
    if [ "$triple" != "host" ]; then
        export CC="${triple}-gcc"
        export CXX="${triple}-g++"
        export STRIP="${triple}-strip"
        export PKG_CONFIG_PATH="$deps/usr/lib/pkgconfig"
        CMAKE_SYSTEM_FLAG="-DCMAKE_SYSTEM_NAME=Linux"
    else
        export CC="gcc"
        export CXX="g++"
        export STRIP="strip"
        CMAKE_SYSTEM_FLAG=""
    fi

    log_with_time "   PG_CONFIG: $PG_CONFIG_BIN"
    log_with_time "   CC: $CC"
    log_with_time "   CXX: $CXX"

    # ==========================================================
    # 核心修复: CMAKE_INSTALL_PREFIX 设置为 /
    # 让其内部安装路径（如 lib/postgresql）直接生成在根级，无套娃污染
    # 完美对齐 pg_cron、pg_repack 的临时路径打包规范
    # ==========================================================
    log_with_time "CMake 配置中: timescaledb v${timescaledb_version} (影子路径模式)"
    if ! cmake -B build \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=/ \
            -DPG_CONFIG="$PG_CONFIG_BIN" \
            -DCMAKE_PREFIX_PATH="$deps/usr" \
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
            ${CMAKE_SYSTEM_FLAG} \
            >>"$log" 2>>"$log"; then
        log_with_time "CMake 配置失败!"
        cat "$log" | tail -60
        exit 1
    fi

    log_with_time "编译中: timescaledb v${timescaledb_version}"
    if ! cmake --build build -j $numcpus >>"$log" 2>>"$log"; then
        log_with_time "编译失败!"
        cat "$log" | tail -60
        exit 1
    fi

    log_with_time "✅ 编译成功!"
    
    # 返回构建目录
    echo "$(pwd)/build"
}

# ==========================================================
# 打包 timescaledb (使用 DESTDIR 影子安装)
# ==========================================================
package_timescaledb() {
    local build_dir="$1"
    
    if [ -z "$build_dir" ] || [ ! -d "$build_dir" ]; then
        log_with_time "错误: 构建目录不存在: $build_dir"
        exit 1
    fi
    
    cd "$build_dir"

    pg_major=$(echo "$version" | cut -d. -f1)
    pkg_name="timescaledb-v${timescaledb_version}-pg${pg_major}.${arch}.tar.gz"
    pkg_path="$plugins_dir/$pkg_name"
    
    log_with_time "打包中: $pkg_path"

    # ==========================================================
    # 核心修复: 利用 env DESTDIR 环境变量无损重定向到 tmp_dest 
    # 标准 CMake 影子拦截语法，完美避开小写参数兼容错误
    # ==========================================================
    tmp_dest="$build/tmp_install"
    rm -rf "$tmp_dest"
    mkdir -p "$tmp_dest"

    if ! env DESTDIR="$tmp_dest" cmake --install . >>"$build/timescaledb.log" 2>>"$build/timescaledb.log"; then
        log_with_time "安装失败!"
        cat "$build/timescaledb.log" | tail -50
        exit 1
    fi

    # ==========================================================
    # 进入临时目录打包 (由于 PREFIX 是 /，此时 lib 和 share 直接存在于顶层)
    # ==========================================================
    cd "$tmp_dest"

    TAR_DIRS=""
    [ -d "lib" ] && TAR_DIRS="$TAR_DIRS lib"
    [ -d "share" ] && TAR_DIRS="$TAR_DIRS share"
    [ -d "bin" ] && TAR_DIRS="$TAR_DIRS bin"
    [ -d "include" ] && TAR_DIRS="$TAR_DIRS include"

    if [ -z "$TAR_DIRS" ]; then
        log_with_time "错误: 没有可打包的目录 (lib/share/bin/include 均不存在)"
        log_with_time "当前目录内容:"
        ls -la
        exit 1
    fi

    tar -czf "$pkg_path" $TAR_DIRS 2>/dev/null

    # ==========================================================
    # 依赖分析 (静态编译检查)
    # ==========================================================
    log_with_time "依赖分析中..."
    
    tmp_check="$build/pkg_check"
    rm -rf "$tmp_check"
    mkdir -p "$tmp_check"
    tar -xzf "$pkg_path" -C "$tmp_check"
    
    echo ""
    echo "=========================================="
    echo "������ 依赖检查:"
    echo "=========================================="
    
    find "$tmp_check" -name "*.so" -type f 2>/dev/null | while read -r so; do
        rel_path="${so#$tmp_check/}"
        echo ""
        echo "������ $rel_path 依赖:"
        ldd "$so" 2>/dev/null | grep -E "=>|not found" || echo "   (无动态依赖或非 ELF 文件)"
    done
    
    if [ -d "$tmp_check/bin" ]; then
        find "$tmp_check/bin" -type f -executable 2>/dev/null | while read -r bin; do
            rel_path="${bin#$tmp_check/}"
            echo ""
            echo "������ $rel_path 依赖:"
            ldd "$bin" 2>/dev/null | grep -E "=>|not found" || echo "   (无动态依赖或非 ELF 文件)"
            echo ""
            echo "������ $rel_path RPATH/RUNPATH:"
            readelf -d "$bin" 2>/dev/null | grep -E "RPATH|RUNPATH" || echo "   (未设置 RPATH/RUNPATH)"
        done
    fi
    
    rm -rf "$tmp_check"
    
    echo ""
    echo "=========================================="

    log_with_time "✅ 打包完成: $pkg_path"
    ls -lh "$pkg_path"
    
    echo ""
    echo "=========================================="
    echo "完成! timescaledb v${timescaledb_version} 已打包"
    echo "   包路径: $pkg_path"
    echo "   包内容:"
    tar -tzf "$pkg_path"
    echo "=========================================="
}

# ==========================================================
# build 模式: 主流程序
# ==========================================================
log_with_time "开始构建 timescaledb v${timescaledb_version} (目标: $triple, PG: $version)"

download_timescaledb

build_dir=$(build_timescaledb)

package_timescaledb "$build_dir"
