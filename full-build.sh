#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_with_time() {
    echo -e "[$(date +%H:%M:%S.%03N)] ${GREEN}$1${NC}"
}

log_warn() {
    echo -e "[$(date +%H:%M:%S.%03N)] ${YELLOW}⚠️ $1${NC}"
}

error_exit() {
    echo -e "[$(date +%H:%M:%S.%03N)] ${RED}错误: $1${NC}"
    exit 1
}

# ==========================================
# 使用说明
# ==========================================
show_usage() {
    echo -e "${BLUE}========================================================================${NC}"
    echo -e "       PostgreSQL 绿色便携版 + 插件生态 一体化构建系统                       "
    echo -e "${BLUE}========================================================================${NC}"
    echo -e "使用方法:"
    echo -e "  $0 <triple>|host <PG版本> [选项]"
    echo -e ""
    echo -e "${GREEN}【选项】:${NC}"
    echo -e "  -p, --plugins <list>    指定要编译的插件，逗号分隔 (默认: 全部启用)"
    echo -e "  -l, --list-plugins     列出所有可用插件"
    echo -e "  -s, --skip-pgsql       跳过 PostgreSQL 编译 (只编译插件)"
    echo -e "  --no-full              不生成 FULL 包，只生成独立包"
    echo -e "  -h, --help             显示帮助"
    echo -e ""
    echo -e "${GREEN}【示例】:${NC}"
    echo -e "  $0 host 16.15"
    echo -e "  $0 host 16.15 -p vector,pg_cron"
    echo -e "  $0 host 16.15 -p vector,pg_cron -s"
    echo -e "  $0 aarch64-linux-gnu 16.15 -p vector"
    echo -e "  $0 host 16.15 --list-plugins"
    echo -e ""
    echo -e "${BLUE}========================================================================${NC}"
}

