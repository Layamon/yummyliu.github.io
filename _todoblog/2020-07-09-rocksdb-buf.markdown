---
layout: post
title: RocksDB Overview(3)——Buffer Manager
date: 2020-07-09 21:00
categories:
  - rocksdb
typora-root-url: ../../layamon.github.io
---
> * TOC
{:toc}

逻辑上，RocksDB最小的粒度是KV对（`(userkey,seq,type) => uservalue`）；KV可逻辑上分成不同的ColumnFamily，这样不同分区可以分别写自己的MemTable和SST Table，但是共享同一个WAL；

ColumnFamily对应的kv放在CF专属的MEMTable和SSTFile中，而SSTTable与CF的关系维护在`Version`中。

> RocksDB保证**跨CF的的原子写**和**一致性读**快照，以及可以分别对不同CF进行挂载、删除与配置。

下图中省去了Index、BloomFilter、Block Cache和Column Family（下称CF）的概念，描述了RocksDB的IO路径：

![image-20200227180548341](/image/2020-0227-rocksdb-overview.png)

在RocksDB中，写事务提交时只需要保证LogRecord落盘即可；Data只需要复制到ActiveMemTable中，后续的数据落盘由FLush操作进行，然后后台进程Compact会不断对sstfile进行整理。

Btree结构的存储引擎通常将BtreePage放在buffer中，这样in-place-update的时候不需要每次都IO，也可以实现合并IO；而RocksDB只是不断的append数据，其Buffer更多的是起到类似batch的作用，收集一批数据后，再进行IO，同样可以合并IO。

> 虽然都合并IO，但是RocksDB一直就是append不存在随机写，而Btree发生miss的时候，还是需要随机写。

本文对RocksDB读写过程中涉及的Buffer与Cache进行介绍，了解RocksDB的IO过程。

# Buffer

**关于Page Cache**

在了解一个存储引擎的buffermanager之前，通常要先了解其对Page Cache的使用情况；这就一般就涉及是否使用DirectIO，文件如何读写的问题；RocksDB实现了一些ENV封装类—— `FileReader/FileWriter`。

RocksDB的文件都是append的，通过配置参数`bytes_per_sync`(SST)和`wal_bytes_per_sync`（WAL)，使得在写一定数据量脏数据后，调用`sync_file_range`进行文件部分sync。

还可配置 `rate_limiter`，控制刷盘速度，避免影响线上查询。

如果使用DIO或者文件系统没有page cache，打开`writable_file_max_buffer_size`，这是一个rocksdb自己的文件缓存区。

## WriteBatch

将一批put/delete/merge打包，最后再通过`DBImpl::Write`写入memtable中。

<img src="/image/rocksdb-buf/writebatch.png" alt="image-20200715105542200" style="zoom:50%;" />



## WriteBuffer

和WriteBuffer相关的参数有：

1. write_buffer_size：一个CF内的MemTable大小限制

2. db_write_buffer_size：DB内总MemTable大小限制

3. max_write_buffer_number：最大MemTable数量

4. min_write_buffer_number_to_merge：一次FLUSH的最小MemTable数量

当MemTable超过上面的限制或者WAL超过`max_total_wal_size`限制，那么就需要Flush MemTable。

> 概念上，write buffer 可理解为 MemTable

### MemTable

## WAL buffer

目前的了解RocksDB没有专门的WALBuffer，直接使用env提供的writefile进行log文件的写入。

<img src="/image/rocksdb-buf/rocksdb-log-writer.png" alt="image-20200725110752115" style="zoom:50%;" />

> [atomic_flush与pipeline_write不兼容](https://github.com/facebook/rocksdb/pull/5860)
>
> 如果BatchA包含cf1和cf2的数据，atomic_flush要求这个Batch中的两个CF的数据保证能同时刷盘；在非pipeline的模式下，

# Cache

## Row Cache

Row cache是全局级别的cache，缓存某些具体的row；可配置在cf和db中。似乎很少用？

## Block Cache

In a way, RocksDB's cache is two-tiered: block cache and page cache. 

+ block cache: uncompress block
+ page cache: compress block

RocksDB的设计，对于一个对象或者行为的配置，都基于一个专门Option；BlockBasedTableOptions中关于blockcache，有四个option：

```cpp
  // Disable block cache. If this is set to true,
  // then no block cache should be used, and the block_cache should
  // point to a nullptr object.
  bool no_block_cache = false;

  // If non-NULL use the specified cache for blocks.
  // If NULL, rocksdb will automatically create and use an 8MB internal cache.
  std::shared_ptr<Cache> block_cache = nullptr;

  // If non-NULL use the specified cache for pages read from device
  // IF NULL, no page cache is used
  std::shared_ptr<PersistentCache> persistent_cache = nullptr;

  // If non-NULL use the specified cache for compressed blocks.
  // If NULL, rocksdb will not use a compressed block cache.
  // Note: though it looks similar to `block_cache`, RocksDB doesn't put the
  //       same type of object there.
  std::shared_ptr<Cache> block_cache_compressed = nullptr;
```

默认地，其中的block是非压缩的（可通过block_cache_compressed指定专门的压缩cache）。

> The compressed block cache can be a replacement of OS page cache, if [Direct-IO](https://github.com/facebook/rocksdb/wiki/Direct-IO) is used.

block的cache置换算法有两种：LRU和Clock；



## table cache

TableCache和BlockCache所服务的对象不一样；TableCache中缓存了一些TableReader，由于ssttable的类型不同，reader可能有多种；`TableCache::FindTable()`如果miss了，就调用相应的NewTableReader创建一个新的Reader



