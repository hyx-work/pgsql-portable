#!/bin/bash
# ==========================================================
# plugin.common.sh - 插件编译脚本公共库
# ==========================================================
# 用法:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/plugin.common.sh"
#
# 提供:
#   日志:      log_info / log_warn / log_error / log_success / log_section
#   执行:      run_or_die
#   下载:      download / verify_file
#   解压:      extract_source
#   工具:      detect_jobs / detect_arch / get_version
#   目录:      init_plugin_dirs / require_pg_config
#   打包:      analyze_package / strip_package / fix_rpath
#
# 约定:
#   - 所有日志输出到 stderr，stdout 仅用于返回数据 (如 info 模式 JSON)
#   - 调用方可设置 LOG_TAIL_LINES 覆盖失败时打印的日志行数 (默认 30)
#   - 调用方可设置 CURL_MAX_TIME 覆盖下载超时 (默认 600)
# ==========================================================

# 防止重复 source
if [ -n "${__PLUGIN_COMMON_LOADED:-}" ]; then
    return 0
fi
__PLUGIN_COMMON_LOADED=1

# ==========================================================
# 默认参数 (调用方可在 source 前覆盖)
# ==========================================================
LOG_TAIL_LINES="${LOG_TAIL_LINES:-30}"
CURL_MAX_TIME="${CURL_MAX_TIME:-600}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-60}"
CURL_RETRY="${CURL_RETRY:-3}"
CURL_RETRY_DELAY="${CURL_RETRY_DELAY:-5}"

# ==========================================================
# 日志函数 (全部输出到 stderr)
# ==========================================================
log_info() {
    echo "[$(date +%H:%M:%S.%03N)] [INFO]  $*" >&2
}

log_warn() {
    echo "[$(date +%H:%M:%S.%03N)] [WARN]  $*" >&2
}

log_error() {
    echo "[$(date +%H:%M:%S.%03N)] [ERROR] $*" >&2
}

log_success() {
    echo "[$(date +%H:%M:%S.%03N)] [OK]    $*" >&2
}

log_section() {
    echo "" >&2
    echo "==========================================" >&2
    echo "[$(date +%H:%M:%S.%03N)] === $*" >&2
    echo "==========================================" >&2
}

# ==========================================================
# 执行命令并在失败时终止
# ==========================================================
# 用法:
#   run_or_die "步骤名" "日志文件" cmd arg1 arg2
run_or_die() {
    local step="$1"
    local logfile="$2"
    shift 2

    if [ "$#" -eq 0 ]; then
        log_error "run_or_die: 缺少要执行的命令 (步骤: $step)"
        exit 1
    fi

    if ! "$@" >>"$logfile" 2>&1; then
        log_error "$step 失败!"
        if [ -f "$logfile" ]; then
            log_error "---- 日志尾部 ($LOG_TAIL_LINES 行): $logfile ----"
            tail -n "$LOG_TAIL_LINES" "$logfile" >&2
            log_error "---- 日志尾部结束 ----"
        fi
        exit 1
    fi
}

# ==========================================================
# 完整性验证
# ==========================================================
# 对压缩包做双重校验: 压缩流完整 + tar 结构可读
# 非压缩包: 仅检查大小 > 1024 字节
verify_file() {
    local file="$1"

    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        return 1
    fi

    case "$file" in
        *.tar.gz|*.tgz)
            gunzip -t "$file" 2>/dev/null && tar -tzf "$file" >/dev/null 2>&1
            ;;
        *.tar.bz2|*.tbz2)
            bzip2 -t "$file" 2>/dev/null && tar -tjf "$file" >/dev/null 2>&1
            ;;
        *.tar.xz|*.txz)
            xz -t "$file" 2>/dev/null && tar -tJf "$file" >/dev/null 2>&1
            ;;
        *.zip)
            unzip -t "$file" >/dev/null 2>&1
            ;;
        *)
            [ "$(stat -c%s "$file" 2>/dev/null || echo 0)" -gt 1024 ]
            ;;
    esac
}

# ==========================================================
# 通用下载函数 (缓存 + 断点续传 + 完整性验证)
# ==========================================================
# 用法:
#   download <filename> <url>
# 缓存目录: $CACHE_DIR (调用方需先 init_plugin_dirs)
download() {
    local filename="$1"
    local url="$2"

    if [ -z "${CACHE_DIR:-}" ]; then
        log_error "download: CACHE_DIR 未定义"
        exit 1
    fi

    local filepath="$CACHE_DIR/$filename"
    mkdir -p "$CACHE_DIR"

    # 1. 缓存命中: 校验后直接返回
    if [ -f "$filepath" ]; then
        if verify_file "$filepath"; then
            log_info "缓存命中: $filename"
            return 0
        else
            log_warn "缓存文件损坏，重新下载: $filename"
            rm -f "$filepath"
        fi
    fi

	# 2. 下载 (断点续传)
    log_info "下载中: $filename"
    log_info "目标 URL: $url"

    if ! curl -L -C - -o "$filepath" "$url" \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" \
        --max-time "$CURL_MAX_TIME" \
        --retry "$CURL_RETRY" \
        --retry-delay "$CURL_RETRY_DELAY" \
        --fail \
        --silent --show-error; then
        # 保留已下载的部分，下次 -C - 继续
        local partial_size=0
        [ -f "$filepath" ] && partial_size=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
        log_error "下载失败: $filename (已下载 $partial_size 字节，保留用于断点续传)"
        return 1
    fi

    # 3. 下载后校验
    if ! verify_file "$filepath"; then
        log_error "下载的文件损坏: $filename"
        rm -f "$filepath"
        return 1
    fi

    log_success "下载完成: $filename"
    return 0
}

