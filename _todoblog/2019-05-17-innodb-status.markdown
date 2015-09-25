---
layout: post
title: 了解show engine innodb status
date: 2019-5-17 18:38
header-img: "img/head.jpg"
categories: 
  - InnoDB
typora-root-url: ../../layamon.github.io
---
> * TOC
{:toc}

# show engine innodb status

首先该命令的输出都是统计信息按秒统计的平均值，值得注意的是该命令的输出不是一个快照信息，就是所有的统计信息不是同一个时间点输出的，因此可能会有冲突的地方。

1. SEMAPHORES

```shell
----------
SEMAPHORES
----------
OS WAIT ARRAY INFO: reservation count 13569, signal count 11421
--Thread 1152170336 has waited at ./../include/buf0buf.ic line 630 for 0.00 seconds the semaphore:
Mutex at 0x2a957858b8 created file buf0buf.c line 517, lock var 0
waiters flag 0
wait is ending
--Thread 1147709792 has waited at ./../include/buf0buf.ic line 630 for 0.00 seconds the semaphore:
Mutex at 0x2a957858b8 created file buf0buf.c line 517, lock var 0
waiters flag 0
wait is ending
Mutex spin waits 5672442, rounds 3899888, OS waits 4719
RW-shared spins 5920, OS waits 2918; RW-excl spins 3463, OS waits 3163
```

该模块分为两个部分：

1. 是等待操作系统信号的线程的描述：线程的并发控制采用的是自选锁，不会出现在这里。

   通过系统信号的等待，我们可以知道当前业务线程的并发热点在哪里。如上例子中，我们可以看出都在buf模块等待，那么可能在bufpool中的竞争比较激烈，具体是竞争什么就得看buf0buf.c:517行是什么了。

   另外还有一些参数的含义如下：

   lock var： 表示当前mutex的上锁状态，locked=1/free=0

   Waiter flag : 等待该mutex的线程数

   wait is ending : 表示无需等待，可以放行了。

2. 系统event的counter，主要有三个信息：

   spin wait: 自旋锁的等待

   Spin round:自旋锁？？

   OS wait：系统信号等待

   spinlock比起OSwait是一种低代价的等待，但是会耗费CPU资源。因此，如果你的spin统计很高，可能浪费了很多cpu，参数*innodb_sync_spin_loops*可以平衡 自旋锁的CPU代价和上下文切换代价。

2. LATEST DETECTED DEADLOCK

``` shell
------------------------
LATEST DETECTED DEADLOCK
------------------------
060717  4:16:48
*** (1) TRANSACTION:
TRANSACTION 0 42313619, ACTIVE 49 sec, process no 10099, OS thread id 3771312 starting index read
mysql tables in use 1, locked 1
LOCK WAIT 3 lock struct(s), heap size 320
MySQL thread id 30898, query id 100626 localhost root Updating
update iz set pad='a' where i=2
*** (1) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 0 page no 16403 n bits 72 index `PRIMARY` of table `test/iz` trx id 0 42313619 lock_mode X locks rec but not gap waiting
Record lock, heap no 5 PHYSICAL RECORD: n_fields 4; compact format; info bits 0
 0: len 4; hex 80000002; asc     ;; 1: len 6; hex 00000285a78f; asc       ;; 2: len 7; hex 00000040150110; asc    @   ;; 3: len 10; hex 61202020202020202020; asc a         ;;

*** (2) TRANSACTION:
TRANSACTION 0 42313620, ACTIVE 24 sec, process no 10099, OS thread id 4078512 starting index read, thread declared inside InnoDB 500
mysql tables in use 1, locked 1
3 lock struct(s), heap size 320
MySQL thread id 30899, query id 100627 localhost root Updating
update iz set pad='a' where i=1
*** (2) HOLDS THE LOCK(S):
RECORD LOCKS space id 0 page no 16403 n bits 72 index `PRIMARY` of table `test/iz` trx id 0 42313620 lock_mode X locks rec but not gap
Record lock, heap no 5 PHYSICAL RECORD: n_fields 4; compact format; info bits 0
 0: len 4; hex 80000002; asc     ;; 1: len 6; hex 00000285a78f; asc       ;; 2: len 7; hex 00000040150110; asc    @   ;; 3: len 10; hex 61202020202020202020; asc a         ;;

*** (2) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 0 page no 16403 n bits 72 index `PRIMARY` of table `test/iz` trx id 0 42313620 lock_mode X locks rec but not gap waiting
Record lock, heap no 4 PHYSICAL RECORD: n_fields 4; compact format; info bits 0
 0: len 4; hex 80000001; asc     ;; 1: len 6; hex 00000285a78e; asc       ;; 2: len 7; hex 000000003411d9; asc     4  ;; 3: len 10; hex 61202020202020202020; asc a         ;;

*** WE ROLL BACK TRANSACTION (2)
```

