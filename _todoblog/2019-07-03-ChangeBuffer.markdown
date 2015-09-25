---
layout: post
title: InnoDB学习——change buffer
date: 2019-07-03 17:26
header-img: "img/head.jpg"
categories: jekyll update
tags:
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
# 简述

ibuf又叫change buffer，是InnoDB中为了避免数据更新时，二级索引的随机IO带来的性能损失，而提出的优化策略。因此在更新一级索引时，满足缓存条件（后文介绍）时，将操作缓存在ibuf中；当满足合并条件（后文介绍）是，再触发二级索引更新。

ibuf同样是一个btree结构。在InnoDB实例中，只有一个全局的ibuf；根节点对应的存储在系统表空间的固定位置（`FSP_IBUF_TREE_ROOT_PAGE_NO`/4）中；在系统启动的时候调用`ibuf_init_at_db_start()`创建ibuf结构。ibuf最大占用 [innodb_change_buffer_max_size](http://dev.mysql.com/doc/refman/5.7/en/innodb-parameters.html#sysvar_innodb_change_buffer_max_size)的内存空间。

在ibuftree中，按照（spaceid，pageno，counter）作为主键来标识一个changebufferrecord；

counter值在插入之后递增；插入时，按照PAGE_CUR_LE方式找到（space id, page no, 0xFFFF）的插入位置，然后将counter=counter+1；见ibuf_insert_low:3408。

```
ibuf_entry = ibuf_entry_build(
		op, index, entry, page_id.space(), page_id.page_no(),
		no_counter ? ULINT_UNDEFINED : 0xFFFF, heap);
```

其中缓存了非唯一的二级索引（non-unique secondary index，NUSI）的操作，类型有多种：

```c
/* Possible operations buffered in the insert/whatever buffer. See
ibuf_insert(). DO NOT CHANGE THE VALUES OF THESE, THEY ARE STORED ON DISK. */
typedef enum {
	IBUF_OP_INSERT = 0,
	IBUF_OP_DELETE_MARK = 1,
	IBUF_OP_DELETE = 2,

	/* Number of different operation types. */
	IBUF_OP_COUNT = 3
} ibuf_op_t;
```

通过参数`innodb_change_buffering`配置，默认是ALL。

打开changebuffer调试：

```
set global innodb_change_buffering_debug = 1;
```

# 插入ibuf

在`innobase_init`中，根据innobase_change_buffering设置全局参数ibuf_use 。在`ibuf_insert`根据ibuf_use进行判断插入那种操作。但在插入之前需要进行判断。

ibuf是面向leafpage的缓存机制，只有non-root leafpage不在bufferpool中的时候，才会将操作缓存；

## ChangeBufferBitmap

**确保能插入**

将叶子节点上的变更提前缓存起来，为了保证缓存的操作合并的时候不会导致nodesplit或者nodemerge，需要跟踪叶子节点的空闲空间；这里追踪叶子节点的空闲空间是通过Change Buffer Bitmap（又叫ibufBitmap）来记录。

1. 当从disk读取一个page到BufferPool时，通过ChangeBufferBitmap，确认是否有该page相关的操作被缓存了；如果有，合并后在放到bufferpool中。
2. 当page不在bufferpool中时，通过ChangeBufferBitmap，可以确认该page中空闲空间是否够放一个record。

ibufBitmap是紧跟在[extent descriptor page](http://mysqlserverteam.com/extent-descriptor-page-of-innodb/)之后的一个page，如下图和code：

![image-20190704181942011](/image/space-file.png)

```c
/** @name The space low address page map
The pages at FSP_XDES_OFFSET and FSP_IBUF_BITMAP_OFFSET are repeated
every XDES_DESCRIBED_PER_PAGE pages in every tablespace. */
/* @{ */
/*--------------------------------------*/
#define FSP_XDES_OFFSET			0	/* !< extent descriptor */
#define FSP_IBUF_BITMAP_OFFSET		1	/* !< insert buffer bitmap */
				/* The ibuf bitmap pages are the ones whose
				page number is the number above plus a
				multiple of XDES_DESCRIBED_PER_PAGE */
```

在Bitmap中，一个leafpage的信息由4bit（IBUF_BITS_PER_PAGE）表示。一个ibufBitmapPage大小有限，只能收纳有限leafpage（16k/4），如下是一个bitmappage的结构：

![image-20190704203435668](/image/bitmap-page.png)

因此，我们需要查询当前表空间中，某个leafpage对应的bitmappage的位置，需要进行如下计算：

```c
ulint bitmap_page_no = FSP_IBUF_BITMAP_OFFSET + ((page_no / page_size) * page_size)
```

每个leafpage对应的四个4bit信息如下：

+ 2bit:IBUF_BITMAP_FREE，索引中的空闲空间大小；由于只有2个bit位，因此这里分别用0、1、2、3代表一个空间空间的区间（见参数IBUF_PAGE_SIZE_PER_FREE_SPACE）。
+ 1bit：IBUF_BITMAP_BUFFERED，在ibuf中是否有该leafpage的操作
+ 1bit：IBUF_BITMAP_IBUF，该page是否是ibuftree的一部分。

## Purge

**确保btree没有空节点**

purge对索引的操作是IBUF_OP_DELETE，delete是IBUF_OP_DELETE_MARK。那么在purge时，根据ibuf计算leafnode上的记录数，需要执行后确保没有空节点。

如果会有？

如果没有？

# ibuf合并

InnoDB读写锁上的X锁所有权是可以在不同线程间转移的，主要用于支持Change Buffer的场景。Change Buffer是一棵全局共享的B+树，存储在系统表空间中。在读取二级索引Page的时候Change Buffer需要与二级索引Page进行合并，这时如果所有IO线程都在读取二级索引Page，将没有IO线程读取Change Buffer Page，因此Change Buffer Page的读取被放到单独的IO线程。

InnoDB读写锁上的X锁所有权是可以在不同线程间转移的，主要用于支持Change Buffer的场景。Change Buffer是一棵全局共享的B+树，存储在系统表空间中。在读取二级索引Page的时候Change Buffer需要与二级索引Page进行合并，这时如果所有IO线程都在读取二级索引Page，将没有IO线程读取Change Buffer Page，因此Change Buffer Page的读取被放到单独的IO线程。而读取二级索引Page的时候，已经对Page加上了X锁，当在异步IO线程需要把Change Buffer合并到二级索引的Page的时候，必须在不解锁的情况下让异步线程获得Page的X锁，这就是X锁所有权转移需要实现的功能。

实现函数是rw_lock_x_lock_move_ownership，实现的逻辑也非常简单，使用CAS原子操作把读写锁的write_thread字段设置为当前线程。

当leafpage不在bufferpool中，NUSI的page操作会缓存在ibuf中。当咋如下情况下，会进行合并：

+ 当page读取到bufferpool中时，index scan、lookup或者预读等情况。
+ master线程定期调用`ibuf_merge_in_background`。
+ 某个leafpage被缓存的操作达到阈值（？）。
+ ibuftree达到配置的最大值时。

某个leafpage合并之后对应的4bit信息也会更新。

# 参考

[The Innodb Change Buffer](https://mysqlserverteam.com/the-innodb-change-buffer/)

[MySQL · 引擎特性 · Innodb change buffer介绍](http://mysql.taobao.org/monthly/2015/07/01/)
