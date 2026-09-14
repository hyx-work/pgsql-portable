# PostgreSQL 插件便携编译指南

## 概述

本文档记录了 `pgsql-portable` 项目中所有插件的便携编译过程，包括 pg_cron、pg_repack、pgvector、TimescaleDB 和 PostGIS。

所有插件遵循统一的编译规范，生成符合便携标准的插件包。

---

## 插件列表

| 插件 | 版本 | 功能 | 预加载 | 构建系统 |
|------|------|------|--------|----------|
| **pg_cron** | 1.6.7 | 定时任务调度 | ✅ 是 | PGXS |
| **pg_repack** | 1.5.3 | 在线表重组 | 否 | PGXS |
| **pgvector** | 0.8.6 | 向量相似度搜索 | 否 | PGXS |
| **TimescaleDB** | 2.29.2 | 时间序列数据库 | ✅ 是 | CMake |
| **PostGIS** | 3.6.4 | 空间地理信息扩展 | 否 | Autotools |

---

## 统一规范

### 目录结构

```
pgsql-portable/
├── cache/                          # 源码包缓存
│   ├── pg_cron-1.6.7.tar.gz
│   ├── pg_repack-1.5.3.tar.gz
│   ├── vector-0.8.6.tar.gz
│   ├── timescaledb-2.29.2.tar.gz
│   ├── sqlite-autoconf-3440000.tar.gz
│   ├── curl-8.4.0.tar.gz
│   ├── geos-3.14.1.tar.bz2
│   ├── proj-8.2.1.tar.gz
│   ├── gdal-3.9.2.tar.xz
│   ├── libxml2-2.9.14.tar.xz
│   ├── json-c-0.17-20230812.tar.gz
│   ├── protobuf-all-3.20.3.tar.gz
│   ├── protobuf-c-1.4.1.tar.gz
│   ├── pcre2-10.42.tar.gz
│   └── postgis-3.6.4.tar.gz
├── build/
│   └── host/
│       └── 16.15/
│           ├── pg_cron_v1.6.7/
│           ├── pg_repack_v1.5.3/
│           ├── vector_v0.8.6/
│           ├── timescaledb_v2.29.2/
│           └── postgis_v3.6.4/
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
│               ├── timescaledb-v2.29.2-pg16.x86_64.tar.gz
│               └── postgis-v3.6.4-pg16.x86_64.tar.gz
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

## PostGIS

### 功能说明

PostGIS 是 PostgreSQL 的空间地理信息扩展，提供地理对象、空间索引和空间查询功能，是 GIS 领域的标准数据库扩展。

### 基本信息

| 属性 | 值 |
|------|-----|
| 默认版本 | 3.6.4 |
| 预加载 | 否 |
| 官网 | https://postgis.net/ |
| 构建系统 | Autotools |
| 必需依赖 | GEOS 3.14.1, PROJ 8.2.1, SQLite3 3.44.0, CURL 8.4.0 |
| 可选依赖 | GDAL 3.9.2, LibXML2 2.9.14, JSON-C 0.17, protobuf 3.20.3, protobuf-c 1.4.1, PCRE2 10.42 |

### 编译命令

```bash
# 查看插件信息
./plugin.postgis.sh info

# 编译（使用默认版本）
./plugin.postgis.sh build host 16.15

# 编译（指定版本）
./plugin.postgis.sh build host 16.15 3.6.4

# 交叉编译 ARM64
./plugin.postgis.sh build aarch64-linux-gnu 16.15

# 跳过依赖编译
./plugin.postgis.sh build host 16.15 --skip-deps
```

### 依赖编译

PostGIS 的依赖需要编译到 `deps/` 目录：

```bash
# SQLite3 (PROJ 依赖)
cd sqlite-autoconf-3440000
./configure --prefix=/usr --disable-shared --enable-static --disable-readline
make -j$(nproc) && make DESTDIR="$deps" install

