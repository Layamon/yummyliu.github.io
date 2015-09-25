---
layout: post
title: PostgreSQL DBA常用的SQL(RQ)
subtitlle: 频繁重用的代码片段整理，有需要可以看看
date: 2018-05-30 11:45
header-img: "img/head.jpg"
categories: 
    - PostgreSQL
---

* TOC
{:toc}
# 表的情况

## 查看表的大小

```sql
SELECT
   relname,
   pg_size_pretty(pg_total_relation_size(relid)) as total,
   pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid)) as table
   FROM pg_catalog.pg_statio_user_tables
   where relname='relanmedddd' and schemaname='snameddd'
   ORDER BY pg_total_relation_size(relid) DESC;
```

## 年龄最大的表

```sql
SELECT b.nspname,
       a.relname ,
       age(a.relfrozenxid) AS maxtableage,
		pg_size_pretty(pg_total_relation_size(a.oid)) as tablesize,
  (SELECT age(pg_database.datfrozenxid)
   FROM pg_database
   WHERE datname !~ 'postgres|temp') AS age
FROM pg_class a
JOIN pg_namespace b ON b.oid = a.relnamespace
WHERE a.relfrozenxid != 0
ORDER BY maxtableage DESC ;

SELECT 'vacuum freeze verbose ' || b.nspname||'.'||a.relname||';' 
FROM pg_class a
JOIN pg_namespace b ON b.oid = a.relnamespace
WHERE a.relfrozenxid != 0
ORDER BY age(a.relfrozenxid) DESC ;
```

## 统计表具体count值

```sql
SELECT
   relname AS objectname,
   relkind AS objecttype,
   reltuples AS "#entries", pg_size_pretty(relpages::bigint*8*1024) AS size
   FROM pg_class
   WHERE relpages >= 8 and relname~'relnameddd'
   ORDER BY relpages DESC;
```

# 函数情况

## 找到函数返回值为某个表的函数

```sql
SELECT *
FROM pg_proc
WHERE prorettype IN
    (SELECT oid
     FROM pg_type
     WHERE typname = 'table_name');
```



# 索引情况

## 无用索引

```sql
-- Completely unused indexes:
SELECT relid::regclass as table, indexrelid::regclass as index
     , pg_size_pretty(pg_relation_size(indexrelid))
  FROM pg_stat_user_indexes
  JOIN pg_index
 USING (indexrelid)
 WHERE idx_scan = 0
   AND indisunique IS FALSE order by pg_relation_size(indexrelid);
   
 SELECT s.schemaname,
       s.relname AS tablename,
       s.indexrelname AS indexname,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size
FROM pg_catalog.pg_stat_user_indexes s
   JOIN pg_catalog.pg_index i ON s.indexrelid = i.indexrelid
WHERE s.idx_scan = 0      -- has never been scanned
  AND 0 <>ALL (i.indkey)  -- no index column is an expression
  AND NOT EXISTS          -- does not enforce a constraint
         (SELECT 1 FROM pg_catalog.pg_constraint c
          WHERE c.conindid = s.indexrelid)
ORDER BY pg_relation_size(s.indexrelid) DESC;
```

## 重复索引

```sql
--- Finds multiple indexes that have the same set of columns, same opclass, expression and predicate -- which make them equivalent. Usually it's safe to drop one of them, but I give no guarantees. :)

SELECT pg_size_pretty(SUM(pg_relation_size(idx))::BIGINT) AS SIZE,
       (array_agg(idx))[1] AS idx1, (array_agg(idx))[2] AS idx2,
       (array_agg(idx))[3] AS idx3, (array_agg(idx))[4] AS idx4
FROM (
    SELECT indexrelid::regclass AS idx, (indrelid::text ||E'\n'|| indclass::text ||E'\n'|| indkey::text ||E'\n'||
                                         COALESCE(indexprs::text,'')||E'\n' || COALESCE(indpred::text,'')) AS KEY
    FROM pg_index) sub
GROUP BY KEY HAVING COUNT(*)>1
ORDER BY SUM(pg_relation_size(idx)) DESC;
```

## 用处不大的索引

```sql
CREATE AGGREGATE array_accum (anyelement)
(
    sfunc = array_append,
    stype = anyarray,
    initcond = '{}'
);

select
    starelid::regclass, indexrelid::regclass, array_accum(staattnum), relpages, reltuples, array_accum(stadistinct)
from
    pg_index
    join  on (starelid=indrelid and staattnum = ANY(indkey))
    join pg_class on (indexrelid=oid)
where
    case when stadistinct < 0 then stadistinct > -.8 else reltuples/stadistinct > .2 end
    and
    not (indisunique or indisprimary)
    and
    (relpages > 100 or reltuples > 1000)
group by
    starelid, indexrelid, relpages, reltuples
order by
    starelid ;
```

