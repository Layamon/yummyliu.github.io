---
layout: post
title: InnoDB——综述
date: 2019-07-09 17:06
header-img: "img/head.jpg"
categories: 
  - InnoDB
  - MySQL
typora-root-url: ../../layamon.github.io
---

* TOC
{:toc}
之前搞PostgreSQL的时候，针对PostgreSQL写了一个[总结性的概述](http://liuyangming.tech/07-2018/PostgreSQL-Overview.html)，最近搞了一段时间MySQL，主要是关注引擎层，这里按同样的套路进行总结，希望想了解InnoDB的人，看到这篇文章能有所收获。

<img src="/image/innodb-overview/arch-db.png" alt="adb" style="zoom: 50%;" />

在一个经典的RDBMS架构中，数据库分为如上几个部分：MySQL即主要提供了Relational Query Procesor的功能，InnoDB就是上图的Transaction Storage Manager部分。本文就从这四个方面阐述我所了解到的InnoDB。

# Access Method

AccessMethod可以理解为数据在外存的组织形式，简单理解为数据的存储形式加上其上面的索引。PostgreSQL的数据是按照堆表存储的，索引中的Value是堆表中的CTID，且PostgreSQL内核中自带有6种；InnoDB的数据直接放在主键索引的Value中，二级索引存储主键ID，目前有三种：Btree、Rtree（spatial index）、倒排索引（Full-Text Search Index）。这里介绍最常用的Btree；

## 文件组织

InnoDB的外存文件按照表空间（tablespace）进行组织；当启动了`innodb_file_per_table`参数后，每个数据表对应一个文件（参看系统表：`INFORMATION_SCHEMA.INNODB_SYS_DATAFILES`）。

<img src="/image/innodb-overview/InnoDB-macro.png" alt="image-20190726103704241" style="zoom: 67%;" />

- **物理**上，在每个space中，有若干个文件或者磁盘分区；每个file分为若干个segment，其中有LeafNodeSegment、NonLeafNodeSegment、rollbacksegment三种segment类型。每个segment是按照extent为单位进行伸缩，每个extent中又有若干个固定大小的page：
  - 对于uncompressed的表空间，page是16Kb；
  - 对于compressed的表空间，page是1~16Kb。

- **逻辑**上，由若干page组织成一个Btree Index，分为聚簇(一级)索引和二级索引，二级索引的val为聚簇索引的key。

[关于InnoDB数据布局的详细了解](http://liuyangming.tech/06-2019/TablespaceFormatInnoDB.html)

### IO最小单元——Page

我们都是在块设备上进行IO，文件表空间划分的最小单位就是Page，但是Page的大小与块设备的最小块不一定是一样的。Page需要加载到bufferpool中进行读写，因此，在InnoDB的bufferpool代码中，有三个需要区分的名称：

```cpp
struct buf_block_t {
  /** @name General fields */
  /* @{ */

  buf_page_t page; /*!< page information; this must
                   be the first field, so that
                   buf_pool->page_hash can point
                   to buf_page_t or buf_block_t */
  byte *frame;     /*!< pointer to buffer frame which
                   is of size UNIV_PAGE_SIZE, and
                   aligned to an address divisible by
                   UNIV_PAGE_SIZE */
...
}
```

+ **frame**是内存地址，指向具体的数据；
+ **page**是frame指向数据的状态信息，其中是需要写回到磁盘的数据；
+ **Block**代表一个Control Block（`buf_block_t`），对于每个frame对应一个ControlBlock结构进行控制信息管理，但这些信息不写回内存。

而我这里说的Page就笼统指表空间中的16k的页，在在InnoDB中有多种页类型，下面展示了FIL_PAGE_INDEX这个类型的结构，这是最常见的也是构成Btree的页类型。

![image-20190726104115317](/image/innodb-overview/page-logical-vs-physical.png)

上图左侧是一个**物理Page的结构**，前面有三个头部信息：文件头部信息，索引头部信息，段头部信息；另外，还有两个虚拟系统记录：

+ *infimum*：该记录表示比该页所有记录都小。
+ *supremum*：该记录表示比改业所有记录都大。

文件头部信息包含了前向和后向的Page的偏移，以及该页最后一次修改的LSN。

索引头部信息包含了PageDirectory数组的大小，而PageDirectory则是从Page尾部开始分配。PageDirectory中维护了该页**部分**元组的偏移，在每个元组中通过n_owned字段，表示该记录前向有几个字段没在PageDirectory中。

> **n_owned**
>
> 在InnoDB中，表是按照B+Tree的方式存储。每个页中，都有一个PageDirectory。其中保存了该页内的record的偏移量。由于不是每个record在PageDirectory中都有一个slot（这称为sparse slots），因此每个record中就有了一个n_owned变量，保存了该recored所own的record数，类似于前向元组数。
>
> 区分**n_uniq**：
>
> dict_index_t->**n_uniq**：在dict_index_t->n_fields中，从前向后，足够用来判断键唯一的列数。

### 变更最小单元——Record

在上述Page中，我们可以看到每个Record记录了其后向Record的偏移，可以认为page中的record按照链表的形式组织起来。注意这个偏移是真实Record的**数据部分**的起始位置，如下图的指针位置所示：

![image-20190726105136952](/image/innodb-overview/InnoDB-io-unit.png)

> 在innobase/include/rem0rec.ic；列出了record中各个值的偏移

在每个Record中都有两(三)个隐藏列：

- DB_TRX_ID：区别于GTID按照事务提交顺序排列，这是按照事务创建顺序排列。非锁定读的事务不会产生。
- DB_ROLL_PTR：指向该记录的前一个版本的undolog record。
- （DB_ROW_ID：如果没有主键，会创建一个。）

对于记录中的变长字段，InnoDB采用overflow page的方式进行存储，这也分为4中类型，默认的rowformat由参数**`innodb_default_row_format`**控制，默认值是`DYNAMIC`，如下：

![image-20190726105556341](/image/innodb-overview/rowformat.png)

- `REDUNDANT`：对于VARBINARY、VARCHAR、BLOB和 TEXT类型等类型，当长度超过767byte时，超过的部分会存储在额外的溢出页中。
- `COMPACT`：和REDUNANT类似，只是溢出也的存储更加紧凑，节省20%的空间。
- `DYNAMIC`：和上两个不同，当列值超过40byte时，那么行中只存储一个指针，指向附加页；然后每个附加页内还有一个指针指向后续数据，指针大小20byte。
- `COMPRESSED`：存储方式和DYNAMIC相似，只是该方式支持压缩表。在系统表空间中不可用，因此该参数不能设置为默认。

> `REDUNDANT` 和 `COMPACT` 索引键值最大为 767 byte，然而 `DYNAMIC` 和 `COMPRESSED` 支持最大为 3072 byte。
>
> 注意，在主从复制中，如果`innodb_default_row_format`在master上设置为`DYNAMIC` ，在slave上设置为 `COMPACT` ，执行如下DDL操作，主上成功，从会失败。
>
> ```sql
> CREATE TABLE t1 (c1 INT PRIMARY KEY, c2 VARCHAR(5000), KEY i1(c2(3070)));
> ```

## B+-tree

在InnoDB中，Btree是B+tree的变种，有以下特征：

+ 节点分为三类：Root、Internal、Leaf；

+ Leaf的level=0，往上递增；

+ 除root层，每层都由两个prev和next指针，指向Brother；

+ 在节点内部，按照key值组织成一个**单向链表**；链表的头部永远是Infimum，表示比所有key都小；尾部永远是Supremum，表示比所有key都大。

+ Non-Leaf节点中的记录叫node_pointer（对应叶子节点的key最小值，叶子节点的指针）
+ 没有固定的M值，不是通过M值来判断是否分裂；因为每个Btree的Page都是固定大小(16K)，其中由链表维护一个已用的Record，另外还有一个Heap空间，等待分配；在`page_cur_parse_insert_rec`进行插入，当Heap空间不够插入一个Record时，那么就插入失败，进行分裂。

那么这里就简单了解下InnoDB中B+-tree的操作，创建一个B+-tree，就是创建索引。一级索引就是重建一个表，这里主要讨论创建二级索引。

版本<5.5，创建一个索引相当于重建一个表（**CopyTable**）。

版本>=5.5，加入了FastIndexCreate特性，但只对二级索引有效（**Inplace**）；索引中只有发起createindex时刻的数据，create index时只能读不能写。

版本>=5.6.7，加入了Online Create Index的特性，创建二级索引的时候可读可写（还是会短暂block一下，但是已经影响很小了）；对于创建索引过程中对表进行的修改，放在RowLog（不是redolog）中；如果创建过程中，MySQL故障了；故障恢复时，会丢弃未完成的Index。

### 节点分裂——insert

在插入的时候，当前page放不下了。那么，按照next指针找到下一个page，如果下一个page已经满了；这时就需要进行节点分裂，大概有4步:

1. 创建一个新的page
2. 确定要分裂的page以及要分裂的位置。
3. 移动记录
4. 修改next和prev指针等节点信息。

通过如下监控信息，可以统计InnoDB中**节点分裂**的次数。

```sql
SET GLOBAL innodb_monitor_enable = index_page_splits;
SET GLOBAL innodb_monitor_enable = index_page_reorg_attempts;
select * from INFORMATION_SCHEMA.INNODB_METRICS where name = 'index_page_reorg_attempts'\G
select * from INFORMATION_SCHEMA.INNODB_METRICS where name = 'index_page_splits'\G
```

当节点分裂后，在父节点中插入一个node_ptr，父节点也需要分裂是；还是递归的调用节点分裂函数，直到不产生分裂为止；如果分裂到根节点，那么根节点产生一个新的根节点，老根节点因为满了，还是会一分为二；最终提升树高。

### 节点合并——delete

首先Btree的删除不等于SQL的delete，SQL的delete只是标记删除，执行的是delete_mark操作；具体的Btree的删除，由purge线程调度执行(或者是rollback)。

在BtreePage中有一个MERGE_THRESHOLD，默认是0.5；当BtreePage由于delete或者update（新记录的大小比历史记录小）使得容量小于0.5；那么就会通过前向和后向指针查看相邻节点是否也可以merge。

可以的话，就会和相邻节点进行合并；将后续节点的数据复制到前面的节点中，那么另一个节点就成空节点了，可以用来放新的数据。

通过如下监控，查看btree的**节点合并**操作统计。

```sql
SET GLOBAL innodb_monitor_enable = index_page_merge_successful;
select * from INFORMATION_SCHEMA.INNODB_METRICS where name = 'index_page_merge_successful'\G
```

当merge到最后，发现自己没有左右邻居节点时，那么将子节点的内容，复制到父节点上；减少树高。注意删除的时候需要将Btree进行rebalance。

> If this merge-split behavior occurs frequently, it can have an adverse affect on performance. To avoid frequent merge-splits, you can lower the `MERGE_THRESHOLD` value so that `InnoDB` attempts page merges at a lower “page-full” percentage. 

# Buffer Manager

在InnoDB中，有如下一些缓冲区；大类上和PgSQL相似都有一个放数据页的BufferPool，和一个放日志记录的LogBuffer。在CHECKPOINT的调度下，进行BufferPool刷盘；每次事务commit进行LogBuffer刷盘。

除了这两个之外，还有为了减小二级索引的写放大，引入的Change Buffer机制；为了避免数据部分写，引入的DoubleWrite Buffer等等，如下图：

![image-20190726110915433](/image/innodb-overview/InnoDB-caching.png)

本节对关键的几个buffer进行介绍：

> 另外，由于早期系统提供的内存分配器在多核场景下效果一般，InnoDB自己实现了一套内存分配器，有参数`innodb_use_sys_malloc`选择，使用参数`innodb_additional_mem_pool_size`控制大小，默认8MB；不过，现在随着系统的发展，系统提供的内存分配器在多核场景查能够提供更好的性能和扩展性。

## Change Buffer

![image-20190726111320366](/image/innodb-overview/change-buffer.png)

Change Buffer是二级索引变更的缓存，避免更新二级索引带来的二级访问；

ChangeBuffer 其不仅仅是一个内存结构，系统表空间中有专门的ChangeBuffer的区域，也是一个Btree，Key为(spaceid,pageno,counter)三元组，其中counter在每个page有一次变更后加一。Value为该page上的操作，之前其中只有insert操作（叫 InsertBuffer，但是命名上没有改变，在代码中还是叫**InsertBuffer**），后来也支持了delete/update/purge操作，成为 ChangeBuffer；

> 注意只是当**非唯一的二级索引**的块不在缓存中时，才会缓存相关操作。
>
> 索引具有唯一约束时，修改索引需要读取数据确认是否存储重复值，因此，此时必须要读取indexpage，所以不用Change Buffer。

当ChangeBuffer满了或者之前缺失的二级索引页被读取到内存中时，会按照changeBuffer中缓存的操作，merge该页的修改：

1. 随机选择changeBuffer中一个随机页。
2. 随机打开该页中的一个cursor。
3. 按照该cursor，读取之后的至多8个页。
4. 异步发起IO请求；当读取完成后，调用回调函数，执行相应的change。

## Buffer Pool

InnoDB的页面缓冲池，由`innodb_buffer_pool_size`配置，存放索引数据，默认是128MB，推荐配置为系统物理内存的80%。

在数据库中，任何BufferPool都逃不过一个刷脏的问题；为了保证恢复及时；那么每间隔一段时间，会在日志中写入一个检查点。CHECKPOINT在DBMS是指一种操作，在InnoDB中也是指redo日志中的一条记录，记录的内容为CHECKPOINT_LSN。其表示在CHECKPOINT_LSN之前的脏页已经从缓冲区写入磁盘了。而完成CHECKPOINT操作的方式主要有两种类型：

- **sharp checkpoint**: 只将commited的事务修改的页进行刷盘，并且记下最新Commited的事务的LSN。这样恢复的时候，redo日志从CHECKPOINT发生的LSN开始恢复即可。由于所有刷盘的数据都是在同一个点(CHECKPOINT LSN)之后，所以称之为sharp。

- **fuzzy checkpoint** ：如果脏页滞留到一定时间，就可能会刷盘。

在InnoDB中，除了 shutdown 的时候，正常时候都是fuzzy CHECKPOINT。刷盘前，同一个脏页可能合并了多次修改，这样省去了很多IO。在BufferPool中的页由三个list维护，分别是：free_list（可用的页）、LRU_list（最近使用的页）、flush_list（按照LSN的顺序组织的脏页，即，最近修改的页）。

由于Bufferpool是有限的，不能只是等满了才进行页换出；所以，InnoDB会持续地进行Page Clean，InnoDB中的换出有两种情况：

- BufferPool满了之后，基于LRU_list，进行页面置换。

- 基于flush_list，其中按照修改的先后顺序排列，选择最早更改的脏页(LSN)进行换出。

  为了避免将热数据换出，所以选择了最早更改的脏页。另外，由于REDO日志是固定大小且循环使用的。当最早的日志记录对应的页没有刷盘，如果此时发生了日志重用，那么更改就没有持久化；因此，当这种情况发生时，InnoDB需要夯住，等待刷盘（同样这也是为什么选择最早更改的脏页的一个原因）。
  

为了避免CHECKPOINT的频繁刷脏，pagecleaner 和用户线程会按照一些阈值点，进行提前刷脏。和这相关是一个Page Cleaner线程组，其分为两个角色协调者和工作者，如下：

<img src="/image/innodb-overview/page-cleaner.png" alt="image-20190726113541342" style="zoom: 50%;" />

Coordinator 持续设置标记位触发 worker 进行刷盘，自己触发后也会参与刷盘；各自认领不同 Bufferpool 对应的 list 进行清理。worker结束后，设置标记位通知coordinator该轮清理完成。

综上，当InnoDB执行fuzzy CHECKPOINT的时候，其会找到flush_list中的最早更改的脏页的LSN，将其作为CHECKPOINT的start，写入事务日志头中(参见源码：`log_checkpoint_margin`和`log_checkpoint`)。

而当InnoDB停机时，做法就是sharp checkpoint。首先，停止数据更新；然后，将脏页刷盘；最后，将当前的LSN写入事务日志头中。

> 另外，在Percona版本的XtraDB中，提供了一种基于代价的 adaptive CHECKPOINT；以及InnoDB后来也有了[adaptive flushing](https://dev.mysql.com/doc/refman/8.0/en/innodb-parameters.html#sysvar_innodb_adaptive_flushing)。

### Adaptive Hash Index

![image-20200106154013692](/image/innodb-overview/ahi.png)

在Buffer Pool中，缓存了IndexPage。在二级索引中，存储的是一级索引的键；因此每次查询需要两个索引查询。为了减少寻路开销，打开参数[`innodb_adaptive_hash_index`](https://dev.mysql.com/doc/refman/5.7/en/innodb-parameters.html#sysvar_innodb_adaptive_hash_index)后，可以启动AHI功能。

每次查询后，将tuple与page的映射关系存储在一个HashTable中，那么后续查询可以通过内存的HashTable进行定位，如上图，提高检索性能。在5.7中，避免锁的竞争，将AHI进行分区。

## Doublewrite Buffer

虽然叫Buffer，但是这是个磁盘中的结构。

InnoDB的页大小是16k，但是OS每次是按照4K写入，因此可能存在16K只写了一部分的情况下，系统crash了，发生了部分写，为了避免这一问题，设计了doublewrite_buffer，通过[`innodb_doublewrite`](https://dev.mysql.com/doc/refman/5.7/en/innodb-parameters.html#sysvar_innodb_doublewrite)参数打开，默认打开。

dwbuffer可以看做是存在于**系统表空间**中的一个短期的日志文件，默认2Mb。double是指表空间的page写了两次，当InnoDB刷页时，**第一次**先将页**顺序**写入到dwbuffer中，dwbuffer刷盘后，**第二次**将页刷到真正的数据文件中。

当recovery时，InnoDB检查dwbuffer中页和其本来位置的页的内容；如果通过检查页的checksum，发现数据表中的页是不一致的，那么从dwbuffer中恢复。而如果double write buffer中的页也是不完整的，那么丢弃。

性能上，尽管每次写页的时候需要写两次；但是由于将dwbuffer的写是顺序的，并且不会每个page调用一次fsync，而是一起fsync；整体性能比原来损失经验值是5%。

> 为什么要保证数据页的完整性？
>
> InnoDB采用的事physiological类型的日志，这样的日志需要写的数据少，但是要求数据页是一致的，否则不能保证数据页恢复的正确性。
>
> double write buffer本身发生了部分写怎么办？
>
> 没事，因为对应的表空间的数据页还没开始写，恢复的时候也不会用dwbuffer中的进行覆盖。

## Log Buffer

InnoDB的表发生变更的时候，首先将变更存储在Log Buffer中，然后写入到Redo日志中。其由`innodb_log_buffer_size`设置，默认16MB；当大事务中的insert/update/delete比较多时，将提高该参数可以减少磁盘IO；通过观察系统统计`innodb_log_waits`，可以得知是否需要调大LogBuffer。

```sql
SELECT name, subsystem, status FROM INFORMATION_SCHEMA.INNODB_METRICS;
```

关于LogBuffer的更详细介绍，参看下节InnoDB日志管理。

# Lock Manager

在MySQL中，在SQL层中，会有一个MDL维护元数据信息，主要用在DDL场景中。对于InnoDB作为引擎的表，表上的DML操作的锁，在InnoDB内实现；可以分为两部分：事务锁（mutex/rwlock）和线程锁（latch）。

![image-20200510095508957](/image/innodb-overview/innodb-lockmanager.png)

## MGL

一般从两个维度描述一个锁：粒度和力度。在InnoDB中，从粒度上分为表锁和行锁；在不同的粒度上，又根据力度的不同分为不同类型。但都是在一个结构中表示`lock_t`，根据`is_record_lock`（提取type_mode的标记位）来判断锁的粒度：表or行。

type_mode是一个无符号的32位整型，从低位排列，第1字节为lock_mode，有如下5中类型；

```c
/* Basic lock modes */
enum lock_mode {
	LOCK_IS = 0,	/* intention shared */
	LOCK_IX,	/* intention exclusive */
	LOCK_S,		/* shared */
	LOCK_X,		/* exclusive */
	LOCK_AUTO_INC,	/* locks the auto-inc counter of a table in an exclusive mode */
	LOCK_NONE,	/* this is used elsewhere to note consistent read */
	LOCK_NUM = LOCK_NONE, /* number of lock modes */
	LOCK_NONE_UNSET = 255
};
```

第2字节为lock_type；

```c
/** Lock types */
/* @{ */
#define LOCK_TABLE	16	/*!< table lock */
#define	LOCK_REC	32	/*!< record lock */
#define LOCK_TYPE_MASK	0xF0UL
```

再高的字节为行锁的类型标记：

```c
#define LOCK_ORDINARY	0	/*!< this flag denotes an ordinary
				next-key lock in contrast to LOCK_GAP
				or LOCK_REC_NOT_GAP */
#define LOCK_GAP	512	
#define LOCK_REC_NOT_GAP 1024	
#define LOCK_INSERT_INTENTION 2048 
#define LOCK_PREDICATE	8192	/*!< Predicate lock */
#define LOCK_PRDT_PAGE	16384	/*!< Page lock */
```

### 表锁

在MySQL中，表锁有排他X和共享S两种力度。

当我们要对某个page中的一行记录进行锁定时，需要对上层的table加意向锁——IS/IX，意为该事务中有意向对表中的某些行加X、S锁。意向锁是InnoDB存储引擎自己维护的，用户无法手动添加意向锁。

> 意向锁主要方便了检查表级别和行级别锁的冲突

注意意向锁是表级别的锁，和表锁X/S有相应的兼容性判断如下：

| -    | IS               | IX     | S      | X                |
| ---- | ---------------- | ------ | ------ | ---------------- |
| IS   | 兼容(compatible) | 兼容   | 兼容   | 不兼容(conflict) |
| IX   | 兼容             | 兼容   | 不兼容 | 不兼容           |
| S    | 兼容             | 不兼容 | 兼容   | 不兼容           |
| X    | 不兼容           | 不兼容 | 不兼容 | 不兼容           |

另外，还有一种特殊的表锁：Auto-Inc Lock，当有AUTO_INCREMENT列时，插入数据时会有这个锁，由参数**innodb_autoinc_lock_mode**控制自增长的控制算法。

![image-20190726121911562](/image/innodb-overview/ailock.png)

默认地，innodb_autoinc_lock_mode=1，此时对于任何insert-like的语句都需要获取AI锁。

当innodb_autoinc_lock_mode=2，这是对于已知行数的simple insert，那么可以预留一段空间，在语句执行期间不需要AI lock，而未知行数的插入需要去AI表锁。

innodb_autoinc_lock_mode=0是为了和前向版本行为兼容的参数。

### 行锁

在InnoDB事务中，DDL不能放在事务中。因此，事务锁主要就是DML引起的行锁，默认的存储引擎InnoDB实现的就是行锁，有X/S两种模式，以及如下四种类型：

- **Record Lock**：基于主键锁定某个记录

- **Gap Lock**：要求隔离级别是RR，并且innodb_locks_unsafe_for_binlog=0；这时，如果查询走非唯一索引或者查询是范围读，那么会加GapLock。

  > `innodb_locks_unsafe_for_binlog`
  >
  > 该参数的作用和将隔离级别设置为 READ COMMITTED相同，是一个将要废弃的参数。

- **Next-Key Lock**：前提是启用了GapLock，其是Record Lock和该Record之前区间的Gap Lock的结合；否则，只是recordLock。

  当给一个record加x/s锁时，其实是给该record加recordlock，加上该record之前的一个gap的gaplock；即给一个左开右闭的区间加了锁。避免幻读。

  当查询的索引具有唯一性时，Next-Key Lock降级为Record Lock。

- **Insert Intention Lock**：Insert语句的特殊的GapLock；gap锁存在的唯一目的是防止有其他事务进行插入，从而造成幻读。假如利用gap锁来代替插入意向锁，那么两个事务则不能同时对一个gap进行插入。因此为了更高的并发性所以使用插入意向gap锁；插入意向锁的使得insert同一个间隙的不同键值的查询之间不阻塞，提高并发；但是还是会阻塞update、delete操作。

  当多个事务在**同一区间**（gap）插入**位置不同**的多条数据时，事务之间**不需要互相等待**

> **监控视图**
>
> ```sql
> select * from information_schema.innodb_trx\G; -- 查看当前的事务信息
> select * from information_schema.innodb_locks\G; --查看当前的锁信息
> select * from information_schema.innodb_lock_waits\G; --- 查看当前的锁等待信息
> --可以联表查，查找自己想要的结果。
> select * from sys.innodb_lock_waits\G; -- 查看当前的锁等待信息
> show engine innodb status\G;
> ---还可以通过当前执行了执行了什么语句
> select * from  performance_schema.events_statements_current\G; 
> show full processlist;
> ```

## MVCC：ReadView

InnoDB中一方面通过锁来进行并发控制（**一致性锁定读**，select for update/select for shared/update where / delete where）；另外，在默认情况下。事务第一次读的时候会通过undo空间提供的多版本，构建一个readview，提供**一致性非锁定读**（这就是RR级别下，可重复读的实现方式，比如，`mysqldump --single-transaction`时，就是基于RR级别的读快照进行导出），这样能够提高读写之间的并发，读不阻塞写。

具体地，是通过ReadView机制实现的，如下图：

![image-20190726122527556](/image/innodb-overview/readview.png)

ReadView是在某一时刻（语句开始，或者事务开始）获取可以看做是三个信息的组合：

+ up_limit：获取时刻已经提交事务的TID最大值，小于等于该ID的数据是可见的。
+ low_limit：获取时刻当前活跃事务的TID最大值，大于等该ID的数据是不可见的。
+ ids：正在活跃的事务ID集合，该集合中ID对应的数据不可见。

对于每个RECORD，其中有一个回滚段指针；通过该指针可以构建该record的历史版本链。那么定位到某个元组，则通过该链，遍历直到找到第一个可见的数据版本，就是最新可见的数据。

## Latch

以上的事务锁是和Transaction相关的并发控制，对象是record或者table；作为多线程服务，MySQL内部还有线程锁；对象是内存中的共享单元，比如buf_page中的page，即`buf_pool->page_hash`；

page_hash是`hash_table_t`类型的hash表；其中的sync_obj就是该hash表中的元素的锁，放在一个union类型中，有两种类型：mutex和rw_lock。

+ **mutex**，实际上是基于Futex机制实现的FutexMutex（Linux Fast userspace mutex）；用在内存共享结构的串行访问上。

- Dictionary mutex（Dictionary header)
- Transaction undo mutex，Transaction system header的并发访问，在修改indexpage前，在Transaction system的header中写入一个undo log entry。
- Rollback segment mutex，Rollback segment header的并发访问，当需要在回滚段中添加一个新的undopage时，需要申请这个mutex。
- lock_sys_wait_mutex：lock timeout data
- lock_sys_mutex：lock_sys_t
- trx_sys_mutex：trx_sys_t
- Thread mutex：后台线程调度的mutex
- query_thr_mutex：保护查询线程的更改
- trx_mutex：trx_t
- Search system mutex
- Buffer pool mutex
- Log mutex
- Memory pool mutex 
- …...

+ **rw_lock（sync0rw.h）**，读写操作的并发访问，其中有两种锁粒度：index和block。有三种力度：S，X，SX（5.7新加的）。主要用在如下些场景中：
  + Secondary index tree latch ，Secondary index non-leaf 和 leaf的读写
  + Clustered index tree latch，Clustered index non-leaf 和 leaf的读写
  + Purge system latch，Undo log pages的读写，
  + Filespace management latch，file page的读写
  + 等等

这里主要介绍rwlock的机制：参见另一篇blog——[《Btree与rwlock》](http://liuyangming.tech/07-2019/InnoDB-Lock.html)。

# Log Manager

数据库日志是保证事务的ACID的重要机制，按照数据恢复的一般算法——**ARIES**，数据库的日志一般有两种：REDO和UNDO；另外，MySQL还有一个BinLog，但其不属于InnoDB。

> ARIES的三个原则
>
> - 日志先写：Write ahead logging
> - 重做历史：Rpeating history during Redo
> - 记录变更：Logging change during Undo

而按照数据库日志存储内容，一般分为三种日志类型：

- 纯物理日志：记录数据页的物理字节位置和内容。
- 纯逻辑日志：记录更改的语句。
- 物理的逻辑日志（Physiological Log）：记录物理页中更改的逻辑，这里的逻辑不是SQL逻辑，而是物理页中的变更操作。

现代DBMS中，一般采用的是Physiological方式。其日志体积更小，恢复更快，并且解决了逻辑日志的非幂等性。

> **逻辑日志的非幂等性**
>
> 比如，逻辑日志中有一个insert a in A，其需要更新数据和索引页。但是crash的时候，可能只更新了data，没有更新index。那么，重新执行insert语句，就不能保证正确性。

## Mini-Transaction(MTR)

MTR是保证InnoDB对若干个page变更的原子性的机制，一个mtr中包含了两类信息：

+ 对若干page的修改的**logrecord**

+ 相应index/tablespace/page上的**lock**，或者**buffer-fixes**（对bufferpage的引用）；


由于MTR是一个原子操作，只有在mtr.commit()时，会将用户线程的mtr复制到logbuffer中（mtr.commit()时，还会释放持有的锁）。因此不存在完成一半的mtr，也就不存在mtr的rollback。

为了避免mtr获取indexpage的锁时，发生死锁；

+ 一个mtr中，只能变更一个index；
+ 只能前向遍历：获取下一个page的锁时，必须释放前一个page的锁。

关于MTR更多内容，参见另一篇blog——[《MTR与Btree》](http://liuyangming.tech/05-2019/InnoDB-Mtr.html)。

## Redo LOG

在InnoDB中，其redo日志就是一种Physiological的日志。其中记录了数据页上的所有变更操作。每个记录的形式如下：

![innodb-redo-rec](/image/innodb-overview/innodb-redo-rec.png)

redo日志是按照磁盘扇区大小（**512byte**）的块存储日志记录，redolog位于`$innodb_log_group_home_dir/ib_logfile`中，可能有多个文件。

```sql
mysql> show global variables like '%innodb_log_file%';
+---------------------------+----------+
| Variable_name             | Value    |
+---------------------------+----------+
| innodb_log_file_size      | 50331648 |
| innodb_log_files_in_group | 2        |
+---------------------------+----------+
2 rows in set (0.01 sec)
```

和PostgreSQL的max_wal_size类似，ib_logfile的大小有上限（`innodb_log_file_size * innodb_log_files_in_group < 512GB`）；如果设置的过小，为了确保重用redo日志时，被重用的redo日志对应的页已经刷盘，那么可能会频繁的刷脏，这时可以调大redo的整体大小；业务**update的吞吐量**和**CHECKPOINT回收redo文件**都和这个相关。

因为，我们recovery的时候需要重做这些记录，但是我们并不知道crash的时候相应记录的修改有没有落盘，因此可能会多次执行，所以其中记录保证幂等性([idempotent](http://books.google.com/books?id=S_yHERPRZScC&lpg=PA543&ots=JJtxVQOEAi&dq=idempotent gray&pg=PA543#v=onepage&q=idempotent gray&f=false))。其实当recovery的时候，和PostgreSQL类似会比较日志的lsn与页面的lsn的大小，只会重做lsn大的日志。

> **双一保证**
>
> 默认将`innodb_flush_log_at_trx_commit`设置为1，保证日志Write Ahead；除非系统层面保证了数据不会丢失，如**battery backed raid card**。
>
> 另外还有上层MySQL的`sync_binlog`；也需要设置为1，保证binlog落盘。

为了提高整体的吞吐量，InnoDB采用组提交的方式，从而减少刷盘的次数（LogBuffer）。

> 这里理解就是服务的吞吐量而不是响应时间，因为如果组没有满，就不刷盘的话，是不是就影响了前面事务的响应时间。在PostgreSQL中通过`commit_siblings`配置一个组提交启用的下限，避免系统负载比较低的时候的刷盘等待。

关于Logbuffer更详尽的介绍，参见另一篇blog——[《LogBuffer与事务提交过程》](http://liuyangming.tech/06-2019/LogBufferAndBufferPool.html)。

## Undo LOG

InnoDB中可以有专门的UNDO表空间（5.6之后可以启用独立undo表空间，之前是放在系统表空间ibdata0中）。在ibdata0中，存储一个trx_sys结构，其中维护了事务相关的信息，就包括了所有的128个回滚段，如下图。

<img src="/image/innodb-overview/trx_sys.png" alt="image-20190718154613462" style="zoom: 67%;" />

> 由`innodb_rollback_segments`定了rollback segment的个数([1,128]），默认128个。每个rseg中，有1024个slot(用了存放undo log page)；
>
> 128个rseg只有后96个是给用户表使用的，并且每个undo log只能同时给一个事务使用，因此整体的事务并发上限为96*1024。
>
> 注意是回滚段，段存在于表空间中；那么有如下位置映射：
>
> + rollback seg0位于ibdata1中
> + [1,32]，放在ibtmp1临时表空间中。
>
> + [33,+)，如果没有开启独立表空间，那么用户回滚段都在ibdata1这个系统表空间中。

<img src="/image/innodb-overview/undo-map.png" alt="image-20200510095111559" style="zoom:50%;" />

如上图，一个事务如果只对应一个UNDOpage（实际上可能不止），那么最多支持96*1024个事务并发。

在InnoDB中，Undo日志记录了行的旧值，当需要找到旧版本的数据时，需要按照undo链进行寻找。有数据变更的事务都需要一个undo record，包含三项信息：

- `Primary_Key_Value`：包括页号和物理位置。
- `Old_trx_id`：更新该行的事务号
- `Old_values_on_that_row`：更新前的数据值。

在MySQL中，事务默认是只读事务；如果后期发现有临时表的写入，就分配**临时表的rseg**；若判断为读写事务，则开始分配事务ID和**普通rseg**。

对于Insert插入的新数据，没有任何老事务可能会读取该新行，所以一般在事务结束后，就将undo log删除，这部分是`insert_undo`。而对于Update和delete的旧数据，需要进行保留，在InnoDB中将其归为一类：`update_undo`。

回滚段是资源是有限的，系统有purge线程定期回收回滚段；每个回滚段上有一个引用计数(`trx_ref_count`)，如果计数为0，表示没有事务在使用，那么purge线程就对其进行回收；回收时，会将该rseg标记为`skip_allocation`，表示该段暂缓分配。

## Crash Recovery

一般恢复分为三步，首先扫描数据；然后基于Redo进行重做；最后基于Undo进行回滚。

在InnoDB中，分为4步：

1. dwbuffer：首先恢复 Doublewrite Buffer中的数据

2. Scan：从磁盘中读取redo日志记录，插入按照LSN排序的红黑树中。

3. Redo：`recv_recovery_from_checkpoint_start`，将重做redo记录，并脏页插入到flush_list中；另外，undo记录也是受redo保护的(临时表除外临时表不记redo），也可以从redo中恢复。

4. Undo：`dict_boot`初始化数据字典子系统；`trx_sys_init_at_db_start`初始化事务子系统，undo段的初始化在此完成；

   <img src="/image/innodb-overview/init-undo.png" alt="image-20190529105306507" style="zoom:150%;" />

   对于Active的事务，进行回滚；
   
   对于Prepare的事务，如果对应的binlog已经提交，那么提交，否则回滚。

# Reference

[worklog-mysql-5223](https://dev.mysql.com/worklog/task/?id=5223)

[InnoDB Page Merging and Page Splitting](https://www.percona.com/blog/2017/04/10/innodb-page-merging-and-page-splitting/)