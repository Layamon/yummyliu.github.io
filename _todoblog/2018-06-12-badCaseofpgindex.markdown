---
layout: post
title: PostgreSQL添加索引并非100%好事？(译)
date: 2018-06-12 10:30
header-img: "img/head.jpg"
categories: 
  - PostgreSQL
---

* TOC
{:toc}


我们都知道添加索引是有性能损失的——数据更新会变慢，index会占用额外的空间；我们时常会由此删掉一些不用的索引；

但是大部分的人不知道SELECT的性能也会被一个新的索引影响，大部分人只是认为新索引没有用到是个浪费；这里展示一个添加索引会让性能变坏的case。

### Example

```sql
CREATE TABLE skewed (
   sort        integer NOT NULL,
   category    integer NOT NULL,
   interesting boolean NOT NULL
);
 
INSERT INTO skewed
   SELECT i, i%1000, i>50000
   FROM generate_series(1, 1000000) i;
 
CREATE INDEX skewed_category_idx ON skewed (category);
 
VACUUM (ANALYZE) skewed;
```

我们要找到category=42的条件下的TOP 20；

```sql
postgres@dbtest:5432/postgres=# EXPLAIN (ANALYZE, BUFFERS)
postgres-# SELECT * FROM skewed
postgres-# WHERE interesting AND category = 42
postgres-# ORDER BY sort
postgres-# LIMIT 20;

```

PostgreSQL基于index，找到category=42的1000行，然后sort找到TOP 20，耗时3.6ms；

##### Add Index

我们想添加一个索引，让sort更快一些；

```sql
postgres@dbtest:5432/postgres=# CREATE INDEX skewed_sort_idx ON skewed (sort);
CREATE INDEX
postgres@dbtest:5432/postgres=# \d skewed
                 Table "public.skewed"
   Column    |  Type   | Collation | Nullable | Default
-------------+---------+-----------+----------+---------
 sort        | integer |           | not null |
 category    | integer |           | not null |
 interesting | boolean |           | not null |
Indexes:
    "skewed_category_idx" btree (category)
    "skewed_sort_idx" btree (sort)
    
postgres@dbtest:5432/postgres=# EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM skewed
WHERE interesting AND category = 42
ORDER BY sort
LIMIT 20;
                                                              QUERY PLAN
---------------------------------------------------------------------------------------------------------------------------------------
 Limit  (cost=0.42..737.14 rows=20 width=9) (actual time=18.801..26.292 rows=20 loops=1)
   Buffers: shared hit=374 read=191
   ->  Index Scan using skewed_sort_idx on skewed  (cost=0.42..33889.43 rows=920 width=9) (actual time=18.800..26.281 rows=20 loops=1)
         Filter: (interesting AND (category = 42))
         Rows Removed by Filter: 69022
         Buffers: shared hit=374 read=191
 Planning time: 0.350 ms
 Execution time: 26.336 ms
(8 rows)
```

居然变慢了！23ms

###### Why？

PostgreSQL认为基于有序的index，找到符合条件的前20条，会更快一些；但是PG不知道符合条件的行，在拍好序的列表中是如何分布的，这样需要扫描69042个元组（Rows Removed by Filter: 69022），才能找到满足条件的20个；

##### Solution

PostgreSQL 10中，添加了额外的统计信息，来追踪不同列的值的相关性；但是没有值的分布信息，在这个查询中帮不上忙，这里只能找别的变通方法；

1. 删掉误导PostgreSQL的index，但是不能因为一类查询删除一个index；