## 索引膨胀

```sql
create schema monitor;

CREATE VIEW monitor.pg_bloat_indexes AS
 WITH btree_index_atts AS (
         SELECT pg_namespace.nspname,
            indexclass.relname AS index_name,
            indexclass.reltuples,
            indexclass.relpages,
            pg_index.indrelid,
            pg_index.indexrelid,
            indexclass.relam,
            tableclass.relname AS tablename,
            (regexp_split_to_table((pg_index.indkey)::text, ' '::text))::smallint AS attnum,
            pg_index.indexrelid AS index_oid
           FROM ((((pg_index
             JOIN pg_class indexclass ON ((pg_index.indexrelid = indexclass.oid)))
             JOIN pg_class tableclass ON ((pg_index.indrelid = tableclass.oid)))
             JOIN pg_namespace ON ((pg_namespace.oid = indexclass.relnamespace)))
             JOIN pg_am ON ((indexclass.relam = pg_am.oid)))
          WHERE ((pg_am.amname = 'btree'::name) AND (indexclass.relpages > 0))
        ), index_item_sizes AS (
         SELECT ind_atts.nspname,
            ind_atts.index_name,
            ind_atts.reltuples,
            ind_atts.relpages,
            ind_atts.relam,
            ind_atts.indrelid AS table_oid,
            ind_atts.index_oid,
            (current_setting('block_size'::text))::numeric AS bs,
            8 AS maxalign,
            24 AS pagehdr,
                CASE
                    WHEN (max(COALESCE(pg_stats.null_frac, (0)::real)) = (0)::double precision) THEN 2
                    ELSE 6
                END AS index_tuple_hdr,
            sum((((1)::double precision - COALESCE(pg_stats.null_frac, (0)::real)) * (COALESCE(pg_stats.avg_width, 1024))::double precision)) AS nulldatawidth
           FROM ((pg_attribute
             JOIN btree_index_atts ind_atts ON (((pg_attribute.attrelid = ind_atts.indexrelid) AND (pg_attribute.attnum = ind_atts.attnum))))
             JOIN pg_stats ON (((pg_stats.schemaname = ind_atts.nspname) AND (((pg_stats.tablename = ind_atts.tablename) AND ((pg_stats.attname)::text = pg_get_indexdef(pg_attribute.attrelid, (pg_attribute.attnum)::integer, true))) OR ((pg_stats.tablename = ind_atts.index_name) AND (pg_stats.attname = pg_attribute.attname))))))
          WHERE (pg_attribute.attnum > 0)
          GROUP BY ind_atts.nspname, ind_atts.index_name, ind_atts.reltuples, ind_atts.relpages, ind_atts.relam, ind_atts.indrelid, ind_atts.index_oid, (current_setting('block_size'::text))::numeric, 8::integer
        ), index_aligned_est AS (
         SELECT index_item_sizes.maxalign,
            index_item_sizes.bs,
            index_item_sizes.nspname,
            index_item_sizes.index_name,
            index_item_sizes.reltuples,
            index_item_sizes.relpages,
            index_item_sizes.relam,
            index_item_sizes.table_oid,
            index_item_sizes.index_oid,
            COALESCE(ceil((((index_item_sizes.reltuples * ((((((((6 + index_item_sizes.maxalign) -
                CASE
                    WHEN ((index_item_sizes.index_tuple_hdr % index_item_sizes.maxalign) = 0) THEN index_item_sizes.maxalign
                    ELSE (index_item_sizes.index_tuple_hdr % index_item_sizes.maxalign)
                END))::double precision + index_item_sizes.nulldatawidth) + (index_item_sizes.maxalign)::double precision) - (
                CASE
                    WHEN (((index_item_sizes.nulldatawidth)::integer % index_item_sizes.maxalign) = 0) THEN index_item_sizes.maxalign
                    ELSE ((index_item_sizes.nulldatawidth)::integer % index_item_sizes.maxalign)
                END)::double precision))::numeric)::double precision) / ((index_item_sizes.bs - (index_item_sizes.pagehdr)::numeric))::double precision) + (1)::double
 precision)), (0)::double precision) AS expected
           FROM index_item_sizes
        ), raw_bloat AS (
         SELECT current_database() AS dbname,
            index_aligned_est.nspname,
            pg_class.relname AS table_name,
            index_aligned_est.index_name,
            (index_aligned_est.bs * ((index_aligned_est.relpages)::bigint)::numeric) AS totalbytes,
            index_aligned_est.expected,
                CASE
                    WHEN ((index_aligned_est.relpages)::double precision <= index_aligned_est.expected) THEN (0)::numeric
                    ELSE (index_aligned_est.bs * ((((index_aligned_est.relpages)::double precision - index_aligned_est.expected))::bigint)::numeric)
                END AS wastedbytes,
                CASE
                    WHEN ((index_aligned_est.relpages)::double precision <= index_aligned_est.expected) THEN (0)::numeric
                    ELSE (((index_aligned_est.bs * ((((index_aligned_est.relpages)::double precision - index_aligned_est.expected))::bigint)::numeric) * (100)::numeric) / (index_aligned_est.bs * ((index_aligned_est.relpages)::bigint)::numeric))
                END AS realbloat,
            pg_relation_size((index_aligned_est.table_oid)::regclass) AS table_bytes,
            stat.idx_scan AS index_scans
           FROM ((index_aligned_est
             JOIN pg_class ON ((pg_class.oid = index_aligned_est.table_oid)))
             JOIN pg_stat_user_indexes stat ON ((index_aligned_est.index_oid = stat.indexrelid)))
        ), format_bloat AS (
         SELECT raw_bloat.dbname AS database_name,
            raw_bloat.nspname AS schema_name,
            raw_bloat.table_name,
            raw_bloat.index_name,
            round(raw_bloat.realbloat) AS bloat_pct,
            round((raw_bloat.wastedbytes / (((1024)::double precision ^ (2)::double precision))::numeric)) AS bloat_mb,
            round((raw_bloat.totalbytes / (((1024)::double precision ^ (2)::double precision))::numeric), 3) AS index_mb,
            round(((raw_bloat.table_bytes)::numeric / (((1024)::double precision ^ (2)::double precision))::numeric), 3) AS table_mb,
            raw_bloat.index_scans
           FROM raw_bloat
        )
 SELECT format_bloat.database_name AS datname,
    format_bloat.schema_name AS nspname,
    format_bloat.table_name AS relname,
    format_bloat.index_name AS idxname,
    format_bloat.index_scans AS idx_scans,
    format_bloat.bloat_pct,
    format_bloat.table_mb,
    (format_bloat.index_mb - format_bloat.bloat_mb) AS actual_mb,
    format_bloat.bloat_mb,
    format_bloat.index_mb AS total_mb
   FROM format_bloat
  ORDER BY format_bloat.bloat_mb DESC;

WITH indexes_bloat AS (
    SELECT
      nspname || '.' || idxname as idx_name,
      actual_mb,
      bloat_pct
    FROM monitor.pg_bloat_indexes
    WHERE nspname NOT IN ('dba', 'monitor', 'trash') AND bloat_pct > 20
    ORDER BY 2 DESC,3 DESC
)
(SELECT idx_name FROM indexes_bloat WHERE actual_mb < 100 AND bloat_pct > 40 ORDER BY bloat_pct DESC LIMIT 30) UNION -- 30 small
(SELECT idx_name FROM indexes_bloat WHERE actual_mb BETWEEN 100 AND 2000 ORDER BY bloat_pct DESC LIMIT 10) UNION -- 10 medium
(SELECT idx_name FROM indexes_bloat WHERE actual_mb BETWEEN 2000 AND 10000 ORDER BY bloat_pct DESC LIMIT 3) UNION -- 3 big
(SELECT idx_name FROM indexes_bloat WHERE actual_mb < 10000 ORDER BY bloat_pct DESC LIMIT 5); -- 5 at least
```