该模块显示了造成死锁的**事务的状态**，已经他们**获得的锁**和**等待的锁**；以及INNODB将要回滚哪个事务来解决这个死锁。在事务的状态里的语句是执行的最后一条语句，但是有可能锁是由于前面的语句造成的，因此对于复杂的情况，可能得查看日志记录才能找到真正冲突的数据。

3. LATEST FOREIGN KEY ERROR

```shell
------------------------
LATEST FOREIGN KEY ERROR
------------------------
060717  4:29:00 Transaction:
TRANSACTION 0 336342767, ACTIVE 0 sec, process no 3946, OS thread id 1151088992 inserting, thread declared inside InnoDB 500
mysql tables in use 1, locked 1
3 lock struct(s), heap size 368, undo log entries 1
MySQL thread id 9697561, query id 188161264 localhost root update
insert into child values(2,2)
Foreign key constraint fails for table `test/child`:
,
  CONSTRAINT `child_ibfk_1` FOREIGN KEY (`parent_id`) REFERENCES `parent` (`id`) ON DELETE CASCADE
Trying to add in child table, in index `par_ind` tuple:
DATA TUPLE: 2 fields;
 0: len 4; hex 80000002; asc     ;; 1: len 6; hex 000000000401; asc       ;;

But in parent table `test/parent`, in index `PRIMARY`,
the closest match we can find is record:
PHYSICAL RECORD: n_fields 3; 1-byte offs TRUE; info bits 0
 0: len 4; hex 80000001; asc     ;; 1: len 6; hex 0000140c2d8f; asc     - ;; 2: len 7; hex 80009c40050084; asc    @   ;;
```

这个模块很简单，打印了违反外键约束的语句，以及违反的哪个外键约束。另外一些没什么鸟用的16进制数，一般用在内核开发的debug的时候。

4. TRANSACTIONS

```shell
------------
TRANSACTIONS
------------
Trx id counter 0 80157601
Purge done for trx's n:o < 0 80154573 undo n:o < 0 0 History list length 6 Total number of lock structs in row lock hash table 0 LIST OF TRANSACTIONS FOR EACH SESSION: ---TRANSACTION 0 0, not started, process no 3396, OS thread id 1152440672 MySQL thread id 8080, query id 728900 localhost root show innodb status ---TRANSACTION 0 80157600, ACTIVE 4 sec, process no 3396, OS thread id 1148250464, thread declared inside InnoDB 442 mysql tables in use 1, locked 0 MySQL thread id 8079, query id 728899 localhost root Sending data select sql_calc_found_rows * from b limit 5 Trx read view will not see trx with id >= 0 80157601, sees < 0 80157597 ---TRANSACTION 0 80157599, ACTIVE 5 sec, process no 3396, OS thread id 1150142816 fetching rows, thread declared inside InnoDB 166 mysql tables in use 1, locked 0 MySQL thread id 8078, query id 728898 localhost root Sending data select sql_calc_found_rows * from b limit 5 Trx read view will not see trx with id >= 0 80157600, sees < 0 80157596 ---TRANSACTION 0 80157598, ACTIVE 7 sec, process no 3396, OS thread id 1147980128 fetching rows, thread declared inside InnoDB 114 mysql tables in use 1, locked 0 MySQL thread id 8077, query id 728897 localhost root Sending data select sql_calc_found_rows * from b limit 5 Trx read view will not see trx with id >= 0 80157599, sees < 0 80157595 ---TRANSACTION 0 80157597, ACTIVE 7 sec, process no 3396, OS thread id 1152305504 fetching rows, thread declared inside InnoDB 400 mysql tables in use 1, locked 0 MySQL thread id 8076, query id 728896 localhost root Sending data select sql_calc_found_rows * from b limit 5 Trx read view will not see trx with id >= 0 80157598, sees < 0 80157594
```

这里只显示的是每个事务的状态，但是如果连接很多，那么这里可能就只是一个counter；

另外，这里还显示的purge已经处理到那个事务了和当前处理的undo record数量（undo n:o），因此，如果有老的事务一直stale，那么通过两次status的purge的状态比较，就可以知道purge阻塞了。对于更新频繁的场景，可能purge跟不上更新的速度，那么可以通过参数*innodb_max_purge_lag*来调整；

History list length 6表示当前在undo space中，但是未被purge的事务数量；事务提交时该值+1， 被purge后，该值-1。

*Total number of lock structs* 表示在内部的行锁哈希表中的行锁对象的总数，这里不等于被锁住的行数，因为一个行锁可能锁了多个行。

