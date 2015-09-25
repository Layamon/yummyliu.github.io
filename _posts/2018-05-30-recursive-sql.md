---
layout: post
title: SQL递归查询
subtitle: 了解一些骚操作，开阔眼界，说不定一些case下，就用上了
date: 2018-05-30 18:06
header-img: "img/head.jpg"
categories: 
    - PostgreSQL
---

* TOC
{:toc}

# 级联信息查询

在PostgreSQL的主从结构中，有中间可以添加级联从库。我们有一个表，记录上生产库上48台机器的级联信息，如下例。

```sql
create table dbinfo ( id int4, host text, pid int4);
insert into dbinfo values ( 1, 'master', NULL);
insert into dbinfo values (generate_series(2,10), 'cascade', 1);
insert into dbinfo values (generate_series(11,14), 'cascade', 2);
insert into dbinfo values (generate_series(15,16), 'cascade', 7);
insert into dbinfo values (generate_series(17,32), 'slave', generate_series(1,16));
insert into dbinfo values (generate_series(33,48), 'slave', generate_series(1,16));
table dbinfo ;
```

我们希望知道某台机器的所有上层节点和下层节点，类似这样的查询我们可以通过WITH语句进行查询，如下。

```sql
postgres=# WITH RECURSIVE downstream AS
  (SELECT *
   FROM dbinfo
   WHERE pid = 2
   UNION ALL SELECT dbinfo.*
   FROM dbinfo,
        downstream
   WHERE dbinfo.pid = downstream.id)
SELECT *
FROM downstream;
 id |  host   | pid
----+---------+-----
 11 | cascade |   2
 12 | cascade |   2
 13 | cascade |   2
 14 | cascade |   2
 18 | slave   |   2
 34 | slave   |   2
 27 | slave   |  11
 28 | slave   |  12
 29 | slave   |  13
 30 | slave   |  14
 43 | slave   |  11
 44 | slave   |  12
 45 | slave   |  13
 46 | slave   |  14
(14 rows)

postgres=# WITH RECURSIVE upstream AS
  ( SELECT *
   FROM dbinfo
   WHERE id = 19
   UNION ALL SELECT dbinfo.*
   FROM dbinfo,
        upstream
   WHERE dbinfo.id = upstream.pid)
SELECT *
FROM upstream;
 id |  host   | pid
----+---------+-----
 19 | slave   |   3
  3 | cascade |   1
  1 | master  |
(3 rows)
```

# CTE

With语句在PostgreSQL中称为Common Table Expressions。标准的CTE可以很简单的建立一个临时表，这对于组织复杂查询很有帮助。普通的CTE可以将SQL代码进行模块化，更易读，也易于维护。另外，递归CTE在处理层级数据的时候，更加厉害，如上例，其类似于在sql中的for循环。

递归查询有两部分：

1. 启动数据：选择递归的初始行，可以有多列

2. 递归方法：基于初始行，产生更多的数据行；两者之间用`union all`连接，递归cte总是返回的是没有重复的数据，因为union；如下一个简单的递归cte

3. 递归终止条件。

   ```sql
   with recursive cruncher(inc, double, square) as (
     select 1, 2.0, 3.0 -- 初始数据
     union all
     select -- 递归方法
       cruncher.inc + 1,
       cruncher.double * 2,
       cruncher.square ^ 2
     from cruncher
     where inc < 10 -- 递归终止条件
   )
   select * from cruncher
   ```


# 有趣的应用

测试数据。

```sql
CREATE TABLE tbl (col INTEGER NOT NULL, col2 INTEGER NOT NULL);
INSERT INTO tbl
SELECT trunc(random()*5) AS col, (random()*1000000)::INT AS col2 FROM generate_series(1,10000000);
CREATE INDEX ON tbl (col, col2);
postgres=# \d tbl
                Table "public.tbl"
 Column |  Type   | Collation | Nullable | Default
--------+---------+-----------+----------+---------
 col    | integer |           | not null |
 col2   | integer |           | not null |
Indexes:
    "tbl_col_col2_idx" btree (col, col2)
```

## 宽松索引扫描

*Index scan* 一般就是指通过过滤条件直接定位结果数据的目标区间，区间是连续的。 *loose index scan*可以简单理解为可以跳过部分索引，目标区间是不连续的。

常说的索引都是指Btree，在一些数据库中支持通过loose index scan来高效的找到一列中的唯一值，当索引中有很多重复值的时候，这很高效；

PostgreSQL并不直接支持loose indexscan，但是可以使用递归CTE；查询的递归部分每次处理一个行，找到比上次处理的行大的最小值，如下测试案例，可见明显提高了DISTINCT的速度。

