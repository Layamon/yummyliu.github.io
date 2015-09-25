---
layout: post
title: 分布式事务
date: 2019-12-19 12:13
categories:
  - DBMS
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
在[分布式杂谈](http://liuyangming.tech/11-2018/Distributed_DBMS.html)中，简单提到了分布式事务；但是只说了ACID中的A（atomic）；DB中必然不只有一个事务，那么还有一个很关键的特性是I（isolation）。

说起I，肯定要说一下隔离级别。在SQL92中定义了标准的隔离级别，可以认为SQL92的隔离级别是在基于锁的并发控制之下的隔离级别。那么级别越大，锁的力度越大。然而，还有一种基于多版本的并发控制，在多版本下没有了SQL92中的异常，但是有了一些新的异常（比如，write skew；SELECT … FOR UPDATE）但是也不是完全等同于SERIALIZATION。

> Snapshot isolation is a guarantee that all reads made in a transaction will see a consistent snapshot of the database, and the transaction itself will successfully commit only if no updates it has made conflict with any concurrent updates made since that snapshot.

那么，分布式事务的不同实现方案能够达到那种隔离级别呢？本文就以这个角度来入手学习各个分布式事务解决方案。

2PC

# Percolator

a variant of two phase commit；To address the disadvantage of coordinator failures, percolator doesn’t use any node as coordinator, instead it uses one of the keys involved in each transaction as a coordinator. We call the coordinating key the primary key, and the other keys secondary keys. Since each key has multiple replicas, and data is kept consistent between these replicas by using a consensus protocol (Raft in TiKV), one node’s failure doesn’t affect the accessibility of data. So Percolator can tolerate node fails permanently.

Such a write-write conflict will cause the transaction to abort.





In TiKV, the whole transaction is restarted with a new timestamp.