# ==========================================================
# 从插件脚本获取元信息 (返回纯 JSON，支持多行)
# ==========================================================
get_plugin_info() {
    local plugin_name="$1"
    local script="${basedir}/plugin.${plugin_name}.sh"
    
    if [ ! -f "$script" ]; then
        return 1
    fi
    
    local info=$(bash "$script" info 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$info" ]; then
        local compact=$(echo "$info" | tr -d '[:space:]')
        if echo "$compact" | grep -q '^{.*}$'; then
            echo "$info"
            return 0
        fi
    fi
    
    return 1
}

# ==========================================================
# 获取插件属性 (纯 bash/sed 解析, 不依赖 jq)
# ==========================================================
get_plugin_property() {
    local plugin_name="$1"
    local property="$2"
    local default_value="$3"
    
    local info=$(get_plugin_info "$plugin_name")
    if [ -z "$info" ]; then
        echo "$default_value"
        return 1
    fi
    
    local value=""
    
    # 字符串值
    value=$(echo "$info" | sed -n 's/.*"'"$property"'": *"\([^"]*\)".*/\1/p' | head -1)
    
    # boolean/数字
    if [ -z "$value" ]; then
        value=$(echo "$info" | sed -n 's/.*"'"$property"'": *\([^,}]*\).*/\1/p' | head -1)
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi
    
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    fi
    
    echo "$default_value"
    return 1
}

# ==========================================================
# 获取插件配置参数
# ==========================================================
get_plugin_configs() {
    local plugin_name="$1"
    local info=$(get_plugin_info "$plugin_name")
    
    if [ -z "$info" ]; then
        return 1
    fi
    
    local config_section=$(echo "$info" | sed -n 's/.*"config": *{\([^}]*\)}.*/\1/p')
    
    if [ -n "$config_section" ]; then
        echo "$config_section" | sed 's/,/\n/g' | while read -r pair; do
            pair=$(echo "$pair" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$pair" ]; then
                local key=$(echo "$pair" | sed -n 's/^"\([^"]*\)":.*/\1/p')
                local val=$(echo "$pair" | sed -n 's/^"[^"]*": *"\([^"]*\)".*/\1/p')
                if [ -z "$val" ]; then
                    val=$(echo "$pair" | sed -n 's/^"[^"]*": *\([^,}]*\).*/\1/p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                fi
                if [ -n "$key" ] && [ -n "$val" ]; then
                    echo "$key = '$val'"
                fi
            fi
        done
    fi
}

# ==========================================================
# 发现所有可用插件
# ==========================================================
discover_plugins() {
    local plugins=()
    for script in "${basedir}"/plugin.*.sh; do
        if [ -f "$script" ]; then
            local name=$(basename "$script" .sh | sed 's/^plugin\.//')
            if get_plugin_info "$name" &>/dev/null; then
                plugins+=("$name")
            else
                log_warn "插件 $name 无法获取元信息，跳过"
            fi
        fi
    done
    echo "${plugins[@]}"
}

# ==========================================================
# 列出所有插件
# ==========================================================
list_plugins() {
    echo -e "${BLUE}可用插件列表:${NC}"
    echo -e "${BLUE}  ${YELLOW}名称${NC}       ${YELLOW}版本${NC}     ${YELLOW}预加载${NC}   ${YELLOW}描述${NC}"
    echo -e "${BLUE}  ----------  --------  --------  --------------------${NC}"
    
    for name in $(discover_plugins); do
        local ver=$(get_plugin_property "$name" "version" "0.0.0")
        local preload=$(get_plugin_property "$name" "preload" "false")
        local desc=$(get_plugin_property "$name" "description" "")
        
        preload_status="❌ 否"
        if [ "$preload" = "true" ] || [ "$preload" = "yes" ]; then
            preload_status="✅ 是"
        fi
        printf "  %-10s %-8s %-8s %s\n" "$name" "$ver" "$preload_status" "$desc"
    done
}

# ==========================================
# 参数解析
# ==========================================
parse_args() {
    SELECTED_PLUGINS=""
    NO_FULL=false
    SKIP_PGSQL=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--plugins)
                SELECTED_PLUGINS="$2"
                shift 2
                ;;
            -l|--list-plugins)
                list_plugins
                exit 0
                ;;
            -s|--skip-pgsql)
                SKIP_PGSQL=true
                shift
                ;;
            --no-full)
                NO_FULL=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                if [ -z "$triple" ]; then
                    triple="$1"
                elif [ -z "$pg_version" ]; then
                    pg_version="$1"
                else
                    log_warn "忽略未知参数: $1"
                fi
                shift
                ;;
        esac
    done
    
    if [ -z "$triple" ] || [ -z "$pg_version" ]; then
        show_usage
        exit 1
    fi
    
    if [ -n "$SELECTED_PLUGINS" ]; then
        IFS=',' read -ra PLUGINS_TO_BUILD <<< "$SELECTED_PLUGINS"
    else
        PLUGINS_TO_BUILD=($(discover_plugins))
    fi
}

# ==========================================
# 架构映射
# ==========================================
map_arch() {
    case $1 in
        x86_64-*linux*) arch=x86_64 ;;
        aarch64-*linux*) arch=aarch64 ;;
        s390x-*linux*) arch=s390x ;;
        arm-*linux*) arch=armv7l ;;
        host) arch=$(uname -m) ;;
        *) arch=$1 ;;
    esac
}

# ==========================================
# 目录定义
# ==========================================
basedir=$(readlink -f "$(dirname "$0")")
deps=""
dist=""
build=""
cache="$basedir/cache"

mkdir -p "$cache"

# ==========================================
# 编译 PostgreSQL
# ==========================================
build_postgresql() {
    local script="${basedir}/pgsql-build.sh"
    if [ ! -f "$script" ]; then
        error_exit "pgsql-build.sh 不存在，无法编译 PostgreSQL"
    fi
    
    log_with_time "������ 调用: $script $triple $pg_version"
    
    if ! "$script" "$triple" "$pg_version"; then
        error_exit "PostgreSQL 编译失败"
    fi
    
    deps="$basedir/deps/$triple"
    dist="$basedir/dist/$triple/$pg_version"
    build="$basedir/build/$triple/$pg_version"
    
    log_with_time "✅ PostgreSQL ${pg_version} 编译完成"
}

