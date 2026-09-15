#!/bin/bash

# ==========================================================
# PostGIS 构建清理脚本（严格修复版）
# ==========================================================
# 精确清除 PostGIS 相关依赖库的编译产物和安装文件
# 特点：
#   - 不使用 set -e，避免单条清理失败导致整体中断
#   - 使用 nullglob，避免通配符未匹配时传给 rm 字面量
#   - 统一 safe_rm，任何清理失败都不中断
#   - 清理结束后输出残留检查，便于确认
# ==========================================================

# 注意：这里刻意不使用 set -e
set -u
set -o pipefail
shopt -s nullglob

basedir=$(readlink -f "$(dirname "$0")")

show_usage() {
    cat << EOF
用法: $0 <triple> [选项]

参数:
  <triple>    目标平台 (如 host, x86_64-linux-gnu 等)

选项:
  (无参数)    清除所有依赖库 + PostGIS build 目录
  --cmake     仅清除 4 个 cmake 依赖库 (json-c, proj, geos, gdal)
  --help      显示帮助

示例:
  $0 host            清除 host 平台的所有构建产物
  $0 host --cmake    仅清除 host 平台的 cmake 依赖库
EOF
}

if [ "${1:-}" = "--help" ] || [ -z "${1:-}" ]; then
    show_usage
    exit 0
fi

triple="$1"
shift

cmake_only=false
if [ "${1:-}" = "--cmake" ]; then
    cmake_only=true
fi

deps="$basedir/deps/$triple"
build="$basedir/build/$triple"

log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1"
}

log_success() {
    echo "[OK] $1"
}

# ==========================================================
# 安全删除：无论是否匹配、是否存在，都不返回错误
# 用法:
#   safe_rm -rf path1 path2 ...
#   safe_rm_glob -rf "$build/foo-"*
# ==========================================================
safe_rm() {
    # 过滤掉不存在的路径，避免 rm 报错
    local args=()
    local opt=()
    local p
    for p in "$@"; do
        case "$p" in
            -*) opt+=("$p") ;;
            *)  [ -e "$p" ] && args+=("$p") ;;
        esac
    done
    if [ "${#args[@]}" -gt 0 ]; then
        rm "${opt[@]}" -- "${args[@]}" 2>/dev/null || true
    fi
}

# 清理某个前缀的所有匹配项（目录/文件）
# 用法: safe_rm_glob -rf "$build/foo-"*
safe_rm_glob() {
    local opt=()
    local p
    for p in "$@"; do
        case "$p" in
            -*) opt+=("$p") ;;
            *)  : ;;
        esac
    done
    local items=()
    for p in "$@"; do
        case "$p" in
            -*) : ;;
            *)  [ -e "$p" ] && items+=("$p") ;;
        esac
    done
    if [ "${#items[@]}" -gt 0 ]; then
        rm "${opt[@]}" -- "${items[@]}" 2>/dev/null || true
    fi
}

# 删除 build 目录下所有匹配前缀的目录
clean_build_prefix() {
    local prefix="$1"
    local items=()
    local p
    for p in "$build/$prefix"*; do
        [ -e "$p" ] && items+=("$p")
    done
    if [ "${#items[@]}" -gt 0 ]; then
        rm -rf -- "${items[@]}" 2>/dev/null || true
    fi
}

