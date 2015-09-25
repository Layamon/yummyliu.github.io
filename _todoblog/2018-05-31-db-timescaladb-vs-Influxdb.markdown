---
layout: post
title: TimescalaDB Or InfluxDB
subtitle: pgwatch3中加一个timescaladb的数据源的工作
date: 2018-05-31 15:43
header-img: "img/head.jpg"
categories:
   - PostgreSQL
---

* TOC
{:toc}

# 时序数据库

这个有当前可能的所有的时序数据库：[tsdb-list](https://misfra.me/2016/04/09/tsdb-list/) 。为什么还要有timescaledb[why](https://blog.timescale.com/what-the-heck-is-time-series-data-and-why-do-i-need-a-time-series-database-dcf3b1b18563)?

- 在我们的许多查询试验中表现不佳（解读：高延迟）
- 甚至都不支持许多其他的查询（因数据库而异）
- 要求我们学习一门新的查询语言（解读：不是SQL语言）
- 不能与我们现有的大多数工具合用（解读：糟糕的兼容性）
- 要求我们将数据分为两个数据库：一个“常规”的关系数据库，还有一个时间序列数据库（解读：操作与开发过程极为头痛）

这里主要就是使用pgwatch2的时候，明明是监控的pg，却要装一个influxdb，学一些influxdb的命令，而且influxdb的SQL支持也没有PostgreSQL规范；以此为切入口，目标是在pgwatch2中加入timescaladb的支持（熟悉一下go以及timescaladb）。

首先是对比一下influxdb和timescaladb的区别：

## create

##### influxdb create

```sql
CREATE DATABASE <database_name>
[WITH [DURATION <duration>]
[REPLICATION <n>]
[SHARD DURATION <duration>]
[NAME <retention-policy-name>]]


CREATE DATABASE %s WITH DURATION %dd REPLICATION 1 SHARD DURATION 3d NAME pgwatch_def_ret
```

+ `DURATION`：定义了influxdb保留的数据最长时间，最小是一小时；

+ `REPLICATION`：在数据节点上，保留数据的几个副本；单节点的influxdb这个设置没有用；

+ `SHARD DURATION`：定义了一个shard组中包含多长时间范围数据；默认是和DURATION相同；（就是按照range方式分区，分区的列是time）

+ 没有create MEASUREMENTS ; 直接insert

  ```sql
  $ influx
  > CREATE DATABASE mydb
  > USE mydb
  Using database mydb
  > SHOW MEASUREMENTS
  > INSERT cpu,host=serverA value=10
  > SHOW MEASUREMENTS
  name: measurements
  name
  ----
  cpu

  > INSERT mem,host=serverA value=10
  > SHOW MEASUREMENTS
  name: measurements
  name
  ----
  cpu
  mem
  ```

##### timescaladb create

```sql
CREATE TABLE conditions (
 time        TIMESTAMPTZ       NOT NULL,
 location    TEXT              NOT NULL,
 temperature DOUBLE PRECISION  NULL
);

create_hypertable()
```

在使用timescaladb的时候，一般考虑两个问题：

1. 我应该按照多大的时间区间分区？

   + Time intervals：当前版本的timescaladb不支持自适应的时间间隔分区（正在开发中）。因此用户需要在创建hypertable的时候，设置`chunk_time_interval`（默认是1个月）。通过`set_chunk_time_interval`来改变；
   + 选择time interval的核心思想就是：时间上最近的那个chunk能够放到内存中，大概占个25%的内存就行；这也和你的数据产生速度相关。如果每天写2G的数据，但是有64GB的内存，把time intervals设置成一周比较好（2\*7=14Gb < 64\* 1/4）
   + 这个设置就相当于influxdb的`SHARD DURATION`

2. 我该不该用空间分区，应该按照空间分几个区？

   + timescaladb的hypertable就是PostgreSQL里的分区表，chunk就是PostgreSQL的分区，一般是安装时间列，采用range的方式进行分区，这里的space分区我猜就是list的方式实现的（有待·考证）。

3. Data Retention

   + 用`drop_chunks`函数实现：

     ```SQL
     SELECT drop_chunks(interval '24 hours', 'conditions');
     --- 这会将hypertable中的只包含老数据的chunk清理掉，不会对chunks中的任何单独的行删除
     ```

   + Automatic Data Retention Policies：类似influxdb的`DURATION`

     和第三方工具结合，定期删除

     + crontab

       ```
       0 3 * * * /usr/bin/psql -h localhost -p 5432 -U postgres -d postgres -c "SELECT drop_chunks(interval '24 hours', 'conditions');" >/dev/null 2>&1
       ```

     + systemd timer

       ```
       cat /etc/systemd/system/retention.service
       [Unit]
       Description=Drop chunks from the 'conditions' table

       [Service]
       Type=oneshot
       ExecStart=/usr/bin/psql -h localhost -p 5432 -U postgres -d postgres -c "SELECT drop_chunks(interval '24 hours', 'conditions');"

       cat /etc/systemd/system/retention.timer
       [Unit]
       Description=Run data retention at 3am daily

       [Timer]
       OnCalendar=*-*-* 03:00:00

       [Install]
       WantedBy=timers.target
       ```
