---
layout: post
title: PostgreSQL的主从切换操作记录
date: 2018-05-30 18:06
header-img: "img/head.jpg"
categories: 
    - PostgreSQL
---

* TOC
{:toc}

## 主从切换

流复制的主从之间是通过wal日志，来同步数据；

假设现在有1主N从，我们需要将其中的一个从升级为主，将主换成从库；并且让其他的从库follow新的主库；

> 先把除了新主库的其他从库停了，保证其他除了新主库之外的其他从库，稍微落后于新主库
>
> 将主库停了，将新主库promote；此时新主库会产生三个新文件，记录了promote的时间点，以及wal日志消费到的位置；
>
> 编辑旧主库

1. 停主库

   ```bash
   $ pg_ctl stop -D /export/postgresql/omi_10/data/
   waiting for server to shut down.... done
   server stopped
   ```

2. 查看从库复制的位置，然后从库直接promote

   ```bash
   $ psql  -c 'select pg_last_wal_receive_lsn() "receive_location",pg_last_wal_replay_lsn() "replay_location",pg_is_in_recovery() "recovery_status";'
    receive_location | replay_location | recovery_status
   ------------------+-----------------+-----------------
    0/75000098       | 0/75000098      | t 
   $ pg_ctl promote -D $pgdata
   waiting for server to promote.... done
   server promoted
   ```


3. 从库promote之后，会产生新的timeline文件；将新的timeline的history文件复制到原主库上；

   ```bash
    pg_wal]$ ll
   -rw------- 1 postgres postgres 16777216 Mar 19 11:05 000000010000000000000075.partial
   -rw------- 1 postgres postgres 16777216 Mar 19 11:08 000000020000000000000075
   -rw------- 1 postgres postgres       42 Mar 19 11:08 00000002.history

   $ scp ...
   ```

4. 编辑主库的recovery.conf文件 然后，启动主库

   ```bash
   $ cat recovery.conf
   recovery_target_timeline = 'latest'
   standby_mode = on
   primary_conninfo = 'user=replication password=*** host=*** port=5432 sslmode=prefer sslcompression=1 krbsrvname=postgres target_session_attrs=any'
   ```

5. 启动新从库

   ```bash
   $ pg_ctl start -D $pgdata
   waiting for server to start....2018-03-19 11:17:40 CST  user=,db=,app=,client=LOG:  listening on IPv4 address "0.0.0.0", port 5432
   2018-03-19 11:17:40 CST  user=,db=,app=,client=LOG:  listening on IPv6 address "::", port 5432
   2018-03-19 11:17:40 CST  user=,db=,app=,client=LOG:  listening on Unix socket "/var/run/postgresql/.s.PGSQL.5432"
   2018-03-19 11:17:40 CST  user=,db=,app=,client=LOG:  listening on Unix socket "/tmp/.s.PGSQL.5432"
   2018-03-19 11:17:40 CST  user=,db=,app=,client=LOG:  redirecting log output to logging collector process
   2018-03-19 11:17:40 CST  user=,db=,app=,client=HINT:  Future log output will appear in directory "log".
    done
   server started
   ```

6. 查看新主从的状态

   ```SQl
   --- 主
   postgres=# select * from pg_stat_replication ;
   -----+------------------------------
   pid              | 2900
   usesysid         | 16384
   usename          | replication
   application_name | walreceiver
   client_addr      | ***
   client_hostname  |
   client_port      | 38154
   backend_start    | 2018-03-19 11:17:40.611539+08
   backend_xmin     | 141644
   state            | streaming
   sent_lsn         | 0/750001A8
   write_lsn        | 0/750001A8
   flush_lsn        | 0/750001A8
   replay_lsn       | 0/750001A8
   write_lag        |
   flush_lag        |
   replay_lag       |
   sync_priority    | 0
   sync_state       | async

   --- 从
   postgres=# select pg_is_in_recovery();
    pg_is_in_recovery
   -------------------
    t
   (1 row)
   ```
