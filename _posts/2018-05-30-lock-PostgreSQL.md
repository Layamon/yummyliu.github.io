---
layout: post
title: 认识PostgreSQL的Lock
date: 2018-05-30 18:06
header-img: "img/head.jpg"
categories: 
    - PostgreSQL
typora-root-url: ../../layamon.github.io
---

{:toc}

PostgreSQL提供了**各种级别的锁**来控制对**各种数据对象**的并发访问。大多数PostgreSQL命令会自动获取适当模式的锁，以确保引用的对象不会在执行命令时，被冲突的事务删除或修改。本文简单介绍下PostgreSQL中的各种锁，以及一点使用经验。如果读了这个文章对PostgreSQL中的锁感兴趣，可以参考官方文档甚至PostgreSQL源码。

本文中按照用户是否可见，将PostgreSQL中有多种类型的锁分为两种。

### 用户可见的

> 从系统视图pg_locks中可见

用户可见的锁，是用户自己能够主动调用，并且在pg_locks中看到是否grant的锁，有regular lock和咨询锁。

#### regular Lock

regular lock分为表级别和行级别两种。

##### 表级别

一些操作可以自动的获得一些锁，也可以用`LOCK`语句显示的获得某些锁。在一个事务中可以定义 很多savepoint，当rollback to 某个sp时，会释放该sp之后获得的锁。

##### 行级别

通过一些数据库操作自动获得一些行锁，行锁并不阻塞数据查询，只阻塞writes和locker，比如如下操作。

- FOR UPDATE
- FOR NO KEY UPFATE
- FOR SHARE
- FOR KEY SHARE

PostgreSQL同一时间修改的行数没有限制，这里如果想避免获得不了锁的等待，可以采用`FOR UPDATE NOWAIT` ，或 `FOR UPDATE SKIP LOCKED`的方式。

#### 咨询锁

​	当MVCC模型和锁策略不符合应用时，采用咨询锁。咨询锁是提供给应用层显示调用的锁方法，在表中存储一个标记位能够实现同样的功能，但是咨询锁更快；其能避免表膨胀，且会话（或事务）结束后能够被Pg自动清理。

获得咨询锁：

1. 会话级别：该级别获得的咨询锁，没有事务特征，事务回滚或者取消，之前获得的咨询锁不会被unlock，一个咨询锁可以多次获得，相应的要多次取消。
2. 事务级别：事务级别获得的锁，事务结束后会自动unlock。

两种方式获得的咨询锁，如果锁在了一个识别符上，那么他们也是互相block的；咨询锁可以用在业务需要强制串行化等场景中，比如秒杀。

#### 死锁检测

​	用户可见的锁一般加锁的方式是LOCK语句直接请求或者SQL语句间接调用，可能会导致死锁；死锁检测的代价比较昂贵，PostgreSQL发生锁等待时，会等待deadlock_timeout后，才检测死锁；默认是1s，负载比较中，一般可以将deadlock_timeout设置为稍大于业务通常事务的执行时间；

```log
ERROR:  deadlock detected
DETAIL:  Process 1181 waits for ShareLock on transaction 579; blocked by process 1148.
Process 1148 waits for ShareLock on transaction 578; blocked by process 1181.
```

​	检测到死锁，PostgreSQL就会回滚事务，这就要求应用一定要对这种错误进行重试处理。

#### 一些建议

##### 内存耗尽

锁是存储在内存中的，上限由参数max_locks_per_transaction 和 max_connections控制，要避免空间耗尽，导致无法获取新的Lock。

##### 咨询锁与limit

使用咨询锁时，如果有limit操作，要注意可能pg_advisory_lock在limit操作之前调用，那么如下的情况可能并不是锁了100个对象。

```sql
SELECT pg_advisory_lock(id) FROM foo WHERE id = 12345; -- ok
SELECT pg_advisory_lock(id) FROM foo WHERE id > 12345 LIMIT 100; -- danger!
SELECT pg_advisory_lock(q.id) FROM
(
  SELECT id FROM foo WHERE id > 12345 LIMIT 100
) q; -- ok
```

##### 加带默认值的列

>（PostgreSQL10之前）

PostgreSQL10之前，果你添加的列带有默认值，PostgreSQL会重写整张表，来对每一行设置默认值，在大表上可能会是几个小时的工作，这样所有查询就会被阻塞，数据库不可用；

DO NOT

```SQL
-- 读写都会被阻塞
ALTER TABLE items ADD COLUMN last_update timestamptz DEFAULT now();
```

INSTEAD

```SQL
-- select, update, insert, 和 delete 都会阻塞
ALTER TABLE items ADD COLUMN last_update timestamptz;
-- select 和 insert 可行, 当表重写的时候，部分update·和delete会被阻塞
UPDATE items SET last_update = now();
```

BETTER

```c
do {
  numRowsUpdated = executeUpdate(
    "UPDATE items SET last_update = ? " +
    "WHERE ctid IN (SELECT ctid FROM items WHERE last_update IS NULL LIMIT 5000)",
    now);
} while (numRowsUpdate > 0);
```