# CURL (PROJ 依赖)
cd curl-8.4.0
./configure --prefix=/usr --disable-shared --enable-static --without-ssl --without-zlib
make -j$(nproc) && make DESTDIR="$deps" install

# GEOS (几何引擎)
cd geos-3.14.1
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF
cmake --build build -j$(nproc) && env DESTDIR="$deps" cmake --install build

# PROJ (坐标转换，依赖 SQLite3 + CURL)
cd proj-8.2.1
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DBUILD_SHARED_LIBS=OFF \
    -DSQLITE3_INCLUDE_DIR="$deps/usr/include" -DSQLITE3_LIBRARY="$deps/usr/lib/libsqlite3.a" \
    -DCURL_INCLUDE_DIR="$deps/usr/include" -DCURL_LIBRARY="$deps/usr/lib/libcurl.a"
cmake --build build -j$(nproc) && env DESTDIR="$deps" cmake --install build

# protobuf (protobuf-c 依赖)
cd protobuf-3.20.3
./configure --prefix=/usr --disable-shared --enable-static
make -j$(nproc) && make DESTDIR="$deps" install

# protobuf-c (MVT 矢量切片支持)
cd protobuf-c-1.4.1
export PATH="$deps/usr/bin:$PATH" PROTOC="$deps/usr/bin/protoc"
./configure --prefix=/usr --disable-shared --enable-static LDFLAGS="-L$deps/usr/lib -static-libtool-libs"
make -j$(nproc) && make DESTDIR="$deps" install
```

### Configure 参数

```bash
./configure \
    --prefix=/usr \
    --with-pgconfig=$PG_CONFIG_BIN \
    --with-geosconfig=$deps/usr/bin/geos-config \
    --with-projdir=$deps/usr \
    --with-xml2config=$deps/usr/bin/xml2-config \
    --with-json-c=$deps/usr \
    --with-protobuf-c=$deps/usr \
    --with-pcre-dir=$deps/usr \
    --without-interrupt-tests
```

### 编译参数

```bash
make -j$(nproc)
make DESTDIR=$tmp_dest install
```

### RPATH 配置

使用 patchelf 修复 RPATH 以实现便携部署：

```bash
# .so 文件: $ORIGIN/.. (回退到上级目录找 libpq)
patchelf --set-rpath '$ORIGIN/..' lib/postgis-3.so

# bin 工具: $ORIGIN/../lib
patchelf --set-rpath '$ORIGIN/../lib' bin/shp2pgsql
```

### 配置参数

```sql
-- 安装扩展
CREATE EXTENSION postgis;

-- 检查版本
SELECT PostGIS_Version();

-- 创建空间表
CREATE TABLE spatial_data (
    id SERIAL PRIMARY KEY,
    name TEXT,
    geom GEOMETRY(Point, 4326)
);
```

### 使用示例

```sql
-- 创建 PostGIS 扩展
CREATE EXTENSION postgis;

-- 插入空间数据
INSERT INTO spatial_data (name, geom)
VALUES ('北京', ST_SetSRID(ST_MakePoint(116.404, 39.915), 4326));

-- 空间查询（查找1000米内的点）
SELECT name, ST_AsText(geom)
FROM spatial_data
WHERE ST_DWithin(
    geom::geography,
    ST_SetSRID(ST_MakePoint(116.404, 39.915), 4326)::geography,
    1000
);
```

### 常见问题

**1. libtool .la 路径错误**

错误：`libtool: error: cannot find the library '/usr/lib/libprotobuf.la'`

原因：libtool 记录了绝对路径，移动库文件后路径失效

解决：使用 `-static-libtool-libs` 参数强制静态链接
```bash
LDFLAGS="-L$deps/usr/lib -static-libtool-libs"
```

**2. C compiler cannot create executables**

错误：`configure: error: C compiler cannot create executables`

原因：编译环境问题（缺少依赖、路径错误等）

解决：
1. 检查 `config.log` 获取详细错误信息
2. 确保已安装必要的编译工具
3. 检查 `CFLAGS`、`LDFLAGS` 是否正确

**3. GEOS C++ 异常崩溃**

错误：`backend unexpectedly closed connection`

解决：重新编译 PostgreSQL 并链接 C++ 标准库
```bash
LDFLAGS=-lstdc++ ./configure [其他参数]
```

**4. proj.db 缺失**

错误：`cannot find proj.db`

解决：确保 PROJ 数据文件已正确安装
```bash
ls $deps/usr/share/proj/
```

**5. protoc 未找到**

警告：`protoc 未找到，protobuf-c 可能编译失败`

解决：确保 protobuf 已正确编译并安装到 deps
```bash
ls $deps/usr/bin/protoc
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
| PostGIS | Autotools | configure | make install DESTDIR |

