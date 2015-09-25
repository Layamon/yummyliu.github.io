---
layout: post
title: PostgreSQL的IO调优
date: 2018-12-24 18:06
header-img: "img/head.jpg"
categories: 
    - PostgreSQL
    - Linux
typora-root-url: ../../layamon.github.io
---

* TOC
{:toc}

# 前言

数据库是应用程序最最后面的一个组件，性能的变差或者不稳定，能够显著影响应用性能。然而，数据库的问题原因可能有多重：

- SQL没写好，查询逻辑冗余，导致使用了很多CPU和内存
- 由于不当的索引，导致查询使用了**全表扫描**
- 数据库维护不当，导致**统计信息更新不及时**
- 错误的容量规划，导致**基础设施不足**
- 逻辑和物理的**设计不当**
- **没有使用链接池**，应用发起了太多的链接；

本文中，主要讲其中比较重要的一项——IO。特别是在高TPS的OLTP应用或者大数据量的数仓环境中，这很重要；

# PostgreSQL本身的调整

## 索引

表上有索引，插入数据时，会引起写放大；我们可以给数据库服务配置多个的磁盘文件系统，将索引和磁盘的放在不同的表空间中。作为一个dba应该考虑：

- 理解索引的需求；建一个**合理**的索引
- **避免**创建多个索引；创建一些不需要的索引，这会拖累系统
- **监控**索引的使用情况；删除不需要的索引
- **定期的重建索引**：当索引列的数据更改了，索引会膨胀。

## 分区

高效的分区策略能够改善IO性能问题。大表可以基于业务逻辑拆分。PostgreSQL支持表分区（逐渐完善中）。

分区能够有效地平衡IO。所有的子分区能够放在不同的表空间和磁盘文件系统中（冷热数据分离）。比如，基于日期列的查询，根据where条件定位到相应的时间分区中，比起全表扫描，这有很大的性能提升。

## 检查点

检查点是数据库的关键行为，同时也是IO敏感的；其保证了数据库的一致性状态，定期执行检查点是很重要的，确保数据变化**持久**保存到磁盘中并且数据库的状态是**一致**的。

不当的检查点配置会导致IO性能问题。DBA需要关注检查点的配置，确保**没有任何IO的尖刺**（这同样也取决于磁盘性能的好坏，以及数据文件的组织）。

### 检查点简述

检查点工作简述：

- 所有提交的数据，被写入到磁盘中；
- clog（commit log）文件更新了提交状态
- 循环利用pg_xlog(pg_wal)中的事务日志文件

配置参数简述：

- max_wal_size （软约束，如果硬性不允许写wal，DB就停止服务了）
- min_wal_size
- checkpoint_timeout（检查点启动间隔时间）
- checkpoint_completion_target（定义何时强制flash）

这些配置决定了检查点执行的频率，以及检查点多长时间结束；

### 配置建议

评估数据库的TPS。评估全天事务数，什么时间达到峰值

- 了解业务

- 单从数据库端，我们可以做：

  - 监控数据库，评估全天的事务数。这可以查询pg_catalog.pg_stat_user_tables得到

  - 评估每天产生的归档日志数

  - 打开`log_checkpoints`参数，监控检查点的进行，理解检查点的行为。

    ```
    2018-06-26 04:50:02.644 CST,,,57574,,5978e06e.e0e6,19349,,2017-07-27 02:33:18 CST,,0,LOG,00000,"checkpoint starting: time",,,,,,,,,""
    2018-06-26 05:35:03.272 CST,,,57574,,5978e06e.e0e6,19350,,2017-07-27 02:33:18 CST,,0,LOG,00000,"checkpoint complete: wrote 595866 buffers (12.6%); 0 transaction log file(s) added, 0 removed, 1498 recycled; write=2610.601 s, sync=0.263 s, total=2700.628 s; sync files=520, longest=0.126 s, average=0.000 s",,,,,,,,,""
    ```

  - 打开`checkpoint_warning`参数，默认是30s；在一个`checkpoint_timeout`时间内，如果wal_size超过了`max_wal_size`，那么会触发一次checkpoint；当在`checkpoint_timeout`期间，checkpoint被频繁的触发（即，间隔时间小于checkpoint_warning），那么就需要提高`max_wal_size`；日志中会提示：

    ```
    LOG:  checkpoints are occurring too frequently (11 seconds apart)
    HINT:  Consider increasing the configuration parameter "max_wal_size".
    ```

