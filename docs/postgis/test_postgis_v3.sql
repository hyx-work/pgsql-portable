-- ==========================================================
-- PostGIS 完整功能测试脚本 v3.0 (含 GDAL 驱动启用)
-- ==========================================================

\set ON_ERROR_STOP off
\pset pager off
\pset border 2

\echo ''
\echo '##########################################################'
\echo '#       PostGIS 完整功能测试脚本 v3.0                    #'
\echo '#       (含 GDAL 驱动启用)                               #'
\echo '##########################################################'

-- ==========================================================
-- [0] 启用 GDAL 驱动 (关键前置步骤)
-- ==========================================================
\echo ''
\echo '=========================================================='
\echo '[0] 启用 GDAL 驱动'
\echo '=========================================================='

\echo '--- 0.1 当前 GDAL 驱动设置 ---'
SHOW postgis.gdal_enabled_drivers;

\echo '--- 0.2 启用所有 GDAL 驱动 ---'
SET postgis.gdal_enabled_drivers = 'ENABLE_ALL';

\echo '--- 0.3 确认设置已生效 ---'
SHOW postgis.gdal_enabled_drivers;

\echo '--- 0.4 永久设置到数据库（需要超级用户，失败可忽略） ---'
DO $$
BEGIN
    EXECUTE 'ALTER DATABASE ' || quote_ident(current_database()) || ' SET postgis.gdal_enabled_drivers = ''ENABLE_ALL''';
    RAISE NOTICE '已永久设置当前数据库的 GDAL 驱动';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '永久设置失败（可能权限不足），当前会话已生效: %', SQLERRM;
END $$;

-- [1] 版本信息
\echo ''
\echo '=========================================================='
\echo '[1] 版本信息'
\echo '=========================================================='

\echo '--- 1.1 PostGIS 完整版本 ---'
SELECT postgis_full_version();

\echo '--- 1.2 PostGIS 库版本 ---'
SELECT postgis_version();

\echo '--- 1.3 GEOS 版本 ---'
SELECT postgis_geos_version();

\echo '--- 1.4 PROJ 版本 ---'
SELECT postgis_proj_version();

\echo '--- 1.5 已安装扩展 ---'
SELECT extname, extversion 
FROM pg_extension 
WHERE extname LIKE 'postgis%' OR extname = 'address_standardizer'
ORDER BY extname;

-- [2] 核心几何
\echo ''
\echo '=========================================================='
\echo '[2] 核心几何功能'
\echo '=========================================================='

\echo '--- 2.1 创建几何 ---'
SELECT '点:   ' || ST_AsText(ST_GeomFromText('POINT(0 0)'));
SELECT '线:   ' || ST_AsText(ST_GeomFromText('LINESTRING(0 0, 1 1, 2 2)'));
SELECT '面:   ' || ST_AsText(ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))'));

\echo '--- 2.2 几何计算 ---'
SELECT '面积 (期望 1):     ' || ST_Area(ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))'));
SELECT '长度 (期望 5):     ' || ST_Length(ST_GeomFromText('LINESTRING(0 0, 3 4)'));
SELECT '距离 (期望 5):     ' || ST_Distance(
    ST_GeomFromText('POINT(0 0)'),
    ST_GeomFromText('POINT(3 4)')
);

\echo '--- 2.3 相交判断 (期望 t) ---'
SELECT ST_Intersects(
    ST_GeomFromText('POLYGON((0 0, 2 0, 2 2, 0 2, 0 0))'),
    ST_GeomFromText('POINT(1 1)')
) AS intersects;

\echo '--- 2.4 求交集 ---'
SELECT ST_AsText(ST_Intersection(
    ST_GeomFromText('POLYGON((0 0, 2 0, 2 2, 0 2, 0 0))'),
    ST_GeomFromText('POLYGON((1 1, 3 1, 3 3, 1 3, 1 1))')
)) AS intersection_result;

-- [3] 坐标转换
\echo ''
\echo '=========================================================='
\echo '[3] 坐标转换 (PROJ 功能)'
\echo '=========================================================='

\echo '--- 3.1 WGS84 → Web Mercator ---'
SELECT ST_AsText(ST_Transform(
    ST_GeomFromText('POINT(116.4 39.9)', 4326), 3857
)) AS wgs84_to_mercator;

\echo '--- 3.2 Web Mercator → WGS84 ---'
SELECT ST_AsText(ST_Transform(
    ST_GeomFromText('POINT(12957588.728337044 4851421.175183357)', 3857), 4326
)) AS mercator_to_wgs84;

