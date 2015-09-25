---
layout: post
title: 
date: 2020-06-18 10:41
categories:
  -
typora-root-url: ../../layamon.github.io
---
> * TOC
{:toc}

ring buffer

1. Bulk-reading

2. When a relation whose size exceeds one-quarter of the buffer pool size (shared_buffers/4) is scanned. In this case, the ring buffer size is *256 KB*.

3. Bulk-writing

4. When the SQL commands listed below are executed. In this case, the ring buffer size is *16 MB*.

5. - *[COPY FROM](http://www.postgresql.org/docs/current/static/sql-copy.html)* command.
   - *[CREATE TABLE AS](http://www.postgresql.org/docs/current/static/sql-createtableas.html)* command.
   - [*CREATE MATERIALIZED VIEW*](http://www.postgresql.org/docs/current/static/sql-creatematerializedview.html) or [*REFRESH MATERIALIZED VIEW*](http://www.postgresql.org/docs/current/static/sql-refreshmaterializedview.html) command.
   - [*ALTER TABLE*](http://www.postgresql.org/docs/current/static/sql-altertable.html) command.

6. Vacuum-processing

7. When an autovacuum performs a vacuum processing. In this case, the ring buffer size is

8.  

9. 256 KB

10. .

The allocated ring buffer is released immediately after use.

LRU-K 

一般LRU新load的数据，直接放在头部，而现在则是放在lru list的中部（**innodb_old_blocks_pct**，default 3/8处），只有当真正访问这个数据页才会放在头部(buf_LRU_make_block_young)，否则如果一直没有访问，那么就基于LRU的规则从尾部被淘汰了，（淘汰的时间有3/8的缓冲时间）

https://juejin.im/post/5e240847f265da3e1824c579

https://juejin.im/post/5e2023e0f265da3df12042b3

![MySQL InnoDB Midpoint Insertion Strategy](/image/pg-inno-lru/lru-k.png)

https://duggup.com/p/what-makes-mysql-lru-cache-scan-resistant

https://dev.mysql.com/doc/refman/8.0/en/innodb-performance-midpoint_insertion.html

2Q

LIRS

https://en.wikipedia.org/wiki/LIRS_caching_algorithm