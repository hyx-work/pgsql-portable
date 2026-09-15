# PostGIS 便携编译指南

## 概述

本文档记录了 PostGIS 的完整编译过程，包括所有依赖库的动态编译，用于生成便携式 PostgreSQL 空间扩展包。

---

## 编译工具要求

| 工具 | 最低版本 | 说明 |
|------|---------|------|
| **cmake** | >= 3.16 | GEOS 要求 3.15+，GDAL 要求 3.16+ |
| **protobuf** | 3.20.3 | 必须是 3.20.x，见 protobuf 章节说明 |
| **protobuf-c** | 1.4.1 | 必须搭配 protobuf < 22.0 |
| **patchelf** | 任意 | ✅ 必需，RPATH 修复 |
| **strip** | 任意 | 可选，瘦身（未安装时跳过） |
| 其他 | - | make, autoconf, automake, libtool, curl, tar, ldd, file（系统自带） |

---

## 基本信息

| 组件 | 版本 | 构建系统 | 必需/可选 |
|------|------|---------|----------|
| **PostGIS** | 3.6.4 | Autotools | - |
| **GEOS** | 3.14.1 | CMake | ✅ 必需 |
| **PROJ** | 8.2.1 | CMake | ✅ 必需 |
| **SQLite3** | 3.44.0 | Autotools | ✅ PROJ 依赖 |
| **CURL** | 8.4.0 | Autotools | ✅ PROJ 依赖 |
| **GDAL** | 3.9.2 | CMake | 可选 |
| **LibXML2** | 2.9.14 | Autotools | 可选 |
| **JSON-C** | 0.17 | CMake | 可选 |
| **protobuf** | 3.20.3 | Autotools | ✅ protobuf-c 依赖 |
| **protobuf-c** | 1.4.1 | Autotools | 可选 |
| **PCRE2** | 10.42 | Autotools | 可选 |

---

## 源码下载

| 组件 | 下载地址 |
|------|---------|
| PostGIS 3.6.4 | `https://download.osgeo.org/postgis/source/postgis-3.6.4.tar.gz` |
| GEOS 3.14.1 | `https://download.osgeo.org/geos/geos-3.14.1.tar.bz2` |
| PROJ 8.2.1 | `https://download.osgeo.org/proj/proj-8.2.1.tar.gz` |
| GDAL 3.9.2 | `https://download.osgeo.org/gdal/3.9.2/gdal-3.9.2.tar.xz` |
| SQLite3 3.44.0 | `https://sqlite.org/2023/sqlite-autoconf-3440000.tar.gz` |
| CURL 8.4.0 | `https://curl.se/download/curl-8.4.0.tar.gz` |
| LibXML2 2.9.14 | `https://download.gnome.org/sources/libxml2/2.9/libxml2-2.9.14.tar.xz` |
| JSON-C 0.17 | `https://github.com/json-c/json-c/archive/refs/tags/json-c-0.17-20230812.tar.gz` |
| protobuf 3.20.3 | `https://github.com/protocolbuffers/protobuf/releases/download/v3.20.3/protobuf-all-3.20.3.tar.gz` |
| protobuf-c 1.4.1 | `https://github.com/protobuf-c/protobuf-c/releases/download/v1.4.1/protobuf-c-1.4.1.tar.gz` |
| PCRE2 10.42 | `https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.42/pcre2-10.42.tar.gz` |

---

## 依赖关系图

```
PostGIS 3.6.4
├── GEOS 3.14.1              [必需] 几何引擎
│   └── (无外部依赖)
│
├── PROJ 8.2.1               [必需] 坐标转换
│   ├── SQLite3 3.44.0       [必需] proj.db 存储
│   └── CURL 8.4.0           [必需] 网格数据下载
│
├── protobuf-c 1.4.1         [可选] MVT 矢量切片
│   └── protobuf 3.20.3      [必需] protoc 编译器
│
├── LibXML2 2.9.14           [可选] KML/GML 支持
├── JSON-C 0.17              [可选] GeoJSON 支持
├── PCRE2 10.42              [可选] 地址标准化
│
└── GDAL 3.9.2               [可选] 栅格支持
    ├── PROJ 8.2.1           [必需]
    └── GEOS 3.14.1          [推荐]
```

