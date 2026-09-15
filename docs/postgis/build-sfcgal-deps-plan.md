# SFCGAL 完整编译依赖方案

> **注意**：此计划尚未实施。当前 plugin.postgis.sh 使用 `--without-sfcgal` 禁用 SFCGAL 支持。
> 以下内容为未来启用 SFCGAL 时的参考方案。

## 版本清单

| 库 | 版本 | 构建系统 | 许可证 |
|---|---|---|---|
| GMP | 6.3.0 | autotools | LGPL v3+ |
| MPFR | 4.2.2 | autotools | LGPL v3+ |
| Boost | 1.86.0 | b2/bjam | BSL-1.0 |
| CGAL | 5.6.1 | cmake | GPLv3+ |
| SFCGAL | 1.4.1 | cmake | LGPL v2+ |

## 下载地址

- GMP: https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz
- MPFR: https://www.mpfr.org/mpfr-current/mpfr-4.2.2.tar.xz
- Boost: https://boostorg.jfrog.io/artifactory/main/release/1.86.0/source/boost_1_86_0.tar.gz
- CGAL: https://github.com/CGAL/cgal/releases/download/v5.6.1/CGAL-5.6.1-library.zip
- SFCGAL: https://gitlab.com/sfcgal/SFCGAL/-/archive/v1.4.1/SFCGAL-v1.4.1.tar.gz

## 依赖链

```
SFCGAL 1.4.1
├── CGAL 5.6.1 (header-only)
│   ├── GMP 6.3.0 (autotools)
│   ├── MPFR 4.2.2 (autotools, 依赖 GMP)
│   └── Boost 1.86.0 (headers + Boost.Thread)
├── GEOS 3.14.1 (已有)
└── PROJ 8.2.1 (已有)
```

## 构建顺序

```
build_gmp → build_mpfr → build_boost → build_proj → build_geos → build_cgal → build_sfcgal
```

## 每个库的构建命令

### GMP 6.3.0

```bash
cd $srcdir
wget https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz
tar xf gmp-6.3.0.tar.xz && cd gmp-6.3.0
./configure --prefix=$deps/usr --enable-shared --disable-static
make -j && make install
```

### MPFR 4.2.2

```bash
cd $srcdir
wget https://www.mpfr.org/mpfr-current/mpfr-4.2.2.tar.xz
tar xf mpfr-4.2.2.tar.xz && cd mpfr-4.2.2
./configure --prefix=$deps/usr --with-gmp=$deps/usr --enable-shared --disable-static
make -j && make install
```

### Boost 1.86.0

```bash
cd $srcdir
wget https://boostorg.jfrog.io/artifactory/main/release/1.86.0/source/boost_1_86_0.tar.gz
tar xf boost_1_86_0.tar.gz && cd boost_1_86_0
./bootstrap.sh --prefix=$deps/usr --with-libraries=thread,system
./b2 install --prefix=$deps/usr link=shared runtime-link=shared
```

### CGAL 5.6.1 (header-only)

```bash
cd $srcdir
wget https://github.com/CGAL/cgal/releases/download/v5.6.1/CGAL-5.6.1-library.zip
mkdir -p cgal-5.6.1 && cd cgal-5.6.1
unzip ../CGAL-5.6.1-library.zip
cmake -B build -DCMAKE_INSTALL_PREFIX=$deps/usr \
    -DCMAKE_BUILD_TYPE=Release \
    -DWITH_GMP=ON -DWITH_MPFR=ON
cmake --install build
```

### SFCGAL 1.4.1

```bash
cd $srcdir
wget https://gitlab.com/sfcgal/SFCGAL/-/archive/v1.4.1/SFCGAL-v1.4.1.tar.gz
tar xf SFCGAL-v1.4.1.tar.gz && cd SFCGAL-v1.4.1
cmake -B build -DCMAKE_INSTALL_PREFIX=$deps/usr \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=$deps/usr \
    -DGEOS_DIR=$deps/usr \
    -DPROJ_DIR=$deps/usr
cmake --install build
```

## 脚本改动点

1. 版本定义区新增 5 个版本号 + tar 变量
2. `download_deps()` 新增 5 个下载 URL
3. `main()` 构建顺序：`build_gmp → build_mpfr → build_boost → build_proj → build_geos → build_cgal → build_sfcgal`
4. `build_postgis()` configure：去掉 `--without-sfcgal`，加 `--with-sfcgalconfig=$deps/usr/bin/sfcgal-config`
5. `clean-postgis.sh` 新增 GMP/MPFR/Boost/CGAL/SFCGAL 清理项

## 注意事项

- CGAL 使用 GPLv3+ 许可证，SFCGAL 是 LGPL v2+，组合后整体为 GPLv3+
- SFCGAL 1.4.1 兼容 CGAL 5.3+，CGAL 5.6.1 可用
- GMP 和 MPFR 使用 autotools 构建
- CGAL 5.0+ 是 header-only，无需编译库
- Boost 只需编译 thread 和 system 库

## 预估编译时间

| 库 | 预估时间 |
|---|---|
| GMP | ~2 分钟 |
| MPFR | ~1 分钟 |
| Boost (thread) | ~3-5 分钟 |
| CGAL | ~1 分钟（header-only） |
| SFCGAL | ~2-3 分钟 |
| **总计** | **~10 分钟** |
