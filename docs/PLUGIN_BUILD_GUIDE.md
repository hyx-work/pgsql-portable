# PostgreSQL 插件便携编译指南

## 概述

本文档记录了 `pgsql-portable` 项目中所有插件的便携编译过程，包括 pg_cron、pg_repack、pgvector 和 TimescaleDB。

所有插件遵循统一的编译规范，生成符合便携标准的插件包。

---

## 插件列表

| 插件 | 版本 | 功能 | 预加载 | 构建系统 |
|------|------|------|--------|----------|
| **pg_cron** | 1.6.7 | 定时任务调度 | ✅ 是 | PGXS |
| **pg_repack** | 1.5.3 | 在线表重组 | 否 | PGXS |
| **pgvector** | 0.8.6 | 向量相似度搜索 | 否 | PGXS |
| **TimescaleDB** | 2.29.2 | 时间序列数据库 | ✅ 是 | CMake |

---

## 统一规范

### 目录结构

```
pgsql-portable/
├── cache/                          # 源码包缓存
│   ├── pg_cron-1.6.7.tar.gz
│   ├── pg_repack-1.5.3.tar.gz
│   ├── vector-0.8.6.tar.gz
│   └── timescaledb-2.29.2.tar.gz
├── build/
│   └── host/
│       └── 16.15/
│           ├── pg_cron_v1.6.7/
│           ├── pg_repack_v1.5.3/
│           ├── vector_v0.8.6/
│           └── timescaledb_v2.29.2/
├── deps/
│   └── host/usr/                   # 静态依赖库
├── dist/
│   └── host/
│       └── 16.15/
│           ├── pgsql/              # PostgreSQL 安装目录
│           └── plugins/            # 插件包输出目录
│               ├── pg_cron-v1.6.7-pg16.x86_64.tar.gz
│               ├── pg_repack-v1.5.3-pg16.x86_64.tar.gz
│               ├── vector-v0.8.6-pg16.x86_64.tar.gz
│               └── timescaledb-v2.29.2-pg16.x86_64.tar.gz
└── plugin.*.sh                     # 插件构建脚本
```

### 插件包结构规范

所有插件打包后必须遵循以下结构：

```
插件包.tar.gz
├── lib/
│   └── postgresql/
│       ├── 插件名.so              # 库文件
│       └── 插件名.so.版本         # 版本化库文件（可选）
└── share/
    └── postgresql/
        └── extension/
            ├── 插件名.control     # 控制文件
            ├── 插件名--版本.sql   # 版本 SQL
            └── ...
```

### 命名规范

| 类型 | 格式 | 示例 |
|------|------|------|
| 源码包 | `插件名-版本.tar.gz` | `pg_cron-1.6.7.tar.gz` |
| 插件包 | `插件名-v版本-pgPG主版本.架构.tar.gz` | `pg_cron-v1.6.7-pg16.x86_64.tar.gz` |
| 构建目录 | `build/triple/PG版本/插件名_v版本/` | `build/host/16.15/pg_cron_v1.6.7/` |

---

## pg_cron

### 功能说明

pg_cron 是 PostgreSQL 的定时任务调度器，类似于 Linux 的 cron，可以在数据库级别执行定期任务。

### 基本信息

| 属性 | 值 |
|------|-----|
| 默认版本 | 1.6.7 |
| 预加载 | ✅ 是 |
| GitHub | https://github.com/citusdata/pg_cron |
| 源码格式 | `v{version}.tar.gz` |

### 编译命令

```bash
# 查看插件信息
./plugin.pg_cron.sh info

# 编译（使用默认版本）
./plugin.pg_cron.sh build host 16.15

# 编译（指定版本）
./plugin.pg_cron.sh build host 16.15 1.6.7

# 交叉编译 ARM64
./plugin.pg_cron.sh build aarch64-linux-gnu 16.15
```

### 编译参数

```bash
make USE_PGXS=1 \
    PG_CONFIG="$PG_CONFIG_BIN" \
    PGXS="$PGXS_FILE" \
    PG_CPPFLAGS="-I$PG_INCLUDE -I$PG_SERVER_INCLUDE -Iinclude" \
    -j$numcpus
```

### 打包参数

