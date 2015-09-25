---
layout: post
title: Pgbouncer源码——Overview
date: 2018-05-30 18:06
header-img: "img/head.jpg"
categories: 
    - Pgbouncer
---

# 文件结构

| admin.c     | show等管理操作                            |
| ----------- | ------------------------------------ |
| client.c    | 客户端连接handle                          |
| dnslookup.c | 基于c-are等库的dns查询                      |
| hba.c       | auth_type为hba时，该文件用来加载hba文件          |
| janitor.c   | 连接池的定期维护操作                           |
| loader.c    | 加载pgbouncer.ini和auth_file文件          |
| main.c      | 入口                                   |
| objects.c   | 维护pgbouncer的内部对象，各种list和cache以及tree等 |
| pam.c       | auth_type的类型为pam时用的                  |
| pktbuf.c    | packet buffer 的数据包的发送和接收             |
| pooler.c    | 连接池socket监听的处理handle                 |
| proto.c     | 协议头部信息处理                             |
| sbuf.c      | 流缓冲区                                 |
| server.c    | db server连接handle                    |
| stats.c     | pgbouncer自身的统计信息，show stats相关        |
| system.c    | libc不提供的 自己实现的系统函数                   |
| takeover.c  | 一个进程接管另一个进程                          |
| util.c      | 一些工具函数                               |
| varcache.c  | 服务配置参数的值，连接上的编码，timezone等信息          |

+ 内部对象

  + user_list：never free
  + database_list: never free
  + pool_list: never free
  + user_tree: auth_file中的user
  + pam_user_tree: pam认证方式的user
  + login_client_list: pam
  + server_cache
  + client_cache
  + db_cache
  + pool_cache
  + user_cache
  + iobuf_cache
  + autodatabase_idle_list

+ 数据结构

  + statlist: 带统计信息的双向链表

  + aatree: 简单的红黑树

  + stab： 基于链表，存储一些预先分配的对象



## SBUF

Stream Buffer:

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

Pgbouncer作为client和server的中间层，需要与client和server分别建立socket连接；SBuf作为在不同socket中高效传输数据的通道，其中定义了一些callback，检测头部信息来做一些处理，如下：

#### signal

```c
/*
 * event types for protocol handler
 */
typedef enum {
	SBUF_EV_READ,		/* got new packet */
	SBUF_EV_RECV_FAILED,	/* error */
	SBUF_EV_SEND_FAILED,	/* error */
	SBUF_EV_CONNECT_FAILED,	/* error */
	SBUF_EV_CONNECT_OK,	/* got connection */
	SBUF_EV_FLUSH,		/* data is sent, buffer empty */
	SBUF_EV_PKT_CALLBACK,	/* next part of pkt data */
	SBUF_EV_TLS_READY	/* TLS was established */
} SBufEvent;
```

注释比较明确了，需要明确两点：

1. pkt data是什么？packet data
2. TLS是什么？**Transport Layer Security** ： 加密安全的连接

#### callback

```c
bool server_proto(SBuf *sbuf, SBufEvent evtype, struct MBuf *data)
```

### client端的callback

```c
bool client_proto(SBuf *sbuf, SBufEvent evtype, struct MBuf *data)
```

分别出列client和server端连接上的sbuf的请求；

## SocketState

```c
/* each state corresponds to a list */
enum SocketState {
	CL_FREE,		/* free_client_list */
	CL_JUSTFREE,		/* justfree_client_list */
	CL_LOGIN,		/* login_client_list */
	CL_WAITING,		/* pool->waiting_client_list */
	CL_WAITING_LOGIN,	/*   - but return to CL_LOGIN instead of CL_ACTIVE */
	CL_ACTIVE,		/* pool->active_client_list */
	CL_CANCEL,		/* pool->cancel_req_list */

	SV_FREE,		/* free_server_list */
	SV_JUSTFREE,		/* justfree_server_list */
	SV_LOGIN,		/* pool->new_server_list */
	SV_IDLE,		/* pool->idle_server_list */
	SV_ACTIVE,		/* pool->active_server_list */
	SV_USED,		/* pool->used_server_list */
	SV_TESTED		/* pool->tested_server_list */
};
#define is_server_socket(sk) ((sk)->state >= SV_FREE)
```