## 全表维护

数据库查询会尽量避免全表扫描，但VACUUM和ANALYZE需要全表扫描来对表做维护操作；这里说一下fillfactor；这个参数表示在表的数据块中给insert使用的空间，默认是100%；这意味着insert可以使用全部的空间，同样意味着，update没有空间使用；

可以在create table和create index的时候指定fillfactor。

> NOTE：当在一个已经存在的表上，更改FILLFACTOR；需要VACUUM FULL或者重建这个表，确保生效；

### 对于VACUUM的一些建议：

- 在**高负载的用户表**上每晚**手动执行**VACUUM ANALYZE
- 在**批量insert之后，执行VACUUM ANALYZE**。
- **监控重要的表上的vacuum状态**（pg_stat_tables），确保被定期vacuum了
- 使用`pgstattuple`，监控**表空间膨胀**
- **禁止**在生产环境执行VACUUM FULL，使用pg_reorg或者pg_repack重建表和索引；
- **确保**高负载系统中，**AUTOVACUUM**是打开的
- 打开**log_autovacuum_min_duration**
- 在高负载的表上，打开**FILLFACTOR**

## 排序操作

执行GROUP BY, ORDER BY, DISTINCT, CREATE INDEX, VACUUM FULL等操作，会执行排序操作，并且可能在磁盘中进行；如果有索引，可以在内存中进行；否则，如果sort降级为使用磁盘，性能大幅下跌；

使用work_mem，来确保排序在内存中发生。可以在**配置文件**中配，也可以在**会话层**，**表层**，**用户层**，**数据库层**配置。通过打开`log_temp_files`配置（以bytes为单位），我们可以判断需要多少空间；打开之后，我们可以在日志中看到：

```bash
LOG:  temporary file: path "base/pgsql_tmp/pgsql_tmp5323.0", size 82332
```

上述信息表示查询需要82332 bytes；因此work_mem设置为大于等于82332 bytes，可以在内存中进行排序；

对于应用的查询，只能在用户级别配置work_mem；做这个之前了解一下该用户的连接数，防止oom；

## 数据库文件系统结构

确保数据库使用多个表空间

- 将表和索引放在不同的表空间中
- **表空间**放在不同的磁盘中
- **pg_wal**放在单独的磁盘中
- 确保`*_cost`的配置和底层是相同的
- 使用iostat或者mpstat等**监控**工具，时常关注读写状态；

## 批量加载数据

数据加载的操作一般是在还未上线的时候进行的的前提，确保下面配置好，能够加速数据加载

1. 调大checkpoint的相关配置
2. 关闭`full_page_write`
3. 关闭wal归档
4. 关闭`synchronous_commit`
5. 去掉索引和约束，后面基于很大的*work_mem*重新创建
6. 如果从csv中加载，调大`maintenance_work_mem`
7. **不要关闭**fsync，尽管这有很大的性能提升，但是会导致数据损坏。

# Linux系统的调整

我们都知道，除了上层透明的cpu缓存以外，有两个和IO相关的组件——内存和磁盘。除了选择优质的硬件以外，我们通常的调优都是针对内存和磁盘之间的cache。

在linux 2.2之前，有两种cache——page cache和buffer cache。在linux 2.4之后，两种合并为pagecache。通过`free`命令可以看到内存的使用情况。

```bash
[liuyangming@ymtest ~]$ free -m
             total       used       free     shared    buffers     cached
Mem:        387491      75453     312038      15021        367      62036
-/+ buffers/cache:      13049     374442
Swap:        65535          0      65535
```
buffers：内核中使用的buffer。

