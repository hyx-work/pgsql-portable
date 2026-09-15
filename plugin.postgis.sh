#!/bin/bash

# ==========================================================
# ������ 目录结构说明
# ==========================================================
# deps/   - 编译依赖库 (GEOS, PROJ, GDAL, LibXML2, JSON-C, protobuf, protobuf-c, PCRE2, SQLite3, CURL)
#          重要性: 编译为动态库 (.so)，与 PostGIS 一起打包
#
# dist/   - 最终产物目录 (PostgreSQL + 插件)
#          重要性: 包含已编译的 PostgreSQL，提供 pg_config 和头文件
#          注意: 只读，不写入，仅用于获取编译参数
#
# build/  - 编译工作目录
#          重要性: 存放 PostGIS 和依赖库的源代码及编译中间文件
#          每次编译会清理重建
#
# cache/  - 源代码包缓存
#          重要性: 避免重复下载，加速编译
#          下载机制: 断点续传 (curl -C -) + 完整性验证 (tar -tf)
# ==========================================================


# ==========================================================
# 版本定义
# ==========================================================
DEFAULT_POSTGIS_VERSION="3.6.4"

# 依赖库版本 (与官方 Windows Bundle 保持一致)
GEOS_VERSION="3.14.1"
PROJ_VERSION="8.2.1"
GDAL_VERSION="3.9.2"
LIBXML2_VERSION="2.9.14"
JSON_C_VERSION="0.17"
PROTOBUF_VERSION="3.20.3"
PROTOBUF_C_VERSION="1.4.1"
PCRE2_VERSION="10.42"
SQLITE3_VERSION="3440000"
CURL_VERSION="8.4.0"

# ==========================================================
# 参数默认值
# ==========================================================
skip_deps=false
postgis_static=false
jobs=$(nproc --all 2>/dev/null || echo 4)

# ==========================================================
# 插件元信息 (info 模式)
# ==========================================================
plugin_info() {
    local plugin_version="${1:-$DEFAULT_POSTGIS_VERSION}"
    
    cat << EOF
{
  "name": "postgis",
  "version": "${plugin_version}",
  "preload": false,
  "config": {},
  "init_sql": "CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS postgis_raster; CREATE EXTENSION IF NOT EXISTS postgis_topology; CREATE EXTENSION IF NOT EXISTS address_standardizer; CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder; SELECT postgis_full_version();",
  "description": "地理空间数据库扩展 (PostGIS ${plugin_version})"
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
  info [版本]                - 返回插件元信息 (JSON格式)
  build <triple> <PG版本> [插件版本] [选项] - 编译打包插件

选项:
  --skip-deps              跳过依赖编译 (使用已存在的 deps)
  --static                 强制静态编译
  --jobs <n>               并行编译数 (默认: CPU核心数)

示例:
  $0 info                    # 使用默认版本 ${DEFAULT_POSTGIS_VERSION}
  $0 build host 16.15        # 完整编译 (含依赖)
  $0 build host 16.15 --skip-deps  # 跳过依赖编译
EOF
}

# ==========================================================
# 获取版本号 (优先级: 参数 > 环境变量 > 默认值)
# ==========================================================
get_version() {
    local version="${1:-}"
    if [ -n "$version" ]; then
        echo "$version"
    elif [ -n "$POSTGIS_VERSION" ]; then
        echo "$POSTGIS_VERSION"
    else
        echo "$DEFAULT_POSTGIS_VERSION"
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
shift 2

if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    postgis_version="$1"
    shift
else
    postgis_version="$DEFAULT_POSTGIS_VERSION"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-deps) skip_deps=true; shift ;;
        --static) postgis_static=true; shift ;;
        --jobs) jobs="$2"; shift 2 ;;
        *) echo "错误: 未知选项: $1"; exit 1 ;;
    esac
done

# ==========================================================
# 架构映射
# ==========================================================
case $triple in
    x86_64-*linux*) arch=x86_64 ;;
    aarch64-*linux*) arch=aarch64 ;;
    s390x-*linux*) arch=s390x ;;
    arm-*linux*) arch=armv7l ;;
    host) arch=$(uname -m) ;;
    *) echo "错误: 不支持的目标平台: $triple"; exit 1 ;;
esac

# ==========================================================
# 目录定义
# ==========================================================
basedir=$(readlink -f "$(dirname "$0")")

postgis_tar="postgis-${postgis_version}.tar.gz"
geos_tar="geos-${GEOS_VERSION}.tar.bz2"
proj_tar="proj-${PROJ_VERSION}.tar.gz"
gdal_tar="gdal-${GDAL_VERSION}.tar.xz"
libxml2_tar="libxml2-${LIBXML2_VERSION}.tar.xz"
json_c_tar="json-c-${JSON_C_VERSION}.tar.gz"
protobuf_tar="protobuf-all-${PROTOBUF_VERSION}.tar.gz"
protobuf_c_tar="protobuf-c-${PROTOBUF_C_VERSION}.tar.gz"
pcre2_tar="pcre2-${PCRE2_VERSION}.tar.gz"
sqlite3_tar="sqlite-autoconf-${SQLITE3_VERSION}.tar.gz"
curl_tar="curl-${CURL_VERSION}.tar.gz"

deps="$basedir/deps/$triple"
dist="$basedir/dist/$triple/$version/pgsql"
build="$basedir/build/$triple/$version/postgis_v${postgis_version}"
cache="$basedir/cache"
plugins_dir="$basedir/dist/$triple/$version/plugins"

mkdir -p "$build" "$cache" "$plugins_dir" "$deps/usr"

if [ ! -f "$dist/bin/pg_config" ]; then
    echo "错误: 找不到 pg_config: $dist/bin/pg_config"
    echo "请先为 $triple 编译安装 PostgreSQL"
    exit 1
fi

export LD_LIBRARY_PATH="$deps/usr/lib:$LD_LIBRARY_PATH"

# ==========================================================
# 日志函数 (全部输出到 stderr，避免污染 stdout)
# ==========================================================
log_info() {
    echo "[$(date +%H:%M:%S.%03N)] ℹ️ $1" >&2
}

