# TimescaleDB 便携编译指南

## 概述

本文档记录了在 `pgsql-portable` 项目中编译 TimescaleDB 的完整过程，包括环境准备、参数配置、常见问题及解决方案。

TimescaleDB 是一个开源的时间序列数据库，作为 PostgreSQL 扩展运行，提供高效的时间序列数据存储和查询能力。

---

## 环境要求

### 必需依赖

| 依赖 | 版本要求 | 说明 |
|------|----------|------|
| **CMake** | ≥ 3.11 | 构建系统（推荐 3.28.x） |
| **GCC/G++** | 支持 C++17 | 编译器 |
| **PostgreSQL** | 已编译 | 提供 pg_config 和头文件 |
| **OpenSSL** | - | 加密通信支持 |

### CentOS 7 安装 CMake

```bash
# 方法: 使用二进制包（推荐）
cd /opt
wget https://github.com/Kitware/CMake/releases/download/v3.28.6/cmake-3.28.6-linux-x86_64.tar.gz
tar -xzf cmake-3.28.6-linux-x86_64.tar.gz
ln -sf /opt/cmake-3.28.6-linux-x86_64/bin/cmake /usr/local/bin/cmake

# 验证
cmake --version
```

### 静态依赖库

TimescaleDB 编译需要以下静态库（位于 `deps/` 目录）：

| 库 | 版本 | 用途 |
|----|------|------|
| OpenSSL | 3.5.7 | SSL/TLS 支持 |
| zlib | 1.3.2 | 数据压缩 |
| ICU | 74.2 | Unicode/国际化 |

---

## 目录结构

```
pgsql-portable/
├── cache/                          # 源码包缓存
│   ├── timescaledb-2.29.2.tar.gz
│   └── ...
├── build/
│   └── host/
│       └── 16.15/
│           └── timescaledb_v2.29.2/
│               ├── build/          # CMake 构建目录
│               └── tmp_install/    # 影子安装目录
│                   ├── lib/
│                   │   └── postgresql/
│                   │       └── timescaledb.so
│                   └── share/
│                       └── postgresql/
│                           └── extension/
│                               ├── timescaledb.control
│                               └── timescaledb--2.29.2.sql
├── deps/
│   └── host/                       # 静态依赖库
│       └── usr/
│           ├── include/
│           └── lib/
├── dist/
│   └── host/
│       └── 16.15/
│           ├── pgsql/              # PostgreSQL 安装目录
│           │   ├── bin/
│           │   │   └── pg_config
│           │   ├── lib/
│           │   └── share/
│           └── plugins/            # 插件包输出目录
│               ├── timescaledb-v2.29.2-pg16.x86_64.tar.gz
│               └── ...
└── plugin.timescaledb.sh           # TimescaleDB 编译脚本
```

---

## 编译参数说明

### CMake 核心参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `-DCMAKE_BUILD_TYPE` | `Release` | 生产环境构建，启用优化 |
| `-DCMAKE_INSTALL_PREFIX` | `/` | 安装前缀，避免 `/usr` 路径污染 |
| `-DCMAKE_INSTALL_LIBDIR` | `lib/postgresql` | 库文件安装目录 |
| `-DCMAKE_INSTALL_DATADIR` | `share/postgresql` | 数据文件安装目录 |
| `-DCMAKE_PREFIX_PATH` | `$deps/usr` | 依赖库搜索路径 |

### PostgreSQL 路径参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `-DPG_CONFIG` | `$dist/bin/pg_config` | PostgreSQL 配置工具路径 |
| `-DPG_LIBDIR` | `/lib/postgresql` | 库文件目录（覆盖 pg_config） |
| `-DPG_PKGLIBDIR` | `/lib/postgresql` | 插件库目录 |
| `-DPG_SHAREDIR` | `/share/postgresql` | 共享文件目录 |
| `-DPG_DATADIR` | `/share/postgresql` | 数据文件目录 |
| `-DPG_INCLUDEDIR` | `/include/postgresql` | 头文件目录 |

