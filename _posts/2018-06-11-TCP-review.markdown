---
layout: post
title: 回顾TCP
date: 2018-06-11 16:30
header-img: "img/head.jpg"
categories: 
  - Network
typora-root-url: ../../yummmyliu.github.io
---

* TOC
{:toc}
# TCP 状态

TCP总共有11中状态：

- CLOSED：无链接的状态。

- LISTEN：server等待client链接的状态。

- SYN-SENT：三次握手的第一步，client发送一个链接请求后的状态。

- SYN-RECEIVED：三次握手的第二步，client收到了链接请求的ACK后的状态。

- ESTABLISHED：三次握手的第三步，链接最终打开了的状态。

  > 在关闭时，两段是相同的。这里讲发起关闭的一端称为：本端。另一个叫：远端。

- FIN-WAIT-1：四次挥手的第一步，本端发送了一个终止链接的请求（**FIN**）后的状态。

- CLOSE-WAIT：远端收到一个终止链接的请求，并且回复了ACK后的状态。比如，本端主动关闭链接而远端被动关闭链接时，远端还需要主动的`close()`，从而离开这个状态，若代码中client端没有主动关闭，可能有bug。

- FIN-WAIT-2：本端**在FIN-WAIT-1**状态后，如果**只收到了**远端的对于关闭请求的ACK后，本端等待远端的一个下一个**主动关闭 FIN**的请求。

- LAST-ACK：远端迟迟没有主动关闭，一段时间后，就会被动关闭并向远端发送一个**主动关闭 FIN**的请求。

- CLOSING：本端**在FIN-WAIT-1**状态后，如果先收到了远端的**主动关闭 FIN**的请求，那么进入该状态，同时等待ACK。

- TIME-WAIT：CLOSING了一段时间后，还是没有收到ACK，进入该状态。之后等了2MSL长时间后，还是没收到ACK，那么可以确认对方收到了FIN，最终关闭。

## 状态转换图

从网上摘了个图：

![](/../layamon.github.io/image/tcp-overview/tcp.gif)

# TCP连接建立与断开

## 三次握手🤝：

### 流程

对于每个处于**LISTENING**状态的Socket，都有两个Queue（也叫backlog，积压）：

+ SYN Queue
+ Accept Queue

当client发起连接时，有如下三步：

1. client发送**SYN**。
2. server接收**SYN**，放入`SYN QUEUE`中；给client返回 **SYN+ACK**。
3. client发送**ACK**；

server收到ACK后，先和ESTABLISHED的连接对比，然后和`SYN QUEUE`中的对比；对比成功，syn queue中的slot删掉，创建一个新的inet_sock，放到ACCEPT QUEUE队列中；**连接建立成功**。当application调用accept的时候，相应的sockets出列，赋予给application

![img](/../layamon.github.io/image/tcp-overview/all-1.png)

以上就是通常的三次握手；但是如果设置了`TCP_FASTOPEN`和`TCP_DEFER_ACCEPT`就有点不一样

### 几个参数

#### TCP_FASTOPEN

默认系统关闭fastopen；一般TCP的CS代码如下所示：

```c
/*************************************
	client 
*************************************/
/* create socket file descriptor */
fd = socket(domain, type, protocol);
/* connect to the target server/port */
connect(fd,...);
/* send some data */
send(fd, buf, size);
/* wait for some reply and read into a local buffer */ 
while ((bytes  = recv(fd, ...))) {
    ...
}

/*************************************
	server 
*************************************/
/* create the socket */
fd = socket();
/* connect and send out some data */
bind(fd, addr, addrlen);
/* this socket will listen for incoming connections */
listen(fd, backlog);
```

加了FASTOPEN参数`echo 1 > /proc/sys/net/ipv4/tcp_fastopen`后，通过tcp的cookie，能够加快连接打开的速度。

```c
/*************************************
	client 
*************************************/
/* create the socket */
fd = socket();
/* connect and send out some data */
sendto(fd, buffer, buf_len, MSG_FASTOPEN, ...);
/* write more data */
send(fd, buf, size);
/* wait for some reply and read into a local buffer */ 
while ((bytes  = recv(fd, ...))) {
    ...
}
/*************************************
	server 
*************************************/
/* 
 * A generic protection in case you include this 
 * from multiple files 
 */
#ifndef _KERNEL_FASTOPEN
#define _KERNEL_FASTOPEN
/* conditional define for TCP_FASTOPEN */
#ifndef TCP_FASTOPEN
#define TCP_FASTOPEN   23
#endif
/* conditional define for MSG_FASTOPEN */
#ifndef MSG_FASTOPEN
#define MSG_FASTOPEN   0x20000000
#endif
#endif

/* a hint value for the Kernel */
int qlen = 5;
/* create the socket */
fd = socket();
/* bind the address */
bind(fd, addr, addrlen);
/* change the socket options to TCO_FASTOPEN */
setsockopt(sockfd, SOL_TCP, TCP_FASTOPEN, &qlen, sizeof(qlen));
/* this socket will listen for incoming connections */
listen(fd, backlog);
```

