---
layout: post
title: Pgbouncer源码——Sbuf
subtitle: Pgbouncer的信息传输通道，与异步IO
date: 2018-06-10 18:06
header-img: "img/head.jpg"
categories: 
    - PostgreSQL
    - Pgbouncer
---

# Sbuf

### Sbuf介绍

```c
/*
 * Stream Buffer.
 *
 * Stream is divided to packets.  On each packet start
 * protocol handler is called that decides what to do.
 */
struct SBuf {
	struct event ev;	/* libevent handle */

	uint8_t wait_type;	/* track wait state */
	uint8_t pkt_action;	/* method for handling current pkt */
	uint8_t tls_state;	/* progress of tls */

	int sock;		/* fd for this socket */

	unsigned pkt_remain;	/* total packet length remaining */

	sbuf_cb_t proto_cb;	/* protocol callback */

	SBuf *dst;		/* target SBuf for current packet */

	IOBuf *io;		/* data buffer, lazily allocated */

	const SBufIO *ops;	/* normal vs. TLS */
	struct tls *tls;	/* TLS context */
	const char *tls_host;	/* target hostname */
};
```

stream buffer，用来在不同socket之间高效传输数据的，同时解析packet header信息，调用相关的callback；如下是sbuf定义的两个状态表示符：一个是sbuf中的packet相关的，一个是sbuf自身相关的

###### pkt_action

```c
#define ACT_UNSET 0
#define ACT_SEND 1
#define ACT_SKIP 2
#define ACT_CALL 3
```

sbuf中是若干个packet，sbuf->pkt_action主要是在后三者之间切换，分别是发送，跳过和调用callback处理这个packet，如下code：

```c
		switch (sbuf->pkt_action) {
		case ACT_SEND:
			iobuf_tag_send(io, avail);
			break;
		case ACT_CALL:
			res = sbuf_call_proto(sbuf, SBUF_EV_PKT_CALLBACK);
			if (!res)
				return false;
			/* after callback, skip pkt */
		case ACT_SKIP:
			iobuf_tag_skip(io, avail);
			break;
		}
```

###### wait_type

```c
enum WaitType {
	W_NONE = 0,
	W_CONNECT,
	W_RECV,
	W_SEND,
	W_ONCE
};
```

这是sbuf自身在等待的事件的标识，记录好自己当前的状态，使用assert断言，确保在执行某些操作时的状态正确性，比如在关闭sbuf时，确保状态是W_NONE的：

```c
bool sbuf_close(SBuf *sbuf)
{
	if (sbuf->wait_type) {
		Assert(sbuf->sock);
		/* event_del() acts funny occasionally, debug it */
		errno = 0;
		if (event_del(&sbuf->ev) < 0) {
			if (errno) {
				log_warning("event_del: %s", strerror(errno));
			} else {
				log_warning("event_del: libevent error");
			}
			/* we can retry whole sbuf_close() if needed */
			/* if (errno == ENOMEM) return false; */
		}
	}
	sbuf_op_close(sbuf);
	sbuf->dst = NULL;
	sbuf->sock = 0;
	sbuf->pkt_remain = 0;
	sbuf->pkt_action = sbuf->wait_type = 0;
	if (sbuf->io) {
		slab_free(iobuf_cache, sbuf->io);
		sbuf->io = NULL;
	}
	return true;
}
```

###### IOBuf

Sbuf中，lazy allocate的临时IO缓存；iobuf中有三个pos：

+ done_pos之前是已发送的
+ done_pos到parse_pos之前是已经解析过的，等待发送的
+ parse_pos到recv_pos之前的是已经接收过的，等待解析

```c
struct iobuf {
	unsigned done_pos;
	unsigned parse_pos;
	unsigned recv_pos;
	uint8_t buf[FLEX_ARRAY];
};
typedef struct iobuf IOBuf;
```

### Sbuf操作

pgbouncer的主要流程就是：接收packet，放在stream buf里，根据不同的情况，执行proto_cb；处理这个packet；

proto_cb就两个：

- client_proto
- server_proto 

Sbuf作为这一整个数据流的高速通道，其对外提供若干Public接口来操作sbuf；为实现这些对外接口，定义了内部的一些函数

##### Public Function

```c
/* initialize SBuf with proto handler */
void sbuf_init(SBuf *sbuf, sbuf_cb_t proto_fn)
/* got new socket from accept() */
bool sbuf_accept(SBuf *sbuf, int sock, bool is_unix)
/* need to connect() to get a socket */
bool sbuf_connect(SBuf *sbuf, const struct sockaddr *sa, int sa_len, int timeout_sec)
/* don't wait for data on this socket */
bool sbuf_pause(SBuf *sbuf)
/* resume from pause, start waiting for data */
void sbuf_continue(SBuf *sbuf)
/*
 * Resume from pause and give socket over to external
 * callback function.
 *
 * The callback will be called with arg given to sbuf_init.
 */
bool sbuf_continue_with_callback(SBuf *sbuf, sbuf_libevent_cb user_cb)
bool sbuf_use_callback_once(SBuf *sbuf, short ev, sbuf_libevent_cb user_cb)
/* socket cleanup & close: keeps .handler and .arg values */
bool sbuf_close(SBuf *sbuf)
```

