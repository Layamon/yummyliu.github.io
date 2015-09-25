---
layout: post
title: PostgreSQL Extension 开发日志
date: 2018-08-07 14:09
categories: 
  - PostgreSQL
  - C++
---

* TOC
{:toc}

> 都知道PostgreSQL是一个扩展性很强的DB，可以自己基于提供的接口，完成一些extension；该extension作为一个管理插件，没有它工作也能完成，但是搞着玩玩，过程记录在这，未完待续...

## 前言

从做一个巡检的插件（[patrol](https://github.com/layamon/patrol)）开始；需要使用C++的json以及网络库，所以采用C/C++混编的方式实现，该插件分为两部分：

+ Commander: PostgreSQL的一个background worker，维护巡检的信息表，以及与patrol通信获取数据；
+ Patrol：实现的AgentServer（Golang），Commander向这些agent服务询问db及os的巡检信息。

目前各个环节初步调通，整理下花时间比较多的坑（未完待续）。

## 搭建一个PostgreSQL的开发环境

做PostgreSQL开发，首先要有一个PostgreSQL实例，后还有各种`lib***-dev`的包，特麻烦。

#### 解决：Docker

先做了个 [postgresql-dev-docker](https://github.com/layamon/postgresql-dev) 的基础镜像，基础镜像里加了一个开发的包，然后基于这个基础镜像编写Commander的Dockerfile。

```dockerfile
FROM postgresql-dev

ADD . /commander

RUN apk add libstdc++ curl-dev jsoncpp-dev && \
	chmod +x /usr/local/bin/gosu && \
    rm -rf /docker-entrypoint-initdb.d && \
    mkdir /docker-entrypoint-initdb.d && \
    apk del curl && \
    rm -rf /var/cache/apk/*

ENV LANG en_US.utf8
ENV PGDATA /var/lib/postgresql/data
VOLUME /var/lib/postgresql/data

COPY docker-entrypoint.sh /

ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 5433
CMD ["postgres"]
```

写完了之后，docker build、docker run即可；意外收获，用了docker后，PostgreSQL不在电脑上跑，电脑再也不发热了！有点小问题，docker build每次都需要下载，不过现在还能忍受，可以提醒自己喝杯水。

## 结合PGXS，编写C/C++混编的Makefile

明白PGXS各个参数的意义，挨个凑吧，不过凑的过程还挺漫长，结果如下：

```makefile
MODULE_big = commander

EXTENSION = commander
DATA = commander--1.0.sql

CXX = c++ -std=c++11 -I/usr/local/include -I/usr/local/opt/openssl/include

#CFLAGS_SL += -stdlib=libc++ -lcpprest -lssl -lcrypto -lboost_system -lboost_thread-mt -lboost_chrono-mt
CFLAGS_SL +=  -fPIC
PG_CPPFLAGS +=  -fPIC
SHLIB_LINK += -lstdc++ -lcurl -ljsoncpp
#PG_CPPFLAGS += -std=c++11
OBJS +=  command/command.o command/httpclient.o commander.o

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
```

基于OBJS，链接成MODULE_big，其中httpclient是c++文件，command是c/c++混编，commander是纯c。

##  ERROR: invalid memory alloc

```
2018-08-07 16:57:52.436 CST [52842] ERROR:  invalid memory alloc request size 18446744072367376384
2018-08-07 16:57:52.436 CST [52842] STATEMENT:  select getjson();
INFO:  msg: [{"id":1,"maxage":19234,"name":"postgres"},{"id":2,"maxage":1239082,"name":"pgbench"}]
ERROR:  invalid memory alloc request size 18446744072367376384
```

获取到的json结果，在如下函数返回时，报错如上的错误。

```c
PG_RETURN_CSTRING(output.c_str() );
```

#### 解决：pstrdup

```
PG_RETURN_CSTRING(pstrdup(output.c_str()));
```

## 字符串截断

```
postgres=# select getjson();
INFO:  msg: [{"id":1,"maxage":19234,"name":"postgres"},{"id":2,"maxage":1239082,"name":"pgbench"}]

                   getjson
----------------------------------------------
 {"id":1,"maxage":19234,"name":"postgres"},{"
(1 row)
```

#### 解决：类型不对

text转ctring，调用函数时再做转化（似乎有点别扭，先能用再说）。

```sql
CREATE OR REPLACE FUNCTION getjson () 
    RETURNS cstring
AS 'commander.so',
'getjson'

select
    getjson::json ->> 1
from (
    select
        getjson ()::text) as a;
```



（未完待续）
