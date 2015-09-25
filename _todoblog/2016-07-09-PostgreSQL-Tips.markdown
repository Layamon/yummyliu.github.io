---
layout: post
title: PostgreSQL杂谈
date: 2016-07-09 23:25
header-img: "img/head.jpg"
categories: 
    - DBMS
typora-root-url: ../../layamon.github.io
---

* TOC
{:toc}


### 关于limit

postgresql 现在有个portal 来运行
关于查询结果的返回：查询的描述结构中有一个 DestReceiver
DestReceiver中的receiveSlot是一个回调函数，
execute plan 函数参数中有一个numberTuple 每次执行返回结果就是最大numberTuple的。
使用limi 3t参数，发现这里还是0，追起来发现，这个numbertuple设置为0就是处理所有的数据，limit设定为3的时候，是和返回值相关，executeplan 中有个死循环，只有当number都处理完，或者TupisNull才会退出，所以limit 设定为3 ，返回的结果就是三个元素，而关于返回结果的输出，
代码中，有两种输出方式：text和binary，使用psql的时候 是走的text方式，另一个binary 猜测是走的libpg odbc？

### netezza 转 pg

由于tpcds没有 pg的 sql查询，直接执行有一些问题

+   日期加减，，14 days -> interval 14 day
+   子查询要有别名
+   grouping
+   ERROR:  failed to find conversion function from unknown to text 
> http://stackoverflow.com/questions/18073901/failed-to-find-conversion-function-from-unknown-to-text
>
> Postgres is happy, if it can detect types of untyped constants from the context. But when any context is not possible, and when query is little bit more complex than trivial, then this mechanism fails. These rules are specific for any SELECT clause, and some are stricter, some not. If I can say, then older routines are more tolerant (due higher compatibility with Oracle and less negative impact on beginners), modern are less tolerant (due higher safety to type errors).
> There was some proposals try to work with any unknown literal constant like text constant, but was rejected for more reasons. So I don't expect significant changes in this area. This issue is usually related to synthetic tests - and less to real queries, where types are deduced from column types.
>
> +   ![icov/image/icovn.png)
+ pg不区分大小写

### over()窗口函数

窗口函数也是计算一些行集合（多个行组成的集合，我们称之为窗口window frame）的数据，有点类似与聚集函数（aggregate function）。但和常规的聚集函数不同的是，窗口函数不会将参与计算的行合并成一行输出，而是保留它们原来的样子

### oom

执行tpcds99个查询的时候，部分查询出现oom，起初希望性能好一点，所以把work_mem和share_buffer设置的比较大，现在将share_buffer调小了，部分oom消失了，可是还是有部分查询存在oom的问题，绕了一圈，发现，work_mem是针对操作符级别的用来作为 sort，hash_table的内存空间，这样我把work_mem调大了，当有操作符需要work_mem的时候就申请不到空间了

### 生成倾斜测试数据

``` sql

CREATE TABLE frequency(keys integer, frequency integer);
INSERT INTO frequency VALUES
(1, 70), (2,10), (3, 5), (4, 3),(5,1),(6,1),
    (7,1),(8,1),(9,1),(10,1),(11,1),(12,1),(13,1),(14,1),(15,1),(16,1);



CREATE TABLE CONSECUTIVE_NUMBER(NUM INT NOT NULL);
INSERT INTO CONSECUTIVE_NUMBER
SELECT ROW_NUMBER() OVER() AS NUM FROM SYSCAT.COLUMNS;
```

### ERROR:  failed to find conversion function from unknown to text

``` sql
SELECT 'string'::text AS rowname, data FROM tbl1

UNION ALL
SELECT 'string2', data FROM tbl2
```

### shema database table tablespace

表空间是一个存储区域，在一个表空间中可以存储多个数据库，尽管PostgreSQL不建议这么做，但我们这么做完全可行。
    一个数据库并不知直接存储表结构等对象的，而是在数据库中逻辑创建了至少一个模式，在模式中创建了表等对象，将不同的模式指派该不同的角色，可以实现权限分离，又可以通过授权，实现模式间对象的共享，并且，还有一个特点就是：public模式可以存储大家都需要访问的对象。
    这样，我们的网就形成了。可是，既然一个表在创建的时候可以指定表空间，那么，是否可以给一个表指定它所在的数据库表空间之外的表空间呢？
    答案是肯定的!这么做完全可以：那这不是违背了表属于模式，而模式属于数据库，数据库最终存在于指定表空间这个网的模型了吗？！
    是的，看上去这确实是不合常理的，但这么做又是有它的道理的，而且现实中，我们往往需要这么做：将表的数据存在一个较慢的磁盘上的表空间，而将表的索引存在于一个快速的磁盘上的表空间。
    但我们再查看表所属的模式还是没变的，它依然属于指定的模式。所以这并不违反常理。实际上，PostgreSQL并没有限制一张表必须属于某个特定的表空间，我们之所以会这么认为，是因为在关系递进时，偷换了一个概念：模式是逻辑存在的，它不受表空间的限制。

### PG性能优化点

+ 模糊查询：

如果没有修改PG库的locale，使用 like ’abc%’ 查询时，默认会扫描所有行，即使有索引也不走索引，引发性能问题。  
原因是要查询的数据类型和索引的数据类型不匹配。
解决方式：重建索引，为索引列指定 pattern_ops 模式，如 varchar_pattern_ops 。
	create index idx_t_name on t(name 	varchar_pattern_ops);

+ 避免长事务

读取大量数据需要使用事务来防止溢出，但是使用长事物可能造成性能问题。
长事物会导致vacuum进程无法回收已经删除数据的存储空间，新的数据写入只能使用新的数据块上，导致磁盘空间持续增长。
解决办法：
数据库上监控长事物
程序上排查长事物产生的原因并进行修复

+ 受长事务影响膨胀的表的处理

小表可使用 vacuum full 来处理。
大表使用 pg_reorg 来进行在线空间收缩，不锁表，不影响业务。

+ 分页排序优化

部分Oracle的复杂SQL使用到PG上会产生性能问题，多层子查询只在最外层排序分页的时候性能影响明显，尽量在子查询里进行关联，过滤，分页。
当表和子查询多时，表的join顺序没有Oracle优化得好，可能会走错索引，所以尽量避免子查询，使用join来做。
