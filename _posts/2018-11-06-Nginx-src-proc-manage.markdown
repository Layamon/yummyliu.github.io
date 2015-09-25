---
layout: post
title: Nginx源码——进程管理
date: 2018-11-06 17:18
header-img: "img/head.jpg"
categories: 
  - nginx
typora-root-url: ../../layamon.github.io
---

* TOC
{:toc}

# 简述

Nginx是一个无阻赛，事件驱动的单线程多进程的结构，其内部高度模块化，整体性能表现优异，资源利用率高。

![The NGINX (/image/nginx-proc-manage/infographic-Inside-NGINX_process-model.png) master process spawns three types of child process: worker, cache manage, and cache loader. They used shared memory for caching, session persistence, rate limits, and logging.](https://www.nginx.com/wp-content/uploads/2015/06/infographic-Inside-NGINX_process-model.png)

跟进程管理相关，有如下4个全局对象：

+ `ngx_int_t  ngx_process_slot` ：ngx_processes数组的下标。
+ `ngx_socket_t  ngx_channel`：worker监听的socket，这里叫channel。
+ `ngx_int_t  ngx_last_process`：ngx_processes的最后一个元素。
+ `ngx_process_t    ngx_processes[NGX_MAX_PROCESSES]`：全局process数组。

每个Nginx进程用如下结构来表示：

```c
typedef struct {
    ngx_pid_t           pid;
    int                 status;
    ngx_socket_t        channel[2];

    ngx_spawn_proc_pt   proc;
    void               *data;
    char               *name;

    unsigned            respawn:1;
    unsigned            just_spawn:1;
    unsigned            detached:1;
    unsigned            exiting:1;
    unsigned            exited:1;
} ngx_process_t;
```

主进程初识化每个worker的时候，都会基于**socketpair**创建一对连接的socket，用作主从通信的channel。

```c
typedef struct {
     ngx_uint_t  command;
     ngx_pid_t   pid;
     ngx_int_t   slot;
     ngx_fd_t    fd;
} ngx_channel_t;
```

worker通过监听channel上的command，来控制Nginx Process；

# 启动过程

## 注册信号

> ngx_init_signals

利用系统调用`sigaction`， 将全局信号对象`ngx_signal_t  signals`注册到系统中，其中定义了各个信号的处理函数。

> `sigaction`信号注册例子：<https://github.com/layamon/multi-processes-demo/blob/master/sighandler.c>
>
> 先构造一个`sigaction`数据结构，然后当参数传进去。

```c
ngx_signal_t  signals[] = {
    { ngx_signal_value(NGX_RECONFIGURE_SIGNAL),
      "SIG" ngx_value(NGX_RECONFIGURE_SIGNAL),
      "reload",
      ngx_signal_handler },

    { ngx_signal_value(NGX_REOPEN_SIGNAL),
      "SIG" ngx_value(NGX_REOPEN_SIGNAL),
      "reopen",
      ngx_signal_handler },
```

`ngx_signal_handler`中按照`ngx_process`分别处理各种不同进程中的信号，该变量有如下取值：

```c
#define NGX_PROCESS_SINGLE     0
#define NGX_PROCESS_MASTER     1
#define NGX_PROCESS_SIGNALLER  2
#define NGX_PROCESS_WORKER     3
#define NGX_PROCESS_HELPER     4
```

## 初始化并启动worker

`ngx_start_worker_processes`按照配置的进程数，挨个启动worker，进程的不同阶段，更新相应的进程状态。

```c
// 就是这里：
    unsigned            respawn:1;
    unsigned            just_spawn:1;
    unsigned            detached:1;
    unsigned            exiting:1;
    unsigned            exited:1;
} ngx_process_t;
#define NGX_PROCESS_NORESPAWN     -1
#define NGX_PROCESS_JUST_SPAWN    -2
#define NGX_PROCESS_RESPAWN       -3
#define NGX_PROCESS_JUST_RESPAWN  -4
#define NGX_PROCESS_DETACHED      -5
```

ngx_spawn_process执行每个worker初识化并启动的操作：

首先，在全局数组`ngx_processes`中，创建一个槽，设置其中连接的channel[2]；然后，fork子进程。

# Master与Worker之间的通信

在`ngx_master_process_cycle`中，通过Main中注册的信号监听回调，当收到某些信号时，将设置如下全局状态对象。

```c
sig_atomic_t  ngx_reap;
sig_atomic_t  ngx_sigio;
sig_atomic_t  ngx_sigalrm;
sig_atomic_t  ngx_terminate;
sig_atomic_t  ngx_quit;
sig_atomic_t  ngx_debug_quit;
ngx_uint_t    ngx_exiting;
sig_atomic_t  ngx_reconfigure;
sig_atomic_t  ngx_reopen;
```

## Master控制Worker

在MasterLoop中，不断检查这些标志位，然后进行相应的操作，不同的操作会通过`ngx_signal_worker_processes`给worker发送不同的指令（`ngx_write_channel(ngx_processes[n].channel[0],`前文知道，启动新worker的时候，相应的ngx_process有自己的channel，并且是通过socketpair创建的一个连接对）。

## Worker的惊群问题

Nginx Master先创建的ListenSocket，然后fork的子进程。如果子进程都阻塞在accept上，那么当有连接到来时，所有子进程都会被唤醒去accept该连接。其实在Linux的某个内核版本后，将这个当做问题修复了，即，多个进程accept同一个fd，那么只会唤醒一个，其他的进程的accept返回`EAGAIN`。

而在Nginx中，我们是基于epoll_wait进行监听处理，尽管没有了accept的问题，但是在epoll这一层还是存在惊群问题。一般的解决方式，在这里加一个互斥锁`accept_mutex`，该锁的实现机制就是一个compare&swap的原子操作[AO_compare_and_swap](<http://www.ccp4.ac.uk/dist/checkout/gc-7.2e/libatomic_ops/src/atomic_ops/sysdeps/gcc/mips.h>)。