\echo '--- 3.3 WGS84 → CGCS2000 ---'
SELECT ST_AsText(ST_Transform(
    ST_GeomFromText('POINT(116.4 39.9)', 4326), 4527
)) AS wgs84_to_cgcs2000;

\echo '--- 3.4 距离计算 (北京→上海, 期望约 1067km) ---'
SELECT ROUND(
    (ST_Distance(
        ST_GeomFromText('POINT(116.4 39.9)', 4326)::geography,
        ST_GeomFromText('POINT(121.5 31.2)', 4326)::geography
    ) / 1000)::numeric, 
    2
) AS distance_km;

-- [4] 栅格功能 ⭐ 关键测试
\echo ''
\echo '=========================================================='
\echo '[4] 栅格功能 (GDAL 功能) ⭐ 关键测试'
\echo '=========================================================='

\echo '--- 4.1 创建栅格元数据 ---'
SELECT (ST_Metadata(
    ST_AsRaster(ST_GeomFromText('POINT(0 0)'), 100, 100)
)).*;

\echo '--- 4.2 GDAL 驱动列表 ⭐ 关键 ---'
SELECT short_name, long_name 
FROM ST_GDALDrivers()
WHERE short_name IN ('PNG', 'JPEG', 'GTiff', 'GIF', 'BMP', 'VRT', 'MEM', 'PDF')
ORDER BY short_name;

\echo '--- 4.3 GDAL 驱动数量 ---'
SELECT COUNT(*) AS total_drivers FROM ST_GDALDrivers();

\echo '--- 4.4 ST_AsPNG ⭐ 关键 ---'
SELECT CASE 
    WHEN ST_AsPNG(ST_AsRaster(ST_GeomFromText('POINT(0 0)'), 100, 100)) IS NOT NULL 
    THEN 'PNG 输出成功 (长度: ' || length(ST_AsPNG(ST_AsRaster(ST_GeomFromText('POINT(0 0)'), 100, 100))) || ' 字节)'
    ELSE 'PNG 输出失败'
END AS png_test;

\echo '--- 4.5 ST_AsGDALRaster (GeoTIFF) ---'
SELECT CASE 
    WHEN ST_AsGDALRaster(ST_AsRaster(ST_GeomFromText('POINT(0 0)'), 100, 100), 'GTiff') IS NOT NULL 
    THEN 'GeoTIFF 输出成功 (长度: ' || length(ST_AsGDALRaster(ST_AsRaster(ST_GeomFromText('POINT(0 0)'), 100, 100), 'GTiff')) || ' 字节)'
    ELSE 'GeoTIFF 输出失败'
END AS geotiff_test;

\echo '--- 4.6 ST_AsJPEG ---'
SELECT CASE 
    WHEN ST_AsJPEG(ST_AsRaster(ST_GeomFromText('POINT(0 0)'), 100, 100)) IS NOT NULL 
    THEN 'JPEG 输出成功 (长度: ' || length(ST_AsJPEG(ST_AsRaster(ST_GeomFromText('POINT(0 0)'), 100, 100))) || ' 字节)'
    ELSE 'JPEG 输出失败'
END AS jpeg_test;

-- [5] GeoJSON / MVT
\echo ''
\echo '=========================================================='
\echo '[5] GeoJSON / MVT 输出'
\echo '=========================================================='

\echo '--- 5.1 GeoJSON ---'
SELECT ST_AsGeoJSON(ST_GeomFromText('POINT(116.4 39.9)', 4326)) AS geojson;

\echo '--- 5.2 MVT 几何 ---'
SELECT ST_AsMVTGeom(
    ST_GeomFromText('POINT(116.4 39.9)', 4326),
    ST_MakeEnvelope(116, 39, 117, 40, 4326)
)::text AS mvt_geom;

\echo '--- 5.3 完整 MVT ---'
SELECT length(ST_AsMVT(t, 'test_layer')) AS mvt_bytes
FROM (
    SELECT ST_AsMVTGeom(
        ST_GeomFromText('POINT(116.4 39.9)', 4326),
        ST_MakeEnvelope(116, 39, 117, 40, 4326)
    ) AS geom
) t;

-- [6] KML / GML / SVG
\echo ''
\echo '=========================================================='
\echo '[6] KML / GML / SVG 输出'
\echo '=========================================================='

\echo '--- 6.1 KML ---'
SELECT ST_AsKML(ST_GeomFromText('POINT(116.4 39.9)', 4326)) AS kml;

\echo '--- 6.2 GML ---'
SELECT ST_AsGML(ST_GeomFromText('POINT(116.4 39.9)', 4326)) AS gml;