```bash
make USE_PGXS=1 \
    PG_CONFIG="$PG_CONFIG_BIN" \
    PGXS="$PGXS_FILE" \
    bindir="$tmp_dest/bin" \
    pkglibdir="$tmp_dest/lib/postgresql" \
    datadir="$tmp_dest/share/postgresql" \
    sharedir="$tmp_dest/share/postgresql" \
    includedir_server="$tmp_dest/postgresql/include/server" \
    install
```

### 配置参数

```sql
-- postgresql.conf
shared_preload_libraries = 'pg_cron'
cron.database_name = 'postgres'
```

### 使用示例

```sql
-- 创建定时任务（每5分钟执行）
SELECT cron.schedule('my-job', '*/5 * * * *', 'SELECT my_function()');

-- 查看定时任务
SELECT * FROM cron.job;

-- 查看任务执行记录
SELECT * FROM cron.job_run_details;

-- 删除定时任务
SELECT cron.unschedule('my-job');
```

---

## pg_repack

### 功能说明

pg_repack 是 PostgreSQL 的在线表重组工具，可以在不锁表的情况下清理表膨胀、重建索引。

### 基本信息

| 属性 | 值 |
|------|-----|
| 默认版本 | 1.5.3 |
| 预加载 | 否 |
| GitHub | https://github.com/reorg/pg_repack |
| 源码格式 | `ver_{version}.tar.gz`（注意 ver_ 前缀） |

### 编译命令

```bash
# 查看插件信息
./plugin.pg_repack.sh info

# 编译（使用默认版本）
./plugin.pg_repack.sh build host 16.15

# 编译（指定版本）
./plugin.pg_repack.sh build host 16.15 1.5.3

# 交叉编译 ARM64
./plugin.pg_repack.sh build aarch64-linux-gnu 16.15
```

### 编译特点

pg_repack 包含两个部分：

1. **bin/（客户端工具）**：需要链接 libpq，设置 RPATH
2. **lib/（扩展库）**：由 PostgreSQL 服务器加载

### 编译参数

```bash
# 编译客户端（bin/）
make -C bin USE_PGXS=1 \
    PG_CONFIG="$PG_CONFIG_BIN" \
    PGXS="$PGXS_FILE" \
    PG_CPPFLAGS="$PG_CPPFLAGS" \
    LDFLAGS="-L$pg_src/src/common -L$pg_src/src/port -L$dist/lib -Wl,-rpath=\$\$ORIGIN/../lib" \
    -j$numcpus

# 编译扩展（lib/）
make -C lib USE_PGXS=1 \
    PG_CONFIG="$PG_CONFIG_BIN" \
    PGXS="$PGXS_FILE" \
    PG_CPPFLAGS="$PG_CPPFLAGS" \
    -j$numcpus
```

### 打包参数

```bash
make USE_PGXS=1 \
    PG_CONFIG="$PG_CONFIG_BIN" \
    PGXS="$PGXS_FILE" \
    bindir="$tmp_dest/bin" \
    pkglibdir="$tmp_dest/lib/postgresql" \
    datadir="$tmp_dest/share/postgresql" \
    sharedir="$tmp_dest/share/postgresql" \
    includedir_server="$tmp_dest/postgresql/include/server" \
    install
```

### 使用示例

```bash
# 重组单个表
pg_repack -d mydb -t mytable

# 重组所有膨胀表
pg_repack -d mydb

# 重建索引
pg_repack -d mydb -i myindex

# 并行重组（4个Worker）
pg_repack -d mydb -j 4

# 查看重组进度
pg_repack -d mydb --status
```

---

## pgvector

### 功能说明

pgvector 是 PostgreSQL 的向量相似度搜索扩展，支持 IVFFlat 和 HNSW 索引，适用于 AI/ML 向量检索场景。

### 基本信息

| 属性 | 值 |
|------|-----|
| 默认版本 | 0.8.6 |
| 预加载 | 否 |
| GitHub | https://github.com/pgvector/pgvector |
| 源码格式 | `v{version}.tar.gz` |

### 编译命令

```bash
# 查看插件信息
./plugin.vector.sh info

# 编译（使用默认版本）
./plugin.vector.sh build host 16.15

# 编译（指定版本）
./plugin.vector.sh build host 16.15 0.8.6

# 交叉编译 ARM64
./plugin.vector.sh build aarch64-linux-gnu 16.15
```

