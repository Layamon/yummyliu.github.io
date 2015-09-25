---
layout: post
title: RocksDB Q&A
date: 2020-07-28 20:39
categories:
  - RocksDB
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
RocksDB的写入基于batch为单位，每个batch中有若干KV操作数据，本文主要针对落盘前的逻辑进行梳理，包括：

1. WritePath：从WriteBatch到SstTable，这经历了什么？
2. Sequence Assign：WriteBatch中的Key怎么分配的SequenceNumber？

# From Batch To Disk

<img src="/image/rocksdb-writeimpl/writebatch-dataflow.png" alt="image-20200729095202413" style="zoom:50%;" />

首先应该知道WriteBatch，物理上就是一个连续的字符流，其中的数据包含多个CF；WriteBatch会完整的写入WAL，此时头部就带上了SequenceNumber。而后续写MemTable的时候，就得按CF分开了。

## Group Write

为了提高整体的写入吞吐，每个Batch写入时包装为一个Writer，WriteBatchInternal的带cfid的Put，只是将cfid放在key前面，默认是0；便于后面读出来进行MemTable插入。

## Pipeline Write

enable_pipelined_write和concurrent_prepare(two write queue)不兼容

而如果enable_pipelined_write打开，那么对于WAL和MemTable分别有一个队列，某write_thread提交的时候，先入wal队，后入MemTable队。这样wal的写盘只需要等待前一个group的WAL落盘，而不需要等待前一个group的WAL和MemTable都落盘。

> JoinBatchGroup：加入到某group中，如果不是leader就在此等待leader设置自己的状态。

1. write_thread_.JoinBatchGroup(&w); 将当前的w加入到组提交中，根据返回的状态分别处理自己的阶段的任务
   1. 如果返回的是STATE_PARALLEL_MEMTABLE_WRITER，写MemTable
   2. STATE_GROUP_LEADER，负责写该group的batch到WAL和MemTable，只不过会根据判断`write_thread_.LaunchParallelMemTableWriters` 唤醒其他write_thread写自己的MemTable。

disableWAL，基于另一个专门的group 队列，进行WAL的group write

nonmem_write_thread_.JoinBatchGroup



enable_pipelined_write

依然是group write，只不过分为两个阶段注册group。为保证MemTable的插入顺序和WAL一直，当某个wal group完成后，会将该group 的thread注册到当前的newest_memtable_writer_后

```cpp
    // Link the remaining of the group to memtable writer list.
    //
    // We have to link our group to memtable writer queue before wake up the
    // next leader or set newest_writer_ to null, otherwise the next leader
    // can run ahead of us and link to memtable writer queue before we do.
    if (write_group.size > 0) {
      if (LinkGroup(write_group, &newest_memtable_writer_)) {
        // The leader can now be different from current writer.
        SetState(write_group.leader, STATE_MEMTABLE_WRITER_LEADER);
      }
    }
```

当某writethread成为STATE_MEMTABLE_WRITER_LEADER后，会判断是否可以parallel，通过write_thread_.LaunchParallelMemTableWriters唤醒follower并行写自己的MemTable。



```
PipelineWriteImpl is an alternative approach to WriteImpl. In WriteImpl, only one thread is allow to write at the same time. This thread will do both WAL and memtable writes for all write threads in the write group. Pending writers wait in queue until the current writer finishes. In the pipeline write approach, two queue is maintained: one WAL writer queue and one memtable writer queue. All writers (regardless of whether they need to write WAL) will still need to first join the WAL writer queue, and after the house keeping work and WAL writing, they will need to join memtable writer queue if needed. The benefit of this approach is that
1. Writers without memtable writes (e.g. the prepare phase of two phase commit) can exit write thread once WAL write is finish. They don't need to wait for memtable writes in case of group commit.
2. Pending writers only need to wait for previous WAL writer finish to be able to join the write thread, instead of wait also for previous memtable writes.
```



## Flush

SwitchMemtable：WAL与MemTable强绑定，只要有一个MemTable执行flush后，就换一个新的WAL；之后的数据继续写其他MemTable和新的Wal，wal没有上限，但是MemTable有上限。

SwitchMemTable只是创建一个新的MemTable，并不主从flush ，而是在最后`InstallSuperVersionAndScheduleWork`中，判断是否需要Flush(**仅仅是trigger**)；但是这里肯定会flush当前的wal，并创建一个新的wal。

```c++
// Attempt to switch to a new memtable and trigger flush of old.  
// Alway flush the buffer of the last log before switching to a new one
```



DBWriteImpl每次调用创建一个Writer，后续对这些Writer进行group 或pipeline。每个Writer负责将自己的的writebatch写到 wal和mem中。

1. 构造一个FlushJob，然后PickMemTablesToFlush：
   - cfd从 imm中找需要Flush的memtable，每个MemTable持有自己的edit，MemTable flush 为l0 file后，将l0fil meta加入到自己的edit中
2. FLushJob.run : WriteLevel0File
   1. BuildTable
   2. 将meta和blob meta加到edit中。
