# plugin.postgis.sh 编译历程（25 版演变）

## 总览

从 sh.1 到最终版，脚本从一个 922 行的简单编译器演变为 1452 行的完整构建系统。核心变化可归纳为 **5 个阶段**，其中 **cmake 构建问题** 和 **libpq 链接问题** 是贯穿全程的两大痛点。

---

## 第一阶段：基础框架

**sh.1（起点）**：922 行，最简框架
- 依赖：GEOS、PROJ、GDAL、LibXML2、JSON-C、protobuf-c、PCRE2（7 个）
- 全部静态编译（`--disable-shared --enable-static`）
- 日志输出到 stdout
- configure 参数手动逐个拼接

- 添加目录结构注释说明
- 优化日志格式
- 调整 configure 参数顺序

---

## 第二阶段：健壮性提升

- 新增 `verify_file()` 函数，支持 tar.gz/tar.bz2/tar.xz 校验
- 下载失败时自动重新下载
- 日志重定向到各依赖独立 `.log` 文件（`>>"$build/proj.log"`）
- 添加解压后空目录检查

- 改进错误处理（每个 build 函数添加 `|| { log_error; tail -30; exit 1 }` 模式）
- 优化并行编译参数
- 调整 configure 选项

---

## 第三阶段：依赖大扩展⭐ 转折点

新增 3 个关键依赖
- 新增 SQLite3 3440000（PROJ 依赖）
- 新增 CURL 8.4.0（PROJ 依赖）
- 新增 protobuf 3.20.3（protobuf-c 的上游依赖，之前假设系统已有 protoc）
- 新增 `source /opt/rh/devtoolset-11/enable`（CentOS 7 兼容）
- 日志重定向到 stderr（`>&2`），避免污染 stdout
- RPATH 便携支持：`-Wl,-rpath,$ORIGIN/../lib -Wl,--disable-new-dtags`
- 构建顺序：`sqlite3 → curl → libxml2 → json_c → pcre2 → protobuf → protobuf_c → proj → geos → gdal`

- protobuf-c 的 PROTOC 路径修复（使用 deps 中的 protoc）
- 添加 `PKG_CONFIG_PATH` 设置
- 修复 `.la` 文件导致的 libtool 路径错误（删除 protobuf 的 `.la` 文件）

---

## 第四阶段：静态→动态转变⭐ 核心转折

### cmake 问题（重点）

**sh15：cmake 安装路径混乱**

cmake 库（JSON-C、PROJ、GEOS、GDAL）的安装路径出现严重问题：

```bash
# 问题1：DESTDIR 模式 vs 直接安装模式混用
# 早期版本用 DESTDIR + prefix=/usr：
env DESTDIR="$deps" cmake --install build
# 这本身是正确的（安装到 $deps/usr/lib），但与 autotools 混用时容易出错

# sh15 修复：cmake 库改为直接安装到 $deps/usr（更直观）
cmake -B build \
    -DCMAKE_INSTALL_PREFIX="$deps/usr" \  # 直接指向 deps
    -DCMAKE_INSTALL_LIBDIR=lib \          # 防止 lib64 分支
    ...

# 不再用 DESTDIR，直接安装
cmake --install build  # 直接装到 $deps/usr/lib
```

```bash
# 问题2：lib64 目录分支
# CentOS 7 上 cmake 默认安装到 lib64/，导致后续找不到库

# sh15 修复：强制指定 lib 目录
-DCMAKE_INSTALL_LIBDIR=lib

# 但 PROJ 仍然有 lib64 问题，需要后处理：
if [ -d "$deps/usr/lib64" ]; then
    mv "$deps/usr/lib64"/* "$deps/usr/lib/" 2>/dev/null || true
    rmdir "$deps/usr/lib64" 2>/dev/null || true
fi
```

```bash
# 问题3：cmake RPATH 设置
# 动态库编译后 RPATH 指向编译机器的绝对路径，无法移植

# sh18 修复：编译期设置 RPATH 为相对路径
cmake -B build \
    -DCMAKE_INSTALL_RPATH='$ORIGIN' \           # RPATH 指向自身目录
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \       # 编译时就生效
    ...
```

**cmake 变化对比：**