#### TCP_DEFER_ACCEPT

三次握手的第二步之后，server需要等待一个ack，才能建立连接；而之后才会有实际数据；这在建立tcp连接的时候，比较耗时；打开了TCP_DEFER_ACCEPT之后，server在接收到SYN+ACK包之后，不会等待ack，直接等待实际数据包；这能减少连接建立时的延迟。

#### AF_INET vs AF_UNIX

分别代表使用的事Unix Socket还是IP Socket。UnixSocket是一种本机内的IPC方式，实际上是一个特殊的文件，拥有inode以及权限等信息，但是是通过recv和send来读写。当bind到UnixSocket上时，我们需要使用文件路径的方式来连接而不是ip:port对。

对于UnixSocket，其数据包免去包头部分的信息，进而减少了网络栈中的数据封装与剥离的过程；另外，也少了路由的代价，从而比起127.0.0.1的性能更加优秀。

## 四次挥手👋

### 流程

在Linux中，一切皆文件，Socket也不例外；一个成功建立的Socket文件，是由两对**<IP，Port>**确定的；当其中一方TCP Close的时候，就开始了这个Socket的四次挥手的关闭流程，如下，摘自Wikipedia：

```
     TCP A                                                TCP B

  0.  ESTABLISHED                                          ESTABLISHED

  1.  (Close)
      FIN-WAIT-1  --> <SEQ=100><ACK=300><CTL=FIN,ACK>  --> CLOSE-WAIT

  2.  FIN-WAIT-2  <-- <SEQ=300><ACK=101><CTL=ACK>      <-- CLOSE-WAIT

  3.                                                       (Close)
      TIME-WAIT   <-- <SEQ=300><ACK=101><CTL=FIN,ACK>  <-- LAST-ACK

  4.  TIME-WAIT   --> <SEQ=101><ACK=301><CTL=ACK>      --> CLOSED

  5.  (2 MSL)
      CLOSED       
```

1. 发起Close的一端A，意味着我没有任何数据需要发送了，但是之后还是会接收数据，直到被通知另一端也Close了；

2. B收到FIN信号，进入CLOSE_WAIT状态，并回复ACK；TCP是可靠的，此时B会保证在B关闭之前将Buffer中的数据发送出去。*这里要确保自己会及时关闭（60s之内）这些CLOSE_WAIT状态的socket，否则会socket泄露*；

   > 如下的CLOSE_WAIT就表示echo 进程没有主动关闭连接
   >
   > [liuyangming@ymtest ~]$ netstat -nalp | grep tcp | grep 8081
   > (Not all processes could be identified, non-owned process info
   >  will not be shown, you would have to be root to see it all.)
   > tcp        0      0 0.0.0.0:8081                0.0.0.0:*                   LISTEN      50092/./echo
   > tcp        0      0 127.0.0.1:59274             127.0.0.1:8081              FIN_WAIT2   -
   > tcp        1      0 127.0.0.1:8081              127.0.0.1:59274             CLOSE_WAIT  50092/./echo

3. A收到了B的主动关闭的一个FIN信号，也会回复一个ACK；

4. 当两端都收到对方的ACK或者超时确认对方肯定收到了ACK后，两端关闭连接。

> 在原来的TCP协议中，是不允许从FIN_WAIT_2状态自动转换的；FIN_WAIT_2应该接着运行，直到另一端已经清理完毕了。但是实际上经过`tcp_fin_timeout`时间，如果收不到另一端的fin控制信号，会强制关闭自己，为了防止dos攻击；
>
> ```
> tcp_fin_timeout (integer; default: 60)
>       This specifies how many seconds to wait for a final FIN packet
>       before the socket is forcibly closed.  This is strictly a
>       violation of the TCP specification, but required to prevent
>       denial-of-service attacks.
> ```

### 几个参数

#### SO_REUSEADDR

连接关闭后，会在会在**TIME_WAIT** 阶段等待一会，这个参数允许重用**TIME_WAIT**的地址。

注意TIME_WAIT状态永远出现在主动发起关闭的一端，CLOSE_WAIT状态永远出现在被动关闭连接的一端。

## 参考文献

[syn-packet-handling-in-the-wild](https://blog.cloudflare.com/syn-packet-handling-in-the-wild/)