\echo '--- 6.3 SVG ---'
SELECT ST_AsSVG(ST_GeomFromText('POINT(0 0)')) AS svg;

-- [7] 拓扑
\echo ''
\echo '=========================================================='
\echo '[7] 拓扑功能'
\echo '=========================================================='

\echo '--- 7.1 拓扑扩展 ---'
SELECT extname, extversion 
FROM pg_extension WHERE extname = 'postgis_topology';

\echo '--- 7.2 创建/查询/删除拓扑 ---'
SELECT CreateTopology('test_topo', 4326) AS created;
SELECT name, srid FROM topology.topology WHERE name = 'test_topo';
SELECT DropTopology('test_topo') AS dropped;

-- [8] 空间索引
\echo ''
\echo '=========================================================='
\echo '[8] 空间索引'
\echo '=========================================================='

\echo '--- 8.1 建表 + 索引 ---'
DROP TABLE IF EXISTS test_points;
CREATE TABLE test_points (
    id SERIAL PRIMARY KEY,
    name TEXT,
    geom GEOMETRY(POINT, 4326)
);
INSERT INTO test_points (name, geom) VALUES
    ('北京', ST_GeomFromText('POINT(116.4 39.9)', 4326)),
    ('上海', ST_GeomFromText('POINT(121.5 31.2)', 4326)),
    ('广州', ST_GeomFromText('POINT(113.3 23.1)', 4326)),
    ('深圳', ST_GeomFromText('POINT(114.1 22.5)', 4326)),
    ('成都', ST_GeomFromText('POINT(104.1 30.7)', 4326)),
    ('西安', ST_GeomFromText('POINT(108.9 34.3)', 4326));
CREATE INDEX idx_test_points_geom ON test_points USING GIST (geom);

\echo '--- 8.2 距离北京 1500km 内的城市 ---'
SELECT name, 
       ROUND((ST_Distance(
           geom::geography,
           ST_GeomFromText('POINT(116.4 39.9)', 4326)::geography
       ) / 1000)::numeric, 2) AS distance_km
FROM test_points
WHERE ST_DWithin(
    geom::geography,
    ST_GeomFromText('POINT(116.4 39.9)', 4326)::geography,
    1500000
)
ORDER BY distance_km;

\echo '--- 8.3 最近 3 个城市 ---'
SELECT name, 
       ROUND((ST_Distance(
           geom::geography,
           ST_GeomFromText('POINT(116.4 39.9)', 4326)::geography
       ) / 1000)::numeric, 2) AS distance_km
FROM test_points
ORDER BY geom <-> ST_GeomFromText('POINT(116.4 39.9)', 4326)
LIMIT 3;

DROP TABLE test_points;

-- [9] 综合判断
\echo ''
\echo '=========================================================='
\echo '[9] 综合判断'
\echo '=========================================================='

\echo '--- 9.1 GDAL 数据完整性 ---'
SELECT CASE 
    WHEN postgis_full_version() LIKE '%GDAL_DATA not found%' 
    THEN 'GDAL_DATA 未找到'
    ELSE 'GDAL_DATA 正常'
END AS gdal_data_status;

\echo '--- 9.2 GDAL 驱动状态 ---'
SELECT CASE 
    WHEN (SELECT COUNT(*) FROM ST_GDALDrivers()) > 0 
    THEN 'GDAL 驱动已加载 (' || (SELECT COUNT(*) FROM ST_GDALDrivers()) || ' 个)'
    ELSE 'GDAL 驱动未加载'
END AS gdal_driver_status;

\echo '--- 9.3 PNG/JPEG/GTiff 驱动检查 ---'
SELECT string_agg(short_name, ', ' ORDER BY short_name) AS key_drivers
FROM ST_GDALDrivers() 
WHERE short_name IN ('PNG', 'JPEG', 'GTiff');

\echo '--- 9.4 当前 GDAL 驱动设置 ---'
SHOW postgis.gdal_enabled_drivers;

\echo ''
\echo '##########################################################'
\echo '#           测试完成                                      #'
\echo '##########################################################'
\echo ''
\echo '关键判断:'
\echo '  [0.3] postgis.gdal_enabled_drivers 应为 ENABLE_ALL'
\echo '  [4.2] GDAL 驱动列表应包含 PNG/JPEG/GTiff'
\echo '  [4.4] ST_AsPNG 应成功'
\echo '  [9.1] 应显示 GDAL_DATA 正常'
\echo '  [9.2] 应显示 GDAL 驱动已加载'
\echo '  [9.3] key_drivers 应包含 PNG, JPEG, GTiff'
\echo ''
