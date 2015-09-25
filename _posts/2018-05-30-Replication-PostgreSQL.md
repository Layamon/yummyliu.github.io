---
ayout: post
title: PostgreSQL的逻辑复制原理与坑
subtitle: 
date: 2018-05-30 18:06
header-img: "img/head.jpg"
categories: 
    - PostgreSQL
---

# Replication Slot

Replication Slot是支持逻辑复制的一个重要特性。在介绍逻辑复制之前，我们需要了解一下ReplicationSLot的机制。

它是PG9.4中，加入的新功能。维护着当前的复制状态（比如，复制完成的位置），即使slave下线或者断连了，还是保持着，以备其再次使用；其通过如下的patch引入到系统中。

> ```text
> author    Robert Haas <rhaas@postgresql.org>  
> Sat, 1 Feb 2014 03:45:17 +0000 (22:45 -0500)
> committer    Robert Haas <rhaas@postgresql.org>  
> Sat, 1 Feb 2014 03:45:36 +0000 (22:45 -0500)
> Replication slots are a crash-safe data structure which can be created
> on either a master or a standby to prevent premature removal of
> write-ahead log segments needed by a standby, as well as (with
> hot_standby_feedback=on) pruning of tuples whose removal would cause
> replication conflicts.  Slots have some advantages over existing
> techniques, as explained in the documentation.
> ```

## 物理复制中的应用

当前流复制的工作方式中，master并不为落后的standby保留额外的wal；如果standby落后太多了，master仍然会删除wal。当其中有standby需要replay的wal，standby会出现如下ERROR：

```
ERROR:  requested WAL segment 00000001000000010000002D has already been removed
```

为了避免这个问题，你可以配置master的archive_command，并且在slave中提供一个restore_command来获取归档中的wal，或者重做一个slave。

另一个不太可靠的方案就是将`wal_keep_segments`设置的足够大，保证slave从不落后太多；但是，没有什么正确的方式来估算多高算高，而且，这个值设的越高，master可能面临磁盘空间的问题。因此，归档是可靠的方案，具体可以利用一些脚本，NFS，或者scp等技术，我们可以很好的解决这个问题。

## 逻辑复制中的应用

和物理复制不同的是，逻辑复制中简单的重做一个落后的备份不太可行。在一些备份节点上，可能包含着自己的数据。在双向备份的情况下，备份DB可能包含一些还没同步过去的数据，这不不能简单的取消这个备份节点，执行一个新的`pg_basebackup`。

```sql
pg_create_logical_replication_slot ( name, 'pgoutput' )
```

slot的引入可以解决的这个问题，即使slave断开连接，master就能持续的关注复制的状态。尽管这是为了逻辑复制添加的，但是在物理复制中也是有用的，因为master可以维护好所有slave需要的wal。这就不需要猜测`wal_keep_segment`。也不需要维护一个归档的系统来维护wal日志。只要pg_xlog的空间足够，那么master就能够保留好wal日志，知道slave上线来重做wal。

这个方式的缺点就是，当slave长期下线，可能会使wal无限增长。可是监控和调整pg_xlog的空间是一个繁忙PG的管理的必须的工作。

## 额外的影响

1. 默认地，物理复制不会使用slots。不做其他改变的话，我们需要在上流的复制节点使用wal归档。

   我们通过在`recovery.conf`中设置`primary_slotname`，在物理复制中replication slot。这个物理复制节点，已经在master中通过`pg_create_physical_replication_slot()`创建了。

2. 在物理复制中使用了slot，我们就不需要使用wal归档来做复制了（除非你想使用PITR来恢复）。你不需要为多个slave维护wal。也不需要维护archive的存储。

3. 但是，你需要关注pg_xlog的空间。系统自动保留wal，你得确保系统有足够的空间。

4. 如果slave长期断开，你必须在master上，手动删除slot。

5. 有了slot，你需要监控slave的状态，因为精确及时的信息都在`pg_replication_slot`中。因此，需要监控pg_xlog的空间和所有replication slot。

6. 任何`wal_keep_segments`降级为最小，来维护wal。

