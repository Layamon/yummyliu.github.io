---
layout: post
title: SQL Puzzles
date: 2018-05-30 18:06
header-img: "img/head.jpg"
categories: 
    - PostgreSQL
---

> ###### 在SQL中计算，还是在APP中计算
>
> - 计算复杂度；在app server中是水平扩展，在dbserver中是垂直扩展
> - 数据量；在db端可以节省很多带宽和磁盘IO;
> - 便利性；SQL不适合复杂的工作；


#### 测试数据

[数据源](http://www.nyxdata.com/nysedata/asp/factbook/viewer_edition.asp?mode=table&key=3327&category=3)

```sql
BEGIN;

CREATE TABLE factbook
 (
   YEAR    INT,
   DATE    DATE,
   shares  text,
   trades  text,
   dollars text
 );

\copy factbook FROM 'factbook.csv' WITH delimiter E'\t' NULL ''

ALTER TABLE factbook
   ALTER shares
    TYPE BIGINT
   USING REPLACE(shares, ',', '')::BIGINT,

   ALTER trades
    TYPE BIGINT
   USING REPLACE(trades, ',', '')::BIGINT,

   ALTER dollars
    TYPE BIGINT
   USING SUBSTRING(REPLACE(dollars, ',', '') FROM 2)::NUMERIC;

commit;

demo=# \set start '2017-02-01'
demo=#   SELECT DATE,
         to_char(shares, '99G999G999G999') AS shares,
         to_char(trades, '99G999G999') AS trades,
         to_char(dollars, 'L99G999G999G999') AS dollars
    FROM factbook
   WHERE DATE >= DATE :'start'
     AND DATE  < DATE :'start' + INTERVAL '1 month'
ORDER BY DATE;
    date    |     shares      |   trades    |     dollars
------------+-----------------+-------------+------------------
 2017-02-01 |   1,161,001,502 |   5,217,859 | $ 44,660,060,305
 2017-02-02 |   1,128,144,760 |   4,586,343 | $ 43,276,102,903
 2017-02-03 |   1,084,735,476 |   4,396,485 | $ 42,801,562,275
 2017-02-06 |     954,533,086 |   3,817,270 | $ 37,300,908,120
 2017-02-07 |   1,037,660,897 |   4,220,252 | $ 39,754,062,721
 2017-02-08 |   1,100,076,176 |   4,410,966 | $ 40,491,648,732
 2017-02-09 |   1,081,638,761 |   4,462,009 | $ 40,169,585,511
 2017-02-10 |   1,021,379,481 |   4,028,745 | $ 38,347,515,768
 2017-02-13 |   1,020,482,007 |   3,963,509 | $ 38,745,317,913
 2017-02-14 |   1,041,009,698 |   4,299,974 | $ 40,737,106,101
 2017-02-15 |   1,120,119,333 |   4,424,251 | $ 43,802,653,477
 2017-02-16 |   1,091,339,672 |   4,461,548 | $ 41,956,691,405
 2017-02-17 |   1,160,693,221 |   4,132,233 | $ 48,862,504,551
 2017-02-21 |   1,103,777,644 |   4,323,282 | $ 44,416,927,777
 2017-02-22 |   1,064,236,648 |   4,169,982 | $ 41,137,731,714
 2017-02-23 |   1,192,772,644 |   4,839,887 | $ 44,254,446,593
 2017-02-24 |   1,187,320,171 |   4,656,770 | $ 45,229,398,830
 2017-02-27 |   1,132,693,382 |   4,243,911 | $ 43,613,734,358
 2017-02-28 |   1,455,597,403 |   4,789,769 | $ 57,874,495,227
```

#### 统计一个月中所有日子的值，把不存在置零

```sql
  SELECT CAST(calendar.entry AS DATE) AS DATE,
         COALESCE(shares, 0) AS shares,
         COALESCE(trades, 0) AS trades,
         to_char(
             COALESCE(dollars, 0),
             'L99G999G999G999'
         ) AS dollars
    FROM /*
          * Generate the target month's calendar then LEFT JOIN
          * each day against the factbook dataset, so as to have
          * every day in the result set, whether or not we have a
          * book entry for the day.
          */
         generate_series(DATE :'start',
                         DATE :'start' + INTERVAL '1 month'
                                       - INTERVAL '1 day',
                         INTERVAL '1 day'
         )
         AS calendar(entry)
         LEFT JOIN factbook
                ON factbook.DATE = calendar.entry
ORDER BY DATE;
```

#### 计算每周相比上周的变化

```sql
WITH computed_data AS
(
  SELECT CAST(DATE AS DATE)   AS DATE,
         to_char(DATE, 'Dy')  AS DAY,
         COALESCE(dollars, 0) AS dollars,
         lag(dollars, 1)
           OVER(
             partition BY EXTRACT('isodow' FROM DATE)
                 ORDER BY DATE
           )
         AS last_week_dollars
    FROM /*
          * Generate the month calendar, plus a week before
          * so that we have values to compare dollars against
          * even for the first week of the month.
          */
         generate_series(DATE :'start' - INTERVAL '1 week',
                         DATE :'start' + INTERVAL '1 month'
                                       - INTERVAL '1 day',
                         INTERVAL '1 day'
         )
         AS calendar(DATE)
         LEFT JOIN factbook USING(DATE)
)
  SELECT DATE, DAY,
         to_char(
             COALESCE(dollars, 0),
             'L99G999G999G999'
         ) AS dollars,
         CASE WHEN dollars IS NOT NULL
               AND dollars <> 0
              THEN round(  100.0
                         * (dollars - last_week_dollars)
                         / dollars
                       , 2)
          END
         AS "WoW %"
    FROM computed_data
   WHERE DATE >= DATE :'start'
ORDER BY DATE;
```

#### 找到股票中连续增长最快的

```sql
with diffs as
  (
     --
     -- compute if the current stock is raising or lowering
     --
     select date, dollars,
            case when   dollars
                      - lag(dollars, 1) over(order by date)
                      < 0
                 then '-'
                 else '+'
             end as diff
       from factbook
      where date is not null
   order by date
  )
select count(*) as days

  from diffs
       left join lateral
       --
       -- for each row of our "diffs" relation, compute the next
       -- day at which the stock change direction is changing, that is
       -- where a + becomes a - or the other way round
       --
       (
         select date
           from diffs d2
          where d2.date > diffs.date
            and d2.diff <> diffs.diff
       order by date
          limit 1
       ) as diff_change on true

 where diffs.diff = '+'

--
-- we group by the date where the +/- change occurs
-- and count how many rows share that value
--
group by diff_change.date

--
-- and we only keep the longest continuously rising number of days
--
order by days desc
   limit 1;
```

> left join lateral: 逐个遍历左边的行（左边也可以是一个子查询），在右边引用进行查询；这里左边是一个CTE-diffs；遍历diffs中的每个diff列为'+'的行，进行右边的子查询，对于左边的每一行，找到比当前date大的但是diff不同的列，即，增长停止的列；按照停止列的date分组，统计count(*),

##### 另一种解法

```sql
with recursive raising as
(
   (
       --
       -- start with the most recent date in our dataset
       -- and prepare our recursive computed data: series
       -- of increasing dollars values and number of days
       -- in a row of seeing an increase
       --
   select date, dollars, array[dollars] as series, 0 as days
     from factbook
    where date is not null
 order by date desc
    limit 1
   )

   union all

  (
         --
         -- fetch the previous day of factbook data and compute
         -- the new series/days values depending on the value of
         -- the previous factbook day compared to the value of the
         -- current day in raising
         --
     select factbook.date,
            factbook.dollars,
            case when raising.dollars > factbook.dollars
                 then array[factbook.dollars] || raising.series
                 else array[factbook.dollars]
             end as series,
            case when raising.dollars > factbook.dollars
                 then days + 1
                 else 0
             end as days
       from factbook join raising on factbook.date < raising.date
   order by date desc
      limit 1
  )
)
--
-- display only the interesting part of the recursive
-- query results:
--
  select days, date, series
    from raising
   where days > 4
order by days desc;
```

> 初始记录从最新一条记录开始，从raise的最新一条记录开始；每次递归，在上轮的集合基础上，把每条记录延伸（如果找到date比当前小，dollars也比当前小；那么当前记录的array+1，days+1,没有找到的记录day=0）；
>
> 0. 起初有一行；
> 1. 找到比raise中date小的最大日期，
>    1. 如果该日期dollar小，以该日期为起始日期并且新的行day+1
>    2. 否则，找到了新的一个起点，day=0；
> 2. 最终把所有的序列union，找到最大的