### 编译参数

```bash
make USE_PGXS=1 \
    PG_CONFIG="$PG_CONFIG_BIN" \
    PGXS="$PGXS_FILE" \
    PG_CPPFLAGS="-I$PG_INCLUDE -I$PG_SERVER_INCLUDE" \
    -j$numcpus
```

### 打包参数

```bash
make USE_PGXS=1 \
    PG_CONFIG="$PG_CONFIG_BIN" \
    PGXS="$PGXS_FILE" \
    bindir="$tmp_dest/bin" \
    pkglibdir="$tmp_dest/lib/postgresql" \
    datadir="$tmp_dest/share/postgresql" \
    sharedir="$tmp_dest/share/postgresql" \
    includedir_server="$tmp_dest/postgresql/include/server" \
    install
```

### 使用示例

```sql
-- 创建向量表
CREATE TABLE items (
    id SERIAL PRIMARY KEY,
    embedding vector(3)  -- 3维向量
);

-- 插入数据
INSERT INTO items (embedding) VALUES
    ('[1,2,3]'),
    ('[4,5,6]'),
    ('[7,8,9]');

-- 创建 HNSW 索引
CREATE INDEX ON items USING hnsw (embedding vector_l2_ops);

-- 相似度搜索（最近邻）
SELECT * FROM items
ORDER BY embedding <=> '[1,2,3]'
LIMIT 5;

-- 向量运算
SELECT embedding + '[1,1,1]' FROM items;
SELECT embedding * '[2,2,2]' FROM items;
```

---

## TimescaleDB

### 功能说明

TimescaleDB 是一个开源的时间序列数据库，作为 PostgreSQL 扩展运行，提供高效的时间序列数据存储和查询能力。

### 基本信息

| 属性 | 值 |
|------|-----|
| 默认版本 | 2.29.2 |
| 预加载 | ✅ 是 |
| GitHub | https://github.com/timescale/timescaledb |
| 构建系统 | CMake |

### 编译命令

```bash
# 查看插件信息
./plugin.timescaledb.sh info

# 编译（使用默认版本）
./plugin.timescaledb.sh build host 16.15

# 编译（指定版本）
./plugin.timescaledb.sh build host 16.15 2.29.2

# 交叉编译 ARM64
./plugin.timescaledb.sh build aarch64-linux-gnu 16.15
```

### CMake 参数

```bash
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/ \
    -DCMAKE_INSTALL_LIBDIR="lib/postgresql" \
    -DCMAKE_INSTALL_DATADIR="share/postgresql" \
    -DPG_CONFIG="$PG_CONFIG_BIN" \
    -DCMAKE_PREFIX_PATH="$deps/usr" \
    -DUSE_OPENSSL=ON \
    -DSEND_TELEMETRY_DEFAULT=OFF \
    -DREGRESS_CHECKS=OFF \
    -DWARNINGS_AS_ERRORS=OFF \
    -DPG_LIBDIR="/lib/postgresql" \
    -DPG_PKGLIBDIR="/lib/postgresql" \
    -DPG_SHAREDIR="/share/postgresql" \
    -DPG_DATADIR="/share/postgresql" \
    -DPG_INCLUDEDIR="/include/postgresql"
```

### 影子安装

```bash
# 使用 DESTDIR 环境变量（不要使用 --destdir 参数）
DESTDIR="$tmp_dest" cmake --install .
```

### 配置参数

```sql
-- postgresql.conf
shared_preload_libraries = 'timescaledb'
timescaledb.max_background_workers = 8
timescaledb.telemetry_level = 'off'
```

### 使用示例

```sql
-- 创建超表
CREATE TABLE sensor_data (
    time TIMESTAMPTZ NOT NULL,
    sensor_id INTEGER,
    temperature DOUBLE PRECISION,
    humidity DOUBLE PRECISION
);

SELECT create_hypertable('sensor_data', 'time');

-- 插入数据
INSERT INTO sensor_data VALUES
    (NOW(), 1, 25.5, 60.0),
    (NOW() + INTERVAL '1 hour', 1, 26.0, 58.0);

-- 时间范围查询
SELECT * FROM sensor_data
WHERE time > NOW() - INTERVAL '1 day';

-- 时间分桶聚合
SELECT time_bucket('1 hour', time) AS bucket,
       AVG(temperature) AS avg_temp
FROM sensor_data
GROUP BY bucket
ORDER BY bucket;
```