枚举值底层就是有序的整数值，通过宏`is_server_socket(sk)`判断是client还是server的socket；

#### StateList

每个socketstate对应一个`StateList`，这是一个带有统计信息的双向链表，用来统计pgbouncer中的各个状态的信息，`show stats`命令的数据来源，如下定义；

```c
/**
 * Structure for both list nodes and heads.
 *
 * It is meant to be embedded in parent structure,
 * which can be acquired with container_of().
 */
struct List {
	/** Pointer to next node or head. */
	struct List *next;
	/** Pointer to previous node or head. */
	struct List *prev;
};

/** Define and initialize emtpy list head */
#define LIST(var) struct List var = { &var, &var }


/**
 * Header structure for StatList.
 */
struct StatList {
	/** Actual list head */
	struct List head;
	/** Count of objects currently in list */
	int cur_count;
#ifdef LIST_DEBUG
	/** List name */
	const char *name;
#endif
};

/** Define and initialize StatList head */
#ifdef LIST_DEBUG
#define STATLIST(var) struct StatList var = { {&var.head, &var.head}, 0, #var }
#else
#define STATLIST(var) struct StatList var = { {&var.head, &var.head}, 0 }
#endif
```

> 这里有一个C语言宏的小技巧：C的宏可以带参数，#var 表示参数变成一个字符串；##连接不同的参数，形成一个新的token；
>
> ```c
> STATLIST(my_list);
> ```
>
> 通过 `gcc -E macros.c -D LIST_DEBUG`验证一下，变成如下的定义，通过宏的技巧可以少敲不少代码😂
>
> ```c
> struct StatList my_list = { {&my_list.head, &my_list.head}, 0, "my_list" };
> ```

## Packet Header 信息

```c
/* old style V2 header: len:4b code:4b */
#define OLD_HEADER_LEN	8
/* new style V3 packet header len - type:1b, len:4b */
#define NEW_HEADER_LEN	5

/*
 * parsed packet header, plus whatever data is
 * available in SBuf for this packet.
 *
 * if (pkt->len == mbuf_avail(&pkt->data))
 * 	packet is fully in buffer
 *
 * get_header() points pkt->data.pos after header.
 * to packet body.
 */
struct PktHdr {
	unsigned type;
	unsigned len;
	struct MBuf data;
};
```

在其中type类型用宏定义了一些类型：

```c
/* type codes for weird pkts */
#define PKT_STARTUP_V2  0x20000
#define PKT_STARTUP     0x30000
#define PKT_CANCEL      80877102
#define PKT_SSLREQ      80877103
```

Mbuf就是Memory Buf，可以就是内存的一段区域，可以理解成最底层malloc上的一层封装；

PktHdr就是将Sbuf中每个Packet Header解析后，将信息放在这里，如果len等于`mbuf_avail(&pkt->data))`，那么说明packet中的数据是完整的；

`bool get_header(struct MBuf *data, PktHdr *pkt) _MUSTCHECK;` get_header检查packer header检查完成并且成功后，将本packer 的数据存入pkt中；

> 定了_MUSTCHECK注解，表示这个函数返回值必须要处理；

## PostgreSQL 相关结构

##### PgSocket

+ PgAddr 是一个联合体： 记录了pgserver的地址信息，可以是 ipv4 ipv6 unixsocket（port+uid/pid）

