---
layout: post
title: 
date: 2020-07-28 20:39
categories:
  -
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
![image-20200729095202413](/image/rocksdb-writeimpl/writebatch-dataflow.png)

# WritePath

db_write_impl将write_batch写入到wal和memtable中。采用group commit的方式写。db中有一个writer_thread的队列，队列头部就是group leader，负责将队列中所有的batch写入到WAL和MemTable中；不管怎么写，writewal总是在memtableinsert之前，

SwitchMemtable：WAL与MemTable强绑定，只要有一个MemTable执行flush后，就换一个新的WAL；之后的数据继续写其他MemTable和新的Wal，wal没有上限，但是MemTable有上限。



WriteBatchInternal的带cfid的Put，只是将cfid放在key前面，默认是0；便于后面读出来进行MemTable插入。



SwitchMemTable只是创建一个新的MemTable，并不主从flush ，而是在最后`InstallSuperVersionAndScheduleWork`中，判断是否需要Flush(**仅仅是trigger**)；但是这里肯定会flush当前的wal，并创建一个新的wal。

```c++
// Attempt to switch to a new memtable and trigger flush of old.  
// Alway flush the buffer of the last log before switching to a new one
```





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



buildTable只是在FlushJob中用到，用来写Level0 sst



prefix extractor：在Option中提供一个方法，可以提取value的一部分数据，单独比较；这样可以做一些优化，比如：

- 如果定义了prefix extractor，那么seek的时候将只在prefix相关区间读取数据。如下代码片段，在迭代开始判断prefix和prefix_start_key是否相同，如果不同，直接退出。

- ```cpp
  
    do {
      if (!ParseKey(&ikey_)) {
        return false;
      }
    
      if (iterate_upper_bound_ != nullptr &&
          user_comparator_->Compare(ikey_.user_key, *iterate_upper_bound_) >= 0) {
        break;
      }
    
      if (prefix_extractor_ && prefix_check &&
          prefix_extractor_->Transform(ikey_.user_key)
                  .compare(prefix_start_key_) != 0) {
        break;
      }
  ```

- 

- 另外，在memtable中可以配置prefix extractor，如下，这样插入的时候可以根据prefix的hint，直接插入到指定位置，减少了比较。

- ```cpp
  
    // Extract sequential insert prefixes.
    const SliceTransform* insert_with_hint_prefix_extractor_;
    
    // Insert hints for each prefix.
    std::unordered_map<Slice, void*, SliceHasher> insert_hints_;
    ```


  ```

- 



​```cpp

uint64_t DBImpl::MinLogNumberToKeep() {
  if (allow_2pc()) {
    return versions_->min_log_number_to_keep_2pc();
  } else {
    return versions_->MinLogNumberWithUnflushedData();
  }
}
  ```

由上，log对应的memtable unflush，那么其log::writer 会一直保留在log_ 或 logs_to_free_中。





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























































writebatch中的jkey value都是lengthprefix的





SwitchMemTable中，只要当前log不空，那么就需要刷最后一个log，切换新的log

```cpp
bool creating_new_log = !log_empty_;
```



Memtable 之后的value就不带前面的prefix length了



rebuilding_trx_是为了支持recovery的时候，WAL中有prepare的恢复[commitlog](https://github.com/facebook/rocksdb/commit/1b8a2e8fdd1db0dac3cb50228065f8e7e43095f0)





[cached_recoverable_state_](https://github.com/facebook/rocksdb/commit/17731a43a6e6a212097c1d83392f81d310ffe2fa) 在2pc中，记一些专门在recover需要的信息，比如在MyRocks中。。。



LogAndApply

1. 基于传入的cfd和edit，构造ManifestWriter

1. VersionSet::ProcessManifestWrite，传入ManifestWriter，逐个执行

1. 1. 基于一堆ManifestWriter的cfd，构造一批BaseReferencedVersionBuilder（取出cfd的current，并引用，析构时释放）

1. 1. 逐个调用BaseReferencedVersionBuilder::DoApplyAndSaveTo

1. 1. 1. N次 version_builder->Apply

1. 1. 1. 1次 version_builder->SaveTo





1035

mysql bugs: https://github.com/mysql/mysql-server/commit/cbd87693248cb4d2a217a8f1c13108e3eca1ecff

如果称聚集索引的事务信息是行级的话（每一行都保存事务和回滚信息），那么，二级索引的事务信息就是页级的。数据页头中的PAGE_MAX_TRX_ID就是这个页级的事务ID，并且只有二级索引页有效。

每当事务修改某条二级索引记录时，都会修改当前页面的PAGE_MAX_TRX_ID的值。当一个读事务某二级索引记录时，InnoDB根据一定的算法，使用PAGE_MAX_TRX_ID和当前读事务ID来判断该记录是否不可见。如果不可见，再定位对应聚集索引来判断真实的可见性。



**索引键**：B+树的排序键，对于聚集索引就是主键，对于二级索引是二级索引键+主键



当我们有两个写请求队列（two_write_queues=true），那么主写队列可以同时向WAL和memtable写，而第二写队列只能写WAL，这个会被用于在WritePrepared事务中写提交标记。在这个场景下，主队列（以及他的PreReleaseCallback回调）总是用于准备项，而第二队列（以及他的PreReleaseCallback回调）总是用于提交。这样 i)避免两个队列的竞争 ii)维护了PreparedHeap的顺序增加，以及 iii)简化代码，避免并发插入到CommitCache（以及从中淘汰数据的代码）。