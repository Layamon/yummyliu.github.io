---
layout: post
title: MySQL8——REDO无锁重构剖析
date: 2019-08-05 20:45
header-img: "img/head.jpg"
categories: 
  - MySQL
  - InnoDB
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}


![image-20190619171105314](/image/mysql-8-redo/logbuffer-flush.png)

在上述LogBuffer的机制中，明显在多个UserThread写入的时候，存在一个竞争瓶颈。尤其是如果磁盘的写入速度比较快，导致磁盘在等待内存线程写入的竞争；这就大大限制了整个系统的写TPS。

在InnoDB中，每个页的变更由mtr来保证原子性；mtr提交的时候，首先在**log_sys->mutex**的互斥下，将自己的record写入到LogBuffer中，并更新全局lsn；然后在**log_sys->flush_order_mutex**的互斥下，将mtr相关的脏页，按顺序放到flushlist中。

+ 考虑这样一种情况：当t1得到**flush_order_mutex**，添加脏页的同时；t2请求**flush_order_mutex**，将会等待；为了保证总体的顺序，t2还持有**mutex**锁，那么此时其他的线程都要等待；这时整个系统的性能就下降了。

+ 另外，如果将这里的锁移除，就没有顺序性保证了。并且如果同时写可能有些在后面的先写完，这样就日志之间存在一些空洞，不能讲LogBuffer一起落盘；这里我们可以添加一些标记位，标明那些写完了。

# 内存拷贝的无锁优化

为了提高内存中的并发度，但是又必须保证整体的顺序；这里设计了一种LinkBuf的结构，保证落盘有序但是局部无序。基于此实现了一个LockFree的LogBuffer和RelaxedOrder的FlushLists；从而，减少了并发mtr提交时的锁同步代价。

## LinkBuf结构

> storage/innobase/include/ut0link_buf.h

![image-20191016170806232](/image/mysql-8-redo/link-buf.png)

在8.0中，添加了一个新的数据结构：Link Buffer。

这是一个固定大小的环形缓存，每个slot中存储了link对象。link可以看做是[from, to]表示的一个区间，对于一个link：[from, to]，通过from%m_capacity得到对应的slotindex，然后在该slot中存储了该区间的长度（`to - from`）。每个slot位置原子更新，整个数组循环重用；

另外，相应的线程负责遍历并清理用过的slot，在empty slot（slot中的val，即length=0，就是一个空slot，详情参考`advance_tail_until`函数）处会暂停遍历，并更新m_tail。此时，从头部开始可以将若干个小link整合成一个大link，如上图浅蓝色的部分。

在源码中，定义为一个模板，在log_sys应用中，有两个场景：

+ `Link_buf<lsn_t> recent_written`：LogBuffer的有序写入，在`log_buffer_write_completed`中，首先等待**recent_written.has_space**，然后`recent_written.add_link`。对应的在log_writer中，会推进recent_written的m_tail。
+ `Link_buf<lsn_t> recent_closed`：FlushList的有序写入，在mtr_commit中，先在`log_wait_for_space_in_log_recent_closed`等待recent_closed可以写入，然后`add_dirty_blocks_to_flush_list`。对应的在log_closer中，会推进recent_closed的m_tail。

## *写入LogBuffer：recent_written*

该对象是跟踪已经写入到LogBuffer中的记录，解决mlog写盘的mutex竞争；通过该对象的tail，可以得知任何小于tail的记录已经写入完毕了。如果进行故障恢复，最远只会恢复到这里(当然前提是这里已经落盘)；

线程——log_writer读取该结构上的tail，向前更新（下节）。

用户线程在写LogBuffer之前，先将sn向前推进，获得一个logbuffer的区间句柄（startsn,endsn,lockno），然后在获得的区间中进行写入。

> ```c++
>Log_handle log_buffer_reserve(log_t &log, size_t len) {
> ...
> /* Reserve space in sequence of data bytes: */
> const sn_t start_sn = log.sn.fetch_add(len);
>   ...
>   }
> ```

LogBuffer主要承载mlog写入和log写盘。

- write_lsn表示log已经写盘的位置(是否sync取决于提交参数，相应有个flushed_to_disk_lsn，暂不讨论)。
- buf_ready_for_write_lsn(其实就是recent_written.tail())表示可以进行write的位置，该位置之前日志是连续的，之后会有空洞。
- current_lsn，已经分配给某个mtr进行日志写入的最远位置。

![image-20191016180050715](/image/mysql-8-redo/recent-written.png)

当前mtr0已经结束，在log_writer下一次写盘时，会尝试推进tail。那么就会推进到mtr0结束处。将此处的mtrrecordgroup刷盘。由于recent_written是有限大小的，因此会循环使用，并且如果新的mtr没有得到link，那么就会等linkbuf有空间才会写。