### 功能开关参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `-DUSE_OPENSSL` | `ON` | 启用 OpenSSL 支持 |
| `-DSEND_TELEMETRY_DEFAULT` | `OFF` | 关闭匿名遥测 |
| `-DREGRESS_CHECKS` | `OFF` | 跳过回归测试 |
| `-DWARNINGS_AS_ERRORS` | `OFF` | 不将警告视为错误 |

### 无效参数（已移除）

以下参数在 TimescaleDB 2.29.2 中无效，会被 CMake 忽略：

```bash
# ❌ 已移除
-DUSE_ICU=ON      # TimescaleDB 通过 PG_CONFIG 自动检测
-DUSE_LZ4=OFF     # 已废弃
-DUSE_ZSTD=OFF    # 已废弃
```

---

## 使用方法

### 基本编译

```bash
# 编译当前主机架构
./plugin.timescaledb.sh build host 16.15

# 交叉编译 ARM64
./plugin.timescaledb.sh build aarch64-linux-gnu 16.15

# 指定 TimescaleDB 版本
./plugin.timescaledb.sh build host 16.15 2.29.2
```

### 查看插件信息

```bash
# 使用默认版本
./plugin.timescaledb.sh info

# 指定版本
./plugin.timescaledb.sh info 2.29.2
```

### 输出格式

```json
{
  "name": "timescaledb",
  "version": "2.29.2",
  "preload": true,
  "config": {
    "timescaledb.max_background_workers": 8,
    "timescaledb.telemetry_level": "off"
  },
  "description": "时间序列数据优化的 PostgreSQL 扩展"
}
```

---

## 编译流程

### 1. 下载源码

```bash
# 源码包缓存位置
cache/timescaledb-2.29.2.tar.gz

# 下载地址
https://github.com/timescale/timescaledb/archive/refs/tags/2.29.2.tar.gz
```

### 2. CMake 配置

```bash
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/ \
    -DCMAKE_INSTALL_LIBDIR="lib/postgresql" \
    -DCMAKE_INSTALL_DATADIR="share/postgresql" \
    -DPG_CONFIG="/path/to/pg_config" \
    -DCMAKE_PREFIX_PATH="/path/to/deps/usr" \
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

### 3. 编译

```bash
cmake --build build -j $(nproc)
```

### 4. 影子安装

```bash
# 使用 DESTDIR 环境变量（不要使用 --destdir 参数）
DESTDIR="/tmp/timescaledb_install" cmake --install .
```

### 5. 打包

```bash
cd /tmp/timescaledb_install
tar -czf timescaledb-v2.29.2-pg16.x86_64.tar.gz lib share
```

---

## 影子目录机制

### 工作原理

影子目录（Shadow Directory）是一种临时安装目录，用于：

1. **隔离安装过程** - 不污染系统目录
2. **方便打包** - 生成可移植的 tar 包
3. **保持独立** - 与 PostgreSQL 主目录分离

### 目录映射

| 阶段 | CMAKE_INSTALL_PREFIX | DESTDIR | 实际物理路径 |
|------|---------------------|---------|-------------|
| 配置 | `/` | 未设置 | `/lib/postgresql/`（理论） |
| 安装 | `/` | `$tmp_dest` | `$tmp_dest/lib/postgresql/`（实际） |
| 打包 | `/` | 无 | `lib/postgresql/`（在 tar 包内） |

### 物理路径示例

```
/root/pgsql-portable/build/host/16.15/timescaledb_v2.29.2/tmp_install/
├── lib/
│   └── postgresql/
│       └── timescaledb.so
└── share/
    └── postgresql/
        └── extension/
            ├── timescaledb.control
            └── timescaledb--2.29.2.sql
