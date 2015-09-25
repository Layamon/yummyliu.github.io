---
layout: post
title: pgbench介绍
date: 2018-02-05 18:07
header-img: "img/head.jpg"
categories: 
    - PostgreSQL
---

* TOC
{: toc}
# 简介

- 动作：在pg上，不断运行相同的sql（可以并行执行，sql也可以自己定义），最终计算出tps（transaction per second）。

- 数据：基于类tpc-b的数据集

- 输出：

  ```
  transaction type: <builtin: TPC-B (sort of)>
  scaling factor: 10 # 有四张表，这里是10，相当于每个表的数据*10(大概10倍，并不是准确的) -s
  query mode: simple # 共三种查询方式：-M, --protocol=simple|extended|prepared
  number of clients: 10 # 并行客户端连接数 -c 
  number of threads: 1  # 工作线程数，多个客户端公用这些工作线程 -j
  number of transactions per client: 1000 # 
  number of transactions actually processed: 10000/10000
  tps = 85.184871 (including connections establishing)
  tps = 85.296346 (excluding connections establishing)
  ```

# 测试

- 初始化数据集：

  | -i                | 初始化模式                                                   |
  | ----------------- | ------------------------------------------------------------ |
  | -F                | 填充因子，insert的时候不写满，提高update效率，默认100，尽量写满 |
  | -n                | 初始化后，不执行vacuum                                       |
  | -q                | quiet                                                        |
  | -s                | 扩展因子,大于20000以上，aid列使用bigint                      |
  | —foreign-keys     | 创建外键                                                     |
  | —index-tablespace | 创建专门的index的表空间                                      |
  | —unlogged-tables  | 不记wal日志的表                                              |

- 进行基准测试

  | -b scriptname@weight | Built-in 脚本:`tpcb-like` `simple-update`  `select-only`     |
  | -------------------- | ------------------------------------------------------------ |
  | -f filename@weight   | 自定义的事务脚本                                             |
  | -c                   | client数                                                     |
  | -C                   | 每次事务建立新的连接                                         |
  | -d                   | debug                                                        |
  | -D varname=value     | 可以定义多个自定义脚本中的参数                               |
  | -j                   | Pgbench 总工作线程                                           |
  | -l                   | 记录每个事务的执行时间                                       |
  | -L limit             | 事务超时限制，事务执行时间超过$limit会被单独记录；由于当前这个已经延时了，其后面的事务会被跳过，比如**例1** |
  | -M                   | 查询方式                                                     |
  | -n                   | 测试前不执行vacuum                                           |
  | -v                   | 执行四个表的vacuum                                           |
  | -N                   | -b simple-update                                             |
  | -P sec               | 每$sec秒输出执行报告                                         |
  | -r                   | 报告每条语句的平均延迟                                       |
  | -R rate              | 事务的运行按照一定速率运行，而不是越快越好，希望是呈现泊松分布式的调度时间线；这么理解，整体的事务执行按照rate的速度执行，当前面的事务完成后，当前事务是否执行，取决于整个的速度与rate符合与否。如果太快了，就等一会，这段时间就是日志中的【schedule lag time】; |
  | -s                   | 扩展因子                                                     |
  | -S                   | Select-only                                                  |
  | -t                   | 每个client执行的事务数                                       |
  | -T                   | 总共测试执行时间，与-t不可同时存在                           |
  | —aggregate-inteval   | 与-l一起使用，输出一段时间间隔里的汇总信息                   |
  | —progress-timestamp  | 使用时间戳而不是秒数                                         |
  | —sampling-rate       | 输出log的时候，采用采样的方式输出                            |

  ## 例1

  -L 5min

  ```
  0 81 4621 0 1412881037 912698 3005
  0 82 6173 0 1412881037 914578 4304
  0 83 skipped 0 1412881037 914578 5217 : 从1412881037+5217处开始执行必然超时，跳过
  0 83 skipped 0 1412881037 914578 5099 
  0 83 4722 0 1412881037 916203 3108
  0 84 4142 0 1412881037 918023 2333
  0 85 2465 0 1412881037 919759 740
  ```


### scaler factor公式

| Target object                | Scale Formula                |
| ---------------------------- | ---------------------------- |
| DB                           | 0.0669*DB_Size_Target_MB-0.5 |
| Table(pgbench_accounts)      | 0.0781*Table_Size_Target_MB  |
| Index(pgbench_accounts_pkey) | 0.4668*Index_Size_Target_MB  |

### 其他

