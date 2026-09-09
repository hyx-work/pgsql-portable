# pg_repack 便携编译指南

## 概述

pg_repack 是 PostgreSQL 的在线表重组工具，可以在不锁表的情况下清理表膨胀、重建索引。

---

## 基本信息

| 属性 | 值 |
|------|-----|
| 默认版本 | 1.5.3 |
| 预加载 | 否 |
| GitHub | https://github.com/reorg/pg_repack |
| 源码格式 | `ver_{version}.tar.gz`（注意 ver_ 前缀） |
| 构建系统 | PGXS |

---

## 环境要求

| 依赖 | 说明 |
|------|------|
| PostgreSQL | 已编译，提供 pg_config 和头文件 |
| PostgreSQL 源码 | 提供 libpgcommon.a、libpgport.a |
| GCC | C 编译器 |
| make | 构建工具 |

---

## 目录结构

```
pgsql-portable/
├── cache/
│   └── pg_repack-1.5.3.tar.gz          # 源码包
├── build/
│   └── host/
│       └── 16.15/
│           ├── postgresql/              # PostgreSQL 源码（用于链接）
│           └── pg_repack_v1.5.3/
│               ├── bin/                 # 客户端工具源码
│               ├── lib/                 # 扩展库源码
│               └── tmp_install/         # 影子安装目录
├── dist/
│   └── host/
│       └── 16.15/
│           ├── pgsql/                  # PostgreSQL 安装目录
│           └── plugins/
│               └── pg_repack-v1.5.3-pg16.x86_64.tar.gz
└── plugin.pg_repack.sh                  # 编译脚本
```

---

## 使用方法

### 查看插件信息

```bash
./plugin.pg_repack.sh info

# 输出
{
  "name": "pg_repack",
  "version": "1.5.3",
  "preload": false,
  "config": {},
  "description": "在线表重组"
}
```

### 编译命令

```bash
# 使用默认版本
./plugin.pg_repack.sh build host 16.15

# 指定版本
./plugin.pg_repack.sh build host 16.15 1.5.3

# 交叉编译 ARM64
./plugin.pg_repack.sh build aarch64-linux-gnu 16.15
```

---

## 编译流程

### 1. 下载源码

```bash
# 下载地址（注意 ver_ 前缀）
https://github.com/reorg/pg_repack/archive/refs/tags/ver_1.5.3.tar.gz

# 缓存位置
cache/pg_repack-1.5.3.tar.gz
```

### 2. 编译客户端（bin/）

```bash
PG_CONFIG_BIN="dist/host/16.15/pgsql/bin/pg_config"
PGXS_FILE=$(find dist/host/16.15/pgsql -name "pgxs.mk" | head -1)
PG_SRC="build/host/16.15/postgresql"

make -C bin USE_PGXS=1 \
    PG_CONFIG="$PG_CONFIG_BIN" \
    PGXS="$PGXS_FILE" \
    PG_CPPFLAGS="-I$PG_INCLUDE -I$PG_INTERNAL_INCLUDE -I$PG_SERVER_INCLUDE" \
    LDFLAGS="-L$PG_SRC/src/common -L$PG_SRC/src/port -L$dist/lib -Wl,-rpath=\$\$ORIGIN/../lib" \
    -j$(nproc)
```

### 3. 编译扩展（lib/）

```bash
make -C lib USE_PGXS=1 \
    PG_CONFIG="$PG_CONFIG_BIN" \
    PGXS="$PGXS_FILE" \
    PG_CPPFLAGS="-I$PG_INCLUDE -I$PG_INTERNAL_INCLUDE -I$PG_SERVER_INCLUDE" \
    -j$(nproc)
```

### 4. 打包

```bash
tmp_dest="build/host/16.15/pg_repack_v1.5.3/tmp_install"
mkdir -p "$tmp_dest"

make USE_PGXS=1 \
    PG_CONFIG="$PG_CONFIG_BIN" \
    PGXS="$PGXS_FILE" \
    bindir="$tmp_dest/bin" \
    pkglibdir="$tmp_dest/lib/postgresql" \
    datadir="$tmp_dest/share/postgresql" \
    sharedir="$tmp_dest/share/postgresql" \
    includedir_server="$tmp_dest/postgresql/include/server" \
    install

cd "$tmp_dest"
tar -czf dist/host/16.15/plugins/pg_repack-v1.5.3-pg16.x86_64.tar.gz lib share bin
```

---

## 编译参数

### 客户端编译参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `-C bin` | - | 只编译 bin 目录 |
| `USE_PGXS` | `1` | 使用 PGXS |
| `LDFLAGS` | `-Wl,-rpath=\$\$ORIGIN/../lib` | 设置 RPATH |

### 扩展编译参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `-C lib` | - | 只编译 lib 目录 |
| `USE_PGXS` | `1` | 使用 PGXS |

