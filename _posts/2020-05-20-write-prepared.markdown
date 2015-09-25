---
layout: post
title: RocksDB的事务写策略
date: 2020-05-20 15:20
categories:
  - MyRocks
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
> 和TransactionDB数据相关的有两个变量，一个是seq和batch绑定，一个是batch和trx绑定。由于目前WriteUnprepare还不可用，暂时我们假设batch与trx有一一对应关系。
>
> ```c++
>   const bool use_seq_per_batch =
>       txn_db_options.write_policy == WRITE_PREPARED ||
>       txn_db_options.write_policy == WRITE_UNPREPARED;
>   const bool use_batch_per_txn =
>       txn_db_options.write_policy == WRITE_COMMITTED ||
>       txn_db_options.write_policy == WRITE_PREPARED
> ```

RocksDB的事务系统是在已有的KV引擎的基础上封装而来的，事务的隔离主要利用其本身的SequenceNumber来实现，因此在了解RocksDB的事务之前，有必要对SequenceNumber有一定的认识。（verion 5.18）

# SequenceNumber

RocksDB的Lsm-tree中的Internalkey都带有一个SequenceNumber，这个Seq是在VersionSet全局生成的，并记录在每个batch的头部，我们称这些batch为SequencedBatch。上面我们暂定trx与batch有一一对应关系，但是trx中的key与batch的seq并不一定是一一对应的，对于TransactionDB，WriteCommited的方式是seq_per_key，WritePrepared是seq_per_batch，参见[MaybeAdvanceSeq](https://github.com/facebook/rocksdb/blob/641fae60f63619ed5d0c9d9e4c4ea5a0ffa3e253/db/write_batch.cc#L1162)。

但是在VersionSet中，有三个seq：*last_sequence <= last_published_sequence_ <=  last_allocated_sequence_*。这三个seq概念的区分与WritePrepared相关，后面解释。

# WritePolicy

## WriteCommited

RocksDB通过SequenceNumber向上返回某个Key最新的数据，而RocksDB的TransactionDB同样基于SequenceNumber来做事务隔离。默认地，当WriteBatch的数据，写入Wal后（即Commit），才写入memtable，这样LSM-tree中都是已提交的数据。那么，事务的隔离级别就取决于何时获取SnapShot。

如上流程，而我们发现，WAL的写入必须在MemTable之前，那么事务的提交路径就会成串行的，如下：

1. 写WriteBatch
2. WriteBatch执行Prepare
3. WriteBatch执行Commit

<img src="/image/write-prepared/2pc-rocksdb.png" alt="image-20200522101817407" style="zoom:50%;" />

首先我们假设在use_batch_per_txn，为了支持2PC，在WriteBatch中，添加了事务相关的控制信息：Prepare(xid)/EndPrepare()/Commit(xid)/Rollback(xid)，标记了对应事务的状态。

由于一个事物的写分成两阶段，那么会对应两个batch；并且进而事务相关的数据与batch的seq相关，取决于下面讨论的Writepolicy不同，数据的seq(下称data-seq)可能是commit-seq也可能是Prepare-seq。而判断可见性，需要比较的是 snapshot-seq与该事务的commit-seq的关系，即**判断data-seq对应的commited_seq是否小于snapshot_seq**。

RocksDB的2PC写入策略默认是WriteCommited，此时data-seq就是commit-seq：

1. Prepare：此时只写日志，WriteImpl会在日志中插入meta marker——Prepare(xid)和EndPrepare()；如上图淡蓝色部分（改数据不存在与WriteBatch中，只是在调用相关接口时才追加到log中）。
2. 提交or回滚
   1. Commit：同样基于WriteImpl对象，此时日志中追加Commit(xid)标记，同时通过MemTableInserter将WriteBatch中的数据写入到对应CF的MemTable中。
   2. Rollback：此时清空WriteBatch中的数据，同时基于WriteImpl在日志中标记Rollback(xid)。

> two_write_queues
>
> [原来叫concurrent_prepare](https://github.com/facebook/rocksdb/commit/857adf388fd1de81b8749bf1e5fe20edf6f8a8c8)，表示在prepare阶段可以并行写wal([见这](https://github.com/facebook/rocksdb/pull/2345#discussion_r122407559))，即调用[ConcurrentWriteWAL](https://github.com/facebook/rocksdb/pull/2345#discussion_r122474277)：该函数有点歧义。
>
> 主要就在这个提交中：https://github.com/facebook/rocksdb/pull/2345/files

WriteCommited方式的事务提交，MemTable中的都是提交的数据，判断事务可见性逻辑简单；但是commit阶段需要做的事情太多，成为系统吞吐瓶颈。因此，RocksDB提出了WritePrepared的写入策略，带来的复杂性主要是判断数据记录（record）的可见性复杂了。

## WritePrepared

此时data-seq就是Prepare-seq，为了**判断prepare-seq对应的commited_seq是否小于snapshot_seq**。此时需要保存<prepare-seq，commit-seq>的信息，空间是有限的，不可能全部记录状态；因此基于不同的数据结构在有限空间下解决这个问题。(version 5.18)

- **PreparedHeap prepared_txns_**：暂存还uncommitted的Prepare-seq，事务提交时删除，见[WritePreparedTxnDB::RemovePrepared](https://github.com/Layamon/terarkdb/blob/668b7e5e83bdce27f863da59a13e2baacde48399/utilities/transactions/write_prepared_txn_db.cc#L444)。

- **commit_cache_**：固定大小的数组，并且设计为[lock free commit cache](https://github.com/facebook/rocksdb/wiki/WritePrepared-Transactions#lock-free-commitcache)。事务提交时，将<prepare-seq, commited-seq>记录到该结构，见[AddCommited](https://github.com/Layamon/terarkdb/blob/668b7e5e83bdce27f863da59a13e2baacde48399/utilities/transactions/write_prepared_txn_db.cc#L406)。

  该结构可认为是一个滑动窗口，缓存该窗口下的<prepare-seq,commit-seq>信息。prepare-seq是通过取模的方式添加到cache中，如果放不进去，就需要推进`max_evicted_seq_`。

上面两个不是无限大的，对于一些不常发生的大事务，采用专门的结构单独存储，这样解决空间问题。

- std::set<uint64_t> delayed_prepared_：对应prepareheap的溢出，通常应该是empty，除非有long running trx，此时会报**Warning**(prepared_mutex_ overhead)。

  当`max_evicted_seq_`推进时，如果ps还在`prepared_txns_`中，将其从`prepared_txns_`转移到`delayed_prepared_`中，见[AdvanceMaxEvictedSeq](https://github.com/Layamon/terarkdb/blob/668b7e5e83bdce27f863da59a13e2baacde48399/utilities/transactions/write_prepared_txn_db.cc#L489)

- old_commit_map_：对应commit_cache的溢出，一般这个情况很少发生，除非发起了一个较大的读事务，比如备份，这时日志里会有如下类似的**Warning** : old_commit_map_mutex；

  因为`max_evicted_seq_`推进时，某个获取SnapShot的长事务持有了**从Commit cache中请出但未提交的prepare seq**，将相应<snapshot seq, prepared seq>加到map中，这样不会导致该SnapShot看见不该看见的东西，见函数[`CheckAgainstSnapshots`](https://github.com/Layamon/terarkdb/blob/668b7e5e83bdce27f863da59a13e2baacde48399/utilities/transactions/write_prepared_txn_db.cc#L672)。

<img src="/image/write-prepared/structures.png" alt="image-20200711171439816" style="zoom: 50%;" />

### 三个SequenceNumber

一开始，写入MemTable的key都是用户可见，其Sequence就是**last_sequence**；后来引入了WritePrepared策略，MemTable中会存在只是Prepared的key，其Sequence对用户不可见；并且为了优化WritePrepare，加了一个参数two_write_queue。

### `two_write_queue`

> two write queue，原名叫 [concurrent_prepare](https://github.com/facebook/mysql-5.6/pull/763)，主要是针对writePrepared的事务的优化，在prepare阶段写MemTable的同时，可以[ConcurrentWriteToWAL](https://github.com/facebook/rocksdb/commit/63822eb761a1c45d255e5676512153d213698b7c)的写WalOnlyBatch

rocksdb的write会通过queue将writer进行排队，队列中的`writer->batch`会写到wal和MemTable。对于2PC的Transaction，为了优化写入速度，又加了一个额外的queue，这个queue只写WalOnly的batch，走`WriteImplWALOnly`逻辑。这里分别称这两个queue为：main queue(下称**mq**)/walonly queue(下称**wq**)。mq维护了**last_sequence**，wq维护了**last_published_queue**，

mq的逻辑是，先写wal，其中通过FetchAddLastAllocatedSequence递增`last_allocated_sequence_`，新的MemTable基于`last_allocated_sequence_+1`写mem（等于MemTable对应的batch持久化到日志中的Sequence，这个如果是WriteCommit的事务，这个Batch就是commit_time_batch，将prepare_batch append到waltermpoint之后得到的）。这样确保Batch与MemTable的Sequence能对上。

而当引入`two_write_queue`后，Prepare阶段将数据写入MemTable后，Commit阶段就是WALOnlyBatch；WalOnlyBatch写完后，WritePrepares Txn通过PrereleaseCallBack，更新**last_published_sequence**，其Sequence用户就是可见的了。

> 在MemTableInserter中，如果是默认的seq_per_key，那么每个key自行递增seq；而如果开启了seq_per_batch，那么基于batch_boundary进行seq递增（但是这里需要处理duplicate key的问题，这里引入了一个sub-patch的概念，表示WritBatch的一个没有重复key subset）。

三个Sequence的总结就是：

+ last_sequence_：一般情况的用户可见的Sequence

+ last_published_sequence_：

  在seq_per_batch=true，即事务用WritePrepare的方式，并且打开two_write_queue时才有效，见

  [last_seq_same_as_publish_seq](https://github.com/facebook/rocksdb/blob/641fae60f63619ed5d0c9d9e4c4ea5a0ffa3e253/db/db_impl.cc#L212)

  - 此时也会启用 last_allocated_sequence_，在WAL中的记录都会有一个Sequence，但这些Seq不一定在MemTable中。

## Write Unprepared

WriteUnprepare与之前最大的不同就是use_batch_per_txn，在WriteUnprepared的事务中，会有多个batch；一个事务对应一批unprep_seq。

> 暂时该模式还未完成，这里只是基于Wiki简单了解一下。

概述

- ReadCallback
  - 对已经写入到Version内的key，进行snapshot check
- RollBack Algo
  - 将事务内修改的key的旧值与trx绑定，trx取消更方便
  - 以提交的方式回滚事务，可重用现有的live snapshot的检查

- TransactionLockMgr
  - 自动将集中的key lock，升级为range lock。

-------------

操作

- Put：Transaction负责维护写到version中的unprepared_batch，并且也有一个类似prepare_head的unprepared_heap。

- Prepare：[BeginUnprepareXID]...[EndPrepare(XID)] ... [BeginUnprepareXID]...[EndPrepare(XID)] ... [**BeginPersistedPrepareXID**]...[EndPrepare(XID)] ... ...[**Commit**(XID)]

  WriteUnprepared可以从WritePrepare生成的WAL的结构恢复，反之则否。

- Commit：为了可见性判断，这里需要维护多个unprepare_seq->commit_seq的映射。同样cache驱逐的时候，需要全部删除

- RollBack：WritePrepare的回滚流程就是，基于prepare-seq的快照，获取原来的数据，然后取一个新的rollback-seq，数据写到db中。

  当需要回滚某个prepare-seq时，如果一个live snapshot seq持有prepare-seq，按理说Prepare-seq对snapshot-seq是不可见的。但是max_evict_seq的推进，如果prepare-seq没有提交，在删除commit-cache的同时、会向old_commit_map中记<snapshot-seq，prepare-seq>信息，这些不是原子的，见[AddCommitted](https://github.com/Layamon/terarkdb/blob/668b7e5e83bdce27f863da59a13e2baacde48399/utilities/transactions/write_prepared_txn_db.cc#L400)。如果此时有live-snapshot就会看到不一致的状态，即prepare-seq就变成对snapshot-seq可见的了；好在MyRocks只在Recovery的时候进行回滚操作，规避了这一问题。

  而在WriteUnprepared的时候，运行时，就会对unprepare-batch进行rollback；这里的rollback，会写一个rollback marker的数据，将其commit到db中；这样假装提交了事务，这期间发起的snanshot，根据已有的逻辑，从commit-cache中取出提交信息，判断prepare-seq<snapshot-seq<commit-seq，发现不可见；而在Recover的时候，判断rollback marker来进行rollback。

- Get：Get的不同就是在读取本事务自己的数据上，由于现在不止一个batch，而是一堆unprep-seq；
- Recovery：需要收集同一个XID对应的unprepare-batch，知道找到EndPrepared(XID)标记；
  - 没找到EndPrepared，那么该事务就隐式rollback了
  - 找到EndPrepred，继续找之后的rollback marker/commited marker来处理事务。
    - 没找到，事务状态为Prepared
    - 找到rollback marker，Rollbacked
    - 找到commited marker，Commited

# Questions

1. 进行可见性判断的时候，snapshot可能无效了：[snapshot release](https://github.com/facebook/rocksdb/commit/f3a99e8a4de2b0147df83344463eb844d94a6a35)

2. include delayed_prepared_ in min_uncommitted

> 关于"TODO(myabandeh): include delayed_prepared_ in min_uncommitted" (已经fix了)
>
> `prepared_txns_.top`不能保证是当前最小未提交的seq，`min_uncommitted_获取的实际的逻辑是：
>
> ```cpp
>    return std::min(prepared_txns_.top(),
>                    db_impl_->GetLatestSequenceNumber() + 1);
> ```
>
> 并没有考虑delay_prepared_的数据，而是在后续IsInSnapShot进行可见性判断的时候再检查，见[IsInSnapShot](https://github.com/Layamon/terarkdb/blob/668b7e5e83bdce27f863da59a13e2baacde48399/utilities/transactions/write_prepared_txn_db.h#L161)。
>
> 在`IsInSnapshot`，判断一个prep_seq标记的Record对snapshot_seq标记的snapshot是否可见。
>
> 由于min_uncommited的计算没有依赖delay_prepared_中的数据，如下，因此在判断prep_seq与min_uncommited关系之前，需先确认prep_seq不在delayed_prepared\_之中
>
> ```cpp
> // Note: since min_uncommitted does not include the delayed_prepared_ we
> // should check delayed_prepared_ first before applying this optimization.
> // TODO(myabandeh): include delayed_prepared_ in min_uncommitted
> if (prep_seq < min_uncommitted) {
> ```
>
> 首先判断获取snapshot的时候prep_seq是否提交的依据是：prep_seq不在delayed_prepared\_中并且prep_seq不在prepared_txns。
>
> + 获取snapshot的时候，`prep_seq`不在`prepared_txns`中，通过`snapshot->min_uncommited`判断；
>
> + 获取snapshot的时候，`prep_seq`不在`delayed_prepared`\_中，则没办法判断；因为`delayed_prepared_`是不断变化的，并且 **min_uncommitted does not include the delayed_prepared\_**。
>
> 那么，如果存在长事务（seqno = s1）在获取snapshot时未提交，并且已经被evict到delay中；那么**snapshot->min_uncommited = prepared_txn.top > s1**；
>
> 而后来在`IsInSnapshot`之前提交了，则移出delay；那么对于s1标记的record，满足**不在`delayed_prepared`\_中**且**s1 < min_uncommited**，则该snapshot误认为该record可见。