2. 改写SQL；

   + 使用基于OFFSET 0的子查询

     ```sql
     SELECT *
     FROM (SELECT * FROM skewed
           WHERE interesting AND category = 42
           OFFSET 0) q
     ORDER BY sort
     LIMIT 20;
     ```

     子查询加了OFFSET和LIMIT，就不会被展开了；

   + 排序的列使用表达式

     ```
     SELECT * FROM skewed
     WHERE interesting AND category = 42
     ORDER BY sort + 0
     LIMIT 20;
     ```

   + 本例中不可取，但是可以考虑一下，建一个条件索引；

     ```sql
     postgres@160.40:5432/postgres=# CREATE INDEX skewed_sort_where_idx ON skewed (sort) where interesting;
     CREATE INDEX
     postgres@160.40:5432/postgres=# set enable_indexscan = off;
     SET
     postgres@160.40:5432/postgres=# EXPLAIN (ANALYZE, BUFFERS)
     SELECT * FROM skewed
     WHERE interesting AND category = 42
     ORDER BY sort
     LIMIT 20;
                                                                       QUERY PLAN
     ----------------------------------------------------------------------------------------------------------------------------------------------
      Limit  (cost=2530.97..2531.02 rows=20 width=9) (actual time=3.291..3.300 rows=20 loops=1)
        Buffers: shared hit=1006
        ->  Sort  (cost=2530.97..2533.27 rows=920 width=9) (actual time=3.290..3.293 rows=20 loops=1)
              Sort Key: sort
              Sort Method: top-N heapsort  Memory: 25kB
              Buffers: shared hit=1006
              ->  Bitmap Heap Scan on skewed  (cost=19.91..2506.49 rows=920 width=9) (actual time=0.766..3.040 rows=950 loops=1)
                    Recheck Cond: (category = 42)
                    Filter: interesting
                    Rows Removed by Filter: 50
                    Heap Blocks: exact=1000
                    Buffers: shared hit=1006
                    ->  Bitmap Index Scan on skewed_category_idx  (cost=0.00..19.68 rows=968 width=0) (actual time=0.366..0.366 rows=1000 loops=1)
                          Index Cond: (category = 42)
                          Buffers: shared hit=6
      Planning time: 0.372 ms
      Execution time: 3.355 ms
     (17 rows)

     postgres@160.40:5432/postgres=# set enable_indexscan = on;
     SET
     postgres@160.40:5432/postgres=# EXPLAIN (ANALYZE, BUFFERS)
     SELECT * FROM skewed
     WHERE interesting AND category = 42
     ORDER BY sort
     LIMIT 20;
                                                                     QUERY PLAN
     -------------------------------------------------------------------------------------------------------------------------------------------
      Limit  (cost=0.42..700.35 rows=20 width=9) (actual time=0.084..7.631 rows=20 loops=1)
        Buffers: shared hit=104 read=55
        ->  Index Scan using skewed_sort_where_idx on skewed  (cost=0.42..32196.84 rows=920 width=9) (actual time=0.082..7.620 rows=20 loops=1)
              Filter: (category = 42)
              Rows Removed by Filter: 19022
              Buffers: shared hit=104 read=55
      Planning time: 0.177 ms
      Execution time: 7.668 ms
     (8 rows)
     ```

     基于已经有序的index Scan，最后的结果是7.8ms ；而基于bitmap index scan+sort却是3ms；我们知道的是，PostgreSQL中，少量元组使用index scan；大量的直接使用seq scan；而两者之间则采用bitmap index scan(随机磁盘IO转顺序IO);

     |               | **Index Scan**                                               | **Bitmap Index Scan**                                        |
     | ------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
     | Operation     | Index scan reads the index in alternation, bouncing between table and index, row at a time. | Scans all index rows before examining base table.This populates a TID bitmap. |
     | Scan Property | Random I/O against the base table. Read a row from the index, then a row from the table, and so on. | Table I/O is sequential, results in physical order.          |
     | LIMIT clause  | useful in combination with LIMIT                             | Handles LIMIT poorly                                         |

     这里PostgreSQL明显选择了一个不好的执行计划:

     ```sql
     postgres@160.40:5432/postgres=# EXPLAIN
     SELECT * FROM skewed
     WHERE interesting AND category = 42
     ORDER BY sort
     LIMIT 20;
                                                QUERY PLAN
     ------------------------------------------------------------------------------------------------
      Limit  (cost=0.42..700.35 rows=20 width=9)
        ->  Index Scan using skewed_sort_where_idx on skewed  (cost=0.42..32196.84 rows=920 width=9)
              Filter: (category = 42)
     (3 rows)

     postgres@160.40:5432/postgres=# set enable_indexscan = off;
     SET
     postgres@160.40:5432/postgres=# EXPLAIN
     SELECT * FROM skewed
     WHERE interesting AND category = 42
     ORDER BY sort
     LIMIT 20;
                                                QUERY PLAN
     -------------------------------------------------------------------------------------------------
      Limit  (cost=2530.97..2531.02 rows=20 width=9)
        ->  Sort  (cost=2530.97..2533.27 rows=920 width=9)
              Sort Key: sort
              ->  Bitmap Heap Scan on skewed  (cost=19.91..2506.49 rows=920 width=9)
                    Recheck Cond: (category = 42)
                    Filter: interesting
                    ->  Bitmap Index Scan on skewed_category_idx  (cost=0.00..19.68 rows=968 width=0)
                          Index Cond: (category = 42)
     (8 rows)
     ```

     但是，当limit大一点到100时，执行计划又准了

     ```sql
     postgres@160.40:5432/postgres=# EXPLAIN
     SELECT * FROM skewed
     WHERE interesting AND category = 42
     ORDER BY sort
     LIMIT 100;
                                                QUERY PLAN
     -------------------------------------------------------------------------------------------------
      Limit  (cost=2541.65..2541.90 rows=100 width=9)
        ->  Sort  (cost=2541.65..2543.95 rows=920 width=9)
              Sort Key: sort
              ->  Bitmap Heap Scan on skewed  (cost=19.91..2506.49 rows=920 width=9)
                    Recheck Cond: (category = 42)
                    Filter: interesting
                    ->  Bitmap Index Scan on skewed_category_idx  (cost=0.00..19.68 rows=968 width=0)
                          Index Cond: (category = 42)
     (8 rows)
     postgres@160.40:5432/postgres=# set enable_bitmapscan = off;
     SET
     postgres@160.40:5432/postgres=# EXPLAIN
     SELECT * FROM skewed
     WHERE interesting AND category = 42
     ORDER BY sort
     LIMIT 100;
                                                QUERY PLAN
     ------------------------------------------------------------------------------------------------
      Limit  (cost=0.42..3500.04 rows=100 width=9)
        ->  Index Scan using skewed_sort_where_idx on skewed  (cost=0.42..32196.84 rows=920 width=9)
              Filter: (category = 42)
     (3 rows)
     ```

     #### 综上

     PostgreSQL 的代价估计，不一定总是最优的；针对某些查询添加的索引，有可能会误导其他的查询，产生不好的执行计划；

     [ref](http://bitnine.net/blog-useful-information/bitmap-index-scan/)

     [ref](https://www.cybertec-postgresql.com/en/index-decreases-select-performance/)
