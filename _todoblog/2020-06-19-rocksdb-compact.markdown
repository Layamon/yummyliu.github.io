---
layout: post
title: RocksDB的Compaction
date: 2020-06-19 14:25
categories:
  - rocksdb
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}

# Compact

相比Btree类型的存储引擎，RocksDB不是in-place-update（in-place-update需要修改当前数据，则可能需要IO），写入直接写入一个新的记录；但是也正是因为不in-place-update，就存在空间膨胀的问题；就需要进行空间收缩；

Compact就是处理空间放大和读放大的任务，是lsm-tree的一个关键操作，Compaction主要作用是回收旧版本并清理已删除的数据；

rocksdb默认的策略是Leveled Compaction，用在sst file compact中；但是不同层触发条件不同：

+ level0（number of files）：唯一一层允许sstfile的keyrange有overlap，基于该层文件个数`level0_file_num_compaction_trigger`触发。

  > 为什么level0基于文件数触发？如果key有很多overwrite、delete那么单个level0文件大小可能很小，如果此时基于bytes限制，0层会有很多文件；level0是最热的层，如果0层文件过多，read的时候需要读更多的文件；

+ others（number of bytes）：整层的文件总大小，这里RocksDB进行了优化，层大小基于最底层向上推导[`level_compaction_dynamic_level_bytes`](https://github.com/facebook/rocksdb/blob/v3.11/include/rocksdb/options.h#L366-L423)。

> **L0->L1的瓶颈点优化**
>
> 其实我们可以发现，由于L0的key是重叠的，那么L0到L1的Compact不能并发进行；这里通过**subCompaction**进行优化，即，先收集文件信息，将单个文件按offset进行分割，最后每个range交由一个subCompact进行处理。
>
> 见`ShouldFormSubcompactions`决定是否将当前的compact划分成 Sub-Compaction。

## Compaction Priority

> Which file to pick to compact?

```cpp
// In Level-based compaction, it Determines which file from a level to be
// picked to merge to the next level. We suggest people try
// kMinOverlappingRatio first when you tune your database.
enum CompactionPri : char {
  // Slightly prioritize larger files by size compensated by #deletes
  kByCompensatedSize = 0x0,
  // First compact files whose data's latest update time is oldest.
  // Try this if you only update some hot keys in small ranges.
  kOldestLargestSeqFirst = 0x1,
  // First compact files whose range hasn't been compacted to the next level
  // for the longest. If your updates are random across the key space,
  // write amplification is slightly better with this option.
  kOldestSmallestSeqFirst = 0x2,
  // First compact files whose ratio between overlapping size in next level
  // and its size is the smallest. It in many cases can optimize write
  // amplification.
  kMinOverlappingRatio = 0x3,
};
```

RocksDB常用的Compact方式是level Compact；这是基于LevelDB演变而来的。LevelDB只有一个Compact线程，并且采用简单的round-robin方式；RocksDB可以基于上述[四种策略](https://rocksdb.org/blog/2016/01/29/compaction_pri.html)进行选择，并构造对应的Job交给线程池执行。

+ kByCompensatedSize：（default）优先选择sst中delete marker更多的文件，更快的收缩空间。
+ kOldestLargestSeqFirst：工作集比较小，频繁更新一些hot key；

### Score

算出每层的分数，最后冒泡排序，将score大的放在前面；得到`compaction_score_`数组。

#### level0

0层是基于文件数触发，首先统计文件数；得到备选score

```cpp
static_cast<double>(num_sorted_runs) / mutable_cf_options.level0_file_num_compaction_trigger;
```

但是也不能超过`max_bytes_for_level_base`，

```cpp
static_cast<double>(total_size) / mutable_cf_options.max_bytes_for_level_base;
```

于是最终的score是两者的max

#### other level

根据参数`level_compaction_dynamic_level_bytes`，决定`level_max_bytes_[]`的大小；从而决定每层score的分母。

## CompactFilter

在rocksdb的Compact中，值得一提的是——在过滤数据的时候，可以定义Compaction filter，按照用户定义的逻辑，进行数据整理，比如删除过期（过期时间自定义）数据，转换数据内容等等；Compactfilter的实现主要有三个接口：

+ Filter

+ FilterMergeOperand

+ FilterV2：返回Decision对象，允许更改value，前两者只是返回是否过滤的bool；

  ```cpp
    enum class Decision {
      kKeep,
      kRemove,
      kChangeValue,
      kRemoveAndSkipUntil,
    };
  ```

Compact filter只对普通value类型（未标记上delete mark）调用，对于merge类型，会在执行merge operator前调用Compaction filter。flush可看作是一种特殊的Compact，但flush不会调用Compaction filter。

https://github.com/facebook/rocksdb/wiki/Choose-Level-Compaction-Files

## SubCompact

将一个CompactJob切分为不同的subcompact，这样可以并发执行；

+ L0->L1的compact不能并行，只能通过subcompact的方式并行。
+ manual compact不能并行，只能通过subcompact的方式并行。
+ Universal Compact的合并类似于L0->L1，不能并行。那么除了L0->L0之外的Compact job采用subcompact的方式

[这里](https://github.com/facebook/rocksdb/wiki/Sub-Compaction)对执行的方法有简单描述：

1. 根据输入sst，确定各个区间边界
2. 基于`Versions::ApproximateSize`计算每个区间的大小；
3. 算出平均大小后，合并区间使每个区间的大小约等于平均值。



Version类似于checkpoint的概念，不断向前推进，这样旧version可以安全删除。

LogAndApply

1. 基于传入的cfd和edit，构造ManifestWriter

1. VersionSet::ProcessManifestWrite，传入ManifestWriter，逐个执行

1. 1. 基于一堆ManifestWriter的cfd，构造一批BaseReferencedVersionBuilder（取出cfd的current，并引用，析构时释放）

1. 1. 逐个调用BaseReferencedVersionBuilder::DoApplyAndSaveTo

1. 1. 1. N次 version_builder->Apply

1. 1. 1. 1次 version_builder->SaveTo