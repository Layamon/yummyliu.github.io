---
layout: post
title: PostgreSQL函数调用小细节
date: 2018-02-05 18:08
header-img: "img/head.jpg"
categories: 
    - PostgreSQL
---

## 避免不必要的函数调用

FUNCTION有三种：

+ VOLATILE : 不管输入是否相同，输出都是不确定的

+ STABLE : 在同一个事务中，输入相同，输出就是相同的；

  + 特别注意的是`now`这个函数，在同一个事务中输出是一样的

    ```sql
    postgres=# begin;
    BEGIN
    postgres=# select now();
                  now
    -------------------------------
     2018-01-30 14:12:56.915239+08
    (1 row)

    postgres=# select now();
                  now
    -------------------------------
     2018-01-30 14:12:56.915239+08
    (1 row)

    postgres=# select now();
                  now
    -------------------------------
     2018-01-30 14:12:56.915239+08
    ```

+ IMMUTABLE : 不管是不是在同一个事务中，输入相同输出就是相同的

  比如一些数据函数，`cos,sin,tan`

```Sql
postgres=# create table demo as select * from generate_series(1,1000) as id;
SELECT 1000
postgres=# \d
        List of relations
 Schema | Name | Type  |  Owner
--------+------+-------+----------
 public | demo | table | postgres
(1 row)

postgres=# create index idx_id on demo(id);
CREATE INDEX
postgres=# explain select * from demo where id = 20;
                               QUERY PLAN
------------------------------------------------------------------------
 Index Only Scan using idx_id on demo  (cost=0.28..8.29 rows=1 width=4)
   Index Cond: (id = 20)
(2 rows)

postgres=# explain select * from demo where id = mymax(20,20);
                      QUERY PLAN
------------------------------------------------------
 Seq Scan on demo  (cost=0.00..267.50 rows=1 width=4)
   Filter: (id = mymax(20, 20))
(2 rows)

postgres=# drop function mymax ;
DROP FUNCTION
postgres=# CREATE OR REPLACE FUNCTION mymax(int, int)
RETURNS int
AS
$$
  BEGIN
       RETURN CASE WHEN $1 > $2 THEN $1 ELSE $2 END;
  END;
$$ LANGUAGE 'plpgsql'IMMUTABLE;
CREATE FUNCTION
postgres=# explain select * from demo where id = mymax(20,20);
                               QUERY PLAN
------------------------------------------------------------------------
 Index Only Scan using idx_id on demo  (cost=0.28..8.29 rows=1 width=4)
   Index Cond: (id = 20)
(2 rows)
```



### 小结

就类似C++中，变量是const，好的习惯就是把变量声明成const；同样PG中定义函数，能严格一点就严格一点，能够给pg更多的提示，就意味着更好的优化。

```sql
SELECT * FROM pg_stat_user_functions ;
```

可以从数据库中，按个检查一下
