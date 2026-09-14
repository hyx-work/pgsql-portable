# 工具依赖

本目录存放编译/打包过程中使用的工具源码包。

## patchelf

| 属性 | 值 |
|------|-----|
| 版本 | 0.19.1 |
| 文件 | patchelf-0.19.1.tar.gz |
| 用途 | 修改 ELF 二进制文件的 RPATH/RUNPATH |
| 许可 | GPLv3+ |

### 为什么需要 patchelf

插件 `.so` 文件编译时，链接器可能从 pg_config 继承绝对路径（如 `/root/pgsql-portable/dist/host/16.15/pgsql/lib`），导致 RUNPATH 包含编译环境路径，不便携。

patchelf 在打包阶段修正 RUNPATH 为相对路径 `$ORIGIN/..`，使插件包可在任意位置部署。

### 编译安装

```bash

# 输出: patchelf 0.19.1# 1. 解压
tar -xzf patchelf-0.19.1.tar.gz
cd patchelf-0.19.1

# 2. 配置
./configure --prefix=/usr/local

# 3. 编译
make -j$(nproc)

# 4. 安装
sudo make install

# 5. 验证
patchelf --version
# 输出: patchelf 0.19.1
```



### 使用场景

`plugin.common.sh` 中的 `fix_rpath` 函数调用 patchelf：

```bash
# 扩展 .so: RPATH 指向上级目录
patchelf --set-rpath '$ORIGIN/..' lib/postgresql/pg_cron.so

# bin 工具: RPATH 指向 lib/
patchelf --set-rpath '$ORIGIN/../lib' bin/pg_repack
```

脚本会自动检测 patchelf 是否可用，未安装时跳过修复并输出警告。