### 打包参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `bindir` | `$tmp_dest/bin` | 可执行文件目录 |
| `pkglibdir` | `$tmp_dest/lib/postgresql` | 库文件目录 |
| `datadir` | `$tmp_dest/share/postgresql` | 数据文件目录 |
| `sharedir` | `$tmp_dest/share/postgresql` | 共享文件目录 |

---

## 插件包结构

```
pg_repack-v1.5.3-pg16.x86_64.tar.gz
├── bin/
│   └── pg_repack                      # 命令行工具
├── lib/
│   └── postgresql/
│       └── pg_repack.so               # 扩展库
└── share/
    └── postgresql/
        └── extension/
            ├── pg_repack.control
            ├── pg_repack--1.0.sql
            └── pg_repack--1.4--1.5.sql
```

---

## RPATH 说明

pg_repack 客户端需要链接 libpq，通过 RPATH 设置运行时库搜索路径：

```bash
# 编译时设置
LDFLAGS="-L$PG_SRC/src/common -L$PG_SRC/src/port -L$dist/lib -Wl,-rpath=\$\$ORIGIN/../lib"

# RPATH 含义
$$ORIGIN     → 可执行文件所在目录
/../lib      → 上级目录的 lib 子目录
```

### 验证 RPATH

```bash
readelf -d pg_repack | grep -E "RPATH|RUNPATH"
# 输出: RPATH: [$ORIGIN/../lib]
```

---

## 使用示例

### 基本用法

```bash
# 重组单个表
pg_repack -d mydb -t mytable

# 重组所有膨胀表
pg_repack -d mydb

# 重建索引
pg_repack -d mydb -i myindex

# 并行重组（4个Worker）
pg_repack -d mydb -j 4
```

### 高级选项

```bash
# 只清理，不重建索引
pg_repack -d mydb --no-order

# 使用特定表空间
pg_repack -d mydb -t mytable -T fast_space

# 查看重组进度
pg_repack -d mydb --status

# 干运行（只显示会做什么）
pg_repack -d mydb --dry-run
```

### 常用命令

```bash
# 完整重组（推荐）
pg_repack -d mydb -t mytable --no-superuser-check

# 重建所有索引
pg_repack -d mydb --index 'my_table_*'

# 排除特定表
pg_repack -d mydb --exclude 'temp_*'

# 设置内存限制
pg_repack -d mydb -t mytable --elevel debug
```

---

## 常见问题

### 1. 找不到 PostgreSQL 源码

**错误**：
```
cannot find -lpgcommon
cannot find -lpgport
```

**解决**：确保 PostgreSQL 源码目录存在
```bash
ls build/host/16.15/postgresql/src/common/libpgcommon.a
ls build/host/16.15/postgresql/src/port/libpgport.a
```

### 2. RPATH 未设置

**问题**：运行 pg_repack 时找不到 libpq
```bash
# 检查 RPATH
readelf -d pg_repack | grep RPATH

# 如果没有设置，重新编译
make -C bin LDFLAGS="-Wl,-rpath=\$\$ORIGIN/../lib" ...
```

### 3. 权限不足

**错误**：
```
ERROR: must be superuser to use pg_repack
```

**解决**：
```bash
# 使用 --no-superuser-check（如果数据库允许）
pg_repack -d mydb --no-superuser-check

# 或者以 postgres 用户运行
sudo -u postgres pg_repack -d mydb
```

### 4. 锁等待超时

**错误**：
```
ERROR: lock timeout
```

**解决**：
```bash
# 增加锁等待时间
pg_repack -d mydb -t mytable --wait-timeout 300

# 或者在低峰期执行
```

---

## 调试技巧

### 查看详细日志

```bash
# 使用 verbose 模式
pg_repack -d mydb -t mytable --elevel debug

# 查看编译日志
cat build/host/16.15/pg_repack_v1.5.3/pg_repack.log
```

### 手动测试

```bash
# 复制插件到 PostgreSQL
cp build/host/16.15/pg_repack_v1.5.3/tmp_install/bin/pg_repack \
   dist/host/16.15/pgsql/bin/

cp build/host/16.15/pg_repack_v1.5.3/tmp_install/lib/postgresql/pg_repack.so \
   dist/host/16.15/pgsql/lib/postgresql/

cp build/host/16.15/pg_repack_v1.5.3/tmp_install/share/postgresql/extension/* \
   dist/host/16.15/pgsql/share/postgresql/extension/

# 创建扩展
psql -d mydb -c "CREATE EXTENSION pg_repack;"

# 测试重组
pg_repack -d mydb -t mytable --dry-run
```

---

## 参考资源

- [pg_repack GitHub](https://github.com/reorg/pg_repack)
- [pg_repack 文档](https://github.com/reorg/pg_repack#readme)
- [PostgreSQL 膨胀处理](https://www.postgresql.org/docs/current/routine-vacuuming.html)
