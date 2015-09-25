---
layout: post
title: InnoDB——Btree与MTR的牵扯
date: 2019-05-21 16:35
header-img: "img/head.jpg"
categories: 
  - InnoDB
typora-root-url: ../../layamon.github.io
---

* TOC
{:toc}
本文结合本站另一个文章——《Btree与rwlock的互动》，一起看更好。

# Mini-transaction

![image-20191226122700730](/image/innodb-mtr/mtr.png)

InnoDB的Mini-transaction（简称mtr）是保证若干个page原子性变更的单位。一个mtr中包含若干个日志记录——mlog，每个日志记录都是对某个page——mblock；

在mtr_start后，只有`mtr_commit`一个操作；`mtr_commit`时会将mtr中的mlog和mblock（dirty page）分别拷贝到logbuffer和flushlist中。在真实事务提交时，会将该事务涉及的所有mlog刷盘，这样各个原子变更就持久化了。恢复的时候按照类型(`mtr_type_t`)调用相应的回调函数，恢复page。

在代码（5.7）中，每个mtr由`mtr_t`结构表示，主要成员位于内部类Impl中，如下：

+ `m_inside_ibuf`：mtr正在操作ibuf

+ `m_memo`：mtr持有的锁的栈

+ `m_log`：mtr日志，`m_n_log_recs`：当前有多少日志记录

+ `m_made_dirty`：产生脏页，需要刷盘；

+ `m_modifications`：进行修改，不一定需要刷盘

+ `m_log_mode`：当前mtr的日志模式（是否记录redo与刷脏）

+ `m_user_space`/`m_undo_space`/`m_sys_space`：当前mtr修改的表空间

+ `m_state`：生命周期的四种状态 

+ `m_flush_observer` ： 当`m_log_mode`表示不写redo时，dirty page的刷盘通过该参数判断(create index)。

+ `m_mtr` : 当前mtr指针（this）

Mini-transaction有如下四种状态，即，mtr的生命周期。

```c++
enum mtr_state_t {
	MTR_STATE_INIT = 0,
	MTR_STATE_ACTIVE = 12231,
	MTR_STATE_COMMITTING = 56456,
	MTR_STATE_COMMITTED = 34676
};
```

+ **初始化**：MTR_STATE_INIT；

+ **启动**：`mtr.start`后是MTR_STATE_ACTIVE；

+ **提交**：`commit`/`commit_checkpoint`：MTR_STATE_COMMITTING
  + `log_reserve_and_write_fast`：按照buf_free将记录复制到LogBuffer中。
  + `add_dirty_page_to_flush_list`：将脏页放到flushlist中。
+ **释放资源**：`release_resources`：在`add_dirty_page_to_flush_list`之后，设置当前状态为MTR_STATE_COMMITTED；

# 乐观的Insert涉及的mtr

在INSERT过程中，共有如下5个mtr（如果有索引可能会有额外的mtr），每个mtr中有若干个记录。

1. 分配undo空间

2. 写undo记录

3. 写数据

4. 2pc-prepare

5. 2pc-commit

![image-20190826165702452](/image/innodb-mtr/optimistic_insert.png)

## 1. 分配undo空间

**trx_undo_assign_undo**

+ MLOG_UNDO_HDR_REUSE：insert的undo页在提交的时候就没有用了，只是在insert事务回滚的时候才用上；所以，insert的undo分配每次都是重用之前的cache，只是修改头部数据即可；而update就是需要创建一个undopage header文件块，如下。

  ```c++
  	if (type == TRX_UNDO_INSERT) {
  		offset = trx_undo_insert_header_reuse(undo_page, trx_id, mtr);
  
  		trx_undo_header_add_space_for_xid(
  			undo_page, undo_page + offset, mtr);
  	} else {
  		ut_a(mach_read_from_2(undo_page + TRX_UNDO_PAGE_HDR
  				      + TRX_UNDO_PAGE_TYPE)
  		     == TRX_UNDO_UPDATE);
  
  		offset = trx_undo_header_create(undo_page, trx_id, mtr);
  
  		trx_undo_header_add_space_for_xid(
  			undo_page, undo_page + offset, mtr);
  	}
  	trx_undo_mem_init_for_reuse(undo, trx_id, xid, offset);
  ```

  修改undopage的头部信息的三个mtr记录

