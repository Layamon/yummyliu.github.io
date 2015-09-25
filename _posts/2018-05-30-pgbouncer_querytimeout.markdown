---
layout: post
title: PostgreSQL+Pgbouncer架构下的查询超时
subtitle: 超时是架构设计中必须要考虑的问题，当使用多个系统时，可能要考虑不同的超时设置
date: 2018-05-30 11:43
header-img: "img/head.jpg"
categories: 
 - Pgbouncer
---

# 问题描述

pgbouncer设置了`query_timeout=60`；超时了日志报错**（Pooler Error: query_timeout）**之后，
Pgbouncer关闭了和pgserver的连接，然而此时pg并没有立马结束相应的*active query*。这时发现Pgbouncer的`show server`和 psql的pg_stat_activity信息不一致；

由于pgserver并没有cancel相应连接上的任务，任务在pgserver这占用一个connection；但是此时pgbouncer由于已经关闭了pgserver的连接，而pg执行完改任务返回结果给pgb时，报错**（"could not send data to client: Broken pipe）**。

Pgbouncer认为自己关闭了连接，所以可以继续给client分配server的connection；于是pgb又向pgserver发起连接，而此时pgserver上一个连接还没有执行完，所以此时pgb没有对pgserver的连接数起到保护作用；pgserver的connection一直上涨，直到pgb的日志中报错：
Pooler Error: pgbouncer cannot connect to server
直到；pgb报错 login failed: FATAL: remaining connection slots are reserved for non-replication superuser connections

直到pg中大量报错“
The postmaster has commanded this server process to roll back the current transaction and exit, because another server process exited abnormally and possibly corrupted shared memory” 
未发现系统日志关于OOM的记录，但是查阅PG文档Linux Memory OverCommit相关，情况与此相符：
在PG文档中，“If PostgreSQL itself is the cause of the system running out of memory, you can avoid the problem by changing your configuration. In some cases, it may help to lower memory-related configuration parameters, particularly shared_buffers and work_mem. In other cases, the problem may be caused by allowing too many connections to the database server itself. In many cases, it may be better to reduce max_connections and instead make use of external connection-pooling software.” 在某些情况下，the problem may be caused by allowing too many connections to the database server itself. 

暂时解决办法：
如果想控制查询执行时间过长就终止，不要在pgbouncer的配置文件里配置query_timeout，在postgresql.conf中配置statement_timeout；
暂时将;

```bash
chat的offline的statement_timeout打开，设为120000；
pgbouncer的query_timeout关闭，这样pgbouncer不会timeoutquery
```

参考PostgreSQL文档：

[LINUX-MEMORY-OVERCOMMIT](https://www.postgresql.org/docs/current/static/kernel-resources.html#LINUX-MEMORY-OVERCOMMIT)