sbuf是和socket对应了，在pgb中有两类socket，因此

+ sbuf_connect

  `launch_new_connection`中pgb去连接pgserver；

  ```c
  	sock = socket(sa->sa_family, SOCK_STREAM, 0);
  	if (sock < 0) {
  		/* probably fd limit */
  		goto failed;
  	}

  	if (!tune_socket(sock, is_unix))
  		goto failed;

  	sbuf->sock = sock;
  ```

+ sbuf_accept

  `accept_client`中，pgb接收client的连接，这里的socket是服务端

  ```c
  //sbuf_accept... 绑定
  	sbuf->sock = sock;
  	if (!tune_socket(sock, is_unix))
  		goto failed;
  //sbuf_wait_for_data... 注册event监听
  	event_set(&sbuf->ev, sbuf->sock, EV_READ | EV_PERSIST, sbuf_recv_cb, sbuf);
  	err = event_add(&sbuf->ev, NULL);
  	if (err < 0) {
  		log_warning("sbuf_wait_for_data: event_add failed: %s", strerror(errno));
  		return false;
  	}
  // 设置sbuf状态，等待数据
  	sbuf->wait_type = W_RECV;
  ```

+ 在client_proto和server_proto这两个callback中，设置pkt_action等参数，表示要进行的操作

```c
/* proto_fn tells to send some bytes to socket */
void sbuf_prepare_send(SBuf *sbuf, SBuf *dst, unsigned amount)
/* proto_fn tells to skip some amount of bytes */
void sbuf_prepare_skip(SBuf *sbuf, unsigned amount)
/* proto_fn tells to skip some amount of bytes */
void sbuf_prepare_fetch(SBuf *sbuf, unsigned amount)
```

##### Internal Function

```c
/*
 * Main recv-parse-send-repeat loop.
 *
 * Reason for skip_recv is to avoid extra recv().  The problem with it
 * is EOF from socket.  Currently that means that the pending data is
 * dropped.  Fortunately server sockets are not paused and dropping
 * data from client is no problem.  So only place where skip_recv is
 * important is sbuf_send_cb().
 */
static void sbuf_main_loop(SBuf *sbuf, bool skip_recv)
```

该函数是sbuf处理数据的主要流程：

1. 分配iobuf空间

2. 如果标记了skip_recv，跳到skip_recv处执行

3. try_more:

   1. iobuf清理done的数据

   2. 判断是否超过sbuf_loopcnt，超过就处理好当前的数据，强制等待数据的状态中

      1. sbuf_process_pending
      2. sbuf_wait_for_data_forced

      > pgb是单进程，在一个查询上耽误太多时间，影响别的查询

   3. 基于iobuf能装下的最多的数据，来接收新的数据

4. skip_recv:

   1. sbuf_process_pending尽可能多的处理sbuf中的packet

      > 根据sbuf->pkt_action对packet操作，如果是ACT_CALL状态，那么调用client/server_proto回调，回调中可能会接着调用`handle_client_work`，其中调用`sbuf_prepare_send/skip`，进一步设置了下一个sbuf的状态;
      >
      > 从代码上，是如上的逻辑，才能实现**尽可能多**的处理packet；但是ACT_CALL只有在sbuf_prepare_fetch中才会设置，但是sbuf_prepare_fetch这个函数，没有人调用；所以似乎没什么用，这个函数写的也有点像未完成：
      >
      > ```c
      > /* proto_fn tells to skip some amount of bytes */
      > void sbuf_prepare_fetch(SBuf *sbuf, unsigned amount)
      > {
      > 	AssertActive(sbuf);
      > 	Assert(sbuf->pkt_remain == 0);
      > 	/* Assert(sbuf->pkt_action == ACT_UNSET || iobuf_send_pending_avail(&sbuf->io)); */
      > 	Assert(amount > 0);
      >
      > 	sbuf->pkt_action = ACT_CALL;
      > 	sbuf->pkt_remain = amount;
      > 	/* sbuf->dst = NULL; // FIXME ?? */
      > }
      > ```

   2. 处理packet后，若iobuf是满的，那么可能还有data，所以抓到try_more上继续执行

   3. 没有更多的数据，那么清理done的数据；

   4. 若sbuf处理后empty了，调用sbuf_call_proto(sbuf, SBUF_EV_FLUSH);