## 重建索引

```sql
CREATE UNIQUE INDEX CONCURRENTLY user_pictures_new_pkey_new ON yay.user_pictures USING btree (id)

BEGIN;
DROP INDEX CONCURRENTLY user_pictures_new_pkey;
ALTER INDEX user_pictures_new_pkey_new RENAME TO user_pictures_new_pkey;
COMMIT;
```

## 重建主键

```sql
CREATE UNIQUE INDEX CONCURRENTLY user_pictures_new_pkey_new ON yay.user_pictures USING btree (id)

--- make index disvalid
update pg_index set indisvalid = false where indexrelid = 'user_pictures_new_pkey'::regclass;

BEGIN;
SET lock_timeout TO '2s'
alter table user_pictures drop CONSTRAINT user_pictures_new_pkey ;

alter table user_pictures add CONSTRAINT user_pictures_pkey PRIMARY KEY USING INDEX user_pictures_pkey_new
COMMIT;
```

# 锁情况

## 锁依赖

```sql
SET application_name='%your_logical_name%';
SELECT blocked_locks.pid     AS blocked_pid,
         blocked_activity.usename  AS blocked_user,
         blocking_locks.pid     AS blocking_pid,
         blocking_activity.usename AS blocking_user,
         blocked_activity.query    AS blocked_statement,
         blocking_activity.query   AS current_statement_in_blocking_process,
         blocked_activity.application_name AS blocked_application,
         blocking_activity.application_name AS blocking_application
   FROM  pg_catalog.pg_locks         blocked_locks
    JOIN pg_catalog.pg_stat_activity blocked_activity  ON blocked_activity.pid = blocked_locks.pid
    JOIN pg_catalog.pg_locks         blocking_locks
        ON blocking_locks.locktype = blocked_locks.locktype
        AND blocking_locks.DATABASE IS NOT DISTINCT FROM blocked_locks.DATABASE
        AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
        AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
        AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
        AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
        AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
        AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
        AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
        AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
        AND blocking_locks.pid != blocked_locks.pid

    JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
   WHERE NOT blocked_locks.GRANTED;
```

