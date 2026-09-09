# PostgreSQL 便携版构建系统

Bash 脚本，用于构建和打包 Linux 平台的 PostgreSQL 便携版二进制文件。支持多版本、多架构，内置插件生态和一键部署能力。

## 特性

- **全静态依赖**：OpenSSL、zlib、ICU、ncurses、libedit 全部静态链接，无运行时库依赖
- **真正便携**：使用 `$ORIGIN/../lib` rpath，编译结果可任意迁移部署
- **多版本支持**：PostgreSQL 16、17、18 版本均可构建
- **多架构支持**：x86_64、aarch64、s390x、armv7l，支持交叉编译
- **插件生态**：内置 pg_cron、pg_repack、pgvector 等常用扩展
- **FULL 包模式**：预装插件 + 初始化数据库，解压即用
- **一键部署**：自动化安装、配置 systemd 服务、端口管理
- **运维工具**：备份恢复、WAL 归档管理、定时任务

## 目录结构

```
pgsql-portable/
├── full-build.sh          # 主构建入口
├── pgsql-build.sh         # PostgreSQL 核心编译
├── pgsql-test.sh          # 冒烟测试
├── check-bin.sh           # 二进制审计工具
├── deploy-pgsql.sh        # 独立包部署脚本
├── deploy-full.sh         # FULL 包部署脚本
├── plugin.*.sh            # 插件构建脚本
├── cache/                 # 源码包缓存
├── build/                 # 中间构建产物
├── deps/                  # 编译好的静态依赖
├── dist/                  # 最终分发包
└── script/                # 运维工具脚本
```

## 快速开始

### 前置要求

- Linux 系统（推荐 Ubuntu/Debian/CentOS）
- GCC 编译器
- make、curl、tar

### 构建 PostgreSQL

```bash
# 构建当前主机架构
./full-build.sh host 16.15

# 交叉编译 ARM64 版本
./full-build.sh aarch64-linux-gnu 17.2

# 只构建特定插件
./full-build.sh host 16.15 -p vector,pg_cron
```

### 构建结果

```
dist/
└── host/
    └── 16.15/
        ├── pgsql-16.15-linux-x86_64.tar.xz      # 独立包
        ├── pgsql-16.15-linux-x86_64-FULL.tar.xz  # FULL 包（含插件）
        └── plugins/
            ├── pg_cron-1.6.7-linux-x86_64.tar.gz
            ├── pg_repack-1.5.3-linux-x86_64.tar.gz
            └── vector-0.8.6-linux-x86_64.tar.gz
```

## 使用方法

### 构建选项

```bash
./full-build.sh <triple>|host <版本> [选项]
```

| 选项 | 说明 |
|------|------|
| `-p, --plugins <list>` | 指定插件，逗号分隔（默认：全部） |
| `-l, --list-plugins` | 列出可用插件 |
| `-s, --skip-pgsql` | 跳过 PostgreSQL 编译 |
| `--no-full` | 不生成 FULL 包 |
| `-h, --help` | 显示帮助 |

### 支持的架构

| Triple | 架构 | 说明 |
|--------|------|------|
| `host` | 当前主机 | 自动检测 |
| `x86_64-linux-gnu` | x86_64 | Intel/AMD 64位 |
| `aarch64-linux-gnu` | aarch64 | ARM64（鲲鹏/飞腾） |
| `s390x-linux-gnu` | s390x | IBM Z |
| `arm-linux-gnueabihf` | armv7l | ARM 32位 |

### 支持的 PostgreSQL 版本

| 版本 | 发布状态 | 当前最新小版本 | 发布时间 | 社区终止支持时间 (EOL) |
|------|----------|---------------|----------|----------------------|
| PostgreSQL 18 | ✅ 当前主要稳定版 | 18.6 (截至2026年8月) | 2025年9月25日 | 预计2030年11月 |
| PostgreSQL 17 | ✅ 稳定版 | 17.11 (截至2026年8月) | 2024年9月26日 | 预计2029年11月 |
| PostgreSQL 16 | ✅ 稳定版 | 16.15 (截至2026年8月) | 2023年9月14日 | 预计2028年11月 |

## 插件系统

### 内置插件

| 插件 | 版本 | 说明 | 预加载 |
|------|------|------|--------|
| **pg_cron** | 1.6.7 | 数据库定时任务调度 | ✅ 是 |
| **pg_repack** | 1.5.3 | 在线表重组/清理膨胀 | 否 |
| **pgvector** | 0.8.6 | 向量相似度搜索（AI/ML） | 否 |

