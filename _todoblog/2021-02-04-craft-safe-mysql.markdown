---
layout: post
title: Crash Safe Slave
date: 2021-02-04 19:43
categories:
  - MySQL
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}

> crash safe slave 又叫 *transactional* replication

MySQL的主从复制将复制信息分别放在master.info和relay-log.info中，在每次事务完成后更新该文件；

- master.info：master的链接信息 与 已经发送给slave的binlog信息
- relay-log.info：slave的回放信息 与已经回放的binlog信息。

而如果在这之间发生Crash，那么重启的时候，就会重做最新的事务，因为重复更新主键，这会导致从库Stop；虽然可以通过一些办法规避这个问题，不影响可靠性（reliability），但是很别扭；而如果将位点信息和事务一起持久化到引擎中，那么可以很容易的解决这个问题。

> 比如：
>
> 1. 从库设置SQL_SLAVE_SKIP_COUNTER，跳过这些事务
> 2. 溢出这个主键，但是会出现重复元素；业务需要处理这个问题。

进而可以配置参数[master_info_repository](http://dev.mysql.com/doc/refman/5.6/en/replication-options-binary-log.html#option_mysqld_master-info-repository)和[relay_log_info_repository](http://dev.mysql.com/doc/refman/5.6/en/replication-options-binary.html#option_mysqld_relay-log-info-repository)，将这两个文件的信息存储在系统表中：

```
mysql> select * from slave_master_info\G
mysql> select * from slave_relay_log_info\G
```

默认地，系统表在MyISAM中，可以将这两个表的SE改成支持事务的。

```
ALTER TABLE mysql.slave_master_info ENGINE = InnoDB;
ALTER TABLE mysql.slave_relay_log_info ENGINE = InnoDB;
```

slave_relay_log_info在每次事务内一起更新，slave_master_info 根据**sync_master_info**配置来更新。



总结，实现Crash Safe Slave需要：

- Set [relay-log-info-repository](http://dev.mysql.com/doc/refman/5.6/en/replication-options-slave.html#option_mysqld_relay-log-info-repository) to TABLE
- Set [relay-log-recovery](http://dev.mysql.com/doc/refman/5.6/en/replication-options-slave.html#option_mysqld_relay-log-recovery) = 1
- 使用 [transactional storage engine](http://dev.mysql.com/doc/refman/5.6/en/innodb-storage-engine.html)











Links

[1. MySQL crash-safe replication](http://mysqlmusings.blogspot.com/2011/04/crash-safe-replication.html)

[2. MySQL crash-safe replication-2](https://mysqlserverteam.com/relay-log-recovery-when-sql-threads-position-is-unavailable/)

[3. crash safe slave and master in RocksDB](https://github.com/facebook/mysql-5.6/commit/84a529dd93c1fd3510577050ef04c2c635161f92)

