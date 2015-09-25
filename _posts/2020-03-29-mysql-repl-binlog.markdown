---
layout: post
title: MySQL5.7——并行复制（MTS）解析
date: 2020-01-29 13:40
categories:
  - MySQL
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}

在[另一个blog](http://liuyangming.tech/06-2019/MySQL-binlog.html)中，阐述了binlog以及group commit的机制，binlog在MySQL中主要是用来做主从同步的，为了提高从库的性能，在5.6中引入了基于database的并行复制，之后又有了基于Logical_clock（group commit）的并行复制。本文基于笔者对MySQL5.7代码的阅读，阐述MySQL基于binlog的主从同步的内部机理。

# GTID-based replication

## 配置

基于gtid的binlog复制

1. 主库赋予权限并锁定

   ```bash
   mysql -h $MASTER_HOST "-P$MASTER_PORT" "-u$USER" "-p$PASS" $DB <<-EOSQL
   	GRANT REPLICATION SLAVE ON *.* TO '$USER'@'%' IDENTIFIED BY '$PASS';
   	FLUSH PRIVILEGES;
   	FLUSH TABLES WITH READ LOCK;
   EOSQL
   ```

   我们可以见将该语句丢到后台：

   ```bash
   mysql -h $MASTER_HOST "-P$MASTER_PORT" "-u$USER" "-p$PASS" $DB <<-EOSQL &
   	GRANT REPLICATION SLAVE ON *.* TO '$USER'@'%' IDENTIFIED BY '$PASS';
   	FLUSH PRIVILEGES;
   	FLUSH TABLES WITH READ LOCK;
   	DO SLEEP(3600);
   EOSQL
   ```

   > FLUSH TABLES WITH READ LOCK; 传说中的FTWRL

2. 导出数据

   ```bash
   mysqldump -h $MASTER_HOST "-P$MASTER_PORT" "-u$USER" "-p$PASS" --opt --databases $DB $DB2 > $DUMP_FILE
   ```

3. 获取master的binlog位点

   ```bash
   MASTER_STATUS=$(mysql -h $MASTER_HOST "-P$MASTER_PORT" "-u$USER" "-p$PASS" -ANe "SHOW MASTER STATUS;" | awk '{print $1 " " $2}')
   LOG_FILE=$(echo $MASTER_STATUS | cut -f1 -d ' ')
   LOG_POS=$(echo $MASTER_STATUS | cut -f2 -d ' ')
   echo "  - Current log file is $LOG_FILE and log position is $LOG_POS"
   ```

4. 释放主库的锁

   ```sql
   UNLOCK TABLES;
   ```

   如果丢后台了，则：

   ```bash
   kill $! 2>/dev/null
   wait $! 2>/dev/null
   ```

5. restore slave

   ```bash
   mysql -h $SLAVE_HOST "-u$USER" -e "DROP DATABASE IF EXISTS $DB; CREATE DATABASE $DB;"
   mysql -h $SLAVE_HOST "-u$USER" $DB < $DUMP_FILE
   ```

6. 启动复制

   ```bash
   	mysql -h $SLAVE_HOST "-u$USER" $DB <<-EOSQL
   		STOP SLAVE;
   		CHANGE MASTER TO MASTER_HOST='$MASTER_HOST',
   		MASTER_PORT=$MASTER_PORT,
   		MASTER_USER='$USER',
   		MASTER_PASSWORD='$PASS',
   		MASTER_LOG_FILE='$LOG_FILE',
   		MASTER_LOG_POS=$LOG_POS;
   		START SLAVE;
   	EOSQL
   ```

7. 检查 slave

   ```bash
   SLAVE_OK=$(mysql -h $SLAVE_HOST "-u$USER" -e "SHOW SLAVE STATUS\G;" | grep 'Waiting for master')
   ```

关于配置个人操作不是很熟练，这里有个[脚本](https://github.com/Layamon/mysql-bash/blob/master/rpl_conf.sh)。

> 如果是基于rowbase，那么在从库开启general-log也看不到查询
>
> ![image-20200610100627076](/image/mysql-binlog/image-20200610100627076.png)

## 基本介绍

MySQL的GTID是全局事务ID，每个事务由GTID标识，在master上跟踪事务状态并在slave上应用。GTID具体就是由冒号连接的两个ID的组合：

```ini
GTID = source_id:transaction_id
```

source_id就是master的server_id（server_uuid上面配置中体现）。transaction_id是一个序列值，表示哪些事务在master上commit成功了。比如，`3E11FA47-71CA-11E1-9E33-C80AA9429562:23`表示在`uuid=3E11FA47-71CA-11E1-9E33-C80AA9429562`的server上事务号23的事务提交成功了。

GTID在整个复制集群中是唯一的，slave中如果重做了某个GTID标识的事务，那么后续该GTID标识的事务则不予理睬（参数enforce-gtid-consistency）。

> **GTID set**
>
> 一组gtid可以表示为一个gtid set，如`2174B383-5441-11E8-B90A-C80AA9429562:1-3:11:47-49, 24DA167-0C0C-11E8-8442-00059A3C7B00:1-19`。
> 
> 关于实例历史gtid的状态，可以查看参数：gtid_executed和gtid_purged，前者表示当前实例已经执行的gtid，后者是前者的子集，其中的gtid已经不再binlog中了（binlog会回收）。通常查看`[GTID_SUBTRACT(@@GLOBAL.gtid_executed, @@GLOBAL.gtid_purged)`，得知在复制过程中binlog中的gtid。
>
> 关于当前gtid的状态，可以查看参数：gtid_owned；这是全局只读的参数；查看全局的值：**@@global.gtid_owned**，可以看到线程和GTID的绑定关系；查询session的值，看当前线程对应的GTID；并且我们可以设置gtid_next，指定当前session的要执行事务的gtid。

在master上的binlog中，是按照事务为单位进行存储；一个事务的binlog前会带有一个gtid event，标识该事务的gtid；并且gtid的生成确保是单调的，并且是没有空隙的。如果事务没有写入到binlog中，那么就不会生成gtid（比如事务是只读的）。通过mysqlbinlog工具可以查看binlog的内容，如下面的binlog日志中的gtid的状态相关的event（Gtid_log_event）：

```bash
mysqlbinlog --no-defaults mysql-bin.091309 | grep GTID -A 5 -B 6
...
#200408  6:59:43 server id 68825538  end_log_pos 35315355 CRC32 0x0e29a8d8      GTID    last_committed=38792    sequence_number=38793   rbr_only=yes
/*!50718 SET TRANSACTION ISOLATION LEVEL READ COMMITTED*//*!*/;
SET @@SESSION.GTID_NEXT= '5fde1f05-9ef2-11e9-ba63-6c92bf69212a:99002437374'/*!*/;
# at 35315355
#200408  6:59:43 server id 68825538  end_log_pos 35315418 CRC32 0x574b0538      Query   thread_id=330385        exec_time=0     error_code=0
SET TIMESTAMP=1586300383/*!*/;
BEGIN
/*!*/;
--
jQXfx/ZtEw==
'/*!*/;
# at 35316037
#200408  6:59:43 server id 68825538  end_log_pos 35316068 CRC32 0xbcfd1374      Xid = 13297501201
COMMIT/*!*/;
...
```

在slave端，如果某个gtid对应的binlog正在执行，那么此时如果执行相同gtid的binlog会被block。系统表`mysql.gtid_executed`维护了已经应用过的gtid，如果崩溃的时候没有及时更新gtid_executed的数据，那么恢复的时候会从binlog中读取。

## 并行复制

Gtid的一大作用就是用在replication中，下面讨论的内容，配置为：`gtid_mod = on/gtid_next = AUTOMATIC`；下图简单罗列了基于Gtid主从同步的过程，Master在binlogcommit的时候产生gtid，记为GTID_LOG_EVENT；Slave按照事务为单位进行恢复，每次读取GTID，按照该GTID执行事务；这样保证整个复制集群的GTID的一致性。

![image-20200430090447224](/image/mysql-repl/gtid-life.png)

并发复制时，last_master_timestamp的更新是在从库事务执行结束后，如果出现一个很大的事务，主从延迟的时间就会变大，可以通过如下操作开启MTS，提高Slave的Replay速度；

```sql
stop slave;
set global slave_parallel_type='logical_clock';
set global slave_parallel_workers=10;
start slave;
```

`slave_parallel_type`有DATABASE、LOGICAL_CLOCK两种机制，区别如何确保worker的并发事务之间不冲突。database就是很直观，不同db的事务肯定不冲突；Logical Clock就是按照commit_order/Lock interval/write set等方式确定了一个逻辑的时间顺序；下面逐个介绍（MySQL 8.0.19）。

### Database 

TODO

### Logical Clock

这里主要介绍Logical_clock的机制。Logical clock原来是基于commit order，在5.7中是基于lock interval的；原理是类似的，只不过无冲突区更宽，使得并发程度更高。

由于在MySQL中写入是基于两阶段锁的并发控制（读是通过ReadView或锁），并且我们知道锁的释放是在XA-engine-commit阶段（InnoDB）；那么，在Master端**同时处于prepare阶段且未提交**的事务就不会存在锁冲突，在Slave端执行时都可以并行执行，这就是基于commit order的Logical clock。

#### Master

MySQL的master在MYSQL_BIN_LOG中，维护一个递增的全局事务号：

```cpp
class MYSQL_BIN_LOG: public TC_LOG
{
   Logical_clock max_committed_transaction; //最后一次组提交的事务中最大sequence_number
   Logical_clock transaction_counter; //全局递增数值，表征每一个事务
}
```

每个事务本身也维护自己的序列号和依赖的last_commited_id：

```cpp
class Transaction_ctx{
  /* Binlog-specific logical timestamps. */
  /*
    Store for the transaction's commit parent sequence_number.
    The value specifies this transaction dependency with a "parent"
    transaction.
    The member is assigned, when the transaction is about to commit
    in binlog to a value of the last committed transaction's sequence_number.
    This and last_committed as numbers are kept ever incremented
    regardless of binary logs being rotated or when transaction
    is logged in multiple pieces.
    However the logger to the binary log may convert them
    according to its specification.
  */
  int64 last_committed;
  int64 sequence_number;
}
```

事务中每条DML在prepare时，会更新自己last_committed（store_commit_parent）；这样last_commit_id实际上就是事务最后一个DML时的逻辑时间戳。

```cpp
  if (!cache_mngr->stmt_cache.is_binlog_empty())
  {
    /*
      Commit parent identification of non-transactional query has
      been deferred until now, except for the mixed transaction case.
    */
    trn_ctx->store_commit_parent(m_dependency_tracker.get_max_committed_timestamp());
    if (cache_mngr->stmt_cache.finalize(thd))
      DBUG_RETURN(RESULT_ABORTED);
    stmt_stuff_logged= true;
  }
```

另一篇文章介绍的binlog组提交中，在flush阶段，会将binlog的信息完全准备好，这里就包括Gtid Event；如下binlog日志的Gtid Event。

```bash
mysqlbinlog --no-defaults mysql-bin.091309 | grep GTID
#200408  6:59:30 server id 68825538  end_log_pos 10898580 CRC32 0xfbc95f0f      GTID    last_committed=11786    sequence_number=11788   rbr_only=yes
SET @@SESSION.GTID_NEXT= '5fde1f05-9ef2-11e9-ba63-6c92bf69212a:99002410369'/*!*/;
#200408  6:59:30 server id 68825538  end_log_pos 10899500 CRC32 0x578388cc      GTID    last_committed=11787    sequence_number=11789   rbr_only=yes
SET @@SESSION.GTID_NEXT= '5fde1f05-9ef2-11e9-ba63-6c92bf69212a:99002410370'/*!*/;
#200408  6:59:30 server id 68825538  end_log_pos 10900014 CRC32 0x8687b9b7      GTID    last_committed=11789    sequence_number=11790   rbr_only=yes
SET @@SESSION.GTID_NEXT= '5fde1f05-9ef2-11e9-ba63-6c92bf69212a:99002410371'/*!*/;
#200408  6:59:30 server id 68825538  end_log_pos 10900490 CRC32 0x0524496a      GTID    last_committed=11789    sequence_number=11791   rbr_only=yes
SET @@SESSION.GTID_NEXT= '5fde1f05-9ef2-11e9-ba63-6c92bf69212a:99002410372'/*!*/;
#200408  6:59:30 server id 68825538  end_log_pos 10900965 CRC32 0x0379b50f      GTID    last_committed=11791    sequence_number=11792   rbr_only=yes
SET @@SESSION.GTID_NEXT= '5fde1f05-9ef2-11e9-ba63-6c92bf69212a:99002410373'/*!*/;
#200408  6:59:30 server id 68825538  end_log_pos 10902208 CRC32 0xba48e69e      GTID    last_committed=11792    sequence_number=11793   rbr_only=yes
SET @@SESSION.GTID_NEXT= '5fde1f05-9ef2-11e9-ba63-6c92bf69212a:99002410374'/*!*/;
#200408  6:59:30 server id 68825538  end_log_pos 10902706 CRC32 0x9ccfd55b      GTID    last_committed=11792    sequence_number=11794   rbr_only=yes
```

上面提到的Logical Clock是一个整数，而整数在计算机内是有上限的；为避免整数溢出，基于binlog的实际存储是按照文件的方式，当达到一定大小后，会进行rotate的情况；实际上，Logical clock内维护一个offset，即rotate的时候的`transaction_counter`；而实际存储在Gtid Event内的last_commited_id和sequence_number是：

+ last_commited_id = Transaction_ctx.last_committed - MYSQL_BIN_LOG.max_committed_transactions.offset

+ sequence_number = Transaction_ctx.sequence_number - MYSQL_BIN_LOG.max_committed_transactions.offset

最后，在GroupCommit的commit阶段，将该Group中Transaction_ctx.sequence_number最大的更新到MYSQL_BIN_LOG.max_committed_transactions中。

> mysqlbinlog \    --start-datetime="2010-11-20 00:00:00" \    --stop-datetime="2010-11-21 00:00:00" \

#### Slave

在Slave端IO线程不断收binlog，写relaylog；SQL Coordinator读binlog，并决定是自己串行回放，还是分发给worker并行回放。具体使用那种并行方式，参见 `class Mts_submode_logical_clock : public Mts_submode`。Coordinator和Worker的信息都保存在以Relay_log_info为父类的结构中。在Slave端，Coordinator按事务为单位，将读出的event用`Slave_job_group`分装，然后，追加到gaq（Group Append Queue？）中；

![image-20200414140803954](/image/mysql-repl/slave-struct.png)

在使用Logical Clock的方式并发回放中，需要注意同步点：

+ Coordinator决定将event分发给某个Worker后，需要等待前面并发Group回放完成：就是检查当前事务的last_committed是否大于所有正在回放的事务中最小的sequence number

  ```cpp
  wait_for_last_committed_trx(rli, last_committed, lwm_estimate)
  // 涉及到的锁和信号量
    /*
       Lock to acquire by methods that concurrently update lwm of committed
       transactions and the min waited timestamp and its index.
    */
    mysql_mutex_t mts_gaq_LOCK;
    mysql_cond_t logical_clock_cond;
  ```

+ Coordinator决定自己串行回放Event，同样要等待

  ```cpp
  wait_for_workers_to_finish
  ```
  
  