# ==========================================
# 设置目录变量
# ==========================================
setup_dirs() {
    deps="$basedir/deps/$triple"
    dist="$basedir/dist/$triple/$pg_version"
    build="$basedir/build/$triple/$pg_version"
    
    if [ ! -d "$dist" ]; then
        error_exit "PostgreSQL 目录不存在: $dist"
    fi
    
    if [ ! -f "$dist/pgsql/bin/pg_config" ] && [ ! -f "$dist/bin/pg_config" ]; then
        error_exit "找不到 pg_config，请确认 PostgreSQL 已正确编译"
    fi
    
    log_with_time "✅ 使用已存在的 PostgreSQL: $dist"
}

# ==========================================
# 编译插件
# ==========================================
build_plugin() {
    local plugin_name="$1"
    local script="${basedir}/plugin.${plugin_name}.sh"
    
    if [ ! -f "$script" ]; then
        log_warn "插件脚本不存在: plugin.${plugin_name}.sh，跳过"
        return 1
    fi
    
    local version=$(get_plugin_property "$plugin_name" "version" "0.0.0")
    
    log_with_time "������ 编译: $plugin_name v${version}"
    
    if ! bash "$script" build "$triple" "$pg_version" "$version"; then
        error_exit "$plugin_name 编译打包失败"
    fi
    
    log_with_time "✅ $plugin_name v${version} 编译打包完成"
}

