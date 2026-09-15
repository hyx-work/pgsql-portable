# pg_cron 便携编译指南

## 概述

pg_cron 是 PostgreSQL 的定时任务调度器，类似于 Linux 的 cron，可以在数据库级别执行定期任务。

---

## 基本信息

| 属性 | 值 |
|------|-----|
| 默认版本 | 1.6.7 |
| 预加载 | ✅ 是 |
| GitHub | https://github.com/citusdata/pg_cron |
| 源码格式 | `v{version}.tar.gz` |
| 构建系统 | PGXS |

---

## 环境要求

| 依赖 | 说明 |
|------|------|
| PostgreSQL | 已编译，提供 pg_config 和头文件 |
| GCC | C 编译器 |
| make | 构建工具 |
| patchelf | 修复 RPATH（必需） |
| plugin.common.sh | 公共库（自动 source，无需手动引入） |

---

## 目录结构

```
pgsql-portable/
├── cache/
│   └── pg_cron-1.6.7.tar.gz           # 源码包
├── build/
│   └── host/
│       └── 16.15/
│           └── pg_cron_v1.6.7/
│               ├── *.c                 # 源代码
│               ├── *.o                 # 编译产物
│               └── tmp_install/        # 影子安装目录
├── dist/
│   └── host/
│       └── 16.15/
│           ├── pgsql/                  # PostgreSQL 安装目录
│           └── plugins/
│               └── pg_cron-v1.6.7-pg16.x86_64.tar.gz
└── plugin.pg_cron.sh                   # 编译脚本
```

---

## 使用方法

### 查看插件信息

```bash
./plugin.pg_cron.sh info

# 输出
{
  "name": "pg_cron",
  "version": "1.6.7",
  "preload": true,
  "config": {
    "cron.database_name": "postgres"
  },
  "description": "定时任务调度器"
}
```

### 编译命令

```bash
# 使用默认版本
./plugin.pg_cron.sh build host 16.15

# 指定版本
./plugin.pg_cron.sh build host 16.15 1.6.7

# 指定并行编译数
./plugin.pg_cron.sh build host 16.15 --jobs 8

# 依赖分析只报告不失败（非严格模式）
./plugin.pg_cron.sh build host 16.15 --no-strict

# 交叉编译 ARM64
./plugin.pg_cron.sh build aarch64-linux-gnu 16.15

# 交叉编译 x86_64
./plugin.pg_cron.sh build x86_64-linux-gnu 16.15
```

---

## 编译流程

脚本自动执行以下步骤，所有命令通过 `run_or_die` 包裹，失败时自动打印日志并终止。

### 1. 下载源码

```
下载地址: https://github.com/citusdata/pg_cron/archive/refs/tags/v{version}.tar.gz
缓存位置: cache/pg_cron-{version}.tar.gz
```

### 2. 解压源码

```
build/host/16.15/pg_cron_v1.6.7/    ← extract_source 自动解压
```

### 3. 编译

```bash
# 脚本内部执行 (resolve_pg_env → run_or_die)
# PG_CPPFLAGS 条件包含 DEPS_DIR (如果存在)
make USE_PGXS=1 \
    PG_CONFIG="$PG_CONFIG_BIN" \
    PGXS="$PGXS_FILE" \
    PG_CPPFLAGS="-I$PG_INCLUDE -I$PG_SERVER_INCLUDE -Iinclude [-I$DEPS_DIR/usr/include]" \
    -j"$jobs"
```

### 4. 打包

```
安装: make install (PGXS 标准布局到 tmp_install/)
瘦身: strip --strip-unneeded (仅 .so 文件)
RPATH修复: fix_rpath (patchelf 设置 $ORIGIN/..)
分析: analyze_dir 依赖检查 (ldd + RPATH)
打包: tar -czf → dist/host/16.15/plugins/pg_cron-v1.6.7-pg16.x86_64.tar.gz
```

---

## 编译参数

### 编译参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `USE_PGXS` | `1` | 使用 PostgreSQL 扩展构建系统 |
| `PG_CONFIG` | `$DIST_DIR/bin/pg_config` | PostgreSQL 配置工具 |
| `PGXS` | `$DIST_DIR/.../pgxs.mk` | PGXS 构建文件 |
| `PG_CPPFLAGS` | `-I$PG_INCLUDE -I$PG_SERVER_INCLUDE -Iinclude` | 头文件搜索路径 |
| `-j` | `$jobs` (自动检测 CPU 核心数) | 并行编译数 |

### 打包参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `bindir` | `$tmp_dest/bin` | 可执行文件目录 |
| `pkglibdir` | `$tmp_dest/lib/postgresql` | 库文件目录 |
| `datadir` | `$tmp_dest/share/postgresql` | 数据文件目录 |
| `sharedir` | `$tmp_dest/share/postgresql` | 共享文件目录 |
| `includedir_server` | `$tmp_dest/include/postgresql/server` | 服务器头文件目录 |