| 参数 | sh.1（早期） | sh15（修复后） |
|---|---|---|
| 安装方式 | `DESTDIR="$deps" cmake --install` | `cmake --install` 直接安装 |
| 前缀 | `-DCMAKE_INSTALL_PREFIX=/usr` | `-DCMAKE_INSTALL_PREFIX="$deps/usr"` |
| lib 目录 | 未指定（默认 lib64） | `-DCMAKE_INSTALL_LIBDIR=lib` |
| RPATH | 未设置 | `-DCMAKE_INSTALL_RPATH='$ORIGIN'` |
| 构建类型 | `-DBUILD_SHARED_LIBS=OFF` | `-DBUILD_SHARED_LIBS=ON`（sh18） |

### libpq 问题（重点）

**libpq 链接失败**

PostGIS 编译时需要链接 PostgreSQL 的 libpq 库，但一直找不到：

```bash
# 问题现象：configure 报错 "could not find libpq"
# 原因：PostgreSQL 编译在 $dist/lib，但 configure 默认只搜索系统路径

# sh10 尝试1：添加 LIBS 显式指定
LIBS="-L$dist/lib -L$deps/usr/lib -lpq"

# 问题：configure 的测试程序找不到 libpq，因为 LD_LIBRARY_PATH 没设置

# sh10 尝试2：添加 LDFLAGS
LDFLAGS="-L$deps/usr/lib -L$dist/lib"

# 问题：静态链接的测试程序不需要运行，但动态链接需要
```

```bash
# sh15：使用 RPATH 引导（关键突破）
export LDFLAGS="-L$deps/usr/lib -L$dist/lib \
    -Wl,-rpath,\$ORIGIN/../lib \
    -Wl,--disable-new-dtags \
    -lstdc++ -lm -lpthread"

# 同时在 configure 参数中也传递 LDFLAGS 和 LIBS
./configure \
    LIBS="-L$dist/lib -L$deps/usr/lib -lpq" \
    LDFLAGS="..." \
    CPPFLAGS="-I$dist/include -I$deps/usr/include" \
    ...
```

**sh18 ~ sh20：动态化后的 libpq 问题**

转为动态库后，libpq 问题变得更复杂：

```bash
# 问题：PostGIS .so 需要运行时找到 libpq.so
# 但 libpq 在 $dist/lib，不在包内

# sh18 方案：RPATH 指向 PostgreSQL 的 lib 目录
export LDFLAGS="-L$deps/usr/lib -L$dist/lib \
    -Wl,-rpath,\$ORIGIN/../lib \
    -Wl,-rpath,\$ORIGIN/../../lib \
    -Wl,--disable-new-dtags"

# 但这要求目标机器的 PostgreSQL 安装在固定位置

# 最终方案：PostGIS .so 的 RPATH = $ORIGIN/..
# lib/postgresql/postgis-3.so → RPATH $ORIGIN/.. → 找到 lib/libpq.so
# 如果 libpq 在系统 PostgreSQL 目录，运行时通过 LD_LIBRARY_PATH 补充
```

```bash
# sh25 最终 configure：
./configure \
    --prefix=/usr \
    --with-pgconfig="$dist/bin/pg_config" \
    --with-pgsql-libdir="$dist/lib" \        # 新增：显式指定 libpq 目录
    --with-geosconfig="$deps/usr/bin/geos-config" \
    --with-projdir="$deps/usr" \
    --with-xmlconfig="$deps/usr/bin/xml2-config" \
    --with-gdalconfig="$deps/usr/bin/gdal-config" \
    --without-sfcgal \
    LDFLAGS="-L$deps/usr/lib -L$dist/lib -Wl,-rpath,'\$ORIGIN/..' -Wl,--disable-new-dtags -ldl -lm -lstdc++" \
    CPPFLAGS="-I$dist/include -I$deps/usr/include" \
    --without-interrupt-tests
```

**libpq 问题演变总结：**

| 版本 | 方案 | 结果 |
|---|---|---|
| sh.1 | 未处理 | configure 失败 |
| sh10 | `LIBS="-L$dist/lib -lpq"` | 运行时找不到 |
| sh15 | `LDFLAGS + RPATH` | 编译通过，运行时部分可用 |
| sh18 | `RPATH + LD_LIBRARY_PATH` | 动态库方案可行 |
| sh25 | `--with-pgsql-libdir` | 最终稳定方案 |

---

## 第五阶段：最终优化

**sh20**：打包结构重构

- 打包目录标准化：`lib/postgresql/`（PostGIS .so）、`lib/`（deps .so）、`share/postgresql/extension/`、`bin/`
- 新增 `strip --strip-unneeded` 瘦身
- 依赖分析使用 `LD_LIBRARY_PATH` 临时设置

**sh25（最终版之前）**：

