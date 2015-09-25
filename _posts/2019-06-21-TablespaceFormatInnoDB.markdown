---
layout: post
title: InnoDB——Data Layout
date: 2019-06-21 09:47
header-img: "img/head.jpg"
categories: 
  - InnoDB
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
如下图，我用不同颜色表示了MySQL中数据在内存和外存中的位置。其中SQL层主要会维护自己元信息（frm），而InnoDB层也会维护自己的元信息以及其他数据，本文主要关注InnoDB的数据。

![image-20191121100530354](/image/innodb-layout/1121-highlevel.png)

# 内存结构简述

内存中主要就是Buffer Pool以及一些其他的辅助缓存，比较重要的有Change Buffer，AHI，这些结构本文暂不讨论，这里先讨论BufferPool。

BufferPool的空间由`srv_buf_pool_size`（总大小）和`srv_buf_pool_instances`控制。

关于bufferpool，按照层级划分有如下结构：

![image-20191226162157502](/image/innodb-layout/1121-bufferpool.png)

最大的是buf_pool_t表示一个bufferpool instance，其中安装buf_chunk_t进行页面分配，默认大小为128MB（在8中可动态调整）；具体的数据块就由buf_block_t表示，需要区分下面三个概念：

+ **frame**代表内存的虚拟地址空间的一个16k单元，其是一个内存地址，指向实际的数据。
+ **page**（buf_page_t）是该页上的相关信息。
+ **Block**代表一个Control Block（`buf_block_t`），对于每个frame对应一个ControlBlock结构进行控制信息管理，但这些信息不写回内存。

每个BufferPool将不同类型的Page组织成对应的List，便于快速找到需要类型的page；

+ Free List：空闲Page所在的链表，便于快速取出一个可用页。

+ LRU List：最近访问过的Page所在的链表，在InnoDB中，LRUList之上还有一个PageHash，避免List的顺序遍历；同时将List分为Young和Old，并采用了更加精细的LRU策略，避免频繁更改List。Page通过`buf_page_get_gen`读取，有不同的读取模式，默认的是`BUF_GET`，大概的读逻辑如下图，新页都是通过`buf_LRU_add_block(TRUE)`先放到OLD区：

  ![image-20200310160649552](/image/innodb-layout/page_get.png)

+ Flush List：在mtr_commit时，将相应的脏页挂在FlushList上，等待刷盘；FlushList是LRUList的一个子集；FlushList中的页是按照page->oldest_modification_lsn降序排列（MySQL5.7)；checkpoint_lsn会根据每个FlushList的oldest_modification_lsn进行判断。

另外，BufferPool内还有一个page_hash，这样定位page时，不需要每次都遍历list。

> 除BuffPool之外，还有一个dictionary cache，dictionary cache是全局共享对象的cache，这其中的数据同样在系统表空间ibdata1中存在。比如，这里不做进一步讨论。
>
> 1. tablespace defintion
> 2. schema definition
> 3. table definition
> 4. stored program definition
> 5. character set definition
> 6. collation definition

# 外存结构简述

在外存中，按照表空间（space）进行组织；当启动了`innodb_file_per_table`参数后，每个数据表对应一个文件（参看系统表：`INFORMATION_SCHEMA.INNODB_SYS_DATAFILES`）。

![image-20191121101335978](/image/innodb-layout/1121-disk.png)

而对于全局共享的对象，需要放在共享的表空间SysSpace（全局变量：`innodb_data_file_path`，默认为ibdata1，spaceid=0）中，这之中除了每个表空间都有的对象（ibuf_bitmap、inode等）外，其中还有如下对象：

+ 公共对象

  1. Change Buffer Tree

     Insert Buffer是二级索引变更的缓存；之前只有insert操作，后来也支持了delete/update/purge操作，成为ChangeBuffer；但是命名上没有改变，在内存中还是叫InsertBuffer；在外存中，放在ibuf文件中。

  2. Transaction Sys Header：事务信息

  3. Dict ：目录信息

+ 0号回滚段
+ Double Write Buffer