##### lock_timeout

每个PostgreSQL中的锁都有一个锁队列。如果一个锁是排他的，事务A占有，事务B获取的时候，就会在锁队列中等待。有趣的是，如果这时候事务C同样要获取该锁，那么它不仅要和A检查冲突性，也要和B检查冲突性，以及队列中其他的事务；这就意味着，即使你的DDL语句可以很快的执行，但是它可能会在队列中等待很久，直到前面的查询结束。并且该DDL操作会将后续的查询阻塞；

DO NOT

```sql
ALTER TABLE items ADD COLUMN last_update timestamptz;
```

INSTEAD

```sql
SET lock_timeout TO '2s'
ALTER TABLE items ADD COLUMN last_update timestamptz;
```

##### CREATE INDEX CONCURRENTLY

在一个大数据集上建索引，有可能会花费数小时甚至数天的时间；常规的create index会阻塞所有的写操作；尽管不阻塞select，但是这还是不好的；

并行的创建索引确实有缺点。如果出了问题，它不会回滚，这会留下一个未完成的index；但是不用担心，`DROP INDEX CONCURRENTLY items_value_idx`，重新创建即可。

##### 慎用激进的锁

当在一个表上执行需要获得激进策略锁的时候，越晚越好，影响越小；比如如果你想替换一个表的内容；

DO NOT

```sql
BEGIN;
-- 读写都被阻塞
TRUNCATE items;
-- long-running operation:
\COPY items FROM 'newdata.csv' WITH CSV 
COMMIT; 
```

Instead

```sql
BEGIN;
CREATE TABLE items_new (LIKE items INCLUDING ALL);
-- long-running operation:
\COPY items_new FROM 'newdata.csv' WITH CSV
-- 读写从这开始阻塞
DROP TABLE items;
ALTER TABLE items_new RENAME TO items;
COMMIT; 
```

这里有个问题，我们不从一开始阻塞写。这样老的items表，在我们drop它之前，会发生改变；为了避免这一个情况，可以在一开始将表锁住，阻塞写，但是不阻塞读；

```SQL
BEGIN;
LOCK items IN EXCLUSIVE MODE;
...
```

##### 添加主键

在表上添加一个主键是有意义的，PostgreSQL中，可以通过alter table很方便的添加一个主键，但是当主键索引创建的时候，会花费很长时间，这样会阻塞查询；

DO NOT

```sql
ALTER TABLE items ADD PRIMARY KEY (id); 
```

INSTEAD

```sql
CREATE UNIQUE INDEX CONCURRENTLY items_pk ON items (id); -- 花很长时间，但是不会阻塞读写
ALTER TABLE items ADD CONSTRAINT items_pk PRIMARY KEY USING INDEX items_pk;  -- 阻塞读写，但是很短
```

通过将主键索引的创建，分成两步；这样繁重的创建索引的工作不会影响业务查询；

##### 调整命令顺序，避免死锁

如下两个事务,会导致死锁

```sql
BEGIN;
UPDATE items SET counter = counter + 1 WHERE key = 'hello'; -- grabs lock on hello
UPDATE items SET counter = counter + 1 WHERE key = 'world'; -- blocks waiting for world
END;
```

```SQL
BEGIN
UPDATE items SET counter = counter + 1 WHERE key = 'world'; -- grabs lock on world
UPDATE items SET counter = counter + 1 WHERE key = 'hello';  -- blocks waiting for hello
END; 
```

在一应用中，调整调用顺序，避免互相锁住对方

### 用户不可见

除了可以在SQL中直接或间接请求的锁以外，PostgreSQL中还有一些底层的锁，比如编程中常听说的自旋锁，以及控制共享内存的轻量锁，还有PostgreSQL的MVCC机制中的 SIReadLock。

#### 自旋锁

不像上述锁有多种模式，自旋锁只有获得和没获得两种状态，在程序中的同步操作中经常用到。和自旋锁（spinlock）类似的概念还有mutex（binary semaphore），atomic（原子操作）。

> spinlock：得不到，忙等
>
> mutex：得不到，阻塞等待唤醒
>
> atomic：把竞态条件作为一个操作，i++(read i; add i; write i; 作为一个操作)

在PostgreSQL中spinlock主要用来作为lightweight lock的基础设施。（PostgreSQL 9.5之后spinlock换成了atomic）

#### 页锁（lightweight lock）

​	PG中，有对于表的数据页的共享/互斥锁，一旦这些行读取或者更改完成后，相应锁就被释放。应用开发者一般不用考虑这个锁。

如果轻量锁成为了系统瓶颈，我们可以从pg_stat_activity中的wait_event_type和wait_event字段看到相关查询在等待某些轻量锁，这里简单介绍几个：

+ WALInsertLock：wal buffer是固定大小的，向wal buffer中写wal record需要竞争的锁，如果把synchronous_commit关闭，这个锁的竞争会更加激烈。