因此，在物理复制中，使用slot是一个权衡方案。你不需要管理archive，但是需要监控master系统的状态，避免master挂掉。

# 逻辑复制

## 简述

提供了类似于MySQL的binlog的Row级别的复制方式，但是在PostgreSQL采用发布/订阅的方式，可以指定只复制某些表，更加灵活。目前只支持基于REPLICA IDENTITY的INSERT/DELETE/UPDATE，并确保SQL语句的执行结果是相同的（区别于只是重新执行SQL，可能不同时间执行相同的SQL的结果也是不一样的）。

主要应用在如下场景中：

+ 将多个数据库合并到一个数据库，用来分析
+ 不同大版本PostgreSQL之间的数据复制
+ 将本机数据库的增量更新，发送给指定DB
+ 给不同用户组访问复制数据的权限
+ 多个数据库之间共享数据

需要注意一些使用逻辑复制的限制。

+ 表名与列名必须结构相同，列的数据类型也必须相同(除非类型隐式转换相同)。
+ 必须有主键或者唯一建约束
+ 双向复制不支持
+ 不复制DDL（schema）
+ 不复制Sequence
+ 不复制TRUNCATE
+ 不复制大对象
+ Subscription可以有更多的列，并且顺序可以不同，但是类型和列名必须相同；
+ 超级用户才有权限添加所有表
+ Can not stream over to the same host(subscription will get locked).

## 机制

wal sender通过`pgoutput.so`将wal解析并发送到远端。如下，当前系统中有三个sender只有repuser是逻辑复制，因此也只有它加载了pgoutput库。

```bash
[root@sh001m01 ~]# ps aux | grep send
postgres  5825  3.1  0.1 8893516 17536 ?       Ss   14:16   0:00 postgres: wal sender process repuser 10.9.145.2(40372) idle
root      5851  0.0  0.0 112656   968 pts/2    R+   14:16   0:00 grep --color=auto send
postgres 11326  2.3  0.4 9005572 71260 ?       Ss   Mar28 391:07 postgres: wal sender process repuser 10.9.145.2(49080) idle
postgres 16680  0.2  0.0 8888864 1900 ?        Ss   Mar15  75:21 postgres: wal sender process replication 10.8.109.160(48712) streaming 756/C75E0000
postgres 28048  0.2  0.0 8888880 1868 ?        Ss   Mar20  59:58 postgres: wal sender process replication 10.7.129.249(48794) streaming 756/C75E0000
[root@sh001m01 ~]# lsof -p 11326 | grep output
postgres 11326 postgres  mem       REG     253,1     15672  33684631 /usr/pgsql-10/lib/pgoutput.so
[root@sh001m01 ~]# lsof -p 16680 | grep output
[root@sh001m01 ~]#
```

### 异步逻辑复制

1. publisher事务开始commit
2. backend进程写wal
3. 向wal sender发送SIGUSR1信号
4. backend返回commit成功
5. wal sender读取wal日志，通过默认的解析插件pgoutput进行解析。
6. Wal sender发送给subscriber

### 同步逻辑复制

1. publisher事务开始commit
2. backend进程写wal
3. 向wal sender发送SIGUSR1信号
4. wal sender读取wal日志，通过默认的解析插件pgoutput进行解析。
5. Wal sender发送给subscriber
6. wal sender向backend发送SIGUSR1信号
7. backend返回commit成功

# 坑

## pgoutput的undefined symbol

```bash
ERROR:  could not create replication slot "my_sub": ERROR:  could not load library "/usr/pgsql-10/lib/pgoutput.so": /usr/pgsql-10/lib/pgoutput.so: undefined symbol: is_publishable_relation
```

### 原因

原来服务器上的PostgreSQL是10.2版本，PostgreSQL的而进行重新安装了10.4。查找`is_publishable_relation`只在10.4的`src/backend/catalog/pg_publication.c`中存在，在10.2中还没有引入这个函数。

```c
/*
 * Another variant of this, taking a Relation.
 */
bool
is_publishable_relation(Relation rel)
{
	return is_publishable_class(RelationGetRelid(rel), rel->rd_rel);
}
```

需重启PostgreSQL来升级小版本。