# ==========================================================
# 解压函数 (自动识别压缩格式)
# ==========================================================
# 用法:
#   extract_source <archive> <target_dir> [strip_components]
extract_source() {
    local archive="$1"
    local target_dir="$2"
    local strip_components="${3:-1}"

    if [ ! -f "$archive" ]; then
        log_error "extract_source: 归档文件不存在: $archive"
        return 1
    fi

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
        *.zip)
            unzip -q "$archive" -d "$target_dir" >/dev/null 2>&1
            ;;
        *)
            log_error "extract_source: 不支持的归档格式: $archive"
            return 1
            ;;
    esac

    if [ -z "$(ls -A "$target_dir" 2>/dev/null)" ]; then
        log_error "extract_source: 解压后目录为空: $target_dir"
        return 1
    fi
    return 0
}

# ==========================================================
# 并行编译数
# ==========================================================
# 优先级: JOBS 环境变量 > nproc > 4
detect_jobs() {
    if [ -n "${JOBS:-}" ]; then
        echo "$JOBS"
        return
    fi
    nproc --all 2>/dev/null || echo 4
}

# ==========================================================
# 架构映射
# ==========================================================
# 用法:
#   arch=$(detect_arch "$triple") || { echo "错误: 不支持的目标平台: $triple" >&2; exit 1; }
# 成功时输出架构名到 stdout，失败返回非零
detect_arch() {
    local triple="$1"
    case "$triple" in
        x86_64-*linux*)
            echo "x86_64"
            ;;
        aarch64-*linux*)
            echo "aarch64"
            ;;
        s390x-*linux*)
            echo "s390x"
            ;;
        arm-*linux*)
            echo "armv7l"
            ;;
        host)
            uname -m
            ;;
        *)
            return 1
            ;;
    esac
}

# ==========================================================
# 版本号解析 (优先级: 参数 > 环境变量 > 默认值)
# ==========================================================
# 用法: ver=$(get_version "$1" "$ENV_VAR_NAME" "$DEFAULT")
get_version() {
    local arg_version="${1:-}"
    local env_name="${2:-}"
    local default_version="${3:-}"

    if [ -n "$arg_version" ]; then
        echo "$arg_version"
    elif [ -n "$env_name" ] && [ -n "${!env_name:-}" ]; then
        echo "${!env_name}"
    else
        echo "$default_version"
    fi
}

# ==========================================================
# 初始化标准目录结构
# ==========================================================
# 用法: init_plugin_dirs <basedir> <triple> <pg_version>
# 导出: DEPS_DIR DIST_DIR BUILD_DIR CACHE_DIR PLUGINS_DIR
init_plugin_dirs() {
    local basedir="$1"
    local triple="$2"
    local pg_version="$3"

    export DEPS_DIR="$basedir/deps/$triple"
    export DIST_DIR="$basedir/dist/$triple/$pg_version/pgsql"
    export BUILD_DIR="$basedir/build/$triple/$pg_version"
    export CACHE_DIR="$basedir/cache"
    export PLUGINS_DIR="$basedir/dist/$triple/$pg_version/plugins"

    mkdir -p "$BUILD_DIR" "$CACHE_DIR" "$PLUGINS_DIR" "$DEPS_DIR/usr"

    export LD_LIBRARY_PATH="$DEPS_DIR/usr/lib:$DIST_DIR/lib:${LD_LIBRARY_PATH:-}"
}

# ==========================================================
# 检查 PostgreSQL 是否已编译
# ==========================================================
require_pg_config() {
    if [ ! -f "$DIST_DIR/bin/pg_config" ]; then
        log_error "找不到 pg_config: $DIST_DIR/bin/pg_config"
        log_error "请先为 $1 编译安装 PostgreSQL"
        exit 1
    fi
}