# ==========================================================
# 打包 FULL 包
# 流程: 解压 -> 合并插件 -> initdb -> 配置 -> 生成meta -> 启动 -> 创建扩展 -> 设置密码 -> 停止 -> 打包
# ==========================================================
package_full() {
    if [ "$NO_FULL" = true ]; then
        log_with_time "⏭️ 跳过 FULL 包生成 (--no-full)"
        return
    fi
    
    log_with_time "������ 生成 FULL 包..."
    
    # ==========================================================
    # 使用 /tmp 目录
    # ==========================================================
    local work_dir="/tmp/pgsql_full_$$"
    rm -rf "$work_dir"
    mkdir -p "$work_dir"
    
    cd "$dist"
    
    # ==========================================================
    # 1. 解压 PostgreSQL 到工作目录
    # ==========================================================
    local pg_pkg="pgsql-${pg_version}-linux-${arch}.tar.xz"
    if [ ! -f "$pg_pkg" ]; then
        log_warn "未找到 PostgreSQL 包: $pg_pkg"
        log_warn "跳过 FULL 包生成"
        rm -rf "$work_dir"
        return
    fi
    
    tar -xf "$pg_pkg" -C "$work_dir"
    log_with_time "✅ PostgreSQL 解压完成: $work_dir/pgsql"
    
    # ==========================================================
    # 2. 合并插件包
    # ==========================================================
    local plugins_dir="${dist}/plugins"
    
    if [ -d "$plugins_dir" ]; then
        log_with_time "扫描插件目录: $plugins_dir"
        for pkg in "$plugins_dir"/*.tar.gz; do
            if [ -f "$pkg" ]; then
                local pkg_name=$(basename "$pkg")
                log_with_time "  发现插件包: $pkg_name"
                tar -xf "$pkg" -C "$work_dir/pgsql"
                log_with_time "    ✅ 已合并: $pkg_name"
            fi
        done
    else
        log_warn "插件目录不存在: $plugins_dir"
    fi
    
    # ==========================================================
    # 3. 设置目录变量
    # ==========================================================
    local PGBIN="$work_dir/pgsql/bin"
    local PGDATA="$work_dir/pgsql/data"
    
    # ==========================================================
    # 4. 计算端口: 54 + 大版本号
    # ==========================================================
    local pg_major=$(echo "$pg_version" | cut -d. -f1)
    local PG_PORT="54${pg_major}"
    log_with_time "PostgreSQL 大版本: $pg_major, 端口: $PG_PORT"
    
    # ==========================================================
    # 5. 收集插件配置信息
    # ==========================================================
    local preload_list=""
    local plugin_configs=""
    
    for plugin_name in "${PLUGINS_TO_BUILD[@]}"; do
        local preload=$(get_plugin_property "$plugin_name" "preload" "false")
        
        if [ "$preload" = "true" ] || [ "$preload" = "yes" ]; then
            if [ -n "$preload_list" ]; then
                preload_list="$preload_list,$plugin_name"
            else
                preload_list="$plugin_name"
            fi
        fi
        
        local configs=$(get_plugin_configs "$plugin_name")
        if [ -n "$configs" ]; then
            plugin_configs="$plugin_configs$configs"
        fi
    done
    
    # ==========================================================
    # 6. 初始化数据库 (使用 nobody 用户)
    # ==========================================================
    log_with_time "初始化数据库: $PGDATA"
    rm -rf "$PGDATA"

    # 设置目录权限 (整个 work_dir 改为 nobody 所有)
    chown -R nobody:nobody "$work_dir" 2>/dev/null || true
    
    if ! su -s /bin/bash nobody -c "$PGBIN/initdb -D $PGDATA -U postgres --locale=C > $work_dir/initdb.log 2>&1"; then
        log_with_time "initdb 失败，错误信息:"
        cat "$work_dir/initdb.log"
        rm -rf "$work_dir"
        error_exit "initdb 失败，终止构建"
    fi
    log_with_time "   ✅ initdb 完成"
    
    # ==========================================================
    # 7. 修改 postgresql.conf
    # ==========================================================
    local CONF_FILE="$PGDATA/postgresql.conf"
    
    if [ -f "$CONF_FILE" ]; then
        log_with_time "修改 postgresql.conf"
        
        # port: 查到则改，查不到则追加
        if grep -q "^port =" "$CONF_FILE"; then
            sed -i "s/^port = .*/port = $PG_PORT/" "$CONF_FILE"
        elif grep -q "^#port =" "$CONF_FILE"; then
            sed -i "s/^#port = .*/port = $PG_PORT/" "$CONF_FILE"
        else
            echo "port = $PG_PORT" >> "$CONF_FILE"
        fi
        
        # listen_addresses
        if grep -q "^listen_addresses =" "$CONF_FILE"; then
            sed -i "s/^listen_addresses = .*/listen_addresses = '*'/" "$CONF_FILE"
        elif grep -q "^#listen_addresses =" "$CONF_FILE"; then
            sed -i "s/^#listen_addresses = .*/listen_addresses = '*'/" "$CONF_FILE"
        else
            echo "listen_addresses = '*'" >> "$CONF_FILE"
        fi
        
        # shared_preload_libraries
        if [ -n "$preload_list" ]; then
            if grep -q "^shared_preload_libraries =" "$CONF_FILE"; then
                sed -i "s/^shared_preload_libraries = .*/shared_preload_libraries = '$preload_list'/" "$CONF_FILE"
            elif grep -q "^#shared_preload_libraries =" "$CONF_FILE"; then
                sed -i "s/^#shared_preload_libraries = .*/shared_preload_libraries = '$preload_list'/" "$CONF_FILE"
            else
                echo "shared_preload_libraries = '$preload_list'" >> "$CONF_FILE"
            fi
        fi
        
        # 插件配置参数 (追加)
        if [ -n "$plugin_configs" ]; then
            echo "" >> "$CONF_FILE"
            echo "# ==========================================================" >> "$CONF_FILE"
            echo "# 插件配置参数 (自动生成)" >> "$CONF_FILE"
            echo "# ==========================================================" >> "$CONF_FILE"
            printf "%s" "$plugin_configs" >> "$CONF_FILE"
        fi
        
        log_with_time "   ✅ postgresql.conf 修改完成 (端口: $PG_PORT)"
    fi
    
    # ==========================================================
    # 8. 修改 pg_hba.conf
    # ==========================================================
    local HBA_FILE="$PGDATA/pg_hba.conf"
    
    if [ -f "$HBA_FILE" ]; then
        log_with_time "修改 pg_hba.conf"
        
        # 外网访问认证: 查到则改，查不到则追加
        if grep -q "^host[[:space:]]\+all[[:space:]]\+all[[:space:]]\+0\.0\.0\.0/0" "$HBA_FILE"; then
            sed -i "s/^host[[:space:]]\+all[[:space:]]\+all[[:space:]]\+0\.0\.0\.0\/0.*/host    all    all    0.0.0.0/0    scram-sha-256/" "$HBA_FILE"
        else
            echo "" >> "$HBA_FILE"
            echo "# 外网访问控制 (自动生成)" >> "$HBA_FILE"
            echo "host    all    all    0.0.0.0/0    scram-sha-256" >> "$HBA_FILE"
        fi
        log_with_time "   ✅ pg_hba.conf 修改完成"
    fi
    
    # ==========================================================
    # 9. 生成 meta 目录 (在启动前，确保 init.sql 存在)
    # ==========================================================
    mkdir -p "$work_dir/pgsql/meta"
    
    # ==========================================================
    # 9.0 生成密码 (基于当前时间: YYMMDD_HHMMSS)
    # ==========================================================
    PG_PASSWORD=$(date +"%y%m%d_%H%M%S")
    log_with_time "生成密码: $PG_PASSWORD"
    
    # 将密码写入 password.txt
    cat > "$work_dir/pgsql/meta/password.txt" << PASSWORD_EOF
==========================================
PostgreSQL 超级用户密码
==========================================
用户:     postgres
密码:     $PG_PASSWORD
生成时间: $(date '+%Y-%m-%d %H:%M:%S')
==========================================
说明:
  1. 外网访问请使用此密码
  2. 建议首次登录后立即修改密码
  3. 修改命令: ALTER USER postgres WITH PASSWORD 'new_password';
==========================================
PASSWORD_EOF
    log_with_time "   ✅ 密码已保存到 meta/password.txt"
    
    # manifest.json
    cat > "$work_dir/pgsql/meta/manifest.json" << MANIFEST_EOF
{
  "postgresql": {
    "version": "${pg_version}",
    "major": "${pg_major}",
    "arch": "${arch}",
    "triple": "${triple}",
    "port": "${PG_PORT}",
    "password": "${PG_PASSWORD}",
    "build_time": "$(date -Iseconds)",
    "build_host": "$(hostname)"
  },
  "plugins": [
MANIFEST_EOF
    
    local plugin_count=0
    for plugin_name in "${PLUGINS_TO_BUILD[@]}"; do
        local info=$(get_plugin_info "$plugin_name")
        if [ -n "$info" ]; then
            if [ $plugin_count -gt 0 ]; then
                echo "," >> "$work_dir/pgsql/meta/manifest.json"
            fi
            echo "    $info" >> "$work_dir/pgsql/meta/manifest.json"
            ((plugin_count++))
        fi
    done
    
    echo "  ]" >> "$work_dir/pgsql/meta/manifest.json"
    echo "}" >> "$work_dir/pgsql/meta/manifest.json"
    
    # init.sql (创建扩展使用)
    cat > "$work_dir/pgsql/meta/init.sql" << INIT_EOF
-- ==========================================================
-- PostgreSQL 扩展初始化脚本
-- 执行方式: psql -p ${PG_PORT} -f meta/init.sql
-- 生成时间: $(date)
-- ==========================================================

$(for plugin_name in "${PLUGINS_TO_BUILD[@]}"; do
    echo "CREATE EXTENSION IF NOT EXISTS ${plugin_name};"
done)

-- 验证扩展
\\dx
INIT_EOF
    
    # README.md
    cat > "$work_dir/pgsql/meta/README.md" << README_EOF
# PostgreSQL ${pg_version} 便携版 + 插件

## 版本信息
| 组件 | 版本 |
|------|------|
| PostgreSQL | ${pg_version} |
| 架构 | ${arch} |
| 端口 | ${PG_PORT} |
| 构建时间 | $(date -Iseconds) |
| 构建主机 | $(hostname) |

## 包含的插件

$(for plugin_name in "${PLUGINS_TO_BUILD[@]}"; do
    local ver=$(get_plugin_property "$plugin_name" "version" "0.0.0")
    local preload=$(get_plugin_property "$plugin_name" "preload" "false")
    local desc=$(get_plugin_property "$plugin_name" "description" "")
    
    if [ "$preload" = "true" ] || [ "$preload" = "yes" ]; then
        echo "- **${plugin_name}**: v${ver} (需要预加载)${desc:+ - $desc}"
    else
        echo "- **${plugin_name}**: v${ver}${desc:+ - $desc}"
    fi
done)

## 快速部署 (开箱即用)

\`\`\`bash
# 1. 解压
tar -xf pgsql-full-${pg_version}-linux-${arch}.tar.xz -C /opt/pgsql${pg_major}

# 2. 启动 (已包含完整配置和扩展)
/opt/pgsql${pg_major}/bin/pg_ctl -D /opt/pgsql${pg_major}/data start

# 3. 查看密码
cat /opt/pgsql${pg_major}/meta/password.txt

# 4. 验证 (使用密码)
psql -p ${PG_PORT} -U postgres -W -c '\dx'
\`\`\`

## 配置摘要

| 配置项 | 值 |
|--------|-----|
| 端口 | ${PG_PORT} |
| 监听 | 所有接口 (*) |
| 预加载 | $(if [ -n "$preload_list" ]; then echo "$preload_list"; else echo "无"; fi) |
| 外网认证 | scram-sha-256 |
| 默认密码 | 见 meta/password.txt |
README_EOF
    
    # ==========================================================
    # 10. 启动 PostgreSQL (使用 nobody 用户)
    # ==========================================================
    log_with_time "启动 PostgreSQL (端口 $PG_PORT)..."
    
    if ! su -s /bin/bash nobody -c "$PGBIN/pg_ctl -D $PGDATA -l $work_dir/pgsql/logfile start" > /dev/null 2>&1; then
        log_with_time "启动失败，错误信息:"
        cat "$work_dir/pgsql/logfile" 2>/dev/null
        su -s /bin/bash nobody -c "$PGBIN/pg_ctl -D $PGDATA stop" > /dev/null 2>&1
        rm -rf "$work_dir"
        error_exit "启动失败，终止构建"
    fi
    sleep 3
    log_with_time "   ✅ 启动完成"
    
    # ==========================================================
    # 11. 创建扩展 (使用 meta/init.sql)
    # ==========================================================
    log_with_time "创建扩展..."
    
    if [ -f "$work_dir/pgsql/meta/init.sql" ]; then
        log_with_time "   使用 meta/init.sql 批量创建扩展..."
        local init_output
        init_output=$(su -s /bin/bash nobody -c "$PGBIN/psql -h 127.0.0.1 -p $PG_PORT -U postgres -d postgres -f $work_dir/pgsql/meta/init.sql" 2>&1)
        local init_code=$?
        
        if [ $init_code -eq 0 ]; then
            log_with_time "   ✅ 所有扩展创建成功 (meta/init.sql)"
        else
            log_warn "   ❌ init.sql 执行失败 (退出码: $init_code)"
            log_warn "      错误信息: $init_output"
            log_with_time "   ⏳ 尝试逐个创建扩展..."
            
            local failed_exts=""
            for plugin_name in "${PLUGINS_TO_BUILD[@]}"; do
                log_with_time "      ⏳ 安装: $plugin_name"
                local ext_output
                ext_output=$(su -s /bin/bash nobody -c "$PGBIN/psql -h 127.0.0.1 -p $PG_PORT -U postgres -d postgres -c \"CREATE EXTENSION IF NOT EXISTS $plugin_name;\" 2>&1")
                local ext_code=$?
                
                if [ $ext_code -eq 0 ]; then
                    if echo "$ext_output" | grep -q "already exists"; then
                        log_with_time "      ⏭️ $plugin_name 已存在 (跳过)"
                    else
                        log_with_time "      ✅ $plugin_name 安装成功"
                    fi
                else
                    log_warn "      ❌ $plugin_name 安装失败"
                    log_warn "         错误信息: $ext_output"
                    failed_exts="$failed_exts $plugin_name"
                fi
            done
            
            if [ -n "$failed_exts" ]; then
                log_warn "   ⚠️ 以下扩展安装失败:$failed_exts"
            fi
        fi
    else
        log_warn "   ⚠️ 未找到 meta/init.sql，逐个创建扩展..."
        local failed_exts=""
        for plugin_name in "${PLUGINS_TO_BUILD[@]}"; do
            log_with_time "      ⏳ 安装: $plugin_name"
            local ext_output
            ext_output=$(su -s /bin/bash nobody -c "$PGBIN/psql -h 127.0.0.1 -p $PG_PORT -U postgres -d postgres -c \"CREATE EXTENSION IF NOT EXISTS $plugin_name;\" 2>&1")
            local ext_code=$?
            
            if [ $ext_code -eq 0 ]; then
                if echo "$ext_output" | grep -q "already exists"; then
                    log_with_time "      ⏭️ $plugin_name 已存在 (跳过)"
                else
                    log_with_time "      ✅ $plugin_name 安装成功"
                fi
            else
                log_warn "      ❌ $plugin_name 安装失败"
                log_warn "         错误信息: $ext_output"
                failed_exts="$failed_exts $plugin_name"
            fi
        done
        
        if [ -n "$failed_exts" ]; then
            log_warn "   ⚠️ 以下扩展安装失败:$failed_exts"
        fi
    fi
    
    # 验证安装结果
    log_with_time "   ������ 验证已安装扩展:"
    su -s /bin/bash nobody -c "$PGBIN/psql -h 127.0.0.1 -p $PG_PORT -U postgres -d postgres -c '\dx'" 2>&1
    
    # ==========================================================
    # 11.5 设置 postgres 用户密码 (使用生成的密码)
    # ==========================================================
    log_with_time "设置 postgres 用户密码..."
    
    if su -s /bin/bash nobody -c "$PGBIN/psql -h 127.0.0.1 -p $PG_PORT -U postgres -d postgres -c \"ALTER USER postgres WITH PASSWORD '$PG_PASSWORD';\"" > /dev/null 2>&1; then
        log_with_time "   ✅ postgres 密码已设置"
        log_with_time "   ������ 密码文件: meta/password.txt"
    else
        log_warn "   ❌ 密码设置失败，外网访问可能无法连接"
    fi
    
    # ==========================================================
    # 12. 停止 PostgreSQL
    # ==========================================================
    log_with_time "停止 PostgreSQL..."
    su -s /bin/bash nobody -c "$PGBIN/pg_ctl -D $PGDATA stop" > /dev/null 2>&1
    log_with_time "   ✅ 已停止"
    
    # ==========================================================
    # 13. 打包到 dist
    # ==========================================================
    cd "$work_dir"
    
    log_with_time "������ 正在压缩 FULL 包 (xz -9 最高压缩率，请耐心等待)..."
    
    local compress_start=$(date +%s)
    local full_size=$(du -sh pgsql 2>/dev/null | cut -f1)
    log_with_time "  压缩前大小: $full_size"

    tar c pgsql | xz -z -9 > "${dist}/pgsql-full-${pg_version}-linux-${arch}.tar.xz" &
    local compress_pid=$!

    local spin='-\|/'
    local i=0
    while kill -0 $compress_pid 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        echo -ne "\r  压缩中... ${spin:$i:1}"
        sleep 2
    done
    echo -e "\r  压缩完成!                "

    local compress_end=$(date +%s)
    local compress_duration=$((compress_end - compress_start))
    log_with_time "  压缩耗时: ${compress_duration}秒"

    local final_size=$(ls -lh "${dist}/pgsql-full-${pg_version}-linux-${arch}.tar.xz" 2>/dev/null | awk '{print $5}')
    log_with_time "  压缩后大小: $final_size"

    rm -rf "$work_dir"

    log_with_time "✅ FULL 包: pgsql-full-${pg_version}-linux-${arch}.tar.xz"
}

# ==========================================
# 显示结果
# ==========================================
show_result() {
    local pg_major=$(echo "$pg_version" | cut -d. -f1)
    local PG_PORT="54${pg_major}"
    
    echo ""
    echo -e "${BLUE}========================================================================${NC}"
    echo -e "${GREEN}✨ 全部构建完成！${NC}"
    echo -e "${BLUE}========================================================================${NC}"
    echo -e "������ 产物目录: ${dist}"
    echo -e ""
    echo -e "������ 产物列表:"
    echo -e "  ������ pgsql-${pg_version}-linux-${arch}.tar.xz"
    
    local plugins_dir="${dist}/plugins"
    if [ -d "$plugins_dir" ]; then
        for pkg in "$plugins_dir"/*.tar.gz; do
            if [ -f "$pkg" ]; then
                echo -e "  ������ plugins/$(basename "$pkg")"
            fi
        done
    fi
    
    if [ "$NO_FULL" != true ]; then
        echo -e "  ������ pgsql-full-${pg_version}-linux-${arch}.tar.xz  ✨ FULL包"
    fi
    
    echo -e "${BLUE}========================================================================${NC}"
    echo -e "������ 部署方式 (开箱即用):"
    echo -e "  1. 解压 FULL 包:"
    echo -e "     tar -xf pgsql-full-${pg_version}-linux-${arch}.tar.xz -C /opt/pgsql${pg_major}"
    echo -e ""
    echo -e "  2. 启动数据库:"
    echo -e "     /opt/pgsql${pg_major}/bin/pg_ctl -D /opt/pgsql${pg_major}/data start"
    echo -e ""
    echo -e "  3. 查看密码:"
    echo -e "     cat /opt/pgsql${pg_major}/meta/password.txt"
    echo -e ""
    echo -e "  4. 验证 (使用密码):"
    echo -e "     psql -p ${PG_PORT} -U postgres -W -c '\dx'"
    echo -e ""
    echo -e "  5. 停止数据库:"
    echo -e "     /opt/pgsql${pg_major}/bin/pg_ctl -D /opt/pgsql${pg_major}/data stop"
    echo -e "${BLUE}========================================================================${NC}"
}

# ==========================================
# 主流程
# ==========================================
main() {
    parse_args "$@"
    map_arch "$triple"
    
    log_with_time "������ 一体化构建启动"
    log_with_time "   Target: $triple ($arch)"
    log_with_time "   PG:     $pg_version"
    log_with_time "   插件:   ${PLUGINS_TO_BUILD[*]:-无}"
    log_with_time "   跳过PG: $SKIP_PGSQL"
    
    if [ "$SKIP_PGSQL" = true ]; then
        log_with_time "⏭️ 跳过 PostgreSQL 编译 (--skip-pgsql)"
        setup_dirs
    else
        build_postgresql
    fi
    
    for plugin_name in "${PLUGINS_TO_BUILD[@]}"; do
        build_plugin "$plugin_name"
    done
    
    package_full
    show_result
}

main "$@"