+ MLOG_2BYTES

+ MLOG_2BYTES

+ MLOG_2BYTES

  ![image-20190626135555987](/image/innodb-mtr/undopage.png)

## 2. 写undo记录

undo的操作就两种，插入和修改；

```c++
/* Operation type flags used in trx_undo_report_row_operation */
#define	TRX_UNDO_INSERT_OP		1
#define	TRX_UNDO_MODIFY_OP		2
```

**trx_undo_report_row_operation**

+ MLOG_UNDO_INSERT：在redo中，写入一条undo相关redo记录

  ![image-20190626135840069](/image/innodb-mtr/mlog_undo_insert.png)

> **注意**
>
> 上面两步都是在`trx_undo_report_row_operation`函数中，但是在写入记录之前需要分配undo空间；因此在分配undo空间的时候，单独产生一个新的mtr；然后在`trx_undo_report_row_operation`中，调用trx_undo_page_report_insert；trx_undof_page_add_undo_rec_log写入一个undo相关的redo记录。

## 3. 写数据

首先都是进行乐观的写入，即`mode!=BTR_MODIFY_TREE`，这一节中只讨论乐观的逻辑。

**page_cur_tuple_insert**

+ MLOG_COMP_REC_INSERT：插入一条记录；因为表的存储模式默认是compact，这里是compact insert。

  ![image-20190626140845880](/image/innodb-mtr/mlog_comp_rec_insert.png)

  


> 一些额外的操作
>
> - MLOG_FILE_NAME
>
>   checkpoint后对表空间的第一次修改，在mtr.commit的时候，需要写一个MLOG_FILE_NAME记录。所以这个记录可能在任何一个`commit`时出现。
>
> ```c++
> /** Write MLOG_FILE_NAME records if a persistent tablespace was modified
> for the first time since the latest fil_names_clear(). */
> inline MY_ATTRIBUTE((warn_unused_result))
> bool
> fil_names_write_if_was_clean(
> ```
>
> 
>
> 如果数据表上有索引，那么会写二级索引记录：`row_ins_sec_index_entry_low`
>
> + MLOG_8BYTES
> + MLOG_COMP_REC_INSERT

## 4. 2pc之prepare

**trx_prepare_low**

主要是设置Prepare阶段的undo的状态；包括tid与tid状态，trx_undo_set_state_at_prepare：1920

+ MLOG_2BYTES
+ MLOG_1BYTE
+ MLOG_4BYTES
+ MLOG_4BYTES
+ MLOG_4BYTES
+ MLOG_WRITE_STRING

## 5. 2pc之commit

**trx_commit**

+ MLOG_2BYTES： 设置事务结束时的undo状态，trx_undo_set_state_at_finish：1874

+ MLOG_4BYTES：设置binlog的位点，trx_sys_update_mysql_binlog_offset

  ```c++
  	mlog_write_ulint(sys_header + field
  			 + TRX_SYS_MYSQL_LOG_OFFSET_LOW,
  			 (ulint)(offset & 0xFFFFFFFFUL),
  			 MLOG_4BYTES, mtr);
  ```


# Btree悲观插入涉及的mtr

```c
  # define LIMIT_OPTIMISTIC_INSERT_DEBUG(NREC, CODE)\
  if (btr_cur_limit_optimistic_insert_debug > 1\
      && (NREC) >= (ulint)btr_cur_limit_optimistic_insert_debug) {\
          CODE;\
  }
```

插入的时候首先尝试乐观的插入——`BTR_MODIFY_LEAF`，当乐观的方式返回DB_FAIL时；进行`BTR_MODIFY_TREE`模式的插入——`btr_cur_pessimistic_insert`。

相比于`btr_cur_optimistic_insert`只需要page上的x-latch，在`btr_cur_pessimistic_insert`函数中，需要tree上的x-latch。具体实施过程中，还是分为三步，但是这里写数据会涉及到树的修改。

