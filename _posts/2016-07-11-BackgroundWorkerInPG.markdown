---
layout: post
title: 认识postgresql的BGW
date: 2016-07-11 21:07
categories: 
    - PostgreSQL
typora-root-url: ../../layamon.github.io
---

* TOC
{:toc}
```bash
/home/liuyangming/postgresql-9.5.3/build/bin/postgres -D data
postgres: checkpointer process
postgres: writer process
postgres: wal writer process
postgres: autovacuum launcher process
postgres: stats collector process
postgres: liuyangming tpcds [local] EXPLAIN // 响应客户端请求fork的进程，其他为常驻的后台辅助服务进程
```

### 1.2. 对应文件

```
autovacuum.c     // 系统自动清理进程的源文件
bgworker.c       // 维护一个BackgroundWorkerArray,其中维护着后台工作进程的列表
		  		// 各个进程都可以访问，postmaster无锁访问，其他进程要或得排它锁才能写，共享锁才能读
bgwriter.c        // 后台写进程的源文件
checkpointer.c    // 检查点进程，掌控系统的所有的检查点，pg 9.2后新加的
fork_process.c    // 启动进程工具函数
pgarch.c          // 预写式日志归档进程的源文件
pgstat.c          // 统计数据收集进程的源文件
postmaster.c      // Postmaster
startup.c
syslogger.c       // 系统日志进程的源文件
walwriter.c       // 预写式日志写进程的源文件
```
看了一天进程启动的代码，想看看在哪个地方可以修改，从而创建一个新的后台进程，
最终没想到在postgresql 中已经提供了一个Custom Background Workers，这是在 postgresql 9.3中新加的新特性[background worker][bwp]，开始没有把bgworker.c和进程对应上，没注意看源文件里的注释啊！！！

```
// POSTGRES pluggable background workers implementation
```

### 1.3. postgresql 启动流程
> postgresql 9.5 版本不同顺序不同

虽然找到了接口，附带追了一下postgresql启动创建进程的流程，以下是我简单画了一个流程图，供君指点 :)
![pgstartup](/image/pg-bgw/postgres启动.jpg)

## 2. background worker

**postgresql 9.3 commit**

```
commit da07a1e856511dca59cbb1357616e26baa64428e
Author: Alvaro Herrera <alvherre@alvh.no-ip.org>
Date:   Thu Dec 6 14:57:52 2012 -0300

Background worker processes

Background workers are postmaster subprocesses that run arbitrary
user-specified code.  They can request shared memory access as well as
backend database connections; or they can just use plain libpq frontend
database connections.

Modules listed in shared_preload_libraries can register background
workers in their _PG_init() function; this is early enough that it's not
necessary to provide an extra GUC option, because the necessary extra
resources can be allocated early on.  Modules can install more than one
bgworker, if necessary.

Care is taken that these extra processes do not interfere with other
postmaster tasks: only one such process is started on each ServerLoop
iteration.  This means a large number of them could be waiting to be
started up and postmaster is still able to quickly service external
connection requests.  Also, shutdown sequence should not be impacted by
a worker process that's reasonably well behaved (i.e. promptly responds
        to termination signals.)

The current implementation lets worker processes specify their start
time, i.e. at what point in the server startup process they are to be
started: right after postmaster start (in which case they mustn't ask
        for shared memory access), when consistent state has been reached
(useful during recovery in a HOT standby server), or when recovery has
terminated (i.e. when normal backends are allowed).

In case of a bgworker crash, actions to take depend on registration
data: if shared memory was requested, then all other connections are
taken down (as well as other bgworkers), just like it were a regular
backend crashing.  The bgworker itself is restarted, too, within a
configurable timeframe (which can be configured to be never).

More features to add to this framework can be imagined without much
effort, and have been discussed, but this seems good enough as a useful
unit already.

An elementary sample module is supplied.
```

我们将想要添加的功能编译成一个共享库，添加到pg的lib里，配置好，pg启动一个新的bg worker运行我们的程序
可以申请访问share_memory的权限，访问数据库的数据，或者直接使用libpg来访问数据库
添加这一个feature，我们就可以利用这一特性做一些我们想要的功能，特别是后台维护性质的任务

### 2.1. 编写一个custome background worker

#### 2.1.1 bgw相关数据结构代码

##### BackgroundWorker结构体

``` c
typedetruct BackgroundWorker
{
    char        bgw_name[BGW_MAXLEN];
    int         bgw_flags;
    BgWorkerStartTime bgw_start_time;
    int         bgw_restart_time;       /* in seconds, or BGW_NEVER_RESTART */
    bgworker_main_type bgw_main;
    char        bgw_library_name[BGW_MAXLEN];   /* only if bgw_main is NULL */
    char        bgw_function_name[BGW_MAXLEN];  /* only if bgw_main is NULL */
    Datum       bgw_main_arg;
    char        bgw_extra[BGW_EXTRALEN];
    pid_t       bgw_notify_pid; /* SIGUSR1 this backend on start/stop */
} BackgroundWorker;
```

##### BackgroundWorker调用执行

