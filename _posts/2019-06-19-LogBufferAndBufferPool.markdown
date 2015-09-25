---
layout: post
title: InnoDB——LogBuffer与事务提交过程
date: 2019-06-19 16:49
header-img: "img/head.jpg"
categories: 
  - InnoDB
typora-root-url: ../../layamon.github.io
---

* TOC
{:toc}
数据变更可以变成若干个redo record，每个record都有一个`mlog_id_t`的类型。不同的数据库操作对应不同组合的Record，这些record以mtr为单位进行组织，保证原子性。

> 1. 数据页的变更必须通过mtr，在`mtr_commit()`中将本次mtr变更的所有record，写入redo日志；
>
>    >  注意这里mtr_commit写入的是redo buffer。具体写入磁盘的时机为：
>    >
>    > 1. 事务提交
>    > 2. log buffer的空间使用过半
>    > 3. log CHECKPOINT
>
> 2. 一般来说，变更记录会通过`mlog_write_ulint()`函数(或其他类似函数)写入。
>
> 3. 对于一些页面级别的操作，只在记录中记录C函数的编码和参数，节约空间。
>
>    1. 不需要在`trx_undo_header_create() ,trx_undo_insert_header_reuse()`的记录中加参数；
>    2. 不能添加不做任何改变的函数，或者需要依赖页外部数据的函数；当前log模块的函数有完备的页面转换，没有足够的理由不要擅自改动。
>


本节基于redo机制的核心控制结构：`log_t`来介绍事务提交时LogBuffer的作用。

# LogBuffer与事务提交

`log_t*	log_sys`是redo日志系统的关键全局变量。负责三项事情：

1. logrecord从mtr_buf复制到logbuffer：用户线程mtr_commit时，将mtr_buf中的redo record，拷贝到log buffer中；
2. logrecord从logbuffer复制到logfile：write_mutex控制logbuffer顺序的刷盘；
3. dirtypage从bufferpool刷写到datafile：log_flush_order_mutex控制flushlist的顺序刷盘；执行CHECKPOINT或preflush。

![image-20190729194135905](/image/mysql-8-redo/logbuffer-flush.png)

InnoDB的logbuffer是双buffer设计，每个默认是16MB，可以进行伸展；

在mtr_commit时，UserThread将自己事务对应的多个mtr复制到logbuffer中；在logbuffer中，每接收到496byte的logrecord，就将这组logrecord包装一个12byte的block header和一个4byte的block tailer，成为一个logblock。刷盘会对齐512字节刷盘。

在事务提交时，双Buffer进行切换；切换时会将当前buffer的最后一个block，复制到新buffer的头部，因为最后一个block可能没有写满，要继续按照lsn进行**连续写入**。

> LSN
>
> log_sys中维护了redo日志已经写到的日志序列号；LSN可以看做是将所有日志拼接在一起，**去掉logfileheader数据**，然后在整个大文件中的文件偏移量。如下在log_init函数中，log_sys->lsn起始位置是算上LOG_BLOCK_HDR_SIZE，但是没有算上LOG_FILE_HDR_SIZE。
>
> log_sys->lsn = LOG_START_LSN + LOG_BLOCK_HDR_SIZE;

双buffer有以下主要参数：

+ `buf`指向当前写入的logbuffer（`buf_ptr`是没有对齐的起始位置）；

+ `first_in_use`表示具体是哪个buffer。

+ `volatile bool	is_extending;`：为了避免redo日志过大超过buffer，当redo日志超过buf_size/2时，就会扩展；扩展后，就不会缩减。

其中三个锁分别控制log_t互斥访问(`mutex`)、日志刷盘(`write_mutex`)、数据刷盘(`log_flush_order_mutex`)的操作。

> 这里互斥锁的类型都是：ib_mutex_t；实际上是基于Futex机制实现的FutexMutex（Linux Fast userspace mutex）。

后面基于5.7版代码，逐一了解与三项工作相关的每个成员变量的含义。

## 从mtr_buf到logbuffer

### mtr_commit

这里需要了解mtr_t的结构，这是mtr的控制结构。

+ mtr_t.`m_made_dirty`与mtr_t.`m_modifications`的区别：

  m_modifications表示该mtr可能进行了修改，在mtr_commit时，还需判断mtr中的记录数，得知是否需要拷贝redo record；
  
  m_made_dirty表示产生了脏页，需要将脏页追加到flush_list中。如下mtr_commit的流程图：
  
  ![image-20190815173343250](/image/innodb-log-buffer/mtr_commit.png)