> 除了space0是共享的以外，我们还可以通过create tablespace创建[General Tablespace](https://dev.mysql.com/doc/refman/5.7/en/general-tablespaces.html)，同样是全局共享的。
>
> InnoDB Instrinsic Tables：InnoDB引擎内部的表，没有undo和redo，用户不可创建，只供引擎内部使用。

类似地，InnoDB在space中逐级的切分下去，直到最后的Record。每个space有若干个**file**或者**diskpartition**；每个file分为若干个**segment**；其中有LeafNodeSegment、NonLeafNodeSegment、RollbackSegment，见[General Tablespace](https://dev.mysql.com/doc/refman/5.7/en/general-tablespaces.html)。每个segment中有若干个固定大小的**page**，Page可以选择进行压缩：

+ 对于uncompressed的表空间，page是16Kb；
+ 对于compressed的表空间，page是1~16Kb。

<img src="/image/innodb-layout/1121-space.png" alt="image-20191121102020358"  />

注意Segment概念只是逻辑上的概念，并不是物理上的结构。物理上Page的组织形式是Extent，每次分配按照Extent进行分配，这有点像BufferPool的chunk。

> 另外对于Record，InnoDB需要与SQL层进行数据转换（`row_sel_store_mysql_field` vs `row_mysql_store_col_in_innobase_format`），
>
> + 对于一个整形数据，MySQL采用的是小端存储，InnoDB采用大端存储。
>
> ![Big Endian and Little Endian](/image/innodb-layout/bigLittleEndian.png)
>
> + 有精度的浮点数，MySQL和InnoDB存储方式相同。

## ibd文件

> 关于InnoDB的文件格式，可以通过[innodb_ruby](https://github.com/jeremycole/innodb_ruby)学习。

基于以上的讨论，当我们打开参数（`innodb_file_per_table`）时，对于一个ibd文件就是对于的表空间。

这里我创建一个测试表t1，包含一个一级索引和一个二级索引，如下：

```sql
mysql> show create table t1\G
*************************** 1. row ***************************
       Table: t1
Create Table: CREATE TABLE `t1` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `salary` int(11) DEFAULT NULL,
  `name` varchar(255) DEFAULT '',
  PRIMARY KEY (`id`),
  KEY `i1` (`salary`)
) ENGINE=InnoDB AUTO_INCREMENT=103 DEFAULT CHARSET=utf8
1 row in set (0.00 sec)
mysql> select *
    -> from
    -> INFORMATION_SCHEMA.INNODB_SYS_TABLES
    -> join INFORMATION_SCHEMA.INNODB_SYS_DATAFILES on INFORMATION_SCHEMA.INNODB_SYS_TABLES.space = INFORMATION_SCHEMA.INNODB_SYS_DATAFILES.space
    -> join INFORMATION_SCHEMA.INNODB_SYS_INDEXES on INFORMATION_SCHEMA.INNODB_SYS_TABLES.TABLE_ID = INFORMATION_SCHEMA.INNODB_SYS_INDEXES.TABLE_ID
    -> where INFORMATION_SCHEMA.INNODB_SYS_TABLES.TABLE_ID = 40\G
*************************** 1. row ***************************
       TABLE_ID: 40
           NAME: testdb/t1
           FLAG: 33
         N_COLS: 6
          SPACE: 23
    FILE_FORMAT: Barracuda
     ROW_FORMAT: Dynamic
  ZIP_PAGE_SIZE: 0
     SPACE_TYPE: Single
          SPACE: 23
           PATH: ./testdb/t1.ibd
       INDEX_ID: 41
           NAME: PRIMARY
       TABLE_ID: 40
           TYPE: 3
       N_FIELDS: 1
        PAGE_NO: 3
          SPACE: 23
MERGE_THRESHOLD: 50
*************************** 2. row ***************************
       TABLE_ID: 40
           NAME: testdb/t1
           FLAG: 33
         N_COLS: 6
          SPACE: 23
    FILE_FORMAT: Barracuda
     ROW_FORMAT: Dynamic
  ZIP_PAGE_SIZE: 0
     SPACE_TYPE: Single
          SPACE: 23
           PATH: ./testdb/t1.ibd
       INDEX_ID: 42
           NAME: i1
       TABLE_ID: 40
           TYPE: 0
       N_FIELDS: 1
        PAGE_NO: 4
          SPACE: 23
MERGE_THRESHOLD: 50
2 rows in set (0.00 sec)
```

表空间的头部几个重要的页的信息：

<img src="/image/innodb-layout/1121-idbsummary.png" alt="image-20191121103020388"  />

1. FSP_HDR页：该页是对整个表空间进行管理的头部页

2. IBUF_BITMAP页：为了避免ibuf的合并造成数据页的分裂合并，在ibufbitmap中保存了叶子节点的可用空间与其他状态（内容比较复杂，将在独立的changebuffer章节阐述）。

3. INODE页：外存空间的管理基本单位是Page，而连续的Page在逻辑上有组织成Segment；Segment只是一个逻辑的组织单位，一个Segment在物理上对应若干个**file segment inode**，简称INODE。这里的INODE页中包含很多inode entry，每个inode entry可以创建一个逻辑的segment，如下图，INODE entry的头部标记一个。

   <img src="/image/innodb-layout/1121-inodeentry.png" alt="image-20191121110059047" style="zoom: 67%;" />

4. INDEX页：索引页，这是最常见的页类型；

在InnoDB中有多种页类型，以上我就介绍了3种。那么，对于一个表的独立表空间中的页是如何管理的呢？表未添加二级索引初始化时，为

![image-20191121145815233](/image/innodb-layout/1121-c1.png)

只有一个索引页，即主键索引。

然后插入了1000条数据，

![image-20191121145948559](/image/innodb-layout/1121-c2.png)

此时，在原索引页之后多了一个索引页，由prev和next看出，这是索引数据页。

然后创建了一个新的索引i2

![image-20191121150202468](/image/innodb-layout/1121-c3.png)

在原索引页之后，追加了一个新的索引页，存放二级索引。

那么，一个表的索引页只是这么追加，如何找到每个索引的root page呢？

这个信息是在单独的InnoDB的系统表中存储的，主要有以下四个：

```sql
SELECT * FROM INFORMATION_SCHEMA.INNODB_SYS_TABLES ;
SELECT * FROM INFORMATION_SCHEMA.INNODB_SYS_COLUMNS ;
SELECT * FROM INFORMATION_SCHEMA.INNODB_SYS_INDEXES;
SELECT * FROM INFORMATION_SCHEMA.INNODB_SYS_FIELDS;
```

在INNODB_SYS_INDEXES中，根据了(spaceid，pageno)，定位每个索引的root。

而在ibd文件内部，由**FSP_HDR**、**INODE**和**XDES**页中的定义了一些外存的list来管理表空间的使用。