```

---

## 打包规范

### 插件包结构

```
timescaledb-v2.29.2-pg16.x86_64.tar.gz
├── lib/
│   └── postgresql/
│       ├── timescaledb.so
│       └── timescaledb.so.2.29.2
└── share/
    └── postgresql/
        └── extension/
            ├── timescaledb.control
            ├── timescaledb--2.29.2.sql
            └── ...
```

### 与其他插件对齐

| 插件 | 库文件路径 | 共享文件路径 |
|------|-----------|-------------|
| pg_cron | `lib/postgresql/pg_cron.so` | `share/postgresql/extension/pg_cron.control` |
| pg_repack | `lib/postgresql/pg_repack.so` | `share/postgresql/extension/pg_repack.control` |
| pgvector | `lib/postgresql/vector.so` | `share/postgresql/extension/vector.control` |
| **timescaledb** | `lib/postgresql/timescaledb.so` | `share/postgresql/extension/timescaledb.control` |

---

## 常见问题

### 1. CMake 版本过低

**错误信息**：
```
CMake 3.11 or higher is required. You are running version 2.8.12
```

**解决方案**：
```bash
# 安装 CMake 3.28.6
cd /opt
wget https://github.com/Kitware/CMake/releases/download/v3.28.6/cmake-3.28.6-linux-x86_64.tar.gz
tar -xzf cmake-3.28.6-linux-x86_64.tar.gz
ln -sf /opt/cmake-3.28.6-linux-x86_64/bin/cmake /usr/local/bin/cmake
```

### 2. 套娃路径问题

**问题描述**：文件被安装到 `tmp_install/root/pgsql-portable/.../lib/` 而不是 `tmp_install/lib/`

**根本原因**：CMake 从 `pg_config` 继承了绝对路径

**解决方案**：
```bash
# 强制指定路径参数
-DPG_LIBDIR="/lib/postgresql" \
-DPG_PKGLIBDIR="/lib/postgresql" \
-DPG_SHAREDIR="/share/postgresql" \
-DPG_DATADIR="/share/postgresql" \
```

### 3. DESTDIR 参数错误

**错误信息**：
```
Unknown argument --destdir
```

**解决方案**：
```bash
# ❌ 错误
cmake --install . --prefix /usr --destdir "$tmp_dest"

# ✅ 正确
DESTDIR="$tmp_dest" cmake --install .
```

### 4. CMake 警告：无效参数

**警告信息**：
```
CMake Warning:
  Manually-specified variables were not used by the project:
    USE_ICU
    USE_LZ4
    USE_ZSTD
```

**解决方案**：移除这些无效参数，TimescaleDB 2.29.2 通过 `PG_CONFIG` 自动检测

### 5. 找不到 pg_config

**错误信息**：
```
错误: 找不到 pg_config: /path/to/pg_config
请先为 host 编译安装 PostgreSQL
```

**解决方案**：先运行 `./pgsql-build.sh host 16.15` 编译 PostgreSQL

### 6. ICU 链接失败

**问题描述**：静态编译的 ICU 无法找到

**解决方案**：
```bash
# 检查 ICU 是否存在
ls $deps/usr/include/unicode/
ls $deps/usr/lib/libicuuc.a

# 如果存在，显式指定路径
-DICU_ROOT=$deps/usr \
-DICU_INCLUDE_DIR=$deps/usr/include \
```

---

## 静态编译说明

### 静态依赖检查

```bash
# 检查 PostgreSQL 编译选项
$dist/bin/pg_config --configure | grep -E "with-openssl|with-icu"