- 添加 `--with-pgsql-libdir="$dist/lib"`（PostGIS configure）
- 添加 `--without-sfcgal`（禁用 SFCGAL）
- 简化 LDFLAGS：`-ldl -lm -lstdc++`
- 移除 `-lpq` 显式链接（PostGIS 自动检测）
- 依赖分析简化：直接 `ldd` 不加 `LD_LIBRARY_PATH`

**最终版 plugin.postgis.sh**：

- 添加 `init_sql` 到插件元信息（自动创建 postgis、postgis_raster、postgis_topology 等扩展）
- 保持 sh25 的所有优化

---

## 关键演变路径

```
sh.1: 简单静态编译（7 依赖）
  ↓
sh5: 添加下载验证和日志系统
  ↓
sh10: 大扩展（+SQLite3, CURL, protobuf = 11 依赖）⭐
  ↓
sh15: cmake 直装模式 + libpq RPATH 修复 ⭐⭐
  ↓
sh18: 全面动态化（静态→动态转变）⭐⭐⭐
  ↓
sh25: 最终优化（--with-pgsql-libdir、--without-sfcgal）
  ↓
最终版: 添加 init_sql 自动初始化
```

## 行数变化

| 版本 | 行数 | 主要变化 |
|---|---|---|
| sh.1 | 922 | 基础框架 |
| sh5 | 1000 | +下载验证、+日志系统 |
| sh10 | 1397 | +SQLite3、+CURL、+protobuf |
| sh15 | 1393 | cmake 直装优化、libpq RPATH |
| sh18 | ~1380 | 全面动态化 |
| sh25 | 1370 | 最终优化 |
| 最终版 | 1452 | +init_sql |

## 两大核心问题总结

### 问题一：cmake 构建路径混乱

**根因**：cmake 和 autotools 的安装模型不同
- autotools：`make install DESTDIR=$deps` → 安装到 `$deps/usr/lib`
- cmake：`cmake --install` → 默认安装到 `/usr/lib`；用 `DESTDIR` 会安装到 `$deps/usr/lib`；用 `-DCMAKE_INSTALL_PREFIX="$deps/usr"` 则直接安装到 `$deps/usr/lib`

**踩坑过程**：
1. autotools 和 cmake 的 DESTDIR 用法不一致 → 容易混淆
2. CentOS 7 的 lib64 问题 → 库文件分散
3. RPATH 指向编译机绝对路径 → 无法移植

**最终方案**：
```bash
cmake -B build \
    -DCMAKE_INSTALL_PREFIX="$deps/usr" \   # 直接指向目标
    -DCMAKE_INSTALL_LIBDIR=lib \           # 防止 lib64
    -DCMAKE_INSTALL_RPATH='$ORIGIN' \      # 相对路径 RPATH
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON    # 编译时生效
cmake --install build                      # 不用 DESTDIR
```

### 问题二：libpq 链接与运行时加载

**根因**：PostGIS 是 PostgreSQL 的插件，需要链接 libpq，但 libpq 的位置不固定

**踩坑过程**：
1. `--with-pgconfig` 能找到 pg_config，但找不到 libpq
2. `LIBS="-lpq"` 编译通过，但运行时 `dlopen` 找不到
3. 动态化后 libpq 成为运行时依赖，RPATH 必须正确

**最终方案**：
```bash
# 编译时
--with-pgsql-libdir="$dist/lib"    # 显式告诉 PostGIS libpq 在哪
LDFLAGS="-L$dist/lib"             # 链接时搜索路径

# 运行时
--set-rpath '$ORIGIN/..'           # postgis.so 在 lib/postgresql/，向上一级找 libpq.so
```

## 补充：protobuf-c 编译踩坑

**问题**：protobuf-c 需要 protoc 编译器，但系统可能没有

**踩坑过程**：
1. sh.1 假设系统有 protoc → 大多数机器没有
2. sh10 自己编译 protobuf → protobuf 编译需要 30+ 分钟
3. protobuf-c configure 找不到 deps 中的 protoc → 用系统旧版本
4. descriptor.proto 找不到 → 手动创建符号链接

**最终方案**：
```bash
# 1. 先编译 protobuf（含 protoc）
build_protobuf  # 安装到 $deps/usr

# 2. 确保 PATH 优先使用 deps 中的 protoc
export PATH="$deps/usr/bin:$PATH"
export PROTOC="$deps/usr/bin/protoc"

# 3. configure 和 make 都显式传递 PROTOC
./configure PROTOC="$deps/usr/bin/protoc"
make PROTOC="$deps/usr/bin/protoc"
```

---