# ==========================================================
# 依赖分析 (ldd + RPATH)
# ==========================================================
# 用法: analyze_dir <dir>
# 默认严格: 任何 "not found" 都返回非零
# 可通过 ANALYZE_STRICT=0 放宽为只报告不失败
analyze_dir() {
    local check_dir="$1"
    local strict="${ANALYZE_STRICT:-1}"

    if [ ! -d "$check_dir" ]; then
        log_error "analyze_dir: 目录不存在: $check_dir"
        return 1
    fi

    echo "" >&2
    echo "==========================================" >&2
    echo "== 依赖检查: $check_dir" >&2
    echo "==========================================" >&2

    local found_issue=0

    # ---- .so 依赖 ----
    while IFS= read -r so; do
        [ -z "$so" ] && continue
        local rel_path="${so#$check_dir/}"

        echo "" >&2
        echo "== $rel_path 依赖:" >&2

        local ldd_out
        ldd_out=$(ldd "$so" 2>/dev/null || true)

        if [ -z "$ldd_out" ]; then
            echo "   (无动态依赖或非 ELF 文件)" >&2
        else
            echo "$ldd_out" | grep -E "=>|not found" >&2 || true
            if echo "$ldd_out" | grep -q "not found"; then
                found_issue=1
                echo "   [!!] 存在 not found 依赖" >&2
            fi
        fi

        echo "== $rel_path RPATH/RUNPATH:" >&2
        readelf -d "$so" 2>/dev/null | grep -E "RPATH|RUNPATH" >&2 \
            || echo "   (未设置 RPATH/RUNPATH)" >&2
    done < <(find "$check_dir" -name "*.so*" -type f 2>/dev/null | sort)

    # ---- bin 可执行文件 ----
    if [ -d "$check_dir/bin" ]; then
        while IFS= read -r bin; do
            [ -z "$bin" ] && continue
            local rel_path="${bin#$check_dir/}"

            echo "" >&2
            echo "== $rel_path 依赖:" >&2

            local ldd_out
            ldd_out=$(ldd "$bin" 2>/dev/null || true)

            if [ -z "$ldd_out" ]; then
                echo "   (无动态依赖或非 ELF 文件)" >&2
            else
                echo "$ldd_out" | grep -E "=>|not found" >&2 || true
                if echo "$ldd_out" | grep -q "not found"; then
                    found_issue=1
                    echo "   [!!] 存在 not found 依赖" >&2
                fi
            fi

            echo "== $rel_path RPATH/RUNPATH:" >&2
            readelf -d "$bin" 2>/dev/null | grep -E "RPATH|RUNPATH" >&2 \
                || echo "   (未设置 RPATH/RUNPATH)" >&2
        done < <(find "$check_dir/bin" -type f -executable 2>/dev/null | sort)
    fi

    echo "" >&2
    echo "==========================================" >&2

    if [ "$found_issue" -eq 1 ]; then
        if [ "$strict" -eq 1 ]; then
            log_error "依赖分析发现问题 (存在 not found)"
            return 1
        else
            log_warn "依赖分析发现问题 (ANALYZE_STRICT=0, 仅报告)"
        fi
    else
        log_success "依赖分析通过"
    fi

    return 0
}

# ==========================================================
# strip 瘦身 (可选)
# ==========================================================
strip_package() {
    local pack_dir="$1"

    if ! command -v strip >/dev/null 2>&1; then
        log_warn "strip 未找到，跳过瘦身"
        return 0
    fi

    log_info "strip 瘦身中..."
    find "$pack_dir/lib" -name "*.so*" -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true
    find "$pack_dir/bin" -type f -executable -exec strip --strip-all {} \; 2>/dev/null || true
}

# ==========================================================
# RPATH 修复 (需要 patchelf)
# ==========================================================
# 用法: fix_rpath <pack_dir> <lib_subdir>
#   lib_subdir: PostGIS 这类扩展用 "lib/postgresql"; 无子目录传 "lib"
fix_rpath() {
    local pack_dir="$1"
    local lib_subdir="${2:-lib}"

    if ! command -v patchelf >/dev/null 2>&1; then
        log_error "patchelf 未找到，RPATH 修复是必需步骤"
        log_error "请先安装 patchelf: 见 tool/README.md"
        exit 1
    fi

    log_info "修复 RPATH..."

    # 扩展 .so: RPATH 指向同包 lib/
    if [ "$lib_subdir" != "lib" ] && [ -d "$pack_dir/$lib_subdir" ]; then
        find "$pack_dir/$lib_subdir" -name "*.so*" -type f 2>/dev/null | while read -r so; do
            patchelf --set-rpath '$ORIGIN/..' "$so" 2>/dev/null || true
        done
    fi

    # 依赖 .so: RPATH 指向自身目录
    if [ -d "$pack_dir/lib" ]; then
        find "$pack_dir/lib" -maxdepth 1 -name "*.so*" -type f 2>/dev/null | while read -r so; do
            patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
        done
    fi

    # bin 工具: RPATH 指向 lib/
    if [ -d "$pack_dir/bin" ]; then
        find "$pack_dir/bin" -type f -executable 2>/dev/null | while read -r bin; do
            if file "$bin" | grep -q "ELF.*executable"; then
                patchelf --set-rpath '$ORIGIN/../lib' "$bin" 2>/dev/null || true
            fi
        done
    fi

    log_success "RPATH 修复完成"
}