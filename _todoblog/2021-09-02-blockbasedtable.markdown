---
layout: post
title: BlockBasedTable
date: 2021-09-02 22:02
categories:
  - MyRocks
typora-root-url: ../../layamon.github.io
---



BlockBasedTable是RocksDB中最常用的SST格式，在[wiki](https://github.com/facebook/rocksdb/wiki/Rocksdb-BlockBasedTable-Format)中，对其格式有个大概的介绍，但是对其中Index部分并没有特别清晰，本文作为该wiki的补充，特别对Index部分进行阐述。

表如其名，BlockBasedTable的Block是按照Block为单位进行组织；但是注意其[block_size](https://github.com/facebook/rocksdb/blob/361895ad79320e583c37d04e18b41df994674e23/include/rocksdb/table.h#L255)在磁盘中不是固定大小的，只是一个CompressUnit；当BuildTable的时候，通过[FlushBlockBySizePolicy](https://github.com/facebook/rocksdb/blob/b9a4a10659969c71e6f6eab4e4bae8c36ede919f/table/flush_block_policy.cc#L47)判断是否该Flush当前的Block。

默认地，index_type为kBinarySearch，TableBuilder将每个Block的last_key抽取出来，作为IndexBlock；TableReader在Open后，将IndexBlock留在内存，Get的时候在其中进行BinarySearch定位到Key所在的Block；由于BinarySearch的CPU代价比较高（[将近30%](https://medium.com/rocksdb-internals-a-beginners-guide/war-story-speeding-up-block-based-table-lookup-ae357d9bc2bf)），RocksDB提出了一个可选的HashIndex，更应该叫PrefixHashIndex，当index_type=kHashSearch且Options.prefix_extractor存在的时候，将构建额外的HashIndex，通过Key的Prefix直接定位Block（记住这是有额外内存代价的，并且和prefix的数量相关）。

> HashIndex的两个优化：
>
> - 为了TableReader构建HashIndex时频繁的malloc，这里将Prefix的内容 和 具体的元信息分开存储。在[BlockPrefixIndex::Create](https://github.com/facebook/rocksdb/blob/b9a4a10659969c71e6f6eab4e4bae8c36ede919f/table/block_prefix_index.cc#L198)中，最终Reader构建Index的时候，在prefixes所在内存上套个slice，避免了copy和malloc；meta则是需要一个个copy到新的variable中。
> - 当Prefix多的时候，之前基于std::unordered_map存储的内存代价很大，考虑到HashIndex只起到定位的作用，其实可以不用存PrefixKey；因此HashIndex只需构建了一个blockHandle的array，[BlockPrefixIndex::GetBlocks](https://github.com/facebook/rocksdb/blob/b9a4a10659969c71e6f6eab4e4bae8c36ede919f/table/block_prefix_index.cc#L218)只需计算好的Hash值，即可array的slot；当然这有个弊端，当Key不存在的时候，需要读取block来判断。
>
> HashIndex的引入是为了解决Binary Search CPU高的问题，先通过标准的unordered_map快速实现拿到预期的收益后，再继续针对Prefix多的用户场景做优化，算是一个避免过早优化例子。

在Block中，默认基于BinarySearch进行定位，但如果`data_block_index_type`为`kDataBlockBinaryAndHash`， `BlockBuilder`中就会[构建hashindex](https://github.com/facebook/rocksdb/blob/b9a4a10659969c71e6f6eab4e4bae8c36ede919f/table/block_builder.h#L74)。

综上，BlockBasedTable的内部布局如下图所示：

<img src="/image/rocksdb/block_based_table.png" alt="image-20210905173356726" style="zoom:67%;" />

值得注意的是，IndexBlock也是按照DataBlock的方式进行组织，HashIndex存储在IndexBlock之可选的IndexMeta区域（HashPrefix的数据和meta是分开存储的，这是个[上面讲的一个小优化](https://github.com/facebook/rocksdb/blob/b9a4a10659969c71e6f6eab4e4bae8c36ede919f/table/index_builder.h#L220)），[构建的HashIndex返回的还是IndexBlock中的RestartIndex](https://github.com/facebook/rocksdb/blob/b9a4a10659969c71e6f6eab4e4bae8c36ede919f/table/index_builder.h#L260)（即RestartOffsets的下标）；可见HashIndex可看做是BinarySearch的一个可选的Meta，用来加速点查。

BuildIndex的时候，IndexBlock逐条添加Key，与此同时维护Block内部的RestartOffsets；当启用HashIndex后，那么IndexBlock会同时维护各个HashPrefix对应的prefix和RestartIndex，最后将这些数据写到IndexBlock的indexmeta区域。

> 另外，对于CompressDict信息，我之前一直理解有偏差；这个不是比选的，默认关闭，通过设置[max_dict_bytes](https://github.com/facebook/rocksdb/blob/b9a4a10659969c71e6f6eab4e4bae8c36ede919f/include/rocksdb/advanced_options.h#L115)打开，对于能够提高压缩率，但同时提高了整体的内存使用率。
