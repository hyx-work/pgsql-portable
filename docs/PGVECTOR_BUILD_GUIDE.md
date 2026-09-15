# pgvector 便携编译指南

## 概述

pgvector 是 PostgreSQL 的向量相似度搜索扩展，支持 IVFFlat 和 HNSW 索引，适用于 AI/ML 向量检索场景。

---

## 基本信息

| 属性 | 值 |
|------|-----|
| 默认版本 | 0.8.6 |
| 预加载 | 否 |
| GitHub | https://github.com/pgvector/pgvector |
| 源码格式 | `v{version}.tar.gz` |
| 构建系统 | PGXS |

---

## 环境要求

| 依赖 | 说明 |
|------|------|
| PostgreSQL | 已编译，提供 pg_config 和头文件 |
| GCC | C 编译器 |
| make | 构建工具 |
| OpenMP | 可选，用于并行索引构建 |
| patchelf | 修复 RPATH（必需） |
| plugin.common.sh | 公共库（自动 source，无需手动引入） |

---

## 目录结构

```
pgsql-portable/
├── cache/
│   └── vector-0.8.6.tar.gz             # 源码包
├── build/
│   └── host/
│       └── 16.15/
│           └── vector_v0.8.6/
│               ├── src/                 # 源代码
│               ├── *.o                  # 编译产物
│               └── tmp_install/         # 影子安装目录
├── dist/
│   └── host/
│       └── 16.15/
│           ├── pgsql/                  # PostgreSQL 安装目录
│           └── plugins/
│               └── vector-v0.8.6-pg16.x86_64.tar.gz
└── plugin.vector.sh                     # 编译脚本
```

---

## 使用方法

### 查看插件信息

```bash
./plugin.vector.sh info

# 输出
{
  "name": "vector",
  "version": "0.8.6",
  "preload": false,
  "config": {},
  "description": "向量相似度搜索"
}
```

### 编译命令

```bash
# 使用默认版本
./plugin.vector.sh build host 16.15

# 指定版本
./plugin.vector.sh build host 16.15 0.8.6

# 指定并行编译数
./plugin.vector.sh build host 16.15 --jobs 8

# 依赖分析只报告不失败（非严格模式）
./plugin.vector.sh build host 16.15 --no-strict

# 交叉编译 ARM64
./plugin.vector.sh build aarch64-linux-gnu 16.15
```

---

## 编译流程

脚本自动执行以下步骤，所有命令通过 `run_or_die` 包裹，失败时自动打印日志并终止。

### 1. 下载源码

```
下载地址: https://github.com/pgvector/pgvector/archive/refs/tags/v{version}.tar.gz
缓存位置: cache/vector-{version}.tar.gz
```

### 2. 编译

```bash
# 脚本内部执行 (resolve_pg_env → run_or_die)
# PG_CPPFLAGS 条件包含 DEPS_DIR (如果存在)
make USE_PGXS=1 \
    PG_CONFIG="$PG_CONFIG_BIN" \
    PGXS="$PGXS_FILE" \
    PG_CPPFLAGS="-I$PG_INCLUDE -I$PG_SERVER_INCLUDE [-I$DEPS_DIR/usr/include]" \
    -j"$jobs"
```

### 3. 打包

```
安装: make install (PGXS 标准布局到 tmp_install/)
瘦身: strip --strip-unneeded (仅 .so 文件)
RPATH修复: fix_rpath (patchelf 设置 $ORIGIN/..)
分析: analyze_dir 依赖检查 (ldd + RPATH)
打包: tar -czf → dist/host/16.15/plugins/vector-v0.8.6-pg16.x86_64.tar.gz
```

---

## 编译参数

### 编译参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `USE_PGXS` | `1` | 使用 PostgreSQL 扩展构建系统 |
| `PG_CONFIG` | `$DIST_DIR/bin/pg_config` | PostgreSQL 配置工具 |
| `PGXS` | `$DIST_DIR/.../pgxs.mk` | PGXS 构建文件 |
| `PG_CPPFLAGS` | `-I$PG_INCLUDE -I$PG_SERVER_INCLUDE` | 头文件搜索路径 |
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
vector-v0.8.6-pg16.x86_64.tar.gz
├── lib/
│   └── postgresql/
│       └── vector.so
└── share/
    └── postgresql/
        └── extension/
            ├── vector.control
            ├── vector--0.1.0.sql
            ├── vector--0.2.0--0.3.0.sql
            ├── vector--0.3.0--0.4.0.sql
            └── vector--0.8.0--0.8.6.sql