## *写入FlushList：recent_closed*

该对象是为了解决5.7中log_sys->flush_order_mutex解决的问题。现在为提高整体的并发度，我们不在保证向flush_list中添加dirty_page是有按LSN有序的。但是还是须满足两个前提条件：

**前提1：保证检查点正确性**：当在某个LSN写入CHECKPOINT记录之后，表示最近修改LSN<该CHECKPOINT_LSN的内存脏页都已经落盘了。

**前提2：保证数据页刷盘的顺序**：始终从flush_list的最老元组开始刷盘，这样可以推进checkpoint_lsn（因为checkpoint_lsn和所有flush_list中的最老修改lsn相关）。

那么，为了保证以上前提，还要提高效率；这里利用recent_closed的结构，实现一个*relaxed order  flush lists*，跟踪向flushlist中并发添加脏页的执行过程。

每次mtr_commit将日志写入到LogBuffer之后，会将mtr.start_lsn到mtr.end_lsn之间的脏页放到对应的flushlist中；在新的设计中，当用户线程需要拷贝脏页时，首先会确认recent_closed有空间（`log_wait_for_space_in_log_recent_closed`）；直到start_lsn对应的slot可写后，用户线程才会将脏页放在对应的flushlist中。

我们将flushList中的最早添加的脏页的lsn称为**last_lsn**；由于一个page可能会被修改多次，其中记录了oldest_modification和newest_modification（但是bufferpool中的状态始终是page最新的状态），那么，5.7的flushlist中的每个page的**oldest_modification >= last_lsn**；

![image-20191016180343977](/image/mysql-8-redo/recent-closed.png)

而在8.0的flushlist中，flushlist没有按照lsn的顺序添加，page的oldest_modification >= last_lsn-recent_close.capacity（可能recent_closed的最后一个mtr的dirtypage已经addtoflushlist了，但是之前的mtr的dirtypage还未addtoflushlist，如上图，只有mtr2的日志拷贝到flushlist中了，但是mtr2对应的lsn是最大的）；这就意味着，在新的flushlist中，最早放到flushlist中的page的oldest_modification不是最小的，因此不能用这个oldest_modification作为checkpoint_lsn，而是要由oldest_modification-recent_closed->capacity作为checkpoint_lsn。

> 注意
>
> 这里由于由某lsn直接减去一个固定大小的值，不能保证checkpoint_lsn肯定是record的边界，有可能checkpoint指向record的中间，这里恢复的时候需要找到checkpoint_lsn后第一个record。

因此，主要的思想就是：在**内存局部（recent_closed->capacity）**是乱序的，但是整体上还是有序的，因此checkpoint_lsn可以向前推进，这能够保证**前提2**；并且可以用last_lsn-recent_closed->capacity作为候选的CHECKPOINT-LSN，这可以满足**前提1**。

最后，在LinkBuf结构中，还有一个负责遍历的线程，这里就是log_closer。当mtr将start_lsn到end_lsn之间的脏页拷贝完之后，就会通知log_closer进行更新M。

> 因此，总结MySQL-8中的mtr提交过程如下：
>
> 1. commit时，通过log_sys.sn预留LogBuffer的空间
> 2. 将mtr_log中的redo record复制到LogBuffer中，然后得到start_lsn和end_lsn；
> 3. 迭代recent_write的连续最大LSN
> 4. 确认recent_closed是否可以插入(log_wait_for_space_in_log_recent_closed)
> 5. 拷贝脏页
> 6. 迭代recent_closed的连续最大LSN

# 专有线程异步操作

上面介绍了logfbuffer和flushlist的优化，下面介绍日志和数据的落盘的优化。

## *写出LogBuffer：commit flush*

在事务提交的时候，一般要求日志必须落盘(除非重新设置了参数)。在5.7中，提交的时候由UserThread负责日志落盘。在8.0中，则是由专门的线程负责，如下图：

![image-20190906174825675](/image/mysql-8-redo/logbuffer-8.png)

+ **log_writer**：原来是由UserThread驱动的，每次将整个LogBuffer写出；现在只要LogBuffer中有数据可以写，专门的log_writer线程不断地将日志记录write到pagecache中；为了避免覆盖不完整的block，每次写都是写一个完整的block；同时更新write_lsn。

  ![image-20191016180843535](/image/mysql-8-redo/log-writer.png)

+ **log_flusher**：log_flusher不断的读取write_lsn，然后调用`fil_flush_file_redo`将日志落盘，同时更新flushed_to_disk_lsn。这样log_flusher和log_writer按照各自的速度同时运行，除了系统内核中的同步外（write_lsn的原子读写），没有同步操作。

