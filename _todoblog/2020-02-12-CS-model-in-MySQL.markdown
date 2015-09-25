---
layout: post
title: 事务请求在MySQL内的流转
date: 2020-02-12 08:51
categories:
  - MySQL
typora-root-url: ../../layamon.github.io
---
> * TOC
{:toc}

client发起一个select查询，在第一次查询会在do_comand处断住，但是之后的查询直接就返回结果了，但是server端进了do_comand断点。

do_command函数返回，客户端就收到结果了，



MySQL只用了poll和select，没有用epoll，见socket_connection.cc:851。
