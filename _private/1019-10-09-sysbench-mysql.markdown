---
layout: post
title: 
date: 2019-10-09 10:20
header-img: "img/head.jpg"
categories: jekyll update
tags:
typora-root-url: ../../layamon.github.io
---
*  TOC
{:toc}


# 测试步骤

1. 初始化数据目录，记住mysql初始root密码，gLB>aRxtV0vd

```bash
/data/mysql-files/bin/mysqld --defaults-file=/data/mysql-files/etc/my.cnf --initialize --debug=d,o
```



2. 启动mysqld

```bash
/data/mysql-files/bin/mysqld --defaults-file=/data/mysql-files/etc/my.cnf --user=root --datadir=/data/mysql-files/var
```

3. 修改root密码

```bash
/data/mysql-files/bin/mysql --connect-expired-password -u root -P 3306 -p < reset_pass.sql
```

> **reset_pass.sql**
>
> ```sql
> ALTER USER 'root'@'localhost' IDENTIFIED BY '111'; flush privileges;
> grant all on *.* to 'root'@'%' identified by '111' with grant option;
> ```

4. 创建数据库

```bash
echo "create database sbtest;" | /data/mysql-files/bin/mysql -u root -P 3306 -p111
echo "show databases;" | /data/mysql-files/bin/mysql -u root -P 3306 -p111
```

5. sysbench——prepare，准备数据

```bash
sysbench \
--db-driver=mysql \
--mysql-user=root \
--mysql-password=123  \
--mysql-host=10.22.190.7 \
--mysql-port=3307 \
--mysql-db=sbtest \
--range_size=100  \
--table_size=10000 \
--tables=10 \
--threads=1 \
--events=0 \
--time=60  \
--rand-type=uniform /usr/share/sysbench/oltp_read_only.lua prepare
```

6. sysbench——run，进行测试

```bash
sysbench \
--mysql_storage_engine=rocksdb \
--db-driver=mysql \
--mysql-user=root \
--mysql-password=123  \
--mysql-host=10.22.190.7 \
--mysql-port=3307 \
--mysql-db=sbtest \
--range_size=100  \
--table_size=10000 \
--tables=10 \
--threads=1 \
--events=0 \
--time=60  \
--rand-type=uniform /usr/share/sysbench/oltp_read_only.lua prepare

sysbench \
--mysql_storage_engine=rocksdb \
--db-driver=mysql \
--mysql-user=root \
--mysql-password=123  \
--mysql-host=10.22.190.7 \
--mysql-port=3307 \
--mysql-db=sbtest \
--range_size=100 \
--table_size=10000 \
--tables=2 \
--threads=32 \
--events=0 \
--time=600 \
--rand-type=uniform /usr/share/sysbench/oltp_write_only.lua run
```



7. 观察

```bash
echo "show processlist" | /data/mysql-files/bin/mysql -u root -P 3306 -p111
```