### 插件开发规范

每个插件脚本遵循统一接口：

```bash
# 查看插件信息
./plugin.vector.sh info

# 构建插件
./plugin.vector.sh build <triple> <pg_version> [plugin_version]
```

插件元数据格式：

```json
{
  "name": "vector",
  "version": "0.8.6",
  "preload": false,
  "config": {}
}
```

## 部署

### 独立包部署

```bash
# 部署 PostgreSQL（交互式，支持升级）
./deploy-pgsql.sh pgsql-16.15-linux-x86_64.tar.xz
```

特性：
- 自动检测已有数据目录，支持原地升级
- 端口自动分配（`54{主版本号}`）
- 生成随机密码
- 创建 systemd 服务

### FULL 包部署

```bash
# 一键部署（预初始化数据库 + 插件）
./deploy-full.sh pgsql-16.15-linux-x86_64-FULL.tar.xz
```

特性：
- 无需 initdb，数据目录已预配置
- 插件已预装并启用
- 自动生成 `init.sql` 创建扩展
- 包含 `manifest.json` 元数据

### 端口规范

端口 = `54{主版本号}`

| 版本 | 端口 |
|------|------|
| PostgreSQL 16 | 5416 |
| PostgreSQL 17 | 5417 |
| PostgreSQL 18 | 5418 |

## 运维工具

| 脚本 | 说明 |
|------|------|
| `script/backup-postgresql.sh` | 在线物理备份（xz 压缩，7天滚动清理） |
| `script/restore-postgresql.sh` | 时间点恢复（PITR） |
| `script/setup-archive-config.sh` | 配置 WAL 归档 |
| `script/clean-archive-wals.sh` | 安全清理 WAL 归档 |
| `script/register-crontab.sh` | 注册定时清理任务 |

### 备份示例

```bash
# 配置 WAL 归档
./script/setup-archive-config.sh <数据目录>

# 执行备份
./script/backup-postgresql.sh <数据目录>

# 注册每日定时清理（02:00 AM）
./script/register-crontab.sh
```

## 二进制审计

使用 `check-bin.sh` 验证构建结果的可移植性：

```bash
./check-bin.sh dist/host/16.15/pgsql-16.15-linux-x86_64
```

检查项：
- 动态库依赖（OpenSSL、ICU、zlib、readline）
- RUNPATH/RPATH 配置
- 是否存在泄漏的系统库依赖

## 测试

运行冒烟测试验证构建结果：

```bash
./pgsql-test.sh dist/host/16.15/pgsql-16.15-linux-x86_64.tar.xz
```

测试内容：
1. 解压便携包到 `/tmp`
2. 初始化数据库（initdb）
3. 启动 PostgreSQL（端口 5416）
4. 执行 `SELECT version()` 验证
5. 停止并清理

## 交叉编译

使用 Zig 编译器进行交叉编译（推荐）：

```bash
# 安装 Zig
# https://ziglang.org/download/

# 构建 x86_64 版本（指定 GLIBC 版本）
CC="zig cc --target=x86_64-linux-gnu.2.18" ./full-build.sh x86_64-linux-gnu 16.15

# 构建 aarch64 版本
CC="zig cc --target=aarch64-linux-gnu.2.18" ./full-build.sh aarch64-linux-gnu 16.15
```

## 国产化适配（信创）

本项目特别针对国产化环境优化：

- **支持架构**：鲲鹏（Kunpeng）、飞腾（Phytium）
- **操作系统**：银河麒麟（Kylin）、统信 UOS
- **文档语言**：全中文文档和提示信息
- **端口规划**：符合国内规范

## 依赖说明

所有依赖均由构建脚本自动下载和编译，无需手动安装：

| 依赖 | 版本 | 用途 |
|------|------|------|
| OpenSSL | 3.5.7 | SSL/TLS 支持 |
| zlib | 1.3.2 | 数据压缩 |
| ICU | 74.2 | Unicode/国际化支持 |
| ncurses | - | 终端控制 |
| libedit | - | 命令行编辑 |

源码包缓存在 `cache/` 目录，支持离线构建。

## 许可证

本项目基于 [build-pgsql](https://github.com/ancwrd1/build-pgsql) 改进，感谢原作者。

[GNU General Public License v3.0](LICENSE) © 2024 pgsql-portable Contributors
