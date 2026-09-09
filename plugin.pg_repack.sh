#!/bin/bash

# ==========================================================
# ������ 目录结构说明
# ==========================================================
# deps/   - 编译依赖库 (openssl, zlib, icu, ncurses, libedit)
#          重要性: pg_repack 需要这些库的头文件和静态库
#
# dist/   - 最终产物目录 (PostgreSQL + 插件)
#          重要性: 包含已编译的 PostgreSQL，提供 pg_config 和头文件
#          注意: 只读，不写入，仅用于获取编译参数
#
# build/  - 编译工作目录
#          重要性: 存放 pg_repack 源代码和编译中间文件
#          每次编译会清理重建
#
# cache/  - 源代码包缓存
#          重要性: 避免重复下载，加速编译
# ==========================================================

# ==========================================================
# 默认版本 (可通过参数覆盖)
# ==========================================================
DEFAULT_PG_REPACK_VERSION="1.5.3"

# ==========================================================
# 插件元信息 (info 模式)
# ==========================================================
plugin_info() {
    local plugin_version="${1:-$DEFAULT_PG_REPACK_VERSION}"
    
    cat << EOF
{
  "name": "pg_repack",
  "version": "${plugin_version}",
  "preload": false,
  "config": {},
  "description": "在线表重组"
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
    echo "  $0 info                    # 使用默认版本 ${DEFAULT_PG_REPACK_VERSION}"
    echo "  $0 info 1.5.0              # 指定版本 1.5.0"
    echo "  $0 build host 16.15        # 使用默认版本 ${DEFAULT_PG_REPACK_VERSION}"
    echo "  $0 build host 16.15 1.5.0  # 指定版本 1.5.0"
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
    elif [ -n "$PG_REPACK_VERSION" ]; then
        echo "$PG_REPACK_VERSION"
    else
        echo "$DEFAULT_PG_REPACK_VERSION"
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
pg_repack_version=$(get_version "$3")

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

# ==========================================================
# 注意: pg_repack 的 tag 格式是 ver_1.5.3 (带 ver_ 前缀)
# ==========================================================
pg_repack_tar="pg_repack-${pg_repack_version}.tar.gz"

deps="$basedir/deps/$triple"
dist="$basedir/dist/$triple/$version/pgsql"
build="$basedir/build/$triple/$version/pg_repack_v${pg_repack_version}"
pg_src="$basedir/build/$triple/$version/postgresql"
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
# 编译 pg_repack
# ==========================================================
build_pg_repack() {
    log="$build/pg_repack.log"
    rm -f "$log"
    
    cd "$basedir/build/$triple/$version"
    rm -rf "pg_repack_v${pg_repack_version}"
    mkdir -p "pg_repack_v${pg_repack_version}"
    tar xf "$cache/$pg_repack_tar" -C "pg_repack_v${pg_repack_version}" --strip-components 1
    cd "pg_repack_v${pg_repack_version}"

    log_with_time "配置编译环境: pg_repack v${pg_repack_version}"
    log_with_time "   构建目录: $(pwd)"
    
    PG_CONFIG_BIN="$dist/bin/pg_config"
    
    # ==========================================================
    # 头文件路径定义
    #   $dist/include/                      → libpq-fe.h, postgres_ext.h
    #   $dist/include/postgresql/server/    → postgres.h, elog.h
    #   $dist/include/postgresql/internal/  → pqexpbuffer.h (pg_repack 需要)
    # ==========================================================
    PG_INCLUDE="$dist/include"
    PG_SERVER_INCLUDE="$dist/include/postgresql/server"
    PG_INTERNAL_INCLUDE="$dist/include/postgresql/internal"
    
    PGXS_FILE=$(find "$dist" -name "pgxs.mk" 2>/dev/null | head -1)
    if [ -z "$PGXS_FILE" ]; then
        log_with_time "错误: 找不到 pgxs.mk"
        exit 1
    fi
    
    export PATH="$dist/bin:$PATH"

    if [ "$triple" != "host" ]; then
        export CC="$triple-gcc"
        export STRIP="$triple-strip"
    else
        export CC="gcc"
        export STRIP="strip"
    fi

    log_with_time "   PG_CONFIG: $PG_CONFIG_BIN"
    log_with_time "   PGXS:      $PGXS_FILE"

    PG_CPPFLAGS="-I$PG_INCLUDE -I$PG_INTERNAL_INCLUDE -I$PG_SERVER_INCLUDE"
    
    if [ -d "$deps/usr/include" ]; then
        PG_CPPFLAGS="$PG_CPPFLAGS -I$deps/usr/include"
    fi

    log_with_time "   PG_CPPFLAGS: $PG_CPPFLAGS"

    # ==========================================================
    # 编译 bin/ 目录 (客户端工具)
    # 依赖: libpgcommon.a, libpgport.a, libpq
    # 使用 RPATH 指定运行时搜索便携版 libpq
    # 参考 portable-build.sh 使用 \$ORIGIN 转义
    # ==========================================================
    log_with_time "编译 pg_repack 客户端 (bin/) v${pg_repack_version}"
    
    if ! make -C bin USE_PGXS=1 \
            PG_CONFIG="$PG_CONFIG_BIN" \
            PGXS="$PGXS_FILE" \
            PG_CPPFLAGS="$PG_CPPFLAGS" \
            LDFLAGS="-L$pg_src/src/common -L$pg_src/src/port -L$dist/lib -Wl,-rpath=\$\$ORIGIN/../lib" \
            -j$numcpus >>"$log" 2>>"$log"; then
        log_with_time "bin/ 编译失败!"
        cat "$log" | tail -60
        exit 1
    fi
 
    # ==========================================================
    # 编译 lib/ 目录 (扩展库)
    # 不需要额外链接，由 PostgreSQL 服务器加载
    # ==========================================================
    log_with_time "编译 pg_repack 扩展 (lib/) v${pg_repack_version}"
    
    if ! make -C lib USE_PGXS=1 \
            PG_CONFIG="$PG_CONFIG_BIN" \
            PGXS="$PGXS_FILE" \
            PG_CPPFLAGS="$PG_CPPFLAGS" \
            -j$numcpus >>"$log" 2>>"$log"; then
        log_with_time "lib/ 编译失败!"
        cat "$log" | tail -60
        exit 1
    fi

    log_with_time "✅ 编译成功!"
    
    echo "$(pwd)"
}

# ==========================================================
# 打包 pg_repack
# ==========================================================
package_pg_repack() {
    local build_dir="$1"
    
    if [ -z "$build_dir" ] || [ ! -d "$build_dir" ]; then
        log_with_time "错误: 构建目录不存在: $build_dir"
        exit 1
    fi
    
    cd "$build_dir"

    PG_CONFIG_BIN="$dist/bin/pg_config"
    PGXS_FILE=$(find "$dist" -name "pgxs.mk" 2>/dev/null | head -1)

    pg_major=$(echo "$version" | cut -d. -f1)
    pkg_name="pg_repack-v${pg_repack_version}-pg${pg_major}.${arch}.tar.gz"
    pkg_path="$plugins_dir/$pkg_name"
    
    log_with_time "打包中: $pkg_path"

    # ==========================================================
    # 使用 make install 安装到临时目录
    # 覆盖所有路径变量，从源头避免套娃
    # ==========================================================
    tmp_dest="$build/tmp_install"
    rm -rf "$tmp_dest"
    mkdir -p "$tmp_dest"

    if ! make USE_PGXS=1 \
            PG_CONFIG="$PG_CONFIG_BIN" \
            PGXS="$PGXS_FILE" \
            bindir="$tmp_dest/bin" \
            pkglibdir="$tmp_dest/lib/postgresql" \
            datadir="$tmp_dest/share/postgresql" \
            sharedir="$tmp_dest/share/postgresql" \
            includedir_server="$tmp_dest/postgresql/include/server" \
            install >>"$build/pg_repack.log" 2>>"$build/pg_repack.log"; then
        log_with_time "安装失败!"
        cat "$build/pg_repack.log" | tail -50
        exit 1
    fi

    # ==========================================================
    # 直接切入 tmp_dest 根目录打包
    # ==========================================================
    cd "$tmp_dest"

    # 动态抓取存在的顶级短目录打包
    TAR_DIRS=""
    [ -d "lib" ] && TAR_DIRS="$TAR_DIRS lib"
    [ -d "share" ] && TAR_DIRS="$TAR_DIRS share"
    [ -d "bin" ] && TAR_DIRS="$TAR_DIRS bin"
    [ -d "include" ] && TAR_DIRS="$TAR_DIRS include"

    if [ -z "$TAR_DIRS" ]; then
        log_with_time "错误: 没有可打包的目录 (lib/share/bin/include 均不存在)"
        exit 1
    fi

    tar -czf "$pkg_path" $TAR_DIRS 2>/dev/null

    # ==========================================================
    # 依赖分析：遍历所有 .so 和 bin 程序
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
    
    # 遍历所有 .so 文件
    find "$tmp_check" -name "*.so" -type f 2>/dev/null | while read -r so; do
        rel_path="${so#$tmp_check/}"
        echo ""
        echo "������ $rel_path 依赖:"
        ldd "$so" 2>/dev/null | grep -E "=>|not found" || echo "   (无动态依赖或非 ELF 文件)"
    done
    
    # 遍历所有 bin 目录下的可执行文件
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

    # 保留临时目录用于调试
    # rm -rf "$tmp_dest"

    log_with_time "✅ 打包完成: $pkg_path"
    ls -lh "$pkg_path"
    
    echo ""
    echo "=========================================="
    echo "完成! pg_repack v${pg_repack_version} 已打包"
    echo "   包路径: $pkg_path"
    echo "   包内容:"
    tar -tzf "$pkg_path"
    echo "=========================================="
}

# ==========================================================
# build 模式: 主流程
# ==========================================================
log_with_time "开始构建 pg_repack v${pg_repack_version} (目标: $triple, PG: $version)"

download "$pg_repack_tar" "https://github.com/reorg/pg_repack/archive/refs/tags/ver_${pg_repack_version}.tar.gz"

build_dir=$(build_pg_repack)

package_pg_repack "$build_dir"