+ **log_flush_notifier**：之前提交的时候，当前线程需要确认LogBuffer已经fsync到哪个位置，如果没有，就将LogBuffer落盘，然后等待；

  ![image-20190909203252074](/image/mysql-8-redo/log_flush_notifier.png)

  而现在用户线程提交的时候，会检查flushed_to_disk_lsn是否足够，如果不够，那么等待某个flush_events。如上图，这里的flush_event按照lsn的区间分成不同的块（默认**INNODB_LOG_EVENTS_DEFAULT**个），并可以循环利用；这样flushed_to_disk_lsn推进一块，就可以通知一部分线程commitOK，提高整体的扩展性，如下图。
  
  另外，如果你只关心write，那么就是由另一个log_write_notifier来通知，相应的用户线程等待write_events事件。
  

> 由于等待事件然后被唤醒的延迟高，这里默认使用spin-loop进行自旋等待。但是为了避免提高系统的CPU代价，添加了**innodb_log_spin_cpu_abs_lwm**和**innodb_log_spin_cpu_pct_hwm**参数来控制CPU代价。

## *写出FlushList：dirtyPage flush*

通过将脏页刷盘，可以将CHECKPOINT-LSN向前递进，从而回收redo日志。CHECKPOINT是由UserThread或者MasterThread来触发写。

8中，由一个专有线程log_checkpointer来负责CHECKPOINT操作，log_checkpointer根据多种条件，来决定写入下一个CHECKPOINT。

checkpoint LSN除了和上述提到的last_lsn - recent_closed.capacity（buffer中的最老修改）相关外，还和 recent_closed.tail() （flushlist中保证连续的lsn位置）以及logbuffer的flushed_to_disk_lsn（要保证日志先于数据刷盘）。

# 总结与思考

MySQL8中，日志的基本结构和原来一样；但是在整个处理流程上充分地异步处理了。其中，通过若干event将各个线程同步起来，有如下几个：

按lsn分区的事件：

- write_events：当innodb_flush_log_at_trx_commit=2时，通知相应的用户线程其等待的lsn已经write。
- flush_events：当innodb_flush_log_at_trx_commit=1时，通知相应的用户线程其等待的lsn已经flush。

通知对应线程的启动的事件：

+ writer_event
+ write_notifier_event
+ flusher_event
+ flush_notifier_event
+ closer_event
+ checkpointer_event

大致流程如下图：

![image-20190910162425005](/image/mysql-8-redo/events.png)

mtr提交时，首先通过prepare_write得到最终要写入的日志长度，分为5步：

0. `log_buffer_reserve`：等待recent_written的空间，预留logbuffer的空间，如果空间不够，会调用log_write_up_to清理LogBuffer空间；log_write_up_to通过设置writer_event，异步触发log_writer写。
1. `write_log`：将m_log的内容memcpy到LogBuffer中，然后在**recent_written**加一个link。
2. `log_wait_for_space_in_log_recent_closed`：等待recent_closed的空间
3. `add_dirty_block_to_flush_list`：将该mtr对应的脏页添加到flushlist中
4. `log_buffer_close`：在**recent_closed**中加一个link。

log_writer等线程等待各自的event，然后开始进行处理。

## recovery

`mtr_commit`会将该mtr对应的脏页添加到flush_list中，并在recent_closed中记下[start_lsn, end_lsn]，recent_closed会维护一个tail位置，tail_lsn之前的是连续的区间段。

```c++
buf_flush_insert_into_flush_list(buf_pool, block, start_lsn);
```

flush_list中的dirty page的oldest_modify_lsn会记下mtr.start_lsn。然后，log_closer会不断的向前推进recent_closed的tail。

当需要做checkpoint时，checkpoint_lsn会根据recent_closed的tail_lsn进行取舍；在5.7中是取出flush_list中min(oldest_modify_lsn)；但是在8中，由于flush是非顺序添加的，min(oldest_modify_lsn)之前会有一些dirty page还未添加进来。但是乱序的最大区间就是recent_closed.size()。因此，安全的checkpoint_lsn可以用`min(oldest_modify_lsn)-recent_closed.size()`。

但是，这带来一个问题，`min(oldest_modify_lsn)`一定是某个mtr的start_lsn，但是`min(oldest_modify_lsn)-recent_closed.size()`就不一定了，有可能会执行某个logrecord group的[start_lsn, end_lsn]之间。这样在恢复时，就不能从checkpoint_lsn点进行恢复。

假如checkpoint_lsn指向了某个区间的中间，那么当前区间对应的dirtypage必然是落盘了（current_start_lsn < checkpoint_lsn），因此，解决办法就是找到**>=checkpoint_lsn的第一个logrecord group**（即，某个mtr的start_lsn）。

# 参考文献

[MySQL 8.0: New Lock free, scalable WAL design](https://mysqlserverteam.com/mysql-8-0-new-lock-free-scalable-wal-design/)

[code of mysql8](https://github.com/mysql/mysql-server)