log_success() {
    echo "[$(date +%H:%M:%S.%03N)] ✅ $1" >&2
}

log_warn() {
    echo "[$(date +%H:%M:%S.%03N)] ⚠️ $1" >&2
}

log_error() {
    echo "[$(date +%H:%M:%S.%03N)] ❌ $1" >&2
}

log_section() {
    echo "" >&2
    echo "==========================================" >&2
    echo "[$(date +%H:%M:%S.%03N)] ������ $1" >&2
    echo "==========================================" >&2
}

# ==========================================================
# 完整性验证函数
# ==========================================================
verify_file() {
    local file="$1"
    
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        return 1
    fi
    
    case "$file" in
        *.tar.gz|*.tgz)
            if gunzip -t "$file" 2>/dev/null && tar -tzf "$file" >/dev/null 2>&1; then
                return 0
            fi
            ;;
        *.tar.bz2|*.tbz2)
            if bzip2 -t "$file" 2>/dev/null && tar -tjf "$file" >/dev/null 2>&1; then
                return 0
            fi
            ;;
        *.tar.xz|*.txz)
            if xz -t "$file" 2>/dev/null && tar -tJf "$file" >/dev/null 2>&1; then
                return 0
            fi
            ;;
        *)
            if [ $(stat -c%s "$file" 2>/dev/null || echo "0") -gt 1024 ]; then
                return 0
            fi
            ;;
    esac
    
    return 1
}

# ==========================================================
# 通用下载函数 (断点续传 + 完整性验证)
# ==========================================================
download() {
    local filename="$1"
    local url="$2"
    local filepath="$cache/$filename"
    
    if [ -f "$filepath" ]; then
        if verify_file "$filepath"; then
            log_info "缓存命中: $filename"
            return 0
        else
            log_warn "缓存文件损坏，重新下载: $filename"
            rm -f "$filepath"
        fi
    fi
    
    log_info "下载中: $filename"
    log_info "目标 URL: $url"
    
    if ! curl -L -C - -o "$filepath" "$url" \
        --connect-timeout 60 \
        --max-time 600 \
        --retry 3 \
        --retry-delay 5 \
        --fail; then
        log_error "下载失败: $filename!"
        return 1
    fi
    
    if verify_file "$filepath"; then
        log_success "下载完成: $filename"
        return 0
    else
        log_error "下载的文件损坏: $filename"
        rm -f "$filepath"
        return 1
    fi
}

# ==========================================================
# 解压函数
# ==========================================================
extract_source() {
    local archive="$1"
    local target_dir="$2"
    local strip_components="${3:-1}"
    
    mkdir -p "$target_dir"
    
    case "$archive" in
        *.tar.gz|*.tgz)
            tar xf "$archive" -C "$target_dir" --strip-components="$strip_components" 2>/dev/null
            ;;
        *.tar.bz2|*.tbz2)
            tar xf "$archive" -C "$target_dir" --strip-components="$strip_components" 2>/dev/null
            ;;
        *.tar.xz|*.txz)
            tar xf "$archive" -C "$target_dir" --strip-components="$strip_components" 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
    
    if [ -z "$(ls -A "$target_dir" 2>/dev/null)" ]; then
        return 1
    fi
    return 0
}

# ==========================================================
# 下载所有依赖
# ==========================================================
download_deps() {
    log_section "下载依赖源码"
    
    local deps_list=(
        "$sqlite3_tar:https://sqlite.org/2023/sqlite-autoconf-${SQLITE3_VERSION}.tar.gz"
        "$curl_tar:https://curl.se/download/curl-${CURL_VERSION}.tar.gz"
        "$proj_tar:https://download.osgeo.org/proj/${proj_tar}"
        "$geos_tar:https://download.osgeo.org/geos/${geos_tar}"
        "$libxml2_tar:https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/$libxml2_tar"
        "$json_c_tar:https://github.com/json-c/json-c/archive/refs/tags/json-c-0.17-20230812.tar.gz"
        "$protobuf_tar:https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_VERSION}/protobuf-all-${PROTOBUF_VERSION}.tar.gz"
        "$protobuf_c_tar:https://github.com/protobuf-c/protobuf-c/releases/download/v${PROTOBUF_C_VERSION}/protobuf-c-${PROTOBUF_C_VERSION}.tar.gz"
        "$pcre2_tar:https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz"
        "$gdal_tar:https://download.osgeo.org/gdal/${GDAL_VERSION}/gdal-${GDAL_VERSION}.tar.xz"
        "$postgis_tar:https://download.osgeo.org/postgis/source/${postgis_tar}"
    )
    
    local failed=0
    
    for item in "${deps_list[@]}"; do
        local filename="${item%%:*}"
        local url="${item#*:}"
        
        if ! download "$filename" "$url"; then
            failed=$((failed + 1))
            log_error "下载失败: $filename"
        fi
    done
    
    if [ $failed -gt 0 ]; then
        log_error "$failed 个文件下载失败，请检查网络后重试"
        exit 1
    fi
    
    log_success "所有依赖源码下载完成并验证通过"
}

# ==========================================================
# 编译 SQLite3 (PROJ 依赖) - 动态库
# ==========================================================
build_sqlite3() {
    log_section "编译 SQLite3 ${SQLITE3_VERSION} (动态库)"
    
    if [ -f "$deps/usr/lib/libsqlite3.so" ]; then
        log_info "SQLite3 已存在，跳过编译"
        return 0
    fi
    
    local src_dir="$build/sqlite-autoconf-${SQLITE3_VERSION}"
    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    
    if ! extract_source "$cache/$sqlite3_tar" "$src_dir"; then
        log_error "SQLite3 解压失败！"
        exit 1
    fi
    
    cd "$src_dir" || exit 1
    
    local host_flag=""
    if [ "$triple" != "host" ]; then
        host_flag="--host=$triple"
        export CC="${triple}-gcc"
        export CXX="${triple}-g++"
    else
        export CC="gcc"
        export CXX="g++"
    fi
    
    export CFLAGS="-fPIC"
    export LDFLAGS="-Wl,-rpath,'\$ORIGIN' -Wl,--disable-new-dtags"
    
    ./configure \
        --prefix=/usr \
        $host_flag \
        --enable-shared \
        --disable-static \
        --disable-readline \
        >>"$build/sqlite3.log" 2>>"$build/sqlite3.log" || {
        log_error "SQLite3 configure 失败!"
        tail -30 "$build/sqlite3.log"
        exit 1
    }
    
    make -j "$jobs" >>"$build/sqlite3.log" 2>>"$build/sqlite3.log" || {
        log_error "SQLite3 make 失败!"
        tail -30 "$build/sqlite3.log"
        exit 1
    }
    
    make DESTDIR="$deps" install >>"$build/sqlite3.log" 2>>"$build/sqlite3.log" || {
        log_error "SQLite3 install 失败!"
        tail -30 "$build/sqlite3.log"
        exit 1
    }
    
    log_success "SQLite3 编译完成"
}

