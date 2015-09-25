---
layout: post
title: 了解Pgbouncer的配置
date: 2018-02-07 10:52
header-img: "img/head.jpg"
categories: 
    - PostgreSQL
    - Pgbouncer
---

# pgbouncer

1. `pgbouncer.ini`
2. user auth file
3. 常用命令

## pgbouncer.ini

ini格式的配置文件，以`;`或者`#`开头的行是注释行，但是在行内的不认为是注释

在配置项里有三个用户，stats_user,admin_user,auth_file中的user;

pgboucner自己会维护一个特殊的数据库，stats_user 只能连接pgbouncer数据库 执行 show命令;

admin_user可以执行所有的命令，也可以连接所有的数据库,如果auth_type不为any，那么用户都需要在auth_file中读取；

auth_file文件的配置如下：

### 常规配置

+ pidfile : 配置这个才能 -d 守护进程

+ listen_addr : 不配，就只监听Unix socket

+ listen_port

+ unix_socket_dir : 默认 /tmp; socket文件目录

+ unix_socket_mode : default 0777

+ unix_socket_group

+ user : pgbouncer如果用root用户启动，可以切换到这个用户

+ auth_file : md5 or plain-text passwd

  ```
  "username1" "password" ...
  "username2" "md5abcdef012342345" ...
  ```

+ auth_type :

  + pam : ignored auth_file, use `PAM` to authenticate user;
  + hba : use auth_hba_file
  + cert : Use TLS connection
  + md5 : (default); MD5-based passwd check;
  + plain : (deprecated);
  + trust : 不需要认证，但是用户名必须在auth_file中
  + any : 和trust一样，并且也不需要在auth_file中读取文件。

+ auth_hba_file

+ auth_query : 从数据库中查询密码的sql

  default: `SELECT usename, passwd FROM pg_shadow WHERE usename=$1`

+ auth_user : 该项设置后，auth_user从auth_file读取，如果auth_file中没有，那么就用auth_query从pg_shadow中获取。

+ pool_mode: when server connection can be reuse by other client

  + session: client断开连接，可复用
  + transaction: 事务结束
  + statement： 查询结束

+ max_client_conn: default 100

  提高该项的值，同时应该提高系统文件描述符限制；理论上最大的文件描述符是：

  ```
  max_client_conn + (max_pool_size * total_databases * total_users)
  ```

  如果所有用户都用同一个数据库用户登录数据库，那么上式为

  ```
  max_client_conn + (max_pool_size * total_databases)
  ```

+ default_pool_size： 20

  每个user-db对的连接池默认大小

+ min_pool_size:

  连接池中维护的最少连接，为了保证当系统长时间不运行，突然来流量，不用从0开始

+ reserve_pool_size

  client到来的时候，如果pool_size是10，10个都在使用，那么就要等待；如果在等待`reserve_pool_timeout`时间后，还是没有old释放，那么系统获得reserve_pool_size个新的连接。如果到达 `pool_size+reserve_pool_size` ，那么新的client就要等待了。从`show pools`可以看到等待的client数。

+ reserve_pool_timeout

+ max_db_connections

  每个后端数据库允许的最大连接数，注意这里是针对后端数据库来计数的，就是不同的用户连接到同一个数据库上，算在一起；所以，如果用户A断开连接了后端的db连接，并不是立马断开，所以此时用户B不能立马获得新的连接。而是要等db连接idle timeout之后，才能建立新的连接；所以还是用一个用户建立连接池吧。

+ max_user_connections

  和上面的类似，只是这个是在user层面的限制，同样的一个用户连接数据库A的连接断开，该用户想重用这个连接，连接B，也需要等待pool重新建立连接。故最佳的使用方式就是用一个pgbouncer上，是同一个数据库用户，登录同一个数据库。

+ server_round_robin

  pgbouncer按照LIFO的方式，重用连接，这样只有少量的连接负载比较大。启动这个就使用循环的方式

+ ignore_startup_parameters

+ disable_pqexec

  禁止simple query protocol, 提高安全性，避免sql注入

### 日志配置

+ stats_period: 隔一段时间输出一个统计log信息

###访问控制

+ admin_users:

  逗号分隔的用户名，这些用户可以运行任何命令；如果auth_type是any，忽略这个配置，因为那样的话，都是任何用户都是adminuser

+ stats_users

  执行read-only查询的用户，SHOW commands expect show FDS

### 连接状态检查

+ server_reset_query； default DISCARD ALL

  如果是transaction pool，那么server_reset_query不会被使用。

+ server_check_delay: 30

  一段时间执行一次server_check_query

+ server_check_query: select 1

+ server_lifetime: 3600s

  关闭超过$@时间的db连接

+ server_idle_timeout 600s

  关闭闲置$@时间的连接

+ server_connect_timeout

  超过$@时间还没完成的连接，关闭

+ server_login_retry

+ client_login_timeout

+ autodb_idle_timeout

+ dns_max_ttl

  dns缓存过期时间

+ dns_nxdomain_ttl

  dns错误过期时间

+ dns_zone_check_period

  dns namespace的一部分连续子集。pgbouncer可以根据hostname获取相应的dns zone，并间隔一段时间检查zone信息是否改变。

  基于udns和cares编译的pgbouncer才提供这一功能。

### TLS 设置

+ client_tls_sslmode
  + disable: plain tcp
  + allow/prefer: 都OK
  + require：必须的
  + verify-ca/verify-full: TLS with client certificate
+ client_tls_key_file
+ client_tls_cert_file
+ client_tls_ca_file
+ client_tls_protocls ...
+ server_tls_sslmode

### 危险的超时

这些超时设置，可能引起异常

+ query_timeout; 0

  查询执行时间过长取消，应该设置成稍微比 postgresql.conf的statement_timeout小

+ query_wait_timeout; 120

  查询等待超时，如果disable，那么都在无限等待

+ client_idle_timeout; 0

+ idle_transaction_timeout; 0

### 底层网络设置

+ pkt_buf: 4096

  packet buffer

+ max_packet_size: 2147483647

  one query or one result set row

+ listen_backlog

  `listen(2)`的第二个参数，listen的等待队列大小。

+ sbuf_loopcnt

  一个连接可以处理几次数据。one loop precesses on `pkt_buf` amount of data. 如果连接上有很大的结果集，如果不限制这个，会拖慢pgbouncer.

+ suspend_timeout

  当SUSPEND 或 重启的时候，buffer flush的等待时间，如果·flush失败，那么连接就drop掉了。

+ tcp_defer_accept

  listen一个socket的时候，接收到一个connect的时候，只有真正的数据来的才会调用accept接收这个端口，否则超时关闭了。

+ tcp_socket_buffer

+ tcp_keepalive

  启动系统的tcp keepalive

###[databases]

libpq的连接字符串。

`*` 作为一个后备的连接串，如果其他的串没有匹配就用这个连接。

### [users]

连接池可以是以上面的database作为一个维度，可以以user作为一个维度，相应的配置有`max_db_connections` `max_user_connections`;