cached：pagecache（可能还有少量别用途，比如slab）。

当我们向文件进行写入时，先写到pagecache中，然后通过主动sync或者间歇性的Linux调度flush，将脏页写盘。

> 在 <= Linux  2.6.31时，系统通过pdflush，进行间歇性的刷盘；
>
> 在 Linux  2.6.32中，进行了改进，不同的磁盘有不同的刷盘进程。
>
> ![image-20190125160344424](/image/pg-tuning/image-20190125160344424.png)

pagecache就是应用程序的内存之外的部分。如果应用程序需要更多的内存，那么pagecache中没有被使用的部分就会被删除，以供应用程序使用。

但是，我们要知道pagecahe并不是在所有场景中都是有用的。比如数据库的redo日志，并不需要在pagecache中缓存，应该能够直接落盘。

## 内存申请

#### NUMA

NUMA是一种CPU的硬件架构。NUMA相对的是SMP，SMP中所有CPU争用一个总线来访问内存；而NUMA称作**非对称性内存访问**：简单来说是，每个CPU有自己的Memory Zone，访问自己的很快，访问别人的慢。

NUMA的内存分配策略默认是localalloc（还有preferred、membind、interleave），即从本地node分配，如果本地node分配不了，根据系统参数：**vm.zone_reclaim_mode**，决定是否从其他node分配内存：

+ 取0，系统倾向于从其他node分配内存
+ 取1，系统倾向于从本地节点回收Cache

当系统中有多个Node，且zone_reclaim_mode=1时；可能内存不能完全利用起来，如果你对内存的使用，更偏向于cache的应用而不是数据局部性的应用，那么建议取0；

在PostgreSQL中，我们通常取0，并且会在bios中将numa关闭：

```shell
grubby --update-kernel=/boot/vmlinuz-$(uname -r) --args="numa=off"
```

#### Shared Memory

PostgreSQL有自己的`shared_buffer`，在<=9.2时，PostgreSQL是基于SYSTEM V的API，SYSTEM V的接口要求设置SHMMAX大小。而>=9.3之后，PostgreSQL基于POSIX的API实现。

> **Shared Memory 接口比较**
>
> SHMMAX：单个进程可以分配的最大共享内存段的大小；
>
> SHMALL：系统范围的总共享内存大小。
>
> | System V                                                     | Posix                                                   |
> | ------------------------------------------------------------ | ------------------------------------------------------- |
> | Shared Memory 接口调用：shmget(), shmat(), shmdt(), shmctl() | Shared Memory接口调用：shm_open(), mmap(), shm_unlink() |

PostgreSQL的shared_buffer推荐配置是内存的1/4大小，有个别情况可以配置为大于3/4；但是不要配置为1/4~3/4之间的值。

#### Over Commit

因为Linux的内存申请和分配是两码事，内存分配发生在内存使用的瞬间，并且应用往往会申请比需要的多；所以，Linux是允许memory overcommit。

在不允许overcommit的情况下，如果申请了2MB内存，但是实际使用了1MB，那么存在内存浪费。而当允许overcommit时，如果没有swap，可能会存在OOM——这时系统的OOM Killer会选择杀掉若干个进程，来释放内存（或者配置vm.panic_on_oom，使系统重启）。

Linux的overcommit根据vm.overcommit_memory的取值不同，有三种策略：

- 0 – Heuristic overcommit handling。这是缺省值，它根据某种算法决定是否可以overcommit。

- 1 – Always overcommit。总是允许overcommit，
- 2 – Don’t overcommit。禁止超过阈值的overcommit。

在PostgreSQL中，往往采用的是第三种，而第三种的阈值是通过vm.overcommit_ratio或vm.overcommit_kbytes来设置的，在`/proc/meminfo`中，可以看到阈值CommitLimit的大小：

```bash
$ grep -i commit /proc/meminfo
CommitLimit:    396446012 kB
Committed_AS:   83477808 kB
```

Committed_AS是已经申请（不是分配）的内存的大小，通过`sar -r`可以查看内存的申请和分配的情况：