```

---

## 数据类型

### 向量类型

```sql
-- 定义向量列（指定维度）
CREATE TABLE items (
    id SERIAL PRIMARY KEY,
    embedding vector(3)    -- 3维向量
);

-- 不同维度
CREATE TABLE documents (
    id SERIAL PRIMARY KEY,
    embedding vector(384)  -- 384维（常用）
);

CREATE TABLE images (
    id SERIAL PRIMARY KEY,
    embedding vector(2048) -- 2048维（ResNet）
);
```

### 向量语法

```sql
-- 字面量
'[1,2,3]'::vector

-- 从数组转换
ARRAY[1,2,3]::vector

-- 零向量
'0,0,0'::vector
```

---

## 索引类型

### HNSW 索引（推荐）

```sql
-- L2 距离
CREATE INDEX ON items USING hnsw (embedding vector_l2_ops);

-- 余弦距离
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops);

-- 内积
CREATE INDEX ON items USING hnsw (embedding vector_ip_ops);

-- 带参数
CREATE INDEX ON items USING hnsw (
    embedding vector_l2_ops
) WITH (m = 16, ef_construction = 200);
```

### IVFFlat 索引

```sql
-- L2 距离
CREATE INDEX ON items USING ivfflat (embedding vector_l2_ops)
    WITH (lists = 100);

-- 余弦距离
CREATE INDEX ON items USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);
```

### 索引参数

| 参数 | HNSW | IVFFlat | 说明 |
|------|------|---------|------|
| `m` | ✅ | ❌ | 每层连接数（默认 16） |
| `ef_construction` | ✅ | ❌ | 构建时搜索范围（默认 200） |
| `lists` | ❌ | ✅ | 聚类数（默认 100） |
| `probe` | ❌ | ✅ | 查询时探测数（默认 10） |

---

## 相似度搜索

### 距离操作符

| 操作符 | 距离类型 | 说明 |
|--------|----------|------|
| `<->` | L2 距离 | 欧氏距离 |
| `<=>` | 余弦距离 | 余弦相似度 |
| `<#>` | 内积 | 负内积 |

### 基本查询

```sql
-- 最近邻查询（L2距离）
SELECT * FROM items
ORDER BY embedding <=> '[1,2,3]'
LIMIT 5;

-- 余弦相似度
SELECT * FROM items
ORDER BY embedding <=> '[1,2,3]'
LIMIT 5;

-- 范围查询（距离 < 1.0）
SELECT * FROM items
WHERE embedding <-> '[1,2,3]' < 1.0;

-- 半径查询
SELECT * FROM items
WHERE embedding <-> '[1,2,3]' <= 0.5
ORDER BY embedding <-> '[1,2,3]';
```

### 高级查询

```sql
-- 批量查询
SELECT id, embedding <-> '[1,2,3]' AS distance
FROM items
ORDER BY distance
LIMIT 10;

-- 带过滤条件
SELECT * FROM items
WHERE category = 'electronics'
ORDER BY embedding <=> '[1,2,3]'
LIMIT 5;

-- 返回距离值
SELECT id,
       embedding <=> '[1,2,3]' AS distance,
       embedding
FROM items
ORDER BY distance
LIMIT 5;
```

---

## 向量运算

### 基本运算

```sql
-- 加法
SELECT embedding + '[1,1,1]' FROM items;

-- 减法
SELECT embedding - '[1,1,1]' FROM items;

-- 标量乘法
SELECT embedding * 2.0 FROM items;

-- 向量乘法（逐元素）
SELECT embedding * '[2,2,2]' FROM items;
```

### 聚合函数

```sql
-- 平均值
SELECT AVG(embedding) FROM items;

-- 归一化
SELECT embedding / NULLIF(vector_norm(embedding), 0) FROM items;

-- L2 范数
SELECT vector_norm(embedding) FROM items;
```

### 向量生成

```sql
-- 随机向量
SELECT random_vector(3);

-- 零向量
SELECT '0,0,0'::vector;
```

---

## 使用示例

### 1. 文本嵌入搜索

```sql
-- 创建表
CREATE TABLE documents (
    id SERIAL PRIMARY KEY,
    content TEXT,
    embedding vector(384)  -- 使用 sentence-transformers
);

-- 插入数据
INSERT INTO documents (content, embedding)
VALUES ('PostgreSQL is a database', '[0.1, 0.2, ...]');

-- 创建索引
CREATE INDEX ON documents USING hnsw (embedding vector_cosine_ops);

-- 搜索相似文档
SELECT content,
       embedding <=> $query_embedding AS distance
FROM documents
ORDER BY distance
LIMIT 10;
```