### 编译顺序

```
第 1 层: SQLite3, CURL, LibXML2, JSON-C, PCRE2, protobuf (无依赖)
第 2 层: protobuf-c (依赖 protobuf)
第 3 层: PROJ (依赖 SQLite3, CURL)
第 4 层: GEOS (无外部依赖)
第 5 层: GDAL (依赖 PROJ + GEOS)
第 6 层: PostGIS (依赖所有)
```

---

## SQLite3 编译

### 基本信息

| 属性 | 值 |
|------|-----|
| 版本 | 3.44.0 |
| 构建系统 | Autotools |
| 依赖 | 无 |

### 编译命令

```bash
tar xzf sqlite-autoconf-3440000.tar.gz
cd sqlite-autoconf-3440000

./configure \
    --prefix=/usr \
    --enable-shared \
    --disable-static \
    --disable-readline

make -j$(nproc)
make DESTDIR="$deps" install
```

### 输出文件

```
usr/lib/libsqlite3.so
usr/lib/libsqlite3.so.0
usr/include/sqlite3.h
usr/bin/sqlite3
```

---

## CURL 编译

### 基本信息

| 属性 | 值 |
|------|-----|
| 版本 | 8.4.0 |
| 构建系统 | Autotools |
| 依赖 | 无 |

### 编译命令

```bash
tar xzf curl-8.4.0.tar.gz
cd curl-8.4.0

./configure \
    --prefix=/usr \
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
    --disable-libcurl-option

make -j$(nproc)
make DESTDIR="$deps" install
```

### 输出文件

```
usr/lib/libcurl.so
usr/lib/libcurl.so.4
usr/include/curl/
usr/bin/curl
```

---

## GEOS 编译

### 基本信息

| 属性 | 值 |
|------|-----|
| 版本 | 3.14.1 |
| 构建系统 | CMake |
| 依赖 | 无外部依赖 |

### 编译命令

```bash
tar xfj geos-3.14.1.tar.bz2
cd geos-3.14.1

cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$deps/usr" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_INSTALL_RPATH='$ORIGIN' \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DBUILD_GEOSOP=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_DOCUMENTATION=OFF

cmake --build build -j$(nproc)
cmake --install build

# 合并 lib64 到 lib (CentOS 7 等系统)
if [ -d "$deps/usr/lib64" ]; then
    mv "$deps/usr/lib64"/* "$deps/usr/lib/" 2>/dev/null || true
    rmdir "$deps/usr/lib64" 2>/dev/null || true
fi
```

### 输出文件

```
usr/lib/libgeos.so
usr/lib/libgeos.so.3.14.1
usr/lib/libgeos_c.so
usr/lib/libgeos_c.so.1
usr/include/geos_c.h
usr/bin/geos-config
```

---

## PROJ 编译

### 基本信息

| 属性 | 值 |
|------|-----|
| 版本 | 8.2.1 |
| 构建系统 | CMake |
| 依赖 | SQLite3, CURL |

### 编译命令

```bash
tar xzf proj-8.2.1.tar.gz
cd proj-8.2.1

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
    -DCURL_LIBRARY="$deps/usr/lib/libcurl.so"

cmake --build build -j$(nproc)
cmake --install build

# 合并 lib64 到 lib (CentOS 7 等系统)
if [ -d "$deps/usr/lib64" ]; then
    mv "$deps/usr/lib64"/* "$deps/usr/lib/" 2>/dev/null || true
    rmdir "$deps/usr/lib64" 2>/dev/null || true
fi
```

### 输出文件

```
usr/lib/libproj.so
usr/lib/libproj.so.22
usr/include/proj.h
usr/bin/proj
usr/share/proj/
```

---

## protobuf 编译

### 基本信息

| 属性 | 值 |
|------|-----|
| 版本 | 3.20.3 |
| 构建系统 | Autotools |
| 依赖 | 无 |

### 版本要求说明

**必须使用 protobuf 3.20.x**，原因如下：

