---
layout: post
title: RocksDB Overview(2)——Lock Manager
date: 2020-07-09 21:00
categories:
  -
typora-root-url: ../../layamon.github.io
---
> * TOC
{:toc}

# Lock Of Transaction

## PessimisticTransaction

### TransactionLockMgr

#### TryLock

#### 



More often, a reader holds it indirectly through a data structure called `super version`, which holds reference counts for list of mem tables and a `version` -- a whole view of the DB.



DBImpl.mutex_

+ MemTable和SST Table的reference counts
+ 在compact finishing，flushing，memtable creating前后修改元数据
+ 调度writer



To solve this problem, we created a meta-meta data structure called “[super version](https://reviews.facebook.net/rROCKSDB1fdb3f7dc60e96394e3e5b69a46ede5d67fb976c)”, which holds reference counters to all those mem table and SST tables, so that readers only need to increase the reference counters for this single data structure. 

> https://rocksdb.org/blog/2014/05/14/lock.html



```cpp
ReturnAndCleanupSuperVersion
```

> vs Version

#### 

## OptimisticTransaction

# Lock Of Thread

SuperVersion

compact结束 和 MemTableFlush时，会创建一个新的Version；Version-`current`表示最新LSM-tree中的文件。Get操作和Iterator的整个生命周期会基于current来读取数据。get/iter引用Version-current，每个version又引用各个文件；如果某个version没有被引用，就需要删除；如果某个文件没有被引用，也需要被删除。

- create version：对所有该version的文件 ref++；反之ref--

由于Version是共享的，ref变更需要加锁，为减少增减引用计数的锁代价，引入SuperVersion，这是thread local的变量。SuperVersion对MemTable和Sst都保持引用

```cpp
SuperVersion* s = thread_local_->Get();
if (s->version_number != super_version_number_.load()) {
  // slow path, cleanup of current super version is omitted
  mutex_.Lock();
  s = super_version_->Ref();
  mutex_.Unlock();
}
```

- create new MemTable
- flush or Compact完成

会创建新的SuperVersion；但这些事件的频率不高；在这之前get/iter引用thread local的sv进行查询。

之前，一个查询需要对MemTable和version分别取mutex，然后加引用；现在只去一次mutex，对SuperVersion加引用，并拷贝为自己的local。