```bash
[liuyangming@ymtest ~]$ sar -r
Linux 2.6.32-696.el6.x86_64 (ymtest)    01/25/2019      _x86_64_        (56 CPU)

12:00:01 AM kbmemfree kbmemused  %memused kbbuffers  kbcached  kbcommit   %commit
12:10:01 AM 319555932  77235820     19.47    371744  63505568 161269628     34.76
12:20:01 AM 319554560  77237192     19.47    371804  63505796 161274804     34.76
12:30:01 AM 319552532  77239220     19.47    371884  63506028 161274096     34.76
12:40:02 AM 319553188  77238564     19.47    371900  63506252 161273828     34.76
12:50:01 AM 319553436  77238316     19.47    371948  63506468 161273712     34.76
01:00:01 AM 319550008  77241744     19.47    372024  63506704 161279040     34.77
01:10:01 AM 319551520  77240232     19.47    372080  63506928 161271600     34.76
01:20:01 AM 319551072  77240680     19.47    372108  63507164 161273632     34.76
01:30:01 AM 319550884  77240868     19.47    372124  63507388 161273876     34.76
01:40:01 AM 319551924  77239828     19.47    372140  63507612 161273568     34.76
01:50:01 AM 319551520  77240232     19.47    372204  63507844 161273584     34.76
```

其中，*kbcommit*对应的就是Committed_AS，而`%commit`为`Committed_AS/(MemTotal+SwapTotal`。

> **CommitLimit计算**
>
> `CommitLimit = (total RAM * vm.overcommit_ratio / 100) + Swap`
>
> 如果使用了hugepage，
>
> `CommitLimit = ([total RAM] – [total huge TLB RAM]) * vm.overcommit_ratio / 100 + swap`

## 内存访问

#### HugePages

在Linux中，内存页默认是4k。当内存很大时，如果页很小，整体性能就会变差。PostgreSQL中只支持Linux的HugePage（在BSD中有Super Page，在Window中有Large Page）。启用了`huge_pages`后，相应的内存页表就会变小，进而会提高内存管理的性能。

Linux的HugePage大小从2MB到1Gb不等；默认是2MB，大小在系统启动的时候设置。

```bash
>> cat /proc/meminfo | grep -i huge
AnonHugePages:         0 kB
HugePages_Total:       0
HugePages_Free:        0
HugePages_Rsvd:        0
HugePages_Surp:        0
Hugepagesize:       2048 kB
```

在如上的配置中，尽管huge page设置成2MB，但是HugePages_Total为0，意思是还未启动HugePage。

基于如下脚本的运行结果，我们可以设置配置相应的HugePage的大小。

```bash
#!/bin/bash
PGDATA="???"
pid=`head -1 $PGDATA/postmaster.pid`
echo "Pid:            $pid"
peak=`grep ^VmPeak /proc/$pid/status | awk '{ print $2 }'`
echo "VmPeak:            $peak kB"
hps=`grep ^Hugepagesize /proc/meminfo | awk '{ print $2 }'`
echo "Hugepagesize:   $hps kB"
hp=$((peak/hps))
echo Set Huge Pages:     $hp
```

```
sysctl -w vm.nr_hugepages= 88
```