连接的状态只有两种：not started和active，注意在多语句的事务中，连接的状态非active时，该连接上的事务也可能是active。另外，还会打印进程和线程ID，方便使用gdb进行调试定位。对于连接上的事务状态就更加细致了，比如显示了*fetching rows*，*updating*等信息。

InnoDB通过*innodb_thread_concurrency*参数限定了可以同时处理的并发数，当事务状态为*Thread declared inside InnoDB 400*，表示该事务在InnoDB中运行了，并且还有400并发余量。如果事务状态为*waiting in InnoDB queue*，那么就表示在等待被处理，如果等待时间过长，就会进入*sleeping before joining InnoDB queue*状态，通过参数*innodb_thread_sleep_delay*可以控制sleep的时间。

*mysql tables in use 1, locked 0*，表示现在使用了几个表，上了几个表锁；注意InnoDB一般没有表锁，除非执行了alter table或者lock table。

5. FILE I/O

```shell
--------
FILE I/O
--------
I/O thread 0 state: waiting for i/o request (insert buffer thread)
I/O thread 1 state: waiting for i/o request (log thread)
I/O thread 2 state: waiting for i/o request (read thread)
I/O thread 3 state: waiting for i/o request (write thread)
Pending normal aio reads: 0, aio writes: 0,
 ibuf aio reads: 0, log i/o's: 0, sync i/o's: 0
Pending flushes (fsync) log: 0; buffer pool: 0
17909940 OS file reads, 22088963 OS file writes, 1743764 OS fsyncs
0.20 reads/s, 16384 avg bytes/read, 5.00 writes/s, 0.80 fsyncs/s
```

上面显示的四个线程只有在Unix/Linux环境下采用，window下没有（可以通过参数*innodb_file_io_threads*调整）。  除了线程的状态，还有aio和fsync的统计信息。对于`16384 avg bytes/read`这个统计信息，主要是在预读的场景中使用，

6. INSERT BUFFER AND ADAPTIVE HASH INDEX

```shell
-------------------------------------
INSERT BUFFER AND ADAPTIVE HASH INDEX
-------------------------------------
Ibuf for space 0: size 1, free list len 887, seg size 889, is not empty
Ibuf for space 0: size 1, free list len 887, seg size 889,
2431891 inserts, 2672643 merged recs, 1059730 merges
Hash table size 8850487, used cells 2381348, node heap has 4091 buffer(s)
2208.17 hash searches/s, 175.05 non-hash searches/s
```

Ibuf的插入和merge的效率。

AHI是将pool中的page的查找从btree查找，变成hash查找。hash search和non-hash search的比例可视为hash的命中率。

这两个东西通过参数就没什么好调整，只是作为一种统计信息可以看看。

7. LOG

```shell
---
LOG
---
Log sequence number 84 3000620880
Log flushed up to   84 3000611265
Last checkpoint at  84 2939889199
0 pending log writes, 0 pending chkp writes
14073669 log i/o's done, 10.90 log i/o's/second
```

通过比较log seq num和log flushed up to，可以知道参数*innodb_log_buffer_size*定义的logbuffer的大小是不是合理的，如果log seq num比log flushed up to大很多（超过30%），那么就要考虑增加这个参数了。

另外，根据参数*innodb_flush_log_at_trx_commit*定义不同，log write的统计信息可能重要性也不高。

8. BUFFER POOL AND MEMORY

```shell
----------------------
BUFFER POOL AND MEMORY
----------------------
Total memory allocated 4648979546; in additional pool allocated 16773888
Buffer pool size   262144
Free buffers       0
Database pages     258053
Modified db pages  37491
Pending reads 0
Pending writes: LRU 0, flush list 0, single page 0
Pages read 57973114, created 251137, written 10761167
9.79 reads/s, 0.31 creates/s, 6.00 writes/s
Buffer pool hit rate 999 / 1000
```

buffer pool中除了放一些脏页，还有一些lock信息（？） 和 AHI以及一些其他结构。

buffer的刷盘通过三种触发：为保证命中率，只将热点数据保留，LRU将冷数据刷盘；checkpoint推进需要flushlist不断将老脏页刷盘；单独的page写。

还有就是buffer的命中率。

> 这里的内存总量包括buffer pool和其他一些不在bufferpool中的cache。

9. ROW OPERATIONS

```shell
--------------
ROW OPERATIONS
--------------
0 queries inside InnoDB, 0 queries in queue
1 read views open inside InnoDB
Main thread process no. 10099, id 88021936, state: waiting for server activity
Number of rows inserted 143, updated 3000041, deleted 0, read 24865563
0.00 inserts/s, 0.00 updates/s, 0.00 deletes/s, 0.00 reads/s
```

从行的维度来统计InnoDB中的查询操作。但是要注意行的大小不同，因此这里每个读写的代价可能不一样；比如读一个10Mb的blog类型和一个10byte的常规类型的行。
