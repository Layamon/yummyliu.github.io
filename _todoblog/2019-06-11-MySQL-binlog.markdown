---
layout: post
title: MySQL-Binlog由很浅到浅
date: 2019-06-11 18:28
header-img: "img/head.jpg"
categories: jekyll update
tags:
  - MySQL
typora-root-url: ../../layamon.github.io
---

* TOC
{:toc}
在MySQL中，除了存储引擎InnoDB的日志外，自身还有一个BinLog，其中记录了对数据进行了修改（以及可能对数据有修改）的事件，主要用在主从复制和PITR场景中。

> BinLog除了记录修改数据的操作，还会记录元信息：
>
> - 确保操作重放的正确的额外信息
> - 错误码
> - binlog自身的维护信息，比如rotate事件。
>
> 除了Redo、undo、binlog这些用于恢复的日志，MySQL中还有一些用于记录的日志：Errorlog、General Query Log、Slow Query Log、DDL Log。

在启动的时候，由binlog-format指定三种类型：statement、row、mixed。

- statement：记录主上执行的语句
- row：以主键为标识，记录相应行的变更。
- mixed：默认使用statement，当MySQL认为[某个语句不能完全复制](https://dev.mysql.com/doc/refman/5.7/en/binary-log-mixed.html)，升级为记录row。

下面从配置管理开始梳理binlog的相关内容。

# binlog配置与管理

+ MySQL的配置文件
  + slave_exec_mode
  + binlog_format=ROW
  + binlog_rows_query_log_events=ON
  +  binlog_row_image=FULL
  + slave_exec_mode=SEMI_STRICT (FB extension)

```bash
>  mysqld --datadir=/Users/liuyangming/dbdata/mysql/data --help --verbose | grep -A 1 'Default options'
Default options are read from the following files in the given order:
/etc/my.cnf /etc/mysql/my.cnf /usr/local/mysql/etc/my.cnf ~/.my.cnf
```

+ 开启binlog的配置

```ini
[mysqld]
performance_schema=ON
log-bin=bin.log
log-bin-index=bin-log.index
max_binlog_size=100M
binlog_format=row
server-id=1
```

+ 重启MySQL

```
mysqladmin -u root -p shutdown

/usr/local/mysql/bin/mysqld_safe --datadir=/Users/liuyangming/dbdata/mysql/data &
```

+ 查看binlog

```sql
mysql> show global variables like "log_bin";
+---------------+-------+
| Variable_name | Value |
+---------------+-------+
| log_bin       | ON    |
+---------------+-------+
1 row in set (0.01 sec)

mysql> show global variables like "binlog_format";
+---------------+-------+
| Variable_name | Value |
+---------------+-------+
| binlog_format | ROW   |
+---------------+-------+
1 row in set (0.01 sec)

mysql> show binary logs;
+------------+-----------+
| Log_name   | File_size |
+------------+-----------+
| bin.000001 |       177 |
| bin.000002 |      1372 |
| bin.000003 |       195 |
| bin.000004 |       154 |
+------------+-----------+
4 rows in set (0.01 sec)
```

在如下三种情况下，binlog会发生切换：

1. MySQL重启

2. 当前binlog段大小超过`max_binlog_size`（注意如果有大事务没结束，不会切换）。

3. flush logs

   ```sql
   mysql> show binary logs;
   +------------+-----------+
   | Log_name   | File_size |
   +------------+-----------+
   | bin.000001 |       177 |
   | bin.000002 |      1372 |
   | bin.000003 |       195 |
   | bin.000004 |       154 |
   +------------+-----------+
   4 rows in set (0.01 sec)
   
   mysql> flush logs;
   Query OK, 0 rows affected (0.09 sec)
   
   mysql> show binary logs;
   +------------+-----------+
   | Log_name   | File_size |
   +------------+-----------+
   | bin.000001 |       177 |
   | bin.000002 |      1372 |
   | bin.000003 |       195 |
   | bin.000004 |       195 |
   | bin.000005 |       154 |
   +------------+-----------+
   5 rows in set (0.00 sec)
   ```

binlog是一组binlog文件加一个索引文件，包含了MySQL中的数据更改。每个log文件由一个magic数(`#define BINLOG_MAGIC        "\xfe\x62\x69\x6e"`，即"\xfe bin")和一组event构成。

```sql
> show binlog events in 'binlog.000002';
+---------------+-----+----------------+-----------+-------------+-------------------------------------------------------------------+
| Log_name      | Pos | Event_type     | Server_id | End_log_pos | Info                                                              |
+---------------+-----+----------------+-----------+-------------+-------------------------------------------------------------------+
| binlog.000002 |   4 | Format_desc    |  97293978 |         123 | Server ver: 5.7.26-29-17-debug-log, Binlog ver: 4                 |
| binlog.000002 | 123 | Previous_gtids |  97293978 |         154 |                                                                   |
| binlog.000002 | 154 | Gtid           |  97293978 |         219 | SET @@SESSION.GTID_NEXT= '3acb9a39-74b8-11ea-8821-fa163e02960f:1' |
| binlog.000002 | 219 | Query          |  97293978 |         319 | create database sbtest                                            |
| binlog.000002 | 319 | Gtid           |  97293978 |         384 | SET @@SESSION.GTID_NEXT= '3acb9a39-74b8-11ea-8821-fa163e02960f:2' |
| binlog.000002 | 384 | Query          |  97293978 |         506 | use `sbtest`; create table abc ( a int primary key, b int)        |
| binlog.000002 | 506 | Rotate         |  97293978 |         550 | binlog.000003;pos=4                                               |
+---------------+-----+----------------+-----------+-------------+-------------------------------------------------------------------+
7 rows in set (0.00 sec)
```

每个log的第一个event都是一个`Format_description_log_event`；描述了当前的log文件是什么格式。后续的event就按照这个格式进行解析；最后一个event是log-rotation事件，描述了下一个binlog文件的名称，如下：

```c
> show binlog events in 'binlog.000003';
+---------------+-----+----------------+-----------+-------------+---------------------------------------------------+
| Log_name      | Pos | Event_type     | Server_id | End_log_pos | Info                                              |
+---------------+-----+----------------+-----------+-------------+---------------------------------------------------+
| binlog.000003 |   4 | Format_desc    |  97293978 |         123 | Server ver: 5.7.26-29-17-debug-log, Binlog ver: 4 |
| binlog.000003 | 123 | Previous_gtids |  97293978 |         194 | 3acb9a39-74b8-11ea-8821-fa163e02960f:1-2          |
+---------------+-----+----------------+-----------+-------------+---------------------------------------------------+
2 rows in set (0.00 sec)
```

binlog的索引文件就是一个文本文件，记录了当前的binlog的文件，如下：

```bash
> cat bin-log.index
./bin.000001
./bin.000002
./bin.000003
./bin.000004
./bin.000005
```

binlog主要用在MySQL的主从集群中，在master端有Binlog dumthread负责发送binlog；在slave段有两个线程：IO/SQL负责这一过程。

IO thread：从master端读取binlog，然后写入到本地的relaylog中。

SQL thread：读取relay log，按照event重做数据；同时也写slave自己的binlog。

通过`show slave status`可以查看复制的进度。当SQL线程执行完某个relaylog上的所有event，那么就将该文件删除。在如下三个情况下，MySQL slave会创建一个新的relaylog：

+ IO线程启动
+ FLUSH LOGS
+ 当前relaylog大于配置项([`max_relay_log_size`](https://dev.mysql.com/doc/refman/5.7/en/replication-options-slave.html#sysvar_max_relay_log_size))。

# BinLog相关代码逻辑

binlog中按照事务的先后顺序组织，每个事务分为若干个event。binlog按照event写入相关的数据，slave按照event调用对应的函数回放数据。在代码中，主要有以下几个模块：

+ client/mysqlbinlog.cc：解析binlog的工具。

+ sql/log.cc：该模块提供了宏观上操作的工具函数，比如创建/删除/写入binlog文件等。

+ [sql/log_event.cc](https://dev.mysql.com/doc/internals/en/event-classes-and-types.html)：底层操作log的函数，其中有各种event与相应的操作类的对应关系。

+ sql/rpl_contants.h：INCIDENT_EVENT事件的代码，用来通知slave“master上发生了可能导致数据不一致的行为”。

+ sql/slave.cc：slave端的IO和SQL线程处理binlog的代码

+ sql/rpl_injector.cc：injector允许在binlog中进行额外的插入，用在组复制场景。

+ sql/rpl_tblmap.cc：数字到具体表的映射，用在row模式的log中，用来确定表。

+ sql/rpl_utility.cc：辅助类用在Table_map_event的处理；在row模式下，每个row操作之前都有个Table_map_event。如下：

  ```sql
  > show binlog events in 'binlog.000003';
  +---------------+-----+----------------+-----------+-------------+-------------------------------------------------------------------+
  | Log_name      | Pos | Event_type     | Server_id | End_log_pos | Info                                                              |
  +---------------+-----+----------------+-----------+-------------+-------------------------------------------------------------------+
  | binlog.000003 |   4 | Format_desc    |  97293978 |         123 | Server ver: 5.7.26-29-17-debug-log, Binlog ver: 4                 |
  | binlog.000003 | 123 | Previous_gtids |  97293978 |         194 | 3acb9a39-74b8-11ea-8821-fa163e02960f:1-2                          |
  | binlog.000003 | 194 | Gtid           |  97293978 |         259 | SET @@SESSION.GTID_NEXT= '3acb9a39-74b8-11ea-8821-fa163e02960f:3' |
  | binlog.000003 | 259 | Query          |  97293978 |         333 | BEGIN                                                             |
  | binlog.000003 | 333 | Table_map      |  97293978 |         382 | table_id: 108 (sbtest.abc)                                        |
  | binlog.000003 | 382 | Write_rows     |  97293978 |         426 | table_id: 108 flags: STMT_END_F                                   |
  | binlog.000003 | 426 | Xid            |  97293978 |         457 | COMMIT /* xid=29 */                                               |
  +---------------+-----+----------------+-----------+-------------+-------------------------------------------------------------------+
  7 rows in set (0.00 sec)
  ```

+ sql/sql_binlog.cc：执行binlog中的语句；为了确认[BINGLOG的模式](https://dev.mysql.com/doc/internals/en/binary-log-versions.html)，第一个event必须是Format_description_log_event。
+ sql/sql_base.cc：其他模块公用的基础函数。

## Event的细节

可以从文档中得知[各个event的含义](https://dev.mysql.com/doc/internals/en/event-meanings.html)。在代码的枚举`Log_event_type`也可了解一些信息。每个event都代表一个数据库的操作，每个event由一个header加具体数据构成；header的结构如下，包括何时产生，由哪个server产生等信息，见`Log_event_header`

```c
    +---------+---------+---------+------------+-----------+-------+
    |timestamp|type code|server_id|event_length|end_log_pos|flags  |
    |4 bytes  |1 byte   |4 bytes  |4 bytes     |4 bytes    |2 bytes|
    +---------+---------+---------+------------+-----------+-------+
```

event的内容按照如下约定写入：

+ 数字按照little-endian存储。

+ 代表位置和长度的值，按照byte表示。

+ 有些数字是用Packed Integer表示

  > Packed Integer
  >
  > 整型数字可以占用8字节，也可以占用1、2、4字节；有第一个字节的值来标明：
  >
  > | **First byte** | **Format**                                                   |
  > | -------------- | ------------------------------------------------------------ |
  > | 0-250          | The first byte is the number (in the range 0-250). No additional bytes are used. |
  > | 252            | Two more bytes are used. The number is in the range 251-0xffff. |
  > | 253            | 还有三个字节，值从0xffff-0xffffff.                           |
  > | 254            | 还有8个字节 0xffffff-0xffffffffffffffff.                     |
  >
  > 第一个byte的251没有用到，用这个值表示SQL中的NULL。

+ 字符串有很多写入格式：

  + 写入到一个固定大小的空间，后面用0x00补齐
  + 变长串前加一个length字段
  + 变长串可能以null结尾，也可能不是；（相应的描述符中有标明）
  + null结尾的变长串的前置length不包含null。
  + 如果变长串是event内容的最后一个，如果没有length前缀；那么就可以通过event的长度得出。

> 事务binlog event写入流程, ref https://zhuanlan.zhihu.com/p/108650249
>
> binlog cache和binlog临时文件都是在事务运行过程中写入，一旦事务提交，binlog cache和binlog临时文件都会释放掉（如果有超大事务，这里可能会耗尽存储空间）。而且如果事务中包含多个DML语句，他们共享binlog cache和binlog 临时文件。整个binlog写入流程：
>
> 1. 事务开启
> 2. 执行dml语句，在dml语句第一次执行的时候会分配内存空间binlog cache
> 3. 执行dml语句期间生成的event不断写入到binlog cache
> 4. 如果binlog cache的空间已经满了，则将binlog cache的数据写入到binlog临时文件，同时清空binlog cache。如果binlog临时文件的大小大于了max_binlog_cache_size的设置则抛错ERROR 1197
> 5. 事务提交，整个binlog cache和binlog临时文件数据全部写入到binlog file中，同时释放binlog cache和binlog临时文件。但是注意此时binlog cache的内存空间会被保留以供THD上的下一个事务使用，但是binlog临时文件被截断为0，保留文件描述符。其实也就是IO_CACHE(参考`typedef struct st_io_cache`)保留，并且保留IO_CACHE中的分配的内存空间和物理文件描述符
> 6. 客户端断开连接，这个过程会释放IO_CACHE同时释放其持有的binlog cache内存空间以及持有的binlog 临时文件。 

# Group Commit

在PostgreSQL中有一个参数[commit_delay](https://www.postgresql.org/docs/current/runtime-config-wal.html#GUC-COMMIT-DELAY)代表PostgreSQL中的组提交，即，相比于每个事务都刷盘，打开这个参数，PostgreSQL会等待一组事务然后一起提交；当然，前提是PostgreSQL打开了`fsync`参数；另外考虑到并发低的时候，没有必要等待；这里当db的活动事务大于`commit_siblings`时，才会delay commit(group commit)。同样地，在MySQL中为了解决fsync带来的tps吞吐瓶颈问题，也有Group Commit特性，和PostgreSQL类似地，有两个参数（`binlog_group_commit_sync_delay`，`binlog_group_commit_sync_no_delay_count`）。

但是MySQL中由于存储的redolog和上层的binlog需要保证XA一致性，因此实现起来相对复杂。

> 如果不开binlog，InnoDB中的log_write_up_to可以将同一个buffer且不属于自己的logrecord一起刷盘，可认为是InnoDB的组提交，这和PG类似，但这里主要讨论的事binlog的组提交

当上层同时启用binlog时，为了保证上下日志的一致，需要采用XA 2pc进行两阶段提交，这里binlog就作为2pc中的协调者（从code可以看出这个用意：`class MYSQL_BIN_LOG: public TC_LOG`）。

1. Prepare InnoDB

   1. 在InnoDB的logbuffer中，写入prepare记录；
   2. **fsync**：日志文件刷盘；
   3. **获取`prepare_commit_mutex`。（5.6）**

2. Prepare binlog

   引擎层表示可以prepare了，那么binlog就可以prepared，没什么特别需要做的

3. Commit binlog

   > **XA recovery**
   >
   > 如果这里binlog刷盘了，那么恢复的时候，该事务认为是提交的；如果在这之前crash了，该事务会被回滚。

   1. 将事务commit写入binlog；
   2. **fsync**：基于`sync_binlog`配置的行为，进行binlog刷盘。

4. Commit InnoDB

   1. 在logbuffer中，写入commit记录；
   2. **释放`prepare_commit_mutex`;（5.6）**
   3. **fsync**：日志文件刷盘
   4. 释放InnoDB的锁

在多个事务并发的进行2PC提交的时候，redolog的写入顺序和binlog的写入顺序可能不一致；在MySQL5.6中，基于`prepare_commit_mutex`，确保三次刷盘操作的顺序，从而保证binlog与InnoDB的redolog的顺序是一致的。

然而，由于存在这样一个互斥同步，导致第2步的binlog**不能进行组提交**；并且理想情况下，一个事务，只有一个fsync操作即可，然而这里进行三次，**性能上也不太乐观**；没有对此进行优化的之前，binlog除了作为存储模块还是事务调度模块，**模块不清晰**，不易于维护。

上述基于`prepare_commit_mutex`的commit机制的临界区过大，使得整个并发度降低，从而整体的吞吐降低。https://dev.mysql.com/worklog/task/?id=5223

binlog的提交先通过binlog cache和临时文件(IO_cache)暂存，最后提交的时候，整体写入到binlog中（`og_event.write()`）。因此，引入了GroupCommit，将binlog的提交划分为三个阶段（StageID），每个阶段都有一个执行队列：

1. flush：从THD cache到binlog，执行binlog write；engine此时会将事务日志刷盘，此时事务状态为prepare。调用栈

   ```c
   ha_flush_log
   -innobase_flush_logs
   --log_buffer_flush_to_disk
   ```

2. sync：从binlog cache到disk file，执行binlog fsync。此时MySQL的事务可以认为是提交了，按照recovery逻辑，engine中prepare会前滚。

3. commit：engine 按序提交。基于recovery逻辑，就不会产生数据丢失；这样，InnoDB的commit可以不用刷盘也可以。事实上确实是这样的，在引擎层提交时，调用`trx_commit_in_memory` 在内存中就将锁释放了，然后才基于参数**`innodb_flush_log_at_trx_commit`**判断是否进行刷redo（*trx_flush_log_if_needed*）。

> InnoDB的事务状态有个特殊的：TRX_STATE_COMMITTED_IN_MEMORY. 关于InnoDB如何在违反WAL的前提下，还能保证数据一致?

binlog实现了组提交，同样也要满足xa-2pc的要求，其中一个同步点就是：保证在binlog刷盘前，将engine的prepare相关的redolog刷盘；可以看代码处理flush逻辑的时候（`process_flush_stage_queue`）,就调用了`ha_flush_logs`将prepare的redo日志刷盘。

binlog的组提交的入口函数是`MYSQL_BIN_LOG::ordered_commit`。进入某阶段的第一个thread作为leader，后续进来的都是follower；leader将该阶段的threads注册到下一阶段中，然后统一负责处理该阶段的任务（如果下一阶段不为空，那么该leader成为下一阶段的follower，因此最慢的sync阶段会累积很多任务），此时follower就是等待处理完成的通知；

**Ref:**

[IO_CACHE](http://mysql.taobao.org/monthly/2018/09/03/)

[binlog recovery](http://mysql.taobao.org/monthly/2018/12/04/)

[MTS](http://mysql.taobao.org/monthly/2015/08/09/)

[innodb violate WAL](https://blog.csdn.net/yanzongshuai/article/details/53958219?depth_1-utm_source=distribute.pc_relevant.none-task-blog-OPENSEARCH-2&utm_source=distribute.pc_relevant.none-task-blog-OPENSEARCH-2)