[这里](https://www.percona.com/blog/2018/12/20/benchmark-postgresql-with-linux-hugepages/)有关于HugePage配置的BenchMark，但是具体情况具体分析。

> **Transparent Huge Pages (THP)**
>
> 该选项一般也是强制关闭的，因为这个选项系统会在你不执行的情况下，将4kb的page换成大页；可能会导致数据库崩溃等不可控的错误。
>
> 在bios中关闭：
>
> grubby --update-kernel=/boot/vmlinuz-$(uname -r) --args="transparent_hugepage=never"

#### TLB

CPU用来管理虚拟存储和物理存储的控制线路叫**MMU（内存管理单元**）。(一般是在bootloader中的eboot阶段的进入main()函数的时候启用MMU模块，如果没有启动MMU模块，CPU内核发出的地址将直接送到内存芯片上；有了MMU模块，MMU会截获CPU内核发出的（虚拟）地址，让将虚拟地址转换成物理地址发送到CPU芯片上。

但是引入MMU后，读取指令和数据的时候，都需要读取两次内存（1. 查询页表得到物理地址；2. 然后访问具体物理地址）。TLB（Translation Lookaside Buffer）就是页表的Cache，每行保存由单个PTE（Page Table Entry）组成的块，提高虚拟地址到物理地址的转换速度，通常称为**快表**。

TLB和CPU Cache都是微处理器的硬件结构。CPU cache是基于cpu和memory之前的缓存器，而TLB只是当CPU使用虚拟地址的时候用来加速转换速度的。

**TLB exhaustion**

>  隐藏的内存占用问题

每个进程都需要小部分内存缓存其使用的所有PTE，可以查询`/proc/$PID/status`中的VmPTE，得知PTE的大小。PTE的大小取决于进程访问的数据范围，如果PostgreSQL的进程访问了shared_buffer的所有页，那么VmPTE比较高。这时，如果链接数很多，那么可能会占用很多内存；

```shell
for p in $(pgrep postgres); 
do 
	grep "VmPTE:" /proc/$p/status; 
done | awk '{pte += $2} END {print pte / 1024 / 1024}'
```

当PTE的size比较大的时候，显然TLB的空间会不足，那么就会TLB miss，进而影响性能。

所以，有三种可能的办法：

1. PostgreSQL尽量和pooler配合使用，减少链接数；
2. 考虑使用hugepage，减少pte数量；
3. 减少PostgreSQL的shared_buffer大小，减少每个进程的pte数据量；

#### SwapSpace

```bash
>> swapon -s
Filename                                Type            Size    Used    Priority
/dev/sda2                               partition       67108860        0       -1
```

​	交换空间是安装系统的时候配置的一个磁盘分区或者一个文件，用于提高系统的虚拟内存大小，并且如果系统内存不够可以暂时使用交换空间，避免OOM。

​	`vm.swappiness`代表系统对交换空间的喜欢程度，越高越喜欢交换出去。如果设置成0，系统的OOM killer可能会杀死自己的进程，比较安全的是设置为1（默认是60）；

​	在PostgreSQL系统中，希望能有较高的响应速度，希望能尽量使用内存，而不是换出去，因此会将系统参数`vm.swappiness`设为较小的值。

## 内存回写

#### DirtyPage Flush

当pagecache变脏了，需要将脏页刷出内存。linux中通过一些参数来控制何时进行内存回写。

+ **vm.dirty_background_ratio/vm.dirty_background_bytes**

  内存中允许存在的脏页比率或者具体值。达到该值，后台刷盘。取决于外存读写速度的不同，通常将vm.dirty_background_ratio设置为5，而vm.dirty_background_bytes设置为读写速度的25%。

+ **vm.dirty_ratio/vm.dirty_bytes**

  前台刷盘会阻塞读写，一般vm.dirty_ratio设置的比vm.dirty_background_ratio大，设置该值确保系统不会再内存中保留过多数据，避免丢失。

+ **vm.dirty_expire_centisecs**

  脏页在内存中保留的最大时间。

+ **vm.dirty_writeback_centisecs**

  刷盘进程（pdflush/flush/kdmflush）周期性启动的时间

在PostgreSQL中，有自己管理的shared_buffer，但是并不是所有的读写都是走shared_buffer；类似地，PostgresQL也有自己的checkpointer和bgwriter进程，也是通过不同的阈值控制shared_buffer的刷写。

## 外存

+ 临时文件大小：temp_file_limit

+ 进程最多打开文件数：max_files_per_process

这两个主要就是一个上限的限制，max_files_per_process通常默认值1000就够用了。temp_file_limit是在work_mem不够的情况下，使用磁盘的临时文件。如果建索引或者一些大查询时，可以把temp_file_limit设置大一点，避免查询中断。