- tpc-b-like benchmark

  ```
  BEGIN;
  UPDATE pgbench_accounts SET abalance = abalance + :delta WHERE aid = :aid;
  SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
  UPDATE pgbench_tellers SET tbalance = tbalance + :delta WHERE tid = :tid;
  UPDATE pgbench_branches SET bbalance = bbalance + :delta WHERE bid = :bid;
  INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (:tid, :bid, :aid, :delta, CURRENT_TIMESTAMP);
  END;
  ```

- Simple-update

  ```
  BEGIN;
  UPDATE pgbench_accounts SET abalance = abalance + :delta WHERE aid = :aid;
  SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
  INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (:tid, :bid, :aid, :delta, CURRENT_TIMESTAMP);
  END;
  ```

- Select-only

  ```
  BEGIN;
  SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
  END;
  ```

### Custom Script

sql文件中，sql语句以换行符作为结束标志；pg10中可以以分号作为结束标志；但是如果要两者兼容，我们换行的时候，加一个分号

1. 变量可以通过 -D 设定，同时也可以通过 以下的元命令设定，有两个变量有预设的值；

   | v         | d                        |
   | --------- | ------------------------ |
   | scale     | 当前扩展因子             |
   | client_id | 从0开始，区别各个session |

2. Meta Command

   - `\set varname expression`： 通过**build-in函数**等表达式计算一个值
   - `\sleep num`
   - `\setshell varname command` : 通过shell命令来给变量赋值
   - `\shell`: 执行一个shell命令

3. build-in函数 基本都是整数的计算

4. 加了-l参数，每个事务的日志写在pgbench_log.pid.threadid(pgbench跑起来是一个单进程，会启动很多线程)，如下,进程pid==25561，启动了16个线程

   ```
   -rw-rw-r--  1 liuyangming liuyangming  230787 1月  18 11:43 pgbench_log.25561
   -rw-rw-r--  1 liuyangming liuyangming  234055 1月  18 11:43 pgbench_log.25561.1
   -rw-rw-r--  1 liuyangming liuyangming  118131 1月  18 11:43 pgbench_log.25561.10
   -rw-rw-r--  1 liuyangming liuyangming  117049 1月  18 11:43 pgbench_log.25561.11
   -rw-rw-r--  1 liuyangming liuyangming  119895 1月  18 11:43 pgbench_log.25561.12
   -rw-rw-r--  1 liuyangming liuyangming  117830 1月  18 11:43 pgbench_log.25561.13
   -rw-rw-r--  1 liuyangming liuyangming  115750 1月  18 11:43 pgbench_log.25561.14
   -rw-rw-r--  1 liuyangming liuyangming  118709 1月  18 11:43 pgbench_log.25561.15
   -rw-rw-r--  1 liuyangming liuyangming  230008 1月  18 11:43 pgbench_log.25561.2
   -rw-rw-r--  1 liuyangming liuyangming  227876 1月  18 11:43 pgbench_log.25561.3
   -rw-rw-r--  1 liuyangming liuyangming  229404 1月  18 11:43 pgbench_log.25561.4
   -rw-rw-r--  1 liuyangming liuyangming  233781 1月  18 11:43 pgbench_log.25561.5
   -rw-rw-r--  1 liuyangming liuyangming  238873 1月  18 11:43 pgbench_log.25561.6
   -rw-rw-r--  1 liuyangming liuyangming  236004 1月  18 11:43 pgbench_log.25561.7
   -rw-rw-r--  1 liuyangming liuyangming  119719 1月  18 11:43 pgbench_log.25561.8
   -rw-rw-r--  1 liuyangming liuyangming  118014 1月  18 11:43 pgbench_log.25561.9
   ```

   log文件中，有6（7）列

   ```
   client_id transaction_no time script_no time_epoch time_us [ schedule_lag ]
   客户端id   
   当前client执行的第几个tran 
   执行的时间 
   执行的第几个脚本 
   事务启动时间
   事务完成时间偏移
   [事务真正被调度的时间]
   ```

5. 聚合log

   --aggregate-interval= 5000s, 以5000s为一个interval统计聚合信息，输出到日志

   ```
   interval_start num_transactions sum_latency sum_latency_2 min_latency max_latency [ sum_lag sum_lag_2 min_lag max_lag [ skipped ] ]
   ```

## NOTE

1. 测试时间不要太短，要不噪声比较多，至少几分钟，取个平均
2. 应该关注一下vacuum，对测试效果的影响
3. 需要考虑pgbench的运行机器的配置，开太多clientsession，如果机器那么多核，自身的调度也是瓶颈。