# ==========================================================
# 编译 CURL (PROJ 依赖) - 动态库
# ==========================================================
build_curl() {
    log_section "编译 CURL ${CURL_VERSION} (动态库)"
    
    if [ -f "$deps/usr/lib/libcurl.so" ]; then
        log_info "CURL 已存在，跳过编译"
        return 0
    fi
    
    local src_dir="$build/curl-${CURL_VERSION}"
    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    
    if ! extract_source "$cache/$curl_tar" "$src_dir"; then
        log_error "CURL 解压失败！"
        exit 1
    fi
    
    cd "$src_dir" || exit 1
    
    local host_flag=""
    if [ "$triple" != "host" ]; then
        host_flag="--host=$triple"
        export CC="${triple}-gcc"
        export CXX="${triple}-g++"
    else
        export CC="gcc"
        export CXX="g++"
    fi
    
    export CFLAGS="-fPIC"
    export LDFLAGS="-Wl,-rpath,'\$ORIGIN' -Wl,--disable-new-dtags"
    
    ./configure \
        --prefix=/usr \
        $host_flag \
        --enable-shared \
        --disable-static \
        --without-ssl \
        --without-zlib \
        --without-libssh2 \
        --without-librtmp \
        --without-libidn2 \
        --disable-ldap \
        --disable-ldaps \
        --disable-rtsp \
        --disable-dict \
        --disable-telnet \
        --disable-tftp \
        --disable-pop3 \
        --disable-imap \
        --disable-smtp \
        --disable-gopher \
        --disable-manual \
        --disable-libcurl-option \
        >>"$build/curl.log" 2>>"$build/curl.log" || {
        log_error "CURL configure 失败!"
        tail -30 "$build/curl.log"
        exit 1
    }
    
    make -j "$jobs" >>"$build/curl.log" 2>>"$build/curl.log" || {
        log_error "CURL make 失败!"
        tail -30 "$build/curl.log"
        exit 1
    }
    
    make DESTDIR="$deps" install >>"$build/curl.log" 2>>"$build/curl.log" || {
        log_error "CURL install 失败!"
        tail -30 "$build/curl.log"
        exit 1
    }
    
    log_success "CURL 编译完成"
}

# ==========================================================
# 编译 protobuf (protoc + libprotobuf) - 动态库
# ==========================================================
build_protobuf() {
    log_section "编译 protobuf ${PROTOBUF_VERSION} (动态库)"
    
    if [ -f "$deps/usr/lib/libprotobuf.so" ] && [ -f "$deps/usr/bin/protoc" ]; then
        log_info "protobuf 已存在，跳过编译"
        return 0
    fi
    
    local src_dir="$build/protobuf-${PROTOBUF_VERSION}"
    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    
    if ! extract_source "$cache/$protobuf_tar" "$src_dir"; then
        log_error "protobuf 解压失败！"
        exit 1
    fi
    
    cd "$src_dir" || exit 1
    
    local host_flag=""
    if [ "$triple" != "host" ]; then
        host_flag="--host=$triple"
        export CC="${triple}-gcc"
        export CXX="${triple}-g++"
    else
        export CC="gcc"
        export CXX="g++"
    fi
    
    export CFLAGS="-fPIC"
    export CXXFLAGS="-fPIC"
    export LDFLAGS="-Wl,-rpath,'\$ORIGIN' -Wl,--disable-new-dtags"
    
    local protobuf_jobs=$((jobs * 2))
    if [ "$protobuf_jobs" -gt 16 ]; then
        protobuf_jobs=16
    fi
    
    ./configure \
        --prefix=/usr \
        $host_flag \
        --enable-shared \
        --disable-static \
        >>"$build/protobuf.log" 2>>"$build/protobuf.log" || {
        log_error "protobuf configure 失败!"
        tail -30 "$build/protobuf.log"
        exit 1
    }
    
    make -j "$protobuf_jobs" >>"$build/protobuf.log" 2>>"$build/protobuf.log" || {
        log_error "protobuf make 失败!"
        tail -30 "$build/protobuf.log"
        exit 1
    }
    
    make DESTDIR="$deps" install >>"$build/protobuf.log" 2>>"$build/protobuf.log" || {
        log_error "protobuf install 失败!"
        tail -30 "$build/protobuf.log"
        exit 1
    }
    
    if [ ! -f "$deps/usr/lib/libprotobuf.so" ]; then
        log_error "protobuf 编译后未找到 libprotobuf.so"
        exit 1
    fi
    
    if [ ! -f "$deps/usr/bin/protoc" ]; then
        log_error "protobuf 编译后未找到 protoc"
        exit 1
    fi
    
    log_success "protobuf 编译完成"
}

