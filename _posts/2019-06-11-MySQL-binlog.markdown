---
layout: post
title: MySQL5.7——不得不了解的Binlog
date: 2019-06-11 18:28
header-img: "img/head.jpg"
categories: 
  - MySQL
typora-root-url: ../../layamon.github.io
---

* TOC
{:toc}
在MySQL中，除了存储引擎InnoDB的日志外，自身还有一个BinLog，这其实是MySQL更关键的日志；了解MySQL基本必不可少的要了解Binlog。其中记录了对数据进行了修改（以及可能对数据有修改）的事件，主要用在主从复制和PITR场景中。

> BinLog除了记录修改数据的操作，还会记录元信息：
>
> - 确保操作重放正确性的额外信息
> - Error Code
> - binlog自身的维护信息，比如rotate事件。
>
> 除了Redo、undo、binlog这些用于事务日志；MySQL中还有一些操作日志：Errorlog、General Query Log、Slow Query Log、DDL Log，暂不讨论。

binlog的内容有三种类型，在启动的时候配置binlog-format。

- statement：记录主上执行的语句
- row：以主键为标识，记录相应行的变更。
- mixed：默认使用statement，当MySQL认为[某个语句不能完全复制](https://dev.mysql.com/doc/refman/5.7/en/binary-log-mixed.html)，升级为记录row。

下面从配置管理开始梳理binlog的相关内容。

# binlog配置简介

+ MySQL的配置文件

```bash
>  bin/mysqld --help --verbose | grep -A 1 'Default options'
Default options are read from the following files in the given order:
/etc/my.cnf /etc/mysql/my.cnf /home/liuyangming/output/etc/my.cnf ~/.my.cnf
```

binlog相关的配置

```ini
[mysqld]
server-id=1

log-bin=bin.log
log-bin-index=bin-log.index
max_binlog_size=100M

binlog_format=row
binlog_row_image=FULL
binlog_rows_query_log_events=ON # 写入一些调试信息，mysqlbinlog -vv 可以看到

log_slave_updates=ON # slave需要记自己的binlog，开了这个可以级联复制
slave_preserve_commit_order=OFF # 并行复制时，从库可以乱序执行
```

查看binlog

```sql
mysql> show global variables like "log_bin";
+---------------+-------+
| Variable_name | Value |
+---------------+-------+
| log_bin       | ON    |
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

上面演示在`flush logs`后，binlog会发生切换，另外在 MySQL重启或当前binlog段大小超过`max_binlog_size`（注意如果有大事务没结束，不会切换）也会发生切换。

binlog的每个log文件由一个magic数(`#define BINLOG_MAGIC  "\xfe\x62\x69\x6e"`，即"\xfe bin")和一组event构成。

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

每个log的第一个event都是一个`Format_description_log_event`；描述了当前的log文件是什么格式。后续的event就按照这个格式进行解析；最后一个event是log-rotation事件，描述了下一个binlog文件的名称，如上：

binlog的索引文件就是一个文本文件，记录了当前的binlog的文件，如下：

```bash
> cat bin-log.index
./bin.000001
./bin.000002
./bin.000003
./bin.000004
./bin.000005
```

binlog对应的在slave中叫relaylog。在如下三个情况下，MySQL slave会创建一个新的relaylog：

+ IO线程启动
+ FLUSH LOGS
+ 当前relaylog大于配置项([`max_relay_log_size`](https://dev.mysql.com/doc/refman/5.7/en/replication-options-slave.html#sysvar_max_relay_log_size))。

当SQL线程执行完某个relaylog上的所有event，那么就将该文件删除。以上是Binlog整体的配置使用情况。

# BinLog代码简析

在代码中，binlog相关的主要有以下几个模块(8.0.19)：

+ mysqlbinlog.cc：解析binlog的工具。
+ rpl_slave.cc：slave端的IO和SQL线程处理binlog的代码
+ rpl_injector.cc：injector允许在binlog中进行额外的插入，用在组复制场景。
+ rpl_tblmap.cc：数字到具体表的映射，用在row模式的log中，用来确定表。
+ sql/rpl_utility.cc：重放用的一些工具类。

+ sql/sql_binlog.cc：mysqlbinlog特定的内部命令`BINLOG $str`的处理逻辑。
+ libbinlogevents：提供了对各个event的读取解压方法。
+ binlog_event.cpp/log_event.cc：定义了各种event，其中有各种event与相应的操作类的对应关系。
+ binlog.cc：binlog的核心逻辑。
+ sql/binlog_reader.h：读取binlog文件的封装
  + sql/binlog_istream.h
+ sql/binlog_ostream.cc：写binlog的封装
+ 等等

那么这里主要了解的就是log_event.cc和binlog.cc模块。

## LogEvent模块

可以从文档中得知[各个event的含义](https://dev.mysql.com/doc/internals/en/event-meanings.html)。在代码的枚举`Log_event_type`也可了解一些信息。关于Event的逻辑主要在代码里分为2个部分：libbinlogevents和logevent。前者关注具体的存储方式，后者关注event之上的操作。

比如Rows_log_event，该event在RBR模式下记录行级别的操作，其会继承两路接口；一路是定义存储的格式，一路是回放时候的具体操作，而该类其实也是作为父类，更具体的操作定义在Write_rows_log_event等子类中，如下图：

![image-20200430131103606](/image/mysql-binlog/row_log_event.png)



如上图，我们可以看到，event首先按照binlog的模式，分别statement和row两大类。每个event都代表一个数据库的操作，每个event由一个header加具体数据构成；header的结构如下，包括何时产生，由哪个server产生等信息，见`Log_event_header`

```c
    +---------+---------+---------+------------+-----------+-------+
    |timestamp|type code|server_id|event_length|end_log_pos|flags  |
    |4 bytes  |1 byte   |4 bytes  |4 bytes     |4 bytes    |2 bytes|
    +---------+---------+---------+------------+-----------+-------+
```

event的内容按照如下约定写入：

+ 数字按照little-endian存储。

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

+ 代表位置和长度的值，按照byte表示。

+ 字符串有很多写入格式：

  + 写入到一个固定大小的空间，后面用0x00补齐
  + 变长串前加一个length字段
  + 变长串可能以null结尾，也可能不是；（相应的描述符中有标明）
  + null结尾的变长串的前置length不包含null。
  + 如果变长串是event内容的最后一个，如果没有length前缀；那么就可以通过event的长度得出。

## Binlog模块

Binlog中以事务为单位存储了event，在执行事务的过程中，event数据暂时存放在IO_CACHE中，大小为**binlog_cache_size**；当超过**binlog_cache_size**后，转存在临时文件中（临时文件通过mkstemp接口创建一个600权限的临时文件）；

```cpp
init_io_cache_ext(file = -1)
	real_open_cached_file
  	create_temp_file
			mkstemp
```

> 可以通过**Binlog_cache_disk_use**查看目前有多少事务使用了磁盘临时文件，如果经常这样，应该考虑提高**binlog_cache_size**避免在commit之前进行IO。
>
> 而临时文件的大小也是有限制的，即max_binlog_cache_size，但是默认值特别大。

最后，在binlog的**Group Commit**的第一阶段FLUSH，会将IO_CACHE以及临时文件中的数据转存到binlog file中；之后truncate 临时文件，但保留IO_CACHE，如下调用栈：

```cpp
MYSQL_BIN_LOG::commit
	MYSQL_BIN_LOG::ordered_commit
		MYSQL_BIN_LOG::flush_cache_to_file
			binlog_cache_data::flush
				MYSQL_BIN_LOG::write_cache
  				MYSQL_BIN_LOG::do_write_cache
  					cache->copy_to(writer) // Binlog_cache_storage cache -> Binlog_event_writer writer
```

当SQL层启用binlog时，为了保证上下日志的一致，需要采用XA 2pc进行两阶段提交，这里binlog就作为2pc中的协调者（从code可以看出这个用意：`class MYSQL_BIN_LOG: public TC_LOG`，TC即Transaction Coordinator），那么，在多个事务并发的进行2PC提交的时候，redolog的写入顺序和binlog的写入顺序可能不一致；为了保证binlog和引擎日志的提交顺序一致，通过在MySQL中的2PC步骤中加锁：`prepare_commit_mutex`确保，如下（未引入Group Commit之前的5.6）：

> 见[这里](https://dev.mysql.com/worklog/task/?id=5223)
>
> <img src="/image/mysql-binlog/binlog56.png" alt="image-20200501072321265" style="zoom:50%;" />

然而，由于存在这样一个互斥同步，导致第2步的binlog**不能进行组提交**；并且理想情况下，一个事务，只有一个fsync操作即可，然而这里进行三次，**性能上也不太乐观**；没有对此进行优化的之前，binlog除了作为存储模块还是事务调度模块，**模块不清晰**，不易于维护。

因此，为提高整体的速度，MySQL改造了这里的逻辑进行重构，引入了Binlog GroupCommit。

### BinLog Group Commit

在PostgreSQL中有一个参数[commit_delay](https://www.postgresql.org/docs/current/runtime-config-wal.html#GUC-COMMIT-DELAY)代表PostgreSQL中的组提交，即，相比于每个事务都刷盘，打开这个参数，PostgreSQL会等待一组事务然后一起提交；当然，前提是PostgreSQL打开了`fsync`参数；另外考虑到并发低的时候，没有必要等待；这里当db的活动事务大于`commit_siblings`时，才会delay commit(group commit)。和PostgreSQL类似地，MySQL有两个参数（binlog_group_commit_sync_delay，binlog_group_commit_sync_no_delay_count`）。

但是MySQL中由于存储的redolog和上层的binlog需要保证XA一致性，因此实现起来相对复杂。

> 如果不开binlog，InnoDB中的log_write_up_to可以将同一个buffer且不属于自己的logrecord一起刷盘，可认为是InnoDB的组提交，这和PG类似，但这里主要讨论的事binlog的组提交

binlog的提交先通过binlog cache和临时文件(IO_cache)暂存，最后提交的时候，整体写入到binlog中；目前的binlog group commit划分为三个阶段（也可认为是4个阶段，第一个阶段commit order是可选的）,见函数入口`MYSQL_BIN_LOG::ordered_commit`。

```cpp
  enum StageID {
    FLUSH_STAGE,
    SYNC_STAGE,
    COMMIT_STAGE,
    STAGE_COUNTER
  };
```

在MySQL的事务执行过程中，会不断的产生事务日志；binlog event就暂存在**IO_CACHE**中，redo log就暂存在**logbuffer**中；

最后，在事务2pc组提交的时候，要保证上下两层日志的顺序一致（保留prepare_commit_mutex的语义），即，**保证在binlog刷盘前，将engine的prepare相关的redolog刷盘**；可以看代码处理flush逻辑的时候（`process_flush_stage_queue`）,就调用了`ha_flush_logs`将prepare的redo日志刷盘（**同步点**）。

为提高binlog的吞吐，MySQL支持了binlog的组提交；其中每个阶段都有一个执行队列，进入某阶段的第一个thread作为leader，后续进来的都是follower；leader将该阶段的threads注册到下一阶段中，然后统一负责处理该阶段的任务（如果下一阶段不为空，那么该leader成为下一阶段的follower，最慢的sync阶段可能会累积很多任务），此时follower就是等待处理完成的通知。

以显示事务为例，比如这个简单例子，笔者在ha_prepare_low和order_commit处打上断点（读者可以自己debug跟踪，了解一下）：

```cpp
> begin;
Query OK, 0 rows affected (0.00 sec)

root@127.0.0.1 [mysql]
> insert into t1 values ( 1,9); ------------ ha_prepare_low
Query OK, 1 row affected (2.50 sec)

root@127.0.0.1 [mysql]
> insert into t1 values ( 5,9); ------------ ha_prepare_low
Query OK, 1 row affected (1.71 sec)

root@127.0.0.1 [mysql]
> insert into t1 values ( 0,9); ------------ ha_prepare_low
Query OK, 1 row affected (1.70 sec)

root@127.0.0.1 [mysql]
> commit;	------------ ordered_commit
Query OK, 0 rows affected (13.10 sec)
```

那么binlog事务处理的整体流程如下：

1. 之前的DML语句都通过`ha_prepare_low(HA_IGNORE_DURABILITY)`执行了，数据由`binlog_cache_data::write_event`（其实就是各个event分别调用自己的write接口）暂存在**IO_CACHE**中。

2. Group Commit

   1. *SLAVE COMMIT ORDER*：CommitOrderManager有自己的一个队列。

      1. 若slave-preserve-commit-order打开，则要求applier线程有序进队列，保证提交顺序。

   2. **FLUSH**：binlog event从THD cache转移到binlog，执行binlog write；**InnoDB此时会将事务日志刷盘**，此时事务状态为prepare。调用栈

      1. `ha_flush_logs`：引擎层sync；

         ```cpp
         ha_flush_log
         -innobase_flush_logs
         --log_buffer_flush_to_disk
         ```

         > 在5.6中，innodb在Prepare阶段就会将redolog刷盘；5.7中，将redolog的刷盘退后到group commit的flush阶段，这样redolog也可以实现类似组提交的优化。

      2. 对队列中每个事务生成GTID。

      3. **取LOCK_log锁**，并将IO_CACHE(session cache)中的内容复制到binlog中。

      4. prepared XIDs的计数器递增

   3. **SYNC**：由leader**取LOCK_sync锁**，取决于sync_binlog参数，将组内事务日志同步到磁盘中，执行binlog fsync。此时MySQL的事务可以认为是提交了。

   4. **COMMIT**：由leader**取LOCK_commit锁**，并将所有事务在engine 按序提交（如果binlog_order_commits=0，那么该步骤并行执行，因此binlog的提交顺序和引擎层可能不一样；默认是1）；此处大概的执行逻辑：
   
      1. 调用after_sync回调
      2. 更新dependency_tracker中的max_committed；（Logical Clock用）
      3. ha_commit_low
      4. 调用after_commit回调
      5. 更新gtids
      6. prepared XIDs递减

以上的步骤转换过程都是通过change_stage进行加锁放锁：

![image-20200603095424073](/image/mysql-binlog/image-20200603095424073.png)

1. 先申请进入下一个阶段，并返回自己是否是leader（`bool leader= m_queue[stage].append(thd);`）；
2. 释放上一阶段的锁
3. 申请下一阶段的锁；

**这样保证了事务提交的顺序（想想函数入口的名字：order_commit）。**

> Q&A
>
> InnoDB的事务状态有个特殊的：**TRX_STATE_COMMITTED_IN_MEMORY**. InnoDB的commit可以不用刷盘。
>
> 在引擎层提交时，调用`trx_commit_in_memory` 在内存中就将锁释放了，然后才基于参数**`innodb_flush_log_at_trx_commit`**判断是否进行刷redo（*trx_flush_log_if_needed*）。
>
> 可以看出InnoDB的redolog，似乎违反了WAL，那么如何保证数据一致？InnoDB可认为是与MySQL强绑定，事务的提交信息已经写入binlog了，recover的时候sql层先读取最后一个binlog文件（之前的保证已经提交）中的xid，构造一个`XID *const xid_list`，传入引擎层的ha_recover对应的函数——innobase_xa_recover（rocksdb_recover），innoDB中的recovery逻辑，会根据该list，判断是否提交事务保证不会产生数据丢失。

### BinLog Cache

上节提到在ordered_commit之前，Log_event调用自己的write接口将自己的数据写出。

```cpp
  virtual bool write(Basic_ostream *ostream) {
    return (write_header(ostream, get_data_size()) ||
            write_data_header(ostream) || write_data_body(ostream) ||
            write_footer(ostream));
  }
```

最终是调用`IO_CACHE_binlog_cache_storage::write`将数据**暂时**写出到IO_CACHE；

IO_CACHE由一个固定大小的内存空间（`binlog_cache_size`）和一个临时文件组成；当内存写满会写到临时文件中，参见`_my_b_write`；可通过监控参数`Binlog_cache_disk_use`查看当前是否有事务使用了临时文件，如果有很多事务使用了临时文件，那么应该考虑增大`binlog_cache_size`。

> 临时文件的大小也是有上限的，但是默认值特别大，见`max_binlog_cache_size`

```cpp
mysql> SHOW GLOBAL STATUS like 'Binlog_cache%';
+-----------------------+------------+
| Variable_name         | Value      |
+-----------------------+------------+
| Binlog_cache_disk_use | 156        |
| Binlog_cache_use      | 1354001342 |
+-----------------------+------------+
2 rows in set (0.01 sec)
```

那么现在，我们知道MySQL的binlog同样有类似于logbuffer的机构——IO_CACHE，只不过IO_CACHE不仅仅用在binlog这一个场景中。

只要事务没有提交，我们并不知道事务数据有多大；最后，在group commit时，才将IO_CACHE中的数据转移到binlog中。这里会将事务数据memcpy两次，在代码中有个值得关注的TODO，不知道是否可行呢？

```cpp
/*
  TODO use mmap instead of IO_CACHE for binlog
  (mmap+fsync is two times faster than write+fsync)
*/

class MYSQL_BIN_LOG: public TC_LOG
```

> 暂时不考虑超大事务，假设binlog的文件大小固定大小，可以先简单做个小实验：
>
> + 实验一：将1G的binlog文件mmap到内存中，模拟随机写入不同长度的事务数据，对该段数据msync。
> + 试验二：同样是1G大小的binlog，但是我们在fsync之前，先将数据写入到额外的临时buffer中（固定大小，模拟io_cache），当事务commit后，再copy到binlog中。binlog文件采用buffer io打开，因此，还需要fsync。这和group commit逻辑相同， 先flush到page cache中，再sync到文件中。