## 某个表上的锁情况

```sql
select a.locktype,a.database,a.pid,a.mode,a.granted,a.relation,b.relname,left(c.query, 100)
from pg_locks a
join pg_class b on a.relation = b.oid
join pg_stat_activity c on a.pid = c.pid
where lower(b.relname) = 'users';
```

# 查询

## 慢查询

```sql
SELECT state, backend_xmin,xact_start,left(query,100)
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY age(backend_xmin) DESC;
```

## 检查线上查询

```sql
select split_part(split_part(application_name,':',1),'-',2) as appname ,left(split_part(query,'FROM',2),100) from pg_stat_activity where usename !='dba' and client_addr = '127.0.0.1' and application_name !='';
```

## 语句平均执行时间

```sql
CREATE OR REPLACE FUNCTION timeit(insql text)
RETURNS interval
AS $$
DECLARE
    tgtpid bigint;
    startts timestamp;
    sumint interval = '0 seconds';
    rec record;
    i int; numiters int := 1000;
BEGIN
    FOR i IN 1..numiters LOOP
        tgtpid := round(100000 * random());
        startts := clock_timestamp();
        EXECUTE insql INTO rec using tgtpid;
        sumint := sumint + (clock_timestamp() - startts)::interval;
    END LOOP;
    RETURN (sumint / numiters);
END;
$$ LANGUAGE plpgsql;

SELECT timeit(
$$
    SELECT count(1) FROM parent p JOIN detail d ON d.pid = p.id WHERE p.id = $1
$$);
```

# 更新数据

## 删除某几列上重复的记录

只保留ctid或者id或者updatetime等最大的

```sql
with keys as ( select last_value(id) over (partition by user_id, moment_id, moment_user_id order by updated_time), count(*) over (partition by user_id, moment_id, moment_user_id) as c
from tablename)
select * from keys where c > 1;

delete from tablename where id in (select id from keys where c > 1);
```

## 批量间隔更新

```sql
$ cat updateoffset.sql

WITH updateid AS
  (SELECT *
   FROM table_bk
   OFFSET :offset LIMIT 500)
UPDATE table
SET created_time = u.created_time
FROM updateid u
WHERE table.id = u.id;

for (( i = 0; i < 54; i++ )); do
psql -f updateoffset.sql -v offset=$((i*500));
Sleep 60;
done
```

# SHELL

## slave获得masterhost

```bash
MHOST=$(grep primary_conninfo recovery.conf | awk -F 'host=' '{print $2}' | awk '{print $1}')
```

# 复制延迟

```sql
SELECT client_addr,
       pg_wal_lsn_diff(
           pg_current_wal_lsn(),
           sent_lsn
       ) AS sent_lag,
       pg_wal_lsn_diff(
           pg_current_wal_lsn(),
           write_lsn
       ) AS write_lag,
       pg_wal_lsn_diff(
           pg_current_wal_lsn(),
           flush_lsn
       ) AS flush_lag,
       pg_wal_lsn_diff(
           pg_current_wal_lsn(),
           replay_lsn
       ) AS replay_lag
  FROM pg_stat_replication;
```

```sql
SELECT slot_name,
       pg_wal_lsn_diff(
         pg_current_wal_lsn(),
         restart_lsn
       ) as restart_lag,
       pg_wal_lsn_diff(
         pg_current_wal_lsn(),
         confirmed_flush_lsn
       ) as flush_lag
  FROM pg_replication_slots;
```