3. TryInstallMemtableFlushResults：
   - 将新的File Install到VersionSet中，一次FLush可能会刷多个MemTable，每个MemTable有一个自己的edit，因此这里VersionSet是将一个edit_list进行LogAndApply

LogAndApply中对于每个cfd，构造一个Manifest Writer；最终调用ProcessManifestWrites：

1. 判断是否有CF的变更，这和CF的atomic相关，需要做一些处理；最终准备好 builder_guards，可认为是version build的一些job，里面有需要的结构：
   - edit
   - version
   - versionbuilder
2. DoApplyAndSaveTo versionstorage
3. 写MANIFEST -log
4. 调callback

### log to keep

由上，log对应的memtable unflush，那么其log::writer 会一直保留在log_ 或 logs_to_free_中。

```
uint64_t DBImpl::MinLogNumberToKeep() {
  if (allow_2pc()) {
    return versions_->min_log_number_to_keep_2pc();
  } else {
    return versions_->MinLogNumberWithUnflushedData();
  }
}
```



# Sequence Assign





> ```
>   const bool use_batch_per_txn =
>       txn_db_options.write_policy == WRITE_COMMITTED ||
>       txn_db_options.write_policy == WRITE_PREPARED
> ```
>
> 这里假设`batch_per_trx=true`

RocksDB的Lsm-tree中的Internalkey都带有一个SequenceNumber，这个Seq是由VersionSet生成的。但是在VersionSet中，有三个seq

last_sequence <= last_published_sequence_ <=  last_allocated_sequence_

- last_sequence: 用户可见的Sequence
- 

rocksdb的write会通过queue将writer进行排队，队列中的`writer->batch`会写到wal和MemTable（都是可选的），为了优化写入速度，又加了一个额外的queue（通过参数`two_write_queue`打开），这个queue只写WalOnly的batch，走`WriteImplWALOnly`逻辑。这里分别称这两个queue为：main queue(下称mq)/walonly queue(下称wq)。

> mq维护了last_sequence，wq维护了last_published_queue，

last_publish_back只有在seq_per_batch=true，即使事务用WritePrepare的方式，并且打开two_write_queue时才有效，否则等于last_seq

```
      // last_sequence_ is always maintained by the main queue that also writes
      // to the memtable. When two_write_queues_ is disabled last seq in
      // memtable is the same as last seq published to the readers. When it is
      // enabled but seq_per_batch_ is disabled, last seq in memtable still
      // indicates last published seq since wal-only writes that go to the 2nd
      // queue do not consume a sequence number. Otherwise writes performed by
      // the 2nd queue could change what is visible to the readers. In this
      // cases, last_seq_same_as_publish_seq_==false, the 2nd queue maintains a
      // separate variable to indicate the last published sequence.
      last_seq_same_as_publish_seq_(
          !(seq_per_batch && options.two_write_queues)),
```

WritePrepares Txn通过PrereleaseCallBack，在写完Wal后，更新last_published_queue(见WriteWalOnly)，

mq的逻辑是，先写wal，其中通过FetchAddLastAllocatedSequence递增`last_allocated_sequence_`，新的MemTable机遇`last_allocated_sequence_+1`写mem（等于MemTable对应的batch持久化到日志中的Sequence，这个如果是WriteCommit的事务，这个Batch就是commit_time_batch，将prepare_batch append到waltermpoint之后得到的）。这样确保Batch与MemTable的Sequence能对上。

在MemTableInserter中，如果是默认的seq_per_key，那么每个key自行递增seq；而如果开启了seq_per_batch，那么基于batch_boundary进行seq递增（但是这里需要处理duplicate key的问题，这里引入了一个sub-patch的概念，表示WritBatch的一个没有重复key subset）

```
  // batch_cnt is expected to be non-zero in seq_per_batch mode and
  // indicates the number of sub-patches. A sub-patch is a subset of the write
  // batch that does not have duplicate keys.
```



l  // the individual batches. The approach is this: 1) Use the terminating
  // markers to indicate the boundary (kTypeEndPrepareXID, kTypeCommitXID,
  // kTypeRollbackXID) 2) Terminate a batch with kTypeNoop in the absence of a
  // natural boundary marker



```
  // batch_cnt is expected to be non-zero in seq_per_batch mode and indicates
  // the number of sub-patches. A sub-patch is a subset of the write batch that
  // does not have duplicate keys.
```



```cpp
// Note: the logic for advancing seq here must be consistent with the
// logic in WriteBatchInternal::InsertInto(write_group...) as well as
// with WriteBatchInternal::InsertInto(write_batch...) that is called on
// the merged batch during recovery from the WAL.
for (auto* writer : write_group) {
  if (writer->CallbackFailed()) {
    continue;
  }
  writer->sequence = next_sequence;
  if (seq_per_batch_) {
    assert(writer->batch_cnt);
    next_sequence += writer->batch_cnt;
  } else if (writer->ShouldWriteToMemtable()) {
    next_sequence += WriteBatchInternal::Count(writer->batch);
  }
}
```