``` c
/*
     * If bgw_main is set, we use that value as the initial entrypoint.
     * However, if the library containing the entrypoint wasn't loaded at
     * postmaster startup time, passing it as a direct function pointer is not
     * possible.  To work around that, we allow callers for whom a function
     * pointer is not available to pass a library name (which will be loaded,
     * if necessary) and a function name (which will be looked up in the named
     * library).
     */
    if (worker->bgw_main != NULL)
        entrypt = worker->bgw_main;
    else
        entrypt = (bgworker_main_type)
            load_external_function(worker->bgw_library_name,
                                   worker->bgw_function_name,
                                   true, NULL);

    /*
     * Note that in normal processes, we would call InitPostgres here.  For a
     * worker, however, we don't know what database to connect to, yet; so we
     * need to wait until the user code does it via
     * BackgroundWorkerInitializeConnection().
     */

    /*
     * Now invoke the user-defined worker code
     */
    entrypt(worker->bgw_main_arg);
```

#### 2.1.2. 一个例子 Hello world
> 创建一个 custome background worker ,循环输出 "hello world"

##### Header

``` c
/*  编写bgw，最少需要添加的头文件，如果需要别的功能再添加别的头文件
    比如，如果想对数据库进程操作，借助spi manager就需要添加spi.h*/
#include "postgres.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/proc.h"
#include "fmgr.h"
```

##### Declaration

``` c
/* Essential for shared libs! */
PG_MODULE_MAGIC;

/* Entry point of library loading */
void _PG_init(void);

/* Signal handling */
static bool got_sigterm = false;
```

##### Initialization

``` c
void
_PG_init(void)
{
    BackgroundWorker    worker;

    /* Register the worker processes */
    worker.bgw_flags = BGWORKER_SHMEM_ACCESS;
    worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
    worker.bgw_main = hello_main;
    worker.bgw_sighup = NULL;
    worker.bgw_sigterm = hello_sigterm;
    worker.bgw_name = "hello world";
    worker.bgw_restart_time = BGW_NEVER_RESTART;
    worker.bgw_main_arg = NULL;
    RegisterBackgroundWorker(&worker);
}
```

##### Main loop

``` c
static void
hello_main(void *main_arg)
{
    /* ready to receive signals */
    BackgroundWorkerUnblockSignals();
    while (!got_sigterm)
    {
        int     rc;
        /* Wait 10s */
        rc = WaitLatch(&MyProc-;>procLatch,
                WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
                10000L);
        ResetLatch(&MyProc-;>procLatch);
        elog(LOG, "Hello World!"); 	/* Say Hello to the world */
    }
    proc_exit(0);
}
```

##### SIGTERM handler

``` c
static void
hello_sigterm(SIGNAL_ARGS)
{
    int         save_errno = errno;
    got_sigterm = true;
    if (MyProc)
        SetLatch(&MyProc-;>procLatch);
    errno = save_errno;
}
```

#####  Makefile

```
MODULES = hello_world
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
```

#### New feature

除此之外,在pg9.4之后添加了新的特性，动态加载bgworker,以插件的方式, create extension 具体例子可以参考源码的 src/test/modules/worker_spi


### 2.2 一句话

在没有这个特性之前，如果我们自己需要创建一个新的后台维护任务，就要自己额外启动一个进程，
并管理好该进程的生命周期。有了bgworker之后，pg启动的时候顺带启动了我们自定义的后台任务进程
并且pgstop顺带stop，更加有整体性

[bwp]: https://wiki.postgresql.org/wiki/What&amp;#39;s_new_in_PostgreSQL_9.3#Custom_Background_Workers

### 3. bgw开发指导 in osx

#### 3.1 安装开发包

osx上brew没有找到postgresql-server-dev-all包，直接cmm源码安装

```bash
» pg_config      
BINDIR = /usr/local/pgsql/bin
DOCDIR = /usr/local/pgsql/share/doc
HTMLDIR = /usr/local/pgsql/share/doc
INCLUDEDIR = /usr/local/pgsql/include
PKGINCLUDEDIR = /usr/local/pgsql/include
INCLUDEDIR-SERVER = /usr/local/pgsql/include/server
LIBDIR = /usr/local/pgsql/lib
PKGLIBDIR = /usr/local/pgsql/lib
LOCALEDIR = /usr/local/pgsql/share/locale
MANDIR = /usr/local/pgsql/share/man
SHAREDIR = /usr/local/pgsql/share
SYSCONFDIR = /usr/local/pgsql/etc
PGXS = /usr/local/pgsql/lib/pgxs/src/makefiles/pgxs.mk
CONFIGURE =
CC = gcc
CPPFLAGS = -DFRONTEND
CFLAGS = -Wall -Wmissing-prototypes -Wpointer-arith -Wdeclaration-after-statement -Wendif-labels -Wmissing-format-attribute -Wformat-security -fno-strict-aliasing -fwrapv -Wno-unused-command-line-argument -O2
CFLAGS_SL =
LDFLAGS = -L../../src/common -Wl,-dead_strip_dylibs
LDFLAGS_EX =
LDFLAGS_SL =
LIBS = -lpgcommon -lpgport -lz -lreadline -lm
VERSION = PostgreSQL 10.3
```

#### 3.2 写makefile

简单期间，直接把源码中的例子拿过来

```bash
cd  ~/go/src/github.com/layamon/patrol/commander
cp ~/src/postgresql-10.3/src/test/modules/worker_spi/* .
USE_PGXS=1 make
ll worker_spi.so
-rwxr-xr-x  1 liuyangming  staff    16K  7 27 13:00 worker_spi.so
```

#### 3.3 按照自己的需求参考文档开干吧