```sql
postgres=# select distinct col from tbl;
 col
-----
   0
   1
   3
   4
   2
(5 rows)

Time: 2207.951 ms (00:02.208)
postgres=# WITH RECURSIVE t AS (
   SELECT MIN(col) AS col FROM tbl
   UNION ALL
   SELECT (SELECT MIN(col) FROM tbl WHERE col > t.col)
   FROM t WHERE t.col IS NOT NULL
   )
SELECT col FROM t WHERE col IS NOT NULL
UNION ALL
SELECT NULL WHERE EXISTS(SELECT 1 FROM tbl WHERE col IS NULL);
 col
-----
   0
   1
   2
   3
   4
(5 rows)

Time: 1.489 ms
```

> Explain:
>
> 通过比较查询计划，我们可以看出Distinct使用的顺序扫描，而CTE的方式则是基于多次的索引扫描。
>
> ```sql
> postgres=# explain select distinct col from tbl;
>                              QUERY PLAN
> --------------------------------------------------------------------
>  HashAggregate  (cost=169247.81..169247.86 rows=5 width=4)
>    Group Key: col
>    ->  Seq Scan on tbl  (cost=0.00..144247.85 rows=9999985 width=4)
> (3 rows)
> 
> Time: 0.597 ms
> postgres=# explain WITH RECURSIVE t AS (
>    SELECT MIN(col) AS col FROM tbl
>    UNION ALL
>    SELECT (SELECT MIN(col) FROM tbl WHERE col > t.col)
>    FROM t WHERE t.col IS NOT NULL
>    )
> SELECT col FROM t WHERE col IS NOT NULL
> UNION ALL
> SELECT NULL WHERE EXISTS(SELECT 1 FROM tbl WHERE col IS NULL);
>                                                        QUERY PLAN
> ------------------------------------------------------------------------------------------------------------------------
>  Append  (cost=52.73..58.40 rows=101 width=4)
>    CTE t
>      ->  Recursive Union  (cost=0.46..52.73 rows=101 width=4)
>            ->  Result  (cost=0.46..0.47 rows=1 width=4)
>                  InitPlan 3 (returns $1)
>                    ->  Limit  (cost=0.43..0.46 rows=1 width=4)
>                          ->  Index Only Scan using tbl_col_col2_idx on tbl  (cost=0.43..253739.48 rows=9999985 width=4)
>                                Index Cond: (col IS NOT NULL)
>            ->  WorkTable Scan on t t_1  (cost=0.00..5.02 rows=10 width=4)
>                  Filter: (col IS NOT NULL)
>    ->  CTE Scan on t  (cost=0.00..2.02 rows=100 width=4)
>          Filter: (col IS NOT NULL)
>    ->  Result  (cost=2.63..2.64 rows=1 width=4)
>          One-Time Filter: $5
>          InitPlan 5 (returns $5)
>            ->  Index Only Scan using tbl_col_col2_idx on tbl tbl_1  (cost=0.43..2.63 rows=1 width=0)
>                  Index Cond: (col IS NULL)
> (17 rows)
> 
> Time: 1.066 ms
> ```

### 有效利用联合索引

PG中联合索引的任何子集都有可能使用索引（只是有可能，会基于代价进行估计）；但是只有当第一列有限制，使用索引的效果才好；MySQL中必须符合最左前缀原则：如果第一列没有出现在where条件中，就不会用多列索引；order by中的顺序必须和定义索引的时候一样。

当我们有一个联合索引，但是查询中并不会用到第一列的条件时，这时我们希望能够利用索引进行查询优化，可以穷举第一列的值，然后整合所有的查询结果，如下。