1. **protobuf-c 1.4.1 兼容性**：protobuf-c 1.4.1 无法编译 protobuf >= 22.0（22.0 引入了 breaking changes 和 abseil 依赖），详见 [protobuf-c#544](https://github.com/protobuf-c/protobuf-c/issues/544)。protobuf 版本号在 22.x 重新编号，3.20.x 是 3.x 系列最后一个版本。

2. **安全修复**：
   - 3.20.2 修复 CVE-2022-1941（MessageSet 解析漏洞导致 DoS）
   - 3.20.3 修复 CVE-2022-3171（二进制数据解析漏洞导致 DoS）

3. **版本号对照**：protobuf 3.20.x = 最后的 3.x 系列；22.x = 新编号方案开始（2023年3月）

### 编译命令

```bash
tar xzf protobuf-all-3.20.3.tar.gz
cd protobuf-3.20.3

./configure \
    --prefix=/usr \
    --enable-shared \
    --disable-static

make -j$(nproc)
make DESTDIR="$deps" install
```

### 输出文件

```
usr/lib/libprotobuf.so
usr/lib/libprotobuf.so.31
usr/lib/libprotoc.so
usr/lib/libprotoc.so.31
usr/bin/protoc
usr/include/google/protobuf/
```

---

## protobuf-c 编译

### 基本信息

| 属性 | 值 |
|------|-----|
| 版本 | 1.4.1 |
| 构建系统 | Autotools |
| 依赖 | protobuf (protoc) |

### 编译命令

```bash
tar xzf protobuf-c-1.4.1.tar.gz
cd protobuf-c-1.4.1

export PATH="$deps/usr/bin:$PATH"
export PKG_CONFIG_PATH="$deps/usr/lib/pkgconfig:$PKG_CONFIG_PATH"
export PROTOC="$deps/usr/bin/protoc"

./configure \
    --prefix=/usr \
    --enable-shared \
    --disable-static \
    PROTOC="$deps/usr/bin/protoc"

make -j$(nproc) \
    PROTOC="$deps/usr/bin/protoc"

make DESTDIR="$deps" install
```

### 常见问题

**libtool .la 路径问题**

错误：`libtool: error: cannot find the library '/usr/lib/libprotobuf.la'`

解决：编译时使用动态库模式，libtool 会正确处理依赖关系

---

## LibXML2 编译

### 基本信息

| 属性 | 值 |
|------|-----|
| 版本 | 2.9.14 |
| 构建系统 | Autotools |
| 依赖 | 无 |

### 编译命令

```bash
tar xf libxml2-2.9.14.tar.xz
cd libxml2-2.9.14

./configure \
    --prefix=/usr \
    --enable-shared \
    --disable-static \
    --without-python \
    --without-icu \
    --without-lzma

make -j$(nproc)
make DESTDIR="$deps" install
```

---

## JSON-C 编译

### 基本信息

| 属性 | 值 |
|------|-----|
| 版本 | 0.17 |
| 构建系统 | CMake |
| 依赖 | 无 |

### 编译命令

```bash
tar xzf json-c-0.17-20230812.tar.gz
cd json-c-json-c-0.17-20230812

cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$deps/usr" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_INSTALL_RPATH='$ORIGIN' \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DBUILD_TESTING=OFF \
    -DDISABLE_WERROR=ON

cmake --build build -j$(nproc)
cmake --install build
```

---

## PCRE2 编译

### 基本信息

| 属性 | 值 |
|------|-----|
| 版本 | 10.42 |
| 构建系统 | Autotools |
| 依赖 | 无 |

### 编译命令

```bash
tar xzf pcre2-10.42.tar.gz
cd pcre2-10.42

./configure \
    --prefix=/usr \
    --enable-shared \
    --disable-static \
    --disable-pcre2grep \
    --disable-pcre2test \
    --enable-unicode

make -j$(nproc)
make DESTDIR="$deps" install
```

---

## GDAL 编译

### 基本信息

| 属性 | 值 |
|------|-----|
| 版本 | 3.9.2 |
| 构建系统 | CMake |
| 用途 | PostGIS raster 支持 (可选) |

### 编译命令

```bash
tar xf gdal-3.9.2.tar.xz
cd gdal-3.9.2

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
    -DGDAL_USE_ODBC=OFF

cmake --build build -j$(nproc)
cmake --install build

# 合并 lib64 到 lib (CentOS 7 等系统)
if [ -d "$deps/usr/lib64" ]; then
    mv "$deps/usr/lib64"/* "$deps/usr/lib/" 2>/dev/null || true
    rmdir "$deps/usr/lib64" 2>/dev/null || true
fi
```

---

## PostGIS 编译

### 编译命令

```bash
# 获取插件元信息 (JSON)
./plugin.postgis.sh info

# 完整编译 (含依赖)
./plugin.postgis.sh build host 16.15

# 指定版本
./plugin.postgis.sh build host 16.15 3.6.4

# 跳过依赖编译 (使用已存在的 deps)
./plugin.postgis.sh build host 16.15 --skip-deps

# 指定并行编译数
./plugin.postgis.sh build host 16.15 --jobs 8

# 交叉编译 ARM64
./plugin.postgis.sh build aarch64-linux-gnu 16.15
```

### 手动编译 (参考)

```bash
tar xzf postgis-3.6.4.tar.gz
cd postgis-3.6.4

export PATH="$deps/usr/bin:$dist/bin:$PATH"
export PKG_CONFIG_PATH="$deps/usr/lib/pkgconfig:$PKG_CONFIG_PATH"
export CFLAGS="-I$deps/usr/include -I$dist/include -fPIC"
export CXXFLAGS="-I$deps/usr/include -I$dist/include -fPIC"
export LDFLAGS="-L$deps/usr/lib -L$dist/lib \
    -Wl,-rpath,\$ORIGIN/.. \
    -Wl,--disable-new-dtags \
    -ldl -lm -lstdc++"

./configure \
    --prefix=/usr \
    --with-pgconfig="$dist/bin/pg_config" \
    --with-pgsql-libdir="$dist/lib" \
    --with-geosconfig="$deps/usr/bin/geos-config" \
    --with-projdir="$deps/usr" \
    --with-xmlconfig="$deps/usr/bin/xml2-config" \
    --with-gdalconfig="$deps/usr/bin/gdal-config" \
    --without-sfcgal \
    LDFLAGS="$LDFLAGS" \
    CPPFLAGS="-I$dist/include -I$deps/usr/include" \
    --without-interrupt-tests

make -j$(nproc)
env DESTDIR="$tmp_dest" make install
```

### configure 参数

| 参数 | 说明 |
|------|------|
| `--prefix=/usr` | 安装前缀 |
| `--with-pgconfig=FILE` | pg_config 路径 |
| `--with-pgsql-libdir=DIR` | PostgreSQL lib 目录 (解决 libpq 找不到问题) |
| `--with-geosconfig=FILE` | geos-config 路径 |
| `--with-projdir=DIR` | PROJ 安装目录 |
| `--with-xmlconfig=FILE` | xml2-config 路径 |
| `--with-gdalconfig=FILE` | gdal-config 路径 |
| `--without-sfcgal` | 禁用 SFCGAL |
| `--without-interrupt-tests` | 禁用中断测试 |

---

## 打包规范

### 插件包结构

```
postgis-v3.6.4-pg16.x86_64.tar.gz
├── lib/
│   ├── postgresql/                # PostGIS 扩展 .so
│   │   ├── postgis-3.so
│   │   ├── postgis_raster-3.so
│   │   ├── postgis_topology-3.so
│   │   ├── address_standardizer-3.so
│   │   └── postgis_tiger_geocoder-3.so
│   ├── geos_c.so → geos_c.so.3.14.1  # 依赖库
│   ├── geos_c.so.3.14.1
│   ├── libproj.so.22
│   ├── libgdal.so.35
│   └── ...
├── share/
│   ├── postgresql/
│   │   └── extension/
│   │       ├── postgis.control
│   │       ├── postgis--3.6.4.sql
│   │       └── ...
│   ├── proj/                     # PROJ 数据 (proj.db)
│   │   └── proj.db
│   └── gdal/                     # GDAL 数据 (stateplane.csv 等)
│       └── stateplane.csv
└── bin/
    ├── shp2pgsql
    ├── pgsql2shp
    ├── gdalinfo
    ├── gdal-config
    ├── gdal_translate
    ├── gdalwarp
    ├── ogr2ogr
    └── ogrinfo
```

### 依赖库 (动态)

PostGIS 依赖库编译为动态库 (.so)，与插件一起打包：

| 库 | 版本 | 文件 |
|----|------|------|
| GEOS | 3.14.1 | libgeos_c.so.3.14.1 |
| PROJ | 8.2.1 | libproj.so.22 |
| GDAL | 3.9.2 | libgdal.so.35 |
| SQLite3 | 3.44.0 | libsqlite3.so.0 |
| CURL | 8.4.0 | libcurl.so.4 |
| LibXML2 | 2.9.14 | libxml2.so.2 |
| JSON-C | 0.17 | libjson-c.so.5 |
| protobuf-c | 1.4.1 | libprotobuf-c.so.1 |
| PCRE2 | 10.42 | libpcre2-8.so.0 |

### RPATH 配置

使用 patchelf 修复 RPATH 以实现便携部署：

```bash
# PostGIS .so 文件: $ORIGIN/.. (lib/postgresql/ 向上一级找 libpq)
patchelf --set-rpath '$ORIGIN/..' lib/postgresql/postgis-3.so

# deps 依赖库: $ORIGIN (同目录)
patchelf --set-rpath '$ORIGIN' lib/libgeos_c.so.3.14.1

# bin 工具: $ORIGIN/../lib
patchelf --set-rpath '$ORIGIN/../lib' bin/shp2pgsql
```

---

## 使用示例

```sql
-- 创建 PostGIS 扩展 (脚本自动执行 init_sql)
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
CREATE EXTENSION IF NOT EXISTS address_standardizer;
CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder;

-- 检查版本
SELECT postgis_full_version();

-- 创建空间表
CREATE TABLE spatial_data (
    id SERIAL PRIMARY KEY,
    name TEXT,
    geom GEOMETRY(Point, 4326)
);

-- 插入数据
INSERT INTO spatial_data (name, geom)
VALUES ('北京', ST_SetSRID(ST_MakePoint(116.404, 39.915), 4326));

-- 空间查询
SELECT name, ST_AsText(geom)
FROM spatial_data
WHERE ST_DWithin(
    geom::geography,
    ST_SetSRID(ST_MakePoint(116.404, 39.915), 4326)::geography,
    1000
);
```

---

## 常见问题

### 1. 找不到 pg_config

**错误**：`错误: 找不到 pg_config: dist/host/16.15/pgsql/bin/pg_config`

**解决**：先编译 PostgreSQL
```bash
./pgsql-build.sh host 16.15
```

### 2. libtool .la 路径错误

**错误**：`libtool: error: cannot find the library '/usr/lib/libprotobuf.la'`

**原因**：libtool 记录了绝对路径，移动库文件后路径失效

**解决**：编译时使用动态库模式，libtool 会正确处理依赖关系

### 3. C compiler cannot create executables

**错误**：`configure: error: C compiler cannot create executables`

**原因**：编译环境问题（缺少依赖、路径错误等）

**解决**：
1. 检查 `config.log` 获取详细错误信息
2. 确保已安装必要的编译工具
3. 检查 `CFLAGS`、`LDFLAGS` 是否正确

### 4. GEOS C++ 异常崩溃

**错误**：`backend unexpectedly closed connection`

**解决**：重新编译 PostgreSQL 并链接 C++ 标准库
```bash
LDFLAGS=-lstdc++ ./configure [其他参数]
```

### 5. proj.db 缺失

**错误**：`cannot find proj.db`

**解决**：确保 PROJ 数据文件已正确安装
```bash
ls $deps/usr/share/proj/
```

### 6. protoc 未找到

**警告**：`protoc 未找到，protobuf-c 可能编译失败`

**解决**：确保 protobuf 已正确编译并安装到 deps
```bash
ls $deps/usr/bin/protoc
```

---

## 参考资源

- [PostGIS 官方文档](https://postgis.net/documentation/)
- [PostGIS GitHub](https://github.com/postgis/postgis)
- [GEOS 文档](https://libgeos.org/)
- [PROJ 文档](https://proj.org/)
- [GDAL 文档](https://gdal.org/)