---

## 编译流程对比

### 构建系统对比

| 插件 | 构建系统 | 配置方式 | 安装方式 |
|------|----------|----------|----------|
| pg_cron | PGXS | make 参数 | make install |
| pg_repack | PGXS | make 参数 | make install |
| pgvector | PGXS | make 参数 | make install |
| TimescaleDB | CMake | cmake 参数 | DESTDIR + cmake --install |

### 路径参数对比

| 插件 | 库文件路径 | 共享文件路径 |
|------|-----------|-------------|
| pg_cron | pkglibdir=$tmp_dest/lib/postgresql | datadir=$tmp_dest/share/postgresql |
| pg_repack | pkglibdir=$tmp_dest/lib/postgresql | datadir=$tmp_dest/share/postgresql |
| pgvector | pkglibdir=$tmp_dest/lib/postgresql | datadir=$tmp_dest/share/postgresql |
| TimescaleDB | -DCMAKE_INSTALL_LIBDIR="lib/postgresql" | -DCMAKE_INSTALL_DATADIR="share/postgresql" |

### 依赖处理对比

| 插件 | 外部依赖 | 处理方式 |
|------|----------|----------|
| pg_cron | PostgreSQL | PGXS 自动检测 |
| pg_repack | PostgreSQL, libpq | 链接 PostgreSQL 源码库 |
| pgvector | PostgreSQL | PGXS 自动检测 |
| TimescaleDB | OpenSSL, ICU | CMake PREFIX_PATH |

---

## 常见问题

### 1. 找不到 pg_config

**错误信息**：
```
错误: 找不到 pg_config: /path/to/pg_config
请先为 host 编译安装 PostgreSQL
```

**解决方案**：先运行 `./pgsql-build.sh host 16.15` 编译 PostgreSQL

### 2. 找不到 pgxs.mk

**错误信息**：
```
错误: 找不到 pgxs.mk
```

**解决方案**：确保 PostgreSQL 已正确编译，pgxs.mk 位于 `$dist/share/postgresql/extension/`

### 3. 编译失败：缺少头文件

**错误信息**：
```
fatal error: postgres.h: No such file or directory
```

**解决方案**：检查 `PG_CPPFLAGS` 是否包含正确的头文件路径

```bash
# 检查头文件路径
ls $dist/include/postgresql/server/postgres.h
```

### 4. 打包后路径不对

**问题描述**：文件被安装到套娃路径

**解决方案**：确保使用正确的路径参数

```bash
# PGXS 插件
pkglibdir="$tmp_dest/lib/postgresql"
datadir="$tmp_dest/share/postgresql"

# TimescaleDB
-DCMAKE_INSTALL_LIBDIR="lib/postgresql"
-DCMAKE_INSTALL_DATADIR="share/postgresql"
```

### 5. TimescaleDB 无效 CMake 参数

**警告信息**：
```
CMake Warning:
  Manually-specified variables were not used by the project:
    USE_ICU
    USE_LZ4
    USE_ZSTD
```

**解决方案**：移除这些无效参数，TimescaleDB 通过 PG_CONFIG 自动检测

### 6. pg_repack 客户端 RPATH 问题

**问题描述**：pg_repack 命令找不到 libpq

**解决方案**：编译时设置 RPATH

```bash
LDFLAGS="-L$pg_src/src/common -L$pg_src/src/port -L$dist/lib -Wl,-rpath=\$\$ORIGIN/../lib"
```

---

## 一键构建

### 构建所有插件

```bash
# 使用 full-build.sh 构建 PostgreSQL + 所有插件
./full-build.sh host 16.15

# 只构建特定插件
./full-build.sh host 16.15 -p pg_cron,vector

# 跳过 PostgreSQL 编译（只编译插件）
./full-build.sh host 16.15 -s
```

### 构建输出

```
dist/host/16.15/
├── pgsql-16.15-linux-x86_64.tar.xz           # PostgreSQL 独立包
├── pgsql-16.15-linux-x86_64-FULL.tar.xz      # FULL 包（含插件）
└── plugins/
    ├── pg_cron-v1.6.7-pg16.x86_64.tar.gz
    ├── pg_repack-v1.5.3-pg16.x86_64.tar.gz
    ├── vector-v0.8.6-pg16.x86_64.tar.gz
    └── timescaledb-v2.29.2-pg16.x86_64.tar.gz
```

