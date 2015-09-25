---
layout: post
title: InnoDB的Btree操作——乐观与悲观操作机制
date: 2019-06-11 10:51
header-img: "img/head.jpg"
categories: jekyll update
tags:
  - InnoDB
typora-root-url: ../../layamon.github.io
---

* TOC
{:toc}
# INSERT流程

了解的redo大致的操作流程，我们以Insert为例，了解一下整理操作过程。

理想情况下的插入，不考虑页面分裂，调用了4次mtr_commit()，分别是：

1. 分配undo段空间
2. 写undo记录
3. 写数据行
4. 2pc commit

## 整体流程

![image-20190611161857692](/image/mysql-insert.png)



## 聚集索引的插入

插入的时候会判断是插入聚集索引还是二级索引，首先考虑聚集索引的插入，即`row_ins_clust_index_entry_low`函数，如下：

![image-20190613134743737](/image/row_ins_clust_index_entry_low.png)

## BtreePage的插入

具体树上的插入细节在`btr_cur_optimistic_insert`中，在MySQL的BufferPool中，分为16K大小的frame；Btree上有一个tree cursor(`btr_cur_t`)和page cursor(`page_cur_t`)。在btr_cur_optimistic_insert函数中，基于之前找到的tree cursor进行插入操作，如下：

![image-20190613173809214](/../Desktop/btr_cur_optimistic_insert.png)

的插入操作`page_cur_insert_rec_low`中，在MySQL的Page中，记录是按照链表的方式组织的，Header中有一个PageDirectory，只是维护了部分记录的位置，因此在每个记录中有一个N_owned字段，用来记录该记录之前**连续有多少没有在PageDirectory中索引记录**。

![image-20190613175716625](/../Desktop/InnoDB-page-directory.png)

> Record的物理结构：
>
> ![image-20190614144541337](/image/physical-record-struct.png)

在Page中插入会pagedirectory和n_owned等信息。

![image-20190613175907422](/image/page_cur_insert_rec_low.png)

## Insert写Redo日志

数据写完了，之后开始写redo日志，由`page_cur_insert_rec_write_log`负责。

![image-20190614155451481](/image/page_cur_insert_rec_write_log.png)

具体的头部信息的写入方式如下，可以对比上文中的Record结构来看：

![image-20190614155652419](/image/mlog_open_and_write_index.png)