# 检查静态库
ls -la $deps/usr/lib/*.a
```

### 编译后验证

```bash
# 检查 .so 文件依赖
ldd $tmp_dest/lib/postgresql/timescaledb.so

# 应该只依赖系统库（libc、libpthread 等）
# 不应该依赖 OpenSSL、ICU 等（已静态链接）
```

### 静态库列表

| 库 | 静态库文件 | 说明 |
|----|-----------|------|
| OpenSSL | `libssl.a`, `libcrypto.a` | SSL/TLS |
| zlib | `libz.a` | 压缩 |
| ICU | `libicuuc.a`, `libicui18n.a`, `libicudata.a` | Unicode |
| ncurses | `libncurses.a` | 终端控制 |
| libedit | `libedit.a` | 命令行编辑 |

---

## 交叉编译

### 支持的架构

| Triple | 架构 | 说明 |
|--------|------|------|
| `host` | 当前主机 | 自动检测 |
| `x86_64-linux-gnu` | x86_64 | Intel/AMD 64位 |
| `aarch64-linux-gnu` | aarch64 | ARM64（鲲鹏/飞腾） |
| `s390x-linux-gnu` | s390x | IBM Z |
| `arm-linux-gnueabihf` | armv7l | ARM 32位 |

### 交叉编译命令

```bash
# ARM64 交叉编译
./plugin.timescaledb.sh build aarch64-linux-gnu 16.15

# x86_64 交叉编译
./plugin.timescaledb.sh build x86_64-linux-gnu 16.15
```

### 交叉编译环境变量

```bash
# 脚本自动设置
export CC="${triple}-gcc"
export CXX="${triple}-g++"
export STRIP="${triple}-strip"
export PKG_CONFIG_PATH="$deps/usr/lib/pkgconfig"
```

---

## 版本支持

### TimescaleDB 版本

| 版本 | 状态 | 说明 |
|------|------|------|
| 2.29.2 | ✅ 默认 | 当前默认编译版本 |
| 2.x.x | ✅ 支持 | 通过参数指定 |

### PostgreSQL 版本兼容性

| TimescaleDB | PostgreSQL 16 | PostgreSQL 17 | PostgreSQL 18 |
|-------------|---------------|---------------|---------------|
| 2.29.2 | ✅ | ✅ | ✅ |

---

## 部署使用

### 安装插件

```bash
# 解压插件包到 PostgreSQL 目录
cd $PGSQL_DIR
tar -xzf timescaledb-v2.29.2-pg16.x86_64.tar.gz

# 重新加载配置
psql -c "SELECT pg_reload_conf();"

# 创建扩展
psql -c "CREATE EXTENSION timescaledb;"
```

### 配置参数

```sql
-- postgresql.conf
shared_preload_libraries = 'timescaledb'
timescaledb.max_background_workers = 8
timescaledb.telemetry_level = 'off'
```

### 验证安装

```sql
SELECT * FROM pg_available_extensions WHERE name = 'timescaledb';
SELECT extname, extversion FROM pg_extension WHERE extname = 'timescaledb';
```

---

## 调研过程回顾

### 第一阶段：环境准备

1. CentOS 7 默认 CMake 版本过低（2.8.x）
2. 尝试4种安装方法，最终选择二进制包方式
3. 安装 CMake 3.28.6 到 `/opt/` 目录

### 第二阶段：编译参数调研

1. 分析 TimescaleDB 官方文档
2. 确定核心 CMake 参数
3. 识别无效参数（USE_ICU/USE_LZ4/USE_ZSTD）

### 第三阶段：打包路径问题

1. 发现套娃路径问题
2. 分析 DESTDIR 与 --destdir 的区别
3. 确定使用 DESTDIR 环境变量

### 第四阶段：路径对齐

1. 确保与 pg_cron、pg_repack 规范一致
2. 添加路径修正逻辑
3. 验证打包结构

### 最终成果

- ✅ CMake 3.28.6 安装配置
- ✅ 无效参数清理
- ✅ 套娃路径修复
- ✅ DESTDIR 正确使用
- ✅ 与现有插件规范对齐

---

## 参考资源

- [TimescaleDB 官方文档](https://docs.timescale.com/timescaledb/latest/)
- [TimescaleDB GitHub](https://github.com/timescale/timescaledb)
- [CMake 官方文档](https://cmake.org/cmake/help/latest/)
- [PostgreSQL 文档](https://www.postgresql.org/docs/)