---

## 插件包结构

```
pg_cron-v1.6.7-pg16.x86_64.tar.gz
├── lib/
│   └── postgresql/
│       └── pg_cron.so
└── share/
    └── postgresql/
        └── extension/
            ├── pg_cron.control
            ├── pg_cron--1.0.sql
            └── pg_cron--1.6--1.6.1.sql
```

---

## 配置参数

### postgresql.conf

```sql
# 必须添加到 shared_preload_libraries
shared_preload_libraries = 'pg_cron'

# 可选配置
cron.database_name = 'postgres'      # 任务存储数据库
cron.log_run = on                     # 记录任务执行
cron.log_statement = on               # 记录 SQL 语句
```

### 重新加载配置

```bash
# 方法1: 命令行
pg_ctl reload

# 方法2: SQL
SELECT pg_reload_conf();
```

---

## 使用示例

### 创建定时任务

```sql
-- 每5分钟执行一次
SELECT cron.schedule('my-job', '*/5 * * * *', 'SELECT my_function()');

-- 每小时执行一次
SELECT cron.schedule('hourly-job', '0 * * * *', 'ANALYZE my_table');

-- 每天凌晨2点执行
SELECT cron.schedule('daily-job', '0 2 * * *', 'SELECT daily_cleanup()');

-- 每周一执行
SELECT cron.schedule('weekly-job', '0 0 * * 1', 'SELECT weekly_report()');
```

### 查看任务

```bash
# 查看所有任务
psql -c "SELECT * FROM cron.job;"

# 查看任务执行记录
psql -c "SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;"
```

### 管理任务

```sql
-- 按任务ID取消
SELECT cron.unschedule(42);

-- 按任务名取消
SELECT cron.unschedule('my-job');

-- 立即执行一次（不等待调度）
SELECT cron.job_run_details;
```

### 使用 Cron 表达式

```
┌───────────── 分钟 (0-59)
│ ┌───────────── 小时 (0-23)
│ │ ┌───────────── 日 (1-31)
│ │ │ ┌───────────── 月 (1-12)
│ │ │ │ ┌───────────── 星期 (0-7, 0和7都是周日)
│ │ │ │ │
* * * * * command

示例：
*/5 * * * *     每5分钟
0 * * * *       每小时
0 2 * * *       每天凌晨2点
0 0 * * 1       每周一
0 0 1 * *       每月1号
```

---

## 常见问题

### 1. 找不到 pg_config

**错误**：
```
错误: 找不到 pg_config: dist/host/16.15/pgsql/bin/pg_config
请先为 host 编译安装 PostgreSQL
```

**解决**：先编译 PostgreSQL
```bash
./pgsql-build.sh host 16.15
```

### 2. 找不到 pgxs.mk

**错误**：
```
错误: 找不到 pgxs.mk
```

**解决**：检查 PostgreSQL 编译是否完整
```bash
find dist/host/16.15/pgsql -name "pgxs.mk"
# 应该返回: dist/host/16.15/pgsql/share/postgresql/extension/pgxs.mk
```

### 3. 共享库加载失败

**错误**：
```
ERROR: could not load library "pg_cron.so": pg_cron.so: cannot open shared object file
```

**解决**：确保 shared_preload_libraries 已配置并重启 PostgreSQL
```bash
# 检查配置
psql -c "SHOW shared_preload_libraries;"

# 重启 PostgreSQL
pg_ctl restart
```

### 4. 任务不执行

**可能原因**：
1. cron daemon 未运行
2. shared_preload_libraries 未配置
3. cron.database_name 不存在

**解决**：
```bash
# 检查 cron 是否启用
psql -c "SELECT * FROM cron.job;"

# 确保任务数据库存在
createdb postgres
```

---

## 调试技巧

### 查看编译日志

```bash
# 编译日志 (run_or_die 失败时会自动打印最后 30 行)
cat build/host/16.15/pg_cron.log
```

### 手动测试

```bash
# 复制插件到 PostgreSQL
cp build/host/16.15/tmp_install/lib/postgresql/pg_cron.so \
   dist/host/16.15/pgsql/lib/postgresql/

cp build/host/16.15/tmp_install/share/postgresql/extension/* \
   dist/host/16.15/pgsql/share/postgresql/extension/

# 重启 PostgreSQL
dist/host/16.15/pgsql/bin/pg_ctl restart -D dist/host/16.15/pgsql/data

# 测试
psql -c "CREATE EXTENSION pg_cron;"
psql -c "SELECT cron.schedule('test', '*/5 * * * *', 'SELECT 1');"
```

---

## 参考资源

- [pg_cron GitHub](https://github.com/citusdata/pg_cron)
- [pg_cron 文档](https://github.com/citusdata/pg_cron#readme)
- [Cron 表达式生成器](https://crontab.guru/)