在mtr_commit的时候，为了保证提前释放mutex后，flush_list的dirty_page的写入是顺序的，这里加了log_flush_order_mutex锁，减下·小了临界区的大小，提高了整体的并发度。

### 拷贝mtr中的record

- `unsigned long buf_free`：buf中空闲的第一个位置，按照该位置向logbuffer中拷贝record。

- `max_buf_free`：推荐的buf_free的最大值，会判断该值，如果超过max_buf_free，需要刷logbuffer；并设置log_sys->`check_flush_or_checkpoint`为true。

  ```c
  void log_buffer_extend(len) {
  ...
  log_sys->max_buf_free = log_sys->buf_size / LOG_BUF_FLUSH_RATIO - LOG_BUF_FLUSH_MARGIN;
  ...
  }
  ```

关于刷盘有一个关键的函数log_free_check，在该函数中检查是否需要刷盘，然后设置参数check_flush_or_checkpoint。

```c
/***********************************************************************//**
Checks if there is need for a log buffer flush or a new checkpoint, and does
this if yes. Any database operation should call this when it has modified
more than about 4 pages. NOTE that this function may only be called when the
OS thread owns no synchronization objects except the dictionary mutex. */
UNIV_INLINE
void
log_free_check(void)
/*================*/
{
...

	if (log_sys->check_flush_or_checkpoint) {

		log_check_margins();
	}
}
```

`log_sys->check_flush_or_checkpoint`：该项为True，表示需要刷logbuffer、或者preflush pool page，或者做CHECKPOINT；其实任何修改了超过4个页的操作，都应该调用`log_free_check`判断是不是需要刷盘。在`log_free_check`中，按照如图逻辑进行具体处理：

![image-20190726164051545](/image/innodb-log-buffer/log_free_check.png)

**例子：insert涉及的redo记录的拷贝**

如下是简单insert中，涉及的五个mtr：

1. 重用UNDO头部
   1. MLOG_UNDO_HDR_REUSE 
   2. MLOG_2BYTES
   3. MLOG_2BYTES
   4. MLOG_2BYTES
   5. **mtr_t::commit()**
2. 插入UNDO记录
   1. MLOG_UNDO_INSERT
   2. **mtr_t::commit()**
3. 插入数据
   1. MLOG_COMP_REC_INSERT
   2. **mtr_t::commit()**
4. xa prepare
   1. MLOG_FILE_NAME
   2. MLOG_2BYTES
   3. MLOG_FILE_NAME
   4. MLOG_1BYTE
   5. MLOG_4BYTES
   6. MLOG_4BYTES
   7. MLOG_4BYTES
   8. MLOG_FILE_NAME
   9. MLOG_WRITE_STRING
   10. **mtr_t::commit()**
5. xa commit
   1. MLOG_2BYTES
   2. MLOG_4BYTES
   3. **mtr_t::commit()**

## 从logbuffer到logfile

### 日志刷盘时机

日志的刷盘是通过调用`void log_write_up_to( lsn_t	lsn, bool	flush_to_disk)`，如果flush_to_disk为True，则表示将参数lsn之前日志都write&**flush**；同时更新相应偏移量。

满足以下条件来进行日志刷盘：

+ LogBuffer中的日志量达到阈值

  **buf_free>max_buf_free**：log_flush_margin:1472；max_buf_free为`buf_size/LOG_BUF_FLUSH_RATIO-LOG_BUF_FLUSH_MARGIN`，大概为小于buf_size的一半。

+ 为了保证WAL，即日志先于数据写，所以当数据同步之前，需要确保数据上lsn标记的日志已经刷盘。

  + **checkpoint**时，为了保证最老的脏页的日志提前刷盘，这里会将脏页最老lsn之前的日志刷盘：log_checkpoint:1844
  + bufferpool中的page进行**其他原因触发的刷盘**时，需要保证日志先写；需要将该page的最新修改的lsn刷盘。buf_flush_write_block_low:1040

+ 事务操作调用；事务提交要保证持久化。

  + 删除表空间时，需要强制写redo
  + log_buffer_flush_to_disk
  + 主线程主动调用
  + 事务提交
  + 等等