+ 检查锁和写undo：与之前乐观的方式类似。
+ 写数据，在调整数结构之前，为了保证操作一定成功；会在调整之前，在表空间中预留足够的空间：`fsp_reserve_free_extents`。插入数据时，按照从下向上的方式调整btree
1. 在cursor的位置插入数据，然后进行节点分裂`btr_page_split_and_insert`
  2. 在父节点上插入node_ptr，父节点同样判断是否进行分裂；进而在其父亲节点上再加node_ptr。
  3. 到达root节点，root节点分裂，提升树高。
+ 提交事务

这里主要讲一下树结构调整的操作。

## 节点分裂

**btr_page_split_and_insert**

申请一个新的page，然后将需要分出去的记录转移过去，最后将记录插入到正确的page中。

![image-20190826205715267](/image/innodb-mtr/btr_page_split_and_insert.png)

1. 找到split_rec，节点的分裂位置，无mtr

2. 分配新page

   MLOG_1BYTE： xdes_set_bit，表空间的Extent Descriptor的修改。

   MLOG_4BYTES：frag_n_used ，空闲碎片表中已经用掉的碎片。

   MLOG_INIT_FILE_PAGE2

   MLOG_4BYTES：fseg_set_nth_frag_page_no，设置碎片的pageno

3. 并初始化一个空闲的page

   MLOG_COMP_PAGE_CREATE

   MLOG_2BYTES：index level

   MLOG_8BYTES：index id

3. 找到分裂的后半节点的第一个记录

4. 尝试将新page添加到树中，`btr_attach_half_pages`

   MLOG_COMP_REC_INSERT

   MLOG_4BYTES：设置老page的next

   MLOG_4BYTES：设置新page的prev，btr_page_set_prev

   MLOG_4BYTES：设置新page的next，btr_page_set_next

   > 在btr_attach_half_pages中，调用btr_insert_on_non_leaf_level向non-leaf page中插入一个node_ptr；还是和插入叶子节点类似的逻辑，先btr_cur_search_to_nth_level，然后btr_cur_optimistic_insert；如果乐观的不行，然后悲观的插入。
   >
   > ```c
   > 			btr_cur_search_to_nth_level(
   > 				index, level, tuple, PAGE_CUR_LE,
   > 				BTR_CONT_MODIFY_TREE,
   > 				&cursor, 0, file, line, mtr);
   > ```

   > node_pointer（子节点的key和page地址）
   >
   > ```c++
   > #define	DATA_INT	6	/* integer: can be any size 1 - 8 bytes */
   > 
   > #define	DATA_SYS_CHILD	7	/* address of the child page in node pointer */
   > ```

5. 转移记录

   MLOG_COMP_LIST_END_COPY_CREATED：结束复制

   MLOG_COMP_LIST_END_DELETE：删除原page中的记录

   按照偏移来操作page的复制：

   - page_get_infimum_offset：起点
   - page_cur_insert_rec_low：插入
   - page_cur_move_to_next：迭代，直接向后移动；由于page中的record实际上是按照链表的方式组织的，找next节点需要用`rec_get_next_offs`获取偏移

6. 确定该插入到哪个page

7. 重新定位插入cursor

   MLOG_COMP_REC_INSERT

## 树层加高

**btr_root_raise_and_insert**

申请一个新的page，将原root的记录，转移到新page中；重建旧的root，作为新的root；然后对新page进行节点分裂。

![image-20190827084346097](/image/innodb-mtr/btr_root_raise_and_insert.png)

1. 申请新page

2. 初始化新page

3. 设置新page的前向和后向节点

4. 将原root中的记录复制到新page

5. 复制原root中的lock信息到新page；**这里没有mtr记录，只是内存数据的转移**

6. 重建原root节点，成为新的root

   MLOG_COMP_PAGE_CREATE：重新创建一个新page

   MLOG_COMP_REC_INSERT：只插入node_pointer，就是子节点的key和地址对应关系。

7. 新page进行分裂

   树高提升好了后，重新定位插入cursor，然后调用btr_page_split_and_insert，进行插入。



# Btree悲观删除涉及的mtr

![image-20190828202208557](/image/innodb-mtr/btr_compress.png)

很多MTR都是和INSERT类似的，这里只是简单表示Btree悲观删除的逻辑。