```sql
postgres=# SELECT COUNT(*) FROM tbl WHERE col2 = 9854;
 count
-------
     6
(1 row)

Time: 309.120 ms
postgres=# SELECT COUNT(*) FROM tbl WHERE col2 = 9854 AND col IN
(
  WITH RECURSIVE
     t AS (SELECT MIN(col) AS col FROM tbl
           UNION ALL
           SELECT (SELECT MIN(col) FROM tbl WHERE col > t.col) FROM t WHERE t.col IS NOT NULL)
  SELECT col FROM t
);
 count
-------
     6
(1 row)

Time: 1.008 ms

                                                                   QUERY PLAN
------------------------------------------------------------------------------------------------------------------------------------------------
 Aggregate  (cost=437.89..437.90 rows=1 width=8)
   ->  Nested Loop  (cost=56.45..437.86 rows=11 width=0)
         ->  HashAggregate  (cost=56.01..57.02 rows=101 width=4)
               Group Key: t.col
               ->  CTE Scan on t  (cost=52.73..54.75 rows=101 width=4)
                     CTE t
                       ->  Recursive Union  (cost=0.46..52.73 rows=101 width=4)
                             ->  Result  (cost=0.46..0.47 rows=1 width=4)
                                   InitPlan 3 (returns $1)
                                     ->  Limit  (cost=0.43..0.46 rows=1 width=4)
                                           ->  Index Only Scan using tbl_col_col2_idx on tbl tbl_1  (cost=0.43..253739.48 rows=9999985 width=4)
                                                 Index Cond: (col IS NOT NULL)
                             ->  WorkTable Scan on t t_1  (cost=0.00..5.02 rows=10 width=4)
                                   Filter: (col IS NOT NULL)
         ->  Index Only Scan using tbl_col_col2_idx on tbl  (cost=0.43..3.75 rows=2 width=4)
               Index Cond: ((col = t.col) AND (col2 = 9854))
(16 rows)
```

第二次查询利用Loose Index Scan统计了col的所有值，然后利用条件：`col=? && col2=9854`进行查询，这样就能利用到`tbl_col_col2_idx`索引了。

## 旅行商问题

n个城市，从其中一个城市出发，经过所有城市，最终回到起点的最短距离；

```sql
--城市数据测试表
create table places as (
  select
    'Seattle' as name, 47.6097 as lat, 122.3331 as lon
    union all select 'San Francisco', 37.7833, 122.4167
    union all select 'Austin', 30.2500, 97.7500
    union all select 'New York', 40.7127, 74.0059
    union all select 'Boston', 42.3601, 71.0589
    union all select 'Chicago', 41.8369, 87.6847
    union all select 'Los Angeles', 34.0500, 118.2500
    union all select 'Denver', 39.7392, 104.9903
);
-- 距离
create or replace function lat_lon_distance(
  lat1 float, lon1 float, lat2 float, lon2 float
) returns float as $$
declare
  x float = 69.1 * (lat2 - lat1);
  y float = 69.1 * (lon2 - lon1) * cos(lat1 / 57.3);
begin
  return sqrt(x * x + y * y);
end
$$ language plpgsql;
```

假设从 San Francisco出发，遍历各个城市。

SF就是递归的起始数据，每次递归就是可能的访问序列，维护四类信息：

+ 访问顺序字符串
+ 最后一个城市的坐标
+ 当前走过的距离
+ 路过的城市数

当某个城市已经出现在**访问顺序字符串**中，表示该城市来过了，那么不产生新的数据；最终，当所有城市都出现在**访问顺序字符串**中时，表示穷举了所有的可能情况。通过UNION ALL，就得到了长度为1~8的所有序列，这些情况都是互不相同的；

然而我们还需要回到原点；只需要找到num_place=8的序列中，回到原点的最近距离，即order by 2 limit 1 即可。

```sql
postgres=# with recursive travel (places_chain, last_lat, last_lon,
    total_distance, num_places) as (
  select -- 初始行
    name, lat, lon, 0::float, 1
    from places
    where name = 'San Francisco'
  union all
  select -- 递归
    -- 添加到访问链中
    travel.places_chain || ' -> ' || places.name,
    places.lat,
    places.lon,
    -- 增加当前距离
    travel.total_distance +
      lat_lon_distance(last_lat, last_lon, places.lat, places.lon),
    travel.num_places + 1
  from
    places, travel
  where
    -- 当前城市没有出现在访问链中的时候，继续旅行，否则不递归旅行
    position(places.name in travel.places_chain) = 0
)
select
  travel.places_chain || ' -> ' || places.name as path,
  total_distance + lat_lon_distance(
      travel.last_lat, travel.last_lon,
      places.lat, places.lon) as final_dist
from travel, places
where
  travel.num_places = 8
  and places.name = 'San Francisco'
order by 2 -- ascending!
limit 1;
-[ RECORD 1 ]-------------------------------------------------------------------------------------------------------------
path       | San Francisco -> Seattle -> Denver -> Chicago -> Boston -> New York -> Austin -> Los Angeles -> San Francisco
final_dist | 6670.83798218894

Time: 166.302 ms
```



###### 参考文章

https://www.periscopedata.com/blog/postgres-recursive-cte

http://www.postgresqltutorial.com/postgresql-recursive-query/

https://wiki.postgresql.org/wiki/Loose_indexscan

https://github.com/digoal/blog/blob/master/201705/20170519_01.md