### 2. 图像特征搜索

```sql
-- 创建表
CREATE TABLE images (
    id SERIAL PRIMARY KEY,
    filename TEXT,
    embedding vector(2048)  -- ResNet 特征
);

-- 搜索相似图像
SELECT filename,
       embedding <=> $query_feature AS similarity
FROM images
ORDER BY similarity
LIMIT 5;
```

### 3. 推荐系统

```sql
-- 用户特征
CREATE TABLE user_features (
    user_id INT PRIMARY KEY,
    features vector(128)
);

-- 物品特征
CREATE TABLE item_features (
    item_id INT PRIMARY KEY,
    features vector(128)
);

-- 推荐相似物品
SELECT i.item_id,
       i.features <=> u.features AS similarity
FROM item_features i, user_features u
WHERE u.user_id = 123
ORDER BY similarity
LIMIT 10;
```

---

## 性能优化

### 索引选择

| 数据规模 | 推荐索引 | 原因 |
|----------|----------|------|
| < 10万 | 无索引 | 暴力搜索足够快 |
| 10万-100万 | IVFFlat | 构建快，查询稍慢 |
| > 100万 | HNSW | 查询快，构建稍慢 |

### 参数调优

```sql
-- HNSW 参数
CREATE INDEX ON items USING hnsw (embedding vector_l2_ops)
    WITH (m = 32, ef_construction = 400);  -- 更高精度

-- IVFFlat 参数
CREATE INDEX ON items USING ivfflat (embedding vector_l2_ops)
    WITH (lists = 1000);  -- 更多聚类

-- 查询时调整
SET hnsw.ef_search = 100;  -- 提高召回率
SET ivfflat.probe = 20;     -- 更多探测
```

### 内存优化

```sql
-- 使用 halfvec（半精度向量）
CREATE TABLE items (
    id SERIAL PRIMARY KEY,
    embedding halfvec(384)  -- 节省50%内存
);

-- 创建索引
CREATE INDEX ON items USING hnsw (embedding halfvec_l2_ops);
```

---

## 常见问题

### 1. 找不到向量操作符

**错误**：
```
ERROR: operator does not exist: vector <-> vector
```

**解决**：
```sql
-- 创建扩展
CREATE EXTENSION vector;

-- 检查扩展
SELECT * FROM pg_extension WHERE extname = 'vector';
```

### 2. 索引构建失败

**错误**：
```
ERROR: number of dimensions (3) does not match expected (128)
```

**解决**：确保向量维度一致
```sql
-- 检查向量维度
SELECT array_length(embedding::real[], 1) FROM items LIMIT 1;
```

### 3. 内存不足

**错误**：
```
ERROR: out of memory
```

**解决**：
```bash
# 增加 work_mem
SET work_mem = '256MB';

# 或者减小索引参数
CREATE INDEX ... WITH (m = 8, ef_construction = 100);
```

### 4. 查询太慢

**可能原因**：
1. 未创建索引
2. 数据量太大
3. 索引参数不合理

**解决**：
```sql
-- 检查是否有索引
SELECT * FROM pg_indexes WHERE tablename = 'items';

-- 创建索引
CREATE INDEX ON items USING hnsw (embedding vector_l2_ops);

-- 调整参数
SET hnsw.ef_search = 100;
```

---

## 调试技巧

### 查看编译日志

```bash
# 编译日志 (run_or_die 失败时会自动打印最后 30 行)
cat build/host/16.15/vector.log
```

### 验证安装

```sql
-- 检查版本
SELECT * FROM pg_available_extensions WHERE name = 'vector';

-- 测试基本功能
SELECT '[1,2,3]'::vector <=> '[4,5,6]'::vector;
```

### 手动测试

```bash
# 复制插件到 PostgreSQL
cp build/host/16.15/tmp_install/lib/postgresql/vector.so \
   dist/host/16.15/pgsql/lib/postgresql/

cp build/host/16.15/tmp_install/share/postgresql/extension/* \
   dist/host/16.15/pgsql/share/postgresql/extension/

# 创建扩展
psql -c "CREATE EXTENSION vector;"

# 测试
psql -c "SELECT '[1,2,3]'::vector <=> '[4,5,6]'::vector;"
```

---

## 参考资源

- [pgvector GitHub](https://github.com/pgvector/pgvector)
- [pgvector 文档](https://github.com/pgvector/pgvector#readme)
- [向量相似度搜索算法](https://www.pinecone.io/learn/series/faiss/hnsw/)