# ==========================================================
# 编译 protobuf-c - 动态库
# ==========================================================
build_protobuf_c() {
    log_section "编译 protobuf-c ${PROTOBUF_C_VERSION} (动态库)"
    
    if [ -f "$deps/usr/lib/libprotobuf-c.so" ]; then
        log_info "protobuf-c 已存在，跳过编译"
        return 0
    fi
    
    if [ ! -f "$deps/usr/bin/protoc" ]; then
        log_warn "deps 中未找到 protoc，跳过 protobuf-c 编译"
        return 0
    fi
    
    local protoc_version=$("$deps/usr/bin/protoc" --version | awk '{print $2}')
    log_info "使用 deps 中的 protoc 版本: $protoc_version"
    
    local src_dir="$build/protobuf-c-${PROTOBUF_C_VERSION}"
    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    
    if ! extract_source "$cache/$protobuf_c_tar" "$src_dir"; then
        log_error "protobuf-c 解压失败！"
        exit 1
    fi
    
    cd "$src_dir" || exit 1
    
    local host_flag=""
    if [ "$triple" != "host" ]; then
        host_flag="--host=$triple"
        export CC="${triple}-gcc"
        export CXX="${triple}-g++"
    else
        export CC="gcc"
        export CXX="g++"
    fi

    export CFLAGS="-fPIC -I$deps/usr/include"
    export CXXFLAGS="-fPIC -I$deps/usr/include"
    export LDFLAGS="-L$deps/usr/lib -Wl,-rpath,'\$ORIGIN' -Wl,--disable-new-dtags"
    export PATH="$deps/usr/bin:/usr/local/bin:$PATH"
    export PKG_CONFIG_PATH="$deps/usr/lib/pkgconfig:$PKG_CONFIG_PATH"
    export PROTOC="$deps/usr/bin/protoc"
    
    ./configure \
        --prefix=/usr \
        $host_flag \
        --enable-shared \
        --disable-static \
        PROTOC="$deps/usr/bin/protoc" \
        >>"$build/protobuf-c.log" 2>>"$build/protobuf-c.log" || {
        log_error "protobuf-c configure 失败!"
        tail -30 "$build/protobuf-c.log"
        exit 1
    }
    
    make -j "$jobs" \
        PROTOC="$deps/usr/bin/protoc" \
        >>"$build/protobuf-c.log" 2>>"$build/protobuf-c.log" || {
        log_error "protobuf-c make 失败!"
        tail -30 "$build/protobuf-c.log"
        exit 1
    }
    
    make DESTDIR="$deps" install >>"$build/protobuf-c.log" 2>>"$build/protobuf-c.log" || {
        log_error "protobuf-c install 失败!"
        tail -30 "$build/protobuf-c.log"
        exit 1
    }
    
    log_success "protobuf-c 编译完成"
}

# ==========================================================
# 编译 LibXML2 - 动态库
# ==========================================================
build_libxml2() {
    log_section "编译 LibXML2 ${LIBXML2_VERSION} (动态库)"
    
    if [ -f "$deps/usr/lib/libxml2.so" ]; then
        log_info "LibXML2 已存在，跳过编译"
        return 0
    fi
    
    local src_dir="$build/libxml2-${LIBXML2_VERSION}"
    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    
    if ! extract_source "$cache/$libxml2_tar" "$src_dir"; then
        log_error "LibXML2 解压失败！"
        exit 1
    fi
    
    cd "$src_dir" || exit 1
    
    local host_flag=""
    if [ "$triple" != "host" ]; then
        host_flag="--host=$triple"
        export CC="${triple}-gcc"
        export CXX="${triple}-g++"
    else
        export CC="gcc"
        export CXX="g++"
    fi

    export CFLAGS="-fPIC"
    export CXXFLAGS="-fPIC"
    export LDFLAGS="-Wl,-rpath,'\$ORIGIN' -Wl,--disable-new-dtags"
    
    ./configure \
        --prefix=/usr \
        $host_flag \
        --enable-shared \
        --disable-static \
        --without-python \
        --without-icu \
        --without-lzma \
        >>"$build/libxml2.log" 2>>"$build/libxml2.log" || {
        log_error "LibXML2 configure 失败!"
        tail -30 "$build/libxml2.log"
        exit 1
    }
    
    make -j "$jobs" >>"$build/libxml2.log" 2>>"$build/libxml2.log" || {
        log_error "LibXML2 make 失败!"
        tail -30 "$build/libxml2.log"
        exit 1
    }
    
    make DESTDIR="$deps" install >>"$build/libxml2.log" 2>>"$build/libxml2.log" || {
        log_error "LibXML2 install 失败!"
        tail -30 "$build/libxml2.log"
        exit 1
    }
    
    log_success "LibXML2 编译完成"
}

# ==========================================================
# 编译 JSON-C - 动态库
# ==========================================================
build_json_c() {
    log_section "编译 JSON-C ${JSON_C_VERSION} (动态库)"
    
    if [ -f "$deps/usr/lib/libjson-c.so" ]; then
        log_info "JSON-C 已存在，跳过编译"
        return 0
    fi
    
    local src_dir="$build/json-c-json-c-${JSON_C_VERSION}"
    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    
    if ! extract_source "$cache/$json_c_tar" "$src_dir"; then
        log_error "JSON-C 解压失败！"
        exit 1
    fi
    
    cd "$src_dir" || exit 1
    
    if [ "$triple" != "host" ]; then
        export CC="${triple}-gcc"
        export CXX="${triple}-g++"
    else
        export CC="gcc"
        export CXX="g++"
    fi
    
    cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_INSTALL_PREFIX="$deps/usr" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_INSTALL_RPATH='$ORIGIN' \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -DBUILD_TESTING=OFF \
        -DDISABLE_WERROR=ON \
        >>"$build/json-c.log" 2>>"$build/json-c.log" || {
        log_error "JSON-C cmake 配置失败!"
        tail -30 "$build/json-c.log"
        exit 1
    }
    
    cmake --build build -j "$jobs" >>"$build/json-c.log" 2>>"$build/json-c.log" || {
        log_error "JSON-C 编译失败!"
        tail -30 "$build/json-c.log"
        exit 1
    }
    
    cmake --install build >>"$build/json-c.log" 2>>"$build/json-c.log" || {
        log_error "JSON-C 安装失败!"
        tail -30 "$build/json-c.log"
        exit 1
    }
    
    log_success "JSON-C 编译完成"
}

