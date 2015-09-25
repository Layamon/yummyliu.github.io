---
layout: post
title: PostgreSQL窗口函数
subtitle: 
date: 2018-02-05 18:06
header-img: "img/head.jpg"
categories: 
    - PostgreSQL
---

* TOC
{:toc}

#  Window function

与当前行相关行的跨行计算；

形式如下，windowfunction+over()：

```Sql
select WINDOWFUNCTON(...) OVER ([PARTITION BY ...] [ORDER BY ...]) FROM ....
```

## 与 aggregate function 的不同

聚集函数得到一个输出结果，窗口函数针对每个元组得到一个结果。

## 注意点：

+ window function 是基于查询过滤（`where`，`group by`， `having`）好的结果再进行操作，这些结果可以看成一个 virtual table。

+ 只能用在`SELECT` list 和  `ORDER BY` 中，不能用在`where`，`group by`， `having`中，这与上一条类似的道理：*window function只是在获得数据后进行的逻辑运算*。

+ 大部分windowfunction只是处理**window frame**中的数据，当over()中有 `ORDER BY`时，window frame就是**从分组的排序头到与当前元素相同的元素为止的所有元素**,否则，就是分组中的所有元素

  ```Sql
  SELECT salary, sum(salary) OVER (ORDER BY salary) FROM empsalary;
   salary |  sum  
  --------+-------
     3500 |  3500
     3900 |  7400
     4200 | 11600
     4500 | 16100
     4800 | 25700
     4800 | 25700
     5000 | 30700
     5200 | 41100
     5200 | 41100
     6000 | 47100
  ```

+ 当需要基于windowfunction的结果进行过滤时，使用子查询

  ```Sql
  SELECT depname, empno, salary, enroll_date
  FROM
    (SELECT depname, empno, salary, enroll_date,
            rank() OVER (PARTITION BY depname ORDER BY salary DESC, empno) AS pos
       FROM empsalary
    ) AS ss
  WHERE pos < 3;
  ```

## PG的window function

+ built-in window functions

  https://www.postgresql.org/docs/9.6/static/functions-window.html#FUNCTIONS-WINDOW-TABLE


+ built-in or user-defined normal aggregate function (but not ordered-set or hypothetical-set aggregates) can be used as a window function

  https://www.postgresql.org/docs/9.6/static/functions-aggregate.html