# ==========================================================
# 清理 cmake 依赖库
# ==========================================================
clean_cmake_deps() {
    log_info "清理 cmake 依赖库..."

    # --- json-c ---
    clean_build_prefix "json-c-"
    safe_rm -rf \
        "$deps/usr/lib/libjson-c.a" \
        "$deps/usr/lib/libjson-c.so" \
        "$deps/usr/lib/libjson-c.so.5" \
        "$deps/usr/lib/libjson-c.so.5.3.0" \
        "$deps/usr/lib/pkgconfig/json-c.pc" \
        "$deps/usr/bin/json-c-validate" \
        "$deps/usr/bin/json-c-generate" \
        "$deps/usr/bin/json-c.tool" \
        "$deps/usr/include/json-c" \
        "$deps/usr/lib/cmake/json-c"
    log_info "json-c 已清理"

    # --- proj ---
    clean_build_prefix "proj-"
    safe_rm -rf \
        "$deps/usr/lib/libproj.a" \
        "$deps/usr/lib/libproj.so" \
        "$deps/usr/lib/libproj.so.22" \
        "$deps/usr/lib/libproj.so.22.2.1" \
        "$deps/usr/lib/pkgconfig/proj.pc" \
        "$deps/usr/bin/proj" \
        "$deps/usr/bin/projinfo" \
        "$deps/usr/bin/projsync" \
        "$deps/usr/bin/cs2cs" \
        "$deps/usr/bin/geod" \
        "$deps/usr/bin/invgeod" \
        "$deps/usr/bin/invproj" \
        "$deps/usr/bin/cct" \
        "$deps/usr/bin/gie" \
        "$deps/usr/include/proj.h" \
        "$deps/usr/include/proj_experimental.h" \
        "$deps/usr/include/proj_constants.h" \
        "$deps/usr/include/proj_symbol_rename.h" \
        "$deps/usr/include/proj" \
        "$deps/usr/lib/cmake/proj4" \
        "$deps/usr/lib/cmake/proj" \
        "$deps/usr/share/proj"
    log_info "proj 已清理"

    # --- geos ---
    clean_build_prefix "geos-"
    safe_rm -rf \
        "$deps/usr/lib/libgeos.a" \
        "$deps/usr/lib/libgeos.so" \
        "$deps/usr/lib/libgeos.so.3.14.1" \
        "$deps/usr/lib/libgeos_c.a" \
        "$deps/usr/lib/libgeos_c.so" \
        "$deps/usr/lib/libgeos_c.so.1" \
        "$deps/usr/lib/libgeos_c.so.1.20.5" \
        "$deps/usr/lib/pkgconfig/geos.pc" \
        "$deps/usr/lib/pkgconfig/geos-c.pc" \
        "$deps/usr/bin/geos-config" \
        "$deps/usr/bin/geos" \
        "$deps/usr/include/geos_c.h" \
        "$deps/usr/include/geos.h" \
        "$deps/usr/include/geodesic.h" \
        "$deps/usr/include/geos" \
        "$deps/usr/lib/cmake/GEOS" \
        "$deps/usr/lib/cmake/geos" \
        "$deps/usr/share/geos"
    log_info "geos 已清理"

    # --- gdal ---
    clean_build_prefix "gdal-"
    safe_rm -rf \
        "$deps/usr/lib/libgdal.a" \
        "$deps/usr/lib/libgdal.so" \
        "$deps/usr/lib/libgdal.so.35" \
        "$deps/usr/lib/libgdal.so.35.3.9.2" \
        "$deps/usr/lib/pkgconfig/gdal.pc" \
        "$deps/usr/bin/gdal-config" \
        "$deps/usr/bin/gdal_translate" \
        "$deps/usr/bin/gdalinfo" \
        "$deps/usr/bin/gdaldem" \
        "$deps/usr/bin/gdaladdo" \
        "$deps/usr/bin/gdalbuildvrt" \
        "$deps/usr/bin/gdal_contour" \
        "$deps/usr/bin/gdal_create" \
        "$deps/usr/bin/gdalenhance" \
        "$deps/usr/bin/gdal_footprint" \
        "$deps/usr/bin/gdal_grid" \
        "$deps/usr/bin/gdallocationinfo" \
        "$deps/usr/bin/gdalmanage" \
        "$deps/usr/bin/gdalmdiminfo" \
        "$deps/usr/bin/gdalmdimtranslate" \
        "$deps/usr/bin/gdal_rasterize" \
        "$deps/usr/bin/gdalsrsinfo" \
        "$deps/usr/bin/gdaltindex" \
        "$deps/usr/bin/gdaltransform" \
        "$deps/usr/bin/gdal_viewshed" \
        "$deps/usr/bin/gdalwarp" \
        "$deps/usr/bin/genbrk" \
        "$deps/usr/bin/nearblack" \
        "$deps/usr/bin/ogrlineref" \
        "$deps/usr/bin/ogrtindex" \
        "$deps/usr/bin/sozip" \
        "$deps/usr/include/gdal" \
        "$deps/usr/include/cpl_atomic_ops.h" \
        "$deps/usr/include/cpl_auto_close.h" \
        "$deps/usr/include/cpl_compressor.h" \
        "$deps/usr/include/cpl_config_extras.h" \
        "$deps/usr/include/cpl_config.h" \
        "$deps/usr/include/cpl_conv.h" \
        "$deps/usr/include/cpl_csv.h" \
        "$deps/usr/include/cpl_error.h" \
        "$deps/usr/include/cpl_hash_set.h" \
        "$deps/usr/include/cpl_http.h" \
        "$deps/usr/include/cpl_json.h" \
        "$deps/usr/include/cplkeywordparser.h" \
        "$deps/usr/include/cpl_list.h" \
        "$deps/usr/include/cpl_minixml.h" \
        "$deps/usr/include/cpl_multiproc.h" \
        "$deps/usr/include/cpl_port.h" \
        "$deps/usr/include/cpl_progress.h" \
        "$deps/usr/include/cpl_quad_tree.h" \
        "$deps/usr/include/cpl_spawn.h" \
        "$deps/usr/include/cpl_string.h" \
        "$deps/usr/include/cpl_time.h" \
        "$deps/usr/include/cpl_virtualmem.h" \
        "$deps/usr/include/cpl_vsi_error.h" \
        "$deps/usr/include/cpl_vsi.h" \
        "$deps/usr/include/cpl_vsi_virtual.h" \
        "$deps/usr/include/gdal_version.h" \
        "$deps/usr/include/gdal.h" \
        "$deps/usr/include/gdalexif.h" \
        "$deps/usr/include/gdal_fwd.h" \
        "$deps/usr/include/gdal_priv.h" \
        "$deps/usr/include/gdal_rat.h" \
        "$deps/usr/include/gdal_utils.h" \
        "$deps/usr/include/gdal_version.h" \
        "$deps/usr/include/gdalwarper.h" \
        "$deps/usr/include/gdalwarpkernel_opencl.h" \
        "$deps/usr/include/gnm_api.h" \
        "$deps/usr/include/gnmgraph.h" \
        "$deps/usr/include/gnm.h" \
        "$deps/usr/include/memdataset.h" \
        "$deps/usr/include/ogr_api.h" \
        "$deps/usr/include/ogr_core.h" \
        "$deps/usr/include/ogr_feature.h" \
        "$deps/usr/include/ogr_featurestyle.h" \
        "$deps/usr/include/ogr_geocoding.h" \
        "$deps/usr/include/ogr_geomcoordinateprecision.h" \
        "$deps/usr/include/ogr_geometry.h" \
        "$deps/usr/include/ogr_p.h" \
        "$deps/usr/include/ogr_recordbatch.h" \
        "$deps/usr/include/ogrsf_frmts.h" \
        "$deps/usr/include/ogr_spatialref.h" \
        "$deps/usr/include/ogr_srs_api.h" \
        "$deps/usr/include/ogr_swq.h" \
        "$deps/usr/include/rawdataset.h" \
        "$deps/usr/include/vrtdataset.h" \
        "$deps/usr/lib/cmake/gdal" \
        "$deps/usr/lib/gdalplugins" \
        "$deps/usr/share/gdal" \
        "$deps/usr/share/bash-completion/completions/gdal2tiles.py" \
        "$deps/usr/share/bash-completion/completions/gdal2xyz.py" \
        "$deps/usr/share/bash-completion/completions/gdaladdo" \
        "$deps/usr/share/bash-completion/completions/gdalbuildvrt" \
        "$deps/usr/share/bash-completion/completions/gdal_calc.py" \
        "$deps/usr/share/bash-completion/completions/gdalchksum.py" \
        "$deps/usr/share/bash-completion/completions/gdalcompare.py" \
        "$deps/usr/share/bash-completion/completions/gdal-config" \
        "$deps/usr/share/bash-completion/completions/gdal_contour" \
        "$deps/usr/share/bash-completion/completions/gdal_create" \
        "$deps/usr/share/bash-completion/completions/gdaldem" \
        "$deps/usr/share/bash-completion/completions/gdal_edit.py" \
        "$deps/usr/share/bash-completion/completions/gdalenhance" \
        "$deps/usr/share/bash-completion/completions/gdal_fillnodata.py" \
        "$deps/usr/share/bash-completion/completions/gdal_grid" \
        "$deps/usr/share/bash-completion/completions/gdalident.py" \
        "$deps/usr/share/bash-completion/completions/gdalimport.py" \
        "$deps/usr/share/bash-completion/completions/gdalinfo" \
        "$deps/usr/share/bash-completion/completions/gdallocationinfo" \
        "$deps/usr/share/bash-completion/completions/gdalmanage" \
        "$deps/usr/share/bash-completion/completions/gdal_merge.py" \
        "$deps/usr/share/bash-completion/completions/gdalmove.py" \
        "$deps/usr/share/bash-completion/completions/gdal_polygonize.py" \
        "$deps/usr/share/bash-completion/completions/gdal_proximity.py" \
        "$deps/usr/share/bash-completion/completions/gdal_rasterize" \
        "$deps/usr/share/bash-completion/completions/gdal_retile.py" \
        "$deps/usr/share/bash-completion/completions/gdal_sieve.py" \
        "$deps/usr/share/bash-completion/completions/gdalsrsinfo" \
        "$deps/usr/share/bash-completion/completions/gdaltindex" \
        "$deps/usr/share/bash-completion/completions/gdaltransform" \
        "$deps/usr/share/bash-completion/completions/gdal_translate" \
        "$deps/usr/share/bash-completion/completions/gdal_viewshed" \
        "$deps/usr/share/bash-completion/completions/gdalwarp" \
        "$deps/usr/share/bash-completion/completions/ogr2ogr" \
        "$deps/usr/share/bash-completion/completions/ogrinfo" \
        "$deps/usr/share/bash-completion/completions/ogrlineref" \
        "$deps/usr/share/bash-completion/completions/ogrmerge.py" \
        "$deps/usr/share/bash-completion/completions/ogrtindex"
    log_info "gdal 已清理"
}