+ WALWriteLock：一般都是同步提交，要保证commit时，wal是刷盘的，那么刷盘就会竞争这个锁。

+ ProcArrayLock：保护PostgreSQL服务进程共享的ProcArray结构。

+ CLogControlLock：clog缓存在共享缓存中，保护clog的读写。

+ SInvalidReadLock：每个PostgreSQL进程维护了一个共享内存的数据子集的cache，如果修改了共享的元组，需要知会其他进程，这通过一个*SICleanupQueue*来传递消息。

  ```c
  typedef union
  {
  	int8		id;				/* type field --- must be first */
  	SharedInvalCatcacheMsg cc;
  	SharedInvalCatalogMsg cat;
  	SharedInvalRelcacheMsg rc;
  	SharedInvalSmgrMsg sm;
  	SharedInvalRelmapMsg rm;
  	SharedInvalSnapshotMsg sn;
  } SharedInvalidationMessage;
  ```

  如果这个锁成为系统瓶颈，说明共享内存的进程会被不同的进程修改，可以通过提高shard_buffers来减少竞争。

+ BufMappingLocks：共享内存的管理有一个buffer map；这个map分为128个区（在PostgreSQL 9.5 之前是16个区）。通过这个锁来保护这个map。

#### SIReadLock

对于regular lock，如果锁了很长时间，我们可以执行querycancel来终止获得相应的锁，而对于轻量锁，如果经常等待很久，或者经常执行querycancel都是不可接受的。在PostgreSQL中，对同一份数据的访问，采用的是多版本快照隔离的方式进行并发控制。

##### 快照隔离中的串行化异常

​	基于快照隔离的并发控制，看到的数据取决于获取的何时的数据版本。在RC和RR级别中，分别是在语句和事务级别获取的快照。在PostgreSQL 9.1之前，SERIALIZABLE级别的实际上就是RR级别，这已经不会出现SQL标准中的dirty read/unrepeatable read/phantom read三种异常，但是基于快照隔离还是会出现一些串行化异常，典型的有写偏（write-skew）。

###### 写偏

| 事务1 tidx    | 事务2   tidy  |
| ------------- | ------------- |
| begin；       |               |
| read   A；    | begin；       |
|               | read   B；    |
| update   B=A; |               |
|               | update   A=B; |
| commit;       |               |
|               | commit        |

如上两个事务，分别是读A写B和读B写A。一开始A!=B，如果串行化正确的话，结果应该是A=B；然而在RR级别中，一开始分别获取了A和B的旧快照，按照如上执行的结果还是A!=B，这就产生了写偏异常。

##### 串行化异常检测

事务时间有三种依赖：

+ T1-(ww)->T2 ：T1 Write A，T2 Write A

+ T1-(wr)->T2 ： T1 Write A， T2 Read A

+ T1-(rw)->T2：T1 Read A，T2 Write A 

在论文*Making Snapshot Isolation Serializable*中解释了如何在快照隔离中实现序列化，其中有一个重要的结论：

结论：事务依赖图中，如果**有环**且环中**有T1-(rw)->T2-(rw)->T3**，就可能出现序列化异常。

那么，在DB中可以检测上述两个条件来检测串行化异常，而检测是否有环的代价较大，在PostgreSQL中只检查其中一个条件。虽然会产生误判，但在保证性能的前提下，能够保证不会产生序列化异常。

![image-20181105070206853](/image/pg-lock/image-20181105070206853.png)

#### SIREADLOCK

PostgreSQL如何检测序列化异常，就是通过SIREADLOCK来进行的，在有些DB中，有自己的意向锁机制，这个锁有点像PostgreSQL中的意向锁，其中保存了两种信息（{object1，...}，tid），即，那个tid要访问那些object。对于SIREADLOCK主要有下面四个操作，这里结合前面的例子进行简单阐述：

| 事务1 tidx  | 事务2 tidy  |
| ----------- | ----------- |
| begin；     |             |
| read A；    | begin；     |
|             | read B；    |
| update B=A; |             |
|             | update A=B; |
| commit;     |             |
|             | abort       |

##### 1.  创建

+ tidx创建一个SIREAD lock {A, {tidx}}。

+ tidy创建一个SIREAD lock {B, {tidy}}。

##### 2. 合并

SIREADLOCK分别三个级别（tuple、page、relation），存储在内存中，为了节省空间，当低级别够了一个高级别时，会合并为一个高级别的锁；比如，当某个page中所有的tuple都加了SIREADLOCK，那么tuple锁就会合并为一个page锁。

##### 3. RW依赖检测

当执行写操作时，发现有rw依赖，那么创建一个rw依赖结构，这里两个事务在update的时候分别创建两个RW conflict结构。

+ {r=tidy, w=tidx, {B}} 

+ {r=tidx, w=tidy, {A}}

##### 4. 提交

当前事务作为Tpivot，检测是否有一个rw出边和一个rw入边，有则按照**first-commiter-win**进行处理，而另一个就Rollback。
