---
layout: post
title: 走近SQL
date: 2018-07-25 13:23
header-img: "img/head.jpg"
categories: 
  - SQL
typora-root-url: ../../layamon.github.io
---

SQL意思是Structured Query Language，是和数据库交互的基本语言。和常规的编程语言不通，SQL是告诉计算机你需要什么数据，而不是告诉计算机如何产生数据，如下。

```python
for line in file:
	record = parse(line)
	if "Ice Cube" == record[0]:
		print int(record[1])

vs 

SELECT year FROM artists
WHERE name = "Ice Cube";
```

SQL就是基于**关系代数操作符**操作**关系型数据**，来获取关系型数据库中的数据。

> 区别于关系型数据，还有多种数据模式：
>
> + No-SQL
>   + key/value
>   + Graph
>   + Document
>   + Column-family : 数据表的列是不固定的，比如Cassandra，不同行的数据可能有不同的列。
> + Array / Matrix：科学计算，机器学习要处理的数据模式

本文整理了笔者写SQL以及平时看到的一些问题，希望能对看到这篇文章的人有帮助。

# GroupBy困扰

比如下面的例子，你能了解为什么这些语句有问题么？

```sql
-- Wrong
SELECT first_name, count(*)
FROM customer
WHERE count(*) > 1
GROUP BY first_name
 
-- Correct
SELECT first_name, count(*)
FROM customer
GROUP BY first_name
HAVING count(*) > 1
 
-- Correct
SELECT first_name, count(*)
FROM customer
GROUP BY first_name
ORDER BY count(*) DESC
 
-- Wrong
SELECT first_name, last_name, count(*)
FROM customer
GROUP BY first_name
 
-- Correct
SELECT first_name, MAX(last_name), count(*)
FROM customer
GROUP BY first_name
 
-- Wrong
SELECT first_name || ' ' || last_name, count(*)
FROM customer
GROUP BY first_name
 
-- Correct
SELECT first_name || ' ' || MAX(last_name), count(*)
FROM customer
GROUP BY first_name
 
-- Correct
SELECT MAX(first_name || ' ' || last_name), count(*)
FROM customer
GROUP BY first_name
```

具体的语法可以从[SQL文档](https://stackoverflow.com/questions/6000847/authoritative-sql-standard-documentation)中查看，有这么个常见的原则：如果有`GROUP BY`语句，那么`HAVING`、`ORDER BY`、`SELECT`中只能出现两种对象，一是 `GROUP BY`后表达式，二是聚集函数。

# SQL执行的顺序

在SQL中，每个关键字可能都对应数据库中的一个执行单元，执行单元之间的逻辑顺序和SQL语句中的语句顺序可能大不相同；而由于查询优化器的作用，逻辑顺序又和实际执行顺序不同。那么，每个关键字的逻辑顺序是什么样呢？SQL操作其实就是一些关系代数操作符算子进行的计算，顺序大概如下：

1. FROM
2. WHERE
3. GROUP BY
4. Aggregations Function
5. HAVING
6. WINDOW FUNCTION
7. SELECT
8. DISTINCT
9. UNION/INTERSET/EXCEPT
10. ORDER BY
11. OFFSET
12. LIMIT

 因此，当写SQL时，了解了这些逻辑顺序，就能理解有些语法为什么不对，如下例。

```sql
-- Doesn't work, cannot put window functions in GROUP BY
SELECT ntile(4) ORDER BY (age) AS bucket, MIN(age), MAX(age)
FROM customer
GROUP BY ntile(4) ORDER BY (age)
 
-- Works:
SELECT bucket, MIN(age), MAX(age)
FROM (
  SELECT age, ntile(4) ORDER BY (age) AS bucket
  FROM customer
) c
GROUP BY bucket
```

## Filter放在Join ON中还是Where中

一般情况下，由于选择下推这都是一样的。但是对于OuterJoin需要区分两者的不同。

# 例题

> In PostgreSQL

## 表的最近三条记录

```sql
SELECT *
FROM tbl_testtable
OFFSET
  (SELECT count(1)-3
   FROM tbl_testtable) LIMIT 3;
```

## 板球运动员的相关系数查询

```sql
select
  Player1
  ,Player2
  ,(Avg(Runs1 * Runs2) - (Avg(Runs1) * Avg(Runs2))) /
  (stddev_pop(Runs1) * stddev_pop(Runs2)) as PlayersCoefficientRuns
from
(
  select
    a.PlayerName as Player1
    ,a.Runs as Runs1
    ,b.PlayerName as Player2
    ,b.Runs as Runs2
    ,a.MatchYear
  from tbl_Players a
  cross join tbl_Players b
  where b.PlayerName>a.PlayerName and a.MatchYear=b.MatchYear
) as t
group by Player1, Player2;
```

## 没有主键的表，删除重复记录

```sql
WITH cte AS
  (SELECT min(ctid) AS minctid ,
          id
   FROM tbl_testtable
   GROUP BY id)
DELETE
FROM tbl_testtable AS t
WHERE NOT EXISTS
    (SELECT 1
     FROM cte
     WHERE t.ctid = cte.minctid)
  AND t.id =3;
```

## 生成19世纪的日历

```sql
SELECT split_part(generate_series::text,' ',1)
FROM generate_series('1990-01-01'::TIMESTAMP, '2000-01-01', '1 days');
```

## 使用递归SQL，生产某时间后的年份

```sql
 WITH RECURSIVE cte AS
  ( SELECT '2001-09-28'::TIMESTAMP AS dt
   UNION ALL SELECT dt + interval '1 years'
   FROM cte
   WHERE dt < '2009-09-28')
SELECT date_part('year',dt)
FROM cte;
```

## 计算三的幂

```sql
WITH RECURSIVE cte AS
  (SELECT 1 AS power_of_3
   UNION ALL SELECT power_of_3 * 3
   FROM cte
   WHERE power_of_3 < 100)
SELECT *
FROM cte;
```

## 计算中位数

```sql
  CREATE OR REPLACE FUNCTION _final_median(NUMERIC[])
   RETURNS NUMERIC AS
$$
   SELECT AVG(val)
   FROM (
     SELECT val
     FROM unnest($1) val
     ORDER BY 1
     LIMIT  2 - MOD(array_upper($1, 1), 2)
     OFFSET CEIL(array_upper($1, 1) / 2.0) - 1
   ) sub;
$$
LANGUAGE 'sql' IMMUTABLE;
 
CREATE AGGREGATE median(NUMERIC) (
  SFUNC=array_append,
  STYPE=NUMERIC[],
  FINALFUNC=_final_median,
  INITCOND='{}'
);
```

## 计算每个月的最大最小销售记录

```sql
select 
	Month_No
	,min(Total_Unit_Sold) as Min_Sales
	,max(Total_Unit_Sold) as Max_Sales 
from tbl_Products
group by Month_No
```

## 找到每个月的星期一的日期

```sql
SELECT *
FROM
  (SELECT CASE
              WHEN extract(dow
                           FROM t) = 1 THEN t
          END AS dts
   FROM generate_series('2018-01-01'::TIMESTAMP,'2018-02-01','1 days') AS t) as subt
WHERE dts IS NOT NULL;
```