# ==========================================================
# 清理 autotools 依赖库
# ==========================================================
clean_autotools_deps() {
    log_info "清理 autotools 依赖库..."

    # --- sqlite3 ---
    clean_build_prefix "sqlite-autoconf-"
    safe_rm -rf \
        "$deps/usr/lib/libsqlite3.a" \
        "$deps/usr/lib/libsqlite3.so" \
        "$deps/usr/lib/libsqlite3.so.0" \
        "$deps/usr/lib/libsqlite3.so.0.8.6" \
        "$deps/usr/lib/libsqlite3.la" \
        "$deps/usr/lib/pkgconfig/sqlite3.pc" \
        "$deps/usr/bin/sqlite3" \
        "$deps/usr/include/sqlite3.h" \
        "$deps/usr/include/sqlite3ext.h"
    log_info "sqlite3 已清理"

    # --- curl ---
    clean_build_prefix "curl-"
    safe_rm -rf \
        "$deps/usr/lib/libcurl.a" \
        "$deps/usr/lib/libcurl.so" \
        "$deps/usr/lib/libcurl.so.4" \
        "$deps/usr/lib/libcurl.so.4.8.0" \
        "$deps/usr/lib/libcurl.la" \
        "$deps/usr/lib/pkgconfig/libcurl.pc" \
        "$deps/usr/bin/curl" \
        "$deps/usr/bin/curl-config" \
        "$deps/usr/include/curl" \
        "$deps/usr/share/aclocal/libcurl.m4"
    log_info "curl 已清理"

    # --- libxml2 ---
    clean_build_prefix "libxml2-"
    safe_rm -rf \
        "$deps/usr/lib/libxml2.a" \
        "$deps/usr/lib/libxml2.so" \
        "$deps/usr/lib/libxml2.so.2" \
        "$deps/usr/lib/libxml2.so.2.9.14" \
        "$deps/usr/lib/libxml2.la" \
        "$deps/usr/lib/pkgconfig/libxml-2.0.pc" \
        "$deps/usr/bin/xml2-config" \
        "$deps/usr/bin/xmlcatalog" \
        "$deps/usr/bin/xmllint" \
        "$deps/usr/include/libxml" \
        "$deps/usr/include/libxml2" \
        "$deps/usr/lib/cmake/libxml2" \
        "$deps/usr/lib/xml2Conf.sh" \
        "$deps/usr/share/aclocal/libxml.m4" \
        "$deps/usr/share/doc/libxml2" \
        "$deps/usr/share/gtk-doc/html/libxml2"
    log_info "libxml2 已清理"

    # --- pcre2 ---
    clean_build_prefix "pcre2-"
    safe_rm -rf \
        "$deps/usr/lib/libpcre2-8.a" \
        "$deps/usr/lib/libpcre2-8.so" \
        "$deps/usr/lib/libpcre2-8.so.0" \
        "$deps/usr/lib/libpcre2-8.so.0.11.2" \
        "$deps/usr/lib/libpcre2-8.la" \
        "$deps/usr/lib/libpcre2-posix.so" \
        "$deps/usr/lib/libpcre2-posix.so.3" \
        "$deps/usr/lib/libpcre2-posix.so.3.0.4" \
        "$deps/usr/lib/libpcre2-posix.la" \
        "$deps/usr/lib/pkgconfig/libpcre2-8.pc" \
        "$deps/usr/lib/pkgconfig/libpcre2-posix.pc" \
        "$deps/usr/bin/pcre2-config" \
        "$deps/usr/bin/pcre2grep" \
        "$deps/usr/bin/pcre2test" \
        "$deps/usr/include/pcre2.h" \
        "$deps/usr/include/pcre2posix.h" \
        "$deps/usr/share/doc/pcre2"
    log_info "pcre2 已清理"

    # --- protobuf ---
    clean_build_prefix "protobuf-"
    safe_rm -rf \
        "$deps/usr/lib/libprotobuf.a" \
        "$deps/usr/lib/libprotobuf.so" \
        "$deps/usr/lib/libprotobuf.so.31" \
        "$deps/usr/lib/libprotobuf.so.31.0.3" \
        "$deps/usr/lib/libprotobuf.la" \
        "$deps/usr/lib/libprotobuf-lite.a" \
        "$deps/usr/lib/libprotobuf-lite.so" \
        "$deps/usr/lib/libprotobuf-lite.so.31" \
        "$deps/usr/lib/libprotobuf-lite.so.31.0.3" \
        "$deps/usr/lib/libprotobuf-lite.la" \
        "$deps/usr/lib/libprotoc.a" \
        "$deps/usr/lib/libprotoc.so" \
        "$deps/usr/lib/libprotoc.so.31" \
        "$deps/usr/lib/libprotoc.so.31.0.3" \
        "$deps/usr/lib/libprotoc.la" \
        "$deps/usr/lib/pkgconfig/protobuf.pc" \
        "$deps/usr/lib/pkgconfig/protobuf-lite.pc" \
        "$deps/usr/bin/protoc" \
        "$deps/usr/include/google" \
        "$deps/usr/include/google/protobuf"
    log_info "protobuf 已清理"

    # --- protobuf-c ---
    clean_build_prefix "protobuf-c-"
    safe_rm -rf \
        "$deps/usr/lib/libprotobuf-c.a" \
        "$deps/usr/lib/libprotobuf-c.so" \
        "$deps/usr/lib/libprotobuf-c.so.1" \
        "$deps/usr/lib/libprotobuf-c.so.1.0.0" \
        "$deps/usr/lib/libprotobuf-c.la" \
        "$deps/usr/lib/pkgconfig/libprotobuf-c.pc" \
        "$deps/usr/bin/protoc-c" \
        "$deps/usr/bin/protoc-gen-c" \
        "$deps/usr/include/protobuf-c" \
        "$deps/usr/include/protobuf-c/protobuf-c.h" \
        "$deps/usr/include/protobuf-c/protobuf-c.proto"
    log_info "protobuf-c 已清理"
}