> 注意日志的刷盘可能有多种触发条件，因此在函数log_write_up_to中，在函数返回后**只是确保该lsn之前已经write了**（如果flush_to_disk为True，确保也flush了）。如果，没有到达指定lsn，才会写，实际还是写到log_sys->lsn；
>
> ```c
> 	DBUG_PRINT("ib_log", ("write " LSN_PF " to " LSN_PF,
> 			      log_sys->write_lsn,
> 			      log_sys->lsn));
> ...
> 	write_lsn = log_sys->lsn;
> ```

### 双buffer切换刷盘

![image-20190809205526703](/image/innodb-log-buffer/logbuffer-detail.png)

MySQL-5.7中为了提高`log_sys->mutex`这个大锁的并发，添加一个新的write_mutex与双buffer的设计（每个默认16MB大小）。事务提交进行日志刷盘时，在mutex的保护下，进行`log_buffer_switch`——双buffer的切换：

1. 将当前buf的最后一个block，复制到新的buf的首部；

2. 然后更新buf_free和buf_next_to_write

   + `unsigned long buf_next_to_write`：准备写盘的redolog的位置，执行完继续推进。

   ```c
   void
   log_write_up_to(
   	lsn_t	lsn,
   	bool	flush_to_disk)
   
   ...
   	start_offset = log_sys->buf_next_to_write;
   ...
   
   /* Do the write to the log files */
   	log_group_write_buf(
   		group, write_buf + area_start,
   		area_end - area_start + pad_size,
   
   ```

3. 用户线程可以继续将record写入到新的buffer中；同时，旧的buf在write_mutex的保护下进行后续的刷盘操作；

   + `write_lsn`/`current_flush_lsn`/`flushed_to_disk_lsn`：buf的刷盘分为两步write和flush；每次写盘的时候都是写到log_sys->lsn，这里会将write_lsn设置为log_sys->lsn；表示当前开始从`write_lsn`开始写，`current_flush_lsn`是正在执行flush操作的lsn；flushed_to_disk_lsn是已经flush到磁盘的lsn（**注意这里是lsn，上面mtrbuf向LogBuffer中拷贝的偏移是ulint**）。
   + `n_pending_flushes`/`flush_event`：当前等待redo sync的任务，最大值为1；由`mutex`控制对flush_event的互斥访问，从而设置`n_pending_flushes`；设置了flush_event就触发相应线程进行刷盘。

> write ahead优化
>
> 操作系统写数据是按照block（page）为单位进行刷盘，一般是4KB原子写；如果需要写出的数据满足下面两个条件：
>
> + 起始地址等于按page对齐的地址
> + 数据大小等于page的整数倍
>
> 那么需要将对应page中的其他数据读入page cache，然后再写出，这就是read-on-write IO，InnoDB中为了避免Logbuffer刷盘时的read-on-write，添加了一个参数——**innodb_log_write_ahead_size**，一般将这个参数为操作系统写block的大小。

## 从bufferpool到datafile

InnoDB中可能有多个bufferpool，总大小为innodb_buffer_pool_size（小于1G，多个小buffer会合并）；在每个buffer中有一个page hash表，通过(spaceid, pageno)快速找到page位置；

### 三个List

每个buffer中还有三个list：freelist、lrulist和flushlist。flushlist中是按照lsn顺序组织dirtypage，lrulist是按照访问先后组织的。刷脏有两种：从flush_list或者lru_list中刷，如下。

```c
mysql> SHOW ENGINE INNODB STATUS\G
Pending writes: LRU 0, flush list 0, single page 0
...
/*Start a buffer flush batch for LRU or flush list */
static
ibool
buf_flush_start(
/*============*/
	buf_pool_t*	buf_pool,	/*!< buffer pool instance */
	buf_flush_t	flush_type)	/*!< in: BUF_FLUSH_LRU
					or BUF_FLUSH_LIST */
{
```

LRU List是在数据读取的时候，将page放在LRUlist中；如果修改了，相应块也放在flushlist中：在Flush List上的页面一定在LRU List上，但是反之则不成立。

+ LRUlist刷：读取数据的时候空间不足，需要按照最近最少使用的原则从LRUlist中淘汰。
+ FLUSHList刷：脏页超过了阈值(`innodb_max_dirty_pages_pct`)，或者定时的CHECKPOINT活动。

### FLUSHList阈值点

在函数`log_calc_max_ages`中，计算了相应的阈值点