---

## 版本支持矩阵

### PostgreSQL 版本兼容性

| 插件 | PG 16 | PG 17 | PG 18 |
|------|-------|-------|-------|
| pg_cron 1.6.7 | ✅ | ✅ | ✅ |
| pg_repack 1.5.3 | ✅ | ✅ | ✅ |
| pgvector 0.8.6 | ✅ | ✅ | ✅ |
| TimescaleDB 2.29.2 | ✅ | ✅ | ✅ |

### 架构支持

| 插件 | x86_64 | aarch64 | s390x | armv7l |
|------|--------|---------|-------|--------|
| pg_cron | ✅ | ✅ | ✅ | ✅ |
| pg_repack | ✅ | ✅ | ✅ | ✅ |
| pgvector | ✅ | ✅ | ✅ | ✅ |
| TimescaleDB | ✅ | ✅ | ✅ | ✅ |

---

## 插件开发规范

### 脚本结构

每个插件脚本必须包含以下函数：

```bash
# 1. 插件元信息
plugin_info() {
    cat << EOF
{
  "name": "插件名",
  "version": "版本号",
  "preload": true/false,
  "config": {},
  "description": "插件描述"
}
EOF
}

# 2. 使用说明
show_usage() {
    echo "用法: $0 {info|build} [参数...]"
}

# 3. 版本获取
get_version() {
    # 优先级: 参数 > 环境变量 > 默认值
}

# 4. 下载函数
download() {
    # 缓存检查 + 下载
}

# 5. 编译函数
build_插件名() {
    # 解压源码 → 配置 → 编译
}

# 6. 打包函数
package_插件名() {
    # 安装到临时目录 → 打包 → 依赖分析
}
```

### 目录变量

```bash
basedir=$(dirname $(readlink -f $0))
deps="$basedir/deps/$triple"
dist="$basedir/dist/$triple/$version/pgsql"
build="$basedir/build/$triple/$version/插件名_v版本"
cache="$basedir/cache"
plugins_dir="$basedir/dist/$triple/$version/plugins"
```

### 日志函数

```bash
log_with_time() {
    echo "[$(date +%H:%M:%S.%03N)] $1" >&2
}
```

### 依赖分析

打包完成后，自动执行依赖分析：

```bash
# 检查 .so 文件依赖
ldd plugin.so

# 检查 RPATH/RUNPATH
readelf -d plugin.so | grep -E "RPATH|RUNPATH"
```

---

## 调试技巧

### 查看编译日志

```bash
# 查看特定插件的编译日志
cat build/host/16.15/pg_cron_v1.6.7/pg_cron.log
cat build/host/16.15/timescaledb_v2.29.2/timescaledb.log
```

### 清理重新编译

```bash
# 清理特定插件
rm -rf build/host/16.15/pg_cron_v1.6.7

# 清理所有构建产物
rm -rf build/*
```

### 手动测试打包

```bash
# 解压插件包到临时目录
mkdir -p /tmp/test_plugin
tar -xzf dist/host/16.15/plugins/pg_cron-v1.6.7-pg16.x86_64.tar.gz -C /tmp/test_plugin

# 检查目录结构
tree /tmp/test_plugin
```

### 验证插件安装

```bash
# 复制到 PostgreSQL 目录
cp -r lib/postgresql/* $PGSQL_DIR/lib/postgresql/
cp -r share/postgresql/* $PGSQL_DIR/share/postgresql/

# 重新加载配置
psql -c "SELECT pg_reload_conf();"

# 创建扩展
psql -c "CREATE EXTENSION pg_cron;"
```

---

## 参考资源

- [PostgreSQL PGXS 文档](https://www.postgresql.org/docs/current/extend-pgxs.html)
- [pg_cron GitHub](https://github.com/citusdata/pg_cron)
- [pg_repack GitHub](https://github.com/reorg/pg_repack)
- [pgvector GitHub](https://github.com/pgvector/pgvector)
- [TimescaleDB 文档](https://docs.timescale.com/timescaledb/latest/)
