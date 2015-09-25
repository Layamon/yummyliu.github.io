---
layout: post
title: Pgbouncer源码——TakeOver
subtitle: 结合Pgbouncer，深入Linux中进程之间的数据交互
date: 2018-06-13 08:07
header-img: "img/head.jpg"
categories: 
  - PostgreSQL
  - Pgbouncer
---

> * TOC
{:toc}

## 背景

在pgbouncer启动的时候，会创建一个dbname为pgbouncer的的假连接池，作为admin pool；当pgbouncer使用`-R`参数online reboot的时候，启动另一个进程，接管原来的socket fd 和 objects，具体的接管流程在takeover模块中，分为两个部分：

> -R参数只有在系统支持Unix Sockets，并且`unix_socket_dir` enabled才能用

```c
// Part 1
	if (cf_reboot) {
		if (check_old_process_unix()) {
			takeover_part1();
			did_takeover = true;
		} else {
			log_info("old process not found, try to continue normally");
			cf_reboot = 0;
			check_pidfile();
		}
	}

......
    if (cf_daemon)
		go_daemon();
    
// Part 2
    if (did_takeover) {
		takeover_finish();
	} else {
		pooler_setup();
	}
```

## takeover Part1

Part_1中，new pgb连接上old pgb，通过show fds，获取到old fds，并`takeover_load_fd`；

```c
//	takeover_load_fd

	if (cmsg->cmsg_level == SOL_SOCKET
		&& cmsg->cmsg_type == SCM_RIGHTS
		&& cmsg->cmsg_len >= CMSG_LEN(sizeof(int)))
	{
		/* get the fd */
		memcpy(&fd, CMSG_DATA(cmsg), sizeof(int));
		log_debug("got fd: %d", fd);
	} else {
		fatal("broken fd packet");
	}
```

takeover_init takeover初始化时，主要有以下几步：

1. 取出admin pool：pgbouncer；

2. 新的admin pool向老的pgbouncer的发起连接，就是一个尝试的登录请求`db=pgbouncer user=pgbouncer`；

3. main_loop_once 处理连接登录的消息

   1. SBUF_EV_CONNECT_OK： 连接成功

   2. SBUF_EV_READ：auth ok

   3. 以及若干个SBUF_EV_READ： 服务器的信息，比如编码等

   4. 最后登录成功，进入`takeover_login`，给old pgb发送指令

      1. SUSPEND

         ```bash
         2018-06-14 11:31:14.709 10444 LOG S-0x67a580: pgbouncer/pgbouncer@unix:6432 Login OK, sending SUSPEND
         ```

      2. SHOW FDS

         ```bash
         2018-06-14 11:31:22.184 10444 LOG SUSPEND finished, sending SHOW FDS
         2018-06-14 11:31:28.661 10444 DEBUG got fd: 12
         2018-06-14 11:31:28.661 10444 DEBUG FD row: fd=12(12) linkfd=0 task=pooler user=NULL db=NULL enc=NULL
         2018-06-14 11:31:28.661 10444 LOG got pooler socket: 127.0.0.1:6432
         2018-06-14 11:31:28.661 10444 DEBUG takeover_parse_data: 'D'
         2018-06-14 11:31:28.661 10444 DEBUG got fd: 13
         2018-06-14 11:31:28.661 10444 DEBUG FD row: fd=13(13) linkfd=0 task=pooler user=NULL db=NULL enc=NULL
         2018-06-14 11:31:28.661 10444 LOG got pooler socket: unix:6432
         ```

      3. CommandComplete

   5. takeover_finish_part1

## takeover Part2

Part2中，new pgb已经通过fork子进程的方式，完成了守护进程的方式运行；此时进行一个收尾工作:

1. 向old pgb发送：`SHUTDOWN`命令；

   ```bash
   2018-06-13 11:38:30.775 7658 LOG sending SHUTDOWN;
   2018-06-13 11:38:30.775 7497 LOG SHUTDOWN command issued
   ```

2. 等待old pgb成功shutdown；

3. 关闭老的pgbouncer的连接

   ```bash
   2018-06-13 11:38:30.776 7658 LOG S-0x249d690: pgbouncer/pgbouncer@unix:6432 closing because: disko over (age=0)
   2018-06-13 11:38:30.776 7658 LOG waiting for old pidfile to go away
   ```

4. 原来已经建立的socket连接，重新开始工作；原来的pool重新开始监听；

   ```bash
   2018-06-13 11:38:30.776 7658 LOG old process killed, resuming work
   2018-06-13 11:38:30.776 7658 LOG process up: pgbouncer 1.8.1, libevent 2.0.21-stable (epoll), adns: c-ares 1.10.0, tls: OpenSSL 1.0.1e-fips 11 Feb 2013
   ```

## Questions

1. pgbouncer如何做到新进程接管老进程？

   `takeover_load_fd` 

2. pgbouncer如何切换的进程？

   在admin.c中，有处理shutdown指令的handler，并没有在handler中主动，停止进程，而是设置一个标志`cf_showdown`，

   ```c
   	log_info("SHUTDOWN command issued");
   	cf_shutdown = 2;
   	event_loopbreak();
   ```

   然后在main函数中，每次的main_loop会判断这个 函数，确定是否退出

   ```c
   	/* main loop */
   	while (cf_shutdown < 2)
   		main_loop_once();
   ```

   这就是为什么在新的pgbouncer进程在给老pgbouncer发送shutdown之后，需要等待一会，确保旧的pid文件没有

   ```c
   	if (cf_pidfile && cf_pidfile[0]) {
   		log_info("waiting for old pidfile to go away");
   		while (1) {
   			struct stat st;
   			if (stat(cf_pidfile, &st) < 0) {
   				if (errno == ENOENT)
   					break;
   			}
   			usleep(USEC/10);
   		}
   	}
   ```