# ==========================================================
# 编译 PCRE2 - 动态库
# ==========================================================
build_pcre2() {
    log_section "编译 PCRE2 ${PCRE2_VERSION} (动态库)"
    
    if [ -f "$deps/usr/lib/libpcre2-8.so" ]; then
        log_info "PCRE2 已存在，跳过编译"
        return 0
    fi
    
    local src_dir="$build/pcre2-${PCRE2_VERSION}"
    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    
    if ! extract_source "$cache/$pcre2_tar" "$src_dir"; then
        log_error "PCRE2 解压失败！"
        exit 1
    fi
    
    cd "$src_dir" || exit 1
    
    local host_flag=""
    if [ "$triple" != "host" ]; then
        host_flag="--host=$triple"
        export CC="${triple}-gcc"
        export CXX="${triple}-g++"
    else
        export CC="gcc"
        export CXX="g++"
    fi

    export CFLAGS="-fPIC"
    export CXXFLAGS="-fPIC"
    export LDFLAGS="-Wl,-rpath,'\$ORIGIN' -Wl,--disable-new-dtags"

    ./configure \
        --prefix=/usr \
        $host_flag \
        --enable-shared \
        --disable-static \
        --disable-pcre2grep \
        --disable-pcre2test \
        --enable-unicode \
        >>"$build/pcre2.log" 2>>"$build/pcre2.log" || {
        log_error "PCRE2 configure 失败!"
        tail -30 "$build/pcre2.log"
        exit 1
    }
    
    make -j "$jobs" >>"$build/pcre2.log" 2>>"$build/pcre2.log" || {
        log_error "PCRE2 make 失败!"
        tail -30 "$build/pcre2.log"
        exit 1
    }
    
    make DESTDIR="$deps" install >>"$build/pcre2.log" 2>>"$build/pcre2.log" || {
        log_error "PCRE2 install 失败!"
        tail -30 "$build/pcre2.log"
        exit 1
    }
    
    log_success "PCRE2 编译完成"
}