```c
/*****************************************************************//**
Calculates the recommended highest values for lsn - last_checkpoint_lsn
and lsn - buf_get_oldest_modification().
@retval true on success
@retval false if the smallest log group is too small to
accommodate the number of OS threads in the database server */
static MY_ATTRIBUTE((warn_unused_result))
bool
log_calc_max_ages(void)
/*===================*/
{
  ...
  log_sys->max_modified_age_async = margin
		- margin / LOG_POOL_PREFLUSH_RATIO_ASYNC;
	log_sys->max_modified_age_sync = margin
		- margin / LOG_POOL_PREFLUSH_RATIO_SYNC;

	log_sys->max_checkpoint_age_async = margin - margin
		/ LOG_POOL_CHECKPOINT_RATIO_ASYNC;
	log_sys->max_checkpoint_age = margin;

...
```

- `max_modified_age_async/max_modified_age_sync`：preflush的异步/同步阈值点
- `max_checkpoint_age_async/max_checkpoint_age`：CHECKPOINT的异步/同步阈值点。

在函数`log_checkpoint_margin`中，判断阈值点，从而执行preflush还是CHECKPOINT。

```c
static
void
log_checkpoint_margin(void)
/*=======================*/
{
  	if (age > log->max_modified_age_sync) {

		/* A flush is urgent: we have to do a synchronous preflush */
		advance = age - log->max_modified_age_sync;
	}
  
  ...
    
  if (checkpoint_age > log->max_checkpoint_age) {
		/* A checkpoint is urgent: we do it synchronously */
		checkpoint_sync = true;
		do_checkpoint = true;
	}
  ...
```

## 其他参数

- `append_on_checkpoint` ：5.7新增，checkpoint时需要额外记录的redo记录，需要在`mutex`下互斥访问。在做DDL时（例如增删列），会先将包含MLOG_FILE_RENAME2日志记录的buf挂到这个变量上。 在DDL完成后，再清理掉。主要是防止DDL期间crash产生的数据词典不一致。

  ```c
  /** Set extra data to be written to the redo log during checkpoint.
  @param[in]	buf	data to be appended on checkpoint, or NULL
  @return pointer to previous data to be appended on checkpoint */
  mtr_buf_t*
  log_append_on_checkpoint(
  	mtr_buf_t*	buf)
  {
  	log_mutex_enter();
  	mtr_buf_t*	old = log_sys->append_on_checkpoint;
  	log_sys->append_on_checkpoint = buf;
  	log_mutex_exit();
  	return(old);
  }
  ```

- `n_pending_checkpoint_writes`：大于0时，表示有CHECKPOINT正在进行。如果此时用户发起CHECKPOINT，那么该值+1`log_group_checkpoint`；结束后该值-1(`log_io_complete_checkpoint`)；

- `checkpoint_buf_ptr/checkpoint_buf`：日志中CHECKPOINT信息块的缓冲区。

- `checkpoint_lock`：checkpoint_buf写入的互斥lock

bufferpool中的每个page中有一个oldest_modification和newest_modification；在函数`add_dirty_page_to_flush_list`中，将newest_modification设置为当前刷盘日志记录的end_lsn（buf_flush_note_modification：86）。

- `log_flush_order_mutex`：InnoDB中多个bufferPool共享的flush_list上的锁；确保flush_list的顺序访问。

  > 另外，buf_pool_t的flush_list_mutex是保证flush_list的互斥访问；而不是order。

- `log_group_capacity`：表示当前日志文件的总容量，值为:(Redo log文件总大小 - redo 文件个数 * LOG_FILE_HDR_SIZE) * 0.9，LOG_FILE_HDR_SIZE 为 4*512 字节；超过该容量会重用之前的日志，如果日志对应的page没有刷盘，那么就会丢失数据。
- `next_checkpoint_no`：每次CHECKPOINT后递增
- `last_checkpoint_lsn/next_checkpoint_lsn`：最近的CHECKPOINT点与当前的CHECKPOINT点；完成之后，last<-next；

# 总结

基于以上的了解，在log_buffer中有两类偏移量：

1. ulint为单位的：redo record可拷贝写入的buffer的位置（buf_free）；redo缓冲区将要向磁盘刷盘的位置（buf_next_to_write）。
2. lsn为单位的：write_lsn、current_flush_lsn、flushed_lsn。

在BufferPool中有若干阈值，在函数`log_checkpoint_margin`进行判断，从而决定要preflush还是CHECKPOINT。

用户线程不管进行了什么变更，最终都是表现为若干个mtr；执行的mtr结束后，调用`mtr_commit()`将本地的日志copy到**logbuffer**中，同时将修改的脏页放到**flush_list**中；后续log_t根据一些阈值点，进行日志和数据的刷盘；