### 路径参数对比

| 插件 | 库文件路径 | 共享文件路径 |
|------|-----------|-------------|
| pg_cron | pkglibdir=$tmp_dest/lib/postgresql | datadir=$tmp_dest/share/postgresql |
| pg_repack | pkglibdir=$tmp_dest/lib/postgresql | datadir=$tmp_dest/share/postgresql |
| pgvector | pkglibdir=$tmp_dest/lib/postgresql | datadir=$tmp_dest/share/postgresql |
| TimescaleDB | -DCMAKE_INSTALL_LIBDIR="lib/postgresql" | -DCMAKE_INSTALL_DATADIR="share/postgresql" |
| PostGIS | 通过 configure 和 make install DESTDIR | 通过 configure 和 make install DESTDIR |

### 依赖处理对比

| 插件 | 外部依赖 | 处理方式 |
|------|----------|----------|
| pg_cron | PostgreSQL | PGXS 自动检测 |
| pg_repack | PostgreSQL, libpq | 链接 PostgreSQL 源码库 |
| pgvector | PostgreSQL | PGXS 自动检测 |
| TimescaleDB | OpenSSL, ICU | CMake PREFIX_PATH |
| PostGIS | GEOS, PROJ, SQLite3, CURL, protobuf, protobuf-c, LibXML2, JSON-C, PCRE2, GDAL | 编译所有依赖到 deps 目录，configure 指定路径 |

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
    ├── timescaledb-v2.29.2-pg16.x86_64.tar.gz
    └── postgis-v3.6.4-pg16.x86_64.tar.gz
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
| PostGIS 3.6.4 | ✅ | ✅ | ✅ |

### 架构支持

| 插件 | x86_64 | aarch64 | s390x | armv7l |
|------|--------|---------|-------|--------|
| pg_cron | ✅ | ✅ | ✅ | ✅ |
| pg_repack | ✅ | ✅ | ✅ | ✅ |
| pgvector | ✅ | ✅ | ✅ | ✅ |
| TimescaleDB | ✅ | ✅ | ✅ | ✅ |
| PostGIS | ✅ | ✅ | ✅ | ✅ |

---

## 公共库 plugin.common.sh

所有插件脚本共享 `plugin.common.sh`，提供统一的基础设施：

```bash
# 引入方式 (每个插件脚本开头)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/plugin.common.sh"
```

### 可用函数

