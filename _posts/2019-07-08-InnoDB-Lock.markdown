---
layout: post
title: InnoDB——Btree与rwlock的互动
date: 2019-07-08 16:35
header-img: "img/head.jpg"
categories: 
  - InnoDB
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
> 本文基于5.7版本代码

# InnoDB的线程锁简述

线程锁的对象是程序运行过程中bufferPool中的page，或其他cache中的对象；有两种类型：mutex和rw_lock。

+ mutex：基于系统提供的原子操作，用在内存共享结构的串行访问上，比如：

  > 关于Mutex具体的实现方式有很多种，见文件ut0mutex.h；想了解更多这里有一篇好文章——[InnoDB mutex 变化历程](http://baotiao.github.io/2020/03/29/innodb-mutex/)。

  + free、LRU、flush List的互斥
  + buf_block_t的mutex，该结构是page在内存的元信息，包括io_fix、state、buf_fix_count等，更新这些信息，需要互斥；
  + 一些共享的对象：lock_sys_mutex、trx_sys_mutex、trx_mutex等等：
    + Dictionary Cache
    + Transaction System的并发访问；比如，在修改indexpage前，在Transaction system的header中写入一个undo log entry。
    + Rollback segment mutex，Rollback segment header的并发访问，当需要在回滚段中添加一个新的undopage时，需要申请这个mutex。

+ rw_lock：rw_lock是InnoDB实现的读写锁，比起mutex，rwlock有两种模式，用在需要shared访问的场景中，比如：

  > InnoDB的rw_lock不依赖[pthread_rwlock_t](https://code.woboq.org/userspace/glibc/nptl/pthread_rwlock_common.c.html)，其是基于futex实现的blocking rwlock，适合于读多写少的场景。

  + buf_page_get_gen ->**hash_lock** = buf_page_hash_lock_get(buf_pool, page_id);
  + buf_block_t中还有一个lock，这对应的是frame，这是page在内存的地址；Page的读写需要加rwlock，本文我们主要讨论rwlock，有两种模式S/X（5.7引入一个新模式SX）。三个模式的兼容关系如下：

```c
/*
 LOCK COMPATIBILITY MATRIX
    S SX  X
 S  +  +  -
 SX +  -  -
 X  -  -  -
 */
```

![image-20200106154013692](/image/innodb-overview/ahi.png)

当我们访问BufferPool中的一个Page时，首先获取**hash_lock**，然后获取**buf_block_t->mutex**，进而修改元信息，然后释放**buf_block_t->mutex**，获取**buf_block_t->lock**，即rwlock，开始读写page。

# rw_lock与Btree

InnoDB的rwlock的具体实现基于64bit的lock_word之上的原子操作，如下实例代码：

> 也可基于mutex实现rwlock，这可以作为另一个话题了,详见`ib_mutex_t`的定义方式。

```cpp
/** Two different implementations for decrementing the lock_word of a rw_lock:
 one for systems supporting atomic operations, one for others. This does
 does not support recusive x-locks: they should be handled by the caller and
 need not be atomic since they are performed by the current lock holder.
 Returns true if the decrement was made, false if not.
 @return true if decr occurs */
ALWAYS_INLINE
bool rw_lock_lock_word_decr(rw_lock_t *lock, /*!< in/out: rw-lock */
                            ulint amount,    /*!< in: amount to decrement */
                            lint threshold)  /*!< in: threshold of judgement */
```

为了避免writethread被多个readthread饿死，writethread可以通过排队的方式阻塞新的readthread，每排队一个writethread将lockword减X_LOCK_DECR（新的SX锁等待时，减X_LOCK_HALF_DECR）。在wl6363中，标明了加了SX锁后lock_word不同取值的意思；其中lock_word=0表示加了xlock；lock_word= 0x20000000没有加锁；

另外，InnoDB中某些需要rwlock同步的function1可能还会调用其他需要同步的funtion2，如果恰好funtion1和function2对同一个对象加锁，这时就需要锁支持可重入（recursive），而InnoDB的rwlock同样是支持可重入。

rw_lock可以用在需要并发读写的结构上，比如Btree索引，文件空间管理等；那么，本文主要描述Btree与rw_lock的互动。

在Btree扫描过程中，首先在`dict_index_t`上加相应模式的rwlock；然后初始化一个cursor，对btr进行搜索，最终cursor停在我们要求的位置；取决于加锁类型、扫描方式等条件，最终cursor**可能**会将扫描路径上的某些block加锁。

之后对于不同操作基于返回的cursor分别操作：

+ 查询操作，基于该cursor，会根据一致性锁定读还是非锁定读，决定创建一个readview还是加意向锁；如果是一致性读的话，MySQL层通过可物化的cursor进行get_next，就是`row_search_mvcc`。

+ 修改操作，在扫描过程中该加的锁已经加好；在返回的cursor处进行操作即可。

> 为保证Btree并发加锁访问时，不产生死锁，这里加锁采用Lock Coupling的方式。Lock Coupling严格保证顺序，避免死锁。
>
> retaining the latch on the parent node until the child node is latched. 

## 加锁入口

在对Btree的搜索入口为`btr_cur_search_to_nth_level`，其参数`latch_mode`分为两部分，低字节为如下的基本操作模式：

```c
/** Latching modes for btr_cur_search_to_nth_level(). */
enum btr_latch_mode {
	/** Search a record on a leaf page and S-latch it. */
	BTR_SEARCH_LEAF = RW_S_LATCH,
	/** (Prepare to) modify a record on a leaf page and X-latch it. */
	BTR_MODIFY_LEAF	= RW_X_LATCH,
	/** Obtain no latches. */
	BTR_NO_LATCHES = RW_NO_LATCH,
	/** Start modifying the entire B-tree. */
	BTR_MODIFY_TREE = 33,
	/** Continue modifying the entire B-tree. */
	BTR_CONT_MODIFY_TREE = 34,
	/** Search the previous record. */
	BTR_SEARCH_PREV = 35,
	/** Modify the previous record. */
	BTR_MODIFY_PREV = 36,
	/** Start searching the entire B-tree. */
	BTR_SEARCH_TREE = 37,
	/** Continue searching the entire B-tree. */
	BTR_CONT_SEARCH_TREE = 38
};
```

而高字节放一些标记位，用来判断rwlock的类型；如下是该函数的大体逻辑：

![image-20191227175829430](/image/btr-rwlock/btr_cur_search_to_nth_level.png)

### **1. 初始化扫描指令**；

函数一开始，识别高位的标记得到如下信息，之后通过(`BTR_LATCH_MODE_WITHOUT_FLAGS`)，将高位信息抹除。

+ ibuf操作：btr_op（`btr_op_t`，btr0cur.c:1117）

+ 统计信息：estimate，在查询优化阶段调用的，比如在`ha_innopart::records_in_range`中用来估计index一个范围内的元组数。

+ 变更意图：lock_intention，便于判断加锁模式（`btr_intention_t`）。

+ 是否需要修改外部存储的数据：，modify_external，用在BTR_MODIFY_LEAF模式中。

### 2. 查找AHI信息

![image-20191226172027826](/image/btr-rwlock/ahi-search.png)

Adaptive Hash Index作为Btree寻路的缓存，提高Btree寻路的开销；在按层查找Btree之前，荣国`btr_search_guess_on_hash`先检索内存page的hash。

首先，将逻辑元组信息编码为一个hash值，通过该hash值找到AHI中的物理record（rec）；为了提高AHI的并发，AHI按indexid+spaceid进行了分区。

然后，rec的地址在buf_chunk_map中找到实例的frame，从而找到Control Block，即，buf_block_t。

最后，在block内存对cursor进行定位，那么cursor最终就找到了目标记录。

如果AHI上有锁，需要将AHI上的锁释放(`has_search_latch`)。AHI没有找目标record，就需要进行实际的Btree查找。

> 关于Adaptive Hash Index的逻辑，都在BTR_CUR_HASH_ADAPT BTR_CUR_ADAPT之内；如果想禁掉AHI，那么将这两个宏去掉即可。

### 3. 解析扫描的指令

1. `dict_index_t`加锁：（btr0cur.cc:959）基于latch_mode和第一步得到的信息加rw_lock，同时设置变量`upper_rw_latch`（rw_lock_type_t ），后续给block加锁会参考。

2. 微调page cursor的搜索模式`page_cur_mode_t`：与Btree键值的比较大小方式(暂不讨论Rtree）。

   > 为什么要微调？
   >
   > InnoDB的Btree的branch_page上存放的是node_ptr，node_ptr的key是对应page的最小值；那么，我们如果按照PAGE_CUR_G和PAGE_CUR_GE的方式查找branch_page时，需要换成PAGE_CUR_L和PAGE_CUR_LE；举例，如果要找8，8位于page[3,5,78,9]中，那么有两个node_ptr：[3,<page_id1>]，[10,<page_id2>]，那么8是在3，而不是10中。

### 4. (search_loop)递归查找

迭代多次，直到到达指定level（不一定level=0，在节点分裂中需要向branch_page中插入node_ptr）;我们都知道mtr.m_memo存有进行原子变更的锁，在搜索之前，先取得当前的**savepoint**，即，m_memo当前的size，这样我们就知道搜索过程中加了多少锁。

在循环中有如下步骤。

1. 确定page需要加的锁模式(X?S?SX)与page的读取方式（BUF_GET...）。

2. `buf_page_get_gen`按照rw_latch类型读取page到buf_pool中，并加锁。对于可以利用change buffer的操作，可能没有读取到block，那么对操作进行缓存。

3. 第一次取出的root节点；通过root节点的得到Btree的height；

4. 在取出的page中，根据目标tuple，采用二分法，在page中定位page_cursor（可以是最终的叶子节点的键值对，可以是非叶子节点的node_ptr）；

   ```cpp
   	/* Perform binary search until the lower and upper limit directory
   	slots come to the distance 1 of each other */
   	while (up - low > 1) {
   		mid = (low + up) / 2;
   		cmp = cmp_dtuple_rec_with_match(
   			tuple, mid_rec, offsets, &cur_matched_fields);
   	}
   ```
   
5. 1487，如果不是最终的level；height—;

6. 1780，迭代到该节点的子节点；n_blocks++；在查找过程中维护了一个路径block数组。

7. height!=0，继续迭代search_loop，返回1；height==0（1306），结束

8. 这时根据latch_mode，释放tree_savepoints和tree_blocks，以及对page也加锁。

### 5. 设置cursor

(1862)找到后设置cursor的low_match和up_match等参数；

### 6. 函数退出

因为调用`btr_cur_search_to_nth_level`的调用者可能已经在外面加锁了，那么退出还是对index加s锁 。（由参数has_search_latch判断，该参数只能为0或者`RW_S_LATCH`；）。

## Btree变更操作

### INSERT的rwlock

以悲观Insert为例

**1. 按BTR_MODIFY_TREE模式，定位cursor，并对index和page加锁。**

+ 首先给索引加SX锁（btr_cur_search_to_nth_level：976；）
  + 在查找的过程中，不需要加锁（rw_latch=RW_NO_LATCH）；
  + 最终将找到的leafpage，以及其左右page加X，见`btr_latch_leaves_t`。

```c
	if (height == 0) {
		if (rw_latch == RW_NO_LATCH) {
			latch_leaves = btr_cur_latch_leaves(
				block, page_id, page_size, latch_mode,
				cursor, mtr);
		}
```

**2. 执行btree悲观插入**

此时index->lock->lock_word = 0x10000000了；即已经在上述步骤中加了SXlock。这时，该index不能被其他线程修改，但是可以读。

然后在pessimistic insert中，通过`btr_page_split_and_insert`修改btr_cur_search_to_nth_level中定位的cursor的page；

在修改叶子节点的时候需要在上层添加一个node_ptr(`btr_insert_on_non_leaf_level`)；这里接着调用btr_cur_search_to_nth_level找到指定的父亲分支节点（这里的latch_mode就是BTR_CONT_MODIFY_TREE，如下），但是level就不是0了，因为要找分支节点。

```c
			btr_cur_search_to_nth_level(
				index, level, tuple, PAGE_CUR_LE,
				BTR_CONT_MODIFY_TREE,
				&cursor, 0, file, line, mtr);
```

最终找到指定分支block的时候，对找到的block(level!=0)加X锁；

```c
			if (latch_mode == BTR_CONT_MODIFY_TREE) {
				child_block = btr_block_get(
					page_id, page_size, RW_X_LATCH,
					index, mtr);
```

然后乐观或者悲观的插入；继续重复这个过程。

因此，总结步骤如下：

1. 在插入的时候首先通过btr_cur_search_to_nth_level在整个index上加SX锁，然后进行定位，并对找到的page与邻居加锁；
2. 调用btr_cur_pessimistic_insert，进行分裂；具体的分裂操作，见另一篇文章「InnoDB源码解析——MTR与Btree操作」
3. 分裂的时候如果需要继续分裂，还是通过btr_cur_search_to_nth_level定位并加锁后，重复操作。

### UPDATE的rwlock

更新行的具体逻辑的入口函数是`row_upd_clust_step`。同样是分为乐观更新和悲观更新。

在row_upd_clust_step之前，

1. 先调用`btr_cur_search_to_nth_level`定位了要更新的cursor位置；此时只是查找，索引加S锁。然后将cursor暂存。

2. 恢复cursor`	success = btr_pcur_restore_position(mode, pcur, &mtr);`，在恢复cursor时给对应的page加X锁`btr_cur_optimistic_latch_leaves`；加锁位置在buf0buf.cc:4720。
3. 执行如下代码进行更新，首先尝试乐观更新；更新的时候，如果新元组的大小和原来相同，那么就写完undo日志`trx_undo_report_row_operation`后，直接原地更新： `btr_cur_update_in_place->row_upd_rec_in_place`。

在update的时候，如果更新的列是有序的，那么需要标记删除+插入，见如下代码(`row_upd_clust_rec`)，这里存在一个**Halloween problem**问题（通过undo构建版本解决）。

### DELETE的rwlock

在InnoDB中，上层的Delete和Update最终都是调用的`row_update_for_mysql(((byte*) record, m_prebuilt);)`，只不过是参数内容不同`m_prebuilt->upd_node->is_delete = TRUE;`。

在InnoDB中发起delete，只是在要删除的元组上标记删除，相当于是一次更新操作；

而最后发起删除的是purge线程；

Purge线程类似PostgreSQL的Vacuum，会清理update/delete中标记删除的数据。产生标记删除的事务放在一个history_list（就是purge的队列）中，由参数`innodb_max_purge_lag`控制大小。

Purge线程在发起删除的时候，不管是清理一级索引还是二级索引，都是先尝试乐观删除：

+ 一级索引：

  `row_purge_remove_clust_if_poss_low(BTR_MODIFY_LEAF)->btr_cur_optimistic_delete`

+ 二级索引：`row_purge_remove_sec_if_poss_leaf`

然后再悲观删除：

+ 一级索引：

  `row_purge_remove_clust_if_poss_low(BTR_MODIFY_TREE)->btr_cur_pessimistic_delete`

+ 二级索引：`row_purge_remove_sec_if_poss_tree`

————————————————————————————————————

关于Delete过程的锁，同样是在调用`btr_cur_optimistic_delete`函数之前，通过search_level加锁，

+ 在调用`btr_pcur_restore_position_func`读取cursor时，对page进行加X锁（`btr_cur_optimistic_latch_leaves`）。

+ 而在整个索引上加SX。

————————————————————————————————————

在删除过程中，对Btree的操作有两种：btr_lift_page_up、btr_compress。

+ btr_compress：如果达到merge_threshold的话，将该block和相邻的block合并；

+ btr_lift_page_up：如果没有左右相邻的page，如下判断，那么将该叶子节点的记录提升到father节点中。

```c
	if (left_page_no == FIL_NULL && right_page_no == FIL_NULL) {
		/* The page is the only one on the level, lift the records
		to the father */

		merge_block = btr_lift_page_up(index, block, mtr);
		goto func_exit;
	}
```

具体的合并操作，见另一篇文章「InnoDB源码解析——MTR与Btree操作」

# 总结

查询扫描前，在索引树上加`btr_search_s_lock`；找到之后释放

插入时，需要RW_X_LATCH对应的leafpage。如果需要叶子分裂，首先在整个index上加X。然后再三个leafpage（prev、current、next）上加X，为了避免死锁，都是先获取左page的lock，之后再持有下一个page的锁。

# 参考

[mysql-rr](https://blog.pythian.com/understanding-mysql-isolation-levels-repeatable-read/)

[mysql-index-lock](http://mysql.taobao.org/monthly/2015/07/05/)

[尝试理解lock](https://github.com/octachrome/innodb-locks)