```c
/*
 * A client or server connection.
 *
 * ->state corresponds to various lists the struct can be at.
 */
struct PgSocket {
	struct List head;		/* list header */
	PgSocket *link;		/* the dest of packets */
	PgPool *pool;		/* parent pool, if NULL not yet assigned */

	PgUser *auth_user;	/* presented login, for client it may differ from pool->user */

	int client_auth_type;	/* auth method decided by hba */

	SocketState state:8;	/* this also specifies socket location */

	bool ready:1;		/* server: accepts new query */
	bool idle_tx:1;		/* server: idling in tx */
	bool close_needed:1;	/* server: this socket must be closed ASAP */
	bool setting_vars:1;	/* server: setting client vars */
	bool exec_on_connect:1;	/* server: executing connect_query */
	bool resetting:1;	/* server: executing reset query from auth login; don't release on flush */
	bool copy_mode:1;	/* server: in copy stream, ignores any Sync packets */

	bool wait_for_welcome:1;/* client: no server yet in pool, cannot send welcome msg */
	bool wait_for_user_conn:1;/* client: waiting for auth_conn server connection */
	bool wait_for_user:1;	/* client: waiting for auth_conn query results */
	bool wait_for_auth:1;	/* client: waiting for external auth (PAM) to be completed */

	bool suspended:1;	/* client/server: if the socket is suspended */

	bool admin_user:1;	/* console client: has admin rights */
	bool own_user:1;	/* console client: client with same uid on unix socket */
	bool wait_for_response:1;/* console client: waits for completion of PAUSE/SUSPEND cmd */

	bool wait_sslchar:1;	/* server: waiting for ssl response: S/N */

	int expect_rfq_count;	/* client: count of ReadyForQuery packets client should see */

	usec_t connect_time;	/* when connection was made */
	usec_t request_time;	/* last activity time */
	usec_t query_start;	/* query start moment */
	usec_t xact_start;	/* xact start moment */
	usec_t wait_start;	/* waiting start moment */

	uint8_t cancel_key[BACKENDKEY_LEN]; /* client: generated, server: remote */
	PgAddr remote_addr;	/* ip:port for remote endpoint */
	PgAddr local_addr;	/* ip:port for local endpoint */

	union {
		struct DNSToken *dns_token;	/* ongoing request */
		PgDatabase *db;			/* cache db while doing auth query */
	};

	VarCache vars;		/* state of interesting server parameters */

	SBuf sbuf;		/* stream buffer, must be last */
};
```

##### PgPool

- PgStats; 每个pool维护一个, 里面记录了这个pool中的统计信息
- PgDatabase: 对应pgbouncer.ini中[database]项的配置信息
- PgUser： 对应pgbouncer.ini中[user]项的配置信息

```c
/*
 * Contains connections for one db+user pair.
 *
 * Stats:
 *   ->stats is updated online.
 *   for each stats_period:
 *   ->older_stats = ->newer_stats
 *   ->newer_stats = ->stats
 */
struct PgPool {
	struct List head;			/* entry in global pool_list */
	struct List map_head;			/* entry in user->pool_list */

	PgDatabase *db;			/* corresponding database */
	PgUser *user;			/* user logged in as */

	struct StatList active_client_list;	/* waiting events logged in clients */
	struct StatList waiting_client_list;	/* client waits for a server to be available */
	struct StatList cancel_req_list;	/* closed client connections with server key */

	struct StatList active_server_list;	/* servers linked with clients */
	struct StatList idle_server_list;	/* servers ready to be linked with clients */
	struct StatList used_server_list;	/* server just unlinked from clients */
	struct StatList tested_server_list;	/* server in testing process */
	struct StatList new_server_list;	/* servers in login phase */

	PgStats stats;
	PgStats newer_stats;
	PgStats older_stats;

	/* database info to be sent to client */
	struct PktBuf *welcome_msg; /* ServerParams without VarCache ones */

	VarCache orig_vars;		/* default params from server */

	usec_t last_lifetime_disconnect;/* last time when server_lifetime was applied */

	/* if last connect failed, there should be delay before next */
	usec_t last_connect_time;
	unsigned last_connect_failed:1;

	unsigned welcome_msg_ready:1;
};


```

#### 综上

关于Pg的数据结构，主要是一个Pgpool，毕竟这就是连接池中间件；其中维护了database的配置，user的配置，并且记录了pool的统计信息；另外其中建立了和server和client的连接，按照不同的状态放在不同的list中；