| 分类 | 函数 | 说明 |
|------|------|------|
| **日志** | `log_info` | 信息日志 `[INFO]` |
| | `log_warn` | 警告日志 `[WARN]` |
| | `log_error` | 错误日志 `[ERROR]` |
| | `log_success` | 成功日志 `[OK]` |
| | `log_section` | 阶段分隔线 |
| **执行** | `run_or_die "步骤名" "日志文件" cmd...` | 执行命令，失败时打印最后 N 行日志并终止 |
| **下载** | `download URL FILENAME CACHE_DIR` | 下载文件（带重试、超时） |
| | `verify_file FILENAME EXPECTED_SIZE EXPECTED_SHA256` | 校验文件大小和 SHA256 |
| | `extract_source ARCHIVE DEST_DIR` | 自动识别格式解压 |
| **工具** | `detect_jobs` | 检测 CPU 核心数（支持 `--jobs` 覆盖） |
| | `detect_arch` | 检测/标准化架构名 |
| | `get_version VAR_NAME DEFAULT VERSION ARG` | 版本优先级: 参数 > 环境变量 > 默认值 |
| **目录** | `init_plugin_dirs` | 初始化 `$build` `$tmp_dest` 等目录 |
| | `require_pg_config` | 验证 pg_config 存在并导出变量 |
| **打包** | `analyze_package NAME LOGFILE STRICT` | 依赖分析（ldd + RPATH） |
| | `strip_package DEST_DIR` | strip 所有 .so 和可执行文件 |
| | `fix_rpath BIN_DIR LIB_DIR` | 用 patchelf 修复 RPATH |

### 可配置变量

```bash
# 在 source plugin.common.sh 之前设置
LOG_TAIL_LINES=30       # 失败时打印的日志行数
CURL_MAX_TIME=600       # 下载超时 (秒)
```

### run_or_die 用法

```bash
# run_or_die 会在命令失败时:
# 1. 打印日志文件最后 LOG_TAIL_LINES 行
# 2. 调用 exit 1 终止脚本
run_or_die "编译 pg_cron" "$logfile" \
    make -C "$src_dir" USE_PGXS=1 -j"$jobs"
```

---

## 插件开发规范

### 脚本结构

每个插件脚本遵循统一结构：

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/plugin.common.sh"

# 默认版本
DEFAULT_XXX_VERSION="x.y.z"

# 插件元信息 (info 模式输出 JSON)
plugin_info() {
    local plugin_version="${1:-$DEFAULT_XXX_VERSION}"
    cat << EOF
{
  "name": "插件名",
  "version": "${plugin_version}",
  "preload": true/false,
  "config": {},
  "init_sql": "自定义初始化SQL（可选，无则省略）",
  "description": "插件描述"
}
EOF
}

# 使用说明
show_usage() { ... }

# 编译函数
build_xxx() {
    local src_dir="$1" logfile="$2" jobs="$3"
    # run_or_die 包裹每个 make/cmake 命令
}

# 打包函数
package_xxx() {
    local src_dir="$1" logfile="$2" jobs="$3"
    # analyze_package + strip_package 自动执行
}

# 主流程
main() {
    local action="$1"; shift
    case "$action" in
        info)    plugin_info "$@" ;;
        build)   parse_args ...; build_xxx ...; package_xxx ... ;;
        *)       show_usage; exit 1 ;;
    esac
}

main "$@"
```

### 目录变量

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # 脚本所在目录
basedir="$SCRIPT_DIR"
deps="$basedir/deps/$triple"                # 依赖库 (动态 .so)
dist="$basedir/dist/$triple/$pg_ver/pgsql"  # PostgreSQL 安装目录
build="$basedir/build/$triple/$pg_ver/插件名_v版本"  # 编译工作目录
cache="$basedir/cache"                      # 源码包缓存
plugins_dir="$basedir/dist/$triple/$pg_ver/plugins"  # 插件包输出
tmp_dest="$build/插件名"                    # 临时安装目录
logfile="$build/插件名.log"                 # 编译日志
```

### 命令行选项

所有插件脚本支持：

```bash
./plugin.xxx.sh build <triple> <PG版本> [插件版本] [选项]

选项:
  --jobs <n>      并行编译数 (默认: CPU核心数)
  --no-strict     依赖分析只报告不失败 (默认严格模式)
```

### 依赖分析

打包完成后自动执行：

```bash
# 分析 .so 文件依赖
analyze_package "插件名" "$logfile" "$strict"

# 内部执行:
# 1. ldd 检查未满足的依赖
# 2. readelf 检查 RPATH/RUNPATH
# 3. 严格模式下发现外部依赖则失败
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
- [PostGIS 文档](https://postgis.net/documentation/)