# ==========================================================
# 清理 PostGIS 自身 build 目录
# ==========================================================
clean_postgis() {
    log_info "清理 PostGIS build 目录..."
    clean_build_prefix "postgis_v"
    clean_build_prefix "postgis-"
    log_info "PostGIS build 已清理"
}

# ==========================================================
# 残留检查
# ==========================================================
check_residue() {
    log_info "残留检查..."

    local residue=0

    if [ -d "$build" ]; then
        local build_items=("$build"/*)
        if [ "${#build_items[@]}" -gt 0 ]; then
            log_warn "build 目录仍有残留:"
            ls -1 "$build" | sed 's/^/    /'
            residue=1
        fi
    fi

    if [ -d "$deps/usr/lib" ]; then
        local lib_hits
        lib_hits=$(find "$deps/usr/lib" -maxdepth 1 \
            \( -name 'libcurl*' -o -name 'libxml2*' -o -name 'libpcre2*' \
               -o -name 'libprotobuf*' -o -name 'libprotoc*' \
               -o -name 'libproj*' -o -name 'libgeos*' -o -name 'libgdal*' \
               -o -name 'libjson-c*' -o -name 'libsqlite3*' \) 2>/dev/null)
        if [ -n "$lib_hits" ]; then
            log_warn "deps/usr/lib 仍有残留库:"
            echo "$lib_hits" | sed 's/^/    /'
            residue=1
        fi
    fi

    if [ -d "$deps/usr/bin" ]; then
        local bin_hits
        bin_hits=$(find "$deps/usr/bin" -maxdepth 1 \
            \( -name 'gdal*' -o -name 'ogr*' -o -name 'proj*' -o -name 'cs2cs' \
               -o -name 'geod' -o -name 'cct' -o -name 'gie' \
               -o -name 'curl*' -o -name 'xml*' -o -name 'pcre2*' \
               -o -name 'protoc*' -o -name 'sqlite3' -o -name 'geos*' \) 2>/dev/null)
        if [ -n "$bin_hits" ]; then
            log_warn "deps/usr/bin 仍有残留:"
            echo "$bin_hits" | sed 's/^/    /'
            residue=1
        fi
    fi

    if [ "$residue" -eq 0 ]; then
        log_success "残留检查通过，未发现明显残留"
    else
        log_warn "残留检查发现未清理项，请检查上面的输出"
    fi
}

# ==========================================================
# 主流程
# ==========================================================
echo "=========================================="
echo "PostGIS 构建清理 (triple=$triple)"
echo "=========================================="
echo ""

if [ "$cmake_only" = true ]; then
    clean_cmake_deps
else
    clean_cmake_deps
    clean_autotools_deps
fi

clean_postgis

echo ""
check_residue
echo ""
echo "=========================================="
log_success "清理完成!"
echo "=========================================="