# ==========================================================
# 编译 PROJ (需要 SQLite3 和 CURL) - 动态库
# ==========================================================
build_proj() {
    log_section "编译 PROJ ${PROJ_VERSION} (动态库)"
    
    if [ -f "$deps/usr/lib/libproj.so" ]; then
        log_info "PROJ 已存在，跳过编译"
        return 0
    fi
    
    export PATH="$deps/usr/bin:$PATH"
    
    if ! command -v sqlite3 &> /dev/null; then
        log_error "未找到 sqlite3 命令，请确保 SQLite3 已编译并安装到 deps"
        exit 1
    fi
    log_info "sqlite3 版本: $(sqlite3 --version)"
    
    local src_dir="$build/proj-${PROJ_VERSION}"
    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    
    if ! extract_source "$cache/$proj_tar" "$src_dir"; then
        log_error "PROJ 解压失败！文件可能已损坏"
        exit 1
    fi
    
    cd "$src_dir" || exit 1
    
    if [ "$triple" != "host" ]; then
        export CC="${triple}-gcc"
        export CXX="${triple}-g++"
    else
        export CC="gcc"
        export CXX="g++"
    fi
    
    export PKG_CONFIG_PATH="$deps/usr/lib/pkgconfig:$PKG_CONFIG_PATH"
    
    cmake -B build \
        -DBUILD_TESTING=OFF \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$deps/usr" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_INSTALL_RPATH='$ORIGIN' \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -DBUILD_PROJINFO=OFF \
        -DBUILD_PROJSYNC=OFF \
        -DBUILD_PROJ=ON \
        -DUSE_EXTERNAL_LIBS=ON \
        -DSQLITE3_INCLUDE_DIR="$deps/usr/include" \
        -DSQLITE3_LIBRARY="$deps/usr/lib/libsqlite3.so" \
        -DCURL_INCLUDE_DIR="$deps/usr/include" \
        -DCURL_LIBRARY="$deps/usr/lib/libcurl.so" \
        >>"$build/proj.log" 2>>"$build/proj.log" || {
        log_error "PROJ cmake 配置失败!"
        tail -30 "$build/proj.log"
        exit 1
    }
    
    cmake --build build -j "$jobs" >>"$build/proj.log" 2>>"$build/proj.log" || {
        log_error "PROJ 编译失败!"
        tail -30 "$build/proj.log"
        exit 1
    }
    
    cmake --install build >>"$build/proj.log" 2>>"$build/proj.log" || {
        log_error "PROJ 安装失败!"
        tail -30 "$build/proj.log"
        exit 1
    }
    
    # 合并 lib64 到 lib
    if [ -d "$deps/usr/lib64" ]; then
        mv "$deps/usr/lib64"/* "$deps/usr/lib/" 2>/dev/null || true
        rmdir "$deps/usr/lib64" 2>/dev/null || true
    fi
    
    log_success "PROJ 编译完成"
}

# ==========================================================
# 编译 GEOS - 动态库
# ==========================================================
build_geos() {
    log_section "编译 GEOS ${GEOS_VERSION} (动态库)"
    
    if [ -f "$deps/usr/lib/libgeos_c.so" ]; then
        log_info "GEOS 已存在，跳过编译"
        return 0
    fi
    
    local src_dir="$build/geos-${GEOS_VERSION}"
    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    
    if ! extract_source "$cache/$geos_tar" "$src_dir"; then
        log_error "GEOS 解压失败！文件可能已损坏"
        exit 1
    fi
    
    cd "$src_dir" || exit 1
    
    if [ "$triple" != "host" ]; then
        export CC="${triple}-gcc"
        export CXX="${triple}-g++"
    else
        export CC="gcc"
        export CXX="g++"
    fi
    
    cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_INSTALL_PREFIX="$deps/usr" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_INSTALL_RPATH='$ORIGIN' \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -DBUILD_GEOSOP=OFF \
        -DBUILD_TESTING=OFF \
        -DBUILD_DOCUMENTATION=OFF \
        >>"$build/geos.log" 2>>"$build/geos.log" || {
        log_error "GEOS cmake 配置失败!"
        tail -30 "$build/geos.log"
        exit 1
    }
    
    cmake --build build -j "$jobs" >>"$build/geos.log" 2>>"$build/geos.log" || {
        log_error "GEOS 编译失败!"
        tail -30 "$build/geos.log"
        exit 1
    }
    
    cmake --install build >>"$build/geos.log" 2>>"$build/geos.log" || {
        log_error "GEOS 安装失败!"
        tail -30 "$build/geos.log"
        exit 1
    }
    
    # 合并 lib64 到 lib
    if [ -d "$deps/usr/lib64" ]; then
        mv "$deps/usr/lib64"/* "$deps/usr/lib/" 2>/dev/null || true
        rmdir "$deps/usr/lib64" 2>/dev/null || true
    fi
    
    log_success "GEOS 编译完成"
}

# ==========================================================
# 编译 GDAL - 动态库
# ==========================================================
build_gdal() {
    log_section "编译 GDAL ${GDAL_VERSION} (动态库)"
    
    if [ -f "$deps/usr/bin/gdal-config" ]; then
        log_info "GDAL 已存在，跳过编译"
        return 0
    fi
    
    local src_dir="$build/gdal-${GDAL_VERSION}"
    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    
    if ! extract_source "$cache/$gdal_tar" "$src_dir"; then
        log_error "GDAL 解压失败！文件可能已损坏"
        exit 1
    fi
    
    cd "$src_dir" || exit 1
    
    if [ "$triple" != "host" ]; then
        export CC="${triple}-gcc"
        export CXX="${triple}-g++"
    else
        export CC="gcc"
        export CXX="g++"
    fi
    
    export PKG_CONFIG_PATH="$deps/usr/lib/pkgconfig:$PKG_CONFIG_PATH"
    export CFLAGS="-fPIC"
    export CXXFLAGS="-fPIC"
    
    cmake -B build \
        -DBUILD_TESTING=OFF \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$deps/usr" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_INSTALL_RPATH='$ORIGIN' \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -DGDAL_BUILD_OPTIONAL_DRIVERS=ON \
        -DOGR_BUILD_OPTIONAL_DRIVERS=OFF \
        -DGDAL_USE_GEOS=ON \
        -DGDAL_USE_PROJ=ON \
        -DGDAL_USE_PNG_INTERNAL=ON \
        -DGDAL_USE_JPEG_INTERNAL=ON \
        -DGDAL_USE_TIFF_INTERNAL=ON \
        -DGEOTIFF_USE_TIFF_INTERNAL=ON \
        -DGDAL_USE_CURL=OFF \
        -DGDAL_USE_SQLITE3=OFF \
        -DGDAL_USE_HDF5=OFF \
        -DGDAL_USE_NETCDF=OFF \
        -DGDAL_USE_PG=OFF \
        -DGDAL_USE_PYTHON=OFF \
        -DGDAL_USE_ODBC=OFF \
        >>"$build/gdal.log" 2>>"$build/gdal.log" || {
        log_error "GDAL cmake 配置失败!"
        tail -30 "$build/gdal.log"
        exit 1
    }
    
    cmake --build build -j "$jobs" >>"$build/gdal.log" 2>>"$build/gdal.log" || {
        log_error "GDAL 编译失败!"
        tail -30 "$build/gdal.log"
        exit 1
    }
    
    cmake --install build >>"$build/gdal.log" 2>>"$build/gdal.log" || {
        log_error "GDAL 安装失败!"
        tail -30 "$build/gdal.log"
        exit 1
    }
    
    # ==========================================================
    # 【修复 1】手动安装 GDAL 数据目录
    # cmake --install 不会把 build/data/ 安装到 share/gdal/
    # ==========================================================
    local gdal_data_src="$src_dir/build/data"
    local gdal_data_dst="$deps/usr/share/gdal"
    
    if [ -d "$gdal_data_src" ] && [ -f "$gdal_data_src/stateplane.csv" ]; then
        mkdir -p "$gdal_data_dst"
        cp -r "$gdal_data_src"/* "$gdal_data_dst/" 2>/dev/null || true
        log_info "  ✅ 手动安装 GDAL 数据: $(ls -1 "$gdal_data_dst" | wc -l) 个文件"
    else
        log_warn "  ⚠️ 未找到 GDAL 数据目录: $gdal_data_src"
    fi
    
    # ==========================================================
    # 【修复 1】手动安装 GDAL 工具
    # ==========================================================
    for tool in gdalinfo gdal-config gdal_translate gdalwarp ogr2ogr ogrinfo; do
        if [ -f "$src_dir/build/apps/$tool" ]; then
            cp "$src_dir/build/apps/$tool" "$deps/usr/bin/" 2>/dev/null || true
            chmod +x "$deps/usr/bin/$tool" 2>/dev/null || true
        fi
    done
    log_info "  ✅ GDAL 工具已安装"
    
    # 合并 lib64 到 lib
    if [ -d "$deps/usr/lib64" ]; then
        mv "$deps/usr/lib64"/* "$deps/usr/lib/" 2>/dev/null || true
        rmdir "$deps/usr/lib64" 2>/dev/null || true
    fi
    
    log_success "GDAL 编译完成"
}

# ==========================================================
# 编译 PostGIS (带 RPATH 便携支持)
# ==========================================================
build_postgis() {
    log_section "编译 PostGIS ${postgis_version}"
    
    local src_dir="$build/postgis-${postgis_version}"
    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    
    if ! extract_source "$cache/$postgis_tar" "$src_dir"; then
        log_error "PostGIS 解压失败！文件可能已损坏"
        log_info "请手动删除缓存文件: rm -f $cache/$postgis_tar"
        log_info "然后重新运行脚本"
        exit 1
    fi
    
    cd "$src_dir" || exit 1
    
    export LD_LIBRARY_PATH="$deps/usr/lib:$dist/lib:$LD_LIBRARY_PATH"
    
    export PATH="$deps/usr/bin:$dist/bin:$PATH"
    export PKG_CONFIG_PATH="$deps/usr/lib/pkgconfig:$PKG_CONFIG_PATH"
    export CFLAGS="-I$deps/usr/include -I$dist/include -fPIC"
    export CXXFLAGS="-I$deps/usr/include -I$dist/include -fPIC"

    if [ "$triple" != "host" ]; then
        export CC="${triple}-gcc"
        export CXX="${triple}-g++"
    else
        export CC="gcc"
        export CXX="g++"
    fi

    log_info "PostGIS 配置中 (所有依赖自动检测)..."

    ./configure \
        --prefix=/usr \
        --with-pgconfig="$dist/bin/pg_config" \
        --with-pgsql-libdir="$dist/lib" \
        --with-geosconfig="$deps/usr/bin/geos-config" \
        --with-projdir="$deps/usr" \
        --with-xmlconfig="$deps/usr/bin/xml2-config" \
        --with-gdalconfig="$deps/usr/bin/gdal-config" \
        --without-sfcgal \
        LDFLAGS="-L$deps/usr/lib -L$dist/lib -Wl,-rpath,'\$ORIGIN/..' -Wl,--disable-new-dtags -ldl -lm -lstdc++" \
        CPPFLAGS="-I$dist/include -I$deps/usr/include" \
        --without-interrupt-tests \
        >>"$build/postgis.log" 2>>"$build/postgis.log" || {
        log_error "PostGIS configure 失败!"
        tail -30 "$build/postgis.log"
        exit 1
    }
    
    log_info "PostGIS 编译中..."
    make -j "$jobs" >>"$build/postgis.log" 2>>"$build/postgis.log" || {
        log_error "PostGIS make 失败!"
        tail -30 "$build/postgis.log"
        exit 1
    }
    
    log_success "PostGIS 编译成功!"
    
    echo "$(pwd)"
}

# ==========================================================
# 打包 PostGIS (含所有依赖库)
# ==========================================================
package_postgis() {
    local build_dir="$1"
    
    if [ -z "$build_dir" ] || [ ! -d "$build_dir" ]; then
        log_error "构建目录不存在: $build_dir"
        exit 1
    fi
    
    cd "$build_dir" || exit 1

    pg_major=$(echo "$version" | cut -d. -f1)
    pkg_name="postgis-v${postgis_version}-pg${pg_major}.${arch}.tar.gz"
    pkg_path="$plugins_dir/$pkg_name"
    
    log_section "打包 PostGIS"
    log_info "目标: $pkg_path"

    tmp_dest="$build/tmp_install"
    rm -rf "$tmp_dest"
    mkdir -p "$tmp_dest"

    log_info "PostGIS 安装中..."
    if ! env DESTDIR="$tmp_dest" make install >>"$build/postgis.log" 2>>"$build/postgis.log"; then
        log_error "安装失败!"
        cat "$build/postgis.log" | tail -50
        exit 1
    fi

    log_info "扫描安装产物..."
    
    cd "$tmp_dest" || exit 1
    
    # 创建标准打包目录
    local final_pack="$build/final_pack"
    rm -rf "$final_pack"
    mkdir -p "$final_pack"/{lib/postgresql,share/postgresql/extension,bin}
    
    # ==========================================================
    # 1. 复制 PostGIS 扩展的核心 .so 到 lib/postgresql/
    # ==========================================================
    local real_lib_dir=""
    real_lib_dir=$(find . -type d -path "*/lib/postgresql" 2>/dev/null | head -1)
    if [ -z "$real_lib_dir" ]; then
        real_lib_dir=$(find . -type d -name "lib" 2>/dev/null | head -1)
    fi
    
    if [ -n "$real_lib_dir" ] && [ -d "$real_lib_dir" ]; then
        find "$real_lib_dir" -maxdepth 1 -name "*.so*" -exec cp -P {} "$final_pack/lib/postgresql/" \; 2>/dev/null || true
        log_info "PostGIS .so: $(ls -1 "$final_pack/lib/postgresql/"*.so* 2>/dev/null | wc -l) 个"
    fi
    
    # ==========================================================
    # 2. 复制 share 扩展 SQL 脚本及元数据到 share 目录
    # ==========================================================
    local real_share_dir=""
    real_share_dir=$(find . -type d -path "*/share/postgresql/extension" 2>/dev/null | head -1)
    if [ -z "$real_share_dir" ]; then
        real_share_dir=$(find . -type d -name "share" 2>/dev/null | head -1)
    fi
    
    if [ -n "$real_share_dir" ] && [ -d "$real_share_dir" ]; then
        find "$real_share_dir" -type f -exec cp {} "$final_pack/share/postgresql/extension/" \; 2>/dev/null || true
        log_info "extension 文件: $(ls -1 "$final_pack/share/postgresql/extension/" 2>/dev/null | wc -l) 个"
    fi
    
    # ==========================================================
    # 3. 复制 deps 的所有 .so 到 lib/
    # ==========================================================
    log_info "复制 deps 依赖库..."
    for lib_dir in "$deps/usr/lib" "$deps/usr/lib64"; do
        if [ -d "$lib_dir" ]; then
            find "$lib_dir" -maxdepth 1 -name "*.so*" \
                ! -name "libpq*" \
                -exec cp -P {} "$final_pack/lib/" \; 2>/dev/null || true
        fi
    done
    log_info "依赖库累计提取: $(ls -1 "$final_pack/lib/"*.so* 2>/dev/null | wc -l) 个"

    # ==========================================================
    # 3.5 【修复 2】打包 PROJ 数据目录
    # ==========================================================
    log_info "收集 PROJ 数据目录..."
    local proj_data_src=""
    for candidate in \
        "$deps/usr/share/proj" \
        "$deps/usr/lib/proj" ; do
        if [ -d "$candidate" ] && [ -f "$candidate/proj.db" ]; then
            proj_data_src="$candidate"
            break
        fi
    done
    
    if [ -n "$proj_data_src" ]; then
        mkdir -p "$final_pack/share/proj"
        cp -r "$proj_data_src"/* "$final_pack/share/proj/" 2>/dev/null || true
        log_info "  ✅ PROJ_DATA: $(ls -1 "$final_pack/share/proj/" 2>/dev/null | wc -l) 个文件"
    else
        log_warn "  ⚠️ 未找到 PROJ 数据目录 (proj.db)"
    fi

    # ==========================================================
    # 3.6 【修复 2】打包 GDAL 数据目录
    # ==========================================================
    log_info "收集 GDAL 数据目录..."
    local gdal_data_src=""
    for candidate in \
        "$deps/usr/share/gdal" \
        "$deps/usr/share/gdal-data" \
        "$deps/usr/lib/gdal" ; do
        if [ -d "$candidate" ] && [ -f "$candidate/stateplane.csv" ]; then
            gdal_data_src="$candidate"
            break
        fi
    done
    
    if [ -n "$gdal_data_src" ]; then
        mkdir -p "$final_pack/share/gdal"
        cp -r "$gdal_data_src"/* "$final_pack/share/gdal/" 2>/dev/null || true
        log_info "  ✅ GDAL_DATA: $(ls -1 "$final_pack/share/gdal/" 2>/dev/null | wc -l) 个文件"
    else
        log_warn "  ⚠️ 未找到 GDAL 数据目录 (stateplane.csv)"
    fi

    # ==========================================================
    # 3.7 【修复 2】打包 GDAL 工具
    # ==========================================================
    for tool in gdalinfo gdal-config gdal_translate gdalwarp ogr2ogr ogrinfo; do
        if [ -f "$deps/usr/bin/$tool" ]; then
            cp "$deps/usr/bin/$tool" "$final_pack/bin/" 2>/dev/null || true
            log_info "  ✅ 复制 GDAL 工具: $tool"
        fi
    done
    
    # ==========================================================
    # 4. 复制 bin 工具
    # ==========================================================
    local real_bin_dir=""
    real_bin_dir=$(find . -type d -name "bin" 2>/dev/null | head -1)
    if [ -n "$real_bin_dir" ] && [ -d "$real_bin_dir" ]; then
        find "$real_bin_dir" -maxdepth 1 -type f -executable -exec cp {} "$final_pack/bin/" \; 2>/dev/null || true
    fi
    
    # 剥身
    if command -v strip &> /dev/null; then
        find "$final_pack/lib/" -name "*.so*" -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true
        find "$final_pack/bin/" -type f -executable -exec strip --strip-all {} \; 2>/dev/null || true
    fi
    
    # ==========================================================
    # 5. RPATH 修复
    # ==========================================================
    if command -v patchelf &> /dev/null; then
        log_info "修复 RPATH..."
        
        # PostGIS 的 .so：RPATH 指向同包的 lib/
        find "$final_pack/lib/postgresql" -name "*.so*" -type f 2>/dev/null | while read -r so_file; do
            patchelf --set-rpath '$ORIGIN/..' "$so_file" 2>/dev/null || true
        done
        
        # deps 的 .so：RPATH 指向自身目录
        find "$final_pack/lib" -maxdepth 1 -name "*.so*" -type f 2>/dev/null | while read -r so_file; do
            patchelf --set-rpath '$ORIGIN' "$so_file" 2>/dev/null || true
        done
        
        # bin 工具：RPATH 指向 lib/
        find "$final_pack/bin" -type f -executable 2>/dev/null | while read -r bin_file; do
            if file "$bin_file" | grep -q "ELF.*executable"; then
                patchelf --set-rpath '$ORIGIN/../lib' "$bin_file" 2>/dev/null || true
            fi
        done
        
        log_success "RPATH 修复完成"
    else
        log_warn "patchelf 未找到，跳过 RPATH 修复"
    fi
    
    # ==========================================================
    # 6. 打包
    # ==========================================================
    cd "$final_pack"
    
    # 【修复 3】打包前校验
    if [ ! -f "$final_pack/share/proj/proj.db" ]; then
        log_warn "警告: proj.db 未打包，PostGIS 坐标转换可能受限"
    fi
    if [ ! -f "$final_pack/share/gdal/stateplane.csv" ]; then
        log_warn "警告: GDAL 数据未打包，栅格投影功能可能受限"
    fi
    
    tar -czf "$pkg_path" lib share bin 2>/dev/null
    
    log_success "打包完成: $pkg_path"
    ls -lh "$pkg_path"
    
    # ==========================================================
    # 7. 依赖分析
    # ==========================================================
    log_info "依赖分析中..."
    
    tmp_check="$build/pkg_check"
    rm -rf "$tmp_check"
    mkdir -p "$tmp_check"
    tar -xzf "$pkg_path" -C "$tmp_check"
    
    echo ""
    echo "=========================================="
    echo "������ 依赖检查:"
    echo "=========================================="
    
    find "$tmp_check/lib/postgresql" -name "*.so*" -type f 2>/dev/null | while read -r so; do
        rel_path="${so#$tmp_check/}"
        echo ""
        echo "������ $rel_path 依赖:"
        ldd "$so" 2>/dev/null | grep -E "=>|not found" | head -20 || echo "   (无动态依赖)"
    done
    
    rm -rf "$tmp_check"
    echo ""
    echo "=========================================="
    
    echo ""
    echo "=========================================="
    echo "完成! PostGIS v${postgis_version} 已打包"
    echo "   包路径: $pkg_path"
    echo "   包大小: $(du -h "$pkg_path" | cut -f1)"
    echo "   包内容:"
    tar -tzf "$pkg_path" | grep -E "share/proj|share/gdal" | head -10
    echo "... (共 $(tar -tzf "$pkg_path" 2>/dev/null | wc -l) 个文件)"
    echo "=========================================="
}

# ==========================================================
# build 模式: 主流程
# ==========================================================
main() {
    log_section "开始构建 PostGIS v${postgis_version} (目标: $triple, PG: $version)"
    log_info "依赖库版本: GEOS=${GEOS_VERSION}, PROJ=${PROJ_VERSION}, GDAL=${GDAL_VERSION}"
    log_info "protobuf 版本: ${PROTOBUF_VERSION}, protobuf-c 版本: ${PROTOBUF_C_VERSION}"
    log_info "并行编译数: $jobs"
    log_info "跳过依赖: $([ "$skip_deps" = true ] && echo '是' || echo '否')"
    
    if [ "$skip_deps" != true ]; then
        download_deps
        build_sqlite3
        build_curl
        build_libxml2
        build_json_c
        build_pcre2
        build_protobuf
        build_protobuf_c
        build_proj
        build_geos
        build_gdal
    else
        log_info "⏭️ 跳过依赖下载和编译 (--skip-deps)"
    fi
    
    build_dir=$(build_postgis)
    package_postgis "$build_dir"
    
    log_section "������ PostGIS v${postgis_version} 构建完成!"
}

# ==========================================================
# 执行
# ==========================================================
main
