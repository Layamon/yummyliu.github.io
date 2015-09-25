---
layout: post
title: 
date: 2021-04-08 16:15
categories:
  -
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}



1. log buffering: 将trxbuffer中国的batch，转移到logbuffer中，按log中的结构组织，比如logblock的CRC32。
2. log flushing：将log buffer写到log file中，此时需要确定log sequence number。
3. write memtable：如名。
4. commit：释放资源，返回commit OK。

